import Foundation
import os

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

// MARK: - Search Ranking Helpers (plan §0 D3/D4/D5/D9/D10, §3, §4)

/// Which albums an artist node lists (plan §2): the full discography or only the albums that match.
nonisolated public enum SearchNodeScope: Sendable {
    case full, matchedOnly
}

/// D3 sort key for one album that contains a match (pure value so SearchSelfCheck can test the order).
nonisolated public struct SearchReleaseKey: Sendable, Equatable {
    /// The query names this version (live, deluxe, remix, …) and the album or matched track carries it.
    public var versionNamed: Bool
    public var bucket: Int
    public var final: Int
    /// The best matched track is a remix/live/alternate cut (a weaker title match than the plain song).
    public var alternateTrack: Bool
    /// `DiscographySection.rawValue`: studio 0 < single/EP 1 (D5) < alternate 2 < featured 3.
    public var section: Int
    public var year: Int?
    public var trackCount: Int
    public var albumID: String

    public init(versionNamed: Bool = false, bucket: Int = 3, final: Int = 1_000_000, alternateTrack: Bool = false,
                section: Int, year: Int?, trackCount: Int, albumID: String) {
        self.versionNamed = versionNamed
        self.bucket = bucket
        self.final = final
        self.alternateTrack = alternateTrack
        self.section = section
        self.year = year
        self.trackCount = trackCount
        self.albumID = albumID
    }
}

nonisolated public enum SearchRanking {
    static let unit = 10_000_000
    /// Version words that, when typed, make the matching release win (D3 "a query naming the version wins").
    static let versionWords: Set<String> = [
        "live", "deluxe", "remix", "remixes", "acoustic", "remaster", "remastered", "demo", "instrumental",
        "unplugged", "extended", "expanded", "anniversary", "edition", "slowed", "acapella", "mix", "version", "edit"
    ]

    static func queryVersionWords(_ query: String) -> Set<String> {
        Set(SearchNormalizer.rawTokens(query).filter { versionWords.contains($0) })
    }

    static func namesVersion(_ words: Set<String>, album: Album, track: Track?) -> Bool {
        guard !words.isEmpty else { return false }
        var tokens = Set(SearchNormalizer.rawTokens(album.title))
        if let track { tokens.formUnion(SearchNormalizer.rawTokens(track.title)) }
        return !words.isDisjoint(with: tokens)
    }

    /// D3 + D5 + D10: true when `a` ranks before `b`.
    /// Version named > better title match (bucket, final beyond 1%, plain over alternate cut) > studio > single/EP >
    /// alternate > Featured On > earliest year (no year last) > fewest tracks > album ID.
    static func releaseOrder(_ a: SearchReleaseKey, _ b: SearchReleaseKey) -> Bool {
        if a.versionNamed != b.versionNamed { return a.versionNamed }
        if a.bucket != b.bucket { return a.bucket > b.bucket }
        if abs(a.final - b.final) * 100 > max(a.final, b.final) { return a.final > b.final }
        if a.alternateTrack != b.alternateTrack { return !a.alternateTrack }
        if a.section != b.section { return a.section < b.section }
        let ya = (a.year ?? 0) > 0 ? a.year : nil
        let yb = (b.year ?? 0) > 0 ? b.year : nil
        switch (ya, yb) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.trackCount != b.trackCount { return a.trackCount < b.trackCount }
        return a.albumID < b.albumID
    }

    /// §3.1 artist + song: when the leading or trailing query tokens equal the whole artist name and terms remain,
    /// returns the remaining (title) tokens.
    static func artistSongRest(queryTokens: [String], artistTokens: [String]) -> [String]? {
        let n = artistTokens.count
        guard n > 0, queryTokens.count > n else { return nil }
        if Array(queryTokens.prefix(n)) == artistTokens { return Array(queryTokens.dropFirst(n)) }
        if Array(queryTokens.suffix(n)) == artistTokens { return Array(queryTokens.dropLast(n)) }
        return nil
    }

    /// Every remaining term is a word (or word prefix) of the title.
    static func titleCovers(_ rest: [String], title: String) -> Bool {
        let words = SearchNormalizer.rawTokens(title)
        return !rest.isEmpty && rest.allSatisfy { r in words.contains { $0.hasPrefix(r) } }
    }

    public enum HitKind: Int, Sendable { case track = 0, album = 1, artist = 2 }

    public struct HitCandidate: Sendable {
        public var kind: HitKind
        public var score: Int
        public var wholeExactArtist: Bool
        public init(kind: HitKind, score: Int, wholeExactArtist: Bool = false) {
            self.kind = kind
            self.score = score
            self.wholeExactArtist = wholeExactArtist
        }
    }

    /// Top hit (§3.3): D4 (an artist wins only on a whole-name match), then best (bucket, final);
    /// candidates in the same bucket within 1% tie and go track > album > artist, then input order.
    static func pickTopHit(_ hits: [HitCandidate]) -> Int? {
        if let i = hits.firstIndex(where: { $0.kind == .artist && $0.wholeExactArtist }) { return i }
        let nonArtist = hits.indices.filter { hits[$0].kind != .artist }
        let pool = nonArtist.isEmpty ? Array(hits.indices) : nonArtist
        guard let best = pool.max(by: { hits[$0].score < hits[$1].score }) else { return nil }
        let tb = hits[best].score / unit, tf = hits[best].score % unit
        let near = pool.filter {
            hits[$0].score / unit == tb && (tf - hits[$0].score % unit) * 100 <= tf
        }
        return near.min { l, r in
            hits[l].kind.rawValue != hits[r].kind.rawValue ? hits[l].kind.rawValue < hits[r].kind.rawValue : l < r
        }
    }

    /// §3.4: fuzzy-only top hit leading the runner-up in the same bucket by less than 0.10 → expand nothing.
    static func isNearTie(top: Int, runner: Int?) -> Bool {
        guard let runner else { return false }
        let tb = top / unit, rb = runner / unit
        return tb <= 1 && rb == tb && top % unit - runner % unit < 100_000
    }
}

// MARK: - Search Index Data Structures

nonisolated public struct SearchIndexEntry<ID: Sendable>: Sendable {
    public let id: ID
    public let key: String
    public let primaryLength: Int32

    public init(id: ID, key: String, primaryLength: Int32 = 0) {
        self.id = id
        self.key = key
        self.primaryLength = primaryLength
    }
}

/// Contiguous byte-buffer index for high-speed SIMD/memchr substring search without per-query String allocations.
nonisolated public struct KindIndex<ID: Sendable>: Sendable {
    public let ids: [ID]
    public let offsets: [Int32]
    public let primaryLengths: [Int32]
    public let buffer: [UInt8]

    public var count: Int { ids.count }

    public static var empty: KindIndex<ID> {
        KindIndex(ids: [], offsets: [0], primaryLengths: [], buffer: [])
    }

    public init(ids: [ID], offsets: [Int32], primaryLengths: [Int32] = [], buffer: [UInt8]) {
        self.ids = ids
        self.offsets = offsets
        self.primaryLengths = primaryLengths
        self.buffer = buffer
    }
}

/// Sendable snapshot of library store lookups passed to SearchEngine once on index update, eliminating per-query actor hops.
nonisolated public struct SearchContext: Sendable {
    public let tracksByID: [UUID: Track]
    public let albumsByID: [String: Album]
    public let artists: [Artist]
    public let artistLookupIndex: [String: Artist]
    public let playlists: [Playlist]
    public let joinedArtists: [String]

    public static let empty = SearchContext(
        tracksByID: [:],
        albumsByID: [:],
        artists: [],
        artistLookupIndex: [:],
        playlists: [],
        joinedArtists: []
    )

    public init(
        tracksByID: [UUID: Track] = [:],
        albumsByID: [String: Album] = [:],
        artists: [Artist] = [],
        artistLookupIndex: [String: Artist] = [:],
        playlists: [Playlist] = [],
        joinedArtists: [String] = []
    ) {
        self.tracksByID = tracksByID
        self.albumsByID = albumsByID
        self.artists = artists
        self.artistLookupIndex = artistLookupIndex
        self.playlists = playlists
        self.joinedArtists = joinedArtists
    }
}

/// One-time album/artist lookup map built off-main per index generation, so search grouping
/// never scans the whole library (mirrors LibraryStore.findAlbum resolution order).
nonisolated struct SearchAlbumLookup: Sendable {
    let generation: UInt64
    /// "normalizedArtist_normalizedTitle" -> first album (same key as LibraryStore's index).
    var byNormalizedKey: [String: Album] = [:]
    /// Lowercased title -> albums in that title bucket.
    var byLowercasedTitle: [String: [Album]] = [:]
    /// Cluster-normalized title -> first album.
    var byClusterTitle: [String: Album] = [:]
    /// Cluster-normalized track album title -> tracks (for synthesized albums).
    var tracksByClusterTitle: [String: [Track]] = [:]
    /// Artist id -> artist.
    var artistsByID: [String: Artist] = [:]

    static func build(generation: UInt64, context ctx: SearchContext) -> SearchAlbumLookup {
        var lookup = SearchAlbumLookup(generation: generation)
        var clusterMemo: [String: String] = [:]
        func cluster(_ title: String) -> String {
            if let cached = clusterMemo[title] { return cached }
            let value = LibraryStore.normalizeAlbumTitleForClustering(title)
            clusterMemo[title] = value
            return value
        }

        // Stable album order (dictionary order is arbitrary) so "first match" is deterministic.
        let albums = ctx.albumsByID.values.sorted { $0.id < $1.id }
        lookup.byNormalizedKey.reserveCapacity(albums.count)
        for album in albums {
            let key = "\(album.normalizedArtist)_\(album.normalizedTitle)"
            if lookup.byNormalizedKey[key] == nil { lookup.byNormalizedKey[key] = album }
            lookup.byLowercasedTitle[album.title.lowercased(), default: []].append(album)
            let clusterKey = cluster(album.title)
            if lookup.byClusterTitle[clusterKey] == nil { lookup.byClusterTitle[clusterKey] = album }
        }
        for track in ctx.tracksByID.values {
            lookup.tracksByClusterTitle[cluster(track.album), default: []].append(track)
        }
        for artist in ctx.artists where lookup.artistsByID[artist.id] == nil {
            lookup.artistsByID[artist.id] = artist
        }
        return lookup
    }

    /// Same resolution order as LibraryStore.findAlbum(title:artist:), using O(1) maps.
    func resolveAlbum(title: String, artist: String?, context ctx: SearchContext) -> Album? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        if let artist {
            let key = "\(FuzzyMatcher.normalize(artist))_\(FuzzyMatcher.normalize(cleanTitle))"
            if let indexed = byNormalizedKey[key] { return indexed }
        }
        if let direct = ctx.albumsByID[cleanTitle] { return direct }
        let bucket = byLowercasedTitle[cleanTitle.lowercased()] ?? []
        if let artist, let match = bucket.first(where: {
            $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame ||
            $0.isLeadOrCollaborativeAlbum(for: artist, joinedArtists: ctx.joinedArtists)
        }) {
            return match
        }
        if let fallback = bucket.first { return fallback }
        let clusterKey = LibraryStore.normalizeAlbumTitleForClustering(cleanTitle)
        if let clustered = byClusterTitle[clusterKey] { return clustered }
        guard let matchingTracks = tracksByClusterTitle[clusterKey], !matchingTracks.isEmpty else { return nil }
        return Album(
            title: cleanTitle,
            artist: artist ?? matchingTracks.first?.artist ?? "Unknown Artist",
            artworkKey: matchingTracks.first?.artworkKey,
            tracks: matchingTracks
        )
    }

    /// O(1) subset of LibraryStore.findArtist(name:) (index lookups only).
    func resolveArtist(name: String, context ctx: SearchContext) -> Artist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ArtistParser.isGenericArtistName(trimmed) else { return nil }
        let canonicalKey = ArtistParser.canonicalArtistKey(trimmed)
        guard !canonicalKey.isEmpty else { return nil }
        return ctx.artistLookupIndex[canonicalKey]
            ?? ctx.artistLookupIndex[trimmed.lowercased()]
            ?? artistsByID[canonicalKey]
    }
}

