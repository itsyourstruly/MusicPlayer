import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Discography Category

nonisolated public enum DiscographyCategory: String, Sendable, Equatable {
    case albums = "ALBUMS"
    case singles = "SINGLES"
    case alternates = "ALTERNATES"
    case featuredOn = "FEATURED ON"
}

// MARK: - Filter Enums & Tree Data Structures

nonisolated public enum SearchCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case artists = "ARTISTS"
    case albums = "ALBUMS"
    case tracks = "TRACKS"

    public var id: String { rawValue }
}

/// Auto-expand decision from the token engine (plan §3.5). Nil means the legacy rule (first artist, first matched album).
nonisolated public struct SearchExpansionHint: Sendable, Equatable {
    /// Top-hit artist (placed first in `artistTreeNodes`).
    public let artistID: String
    /// Album (by `Album.id`) to expand inside that artist, if any: the D3 topmost album holding the match.
    public let albumID: String?
    /// Top hit is fuzzy-only and leads the runner-up by less than 0.10: expand nothing (TRACKS keeps its first 3).
    public let suppress: Bool
    /// Matched track inside `albumID` that gets the top-hit accent (track top hits only, §6b).
    public let trackID: UUID?
    /// D12: top hit is a song or album (matched-only results), not an exact artist name.
    public let isSongOrAlbumHit: Bool

    public init(artistID: String, albumID: String?, suppress: Bool, trackID: UUID? = nil, isSongOrAlbumHit: Bool = false) {
        self.artistID = artistID
        self.albumID = albumID
        self.suppress = suppress
        self.trackID = trackID
        self.isSongOrAlbumHit = isSongOrAlbumHit
    }
}

nonisolated public struct GlobalSearchResults: Sendable, Equatable {
    public var artistTreeNodes: [SearchTreeArtistNode]
    public var playlists: [Playlist]
    public var directMatchedAlbums: [(album: Album, artist: Artist)]
    public var directMatchedTracks: [SearchTreeTrackNode]

    public let totalArtistsCount: Int
    public let totalAlbumsCount: Int
    public let totalTracksCount: Int

    public let matchedArtists: [SearchTreeArtistNode]
    public let matchedAlbums: [(album: Album, artist: Artist)]
    public let matchedTracks: [SearchTreeTrackNode]

    /// Artist -> album grouping of matched tracks for the TRACKS category, built off-main by SearchEngine.
    public let trackCategoryNodes: [SearchTreeArtistNode]
    /// Matched tracks not already shown under the top artist node (precomputed, not derived in view body).
    public let unrepresentedTracks: [SearchTreeTrackNode]
    /// Normalized query that produced these results (part of equality so rows refresh across queries).
    public let query: String
    /// Token-engine auto-expand hint (nil for the legacy scanner).
    public let expansionHint: SearchExpansionHint?

    public static let empty = GlobalSearchResults(
        artistTreeNodes: [],
        playlists: [],
        directMatchedAlbums: [],
        directMatchedTracks: []
    )

    public init(
        artistTreeNodes: [SearchTreeArtistNode],
        playlists: [Playlist],
        directMatchedAlbums: [(album: Album, artist: Artist)],
        directMatchedTracks: [SearchTreeTrackNode],
        trackCategoryNodes: [SearchTreeArtistNode] = [],
        query: String = "",
        expansionHint: SearchExpansionHint? = nil,
        unresolvedTracks: [SearchTreeTrackNode] = []
    ) {
        self.expansionHint = expansionHint
        self.trackCategoryNodes = trackCategoryNodes
        self.query = query
        self.artistTreeNodes = artistTreeNodes
        self.playlists = playlists
        self.directMatchedAlbums = directMatchedAlbums
        self.directMatchedTracks = directMatchedTracks

        self.totalArtistsCount = artistTreeNodes.count

        var albumSet = Set<String>()
        for artist in artistTreeNodes {
            for album in artist.albums {
                albumSet.insert(album.album.id)
            }
        }
        for (alb, _) in directMatchedAlbums {
            albumSet.insert(alb.id)
        }
        self.totalAlbumsCount = albumSet.count

        var trackSet = Set<UUID>()
        for artist in artistTreeNodes {
            for album in artist.albums {
                for track in album.tracks {
                    trackSet.insert(track.track.id)
                }
            }
        }
        for track in directMatchedTracks {
            trackSet.insert(track.track.id)
        }
        self.totalTracksCount = trackSet.count

        self.matchedArtists = artistTreeNodes.filter { $0.isDirectlyMatched }
        self.matchedAlbums = directMatchedAlbums
        self.matchedTracks = directMatchedTracks

        // D13(b): only songs that could not be resolved to a library artist/album (computed by the engine).
        self.unrepresentedTracks = unresolvedTracks
    }

    public var hasResults: Bool {
        !artistTreeNodes.isEmpty || !playlists.isEmpty || !directMatchedAlbums.isEmpty || !directMatchedTracks.isEmpty
    }

    public var isEmpty: Bool {
        !hasResults
    }

    public static func == (lhs: GlobalSearchResults, rhs: GlobalSearchResults) -> Bool {
        lhs.query == rhs.query &&
        lhs.totalArtistsCount == rhs.totalArtistsCount &&
        lhs.totalAlbumsCount == rhs.totalAlbumsCount &&
        lhs.totalTracksCount == rhs.totalTracksCount &&
        lhs.playlists.count == rhs.playlists.count &&
        lhs.directMatchedAlbums.count == rhs.directMatchedAlbums.count &&
        lhs.directMatchedTracks.count == rhs.directMatchedTracks.count &&
        lhs.artistTreeNodes == rhs.artistTreeNodes &&
        lhs.directMatchedTracks == rhs.directMatchedTracks &&
        lhs.directMatchedAlbums.map { $0.album.id } == rhs.directMatchedAlbums.map { $0.album.id } &&
        lhs.playlists.map { $0.id } == rhs.playlists.map { $0.id } &&
        lhs.playlists.map { $0.name } == rhs.playlists.map { $0.name } &&
        lhs.trackCategoryNodes == rhs.trackCategoryNodes &&
        lhs.expansionHint == rhs.expansionHint
    }
}

nonisolated public struct SearchTreeArtistNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let artist: Artist
    public var albums: [SearchTreeAlbumNode]
    public var isDirectlyMatched: Bool
    public var relevanceScore: Int
    public let studioAlbumNodes: [SearchTreeAlbumNode]
    public let singlesNodes: [SearchTreeAlbumNode]
    public let alternatesNodes: [SearchTreeAlbumNode]
    public let featuredAlbumNodes: [SearchTreeAlbumNode]

    public init(
        id: String,
        artist: Artist,
        albums: [SearchTreeAlbumNode],
        isDirectlyMatched: Bool,
        relevanceScore: Int
    ) {
        self.id = id
        self.artist = artist
        self.albums = albums
        self.isDirectlyMatched = isDirectlyMatched
        self.relevanceScore = relevanceScore
        self.studioAlbumNodes = albums.filter { $0.category == .albums }
        self.singlesNodes = albums.filter { $0.category == .singles }
        self.alternatesNodes = albums.filter { $0.category == .alternates }
        self.featuredAlbumNodes = albums.filter { $0.category == .featuredOn }
    }

    public static func == (lhs: SearchTreeArtistNode, rhs: SearchTreeArtistNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.artist.id == rhs.artist.id &&
        lhs.artist.name == rhs.artist.name &&
        lhs.artist.mostRecentArtworkKey == rhs.artist.mostRecentArtworkKey &&
        lhs.isDirectlyMatched == rhs.isDirectlyMatched &&
        lhs.relevanceScore == rhs.relevanceScore &&
        lhs.albums == rhs.albums
    }
}

