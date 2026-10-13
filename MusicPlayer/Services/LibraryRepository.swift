import Foundation
import os

// MARK: - Flat Records for Durability and Zero-Recursion Serialization

/// Flat album record containing only scalar fields and track UUIDs.
/// Decouples persistence from nested album/track model graphs to prevent encoding traps.
nonisolated public struct AlbumRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let groupKey: String?
    public let title: String
    public let artist: String
    public let year: Int?
    public let genre: String?
    public let artworkKey: String?
    public let trackIDs: [UUID]
    public let mainTrackIDs: [UUID]
    public let alternateTrackIDs: [UUID]
    public let normalizedTitle: String
    public let normalizedArtist: String
    public let searchTokens: String
    public let resolvedYear: Int?
    public let isSingle: Bool
    public let isRemix: Bool
    public let isLive: Bool
    public let isStudioAlbum: Bool
    public let searchKey: String

    public init(
        id: String,
        groupKey: String? = nil,
        title: String,
        artist: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkKey: String? = nil,
        trackIDs: [UUID] = [],
        mainTrackIDs: [UUID] = [],
        alternateTrackIDs: [UUID] = [],
        normalizedTitle: String = "",
        normalizedArtist: String = "",
        searchTokens: String = "",
        resolvedYear: Int? = nil,
        isSingle: Bool = false,
        isRemix: Bool = false,
        isLive: Bool = false,
        isStudioAlbum: Bool = true,
        searchKey: String = ""
    ) {
        self.id = id
        self.groupKey = groupKey
        self.title = title
        self.artist = artist
        self.year = year
        self.genre = genre
        self.artworkKey = artworkKey
        self.trackIDs = trackIDs
        self.mainTrackIDs = mainTrackIDs
        self.alternateTrackIDs = alternateTrackIDs
        self.normalizedTitle = normalizedTitle
        self.normalizedArtist = normalizedArtist
        self.searchTokens = searchTokens
        self.resolvedYear = resolvedYear
        self.isSingle = isSingle
        self.isRemix = isRemix
        self.isLive = isLive
        self.isStudioAlbum = isStudioAlbum
        self.searchKey = searchKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.groupKey = try c.decodeIfPresent(String.self, forKey: .groupKey)
        self.title = try c.decode(String.self, forKey: .title)
        self.artist = try c.decode(String.self, forKey: .artist)
        self.year = try c.decodeIfPresent(Int.self, forKey: .year)
        self.genre = try c.decodeIfPresent(String.self, forKey: .genre)
        self.artworkKey = try c.decodeIfPresent(String.self, forKey: .artworkKey)
        let tIDs = try c.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        self.trackIDs = tIDs
        self.mainTrackIDs = try c.decodeIfPresent([UUID].self, forKey: .mainTrackIDs) ?? tIDs
        self.alternateTrackIDs = try c.decodeIfPresent([UUID].self, forKey: .alternateTrackIDs) ?? []
        self.normalizedTitle = try c.decodeIfPresent(String.self, forKey: .normalizedTitle) ?? ""
        self.normalizedArtist = try c.decodeIfPresent(String.self, forKey: .normalizedArtist) ?? ""
        self.searchTokens = try c.decodeIfPresent(String.self, forKey: .searchTokens) ?? ""
        self.resolvedYear = try c.decodeIfPresent(Int.self, forKey: .resolvedYear) ?? self.year
        self.isSingle = try c.decodeIfPresent(Bool.self, forKey: .isSingle) ?? false
        self.isRemix = try c.decodeIfPresent(Bool.self, forKey: .isRemix) ?? false
        self.isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        self.isStudioAlbum = try c.decodeIfPresent(Bool.self, forKey: .isStudioAlbum) ?? true
        self.searchKey = try c.decodeIfPresent(String.self, forKey: .searchKey) ?? ""
    }
}