/// Immutable SearchSnapshot value swapped under OSAllocatedUnfairLock.
nonisolated public struct SearchSnapshot: Sendable {
    public let generation: UInt64
    public let tracks: KindIndex<UUID>
    public let albums: KindIndex<String>
    public let artists: KindIndex<String>
    public let playlists: KindIndex<UUID>
    public let context: SearchContext?
    /// Token / prefix index (plan §3.2). Nil until the normalized rebuild finishes; the legacy scanner is used meanwhile.
    public let tokenIndex: SearchTokenIndex?

    public static let empty = SearchSnapshot(
        generation: 0,
        tracks: .empty,
        albums: .empty,
        artists: .empty,
        playlists: .empty,
        context: nil
    )

    public var isEmpty: Bool {
        tracks.count == 0 && albums.count == 0 && artists.count == 0 && playlists.count == 0
    }

    public init(
        generation: UInt64,
        tracks: KindIndex<UUID>,
        albums: KindIndex<String>,
        artists: KindIndex<String>,
        playlists: KindIndex<UUID>,
        context: SearchContext?,
        tokenIndex: SearchTokenIndex? = nil
    ) {
        self.tokenIndex = tokenIndex
        self.generation = generation
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.context = context
    }
}

nonisolated public struct SearchIndex: Sendable {
    public let tracks: [SearchIndexEntry<UUID>]
    public let albums: [SearchIndexEntry<String>]
    public let artists: [SearchIndexEntry<String>]
    public let playlists: [SearchIndexEntry<UUID>]

    public static let empty = SearchIndex(tracks: [], albums: [], artists: [], playlists: [])

    public init(
        tracks: [SearchIndexEntry<UUID>] = [],
        albums: [SearchIndexEntry<String>] = [],
        artists: [SearchIndexEntry<String>] = [],
        playlists: [SearchIndexEntry<UUID>] = []
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }
}

nonisolated public struct FlatSearchResults: Sendable {
    public let trackIDs: [UUID]
    public let albumIDs: [String]
    public let artistIDs: [String]
    public let playlistIDs: [UUID]
    public let trackScores: [Int]
    public let albumScores: [Int]
    public let artistScores: [Int]
    public let playlistScores: [Int]
    /// Scores come from the token engine (bucket × 10M + final × 1M).
    public let isTokenRanked: Bool
    /// Per `artistIDs` entry: the query equals the artist's whole name (bucket 3).
    public let artistWholeExact: [Bool]

    public static let empty = FlatSearchResults(
        trackIDs: [], albumIDs: [], artistIDs: [], playlistIDs: [],
        trackScores: [], albumScores: [], artistScores: [], playlistScores: []
    )

    public init(
        trackIDs: [UUID] = [],
        albumIDs: [String] = [],
        artistIDs: [String] = [],
        playlistIDs: [UUID] = [],
        trackScores: [Int] = [],
        albumScores: [Int] = [],
        artistScores: [Int] = [],
        playlistScores: [Int] = [],
        isTokenRanked: Bool = false,
        artistWholeExact: [Bool] = []
    ) {
        self.isTokenRanked = isTokenRanked
        self.artistWholeExact = artistWholeExact
        self.trackIDs = trackIDs
        self.albumIDs = albumIDs
        self.artistIDs = artistIDs
        self.playlistIDs = playlistIDs
        self.trackScores = trackScores
        self.albumScores = albumScores
        self.artistScores = artistScores
        self.playlistScores = playlistScores
    }
}

public typealias SearchFlatResults = FlatSearchResults

// MARK: - Internal Top-K Bounded Buffer & Cache

nonisolated private struct ScoredItem<ID: Sendable>: Sendable {
    let id: ID
    let score: Int
    let index: Int
}

nonisolated private final class TopKBuffer<ID: Sendable> {
    private var items: [ScoredItem<ID>]
    private let capacity: Int
    private var minScore: Int = Int.min
    private var minIndexValue: Int = Int.max
    private var minPosition: Int = 0

    nonisolated init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.items = []
        self.items.reserveCapacity(self.capacity)
    }

    @inline(__always)
    func insert(id: ID, score: Int, index: Int) {
        if items.count < capacity {
            items.append(ScoredItem(id: id, score: score, index: index))
            if items.count == capacity {
                recomputeMin()
            }
        } else if score > minScore || (score == minScore && index < minIndexValue) {
            items[minPosition] = ScoredItem(id: id, score: score, index: index)
            recomputeMin()
        }
    }

    @inline(__always)
    private func recomputeMin() {
        guard !items.isEmpty else { return }
        var lowestScore = items[0].score
        var worstIdx = items[0].index
        var worstPos = 0

        for i in 1..<items.count {
            let s = items[i].score
            let idx = items[i].index
            if s < lowestScore || (s == lowestScore && idx > worstIdx) {
                lowestScore = s
                worstIdx = idx
                worstPos = i
            }
        }
        self.minScore = lowestScore
        self.minIndexValue = worstIdx
        self.minPosition = worstPos
    }

    func sortedItems() -> [(id: ID, score: Int)] {
        items.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            return a.index < b.index
        }
        return items.map { ($0.id, $0.score) }
    }

    func sortedIDs() -> [ID] {
        sortedItems().map { $0.id }
    }
}

nonisolated private struct IncrementalSearchCache: Sendable {
    var query: String = ""
    var generation: UInt64 = 0
    var trackIndices: [Int] = []
    var albumIndices: [Int] = []
    var artistIndices: [Int] = []
    var playlistIndices: [Int] = []

    nonisolated init(
        query: String = "",
        generation: UInt64 = 0,
        trackIndices: [Int] = [],
        albumIndices: [Int] = [],
        artistIndices: [Int] = [],
        playlistIndices: [Int] = []
    ) {
        self.query = query
        self.generation = generation
        self.trackIndices = trackIndices
        self.albumIndices = albumIndices
        self.artistIndices = artistIndices
        self.playlistIndices = playlistIndices
    }
}

// MARK: - In-Memory Search Engine