nonisolated public struct SearchTreeAlbumNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let album: Album
    public var tracks: [SearchTreeTrackNode]
    public var isDirectlyMatched: Bool
    public var relevanceScore: Int
    public var category: DiscographyCategory

    public static func == (lhs: SearchTreeAlbumNode, rhs: SearchTreeAlbumNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.album.id == rhs.album.id &&
        lhs.album.title == rhs.album.title &&
        lhs.album.artworkKey == rhs.album.artworkKey &&
        lhs.album.tracks.count == rhs.album.tracks.count &&
        lhs.isDirectlyMatched == rhs.isDirectlyMatched &&
        lhs.relevanceScore == rhs.relevanceScore &&
        lhs.category == rhs.category &&
        lhs.tracks == rhs.tracks
    }
}

nonisolated public struct SearchTreeTrackNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let track: Track
    public var isDirectlyMatched: Bool
    public var relevanceScore: Int

    public static func == (lhs: SearchTreeTrackNode, rhs: SearchTreeTrackNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.track.id == rhs.track.id &&
        lhs.track.title == rhs.track.title &&
        lhs.track.duration == rhs.track.duration &&
        lhs.track.trackNumber == rhs.track.trackNumber &&
        lhs.isDirectlyMatched == rhs.isDirectlyMatched &&
        lhs.relevanceScore == rhs.relevanceScore
    }
}

// MARK: - Flat Search Result Rows

/// One flat row of the library search results. The whole result tree (artist -> category -> album -> track,
/// filtered lists, show-more, playlists) is flattened into a single array built off the main actor, so the
/// results render with ONE ForEach inside ONE lazy container (no nested lazy stacks). Tree connector lines
/// and the original stack spacing are reproduced per row via the gap/line fields.
nonisolated public enum SearchResultRowKind: Sendable {
    case controls(artists: Int, albums: Int, tracks: Int, filter: SearchCategoryFilter?)
    case artistHeader(SearchTreeArtistNode)
    case categoryHeader(String)
    case albumHeader(SearchTreeAlbumNode, artistID: String)
    case albumTrack(SearchTreeTrackNode, albumTracks: [Track], index: Int)
    case looseTracksHeader(count: Int)
    case looseTrack(SearchTreeTrackNode, index: Int)
    case loadMore
    case filteredArtist(SearchTreeArtistNode)
    case filteredAlbum(album: Album, artist: Artist)
    case playlistsHeader(count: Int, isCollapsed: Bool)
    case playlistsGrid([Playlist])
}

nonisolated public struct SearchResultRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: SearchResultRowKind
    /// Space above the row that lies outside every connector line (stack spacing / outer padding).
    public var outerGap: CGFloat = 0
    /// Space above the row covered only by the artist connector line.
    public var artistLineGap: CGFloat = 0
    /// Space above the row covered by both the artist and album connector lines.
    public var albumLineGap: CGFloat = 0
    public var artistLine: Bool = false
    public var albumLine: Bool = false
    /// TRACKS category rows resolve artist/album against the library on tap.
    public var resolvesFromLibrary: Bool = false

    public static func == (lhs: SearchResultRow, rhs: SearchResultRow) -> Bool {
        guard lhs.id == rhs.id,
              lhs.outerGap == rhs.outerGap,
              lhs.artistLineGap == rhs.artistLineGap,
              lhs.albumLineGap == rhs.albumLineGap,
              lhs.artistLine == rhs.artistLine,
              lhs.albumLine == rhs.albumLine,
              lhs.resolvesFromLibrary == rhs.resolvesFromLibrary else { return false }
        switch (lhs.kind, rhs.kind) {
        case let (.controls(a1, b1, c1, f1), .controls(a2, b2, c2, f2)):
            return a1 == a2 && b1 == b2 && c1 == c2 && f1 == f2
        case let (.artistHeader(n1), .artistHeader(n2)):
            return n1 == n2
        case let (.categoryHeader(t1), .categoryHeader(t2)):
            return t1 == t2
        case let (.albumHeader(n1, a1), .albumHeader(n2, a2)):
            return a1 == a2 && n1 == n2
        case let (.albumTrack(n1, q1, i1), .albumTrack(n2, q2, i2)):
            return i1 == i2 && q1.count == q2.count && n1 == n2
        case let (.looseTracksHeader(c1), .looseTracksHeader(c2)):
            return c1 == c2
        case let (.looseTrack(n1, i1), .looseTrack(n2, i2)):
            return i1 == i2 && n1 == n2
        case (.loadMore, .loadMore):
            return true
        case let (.filteredArtist(n1), .filteredArtist(n2)):
            return n1 == n2
        case let (.filteredAlbum(al1, ar1), .filteredAlbum(al2, ar2)):
            return al1.id == al2.id && al1.title == al2.title && al1.artist == al2.artist &&
                al1.artworkKey == al2.artworkKey && al1.formattedYear == al2.formattedYear && ar1.name == ar2.name
        case let (.playlistsHeader(c1, x1), .playlistsHeader(c2, x2)):
            return c1 == c2 && x1 == x2
        case let (.playlistsGrid(p1), .playlistsGrid(p2)):
            return p1.count == p2.count && zip(p1, p2).allSatisfy {
                $0.id == $1.id && $0.name == $1.name && $0.isPinned == $1.isPinned && $0.trackIDs.count == $1.trackIDs.count
            }
        default:
            return false
        }
    }
}