/// Flat artist record containing only scalar fields, album IDs, and track UUIDs.
nonisolated public struct ArtistRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let albumIDs: [String]
    public let trackIDs: [UUID]
    public let normalizedName: String
    public let searchTokens: String
    public let ownAlbumCount: Int
    public let ownTrackCount: Int
    public let ownTotalDuration: TimeInterval
    public let discographySummary: String
    public let mostRecentArtworkKey: String?
    public let searchKey: String

    public init(
        id: String,
        name: String,
        albumIDs: [String] = [],
        trackIDs: [UUID] = [],
        normalizedName: String = "",
        searchTokens: String = "",
        ownAlbumCount: Int = 0,
        ownTrackCount: Int = 0,
        ownTotalDuration: TimeInterval = 0,
        discographySummary: String = "",
        mostRecentArtworkKey: String? = nil,
        searchKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.albumIDs = albumIDs
        self.trackIDs = trackIDs
        self.normalizedName = normalizedName
        self.searchTokens = searchTokens
        self.ownAlbumCount = ownAlbumCount
        self.ownTrackCount = ownTrackCount
        self.ownTotalDuration = ownTotalDuration
        self.discographySummary = discographySummary
        self.mostRecentArtworkKey = mostRecentArtworkKey
        self.searchKey = searchKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.albumIDs = try c.decodeIfPresent([String].self, forKey: .albumIDs) ?? []
        self.trackIDs = try c.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        self.normalizedName = try c.decodeIfPresent(String.self, forKey: .normalizedName) ?? ""
        self.searchTokens = try c.decodeIfPresent(String.self, forKey: .searchTokens) ?? ""
        self.ownAlbumCount = try c.decodeIfPresent(Int.self, forKey: .ownAlbumCount) ?? 0
        self.ownTrackCount = try c.decodeIfPresent(Int.self, forKey: .ownTrackCount) ?? 0
        self.ownTotalDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .ownTotalDuration) ?? 0
        self.discographySummary = try c.decodeIfPresent(String.self, forKey: .discographySummary) ?? ""
        self.mostRecentArtworkKey = try c.decodeIfPresent(String.self, forKey: .mostRecentArtworkKey)
        self.searchKey = try c.decodeIfPresent(String.self, forKey: .searchKey) ?? ""
    }
}

