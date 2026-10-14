import Foundation
import CryptoKit
import Observation
import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#endif


/// Persistent cache record for a downloaded online track metadata result and artwork.
public struct CachedTrackMetadataRecord: Codable, Sendable {
    public var onlineMetadata: OnlineTrackMetadata
    public let localTrackSignature: String
    public let filePath: String
    public let fileName: String
    public let fileSizeBytes: Int64
    public let cachedArtworkKey: String?
    public let downloadedAt: Date
    public var wasApplied: Bool

    // Applied snapshot fields to perfectly restore tracks after rescan or unlink
    public var appliedTitle: String?
    public var appliedArtist: String?
    public var appliedAlbum: String?
    public var appliedAlbumArtist: String?
    public var appliedGenre: String?
    public var appliedYear: Int?
    public var appliedTrackNumber: Int?
    public var appliedOriginalTrackNumber: Int?
    public var appliedDeluxeTrackNumber: Int?
    public var appliedTotalTracks: Int?
    public var appliedDiscNumber: Int?

    public nonisolated init(
        onlineMetadata: OnlineTrackMetadata,
        localTrackSignature: String,
        filePath: String,
        fileName: String,
        fileSizeBytes: Int64,
        cachedArtworkKey: String?,
        downloadedAt: Date = Date(),
        wasApplied: Bool = false,
        appliedTitle: String? = nil,
        appliedArtist: String? = nil,
        appliedAlbum: String? = nil,
        appliedAlbumArtist: String? = nil,
        appliedGenre: String? = nil,
        appliedYear: Int? = nil,
        appliedTrackNumber: Int? = nil,
        appliedOriginalTrackNumber: Int? = nil,
        appliedDeluxeTrackNumber: Int? = nil,
        appliedTotalTracks: Int? = nil,
        appliedDiscNumber: Int? = nil
    ) {
        self.onlineMetadata = onlineMetadata
        self.localTrackSignature = localTrackSignature
        self.filePath = filePath
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.cachedArtworkKey = cachedArtworkKey
        self.downloadedAt = downloadedAt
        self.wasApplied = wasApplied
        self.appliedTitle = appliedTitle
        self.appliedArtist = appliedArtist
        self.appliedAlbum = appliedAlbum
        self.appliedAlbumArtist = appliedAlbumArtist
        self.appliedGenre = appliedGenre
        self.appliedYear = appliedYear
        self.appliedTrackNumber = appliedTrackNumber
        self.appliedOriginalTrackNumber = appliedOriginalTrackNumber
        self.appliedDeluxeTrackNumber = appliedDeluxeTrackNumber
        self.appliedTotalTracks = appliedTotalTracks
        self.appliedDiscNumber = appliedDiscNumber
    }
}

/// Multi-index container for persistently cached downloaded metadata that survives unlinking, rescanning, and restarts.
public struct PersistentDownloadedMetadataCache: Codable, Sendable {
    public var recordsByFilePath: [String: CachedTrackMetadataRecord] = [:]
    public var recordsBySignature: [String: CachedTrackMetadataRecord] = [:]
    public var recordsByFileSignature: [String: CachedTrackMetadataRecord] = [:]

    public nonisolated init() {}

    public var totalRecordsCount: Int {
        recordsByFilePath.count
    }
}

/// Manifest metadata describing chunked binary cache on disk for ultra-high-speed parallel loading.
public struct LibraryChunksManifest: Codable, Sendable {
    public let totalTracks: Int
    public let chunkCount: Int
    public let chunkSize: Int

    public init(totalTracks: Int, chunkCount: Int, chunkSize: Int) {
        self.totalTracks = totalTracks
        self.chunkCount = chunkCount
        self.chunkSize = chunkSize
    }
}

/// Single binary property list snapshot for instant frame-1 cold boot loading.
public struct LibrarySnapshot: Codable, Sendable {
    public let version: Int
    public let tracks: [Track]
    public let albums: [Album]
    public let artists: [Artist]
    public let artistLookupIndex: [String: Artist]
    public let settingsHash: String

    public init(
        version: Int = 1,
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        artistLookupIndex: [String: Artist],
        settingsHash: String
    ) {
        self.version = version
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.artistLookupIndex = artistLookupIndex
        self.settingsHash = settingsHash
    }
}

/// Consolidated result of background album and artist grouping and synthesis.
public struct AlbumsAndArtistsResult: Sendable {
    public let tracks: [Track]
    public let albums: [Album]
    public let artists: [Artist]
    public let artistLookupIndex: [String: Artist]

    public init(
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        artistLookupIndex: [String: Artist]
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.artistLookupIndex = artistLookupIndex
    }
}

/// Cached statistics for an individual linked folder or Jellyfin server.
public struct FolderStats: Codable, Sendable, Equatable {
    public var trackCount: Int
    public var albumCount: Int
    public var artistCount: Int

    public init(trackCount: Int = 0, albumCount: Int = 0, artistCount: Int = 0) {
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.artistCount = artistCount
    }
}

/// High-performance search model driving asynchronous search projection from SearchEngine
@Observable
@MainActor
public final class LibrarySearchModel {
    public private(set) var flatResults: FlatSearchResults = .empty
    public private(set) var matchedTrackIDs: [UUID] = []
    public private(set) var matchedAlbumIDs: [String] = []
    public private(set) var matchedArtistIDs: [String] = []
    public private(set) var matchedPlaylistIDs: [UUID] = []
    public private(set) var isQueryActive: Bool = false
    public private(set) var isSearching: Bool = false
    private var currentQuery: String = ""
    private var searchTask: Task<Void, Never>? = nil

    public init() {}

    public func search(query: String) {
        let clean = FuzzyMatcher.normalize(query)
        if clean.isEmpty {
            searchTask?.cancel()
            currentQuery = ""
            isQueryActive = false
            isSearching = false
            flatResults = .empty
            matchedTrackIDs = []
            matchedAlbumIDs = []
            matchedArtistIDs = []
            matchedPlaylistIDs = []
            return
        }
        guard clean != currentQuery else { return }
        searchTask?.cancel()
        currentQuery = clean
        isSearching = true

        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            let flat = await SearchEngine.shared.searchFlat(
                query: clean,
                maxTrackResults: 200,
                maxAlbumResults: 50,
                maxArtistResults: 50,
                maxPlaylistResults: 50
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.currentQuery == clean else { return }
                self.flatResults = flat
                self.matchedTrackIDs = flat.trackIDs
                self.matchedAlbumIDs = flat.albumIDs
                self.matchedArtistIDs = flat.artistIDs
                self.matchedPlaylistIDs = flat.playlistIDs
                self.isQueryActive = true
                self.isSearching = false
                AppLogger.library.info("LibrarySearchModel published query '\(clean)': \(flat.trackIDs.count) tracks, \(flat.albumIDs.count) albums, \(flat.artistIDs.count) artists.")
            }
        }
    }
}

/// Unified `@Observable` central library state and data persistence store.
/// Manages tracks, albums, artists, playlists, user preferences, and background scanning.
@Observable
@MainActor
public final class LibraryStore {
    // Shared reference for cross-component access
    public static weak var shared: LibraryStore? = nil

    // MARK: - Search Model
    public let searchModel = LibrarySearchModel()

    // MARK: - Core State

    // All tracks loaded in the user library
    public private(set) var tracks: [Track] = [] {
        didSet {
            invalidateSortedCaches()
        }
    }
    // Fast O(1) indexed lookup for tracks by UUID
    public private(set) var tracksByID: [UUID: Track] = [:]
    // Grouped album entities
    public private(set) var albums: [Album] = [] {
        didSet {
            invalidateSortedCaches()
        }
    }
    // Grouped artist entities
    public private(set) var artists: [Artist] = [] {
        didSet { invalidateSortedCaches() }
    }
    // User-created and smart playlists
    public private(set) var playlists: [Playlist] = [] {
        didSet { invalidateSortedCaches() }
    }
    // Search index version to trigger reactive search updates
    public var searchIndexVersion: Int = 0
    // ID of the last playlist to which a track was added
    public private(set) var lastAddedPlaylistID: UUID?
    // Track playback counts keyed by track ID
    public private(set) var playCounts: [UUID: Int] = [:]
    // Track saved playback positions (in seconds) keyed by track ID
    public private(set) var playbackPositions: [UUID: TimeInterval] = [:]
    // Quick-access pinned playlists and collections
    public private(set) var pinnedItemIDs: [PinnedItemIdentifier] = []
    @ObservationIgnored public private(set) var pinnedItemsCache: [PinnedItem] = []
    // IDs of albums pinned to home view
    public private(set) var pinnedAlbumIDs: Set<String> = []
    // Recently played album IDs (ordered most recent first, max 25)
    public private(set) var recentAlbumIDs: [String] = []
    @ObservationIgnored public private(set) var recentAlbumsCache: [Album] = []

    /// Computed recently played albums matching known library albums
    public var recentAlbums: [Album] {
        if !recentAlbumsCache.isEmpty {
            return recentAlbumsCache
        }
        return recentAlbumIDs.compactMap { albumsByID[$0] }
    }
    // Recently played track IDs from Search Library (ordered most recent first, max 50)
    public private(set) var recentSearchPlayedTrackIDs: [UUID] = []

    /// Computed recently played tracks from Search Library matching known library tracks
    public var recentSearchPlayedTracks: [Track] {
        return recentSearchPlayedTrackIDs.compactMap { tracksByID[$0] }
    }
    // User preferences and configuration store
    public var settings: AppSettings = AppSettings()

    // MARK: - Duplicate & Metadata Enrichment State

    // Detected groups of duplicate audio tracks
    public private(set) var duplicateGroups: [DuplicateGroup] = []
    // Pending metadata changes from background enrichment
    public private(set) var enrichmentDiffs: [MetadataDiff] = []
    // Metadata matches approved by the user
    public private(set) var verifiedGoodDiffs: [MetadataDiff] = []
    // Tracks that could not be automatically matched online
    public private(set) var unmatchedTrackIDs: Set<UUID> = []
    // Persistent multi-index downloaded metadata cache
    public private(set) var downloadedMetadataCache = PersistentDownloadedMetadataCache()
    // Controls is background checking metadata
    public private(set) var isBackgroundCheckingMetadata: Bool = false
    public private(set) var isBackgroundCheckingMetadataPaused: Bool = false
    public private(set) var backgroundCheckProgress: Double = 0.0
    public private(set) var backgroundCheckStatusText: String = ""
    public private(set) var backgroundCheckScannedCount: Int = 0
    public private(set) var backgroundCheckTotalCount: Int = 0
    // Controls is enriching metadata
    public private(set) var isEnrichingMetadata: Bool = false
    public private(set) var enrichProgress: Double = 0.0
    public private(set) var enrichStatusText: String = ""
    public private(set) var enrichProcessedCount: Int = 0
    public private(set) var enrichTotalCount: Int = 0

    // MARK: - Artist Discography Multi-Source Scan State
    public var isScanningArtistDiscography: Bool = false
    public var isDiscographyScanComplete: Bool = false
    public var activeDiscographyScanArtistName: String? = nil
    public var discographyScanProgress: Double = 0.0
    public var discographyScanStatusText: String = ""
    public var discographyScanResult: DiscographyScanResult? = nil

    public var verifiedGoodCount: Int {
        verifiedGoodDiffs.count
    }

    private var hasExcludedFolders: Bool {
        settings.linkedFolders.contains { $0.isExcludedFromTagEnrichment }
    }

    public var visibleEnrichmentDiffs: [MetadataDiff] {
        guard hasExcludedFolders else { return enrichmentDiffs }
        return enrichmentDiffs.filter { !isTrackExcludedFromTagEnrichment($0.localTrack) }
    }

    public var visibleVerifiedGoodDiffs: [MetadataDiff] {
        guard hasExcludedFolders else { return verifiedGoodDiffs }
        return verifiedGoodDiffs.filter { !isTrackExcludedFromTagEnrichment($0.localTrack) }
    }

    public var visibleVerifiedGoodCount: Int {
        guard hasExcludedFolders else { return verifiedGoodDiffs.count }
        return visibleVerifiedGoodDiffs.count
    }

    public var visibleDuplicateGroups: [DuplicateGroup] {
        guard hasExcludedFolders else { return duplicateGroups }
        return duplicateGroups.compactMap { (group: DuplicateGroup) -> DuplicateGroup? in
            let nonExcludedCandidates = group.candidates.filter { !isTrackExcludedFromTagEnrichment($0.track) }
            if nonExcludedCandidates.count < 2 {
                return nil
            }
            return DuplicateGroup(
                id: group.id,
                normalizedTitle: group.normalizedTitle,
                normalizedArtist: group.normalizedArtist,
                candidates: nonExcludedCandidates,
                selectedPrimaryTrackID: group.selectedPrimaryTrackID
            )
        }
    }

    public var unmatchedTracks: [Track] {
        let idSet = unmatchedTrackIDs
        guard hasExcludedFolders else { return tracks.filter { idSet.contains($0.id) } }
        return tracks.filter { idSet.contains($0.id) && !isTrackExcludedFromTagEnrichment($0) }
    }

    public var unmatchedTracksCount: Int {
        unmatchedTrackIDs.count
    }

    // Fast O(1) index mapping normalized artist name variants and IDs to Artist entities
    @ObservationIgnored public private(set) var artistLookupIndex: [String: Artist] = [:]

    // MARK: - Scanning & Loading State

    // Indicates initial background loading of persisted library data from disk
    public private(set) var isInitialLoading: Bool = true
    // Indicates active file system audio scanning
    public private(set) var isScanning: Bool = false
    public private(set) var currentlyScanningFolderID: UUID? = nil
    // Overall scanning completion progress (0.0 - 1.0)
    public private(set) var scanProgress: Double = 0.0
    // Human-readable status text for scanner UI
    public private(set) var scanStatusText: String = ""
    // Errors encountered per Jellyfin server ID
    public private(set) var jellyfinServerErrors: [UUID: String] = [:]
    // Last successful sync date per Jellyfin server ID
    public private(set) var jellyfinLastSyncDates: [UUID: Date] = [:]

    // MARK: - UI & Filter State

    public var searchQuery: String = "" {
        didSet {
            searchModel.search(query: searchQuery)
        }
    }
    public var globalSearchQuery: String = ""
    public var selectedCategory: LibraryCategory = .artists

    public var selectedSortOption: TrackSortOption {
        get { trackSortOption }
        set { trackSortOption = newValue }
    }
    public var trackSortOption: TrackSortOption = .title {
        didSet { cachedSortedTracks = nil }
    }
    // Controls is track sort reversed
    public var isTrackSortReversed: Bool = false {
        didSet { cachedSortedTracks = nil }
    }

    public var artistSortOption: ArtistSortOption = .name {
        didSet { cachedSortedArtists = nil }
    }
    // Controls is artist sort reversed
    public var isArtistSortReversed: Bool = false {
        didSet { cachedSortedArtists = nil }
    }

    public var albumSortOption: AlbumSortOption = .title {
        didSet { cachedSortedAlbums = nil }
    }
    // Controls is album sort reversed
    public var isAlbumSortReversed: Bool = false {
        didSet { cachedSortedAlbums = nil }
    }

    public var playlistSortOption: PlaylistSortOption = .name {
        didSet { cachedSortedPlaylists = nil }
    }
    // Controls is playlist sort reversed
    public var isPlaylistSortReversed: Bool = false {
        didSet { cachedSortedPlaylists = nil }
    }

    @ObservationIgnored private var cachedSortedTracks: [Track]? = nil
    @ObservationIgnored private var cachedSortedAlbums: [Album]? = nil
    @ObservationIgnored private var cachedSortedArtists: [Artist]? = nil
    @ObservationIgnored private var cachedSortedPlaylists: [Playlist]? = nil
    @ObservationIgnored private var cachedActiveTracks: [Track]? = nil
    @ObservationIgnored private var cachedActiveAlbums: [Album]? = nil
    @ObservationIgnored private var cachedActiveArtists: [Artist]? = nil
    @ObservationIgnored public private(set) var albumsByID: [String: Album] = [:]
    @ObservationIgnored private var albumsByNormalizedKey: [String: Album] = [:]

    @ObservationIgnored private var cachedFilteredTracksKey: String? = nil
    @ObservationIgnored private var cachedFilteredTracksResult: [Track]? = nil
    @ObservationIgnored private var cachedFilteredAlbumsKey: String? = nil
    @ObservationIgnored private var cachedFilteredAlbumsResult: [Album]? = nil
    @ObservationIgnored private var cachedFilteredArtistsKey: String? = nil
    @ObservationIgnored private var cachedFilteredArtistsResult: [Artist]? = nil
    @ObservationIgnored private var cachedFilteredPlaylistsKey: String? = nil
    @ObservationIgnored private var cachedFilteredPlaylistsResult: [Playlist]? = nil

    /// Rebuilds fast O(1) indexed lookup tables for albums and tracks
    private func rebuildAlbumLookups() {
        var byID: [String: Album] = [:]
        byID.reserveCapacity(albums.count)
        var byKey: [String: Album] = [:]
        byKey.reserveCapacity(albums.count)

        for album in albums {
            byID[album.id] = album
            let key = "\(album.normalizedArtist)_\(album.normalizedTitle)"
            if byKey[key] == nil {
                byKey[key] = album
            }
        }
        self.albumsByID = byID
        self.albumsByNormalizedKey = byKey

        var tByID: [UUID: Track] = [:]
        tByID.reserveCapacity(tracks.count)
        for track in tracks {
            tByID[track.id] = track
        }
        self.tracksByID = tByID
    }

    /// Atomically applies an immutable LibraryState emitted by LibraryRepository on MainActor.
    public func applyLoadedLibraryState(_ state: LibraryState) {
        self.tracks = state.tracks
        self.tracksByID = state.tracksByID
        self.albums = state.albums
        self.albumsByID = state.albumsByID
        self.artists = state.artists
        self.artistLookupIndex = state.artistLookupIndex
        self.cachedActiveTracks = state.tracks

        var byKey: [String: Album] = [:]
        byKey.reserveCapacity(state.albums.count)
        for album in state.albums {
            let key = "\(album.normalizedArtist)_\(album.normalizedTitle)"
            if byKey[key] == nil {
                byKey[key] = album
            }
        }
        self.albumsByNormalizedKey = byKey

        self.invalidateSortedCaches()
        self.isInitialLoading = false

        if !self.recentAlbumIDs.isEmpty {
            let freshRecents = self.recentAlbumIDs.compactMap { self.albumsByID[$0] }
            if !freshRecents.isEmpty {
                self.recentAlbumsCache = freshRecents
                self.saveRecentAlbums()
            }
        }
        if !self.pinnedItemIDs.isEmpty {
            var resolvedPins: [PinnedItem] = []
            for identifier in self.pinnedItemIDs {
                switch identifier.type {
                case .playlist:
                    if let plID = UUID(uuidString: identifier.targetID),
                       let pl = self.playlists.first(where: { $0.id == plID }) {
                        resolvedPins.append(.playlist(pl))
                    }
                case .album:
                    if let al = self.albumsByID[identifier.targetID] {
                        resolvedPins.append(.album(al))
                    }
                }
            }
            if !resolvedPins.isEmpty {
                self.pinnedItemsCache = resolvedPins
                self.savePins()
            }
        }

        let searchCtx = SearchContext(
            tracksByID: state.tracksByID,
            albumsByID: state.albumsByID,
            artists: state.artists,
            artistLookupIndex: state.artistLookupIndex,
            playlists: self.playlists,
            joinedArtists: self.settings.joinedArtists
        )
        SearchEngine.shared.updateIndex(searchEntries: state.searchEntries, playlists: self.playlists, context: searchCtx)
    }

    /// Fast O(1) indexed lookup for a track by its UUID.
    public func track(forID id: UUID) -> Track? {
        tracksByID[id]
    }

    /// Fast O(1) indexed lookup for an album by its stable ID.
    public func album(forID id: String) -> Album? {
        albumsByID[id]
    }

    /// Fast O(1) indexed lookup for an album by its normalized artist and title.
    public func album(normalizedArtist: String, normalizedTitle: String) -> Album? {
        albumsByNormalizedKey["\(normalizedArtist)_\(normalizedTitle)"]
    }

    /// Invalidates all cached sorted collections
    public func invalidateSortedCaches() {
        cachedSortedTracks = nil
        cachedSortedAlbums = nil
        cachedSortedArtists = nil
        cachedSortedPlaylists = nil
        cachedActiveTracks = nil
        cachedActiveAlbums = nil
        cachedActiveArtists = nil
        cachedFilteredTracksKey = nil
        cachedFilteredTracksResult = nil
        cachedFilteredAlbumsKey = nil
        cachedFilteredAlbumsResult = nil
        cachedFilteredArtistsKey = nil
        cachedFilteredArtistsResult = nil
        cachedFilteredPlaylistsKey = nil
        cachedFilteredPlaylistsResult = nil
    }

    // MARK: - File Paths & Persistence Coordination

    @ObservationIgnored private var saveLibraryDebounceTask: Task<Void, Never>? = nil
    @ObservationIgnored private var savePlayCountsDebounceTask: Task<Void, Never>? = nil
    @ObservationIgnored private var warmSearchIndexDebounceTask: Task<Void, Never>? = nil
    @ObservationIgnored private var searchDeltaDebounceTask: Task<Void, Never>? = nil
    @ObservationIgnored private var pendingDeltaInsertedTracks: [UUID: Track] = [:]
    @ObservationIgnored private var pendingDeltaRemovedTrackIDs: Set<UUID> = []
    @ObservationIgnored private var pendingDeltaUpdatedTracks: [UUID: Track] = [:]
    @ObservationIgnored private var pendingDeltaAlbums: [Album]? = nil
    @ObservationIgnored private var pendingDeltaArtists: [Artist]? = nil
    @ObservationIgnored private var pendingDeltaPlaylists: [Playlist]? = nil
    @ObservationIgnored private var fileGenerations: [URL: Int] = [:]

    private func bumpGeneration(for url: URL) -> Int {
        let next = (fileGenerations[url] ?? 0) + 1
        fileGenerations[url] = next
        return next
    }

    public var organizationModesContainer = OrganizationModesContainer()

    // File manager
    private let fileManager = FileManager.default
    // File system location for storage directory url
    public let storageDirectoryURL: URL

    // Initialize with configured properties
    public init() {
        // App support
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.storageDirectoryURL = appSupport.appendingPathComponent("MusicPlayerData", isDirectory: true)

        LibraryStore.shared = self

        if !fileManager.fileExists(atPath: storageDirectoryURL.path) {
            try? fileManager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        }

        // Wire bookmark stale updates
        SecurityScopedBookmark.shared.onBookmarkUpdated = { [weak self] folderID, newBookmarkData in
            guard let self = self else { return }
            if let idx = self.settings.linkedFolders.firstIndex(where: { $0.id == folderID }) {
                self.settings.linkedFolders[idx].bookmarkData = newBookmarkData
                self.saveSettings()
                AppLogger.storage.info("Updated stale bookmark for folder: \(folderID)")
            }
        }

        // 1. Instant sync load of lightweight preferences for immediate frame 1 paint
        loadLightweightPreferences()

        // Offload security-scoped bookmark resolution and server pre-warming to background task so main thread/init is zero latency
        let folders = self.settings.linkedFolders
        let jellyfinServers = self.settings.jellyfinServers
        Task.detached(priority: .userInitiated) {
            _ = SecurityScopedBookmark.shared.resolveAndAccessBookmark()
            SecurityScopedBookmark.shared.resolveAndAccessAllBookmarks(folders: folders)
            for server in jellyfinServers {
                _ = JellyfinKeychain.getToken(forServerId: server.serverId, userId: server.userId)
            }
        }

        // Wire remote artwork loader for Jellyfin images
        ArtworkCacheService.remoteArtworkLoader = { key, fullResolution in
            await JellyfinArtworkRegistry.shared.fetchArtworkData(for: key, fullResolution: fullResolution)
        }

        NotificationCenter.default.addObserver(forName: .hideTrackRequested, object: nil, queue: .main) { [weak self] note in
            guard let track = note.userInfo?["track"] as? Track else { return }
            self?.hideTrack(track)
        }

        // 2. Load cached library data asynchronously off main thread at maximum speed
        loadPersistedStateAsync()
    }

    // MARK: - Computed Filtered Collections

    /// Returns resolved user-pinned albums and playlists in their customized display order.
    public var pinnedItems: [PinnedItem] {
        if !pinnedItemsCache.isEmpty {
            return pinnedItemsCache
        }
        var results: [PinnedItem] = []
        for identifier in pinnedItemIDs {
            switch identifier.type {
            case .playlist:
                if let plID = UUID(uuidString: identifier.targetID),
                   let pl = playlists.first(where: { $0.id == plID }) {
                    results.append(.playlist(pl))
                }
            case .album:
                if let al = albumsByID[identifier.targetID] {
                    results.append(.album(al))
                }
            }
        }
        return results
    }

    public var pinnedPlaylists: [Playlist] {
        playlists.filter { $0.isPinned }
    }

    /// Returns tracks belonging strictly to enabled linked folders.
    public var activeTracks: [Track] {
        if settings.disabledFolderIDs.isEmpty {
            return tracks
        }
        if let cached = cachedActiveTracks {
            return cached
        }
        let filtered = tracks.filter { isTrackFromEnabledFolder($0) }
        cachedActiveTracks = filtered
        return filtered
    }

    /// Returns albums containing tracks belonging strictly to enabled linked folders.
    public var activeAlbums: [Album] {
        if settings.disabledFolderIDs.isEmpty {
            return albums
        }
        if let cached = cachedActiveAlbums {
            return cached
        }
        var result: [Album] = []
        for album in albums {
            let filtered = album.tracks.filter { isTrackFromEnabledFolder($0) }
            if !filtered.isEmpty {
                if filtered.count == album.tracks.count {
                    result.append(album)
                } else {
                    result.append(Album(
                        title: album.title,
                        artist: album.artist,
                        year: album.year,
                        genre: album.genre,
                        artworkKey: album.artworkKey,
                        tracks: filtered
                    ))
                }
            }
        }
        cachedActiveAlbums = result
        return result
    }

    /// Returns artists containing tracks and albums belonging strictly to enabled linked folders.
    public var activeArtists: [Artist] {
        if settings.disabledFolderIDs.isEmpty {
            return artists
        }
        if let cached = cachedActiveArtists {
            return cached
        }
        var result: [Artist] = []
        for artist in artists {
            let filteredTracks = artist.tracks.filter { isTrackFromEnabledFolder($0) }
            if !filteredTracks.isEmpty {
                let filteredAlbums = artist.albums.compactMap { album -> Album? in
                    let tr = album.tracks.filter { isTrackFromEnabledFolder($0) }
                    guard !tr.isEmpty else { return nil }
                    if tr.count == album.tracks.count { return album }
                    return Album(
                        title: album.title,
                        artist: album.artist,
                        year: album.year,
                        genre: album.genre,
                        artworkKey: album.artworkKey,
                        tracks: tr
                    )
                }
                result.append(Artist(
                    name: artist.name,
                    albums: filteredAlbums,
                    tracks: filteredTracks,
                    joinedArtists: settings.joinedArtists
                ))
            }
        }
        cachedActiveArtists = result
        return result
    }