nonisolated enum SearchResultRowBuilder {
    struct Input: Sendable {
        var results: GlobalSearchResults
        var filter: SearchCategoryFilter?
        var expandedArtistIDs: Set<String>
        var expandedAlbumIDs: Set<String>
        var trackExpandedArtistIDs: Set<String>
        var trackExpandedAlbumIDs: Set<String>
        var isPlaylistsCollapsed: Bool
        var canLoadMore: Bool
    }

    /// Number of artist matches expanded by default in the TRACKS category.
    static let defaultTrackCategoryExpansion = 3

    static func build(_ input: Input) -> [SearchResultRow] {
        var rows: [SearchResultRow] = []
        var usedIDs = Set<String>()
        func add(_ row: SearchResultRow) {
            if usedIDs.insert(row.id).inserted {
                rows.append(row)
            } else {
                var n = 2
                while !usedIDs.insert("\(row.id)#\(n)").inserted { n += 1 }
                var copy = SearchResultRow(id: "\(row.id)#\(n)", kind: row.kind)
                copy.outerGap = row.outerGap
                copy.artistLineGap = row.artistLineGap
                copy.albumLineGap = row.albumLineGap
                copy.artistLine = row.artistLine
                copy.albumLine = row.albumLine
                copy.resolvesFromLibrary = row.resolvesFromLibrary
                rows.append(copy)
            }
        }

        let results = input.results
        add(SearchResultRow(
            id: "controls",
            kind: .controls(
                artists: results.totalArtistsCount,
                albums: results.totalAlbumsCount,
                tracks: results.totalTracksCount,
                filter: input.filter
            )
        ))

        /// D12: the top-match album for the top-hit artist in a song/album search; nil for artist searches.
        func topMatchAlbumID(_ node: SearchTreeArtistNode) -> String? {
            guard let hint = results.expansionHint, hint.isSongOrAlbumHit, !hint.suppress,
                  hint.artistID == node.artist.id, let albumID = hint.albumID else { return nil }
            return node.albums.first { $0.album.id == albumID }?.id
        }

        func appendArtist(_ node: SearchTreeArtistNode, gap: CGFloat, isExpanded: Bool, expandedAlbums: Set<String>, prefix: String, resolves: Bool) {
            var header = SearchResultRow(id: "\(prefix)artist-\(node.id)", kind: .artistHeader(node))
            header.outerGap = gap
            header.resolvesFromLibrary = resolves
            add(header)
            guard isExpanded, !node.albums.isEmpty else { return }

            // D11: headers only when sections are mixed; order via SearchSectionLayout.topMatchSectionFirst.
            let categories = SearchSectionLayout.layout([
                ("ALBUMS", node.studioAlbumNodes),
                ("SINGLES & EPS", node.singlesNodes),
                ("ALTERNATES", node.alternatesNodes),
                ("FEATURED ON", node.featuredAlbumNodes)
            ], topAlbumID: topMatchAlbumID(node), id: { $0.id })
            var isFirstCategory = true
            for (title, albums) in categories {
                var headerless = false
                if let title {
                    var cat = SearchResultRow(id: "\(prefix)cat-\(node.id)-\(title)", kind: .categoryHeader("\(title) (\(albums.count))"))
                    cat.outerGap = isFirstCategory ? 6 : 0
                    cat.artistLineGap = isFirstCategory ? 0 : 14
                    cat.artistLine = true
                    cat.resolvesFromLibrary = resolves
                    add(cat)
                } else {
                    headerless = true
                }
                isFirstCategory = false

                for (albumIndex, albumNode) in albums.enumerated() {
                    var albumRow = SearchResultRow(id: "\(prefix)album-\(node.id)-\(albumNode.id)", kind: .albumHeader(albumNode, artistID: node.id))
                    if headerless && albumIndex == 0 { albumRow.outerGap = 6 }
                    albumRow.artistLineGap = 6
                    albumRow.artistLine = true
                    albumRow.resolvesFromLibrary = resolves
                    add(albumRow)

                    guard expandedAlbums.contains(albumNode.id), !albumNode.tracks.isEmpty else { continue }
                    let albumTracks = albumNode.album.tracks
                    for index in albumNode.tracks.indices {
                        let trackNode = albumNode.tracks[index]
                        // Queue position in the full album (the node may list only the matched tracks, D8).
                        let queueIndex = albumTracks.firstIndex { $0.id == trackNode.track.id } ?? index
                        var trackRow = SearchResultRow(
                            id: "\(prefix)track-\(node.id)-\(albumNode.id)-\(trackNode.id)",
                            kind: .albumTrack(trackNode, albumTracks: albumTracks, index: queueIndex)
                        )
                        trackRow.artistLineGap = index == 0 ? 2 : 0
                        trackRow.albumLineGap = index == 0 ? 0 : 4
                        trackRow.artistLine = true
                        trackRow.albumLine = true
                        trackRow.resolvesFromLibrary = resolves
                        add(trackRow)
                    }
                }
            }
        }

        func appendFilteredAlbums() {
            for index in results.matchedAlbums.indices {
                let pair = results.matchedAlbums[index]
                var row = SearchResultRow(id: "falbum-\(pair.album.id)", kind: .filteredAlbum(album: pair.album, artist: pair.artist))
                row.outerGap = index == 0 ? 16 : 8
                add(row)
            }
        }

        func appendTrackCategory() {
            let nodes = results.trackCategoryNodes
            for index in nodes.indices {
                let node = nodes[index]
                appendArtist(
                    node,
                    gap: index == 0 ? 16 : 14,
                    isExpanded: input.trackExpandedArtistIDs.contains(node.id),
                    expandedAlbums: input.trackExpandedAlbumIDs,
                    prefix: "k-",
                    resolves: true
                )
            }
            if input.canLoadMore {
                var more = SearchResultRow(id: "k-loadmore", kind: .loadMore)
                more.outerGap = nodes.isEmpty ? 16 : 14
                add(more)
            }
        }

        switch input.filter {
        case .artists:
            let list = results.matchedArtists.isEmpty ? results.artistTreeNodes : results.matchedArtists
            for index in list.indices {
                var row = SearchResultRow(id: "fartist-\(list[index].id)", kind: .filteredArtist(list[index]))
                row.outerGap = index == 0 ? 16 : 8
                add(row)
            }
        case .albums:
            appendFilteredAlbums()
        case .tracks:
            appendTrackCategory()
        case nil:
            if !results.artistTreeNodes.isEmpty {
                for node in results.artistTreeNodes {
                    appendArtist(
                        node,
                        gap: 16,
                        isExpanded: input.expandedArtistIDs.contains(node.id),
                        expandedAlbums: input.expandedAlbumIDs,
                        prefix: "",
                        resolves: false
                    )
                }
                let loose = results.unrepresentedTracks
                if !loose.isEmpty {
                    var header = SearchResultRow(id: "loose-header", kind: .looseTracksHeader(count: loose.count))
                    header.outerGap = 16
                    add(header)
                    for index in loose.indices {
                        var row = SearchResultRow(id: "loose-\(loose[index].id)", kind: .looseTrack(loose[index], index: index))
                        row.outerGap = 16
                        add(row)
                    }
                    if input.canLoadMore {
                        var more = SearchResultRow(id: "loose-loadmore", kind: .loadMore)
                        more.outerGap = 16
                        add(more)
                    }
                }
                // Artist rows that show no albums (collapsed headers only) must never hide the album and song
                // matches: list them directly underneath.
                if !results.artistTreeNodes.contains(where: { !$0.albums.isEmpty }) {
                    if !results.directMatchedAlbums.isEmpty {
                        appendFilteredAlbums()
                    }
                    if !results.directMatchedTracks.isEmpty, loose.isEmpty {
                        appendTrackCategory()
                    }
                }
            } else {
                if !results.directMatchedAlbums.isEmpty {
                    appendFilteredAlbums()
                }
                if !results.directMatchedTracks.isEmpty {
                    appendTrackCategory()
                }
            }

            if !results.playlists.isEmpty {
                var header = SearchResultRow(id: "playlists-header", kind: .playlistsHeader(count: results.playlists.count, isCollapsed: input.isPlaylistsCollapsed))
                header.outerGap = 16
                add(header)
                if !input.isPlaylistsCollapsed {
                    var grid = SearchResultRow(id: "playlists-grid", kind: .playlistsGrid(results.playlists))
                    grid.outerGap = 10
                    add(grid)
                }
            }
        }
        return rows
    }
}

// MARK: - Search Section Layout (D11 + D12)

/// D11: section headers in search results appear only when the matched albums span more than one section type.
/// D12: when headers show for a song/album top hit, the section holding the top match moves to the top.
nonisolated enum SearchSectionLayout {
    /// D12 switch. `true` (default) = in a song/album search the section containing the top-match album goes first,
    /// the rest follow in standard order. `false` = always standard order
    /// ALBUMS → SINGLES & EPS → ALTERNATES → FEATURED ON. Exact artist-name searches always use standard order.
    static let topMatchSectionFirst = true

    /// `groups` are in standard section order, each already in ranked order. `topAlbumID` is the top-match album
    /// (pass nil for artist searches). Returns (header title or nil, items); one non-empty section → one headerless group.
    static func layout<T>(_ groups: [(String, [T])], topAlbumID: String?, id: (T) -> String,
                          topMatchFirst: Bool = topMatchSectionFirst) -> [(String?, [T])] {
        var nonEmpty = groups.filter { !$0.1.isEmpty }
        if nonEmpty.count == 1 { return [(nil, nonEmpty[0].1)] }
        if topMatchFirst, let topAlbumID,
           let i = nonEmpty.firstIndex(where: { $0.1.contains { id($0) == topAlbumID } }), i > 0 {
            nonEmpty.insert(nonEmpty.remove(at: i), at: 0)
        }
        return nonEmpty.map { (Optional($0.0), $0.1) }
    }
}

