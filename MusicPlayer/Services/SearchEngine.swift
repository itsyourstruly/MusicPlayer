import Foundation

/// Ultra-fast, in-memory inverted search engine actor.
/// Pre-computes 2-char and 3-char prefix buckets and token posting lists for
/// tracks, albums, artists, and playlists, allowing sub-millisecond query evaluation
/// across tens of thousands of library items with zero main-thread overhead.
public actor SearchEngine {
    public static let shared = SearchEngine()

    // MARK: - Inverted Index Posting Lists

    // 2-char and 3-char prefix maps -> array of track indices
    private var trackPrefixIndex: [String: [Int]] = [:]
    // Exact word token maps -> array of track indices
    private var trackTokenIndex: [String: [Int]] = [:]

    // Album prefix and token maps
    private var albumPrefixIndex: [String: [Int]] = [:]
    private var albumTokenIndex: [String: [Int]] = [:]

    // Artist prefix and token maps
    private var artistPrefixIndex: [String: [Int]] = [:]
    private var artistTokenIndex: [String: [Int]] = [:]

    // Primary library snapshots
    private var tracks: [Track] = []
    private var albums: [Album] = []
    private var artists: [Artist] = []
    private var playlists: [Playlist] = []
    private var joinedArtists: [String] = []

    // Artist canonical dictionary for O(1) lookups
    private var artistByKey: [String: Artist] = [:]

    // ID to index mappings
    private var trackIndexByID: [UUID: Int] = [:]
    private var albumIndexByID: [String: Int] = [:]
    private var artistIndexByID: [String: Int] = [:]

    private var isIndexed: Bool = false

    public init() {}

    // MARK: - Index Management

    /// Rebuilds the in-memory inverted indices asynchronously.
    public func updateIndex(
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        joinedArtists: [String] = []
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.joinedArtists = joinedArtists

        // 1. Index Tracks
        var tPrefixIdx = [String: [Int]]()
        var tTokenIdx = [String: [Int]]()
        var tByID = [UUID: Int]()
        tByID.reserveCapacity(tracks.count)

        for (idx, track) in tracks.enumerated() {
            tByID[track.id] = idx

            let tokens = track.searchTokens.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens {
                let tokenStr = String(token)
                tTokenIdx[tokenStr, default: []].append(idx)

                if tokenStr.count >= 2 {
                    let p2 = String(tokenStr.prefix(2))
                    tPrefixIdx[p2, default: []].append(idx)
                }
                if tokenStr.count >= 3 {
                    let p3 = String(tokenStr.prefix(3))
                    tPrefixIdx[p3, default: []].append(idx)
                }
            }
        }

        // 2. Index Albums
        var albPrefixIdx = [String: [Int]]()
        var albTokenIdx = [String: [Int]]()
        var albByID = [String: Int]()
        albByID.reserveCapacity(albums.count)

        for (idx, album) in albums.enumerated() {
            albByID[album.id] = idx

            let tokens = album.searchTokens.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens {
                let tokenStr = String(token)
                albTokenIdx[tokenStr, default: []].append(idx)

                if tokenStr.count >= 2 {
                    let p2 = String(tokenStr.prefix(2))
                    albPrefixIdx[p2, default: []].append(idx)
                }
                if tokenStr.count >= 3 {
                    let p3 = String(tokenStr.prefix(3))
                    albPrefixIdx[p3, default: []].append(idx)
                }
            }
        }

        // 3. Index Artists
        var artPrefixIdx = [String: [Int]]()
        var artTokenIdx = [String: [Int]]()
        var artByID = [String: Int]()
        var aByKey = [String: Artist]()
        artByID.reserveCapacity(artists.count)
        aByKey.reserveCapacity(artists.count * 2)

        for (idx, artist) in artists.enumerated() {
            artByID[artist.id] = idx
            let aKey = ArtistParser.canonicalArtistKey(artist.name)
            if !aKey.isEmpty { aByKey[aKey] = artist }
            let rawKey = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !rawKey.isEmpty { aByKey[rawKey] = artist }

            let tokens = artist.searchTokens.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens {
                let tokenStr = String(token)
                artTokenIdx[tokenStr, default: []].append(idx)

                if tokenStr.count >= 2 {
                    let p2 = String(tokenStr.prefix(2))
                    artPrefixIdx[p2, default: []].append(idx)
                }
                if tokenStr.count >= 3 {
                    let p3 = String(tokenStr.prefix(3))
                    artPrefixIdx[p3, default: []].append(idx)
                }
            }
        }

        self.trackPrefixIndex = tPrefixIdx
        self.trackTokenIndex = tTokenIdx
        self.trackIndexByID = tByID

        self.albumPrefixIndex = albPrefixIdx
        self.albumTokenIndex = albTokenIdx
        self.albumIndexByID = albByID

        self.artistPrefixIndex = artPrefixIdx
        self.artistTokenIndex = artTokenIdx
        self.artistIndexByID = artByID
        self.artistByKey = aByKey

        self.isIndexed = true
    }

    // MARK: - Progressive Streaming Search

    /// Progressive streaming search that immediately yields top-tier direct matches,
    /// followed by the full deep discography hierarchy.
    public func searchStream(
        query: String,
        tracksFallback: [Track]? = nil,
        albumsFallback: [Album]? = nil,
        artistsFallback: [Artist]? = nil,
        playlistsFallback: [Playlist]? = nil,
        joinedArtistsFallback: [String]? = nil,
        maxTrackResults: Int = 150,
        maxAlbumResults: Int = 80,
        maxArtistResults: Int = 40
    ) -> AsyncStream<GlobalSearchResults> {
        AsyncStream { continuation in
            let cleanQuery = FuzzyMatcher.normalize(query)
            guard cleanQuery.count >= 2 else {
                continuation.yield(.empty)
                continuation.finish()
                return
            }

            let effectiveTracks = !self.tracks.isEmpty ? self.tracks : (tracksFallback ?? [])
            let effectiveAlbums = !self.albums.isEmpty ? self.albums : (albumsFallback ?? [])
            let effectiveArtists = !self.artists.isEmpty ? self.artists : (artistsFallback ?? [])
            let effectivePlaylists = !self.playlists.isEmpty ? self.playlists : (playlistsFallback ?? [])
            let effectiveJoinedArtists = !self.joinedArtists.isEmpty ? self.joinedArtists : (joinedArtistsFallback ?? [])

            guard !effectiveTracks.isEmpty || !effectiveAlbums.isEmpty || !effectiveArtists.isEmpty else {
                continuation.yield(.empty)
                continuation.finish()
                return
            }

            if !self.isIndexed {
                self.updateIndex(
                    tracks: effectiveTracks,
                    albums: effectiveAlbums,
                    artists: effectiveArtists,
                    playlists: effectivePlaylists,
                    joinedArtists: effectiveJoinedArtists
                )
            }

            guard !Task.isCancelled else {
                continuation.finish()
                return
            }

            // Phase 1: Rapid Top-Tier Direct Matches
            let topTier = self.evaluateTopTier(
                cleanQuery: cleanQuery,
                effectiveTracks: effectiveTracks,
                effectiveAlbums: effectiveAlbums,
                effectiveArtists: effectiveArtists,
                effectivePlaylists: effectivePlaylists,
                effectiveJoinedArtists: effectiveJoinedArtists,
                maxTrackResults: min(maxTrackResults, 40),
                maxAlbumResults: min(maxAlbumResults, 24),
                maxArtistResults: min(maxArtistResults, 12)
            )

            if topTier.hasResults {
                continuation.yield(topTier)
            }

            guard !Task.isCancelled else {
                continuation.finish()
                return
            }

            // Phase 2: Full Deep Ranked Search Hierarchy
            let fullResults = self.evaluateFullSearch(
                cleanQuery: cleanQuery,
                effectiveTracks: effectiveTracks,
                effectiveAlbums: effectiveAlbums,
                effectiveArtists: effectiveArtists,
                effectivePlaylists: effectivePlaylists,
                effectiveJoinedArtists: effectiveJoinedArtists,
                maxTrackResults: maxTrackResults,
                maxAlbumResults: maxAlbumResults,
                maxArtistResults: maxArtistResults
            )

            guard !Task.isCancelled else {
                continuation.finish()
                return
            }

            continuation.yield(fullResults)
            continuation.finish()
        }
    }

    // MARK: - Direct Synchronous Search

    /// Searches the library returning rich structured `GlobalSearchResults`.
    public func search(
        query: String,
        tracksFallback: [Track]? = nil,
        albumsFallback: [Album]? = nil,
        artistsFallback: [Artist]? = nil,
        playlistsFallback: [Playlist]? = nil,
        joinedArtistsFallback: [String]? = nil,
        maxTrackResults: Int = 150,
        maxAlbumResults: Int = 80,
        maxArtistResults: Int = 40
    ) -> GlobalSearchResults {
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard cleanQuery.count >= 2 else {
            return .empty
        }

        let effectiveTracks = !tracks.isEmpty ? tracks : (tracksFallback ?? [])
        let effectiveAlbums = !albums.isEmpty ? albums : (albumsFallback ?? [])
        let effectiveArtists = !artists.isEmpty ? artists : (artistsFallback ?? [])
        let effectivePlaylists = !playlists.isEmpty ? playlists : (playlistsFallback ?? [])
        let effectiveJoinedArtists = !joinedArtists.isEmpty ? joinedArtists : (joinedArtistsFallback ?? [])

        guard !effectiveTracks.isEmpty || !effectiveAlbums.isEmpty || !effectiveArtists.isEmpty else {
            return .empty
        }

        if !isIndexed {
            updateIndex(
                tracks: effectiveTracks,
                albums: effectiveAlbums,
                artists: effectiveArtists,
                playlists: effectivePlaylists,
                joinedArtists: effectiveJoinedArtists
            )
        }

        return evaluateFullSearch(
            cleanQuery: cleanQuery,
            effectiveTracks: effectiveTracks,
            effectiveAlbums: effectiveAlbums,
            effectiveArtists: effectiveArtists,
            effectivePlaylists: effectivePlaylists,
            effectiveJoinedArtists: effectiveJoinedArtists,
            maxTrackResults: maxTrackResults,
            maxAlbumResults: maxAlbumResults,
            maxArtistResults: maxArtistResults
        )
    }

    // MARK: - Phase 1: Rapid Top-Tier Evaluation

    private func evaluateTopTier(
        cleanQuery: String,
        effectiveTracks: [Track],
        effectiveAlbums: [Album],
        effectiveArtists: [Artist],
        effectivePlaylists: [Playlist],
        effectiveJoinedArtists: [String],
        maxTrackResults: Int,
        maxAlbumResults: Int,
        maxArtistResults: Int
    ) -> GlobalSearchResults {
        let queryCount = cleanQuery.count
        let queryWithThe = "the " + cleanQuery
        let spaceQuery = " " + cleanQuery

        // 1. Direct Track Hits
        var candidateTrackIndices: Set<Int> = []
        let p2 = String(cleanQuery.prefix(2))
        if let hits = trackPrefixIndex[p2] { candidateTrackIndices.formUnion(hits) }
        if cleanQuery.count >= 3 {
            let p3 = String(cleanQuery.prefix(3))
            if let hits = trackPrefixIndex[p3] { candidateTrackIndices.formUnion(hits) }
        }

        var directMatchedTracks: [SearchTreeTrackNode] = []
        var matchedTrackScores = [UUID: Int]()
        directMatchedTracks.reserveCapacity(min(candidateTrackIndices.count, maxTrackResults))

        for idx in candidateTrackIndices {
            guard idx < effectiveTracks.count else { continue }
            let track = effectiveTracks[idx]
            let normTitle = track.normalizedTitle
            var score = 0

            if normTitle == cleanQuery {
                score = 10_000
            } else if normTitle == queryWithThe || "the " + normTitle == cleanQuery {
                score = 9_500
            } else if normTitle.hasPrefix(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                score = 7_500 + Int(ratio * 1_500)
            } else if normTitle.contains(spaceQuery) {
                score = 6_000
            }

            if score > 0 {
                matchedTrackScores[track.id] = score
                directMatchedTracks.append(SearchTreeTrackNode(
                    id: "direct_track_\(track.id.uuidString)",
                    track: track,
                    isDirectlyMatched: true,
                    relevanceScore: score
                ))
            }
        }
        directMatchedTracks.sort { $0.relevanceScore > $1.relevanceScore }
        if directMatchedTracks.count > maxTrackResults {
            directMatchedTracks = Array(directMatchedTracks.prefix(maxTrackResults))
        }

        // 2. Direct Album Hits
        var candidateAlbumIndices: Set<Int> = []
        if let hits = albumPrefixIndex[p2] { candidateAlbumIndices.formUnion(hits) }
        if cleanQuery.count >= 3 {
            let p3 = String(cleanQuery.prefix(3))
            if let hits = albumPrefixIndex[p3] { candidateAlbumIndices.formUnion(hits) }
        }

        var directMatchedAlbums: [(album: Album, artist: Artist)] = []
        var matchedAlbumScores = [String: Int]()

        for idx in candidateAlbumIndices {
            guard idx < effectiveAlbums.count else { continue }
            let album = effectiveAlbums[idx]
            let normTitle = album.normalizedTitle
            var score = 0

            if normTitle == cleanQuery {
                score = 100_000
            } else if normTitle == queryWithThe || "the " + normTitle == cleanQuery {
                score = 95_000
            } else if normTitle.hasPrefix(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                score = 75_000 + Int(ratio * 15_000)
            } else if normTitle.contains(spaceQuery) {
                score = 60_000
            }

            if score > 0 {
                matchedAlbumScores[album.id] = score
                let canonicalArtistKey = ArtistParser.canonicalArtistKey(album.artist)
                let primaryArtist = artistByKey[canonicalArtistKey] ?? artistByKey[album.artist.lowercased()] ?? Artist(name: album.artist, albums: [album])
                directMatchedAlbums.append((album, primaryArtist))
            }
        }
        if directMatchedAlbums.count > maxAlbumResults {
            directMatchedAlbums = Array(directMatchedAlbums.prefix(maxAlbumResults))
        }

        // 3. Direct Artist Hits
        var candidateArtistIndices: Set<Int> = []
        if let hits = artistPrefixIndex[p2] { candidateArtistIndices.formUnion(hits) }
        if cleanQuery.count >= 3 {
            let p3 = String(cleanQuery.prefix(3))
            if let hits = artistPrefixIndex[p3] { candidateArtistIndices.formUnion(hits) }
        }

        var topArtistNodes: [SearchTreeArtistNode] = []
        var seenArtistIDs = Set<String>()

        for idx in candidateArtistIndices {
            guard idx < effectiveArtists.count else { continue }
            let artist = effectiveArtists[idx]
            let normName = artist.normalizedName
            var score = 0

            if normName == cleanQuery {
                score = 1_000_000
            } else if normName == queryWithThe || "the " + normName == cleanQuery {
                score = 950_000
            } else if normName.hasPrefix(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normName.count, 1))
                score = 750_000 + Int(ratio * 150_000)
            } else if normName.contains(spaceQuery) {
                score = 600_000
            }

            if score > 0 && seenArtistIDs.insert(artist.id).inserted {
                var albumNodes: [SearchTreeAlbumNode] = []
                for album in artist.albums.prefix(6) {
                    var trackNodes: [SearchTreeTrackNode] = []
                    for track in album.tracks {
                        let tScore = matchedTrackScores[track.id] ?? 0
                        trackNodes.append(SearchTreeTrackNode(
                            id: "tree_track_\(artist.id)_\(album.id)_\(track.id.uuidString)",
                            track: track,
                            isDirectlyMatched: tScore > 0,
                            relevanceScore: tScore
                        ))
                    }
                    albumNodes.append(SearchTreeAlbumNode(
                        id: "tree_album_\(artist.id)_\(album.id)",
                        album: album,
                        tracks: trackNodes,
                        isDirectlyMatched: (matchedAlbumScores[album.id] ?? 0) > 0,
                        relevanceScore: max(matchedAlbumScores[album.id] ?? 0, score),
                        category: album.isSingle ? .singles : .albums
                    ))
                }

                topArtistNodes.append(SearchTreeArtistNode(
                    id: "tree_artist_\(artist.id)",
                    artist: artist,
                    albums: albumNodes,
                    isDirectlyMatched: true,
                    relevanceScore: score
                ))
            }
        }

        // Include any direct matched albums not yet represented in topArtistNodes
        var topIncludedAlbumIDs = Set<String>()
        for artNode in topArtistNodes {
            for albNode in artNode.albums {
                topIncludedAlbumIDs.insert(albNode.album.id)
            }
        }

        for (album, primaryArtist) in directMatchedAlbums {
            if !topIncludedAlbumIDs.contains(album.id) {
                let artistName = !primaryArtist.name.isEmpty ? primaryArtist.name : (!album.artist.isEmpty ? album.artist : "Various Artists")
                let syntheticArtist = Artist(name: artistName, albums: [album])
                let artistNodeID = "tree_artist_\(syntheticArtist.id)"
                if seenArtistIDs.insert(syntheticArtist.id).inserted {
                    var trackNodes: [SearchTreeTrackNode] = []
                    for track in album.tracks {
                        let tScore = matchedTrackScores[track.id] ?? 0
                        trackNodes.append(SearchTreeTrackNode(
                            id: "tree_track_\(syntheticArtist.id)_\(album.id)_\(track.id.uuidString)",
                            track: track,
                            isDirectlyMatched: tScore > 0,
                            relevanceScore: tScore
                        ))
                    }
                    let albScore = matchedAlbumScores[album.id] ?? 75_000
                    let albumNode = SearchTreeAlbumNode(
                        id: "tree_album_\(syntheticArtist.id)_\(album.id)",
                        album: album,
                        tracks: trackNodes,
                        isDirectlyMatched: true,
                        relevanceScore: albScore,
                        category: album.isSingle ? .singles : .albums
                    )
                    topArtistNodes.append(SearchTreeArtistNode(
                        id: artistNodeID,
                        artist: syntheticArtist,
                        albums: [albumNode],
                        isDirectlyMatched: false,
                        relevanceScore: albScore
                    ))
                    topIncludedAlbumIDs.insert(album.id)
                }
            }
        }

        topArtistNodes.sort { $0.relevanceScore > $1.relevanceScore }
        if topArtistNodes.count > maxArtistResults {
            topArtistNodes = Array(topArtistNodes.prefix(maxArtistResults))
        }

        return GlobalSearchResults(
            artistTreeNodes: topArtistNodes,
            playlists: [],
            directMatchedAlbums: directMatchedAlbums,
            directMatchedTracks: directMatchedTracks
        )
    }

    // MARK: - Phase 2: Full Deep Search Hierarchy

    private func evaluateFullSearch(
        cleanQuery: String,
        effectiveTracks: [Track],
        effectiveAlbums: [Album],
        effectiveArtists: [Artist],
        effectivePlaylists: [Playlist],
        effectiveJoinedArtists: [String],
        maxTrackResults: Int,
        maxAlbumResults: Int,
        maxArtistResults: Int
    ) -> GlobalSearchResults {
        let queryCount = cleanQuery.count
        let queryWithThe = "the " + cleanQuery
        let spaceQuery = " " + cleanQuery
        let queryTokens = cleanQuery.contains(" ") ? cleanQuery.split(separator: " ", omittingEmptySubsequences: true) : []

        // MARK: 1. Candidate Track Selection & Scoring via Index
        var candidateTrackIndices: Set<Int> = []
        let p2 = String(cleanQuery.prefix(2))
        if let p2Hits = trackPrefixIndex[p2] {
            candidateTrackIndices.formUnion(p2Hits)
        }
        if cleanQuery.count >= 3 {
            let p3 = String(cleanQuery.prefix(3))
            if let p3Hits = trackPrefixIndex[p3] {
                candidateTrackIndices.formUnion(p3Hits)
            }
        }
        for qToken in queryTokens {
            let qStr = String(qToken)
            if qStr.count >= 2 {
                let qp2 = String(qStr.prefix(2))
                if let hits = trackPrefixIndex[qp2] {
                    candidateTrackIndices.formUnion(hits)
                }
            }
        }

        var matchedTrackScores = [UUID: Int]()
        matchedTrackScores.reserveCapacity(min(candidateTrackIndices.count, 256))
        var directMatchedTracks: [SearchTreeTrackNode] = []
        directMatchedTracks.reserveCapacity(min(candidateTrackIndices.count, 128))

        for idx in candidateTrackIndices {
            guard idx < effectiveTracks.count else { continue }
            let track = effectiveTracks[idx]
            let normTitle = track.normalizedTitle
            var trackScore = 0

            if normTitle == cleanQuery {
                trackScore = 10_000
            } else if normTitle == queryWithThe || "the " + normTitle == cleanQuery {
                trackScore = 9_500
            } else if normTitle.hasPrefix(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                trackScore = 7_500 + Int(ratio * 1_500)
            } else if normTitle.contains(spaceQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                trackScore = 6_000 + Int(ratio * 1_000)
            } else if normTitle.contains(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                trackScore = 4_500 + Int(ratio * 1_000)
            } else if !queryTokens.isEmpty && queryTokens.allSatisfy({ normTitle.contains($0) }) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                trackScore = 3_500 + Int(ratio * 1_000)
            } else if queryCount >= 2 && normTitle.count >= queryCount {
                let titleFuzzy = FuzzyMatcher.evaluateScore(cleanText: normTitle, cleanQuery: cleanQuery)
                if titleFuzzy >= 700 {
                    trackScore = 2_000 + titleFuzzy * 2
                }
            }

            if trackScore > 0 {
                matchedTrackScores[track.id] = trackScore
                directMatchedTracks.append(SearchTreeTrackNode(
                    id: "direct_track_\(track.id.uuidString)",
                    track: track,
                    isDirectlyMatched: true,
                    relevanceScore: trackScore
                ))
            }
        }
        directMatchedTracks.sort { $0.relevanceScore > $1.relevanceScore }
        if directMatchedTracks.count > maxTrackResults {
            directMatchedTracks = Array(directMatchedTracks.prefix(maxTrackResults))
        }

        // MARK: 2. Candidate Album Selection & Scoring via Index
        var candidateAlbumIndices: Set<Int> = []
        if let hits = albumPrefixIndex[p2] { candidateAlbumIndices.formUnion(hits) }
        if cleanQuery.count >= 3 {
            let p3 = String(cleanQuery.prefix(3))
            if let hits = albumPrefixIndex[p3] { candidateAlbumIndices.formUnion(hits) }
        }
        for qToken in queryTokens {
            let qStr = String(qToken)
            if qStr.count >= 2 {
                let qp2 = String(qStr.prefix(2))
                if let hits = albumPrefixIndex[qp2] { candidateAlbumIndices.formUnion(hits) }
            }
        }

        var matchedAlbumScores = [String: Int]()
        matchedAlbumScores.reserveCapacity(min(candidateAlbumIndices.count, 128))

        for idx in candidateAlbumIndices {
            guard idx < effectiveAlbums.count else { continue }
            let album = effectiveAlbums[idx]
            let normTitle = album.normalizedTitle
            var albScore = 0

            if normTitle == cleanQuery {
                albScore = 100_000
            } else if normTitle == queryWithThe || "the " + normTitle == cleanQuery {
                albScore = 95_000
            } else if normTitle.hasPrefix(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                albScore = 75_000 + Int(ratio * 15_000)
            } else if normTitle.contains(spaceQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                albScore = 60_000 + Int(ratio * 10_000)
            } else if normTitle.contains(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                albScore = 45_000 + Int(ratio * 10_000)
            } else if !queryTokens.isEmpty && queryTokens.allSatisfy({ normTitle.contains($0) }) {
                let ratio = Double(queryCount) / Double(max(normTitle.count, 1))
                albScore = 35_000 + Int(ratio * 10_000)
            } else if queryCount >= 2 && normTitle.count >= queryCount {
                let titleFuzzy = FuzzyMatcher.evaluateScore(cleanText: normTitle, cleanQuery: cleanQuery)
                if titleFuzzy >= 700 {
                    albScore = 20_000 + titleFuzzy * 20
                }
            }

            if albScore > 0 {
                matchedAlbumScores[album.id] = albScore
            }
        }

        // MARK: 3. Candidate Artist Selection & Scoring via Index
        var candidateArtistIndices: Set<Int> = []
        if let hits = artistPrefixIndex[p2] { candidateArtistIndices.formUnion(hits) }
        if cleanQuery.count >= 3 {
            let p3 = String(cleanQuery.prefix(3))
            if let hits = artistPrefixIndex[p3] { candidateArtistIndices.formUnion(hits) }
        }
        for qToken in queryTokens {
            let qStr = String(qToken)
            if qStr.count >= 2 {
                let qp2 = String(qStr.prefix(2))
                if let hits = artistPrefixIndex[qp2] { candidateArtistIndices.formUnion(hits) }
            }
        }

        var matchedArtistScores = [String: Int]()
        matchedArtistScores.reserveCapacity(min(candidateArtistIndices.count, 64))

        for idx in candidateArtistIndices {
            guard idx < effectiveArtists.count else { continue }
            let artist = effectiveArtists[idx]
            let aKey = ArtistParser.canonicalArtistKey(artist.name)
            let normName = artist.normalizedName
            var aScore = 0

            if normName == cleanQuery {
                aScore = 1_000_000
            } else if normName == queryWithThe || "the " + normName == cleanQuery {
                aScore = 950_000
            } else if normName.hasPrefix(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normName.count, 1))
                aScore = 750_000 + Int(ratio * 150_000)
            } else if normName.contains(spaceQuery) {
                let ratio = Double(queryCount) / Double(max(normName.count, 1))
                aScore = 600_000 + Int(ratio * 100_000)
            } else if normName.contains(cleanQuery) {
                let ratio = Double(queryCount) / Double(max(normName.count, 1))
                aScore = 450_000 + Int(ratio * 100_000)
            } else if queryCount >= 2 && normName.count >= queryCount {
                let fuzzy = FuzzyMatcher.evaluateScore(cleanText: normName, cleanQuery: cleanQuery)
                if fuzzy >= 700 {
                    aScore = 200_000 + fuzzy * 200
                }
            }

            if aScore > 0 {
                matchedArtistScores[aKey] = aScore
            }
        }

        // MARK: 4. Playlist Scoring
        let scoredPlaylists: [(Playlist, Int)] = effectivePlaylists.compactMap { playlist in
            let nameScore = FuzzyMatcher.evaluateScore(cleanText: playlist.normalizedName, cleanQuery: cleanQuery)
            let tokenScore = FuzzyMatcher.evaluateScore(cleanText: playlist.searchTokens, cleanQuery: cleanQuery)
            let maxScore = max(nameScore * 2, tokenScore)
            return maxScore > 0 ? (playlist, maxScore) : nil
        }
        var seenPlaylistIDs = Set<UUID>()
        var matchedPlaylists: [Playlist] = []
        for (playlist, _) in scoredPlaylists.sorted(by: { $0.1 > $1.1 }) {
            if seenPlaylistIDs.insert(playlist.id).inserted {
                matchedPlaylists.append(playlist)
            }
        }

        // MARK: 5. Build Direct Matched Albums
        var directMatchedAlbums: [(album: Album, artist: Artist)] = []
        var seenDirectAlbumIDs = Set<String>()

        let scoredAlbums = effectiveAlbums.compactMap { album -> (Album, Int)? in
            let directScore = matchedAlbumScores[album.id] ?? 0
            let trackScores = album.tracks.compactMap { matchedTrackScores[$0.id] }
            let maxTrackScore = trackScores.max() ?? 0
            let bestScore = max(directScore, maxTrackScore)
            return bestScore > 0 ? (album, bestScore) : nil
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let yL = lhs.0.resolvedYear ?? lhs.0.year ?? 0
            let yR = rhs.0.resolvedYear ?? rhs.0.year ?? 0
            if yL != yR { return yL > yR }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }

        for (album, _) in scoredAlbums {
            if seenDirectAlbumIDs.insert(album.id).inserted {
                let canonicalArtistKey = ArtistParser.canonicalArtistKey(album.artist)
                let primaryArtist = artistByKey[canonicalArtistKey] ?? artistByKey[album.artist.lowercased()] ?? Artist(name: album.artist, albums: [album])
                directMatchedAlbums.append((album, primaryArtist))
            }
        }
        if directMatchedAlbums.count > maxAlbumResults {
            directMatchedAlbums = Array(directMatchedAlbums.prefix(maxAlbumResults))
        }

        // MARK: 6. Gather Relevant Artist Keys
        var relevantArtistKeys = Set<String>()
        for (aKey, _) in matchedArtistScores {
            relevantArtistKeys.insert(aKey)
        }
        for album in effectiveAlbums where (matchedAlbumScores[album.id] ?? 0) > 0 {
            let k = ArtistParser.canonicalArtistKey(album.artist)
            if !k.isEmpty { relevantArtistKeys.insert(k) }
        }
        for track in effectiveTracks where (matchedTrackScores[track.id] ?? 0) > 0 {
            let k1 = ArtistParser.canonicalArtistKey(track.artist)
            if !k1.isEmpty { relevantArtistKeys.insert(k1) }
            if let albumArtist = track.albumArtist, !albumArtist.isEmpty {
                let k2 = ArtistParser.canonicalArtistKey(albumArtist)
                if !k2.isEmpty { relevantArtistKeys.insert(k2) }
            }
        }

        // MARK: 7. Assemble Hierarchical Tree in a Single Pass
        var artistTreeNodes: [SearchTreeArtistNode] = []
        var seenArtistNodeIDs = Set<String>()

        for aKey in relevantArtistKeys {
            guard let artistObj = artistByKey[aKey] ?? effectiveArtists.first(where: { ArtistParser.canonicalArtistKey($0.name) == aKey }) else { continue }
            let artistNodeID = "tree_artist_\(artistObj.id)"
            guard seenArtistNodeIDs.insert(artistNodeID).inserted else { continue }

            let artistScore = matchedArtistScores[aKey] ?? 0
            let isArtistDirectlyMatched = artistScore > 0

            var candidateAlbums = artistObj.albums
            if !isArtistDirectlyMatched {
                candidateAlbums = candidateAlbums.filter { album in
                    let isAlbMatched = (matchedAlbumScores[album.id] ?? 0) > 0
                    let hasMatchedTrack = album.tracks.contains { (matchedTrackScores[$0.id] ?? 0) > 0 }
                    return isAlbMatched || hasMatchedTrack
                }
            }

            guard !candidateAlbums.isEmpty || isArtistDirectlyMatched else { continue }

            // Single-pass discography categorization
            var ownLeadStudio: [Album] = []
            var ownLeadSingles: [Album] = []
            var ownLeadAlternates: [Album] = []
            var featuredAlbums: [Album] = []
            ownLeadStudio.reserveCapacity(candidateAlbums.count)

            for album in candidateAlbums {
                if album.isLeadOrCollaborativeAlbum(for: artistObj.name, joinedArtists: effectiveJoinedArtists) {
                    if album.isStudioAlbum {
                        ownLeadStudio.append(album)
                    } else if album.isSingle {
                        ownLeadSingles.append(album)
                    } else if album.isRemix || album.isLive {
                        ownLeadAlternates.append(album)
                    } else {
                        ownLeadStudio.append(album)
                    }
                } else if album.isFeaturedAlbum(for: artistObj.name, joinedArtists: effectiveJoinedArtists) {
                    featuredAlbums.append(album)
                }
            }

            var seenAlbumNodeIDs = Set<String>()
            var bestTrackScoreForArtist = 0
            var bestAlbumScoreForArtist = 0

            func buildSectionNodes(for sectionAlbums: [Album], category: DiscographyCategory) -> [SearchTreeAlbumNode] {
                guard !sectionAlbums.isEmpty else { return [] }
                var nodes: [SearchTreeAlbumNode] = []
                nodes.reserveCapacity(sectionAlbums.count)

                for album in sectionAlbums {
                    let albumNodeID = "tree_album_\(artistObj.id)_\(album.id)"
                    guard seenAlbumNodeIDs.insert(albumNodeID).inserted else { continue }

                    let albScore = matchedAlbumScores[album.id] ?? 0
                    let isAlbumDirectlyMatched = albScore > 0
                    if isAlbumDirectlyMatched {
                        bestAlbumScoreForArtist = max(bestAlbumScoreForArtist, albScore)
                    }

                    let sortedAlbumTracks = album.tracks.sorted {
                        let d0 = $0.discNumber ?? 1
                        let d1 = $1.discNumber ?? 1
                        if d0 != d1 { return d0 < d1 }
                        let t0 = $0.trackNumber ?? 0
                        let t1 = $1.trackNumber ?? 0
                        if t0 > 0 && t1 > 0 && t0 != t1 { return t0 < t1 }
                        if t0 > 0 && t1 == 0 { return true }
                        if t0 == 0 && t1 > 0 { return false }
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }

                    var trackNodes: [SearchTreeTrackNode] = []
                    trackNodes.reserveCapacity(sortedAlbumTracks.count)

                    for track in sortedAlbumTracks {
                        let trackNodeID = "tree_track_\(artistObj.id)_\(album.id)_\(track.id.uuidString)"
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
                    let aHasMatch = nodeA.isDirectlyMatched || nodeA.tracks.contains(where: { $0.isDirectlyMatched })
                    let bHasMatch = nodeB.isDirectlyMatched || nodeB.tracks.contains(where: { $0.isDirectlyMatched })
                    if aHasMatch != bHasMatch {
                        return aHasMatch && !bHasMatch
                    }
                    if nodeA.relevanceScore != nodeB.relevanceScore {
                        return nodeA.relevanceScore > nodeB.relevanceScore
                    }
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
            let featuredNodes = buildSectionNodes(for: featuredAlbums, category: .featuredOn)

            let allAlbumNodes = studioNodes + singlesNodes + alternatesNodes + featuredNodes
            let totalRelevance = max(artistScore, bestTrackScoreForArtist, bestAlbumScoreForArtist)

            artistTreeNodes.append(SearchTreeArtistNode(
                id: artistNodeID,
                artist: artistObj,
                albums: allAlbumNodes,
                isDirectlyMatched: isArtistDirectlyMatched,
                relevanceScore: totalRelevance
            ))
        }

        // Include any direct matched albums not yet represented in artistTreeNodes
        var fullIncludedAlbumIDs = Set<String>()
        for artNode in artistTreeNodes {
            for albNode in artNode.albums {
                fullIncludedAlbumIDs.insert(albNode.album.id)
            }
        }

        for (album, primaryArtist) in directMatchedAlbums {
            if !fullIncludedAlbumIDs.contains(album.id) {
                let albScore = matchedAlbumScores[album.id] ?? 0
                let artistName = !primaryArtist.name.isEmpty ? primaryArtist.name : (!album.artist.isEmpty ? album.artist : "Various Artists")
                let syntheticArtist = Artist(name: artistName, albums: [album])
                let artistNodeID = "tree_artist_\(syntheticArtist.id)"
                if seenArtistNodeIDs.insert(artistNodeID).inserted {
                    var trackNodes: [SearchTreeTrackNode] = []
                    for track in album.tracks {
                        let tScore = matchedTrackScores[track.id] ?? 0
                        trackNodes.append(SearchTreeTrackNode(
                            id: "tree_track_\(syntheticArtist.id)_\(album.id)_\(track.id.uuidString)",
                            track: track,
                            isDirectlyMatched: tScore > 0,
                            relevanceScore: tScore
                        ))
                    }
                    let albumNode = SearchTreeAlbumNode(
                        id: "tree_album_\(syntheticArtist.id)_\(album.id)",
                        album: album,
                        tracks: trackNodes,
                        isDirectlyMatched: true,
                        relevanceScore: albScore > 0 ? albScore : 80_000,
                        category: album.isSingle ? .singles : .albums
                    )
                    artistTreeNodes.append(SearchTreeArtistNode(
                        id: artistNodeID,
                        artist: syntheticArtist,
                        albums: [albumNode],
                        isDirectlyMatched: false,
                        relevanceScore: albScore > 0 ? albScore : 80_000
                    ))
                    fullIncludedAlbumIDs.insert(album.id)
                }
            }
        }

        artistTreeNodes.sort {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.artist.name.localizedCaseInsensitiveCompare($1.artist.name) == .orderedAscending
        }
        if artistTreeNodes.count > maxArtistResults {
            artistTreeNodes = Array(artistTreeNodes.prefix(maxArtistResults))
        }

        return GlobalSearchResults(
            artistTreeNodes: artistTreeNodes,
            playlists: matchedPlaylists,
            directMatchedAlbums: directMatchedAlbums,
            directMatchedTracks: directMatchedTracks
        )
    }
}