    public var filteredTracks: [Track] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if cleanQuery.isEmpty || !searchModel.isQueryActive {
            if let cached = cachedSortedTracks {
                return cached
            }
            let sourceList: [Track]
            if settings.autoHideDuplicates && !duplicateGroups.isEmpty {
                let hiddenTrackIDs = Set(duplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track.id } })
                sourceList = activeTracks.filter { !hiddenTrackIDs.contains($0.id) }
            } else {
                sourceList = activeTracks
            }
            let sorted = sortTracks(sourceList, by: trackSortOption, isReversed: isTrackSortReversed)
            cachedSortedTracks = sorted
            return sorted
        }

        let hiddenTrackIDs: Set<UUID>
        if settings.autoHideDuplicates && !duplicateGroups.isEmpty {
            hiddenTrackIDs = Set(duplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track.id } })
        } else {
            hiddenTrackIDs = []
        }

        var result: [Track] = []
        let trackIDs = searchModel.flatResults.trackIDs
        result.reserveCapacity(trackIDs.count)
        for id in trackIDs {
            if !hiddenTrackIDs.isEmpty && hiddenTrackIDs.contains(id) { continue }
            if let track = tracksByID[id] {
                result.append(track)
            }
        }
        return result
    }

    /// Standardized, high-performance album search scoring title, artist, and track titles.
    public func searchAlbums(query: String) -> [Album] {
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard !cleanQuery.isEmpty else { return activeAlbums }

        if cleanQuery == FuzzyMatcher.normalize(searchQuery) && searchModel.isQueryActive {
            return filteredAlbums
        }

        let flat = SearchEngine.shared.searchFlat(
            query: cleanQuery,
            maxTrackResults: 0,
            maxAlbumResults: 100,
            maxArtistResults: 0,
            maxPlaylistResults: 0
        )
        var result: [Album] = []
        result.reserveCapacity(flat.albumIDs.count)
        for id in flat.albumIDs {
            if let album = albumsByID[id] {
                result.append(album)
            }
        }
        return result
    }

    public var filteredAlbums: [Album] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || !searchModel.isQueryActive {
            if let cached = cachedSortedAlbums {
                return cached
            }
            let sorted = sortAlbums(activeAlbums, by: albumSortOption, isReversed: isAlbumSortReversed)
            cachedSortedAlbums = sorted
            return sorted
        }

        var result: [Album] = []
        let albumIDs = searchModel.flatResults.albumIDs
        result.reserveCapacity(albumIDs.count)
        for id in albumIDs {
            if let album = albumsByID[id] {
                result.append(album)
            }
        }
        return result
    }

    public var filteredArtists: [Artist] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if cleanQuery.isEmpty || !searchModel.isQueryActive {
            if let cached = cachedSortedArtists {
                return cached
            }
            let sorted = sortArtists(activeArtists, by: artistSortOption, isReversed: isArtistSortReversed)
            cachedSortedArtists = sorted
            return sorted
        }

        var result: [Artist] = []
        let artistIDs = searchModel.flatResults.artistIDs
        result.reserveCapacity(artistIDs.count)
        for id in artistIDs {
            if let artist = artistLookupIndex[id] ?? activeArtists.first(where: { $0.id == id }) {
                result.append(artist)
            }
        }
        return result
    }

    public var filteredPlaylists: [Playlist] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if cleanQuery.isEmpty || !searchModel.isQueryActive {
            if let cached = cachedSortedPlaylists {
                return cached
            }
            let sorted = sortPlaylists(playlists, by: playlistSortOption, isReversed: isPlaylistSortReversed)
            cachedSortedPlaylists = sorted
            return sorted
        }

        var result: [Playlist] = []
        let playlistIDs = searchModel.flatResults.playlistIDs
        if !playlistIDs.isEmpty {
            let pMap = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result.reserveCapacity(playlistIDs.count)
            for id in playlistIDs {
                if let pl = pMap[id] {
                    result.append(pl)
                }
            }
        }
        return result
    }

    public var totalLibraryDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    public var totalLibraryDiskBytes: Int64 {
        tracks.reduce(0) { $0 + ($1.fileInfo?.fileSizeBytes ?? 0) }
    }

    public var totalDuplicateSavingsBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.potentialSavedBytes }
    }

    public var totalDuplicateTracksCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.duplicateCandidates.count }
    }

    public var tracksMissingArtworkCount: Int {
        tracks.filter { $0.artworkKey?.isEmpty != false }.count
    }

    public var tracksMissingMetadataCount: Int {
        tracks.filter { $0.year == nil || $0.trackNumber == nil || $0.artworkKey == nil }.count
    }

    // MARK: - Direct Collection Lookups

    /// Finds an Album matching the specified title and optional artist name.
    public func findAlbum(title: String, artist: String? = nil) -> Album? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        // Fast O(1) indexed check by artist + title
        if let artist = artist {
            let normArtist = FuzzyMatcher.normalize(artist)
            let normTitle = FuzzyMatcher.normalize(cleanTitle)
            if let indexed = album(normalizedArtist: normArtist, normalizedTitle: normTitle) {
                return indexed
            }
        }

        // Fast O(1) indexed check by ID
        if let directID = albumsByID[cleanTitle] {
            return directID
        }

        if let direct = albums.first(where: {
            guard $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame else { return false }
            if let artist {
                return $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame ||
                       $0.isLeadOrCollaborativeAlbum(for: artist, joinedArtists: settings.joinedArtists)
            }
            return true
        }) {
            return direct
        }
        if let fallback = albums.first(where: { $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame }) {
            return fallback
        }
        // Norm query
        let normQuery = normalizeAlbumTitleForClustering(cleanTitle)
        if let normMatch = albums.first(where: { normalizeAlbumTitleForClustering($0.title) == normQuery }) {
            return normMatch
        }
        // Synthesize album from matching tracks if not indexed in albums collection
        let matchingTracks = tracks.filter {
            $0.album.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame ||
            normalizeAlbumTitleForClustering($0.album) == normQuery
        }
        // Ensure preconditions are met before proceeding
        guard !matchingTracks.isEmpty else { return nil }
        return Album(
            title: cleanTitle,
            artist: artist ?? matchingTracks.first?.artist ?? "Unknown Artist",
            artworkKey: matchingTracks.first?.artworkKey,
            tracks: matchingTracks
        )
    }

    /// Finds an Artist matching the specified name (exact or individual parsed artist match) with O(1) indexed lookup.
    public func findArtist(name: String) -> Artist? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !ArtistParser.isGenericArtistName(trimmedName) else { return nil }
        let canonicalKey = ArtistParser.canonicalArtistKey(trimmedName)
        let lowerKey = trimmedName.lowercased()
        guard !canonicalKey.isEmpty else { return nil }

        // Fast O(1) cache/index lookup
        if let cached = artistLookupIndex[canonicalKey] ?? artistLookupIndex[lowerKey] {
            return cached
        }

        // Direct matching in artists array
        if let direct = artists.first(where: {
            $0.id == canonicalKey ||
            $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame ||
            ArtistParser.canonicalArtistKey($0.name) == canonicalKey
        }) {
            artistLookupIndex[canonicalKey] = direct
            return direct
        }

        // Match tracks containing this artist in all metadata (direct or featured in title)
        let matchingTracks = tracks.filter { track in
            let trackRawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let trackCanonical = ArtistParser.canonicalArtistKey(trackRawArtist)
            let albumRawArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let albumCanonical = ArtistParser.canonicalArtistKey(albumRawArtist)

            // If this track belongs to a joined artist, only match if trimmedName is that joined artist
            var matchedJoined: String? = nil
            for joined in settings.joinedArtists {
                let joinedCanonical = ArtistParser.canonicalArtistKey(joined)
                if trackCanonical == joinedCanonical || albumCanonical == joinedCanonical {
                    matchedJoined = joined
                    break
                }
                let joinedParts = ArtistParser.parseArtists(from: joined).map { ArtistParser.canonicalArtistKey($0) }
                if joinedParts.count > 1 {
                    let trackParts = ArtistParser.parseArtists(from: trackRawArtist).map { ArtistParser.canonicalArtistKey($0) }
                    let albumParts = ArtistParser.parseArtists(from: albumRawArtist).map { ArtistParser.canonicalArtistKey($0) }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) || (!albumParts.isEmpty && Set(joinedParts).isSubset(of: Set(albumParts))) {
                        matchedJoined = joined
                        break
                    }
                }
            }

            if let joined = matchedJoined {
                return ArtistParser.canonicalArtistKey(joined) == canonicalKey
            }

            let all = ArtistParser.allArtists(forTitle: track.title, artist: track.artist, albumArtist: track.albumArtist)
            return all.contains {
                $0.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame ||
                ArtistParser.canonicalArtistKey($0) == canonicalKey
            }
        }

        if !matchingTracks.isEmpty {
            let matchingTrackIDs = Set(matchingTracks.map { $0.id })
            let matchingAlbums = albums.filter { album in
                album.tracks.contains { matchingTrackIDs.contains($0.id) }
            }
            let synthesized = Artist(name: trimmedName, albums: matchingAlbums, tracks: matchingTracks, joinedArtists: settings.joinedArtists)
            artistLookupIndex[canonicalKey] = synthesized
            return synthesized
        }
        return nil
    }

    // MARK: - Directory Linking & Scanning

    /// Returns the linked folder entity that owns this track, if matched.
    public func folder(for track: Track) -> LinkedFolder? {
        if track.isJellyfinItem || track.metadataSource == .server {
            return nil
        }
        if let folderID = track.folderID, let match = settings.linkedFolders.first(where: { $0.id == folderID }) {
            return match
        }
        if settings.linkedFolders.count == 1 && settings.jellyfinServers.isEmpty {
            return settings.linkedFolders.first
        }
        let trackCanonical = track.url.resolvingSymlinksInPath().standardizedFileURL.path
        for f in settings.linkedFolders {
            if let p = f.path {
                let canonicalPath = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
                if trackCanonical.hasPrefix(canonicalPath) || track.url.path.hasPrefix(p) {
                    return f
                }
            }
            if let fURL = SecurityScopedBookmark.shared.url(for: f.id) {
                let fCanonical = fURL.resolvingSymlinksInPath().standardizedFileURL.path
                if trackCanonical.hasPrefix(fCanonical) || track.url.standardizedFileURL.path.hasPrefix(fURL.standardizedFileURL.path) {
                    return f
                }
            }
        }
        return nil
    }

    /// Checks whether a linked folder is currently enabled for display in the Library tabs.
    public func isFolderEnabled(_ folderID: UUID) -> Bool {
        !settings.disabledFolderIDs.contains(folderID)
    }

    /// Toggles the enabled state of a linked folder for Library views.
    public func toggleFolderEnabled(_ folderID: UUID) {
        if settings.disabledFolderIDs.contains(folderID) {
            settings.disabledFolderIDs.remove(folderID)
        } else {
            settings.disabledFolderIDs.insert(folderID)
        }
        saveSettings()
        invalidateSortedCaches()
    }

    /// Determines if a track belongs to an enabled folder.
    public func isTrackFromEnabledFolder(_ track: Track) -> Bool {
        guard !settings.disabledFolderIDs.isEmpty else { return true }
        if let fID = track.folderID {
            return !settings.disabledFolderIDs.contains(fID)
        }
        if let f = folder(for: track) {
            return !settings.disabledFolderIDs.contains(f.id)
        }
        return true
    }

    /// Determines if a track should be excluded from tag enrichment sheets and scans.
    public func isTrackExcludedFromTagEnrichment(_ track: Track) -> Bool {
        guard hasExcludedFolders else { return false }
        guard let f = folder(for: track) else { return false }
        return f.isExcludedFromTagEnrichment
    }

    /// Toggles the tag enrichment exclusion flag for a specific linked folder.
    public func toggleTagEnrichmentExclusion(for folderID: UUID) {
        guard let index = settings.linkedFolders.firstIndex(where: { $0.id == folderID }) else { return }
        settings.linkedFolders[index].isExcludedFromTagEnrichment.toggle()
        saveSettings()
    }

    public typealias FolderStats = MusicPlayer.FolderStats
    @ObservationIgnored private var cachedFolderStats: [UUID: FolderStats] = [:]

    /// Track count for an individual linked folder (O(1) indexed).
    public func trackCount(for folder: LinkedFolder) -> Int {
        if settings.linkedFolders.count <= 1 && settings.jellyfinServers.isEmpty {
            return tracks.count
        }
        if let stats = cachedFolderStats[folder.id] {
            return stats.trackCount
        }
        if !isInitialLoading {
            rebuildFolderStats()
            return cachedFolderStats[folder.id]?.trackCount ?? 0
        }
        return 0
    }

    /// Album count for an individual linked folder (O(1) indexed).
    public func albumCount(for folder: LinkedFolder) -> Int {
        if settings.linkedFolders.count <= 1 && settings.jellyfinServers.isEmpty {
            return albums.count
        }
        if let stats = cachedFolderStats[folder.id] {
            return stats.albumCount
        }
        if !isInitialLoading {
            rebuildFolderStats()
            return cachedFolderStats[folder.id]?.albumCount ?? 0
        }
        return 0
    }

    /// Artist count for an individual linked folder (O(1) indexed).
    public func artistCount(for folder: LinkedFolder) -> Int {
        if settings.linkedFolders.count <= 1 && settings.jellyfinServers.isEmpty {
            return artists.count
        }
        if let stats = cachedFolderStats[folder.id] {
            return stats.artistCount
        }
        if !isInitialLoading {
            rebuildFolderStats()
            return cachedFolderStats[folder.id]?.artistCount ?? 0
        }
        return 0
    }

    /// Track count for a Jellyfin server (O(1) indexed).
    public func trackCount(for server: JellyfinServerLink) -> Int {
        if let stats = cachedFolderStats[server.id] {
            return stats.trackCount
        }
        if !isInitialLoading {
            rebuildFolderStats()
            return cachedFolderStats[server.id]?.trackCount ?? 0
        }
        return 0
    }

    /// Album count for a Jellyfin server (O(1) indexed).
    public func albumCount(for server: JellyfinServerLink) -> Int {
        if let stats = cachedFolderStats[server.id] {
            return stats.albumCount
        }
        if !isInitialLoading {
            rebuildFolderStats()
            return cachedFolderStats[server.id]?.albumCount ?? 0
        }
        return 0
    }

    /// Artist count for a Jellyfin server (O(1) indexed).
    public func artistCount(for server: JellyfinServerLink) -> Int {
        if let stats = cachedFolderStats[server.id] {
            return stats.artistCount
        }
        if !isInitialLoading {
            rebuildFolderStats()
            return cachedFolderStats[server.id]?.artistCount ?? 0
        }
        return 0
    }

    /// Non-isolated folder stats calculator that runs safely in background tasks.
    nonisolated public static func computeFolderStats(
        tracks: [Track],
        linkedFolders: [LinkedFolder],
        jellyfinServers: [JellyfinServerLink] = []
    ) -> [UUID: FolderStats] {
        var statsMap: [UUID: (tracks: Int, albums: Set<String>, artists: Set<String>)] = [:]
        for folder in linkedFolders {
            statsMap[folder.id] = (0, Set<String>(), Set<String>())
        }
        for server in jellyfinServers {
            statsMap[server.id] = (0, Set<String>(), Set<String>())
        }

        let folderLookups: [(id: UUID, path: String)] = linkedFolders.compactMap { folder in
            guard let p = folder.path else { return nil }
            return (folder.id, URL(fileURLWithPath: p).standardizedFileURL.path)
        }

        let singleFolderID = (linkedFolders.count == 1 && jellyfinServers.isEmpty) ? linkedFolders.first?.id : nil

        for track in tracks {
            let matchedFolderID: UUID?
            if let fID = track.folderID {
                matchedFolderID = fID
            } else if !track.isJellyfinItem && track.metadataSource != .server, let sID = singleFolderID {
                matchedFolderID = sID
            } else if !track.isJellyfinItem && track.metadataSource != .server {
                let trackPath = track.url.standardizedFileURL.path
                matchedFolderID = folderLookups.first(where: { trackPath.hasPrefix($0.path) })?.id
            } else {
                matchedFolderID = nil
            }

            if let fID = matchedFolderID, var cur = statsMap[fID] {
                cur.tracks += 1
                cur.albums.insert("\(track.album.lowercased())---\(track.artist.lowercased())")
                cur.artists.insert(track.artist.lowercased())
                statsMap[fID] = cur
            }
        }

        var result: [UUID: FolderStats] = [:]
        for (fID, cur) in statsMap {
            result[fID] = FolderStats(trackCount: cur.tracks, albumCount: cur.albums.count, artistCount: cur.artists.count)
        }
        return result
    }

    /// Rebuilds cached statistics for all linked folders and servers in a single O(N) pass and persists to binary cache.
    public func rebuildFolderStats() {
        let stats = Self.computeFolderStats(
            tracks: self.tracks,
            linkedFolders: self.settings.linkedFolders,
            jellyfinServers: self.settings.jellyfinServers
        )
        self.cachedFolderStats = stats
        let url = self.folderStatsFileURL
        let stringKeyed = Dictionary(stats.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
        Task.detached(priority: .utility) {
            if let json = try? JSONEncoder().encode(stringKeyed) {
                try? json.write(to: url, options: .atomic)
            }
        }
    }

    /// Adds a new music directory, creates a security bookmark, and initiates indexing for that folder.
    public func addAndScanFolder(url: URL) async {
        let folderID = UUID()
        guard let bookmark = SecurityScopedBookmark.shared.saveBookmark(for: url, folderID: folderID) else {
            AppLogger.library.error("Could not obtain security-scoped bookmark for \(url.path)")
            return
        }

        let newFolder = LinkedFolder(
            id: folderID,
            name: url.lastPathComponent,
            path: url.path,
            bookmarkData: bookmark,
            isExcludedFromTagEnrichment: false,
            dateAdded: Date()
        )

        settings.linkedFolders.append(newFolder)
        settings.linkedFolderName = settings.linkedFolders.first?.name
        saveSettings()

        await rescanSingleFolder(folder: newFolder, url: url)
    }

    /// Backwards compatibility linkAndScanFolder method.
    public func linkAndScanFolder(url: URL) async {
        await addAndScanFolder(url: url)
    }

    /// Rescans a specific linked folder by its UUID.
    public func rescanFolder(id: UUID) async {
        guard !isScanning else { return }
        guard let folder = settings.linkedFolders.first(where: { $0.id == id }) else { return }
        guard let url = SecurityScopedBookmark.shared.resolveAndAccessBookmark(folderID: folder.id, bookmarkData: folder.bookmarkData) ??
              (folder.path.map { URL(fileURLWithPath: $0) }) else {
            AppLogger.library.warning("Unable to resolve URL for folder: \(folder.name)")
            return
        }
        await rescanSingleFolder(folder: folder, url: url)
    }

    /// Changes the target directory of an existing linked folder and rescans it.
    public func changeFolder(id: UUID, newURL: URL) async {
        guard let index = settings.linkedFolders.firstIndex(where: { $0.id == id }) else { return }
        guard let bookmark = SecurityScopedBookmark.shared.saveBookmark(for: newURL, folderID: id) else {
            AppLogger.library.error("Could not obtain security-scoped bookmark for \(newURL.path)")
            return
        }

        settings.linkedFolders[index].name = newURL.lastPathComponent
        settings.linkedFolders[index].path = newURL.path
        settings.linkedFolders[index].bookmarkData = bookmark
        settings.linkedFolderName = settings.linkedFolders.first?.name
        saveSettings()

        await rescanSingleFolder(folder: settings.linkedFolders[index], url: newURL)
    }

    /// Unlinks a specific folder by its UUID, removing its tracks while preserving cache and other folders.
    public func unlinkFolder(id: UUID) {
        SecurityScopedBookmark.shared.stopAccessing(folderID: id)
        settings.linkedFolders.removeAll { $0.id == id }
        settings.linkedFolderName = settings.linkedFolders.first?.name

        // Remove tracks belonging to this folder
        self.tracks.removeAll { $0.folderID == id || (!($0.isJellyfinItem || $0.metadataSource == .server) && self.folder(for: $0)?.id == id) }
        rebuildAlbumsAndArtists()

        self.settings.totalScannedFiles = self.tracks.count
        if settings.linkedFolders.isEmpty {
            self.settings.lastScanDate = nil
            self.duplicateGroups = []
        }

        saveSettings()
        saveLibrary()
        saveDuplicates()

        Task {
            await self.recalculateDuplicates()
        }
        AppLogger.library.info("Unlinked folder [\(id)] successfully.")
    }

    /// Replaces or adds tracks from a Jellyfin server sync.
    public func updateJellyfinTracks(_ serverTracks: [Track], for serverID: UUID) async {
        let removedIDs = self.settings.removedJellyfinItemIDs
        let filteredServerTracks = removedIDs.isEmpty ? serverTracks : serverTracks.filter { track in
            let itemId = track.jellyfinItemId ?? JellyfinPlaybackReporter.extractItemId(from: track)
            if let id = itemId, removedIDs.contains(id) {
                return false
            }
            return true
        }

        let existingServerTracks = self.tracks.filter { $0.folderID == serverID }

        // Never clear or replace server tracks with an empty or partial list on error
        guard !filteredServerTracks.isEmpty || existingServerTracks.isEmpty else {
            return
        }

        let existingIDs = Set(existingServerTracks.map(\.id))
        let newIDs = Set(filteredServerTracks.map(\.id))
        let deletedIDs = existingIDs.subtracting(newIDs)

        let newState = await LibraryRepository.shared.applyChangeSet(
            upserted: filteredServerTracks,
            removedIDs: deletedIDs,
            settings: self.settings,
            verifiedGoodDiffs: self.verifiedGoodDiffs,
            downloadedMetadataCache: self.downloadedMetadataCache
        )

        self.applyLoadedLibraryState(newState)
        self.cachedFolderStats = Self.computeFolderStats(
            tracks: self.tracks,
            linkedFolders: self.settings.linkedFolders,
            jellyfinServers: self.settings.jellyfinServers
        )
        self.settings.totalScannedFiles = self.tracks.count

        saveLibrary()
        let serverBinURL = self.jellyfinServerCacheURL(for: serverID)
        let serverJSONURL = self.jellyfinServerJSONURL(for: serverID)
        Task.detached(priority: .utility) {
            Self.saveFast(filteredServerTracks, to: serverBinURL, jsonURL: serverJSONURL)
        }
        JellyfinArtworkRegistry.shared.populateFromTracks(self.tracks, servers: self.settings.jellyfinServers)

        buildSearchIndex(immediate: false)
    }

    /// Removes all tracks for a linked Jellyfin server and updates settings and storage.
    public func removeJellyfinServer(id: UUID) {
        settings.jellyfinServers.removeAll { $0.id == id }
        jellyfinServerErrors.removeValue(forKey: id)
        jellyfinLastSyncDates.removeValue(forKey: id)
        saveJellyfinLastSyncDates()
        saveSettings()
        self.tracks.removeAll { $0.folderID == id }
        rebuildAlbumsAndArtists()
        saveLibrary()
        let sBinURL = self.jellyfinServerCacheURL(for: id)
        let sJSONURL = self.jellyfinServerJSONURL(for: id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: sBinURL)
            try? FileManager.default.removeItem(at: sJSONURL)
        }
    }

    /// Syncs tracks from a Jellyfin server, updating scan progress and surfacing any errors.
    public func syncJellyfinServer(_ serverLink: JellyfinServerLink) async {
        // Ignore a duplicate request for a server that is already syncing (e.g. double tap).
        if isScanning && currentlyScanningFolderID == serverLink.id { return }
        // Wait for any other scan/sync to finish so their shared scan state (and defers) can't interleave.
        while isScanning {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
        }
        self.isScanning = true
        self.currentlyScanningFolderID = serverLink.id
        self.scanProgress = 0.0
        self.scanStatusText = "SYNCING JELLYFIN (\(serverLink.serverName.uppercased()))..."

        #if os(macOS)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Syncing Jellyfin - \(serverLink.serverName)"
        )
        #elseif os(iOS)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        if UIApplication.shared.applicationState != .active {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "JellyfinSync") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
        }
        #endif

        defer {
            #if os(macOS)
            ProcessInfo.processInfo.endActivity(activity)
            #elseif os(iOS)
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            #endif
            self.isScanning = false
            self.currentlyScanningFolderID = nil
            self.scanProgress = 1.0
            self.scanStatusText = ""
        }

        guard let token = JellyfinKeychain.getToken(forServerId: serverLink.serverId, userId: serverLink.userId) else {
            let errorMsg = "TOKEN MISSING: PLEASE SIGN IN AGAIN"
            self.jellyfinServerErrors[serverLink.id] = errorMsg
            AppLogger.library.error("Jellyfin sync failed: token missing for server \(serverLink.serverName)")
            return
        }

        do {
            await backfillJellyfinPathsIfNeeded(serverLink, token: token)

            let existingServerTracks = self.tracks.filter { $0.folderID == serverLink.id }
            let lastSync = self.jellyfinLastSyncDates[serverLink.id]

            let (progressStream, progressContinuation) = AsyncStream.makeStream(of: (current: Int, total: Int, text: String).self)
            let progressTask = Task { @MainActor in
                for await p in progressStream {
                    if p.total > 0 {
                        self.scanProgress = Double(p.current) / Double(p.total)
                    }
                    self.scanStatusText = p.text
                }
            }

            let syncStartTime = Date()
            let (upserted, removedIDs) = try await JellyfinSyncService.shared.fetchAudioTrackChanges(
                for: serverLink,
                token: token,
                existingTracks: existingServerTracks,
                lastSyncDate: lastSync,
                statusHandler: { status in
                    progressContinuation.yield((current: 0, total: 0, text: "SYNCING JELLYFIN (\(serverLink.serverName.uppercased())): \(status)"))
                },
                progressHandler: { current, total in
                    progressContinuation.yield((current: current, total: total, text: "SYNCING JELLYFIN (\(serverLink.serverName.uppercased())): \(current)/\(total)"))
                }
            )
            progressContinuation.finish()
            _ = await progressTask.result

            self.jellyfinServerErrors.removeValue(forKey: serverLink.id)
            self.jellyfinLastSyncDates[serverLink.id] = syncStartTime
            self.saveJellyfinLastSyncDates()

            let removedSettingIDs = self.settings.removedJellyfinItemIDs
            let filteredUpserted = removedSettingIDs.isEmpty ? upserted : upserted.filter { track in
                let itemId = track.jellyfinItemId ?? JellyfinPlaybackReporter.extractItemId(from: track)
                if let id = itemId, removedSettingIDs.contains(id) {
                    return false
                }
                return true
            }

            // Fast path: server reported no changes, so skip the full library rebuild and saves.
            if filteredUpserted.isEmpty && removedIDs.isEmpty {
                AppLogger.library.info("Jellyfin sync: no changes for \(serverLink.serverName); skipped rebuild.")
                return
            }

            // Jellyfin tracks are always folder-organized (+ active-mode manual overrides)
            let organizeMode = self.settings.libraryScanMethod
            let organizeOverrides = self.organizationModesContainer.state(for: organizeMode).overrides
            let organizedUpserted = await Task.detached(priority: .userInitiated) {
                LibraryOrganizer.organizeBatch(tracks: filteredUpserted, mode: organizeMode, overrides: organizeOverrides)
            }.value

            let newState = await LibraryRepository.shared.applyChangeSet(
                upserted: organizedUpserted,
                removedIDs: removedIDs,
                settings: self.settings,
                verifiedGoodDiffs: self.verifiedGoodDiffs,
                downloadedMetadataCache: self.downloadedMetadataCache
            )
            self.applyLoadedLibraryState(newState)
            let allTracks = self.tracks
            let statsFolders = self.settings.linkedFolders
            let statsServers = self.settings.jellyfinServers
            let serverID = serverLink.id
            let (stats, currentServerTracks) = await Task.detached(priority: .userInitiated) {
                (LibraryStore.computeFolderStats(tracks: allTracks, linkedFolders: statsFolders, jellyfinServers: statsServers),
                 allTracks.filter { $0.folderID == serverID })
            }.value
            self.cachedFolderStats = stats
            self.settings.totalScannedFiles = allTracks.count
            saveLibrary()

            let serverBinURL = self.jellyfinServerCacheURL(for: serverLink.id)
            let serverJSONURL = self.jellyfinServerJSONURL(for: serverLink.id)
            Task.detached(priority: .utility) {
                Self.saveFast(currentServerTracks, to: serverBinURL, jsonURL: serverJSONURL)
            }
            JellyfinArtworkRegistry.shared.populateFromTracks(self.tracks, servers: self.settings.jellyfinServers)
            buildSearchIndex(immediate: false)
            AppLogger.library.info("Jellyfin sync succeeded: \(upserted.count) upserted, \(removedIDs.count) removed for \(serverLink.serverName)")
        } catch {
            let mappedErr = JellyfinClient.mapNetworkError(error)
            let errorMsg = mappedErr.localizedDescription.uppercased()
            self.jellyfinServerErrors[serverLink.id] = errorMsg
            AppLogger.library.error("Jellyfin sync failed: \(errorMsg)")
        }
    }

    /// One-time (per server) backfill of case-preserving, library-relative Jellyfin paths so existing
    /// tracks can be folder-organized without a full re-sync. Fetches only Id+Path; on failure it
    /// simply retries on the next sync.
    private func backfillJellyfinPathsIfNeeded(_ serverLink: JellyfinServerLink, token: String) async {
        let flagKey = "jellyfin_path_backfill_v1_\(serverLink.id.uuidString)"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let serverID = serverLink.id
        guard self.tracks.contains(where: { $0.folderID == serverID }) else {
            // Nothing stored yet: the regular full sync stores correct paths and roots.
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        self.scanStatusText = "SYNCING JELLYFIN (\(serverLink.serverName.uppercased())): READING FOLDERS..."
        do {
            let pathsByItemID = try await JellyfinSyncService.shared.fetchRelativeItemPaths(for: serverLink, token: token)
            let snapshot = self.tracks
            let mode = self.settings.libraryScanMethod
            let overrides = self.organizationModesContainer.state(for: mode).overrides

            let updated: [Track] = await Task.detached(priority: .userInitiated) {
                var result: [Track] = []
                for track in snapshot where track.folderID == serverID {
                    guard let itemID = track.jellyfinItemId, let rel = pathsByItemID[itemID] else { continue }
                    let withPath = track.withIdentity(id: track.id, relativePath: rel)
                    result.append(LibraryOrganizer.organize(track: withPath, mode: mode, override: overrides[track.id]))
                }
                return result
            }.value

            if !updated.isEmpty {
                let newState = await LibraryRepository.shared.applyChangeSet(
                    upserted: updated,
                    removedIDs: [],
                    settings: self.settings,
                    verifiedGoodDiffs: self.verifiedGoodDiffs,
                    downloadedMetadataCache: self.downloadedMetadataCache
                )
                self.applyLoadedLibraryState(newState)
                saveLibrary()

                let serverTracks = self.tracks.filter { $0.folderID == serverID }
                let serverBinURL = self.jellyfinServerCacheURL(for: serverID)
                let serverJSONURL = self.jellyfinServerJSONURL(for: serverID)
                Task.detached(priority: .utility) {
                    Self.saveFast(serverTracks, to: serverBinURL, jsonURL: serverJSONURL)
                }
            }
            if !pathsByItemID.isEmpty {
                UserDefaults.standard.set(true, forKey: flagKey)
            }
            AppLogger.library.info("Jellyfin path backfill: \(updated.count) tracks updated for \(serverLink.serverName)")
        } catch {
            AppLogger.library.warning("Jellyfin path backfill failed (will retry next sync): \(error.localizedDescription)")
        }
    }

    /// Rescans all linked directories and Jellyfin servers.
    public func rescanCurrentDirectory() async {
        guard !isScanning else { return }
        if !settings.linkedFolders.isEmpty {
            for folder in settings.linkedFolders {
                await rescanFolder(id: folder.id)
            }
        } else if let url = SecurityScopedBookmark.shared.resolveAndAccessBookmark() {
            await addAndScanFolder(url: url)
        } else {
            AppLogger.library.warning("No active security-scoped directory available to rescan.")
        }

        for server in settings.jellyfinServers {
            await syncJellyfinServer(server)
        }
    }

    /// Unlinks all music folders and clears scanned library data.
    /// Preserves downloaded metadata cache and artwork cache so re-linking immediately restores all metadata.
    public func unlinkDirectory() {
        SecurityScopedBookmark.shared.clearSavedBookmark()
        for f in settings.linkedFolders {
            SecurityScopedBookmark.shared.stopAccessing(folderID: f.id)
        }
        settings.linkedFolders = []
        settings.linkedFolderName = nil
        settings.lastScanDate = nil
        settings.totalScannedFiles = 0
        self.tracks = []
        self.tracksByID = [:]
        self.albums = []
        self.albumsByID = [:]
        self.albumsByNormalizedKey = [:]
        self.artists = []
        self.artistLookupIndex = [:]
        self.duplicateGroups = []
        saveSettings()
        saveLibrary()
        saveDuplicates()
        // NOTE: downloadedMetadataCache and ArtworkCacheService are intentionally kept intact on disk!
        AppLogger.library.info("Unlinked directory while safely preserving downloaded metadata and artwork cache.")
    }

    // Rescans an individual folder directory and integrates its tracks
    private func rescanSingleFolder(folder: LinkedFolder, url: URL) async {
        guard !isScanning else { return }
        self.isScanning = true
        self.currentlyScanningFolderID = folder.id
        self.scanProgress = 0.0
        self.scanStatusText = "Scanning \(folder.name)..."

        #if os(macOS)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Scanning Music Library - \(folder.name)"
        )
        #elseif os(iOS)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        if UIApplication.shared.applicationState != .active {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "MusicLibraryScan") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
        }
        #endif

        defer {
            #if os(macOS)
            ProcessInfo.processInfo.endActivity(activity)
            #elseif os(iOS)
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            #endif
            self.isScanning = false
            self.currentlyScanningFolderID = nil
        }

        let folderID = folder.id
        let folderName = folder.name
        let folderPath = folder.path
        let scanMethod = self.settings.libraryScanMethod
        let removedPaths = self.settings.removedTrackPaths
        let joinedArtists = self.settings.joinedArtists
        let manualCollaborativeAlbumIDs = self.settings.manualCollaborativeAlbumIDs
        let originalAlbumArtistsByTrackID = self.settings.originalAlbumArtistsByTrackID
        let metadataCache = self.downloadedMetadataCache
        let goodDiffs = self.verifiedGoodDiffs
        let currentTracks = self.tracks
        let currentLinkedFolders = self.settings.linkedFolders
        let currentJellyfinServers = self.settings.jellyfinServers

        let folderCanonical = url.standardizedFileURL.path
        let folderPathCanonical = (folderPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) ?? folderCanonical
        let folderPathRaw = folderPath ?? folderCanonical

        @Sendable func isFolderTrack(_ track: Track) -> Bool {
            if let fID = track.folderID {
                return fID == folderID
            }
            let trackPath = track.url.path
            return trackPath.hasPrefix(folderCanonical) || trackPath.hasPrefix(folderPathCanonical) || trackPath.hasPrefix(folderPathRaw)
        }

        let folderTracks = currentTracks.filter { isFolderTrack($0) }
        let otherTracks = currentTracks.filter { !isFolderTrack($0) }

        let (progressStream, progressContinuation) = AsyncStream.makeStream(of: (current: Int, total: Int, name: String).self)
        let progressTask = Task { @MainActor in
            for await p in progressStream {
                self.scanProgress = p.total > 0 ? Double(p.current) / Double(p.total) : 0.0
                self.scanStatusText = "Processing (\(p.current)/\(p.total)): \(p.name)"
            }
        }

        // Execute scanning and tag enrichment in background
        let scannedTracks = await Task.detached(priority: .userInitiated) { () -> [Track] in
            let tracks = await AudioScannerService.shared.scanDirectory(
                at: url,
                existingTracks: folderTracks,
                scanMethod: scanMethod
            ) { current, total, name in
                progressContinuation.yield((current: current, total: total, name: name))
            }
            progressContinuation.finish()
            return tracks
        }.value

        _ = await progressTask.result
        let tScanDone = Date()
        AppLogger.library.debug("SCAN TIMING: file scan finished, \(scannedTracks.count) tracks")

        var filteredTracks = scannedTracks
            .filter { !removedPaths.contains($0.url.standardizedFileURL.path) }
            .map { $0.withFolderID(folderID) }

        // Re-attach cached online metadata and artwork to newly scanned tracks
        for i in 0..<filteredTracks.count {
            if let record = Self.lookupCachedMetadata(for: filteredTracks[i], in: metadataCache) {
                if record.wasApplied {
                    let appliedArtist: String = {
                        if let a = record.appliedArtist, !a.isEmpty, !MetadataSanitizer.isUnknownArtist(a) {
                            return a
                        }
                        return filteredTracks[i].artist
                    }()
                    let appliedAlbum: String = {
                        if let a = record.appliedAlbum, !a.isEmpty, !MetadataSanitizer.isUnknownAlbum(a) {
                            return a
                        }
                        return filteredTracks[i].album
                    }()
                    let appliedTitle: String = {
                        if let t = record.appliedTitle, !t.isEmpty, !MetadataSanitizer.isUnknownTitle(t) {
                            return t
                        }
                        return filteredTracks[i].title
                    }()

                    filteredTracks[i] = Track(
                        id: filteredTracks[i].id,
                        title: appliedTitle,
                        artist: appliedArtist,
                        album: appliedAlbum,
                        albumArtist: record.appliedAlbumArtist ?? filteredTracks[i].albumArtist,
                        composer: filteredTracks[i].composer,
                        performer: filteredTracks[i].performer,
                        genre: record.appliedGenre ?? filteredTracks[i].genre,
                        year: record.appliedYear ?? filteredTracks[i].year,
                        trackNumber: record.appliedTrackNumber ?? filteredTracks[i].trackNumber,
                        originalTrackNumber: record.appliedOriginalTrackNumber ?? filteredTracks[i].originalTrackNumber,
                        deluxeTrackNumber: record.appliedDeluxeTrackNumber ?? filteredTracks[i].deluxeTrackNumber,
                        totalTracks: record.appliedTotalTracks ?? filteredTracks[i].totalTracks,
                        discNumber: record.appliedDiscNumber ?? filteredTracks[i].discNumber,
                        discTotal: filteredTracks[i].discTotal,
                        duration: filteredTracks[i].duration,
                        url: filteredTracks[i].url,
                        artworkKey: record.cachedArtworkKey ?? filteredTracks[i].artworkKey,
                        dateAdded: filteredTracks[i].dateAdded,
                        fileInfo: filteredTracks[i].fileInfo,
                        lyrics: filteredTracks[i].lyrics,
                        isAlternate: filteredTracks[i].isAlternate,
                        folderID: folderID,
                        relativePath: filteredTracks[i].relativePath,
                        metadataSource: filteredTracks[i].metadataSource,
                        tagSnapshot: filteredTracks[i].tagSnapshot
                    )
                } else if filteredTracks[i].artworkKey == nil, let artKey = record.cachedArtworkKey {
                    filteredTracks[i] = filteredTracks[i].withArtworkKey(artKey)
                }
            }
        }

        AppLogger.library.debug("SCAN TIMING: metadata reattach \(String(format: "%.2f", Date().timeIntervalSince(tScanDone)))s")

        // FOLDER mode: artist/album/title come only from the path, using the same organizer as mode switching.
        if scanMethod == .folderHierarchy {
            let toOrganize = filteredTracks
            let folderOverrides = self.organizationModesContainer.state(for: .folderHierarchy).overrides
            let layout = self.settings.folderHierarchyLayout
            let rootNames: [UUID: String] = [folderID: folderName]
            filteredTracks = await Task.detached(priority: .userInitiated) {
                LibraryOrganizer.organizeBatch(
                    tracks: toOrganize,
                    mode: .folderHierarchy,
                    overrides: folderOverrides,
                    layout: layout,
                    rootFolderNames: rootNames
                )
            }.value
        }
        let existingFolderIDs = Set(folderTracks.map(\.id))
        let scannedIDs = Set(filteredTracks.map(\.id))
        let removedFolderIDs = existingFolderIDs.subtracting(scannedIDs)

        // Fast path: nothing in this folder changed, so skip the full library rebuild and saves.
        if removedFolderIDs.isEmpty && Set(filteredTracks) == Set(folderTracks) {
            self.settings.lastScanDate = Date()
            self.scanProgress = 1.0
            self.scanStatusText = "Scan complete for \(folderName). No changes."
            AppLogger.library.info("Folder [\(folderName)] unchanged; skipped rebuild.")
            return
        }

        let tRebuild = Date()
        let newState = await LibraryRepository.shared.applyChangeSet(
            upserted: filteredTracks,
            removedIDs: removedFolderIDs,
            settings: self.settings,
            verifiedGoodDiffs: goodDiffs,
            downloadedMetadataCache: metadataCache
        )

        AppLogger.library.debug("SCAN TIMING: library rebuild \(String(format: "%.2f", Date().timeIntervalSince(tRebuild)))s")
        let tApply = Date()
        self.applyLoadedLibraryState(newState)
        AppLogger.library.debug("SCAN TIMING: apply to UI \(String(format: "%.2f", Date().timeIntervalSince(tApply)))s")
        let statsTracks = self.tracks
        let statsFolders = self.settings.linkedFolders
        let statsServers = self.settings.jellyfinServers
        self.cachedFolderStats = await Task.detached(priority: .userInitiated) {
            LibraryStore.computeFolderStats(tracks: statsTracks, linkedFolders: statsFolders, jellyfinServers: statsServers)
        }.value

        // Cache baseline metadata for newly indexed tracks non-blockingly
        let tCache = Date()
        self.cacheScannedTracks(filteredTracks)
        AppLogger.library.debug("SCAN TIMING: metadata cache \(String(format: "%.2f", Date().timeIntervalSince(tCache)))s, total after scan \(String(format: "%.2f", Date().timeIntervalSince(tScanDone)))s")

        self.settings.lastScanDate = Date()
        self.settings.totalScannedFiles = self.tracks.count
        self.scanProgress = 1.0
        self.scanStatusText = "Scan complete for \(folderName). Indexed \(filteredTracks.count) tracks."

        // Save state non-blockingly
        saveLibrary()
        saveSettings()
        saveEnrichmentCache()

        let currentTracksToSearch = self.tracks

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let groups = await DuplicateDetectionService.shared.analyzeDuplicates(in: currentTracksToSearch)
            await MainActor.run {
                self.duplicateGroups = groups
                self.saveDuplicates()
            }
        }

        AppLogger.library.info("Folder [\(folderName)] scanned with \(filteredTracks.count) tracks.")
    }

    // MARK: - Playlist Operations

    /// Creates a new user playlist.
    @discardableResult
    public func createPlaylist(name: String, description: String = "") -> Playlist {
        // Trimmed name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Final name
        let finalName = trimmedName.isEmpty ? "New Playlist" : trimmedName

        // Playlist
        let playlist = Playlist(
            name: finalName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            isPinned: false,
            trackIDs: []
        )
        playlists.append(playlist)
        savePlaylists()
        AppLogger.library.info("Created playlist: \(playlist.name)")
        return playlist
    }

    /// Deletes a playlist by ID.
    public func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        // Id string
        let idString = id.uuidString
        pinnedItemIDs.removeAll { $0.type == .playlist && $0.targetID == idString }
        if lastAddedPlaylistID == id {
            lastAddedPlaylistID = nil
            UserDefaults.standard.removeObject(forKey: "last_added_playlist_id_v1")
        }
        savePlaylists()
        savePins()
    }

    /// Deletes a playlist.
    public func deletePlaylist(_ playlist: Playlist) {
        deletePlaylist(id: playlist.id)
    }

    /// Returns whether a given album is currently pinned to the Home screen.
    public func isAlbumPinned(_ album: Album) -> Bool {
        pinnedAlbumIDs.contains(album.id)
    }

    /// Returns whether a given playlist is currently pinned.
    public func isPlaylistPinned(_ playlist: Playlist) -> Bool {
        playlist.isPinned
    }

    /// Toggles the pinned status of an album.
    public func togglePinAlbum(_ album: Album) {
        if pinnedAlbumIDs.contains(album.id) {
            pinnedAlbumIDs.remove(album.id)
            pinnedItemIDs.removeAll { $0.type == .album && $0.targetID == album.id }
        } else {
            pinnedAlbumIDs.insert(album.id)
            pinnedItemIDs.append(PinnedItemIdentifier(type: .album, targetID: album.id))
        }
        savePins()
    }

    /// Toggles the pinned status of a playlist by ID.
    public func togglePinPlaylist(id: UUID) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].isPinned.toggle()
        playlists[index].dateModified = Date()
        // Id string
        let idString = id.uuidString
        if playlists[index].isPinned {
            if !pinnedItemIDs.contains(where: { $0.type == .playlist && $0.targetID == idString }) {
                pinnedItemIDs.append(PinnedItemIdentifier(type: .playlist, targetID: idString))
            }
        } else {
            pinnedItemIDs.removeAll { $0.type == .playlist && $0.targetID == idString }
        }
        savePlaylists()
        savePins()
    }

    /// Toggles the pinned status of a playlist.
    public func togglePinPlaylist(_ playlist: Playlist) {
        togglePinPlaylist(id: playlist.id)
    }

    /// Moves a pinned item between positions on the Home screen.
    public func movePin(sourceID: String, targetID: String) {
        // Ensure preconditions are met before proceeding
        guard let from = pinnedItemIDs.firstIndex(where: { $0.id == sourceID }),
              // To
              let to = pinnedItemIDs.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        // Item
        let item = pinnedItemIDs.remove(at: from)
        pinnedItemIDs.insert(item, at: to)
        savePins()
    }

    /// Reorders pins from IndexSet to offset.
    public func reorderPins(fromOffsets: IndexSet, toOffset: Int) {
        pinnedItemIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        savePins()
    }

    /// Adds a track to a playlist.
    public func addTrack(_ track: Track, toPlaylistID playlistID: UUID) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        lastAddedPlaylistID = playlistID
        UserDefaults.standard.set(playlistID.uuidString, forKey: "last_added_playlist_id_v1")
        if !playlists[index].trackIDs.contains(track.id) {
            playlists[index].trackIDs.append(track.id)
            playlists[index].dateModified = Date()
            savePlaylists()
        }
    }

    /// Adds multiple tracks to a playlist, preserving existing items and preventing duplicates.
    public func addTracks(_ newTracks: [Track], toPlaylistID playlistID: UUID) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        lastAddedPlaylistID = playlistID
        UserDefaults.standard.set(playlistID.uuidString, forKey: "last_added_playlist_id_v1")
        // Unique identifier for updated track i ds
        var updatedTrackIDs = playlists[index].trackIDs
        var seenTrackIDs = Set(updatedTrackIDs)
        for track in newTracks {
            if seenTrackIDs.insert(track.id).inserted {
                updatedTrackIDs.append(track.id)
            }
        }
        playlists[index].trackIDs = updatedTrackIDs
        playlists[index].dateModified = Date()
        savePlaylists()
    }

    /// Removes a track from a playlist.
    public func removeTrack(trackID: UUID, fromPlaylistID playlistID: UUID) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        playlists[index].dateModified = Date()
        savePlaylists()
    }

    /// Moves a track from one playlist to another playlist.
    public func moveTrack(_ track: Track, fromPlaylistID sourceID: UUID, toPlaylistID destinationID: UUID) {
        removeTrack(trackID: track.id, fromPlaylistID: sourceID)
        addTrack(track, toPlaylistID: destinationID)
    }

    /// Reorders tracks within a playlist.
    public func reorderPlaylistTracks(playlistID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        playlists[index].dateModified = Date()
        savePlaylists()
    }

    /// Moves a track from a source ID to a target ID position in a playlist.
    public func movePlaylistTrack(playlistID: UUID, sourceID: UUID, targetID: UUID) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              // From
              let from = playlists[index].trackIDs.firstIndex(of: sourceID),
              // To
              let to = playlists[index].trackIDs.firstIndex(of: targetID) else { return }
        // Ensure preconditions are met before proceeding
        guard from != to else { return }
        // Unique identifier for track id
        let trackID = playlists[index].trackIDs.remove(at: from)
        playlists[index].trackIDs.insert(trackID, at: to)
        playlists[index].dateModified = Date()
        savePlaylists()
    }

    /// Sorts tracks within a playlist according to the specified criteria.
    public func sortPlaylistTracks(playlistID: UUID, by criteria: PlaylistTrackSortCriteria) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // Current tracks
        let currentTracks = tracks(for: playlists[index])
        // Sorted
        let sorted: [Track]
        switch criteria {
        case .custom:
            return
        case .name:
            sorted = currentTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            sorted = currentTracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:
            sorted = currentTracks.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .favorite:
            sorted = currentTracks.sorted {
                // P 1
                let p1 = playCount(for: $0.id)
                // P 2
                let p2 = playCount(for: $1.id)
                if p1 != p2 { return p1 > p2 }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .newest:
            sorted = currentTracks.sorted {
                if let y1 = $0.year, let y2 = $1.year, y1 != y2 {
                    return y1 > y2
                }
                return $0.dateAdded > $1.dateAdded
            }
        case .oldest:
            sorted = currentTracks.sorted {
                if let y1 = $0.year, let y2 = $1.year, y1 != y2 {
                    return y1 < y2
                }
                return $0.dateAdded < $1.dateAdded
            }
        }
        playlists[index].trackIDs = sorted.map { $0.id }
        playlists[index].dateModified = Date()
        savePlaylists()
    }

    // MARK: - Play Counts & Statistics

    /// Increments the play counter for a given track ID and persists state.
    public func incrementPlayCount(for trackID: UUID) {
        playCounts[trackID, default: 0] += 1
        savePlayCounts()
    }

    /// Returns the number of times a track has been played.
    public func playCount(for trackID: UUID) -> Int {
        playCounts[trackID] ?? 0
    }

    /// Updates playlist metadata including name, description, and custom artwork key.
    public func updatePlaylist(id: UUID, name: String, description: String = "", customArtworkKey: String? = nil) {
        // Ensure preconditions are met before proceeding
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        // Trimmed
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].name = trimmed.isEmpty ? "Playlist" : trimmed
        playlists[index].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].customArtworkKey = customArtworkKey
        playlists[index].dateModified = Date()
        savePlaylists()
    }

    /// Resolves the artwork key for a playlist (custom artwork or first track with artwork).
    public func artworkKey(for playlist: Playlist) -> String? {
        if let custom = playlist.customArtworkKey, !custom.isEmpty {
            return custom
        }
        // Pl tracks
        let plTracks = tracks(for: playlist)
        return plTracks.first(where: { $0.artworkKey != nil })?.artworkKey
    }

    /// Returns resolved `[Track]` objects for a given playlist.
    public func tracks(for playlist: Playlist) -> [Track] {
        let trackMap = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.trackIDs.compactMap { trackMap[$0] }
    }

    /// Returns resolved `[Track]` objects for a given playlist ID.
    public func tracks(forPlaylistID id: UUID) -> [Track] {
        // Ensure preconditions are met before proceeding
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        return tracks(for: playlist)
    }

    // MARK: - Joined Artists Management

    /// Checks if a raw artist string matches an active joined artist rule.
    public func isArtistJoined(rawArtist: String) -> Bool {
        // Clean
        let clean = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Ensure preconditions are met before proceeding
        guard !clean.isEmpty else { return false }
        return settings.joinedArtists.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == clean }
    }

    /// Adds a joined artist rule for a multi-artist collaboration string and triggers a library re-index.
    public func joinArtists(for rawArtist: String) {
        // Clean
        let clean = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !clean.isEmpty else { return }
        if !isArtistJoined(rawArtist: clean) {
            settings.joinedArtists.append(clean)
            saveSettings()
            rebuildAlbumsAndArtists()
        }
    }

    /// Removes a joined artist rule and re-indexes back to individual artists.
    public func unjoinArtists(for rawArtist: String) {
        // Clean
        let clean = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        settings.joinedArtists.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == clean }
        saveSettings()
        rebuildAlbumsAndArtists()
    }

    // MARK: - Multi-Artist Parsing & Album Aggregation

    // Precompiled static edition regexes to avoid compilation overhead on every track
    nonisolated(unsafe) private static let editionRegexes: [NSRegularExpression] = {
        let patterns = [
            #"\s*[\(\[](?:deluxe(?:\s+(?:edition|version|ep|set|package))?|expanded(?:\s+(?:edition|version))?|super\s+deluxe(?:\s+edition)?|special\s+edition|collector'?s?\s+edition|bonus\s+track(?:s)?\s*(?:version|edition)?|international\s+version|anniversary(?:\s+edition)?|remastered(?:\s+edition)?|standard\s+(?:version|edition)|explicit(?:\s+version)?|clean(?:\s+version)?|remix(?:es)?(?:\s+&\s+alternates?)?|alternates?|alternatives?|live(?:\s+recording(?:s)?)?|instrumentals?|acoustics?)[\)\]]"#,
            #"\s*-\s*(?:deluxe(?:\s+(?:edition|version|ep))?|expanded(?:\s+edition)?|super\s+deluxe|special\s+edition|remastered|anniversary\s+edition|bonus\s+tracks?|remix(?:es)?|alternates?|alternatives?|live|instrumentals?|acoustics?)"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    nonisolated(unsafe) private static let cdDiscFolderRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"/(?:cd|disc|disk)\s*\d+"#, options: [.caseInsensitive])
    }()

    // Normalize album title for clustering (static, high speed)
    nonisolated public static func normalizeAlbumTitleForClustering(_ rawTitle: String) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return "unknown album" }

        for regex in editionRegexes {
            let range = NSRange(location: 0, length: title.utf16.count)
            title = regex.stringByReplacingMatches(in: title, options: [], range: range, withTemplate: "")
        }

        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? rawTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    public func normalizeAlbumTitleForClustering(_ rawTitle: String) -> String {
        Self.normalizeAlbumTitleForClustering(rawTitle)
    }

    private struct TrackClusterItem {
        let track: Track
        let canonicalArtists: Set<String>
        let canonicalAlbumArtist: String?
        let cleanFolder: String
        let artworkKey: String?
    }

    nonisolated private static func cleanFolderForTrack(url: URL) -> String {
        let path = url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        guard let regex = cdDiscFolderRegex else { return path }
        let range = NSRange(location: 0, length: path.utf16.count)
        return regex.stringByReplacingMatches(in: path, options: [], range: range, withTemplate: "")
    }

    /// High-performance nonisolated album and artist synthesis engine.
    /// Runs seamlessly in background tasks without locking the UI main thread.
    nonisolated public static func buildAlbumsAndArtists(
        tracks: [Track],
        joinedArtists: [String],
        manualCollaborativeAlbumIDs: Set<String>,
        originalAlbumArtistsByTrackID: [String: String],
        verifiedGoodDiffs: [MetadataDiff],
        downloadedMetadataCache: PersistentDownloadedMetadataCache,
        scanMethod: LibraryScanMethod = .id3Tags
    ) -> AlbumsAndArtistsResult {
        var workingTracks = tracks
        let trackIndexByID: [UUID: Int] = Dictionary(workingTracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var tracksModified = false

        // 1. Initial grouping strictly by Album
        var albumTitleBuckets: [String: [TrackClusterItem]] = [:]
        var standaloneSingleTracks: [Track] = []

        for track in tracks {
            // Jellyfin is always folder-grouped (when a genuine server path exists); local only in FOLDER mode
            let folderGroupingPath: String? = track.isJellyfinItem
                ? LibraryOrganizer.jellyfinFolderPath(for: track)
                : (scanMethod == .folderHierarchy ? track.relativePath : nil)
            if let relPath = folderGroupingPath {
                let parsed = FolderPathMetadataParser.parse(relativePath: relPath)
                let folderKey = (track.folderID?.uuidString ?? "") + "_" + parsed.albumDirectory
                let item = TrackClusterItem(
                    track: track,
                    canonicalArtists: Set(ArtistParser.parseArtists(from: track.artist).map { ArtistParser.canonicalArtistKey($0) }),
                    canonicalAlbumArtist: track.albumArtist.flatMap { ArtistParser.canonicalArtistKey($0) },
                    cleanFolder: folderKey,
                    artworkKey: track.artworkKey
                )
                albumTitleBuckets[folderKey, default: []].append(item)
                continue
            }

            let trimmedAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedAlbum.isEmpty || trimmedAlbum.lowercased() == "unknown album" || trimmedAlbum.lowercased() == "unknown" {
                standaloneSingleTracks.append(track)
                continue
            }

            let baseNormAlbum = normalizeAlbumTitleForClustering(trimmedAlbum)
            let cleanFolder: String
            if track.isJellyfinItem || track.metadataSource == .server {
                cleanFolder = "jf_album_\(track.jellyfinAlbumId ?? track.jellyfinItemId ?? "")"
            } else {
                cleanFolder = cleanFolderForTrack(url: track.url)
            }
            let item = TrackClusterItem(
                track: track,
                canonicalArtists: Set(ArtistParser.parseArtists(from: track.artist).map { ArtistParser.canonicalArtistKey($0) }),
                canonicalAlbumArtist: track.albumArtist.flatMap { ArtistParser.canonicalArtistKey($0) },
                cleanFolder: cleanFolder,
                artworkKey: track.artworkKey
            )
            albumTitleBuckets[baseNormAlbum, default: []].append(item)
        }

        let tBuild = Date()
        var rawAlbumClusters: [[Track]] = []

        // Process each album title bucket: merge tracks into unified albums
        for (_, itemsInBucket) in albumTitleBuckets {
            var subClusters: [[TrackClusterItem]] = []

            for item in itemsInBucket {
                var mergedIndices: [Int] = []
                for (idx, cluster) in subClusters.enumerated() {
                    let isRelated = cluster.contains { other in
                        // 1. Same directory/folder
                        if !item.cleanFolder.isEmpty && item.cleanFolder == other.cleanFolder {
                            return true
                        }
                        // 2. Shared artwork key
                        if let art = item.artworkKey, !art.isEmpty, let otherArt = other.artworkKey, !otherArt.isEmpty, art == otherArt {
                            return true
                        }
                        // 3. Shared album artist
                        if let albArt = item.canonicalAlbumArtist, !albArt.isEmpty, let otherAlb = other.canonicalAlbumArtist, !otherAlb.isEmpty, albArt == otherAlb {
                            return true
                        }
                        // 4. Overlapping artists
                        if !item.canonicalArtists.isDisjoint(with: other.canonicalArtists) {
                            return true
                        }
                        return false
                    }

                    if isRelated {
                        mergedIndices.append(idx)
                    }
                }

                if mergedIndices.isEmpty {
                    subClusters.append([item])
                } else {
                    var combined: [TrackClusterItem] = [item]
                    for idx in mergedIndices.sorted(by: >) {
                        combined.append(contentsOf: subClusters.remove(at: idx))
                    }
                    subClusters.append(combined)
                }
            }

            rawAlbumClusters.append(contentsOf: subClusters.map { $0.map { $0.track } })
        }

        AppLogger.library.debug("REBUILD TIMING: album clustering \(String(format: "%.2f", Date().timeIntervalSince(tBuild)))s")
        var newAlbums: [Album] = []
        newAlbums.reserveCapacity(rawAlbumClusters.count + standaloneSingleTracks.count)

        for singleTrack in standaloneSingleTracks {
            let album = Album(
                title: singleTrack.album.isEmpty ? "Unknown Album" : singleTrack.album,
                artist: singleTrack.artist.isEmpty ? "Unknown Artist" : singleTrack.artist,
                year: singleTrack.year,
                artworkKey: singleTrack.artworkKey,
                tracks: [singleTrack]
            )
            newAlbums.append(album)
        }

        // Jellyfin AlbumIds shared by more than one cluster (e.g. tag-merged folders) get a folder suffix
        // so album IDs stay unique; single-cluster AlbumIds keep their stable "jf_album_<id>" key.
        var jellyfinAlbumIDClusterCounts: [String: Int] = [:]
        for cluster in rawAlbumClusters {
            if let f = cluster.first, f.isJellyfinItem, let aid = f.jellyfinAlbumId, !aid.isEmpty {
                jellyfinAlbumIDClusterCounts[aid, default: 0] += 1
            }
        }

        for groupTracks in rawAlbumClusters {
            guard let first = groupTracks.first else { continue }

            let baseAlbumTitle = first.album.isEmpty ? "Unknown Album" : first.album.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let albumTitle = baseAlbumTitle

            var seenTrackIDs = Set<UUID>()
            var uniqueClusterTracks: [Track] = []
            uniqueClusterTracks.reserveCapacity(groupTracks.count)
            for t in groupTracks {
                if seenTrackIDs.insert(t.id).inserted {
                    uniqueClusterTracks.append(t)
                }
            }

            // Smart Display Artist determination
            let explicitAlbumArtist = groupTracks.compactMap { $0.albumArtist?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }.first { !$0.isEmpty && !MetadataSanitizer.isUnknownArtist($0) && $0.lowercased() != "various artists" && $0.lowercased() != "various" }
            let resolvedArtists = ArtistParser.resolveAlbumArtists(
                for: uniqueClusterTracks,
                explicitAlbumArtist: explicitAlbumArtist,
                joinedArtists: joinedArtists
            )
            let displayArtist = ArtistParser.formatDisplayArtist(resolvedArtists)

            // Propagate artwork consensus across album tracks
            let albumArtworkKey = Album.computeConsensusArtworkKey(
                tracks: uniqueClusterTracks,
                fallbackKey: groupTracks.compactMap({ $0.artworkKey }).first(where: { !$0.isEmpty })
            )

            if let validArtworkKey = albumArtworkKey, !validArtworkKey.isEmpty {
                for i in 0..<uniqueClusterTracks.count {
                    if uniqueClusterTracks[i].artworkKey == nil || uniqueClusterTracks[i].artworkKey?.isEmpty == true {
                        uniqueClusterTracks[i] = uniqueClusterTracks[i].withArtworkKey(validArtworkKey)
                        if let globalIdx = trackIndexByID[uniqueClusterTracks[i].id] {
                            workingTracks[globalIdx] = workingTracks[globalIdx].withArtworkKey(validArtworkKey)
                            tracksModified = true
                        }
                    }
                }
            }

            // Determine release year from track consensus
            let trackYears = uniqueClusterTracks.compactMap { $0.year }.filter { $0 > 0 }
            let yearFrequencies = Dictionary(grouping: trackYears, by: { $0 }).mapValues { $0.count }
            let consensusYear: Int? = {
                if let mostFrequent = yearFrequencies.max(by: { $0.value < $1.value }) {
                    return mostFrequent.key
                }
                return uniqueClusterTracks.compactMap({ $0.year }).first(where: { $0 > 0 }) ?? first.year
            }()

            if let validConsensusYear = consensusYear, validConsensusYear > 0 {
                for i in 0..<uniqueClusterTracks.count {
                    if uniqueClusterTracks[i].year == nil || uniqueClusterTracks[i].year == 0 {
                        uniqueClusterTracks[i] = uniqueClusterTracks[i].withYear(validConsensusYear)
                        if let globalIdx = trackIndexByID[uniqueClusterTracks[i].id] {
                            workingTracks[globalIdx] = workingTracks[globalIdx].withYear(validConsensusYear)
                            tracksModified = true
                        }
                    }
                }
            }

            // Instant Album Artist Consensus Propagation
            let resolvedAlbumArtist = explicitAlbumArtist ?? (displayArtist.isEmpty || MetadataSanitizer.isUnknownArtist(displayArtist) ? nil : displayArtist)
            if let validAlbumArtist = resolvedAlbumArtist, !validAlbumArtist.isEmpty, !MetadataSanitizer.isUnknownArtist(validAlbumArtist) {
                for i in 0..<uniqueClusterTracks.count {
                    let trackArtist = uniqueClusterTracks[i].artist.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trackArtist.isEmpty || MetadataSanitizer.isUnknownArtist(trackArtist) {
                        uniqueClusterTracks[i] = uniqueClusterTracks[i].withArtist(validAlbumArtist)
                        if let globalIdx = trackIndexByID[uniqueClusterTracks[i].id] {
                            workingTracks[globalIdx] = workingTracks[globalIdx].withArtist(validAlbumArtist)
                            tracksModified = true
                        }
                    }
                }
            }

            let sortedAlbumTracks = uniqueClusterTracks.sorted { t1, t2 in
                let d1 = t1.discNumber ?? 1
                let d2 = t2.discNumber ?? 1
                if d1 != d2 { return d1 < d2 }

                let n1 = t1.trackNumber ?? 0
                let n2 = t2.trackNumber ?? 0
                if n1 > 0 && n2 > 0 && n1 != n2 {
                    return n1 < n2
                }
                if n1 > 0 && n2 == 0 { return true }
                if n1 == 0 && n2 > 0 { return false }

                return t1.title.localizedCaseInsensitiveCompare(t2.title) == .orderedAscending
            }

            let groupKey: String? = {
                if first.isJellyfinItem || first.metadataSource == .server {
                    if let albumId = first.jellyfinAlbumId, !albumId.isEmpty {
                        if (jellyfinAlbumIDClusterCounts[albumId] ?? 0) > 1 {
                            let folderPart = LibraryOrganizer.jellyfinFolderPath(for: first)
                                .map { FolderPathMetadataParser.parse(relativePath: $0).albumDirectory } ?? first.id.uuidString
                            return "jf_album_\(albumId)_\(folderPart)"
                        }
                        return "jf_album_\(albumId)"
                    }
                    if let itemId = first.jellyfinItemId, !itemId.isEmpty {
                        return "jf_album_\(itemId)"
                    }
                    return "jf_album_\(first.folderID?.uuidString ?? "")_\(first.album)"
                }
                if scanMethod == .folderHierarchy, let firstRel = first.relativePath {
                    let parsed = FolderPathMetadataParser.parse(relativePath: firstRel)
                    return (first.folderID?.uuidString ?? "") + "_" + parsed.albumDirectory
                }
                return nil
            }()

            let album = Album(
                title: albumTitle,
                artist: displayArtist.isEmpty ? "Unknown Artist" : displayArtist,
                year: consensusYear,
                genre: first.genre,
                artworkKey: albumArtworkKey,
                tracks: sortedAlbumTracks,
                groupKey: groupKey
            )
            newAlbums.append(album)
        }

        // Deduplicate album IDs
        var uniqueAlbums: [Album] = []
        var seenAlbumIDs = Set<String>()
        uniqueAlbums.reserveCapacity(newAlbums.count)
        for album in newAlbums {
            if seenAlbumIDs.insert(album.id).inserted {
                uniqueAlbums.append(album)
            }
        }

        // Apply manual collaborative albums if any exist
        if !manualCollaborativeAlbumIDs.isEmpty {
            for i in 0..<uniqueAlbums.count {
                if manualCollaborativeAlbumIDs.contains(uniqueAlbums[i].id) {
                    var distinctArtists: [String] = []
                    var seen = Set<String>()
                    for track in uniqueAlbums[i].tracks {
                        for a in ArtistParser.parseArtists(from: track.artist) {
                            let clean = a.trimmingCharacters(in: .whitespacesAndNewlines)
                            let canon = ArtistParser.canonicalArtistKey(clean)
                            if !canon.isEmpty && !ArtistParser.isGenericArtistName(clean) && seen.insert(canon).inserted {
                                distinctArtists.append(clean)
                            }
                        }
                    }
                    if !distinctArtists.isEmpty {
                        let unified = ArtistParser.formatDisplayArtist(distinctArtists)
                        let albTrackIDs = Set(uniqueAlbums[i].tracks.map { $0.id })
                        for tIdx in 0..<workingTracks.count {
                            if albTrackIDs.contains(workingTracks[tIdx].id) {
                                workingTracks[tIdx] = workingTracks[tIdx].withAlbumArtist(unified)
                                tracksModified = true
                            }
                        }
                        uniqueAlbums[i] = Album(
                            title: uniqueAlbums[i].title,
                            artist: unified,
                            year: uniqueAlbums[i].year,
                            genre: uniqueAlbums[i].genre,
                            artworkKey: uniqueAlbums[i].artworkKey,
                            tracks: uniqueAlbums[i].tracks.map { $0.withAlbumArtist(unified) }
                        )
                    }
                }
            }
        }

        let sortedAlbums = uniqueAlbums.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        AppLogger.library.debug("REBUILD TIMING: albums built \(String(format: "%.2f", Date().timeIntervalSince(tBuild)))s")
        // 2. High-Speed Inverted Index for Track -> Albums
        var trackIDToAlbumsMap: [UUID: [Album]] = [:]
        trackIDToAlbumsMap.reserveCapacity(workingTracks.count)
        for album in sortedAlbums {
            for track in album.tracks {
                trackIDToAlbumsMap[track.id, default: []].append(album)
            }
        }

        // 3. Multi-Artist & Title Feature Extraction
        var verifiedArtistNames: [String: String] = [:]
        for diff in verifiedGoodDiffs {
            let parsed = ArtistParser.parseArtists(from: diff.onlineMetadata.artist)
            for a in parsed {
                let k = ArtistParser.canonicalArtistKey(a)
                if !k.isEmpty && !ArtistParser.isGenericArtistName(a) {
                    verifiedArtistNames[k] = a
                }
            }
        }
        for (_, record) in downloadedMetadataCache.recordsByFilePath {
            let parsed = ArtistParser.parseArtists(from: record.onlineMetadata.artist)
            for a in parsed {
                let k = ArtistParser.canonicalArtistKey(a)
                if !k.isEmpty && !ArtistParser.isGenericArtistName(a) {
                    verifiedArtistNames[k] = a
                }
            }
        }

        var artistTracksMap: [String: (variantCounts: [String: Int], tracks: [Track], seenTrackIDs: Set<UUID>)] = [:]

        for track in workingTracks {
            let trackRawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let trackCanonical = ArtistParser.canonicalArtistKey(trackRawArtist)
            let albumRawArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let albumCanonical = ArtistParser.canonicalArtistKey(albumRawArtist)

            var matchedJoinedArtist: String? = nil
            for joinedRule in joinedArtists {
                let joinedCanonical = ArtistParser.canonicalArtistKey(joinedRule)
                if trackCanonical == joinedCanonical || albumCanonical == joinedCanonical {
                    matchedJoinedArtist = joinedRule
                    break
                }
                let joinedParts = ArtistParser.parseArtists(from: joinedRule).map { ArtistParser.canonicalArtistKey($0) }
                if joinedParts.count > 1 {
                    let trackParts = ArtistParser.parseArtists(from: trackRawArtist).map { ArtistParser.canonicalArtistKey($0) }
                    let albumParts = ArtistParser.parseArtists(from: albumRawArtist).map { ArtistParser.canonicalArtistKey($0) }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) || (!albumParts.isEmpty && Set(joinedParts).isSubset(of: Set(albumParts))) {
                        matchedJoinedArtist = joinedRule
                        break
                    }
                }
            }

            let allTrackArtists: [String]
            if let joined = matchedJoinedArtist {
                allTrackArtists = [joined]
            } else {
                allTrackArtists = ArtistParser.allArtists(
                    forTitle: track.title,
                    artist: track.artist,
                    albumArtist: track.albumArtist
                )
            }

            for artistName in allTrackArtists {
                if ArtistParser.isGenericArtistName(artistName) {
                    continue
                }
                let canonicalKey = ArtistParser.canonicalArtistKey(artistName)
                guard !canonicalKey.isEmpty else { continue }

                // Mutate in place so the artist's track array isn't copied on every track (was O(n^2)).
                let emptyEntry: (variantCounts: [String: Int], tracks: [Track], seenTrackIDs: Set<UUID>) = (variantCounts: [:], tracks: [], seenTrackIDs: [])
                if artistTracksMap[canonicalKey, default: emptyEntry].seenTrackIDs.insert(track.id).inserted {
                    artistTracksMap[canonicalKey, default: emptyEntry].tracks.append(track)
                }
                artistTracksMap[canonicalKey, default: emptyEntry].variantCounts[artistName, default: 0] += 1
            }
        }

        AppLogger.library.debug("REBUILD TIMING: artist grouping \(String(format: "%.2f", Date().timeIntervalSince(tBuild)))s")
        // 4. Instantaneous Artist Synthesis using Inverted Track-to-Album Map
        var newArtists: [Artist] = []
        newArtists.reserveCapacity(artistTracksMap.count)

        for (canonicalKey, artistData) in artistTracksMap {
            let sortedVariants = artistData.variantCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return ArtistParser.preferredArtistDisplayName(lhs.key, rhs.key) == lhs.key
            }
            let localMajorityName = sortedVariants.first?.key ?? verifiedArtistNames[canonicalKey] ?? "Unknown Artist"
            let artistName = !localMajorityName.isEmpty ? localMajorityName : (verifiedArtistNames[canonicalKey] ?? "Unknown Artist")
            if ArtistParser.isGenericArtistName(artistName) {
                continue
            }
            let artistTracks = artistData.tracks

            var seenRelevantAlbumIDs = Set<String>()
            var relevantAlbums: [Album] = []
            for track in artistTracks {
                if let albumsForTrack = trackIDToAlbumsMap[track.id] {
                    for alb in albumsForTrack {
                        if seenRelevantAlbumIDs.insert(alb.id).inserted {
                            relevantAlbums.append(alb)
                        }
                    }
                }
            }

            let artist = Artist(
                name: artistName,
                albums: relevantAlbums,
                tracks: artistTracks,
                joinedArtists: joinedArtists
            )
            newArtists.append(artist)
        }

        let sortedArtists = newArtists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // 5. Build instantaneous O(1) lookup index with canonical key aliases
        var lookup: [String: Artist] = [:]
        lookup.reserveCapacity(sortedArtists.count * 4)
        for artist in sortedArtists {
            let lower = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let canon = ArtistParser.canonicalArtistKey(artist.name)
            lookup[lower] = artist
            lookup[canon] = artist
            lookup[artist.id] = artist
        }
        for (canonicalKey, artistData) in artistTracksMap {
            if let matched = lookup[canonicalKey] {
                for variant in artistData.variantCounts.keys {
                    let vLower = variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let vCanon = ArtistParser.canonicalArtistKey(variant)
                    lookup[vLower] = matched
                    lookup[vCanon] = matched
                }
            }
        }

        AppLogger.library.debug("REBUILD TIMING: total \(String(format: "%.2f", Date().timeIntervalSince(tBuild)))s")
        return AlbumsAndArtistsResult(
            tracks: workingTracks,
            albums: sortedAlbums,
            artists: sortedArtists,
            artistLookupIndex: lookup
        )
    }

    @ObservationIgnored private var rebuildTask: Task<Void, Never>? = nil
    @ObservationIgnored private var pendingRebuild: Bool = false
    @ObservationIgnored private var reorganizeGeneration: Int = 0
    @ObservationIgnored private var pendingRepositoryPatchIDs = Set<UUID>()

    /// Rebuilds albums, artists, and indexes off-main-actor in Task.detached with back-to-back coalescing.
    public func rebuildAlbumsAndArtists() {
        if rebuildTask != nil {
            pendingRebuild = true
            return
        }

        let tracksToBuild = self.tracks
        let verifiedGoodDiffs = self.verifiedGoodDiffs
        let downloadedMetadataCache = self.downloadedMetadataCache
        let settingsSnapshot = self.settings
        let persist = !self.isInitialLoading

        rebuildTask = Task { @MainActor [weak self] in
            // Rebuild through the repository (persisted source of truth, off the main actor) so in-memory
            // edits/removals survive relaunch and later change sets.
            // (While the initial load is still running the store may hold only a preview subset, so
            // never replace the repository's tracks then; build locally as before.)
            let res: (tracks: [Track], albums: [Album], artists: [Artist], lookup: [String: Artist])
            if persist {
                let state = await LibraryRepository.shared.replaceAllTracks(
                    tracksToBuild,
                    settings: settingsSnapshot,
                    verifiedGoodDiffs: verifiedGoodDiffs,
                    downloadedMetadataCache: downloadedMetadataCache
                )
                res = (state.tracks, state.albums, state.artists, state.artistLookupIndex)
            } else {
                let built = await Task.detached(priority: .userInitiated) {
                    Self.buildAlbumsAndArtists(
                        tracks: tracksToBuild,
                        joinedArtists: settingsSnapshot.joinedArtists,
                        manualCollaborativeAlbumIDs: settingsSnapshot.manualCollaborativeAlbumIDs,
                        originalAlbumArtistsByTrackID: settingsSnapshot.originalAlbumArtistsByTrackID,
                        verifiedGoodDiffs: verifiedGoodDiffs,
                        downloadedMetadataCache: downloadedMetadataCache,
                        scanMethod: settingsSnapshot.libraryScanMethod
                    )
                }.value
                res = (built.tracks, built.albums, built.artists, built.artistLookupIndex)
            }

            guard let self else { return }
            self.rebuildTask = nil

            self.tracks = res.tracks
            self.albums = res.albums
            self.artists = res.artists
            self.artistLookupIndex = res.lookup
            self.rebuildAlbumLookups()
            self.invalidateSortedCaches()
            self.enqueueSearchDelta(albums: res.albums, artists: res.artists)
            if persist { self.saveLibrary() }

            if self.pendingRebuild {
                self.pendingRebuild = false
                self.rebuildAlbumsAndArtists()
            }
        }
    }

    /// Patches albums and artists in place for a single-track modification without full library rebuild.
    public func patchTrackInPlace(_ updatedTrack: Track) {
        guard let idx = self.tracks.firstIndex(where: { $0.id == updatedTrack.id }) else { return }
        let oldTrack = self.tracks[idx]

        // 1. Update tracks array (+ O(1) lookup)
        self.tracks[idx] = updatedTrack
        self.tracksByID[updatedTrack.id] = updatedTrack

        // 2. Patch albums in place
        for aIdx in 0..<self.albums.count {
            if let tIdx = self.albums[aIdx].tracks.firstIndex(where: { $0.id == updatedTrack.id }) {
                var updatedAlbumTracks = self.albums[aIdx].tracks
                updatedAlbumTracks[tIdx] = updatedTrack
                let oldAlbum = self.albums[aIdx]
                self.albums[aIdx] = Album(
                    title: oldAlbum.title,
                    artist: oldAlbum.artist,
                    year: oldAlbum.year,
                    artworkKey: oldAlbum.artworkKey,
                    tracks: updatedAlbumTracks,
                    groupKey: oldAlbum.groupKey
                )
            }
        }

        // 3. Patch artists in place
        for artIdx in 0..<self.artists.count {
            var artistModified = false
            var updatedArtistTracks = self.artists[artIdx].tracks
            if let tIdx = updatedArtistTracks.firstIndex(where: { $0.id == updatedTrack.id }) {
                updatedArtistTracks[tIdx] = updatedTrack
                artistModified = true
            }

            var updatedArtistAlbums = self.artists[artIdx].albums
            for albIdx in 0..<updatedArtistAlbums.count {
                if let tIdx = updatedArtistAlbums[albIdx].tracks.firstIndex(where: { $0.id == updatedTrack.id }) {
                    var albTracks = updatedArtistAlbums[albIdx].tracks
                    albTracks[tIdx] = updatedTrack
                    let oldAlb = updatedArtistAlbums[albIdx]
                    updatedArtistAlbums[albIdx] = Album(
                        title: oldAlb.title,
                        artist: oldAlb.artist,
                        year: oldAlb.year,
                        artworkKey: oldAlb.artworkKey,
                        tracks: albTracks,
                        groupKey: oldAlb.groupKey
                    )
                    artistModified = true
                }
            }

            if artistModified {
                let oldArtist = self.artists[artIdx]
                self.artists[artIdx] = Artist(
                    name: oldArtist.name,
                    albums: updatedArtistAlbums,
                    tracks: updatedArtistTracks,
                    joinedArtists: self.settings.joinedArtists
                )
                self.artistLookupIndex[oldArtist.id] = self.artists[artIdx]
            }
        }

        // 4. Invalidate sorted caches & apply delta to SearchEngine ONLY if searchable metadata changed
        invalidateSortedCaches()
        let searchableMetadataChanged = (oldTrack.title != updatedTrack.title) ||
            (oldTrack.artist != updatedTrack.artist) ||
            (oldTrack.album != updatedTrack.album) ||
            (oldTrack.genre != updatedTrack.genre) ||
            (oldTrack.searchTokens != updatedTrack.searchTokens)

        if searchableMetadataChanged {
            enqueueSearchDelta(updatedTracks: [updatedTrack])
        }

        // 5. Persist the patch through the repository (coalesced; no regrouping)
        schedulePatchPersistence(for: updatedTrack.id)
    }

    /// Coalesces in-place track patches into one repository update so they survive relaunch/rescans.
    private func schedulePatchPersistence(for trackID: UUID) {
        let shouldSchedule = pendingRepositoryPatchIDs.isEmpty
        pendingRepositoryPatchIDs.insert(trackID)
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !self.isInitialLoading else {
                self.pendingRepositoryPatchIDs.removeAll()
                return
            }
            let ids = self.pendingRepositoryPatchIDs
            self.pendingRepositoryPatchIDs.removeAll()
            let updated = ids.compactMap { self.tracksByID[$0] }
            guard !updated.isEmpty else { return }
            await LibraryRepository.shared.upsertTracksPreservingStructure(
                updated,
                albums: self.albums,
                artists: self.artists,
                lookup: self.artistLookupIndex
            )
            self.saveLibrary()
        }
    }

    public func enqueueSearchDelta(
        insertedTracks: [Track] = [],
        removedTrackIDs: Set<UUID> = [],
        updatedTracks: [Track] = [],
        albums: [Album]? = nil,
        artists: [Artist]? = nil,
        playlists: [Playlist]? = nil
    ) {
        for t in insertedTracks {
            pendingDeltaInsertedTracks[t.id] = t
            pendingDeltaRemovedTrackIDs.remove(t.id)
            pendingDeltaUpdatedTracks.removeValue(forKey: t.id)
        }
        for id in removedTrackIDs {
            pendingDeltaRemovedTrackIDs.insert(id)
            pendingDeltaInsertedTracks.removeValue(forKey: id)
            pendingDeltaUpdatedTracks.removeValue(forKey: id)
        }
        for t in updatedTracks {
            if pendingDeltaInsertedTracks[t.id] != nil {
                pendingDeltaInsertedTracks[t.id] = t
            } else {
                pendingDeltaUpdatedTracks[t.id] = t
            }
        }
        if let albums {
            self.pendingDeltaAlbums = albums
        }
        if let artists {
            self.pendingDeltaArtists = artists
        }
        if let playlists {
            self.pendingDeltaPlaylists = playlists
        }

        searchDeltaDebounceTask?.cancel()
        searchDeltaDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }

            let inserted = Array(self.pendingDeltaInsertedTracks.values)
            let removed = self.pendingDeltaRemovedTrackIDs
            let updated = Array(self.pendingDeltaUpdatedTracks.values)
            let albums = self.pendingDeltaAlbums
            let artists = self.pendingDeltaArtists
            let playlists = self.pendingDeltaPlaylists

            self.pendingDeltaInsertedTracks.removeAll()
            self.pendingDeltaRemovedTrackIDs.removeAll()
            self.pendingDeltaUpdatedTracks.removeAll()
            self.pendingDeltaAlbums = nil
            self.pendingDeltaArtists = nil
            self.pendingDeltaPlaylists = nil

            self.buildSearchIndex(immediate: false)
            self.searchIndexVersion += 1
            self.invalidateSortedCaches()
        }
    }

    /// Incremental track changes applied to library search index.
    public func applyTrackChanges(
        inserted: [Track] = [],
        updated: [Track] = [],
        removedIDs: Set<UUID> = [],
        updatedAlbums: [Album] = [],
        updatedArtists: [Artist] = []
    ) {
        buildSearchIndex(immediate: false)
        searchIndexVersion += 1
        invalidateSortedCaches()
    }

    /// Asynchronously warms the search engine index.
    public func warmSearchIndex(immediate: Bool = false) {
        buildSearchIndex(immediate: immediate)
    }

    /// Builds or updates the SearchEngine index with debouncing.
    public func buildSearchIndex(immediate: Bool = false) {
        warmSearchIndexDebounceTask?.cancel()
        let searchCtx = SearchContext(
            tracksByID: self.tracksByID,
            albumsByID: self.albumsByID,
            artists: self.artists,
            artistLookupIndex: self.artistLookupIndex,
            playlists: self.playlists,
            joinedArtists: self.settings.joinedArtists
        )
        let pl = self.playlists

        if immediate {
            Task.detached(priority: .userInitiated) {
                let entries = await LibraryRepository.shared.currentSearchEntries
                if !entries.tracks.isEmpty {
                    SearchEngine.shared.updateIndex(searchEntries: entries, playlists: pl, context: searchCtx)
                } else {
                    let tracksCopy = Array(searchCtx.tracksByID.values)
                    let albumsCopy = Array(searchCtx.albumsByID.values)
                    SearchEngine.shared.updateIndex(tracks: tracksCopy, albums: albumsCopy, artists: searchCtx.artists, playlists: pl, context: searchCtx)
                }
            }
            return
        }

        warmSearchIndexDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self = self else { return }
            let plCopy = self.playlists
            let ctxCopy = SearchContext(
                tracksByID: self.tracksByID,
                albumsByID: self.albumsByID,
                artists: self.artists,
                artistLookupIndex: self.artistLookupIndex,
                playlists: self.playlists,
                joinedArtists: self.settings.joinedArtists
            )
            Task.detached(priority: .utility) {
                let entries = await LibraryRepository.shared.currentSearchEntries
                if !entries.tracks.isEmpty {
                    SearchEngine.shared.updateIndex(searchEntries: entries, playlists: plCopy, context: ctxCopy)
                } else {
                    let tracksCopy = Array(ctxCopy.tracksByID.values)
                    let albumsCopy = Array(ctxCopy.albumsByID.values)
                    SearchEngine.shared.updateIndex(tracks: tracksCopy, albums: albumsCopy, artists: ctxCopy.artists, playlists: plCopy, context: ctxCopy)
                }
            }
        }
    }

    // Extract primary artist name
    private func extractPrimaryArtistName(from rawArtist: String) -> String {
        // Primary artist name
        var artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Feature separators
        let featureSeparators = [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " vs. ", " vs "]
        for sep in featureSeparators {
            if let range = artist.range(of: sep, options: .caseInsensitive) {
                artist = String(artist[..<range.lowerBound])
            }
        }
        return artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Sort tracks
    nonisolated public static func sortTracks(_ list: [Track], by option: TrackSortOption, isReversed: Bool, playCounts: [UUID: Int] = [:]) -> [Track] {
        let sorted: [Track]
        switch option {
        case .title:
            sorted = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == (isReversed ? .orderedDescending : .orderedAscending) }
        case .artist:
            sorted = list.sorted {
                if $0.artist != $1.artist {
                    return $0.artist.localizedCaseInsensitiveCompare($1.artist) == (isReversed ? .orderedDescending : .orderedAscending)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .album:
            sorted = list.sorted {
                if $0.album != $1.album {
                    return $0.album.localizedCaseInsensitiveCompare($1.album) == (isReversed ? .orderedDescending : .orderedAscending)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .duration:
            sorted = list.sorted { isReversed ? $0.duration > $1.duration : $0.duration < $1.duration }
        case .plays:
            sorted = list.sorted {
                let p0 = playCounts[$0.id] ?? 0
                let p1 = playCounts[$1.id] ?? 0
                if p0 != p1 {
                    return isReversed ? p0 < p1 : p0 > p1
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .newest:
            sorted = list.sorted { t1, t2 in
                let d1 = max(t1.dateAdded, t1.fileInfo?.creationDate ?? .distantPast)
                let d2 = max(t2.dateAdded, t2.fileInfo?.creationDate ?? .distantPast)
                if d1 != d2 {
                    return isReversed ? (d1 < d2) : (d1 > d2)
                }
                return t1.title.localizedCaseInsensitiveCompare(t2.title) == .orderedAscending
            }
        }
        return sorted
    }

    private func sortTracks(_ list: [Track], by option: TrackSortOption, isReversed: Bool) -> [Track] {
        Self.sortTracks(list, by: option, isReversed: isReversed, playCounts: self.playCounts)
    }

    // Sort artists
    private func sortArtists(_ list: [Artist], by option: ArtistSortOption, isReversed: Bool) -> [Artist] {
        switch option {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == (isReversed ? .orderedDescending : .orderedAscending) }
        case .most:
            return list.sorted {
                if $0.tracks.count != $1.tracks.count {
                    return isReversed ? ($0.tracks.count < $1.tracks.count) : ($0.tracks.count > $1.tracks.count)
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .newest:
            let artistDates = Dictionary(list.map { artist in
                let maxDate = artist.tracks.map { max($0.dateAdded, $0.fileInfo?.creationDate ?? .distantPast) }.max() ?? .distantPast
                return (artist.id, maxDate)
            }, uniquingKeysWith: { max($0, $1) })
            return list.sorted { a1, a2 in
                let d1 = artistDates[a1.id] ?? .distantPast
                let d2 = artistDates[a2.id] ?? .distantPast
                if d1 != d2 {
                    return isReversed ? (d1 < d2) : (d1 > d2)
                }
                return a1.name.localizedCaseInsensitiveCompare(a2.name) == .orderedAscending
            }
        }
    }

    // Sort albums
    private func sortAlbums(_ list: [Album], by option: AlbumSortOption, isReversed: Bool) -> [Album] {
        switch option {
        case .title:
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == (isReversed ? .orderedDescending : .orderedAscending) }
        case .most:
            return list.sorted {
                if $0.tracks.count != $1.tracks.count {
                    return isReversed ? ($0.tracks.count < $1.tracks.count) : ($0.tracks.count > $1.tracks.count)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .artist:
            return list.sorted {
                if $0.artist != $1.artist {
                    return $0.artist.localizedCaseInsensitiveCompare($1.artist) == (isReversed ? .orderedDescending : .orderedAscending)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted {
                if $0.totalDuration != $1.totalDuration {
                    return isReversed ? ($0.totalDuration < $1.totalDuration) : ($0.totalDuration > $1.totalDuration)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .newest:
            let albumDates = Dictionary(list.map { album in
                let maxDate = album.tracks.map { max($0.dateAdded, $0.fileInfo?.creationDate ?? .distantPast) }.max() ?? .distantPast
                return (album.id, maxDate)
            }, uniquingKeysWith: { max($0, $1) })
            return list.sorted { a1, a2 in
                let d1 = albumDates[a1.id] ?? .distantPast
                let d2 = albumDates[a2.id] ?? .distantPast
                if d1 != d2 {
                    return isReversed ? (d1 < d2) : (d1 > d2)
                }
                return a1.title.localizedCaseInsensitiveCompare(a2.title) == .orderedAscending
            }
        }
    }

    // Sort playlists
    private func sortPlaylists(_ list: [Playlist], by option: PlaylistSortOption, isReversed: Bool) -> [Playlist] {
        switch option {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == (isReversed ? .orderedDescending : .orderedAscending) }
        case .most:
            return list.sorted {
                if $0.trackIDs.count != $1.trackIDs.count {
                    return isReversed ? ($0.trackIDs.count < $1.trackIDs.count) : ($0.trackIDs.count > $1.trackIDs.count)
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    // MARK: - Duplicate Resolution Operations

    /// Re-evaluates all indexed tracks to detect duplicate clusters.
    public func recalculateDuplicates() async {
        // Groups
        let groups = await DuplicateDetectionService.shared.analyzeDuplicates(in: tracks)
        self.duplicateGroups = groups
        saveDuplicates()
    }

    /// Sets the preferred primary track for a given duplicate group.
    public func resolveDuplicate(groupID: String, selectedPrimaryTrackID: UUID) {
        // Ensure preconditions are met before proceeding
        guard let idx = duplicateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        duplicateGroups[idx].selectedPrimaryTrackID = selectedPrimaryTrackID
        saveDuplicates()
    }

    /// Automatically sets all duplicate groups to use their recommended (highest scoring) primary candidate.
    public func autoResolveAllDuplicates() {
        for i in 0..<duplicateGroups.count {
            if let rec = duplicateGroups[i].candidates.first(where: { $0.isRecommended }) {
                duplicateGroups[i].selectedPrimaryTrackID = rec.track.id
            }
        }
        saveDuplicates()
    }

    /// Deletes duplicate files from disk and removes them from the library.
    public func deleteDuplicateTracks(tracksToDelete: [Track]) async -> (successCount: Int, failedCount: Int) {
        // Success count
        var successCount = 0
        // Failed count
        var failedCount = 0
        // Unique identifier for deleted i ds
        var deletedIDs = Set<UUID>()

        for track in tracksToDelete {
            if track.isJellyfinItem || track.metadataSource == .server {
                if let itemId = track.jellyfinItemId ?? JellyfinPlaybackReporter.extractItemId(from: track) {
                    self.settings.removedJellyfinItemIDs.insert(itemId)
                }
                JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
                deletedIDs.insert(track.id)
                successCount += 1
                continue
            }

            // File system location for file url
            let fileURL = track.url
            // Deleted
            var deleted = false

            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    #if os(macOS) || os(iOS)
                    try fileManager.trashItem(at: fileURL, resultingItemURL: nil)
                    deleted = true
                    #else
                    try fileManager.removeItem(at: fileURL)
                    deleted = true
                    #endif
                } else {
                    deleted = true
                }
            } catch {
                do {
                    try fileManager.removeItem(at: fileURL)
                    deleted = true
                } catch {
                    AppLogger.storage.error("Failed to delete file at \(fileURL.path): \(error.localizedDescription)")
                    failedCount += 1
                }
            }

            if deleted {
                successCount += 1
                deletedIDs.insert(track.id)
            }
        }

        if !deletedIDs.isEmpty {
            for track in tracksToDelete {
                if !track.isJellyfinItem && track.metadataSource != .server {
                    self.settings.removedTrackPaths.insert(track.url.standardizedFileURL.path)
                }
            }
            self.tracks.removeAll { deletedIDs.contains($0.id) }
            for i in 0..<playlists.count {
                playlists[i].trackIDs.removeAll { deletedIDs.contains($0) }
            }
            rebuildAlbumsAndArtists()
            await recalculateDuplicates()
            self.settings.totalScannedFiles = self.tracks.count
            saveLibrary()
            savePlaylists()
            saveSettings()
        }

        return (successCount, failedCount)
    }

    /// Deletes a single audio file from disk and the library.
    public func deleteSingleTrackFile(track: Track) async -> Bool {
        // Res
        let res = await deleteDuplicateTracks(tracksToDelete: [track])
        return res.successCount > 0
    }

    /// Removes a track from the app's library and hides it, while leaving the audio file intact on disk or server.
    public func removeTrackFromLibrary(track: Track) {
        if track.isJellyfinItem || track.metadataSource == .server {
            if let itemId = track.jellyfinItemId ?? JellyfinPlaybackReporter.extractItemId(from: track) {
                self.settings.removedJellyfinItemIDs.insert(itemId)
            }
            JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
        } else {
            let path = track.url.standardizedFileURL.path
            self.settings.removedTrackPaths.insert(path)
        }
        self.tracks.removeAll { $0.id == track.id }
        for i in 0..<playlists.count {
            playlists[i].trackIDs.removeAll { $0 == track.id }
        }
        rebuildAlbumsAndArtists()
        Task {
            await recalculateDuplicates()
        }
        self.settings.totalScannedFiles = self.tracks.count
        saveLibrary()
        savePlaylists()
        saveSettings()
    }

    /// Hides a track from the library and persists its exclusion so it does not reappear on scans.
    public func hideTrack(_ track: Track) {
        removeTrackFromLibrary(track: track)
    }

    /// Permanently deletes a track from the remote Jellyfin server, removes local downloads, and purges it from the library.
    public func deleteJellyfinTrack(_ track: Track) async throws {
        if let server = settings.jellyfinServers.first(where: { $0.id == track.folderID }) ?? settings.jellyfinServers.first,
           let itemId = track.jellyfinItemId ?? JellyfinPlaybackReporter.extractItemId(from: track) {
            try await JellyfinClient.shared.deleteItem(itemId: itemId, serverLink: server)
            self.settings.removedJellyfinItemIDs.insert(itemId)
        }
        JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
        self.tracks.removeAll { $0.id == track.id }
        for i in 0..<playlists.count {
            playlists[i].trackIDs.removeAll { $0 == track.id }
        }
        rebuildAlbumsAndArtists()
        await recalculateDuplicates()
        self.settings.totalScannedFiles = self.tracks.count
        saveLibrary()
        savePlaylists()
        saveSettings()
    }

    // MARK: - Online Metadata Enrichment

    /// Applies verified online metadata and artwork to a track and writes it to file if enabled.
    public func applyOnlineMetadata(
        trackID: UUID,
        onlineMetadata: OnlineTrackMetadata,
        artworkData: Data? = nil,
        preserveLocalTitleAndArtist: Bool = true
    ) async -> Bool {
        // Ensure preconditions are met before proceeding
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        // Existing track
        let existingTrack = tracks[index]

        // Multi-artist & feature credit preservation:
        // If local track has multiple artists and online result only has a single artist,
        // do not overwrite and downgrade local multi-artist tags.
        let isLocalMultiArtist = ArtistParser.parseArtists(from: existingTrack.artist).count > 1 ||
                                 existingTrack.artist.lowercased().contains(" & ") ||
                                 existingTrack.artist.lowercased().contains(", ") ||
                                 existingTrack.artist.lowercased().contains(" feat") ||
                                 existingTrack.artist.lowercased().contains(" ft.")
        let isOnlineMultiArtist = ArtistParser.parseArtists(from: onlineMetadata.artist).count > 1

        let shouldPreserveLocalArtist = (preserveLocalTitleAndArtist && !existingTrack.artist.isEmpty && existingTrack.artist.lowercased() != "unknown artist") ||
                                       (isLocalMultiArtist && !isOnlineMultiArtist)

        let finalArtist = shouldPreserveLocalArtist
            ? existingTrack.artist
            : onlineMetadata.artist

        let hasLocalFeatureInTitle = existingTrack.title.lowercased().contains("feat") || existingTrack.title.lowercased().contains("ft.")
        let hasOnlineFeatureInTitle = onlineMetadata.title.lowercased().contains("feat") || onlineMetadata.title.lowercased().contains("ft.")
        let shouldPreserveLocalTitle = (preserveLocalTitleAndArtist || (hasLocalFeatureInTitle && !hasOnlineFeatureInTitle)) &&
                                       !existingTrack.title.isEmpty && !existingTrack.title.lowercased().hasPrefix("track")

        let finalTitle = shouldPreserveLocalTitle
            ? existingTrack.title
            : onlineMetadata.title

        // Deluxe vs Normal album resolution based on local data:
        let isLocalTrackDeluxe = DeluxeAlbumDetector.isDeluxe(text: existingTrack.album) || DeluxeAlbumDetector.isLocalTrackFromDeluxe(localTrack: existingTrack)
        let editionPref = DeluxeAlbumDetector.resolveEditionPreference(localTrack: existingTrack)
        let isOnlineDeluxe = DeluxeAlbumDetector.isDeluxe(text: onlineMetadata.album)
        let effectiveOnlineAlbum: String
        if isLocalTrackDeluxe && !isOnlineDeluxe {
            // NEVER overwrite a local Deluxe album with a non-deluxe album name
            effectiveOnlineAlbum = existingTrack.album
        } else {
            switch editionPref {
            case .normal:
                effectiveOnlineAlbum = isOnlineDeluxe
                    ? DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album)
                    : onlineMetadata.album
            case .deluxe, .unspecified:
                effectiveOnlineAlbum = onlineMetadata.album
            }
        }

        // Single detection: if the track is a single, name the album as the track name!
        let isSingleRelease = onlineMetadata.isSingle ||
                              onlineMetadata.album.lowercased().hasSuffix(" - single") ||
                              onlineMetadata.album.lowercased().hasSuffix(" (single)") ||
                              onlineMetadata.album.lowercased().hasSuffix(" [single]") ||
                              onlineMetadata.album.lowercased() == "single" ||
                              existingTrack.album.lowercased().hasSuffix(" - single") ||
                              existingTrack.album.lowercased().hasSuffix(" (single)") ||
                              existingTrack.album.lowercased() == "single" ||
                              (DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album).lowercased() == DeluxeAlbumDetector.cleanToStandardAlbumName(finalTitle).lowercased() && (onlineMetadata.totalTracks == nil || onlineMetadata.totalTracks! <= 2))

        // If local track already has a valid album and online candidate is a compilation, preserve local album
        let isLocalAlbumValid = !existingTrack.album.isEmpty &&
                                existingTrack.album.lowercased() != "unknown album" &&
                                !existingTrack.album.lowercased().hasSuffix(" - single") &&
                                !existingTrack.album.lowercased().hasSuffix(" (single)") &&
                                existingTrack.album.lowercased() != "single" &&
                                existingTrack.album.lowercased() != existingTrack.title.lowercased()

        // Final album
        var finalAlbum: String
        if isSingleRelease {
            finalAlbum = finalTitle // Single album name is track title!
        } else if isLocalAlbumValid {
            // Strict preservation: NEVER overwrite existing valid album
            finalAlbum = existingTrack.album
        } else if isLocalTrackDeluxe && !isOnlineDeluxe {
            finalAlbum = existingTrack.album
        } else if !effectiveOnlineAlbum.isEmpty && effectiveOnlineAlbum.lowercased() != "unknown album" {
            finalAlbum = effectiveOnlineAlbum
        } else {
            finalAlbum = existingTrack.album
        }

        // Route remixes to [Main Album] (Remixes) and live to [Main Album] (Live)
        if MetadataSanitizer.isRemixOrAlternateVersion(title: finalTitle, album: finalAlbum) {
            finalAlbum = MetadataSanitizer.remixAlbumName(forStandardAlbum: finalAlbum)
        } else if MetadataSanitizer.isLiveRecording(title: finalTitle, album: finalAlbum) {
            finalAlbum = MetadataSanitizer.liveAlbumName(forStandardAlbum: finalAlbum)
        }

        // Final artwork key: only update if missing locally or if the album changed
        let isLocalAlbumChanged = existingTrack.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != finalAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasLocalArtwork = existingTrack.artworkKey != nil && !existingTrack.artworkKey!.isEmpty

        var finalArtworkKey = existingTrack.artworkKey
        let albumArtKey = ArtworkCacheService.albumArtworkKey(artist: finalArtist, album: finalAlbum)
        if let art = artworkData, !art.isEmpty {
            await ArtworkCacheService.shared.saveArtwork(data: art, key: albumArtKey)
            finalArtworkKey = albumArtKey
        } else if (!hasLocalArtwork || isLocalAlbumChanged), let artURL = onlineMetadata.artworkURL {
            if let downloaded = await MusicMetadataService.shared.downloadArtworkData(from: artURL) {
                await ArtworkCacheService.shared.saveArtwork(data: downloaded, key: albumArtKey)
                finalArtworkKey = albumArtKey
            }
        }

        // Fallback transfer: preserve local tags when online values are missing or zero
        let finalYear = (onlineMetadata.releaseYear ?? 0) > 0
            ? onlineMetadata.releaseYear
            : existingTrack.year

        // Final genre: fill missing genre if online has one, normalized to canonical taxonomy
        let finalGenreRaw: String?
        if let localG = existingTrack.genre, !localG.isEmpty && localG != "Unknown Genre" && localG != "—" {
            finalGenreRaw = localG
        } else if let g = onlineMetadata.genre, !g.isEmpty && g != "Unknown Genre" && g != "—" {
            finalGenreRaw = g
        } else {
            finalGenreRaw = existingTrack.genre
        }
        let finalGenre = MetadataSanitizer.normalizeGenre(finalGenreRaw) ?? finalGenreRaw

        // Track number management:
        // Always preserve local track number as ground truth. Never overwrite local track numbers with online numbers.
        let originalTrackNumber = existingTrack.originalTrackNumber ?? existingTrack.trackNumber
        let finalOriginalTrackNumber: Int?
        let finalDeluxeTrackNumber: Int?
        let finalTrackNumber: Int?

        let isLocalDeluxe = (editionPref == .deluxe || isOnlineDeluxe)
        if let localNum = existingTrack.trackNumber, localNum > 0 {
            finalOriginalTrackNumber = originalTrackNumber
            finalDeluxeTrackNumber = existingTrack.deluxeTrackNumber
            finalTrackNumber = localNum
        } else if let onlineNum = onlineMetadata.trackNumber, onlineNum > 0 {
            finalOriginalTrackNumber = originalTrackNumber ?? onlineNum
            finalDeluxeTrackNumber = isLocalDeluxe ? onlineNum : existingTrack.deluxeTrackNumber
            finalTrackNumber = onlineNum
        } else {
            finalOriginalTrackNumber = originalTrackNumber
            finalDeluxeTrackNumber = existingTrack.deluxeTrackNumber
            finalTrackNumber = nil
        }

        // Final total tracks
        let finalTotalTracks = (onlineMetadata.totalTracks ?? 0) > 0
            ? onlineMetadata.totalTracks
            : existingTrack.totalTracks

        // Final disc number
        let finalDiscNumber = (onlineMetadata.discNumber ?? 0) > 0
            ? onlineMetadata.discNumber
            : existingTrack.discNumber

        // Updated track
        let updatedTrack = Track(
            id: existingTrack.id,
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            albumArtist: onlineMetadata.albumArtist ?? existingTrack.albumArtist,
            genre: finalGenre,
            year: finalYear,
            trackNumber: finalTrackNumber,
            originalTrackNumber: finalOriginalTrackNumber,
            deluxeTrackNumber: finalDeluxeTrackNumber,
            totalTracks: finalTotalTracks,
            discNumber: finalDiscNumber,
            duration: existingTrack.duration,
            url: existingTrack.url,
            artworkKey: finalArtworkKey,
            dateAdded: existingTrack.dateAdded,
            fileInfo: existingTrack.fileInfo,
            lyrics: existingTrack.lyrics
        )

        tracks[index] = updatedTrack

        // Write directly to file if enabled
        if settings.writeMetadataToAudioFiles {
            _ = await AudioFileMetadataWriter.shared.writeMetadata(
                to: existingTrack.url,
                title: updatedTrack.title,
                artist: updatedTrack.artist,
                album: updatedTrack.album,
                albumArtist: updatedTrack.albumArtist,
                year: updatedTrack.year,
                genre: updatedTrack.genre,
                trackNumber: updatedTrack.trackNumber,
                totalTracks: updatedTrack.totalTracks,
                discNumber: updatedTrack.discNumber,
                artworkData: artworkData
            )
        }

        // Move enriched record to verified good diffs
        let diff = MetadataDiff(
            localTrack: updatedTrack,
            onlineMetadata: onlineMetadata,
            preserveLocalTitleAndArtist: preserveLocalTitleAndArtist
        )
        self.enrichmentDiffs.removeAll { $0.id == trackID }
        self.unmatchedTrackIDs.remove(trackID)
        self.verifiedGoodDiffs.removeAll { $0.id == trackID }
        if (updatedTrack.year ?? 0) >= 1900 {
            self.verifiedGoodDiffs.append(diff)
        } else {
            self.unmatchedTrackIDs.insert(trackID)
        }
        self.saveEnrichmentCache()

        // Permanently record in downloaded metadata cache
        self.cacheDownloadedMetadata(
            track: updatedTrack,
            onlineMetadata: onlineMetadata,
            artworkKey: finalArtworkKey,
            wasApplied: true
        )

        self.patchTrackInPlace(updatedTrack)
        saveLibrary()

        return true
    }

    /// Applies customized metadata with granular per-field locking (allowing user to choose which tags to overwrite vs preserve).
    public func applyCustomizedMetadata(
        trackID: UUID,
        onlineMetadata: OnlineTrackMetadata,
        lockedFields: Set<MetadataField>,
        artworkData: Data? = nil
    ) async -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        let existingTrack = tracks[index]

        let finalTitle = lockedFields.contains(.title) ? existingTrack.title : onlineMetadata.title
        let finalArtist = lockedFields.contains(.artist) ? existingTrack.artist : onlineMetadata.artist
        let rawAlbum = lockedFields.contains(.album) ? existingTrack.album : (onlineMetadata.album.isEmpty ? existingTrack.album : onlineMetadata.album)
        let isTrackRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: finalTitle, album: rawAlbum)
        let isTrackLive = MetadataSanitizer.isLiveRecording(title: finalTitle, album: rawAlbum)
        let finalAlbum: String
        if isTrackRemix {
            finalAlbum = MetadataSanitizer.remixAlbumName(forStandardAlbum: rawAlbum)
        } else if isTrackLive {
            finalAlbum = MetadataSanitizer.liveAlbumName(forStandardAlbum: rawAlbum)
        } else {
            finalAlbum = rawAlbum
        }
        let finalAlbumArtist = lockedFields.contains(.artist) ? existingTrack.albumArtist : (onlineMetadata.albumArtist ?? onlineMetadata.artist)
        let finalYear = lockedFields.contains(.year) ? existingTrack.year : (onlineMetadata.releaseYear ?? existingTrack.year)
        let finalGenre = lockedFields.contains(.genre) ? existingTrack.genre : (onlineMetadata.genre ?? existingTrack.genre)
        let finalTrackNumber = lockedFields.contains(.trackNumber) ? existingTrack.trackNumber : (onlineMetadata.trackNumber ?? existingTrack.trackNumber)
        let finalDiscNumber = lockedFields.contains(.trackNumber) ? existingTrack.discNumber : (onlineMetadata.discNumber ?? existingTrack.discNumber)
        let finalTotalTracks = lockedFields.contains(.trackNumber) ? existingTrack.totalTracks : (onlineMetadata.totalTracks ?? existingTrack.totalTracks)

        // Artwork resolution
        var finalArtworkKey = existingTrack.artworkKey
        var finalArtworkData = artworkData
        if !lockedFields.contains(.artwork) {
            let albumArtKey = ArtworkCacheService.albumArtworkKey(artist: finalArtist, album: finalAlbum)
            if let art = artworkData, !art.isEmpty {
                await ArtworkCacheService.shared.saveArtwork(data: art, key: albumArtKey)
                finalArtworkKey = albumArtKey
            } else if let artURL = onlineMetadata.artworkURL {
                if let downloaded = await MusicMetadataService.shared.downloadArtworkData(from: artURL) {
                    await ArtworkCacheService.shared.saveArtwork(data: downloaded, key: albumArtKey)
                    finalArtworkKey = albumArtKey
                    finalArtworkData = downloaded
                }
            }
        }

        let updatedTrack = Track(
            id: existingTrack.id,
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            albumArtist: finalAlbumArtist,
            genre: finalGenre,
            year: finalYear,
            trackNumber: finalTrackNumber,
            originalTrackNumber: existingTrack.originalTrackNumber ?? finalTrackNumber,
            deluxeTrackNumber: existingTrack.deluxeTrackNumber,
            totalTracks: finalTotalTracks,
            discNumber: finalDiscNumber,
            duration: existingTrack.duration,
            url: existingTrack.url,
            artworkKey: finalArtworkKey,
            dateAdded: existingTrack.dateAdded,
            fileInfo: existingTrack.fileInfo,
            lyrics: existingTrack.lyrics
        )

        tracks[index] = updatedTrack

        // Write directly to file if enabled
        if settings.writeMetadataToAudioFiles {
            _ = await AudioFileMetadataWriter.shared.writeMetadata(
                to: existingTrack.url,
                title: updatedTrack.title,
                artist: updatedTrack.artist,
                album: updatedTrack.album,
                albumArtist: updatedTrack.albumArtist,
                year: updatedTrack.year,
                genre: updatedTrack.genre,
                trackNumber: updatedTrack.trackNumber,
                totalTracks: updatedTrack.totalTracks,
                discNumber: updatedTrack.discNumber,
                artworkData: finalArtworkData
            )
        }

        let diff = MetadataDiff(
            localTrack: updatedTrack,
            onlineMetadata: onlineMetadata,
            preserveLocalTitleAndArtist: lockedFields.contains(.title) && lockedFields.contains(.artist)
        )
        self.enrichmentDiffs.removeAll { $0.id == trackID }
        self.unmatchedTrackIDs.remove(trackID)
        self.verifiedGoodDiffs.removeAll { $0.id == trackID }
        if (updatedTrack.year ?? 0) >= 1900 {
            self.verifiedGoodDiffs.append(diff)
        } else {
            self.unmatchedTrackIDs.insert(trackID)
        }
        self.saveEnrichmentCache()

        self.cacheDownloadedMetadata(
            track: updatedTrack,
            onlineMetadata: onlineMetadata,
            artworkKey: finalArtworkKey,
            wasApplied: true
        )

        self.patchTrackInPlace(updatedTrack)
        saveLibrary()

        return true
    }

    /// Applies an online album and its child cuts to all matched child tracks (including discovered/reassigned tracks).
    public func applyOnlineAlbumToAlbum(
        album: Album?,
        onlineAlbum: OnlineAlbumItem,
        onlineTracks: [OnlineTrackMetadata],
        preserveLocalTitleAndArtist: Bool = true,
        specificTracksToApply: [Track]? = nil,
        specificAssignments: [DisambiguationMatcher.AlbumCutAssignment]? = nil,
        unmatchedActions: [UUID: UnmatchedTrackAction]? = nil
    ) async -> Bool {
        // 1. Download artwork if available
        var artworkKey: String? = nil
        var artworkData: Data? = nil
        if let artURL = onlineAlbum.artworkURL {
            if let data = await MusicMetadataService.shared.downloadArtworkData(from: artURL), !data.isEmpty {
                let key = ArtworkCacheService.albumArtworkKey(artist: onlineAlbum.artistName, album: onlineAlbum.title)
                await ArtworkCacheService.shared.saveArtwork(data: data, key: key)
                artworkKey = key
                artworkData = data
            }
        }

        // Determine assignments: use verified specific assignments if passed, or run bipartite matching
        let assignments: [DisambiguationMatcher.AlbumCutAssignment]
        if let specific = specificAssignments, !specific.isEmpty {
            assignments = specific
        } else {
            let candidatePool: [Track]
            if let specificTracks = specificTracksToApply, !specificTracks.isEmpty {
                candidatePool = specificTracks
            } else if let alb = album, !alb.tracks.isEmpty {
                candidatePool = alb.tracks
            } else {
                candidatePool = self.tracks
            }

            let (computed, _) = DisambiguationMatcher.matchAlbumTracklistToCandidates(
                onlineTracks: onlineTracks,
                albumTitle: onlineAlbum.title,
                albumArtist: onlineAlbum.artistName,
                candidateTracks: candidatePool
            )
            assignments = computed
        }

        var processedTrackIDs: Set<UUID> = []
        var trackIndexMap: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackIndexMap[t.id] = i
        }

        var fileTaggingQueue: [(url: URL, track: Track, artworkData: Data?)] = []

        // Process matched official cuts
        for assignment in assignments {
            guard let localTrack = assignment.localTrack,
                  let trackIndex = trackIndexMap[localTrack.id],
                  trackIndex < tracks.count else { continue }

            let existingTrack = tracks[trackIndex]
            let cut = assignment.cut

            let hasLocalFeatureInTitle = existingTrack.title.lowercased().contains("feat") || existingTrack.title.lowercased().contains("ft.")
            let hasOnlineFeatureInTitle = cut.title.lowercased().contains("feat") || cut.title.lowercased().contains("ft.")
            let shouldPreserveLocalTitle = (preserveLocalTitleAndArtist || (hasLocalFeatureInTitle && !hasOnlineFeatureInTitle)) &&
                                           !existingTrack.title.isEmpty && !existingTrack.title.lowercased().hasPrefix("track")
            let finalTitle = shouldPreserveLocalTitle ? existingTrack.title : cut.title

            let cutArtist = !cut.artist.isEmpty ? cut.artist : onlineAlbum.artistName
            let finalArtist: String = {
                if !preserveLocalTitleAndArtist {
                    return cutArtist
                }
                // If local artist is empty or unknown, adopt the official online artist
                if existingTrack.artist.isEmpty || MetadataSanitizer.isUnknownArtist(existingTrack.artist) {
                    return cutArtist
                }
                // If local artist has feature / multiple artists (e.g. "Artist A feat. Artist B"), preserve the collaborative credit
                let parsedArtists = ArtistParser.parseArtists(from: existingTrack.artist)
                if parsedArtists.count > 1 {
                    return existingTrack.artist
                }
                // If local artist matched the old album artist and has no features, update to the new album artist
                if let alb = album, existingTrack.artist.localizedCaseInsensitiveCompare(alb.artist) == .orderedSame {
                    return cutArtist
                }
                return existingTrack.artist
            }()

            let finalAlbum = onlineAlbum.title
            let finalYear = onlineAlbum.releaseYear ?? cut.releaseYear ?? existingTrack.year
            let finalGenre = onlineAlbum.genre ?? cut.genre ?? existingTrack.genre
            let finalTrackNumber = (existingTrack.trackNumber ?? 0) > 0 ? existingTrack.trackNumber : cut.trackNumber
            let finalTotalTracks = onlineAlbum.trackCount ?? cut.totalTracks ?? existingTrack.totalTracks
            let finalArtworkKey = artworkKey ?? existingTrack.artworkKey

            let updatedTrack = Track(
                id: existingTrack.id,
                title: finalTitle,
                artist: finalArtist,
                album: finalAlbum,
                albumArtist: onlineAlbum.artistName,
                genre: finalGenre,
                year: finalYear,
                trackNumber: finalTrackNumber,
                originalTrackNumber: existingTrack.originalTrackNumber ?? finalTrackNumber,
                deluxeTrackNumber: existingTrack.deluxeTrackNumber,
                totalTracks: finalTotalTracks,
                discNumber: cut.discNumber ?? existingTrack.discNumber,
                duration: existingTrack.duration,
                url: existingTrack.url,
                artworkKey: finalArtworkKey,
                dateAdded: existingTrack.dateAdded,
                fileInfo: existingTrack.fileInfo,
                lyrics: existingTrack.lyrics,
                isAlternate: false
            )

            tracks[trackIndex] = updatedTrack
            processedTrackIDs.insert(existingTrack.id)

            if existingTrack.canReadLocalBytes && existingTrack.url.isFileURL && !existingTrack.isJellyfinItem {
                fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkData: artworkData))
            }

            let synthesizedMetadata = OnlineTrackMetadata(
                id: cut.id,
                title: finalTitle,
                artist: finalArtist,
                album: finalAlbum,
                albumArtist: onlineAlbum.artistName,
                releaseDate: onlineAlbum.releaseDate,
                releaseYear: finalYear,
                genre: finalGenre,
                trackNumber: finalTrackNumber,
                totalTracks: finalTotalTracks,
                discNumber: cut.discNumber ?? 1,
                duration: existingTrack.duration,
                artworkURL: onlineAlbum.artworkURL,
                previewURL: cut.previewURL,
                sourceAPI: onlineAlbum.sourceAPI,
                isCompilation: false
            )

            self.cacheDownloadedMetadata(
                track: updatedTrack,
                onlineMetadata: synthesizedMetadata,
                artworkKey: finalArtworkKey,
                wasApplied: true,
                autoSave: false
            )
        }

        // Process remaining unmatched local tracks in the album
        if let alb = album {
            let candidateLibraryAlbums = self.albums
            for localTrack in alb.tracks {
                guard !processedTrackIDs.contains(localTrack.id),
                      let trackIndex = trackIndexMap[localTrack.id],
                      trackIndex < tracks.count else { continue }

                let existingTrack = tracks[trackIndex]

                let action: UnmatchedTrackAction
                if let preAction = unmatchedActions?[localTrack.id] {
                    action = preAction
                } else {
                    action = await AlbumOrganizationService.shared.resolveUnmatchedTrack(
                        track: existingTrack,
                        currentAlbum: alb,
                        onlineAlbum: onlineAlbum,
                        onlineCuts: onlineTracks,
                        libraryAlbums: candidateLibraryAlbums
                    )
                }

                let updatedTrack: Track
                switch action {
                case .moveToAlternates:
                    let rawAlbum = onlineAlbum.title
                    let finalAlbum: String
                    if MetadataSanitizer.isRemixOrAlternateVersion(title: existingTrack.title, album: rawAlbum) {
                        finalAlbum = MetadataSanitizer.remixAlbumName(forStandardAlbum: rawAlbum)
                    } else if MetadataSanitizer.isLiveRecording(title: existingTrack.title, album: rawAlbum) {
                        finalAlbum = MetadataSanitizer.liveAlbumName(forStandardAlbum: rawAlbum)
                    } else {
                        finalAlbum = rawAlbum
                    }
                    let finalArtworkKey = artworkKey ?? existingTrack.artworkKey
                    let finalYear = onlineAlbum.releaseYear ?? existingTrack.year
                    let finalArtist: String = {
                        if !preserveLocalTitleAndArtist {
                            return onlineAlbum.artistName
                        }
                        if existingTrack.artist.isEmpty || MetadataSanitizer.isUnknownArtist(existingTrack.artist) {
                            return onlineAlbum.artistName
                        }
                        let parsedArtists = ArtistParser.parseArtists(from: existingTrack.artist)
                        if parsedArtists.count > 1 {
                            return existingTrack.artist
                        }
                        if let alb = album, existingTrack.artist.localizedCaseInsensitiveCompare(alb.artist) == .orderedSame {
                            return onlineAlbum.artistName
                        }
                        return existingTrack.artist
                    }()

                    updatedTrack = Track(
                        id: existingTrack.id,
                        title: existingTrack.title,
                        artist: finalArtist,
                        album: finalAlbum,
                        albumArtist: onlineAlbum.artistName,
                        genre: onlineAlbum.genre ?? existingTrack.genre,
                        year: finalYear,
                        trackNumber: existingTrack.trackNumber,
                        originalTrackNumber: existingTrack.originalTrackNumber,
                        deluxeTrackNumber: existingTrack.deluxeTrackNumber,
                        totalTracks: onlineAlbum.trackCount ?? existingTrack.totalTracks,
                        discNumber: existingTrack.discNumber,
                        duration: existingTrack.duration,
                        url: existingTrack.url,
                        artworkKey: finalArtworkKey,
                        dateAdded: existingTrack.dateAdded,
                        fileInfo: existingTrack.fileInfo,
                        lyrics: existingTrack.lyrics,
                        isAlternate: true
                    )
                    if existingTrack.canReadLocalBytes && existingTrack.url.isFileURL && !existingTrack.isJellyfinItem {
                        fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkData: artworkData))
                    }

                case .moveToAlbum(
                    let targetAlbumTitle,
                    let targetArtist,
                    let actionYear,
                    let actionGenre,
                    let actionArtworkKey,
                    let actionArtworkURL,
                    let actionTrackNumber,
                    let actionTotalTracks,
                    let actionDiscNumber,
                    _
                ):
                    let matchingAlbum = candidateLibraryAlbums.first(where: {
                        FuzzyMatcher.normalize($0.title) == FuzzyMatcher.normalize(targetAlbumTitle)
                    })
                    let finalAlbum = targetAlbumTitle
                    let finalArtist = !targetArtist.isEmpty ? targetArtist : (matchingAlbum?.artist ?? existingTrack.artist)
                    let finalAlbumArtist: String = {
                        if let matching = matchingAlbum {
                            if let trackAlbumArtist = matching.tracks.compactMap({ $0.albumArtist }).first(where: { !$0.isEmpty }) {
                                return trackAlbumArtist
                            }
                            return matching.artist
                        }
                        if !targetArtist.isEmpty {
                            return targetArtist
                        }
                        return existingTrack.albumArtist ?? existingTrack.artist
                    }()
                    let finalYear = matchingAlbum?.year ?? actionYear ?? existingTrack.year
                    let finalGenre = matchingAlbum?.genre ?? actionGenre ?? existingTrack.genre
                    let finalTrackNumber = actionTrackNumber ?? existingTrack.trackNumber
                    let finalTotalTracks = matchingAlbum?.tracks.count ?? actionTotalTracks ?? existingTrack.totalTracks
                    let finalDiscNumber = actionDiscNumber ?? existingTrack.discNumber
                    let targetArtworkKey = matchingAlbum?.artworkKey ?? actionArtworkKey ?? existingTrack.artworkKey

                    var targetArtworkData: Data? = nil
                    if let key = targetArtworkKey {
                        targetArtworkData = await ArtworkCacheService.shared.loadArtwork(key: key)
                    }
                    if targetArtworkData == nil, let artURL = actionArtworkURL {
                        if let downloaded = await MusicMetadataService.shared.downloadArtworkData(from: artURL), !downloaded.isEmpty {
                            let key = targetArtworkKey ?? ArtworkCacheService.albumArtworkKey(artist: finalAlbumArtist, album: finalAlbum)
                            await ArtworkCacheService.shared.saveArtwork(data: downloaded, key: key)
                            targetArtworkData = downloaded
                        }
                    }

                    let isAlt = MetadataSanitizer.isRemixOrAlternateVersion(title: existingTrack.title, album: targetAlbumTitle) ||
                                MetadataSanitizer.isLiveRecording(title: existingTrack.title, album: targetAlbumTitle)

                    updatedTrack = Track(
                        id: existingTrack.id,
                        title: existingTrack.title,
                        artist: finalArtist,
                        album: finalAlbum,
                        albumArtist: finalAlbumArtist,
                        genre: finalGenre,
                        year: finalYear,
                        trackNumber: finalTrackNumber,
                        originalTrackNumber: existingTrack.originalTrackNumber ?? finalTrackNumber,
                        deluxeTrackNumber: existingTrack.deluxeTrackNumber,
                        totalTracks: finalTotalTracks,
                        discNumber: finalDiscNumber,
                        duration: existingTrack.duration,
                        url: existingTrack.url,
                        artworkKey: targetArtworkKey,
                        dateAdded: existingTrack.dateAdded,
                        fileInfo: existingTrack.fileInfo,
                        lyrics: existingTrack.lyrics,
                        isAlternate: isAlt
                    )
                    if existingTrack.canReadLocalBytes && existingTrack.url.isFileURL && !existingTrack.isJellyfinItem {
                        fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkData: targetArtworkData))
                    }

                case .keepInMain:
                    let rawAlbum = onlineAlbum.title
                    let finalArtworkKey = artworkKey ?? existingTrack.artworkKey
                    let finalYear = onlineAlbum.releaseYear ?? existingTrack.year
                    let finalArtist: String = {
                        if !preserveLocalTitleAndArtist {
                            return onlineAlbum.artistName
                        }
                        if existingTrack.artist.isEmpty || MetadataSanitizer.isUnknownArtist(existingTrack.artist) {
                            return onlineAlbum.artistName
                        }
                        let parsedArtists = ArtistParser.parseArtists(from: existingTrack.artist)
                        if parsedArtists.count > 1 {
                            return existingTrack.artist
                        }
                        if let alb = album, existingTrack.artist.localizedCaseInsensitiveCompare(alb.artist) == .orderedSame {
                            return onlineAlbum.artistName
                        }
                        return existingTrack.artist
                    }()

                    updatedTrack = Track(
                        id: existingTrack.id,
                        title: existingTrack.title,
                        artist: finalArtist,
                        album: rawAlbum,
                        albumArtist: onlineAlbum.artistName,
                        genre: onlineAlbum.genre ?? existingTrack.genre,
                        year: finalYear,
                        trackNumber: existingTrack.trackNumber,
                        originalTrackNumber: existingTrack.originalTrackNumber,
                        deluxeTrackNumber: existingTrack.deluxeTrackNumber,
                        totalTracks: onlineAlbum.trackCount ?? existingTrack.totalTracks,
                        discNumber: existingTrack.discNumber,
                        duration: existingTrack.duration,
                        url: existingTrack.url,
                        artworkKey: finalArtworkKey,
                        dateAdded: existingTrack.dateAdded,
                        fileInfo: existingTrack.fileInfo,
                        lyrics: existingTrack.lyrics,
                        isAlternate: false
                    )
                    if existingTrack.canReadLocalBytes && existingTrack.url.isFileURL && !existingTrack.isJellyfinItem {
                        fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkData: artworkData))
                    }
                }

                tracks[trackIndex] = updatedTrack
                processedTrackIDs.insert(existingTrack.id)
            }
        }

        // Clean up diff lists
        self.enrichmentDiffs.removeAll { processedTrackIDs.contains($0.id) }
        self.unmatchedTrackIDs.subtract(processedTrackIDs)
        self.saveEnrichmentCache()

        // Batch write metadata to files on background queue if enabled
        if settings.writeMetadataToAudioFiles && !fileTaggingQueue.isEmpty {
            for item in fileTaggingQueue {
                _ = await AudioFileMetadataWriter.shared.writeMetadata(
                    to: item.url,
                    title: item.track.title,
                    artist: item.track.artist,
                    album: item.track.album,
                    albumArtist: item.track.albumArtist,
                    year: item.track.year,
                    genre: item.track.genre,
                    trackNumber: item.track.trackNumber,
                    totalTracks: item.track.totalTracks,
                    discNumber: item.track.discNumber,
                    artworkData: item.artworkData
                )
            }
        }

        rebuildAlbumsAndArtists()
        await recalculateDuplicates()
        saveLibrary()
        self.saveDownloadedMetadataCache()

        // Sync currently playing track in player service if updated
        if let sharedPlayer = AudioPlayerService.shared,
           let currentPlaying = sharedPlayer.currentTrack,
           let updated = self.tracks.first(where: { $0.id == currentPlaying.id }) {
            sharedPlayer.syncTrackMetadata(updatedTrack: updated)
        }

        return true
    }

    /// Dismisses a pending metadata enrichment diff, keeping the local track as-is.
    public func dismissEnrichmentDiff(diffID: UUID) {
        self.enrichmentDiffs.removeAll { $0.id == diffID }
        self.saveEnrichmentCache()
    }

    /// High-performance batch enrichment engine with parallel artwork deduplication, single-pass in-memory updates, and single-transaction disk save.
    public func applyBatchOnlineMetadata(
        diffs: [MetadataDiff],
        preserveLocalTitleAndArtist: Bool = true,
        onProgress: ((Double, String) -> Void)? = nil,
        onCountProgress: ((Int, Int) -> Void)? = nil
    ) async -> Int {
        // Ensure preconditions are met before proceeding
        guard !diffs.isEmpty else { return 0 }

        self.isEnrichingMetadata = true
        self.enrichProcessedCount = 0
        self.enrichTotalCount = diffs.count
        self.enrichProgress = 0.0
        self.enrichStatusText = "Preparing batch enrichment for \(diffs.count) tracks..."

        // Ensure root linked folder security-scoped access is active across all file writes
        let rootFolderURL = SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        // Flag indicating if root accessing
        let isRootAccessing = rootFolderURL?.startAccessingSecurityScopedResource() ?? false
        // Cleanup upon exiting scope
        defer {
            if isRootAccessing, let root = rootFolderURL {
                root.stopAccessingSecurityScopedResource()
            }
            self.isEnrichingMetadata = false
            self.enrichProcessedCount = 0
            self.enrichTotalCount = 0
        }

        // Total
        let total = diffs.count
        onCountProgress?(0, total)
        onProgress?(0.02, "Preparing batch enrichment for \(total) tracks...")

        // MARK: - Step 1: Parallel Artwork Deduplication by Album Key
        var artworkURLsByAlbumKey: [String: URL] = [:]
        for diff in diffs {
            // File path location
            if let artURL = diff.onlineMetadata.artworkURL {
                // Flag indicating if local deluxe
                let isLocalDeluxe = DeluxeAlbumDetector.isLocalTrackFromDeluxe(localTrack: diff.localTrack)
                // Flag indicating if online deluxe
                let isOnlineDeluxe = DeluxeAlbumDetector.isDeluxe(text: diff.onlineMetadata.album)
                // Effective online
                let effectiveOnline = (!isLocalDeluxe && isOnlineDeluxe)
                    ? DeluxeAlbumDetector.cleanToStandardAlbumName(diff.onlineMetadata.album)
                    : diff.onlineMetadata.album

                // Final artist
                let finalArtist = (preserveLocalTitleAndArtist && !diff.localTrack.artist.isEmpty && diff.localTrack.artist.lowercased() != "unknown artist") ? diff.localTrack.artist : diff.onlineMetadata.artist
                // Flag indicating if local album valid
                let isLocalAlbumValid = !diff.localTrack.album.isEmpty && diff.localTrack.album.lowercased() != "unknown album" && !diff.localTrack.album.lowercased().hasSuffix(" - single") && !diff.localTrack.album.lowercased().hasSuffix(" (single)") && diff.localTrack.album.lowercased() != "single"
                // Final album
                let finalAlbum = (isLocalAlbumValid && (diff.onlineMetadata.isCompilation || diff.onlineMetadata.isSingle)) ? diff.localTrack.album : (!effectiveOnline.isEmpty ? effectiveOnline : diff.localTrack.album)
                // Album key
                let albumKey = ArtworkCacheService.albumArtworkKey(artist: finalArtist, album: finalAlbum)
                if artworkURLsByAlbumKey[albumKey] == nil {
                    artworkURLsByAlbumKey[albumKey] = artURL
                }
            }
        }

        // MARK: - Step 1: Bounded Parallel Artwork Download (Saves directly to disk, 0 RAM retention)
        var downloadedArtworkKeys = Set<String>()
        if !artworkURLsByAlbumKey.isEmpty {
            let uniqueList = Array(artworkURLsByAlbumKey)
            let totalUniqueArt = uniqueList.count
            var downloadedCount = 0
            onProgress?(0.05, "Step 1/3: Downloading album artwork (0/\(totalUniqueArt))...")

            let maxArtWorkers = 4
            var artIndex = 0

            await withTaskGroup(of: (String, Bool).self) { group in
                while artIndex < totalUniqueArt && artIndex < maxArtWorkers {
                    let (key, url) = uniqueList[artIndex]
                    artIndex += 1
                    group.addTask {
                        if let data = await MusicMetadataService.shared.downloadArtworkData(from: url), !data.isEmpty {
                            await ArtworkCacheService.shared.saveArtwork(data: data, key: key)
                            return (key, true)
                        }
                        return (key, false)
                    }
                }

                for await (key, success) in group {
                    if success {
                        downloadedArtworkKeys.insert(key)
                    }
                    downloadedCount += 1
                    let p = 0.05 + (Double(downloadedCount) / Double(max(1, totalUniqueArt))) * 0.30
                    onProgress?(p, "Downloading artwork (\(downloadedCount)/\(totalUniqueArt))...")

                    if artIndex < totalUniqueArt {
                        let (nextKey, nextUrl) = uniqueList[artIndex]
                        artIndex += 1
                        group.addTask {
                            if let nextData = await MusicMetadataService.shared.downloadArtworkData(from: nextUrl), !nextData.isEmpty {
                                await ArtworkCacheService.shared.saveArtwork(data: nextData, key: nextKey)
                                return (nextKey, true)
                            }
                            return (nextKey, false)
                        }
                    }
                }
            }
        } else {
            onProgress?(0.35, "Artwork verification complete.")
        }

        // MARK: - Step 2: Single-Pass In-Memory Track Mutation with Smooth Progress Yielding
        var enrichedCount = 0
        var fileTaggingQueue: [(url: URL, track: Track, artworkKey: String?)] = []
        var processedTrackIDs = Set<UUID>()
        var newVerifiedGood: [MetadataDiff] = []

        var trackIndexMap: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackIndexMap[t.id] = i
        }

        for (idx, diff) in diffs.enumerated() {
            guard let trackIndex = trackIndexMap[diff.localTrack.id], trackIndex < tracks.count else { continue }
            let existingTrack = tracks[trackIndex]
            let onlineMetadata = diff.onlineMetadata

            // Multi-artist & feature credit preservation:
            let isLocalMultiArtist = ArtistParser.parseArtists(from: existingTrack.artist).count > 1 ||
                                     existingTrack.artist.lowercased().contains(" & ") ||
                                     existingTrack.artist.lowercased().contains(", ") ||
                                     existingTrack.artist.lowercased().contains(" feat") ||
                                     existingTrack.artist.lowercased().contains(" ft.")
            let isOnlineMultiArtist = ArtistParser.parseArtists(from: onlineMetadata.artist).count > 1

            let shouldPreserveLocalArtist = (preserveLocalTitleAndArtist && !existingTrack.artist.isEmpty && existingTrack.artist.lowercased() != "unknown artist") ||
                                           (isLocalMultiArtist && !isOnlineMultiArtist)

            let finalArtist = shouldPreserveLocalArtist
                ? existingTrack.artist
                : onlineMetadata.artist

            let hasLocalFeatureInTitle = existingTrack.title.lowercased().contains("feat") || existingTrack.title.lowercased().contains("ft.")
            let hasOnlineFeatureInTitle = onlineMetadata.title.lowercased().contains("feat") || onlineMetadata.title.lowercased().contains("ft.")
            let shouldPreserveLocalTitle = (preserveLocalTitleAndArtist || (hasLocalFeatureInTitle && !hasOnlineFeatureInTitle)) &&
                                           !existingTrack.title.isEmpty && !existingTrack.title.lowercased().hasPrefix("track")

            let finalTitle = shouldPreserveLocalTitle
                ? existingTrack.title
                : onlineMetadata.title

            // Deluxe vs Normal album resolution based on local data:
            let isLocalTrackDeluxe = DeluxeAlbumDetector.isDeluxe(text: existingTrack.album) || DeluxeAlbumDetector.isLocalTrackFromDeluxe(localTrack: existingTrack)
            let editionPref = DeluxeAlbumDetector.resolveEditionPreference(localTrack: existingTrack)
            let isOnlineDeluxe = DeluxeAlbumDetector.isDeluxe(text: onlineMetadata.album)
            let effectiveOnline: String
            if isLocalTrackDeluxe && !isOnlineDeluxe {
                effectiveOnline = existingTrack.album
            } else {
                switch editionPref {
                case .normal:
                    effectiveOnline = isOnlineDeluxe
                        ? DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album)
                        : onlineMetadata.album
                case .deluxe, .unspecified:
                    effectiveOnline = onlineMetadata.album
                }
            }

            // Single detection: if the track is a single, name the album as the track name!
            let isSingleRelease = onlineMetadata.isSingle ||
                                  onlineMetadata.album.lowercased().hasSuffix(" - single") ||
                                  onlineMetadata.album.lowercased().hasSuffix(" (single)") ||
                                  onlineMetadata.album.lowercased().hasSuffix(" [single]") ||
                                  onlineMetadata.album.lowercased() == "single" ||
                                  existingTrack.album.lowercased().hasSuffix(" - single") ||
                                  existingTrack.album.lowercased().hasSuffix(" (single)") ||
                                  existingTrack.album.lowercased() == "single" ||
                                  (DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album).lowercased() == DeluxeAlbumDetector.cleanToStandardAlbumName(finalTitle).lowercased() && (onlineMetadata.totalTracks == nil || onlineMetadata.totalTracks! <= 2))

            let isLocalAlbumValid = !existingTrack.album.isEmpty &&
                                    existingTrack.album.lowercased() != "unknown album" &&
                                    !existingTrack.album.lowercased().hasSuffix(" - single") &&
                                    !existingTrack.album.lowercased().hasSuffix(" (single)") &&
                                    existingTrack.album.lowercased() != "single" &&
                                    existingTrack.album.lowercased() != existingTrack.title.lowercased()

            var finalAlbum: String
            if isSingleRelease {
                finalAlbum = finalTitle
            } else if isLocalAlbumValid {
                // Strict preservation: NEVER overwrite existing valid album
                finalAlbum = existingTrack.album
            } else if isLocalTrackDeluxe && !isOnlineDeluxe {
                finalAlbum = existingTrack.album
            } else if !effectiveOnline.isEmpty && effectiveOnline.lowercased() != "unknown album" {
                finalAlbum = effectiveOnline
            } else {
                finalAlbum = existingTrack.album
            }

            // Route remixes to [Main Album] (Remixes) and live to [Main Album] (Live)
            if MetadataSanitizer.isRemixOrAlternateVersion(title: finalTitle, album: finalAlbum) {
                finalAlbum = MetadataSanitizer.remixAlbumName(forStandardAlbum: finalAlbum)
            } else if MetadataSanitizer.isLiveRecording(title: finalTitle, album: finalAlbum) {
                finalAlbum = MetadataSanitizer.liveAlbumName(forStandardAlbum: finalAlbum)
            }

            // Final artwork key: only update if missing locally or if the album changed
            let isLocalAlbumChanged = existingTrack.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != finalAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasLocalArtwork = existingTrack.artworkKey != nil && !existingTrack.artworkKey!.isEmpty

            let albumKey = ArtworkCacheService.albumArtworkKey(artist: finalArtist, album: finalAlbum)
            var hasArtworkAvailable = downloadedArtworkKeys.contains(albumKey)
            if !hasArtworkAvailable {
                hasArtworkAvailable = await ArtworkCacheService.shared.hasArtwork(key: albumKey)
            }
            var finalArtworkKey = existingTrack.artworkKey
            var artworkKeyForTagging: String? = nil
            if (!hasLocalArtwork || isLocalAlbumChanged) && hasArtworkAvailable {
                finalArtworkKey = albumKey
                artworkKeyForTagging = albumKey
            }

            let finalYear = (onlineMetadata.releaseYear ?? 0) > 0
                ? onlineMetadata.releaseYear
                : existingTrack.year

            let finalGenreRaw: String?
            if let localG = existingTrack.genre, !localG.isEmpty && localG != "Unknown Genre" && localG != "—" {
                finalGenreRaw = localG
            } else if let g = onlineMetadata.genre, !g.isEmpty && g != "Unknown Genre" && g != "—" {
                finalGenreRaw = g
            } else {
                finalGenreRaw = existingTrack.genre
            }
            let finalGenre = MetadataSanitizer.normalizeGenre(finalGenreRaw) ?? finalGenreRaw

            // Track number management:
            // Always preserve local track number as ground truth. Never overwrite local track numbers with online numbers.
            let originalTrackNumber = existingTrack.originalTrackNumber ?? existingTrack.trackNumber
            let finalOriginalTrackNumber: Int?
            let finalDeluxeTrackNumber: Int?
            let finalTrackNumber: Int?

            let isLocalDeluxe = (editionPref == .deluxe || isOnlineDeluxe)
            if let localNum = existingTrack.trackNumber, localNum > 0 {
                finalOriginalTrackNumber = originalTrackNumber
                finalDeluxeTrackNumber = existingTrack.deluxeTrackNumber
                finalTrackNumber = localNum
            } else if let onlineNum = onlineMetadata.trackNumber, onlineNum > 0 {
                finalOriginalTrackNumber = originalTrackNumber ?? onlineNum
                finalDeluxeTrackNumber = isLocalDeluxe ? onlineNum : existingTrack.deluxeTrackNumber
                finalTrackNumber = onlineNum
            } else {
                finalOriginalTrackNumber = originalTrackNumber
                finalDeluxeTrackNumber = existingTrack.deluxeTrackNumber
                finalTrackNumber = nil
            }

            let finalTotalTracks = (onlineMetadata.totalTracks ?? 0) > 0
                ? onlineMetadata.totalTracks
                : existingTrack.totalTracks

            let finalDiscNumber = (onlineMetadata.discNumber ?? 0) > 0
                ? onlineMetadata.discNumber
                : existingTrack.discNumber

            let updatedTrack = Track(
                id: existingTrack.id,
                title: finalTitle,
                artist: finalArtist,
                album: finalAlbum,
                albumArtist: onlineMetadata.albumArtist ?? existingTrack.albumArtist,
                genre: finalGenre,
                year: finalYear,
                trackNumber: finalTrackNumber,
                originalTrackNumber: finalOriginalTrackNumber,
                deluxeTrackNumber: finalDeluxeTrackNumber,
                totalTracks: finalTotalTracks,
                discNumber: finalDiscNumber,
                duration: existingTrack.duration,
                url: existingTrack.url,
                artworkKey: finalArtworkKey,
                dateAdded: existingTrack.dateAdded,
                fileInfo: existingTrack.fileInfo,
                lyrics: existingTrack.lyrics
            )

            tracks[trackIndex] = updatedTrack
            processedTrackIDs.insert(diff.localTrack.id)
            enrichedCount += 1
            if existingTrack.canReadLocalBytes && existingTrack.url.isFileURL && !existingTrack.isJellyfinItem {
                fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkKey: artworkKeyForTagging))
            }

            // In-memory cache update only (autoSave: false)
            self.cacheDownloadedMetadata(
                track: updatedTrack,
                onlineMetadata: onlineMetadata,
                artworkKey: finalArtworkKey,
                wasApplied: true,
                autoSave: false
            )

            let updatedDiff = MetadataDiff(
                localTrack: updatedTrack,
                onlineMetadata: onlineMetadata,
                preserveLocalTitleAndArtist: preserveLocalTitleAndArtist
            )
            if (updatedTrack.year ?? 0) >= 1900 {
                newVerifiedGood.append(updatedDiff)
            } else {
                self.unmatchedTrackIDs.insert(updatedTrack.id)
            }

            let progressVal = 0.35 + (Double(idx + 1) / Double(total)) * 0.40
            if !settings.writeMetadataToAudioFiles {
                self.enrichProcessedCount = idx + 1
                onCountProgress?(idx + 1, total)
            }
            if idx % 10 == 0 || idx == total - 1 {
                onProgress?(progressVal, "Step 2/3: Applying metadata (\(idx + 1)/\(total)): \(finalTitle)")
                await Task.yield()
            }
        }

        // MARK: - Step 2.5: Lossless Audio File Tag Writing with Bounded Worker Pool & On-Demand Artwork Loading
        if settings.writeMetadataToAudioFiles && !fileTaggingQueue.isEmpty {
            let taggingTotal = fileTaggingQueue.count
            var taggingDone = 0
            self.enrichTotalCount = taggingTotal
            self.enrichProcessedCount = 0
            onCountProgress?(0, taggingTotal)
            onProgress?(0.75, "Step 3/3: Embedding tags into audio files on disk (0/\(taggingTotal))...")

            let maxTagWorkers = 4
            var queueIndex = 0

            await withTaskGroup(of: Void.self) { group in
                while queueIndex < taggingTotal && queueIndex < maxTagWorkers {
                    let item = fileTaggingQueue[queueIndex]
                    queueIndex += 1
                    group.addTask {
                        let artData: Data?
                        if let artKey = item.artworkKey {
                            artData = await ArtworkCacheService.shared.loadArtwork(key: artKey)
                        } else {
                            artData = nil
                        }
                        _ = await AudioFileMetadataWriter.shared.writeMetadata(
                            to: item.url,
                            title: item.track.title,
                            artist: item.track.artist,
                            album: item.track.album,
                            albumArtist: item.track.albumArtist,
                            year: item.track.year,
                            genre: item.track.genre,
                            trackNumber: item.track.trackNumber,
                            totalTracks: item.track.totalTracks,
                            discNumber: item.track.discNumber,
                            artworkData: artData
                        )
                    }
                }

                for await _ in group {
                    taggingDone += 1
                    self.enrichProcessedCount = taggingDone
                    self.enrichTotalCount = taggingTotal
                    onCountProgress?(taggingDone, taggingTotal)
                    let p = 0.75 + (Double(taggingDone) / Double(max(1, taggingTotal))) * 0.15
                    let activeTrackName = taggingDone <= fileTaggingQueue.count ? fileTaggingQueue[taggingDone - 1].track.title : ""
                    onProgress?(p, "Writing audio tags (\(taggingDone)/\(taggingTotal)): \(activeTrackName)")

                    if queueIndex < taggingTotal {
                        let nextItem = fileTaggingQueue[queueIndex]
                        queueIndex += 1
                        group.addTask {
                            let nextArtData: Data?
                            if let nextArtKey = nextItem.artworkKey {
                                nextArtData = await ArtworkCacheService.shared.loadArtwork(key: nextArtKey)
                            } else {
                                nextArtData = nil
                            }
                            _ = await AudioFileMetadataWriter.shared.writeMetadata(
                                to: nextItem.url,
                                title: nextItem.track.title,
                                artist: nextItem.track.artist,
                                album: nextItem.track.album,
                                albumArtist: nextItem.track.albumArtist,
                                year: nextItem.track.year,
                                genre: nextItem.track.genre,
                                trackNumber: nextItem.track.trackNumber,
                                totalTracks: nextItem.track.totalTracks,
                                discNumber: nextItem.track.discNumber,
                                artworkData: nextArtData
                            )
                        }
                    }
                }
            }
        }

        // MARK: - Step 3: Single Transaction Library & Cache Persistence
        onProgress?(0.92, "Rebuilding albums and updating discographies...")
        rebuildAlbumsAndArtists()
        await recalculateDuplicates()

        onProgress?(0.96, "Saving library database...")
        saveLibrary()
        saveEnrichmentCache()
        saveDownloadedMetadataCache()

        // Clean up diff lists and update verified good tracks only AFTER file tagging and persistence are complete
        self.enrichmentDiffs.removeAll { processedTrackIDs.contains($0.id) }
        self.unmatchedTrackIDs.subtract(processedTrackIDs)
        self.verifiedGoodDiffs.removeAll { processedTrackIDs.contains($0.id) }
        self.verifiedGoodDiffs.append(contentsOf: newVerifiedGood)

        // MARK: - Step 4: Verification & Resource Cleanup (Purge memory cache)
        onProgress?(0.99, "Verifying applied changes and finalizing...")
        fileTaggingQueue.removeAll(keepingCapacity: false)
        await MusicMetadataService.shared.clearCache()
        await ArtworkCacheService.shared.clearMemoryCache()

        AppLogger.metadata.info("[Enrichment Complete] Successfully enriched \(enrichedCount) tracks with verified online metadata.")
        onProgress?(1.0, "Enrichment complete! Successfully enriched \(enrichedCount) tracks.")
        return enrichedCount
    }

    /// Checks metadata for all tracks in a specific album and returns their side-by-side diffs.
    public func checkMetadataForAlbum(album: Album, source: MetadataAPIOption = .all) async -> [MetadataDiff] {
        // Catalog songs
        let catalogSongs = await MusicMetadataService.shared.searchAlbumSongs(
            album: album.title,
            artist: album.artist,
            source: source
        )

        // Diffs
        var diffs: [MetadataDiff] = []
        for local in album.tracks {
            // Sig
            let sig = MetadataSanitizer.sanitize(track: local)
            if let best = DisambiguationMatcher.bestMatch(for: sig, in: catalogSongs ?? []) {
                // Diff
                let diff = MetadataDiff(localTrack: local, onlineMetadata: best, preserveLocalTitleAndArtist: true)
                diffs.append(diff)
            } else if let single = await MusicMetadataService.shared.findExactMatch(for: local, source: source) {
                // Diff
                let diff = MetadataDiff(localTrack: local, onlineMetadata: single, preserveLocalTitleAndArtist: true)
                diffs.append(diff)
            }
        }
        return diffs
    }

    /// Finds local tracks matching an online album and generates side-by-side enrichment diffs.
    public func checkMetadataForOnlineAlbum(title: String, artist: String, source: MetadataAPIOption = .all) async -> [MetadataDiff] {
        // Target tracks
        var targetTracks: [Track] = []
        if let localAlbum = findAlbum(title: title, artist: artist) {
            targetTracks = localAlbum.tracks
        } else {
            // Clean title
            let cleanTitle = FuzzyMatcher.normalize(title)
            // Clean artist
            let cleanArtist = FuzzyMatcher.normalize(artist)
            targetTracks = tracks.filter { track in
                // T album
                let tAlbum = FuzzyMatcher.normalize(track.album)
                // T artist
                let tArtist = FuzzyMatcher.normalize(track.artist)
                return (tAlbum == cleanTitle || tAlbum.contains(cleanTitle) || cleanTitle.contains(tAlbum)) &&
                       (tArtist == cleanArtist || tArtist.contains(cleanArtist) || cleanArtist.contains(tArtist))
            }
        }

        // Ensure preconditions are met before proceeding
        guard !targetTracks.isEmpty else { return [] }

        // Catalog songs
        let catalogSongs = await MusicMetadataService.shared.searchAlbumSongs(
            album: title,
            artist: artist,
            source: source
        )

        // Diffs
        var diffs: [MetadataDiff] = []
        for local in targetTracks {
            // Sig
            let sig = MetadataSanitizer.sanitize(track: local)
            if let best = DisambiguationMatcher.bestMatch(for: sig, in: catalogSongs ?? []) {
                // Diff
                let diff = MetadataDiff(localTrack: local, onlineMetadata: best, preserveLocalTitleAndArtist: true)
                diffs.append(diff)
            } else if let single = await MusicMetadataService.shared.findExactMatch(for: local, source: source) {
                // Diff
                let diff = MetadataDiff(localTrack: local, onlineMetadata: single, preserveLocalTitleAndArtist: true)
                diffs.append(diff)
            }
        }
        return diffs
    }


    /// Finds all local tracks by an artist, including fuzzy/case-insensitive/punctuation duplicates (e.g., "J Cole", "J. COLE", "j. cole").
    public func findTracksForArtistDiscography(artistName: String) -> [Track] {
        let normalizedTarget = FuzzyMatcher.normalize(artistName)
        guard !normalizedTarget.isEmpty else { return [] }
        return tracks.filter { track in
            let normalizedTrackArtist = track.normalizedArtist
            if normalizedTrackArtist == normalizedTarget { return true }
            if track.artist.localizedCaseInsensitiveCompare(artistName) == .orderedSame { return true }
            // Check similarity score for minor variations / punctuation differences
            let score = FuzzyMatcher.evaluateScore(cleanText: normalizedTrackArtist, cleanQuery: normalizedTarget)
            return score >= 85
        }
    }

    /// Triggers a multi-source (iTunes + Deezer + MusicBrainz) discography scan specifically for all tracks of an artist.
    public func scanArtistDiscographyMetadata(artistName: String, source: MetadataAPIOption = .all) {
        let targetArtist = findArtist(name: artistName) ?? artists.first(where: {
            $0.name.localizedCaseInsensitiveCompare(artistName) == .orderedSame ||
            ArtistParser.canonicalArtistKey($0.name) == ArtistParser.canonicalArtistKey(artistName)
        })

        // Strictly isolate artist's own albums and exclude featured-on albums!
        let ownAlbums: [Album] = {
            if let target = targetArtist {
                return target.albums.filter {
                    !$0.isFeaturedAlbum(for: artistName, joinedArtists: settings.joinedArtists)
                }
            } else {
                return albums.filter {
                    $0.isLeadOrCollaborativeAlbum(for: artistName, joinedArtists: settings.joinedArtists) &&
                    !$0.isFeaturedAlbum(for: artistName, joinedArtists: settings.joinedArtists)
                }
            }
        }()

        guard !ownAlbums.isEmpty else { return }

        isScanningArtistDiscography = true
        isDiscographyScanComplete = false
        activeDiscographyScanArtistName = artistName
        discographyScanProgress = 0.0
        discographyScanStatusText = "Scanning discography for \(artistName)..."
        discographyScanResult = nil

        let totalAlbumsCount = Double(ownAlbums.count)
        let allLibraryTracks = self.tracks
        let allLibraryAlbums = self.albums

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            var scannedAlbumItems: [DiscographyAlbumReviewItem] = []
            scannedAlbumItems.reserveCapacity(ownAlbums.count)

            for (index, localAlbum) in ownAlbums.enumerated() {
                let progressFraction = Double(index) / totalAlbumsCount
                await MainActor.run {
                    self.discographyScanProgress = progressFraction
                    self.discographyScanStatusText = "Scanning (\(index + 1)/\(ownAlbums.count)): \"\(localAlbum.title)\"..."
                }

                // 1. Search online albums for this specific album (exact path as AlbumMetadataSheet)
                let searchQuery = "\(localAlbum.artist) \(localAlbum.title)".trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateAlbums = await MusicMetadataService.shared.searchOnlineAlbums(query: searchQuery, source: source)

                let onlineAlbumCandidate: OnlineAlbumItem?
                if let first = candidateAlbums.first {
                    onlineAlbumCandidate = first
                } else {
                    let fallbackCandidates = await MusicMetadataService.shared.searchOnlineAlbums(query: localAlbum.title, source: source)
                    onlineAlbumCandidate = fallbackCandidates.first(where: {
                        let candArtist = FuzzyMatcher.normalize($0.artistName)
                        let artNorm = FuzzyMatcher.normalize(artistName)
                        return candArtist == artNorm || candArtist.contains(artNorm) || artNorm.contains(candArtist)
                    }) ?? fallbackCandidates.first
                }

                guard let bestOnlineAlbum = onlineAlbumCandidate else {
                    continue
                }

                // 2. Fetch track cuts for this online album
                let cuts = await MusicMetadataService.shared.fetchOnlineAlbumCuts(albumItem: bestOnlineAlbum)
                guard !cuts.isEmpty else { continue }

                // 3. Optimal bipartite matching with candidate tracks
                let (assignments, unmatchedTracks) = await Task.detached(priority: .userInitiated) { () -> ([DisambiguationMatcher.AlbumCutAssignment], [Track]) in
                    let localIDs = Set(localAlbum.tracks.map { $0.id })
                    var cutTitles = Set<String>()
                    for cut in cuts {
                        cutTitles.insert(FuzzyMatcher.normalize(cut.title))
                        let sig = MetadataSanitizer.buildSignature(title: cut.title, artist: cut.artist, album: cut.album)
                        cutTitles.insert(FuzzyMatcher.normalize(sig.coreTitle))
                    }

                    let cleanAlbumArtist = FuzzyMatcher.normalize(localAlbum.artist)
                    let cleanOnlineArtist = FuzzyMatcher.normalize(bestOnlineAlbum.artistName)

                    var candidateTracks = localAlbum.tracks
                    var seenIDs = localIDs

                    for track in allLibraryTracks {
                        guard !seenIDs.contains(track.id) else { continue }
                        let tTitle = FuzzyMatcher.normalize(track.title)
                        let sig = MetadataSanitizer.sanitize(track: track)
                        let tCoreTitle = FuzzyMatcher.normalize(sig.coreTitle)
                        guard cutTitles.contains(tTitle) || cutTitles.contains(tCoreTitle) else { continue }

                        let tArtist = FuzzyMatcher.normalize(track.artist)
                        let isArtistMatch = (!cleanAlbumArtist.isEmpty && (tArtist == cleanAlbumArtist || tArtist.contains(cleanAlbumArtist) || cleanAlbumArtist.contains(tArtist))) ||
                                            (!cleanOnlineArtist.isEmpty && (tArtist == cleanOnlineArtist || tArtist.contains(cleanOnlineArtist) || cleanOnlineArtist.contains(tArtist)))

                        if isArtistMatch {
                            candidateTracks.append(track)
                            seenIDs.insert(track.id)
                        }
                    }

                    let (matched, _) = DisambiguationMatcher.matchAlbumTracklistToCandidates(
                        onlineTracks: cuts,
                        albumTitle: bestOnlineAlbum.title,
                        albumArtist: bestOnlineAlbum.artistName,
                        candidateTracks: candidateTracks
                    )

                    var matchedInAlbum: Set<UUID> = []
                    for a in matched {
                        guard let local = a.localTrack else { continue }
                        if localAlbum.tracks.contains(where: { $0.id == local.id }) {
                            matchedInAlbum.insert(local.id)
                        }
                    }
                    let unmatched = localAlbum.tracks.filter { !matchedInAlbum.contains($0.id) }
                    return (matched, unmatched)
                }.value

                // 4. Resolve unmatched tracks (alternates / other album moves / keep in main)
                var unmatchedActions: [UUID: UnmatchedTrackAction] = [:]
                if !unmatchedTracks.isEmpty {
                    let resolvedActions = await AlbumOrganizationService.shared.resolveAllUnmatchedTracks(
                        tracks: unmatchedTracks,
                        currentAlbum: localAlbum,
                        onlineAlbum: bestOnlineAlbum,
                        onlineCuts: cuts,
                        libraryAlbums: allLibraryAlbums
                    )
                    for (id, action) in resolvedActions {
                        unmatchedActions[id] = action
                    }
                }

                // 5. Categorize album
                let itemCategory: DiscographyReviewCategory
                if localAlbum.isRemix || localAlbum.isLive {
                    itemCategory = .alternates
                } else if localAlbum.isSingle {
                    itemCategory = .singles
                } else {
                    itemCategory = .albums
                }

                let reviewItem = DiscographyAlbumReviewItem(
                    album: localAlbum,
                    selectedOnlineAlbum: bestOnlineAlbum,
                    onlineCuts: cuts,
                    assignments: assignments,
                    unmatchedTracks: unmatchedTracks,
                    unmatchedActions: unmatchedActions,
                    category: itemCategory
                )
                scannedAlbumItems.append(reviewItem)
            }

            // Categorize into final result
            var studioAlbums: [DiscographyAlbumReviewItem] = []
            var singles: [DiscographyAlbumReviewItem] = []
            var alternates: [DiscographyAlbumReviewItem] = []

            for item in scannedAlbumItems {
                switch item.category {
                case .albums:
                    studioAlbums.append(item)
                case .singles:
                    singles.append(item)
                case .alternates:
                    alternates.append(item)
                }
            }

            let sortBlock: (DiscographyAlbumReviewItem, DiscographyAlbumReviewItem) -> Bool = { lhs, rhs in
                let yL = lhs.album.resolvedYear ?? lhs.album.year ?? 0
                let yR = rhs.album.resolvedYear ?? rhs.album.year ?? 0
                if yL != yR { return yL > yR }
                return lhs.album.title.localizedCaseInsensitiveCompare(rhs.album.title) == .orderedAscending
            }
            studioAlbums.sort(by: sortBlock)
            singles.sort(by: sortBlock)
            alternates.sort(by: sortBlock)

            let finalResult = DiscographyScanResult(
                artistName: artistName,
                albums: studioAlbums,
                singles: singles,
                alternates: alternates
            )

            await MainActor.run {
                self.discographyScanResult = finalResult
                self.discographyScanProgress = 1.0
                self.discographyScanStatusText = "Scan Complete • \(finalResult.totalMatchesCount) Albums Matched"
                self.isScanningArtistDiscography = false
                self.isDiscographyScanComplete = true
            }
        }
    }

    /// Applies and commits the reviewed multi-source discography scan result to local audio tracks and files on disk.
    public func commitDiscographyScanResult(
        _ result: DiscographyScanResult,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async {
        let allItems = result.albums + result.singles + result.alternates
        guard !allItems.isEmpty else {
            onProgress?(1.0, "No albums to update.")
            return
        }

        let total = Double(allItems.count)
        var appliedCount = 0

        for (index, item) in allItems.enumerated() {
            let progressFraction = Double(index) / total
            onProgress?(progressFraction, "Applying album (\(index + 1)/\(allItems.count)): \"\(item.album.title)\"...")

            // Compute active assignments based on rejected/accepted track IDs and locks
            var activeAssignments: [DisambiguationMatcher.AlbumCutAssignment] = []
            for assignment in item.assignments {
                guard let local = assignment.localTrack else { continue }
                guard !item.lockedTrackIDs.contains(local.id) else { continue }
                let isLocalInAlbum = item.album.tracks.contains(where: { $0.id == local.id })
                if isLocalInAlbum {
                    if !item.rejectedTrackIDs.contains(local.id) {
                        activeAssignments.append(assignment)
                    }
                } else {
                    if item.acceptedTrackIDs.contains(local.id) {
                        activeAssignments.append(assignment)
                    }
                }
            }

            let targetTracks = activeAssignments.compactMap { $0.localTrack }
            let tracksToApply = targetTracks.isEmpty ? item.album.tracks : targetTracks

            // Filter unmatched actions to exclude locked tracks
            var activeUnmatchedActions = item.unmatchedActions
            for lockedID in item.lockedTrackIDs {
                activeUnmatchedActions.removeValue(forKey: lockedID)
            }

            let success = await applyOnlineAlbumToAlbum(
                album: item.album,
                onlineAlbum: item.selectedOnlineAlbum,
                onlineTracks: item.onlineCuts,
                preserveLocalTitleAndArtist: false,
                specificTracksToApply: tracksToApply,
                specificAssignments: activeAssignments,
                unmatchedActions: activeUnmatchedActions
            )

            if success {
                appliedCount += 1
            }
        }

        onProgress?(1.0, "Successfully updated \(appliedCount) albums.")
    }

    /// Launches an isolated background metadata scan off the main thread.
    public func startBackgroundMetadataScan(for customTracks: [Track]? = nil, forceRecheck: Bool = false) {
        // Ensure preconditions are met before proceeding
        guard !isBackgroundCheckingMetadata else { return }
        let rawTracks = customTracks ?? self.tracks
        let tracksToScan = rawTracks.filter { !isTrackExcludedFromTagEnrichment($0) }
        guard !tracksToScan.isEmpty else { return }

        isBackgroundCheckingMetadata = true
        isBackgroundCheckingMetadataPaused = false
        backgroundCheckProgress = 0.0
        backgroundCheckScannedCount = 0
        backgroundCheckTotalCount = tracksToScan.count
        backgroundCheckStatusText = "Initializing metadata scan..."

        // Immediately index any tracks with complete tags so they're recognized as Good right away
        self.indexCompleteTracksIntoVerifiedGood()

        // Diffs
        let diffs = self.enrichmentDiffs
        // Good
        let good = self.verifiedGoodDiffs
        // Unmatched
        let unmatched = self.unmatchedTrackIDs
        // File system location for storage url
        let storageURL = self.storageDirectoryURL

        Task { [weak self] in
            await BackgroundMetadataScanner.shared.startScan(
                tracks: tracksToScan,
                existingDiffs: diffs,
                existingGood: good,
                existingUnmatched: unmatched,
                forceRecheck: forceRecheck,
                storageDirectoryURL: storageURL,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.backgroundCheckProgress = progress.progress
                        self.backgroundCheckScannedCount = progress.scannedCount
                        self.backgroundCheckTotalCount = progress.totalCount
                        self.backgroundCheckStatusText = progress.statusText
                        if !progress.enrichmentDiffs.isEmpty || !progress.verifiedGoodDiffs.isEmpty || !progress.unmatchedTrackIDs.isEmpty {
                            self.enrichmentDiffs = progress.enrichmentDiffs
                            self.verifiedGoodDiffs = progress.verifiedGoodDiffs
                            self.unmatchedTrackIDs = progress.unmatchedTrackIDs
                        }
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.enrichmentDiffs = result.enrichmentDiffs
                        self.verifiedGoodDiffs = result.verifiedGoodDiffs
                        self.unmatchedTrackIDs = result.unmatchedTrackIDs
                        self.isBackgroundCheckingMetadata = false
                        self.isBackgroundCheckingMetadataPaused = false
                        self.backgroundCheckProgress = 1.0
                        self.backgroundCheckScannedCount = self.backgroundCheckTotalCount
                        self.backgroundCheckStatusText = "Library analysis complete."
                        self.saveEnrichmentCache()
                    }
                }
            )
        }
    }

    /// Pauses any currently active background scan.
    public func pauseBackgroundMetadataScan() {
        Task {
            await BackgroundMetadataScanner.shared.pause()
            await MainActor.run {
                self.isBackgroundCheckingMetadataPaused = true
            }
        }
    }

    /// Resumes a paused background scan.
    public func resumeBackgroundMetadataScan() {
        Task {
            await BackgroundMetadataScanner.shared.resume()
            await MainActor.run {
                self.isBackgroundCheckingMetadataPaused = false
            }
        }
    }

    /// Cancels any currently active background scan.
    public func cancelBackgroundMetadataScan() {
        Task {
            await BackgroundMetadataScanner.shared.cancel()
            await MainActor.run {
                self.isBackgroundCheckingMetadata = false
                self.isBackgroundCheckingMetadataPaused = false
                self.saveEnrichmentCache()
            }
        }
    }

    /// Triggers a full rescan of all metadata from scratch.
    public func rescanAllMetadata() {
        startBackgroundMetadataScan(forceRecheck: false)
    }

    /// Audits all library tracks and immediately indexes any tracks whose tags are filled in the app's cache into `verifiedGoodDiffs`.
    public func indexCompleteTracksIntoVerifiedGood() {
        let currentTracks = self.tracks.filter { !self.isTrackExcludedFromTagEnrichment($0) }
        let currentExistingIDs = Set(verifiedGoodDiffs.map { $0.localTrack.id })
        let currentDiffIDs = Set(enrichmentDiffs.map { $0.localTrack.id })

        Task.detached(priority: .background) { [weak self] in
            var newGood: [MetadataDiff] = []
            var existingIDs = currentExistingIDs

            for track in currentTracks {
                if existingIDs.contains(track.id) || currentDiffIDs.contains(track.id) {
                    continue
                }

                var effectiveTrack = track
                var isComplete = effectiveTrack.isComplete7CoreTags

                // If artwork key is nil, check if album artwork is available in the app's cache
                if !isComplete && effectiveTrack.artworkKey == nil {
                    let albumKey = ArtworkCacheService.albumArtworkKey(artist: effectiveTrack.artist, album: effectiveTrack.album)
                    if ArtworkCacheService.hasCachedArtworkFile(key: albumKey) {
                        effectiveTrack = effectiveTrack.withArtworkKey(albumKey)
                        isComplete = effectiveTrack.isComplete7CoreTags
                    }
                }

                if isComplete {
                    let syntheticOnline = OnlineTrackMetadata(
                        id: "local_verified_\(effectiveTrack.id)",
                        title: effectiveTrack.title,
                        artist: effectiveTrack.artist,
                        album: effectiveTrack.album,
                        albumArtist: effectiveTrack.albumArtist,
                        releaseDate: nil,
                        releaseYear: effectiveTrack.year,
                        genre: effectiveTrack.genre,
                        trackNumber: effectiveTrack.trackNumber,
                        totalTracks: effectiveTrack.totalTracks,
                        discNumber: effectiveTrack.discNumber,
                        duration: effectiveTrack.duration,
                        artworkURL: nil,
                        previewURL: nil,
                        sourceAPI: "Cache Tags Verified",
                        isCompilation: false
                    )
                    let diff = MetadataDiff(localTrack: effectiveTrack, onlineMetadata: syntheticOnline, preserveLocalTitleAndArtist: true)
                    newGood.append(diff)
                    existingIDs.insert(effectiveTrack.id)
                }
            }

            if !newGood.isEmpty {
                let goodToAppend = newGood
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.verifiedGoodDiffs.append(contentsOf: goodToAppend)
                    let addedIDs = Set(goodToAppend.map { $0.localTrack.id })
                    self.unmatchedTrackIDs.subtract(addedIDs)
                    self.saveEnrichmentCache()
                    AppLogger.metadata.info("[LibraryStore] Indexed \(goodToAppend.count) complete cached tracks directly into Verified Good.")
                }
            }
        }
    }

    // MARK: - Manual Collaborative Albums

    /// Checks if an album is manually designated as a collaborative album.
    public func isCollaborativeAlbum(_ album: Album) -> Bool {
        if settings.manualCollaborativeAlbumIDs.contains(album.id) {
            return true
        }
        let trackIDStrings = album.tracks.map { $0.id.uuidString }
        if !trackIDStrings.isEmpty && trackIDStrings.allSatisfy({ settings.originalAlbumArtistsByTrackID[$0] != nil }) {
            return true
        }
        return false
    }

    /// Toggles the collaborative status of an album.
    public func toggleCollaborativeAlbum(_ album: Album) {
        if isCollaborativeAlbum(album) {
            revertCollaborativeAlbum(album)
        } else {
            makeCollaborativeAlbum(album)
        }
    }

    /// Marks an album as collaborative, setting all artists in each track as album artists, and persisting the original values.
    public func makeCollaborativeAlbum(_ album: Album) {
        settings.manualCollaborativeAlbumIDs.insert(album.id)

        // Find all tracks in the library belonging to this album
        let albumTrackIDs = Set(album.tracks.map { $0.id })
        guard !albumTrackIDs.isEmpty else { return }

        // Find all artists present across the album tracks (ONLY track.artist, strictly excluding title features!)
        var distinctArtists: [String] = []
        var seenArtists = Set<String>()
        for track in album.tracks {
            let artistsOnTrack = ArtistParser.parseArtists(from: track.artist)
            for artist in artistsOnTrack {
                let clean = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let canon = ArtistParser.canonicalArtistKey(clean)
                if !canon.isEmpty && !ArtistParser.isGenericArtistName(clean) && seenArtists.insert(canon).inserted {
                    distinctArtists.append(clean)
                }
            }
        }
        guard !distinctArtists.isEmpty else { return }
        let unifiedAlbumArtist = ArtistParser.formatDisplayArtist(distinctArtists)

        for i in 0..<tracks.count {
            if albumTrackIDs.contains(tracks[i].id) {
                let trackIDStr = tracks[i].id.uuidString
                // Preserve original album artist if not already stored
                if settings.originalAlbumArtistsByTrackID[trackIDStr] == nil {
                    settings.originalAlbumArtistsByTrackID[trackIDStr] = tracks[i].albumArtist ?? "__NIL__"
                }

                // Set all album tracks uniformly to the unified album artist
                tracks[i] = tracks[i].withAlbumArtist(unifiedAlbumArtist)
            }
        }

        rebuildAlbumsAndArtists()

        // Also track the newly generated album ID so lookup by ID remains instant
        if let firstTrackID = album.tracks.first?.id,
           let newAlbum = self.albums.first(where: { $0.tracks.contains(where: { $0.id == firstTrackID }) }) {
            settings.manualCollaborativeAlbumIDs.insert(newAlbum.id)
        }

        saveLibrary()
        saveSettings()
    }

    /// Reverts an album back to default, restoring original album artists for each track.
    public func revertCollaborativeAlbum(_ album: Album) {
        settings.manualCollaborativeAlbumIDs.remove(album.id)

        let albumTrackIDs = Set(album.tracks.map { $0.id })
        for i in 0..<tracks.count {
            if albumTrackIDs.contains(tracks[i].id) {
                let trackIDStr = tracks[i].id.uuidString
                if let original = settings.originalAlbumArtistsByTrackID[trackIDStr] {
                    tracks[i] = tracks[i].withAlbumArtist(original == "__NIL__" ? nil : original)
                    settings.originalAlbumArtistsByTrackID.removeValue(forKey: trackIDStr)
                }
            }
        }

        rebuildAlbumsAndArtists()

        // Remove any new/reverted IDs from manualCollaborativeAlbumIDs
        if let firstTrackID = album.tracks.first?.id,
           let revertedAlbum = self.albums.first(where: { $0.tracks.contains(where: { $0.id == firstTrackID }) }) {
            settings.manualCollaborativeAlbumIDs.remove(revertedAlbum.id)
        }

        saveLibrary()
        saveSettings()
    }

    /// Re-checks a single verified good track against online database.
    public func recheckVerifiedGoodTrack(_ track: Track) async -> Bool {
        verifiedGoodDiffs.removeAll { $0.id == track.id }
        // Match
        let match = await MusicMetadataService.shared.findExactMatch(for: track)
        if let match = match {
            // Diff
            let diff = MetadataDiff(localTrack: track, onlineMetadata: match, preserveLocalTitleAndArtist: true)
            if diff.fieldsEnrichedCount > 0 {
                enrichmentDiffs.removeAll { $0.id == track.id }
                enrichmentDiffs.append(diff)
            } else {
                verifiedGoodDiffs.append(diff)
            }
            saveEnrichmentCache()
            cacheDownloadedMetadata(track: track, onlineMetadata: match, wasApplied: false)
            return true
        } else {
            unmatchedTrackIDs.insert(track.id)
            saveEnrichmentCache()
            return false
        }
    }

    /// Re-checks all verified good tracks in the background queue.
    public func recheckAllVerifiedGoodTracks() {
        let tracksToRecheck = verifiedGoodDiffs.map { $0.localTrack }
        guard !tracksToRecheck.isEmpty else { return }
        self.verifiedGoodDiffs.removeAll()
        saveEnrichmentCache()
        startBackgroundMetadataScan(for: tracksToRecheck, forceRecheck: true)
    }

    /// Re-checks a single unmatched track against online database.
    public func recheckUnmatchedTrack(_ track: Track) async -> Bool {
        unmatchedTrackIDs.remove(track.id)
        // Match
        let match = await MusicMetadataService.shared.findExactMatch(for: track)
        if let match = match {
            // Diff
            let diff = MetadataDiff(localTrack: track, onlineMetadata: match, preserveLocalTitleAndArtist: true)
            if diff.fieldsEnrichedCount > 0 {
                enrichmentDiffs.removeAll { $0.id == track.id }
                enrichmentDiffs.append(diff)
            } else {
                verifiedGoodDiffs.removeAll { $0.id == track.id }
                verifiedGoodDiffs.append(diff)
            }
            saveEnrichmentCache()
            cacheDownloadedMetadata(track: track, onlineMetadata: match, wasApplied: false)
            return true
        } else {
            unmatchedTrackIDs.insert(track.id)
            saveEnrichmentCache()
            return false
        }
    }

    /// Re-checks a single track against a specific online provider (Apple Music, Deezer, MusicBrainz).
    /// If an exact match is found, updates `enrichmentDiffs` or `verifiedGoodDiffs` and caches the metadata.
    /// Returns the newly found `OnlineTrackMetadata` if matched.
    public func recheckTrackWithSpecificAPI(track: Track, source: MetadataAPIOption) async -> OnlineTrackMetadata? {
        let match = await MusicMetadataService.shared.findExactMatch(for: track, source: source)
        if let match = match {
            let diff = MetadataDiff(localTrack: track, onlineMetadata: match, preserveLocalTitleAndArtist: true)
            enrichmentDiffs.removeAll { $0.localTrack.id == track.id }
            verifiedGoodDiffs.removeAll { $0.localTrack.id == track.id }
            unmatchedTrackIDs.remove(track.id)

            if diff.fieldsEnrichedCount > 0 {
                enrichmentDiffs.append(diff)
            } else {
                verifiedGoodDiffs.append(diff)
            }
            saveEnrichmentCache()
            cacheDownloadedMetadata(track: track, onlineMetadata: match, wasApplied: false)
            return match
        }
        return nil
    }

    /// Re-checks all currently unmatched / ignored tracks in the background queue.
    public func recheckAllUnmatchedTracks() {
        let unmatchedList = unmatchedTracks
        guard !unmatchedList.isEmpty else { return }
        self.unmatchedTrackIDs.removeAll()
        saveEnrichmentCache()
        startBackgroundMetadataScan(for: unmatchedList, forceRecheck: true)
    }

    /// Automatically scans and enriches all tracks missing artwork or release metadata.
    public func enrichAllMissingMetadata() async {
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }
        self.isEnrichingMetadata = true
        self.enrichProgress = 0.0
        self.enrichStatusText = "Scanning library for missing metadata..."

        // Candidates
        let candidates = tracks.filter { !isTrackExcludedFromTagEnrichment($0) && ($0.artworkKey == nil || $0.year == nil || $0.trackNumber == nil) }
        // Total
        let total = candidates.count
        self.enrichTotalCount = total
        self.enrichProcessedCount = 0

        defer {
            self.isEnrichingMetadata = false
            self.enrichProcessedCount = 0
            self.enrichTotalCount = 0
        }

        // Ensure preconditions are met before proceeding
        guard total > 0 else {
            self.enrichProgress = 1.0
            self.enrichStatusText = "All tracks already have complete metadata and artwork."
            return
        }

        // Enriched count
        var enrichedCount = 0
        for (idx, track) in candidates.enumerated() {
            self.enrichProcessedCount = idx + 1
            self.enrichProgress = Double(idx + 1) / Double(total)
            self.enrichStatusText = "Enriching (\(idx + 1)/\(total)): \(track.title)"

            // Exact match
            let exactMatch = await MusicMetadataService.shared.findExactMatch(for: track)
            if let bestMatch = exactMatch {
                // Art data
                var artData: Data? = nil
                // File path location
                if let artURL = bestMatch.artworkURL, track.artworkKey == nil {
                    artData = await MusicMetadataService.shared.downloadArtworkData(from: artURL)
                }

                // Success
                let success = await applyOnlineMetadata(
                    trackID: track.id,
                    onlineMetadata: bestMatch,
                    artworkData: artData
                )
                if success { enrichedCount += 1 }
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        self.enrichProgress = 1.0
        self.enrichStatusText = "Enrichment complete. Updated \(enrichedCount) tracks."
    }

    // MARK: - Persistence Engine

    // File path location
    private var libraryFileURL: URL { storageDirectoryURL.appendingPathComponent("library.json") }
    // Cached pre-computed albums for instant cold boot
    private var albumsFileURL: URL { storageDirectoryURL.appendingPathComponent("albums.json") }
    // Cached pre-computed artists for instant cold boot
    private var artistsFileURL: URL { storageDirectoryURL.appendingPathComponent("artists.json") }
    // Recently played album IDs
    private var recentAlbumsFileURL: URL { storageDirectoryURL.appendingPathComponent("recent_albums.json") }
    // Recently played track IDs from Search Library
    private var recentSearchTracksFileURL: URL { storageDirectoryURL.appendingPathComponent("recent_search_tracks.json") }
    // File path location
    private var playlistsFileURL: URL { storageDirectoryURL.appendingPathComponent("playlists.json") }
    // File path location
    private var playCountsFileURL: URL { storageDirectoryURL.appendingPathComponent("playcounts.json") }
    // File path location
    private var playbackPositionsFileURL: URL { storageDirectoryURL.appendingPathComponent("playback_positions.json") }
    // File path location
    private var pinsFileURL: URL { storageDirectoryURL.appendingPathComponent("pins.json") }
    // File path location
    private var settingsFileURL: URL { storageDirectoryURL.appendingPathComponent("settings.json") }
    // File path location
    private var duplicatesFileURL: URL { storageDirectoryURL.appendingPathComponent("duplicates.json") }
    // File path location
    private var enrichmentFileURL: URL { storageDirectoryURL.appendingPathComponent("enrichment_diffs.json") }
    // File path location
    private var verifiedGoodFileURL: URL { storageDirectoryURL.appendingPathComponent("verified_good_diffs.json") }
    // File path location
    private var unmatchedFileURL: URL { storageDirectoryURL.appendingPathComponent("unmatched_tracks.json") }
    // File path location for persistent downloaded metadata cache
    private var downloadedMetadataCacheFileURL: URL { storageDirectoryURL.appendingPathComponent("downloaded_metadata_cache.json") }
    // File path location for multi-mode organization state (METADATA vs FOLDER)
    private var organizationModesFileURL: URL { storageDirectoryURL.appendingPathComponent("organization_modes.json") }
    private var librarySnapshotURL: URL { storageDirectoryURL.appendingPathComponent("library.snapshot") }

    public func computeSettingsHash() -> String {
        let joinedPart = settings.joinedArtists.sorted().joined(separator: "|")
        let colPart = settings.manualCollaborativeAlbumIDs.sorted().joined(separator: "|")
        let methodPart = settings.libraryScanMethod.rawValue
        let input = "v2_\(joinedPart)_\(colPart)_\(methodPart)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // Fast-boot binary PropertyList cache URLs (up to 10x faster deserialization than JSON)
    private var libraryBinaryCacheURL: URL { storageDirectoryURL.appendingPathComponent("library.cache") }
    private var libraryPreviewCacheURL: URL { storageDirectoryURL.appendingPathComponent("library_preview.cache") }
    private var libraryChunksDirectoryURL: URL { storageDirectoryURL.appendingPathComponent("library_chunks", isDirectory: true) }
    private var libraryChunksManifestURL: URL { storageDirectoryURL.appendingPathComponent("library_chunks_manifest.json") }
    private var albumsBinaryCacheURL: URL { storageDirectoryURL.appendingPathComponent("albums.cache") }
    private var artistsBinaryCacheURL: URL { storageDirectoryURL.appendingPathComponent("artists.cache") }
    private var playlistsBinaryCacheURL: URL { storageDirectoryURL.appendingPathComponent("playlists.cache") }
    private var playCountsBinaryCacheURL: URL { storageDirectoryURL.appendingPathComponent("playcounts.cache") }
    private var playbackPositionsBinaryCacheURL: URL { storageDirectoryURL.appendingPathComponent("playback_positions.cache") }
    private var recentAlbumsCacheURL: URL { storageDirectoryURL.appendingPathComponent("recent_albums.cache") }
    private var pinnedItemsCacheURL: URL { storageDirectoryURL.appendingPathComponent("pinned_items.cache") }
    private var folderStatsCacheURL: URL { storageDirectoryURL.appendingPathComponent("folder_stats.cache") }
    private var folderStatsFileURL: URL { storageDirectoryURL.appendingPathComponent("folder_stats.json") }

    // Isolated Jellyfin per-server caches for instant offline restore
    public func jellyfinServerCacheURL(for serverID: UUID) -> URL {
        storageDirectoryURL.appendingPathComponent("jellyfin_server_\(serverID.uuidString).cache")
    }
    public func jellyfinServerJSONURL(for serverID: UUID) -> URL {
        storageDirectoryURL.appendingPathComponent("jellyfin_server_\(serverID.uuidString).json")
    }

    /// Fast in-process loader that reads precompiled binary property list cache (<10ms)
    /// and gracefully falls back to legacy JSON if binary cache does not exist yet.
    nonisolated public static func loadFast<T: Decodable>(
        from binaryURL: URL,
        fallbackJSONURL: URL,
        onDecodedFallback: (@Sendable (T) -> Void)? = nil
    ) -> T? {
        // 1. Ultra-fast binary PropertyList cache
        if let data = try? Data(contentsOf: binaryURL) {
            let decoder = PropertyListDecoder()
            if let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }
        // 2. Fallback to standard JSON
        if let data = try? Data(contentsOf: fallbackJSONURL) {
            let decoder = JSONDecoder()
            if let decoded = try? decoder.decode(T.self, from: data) {
                onDecodedFallback?(decoded)
                return decoded
            }
        }
        return nil
    }

    /// Fast dual-tier persistence: writes binary PropertyList cache for instant cold-boot loading,
    /// alongside standard JSON for durability and compatibility.
    nonisolated public static func saveFast<T: Encodable>(
        _ value: T,
        to binaryURL: URL,
        jsonURL: URL
    ) {
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        if let binData = try? plistEncoder.encode(value) {
            try? binData.write(to: binaryURL, options: .atomic)
        }
        if let jsonData = try? JSONEncoder().encode(value) {
            try? jsonData.write(to: jsonURL, options: .atomic)
        }
    }

    /// Ultra-fast parallel loader that decodes chunked binary property lists across all CPU hardware cores in parallel (<35ms for 30k+ tracks).
    nonisolated public static func loadChunks(from directoryURL: URL, manifestURL: URL) -> [Track]? {
        guard let mData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(LibraryChunksManifest.self, from: mData),
              manifest.chunkCount > 0 else {
            return nil
        }

        var chunkResults: [[Track]?] = Array(repeating: nil, count: manifest.chunkCount)

        DispatchQueue.concurrentPerform(iterations: manifest.chunkCount) { chunkIdx in
            let chunkFile = directoryURL.appendingPathComponent("chunk_\(chunkIdx).cache")
            let decoder = PropertyListDecoder()
            if let data = try? Data(contentsOf: chunkFile),
               let tracks = try? decoder.decode([Track].self, from: data) {
                chunkResults[chunkIdx] = tracks
            }
        }

        var allTracks: [Track] = []
        allTracks.reserveCapacity(manifest.totalTracks)
        for tracks in chunkResults {
            if let t = tracks {
                allTracks.append(contentsOf: t)
            }
        }
        return allTracks.isEmpty ? nil : allTracks
    }

    /// Parallel binary chunk persistence that splits tracks into bite-sized binary plists across CPU hardware cores (<40ms for 30k+ tracks).
    nonisolated public static func saveChunks(_ tracks: [Track], to directoryURL: URL, manifestURL: URL) {
        let chunkSize = 2500
        let total = tracks.count
        guard total > 0 else {
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: directoryURL)
            return
        }
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let chunkCount = (total + chunkSize - 1) / chunkSize

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIdx in
            let start = chunkIdx * chunkSize
            let end = min(start + chunkSize, total)
            let slice = Array(tracks[start..<end])
            let chunkFile = directoryURL.appendingPathComponent("chunk_\(chunkIdx).cache")
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let binData = try? encoder.encode(slice) {
                try? binData.write(to: chunkFile, options: .atomic)
            }
        }

        // Clean up any stale chunk files beyond chunkCount
        var staleIdx = chunkCount
        while true {
            let staleFile = directoryURL.appendingPathComponent("chunk_\(staleIdx).cache")
            if FileManager.default.fileExists(atPath: staleFile.path) {
                try? FileManager.default.removeItem(at: staleFile)
                staleIdx += 1
            } else {
                break
            }
        }

        let manifest = LibraryChunksManifest(totalTracks: total, chunkCount: chunkCount, chunkSize: chunkSize)
        if let mData = try? JSONEncoder().encode(manifest) {
            try? mData.write(to: manifestURL, options: .atomic)
        }
    }

    // Save downloaded metadata cache non-blockingly
    public func saveDownloadedMetadataCache() {
        let cacheToSave = self.downloadedMetadataCache
        let url = self.downloadedMetadataCacheFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(cacheToSave) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Load downloaded metadata cache
    public func loadDownloadedMetadataCache() {
        if let data = try? Data(contentsOf: downloadedMetadataCacheFileURL),
           let loaded = try? JSONDecoder().decode(PersistentDownloadedMetadataCache.self, from: data) {
            self.downloadedMetadataCache = loaded
            AppLogger.storage.info("Loaded \(loaded.recordsByFilePath.count) downloaded metadata records from cache.")
        }
    }

    // Manually clear downloaded metadata cache
    public func clearDownloadedMetadataCache() {
        self.downloadedMetadataCache = PersistentDownloadedMetadataCache()
        self.enrichmentDiffs = []
        self.verifiedGoodDiffs = []
        self.unmatchedTrackIDs = []

        try? fileManager.removeItem(at: downloadedMetadataCacheFileURL)
        saveEnrichmentCache()
        AppLogger.storage.info("Manually cleared downloaded metadata cache.")
    }

    // Manually clear artwork cache
    public func clearArtworkCache() {
        Task.detached(priority: .utility) {
            await ArtworkCacheService.shared.clearCache()
        }
        AppLogger.storage.info("Manually cleared artwork cache.")
    }

    // Record an album played for LATEST PLAYS
    public func recordAlbumPlayed(albumID: String) {
        guard !albumID.isEmpty else { return }
        var updated = recentAlbumIDs.filter { $0 != albumID }
        updated.insert(albumID, at: 0)
        if updated.count > 25 {
            updated = Array(updated.prefix(25))
        }
        self.recentAlbumIDs = updated

        if let album = album(forID: albumID) ?? albumsByID[albumID] ?? albums.first(where: { $0.id == albumID }) {
            var updatedAlbums = recentAlbumsCache.filter { $0.id != albumID }
            updatedAlbums.insert(album, at: 0)
            if updatedAlbums.count > 25 {
                updatedAlbums = Array(updatedAlbums.prefix(25))
            }
            self.recentAlbumsCache = updatedAlbums
        }
        saveRecentAlbums()
    }

    // Record track played and update its album in LATEST PLAYS
    public func recordTrackPlayed(_ track: Track) {
        if let album = findAlbum(title: track.album, artist: track.albumArtist ?? track.artist) ?? findAlbum(title: track.album) {
            recordAlbumPlayed(albumID: album.id)
        } else {
            let cleanArtist = (track.albumArtist ?? track.artist).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let cleanTitle = track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let y = track.year, y > 0 {
                recordAlbumPlayed(albumID: "\(cleanArtist)_\(cleanTitle)_\(y)")
            } else {
                recordAlbumPlayed(albumID: "\(cleanArtist)_\(cleanTitle)")
            }
        }
    }

    // Save recent albums asynchronously
    public func saveRecentAlbums() {
        let ids = self.recentAlbumIDs
        let albums = self.recentAlbumsCache
        let url = self.recentAlbumsFileURL
        let cacheUrl = self.recentAlbumsCacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(ids) {
                try? data.write(to: url, options: .atomic)
            }
            if let jsonData = try? JSONEncoder().encode(albums) {
                try? jsonData.write(to: cacheUrl, options: .atomic)
            }
        }
    }

    /// Records a track played from the Search Library page and persists to disk.
    public func recordSearchPlayedTrack(_ track: Track) {
        recentSearchPlayedTrackIDs.removeAll { $0 == track.id }
        recentSearchPlayedTrackIDs.insert(track.id, at: 0)
        if recentSearchPlayedTrackIDs.count > 50 {
            recentSearchPlayedTrackIDs = Array(recentSearchPlayedTrackIDs.prefix(50))
        }
        saveRecentSearchPlayedTracks()
    }

    /// Clears recently played tracks history from Search Library.
    public func clearRecentSearchPlayedTracks() {
        recentSearchPlayedTrackIDs.removeAll()
        saveRecentSearchPlayedTracks()
    }

    /// Persists recently played tracks from Search Library asynchronously.
    public func saveRecentSearchPlayedTracks() {
        let ids = self.recentSearchPlayedTrackIDs
        let url = self.recentSearchTracksFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(ids) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Stores or rewrites a downloaded online track metadata record across multiple lookup indices.
    public func cacheDownloadedMetadata(
        track: Track,
        onlineMetadata: OnlineTrackMetadata,
        artworkKey: String? = nil,
        wasApplied: Bool = false,
        autoSave: Bool = true
    ) {
        let sig = computeTrackSignature(artist: track.artist, title: track.title, duration: track.duration)
        let fileSig = computeFileSignature(fileName: track.url.lastPathComponent, size: track.fileInfo?.fileSizeBytes ?? 0)
        let path = track.url.standardizedFileURL.path

        // If old record exists for this file path with a different signature, clean up old signature mapping
        if let existing = downloadedMetadataCache.recordsByFilePath[path],
           !existing.localTrackSignature.isEmpty,
           existing.localTrackSignature != sig {
            downloadedMetadataCache.recordsBySignature.removeValue(forKey: existing.localTrackSignature)
        }

        let record = CachedTrackMetadataRecord(
            onlineMetadata: onlineMetadata,
            localTrackSignature: sig,
            filePath: path,
            fileName: track.url.lastPathComponent,
            fileSizeBytes: track.fileInfo?.fileSizeBytes ?? 0,
            cachedArtworkKey: artworkKey ?? track.artworkKey,
            downloadedAt: Date(),
            wasApplied: wasApplied,
            appliedTitle: wasApplied ? track.title : nil,
            appliedArtist: wasApplied ? track.artist : nil,
            appliedAlbum: wasApplied ? track.album : nil,
            appliedAlbumArtist: wasApplied ? track.albumArtist : nil,
            appliedGenre: wasApplied ? track.genre : nil,
            appliedYear: wasApplied ? track.year : nil,
            appliedTrackNumber: wasApplied ? track.trackNumber : nil,
            appliedOriginalTrackNumber: wasApplied ? track.originalTrackNumber : nil,
            appliedDeluxeTrackNumber: wasApplied ? track.deluxeTrackNumber : nil,
            appliedTotalTracks: wasApplied ? track.totalTracks : nil,
            appliedDiscNumber: wasApplied ? track.discNumber : nil
        )

        downloadedMetadataCache.recordsByFilePath[path] = record
        if !sig.isEmpty {
            downloadedMetadataCache.recordsBySignature[sig] = record
        }
        if !fileSig.isEmpty {
            downloadedMetadataCache.recordsByFileSignature[fileSig] = record
        }

        if autoSave {
            saveDownloadedMetadataCache()
        }
    }

    /// Indexes and caches baseline metadata for scanned tracks so unlinking/relinking or rescanning is instantaneous.
    public func cacheScannedTracks(_ tracks: [Track]) {
        var didModify = false
        for track in tracks {
            let path = track.url.standardizedFileURL.path
            let sig = computeTrackSignature(artist: track.artist, title: track.title, duration: track.duration)
            let fileSig = computeFileSignature(fileName: track.url.lastPathComponent, size: track.fileInfo?.fileSizeBytes ?? 0)

            if let existing = downloadedMetadataCache.recordsByFilePath[path] {
                // If the track was updated locally, has new artwork, or gained a valid artist over stale unknown, update cache record
                let existingArtist = existing.appliedArtist ?? ""
                let gainedValidArtist = !track.artist.isEmpty && !MetadataSanitizer.isUnknownArtist(track.artist) && MetadataSanitizer.isUnknownArtist(existingArtist)
                if existing.cachedArtworkKey != track.artworkKey || existing.filePath != path || gainedValidArtist {
                    let updated = CachedTrackMetadataRecord(
                        onlineMetadata: existing.onlineMetadata,
                        localTrackSignature: sig,
                        filePath: path,
                        fileName: track.url.lastPathComponent,
                        fileSizeBytes: track.fileInfo?.fileSizeBytes ?? 0,
                        cachedArtworkKey: track.artworkKey ?? existing.cachedArtworkKey,
                        downloadedAt: existing.downloadedAt,
                        wasApplied: existing.wasApplied,
                        appliedTitle: existing.appliedTitle,
                        appliedArtist: gainedValidArtist ? track.artist : existing.appliedArtist,
                        appliedAlbum: existing.appliedAlbum,
                        appliedAlbumArtist: existing.appliedAlbumArtist,
                        appliedGenre: existing.appliedGenre,
                        appliedYear: existing.appliedYear,
                        appliedTrackNumber: existing.appliedTrackNumber,
                        appliedOriginalTrackNumber: existing.appliedOriginalTrackNumber,
                        appliedDeluxeTrackNumber: existing.appliedDeluxeTrackNumber,
                        appliedTotalTracks: existing.appliedTotalTracks,
                        appliedDiscNumber: existing.appliedDiscNumber
                    )
                    downloadedMetadataCache.recordsByFilePath[path] = updated
                    if !sig.isEmpty { downloadedMetadataCache.recordsBySignature[sig] = updated }
                    if !fileSig.isEmpty { downloadedMetadataCache.recordsByFileSignature[fileSig] = updated }
                    didModify = true
                }
            } else if track.artworkKey != nil || (track.year != nil && track.trackNumber != nil) {
                // Store baseline record for newly scanned track with local metadata
                let baselineOnline = OnlineTrackMetadata(
                    id: "local_\(track.id.uuidString)",
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    albumArtist: track.albumArtist,
                    releaseYear: track.year,
                    genre: track.genre,
                    trackNumber: track.trackNumber,
                    totalTracks: track.totalTracks,
                    discNumber: track.discNumber,
                    duration: track.duration,
                    artworkURL: nil
                )
                let record = CachedTrackMetadataRecord(
                    onlineMetadata: baselineOnline,
                    localTrackSignature: sig,
                    filePath: path,
                    fileName: track.url.lastPathComponent,
                    fileSizeBytes: track.fileInfo?.fileSizeBytes ?? 0,
                    cachedArtworkKey: track.artworkKey,
                    downloadedAt: Date(),
                    wasApplied: false,
                    appliedTitle: track.title,
                    appliedArtist: track.artist,
                    appliedAlbum: track.album,
                    appliedAlbumArtist: track.albumArtist,
                    appliedGenre: track.genre,
                    appliedYear: track.year,
                    appliedTrackNumber: track.trackNumber,
                    appliedOriginalTrackNumber: track.originalTrackNumber,
                    appliedDeluxeTrackNumber: track.deluxeTrackNumber,
                    appliedTotalTracks: track.totalTracks,
                    appliedDiscNumber: track.discNumber
                )
                downloadedMetadataCache.recordsByFilePath[path] = record
                if !sig.isEmpty { downloadedMetadataCache.recordsBySignature[sig] = record }
                if !fileSig.isEmpty { downloadedMetadataCache.recordsByFileSignature[fileSig] = record }
                didModify = true
            }
        }
        if didModify {
            saveDownloadedMetadataCache()
        }
    }

    /// Queries the persistent cache using multi-index fallback: path -> file signature -> acoustic signature.
    nonisolated public static func lookupCachedMetadata(
        for track: Track,
        in cache: PersistentDownloadedMetadataCache
    ) -> CachedTrackMetadataRecord? {
        let path = track.url.standardizedFileURL.path
        if let record = cache.recordsByFilePath[path] {
            return record
        }
        let fileSig = computeFileSignature(fileName: track.url.lastPathComponent, size: track.fileInfo?.fileSizeBytes ?? 0)
        if !fileSig.isEmpty, let record = cache.recordsByFileSignature[fileSig] {
            return record
        }
        let sig = computeTrackSignature(artist: track.artist, title: track.title, duration: track.duration)
        if !sig.isEmpty, let record = cache.recordsBySignature[sig] {
            return record
        }
        return nil
    }

    /// Queries the persistent cache using multi-index fallback: path -> file signature -> acoustic signature.
    public func lookupCachedMetadata(for track: Track) -> CachedTrackMetadataRecord? {
        Self.lookupCachedMetadata(for: track, in: downloadedMetadataCache)
    }

    nonisolated public static func computeTrackSignature(artist: String, title: String, duration: TimeInterval) -> String {
        let normArtist = FuzzyMatcher.normalize(artist)
        let normTitle = FuzzyMatcher.normalize(title)
        guard !normArtist.isEmpty || !normTitle.isEmpty else { return "" }
        let durInt = Int(duration.rounded())
        return "\(normArtist)__\(normTitle)__\(durInt)"
    }

    public func computeTrackSignature(artist: String, title: String, duration: TimeInterval) -> String {
        Self.computeTrackSignature(artist: artist, title: title, duration: duration)
    }

    nonisolated public static func computeFileSignature(fileName: String, size: Int64) -> String {
        let normName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normName.isEmpty else { return "" }
        return "\(normName)__\(size)"
    }

    public func computeFileSignature(fileName: String, size: Int64) -> String {
        Self.computeFileSignature(fileName: fileName, size: size)
    }

    /// Intelligently matches all local tracks with cached downloaded metadata, re-attaching artwork and diffs.
    @discardableResult
    public func reattachCachedMetadataToTracks() -> Int {
        var reattachedCount = 0
        var updatedTracks = self.tracks
        var newDiffs: [MetadataDiff] = []
        var newVerified: [MetadataDiff] = []

        for (idx, track) in tracks.enumerated() {
            if let record = lookupCachedMetadata(for: track) {
                reattachedCount += 1
                var currentTrack = track

                if record.wasApplied {
                    // Restore fully applied metadata and artwork, preserving valid track values if record has unknown/empty
                    let appliedArtist: String = {
                        if let art = record.appliedArtist, !art.isEmpty, !MetadataSanitizer.isUnknownArtist(art) {
                            return art
                        }
                        return track.artist
                    }()
                    let appliedAlbum: String = {
                        if let alb = record.appliedAlbum, !alb.isEmpty, !MetadataSanitizer.isUnknownAlbum(alb) {
                            return alb
                        }
                        return track.album
                    }()
                    let appliedTitle: String = {
                        if let tit = record.appliedTitle, !tit.isEmpty, !MetadataSanitizer.isUnknownTitle(tit) {
                            return tit
                        }
                        return track.title
                    }()

                    currentTrack = Track(
                        id: track.id,
                        title: appliedTitle,
                        artist: appliedArtist,
                        album: appliedAlbum,
                        albumArtist: record.appliedAlbumArtist ?? track.albumArtist,
                        genre: record.appliedGenre ?? track.genre,
                        year: record.appliedYear ?? track.year,
                        trackNumber: record.appliedTrackNumber ?? track.trackNumber,
                        originalTrackNumber: record.appliedOriginalTrackNumber ?? track.originalTrackNumber,
                        deluxeTrackNumber: record.appliedDeluxeTrackNumber ?? track.deluxeTrackNumber,
                        totalTracks: record.appliedTotalTracks ?? track.totalTracks,
                        discNumber: record.appliedDiscNumber ?? track.discNumber,
                        duration: track.duration,
                        url: track.url,
                        artworkKey: record.cachedArtworkKey ?? track.artworkKey,
                        dateAdded: track.dateAdded,
                        fileInfo: track.fileInfo,
                        lyrics: track.lyrics
                    )
                } else if track.artworkKey == nil, let artKey = record.cachedArtworkKey {
                    currentTrack = track.withArtworkKey(artKey)
                }

                updatedTracks[idx] = currentTrack

                // Reconstruct MetadataDiff
                let diff = MetadataDiff(
                    localTrack: currentTrack,
                    onlineMetadata: record.onlineMetadata,
                    preserveLocalTitleAndArtist: true
                )

                if record.wasApplied || diff.fieldsEnrichedCount == 0 {
                    newVerified.append(diff)
                } else {
                    newDiffs.append(diff)
                }
            }
        }

        self.tracks = updatedTracks

        // Merge reattached diffs with existing without duplicating
        var existingDiffMap = Dictionary(enrichmentDiffs.map { ($0.localTrack.id, $0) }, uniquingKeysWith: { first, _ in first })
        for d in newDiffs {
            existingDiffMap[d.localTrack.id] = d
        }
        self.enrichmentDiffs = Array(existingDiffMap.values)

        var existingGoodMap = Dictionary(
            verifiedGoodDiffs.filter { ($0.localTrack.year ?? 0) >= 1900 }.map { ($0.localTrack.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for g in newVerified {
            if (g.localTrack.year ?? 0) >= 1900 {
                existingGoodMap[g.localTrack.id] = g
            }
        }
        self.verifiedGoodDiffs = Array(existingGoodMap.values)

        saveEnrichmentCache()
        AppLogger.storage.info("Reattached cached metadata to \(reattachedCount) tracks.")
        return reattachedCount
    }

    // MARK: - Non-Blocking Background Persistence

    private static func writeData(_ data: Data, to url: URL, label: String) {
        Task.detached(priority: .utility) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.storage.error("Failed to save \(label): \(error.localizedDescription)")
            }
        }
    }

    // Save enrichment cache asynchronously
    public func saveEnrichmentCache() {
        let diffs = self.enrichmentDiffs
        let good = self.verifiedGoodDiffs
        let unmatched = Array(self.unmatchedTrackIDs)
        let diffURL = self.enrichmentFileURL
        let goodURL = self.verifiedGoodFileURL
        let unmatchedURL = self.unmatchedFileURL

        Task.detached(priority: .utility) {
            if let diffData = try? JSONEncoder().encode(diffs) {
                try? diffData.write(to: diffURL, options: .atomic)
            }
            if let goodData = try? JSONEncoder().encode(good) {
                try? goodData.write(to: goodURL, options: .atomic)
            }
            if let unmatchedData = try? JSONEncoder().encode(unmatched) {
                try? unmatchedData.write(to: unmatchedURL, options: .atomic)
            }
        }
    }

    // Save duplicates asynchronously
    public func saveDuplicates() {
        let groups = self.duplicateGroups
        let url = self.duplicatesFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(groups) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Save settings asynchronously
    public func saveSettings() {
        HapticManager.shared.isEnabled = self.settings.isHapticsEnabled
        UserDefaults.standard.set(self.settings.isArtworkRounded, forKey: "isArtworkRounded")
        let currentSettings = self.settings
        let url = self.settingsFileURL
        // Generation-ordered write so a slower earlier save can never overwrite a newer one.
        let gen = bumpGeneration(for: url)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(currentSettings) {
                await PersistenceWriter.shared.write(data: data, to: url, generation: gen)
            }
        }
    }

    // Save library tracks, albums, and artists asynchronously with generation tracking & debouncing (~1s)
    public func saveLibrary() {
        guard !isInitialLoading else { return }

        LibraryRepository.shared.scheduleSave(storageDir: storageDirectoryURL, settingsHash: computeSettingsHash())

        saveLibraryDebounceTask?.cancel()

        let currentFolderStats = self.cachedFolderStats
        let folderStatsUrl = self.folderStatsFileURL

        if !currentFolderStats.isEmpty {
            saveLibraryDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }

                Task.detached(priority: .utility) {
                    let stringKeyed = Dictionary(currentFolderStats.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
                    if let statsJson = try? JSONEncoder().encode(stringKeyed) {
                        try? statsJson.write(to: folderStatsUrl, options: .atomic)
                    }
                }
            }
        }
    }

    /// Flushes library snapshot immediately to disk without debouncing (e.g. on backgrounding).
    public func flushSnapshotImmediate() {
        saveLibraryDebounceTask?.cancel()
        saveLibraryDebounceTask = nil
        guard !isInitialLoading else { return }

        let sDir = self.storageDirectoryURL
        let sHash = self.computeSettingsHash()
        Task.detached(priority: .userInitiated) {
            await LibraryRepository.shared.flushImmediate(storageDir: sDir, settingsHash: sHash)
        }

        let currentFolderStats = self.cachedFolderStats
        let folderStatsUrl = self.folderStatsFileURL

        if !currentFolderStats.isEmpty {
            Task.detached(priority: .userInitiated) {
                let stringKeyed = Dictionary(currentFolderStats.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
                if let statsJson = try? JSONEncoder().encode(stringKeyed) {
                    try? statsJson.write(to: folderStatsUrl, options: .atomic)
                }
            }
        }
    }

    nonisolated internal static func writeSnapshot(_ snapshot: LibrarySnapshot, to url: URL) {
        // Obsolete: Replaced by LibraryRepository writing flat library.v2.json
    }

    nonisolated internal static func deleteLegacyStorageFiles(storageDir: URL) {
        let fm = FileManager.default
        let chunksDir = storageDir.appendingPathComponent("library_chunks", isDirectory: true)
        let chunksManifest = storageDir.appendingPathComponent("library_chunks_manifest.json")
        let libBin = storageDir.appendingPathComponent("library.cache")
        let oldBinPlist = storageDir.appendingPathComponent("library.binaryplist")
        let sqliteURL = storageDir.appendingPathComponent("library.sqlite")
        let walURL = storageDir.appendingPathComponent("library.sqlite-wal")
        let shmURL = storageDir.appendingPathComponent("library.sqlite-shm")

        try? fm.removeItem(at: chunksDir)
        try? fm.removeItem(at: chunksManifest)
        try? fm.removeItem(at: libBin)
        try? fm.removeItem(at: oldBinPlist)
        try? fm.removeItem(at: sqliteURL)
        try? fm.removeItem(at: walURL)
        try? fm.removeItem(at: shmURL)
    }

    /// Writes new tag metadata to the underlying audio file on disk (if local in METADATA mode),
    /// stores mode overrides, updates memory and cache records, and persists changes.
    public func updateTrackMetadata(
        for trackID: UUID,
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        composer: String?,
        performer: String?,
        genre: String?,
        year: Int?,
        trackNumber: Int?,
        totalTracks: Int?,
        discNumber: Int?,
        discTotal: Int?
    ) async -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        let existingTrack = tracks[index]

        // 1. Record override for current organization mode
        let currentMode = settings.libraryScanMethod
        var modeState = organizationModesContainer.state(for: currentMode)
        let override = TrackMetadataOverride(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            composer: composer,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            discNumber: discNumber
        )
        modeState.overrides[trackID] = override
        organizationModesContainer.update(state: modeState, for: currentMode)
        saveOrganizationModes()

        // 2. Write to disk only if file is local and we are in METADATA mode
        if existingTrack.canReadLocalBytes && existingTrack.url.isFileURL && !existingTrack.isJellyfinItem && settings.libraryScanMethod == .id3Tags {
            _ = await AudioFileMetadataWriter.shared.writeMetadata(
                to: existingTrack.url,
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                composer: composer,
                performer: performer,
                year: year,
                genre: genre,
                trackNumber: trackNumber,
                totalTracks: totalTracks,
                discNumber: discNumber,
                discTotal: discTotal
            )
        }

        let updatedTrack = existingTrack.withUpdatedTags(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            composer: composer,
            performer: performer,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            totalTracks: totalTracks,
            discNumber: discNumber,
            discTotal: discTotal
        )

        self.patchTrackInPlace(updatedTrack)
        saveLibrary()

        // Update persistent downloaded metadata cache if present
        let path = updatedTrack.url.standardizedFileURL.path
        if var record = downloadedMetadataCache.recordsByFilePath[path] {
            let synth = OnlineTrackMetadata(
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                releaseYear: year,
                genre: genre,
                trackNumber: trackNumber,
                totalTracks: totalTracks,
                discNumber: discNumber,
                sourceAPI: record.onlineMetadata.sourceAPI
            )
            record.onlineMetadata = synth
            downloadedMetadataCache.recordsByFilePath[path] = record
            saveDownloadedMetadataCache()
        }

        return true
    }

    /// Returns true if manual metadata edits exist for a specific track in the active organization mode.
    public func hasOverride(for trackID: UUID) -> Bool {
        organizationModesContainer.state(for: settings.libraryScanMethod).overrides[trackID] != nil
    }

    /// Returns true if any tracks in the given album have manual metadata edits in the active organization mode.
    public func hasOverrides(forAlbum album: Album) -> Bool {
        let overrides = organizationModesContainer.state(for: settings.libraryScanMethod).overrides
        return album.trackIDs.contains { overrides[$0] != nil }
    }

    /// Resets manual metadata edits for a specific track, restoring its original organized metadata.
    public func resetEdits(for trackID: UUID) {
        let currentMode = settings.libraryScanMethod
        var modeState = organizationModesContainer.state(for: currentMode)
        modeState.overrides.removeValue(forKey: trackID)
        organizationModesContainer.update(state: modeState, for: currentMode)
        saveOrganizationModes()

        if let idx = tracks.firstIndex(where: { $0.id == trackID }) {
            let organized = LibraryOrganizer.organize(track: tracks[idx], mode: currentMode, override: nil)
            patchTrackInPlace(organized)
            saveLibrary()
        }
    }

    /// Resets manual metadata edits for all tracks in an album, restoring their original organized metadata.
    public func resetEdits(forAlbum album: Album) {
        let currentMode = settings.libraryScanMethod
        var modeState = organizationModesContainer.state(for: currentMode)
        var changed = false

        for trackID in album.trackIDs {
            if modeState.overrides.removeValue(forKey: trackID) != nil {
                changed = true
                if let idx = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[idx] = LibraryOrganizer.organize(track: tracks[idx], mode: currentMode, override: nil)
                }
            }
        }

        if changed {
            organizationModesContainer.update(state: modeState, for: currentMode)
            saveOrganizationModes()
            rebuildAlbumsAndArtists()
            saveLibrary()
        }
    }

    /// Switches library organization mode (METADATA vs FOLDER) without disk rescan.
    public func setLibraryOrganization(_ method: LibraryScanMethod) {
        Task { await applyLocalOrganization(method: method, layout: settings.folderHierarchyLayout) }
    }

    /// Changes the FOLDER-mode hierarchy layout (no disk rescan).
    public func setFolderHierarchyLayout(_ layout: FolderHierarchyLayout) {
        Task { await applyLocalOrganization(method: settings.libraryScanMethod, layout: layout) }
    }

    /// Applies a local organization mode + folder layout together in ONE incremental reorganize pass.
    public func applyLocalOrganization(method: LibraryScanMethod, layout: FolderHierarchyLayout) async {
        let methodChanged = settings.libraryScanMethod != method
        let layoutChanged = settings.folderHierarchyLayout != layout
        guard methodChanged || layoutChanged else { return }

        if methodChanged {
            // Snapshot current mode state (pins/recents) and restore the target mode's
            let currentMode = settings.libraryScanMethod
            var currentModeState = organizationModesContainer.state(for: currentMode)
            currentModeState.pinnedItemIDs = self.pinnedItemIDs
            currentModeState.recentAlbumIDs = self.recentAlbumIDs
            organizationModesContainer.update(state: currentModeState, for: currentMode)

            let targetState = organizationModesContainer.state(for: method)
            self.pinnedItemIDs = targetState.pinnedItemIDs
            self.pinnedAlbumIDs = Set(targetState.pinnedItemIDs.filter { $0.type == PinnedItemType.album }.map { $0.targetID })
            self.recentAlbumIDs = targetState.recentAlbumIDs
        }

        settings.libraryScanMethod = method
        settings.folderHierarchyLayout = layout
        saveSettings()

        if methodChanged {
            saveOrganizationModes()
            savePins()
            saveRecentAlbums()
        }

        // Layout only matters in FOLDER mode; album clustering itself depends on the mode.
        guard methodChanged || method == .folderHierarchy else { return }
        await reorganizeLocalTracks(forceRebuild: methodChanged)
    }

    /// Incrementally re-organizes LOCAL (non-Jellyfin) tracks off the main actor. Only tracks whose
    /// organized fields actually change are sent through the repository change set (persisted);
    /// albums/artists rebuild once. Skips everything when nothing changed (unless `forceRebuild`,
    /// needed when the mode changed because album clustering depends on it). Stale passes are dropped.
    private func reorganizeLocalTracks(forceRebuild: Bool) async {
        reorganizeGeneration &+= 1
        let generation = reorganizeGeneration
        let mode = settings.libraryScanMethod
        let layout = settings.folderHierarchyLayout
        let overrides = organizationModesContainer.state(for: mode).overrides
        let rootNames = Dictionary(settings.linkedFolders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let snapshot = self.tracks

        let changed: [Track] = await Task.detached(priority: .userInitiated) {
            var result: [Track] = []
            for track in snapshot where !track.isJellyfinItem {
                let rootName = track.folderID.flatMap { rootNames[$0] }
                let organized = LibraryOrganizer.organize(
                    track: track,
                    mode: mode,
                    override: overrides[track.id],
                    layout: layout,
                    rootFolderName: rootName
                )
                if organized.title != track.title
                    || organized.artist != track.artist
                    || organized.album != track.album
                    || organized.albumArtist != track.albumArtist
                    || organized.year != track.year
                    || organized.trackNumber != track.trackNumber
                    || organized.discNumber != track.discNumber {
                    result.append(organized)
                }
            }
            return result
        }.value

        guard reorganizeGeneration == generation else { return }
        guard !changed.isEmpty || forceRebuild else {
            AppLogger.library.info("Reorganize: no local track changes; skipped rebuild.")
            return
        }

        // Repository is the persisted source of truth; it rebuilds albums/artists off the main actor.
        let newState = await LibraryRepository.shared.applyChangeSet(
            upserted: changed,
            removedIDs: [],
            settings: self.settings,
            verifiedGoodDiffs: self.verifiedGoodDiffs,
            downloadedMetadataCache: self.downloadedMetadataCache
        )
        guard reorganizeGeneration == generation else { return }
        applyLoadedLibraryState(newState)
        saveLibrary()
        AppLogger.library.info("Reorganize: \(changed.count) local tracks changed.")
    }

    /// Persists multi-mode organization state asynchronously
    public func saveOrganizationModes() {
        let container = self.organizationModesContainer
        let url = self.organizationModesFileURL
        let gen = bumpGeneration(for: url)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(container) {
                await PersistenceWriter.shared.write(data: data, to: url, generation: gen)
            }
        }
    }

    /// Upgrades in-memory placeholder track after on-demand cloud download finishes.
    public func upgradeTrackAfterDownload(trackID: UUID, fileURL: URL) {
        guard let idx = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let current = tracks[idx]

        Task.detached(priority: .utility) { [weak self] in
            let scanner = AudioScannerService()
            guard let scanned = await scanner.parseAudioTrack(at: fileURL, folderID: current.folderID) else { return }

            await MainActor.run { [weak self] in
                guard let self = self, let currentIndex = self.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                let cur = self.tracks[currentIndex]

                let snapshot = TagSnapshot(
                    title: scanned.title,
                    artist: scanned.artist,
                    album: scanned.album,
                    albumArtist: scanned.albumArtist,
                    year: scanned.year,
                    trackNumber: scanned.trackNumber,
                    discNumber: scanned.discNumber
                )

                let isTagsMode = self.settings.libraryScanMethod == .id3Tags
                let upgraded = cur
                    .withOrganizedMetadata(
                        title: isTagsMode ? scanned.title : cur.title,
                        artist: isTagsMode ? scanned.artist : cur.artist,
                        album: isTagsMode ? scanned.album : cur.album,
                        albumArtist: isTagsMode ? scanned.albumArtist : cur.albumArtist,
                        year: scanned.year ?? cur.year,
                        trackNumber: scanned.trackNumber ?? cur.trackNumber,
                        discNumber: scanned.discNumber ?? cur.discNumber
                    )
                    .withUpdatedTags(
                        metadataSource: .embeddedTags,
                        tagSnapshot: snapshot
                    )
                    .withArtworkKey(scanned.artworkKey ?? cur.artworkKey ?? "")

                self.patchTrackInPlace(upgraded)
                self.saveLibrary()
            }
        }
    }

    /// One-time deterministic Track ID scheme migration from sandbox path hash (v1) to relative path UUID (v2).
    public func migrateTrackIDsToV2() {
        guard settings.trackIDSchemeVersion < 2 else { return }
        AppLogger.storage.info("Starting one-time Track ID Scheme v2 migration...")

        var oldToNewIDMap: [UUID: UUID] = [:]
        var newTracks: [Track] = []
        var seenNewIDs = Set<UUID>()

        for track in self.tracks {
            if track.isJellyfinItem || track.metadataSource == .server {
                if !seenNewIDs.contains(track.id) {
                    seenNewIDs.insert(track.id)
                    newTracks.append(track)
                }
                continue
            }

            let relativePath = track.relativePath ?? {
                if let folderID = track.folderID,
                   let folderURL = SecurityScopedBookmark.shared.url(for: folderID) {
                    return TrackIdentity.computeRelativePath(fileURL: track.url, folderURL: folderURL)
                }
                return track.url.lastPathComponent
            }()

            let newID = TrackIdentity.localTrackID(folderID: track.folderID, relativePath: relativePath)
            if seenNewIDs.contains(newID) {
                // Collision: keep first entry
                continue
            }
            seenNewIDs.insert(newID)
            oldToNewIDMap[track.id] = newID

            let migratedTrack = track.withIdentity(
                id: newID,
                relativePath: relativePath,
                metadataSource: track.metadataSource ?? .embeddedTags,
                tagSnapshot: track.tagSnapshot
            )
            newTracks.append(migratedTrack)
        }

        self.tracks = newTracks

        // Remap playlists
        for i in 0..<self.playlists.count {
            self.playlists[i].trackIDs = self.playlists[i].trackIDs.map { oldID in
                oldToNewIDMap[oldID] ?? oldID
            }
        }

        // Remap play counts
        var newPlayCounts: [UUID: Int] = [:]
        for (oldID, count) in self.playCounts {
            let targetID = oldToNewIDMap[oldID] ?? oldID
            newPlayCounts[targetID] = count
        }
        self.playCounts = newPlayCounts

        // Remap playback positions
        var newPositions: [UUID: TimeInterval] = [:]
        for (oldID, pos) in self.playbackPositions {
            let targetID = oldToNewIDMap[oldID] ?? oldID
            newPositions[targetID] = pos
        }
        self.playbackPositions = newPositions

        // Remap recent search tracks
        self.recentSearchPlayedTrackIDs = self.recentSearchPlayedTrackIDs.map { oldID in
            oldToNewIDMap[oldID] ?? oldID
        }

        // Remap EqualizerManager.perTrackEQMap
        EqualizerManager.shared.remapTrackIDs(using: oldToNewIDMap)

        // Remap active player queues
        AudioPlayerService.shared?.remapTrackIDs(using: oldToNewIDMap)

        self.settings.trackIDSchemeVersion = 2
        saveSettings()
        rebuildAlbumsAndArtists()
        saveLibrary()
        savePlaylists()
        savePlayCounts()
        savePlaybackPositions()
        saveRecentSearchPlayedTracks()

        AppLogger.storage.info("Track ID Scheme v2 migration complete. Remapped \(oldToNewIDMap.count) tracks.")
    }

    // Save playlists asynchronously
    public func savePlaylists() {
        let playlistsToSave = self.playlists
        let url = self.playlistsFileURL
        let binUrl = self.playlistsBinaryCacheURL
        Task.detached(priority: .utility) {
            Self.saveFast(playlistsToSave, to: binUrl, jsonURL: url)
        }
    }

    // Save play counts asynchronously with debouncing & generation tracking
    public func savePlayCounts() {
        savePlayCountsDebounceTask?.cancel()
        let counts = self.playCounts
        let url = self.playCountsFileURL
        let binUrl = self.playCountsBinaryCacheURL
        let genJson = bumpGeneration(for: url)
        let genBin = bumpGeneration(for: binUrl)

        savePlayCountsDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }

            Task.detached(priority: .utility) {
                let stringKeyed = Dictionary(counts.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
                var items: [(data: Data, url: URL, generation: Int)] = []
                if let json = try? JSONEncoder().encode(stringKeyed) {
                    items.append((json, url, genJson))
                }
                let plist = PropertyListEncoder()
                plist.outputFormat = .binary
                if let bin = try? plist.encode(stringKeyed) {
                    items.append((bin, binUrl, genBin))
                }
                await PersistenceWriter.shared.writeBatch(items)
            }
        }
    }

    // Set playback position for a track
    public func setPlaybackPosition(_ position: TimeInterval, for trackID: UUID) {
        if position <= 0 {
            playbackPositions.removeValue(forKey: trackID)
        } else {
            playbackPositions[trackID] = position
        }
        savePlaybackPositions()
    }

    // Remove playback position for a track
    public func removePlaybackPosition(for trackID: UUID) {
        if playbackPositions.removeValue(forKey: trackID) != nil {
            savePlaybackPositions()
        }
    }

    // Retrieve playback position for a track
    public func playbackPosition(for trackID: UUID) -> TimeInterval? {
        playbackPositions[trackID]
    }

    // Save playback positions asynchronously
    public func savePlaybackPositions() {
        let positions = self.playbackPositions
        let url = self.playbackPositionsFileURL
        let binUrl = self.playbackPositionsBinaryCacheURL
        Task.detached(priority: .utility) {
            let stringKeyed = Dictionary(positions.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
            Self.saveFast(stringKeyed, to: binUrl, jsonURL: url)
        }
    }

    // Save pins asynchronously
    public func savePins() {
        let pins = self.pinnedItemIDs
        let items = self.pinnedItemsCache
        let url = self.pinsFileURL
        let cacheUrl = self.pinnedItemsCacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(pins) {
                try? data.write(to: url, options: .atomic)
            }
            if let jsonData = try? JSONEncoder().encode(items) {
                try? jsonData.write(to: cacheUrl, options: .atomic)
            }
        }
    }

    // Instant sync load of lightweight preferences for immediate frame 1 paint
    private func loadLightweightPreferences() {
        if let data = try? Data(contentsOf: settingsFileURL),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = loaded
            self.selectedCategory = loaded.defaultLibraryCategory
        }
        HapticManager.shared.isEnabled = self.settings.isHapticsEnabled

        if let data = try? Data(contentsOf: pinsFileURL),
           let loadedPins = try? JSONDecoder().decode([PinnedItemIdentifier].self, from: data) {
            self.pinnedItemIDs = loadedPins
            self.pinnedAlbumIDs = Set(loadedPins.filter { $0.type == .album }.map { $0.targetID })
        }

        // Instant frame 1 cached pinned items
        if let data = try? Data(contentsOf: pinnedItemsCacheURL) {
            if let loadedPinnedItems = try? JSONDecoder().decode([PinnedItem].self, from: data) {
                self.pinnedItemsCache = loadedPinnedItems
            } else if let loadedPinnedItems = try? PropertyListDecoder().decode([PinnedItem].self, from: data) {
                self.pinnedItemsCache = loadedPinnedItems
            }
        }

        if let data = try? Data(contentsOf: recentAlbumsFileURL),
           let loadedRecent = try? JSONDecoder().decode([String].self, from: data) {
            self.recentAlbumIDs = loadedRecent
        }

        // Instant frame 1 cached recent albums for "LATEST PLAYS"
        if let data = try? Data(contentsOf: recentAlbumsCacheURL) {
            if let loadedRecentAlbums = try? JSONDecoder().decode([Album].self, from: data) {
                self.recentAlbumsCache = loadedRecentAlbums
            } else if let loadedRecentAlbums = try? PropertyListDecoder().decode([Album].self, from: data) {
                self.recentAlbumsCache = loadedRecentAlbums
            }
        }

        if let data = try? Data(contentsOf: recentSearchTracksFileURL),
           let loadedSearchTracks = try? JSONDecoder().decode([UUID].self, from: data) {
            self.recentSearchPlayedTrackIDs = loadedSearchTracks
        }

        // Instant frame 1 cached folder stats (for instantaneous Sources & Folders tab count display)
        if let data = try? Data(contentsOf: folderStatsFileURL),
           let loadedStats = try? JSONDecoder().decode([String: FolderStats].self, from: data) {
            self.cachedFolderStats = Dictionary(loadedStats.compactMap { key, val in
                UUID(uuidString: key).map { ($0, val) }
            }, uniquingKeysWith: { first, _ in first })
        } else if let data = try? Data(contentsOf: folderStatsCacheURL) {
            if let loadedStats = try? PropertyListDecoder().decode([String: FolderStats].self, from: data) {
                self.cachedFolderStats = Dictionary(loadedStats.compactMap { key, val in
                    UUID(uuidString: key).map { ($0, val) }
                }, uniquingKeysWith: { first, _ in first })
            }
        }

        if let lastIDStr = UserDefaults.standard.string(forKey: "last_added_playlist_id_v1"),
           let lastID = UUID(uuidString: lastIDStr) {
            self.lastAddedPlaylistID = lastID
        }

        if let data = try? Data(contentsOf: organizationModesFileURL),
           let loadedModes = try? JSONDecoder().decode(OrganizationModesContainer.self, from: data) {
            self.organizationModesContainer = loadedModes
        }

        if let data = UserDefaults.standard.data(forKey: "jellyfin_last_sync_dates_v1"),
           let loadedSyncDates = try? JSONDecoder().decode([UUID: Date].self, from: data) {
            self.jellyfinLastSyncDates = loadedSyncDates
        }
    }

    /// Persists last sync timestamps per Jellyfin server ID to UserDefaults.
    public func saveJellyfinLastSyncDates() {
        if let data = try? JSONEncoder().encode(jellyfinLastSyncDates) {
            UserDefaults.standard.set(data, forKey: "jellyfin_last_sync_dates_v1")
        }
    }

    // Rebuilds fast lookup index from loaded artist entities
    public func rebuildArtistLookupIndex() {
        var lookup: [String: Artist] = [:]
        for artist in artists {
            let canon = ArtistParser.canonicalArtistKey(artist.name)
            lookup[canon] = artist
            lookup[artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = artist
            lookup[artist.id] = artist
        }
        self.artistLookupIndex = lookup
    }

    // Streams heavy track library and cached collections asynchronously off main thread
    private func loadPersistedStateAsync() {
        let storageDir = self.storageDirectoryURL
        let expectedSettingsHash = computeSettingsHash()
        let currentSettings = self.settings

        let playURL = self.playlistsFileURL
        let playBinURL = self.playlistsBinaryCacheURL
        let countsURL = self.playCountsFileURL
        let countsBinURL = self.playCountsBinaryCacheURL
        let posURL = self.playbackPositionsFileURL
        let posBinURL = self.playbackPositionsBinaryCacheURL
        let dupURL = self.duplicatesFileURL
        let enrichURL = self.enrichmentFileURL
        let goodURL = self.verifiedGoodFileURL
        let unmatchURL = self.unmatchedFileURL
        let metaCacheURL = self.downloadedMetadataCacheFileURL
        let jellyfinServers = self.settings.jellyfinServers

        // TIER 1: Ultra-fast flat repository loading with fallback to SQLite rescue and chunks
        Task.detached(priority: .userInitiated) { [weak self] in
            // Step 1: Concurrently load metadata caches first
            async let dupTask: [DuplicateGroup]? = {
                guard let data = try? Data(contentsOf: dupURL) else { return nil }
                return try? JSONDecoder().decode([DuplicateGroup].self, from: data)
            }()
            async let diffsTask: [MetadataDiff]? = {
                guard let data = try? Data(contentsOf: enrichURL) else { return nil }
                return try? JSONDecoder().decode([MetadataDiff].self, from: data)
            }()
            async let goodTask: [MetadataDiff]? = {
                guard let data = try? Data(contentsOf: goodURL) else { return nil }
                return try? JSONDecoder().decode([MetadataDiff].self, from: data)
            }()
            async let unmatchedTask: [UUID]? = {
                guard let data = try? Data(contentsOf: unmatchURL) else { return nil }
                return try? JSONDecoder().decode([UUID].self, from: data)
            }()
            async let metaCacheTask: PersistentDownloadedMetadataCache? = {
                guard let data = try? Data(contentsOf: metaCacheURL) else { return nil }
                return try? JSONDecoder().decode(PersistentDownloadedMetadataCache.self, from: data)
            }()

            let (state, hashMismatch) = await LibraryRepository.shared.load(
                storageDir: storageDir,
                expectedSettingsHash: expectedSettingsHash,
                settings: currentSettings
            )

            let loadedDuplicates = await dupTask ?? []
            let loadedDiffs = await diffsTask ?? []
            let loadedGood = (await goodTask ?? []).filter { ($0.localTrack.year ?? 0) >= 1900 }
            let loadedUnmatched = await unmatchedTask ?? []
            let loadedMetaCache = await metaCacheTask ?? PersistentDownloadedMetadataCache()

            if !jellyfinServers.isEmpty && !state.tracks.isEmpty {
                JellyfinArtworkRegistry.shared.populateFromTracks(state.tracks, servers: jellyfinServers)
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.duplicateGroups = loadedDuplicates
                self.enrichmentDiffs = loadedDiffs
                self.verifiedGoodDiffs = loadedGood
                self.unmatchedTrackIDs = Set(loadedUnmatched)
                self.downloadedMetadataCache = loadedMetaCache

                self.applyLoadedLibraryState(state)

                if hashMismatch {
                    Task.detached(priority: .utility) { [weak self] in
                        guard let self = self else { return }
                        let rebuilt = await LibraryRepository.shared.rebuildAll(
                            settings: currentSettings,
                            verifiedGoodDiffs: loadedGood,
                            downloadedMetadataCache: loadedMetaCache
                        )
                        await MainActor.run {
                            self.applyLoadedLibraryState(rebuilt)
                        }
                    }
                }
            }
        }

        // TIER 1B: Instant Playlists, Play Counts & Playback Positions (Concurrent User-Initiated Task)
        Task.detached(priority: .userInitiated) { [weak self] in
            async let plTask: [Playlist]? = Self.loadFast(from: playBinURL, fallbackJSONURL: playURL) { fallback in
                Task.detached(priority: .utility) {
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    if let binData = try? encoder.encode(fallback) {
                        try? binData.write(to: playBinURL, options: .atomic)
                    }
                }
            }

            async let countsTask: [String: Int]? = Self.loadFast(from: countsBinURL, fallbackJSONURL: countsURL) { fallback in
                Task.detached(priority: .utility) {
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    if let binData = try? encoder.encode(fallback) {
                        try? binData.write(to: countsBinURL, options: .atomic)
                    }
                }
            }

            async let posTask: [String: TimeInterval]? = Self.loadFast(from: posBinURL, fallbackJSONURL: posURL) { fallback in
                Task.detached(priority: .utility) {
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    if let binData = try? encoder.encode(fallback) {
                        try? binData.write(to: posBinURL, options: .atomic)
                    }
                }
            }

            let loadedPlaylists = await plTask
            let loadedCounts = await countsTask
            let loadedPositions = await posTask

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let p = loadedPlaylists {
                    self.playlists = p
                }
                if let c = loadedCounts {
                    self.playCounts = Dictionary(c.compactMap { key, val in
                        UUID(uuidString: key).map { ($0, val) }
                    }, uniquingKeysWith: { first, _ in first })
                }
                if let pos = loadedPositions {
                    self.playbackPositions = Dictionary(pos.compactMap { key, val in
                        UUID(uuidString: key).map { ($0, val) }
                    }, uniquingKeysWith: { first, _ in first })
                }
                self.invalidateSortedCaches()
            }
        }
    }
}