// MARK: - Global Search Model

/// Small dedicated search model: debounces typing, guards against stale queries, pages track results,
/// and publishes results + default expansions + flattened rows in a single assignment per query.
@Observable
@MainActor
final class GlobalSearchModel {
    struct Presentation: Equatable {
        var results: GlobalSearchResults = .empty
        var expandedArtistIDs: Set<String> = []
        var expandedAlbumIDs: Set<String> = []
        var trackExpandedArtistIDs: Set<String> = []
        var trackExpandedAlbumIDs: Set<String> = []
        /// "artistID|albumID" of the album opened automatically for the current top hit (§6b).
        var autoExpandedKey: String? = nil
        var autoExpandedArtistID: String? = nil
        var autoExpandedAlbumID: String? = nil
    }

    /// Main-tree expansion state that `nextExpansion` carries from one result set to the next (§6b).
    nonisolated struct ExpansionState: Equatable, Sendable {
        var expandedArtistIDs: Set<String> = []
        var expandedAlbumIDs: Set<String> = []
        var autoExpandedKey: String? = nil
        var autoExpandedArtistID: String? = nil
        var autoExpandedAlbumID: String? = nil
    }

    /// Albums/artists the user opened or closed by hand (written only by the toggle functions).
    nonisolated struct UserExpansion: Equatable, Sendable {
        var expandedArtistIDs: Set<String> = []
        var expandedAlbumIDs: Set<String> = []
        var collapsedAlbumIDs: Set<String> = []
    }

    /// §6b auto-expand rules (pure, so SearchSelfCheck can test them):
    /// 1. never collapse an album the user opened; 2. change the auto album only when the hint key changes
    /// (same key → nothing changes, so no flicker while typing); 3. never reopen an album the user collapsed;
    /// 4. `suppress` → open nothing and keep the key. Nothing here scrolls (D7).
    nonisolated static func nextExpansion(prev: ExpansionState, hint: SearchExpansionHint?, user: UserExpansion) -> ExpansionState {
        var next = prev
        if let hint, !hint.suppress {
            let key = "\(hint.artistID)|\(hint.albumID ?? "")"
            if key != prev.autoExpandedKey {
                if let old = prev.autoExpandedAlbumID, !user.expandedAlbumIDs.contains(old) {
                    next.expandedAlbumIDs.remove(old)
                }
                if let old = prev.autoExpandedArtistID, old != hint.artistID, !user.expandedArtistIDs.contains(old) {
                    next.expandedArtistIDs.remove(old)
                }
                next.expandedArtistIDs.insert(hint.artistID)
                next.autoExpandedArtistID = hint.artistID
                if let albumID = hint.albumID, !user.collapsedAlbumIDs.contains(albumID) {
                    next.expandedAlbumIDs.insert(albumID)
                    next.autoExpandedAlbumID = albumID
                } else {
                    next.autoExpandedAlbumID = nil
                }
                next.autoExpandedKey = key
            }
        }
        next.expandedAlbumIDs.formUnion(user.expandedAlbumIDs)
        next.expandedArtistIDs.formUnion(user.expandedArtistIDs)
        next.expandedAlbumIDs.subtract(user.collapsedAlbumIDs)
        return next
    }

    static let pageSize = 80
    static let maxTrackLimit = 400
    static let debounce: Duration = .milliseconds(130)
    static let expandAnimation = Animation.spring(response: 0.22, dampingFraction: 0.86)
    static let filterAnimation = Animation.spring(response: 0.22, dampingFraction: 0.85)

    private(set) var presentation = Presentation()
    /// Flattened rows rendered by the results container (built off-main).
    private(set) var rows: [SearchResultRow] = []
    private(set) var activeCategoryFilter: SearchCategoryFilter? = nil
    private(set) var isPlaylistsCollapsed = false
    private(set) var isSearching = false
    private(set) var trackLimit = GlobalSearchModel.pageSize

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var rowsTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var rowsGeneration: UInt64 = 0
    @ObservationIgnored private var currentQuery = ""
    @ObservationIgnored private var userExpansion = UserExpansion()

    var canLoadMore: Bool {
        canLoadMore(for: presentation.results)
    }

    private func canLoadMore(for results: GlobalSearchResults) -> Bool {
        trackLimit < Self.maxTrackLimit && results.directMatchedTracks.count >= trackLimit
    }