/// Flat, safe-to-encode schema persisted to `Application Support/MusicPlayerData/library.v2.json`.
nonisolated public struct LibraryFile: Codable, Sendable {
    public let schemaVersion: Int
    public let settingsHash: String
    public let tracks: [Track]
    public let albums: [AlbumRecord]
    public let artists: [ArtistRecord]

    public init(
        schemaVersion: Int = 2,
        settingsHash: String,
        tracks: [Track],
        albums: [AlbumRecord],
        artists: [ArtistRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.settingsHash = settingsHash
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
    }
}

/// Pre-computed search entries extracted once per mutation to feed SearchEngine without re-folding strings.
nonisolated public struct LibrarySearchEntries: Sendable {
    public let tracks: [SearchIndexEntry<UUID>]
    public let albums: [SearchIndexEntry<String>]
    public let artists: [SearchIndexEntry<String>]

    public static let empty = LibrarySearchEntries(tracks: [], albums: [], artists: [])

    public init(
        tracks: [SearchIndexEntry<UUID>] = [],
        albums: [SearchIndexEntry<String>] = [],
        artists: [SearchIndexEntry<String>] = []
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
    }
}

/// Immutable snapshot of the library state published to LibraryStore on the main actor.
nonisolated public struct LibraryState: Sendable {
    public let tracks: [Track]
    public let tracksByID: [UUID: Track]
    public let albums: [Album]
    public let albumsByID: [String: Album]
    public let artists: [Artist]
    public let artistLookupIndex: [String: Artist]
    public let searchEntries: LibrarySearchEntries

    public static let empty = LibraryState(
        tracks: [],
        tracksByID: [:],
        albums: [],
        albumsByID: [:],
        artists: [],
        artistLookupIndex: [:],
        searchEntries: .empty
    )

    public init(
        tracks: [Track] = [],
        tracksByID: [UUID: Track] = [:],
        albums: [Album] = [],
        albumsByID: [String: Album] = [:],
        artists: [Artist] = [],
        artistLookupIndex: [String: Artist] = [:],
        searchEntries: LibrarySearchEntries = .empty
    ) {
        self.tracks = tracks
        self.tracksByID = tracksByID
        self.albums = albums
        self.albumsByID = albumsByID
        self.artists = artists
        self.artistLookupIndex = artistLookupIndex
        self.searchEntries = searchEntries
    }
}

// MARK: - Library Repository Actor

/// The single actor that owns and synchronizes every mutation to tracks, albums, and artists.
/// Eliminates data races, duplicate entity traps, and main-actor stalls.
public actor LibraryRepository {
    public static let shared = LibraryRepository()

    private var tracksMap: [UUID: Track] = [:]
    private var albums: [Album] = []
    private var albumsByID: [String: Album] = [:]
    private var artists: [Artist] = []
    private var artistLookupIndex: [String: Artist] = [:]
    private var searchEntries: LibrarySearchEntries = .empty

    private var albumRecords: [AlbumRecord] = []
    private var artistRecords: [ArtistRecord] = []

    private var saveTask: Task<Void, Never>? = nil

    public init() {}

    // MARK: - Current State Accessors

    public var currentState: LibraryState {
        LibraryState(
            tracks: Array(tracksMap.values),
            tracksByID: tracksMap,
            albums: albums,
            albumsByID: albumsByID,
            artists: artists,
            artistLookupIndex: artistLookupIndex,
            searchEntries: searchEntries
        )
    }

    public var currentSearchEntries: LibrarySearchEntries {
        searchEntries
    }

    // MARK: - Cold Launch Loading

    /// Fast, non-blocking cold boot loader.
    /// Reads `library.v2.json` with `.mappedIfSafe`, decodes flat records, and rebuilds in-memory lookup indices.
    /// Falls back to `library.snapshot` or `LegacySQLiteImporter` if v2 is missing.
    public func load(
        storageDir: URL,
        expectedSettingsHash: String,
        settings: AppSettings
    ) async -> (state: LibraryState, hashMismatch: Bool) {
        let v2URL = storageDir.appendingPathComponent("library.v2.json")
        let snapshotURL = storageDir.appendingPathComponent("library.snapshot")

        // 1. Attempt reading library.v2.json
        if FileManager.default.fileExists(atPath: v2URL.path),
           let data = try? Data(contentsOf: v2URL, options: .mappedIfSafe) {
            let file: LibraryFile?
            if let plistFile = try? PropertyListDecoder().decode(LibraryFile.self, from: data) {
                file = plistFile
            } else {
                file = try? JSONDecoder().decode(LibraryFile.self, from: data)
            }

            if let file = file {
                let loadedTracks = file.tracks
                self.tracksMap = Dictionary(loadedTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, second in second })

                // Reconstruct in-memory Album models from flat AlbumRecords via memberwise restore
                var reconstructedAlbums: [Album] = []
                reconstructedAlbums.reserveCapacity(file.albums.count)
                for record in file.albums {
                    let albumTracks = record.trackIDs.compactMap { self.tracksMap[$0] }
                    let mainTracks = record.mainTrackIDs.compactMap { self.tracksMap[$0] }
                    let altTracks = record.alternateTrackIDs.compactMap { self.tracksMap[$0] }
                    let alb = Album(
                        restoredFrom: record,
                        tracks: albumTracks,
                        mainTracks: mainTracks.isEmpty ? albumTracks : mainTracks,
                        alternateTracks: altTracks
                    )
                    reconstructedAlbums.append(alb)
                }
                self.albums = reconstructedAlbums
                self.albumsByID = Dictionary(reconstructedAlbums.map { ($0.id, $0) }, uniquingKeysWith: { _, second in second })

                // Reconstruct in-memory Artist models from flat ArtistRecords via memberwise restore
                var reconstructedArtists: [Artist] = []
                reconstructedArtists.reserveCapacity(file.artists.count)
                for record in file.artists {
                    let artistAlbums = record.albumIDs.compactMap { self.albumsByID[$0] }
                    let artistTracks = record.trackIDs.compactMap { self.tracksMap[$0] }
                    let art = Artist(
                        restoredFrom: record,
                        albums: artistAlbums,
                        tracks: artistTracks
                    )
                    reconstructedArtists.append(art)
                }
                self.artists = reconstructedArtists

                // Rebuild lookup index
                var lookup: [String: Artist] = [:]
                lookup.reserveCapacity(reconstructedArtists.count * 3)
                for artist in reconstructedArtists {
                    let lower = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let canon = ArtistParser.canonicalArtistKey(artist.name)
                    lookup[lower] = artist
                    lookup[canon] = artist
                    lookup[artist.id] = artist
                }
                self.artistLookupIndex = lookup

                // Reconstruct search entries from prefolded keys (zero folding at launch)
                let trackEntries = loadedTracks.map { t in
                    SearchIndexEntry(id: t.id, key: !t.searchTokens.isEmpty ? t.searchTokens : SearchEngine.normalizeKey("\(t.title) \(t.artist) \(t.album)"))
                }
                let albumEntries = file.albums.map { a in
                    let key = !a.searchTokens.isEmpty ? a.searchTokens : (!a.searchKey.isEmpty ? a.searchKey : SearchEngine.normalizeKey("\(a.title) \(a.artist)"))
                    return SearchIndexEntry(id: a.id, key: key)
                }
                let artistEntries = file.artists.map { art in
                    let key = !art.searchTokens.isEmpty ? art.searchTokens : (!art.searchKey.isEmpty ? art.searchKey : SearchEngine.normalizeKey(art.name))
                    return SearchIndexEntry(id: art.id, key: key)
                }
                self.searchEntries = LibrarySearchEntries(tracks: trackEntries, albums: albumEntries, artists: artistEntries)
                self.albumRecords = file.albums
                self.artistRecords = file.artists

                let hashMismatch = file.settingsHash != expectedSettingsHash
                AppLogger.storage.info("Loaded library.v2.json: \(loadedTracks.count) tracks, \(reconstructedAlbums.count) albums, \(reconstructedArtists.count) artists (hashMismatch: \(hashMismatch)).")
                return (state: currentState, hashMismatch: hashMismatch)
            }
        }

        // 2. Migration fallback: library.snapshot
        if FileManager.default.fileExists(atPath: snapshotURL.path),
           let mappedData = try? Data(contentsOf: snapshotURL, options: .alwaysMapped),
           let snapshot = try? PropertyListDecoder().decode(LibrarySnapshot.self, from: mappedData) {
            AppLogger.storage.info("Migrating legacy library.snapshot to library.v2.json...")
            let state = updateFullState(
                tracks: snapshot.tracks,
                albums: snapshot.albums,
                artists: snapshot.artists,
                lookup: snapshot.artistLookupIndex
            )
            performSaveImmediate(storageDir: storageDir, settingsHash: expectedSettingsHash)
            deleteLegacyFiles(storageDir: storageDir)
            return (state: state, hashMismatch: false)
        }

        // 3. Migration fallback: LegacySQLiteImporter
        let sqliteURL = storageDir.appendingPathComponent("library.sqlite")
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            let rescuedTracks = LegacySQLiteImporter.importAndCleanup(storageDirectoryURL: storageDir)
            if !rescuedTracks.isEmpty {
                AppLogger.storage.info("Rescued \(rescuedTracks.count) tracks from library.sqlite during v2 migration.")
                let res = LibraryStore.buildAlbumsAndArtists(
                    tracks: rescuedTracks,
                    joinedArtists: settings.joinedArtists,
                    manualCollaborativeAlbumIDs: settings.manualCollaborativeAlbumIDs,
                    originalAlbumArtistsByTrackID: settings.originalAlbumArtistsByTrackID,
                    verifiedGoodDiffs: [],
                    downloadedMetadataCache: PersistentDownloadedMetadataCache(),
                    scanMethod: settings.libraryScanMethod
                )
                let state = updateFullState(
                    tracks: res.tracks,
                    albums: res.albums,
                    artists: res.artists,
                    lookup: res.artistLookupIndex
                )
                performSaveImmediate(storageDir: storageDir, settingsHash: expectedSettingsHash)
                deleteLegacyFiles(storageDir: storageDir)
                return (state: state, hashMismatch: false)
            }
        }

        // Fresh library
        return (state: .empty, hashMismatch: false)
    }

    // MARK: - Change Set Application

    /// Applies a differential change set to the library.
    /// Merges exclusively by `Track.id` using `Dictionary(_:uniquingKeysWith:)` (last write wins).
    /// Recomputes albums and artists in memory and returns an immutable `LibraryState`.
    public func applyChangeSet(
        upserted: [Track],
        removedIDs: Set<UUID>,
        settings: AppSettings,
        verifiedGoodDiffs: [MetadataDiff] = [],
        downloadedMetadataCache: PersistentDownloadedMetadataCache = PersistentDownloadedMetadataCache()
    ) -> LibraryState {
        // 1. Remove deleted tracks
        for id in removedIDs {
            tracksMap.removeValue(forKey: id)
        }

        // 2. Upsert new/updated tracks
        for track in upserted {
            tracksMap[track.id] = track
        }

        let allTracks = Array(tracksMap.values)

        // 3. Recompute albums and artists
        let res = LibraryStore.buildAlbumsAndArtists(
            tracks: allTracks,
            joinedArtists: settings.joinedArtists,
            manualCollaborativeAlbumIDs: settings.manualCollaborativeAlbumIDs,
            originalAlbumArtistsByTrackID: settings.originalAlbumArtistsByTrackID,
            verifiedGoodDiffs: verifiedGoodDiffs,
            downloadedMetadataCache: downloadedMetadataCache,
            scanMethod: settings.libraryScanMethod
        )

        return updateFullState(
            tracks: res.tracks,
            albums: res.albums,
            artists: res.artists,
            lookup: res.artistLookupIndex
        )
    }

    /// Full rebuild (e.g. settings hash mismatch recovery).
    public func rebuildAll(
        settings: AppSettings,
        verifiedGoodDiffs: [MetadataDiff] = [],
        downloadedMetadataCache: PersistentDownloadedMetadataCache = PersistentDownloadedMetadataCache()
    ) -> LibraryState {
        let allTracks = Array(tracksMap.values)
        let res = LibraryStore.buildAlbumsAndArtists(
            tracks: allTracks,
            joinedArtists: settings.joinedArtists,
            manualCollaborativeAlbumIDs: settings.manualCollaborativeAlbumIDs,
            originalAlbumArtistsByTrackID: settings.originalAlbumArtistsByTrackID,
            verifiedGoodDiffs: verifiedGoodDiffs,
            downloadedMetadataCache: downloadedMetadataCache,
            scanMethod: settings.libraryScanMethod
        )

        return updateFullState(
            tracks: res.tracks,
            albums: res.albums,
            artists: res.artists,
            lookup: res.artistLookupIndex
        )
    }

    // MARK: - State Update Helpers

    private func updateFullState(
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        lookup: [String: Artist]
    ) -> LibraryState {
        self.tracksMap = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, second in second })
        self.albums = albums
        self.albumsByID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { _, second in second })
        self.artists = artists
        self.artistLookupIndex = lookup

        // Construct flat records
        var aRecords: [AlbumRecord] = []
        aRecords.reserveCapacity(albums.count)
        var albumSearchEntries: [SearchIndexEntry<String>] = []
        albumSearchEntries.reserveCapacity(albums.count)

        for a in albums {
            let key = !a.searchTokens.isEmpty ? a.searchTokens : SearchEngine.normalizeKey("\(a.title) \(a.artist)")
            let primaryLen = Int32(SearchEngine.normalizeKey(a.title).utf8.count)
            aRecords.append(AlbumRecord(
                id: a.id,
                groupKey: a.groupKey,
                title: a.title,
                artist: a.artist,
                year: a.year,
                genre: a.genre,
                artworkKey: a.artworkKey,
                trackIDs: a.trackIDs,
                mainTrackIDs: a.mainTracks.map { $0.id },
                alternateTrackIDs: a.alternateTracks.map { $0.id },
                normalizedTitle: a.normalizedTitle,
                normalizedArtist: a.normalizedArtist,
                searchTokens: a.searchTokens,
                resolvedYear: a.resolvedYear,
                isSingle: a.isSingle,
                isRemix: a.isRemix,
                isLive: a.isLive,
                isStudioAlbum: a.isStudioAlbum,
                searchKey: key
            ))
            albumSearchEntries.append(SearchIndexEntry(id: a.id, key: key, primaryLength: primaryLen))
        }
        self.albumRecords = aRecords

        var artRecords: [ArtistRecord] = []
        artRecords.reserveCapacity(artists.count)
        var artistSearchEntries: [SearchIndexEntry<String>] = []
        artistSearchEntries.reserveCapacity(artists.count)

        for art in artists {
            let key = !art.searchTokens.isEmpty ? art.searchTokens : SearchEngine.normalizeKey(art.name)
            let primaryLen = Int32(SearchEngine.normalizeKey(art.name).utf8.count)
            artRecords.append(ArtistRecord(
                id: art.id,
                name: art.name,
                albumIDs: art.albums.map { $0.id },
                trackIDs: art.tracks.map { $0.id },
                normalizedName: art.normalizedName,
                searchTokens: art.searchTokens,
                ownAlbumCount: art.ownAlbumCount,
                ownTrackCount: art.ownTrackCount,
                ownTotalDuration: art.ownTotalDuration,
                discographySummary: art.discographySummary,
                mostRecentArtworkKey: art.mostRecentArtworkKey,
                searchKey: key
            ))
            artistSearchEntries.append(SearchIndexEntry(id: art.id, key: key, primaryLength: primaryLen))
        }
        self.artistRecords = artRecords

        let trackSearchEntries = tracks.map { t -> SearchIndexEntry<UUID> in
            let key = !t.searchTokens.isEmpty ? t.searchTokens : SearchEngine.normalizeKey("\(t.title) \(t.artist) \(t.album)")
            let primaryLen = Int32(SearchEngine.normalizeKey(t.title).utf8.count)
            return SearchIndexEntry(id: t.id, key: key, primaryLength: primaryLen)
        }

        self.searchEntries = LibrarySearchEntries(
            tracks: trackSearchEntries,
            albums: albumSearchEntries,
            artists: artistSearchEntries
        )

        return currentState
    }

    // MARK: - Debounced & Immediate Persistence

    /// Schedules a debounced save of `library.v2.json` (~1 second debounce).
    nonisolated public func scheduleSave(storageDir: URL, settingsHash: String) {
        Task { [weak self] in
            await self?.debouncedSave(storageDir: storageDir, settingsHash: settingsHash)
        }
    }

    public func debouncedSave(storageDir: URL, settingsHash: String) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSaveImmediate(storageDir: storageDir, settingsHash: settingsHash)
        }
    }

    /// Flushes library immediately to disk without debouncing (e.g. backgrounding).
    public func flushImmediate(storageDir: URL, settingsHash: String) {
        saveTask?.cancel()
        saveTask = nil
        performSaveImmediate(storageDir: storageDir, settingsHash: settingsHash)
    }

    private func performSaveImmediate(storageDir: URL, settingsHash: String) {
        let file = LibraryFile(
            schemaVersion: 2,
            settingsHash: settingsHash,
            tracks: Array(tracksMap.values),
            albums: albumRecords,
            artists: artistRecords
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encodedData: Data?
        if let data = try? encoder.encode(file) {
            encodedData = data
        } else {
            encodedData = try? JSONEncoder().encode(file)
        }

        guard let data = encodedData else {
            AppLogger.storage.error("Failed to encode LibraryFile.")
            return
        }

        let v2URL = storageDir.appendingPathComponent("library.v2.json")
        let tempURL = storageDir.appendingPathComponent("library.v2.json.tmp.\(UUID().uuidString)")

        do {
            try data.write(to: tempURL, options: [.completeFileProtectionUntilFirstUserAuthentication])
            if FileManager.default.fileExists(atPath: v2URL.path) {
                _ = try FileManager.default.replaceItemAt(v2URL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: v2URL)
            }
        } catch {
            try? data.write(to: v2URL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func deleteLegacyFiles(storageDir: URL) {
        let fm = FileManager.default
        let legacySnapshot = storageDir.appendingPathComponent("library.snapshot")
        let chunksDir = storageDir.appendingPathComponent("library_chunks", isDirectory: true)
        let chunksManifest = storageDir.appendingPathComponent("library_chunks_manifest.json")
        let libBin = storageDir.appendingPathComponent("library.cache")
        let oldBinPlist = storageDir.appendingPathComponent("library.binaryplist")
        let sqliteURL = storageDir.appendingPathComponent("library.sqlite")
        let walURL = storageDir.appendingPathComponent("library.sqlite-wal")
        let shmURL = storageDir.appendingPathComponent("library.sqlite-shm")

        try? fm.removeItem(at: legacySnapshot)
        try? fm.removeItem(at: chunksDir)
        try? fm.removeItem(at: chunksManifest)
        try? fm.removeItem(at: libBin)
        try? fm.removeItem(at: oldBinPlist)
        try? fm.removeItem(at: sqliteURL)
        try? fm.removeItem(at: walURL)
        try? fm.removeItem(at: shmURL)
    }
}
