import Foundation

// MARK: - Cached Artist Discography
public struct CachedArtistDiscography: Sendable {
    public let studio: [Album]
    public let singles: [Album]
    public let alternates: [Album]
    public let featured: [Album]

    public init(studio: [Album], singles: [Album], alternates: [Album], featured: [Album]) {
        self.studio = studio
        self.singles = singles
        self.alternates = alternates
        self.featured = featured
    }
}



// MARK: - Flat Search Results (Ranked IDs)

public struct FlatSearchResults: Sendable {
    public let trackIDs: [UUID]
    public let albumIDs: [String]
    public let artistIDs: [String]
    public let playlistIDs: [UUID]

    public static let empty = FlatSearchResults(trackIDs: [], albumIDs: [], artistIDs: [], playlistIDs: [])

    public init(
        trackIDs: [UUID] = [],
        albumIDs: [String] = [],
        artistIDs: [String] = [],
        playlistIDs: [UUID] = []
    ) {
        self.trackIDs = trackIDs
        self.albumIDs = albumIDs
        self.artistIDs = artistIDs
        self.playlistIDs = playlistIDs
    }
}

// MARK: - Thin SQLite FTS5 Search Engine Actor

/// High-performance search engine powered by disk-backed SQLite FTS5 inverted indexes.
/// Operates with zero 100k-object in-memory snapshots and zero launch warm-up delay.
public actor SearchEngine {
    public static let shared = SearchEngine()

    private var discographyMemo: [String: CachedArtistDiscography] = [:]

    public init() {}

    // MARK: - Fast Flat ID Search (Nonblocking Concurrent Read)

    public nonisolated func searchFlat(query: String, maxResults: Int = 100) -> FlatSearchResults {
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard !cleanQuery.isEmpty else { return .empty }

        let res = LibraryDatabase.shared.searchFTS(
            query: cleanQuery,
            maxTracks: maxResults,
            maxAlbums: maxResults,
            maxArtists: maxResults,
            maxPlaylists: maxResults
        )

        return FlatSearchResults(
            trackIDs: res.trackIDs,
            albumIDs: res.albumIDs,
            artistIDs: res.artistIDs,
            playlistIDs: res.playlistIDs
        )
    }

    // MARK: - Full Structured Search for GlobalSearchView

    public func search(
        query: String,
        maxTrackResults: Int = 80,
        maxAlbumResults: Int = 40,
        maxArtistResults: Int = 40,
        libraryStore: LibraryStore? = nil
    ) async -> GlobalSearchResults {
        guard !Task.isCancelled else { return .empty }
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard !cleanQuery.isEmpty else { return .empty }

        // Query the disk-backed FTS5 index via dedicated read connection
        let flat = LibraryDatabase.shared.searchFTS(
            query: cleanQuery,
            maxTracks: maxTrackResults,
            maxAlbums: maxAlbumResults,
            maxArtists: maxArtistResults,
            maxPlaylists: 20
        )

        guard !Task.isCancelled else { return .empty }

        return await buildSearchResults(
            cleanQuery: cleanQuery,
            flat: flat,
            maxTrackResults: maxTrackResults,
            maxAlbumResults: maxAlbumResults,
            maxArtistResults: maxArtistResults,
            libraryStore: libraryStore
        )
    }

    public func searchStream(
        query: String,
        maxTrackResults: Int = 80,
        maxAlbumResults: Int = 40,
        maxArtistResults: Int = 40,
        libraryStore: LibraryStore? = nil
    ) -> AsyncStream<GlobalSearchResults> {
        AsyncStream { continuation in
            Task {
                let results = await self.search(
                    query: query,
                    maxTrackResults: maxTrackResults,
                    maxAlbumResults: maxAlbumResults,
                    maxArtistResults: maxArtistResults,
                    libraryStore: libraryStore
                )
                continuation.yield(results)
                continuation.finish()
            }
        }
    }

    // MARK: - Tree Assembly from Models

    private func buildSearchResults(
        cleanQuery: String,
        flat: (trackIDs: [UUID], albumIDs: [String], artistIDs: [String], playlistIDs: [UUID]),
        maxTrackResults: Int,
        maxAlbumResults: Int,
        maxArtistResults: Int,
        libraryStore: LibraryStore?
    ) async -> GlobalSearchResults {
        guard let store = libraryStore else {
            return .empty
        }

        // 1. Resolve Direct Tracks
        var directMatchedTracks: [SearchTreeTrackNode] = []
        directMatchedTracks.reserveCapacity(flat.trackIDs.count)
        var matchedTrackScores: [UUID: Int] = [:]

        for (rank, id) in flat.trackIDs.enumerated() {
            guard let track = await store.track(forID: id) else { continue }
            let score = 10_000 - rank * 10
            matchedTrackScores[track.id] = score
            directMatchedTracks.append(SearchTreeTrackNode(
                id: "direct_track_\(track.id.uuidString)",
                track: track,
                isDirectlyMatched: true,
                relevanceScore: score
            ))
        }

        // 2. Resolve Direct Albums
        var directMatchedAlbums: [(album: Album, artist: Artist)] = []
        directMatchedAlbums.reserveCapacity(flat.albumIDs.count)
        var matchedAlbumScores: [String: Int] = [:]

        for (rank, id) in flat.albumIDs.enumerated() {
            guard let album = await store.album(forID: id) else { continue }
            let score = 80_000 - rank * 50
            matchedAlbumScores[album.id] = score
            let primaryArtist = await store.findArtist(name: album.artist) ?? Artist(name: album.artist, albums: [album])
            directMatchedAlbums.append((album: album, artist: primaryArtist))
        }

        // 3. Resolve Direct Playlists
        var matchedPlaylists: [Playlist] = []
        let pMap = await Dictionary(store.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in flat.playlistIDs {
            guard let pl = pMap[id] else { continue }
            matchedPlaylists.append(pl)
        }

        // 4. Resolve Artists & Group Tree
        var matchedArtistScores: [String: Int] = [:]
        var artistEntities: [Artist] = []

        for (rank, id) in flat.artistIDs.enumerated() {
            let score = 100_000 - rank * 100
            if let art = await store.artistLookupIndex[id] {
                artistEntities.append(art)
            } else if let art = await store.findArtist(name: id) {
                artistEntities.append(art)
            }
        }

        // Also gather artists from direct albums and tracks
        for (album, primaryArtist) in directMatchedAlbums {
            if !artistEntities.contains(where: { $0.id == primaryArtist.id }) {
                artistEntities.append(primaryArtist)
            }
        }

        var artistTreeNodes: [SearchTreeArtistNode] = []
        var seenArtistNodeIDs = Set<String>()

        for artist in artistEntities {
            let artistNodeID = "tree_artist_\(artist.id)"
            guard seenArtistNodeIDs.insert(artistNodeID).inserted else { continue }

            let artistScore = matchedArtistScores[artist.id] ?? 0
            let isArtistDirectlyMatched = artistScore > 0

            // Lazily memoize discography groupings per artist
            let disco = self.getOrComputeDiscography(for: artist, joinedArtists: await store.settings.joinedArtists)

            func filterSectionIfNeeded(_ albums: [Album]) -> [Album] {
                if isArtistDirectlyMatched { return albums }
                return albums.filter { album in
                    (matchedAlbumScores[album.id] ?? 0) > 0 ||
                    album.tracks.contains { (matchedTrackScores[$0.id] ?? 0) > 0 }
                }
            }

            let ownLeadStudio = filterSectionIfNeeded(disco.studio)
            let ownLeadSingles = filterSectionIfNeeded(disco.singles)
            let ownLeadAlternates = filterSectionIfNeeded(disco.alternates)
            let ownFeatured = filterSectionIfNeeded(disco.featured)

            let totalAlbumsCount = ownLeadStudio.count + ownLeadSingles.count + ownLeadAlternates.count + ownFeatured.count
            guard totalAlbumsCount > 0 || isArtistDirectlyMatched else { continue }

            var seenAlbumNodeIDs = Set<String>()
            var bestTrackScoreForArtist = 0
            var bestAlbumScoreForArtist = 0

            func buildSectionNodes(for sectionAlbums: [Album], category: DiscographyCategory) -> [SearchTreeAlbumNode] {
                guard !sectionAlbums.isEmpty else { return [] }
                var nodes: [SearchTreeAlbumNode] = []

                for album in sectionAlbums {
                    let albumNodeID = "tree_album_\(artist.id)_\(album.id)"
                    guard seenAlbumNodeIDs.insert(albumNodeID).inserted else { continue }

                    let albScore = matchedAlbumScores[album.id] ?? 0
                    let isAlbumDirectlyMatched = albScore > 0
                    if isAlbumDirectlyMatched {
                        bestAlbumScoreForArtist = max(bestAlbumScoreForArtist, albScore)
                    }

                    var trackNodes: [SearchTreeTrackNode] = []
                    for track in album.tracks {
                        let trackNodeID = "tree_track_\(artist.id)_\(album.id)_\(track.id.uuidString)"
                        let tScore = matchedTrackScores[track.id] ?? 0
                        if tScore > 0 {
                            bestTrackScoreForArtist = max(bestTrackScoreForArtist, tScore)
                        }

                        if !isArtistDirectlyMatched && !isAlbumDirectlyMatched && tScore == 0 {
                            continue
                        }

                        trackNodes.append(SearchTreeTrackNode(
                            id: trackNodeID,
                            track: track,
                            isDirectlyMatched: tScore > 0,
                            relevanceScore: tScore
                        ))
                    }

                    if !isArtistDirectlyMatched && !isAlbumDirectlyMatched && trackNodes.isEmpty {
                        continue
                    }

                    nodes.append(SearchTreeAlbumNode(
                        id: albumNodeID,
                        album: album,
                        tracks: trackNodes,
                        isDirectlyMatched: isAlbumDirectlyMatched,
                        relevanceScore: max(albScore, trackNodes.map { $0.relevanceScore }.max() ?? 0),
                        category: category
                    ))
                }

                nodes.sort { nodeA, nodeB in
                    let aHas = nodeA.isDirectlyMatched || nodeA.tracks.contains(where: { $0.isDirectlyMatched })
                    let bHas = nodeB.isDirectlyMatched || nodeB.tracks.contains(where: { $0.isDirectlyMatched })
                    if aHas != bHas { return aHas && !bHas }
                    if nodeA.relevanceScore != nodeB.relevanceScore { return nodeA.relevanceScore > nodeB.relevanceScore }
                    let yA = nodeA.album.resolvedYear ?? nodeA.album.year ?? 0
                    let yB = nodeB.album.resolvedYear ?? nodeB.album.year ?? 0
                    if yA != yB { return yA > yB }
                    return nodeA.album.title.localizedCaseInsensitiveCompare(nodeB.album.title) == .orderedAscending
                }

                return nodes
            }

            let studioNodes = buildSectionNodes(for: ownLeadStudio, category: .albums)
            let singlesNodes = buildSectionNodes(for: ownLeadSingles, category: .singles)
            let alternatesNodes = buildSectionNodes(for: ownLeadAlternates, category: .alternates)
            let featuredNodes = buildSectionNodes(for: ownFeatured, category: .featuredOn)

            let allAlbumNodes = studioNodes + singlesNodes + alternatesNodes + featuredNodes
            let totalRelevance = max(artistScore, bestTrackScoreForArtist, bestAlbumScoreForArtist)

            artistTreeNodes.append(SearchTreeArtistNode(
                id: artistNodeID,
                artist: artist,
                albums: allAlbumNodes,
                isDirectlyMatched: isArtistDirectlyMatched,
                relevanceScore: totalRelevance
            ))
        }

        artistTreeNodes.sort {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.artist.name.localizedCaseInsensitiveCompare($1.artist.name) == .orderedAscending
        }

        return GlobalSearchResults(
            artistTreeNodes: Array(artistTreeNodes.prefix(maxArtistResults)),
            playlists: matchedPlaylists,
            directMatchedAlbums: Array(directMatchedAlbums.prefix(maxAlbumResults)),
            directMatchedTracks: Array(directMatchedTracks.prefix(maxTrackResults))
        )
    }

    // MARK: - Lazy Discography Memoization

    private func getOrComputeDiscography(for artist: Artist, joinedArtists: [String]) -> CachedArtistDiscography {
        if let cached = discographyMemo[artist.id] {
            return cached
        }
        var ownLeadStudio: [Album] = []
        var ownLeadSingles: [Album] = []
        var ownLeadAlternates: [Album] = []
        var featuredAlbums: [Album] = []

        for album in artist.albums {
            if album.isLeadOrCollaborativeAlbum(for: artist.name, joinedArtists: joinedArtists) {
                if album.isStudioAlbum {
                    ownLeadStudio.append(album)
                } else if album.isSingle {
                    ownLeadSingles.append(album)
                } else if album.isRemix || album.isLive {
                    ownLeadAlternates.append(album)
                } else {
                    ownLeadStudio.append(album)
                }
            } else if album.isFeaturedAlbum(for: artist.name, joinedArtists: joinedArtists) {
                featuredAlbums.append(album)
            }
        }
        let disco = CachedArtistDiscography(
            studio: ownLeadStudio,
            singles: ownLeadSingles,
            alternates: ownLeadAlternates,
            featured: featuredAlbums
        )
        discographyMemo[artist.id] = disco
        return disco
    }
}