    func submit(_ rawQuery: String, debounced: Bool = true) {
        let clean = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            clear()
            return
        }
        if clean != currentQuery {
            trackLimit = Self.pageSize
        }
        currentQuery = clean
        run(query: clean, limit: trackLimit, debounced: debounced, preserveExpansion: false)
    }

    func loadMore() {
        guard canLoadMore, !currentQuery.isEmpty else { return }
        trackLimit = min(trackLimit + Self.pageSize, Self.maxTrackLimit)
        run(query: currentQuery, limit: trackLimit, debounced: false, preserveExpansion: true)
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        if isSearching { isSearching = false }
    }

    func clear() {
        cancel()
        cancelRowBuild()
        currentQuery = ""
        trackLimit = Self.pageSize
        userExpansion = UserExpansion()
        if presentation != Presentation() || !rows.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) {
                presentation = Presentation()
                rows = []
            }
        }
    }

    // MARK: Interaction (expansion, filters) — each change rebuilds rows off-main, then animates them in.

    func toggleArtistExpansion(_ artistID: String) {
        var next = presentation
        if activeCategoryFilter == .tracks {
            if next.trackExpandedArtistIDs.contains(artistID) {
                next.trackExpandedArtistIDs.remove(artistID)
            } else {
                next.trackExpandedArtistIDs.insert(artistID)
                if let node = next.results.trackCategoryNodes.first(where: { $0.id == artistID }) {
                    next.trackExpandedAlbumIDs.formUnion(node.albums.map(\.id))
                }
            }
        } else if next.expandedArtistIDs.contains(artistID) {
            next.expandedArtistIDs.remove(artistID)
            userExpansion.expandedArtistIDs.remove(artistID)
        } else {
            userExpansion.expandedArtistIDs.insert(artistID)
            let results = next.results
            if let index = results.artistTreeNodes.firstIndex(where: { $0.id == artistID }),
               results.artistTreeNodes[index].albums.isEmpty,
               let expanded = SearchEngine.shared.expandArtist(artistID: artistID, query: currentQuery) {
                var updatedNodes = results.artistTreeNodes
                updatedNodes[index] = expanded
                next.results = GlobalSearchResults(
                    artistTreeNodes: updatedNodes,
                    playlists: results.playlists,
                    directMatchedAlbums: results.directMatchedAlbums,
                    directMatchedTracks: results.directMatchedTracks,
                    trackCategoryNodes: results.trackCategoryNodes,
                    query: results.query,
                    expansionHint: results.expansionHint,
                    unresolvedTracks: results.unrepresentedTracks
                )
            }
            next.expandedArtistIDs.insert(artistID)
        }
        presentation = next
        rebuildRows(animation: Self.expandAnimation)
    }

    func toggleAlbumExpansion(_ albumID: String, artistID: String) {
        var next = presentation
        if activeCategoryFilter == .tracks {
            next.trackExpandedArtistIDs.insert(artistID)
            if next.trackExpandedAlbumIDs.contains(albumID) {
                next.trackExpandedAlbumIDs.remove(albumID)
            } else {
                next.trackExpandedAlbumIDs.insert(albumID)
            }
        } else {
            next.expandedArtistIDs.insert(artistID)
            if next.expandedAlbumIDs.contains(albumID) {
                next.expandedAlbumIDs.remove(albumID)
                userExpansion.expandedAlbumIDs.remove(albumID)
                userExpansion.collapsedAlbumIDs.insert(albumID)
            } else {
                next.expandedAlbumIDs.insert(albumID)
                userExpansion.expandedAlbumIDs.insert(albumID)
                userExpansion.collapsedAlbumIDs.remove(albumID)
            }
        }
        presentation = next
        rebuildRows(animation: Self.expandAnimation)
    }

    func collapseAll() {
        userExpansion.collapsedAlbumIDs.formUnion(presentation.expandedAlbumIDs)
        userExpansion.expandedAlbumIDs.removeAll()
        userExpansion.expandedArtistIDs.removeAll()
        presentation.expandedArtistIDs.removeAll()
        presentation.expandedAlbumIDs.removeAll()
        rebuildRows(animation: Self.expandAnimation)
    }

    func toggleCategoryFilter(_ category: SearchCategoryFilter) {
        activeCategoryFilter = (activeCategoryFilter == category) ? nil : category
        rebuildRows(animation: Self.filterAnimation)
    }

    func togglePlaylistsCollapsed() {
        isPlaylistsCollapsed.toggle()
        rebuildRows(animation: Self.filterAnimation)
    }

    // MARK: Row building

    private func rowInput(for presentation: Presentation, canLoadMore: Bool) -> SearchResultRowBuilder.Input {
        SearchResultRowBuilder.Input(
            results: presentation.results,
            filter: activeCategoryFilter,
            expandedArtistIDs: presentation.expandedArtistIDs,
            expandedAlbumIDs: presentation.expandedAlbumIDs,
            trackExpandedArtistIDs: presentation.trackExpandedArtistIDs,
            trackExpandedAlbumIDs: presentation.trackExpandedAlbumIDs,
            isPlaylistsCollapsed: isPlaylistsCollapsed,
            canLoadMore: canLoadMore
        )
    }

    private func cancelRowBuild() {
        rowsTask?.cancel()
        rowsTask = nil
        rowsGeneration &+= 1
    }

    private func rebuildRows(animation: Animation?) {
        cancelRowBuild()
        let token = rowsGeneration
        let input = rowInput(for: presentation, canLoadMore: canLoadMore)
        rowsTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                SearchResultRowBuilder.build(input)
            }.value
            guard let self, !Task.isCancelled, token == self.rowsGeneration else { return }
            if built != self.rows {
                withAnimation(animation) {
                    self.rows = built
                }
            }
            self.rowsTask = nil
        }
    }

    private func run(query: String, limit: Int, debounced: Bool, preserveExpansion: Bool) {
        searchTask?.cancel()
        generation &+= 1
        let token = generation
        if !isSearching { isSearching = true }

        searchTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.debounce)
            }
            guard !Task.isCancelled else { return }

            let results = await SearchEngine.shared.search(
                query: query,
                maxTrackResults: limit,
                maxAlbumResults: 40,
                maxArtistResults: 40
            )

            // Stale-query guard: drop results superseded by newer input.
            guard let self, !Task.isCancelled, token == self.generation, query == self.currentQuery else { return }
            let next = self.makePresentation(results, preserveExpansion: preserveExpansion)
            let input = self.rowInput(for: next, canLoadMore: self.canLoadMore(for: results))
            let built = await Task.detached(priority: .userInitiated) {
                SearchResultRowBuilder.build(input)
            }.value
            guard !Task.isCancelled, token == self.generation, query == self.currentQuery else { return }

            // Publish results and their rows together; supersede any in-flight interaction rebuild.
            self.cancelRowBuild()
            if next != self.presentation {
                self.presentation = next
            }
            if built != self.rows {
                self.rows = built
            }
            self.isSearching = false
            self.searchTask = nil
        }
    }

    private func makePresentation(_ results: GlobalSearchResults, preserveExpansion: Bool) -> Presentation {
        var next = Presentation(results: results)
        if preserveExpansion {
            next.expandedArtistIDs = presentation.expandedArtistIDs
            next.expandedAlbumIDs = presentation.expandedAlbumIDs
            next.trackExpandedArtistIDs = presentation.trackExpandedArtistIDs
            next.trackExpandedAlbumIDs = presentation.trackExpandedAlbumIDs
            next.autoExpandedKey = presentation.autoExpandedKey
            next.autoExpandedArtistID = presentation.autoExpandedArtistID
            next.autoExpandedAlbumID = presentation.autoExpandedAlbumID
        } else if let hint = results.expansionHint {
            // Token engine top-hit rule (§6b): carry the previous expansion and change only what the hint changes.
            let prev = ExpansionState(
                expandedArtistIDs: presentation.expandedArtistIDs,
                expandedAlbumIDs: presentation.expandedAlbumIDs,
                autoExpandedKey: presentation.autoExpandedKey,
                autoExpandedArtistID: presentation.autoExpandedArtistID,
                autoExpandedAlbumID: presentation.autoExpandedAlbumID
            )
            let state = Self.nextExpansion(prev: prev, hint: hint, user: userExpansion)
            next.expandedArtistIDs = state.expandedArtistIDs
            next.expandedAlbumIDs = state.expandedAlbumIDs
            next.autoExpandedKey = state.autoExpandedKey
            next.autoExpandedArtistID = state.autoExpandedArtistID
            next.autoExpandedAlbumID = state.autoExpandedAlbumID
        } else if let topArtistNode = results.artistTreeNodes.first {
            next.expandedArtistIDs.insert(topArtistNode.id)
            let matchedAlbum = topArtistNode.albums.first(where: { $0.isDirectlyMatched })
                ?? topArtistNode.albums.first(where: { $0.tracks.contains(where: { $0.isDirectlyMatched }) })
                ?? topArtistNode.albums.first
            if let matchedAlbumID = matchedAlbum?.id {
                next.expandedAlbumIDs.insert(matchedAlbumID)
            }
        }
        // TRACKS category: only the first few matches start expanded (new ones from paging stay collapsed).
        if !preserveExpansion {
            for node in results.trackCategoryNodes.prefix(SearchResultRowBuilder.defaultTrackCategoryExpansion) {
                next.trackExpandedArtistIDs.insert(node.id)
                next.trackExpandedAlbumIDs.formUnion(node.albums.map(\.id))
            }
        }
        return next
    }
}

// MARK: - Main Global Search View