/// Ultra-fast in-memory search engine holding an immutable SearchSnapshot behind an OSAllocatedUnfairLock.
/// Operates without actor isolation stalls, locks or disk queries during search execution.
nonisolated public final class SearchEngine: @unchecked Sendable {
    public static let shared = SearchEngine()

    private let indexLock = OSAllocatedUnfairLock(initialState: SearchSnapshot.empty)
    private let nextGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 1)
    private let discographyLock = OSAllocatedUnfairLock<[String: CachedArtistDiscography]>(initialState: [:])
    private let incrementalLock = OSAllocatedUnfairLock<IncrementalSearchCache>(initialState: IncrementalSearchCache())
    private let albumLookupLock = OSAllocatedUnfairLock<SearchAlbumLookup?>(initialState: nil)
    /// Last token-index result (full dense scores), reused by expandArtist for the same query and generation.
    private let tokenResultCache = OSAllocatedUnfairLock<(generation: UInt64, query: String, results: SearchTokenResults)?>(initialState: nil)

    /// Debug flag (plan §3.3): set the "SearchUseLegacyScanner" user default to fall back to the substring scanner.
    public static var useTokenIndex: Bool {
        !UserDefaults.standard.bool(forKey: "SearchUseLegacyScanner")
    }
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "amo.MusicPlayer", category: "Search")

    public init() {}

    /// Returns the lookup map for the snapshot's generation, building it once (off-main) when stale.
    private func albumLookup(for snapshot: SearchSnapshot, context: SearchContext) -> SearchAlbumLookup {
        if let cached = albumLookupLock.withLock({ $0 }), cached.generation == snapshot.generation {
            return cached
        }
        let built = SearchAlbumLookup.build(generation: snapshot.generation, context: context)
        albumLookupLock.withLock { current in
            if current == nil || current!.generation <= built.generation { current = built }
        }
        return built
    }

    // MARK: - Normalization

    public static func normalizeKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return FuzzyMatcher.normalize(folded)
    }

    /// Query normalization through the shared SearchNormalizer pipeline (plan §3.1).
    /// A trailing partial "n" is kept as typed so it can still prefix-match.
    public static func normalizeQuery(_ query: String) -> String {
        SearchNormalizer.canonicalTokens(query, lastIsPartial: SearchNormalizer.lastTokenIsPartial(query)).joined(separator: " ")
    }

    @inline(__always)
    static func trackSearchKey(_ t: Track) -> (key: String, primaryLength: Int32) {
        SearchNormalizer.legacyKey(for: SearchNormalizer.trackFields(title: t.title, artist: t.artist, album: t.album, genre: t.genre))
    }

    @inline(__always)
    static func albumSearchKey(_ a: Album) -> (key: String, primaryLength: Int32) {
        SearchNormalizer.legacyKey(for: SearchNormalizer.albumFields(title: a.title, artist: a.artist, year: a.resolvedYear))
    }

    @inline(__always)
    static func artistSearchKey(_ a: Artist) -> (key: String, primaryLength: Int32) {
        SearchNormalizer.legacyKey(for: SearchNormalizer.artistFields(name: a.name))
    }

    @inline(__always)
    static func playlistSearchKey(_ p: Playlist) -> (key: String, primaryLength: Int32) {
        SearchNormalizer.legacyKey(for: SearchNormalizer.playlistFields(name: p.name))
    }

    /// Rebuilds the snapshot for `generation` from raw model fields with SearchNormalizer keys, off-main,
    /// and swaps it in only if no newer index update arrived meanwhile.
    private func scheduleNormalizedRebuild(
        replacing generation: UInt64,
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        context: SearchContext?
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let built = Self.buildNormalizedSnapshotParts(tracks: tracks, albums: albums, artists: artists, playlists: playlists)
            let newGen = self.nextGeneration.withLock { g -> UInt64 in
                let cur = g
                g += 1
                return cur
            }
            let snapshot = SearchSnapshot(
                generation: newGen,
                tracks: built.tracks,
                albums: built.albums,
                artists: built.artists,
                playlists: built.playlists,
                context: context,
                tokenIndex: built.tokenIndex
            )
            let applied = self.indexLock.withLock { current -> Bool in
                guard current.generation == generation else { return false }
                if snapshot.isEmpty && !current.isEmpty { return false }
                current = snapshot
                return true
            }
            if applied {
                self.discographyLock.withLock { $0.removeAll() }
                self.incrementalLock.withLock { $0 = IncrementalSearchCache() }
                self.tokenResultCache.withLock { $0 = nil }
                AppLogger.library.info("SearchEngine normalized index applied (gen: \(newGen), vocabulary: \(built.tokenIndex.vocabularySize)).")
            }
        }
    }

    private static func buildNormalizedSnapshotParts(
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist]
    ) -> (tracks: KindIndex<UUID>, albums: KindIndex<String>, artists: KindIndex<String>, playlists: KindIndex<UUID>, tokenIndex: SearchTokenIndex) {
        // Fields are computed once and feed both the legacy substring keys and the token index.
        var trackEntries: [SearchIndexEntry<UUID>] = []
        var trackFields: [(id: UUID, fields: [SearchField])] = []
        trackEntries.reserveCapacity(tracks.count)
        trackFields.reserveCapacity(tracks.count)
        for t in tracks {
            let f = SearchNormalizer.trackFields(title: t.title, artist: t.artist, album: t.album, genre: t.genre)
            let k = SearchNormalizer.legacyKey(for: f)
            guard !k.key.isEmpty else { continue }
            trackEntries.append(SearchIndexEntry(id: t.id, key: k.key, primaryLength: k.primaryLength))
            trackFields.append((t.id, f))
        }
        var albumEntries: [SearchIndexEntry<String>] = []
        var albumFields: [(id: String, fields: [SearchField])] = []
        albumEntries.reserveCapacity(albums.count)
        albumFields.reserveCapacity(albums.count)
        for a in albums {
            let f = SearchNormalizer.albumFields(title: a.title, artist: a.artist, year: a.resolvedYear)
            let k = SearchNormalizer.legacyKey(for: f)
            guard !k.key.isEmpty else { continue }
            albumEntries.append(SearchIndexEntry(id: a.id, key: k.key, primaryLength: k.primaryLength))
            albumFields.append((a.id, f))
        }
        var artistEntries: [SearchIndexEntry<String>] = []
        var artistFields: [(id: String, fields: [SearchField])] = []
        artistEntries.reserveCapacity(artists.count)
        artistFields.reserveCapacity(artists.count)
        for art in artists {
            let f = SearchNormalizer.artistFields(name: art.name)
            let k = SearchNormalizer.legacyKey(for: f)
            guard !k.key.isEmpty else { continue }
            artistEntries.append(SearchIndexEntry(id: art.id, key: k.key, primaryLength: k.primaryLength))
            artistFields.append((art.id, f))
        }
        var playlistEntries: [SearchIndexEntry<UUID>] = []
        var playlistFields: [(id: UUID, fields: [SearchField])] = []
        playlistEntries.reserveCapacity(playlists.count)
        playlistFields.reserveCapacity(playlists.count)
        for pl in playlists {
            let f = SearchNormalizer.playlistFields(name: pl.name)
            let k = SearchNormalizer.legacyKey(for: f)
            guard !k.key.isEmpty else { continue }
            playlistEntries.append(SearchIndexEntry(id: pl.id, key: k.key, primaryLength: k.primaryLength))
            playlistFields.append((pl.id, f))
        }
        let tokenIndex = SearchTokenIndex.build(tracks: trackFields, albums: albumFields, artists: artistFields, playlists: playlistFields)
        return (buildKindIndex(from: trackEntries), buildKindIndex(from: albumEntries),
                buildKindIndex(from: artistEntries), buildKindIndex(from: playlistEntries), tokenIndex)
    }

    // MARK: - Index Population

    private static func buildKindIndex<ID: Sendable>(from entries: [SearchIndexEntry<ID>]) -> KindIndex<ID> {
        guard !entries.isEmpty else { return .empty }
        var ids: [ID] = []
        ids.reserveCapacity(entries.count)
        var offsets: [Int32] = []
        offsets.reserveCapacity(entries.count + 1)
        var primaryLengths: [Int32] = []
        primaryLengths.reserveCapacity(entries.count)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(entries.count * 32)

        var currentOffset: Int32 = 0
        offsets.append(currentOffset)

        for entry in entries {
            ids.append(entry.id)
            let bytes = Array(entry.key.utf8)
            buffer.append(contentsOf: bytes)
            currentOffset += Int32(bytes.count)
            offsets.append(currentOffset)
            let pLen = entry.primaryLength > 0 ? entry.primaryLength : Int32(bytes.count)
            primaryLengths.append(pLen)
        }

        return KindIndex(ids: ids, offsets: offsets, primaryLengths: primaryLengths, buffer: buffer)
    }

    public func updateIndex(searchEntries: LibrarySearchEntries, playlists: [Playlist] = [], context: SearchContext? = nil) {
        let gen = nextGeneration.withLock { g -> UInt64 in
            let cur = g
            g += 1
            return cur
        }

        var playlistEntries: [SearchIndexEntry<UUID>] = []
        playlistEntries.reserveCapacity(playlists.count)
        for pl in playlists {
            let key = Self.normalizeKey(pl.name)
            let primaryLen = Int32(key.utf8.count)
            playlistEntries.append(SearchIndexEntry(id: pl.id, key: key, primaryLength: primaryLen))
        }

        let newTracks = Self.buildKindIndex(from: searchEntries.tracks)
        let newAlbums = Self.buildKindIndex(from: searchEntries.albums)
        let newArtists = Self.buildKindIndex(from: searchEntries.artists)
        let newPlaylists = Self.buildKindIndex(from: playlistEntries)

        let newSnapshot = SearchSnapshot(
            generation: gen,
            tracks: newTracks,
            albums: newAlbums,
            artists: newArtists,
            playlists: newPlaylists,
            context: context
        )

        let didApply = indexLock.withLock { current -> Bool in
            guard gen >= current.generation else { return false }
            if newSnapshot.isEmpty && !current.isEmpty {
                AppLogger.library.warning("SearchEngine ignoring empty index update because current index has \(current.tracks.count) tracks.")
                return false
            }
            current = newSnapshot
            return true
        }

        if didApply {
            discographyLock.withLock { $0.removeAll() }
            incrementalLock.withLock { $0 = IncrementalSearchCache() }
            AppLogger.library.info("SearchEngine updated (gen: \(gen)): \(newTracks.count) tracks, \(newAlbums.count) albums, \(newArtists.count) artists.")
            if let context {
                scheduleNormalizedRebuild(
                    replacing: gen,
                    tracks: Array(context.tracksByID.values),
                    albums: Array(context.albumsByID.values),
                    artists: context.artists,
                    playlists: playlists,
                    context: context
                )
            }
        }
    }

    public func updateIndex(tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist] = [], context: SearchContext? = nil) {
        let gen = nextGeneration.withLock { g -> UInt64 in
            let cur = g
            g += 1
            return cur
        }

        var trackEntries: [SearchIndexEntry<UUID>] = []
        trackEntries.reserveCapacity(tracks.count)
        for t in tracks {
            let key = !t.searchTokens.isEmpty ? t.searchTokens : Self.normalizeKey("\(t.title) \(t.artist) \(t.album)")
            let primaryLen = Int32(Self.normalizeKey(t.title).utf8.count)
            trackEntries.append(SearchIndexEntry(id: t.id, key: key, primaryLength: primaryLen))
        }

        var albumEntries: [SearchIndexEntry<String>] = []
        albumEntries.reserveCapacity(albums.count)
        for a in albums {
            let key = !a.searchTokens.isEmpty ? a.searchTokens : Self.normalizeKey("\(a.title) \(a.artist)")
            let primaryLen = Int32(Self.normalizeKey(a.title).utf8.count)
            albumEntries.append(SearchIndexEntry(id: a.id, key: key, primaryLength: primaryLen))
        }

        var artistEntries: [SearchIndexEntry<String>] = []
        artistEntries.reserveCapacity(artists.count)
        for art in artists {
            let key = !art.searchTokens.isEmpty ? art.searchTokens : Self.normalizeKey(art.name)
            let primaryLen = Int32(Self.normalizeKey(art.name).utf8.count)
            artistEntries.append(SearchIndexEntry(id: art.id, key: key, primaryLength: primaryLen))
        }

        var playlistEntries: [SearchIndexEntry<UUID>] = []
        playlistEntries.reserveCapacity(playlists.count)
        for pl in playlists {
            let key = Self.normalizeKey(pl.name)
            let primaryLen = Int32(key.utf8.count)
            playlistEntries.append(SearchIndexEntry(id: pl.id, key: key, primaryLength: primaryLen))
        }

        let newTracks = Self.buildKindIndex(from: trackEntries)
        let newAlbums = Self.buildKindIndex(from: albumEntries)
        let newArtists = Self.buildKindIndex(from: artistEntries)
        let newPlaylists = Self.buildKindIndex(from: playlistEntries)

        let newSnapshot = SearchSnapshot(
            generation: gen,
            tracks: newTracks,
            albums: newAlbums,
            artists: newArtists,
            playlists: newPlaylists,
            context: context
        )

        let didApply = indexLock.withLock { current -> Bool in
            guard gen >= current.generation else { return false }
            if newSnapshot.isEmpty && !current.isEmpty {
                AppLogger.library.warning("SearchEngine ignoring empty index update because current index has \(current.tracks.count) tracks.")
                return false
            }
            current = newSnapshot
            return true
        }

        if didApply {
            discographyLock.withLock { $0.removeAll() }
            incrementalLock.withLock { $0 = IncrementalSearchCache() }
            AppLogger.library.info("SearchEngine updated (gen: \(gen)): \(newTracks.count) tracks, \(newAlbums.count) albums, \(newArtists.count) artists.")
            scheduleNormalizedRebuild(
                replacing: gen,
                tracks: tracks,
                albums: albums,
                artists: artists,
                playlists: playlists,
                context: context
            )
        }
    }

    // MARK: - Query: Flat Search

    public static func scoreMatch(
        query: String,
        key: String,
        primaryLen: Int,
        kindPriority: Int
    ) -> Int {
        // Inputs are already normalized by SearchNormalizer (query via normalizeQuery, keys via *SearchKey).
        let cleanQuery = query
        guard !cleanQuery.isEmpty else { return 0 }
        let cleanKey = key
        guard cleanKey.count >= cleanQuery.count else { return 0 }

        let qBytes = Array(cleanQuery.utf8)
        let kBytes = Array(cleanKey.utf8)
        let qLen = qBytes.count
        let kLen = kBytes.count
        let pLen = min(primaryLen, kLen)

        // Exact match of primary field
        if qLen == pLen && kBytes.starts(with: qBytes) {
            return 6 * 10_000_000 + (10_000 - min(pLen, 9_999)) * 100 + kindPriority
        }
        // Prefix of primary field
        if qLen < pLen && kBytes.starts(with: qBytes) {
            return 5 * 10_000_000 + (10_000 - min(pLen, 9_999)) * 100 + kindPriority
        }

        var bestTier = 0
        if qLen <= kLen {
            for offset in 0...(kLen - qLen) {
                var matches = true
                for qi in 0..<qLen {
                    if kBytes[offset + qi] != qBytes[qi] {
                        matches = false
                        break
                    }
                }
                if matches {
                    let isWordStart = (offset == 0 || kBytes[offset - 1] == 0x20)
                    let tier: Int
                    if offset < pLen {
                        tier = isWordStart ? 4 : 2
                    } else {
                        tier = isWordStart ? 3 : 1
                    }
                    bestTier = max(bestTier, tier)
                    if bestTier == 4 { break }
                }
            }
        }

        guard bestTier > 0 else { return 0 }
        return bestTier * 10_000_000 + (10_000 - min(pLen, 9_999)) * 100 + kindPriority
    }

    private func scanKind<ID: Sendable>(
        kind: KindIndex<ID>,
        candidateIndices: [Int]?,
        queryBytes: [UInt8],
        kindPriority: Int,
        maxResults: Int
    ) -> (topIDs: [ID], topScores: [Int], matchingIndices: [Int]) {
        guard kind.count > 0, !queryBytes.isEmpty, maxResults > 0 else { return ([], [], []) }
        let queryLen = queryBytes.count
        let firstByte = queryBytes[0]

        let buffer = kind.buffer
        let offsets = kind.offsets
        let primaryLengths = kind.primaryLengths
        let ids = kind.ids

        let topK = TopKBuffer<ID>(capacity: maxResults)
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(min(kind.count, 2048))

        buffer.withUnsafeBufferPointer { bufPtr in
            guard let baseBuf = bufPtr.baseAddress else { return }
            queryBytes.withUnsafeBufferPointer { qPtr in
                guard let baseQ = qPtr.baseAddress else { return }

                let indicesToScanCount = candidateIndices?.count ?? kind.count

                for step in 0..<indicesToScanCount {
                    if (step & 4095) == 0 && Task.isCancelled { break }

                    let i = candidateIndices?[step] ?? step
                    let start = Int(offsets[i])
                    let end = Int(offsets[i + 1])
                    let len = end - start
                    if len < queryLen { continue }

                    let primaryLen = (i < primaryLengths.count && primaryLengths[i] > 0) ? Int(primaryLengths[i]) : len
                    let entryPtr = baseBuf + start

                    var bestTier = 0

                    // 1. Prefix match check
                    if memcmp(entryPtr, baseQ, queryLen) == 0 {
                        if queryLen == primaryLen {
                            bestTier = 6
                        } else if queryLen < primaryLen {
                            bestTier = 5
                        } else {
                            bestTier = 4
                        }
                    } else {
                        // 2. Substring & word boundary search using memchr
                        var searchOffset = 0

                        while searchOffset <= len - queryLen {
                            let remainingLen = len - searchOffset
                            guard let matchRaw = memchr(entryPtr + searchOffset, Int32(firstByte), remainingLen) else {
                                break
                            }
                            let matchPtr = matchRaw.assumingMemoryBound(to: UInt8.self)
                            let matchOffset = entryPtr.distance(to: matchPtr)
                            if matchOffset + queryLen > len { break }

                            if memcmp(matchPtr, baseQ, queryLen) == 0 {
                                let isWordStart = (matchOffset == 0 || entryPtr[matchOffset - 1] == 0x20)
                                let tier: Int
                                if matchOffset < primaryLen {
                                    tier = isWordStart ? 4 : 2
                                } else {
                                    tier = isWordStart ? 3 : 1
                                }
                                bestTier = max(bestTier, tier)
                                if bestTier == 4 { break }
                            }
                            searchOffset = matchOffset + 1
                        }
                    }

                    if bestTier > 0 {
                        let score = bestTier * 10_000_000 + (10_000 - min(primaryLen, 9_999)) * 100 + kindPriority
                        topK.insert(id: ids[i], score: score, index: i)
                        matchedIndices.append(i)
                    }
                }
            }
        }

        let sorted = topK.sortedItems()
        return (sorted.map { $0.id }, sorted.map { $0.score }, matchedIndices)
    }

    private func fallbackScanContext(
        query: String,
        context: SearchContext,
        maxTrackResults: Int,
        maxAlbumResults: Int,
        maxArtistResults: Int,
        maxPlaylistResults: Int
    ) -> FlatSearchResults {
        let clean = Self.normalizeQuery(query)
        guard !clean.isEmpty else { return .empty }

        var scoredTracks: [(id: UUID, score: Int)] = []
        for (id, t) in context.tracksByID {
            let k = Self.trackSearchKey(t)
            let s = Self.scoreMatch(query: clean, key: k.key, primaryLen: Int(k.primaryLength), kindPriority: 1)
            if s > 0 {
                scoredTracks.append((id, s))
            }
        }
        scoredTracks.sort { $0.score > $1.score }
        let topTracks = Array(scoredTracks.prefix(maxTrackResults))

        var scoredAlbums: [(id: String, score: Int)] = []
        for (id, a) in context.albumsByID {
            let k = Self.albumSearchKey(a)
            let s = Self.scoreMatch(query: clean, key: k.key, primaryLen: Int(k.primaryLength), kindPriority: 2)
            if s > 0 {
                scoredAlbums.append((id, s))
            }
        }
        scoredAlbums.sort { $0.score > $1.score }
        let topAlbums = Array(scoredAlbums.prefix(maxAlbumResults))

        var scoredArtists: [(id: String, score: Int)] = []
        for art in context.artists {
            let k = Self.artistSearchKey(art)
            let s = Self.scoreMatch(query: clean, key: k.key, primaryLen: Int(k.primaryLength), kindPriority: 3)
            if s > 0 {
                scoredArtists.append((art.id, s))
            }
        }
        scoredArtists.sort { $0.score > $1.score }
        let topArtists = Array(scoredArtists.prefix(maxArtistResults))

        var scoredPlaylists: [(id: UUID, score: Int)] = []
        for pl in context.playlists {
            let k = Self.playlistSearchKey(pl)
            let s = Self.scoreMatch(query: clean, key: k.key, primaryLen: Int(k.primaryLength), kindPriority: 0)
            if s > 0 {
                scoredPlaylists.append((pl.id, s))
            }
        }
        scoredPlaylists.sort { $0.score > $1.score }
        let topPlaylists = Array(scoredPlaylists.prefix(maxPlaylistResults))

        Task.detached(priority: .utility) { [weak self] in
            self?.updateIndex(
                tracks: Array(context.tracksByID.values),
                albums: Array(context.albumsByID.values),
                artists: context.artists,
                playlists: context.playlists,
                context: context
            )
        }

        return FlatSearchResults(
            trackIDs: topTracks.map { $0.id },
            albumIDs: topAlbums.map { $0.id },
            artistIDs: topArtists.map { $0.id },
            playlistIDs: topPlaylists.map { $0.id },
            trackScores: topTracks.map { $0.score },
            albumScores: topAlbums.map { $0.score },
            artistScores: topArtists.map { $0.score },
            playlistScores: topPlaylists.map { $0.score }
        )
    }

    private func executeSearchFlat(
        query: String,
        maxTrackResults: Int = 200,
        maxAlbumResults: Int = 50,
        maxArtistResults: Int = 50,
        maxPlaylistResults: Int = 50
    ) -> FlatSearchResults {
        guard !Task.isCancelled else { return .empty }
        // Q7: fewer than 2 normalized grapheme clusters runs no search.
        guard SearchNormalizer.meetsMinimumLength(query) else { return .empty }
        let cleanQuery = Self.normalizeQuery(query)
        guard !cleanQuery.isEmpty else { return .empty }

        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("flatScan", id: signpostID)
        defer { signposter.endInterval("flatScan", interval) }

        let snapshot = indexLock.withLock { $0 }
        if snapshot.isEmpty {
            if let ctx = snapshot.context, !ctx.tracksByID.isEmpty {
                return fallbackScanContext(
                    query: cleanQuery,
                    context: ctx,
                    maxTrackResults: maxTrackResults,
                    maxAlbumResults: maxAlbumResults,
                    maxArtistResults: maxArtistResults,
                    maxPlaylistResults: maxPlaylistResults
                )
            }
            return .empty
        }

        if Self.useTokenIndex, let tokenIndex = snapshot.tokenIndex {
            let r = tokenIndex.search(query, limits: SearchTokenLimits(
                tracks: maxTrackResults, albums: maxAlbumResults, artists: maxArtistResults, playlists: maxPlaylistResults))
            guard !r.cancelled, !Task.isCancelled else { return .empty }
            tokenResultCache.withLock { $0 = (snapshot.generation, query, r) }
            return FlatSearchResults(
                trackIDs: r.tracks.ids,
                albumIDs: r.albums.ids,
                artistIDs: r.artists.ids,
                playlistIDs: r.playlists.ids,
                trackScores: r.tracks.scores,
                albumScores: r.albums.scores,
                artistScores: r.artists.scores,
                playlistScores: r.playlists.scores,
                isTokenRanked: true,
                artistWholeExact: r.artists.wholeExact
            )
        }

        let queryBytes = Array(cleanQuery.utf8)
        guard !queryBytes.isEmpty else { return .empty }

        let (canNarrow, prevCache) = incrementalLock.withLock { cache -> (Bool, IncrementalSearchCache) in
            let narrow = (cache.generation == snapshot.generation &&
                          !cache.query.isEmpty &&
                          cleanQuery.hasPrefix(cache.query))
            return (narrow, cache)
        }

        let candidateTrackIndices = canNarrow ? prevCache.trackIndices : nil
        let candidateAlbumIndices = canNarrow ? prevCache.albumIndices : nil
        let candidateArtistIndices = canNarrow ? prevCache.artistIndices : nil
        let candidatePlaylistIndices = canNarrow ? prevCache.playlistIndices : nil

        let (trackIDs, trackScores, newTrackIndices) = scanKind(
            kind: snapshot.tracks,
            candidateIndices: candidateTrackIndices,
            queryBytes: queryBytes,
            kindPriority: 1,
            maxResults: maxTrackResults
        )
        guard !Task.isCancelled else { return .empty }

        let (albumIDs, albumScores, newAlbumIndices) = scanKind(
            kind: snapshot.albums,
            candidateIndices: candidateAlbumIndices,
            queryBytes: queryBytes,
            kindPriority: 2,
            maxResults: maxAlbumResults
        )
        guard !Task.isCancelled else { return .empty }

        let (artistIDs, artistScores, newArtistIndices) = scanKind(
            kind: snapshot.artists,
            candidateIndices: candidateArtistIndices,
            queryBytes: queryBytes,
            kindPriority: 3,
            maxResults: maxArtistResults
        )
        guard !Task.isCancelled else { return .empty }

        let (playlistIDs, playlistScores, newPlaylistIndices) = scanKind(
            kind: snapshot.playlists,
            candidateIndices: candidatePlaylistIndices,
            queryBytes: queryBytes,
            kindPriority: 0,
            maxResults: maxPlaylistResults
        )
        guard !Task.isCancelled else { return .empty }

        incrementalLock.withLock { cache in
            cache = IncrementalSearchCache(
                query: cleanQuery,
                generation: snapshot.generation,
                trackIndices: newTrackIndices,
                albumIndices: newAlbumIndices,
                artistIndices: newArtistIndices,
                playlistIndices: newPlaylistIndices
            )
        }

        return FlatSearchResults(
            trackIDs: trackIDs,
            albumIDs: albumIDs,
            artistIDs: artistIDs,
            playlistIDs: playlistIDs,
            trackScores: trackScores,
            albumScores: albumScores,
            artistScores: artistScores,
            playlistScores: playlistScores
        )
    }

    nonisolated public func searchFlat(
        query: String,
        maxTrackResults: Int = 200,
        maxAlbumResults: Int = 50,
        maxArtistResults: Int = 50,
        maxPlaylistResults: Int = 50
    ) -> FlatSearchResults {
        executeSearchFlat(
            query: query,
            maxTrackResults: maxTrackResults,
            maxAlbumResults: maxAlbumResults,
            maxArtistResults: maxArtistResults,
            maxPlaylistResults: maxPlaylistResults
        )
    }

    nonisolated public func searchFlat(
        query: String,
        maxTrackResults: Int = 200,
        maxAlbumResults: Int = 50,
        maxArtistResults: Int = 50,
        maxPlaylistResults: Int = 50
    ) async -> FlatSearchResults {
        await Task.detached(priority: .userInitiated) {
            self.executeSearchFlat(
                query: query,
                maxTrackResults: maxTrackResults,
                maxAlbumResults: maxAlbumResults,
                maxArtistResults: maxArtistResults,
                maxPlaylistResults: maxPlaylistResults
            )
        }.value
    }

    nonisolated public func searchFlat(
        query: String,
        maxResults: Int
    ) async -> FlatSearchResults {
        await searchFlat(
            query: query,
            maxTrackResults: maxResults,
            maxAlbumResults: min(maxResults, 50),
            maxArtistResults: min(maxResults, 50),
            maxPlaylistResults: min(maxResults, 50)
        )
    }

    // MARK: - Query: Full Structured Search (GlobalSearchView)

    nonisolated public func search(
        query: String,
        tracksByID: [UUID: Track] = [:],
        albumsByID: [String: Album] = [:],
        artists: [Artist] = [],
        artistLookupIndex: [String: Artist] = [:],
        playlists: [Playlist] = [],
        joinedArtists: [String] = [],
        maxTrackResults: Int = 80,
        maxAlbumResults: Int = 40,
        maxArtistResults: Int = 40
    ) async -> GlobalSearchResults {
        guard !Task.isCancelled else { return .empty }
        // Q7: fewer than 2 normalized grapheme clusters runs no search.
        guard SearchNormalizer.meetsMinimumLength(query) else { return .empty }
        let cleanQuery = Self.normalizeQuery(query)
        guard !cleanQuery.isEmpty else { return .empty }

        return await Task.detached(priority: .userInitiated) { () -> GlobalSearchResults in
            let startTime = DispatchTime.now()
            let signpostID = self.signposter.makeSignpostID()
            let overallInterval = self.signposter.beginInterval("search", id: signpostID)
            defer { self.signposter.endInterval("search", overallInterval) }

            let scanInterval = self.signposter.beginInterval("scan", id: signpostID)
            let flat = self.executeSearchFlat(
                query: query,
                maxTrackResults: maxTrackResults,
                maxAlbumResults: maxAlbumResults,
                maxArtistResults: maxArtistResults,
                maxPlaylistResults: 50
            )
            self.signposter.endInterval("scan", scanInterval)

            guard !Task.isCancelled else { return .empty }

            let rankInterval = self.signposter.beginInterval("rank", id: signpostID)
            self.signposter.endInterval("rank", rankInterval)

            let treeInterval = self.signposter.beginInterval("tree", id: signpostID)
            let snapshot = self.indexLock.withLock { $0 }
            let results = self.buildSearchResults(
                cleanQuery: cleanQuery,
                flat: flat,
                context: snapshot.context,
                snapshot: snapshot,
                maxTrackResults: maxTrackResults,
                maxAlbumResults: maxAlbumResults,
                maxArtistResults: maxArtistResults
            )
            self.signposter.endInterval("tree", treeInterval)

            let publishInterval = self.signposter.beginInterval("publish", id: signpostID)
            self.signposter.endInterval("publish", publishInterval)

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            AppLogger.library.debug("Search '\(cleanQuery)' completed in \(String(format: "%.2f", elapsedMs))ms: \(results.matchedTracks.count) tracks, \(results.matchedAlbums.count) albums, \(results.artistTreeNodes.count) artists.")

            return results
        }.value
    }

    // MARK: - Tree Assembly from Models

    private func buildSearchResults(
        cleanQuery: String,
        flat: FlatSearchResults,
        context: SearchContext?,
        snapshot: SearchSnapshot,
        maxTrackResults: Int,
        maxAlbumResults: Int,
        maxArtistResults: Int
    ) -> GlobalSearchResults {
        guard let ctx = context else { return .empty }
        let lookup = albumLookup(for: snapshot, context: ctx)
        let tracksByID = ctx.tracksByID
        let albumsByID = ctx.albumsByID
        let artistLookupIndex = ctx.artistLookupIndex
        let playlists = ctx.playlists
        let joinedArtists = ctx.joinedArtists

        // 1. Direct Tracks
        var directMatchedTracks: [SearchTreeTrackNode] = []
        directMatchedTracks.reserveCapacity(min(flat.trackIDs.count, maxTrackResults))
        var matchedTrackScores: [UUID: Int] = [:]

        for (rank, id) in flat.trackIDs.prefix(maxTrackResults).enumerated() {
            guard let track = tracksByID[id] else { continue }
            let score = rank < flat.trackScores.count ? flat.trackScores[rank] : (10_000 - rank * 10)
            matchedTrackScores[track.id] = score
            directMatchedTracks.append(SearchTreeTrackNode(
                id: track.id.uuidString,
                track: track,
                isDirectlyMatched: true,
                relevanceScore: score
            ))
        }

        // 2. Direct Albums
        var directMatchedAlbums: [(album: Album, artist: Artist)] = []
        directMatchedAlbums.reserveCapacity(min(flat.albumIDs.count, maxAlbumResults))
        var matchedAlbumScores: [String: Int] = [:]

        for (rank, id) in flat.albumIDs.prefix(maxAlbumResults).enumerated() {
            guard let album = albumsByID[id] else { continue }
            let score = rank < flat.albumScores.count ? flat.albumScores[rank] : (80_000 - rank * 50)
            matchedAlbumScores[album.id] = score
            let primaryArtist = Self.resolveCreditedArtist(
                credit: album.artist, title: album.title,
                holds: { $0.albums.contains { $0.id == album.id } },
                artistLookupIndex: artistLookupIndex, lookup: lookup,
                serverCreditNames: album.albumArtistKeys ?? [])
                ?? Artist(name: album.artist, albums: [album])
            directMatchedAlbums.append((album: album, artist: primaryArtist))
        }

        // 3. Direct Playlists
        var matchedPlaylists: [Playlist] = []
        let pMap = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in flat.playlistIDs {
            guard let pl = pMap[id] else { continue }
            matchedPlaylists.append(pl)
        }

        // 4. Artists & Tree Assembly
        var matchedArtistScores: [String: Int] = [:]
        var artistEntities: [Artist] = []
        var seenArtistIDs = Set<String>()

        for (rank, id) in flat.artistIDs.prefix(maxArtistResults).enumerated() {
            let score = rank < flat.artistScores.count ? flat.artistScores[rank] : (100_000 - rank * 100)
            matchedArtistScores[id] = score
            if let art = artistLookupIndex[id] ?? lookup.artistsByID[id] {
                if seenArtistIDs.insert(art.id).inserted {
                    artistEntities.append(art)
                }
            }
        }

        for (_, primaryArtist) in directMatchedAlbums {
            if seenArtistIDs.insert(primaryArtist.id).inserted {
                artistEntities.append(primaryArtist)
            }
        }

        var trackOwnerIDs = Set<String>()
        for node in directMatchedTracks {
            let track = node.track
            let artist = Self.resolveCreditedArtist(
                credit: track.artist, title: track.title,
                holds: { $0.albums.contains { $0.tracks.contains { $0.id == track.id } } },
                artistLookupIndex: artistLookupIndex, lookup: lookup)
            if let artist { trackOwnerIDs.insert(artist.id) }
            if let artist, seenArtistIDs.insert(artist.id).inserted {
                artistEntities.append(artist)
            }
        }

        var artistRelevanceScores: [String: Int] = [:]
        var expansionHint: SearchExpansionHint? = nil
        var topHit: TopHitInfo? = nil
        if flat.isTokenRanked {
            let ranked = Self.tokenRankArtists(
                artistEntities, flat: flat, matchedArtistScores: matchedArtistScores,
                matchedAlbumScores: matchedAlbumScores, matchedTrackScores: matchedTrackScores,
                directMatchedAlbums: directMatchedAlbums, directMatchedTracks: directMatchedTracks,
                artistLookupIndex: artistLookupIndex, lookup: lookup,
                cleanQuery: cleanQuery, joinedArtists: joinedArtists)
            artistEntities = ranked.artists
            artistRelevanceScores = ranked.relevance
            expansionHint = ranked.hint
            topHit = ranked.top
        }
        for artist in artistEntities where !flat.isTokenRanked {
            let ownArtistScore = matchedArtistScores[artist.id] ?? 0
            var bestAlbumScore = 0
            var bestTrackScore = 0
            for album in artist.albums {
                if let aScore = matchedAlbumScores[album.id] {
                    bestAlbumScore = max(bestAlbumScore, aScore)
                }
                for track in album.tracks {
                    if let tScore = matchedTrackScores[track.id] {
                        bestTrackScore = max(bestTrackScore, tScore)
                    }
                }
            }
            let relevance = max(ownArtistScore, bestAlbumScore, bestTrackScore, 10)
            artistRelevanceScores[artist.id] = relevance
        }

        if !flat.isTokenRanked {
        artistEntities.sort {
            let r0 = artistRelevanceScores[$0.id] ?? 0
            let r1 = artistRelevanceScores[$1.id] ?? 0
            if r0 != r1 {
                return r0 > r1
            }
            return $0.normalizedName < $1.normalizedName
        }
        }

        var artistTreeNodes: [SearchTreeArtistNode] = []
        var seenArtistNodeIDs = Set<String>()

        let treeArtists = Self.treeArtists(artistEntities, cap: maxArtistResults, trackOwnerIDs: trackOwnerIDs)
        for (idx, artist) in treeArtists.enumerated() {
            let artistNodeID = artist.id
            guard seenArtistNodeIDs.insert(artistNodeID).inserted else { continue }

            let isTopArtist = (idx == 0)
            let artistScore = matchedArtistScores[artist.id] ?? 0
            let isArtistDirectlyMatched = artistScore > 0

            if isTopArtist {
                // §2: an album or track top hit lists only matching albums (each with all its tracks, D8), in D3 order;
                // an artist top hit (D4) or the legacy scanner keeps the full discography.
                let matchedOnly = topHit.map { $0.kind != .artist } ?? false
                let minScore = matchedOnly && (topHit?.score ?? 0) >= SearchRanking.unit ? SearchRanking.unit : 1
                let node = buildArtistNode(
                    artist: artist,
                    cleanQuery: cleanQuery,
                    directArtistScore: artistScore,
                    matchedAlbumScores: matchedAlbumScores,
                    matchedTrackScores: matchedTrackScores,
                    tracksByID: tracksByID,
                    joinedArtists: joinedArtists,
                    scope: matchedOnly ? .matchedOnly : .full,
                    minScore: minScore,
                    matchedTracksOnly: matchedOnly && topHit?.kind == .track
                )
                // A matched-only top artist whose discography shows none of the matches would be an empty row that
                // hides the album and song results; skip it so the direct results render instead.
                if matchedOnly, node.albums.isEmpty {
                    if expansionHint?.artistID == artist.id { expansionHint = nil }
                    if topHit?.soleArtist == true { break }
                    continue
                }
                artistTreeNodes.append(node)
                // §6b / D1 / D3: open the topmost album that holds the match; flag the best matched track in it.
                if matchedOnly, let hint = expansionHint, hint.artistID == artist.id, let first = node.albums.first {
                    expansionHint = SearchExpansionHint(artistID: hint.artistID, albumID: first.album.id,
                                                        suppress: hint.suppress,
                                                        isSongOrAlbumHit: true)
                }
                if topHit?.soleArtist == true { break }
            } else {
                let totalRelevance = artistRelevanceScores[artist.id] ?? max(artistScore, 10)
                artistTreeNodes.append(SearchTreeArtistNode(
                    id: artistNodeID,
                    artist: artist,
                    albums: [],
                    isDirectlyMatched: isArtistDirectlyMatched,
                    relevanceScore: totalRelevance
                ))
            }
        }

        // Token engine: artistEntities is already in final order (top hit first); keep it.
        if !flat.isTokenRanked {
        artistTreeNodes.sort {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.artist.normalizedName < $1.artist.normalizedName
        }
        }

        let cappedTracks = Array(directMatchedTracks.prefix(maxTrackResults))
        let trackCategoryNodes = Self.buildTrackCategoryNodes(tracks: cappedTracks, lookup: lookup, context: ctx)

        return GlobalSearchResults(
            artistTreeNodes: artistTreeNodes,
            playlists: matchedPlaylists,
            directMatchedAlbums: Array(directMatchedAlbums.prefix(maxAlbumResults)),
            directMatchedTracks: cappedTracks,
            trackCategoryNodes: trackCategoryNodes,
            query: cleanQuery,
            expansionHint: expansionHint,
            unresolvedTracks: Self.unresolvedTracks(cappedTracks, artistLookupIndex: artistLookupIndex, lookup: lookup)
        )
    }

    /// D13(c): the first `cap` artists in rank order, then any later artist that owns a matched song
    /// (collapsed header only; its children are built on expand), so no song falls out of the tree.
    nonisolated static func treeArtists(_ ranked: [Artist], cap: Int, trackOwnerIDs: Set<String>) -> [Artist] {
        var seen = Set<String>()
        var out: [Artist] = []
        for (i, a) in ranked.enumerated() where (i < cap || trackOwnerIDs.contains(a.id)) && seen.insert(a.id).inserted {
            out.append(a)
        }
        return out
    }

    /// D13(a): expanding an artist in the main tree shows only its matches when it has any;
    /// an artist matched by name only keeps its full discography.
    nonisolated static func expandScope(matchedAlbums: Int, matchedTracks: Int) -> SearchNodeScope {
        matchedAlbums + matchedTracks > 0 ? .matchedOnly : .full
    }

    /// D13(b): matched songs that cannot be placed under a library artist album after credit splitting.
    nonisolated static func unresolvedTracks(_ nodes: [SearchTreeTrackNode], artistLookupIndex: [String: Artist],
                                             lookup: SearchAlbumLookup) -> [SearchTreeTrackNode] {
        nodes.filter { node in
            let track = node.track
            let holds: (Artist) -> Bool = { $0.albums.contains { $0.tracks.contains { $0.id == track.id } } }
            guard let artist = resolveCreditedArtist(credit: track.artist, title: track.title, holds: holds,
                                                     artistLookupIndex: artistLookupIndex, lookup: lookup) else { return true }
            return !holds(artist)
        }
    }

    /// Token-engine artist order and top hit (plan §3.4 artist rank, §3.5 auto-expand).
    /// Library artist for a track or album credit. Tries the whole credit first, then each parsed artist
    /// ("A & B", "A, B", "A feat. B", title "(feat. B)"); prefers the one whose discography holds the release.
    /// `serverCreditNames` (a server album's album-artist keys) are tried first, in server order.
    /// Returns nil when no candidate's discography holds the release, so callers never attach a release to an
    /// artist row that cannot show it.
    nonisolated static func resolveCreditedArtist(credit: String, title: String, holds: (Artist) -> Bool,
                                      artistLookupIndex: [String: Artist], lookup: SearchAlbumLookup,
                                      serverCreditNames: [String] = []) -> Artist? {
        func find(_ name: String) -> Artist? {
            artistLookupIndex[ArtistParser.canonicalArtistKey(name)]
                ?? artistLookupIndex[name.lowercased()]
                ?? lookup.artistsByID[ArtistParser.canonicalArtistKey(name)]
        }
        var names = serverCreditNames
        if !names.contains(credit) { names.append(credit) }
        for n in ArtistParser.allArtists(forTitle: title, artist: credit) where !names.contains(n) { names.append(n) }
        for name in names {
            if let artist = find(name), holds(artist) { return artist }
        }
        return nil
    }

    private static func tokenRankArtists(
        _ entities: [Artist],
        flat: FlatSearchResults,
        matchedArtistScores: [String: Int],
        matchedAlbumScores: [String: Int],
        matchedTrackScores: [UUID: Int],
        directMatchedAlbums: [(album: Album, artist: Artist)],
        directMatchedTracks: [SearchTreeTrackNode],
        artistLookupIndex: [String: Artist],
        lookup: SearchAlbumLookup,
        cleanQuery: String,
        joinedArtists: [String]
    ) -> (artists: [Artist], relevance: [String: Int], hint: SearchExpansionHint?, top: TopHitInfo?) {
        let unit = 10_000_000
        func split(_ s: Int) -> (bucket: Int, final: Int) { (s / unit, s % unit) }

        // artistRank = max(ownName, 0.85 × bestAlbum, 0.70 × bestTrack), by bucket first;
        // an own-name match in the winning bucket beats an artist pulled in by an album or song.
        struct Rank { let bucket: Int; let own: Bool; let final: Int }
        var ranks: [String: Rank] = [:]
        var relevance: [String: Int] = [:]
        for artist in entities {
            let own = matchedArtistScores[artist.id] ?? 0
            var bestAlbum = 0, bestTrack = 0
            for album in artist.albums {
                if let a = matchedAlbumScores[album.id] { bestAlbum = max(bestAlbum, a) }
                for track in album.tracks {
                    if let t = matchedTrackScores[track.id] { bestTrack = max(bestTrack, t) }
                }
            }
            var cands: [(bucket: Int, final: Int)] = []
            if own > 0 { cands.append(split(own)) }
            if bestAlbum > 0 { let s = split(bestAlbum); cands.append((s.bucket, Int(Double(s.final) * 0.85))) }
            if bestTrack > 0 { let s = split(bestTrack); cands.append((s.bucket, Int(Double(s.final) * 0.70))) }
            let best = cands.max { $0.bucket != $1.bucket ? $0.bucket < $1.bucket : $0.final < $1.final } ?? (0, 0)
            let ownWins = own > 0 && split(own).bucket == best.bucket
            ranks[artist.id] = Rank(bucket: best.bucket, own: ownWins, final: best.final)
            relevance[artist.id] = max(best.bucket * unit + best.final, 10)
        }
        var ordered = entities.sorted { a, b in
            let ra = ranks[a.id] ?? Rank(bucket: 0, own: false, final: 0)
            let rb = ranks[b.id] ?? Rank(bucket: 0, own: false, final: 0)
            if ra.bucket != rb.bucket { return ra.bucket > rb.bucket }
            if ra.own != rb.own { return ra.own }
            if ra.final != rb.final { return ra.final > rb.final }
            return a.normalizedName < b.normalizedName
        }

        // Top hit across kinds (§3.3, D4); playlists are not expandable and are ignored.
        enum Hit { case artist(String), album(Int), track(Int) }
        var hits: [(hit: Hit, score: Int)] = []
        var cands: [SearchRanking.HitCandidate] = []
        let queryTokens = SearchNormalizer.rawTokens(cleanQuery)
        // §3.1 artist + song: ×1.2 at coverage 1.0 when the query is "<whole artist name> <title terms>" (or reversed).
        var intentArtistIDs: [Int: String] = [:]
        func intentBoost(_ score: Int, title: String, artistName: String, artistID: String?, hitIndex: Int) -> Int {
            let artistTokens = SearchNormalizer.rawTokens(artistName)
            guard let artistID, let rest = SearchRanking.artistSongRest(queryTokens: queryTokens, artistTokens: artistTokens),
                  SearchRanking.titleCovers(rest, title: title) else { return score }
            let s = split(score)
            let coverage = 0.6 + 0.4 * Double(rest.count) / Double(max(queryTokens.count, 1))
            intentArtistIDs[hitIndex] = artistID
            return s.bucket * unit + min(Int(Double(s.final) / coverage * 1.2), unit - 1)
        }
        func artistFor(name: String) -> Artist? {
            artistLookupIndex[ArtistParser.canonicalArtistKey(name)]
                ?? artistLookupIndex[name.lowercased()]
                ?? lookup.artistsByID[ArtistParser.canonicalArtistKey(name)]
        }
        func trackArtist(_ track: Track) -> Artist? {
            resolveCreditedArtist(credit: track.artist, title: track.title,
                                  holds: { $0.albums.contains { $0.tracks.contains { $0.id == track.id } } },
                                  artistLookupIndex: artistLookupIndex, lookup: lookup)
        }
        // Scores come from the node itself so a skipped (unresolvable) ID cannot shift scores onto other results.
        for (i, node) in directMatchedTracks.prefix(2).enumerated() {
            let track = node.track
            let s = node.relevanceScore
            let boosted = intentBoost(s, title: track.title, artistName: track.artist, artistID: trackArtist(track)?.id, hitIndex: hits.count)
            hits.append((.track(i), boosted))
            cands.append(.init(kind: .track, score: boosted))
        }
        for (i, pair) in directMatchedAlbums.prefix(2).enumerated() {
            let s = matchedAlbumScores[pair.album.id] ?? 0
            let boosted = intentBoost(s, title: pair.album.title, artistName: pair.artist.name, artistID: pair.artist.id, hitIndex: hits.count)
            hits.append((.album(i), boosted))
            cands.append(.init(kind: .album, score: boosted))
        }
        for (i, id) in flat.artistIDs.prefix(2).enumerated() where i < flat.artistScores.count {
            hits.append((.artist(id), flat.artistScores[i]))
            cands.append(.init(kind: .artist, score: flat.artistScores[i],
                               wholeExactArtist: i < flat.artistWholeExact.count && flat.artistWholeExact[i]))
        }
        // D4: an artist whose whole name equals the query wins even beyond the top 2.
        if !cands.contains(where: { $0.wholeExactArtist }),
           let i = flat.artistWholeExact.firstIndex(of: true), i < flat.artistIDs.count, i < flat.artistScores.count {
            hits.append((.artist(flat.artistIDs[i]), flat.artistScores[i]))
            cands.append(.init(kind: .artist, score: flat.artistScores[i], wholeExactArtist: true))
        }
        guard let topIndex = SearchRanking.pickTopHit(cands) else { return (ordered, relevance, nil, nil) }
        let top = hits[topIndex]
        let soleArtistID = intentArtistIDs[topIndex]
        // No expansion when the top hit is fuzzy-only and leads the runner-up by less than 0.10.
        let runner = hits.indices.filter { $0 != topIndex }.map { hits[$0].score }.max()
        let suppress = SearchRanking.isNearTie(top: top.score, runner: runner)

        var topArtist: Artist?
        var albumID: String?
        var kind = SearchRanking.HitKind.artist
        switch top.hit {
        case .artist(let id):
            topArtist = entities.first { $0.id == id } ?? artistLookupIndex[id] ?? lookup.artistsByID[id]
            if let artist = topArtist {
                // Expand the best album only if an album or track of this artist matched directly.
                var bestAlbum: (id: String, score: Int)?
                for album in artist.albums {
                    if let s = matchedAlbumScores[album.id], s > (bestAlbum?.score ?? 0) { bestAlbum = (album.id, s) }
                }
                if bestAlbum == nil {
                    var bestTrackAlbum: (id: String, score: Int)?
                    for album in artist.albums {
                        for track in album.tracks {
                            if let s = matchedTrackScores[track.id], s > (bestTrackAlbum?.score ?? 0) { bestTrackAlbum = (album.id, s) }
                        }
                    }
                    bestAlbum = bestTrackAlbum
                }
                albumID = bestAlbum?.id
            }
        case .album(let i):
            kind = .album
            topArtist = directMatchedAlbums[i].artist
            albumID = directMatchedAlbums[i].album.id
        case .track(let i):
            kind = .track
            let track = directMatchedTracks[i].track
            topArtist = trackArtist(track)
            // D9: a song on another artist's album, credited to a featured artist, is led by the featured artist
            // (that album sits under their FEATURED ON; their own releases of the song still rank first by D3).
            for name in ArtistParser.allArtists(forTitle: track.title, artist: track.artist) {
                guard let candidate = artistFor(name: name),
                      let album = candidate.albums.first(where: { $0.tracks.contains(where: { $0.id == track.id }) }),
                      album.isFeaturedAlbum(for: candidate.name, joinedArtists: joinedArtists) else { continue }
                topArtist = candidate
                break
            }
            // The D3 topmost album is chosen once the matched-only node is built.
            albumID = topArtist?.albums.first(where: { $0.tracks.contains(where: { $0.id == track.id }) })?.id
        }
        guard let artist = topArtist else { return (ordered, relevance, nil, nil) }
        // Put the top-hit artist first.
        if let idx = ordered.firstIndex(where: { $0.id == artist.id }) {
            let a = ordered.remove(at: idx)
            ordered.insert(a, at: 0)
        } else {
            ordered.insert(artist, at: 0)
            relevance[artist.id] = max(top.score, 10)
        }
        let info = TopHitInfo(kind: kind, score: top.score, soleArtist: soleArtistID == artist.id)
        return (ordered, relevance, SearchExpansionHint(artistID: artist.id, albumID: albumID, suppress: suppress), info)
    }

    /// Top-hit facts that shape the top artist node (not part of the published results).
    nonisolated struct TopHitInfo: Sendable {
        let kind: SearchRanking.HitKind
        let score: Int
        /// §3.1 artist + song intent: show only this artist.
        let soleArtist: Bool
    }

    /// Groups matched tracks into artist -> album nodes for the TRACKS category (previously built in the view body).
    private static func buildTrackCategoryNodes(
        tracks: [SearchTreeTrackNode],
        lookup: SearchAlbumLookup,
        context ctx: SearchContext
    ) -> [SearchTreeArtistNode] {
        var orderedArtistKeys: [String] = []
        var artistKeyToArtist: [String: Artist] = [:]
        var artistKeyToOrderedAlbumKeys: [String: [String]] = [:]
        var albumKeyToAlbum: [String: Album] = [:]
        var albumKeyToTracks: [String: [SearchTreeTrackNode]] = [:]

        for trackNode in tracks {
            let track = trackNode.track
            let artistName = track.artist.isEmpty ? "Unknown Artist" : track.artist
            let artistKey = ArtistParser.canonicalArtistKey(artistName)
            let albumTitle = track.album.isEmpty ? "Singles" : track.album
            let albumKey = "\(artistKey)_\(albumTitle.lowercased())"

            if artistKeyToArtist[artistKey] == nil {
                artistKeyToArtist[artistKey] = lookup.resolveArtist(name: artistName, context: ctx)
                    ?? Artist(name: artistName, albums: [])
                orderedArtistKeys.append(artistKey)
                artistKeyToOrderedAlbumKeys[artistKey] = []
            }

            if albumKeyToAlbum[albumKey] == nil {
                albumKeyToAlbum[albumKey] = lookup.resolveAlbum(title: albumTitle, artist: artistName, context: ctx)
                    ?? Album(title: albumTitle, artist: artistName, tracks: [track])
                artistKeyToOrderedAlbumKeys[artistKey]?.append(albumKey)
                albumKeyToTracks[albumKey] = []
            }

            albumKeyToTracks[albumKey]?.append(trackNode)
        }

        var nodes: [SearchTreeArtistNode] = []
        nodes.reserveCapacity(orderedArtistKeys.count)
        for artistKey in orderedArtistKeys {
            guard let artist = artistKeyToArtist[artistKey],
                  let albumKeys = artistKeyToOrderedAlbumKeys[artistKey] else { continue }
            var albumNodes: [SearchTreeAlbumNode] = []
            for albKey in albumKeys {
                guard let album = albumKeyToAlbum[albKey],
                      let trks = albumKeyToTracks[albKey] else { continue }
                albumNodes.append(SearchTreeAlbumNode(
                    id: "synth_album_\(albKey)",
                    album: album,
                    tracks: trks,
                    isDirectlyMatched: true,
                    relevanceScore: trks.map { $0.relevanceScore }.max() ?? 50_000,
                    category: {
                        switch DiscographyClassifier.releaseSection(for: album) {
                        case .singlesAndEPs: return .singles
                        case .alternates: return .alternates
                        default: return .albums
                        }
                    }()
                ))
            }
            nodes.append(SearchTreeArtistNode(
                id: "synth_artist_\(artistKey)",
                artist: artist,
                albums: albumNodes,
                isDirectlyMatched: true,
                relevanceScore: albumNodes.map { $0.relevanceScore }.max() ?? 50_000
            ))
        }
        return nodes
    }

    nonisolated public func expandArtist(artistID: String, query: String) -> SearchTreeArtistNode? {
        let snapshot = indexLock.withLock { $0 }
        guard let ctx = snapshot.context else { return nil }
        guard let artist = ctx.artistLookupIndex[artistID]
            ?? albumLookup(for: snapshot, context: ctx).artistsByID[artistID] else {
            return nil
        }
        let cleanQuery = SearchNormalizer.meetsMinimumLength(query) ? Self.normalizeQuery(query) : ""
        let joinedArtists = ctx.joinedArtists

        var directArtistScore = 0
        var matchedAlbumScores: [String: Int] = [:]
        var matchedTrackScores: [UUID: Int] = [:]
        if !cleanQuery.isEmpty, Self.useTokenIndex, let tokenIndex = snapshot.tokenIndex {
            let cached = tokenResultCache.withLock { $0 }
            let r: SearchTokenResults
            if let cached, cached.generation == snapshot.generation, cached.query == query {
                r = cached.results
            } else {
                r = tokenIndex.search(query, limits: SearchTokenLimits(tracks: 1, albums: 1, artists: 1, playlists: 0))
            }
            func dense<ID>(_ kind: SearchTokenKindIndex<ID>, _ res: SearchTokenKindResult<ID>, _ id: ID) -> Int {
                guard let i = kind.indexByID[id], i < res.dense.count else { return 0 }
                return Int(res.dense[i])
            }
            directArtistScore = dense(tokenIndex.artists, r.artists, artist.id)
            for album in artist.albums {
                let aScore = dense(tokenIndex.albums, r.albums, album.id)
                if aScore > 0 { matchedAlbumScores[album.id] = aScore }
                for track in album.tracks {
                    let tScore = dense(tokenIndex.tracks, r.tracks, track.id)
                    if tScore > 0 { matchedTrackScores[track.id] = tScore }
                }
            }
        } else if !cleanQuery.isEmpty {
            let artKey = Self.artistSearchKey(artist)
            directArtistScore = Self.scoreMatch(query: cleanQuery, key: artKey.key, primaryLen: Int(artKey.primaryLength), kindPriority: 2)

            for album in artist.albums {
                let albKey = Self.albumSearchKey(album)
                let aScore = Self.scoreMatch(query: cleanQuery, key: albKey.key, primaryLen: Int(albKey.primaryLength), kindPriority: 1)
                if aScore > 0 {
                    matchedAlbumScores[album.id] = aScore
                }
                for track in album.tracks {
                    let tKey = Self.trackSearchKey(track)
                    let tScore = Self.scoreMatch(query: cleanQuery, key: tKey.key, primaryLen: Int(tKey.primaryLength), kindPriority: 0)
                    if tScore > 0 {
                        matchedTrackScores[track.id] = tScore
                    }
                }
            }
        }

        // D13(a): matched albums > matched tracks only (same view as the top hit), ignoring weak fuzzy noise
        // when stronger matches exist.
        let scope = Self.expandScope(matchedAlbums: matchedAlbumScores.count, matchedTracks: matchedTrackScores.count)
        let best = max(matchedAlbumScores.values.max() ?? 0, matchedTrackScores.values.max() ?? 0)
        let minScore = scope == .matchedOnly && best >= SearchRanking.unit ? SearchRanking.unit : 1
        return buildArtistNode(
            artist: artist,
            cleanQuery: cleanQuery,
            directArtistScore: directArtistScore,
            matchedAlbumScores: matchedAlbumScores,
            matchedTrackScores: matchedTrackScores,
            tracksByID: ctx.tracksByID,
            joinedArtists: joinedArtists,
            scope: scope,
            minScore: minScore,
            matchedTracksOnly: scope == .matchedOnly
        )
    }

    private func buildArtistNode(
        artist: Artist,
        cleanQuery: String,
        directArtistScore: Int,
        matchedAlbumScores: [String: Int],
        matchedTrackScores: [UUID: Int],
        tracksByID: [UUID: Track],
        joinedArtists: [String],
        scope: SearchNodeScope,
        minScore: Int = 1,
        matchedTracksOnly: Bool = false
    ) -> SearchTreeArtistNode {
        let isTopArtist = scope == .full
        let matchedOnly = scope == .matchedOnly
        // In matched-only scope the artist's own name match does not pull in the discography.
        let isArtistDirectlyMatched = directArtistScore > 0 && !matchedOnly
        func matched(_ score: Int?) -> Bool { (score ?? 0) >= minScore }

        let disco = getOrComputeDiscography(for: artist, joinedArtists: joinedArtists)

        func filterSectionIfNeeded(_ albums: [Album]) -> [Album] {
            if isArtistDirectlyMatched || isTopArtist { return albums }
            return albums.filter { album in
                matched(matchedAlbumScores[album.id]) ||
                album.tracks.contains { matched(matchedTrackScores[$0.id]) }
            }
        }

        let ownLeadStudio = filterSectionIfNeeded(disco.studio)
        let ownLeadSingles = filterSectionIfNeeded(disco.singles)
        let ownLeadAlternates = filterSectionIfNeeded(disco.alternates)
        let ownFeatured = filterSectionIfNeeded(disco.featured)

        var seenAlbumNodeIDs = Set<String>()
        var bestTrackScoreForArtist = 0
        var bestAlbumScoreForArtist = 0

        func buildSectionNodes(for sectionAlbums: [Album], category: DiscographyCategory) -> [SearchTreeAlbumNode] {
            guard !sectionAlbums.isEmpty else { return [] }
            var nodes: [SearchTreeAlbumNode] = []

            for album in sectionAlbums {
                let albumNodeID = album.id
                guard seenAlbumNodeIDs.insert(albumNodeID).inserted else { continue }

                let albScore = matched(matchedAlbumScores[album.id]) ? (matchedAlbumScores[album.id] ?? 0) : 0
                let isAlbumDirectlyMatched = albScore > 0
                if isAlbumDirectlyMatched {
                    bestAlbumScoreForArtist = max(bestAlbumScoreForArtist, albScore)
                }

                var trackNodes: [SearchTreeTrackNode] = []
                for track in album.tracks {
                    let tScore = matched(matchedTrackScores[track.id]) ? (matchedTrackScores[track.id] ?? 0) : 0
                    if tScore > 0 {
                        bestTrackScoreForArtist = max(bestTrackScoreForArtist, tScore)
                    }

                    // D8 (revised): in a song search the opened album lists only the matched track(s);
                    // tapping the album still opens the full album.
                    if matchedTracksOnly && tScore == 0 { continue }
                    if !isArtistDirectlyMatched && !isAlbumDirectlyMatched && tScore == 0 && !isTopArtist && !matchedOnly {
                        continue
                    }

                    trackNodes.append(SearchTreeTrackNode(
                        id: track.id.uuidString,
                        track: track,
                        isDirectlyMatched: tScore > 0,
                        relevanceScore: tScore
                    ))
                }

                if !isArtistDirectlyMatched && !isAlbumDirectlyMatched && trackNodes.isEmpty && !isTopArtist {
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

            // Section order comes from DiscographyClassifier (query-independent, §3.8).
            return nodes
        }

        let studioNodes = buildSectionNodes(for: ownLeadStudio, category: .albums)
        let singlesNodes = buildSectionNodes(for: ownLeadSingles, category: .singles)
        let alternatesNodes = buildSectionNodes(for: ownLeadAlternates, category: .alternates)
        let featuredNodes = buildSectionNodes(for: ownFeatured, category: .featuredOn)

        var allAlbumNodes = studioNodes + singlesNodes + alternatesNodes + featuredNodes
        if matchedOnly {
            // D3/D5/D10 order of the matching albums (topmost first); section order stays for the full discography.
            let words = SearchRanking.queryVersionWords(cleanQuery)
            func sectionRank(_ c: DiscographyCategory) -> Int {
                switch c {
                case .albums: return DiscographySection.albums.rawValue
                case .singles: return DiscographySection.singlesAndEPs.rawValue
                case .alternates: return DiscographySection.alternates.rawValue
                case .featuredOn: return DiscographySection.featuredOn.rawValue
                }
            }
            var keys: [String: SearchReleaseKey] = [:]
            for node in allAlbumNodes {
                let bestTrack = node.tracks.filter { $0.isDirectlyMatched }.max { $0.relevanceScore < $1.relevanceScore }
                let rank = node.relevanceScore
                keys[node.id] = SearchReleaseKey(
                    versionNamed: SearchRanking.namesVersion(words, album: node.album, track: bestTrack?.track),
                    bucket: rank / SearchRanking.unit,
                    final: rank % SearchRanking.unit,
                    alternateTrack: bestTrack.map { DiscographyClassifier.isAlternateTrack($0.track) } ?? false,
                    section: sectionRank(node.category),
                    year: node.album.resolvedYear ?? node.album.year,
                    trackCount: node.album.tracks.count,
                    albumID: node.album.id
                )
            }
            allAlbumNodes.sort { l, r in
                guard let a = keys[l.id], let b = keys[r.id] else { return false }
                return SearchRanking.releaseOrder(a, b)
            }
        }
        let totalRelevance = max(directArtistScore, bestTrackScoreForArtist, bestAlbumScoreForArtist)

        return SearchTreeArtistNode(
            id: artist.id,
            artist: artist,
            albums: allAlbumNodes,
            isDirectlyMatched: isArtistDirectlyMatched,
            relevanceScore: totalRelevance
        )
    }

    // MARK: - Lazy Discography Memoization

    private func getOrComputeDiscography(for artist: Artist, joinedArtists: [String]) -> CachedArtistDiscography {
        if let cached = discographyLock.withLock({ $0[artist.id] }) {
            return cached
        }
        let sections = DiscographyClassifier.sections(for: artist.albums, artistName: artist.name, joinedArtists: joinedArtists)
        let disco = CachedArtistDiscography(
            studio: sections.albums,
            singles: sections.singlesAndEPs,
            alternates: sections.alternates,
            featured: sections.featuredOn
        )
        discographyLock.withLock { $0[artist.id] = disco }
        return disco
    }
}
