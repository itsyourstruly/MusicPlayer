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

/// Immutable SearchSnapshot value swapped under OSAllocatedUnfairLock.
nonisolated public struct SearchSnapshot: Sendable {
    public let generation: UInt64
    public let tracks: KindIndex<UUID>
    public let albums: KindIndex<String>
    public let artists: KindIndex<String>
    public let playlists: KindIndex<UUID>
    public let context: SearchContext?

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
        context: SearchContext?
    ) {
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
        playlistScores: [Int] = []
    ) {
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
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "amo.MusicPlayer", category: "Search")

    public init() {}

    // MARK: - Normalization

    public static func normalizeKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return FuzzyMatcher.normalize(folded)
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
        }
    }

    // MARK: - Query: Flat Search

    public static func scoreMatch(
        query: String,
        key: String,
        primaryLen: Int,
        kindPriority: Int
    ) -> Int {
        let cleanQuery = normalizeKey(query)
        guard !cleanQuery.isEmpty else { return 0 }
        let cleanKey = normalizeKey(key)
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
        let clean = FuzzyMatcher.normalize(query)
        guard !clean.isEmpty else { return .empty }

        var scoredTracks: [(id: UUID, score: Int)] = []
        for (id, t) in context.tracksByID {
            let key = !t.searchTokens.isEmpty ? t.searchTokens : Self.normalizeKey("\(t.title) \(t.artist) \(t.album)")
            let primaryLen = Self.normalizeKey(t.title).utf8.count
            let s = Self.scoreMatch(query: clean, key: key, primaryLen: primaryLen, kindPriority: 1)
            if s > 0 {
                scoredTracks.append((id, s))
            }
        }
        scoredTracks.sort { $0.score > $1.score }
        let topTracks = Array(scoredTracks.prefix(maxTrackResults))

        var scoredAlbums: [(id: String, score: Int)] = []
        for (id, a) in context.albumsByID {
            let key = !a.searchTokens.isEmpty ? a.searchTokens : Self.normalizeKey("\(a.title) \(a.artist)")
            let primaryLen = Self.normalizeKey(a.title).utf8.count
            let s = Self.scoreMatch(query: clean, key: key, primaryLen: primaryLen, kindPriority: 2)
            if s > 0 {
                scoredAlbums.append((id, s))
            }
        }
        scoredAlbums.sort { $0.score > $1.score }
        let topAlbums = Array(scoredAlbums.prefix(maxAlbumResults))

        var scoredArtists: [(id: String, score: Int)] = []
        for art in context.artists {
            let key = !art.searchTokens.isEmpty ? art.searchTokens : Self.normalizeKey(art.name)
            let primaryLen = Self.normalizeKey(art.name).utf8.count
            let s = Self.scoreMatch(query: clean, key: key, primaryLen: primaryLen, kindPriority: 3)
            if s > 0 {
                scoredArtists.append((art.id, s))
            }
        }
        scoredArtists.sort { $0.score > $1.score }
        let topArtists = Array(scoredArtists.prefix(maxArtistResults))

        var scoredPlaylists: [(id: UUID, score: Int)] = []
        for pl in context.playlists {
            let key = Self.normalizeKey(pl.name)
            let primaryLen = key.utf8.count
            let s = Self.scoreMatch(query: clean, key: key, primaryLen: primaryLen, kindPriority: 0)
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
        let cleanQuery = Self.normalizeKey(query)
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
        let cleanQuery = Self.normalizeKey(query)
        guard !cleanQuery.isEmpty else { return .empty }

        return await Task.detached(priority: .userInitiated) { () -> GlobalSearchResults in
            let startTime = DispatchTime.now()
            let signpostID = self.signposter.makeSignpostID()
            let overallInterval = self.signposter.beginInterval("search", id: signpostID)
            defer { self.signposter.endInterval("search", overallInterval) }

            let scanInterval = self.signposter.beginInterval("scan", id: signpostID)
            let flat = self.executeSearchFlat(
                query: cleanQuery,
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
        maxTrackResults: Int,
        maxAlbumResults: Int,
        maxArtistResults: Int
    ) -> GlobalSearchResults {
        guard let ctx = context else { return .empty }
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
            let primaryArtist = artistLookupIndex[ArtistParser.canonicalArtistKey(album.artist)]
                ?? artistLookupIndex[album.artist.lowercased()]
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
            if let art = artistLookupIndex[id] ?? ctx.artists.first(where: { $0.id == id }) {
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

        for node in directMatchedTracks {
            let track = node.track
            let artistKey = ArtistParser.canonicalArtistKey(track.artist)
            let artist = artistLookupIndex[artistKey]
                ?? artistLookupIndex[track.artist.lowercased()]
                ?? ctx.artists.first(where: { $0.id == track.artist.lowercased() })
            if let artist, seenArtistIDs.insert(artist.id).inserted {
                artistEntities.append(artist)
            }
        }

        var artistRelevanceScores: [String: Int] = [:]
        for artist in artistEntities {
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

        artistEntities.sort {
            let r0 = artistRelevanceScores[$0.id] ?? 0
            let r1 = artistRelevanceScores[$1.id] ?? 0
            if r0 != r1 {
                return r0 > r1
            }
            return $0.normalizedName < $1.normalizedName
        }

        var artistTreeNodes: [SearchTreeArtistNode] = []
        var seenArtistNodeIDs = Set<String>()

        for (idx, artist) in artistEntities.prefix(maxArtistResults).enumerated() {
            let artistNodeID = artist.id
            guard seenArtistNodeIDs.insert(artistNodeID).inserted else { continue }

            let isTopArtist = (idx == 0)
            let artistScore = matchedArtistScores[artist.id] ?? 0
            let isArtistDirectlyMatched = artistScore > 0

            if isTopArtist {
                let node = buildArtistNode(
                    artist: artist,
                    cleanQuery: cleanQuery,
                    directArtistScore: artistScore,
                    matchedAlbumScores: matchedAlbumScores,
                    matchedTrackScores: matchedTrackScores,
                    tracksByID: tracksByID,
                    joinedArtists: joinedArtists,
                    isTopArtist: true
                )
                artistTreeNodes.append(node)
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

        artistTreeNodes.sort {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.artist.normalizedName < $1.artist.normalizedName
        }

        return GlobalSearchResults(
            artistTreeNodes: Array(artistTreeNodes.prefix(maxArtistResults)),
            playlists: matchedPlaylists,
            directMatchedAlbums: Array(directMatchedAlbums.prefix(maxAlbumResults)),
            directMatchedTracks: Array(directMatchedTracks.prefix(maxTrackResults))
        )
    }

    nonisolated public func expandArtist(artistID: String, query: String) -> SearchTreeArtistNode? {
        let snapshot = indexLock.withLock { $0 }
        guard let ctx = snapshot.context else { return nil }
        guard let artist = ctx.artistLookupIndex[artistID] ?? ctx.artists.first(where: { $0.id == artistID }) else {
            return nil
        }
        let cleanQuery = Self.normalizeKey(query)
        let joinedArtists = ctx.joinedArtists

        var directArtistScore = 0
        var matchedAlbumScores: [String: Int] = [:]
        var matchedTrackScores: [UUID: Int] = [:]
        if !cleanQuery.isEmpty {
            let artKey = !artist.searchTokens.isEmpty ? artist.searchTokens : Self.normalizeKey(artist.name)
            directArtistScore = Self.scoreMatch(query: cleanQuery, key: artKey, primaryLen: artist.name.utf8.count, kindPriority: 2)

            for album in artist.albums {
                let albKey = !album.searchTokens.isEmpty ? album.searchTokens : Self.normalizeKey("\(album.title) \(album.artist)")
                let aScore = Self.scoreMatch(query: cleanQuery, key: albKey, primaryLen: album.title.utf8.count, kindPriority: 1)
                if aScore > 0 {
                    matchedAlbumScores[album.id] = aScore
                }
                for track in album.tracks {
                    let tKey = !track.searchTokens.isEmpty ? track.searchTokens : Self.normalizeKey("\(track.title) \(track.artist) \(track.album)")
                    let tScore = Self.scoreMatch(query: cleanQuery, key: tKey, primaryLen: track.title.utf8.count, kindPriority: 0)
                    if tScore > 0 {
                        matchedTrackScores[track.id] = tScore
                    }
                }
            }
        }

        return buildArtistNode(
            artist: artist,
            cleanQuery: cleanQuery,
            directArtistScore: directArtistScore,
            matchedAlbumScores: matchedAlbumScores,
            matchedTrackScores: matchedTrackScores,
            tracksByID: ctx.tracksByID,
            joinedArtists: joinedArtists,
            isTopArtist: true
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
        isTopArtist: Bool
    ) -> SearchTreeArtistNode {
        let isArtistDirectlyMatched = directArtistScore > 0

        let disco = getOrComputeDiscography(for: artist, joinedArtists: joinedArtists)

        func filterSectionIfNeeded(_ albums: [Album]) -> [Album] {
            if isArtistDirectlyMatched || isTopArtist { return albums }
            return albums.filter { album in
                (matchedAlbumScores[album.id] ?? 0) > 0 ||
                album.tracks.contains { (matchedTrackScores[$0.id] ?? 0) > 0 }
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

                let albScore = matchedAlbumScores[album.id] ?? 0
                let isAlbumDirectlyMatched = albScore > 0
                if isAlbumDirectlyMatched {
                    bestAlbumScoreForArtist = max(bestAlbumScoreForArtist, albScore)
                }

                var trackNodes: [SearchTreeTrackNode] = []
                for track in album.tracks {
                    let tScore = matchedTrackScores[track.id] ?? 0
                    if tScore > 0 {
                        bestTrackScoreForArtist = max(bestTrackScoreForArtist, tScore)
                    }

                    if !isArtistDirectlyMatched && !isAlbumDirectlyMatched && tScore == 0 && !isTopArtist {
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

            nodes.sort { nodeA, nodeB in
                let aHas = nodeA.isDirectlyMatched || nodeA.tracks.contains(where: { $0.isDirectlyMatched })
                let bHas = nodeB.isDirectlyMatched || nodeB.tracks.contains(where: { $0.isDirectlyMatched })
                if aHas != bHas { return aHas && !bHas }
                if nodeA.relevanceScore != nodeB.relevanceScore { return nodeA.relevanceScore > nodeB.relevanceScore }
                let yA = nodeA.album.resolvedYear ?? nodeA.album.year ?? 0
                let yB = nodeB.album.resolvedYear ?? nodeB.album.year ?? 0
                if yA != yB { return yA > yB }
                return nodeA.album.normalizedTitle < nodeB.album.normalizedTitle
            }

            return nodes
        }

        let studioNodes = buildSectionNodes(for: ownLeadStudio, category: .albums)
        let singlesNodes = buildSectionNodes(for: ownLeadSingles, category: .singles)
        let alternatesNodes = buildSectionNodes(for: ownLeadAlternates, category: .alternates)
        let featuredNodes = buildSectionNodes(for: ownFeatured, category: .featuredOn)

        let allAlbumNodes = studioNodes + singlesNodes + alternatesNodes + featuredNodes
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
        discographyLock.withLock { $0[artist.id] = disco }
        return disco
    }
}