public struct GlobalSearchView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var searchQuery: String = ""
    @State private var searchModel = GlobalSearchModel()
    @State private var isSearchPresented: Bool = false

    // Results, expansion sets, filters and flattened rows live in GlobalSearchModel.
    private var results: GlobalSearchResults { searchModel.presentation.results }
    private var isSearching: Bool { searchModel.isSearching }

    // Selection states for navigation & sheets
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil

    // Serialized asynchronous search pipeline state
    @State private var activeSearchTask: Task<Void, Never>? = nil
    @State private var inFlightQuery: String? = nil
    @State private var pendingSearchQuery: String? = nil

    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        initialQuery: String? = nil
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        let query = initialQuery ?? libraryStore.globalSearchQuery
        self._searchQuery = State(initialValue: query)
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func goBack() {
        HapticFeedback.lightImpact()
        isSearchPresented = false
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        dismiss()
    }

    public var body: some View {
        Group {
            libraryContentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())

        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    // Allow pulling right from any empty space on the page to go back
                    let isHorizontalPull = abs(value.translation.height) < max(value.translation.width, 1) * 0.65
                    let isSignificantRightwardDrag = value.translation.width > 60 || (value.translation.width > 25 && value.predictedEndTranslation.width > 90)

                    if isHorizontalPull && isSignificantRightwardDrag {
                        goBack()
                    }
                }
        )
        .navigationTitle("SEARCH LIBRARY")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchQuery,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("SEARCH TRACKS, ARTISTS, ALBUMS...")
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 32, height: 32, alignment: .center)
                        .contentShape(Rectangle())
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            playlistPickerSheet(for: track)
        }
        .task {
            let initial = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !initial.isEmpty {
                dispatchSearch(for: initial)
            } else {
                isSearchPresented = true
            }
        }
        .task(id: searchQuery) {
            let clean = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                clearAllSearchState()
                return
            }

            // Debounce (130 ms), stale-query guard and single publish are handled by the search model.
            searchModel.submit(clean)
        }
        .onDisappear {
            isSearchPresented = false
            activeSearchTask?.cancel()
            activeSearchTask = nil
            inFlightQuery = nil
            pendingSearchQuery = nil
            searchModel.cancel()
            libraryStore.globalSearchQuery = searchQuery
            #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }
        .onSubmit(of: .search) {
            libraryStore.globalSearchQuery = searchQuery
        }
        .enableInteractivePopGesture()
    }

    // MARK: - Library Tree Content View

    @ViewBuilder
    private var libraryContentView: some View {
        if trimmedQuery.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                recentSearchPlayedTracksSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .padding(.bottom, 140)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        } else if results.hasResults {
            LibrarySearchResultsContainer(
                rows: searchModel.rows,
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectArtist: { selectedArtistForNavigation = $0 },
                onSelectAlbum: { selectedAlbumForNavigation = $0 },
                onSelectTrackForInfo: { selectedTrackForInfo = $0 },
                onSelectTrackForPlaylist: { selectedTrackForPlaylist = $0 },
                onToggleArtistExpansion: { artistID in
                    HapticFeedback.selectionChanged()
                    searchModel.toggleArtistExpansion(artistID)
                },
                onToggleAlbumExpansion: { albumID, artistID in
                    HapticFeedback.selectionChanged()
                    searchModel.toggleAlbumExpansion(albumID, artistID: artistID)
                },
                onCollapseAll: {
                    HapticFeedback.lightImpact()
                    searchModel.collapseAll()
                },
                onToggleCategoryFilter: { category in
                    searchModel.toggleCategoryFilter(category)
                },
                onTogglePlaylistsCollapse: {
                    searchModel.togglePlaylistsCollapsed()
                },
                onLoadMoreTracks: {
                    HapticFeedback.selectionChanged()
                    searchModel.loadMore()
                }
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearching {
            ScrollView(.vertical, showsIndicators: false) {
                searchingIndicatorView
                    .frame(maxWidth: .infinity, minHeight: 350, alignment: .top)
                    .padding(.bottom, 140)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                emptyResultsView
                    .frame(maxWidth: .infinity, minHeight: 350, alignment: .top)
                    .padding(.bottom, 140)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.always)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    // MARK: - State Views

    @ViewBuilder
    private var recentSearchPlayedTracksSection: some View {
        let recentTracks = libraryStore.recentSearchPlayedTracks
        if !recentTracks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("RECENTLY PLAYED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            libraryStore.clearRecentSearchPlayedTracks()
                        }
                    }) {
                        Text("CLEAR")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(recentTracks) { track in
                        TrackRowView(
                            track: track,
                            isCurrentTrack: track.id == playerService.currentTrack?.id,
                            isPlaying: playerService.playbackStatus.isPlaying && track.id == playerService.currentTrack?.id,
                            isNextTrack: track.id == playerService.nextTrack?.id,
                            isInPlayNext: playerService.playNextQueue.contains(where: { $0.id == track.id }),
                            isTapToPlayNextEnabled: libraryStore.settings.tapToPlayNext,
                            onPlay: {
                                libraryStore.recordSearchPlayedTrack(track)
                                playerService.play(track: track, inQueue: recentTracks, startIndex: recentTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                            },
                            onPlayNext: {
                                playerService.insertPlayNextFront(track: track)
                            },
                            onQueueNext: {
                                playerService.playNext(track: track)
                            },
                            onAddToQueue: {
                                playerService.appendToQueue(track: track)
                            },
                            onAddToPlaylist: {
                                selectedTrackForPlaylist = track
                            },
                            onShowInfo: {
                                selectedTrackForInfo = track
                            },
                            onSelectArtist: { artistName in
                                if let artistObj = libraryStore.findArtist(name: artistName) {
                                    selectedArtistForNavigation = artistObj
                                }
                            },
                            onSelectAlbum: {
                                if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                                    selectedAlbumForNavigation = albumObj
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var searchingIndicatorView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .padding(.top, 40)

            Text("Searching...")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyResultsView: some View {
        EmptyStateView(title: "EMPTY", message: "")
    }

    // MARK: - Playlist Picker Sheet

    private func playlistPickerSheet(for track: Track) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore) { playlist in
            libraryStore.addTrack(track, toPlaylistID: playlist.id)
            HapticFeedback.notificationSuccess()
            selectedTrackForPlaylist = nil
        }
    }

    // MARK: - Serialized Search Pipeline

    private func clearAllSearchState() {
        // Cancel active in-flight tasks and reset pending queries
        activeSearchTask?.cancel()
        activeSearchTask = nil
        inFlightQuery = nil
        pendingSearchQuery = nil
        searchModel.clear()
    }

    private func dispatchSearch(for rawQuery: String) {
        let clean = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            clearAllSearchState()
            return
        }

        // Cancel any in-flight runner and search the library immediately (no debounce for explicit dispatch)
        activeSearchTask?.cancel()
        activeSearchTask = nil
        inFlightQuery = nil
        pendingSearchQuery = nil
        searchModel.submit(clean, debounced: false)
    }
}

// MARK: - Search Tree Track Row Component

/// Tree track row with connector, playback indicator, and animated side swipe on context menu actions
public struct SearchTreeTrackRowView: View {
    public let trackNode: SearchTreeTrackNode
    /// Resolves the playback queue lazily (only when the user taps play).
    public let queueTracks: () -> [Track]
    public let trackIndex: Int
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onAddToPlaylist: (Track) -> Void
    public let onShowInfo: (Track) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var showPlayNextSuccess: Bool = false
    @State private var showQueueNextSuccess: Bool = false

    private var track: Track { trackNode.track }
    private var isCurrent: Bool { playerService.currentTrack?.id == track.id }
    private var isPlaying: Bool { isCurrent && playerService.playbackStatus.isPlaying }

    private func playFromQueue() {
        let queue = queueTracks()
        libraryStore.recordSearchPlayedTrack(track)
        playerService.play(
            track: track,
            inQueue: queue,
            startIndex: queue.firstIndex(where: { $0.id == track.id }) ?? trackIndex
        )
    }

    public var body: some View {
        ZStack {
            // Leading "PLAY NEXT" reveal surface
            if dragOffset > 0 || showPlayNextSuccess {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 10, weight: .bold))
                        Text(showPlayNextSuccess ? "QUEUED" : "PLAY NEXT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Spacer()
                }
            }

            // Trailing "QUEUE NEXT" reveal surface
            if dragOffset < 0 || showQueueNextSuccess {
                HStack {
                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                            .font(.system(size: 10, weight: .bold))
                        Text(showQueueNextSuccess ? "QUEUED" : "QUEUE NEXT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Foreground Track Content
            Button(action: {
                playFromQueue()
            }) {
                HStack(spacing: 8) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 22, alignment: .leading)
                    } else if isCurrent {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 22, alignment: .leading)
                    } else if let trackNum = track.trackNumber, trackNum > 0 {
                        Text(String(format: "%02d", trackNum))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .leading)
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 10, height: 1.5)
                            .frame(width: 22, alignment: .leading)
                    }

                    Text(track.title)
                        .font(.system(size: 13, weight: (isCurrent || trackNode.isDirectlyMatched) ? .bold : .medium))
                        .foregroundStyle(trackNode.isDirectlyMatched ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(TimeFormatting.format(seconds: track.duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
            )
            .offset(x: dragOffset)
        }
        .contextMenu {
            Button(action: {
                playFromQueue()
            }) {
                Text("PLAY")
            }

            Button(action: triggerPlayNext) {
                Text("PLAY NEXT")
            }

            Button(action: triggerQueueNext) {
                Text("QUEUE NEXT")
            }

            Button(action: {
                onAddToPlaylist(track)
            }) {
                Text("ADD TO PLAYLIST")
            }

            Button(action: {
                onShowInfo(track)
            }) {
                Text("GET INFO")
            }

            Button(action: {
                if let artistObj = libraryStore.findArtist(name: track.artist) {
                    onSelectArtist(artistObj)
                }
            }) {
                Text("GO TO ARTIST")
            }

            Button(action: {
                if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                    onSelectAlbum(albumObj)
                }
            }) {
                Text("GO TO ALBUM")
            }
        }
    }

    private func triggerPlayNext() {
        HapticFeedback.notificationSuccess()
        playerService.insertPlayNextFront(track: track)
        showPlayNextSuccess = true

        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            dragOffset = 65
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                dragOffset = 0
                showPlayNextSuccess = false
            }
        }
    }

    private func triggerQueueNext() {
        HapticFeedback.notificationSuccess()
        playerService.playNext(track: track)
        showQueueNextSuccess = true

        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            dragOffset = -65
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                dragOffset = 0
                showQueueNextSuccess = false
            }
        }
    }
}

// MARK: - Search Album Tree Node Row

/// Album header row of the flat tree (its tracks are separate flat rows).
public struct SearchAlbumTreeNodeRow: View {
    public let albumNode: SearchTreeAlbumNode
    public let onToggleExpand: () -> Void
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectAlbum: (Album) -> Void

    public var body: some View {
        let resolvedAlbumArt = albumNode.album.artworkKey ?? albumNode.album.tracks.first(where: { $0.artworkKey != nil })?.artworkKey

        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 10, height: 1.5)

            AlbumArtworkView(
                artworkKey: resolvedAlbumArt,
                title: albumNode.album.title,
                subtitle: albumNode.album.artist,
                cornerRadius: 6
            )
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(albumNode.album.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(albumNode.album.formattedYear)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text("\(albumNode.tracks.count) \(albumNode.tracks.count == 1 ? "TRACK" : "TRACKS")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button(action: {
                onSelectAlbum(albumNode.album)
            }) {
                Text("OPEN")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleExpand()
        }
        .albumContextMenu(album: albumNode.album, libraryStore: libraryStore, playerService: playerService)
    }
}

// MARK: - Search Artist Tree Node Row

/// Artist header row of the flat tree (its categories/albums/tracks are separate flat rows).
public struct SearchArtistTreeNodeRow: View {
    public let artistNode: SearchTreeArtistNode
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectArtist: (Artist) -> Void
    public let onToggleArtistExpansion: (String) -> Void

    public var body: some View {
        let summary = artistNode.artist.discographySummary

        HStack(spacing: 12) {
            AlbumArtworkView(
                artworkKey: artistNode.artist.mostRecentArtworkKey ?? artistNode.albums.first?.album.artworkKey,
                title: artistNode.artist.name,
                subtitle: summary,
                cornerRadius: 8
            )
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(artistNode.artist.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: {
                onSelectArtist(artistNode.artist)
            }) {
                Text("OPEN")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleArtistExpansion(artistNode.id)
        }
        .contextMenu {
            Button(action: {
                onSelectArtist(artistNode.artist)
            }) {
                Text("VIEW ARTIST")
            }

            Button(action: {
                if let first = artistNode.artist.tracks.first {
                    libraryStore.recordSearchPlayedTrack(first)
                    playerService.play(track: first, inQueue: artistNode.artist.tracks)
                }
            }) {
                Text("PLAY ARTIST")
            }

            Button(action: {
                var shuffled = artistNode.artist.tracks
                shuffled.shuffle()
                if let first = shuffled.first {
                    libraryStore.recordSearchPlayedTrack(first)
                    playerService.play(track: first, inQueue: shuffled)
                }
            }) {
                Text("SHUFFLE ARTIST")
            }
        }
    }
}
// MARK: - Equatable Library Search Results Container

/// Renders the flattened search rows with a single ForEach inside a single LazyVStack.
public struct LibrarySearchResultsContainer: View, Equatable {
    public let rows: [SearchResultRow]

    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onSelectTrackForInfo: (Track) -> Void
    public let onSelectTrackForPlaylist: (Track) -> Void
    public let onToggleArtistExpansion: (String) -> Void
    public let onToggleAlbumExpansion: (String, String) -> Void
    public let onCollapseAll: () -> Void
    public let onToggleCategoryFilter: (SearchCategoryFilter) -> Void
    public let onTogglePlaylistsCollapse: () -> Void
    public let onLoadMoreTracks: () -> Void

    public static func == (lhs: LibrarySearchResultsContainer, rhs: LibrarySearchResultsContainer) -> Bool {
        lhs.rows == rhs.rows
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SearchResultRowView(
                        row: row,
                        libraryStore: libraryStore,
                        playerService: playerService,
                        onSelectArtist: onSelectArtist,
                        onSelectAlbum: onSelectAlbum,
                        onSelectTrackForInfo: onSelectTrackForInfo,
                        onSelectTrackForPlaylist: onSelectTrackForPlaylist,
                        onToggleArtistExpansion: onToggleArtistExpansion,
                        onToggleAlbumExpansion: onToggleAlbumExpansion,
                        onCollapseAll: onCollapseAll,
                        onToggleCategoryFilter: onToggleCategoryFilter,
                        onTogglePlaylistsCollapse: onTogglePlaylistsCollapse,
                        onLoadMoreTracks: onLoadMoreTracks
                    )
                    .equatable()
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 140)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - Flat Search Row View

public struct SearchResultRowView: View, Equatable {
    public let row: SearchResultRow
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onSelectTrackForInfo: (Track) -> Void
    public let onSelectTrackForPlaylist: (Track) -> Void
    public let onToggleArtistExpansion: (String) -> Void
    public let onToggleAlbumExpansion: (String, String) -> Void
    public let onCollapseAll: () -> Void
    public let onToggleCategoryFilter: (SearchCategoryFilter) -> Void
    public let onTogglePlaylistsCollapse: () -> Void
    public let onLoadMoreTracks: () -> Void

    public static func == (lhs: SearchResultRowView, rhs: SearchResultRowView) -> Bool {
        lhs.row == rhs.row
    }

    /// TRACKS category rows resolve the tapped artist/album against the library (as before).
    private var selectArtist: (Artist) -> Void {
        guard row.resolvesFromLibrary else { return onSelectArtist }
        let store = libraryStore
        let select = onSelectArtist
        return { artist in select(store.findArtist(name: artist.name) ?? artist) }
    }

    private var selectAlbum: (Album) -> Void {
        guard row.resolvesFromLibrary else { return onSelectAlbum }
        let store = libraryStore
        let select = onSelectAlbum
        return { album in select(store.findAlbum(title: album.title, artist: album.artist) ?? album) }
    }

    public var body: some View {
        content
            .padding(.top, row.albumLineGap)
            .modifier(SearchConnectorLine(isActive: row.albumLine, indent: 26, lineOffset: 15))
            .padding(.top, row.artistLineGap)
            .modifier(SearchConnectorLine(isActive: row.artistLine, indent: 24, lineOffset: 12))
            .padding(.top, row.outerGap)
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case let .controls(artists, albums, tracks, filter):
            SearchTreeControlsBar(
                artistsCount: artists,
                albumsCount: albums,
                tracksCount: tracks,
                activeCategoryFilter: filter,
                onCollapseAll: onCollapseAll,
                onToggleCategoryFilter: onToggleCategoryFilter
            )
        case let .artistHeader(node):
            SearchArtistTreeNodeRow(
                artistNode: node,
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectArtist: selectArtist,
                onToggleArtistExpansion: onToggleArtistExpansion
            )
        case let .categoryHeader(title):
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.65))
                .padding(.leading, 10)
        case let .albumHeader(node, artistID):
            SearchAlbumTreeNodeRow(
                albumNode: node,
                onToggleExpand: { onToggleAlbumExpansion(node.id, artistID) },
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectAlbum: selectAlbum
            )
        case let .albumTrack(trackNode, albumTracks, index):
            SearchTreeTrackRowView(
                trackNode: trackNode,
                queueTracks: { albumTracks },
                trackIndex: index,
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectArtist: selectArtist,
                onSelectAlbum: selectAlbum,
                onAddToPlaylist: onSelectTrackForPlaylist,
                onShowInfo: onSelectTrackForInfo
            )
        case let .looseTracksHeader(count):
            Text("TRACKS (\(count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 12)
                .padding(.bottom, -4)
        case let .looseTrack(trackNode, index):
            SearchTreeTrackRowView(
                trackNode: trackNode,
                queueTracks: { [libraryStore] in
                    libraryStore.findAlbum(title: trackNode.track.album, artist: trackNode.track.artist)?.tracks ?? [trackNode.track]
                },
                trackIndex: index,
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectArtist: onSelectArtist,
                onSelectAlbum: onSelectAlbum,
                onAddToPlaylist: onSelectTrackForPlaylist,
                onShowInfo: onSelectTrackForInfo
            )
            .padding(.vertical, -6)
        case .loadMore:
            Button(action: onLoadMoreTracks) {
                Text("SHOW MORE TRACKS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case let .filteredArtist(node):
            filteredArtistRow(node)
        case let .filteredAlbum(album, artist):
            filteredAlbumRow(album: album, artist: artist)
        case let .playlistsHeader(count, isCollapsed):
            Button(action: onTogglePlaylistsCollapse) {
                HStack {
                    Text("PLAYLISTS (\(count))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        case let .playlistsGrid(playlists):
            playlistsGrid(playlists)
        }
    }

    private func filteredArtistRow(_ artistNode: SearchTreeArtistNode) -> some View {
        let totalTracks = artistNode.albums.reduce(0) { $0 + $1.tracks.count }
        let summary = "\(artistNode.albums.count) \(artistNode.albums.count == 1 ? "ALBUM" : "ALBUMS") · \(totalTracks) \(totalTracks == 1 ? "TRACK" : "TRACKS")"

        return Button(action: {
            onSelectArtist(artistNode.artist)
        }) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: artistNode.artist.mostRecentArtworkKey ?? artistNode.albums.first?.album.artworkKey,
                    title: artistNode.artist.name,
                    subtitle: summary,
                    cornerRadius: 8
                )
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artistNode.artist.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("OPEN")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: {
                onSelectArtist(artistNode.artist)
            }) {
                Text("VIEW ARTIST")
            }
        }
    }

    private func filteredAlbumRow(album: Album, artist: Artist) -> some View {
        let resolvedAlbumArt = album.artworkKey ?? album.tracks.first(where: { $0.artworkKey != nil })?.artworkKey

        return Button(action: {
            onSelectAlbum(album)
        }) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: resolvedAlbumArt,
                    title: album.title,
                    subtitle: album.artist,
                    cornerRadius: 6
                )
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(album.artist.isEmpty ? artist.name : album.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Text(album.formattedYear)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text("OPEN")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService)
    }

    /// Non-lazy adaptive grid (same geometry as GridItem(.adaptive(minimum: 155), spacing: 14)) so the
    /// single outer LazyVStack stays the only lazy container.
    private func playlistsGrid(_ playlists: [Playlist]) -> some View {
        SearchAdaptiveGridLayout(minimum: 155, spacing: 14) {
            ForEach(playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlistID: playlist.id, libraryStore: libraryStore, playerService: playerService)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            AlbumArtworkView(
                                artworkKey: libraryStore.artworkKey(for: playlist),
                                title: playlist.name,
                                subtitle: "Playlist",
                                cornerRadius: 8
                            )
                            .aspectRatio(1.0, contentMode: .fit)

                            if playlist.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .padding(5)
                                    .background(Color.black.opacity(0.65))
                                    .clipShape(Circle())
                                    .padding(6)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            Text(playlist.formattedTrackCount)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Tree Connector Line

/// Indents a flat row and draws its segment of the vertical tree connector line, so consecutive rows
/// form the same continuous line the nested tree used to draw.
private struct SearchConnectorLine: ViewModifier {
    let isActive: Bool
    let indent: CGFloat
    let lineOffset: CGFloat

    func body(content: Content) -> some View {
        if isActive {
            content
                .padding(.leading, indent)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1.5)
                        .padding(.leading, lineOffset)
                }
        } else {
            content
        }
    }
}

// MARK: - Adaptive Grid Layout (non-lazy)

private struct SearchAdaptiveGridLayout: Layout {
    let minimum: CGFloat
    let spacing: CGFloat

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimum + spacing)))
        let columnWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        return (count, columnWidth)
    }

    private func rowHeights(_ subviews: Subviews, count: Int, columnWidth: CGFloat) -> [CGFloat] {
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let end = min(index + count, subviews.count)
            var height: CGFloat = 0
            for i in index..<end {
                height = max(height, subviews[i].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height)
            }
            heights.append(height)
            index = end
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimum * 2 + spacing)
        let (count, columnWidth) = columns(for: width)
        let heights = rowHeights(subviews, count: count, columnWidth: columnWidth)
        let total = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, columnWidth) = columns(for: bounds.width)
        let heights = rowHeights(subviews, count: count, columnWidth: columnWidth)
        var y = bounds.minY
        for (rowIndex, height) in heights.enumerated() {
            for column in 0..<count {
                let index = rowIndex * count + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x + columnWidth / 2, y: y + height / 2),
                    anchor: .center,
                    proposal: ProposedViewSize(width: columnWidth, height: nil)
                )
            }
            y += height + spacing
        }
    }
}

// MARK: - Tree Controls Bar

private struct SearchTreeControlsBar: View {
    let artistsCount: Int
    let albumsCount: Int
    let tracksCount: Int
    let activeCategoryFilter: SearchCategoryFilter?
    let onCollapseAll: () -> Void
    let onToggleCategoryFilter: (SearchCategoryFilter) -> Void

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    onToggleCategoryFilter(.artists)
                }) {
                    Text("\(artistsCount) ARTISTS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCategoryFilter == .artists ? Color.white : Color.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("·")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    onToggleCategoryFilter(.albums)
                }) {
                    Text("\(albumsCount) ALBUMS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCategoryFilter == .albums ? Color.white : Color.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("·")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    onToggleCategoryFilter(.tracks)
                }) {
                    Text("\(tracksCount) TRACKS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCategoryFilter == .tracks ? Color.white : Color.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if activeCategoryFilter == nil {
                Button(action: onCollapseAll) {
                    Text("COLLAPSE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    if let cur = activeCategoryFilter {
                        onToggleCategoryFilter(cur)
                    }
                }) {
                    Text("SHOW ALL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
