import Foundation
import Observation
import SwiftUI
import os

/// Persistent cache record for a downloaded online track metadata result and artwork.
public struct CachedTrackMetadataRecord: Codable, Sendable {
    public let onlineMetadata: OnlineTrackMetadata
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

    public init(
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

    public init() {}

    public var totalRecordsCount: Int {
        recordsByFilePath.count
    }
}

/// Unified `@Observable` central library state and data persistence store.
/// Manages tracks, albums, artists, playlists, user preferences, and background scanning.
@Observable
@MainActor
public final class LibraryStore {
    // MARK: - Core State

    // All tracks loaded in the user library
    public private(set) var tracks: [Track] = []
    // Grouped album entities
    public private(set) var albums: [Album] = []
    // Grouped artist entities
    public private(set) var artists: [Artist] = []
    // User-created and smart playlists
    public private(set) var playlists: [Playlist] = []
    // Track playback counts keyed by track ID
    public private(set) var playCounts: [UUID: Int] = [:]
    // Track saved playback positions (in seconds) keyed by track ID
    public private(set) var playbackPositions: [UUID: TimeInterval] = [:]
    // Quick-access pinned playlists and collections
    public private(set) var pinnedItemIDs: [PinnedItemIdentifier] = []
    // IDs of albums pinned to home view
    public private(set) var pinnedAlbumIDs: Set<String> = []
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
    public private(set) var backgroundCheckProgress: Double = 0.0
    public private(set) var backgroundCheckStatusText: String = ""
    public private(set) var backgroundCheckScannedCount: Int = 0
    public private(set) var backgroundCheckTotalCount: Int = 0
    // Controls is enriching metadata
    public private(set) var isEnrichingMetadata: Bool = false
    public private(set) var enrichProgress: Double = 0.0
    public private(set) var enrichStatusText: String = ""

    public var verifiedGoodCount: Int {
        verifiedGoodDiffs.count
    }

    public var unmatchedTracks: [Track] {
        // Id set
        let idSet = unmatchedTrackIDs
        return tracks.filter { idSet.contains($0.id) }
    }

    public var unmatchedTracksCount: Int {
        unmatchedTrackIDs.count
    }

    // Fast O(1) index mapping normalized artist name variants and IDs to Artist entities
    @ObservationIgnored private var artistLookupIndex: [String: Artist] = [:]

    // MARK: - Scanning State

    // Indicates active file system audio scanning
    public private(set) var isScanning: Bool = false
    // Overall scanning completion progress (0.0 - 1.0)
    public private(set) var scanProgress: Double = 0.0
    // Human-readable status text for scanner UI
    public private(set) var scanStatusText: String = ""

    // MARK: - UI & Filter State

    public var searchQuery: String = ""
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

    /// Invalidates all cached sorted collections
    public func invalidateSortedCaches() {
        cachedSortedTracks = nil
        cachedSortedAlbums = nil
        cachedSortedArtists = nil
        cachedSortedPlaylists = nil
    }

    // MARK: - File Paths

    // File manager
    private let fileManager = FileManager.default
    // File system location for storage directory url
    private let storageDirectoryURL: URL

    // Initialize with configured properties
    public init() {
        // App support
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.storageDirectoryURL = appSupport.appendingPathComponent("MusicPlayerData", isDirectory: true)

        if !fileManager.fileExists(atPath: storageDirectoryURL.path) {
            try? fileManager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        }

        // Immediately resolve and retain security-scoped folder access
        _ = SecurityScopedBookmark.shared.resolveAndAccessBookmark()

        loadPersistedState()
    }

    // MARK: - Computed Filtered Collections

    /// Returns resolved user-pinned albums and playlists in their customized display order.
    public var pinnedItems: [PinnedItem] {
        // Results
        var results: [PinnedItem] = []
        for identifier in pinnedItemIDs {
            switch identifier.type {
            case .playlist:
                // Unique identifier
                if let plID = UUID(uuidString: identifier.targetID),
                   // Pl
                   let pl = playlists.first(where: { $0.id == plID }) {
                    results.append(.playlist(pl))
                }
            case .album:
                if let al = albums.first(where: { $0.id == identifier.targetID }) {
                    results.append(.album(al))
                }
            }
        }
        return results
    }

    public var pinnedPlaylists: [Playlist] {
        playlists.filter { $0.isPinned }
    }

    public var filteredTracks: [Track] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if cleanQuery.isEmpty {
            if let cached = cachedSortedTracks {
                return cached
            }
            let sourceList: [Track]
            if settings.autoHideDuplicates && !duplicateGroups.isEmpty {
                let hiddenTrackIDs = Set(duplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track.id } })
                sourceList = tracks.filter { !hiddenTrackIDs.contains($0.id) }
            } else {
                sourceList = tracks
            }
            let sorted = sortTracks(sourceList, by: trackSortOption, isReversed: isTrackSortReversed)
            cachedSortedTracks = sorted
            return sorted
        }

        let sourceList: [Track]
        if settings.autoHideDuplicates && !duplicateGroups.isEmpty {
            let hiddenTrackIDs = Set(duplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track.id } })
            sourceList = tracks.filter { !hiddenTrackIDs.contains($0.id) }
        } else {
            sourceList = tracks
        }

        let scored: [(Track, Int)] = sourceList.compactMap { track in
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (track, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map { $0.0 }
    }

    /// Standardized, high-performance album search scoring title, artist, and track titles.
    public func searchAlbums(query: String) -> [Album] {
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard !cleanQuery.isEmpty else { return albums }

        let scored: [(Album, Int)] = albums.compactMap { album in
            var maxScore = FuzzyMatcher.scoreAlbum(
                normalizedTitle: album.normalizedTitle,
                normalizedArtist: album.normalizedArtist,
                cleanQuery: cleanQuery
            )
            for track in album.tracks {
                let trackScore = FuzzyMatcher.scoreTrack(
                    normalizedTitle: track.normalizedTitle,
                    normalizedArtist: track.normalizedArtist,
                    normalizedAlbum: track.normalizedAlbum,
                    searchTokens: track.searchTokens,
                    cleanQuery: cleanQuery
                )
                if trackScore > maxScore {
                    maxScore = trackScore
                }
            }
            return maxScore > 0 ? (album, maxScore) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map { $0.0 }
    }

    public var filteredAlbums: [Album] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if let cached = cachedSortedAlbums {
                return cached
            }
            let sorted = sortAlbums(albums, by: albumSortOption, isReversed: isAlbumSortReversed)
            cachedSortedAlbums = sorted
            return sorted
        }
        return searchAlbums(query: trimmed)
    }

    public var filteredArtists: [Artist] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if cleanQuery.isEmpty {
            if let cached = cachedSortedArtists {
                return cached
            }
            let sorted = sortArtists(artists, by: artistSortOption, isReversed: isArtistSortReversed)
            cachedSortedArtists = sorted
            return sorted
        }
        let scored: [(Artist, Int)] = artists.compactMap { artist in
            let score = FuzzyMatcher.scoreArtist(normalizedName: artist.normalizedName, cleanQuery: cleanQuery)
            return score > 0 ? (artist, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }.map { $0.0 }
    }

    public var filteredPlaylists: [Playlist] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if cleanQuery.isEmpty {
            if let cached = cachedSortedPlaylists {
                return cached
            }
            let sorted = sortPlaylists(playlists, by: playlistSortOption, isReversed: isPlaylistSortReversed)
            cachedSortedPlaylists = sorted
            return sorted
        }
        let scored: [(Playlist, Int)] = playlists.compactMap { playlist in
            let nameScore = FuzzyMatcher.evaluateScore(cleanText: playlist.normalizedName, cleanQuery: cleanQuery)
            let tokenScore = FuzzyMatcher.evaluateScore(cleanText: playlist.searchTokens, cleanQuery: cleanQuery)
            let maxScore = max(nameScore * 2, tokenScore)
            return maxScore > 0 ? (playlist, maxScore) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }.map { $0.0 }
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
        if let direct = albums.first(where: {
            guard $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame else { return false }
            if let artist {
                return $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame
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
            let synthesized = Artist(name: trimmedName, albums: matchingAlbums, tracks: matchingTracks)
            artistLookupIndex[canonicalKey] = synthesized
            return synthesized
        }
        return nil
    }

    // MARK: - Directory Linking & Scanning

    /// Links a new directory, saves the security bookmark, and initiates indexing.
    public func linkAndScanFolder(url: URL) async {
        // Ensure preconditions are met before proceeding
        guard SecurityScopedBookmark.shared.saveBookmark(for: url) else {
            AppLogger.library.error("Could not obtain security-scoped bookmark for \(url.path)")
            return
        }

        settings.linkedFolderName = url.lastPathComponent
        saveSettings()

        await rescanDirectory(url: url)
    }

    /// Rescans the previously linked directory.
    public func rescanCurrentDirectory() async {
        // Ensure preconditions are met before proceeding
        guard let url = SecurityScopedBookmark.shared.resolveAndAccessBookmark() else {
            AppLogger.library.warning("No active security-scoped directory available to rescan.")
            return
        }

        await rescanDirectory(url: url)
    }

    /// Unlinks the music folder and clears scanned library data.
    /// Preserves downloaded metadata cache and artwork cache so re-linking immediately restores all metadata.
    public func unlinkDirectory() {
        SecurityScopedBookmark.shared.clearSavedBookmark()
        settings.linkedFolderName = nil
        settings.lastScanDate = nil
        settings.totalScannedFiles = 0
        self.tracks = []
        self.albums = []
        self.artists = []
        self.duplicateGroups = []
        saveSettings()
        saveLibrary()
        saveDuplicates()
        // NOTE: downloadedMetadataCache and ArtworkCacheService are intentionally kept intact on disk!
        AppLogger.library.info("Unlinked directory while safely preserving downloaded metadata and artwork cache.")
    }

    // Rescan directory
    private func rescanDirectory(url: URL) async {
        self.isScanning = true
        self.scanProgress = 0.0
        self.scanStatusText = "Scanning directory..."

        let cachedExistingTracks = self.tracks

        // Scanned tracks with smart differential fast-path
        let scannedTracks = await AudioScannerService.shared.scanDirectory(
            at: url,
            existingTracks: cachedExistingTracks
        ) { [weak self] current, total, name in
            Task { @MainActor in
                guard let self = self else { return }
                self.scanProgress = total > 0 ? Double(current) / Double(total) : 0.0
                self.scanStatusText = "Processing (\(current)/\(total)): \(name)"
            }
        }

        self.scanStatusText = "Building albums and artists..."
        self.tracks = scannedTracks
        rebuildAlbumsAndArtists()

        self.scanStatusText = "Re-attaching cached metadata & artwork..."
        let reattached = reattachCachedMetadataToTracks()
        if reattached > 0 {
            rebuildAlbumsAndArtists()
        }

        // Cache baseline metadata and artwork for all scanned tracks non-blockingly
        self.scanStatusText = "Finalizing library index..."
        cacheScannedTracks(self.tracks)

        self.settings.lastScanDate = Date()
        self.settings.totalScannedFiles = scannedTracks.count
        self.isScanning = false
        self.scanProgress = 1.0
        self.scanStatusText = "Scan complete. Indexed \(scannedTracks.count) tracks (reattached \(reattached) cached)."

        saveLibrary()
        saveSettings()
        saveEnrichmentCache()

        Task {
            await self.recalculateDuplicates()
        }
        AppLogger.library.info("Library updated with \(scannedTracks.count) tracks. Reattached \(reattached) cached metadata records.")
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
        // Unique identifier for updated track i ds
        var updatedTrackIDs = playlists[index].trackIDs
        for track in newTracks {
            if !updatedTrackIDs.contains(track.id) {
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

    // Normalize album title for clustering
    private func normalizeAlbumTitleForClustering(_ rawTitle: String) -> String {
        // Display title
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Ensure preconditions are met before proceeding
        guard !title.isEmpty else { return "unknown album" }

        // Strip common deluxe / edition / version suffixes in parentheses, brackets, or after dashes:
        let editionPatterns = [
            #"\s*[\(\[](?:deluxe(?:\s+(?:edition|version|ep|set|package))?|expanded(?:\s+(?:edition|version))?|super\s+deluxe(?:\s+edition)?|special\s+edition|collector'?s?\s+edition|bonus\s+track(?:s)?\s*(?:version|edition)?|international\s+version|anniversary(?:\s+edition)?|remastered(?:\s+edition)?|standard\s+(?:version|edition)|explicit(?:\s+version)?|clean(?:\s+version)?)[\)\]]"#,
            #"\s*-\s*(?:deluxe(?:\s+(?:edition|version|ep))?|expanded(?:\s+edition)?|super\s+deluxe|special\s+edition|remastered|anniversary\s+edition|bonus\s+tracks?)"#
        ]

        for pat in editionPatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                // Range
                let range = NSRange(location: 0, length: title.utf16.count)
                title = regex.stringByReplacingMatches(in: title, options: [], range: range, withTemplate: "")
            }
        }

        // Cleaned
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? rawTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    // Rebuild albums and artists with O(N) performance
    private func rebuildAlbumsAndArtists() {
        // 1. Initial grouping strictly by Album (preserving unified albums without splitting by individual track artists)
        var albumTitleBuckets: [String: [Track]] = [:]
        var standaloneSingleTracks: [Track] = []

        for track in self.tracks {
            let trimmedAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: track.title, album: track.album)
            let isLive = MetadataSanitizer.isLiveRecording(title: track.title, album: track.album)

            if trimmedAlbum.isEmpty || trimmedAlbum.lowercased() == "unknown album" || trimmedAlbum.lowercased() == "unknown" {
                standaloneSingleTracks.append(track)
                continue
            }

            let baseNormAlbum = normalizeAlbumTitleForClustering(trimmedAlbum)
            let normAlbum: String
            if isRemix {
                normAlbum = "\(baseNormAlbum)____alternates"
            } else if isLive {
                normAlbum = "\(baseNormAlbum)____live"
            } else {
                normAlbum = baseNormAlbum
            }

            albumTitleBuckets[normAlbum, default: []].append(track)
        }

        var rawAlbumClusters: [[Track]] = []

        // Process each album title bucket: merge tracks into unified albums
        for (_, tracksInBucket) in albumTitleBuckets {
            var subClusters: [[Track]] = []

            for track in tracksInBucket {
                let trackArtists = Set(ArtistParser.parseArtists(from: track.artist).map { ArtistParser.canonicalArtistKey($0) })
                let trackAlbArtist = track.albumArtist.flatMap { ArtistParser.canonicalArtistKey($0) }
                let trackFolder = track.url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
                let cleanFolder = trackFolder
                    .replacingOccurrences(of: #"/cd\s*\d+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"/disc\s*\d+"#, with: "", options: .regularExpression)
                let trackArt = track.artworkKey

                var mergedIndices: [Int] = []
                for (idx, cluster) in subClusters.enumerated() {
                    let isRelated = cluster.contains { other in
                        // 1. Same directory/folder
                        let otherFolder = other.url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
                            .replacingOccurrences(of: #"/cd\s*\d+"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: #"/disc\s*\d+"#, with: "", options: .regularExpression)
                        if !cleanFolder.isEmpty && cleanFolder == otherFolder {
                            return true
                        }
                        // 2. Shared artwork key
                        if let art = trackArt, !art.isEmpty, let otherArt = other.artworkKey, !otherArt.isEmpty, art == otherArt {
                            return true
                        }
                        // 3. Shared album artist
                        if let albArt = trackAlbArtist, !albArt.isEmpty, let otherAlb = other.albumArtist.flatMap({ ArtistParser.canonicalArtistKey($0) }), !otherAlb.isEmpty, albArt == otherAlb {
                            return true
                        }
                        // 4. Overlapping artists (e.g. lead artist or collaborator)
                        let otherArtists = Set(ArtistParser.parseArtists(from: other.artist).map { ArtistParser.canonicalArtistKey($0) })
                        if !trackArtists.isDisjoint(with: otherArtists) {
                            return true
                        }
                        return false
                    }

                    if isRelated {
                        mergedIndices.append(idx)
                    }
                }

                if mergedIndices.isEmpty {
                    subClusters.append([track])
                } else {
                    var combined: [Track] = [track]
                    for idx in mergedIndices.sorted(by: >) {
                        combined.append(contentsOf: subClusters.remove(at: idx))
                    }
                    subClusters.append(combined)
                }
            }

            rawAlbumClusters.append(contentsOf: subClusters)
        }

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

        for groupTracks in rawAlbumClusters {
            guard let first = groupTracks.first else { continue }

            let isRemixCluster = groupTracks.allSatisfy { MetadataSanitizer.isRemixOrAlternateVersion(title: $0.title, album: $0.album) }
            let isLiveCluster = groupTracks.allSatisfy { MetadataSanitizer.isLiveRecording(title: $0.title, album: $0.album) }
            let baseAlbumTitle = first.album.isEmpty ? "Unknown Album" : first.album.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let albumTitle: String
            if isRemixCluster {
                albumTitle = MetadataSanitizer.remixAlbumName(forStandardAlbum: baseAlbumTitle)
            } else if isLiveCluster {
                albumTitle = MetadataSanitizer.liveAlbumName(forStandardAlbum: baseAlbumTitle)
            } else {
                albumTitle = baseAlbumTitle
            }

            // Display Artist determination strictly for this unified album: list out each individual artist
            let explicitAlbumArtist = groupTracks.compactMap { $0.albumArtist?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }.first { !$0.isEmpty && !MetadataSanitizer.isUnknownArtist($0) && $0.lowercased() != "various artists" && $0.lowercased() != "various" }
            let displayArtist: String
            if let explicit = explicitAlbumArtist {
                displayArtist = explicit
            } else {
                var allTrackArtists: [String] = []
                for t in groupTracks {
                    let parsed = ArtistParser.parseArtists(from: t.artist)
                    for a in parsed {
                        let clean = a.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty && !MetadataSanitizer.isUnknownArtist(clean) && clean.lowercased() != "various artists" && clean.lowercased() != "various" && !allTrackArtists.contains(where: { $0.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
                            allTrackArtists.append(clean)
                        }
                    }
                }

                if allTrackArtists.count == 1 {
                    displayArtist = allTrackArtists[0]
                } else if allTrackArtists.count == 2 {
                    displayArtist = "\(allTrackArtists[0]) & \(allTrackArtists[1])"
                } else if allTrackArtists.count >= 3 {
                    let firstPart = allTrackArtists.dropLast().joined(separator: ", ")
                    displayArtist = "\(firstPart) & \(allTrackArtists.last!)"
                } else {
                    displayArtist = first.artist.isEmpty ? "Unknown Artist" : first.artist
                }
            }

            // Propagate artwork consensus across album tracks
            let albumArtworkKey = groupTracks.compactMap({ $0.artworkKey }).first(where: { !$0.isEmpty })

            var seenTrackIDs = Set<UUID>()
            var uniqueClusterTracks: [Track] = []
            uniqueClusterTracks.reserveCapacity(groupTracks.count)
            for t in groupTracks {
                if seenTrackIDs.insert(t.id).inserted {
                    uniqueClusterTracks.append(t)
                }
            }

            // Instant Album Artwork Consensus Propagation:
            if let validArtworkKey = albumArtworkKey, !validArtworkKey.isEmpty {
                for i in 0..<uniqueClusterTracks.count {
                    if uniqueClusterTracks[i].artworkKey == nil || uniqueClusterTracks[i].artworkKey?.isEmpty == true {
                        uniqueClusterTracks[i] = uniqueClusterTracks[i].withArtworkKey(validArtworkKey)
                        if let globalIdx = self.tracks.firstIndex(where: { $0.id == uniqueClusterTracks[i].id }) {
                            self.tracks[globalIdx] = self.tracks[globalIdx].withArtworkKey(validArtworkKey)
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

            // Instant Album Year Consensus Propagation:
            if let validConsensusYear = consensusYear, validConsensusYear > 0 {
                for i in 0..<uniqueClusterTracks.count {
                    if uniqueClusterTracks[i].year == nil || uniqueClusterTracks[i].year == 0 {
                        uniqueClusterTracks[i] = uniqueClusterTracks[i].withYear(validConsensusYear)
                        if let globalIdx = self.tracks.firstIndex(where: { $0.id == uniqueClusterTracks[i].id }) {
                            self.tracks[globalIdx] = self.tracks[globalIdx].withYear(validConsensusYear)
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

            let album = Album(
                title: albumTitle,
                artist: displayArtist.isEmpty ? "Unknown Artist" : displayArtist,
                year: consensusYear,
                genre: first.genre,
                artworkKey: albumArtworkKey,
                tracks: sortedAlbumTracks
            )
            newAlbums.append(album)
        }

        // Deduplicate any colliding album IDs to guarantee 100% unique IDs
        var uniqueAlbums: [Album] = []
        var seenAlbumIDs = Set<String>()
        uniqueAlbums.reserveCapacity(newAlbums.count)
        for album in newAlbums {
            if seenAlbumIDs.insert(album.id).inserted {
                uniqueAlbums.append(album)
            }
        }

        self.albums = uniqueAlbums.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        // 2. High-Speed Inverted Index for Track -> Albums (O(totalAlbumTracks) single pass)
        var trackIDToAlbumsMap: [UUID: [Album]] = [:]
        trackIDToAlbumsMap.reserveCapacity(self.tracks.count)
        for album in self.albums {
            for track in album.tracks {
                trackIDToAlbumsMap[track.id, default: []].append(album)
            }
        }

        // 3. Multi-Artist & Title Feature Extraction (with Joined Artists support)
        // 3. Multi-Artist & Title Feature Extraction (with Verified Names & Joined Artists support)
        var verifiedArtistNames: [String: String] = [:]
        for diff in self.verifiedGoodDiffs {
            let parsed = ArtistParser.parseArtists(from: diff.onlineMetadata.artist)
            for a in parsed {
                let k = ArtistParser.canonicalArtistKey(a)
                if !k.isEmpty && !ArtistParser.isGenericArtistName(a) {
                    verifiedArtistNames[k] = a
                }
            }
        }
        for (_, record) in self.downloadedMetadataCache.recordsByFilePath {
            let parsed = ArtistParser.parseArtists(from: record.onlineMetadata.artist)
            for a in parsed {
                let k = ArtistParser.canonicalArtistKey(a)
                if !k.isEmpty && !ArtistParser.isGenericArtistName(a) {
                    verifiedArtistNames[k] = a
                }
            }
        }

        var artistTracksMap: [String: (variantCounts: [String: Int], tracks: [Track], seenTrackIDs: Set<UUID>)] = [:]

        for track in tracks {
            let trackRawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let trackCanonical = ArtistParser.canonicalArtistKey(trackRawArtist)
            let albumRawArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let albumCanonical = ArtistParser.canonicalArtistKey(albumRawArtist)

            var matchedJoinedArtist: String? = nil
            for joinedRule in settings.joinedArtists {
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

                if var existing = artistTracksMap[canonicalKey] {
                    if existing.seenTrackIDs.insert(track.id).inserted {
                        existing.tracks.append(track)
                    }
                    existing.variantCounts[artistName, default: 0] += 1
                    artistTracksMap[canonicalKey] = existing
                } else {
                    artistTracksMap[canonicalKey] = (variantCounts: [artistName: 1], tracks: [track], seenTrackIDs: [track.id])
                }
            }
        }

        // 4. Instantaneous Artist Synthesis using Inverted Track-to-Album Map
        var newArtists: [Artist] = []
        newArtists.reserveCapacity(artistTracksMap.count)

        for (canonicalKey, artistData) in artistTracksMap {
            // Find local majority consensus name among local tracks
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
                tracks: artistTracks
            )
            newArtists.append(artist)
        }

        let sortedArtists = newArtists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.artists = sortedArtists

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
        self.artistLookupIndex = lookup
        invalidateSortedCaches()
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
    private func sortTracks(_ list: [Track], by option: TrackSortOption, isReversed: Bool) -> [Track] {
        // Sorted
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
                // P 0
                let p0 = playCounts[$0.id] ?? 0
                // P 1
                let p1 = playCounts[$1.id] ?? 0
                if p0 != p1 {
                    return isReversed ? p0 < p1 : p0 > p1
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
        return sorted
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
        self.verifiedGoodDiffs.append(diff)
        self.saveEnrichmentCache()

        // Permanently record in downloaded metadata cache
        self.cacheDownloadedMetadata(
            track: updatedTrack,
            onlineMetadata: onlineMetadata,
            artworkKey: finalArtworkKey,
            wasApplied: true
        )

        rebuildAlbumsAndArtists()
        await recalculateDuplicates()
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
        self.verifiedGoodDiffs.append(diff)
        self.saveEnrichmentCache()

        self.cacheDownloadedMetadata(
            track: updatedTrack,
            onlineMetadata: onlineMetadata,
            artworkKey: finalArtworkKey,
            wasApplied: true
        )

rebuildAlbumsAndArtists()
        await recalculateDuplicates()
        saveLibrary()

        return true
    }

    /// Applies an online album and its child cuts to all matched child tracks (including discovered/reassigned tracks).
    public func applyOnlineAlbumToAlbum(
        album: Album?,
        onlineAlbum: OnlineAlbumItem,
        onlineTracks: [OnlineTrackMetadata],
        preserveLocalTitleAndArtist: Bool = true,
        specificTracksToApply: [Track]? = nil
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

        // Determine target candidate tracks: specific passed tracks, or album tracks, or all library candidates
        let candidatePool: [Track]
        if let specific = specificTracksToApply, !specific.isEmpty {
            candidatePool = specific
        } else if let alb = album, !alb.tracks.isEmpty {
            candidatePool = alb.tracks
        } else {
            candidatePool = self.tracks
        }

        // Run bipartite tracklist alignment
        let (assignments, _) = DisambiguationMatcher.matchAlbumTracklistToCandidates(
            onlineTracks: onlineTracks,
            albumTitle: onlineAlbum.title,
            albumArtist: onlineAlbum.artistName,
            candidateTracks: candidatePool
        )

        var processedTrackIDs: Set<UUID> = []
        var trackIndexMap: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackIndexMap[t.id] = i
        }

        var fileTaggingQueue: [(url: URL, track: Track, artworkData: Data?)] = []

        for assignment in assignments {
            guard let localTrack = assignment.localTrack,
                  let trackIndex = trackIndexMap[localTrack.id],
                  trackIndex < tracks.count else { continue }

            let existingTrack = tracks[trackIndex]
            let cut = assignment.cut

            let finalTitle = preserveLocalTitleAndArtist ? existingTrack.title : cut.title
            let finalArtist = preserveLocalTitleAndArtist ? existingTrack.artist : cut.artist
            let rawAlbum = onlineAlbum.title
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
                lyrics: existingTrack.lyrics
            )

            tracks[trackIndex] = updatedTrack
            processedTrackIDs.insert(existingTrack.id)

            fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkData: artworkData))

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
        onProgress: ((Double, String) -> Void)? = nil
    ) async -> Int {
        // Ensure preconditions are met before proceeding
        guard !diffs.isEmpty else { return 0 }

        // Ensure root linked folder security-scoped access is active across all file writes
        let rootFolderURL = SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        // Flag indicating if root accessing
        let isRootAccessing = rootFolderURL?.startAccessingSecurityScopedResource() ?? false
        // Cleanup upon exiting scope
        defer {
            if isRootAccessing, let root = rootFolderURL {
                root.stopAccessingSecurityScopedResource()
            }
        }

        // Total
        let total = diffs.count
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
            fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artworkKey: artworkKeyForTagging))

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
            newVerifiedGood.append(updatedDiff)

            let progressVal = 0.35 + (Double(idx + 1) / Double(total)) * 0.40
            if idx % 10 == 0 || idx == total - 1 {
                onProgress?(progressVal, "Step 2/3: Applying metadata (\(idx + 1)/\(total)): \(finalTitle)")
                await Task.yield()
            }
        }

        // Clean up diff lists and update verified good tracks
        self.enrichmentDiffs.removeAll { processedTrackIDs.contains($0.id) }
        self.unmatchedTrackIDs.subtract(processedTrackIDs)
        self.verifiedGoodDiffs.removeAll { processedTrackIDs.contains($0.id) }
        self.verifiedGoodDiffs.append(contentsOf: newVerifiedGood)

        // MARK: - Step 2.5: Lossless Audio File Tag Writing with Bounded Worker Pool & On-Demand Artwork Loading
        if settings.writeMetadataToAudioFiles && !fileTaggingQueue.isEmpty {
            let taggingTotal = fileTaggingQueue.count
            var taggingDone = 0
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

    /// Triggers an online metadata scan specifically for all tracks in an artist's discography.
    public func scanArtistDiscographyMetadata(artistName: String, source: MetadataAPIOption = .all) {
        let artistTracks = findTracksForArtistDiscography(artistName: artistName)
        guard !artistTracks.isEmpty else { return }

        isBackgroundCheckingMetadata = true
        backgroundCheckProgress = 0.0
        backgroundCheckStatusText = "Scanning discography for \(artistName) via \(source.displayName)..."

        let trackIDs = Set(artistTracks.map { $0.id })
        self.enrichmentDiffs.removeAll { trackIDs.contains($0.localTrack.id) }
        self.verifiedGoodDiffs.removeAll { trackIDs.contains($0.localTrack.id) }
        self.unmatchedTrackIDs.subtract(trackIDs)

        let storageURL = self.storageDirectoryURL

        Task {
            await BackgroundMetadataScanner.shared.startScan(
                tracks: artistTracks,
                existingDiffs: self.enrichmentDiffs,
                existingGood: self.verifiedGoodDiffs,
                existingUnmatched: self.unmatchedTrackIDs,
                forceRecheck: true,
                storageDirectoryURL: storageURL,
                source: source,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.backgroundCheckProgress = progress.progress
                        self.backgroundCheckStatusText = progress.statusText
                        self.enrichmentDiffs = progress.enrichmentDiffs
                        self.verifiedGoodDiffs = progress.verifiedGoodDiffs
                        self.unmatchedTrackIDs = progress.unmatchedTrackIDs
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.enrichmentDiffs = result.enrichmentDiffs
                        self.verifiedGoodDiffs = result.verifiedGoodDiffs
                        self.unmatchedTrackIDs = result.unmatchedTrackIDs
                        self.isBackgroundCheckingMetadata = false
                        self.backgroundCheckProgress = 1.0
                        self.backgroundCheckStatusText = "Discography scan complete for \(artistName)."
                        self.saveEnrichmentCache()
                    }
                }
            )
        }
    }

    /// Launches an isolated background metadata scan off the main thread.
    public func startBackgroundMetadataScan(for customTracks: [Track]? = nil, forceRecheck: Bool = false) {
        // Ensure preconditions are met before proceeding
        guard !isBackgroundCheckingMetadata else { return }
        let tracksToScan = customTracks ?? self.tracks
        guard !tracksToScan.isEmpty else { return }

        isBackgroundCheckingMetadata = true
        backgroundCheckProgress = 0.0
        backgroundCheckScannedCount = 0
        backgroundCheckTotalCount = tracksToScan.count
        backgroundCheckStatusText = "Initializing metadata scan..."

        if forceRecheck && customTracks == nil {
            self.enrichmentDiffs.removeAll()
            self.verifiedGoodDiffs.removeAll()
            self.unmatchedTrackIDs.removeAll()
        }

        // Diffs
        let diffs = self.enrichmentDiffs
        // Good
        let good = self.verifiedGoodDiffs
        // Unmatched
        let unmatched = self.unmatchedTrackIDs
        // File system location for storage url
        let storageURL = self.storageDirectoryURL

        Task {
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
                        self.enrichmentDiffs = progress.enrichmentDiffs
                        self.verifiedGoodDiffs = progress.verifiedGoodDiffs
                        self.unmatchedTrackIDs = progress.unmatchedTrackIDs
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.enrichmentDiffs = result.enrichmentDiffs
                        self.verifiedGoodDiffs = result.verifiedGoodDiffs
                        self.unmatchedTrackIDs = result.unmatchedTrackIDs
                        self.isBackgroundCheckingMetadata = false
                        self.backgroundCheckProgress = 1.0
                        self.backgroundCheckScannedCount = self.backgroundCheckTotalCount
                        self.backgroundCheckStatusText = "Library analysis complete."
                    }
                }
            )
        }
    }

    /// Cancels any currently active background scan.
    public func cancelBackgroundMetadataScan() {
        Task {
            await BackgroundMetadataScanner.shared.cancel()
            await MainActor.run {
                self.isBackgroundCheckingMetadata = false
            }
        }
    }

    /// Triggers a full rescan of all metadata from scratch.
    public func rescanAllMetadata() {
        startBackgroundMetadataScan(forceRecheck: true)
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
        let candidates = tracks.filter { $0.artworkKey == nil || $0.year == nil || $0.trackNumber == nil }
        // Total
        let total = candidates.count

        // Ensure preconditions are met before proceeding
        guard total > 0 else {
            self.enrichProgress = 1.0
            self.enrichStatusText = "All tracks already have complete metadata and artwork."
            self.isEnrichingMetadata = false
            return
        }

        // Enriched count
        var enrichedCount = 0
        for (idx, track) in candidates.enumerated() {
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
        self.isEnrichingMetadata = false
    }

    // MARK: - Persistence Engine

    // File path location
    private var libraryFileURL: URL { storageDirectoryURL.appendingPathComponent("library.json") }
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

        Task.detached(priority: .utility) {
            await ArtworkCacheService.shared.clearCache()
        }
        AppLogger.storage.info("Manually cleared downloaded metadata and artwork cache.")
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
                // If the track was updated locally or has new artwork, ensure indices are synchronized
                if existing.cachedArtworkKey != track.artworkKey || existing.filePath != path {
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
                        appliedArtist: existing.appliedArtist,
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
    public func lookupCachedMetadata(for track: Track) -> CachedTrackMetadataRecord? {
        let path = track.url.standardizedFileURL.path
        if let record = downloadedMetadataCache.recordsByFilePath[path] {
            return record
        }
        let fileSig = computeFileSignature(fileName: track.url.lastPathComponent, size: track.fileInfo?.fileSizeBytes ?? 0)
        if !fileSig.isEmpty, let record = downloadedMetadataCache.recordsByFileSignature[fileSig] {
            return record
        }
        let sig = computeTrackSignature(artist: track.artist, title: track.title, duration: track.duration)
        if !sig.isEmpty, let record = downloadedMetadataCache.recordsBySignature[sig] {
            return record
        }
        return nil
    }

    public func computeTrackSignature(artist: String, title: String, duration: TimeInterval) -> String {
        let normArtist = FuzzyMatcher.normalize(artist)
        let normTitle = FuzzyMatcher.normalize(title)
        guard !normArtist.isEmpty || !normTitle.isEmpty else { return "" }
        let durInt = Int(duration.rounded())
        return "\(normArtist)__\(normTitle)__\(durInt)"
    }

    public func computeFileSignature(fileName: String, size: Int64) -> String {
        let normName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normName.isEmpty else { return "" }
        return "\(normName)__\(size)"
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
                    // Restore fully applied metadata and artwork
                    currentTrack = Track(
                        id: track.id,
                        title: record.appliedTitle ?? track.title,
                        artist: record.appliedArtist ?? track.artist,
                        album: record.appliedAlbum ?? track.album,
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

        var existingGoodMap = Dictionary(verifiedGoodDiffs.map { ($0.localTrack.id, $0) }, uniquingKeysWith: { first, _ in first })
        for g in newVerified {
            existingGoodMap[g.localTrack.id] = g
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
        let currentSettings = self.settings
        let url = self.settingsFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(currentSettings) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Save library tracks asynchronously
    public func saveLibrary() {
        let tracksToSave = self.tracks
        let url = self.libraryFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(tracksToSave) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Save playlists asynchronously
    public func savePlaylists() {
        let playlistsToSave = self.playlists
        let url = self.playlistsFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(playlistsToSave) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Save play counts asynchronously
    public func savePlayCounts() {
        let counts = self.playCounts
        let url = self.playCountsFileURL
        Task.detached(priority: .utility) {
            let stringKeyed = Dictionary(counts.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
            if let data = try? JSONEncoder().encode(stringKeyed) {
                try? data.write(to: url, options: .atomic)
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
        Task.detached(priority: .utility) {
            let stringKeyed = Dictionary(positions.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
            if let data = try? JSONEncoder().encode(stringKeyed) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Save pins asynchronously
    public func savePins() {
        let pins = self.pinnedItemIDs
        let url = self.pinsFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(pins) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // Load persisted state
    private func loadPersistedState() {
        // Load Downloaded Metadata Cache first
        loadDownloadedMetadataCache()

        // Load Settings
        if let data = try? Data(contentsOf: settingsFileURL),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = loaded
            self.selectedCategory = loaded.defaultLibraryCategory
        }

        // Load Enrichment Diffs, Verified Good, & Unmatched before reattachment
        if let data = try? Data(contentsOf: enrichmentFileURL),
           let loadedDiffs = try? JSONDecoder().decode([MetadataDiff].self, from: data) {
            self.enrichmentDiffs = loadedDiffs
        }

        if let data = try? Data(contentsOf: verifiedGoodFileURL),
           let loadedGood = try? JSONDecoder().decode([MetadataDiff].self, from: data) {
            self.verifiedGoodDiffs = loadedGood
        }

        if let data = try? Data(contentsOf: unmatchedFileURL),
           let loadedUnmatched = try? JSONDecoder().decode([UUID].self, from: data) {
            self.unmatchedTrackIDs = Set(loadedUnmatched)
        }

        // Load Library Tracks
        if let data = try? Data(contentsOf: libraryFileURL),
           let loadedTracks = try? JSONDecoder().decode([Track].self, from: data) {
            self.tracks = loadedTracks
            rebuildAlbumsAndArtists()
        }

        // Reattach cached metadata & artwork to loaded library tracks
        if !self.tracks.isEmpty {
            let reattached = reattachCachedMetadataToTracks()
            if reattached > 0 {
                rebuildAlbumsAndArtists()
            }
        }

        // Load Duplicates
        if let data = try? Data(contentsOf: duplicatesFileURL),
           let loadedDuplicates = try? JSONDecoder().decode([DuplicateGroup].self, from: data) {
            self.duplicateGroups = loadedDuplicates
        } else if !self.tracks.isEmpty {
            Task {
                await self.recalculateDuplicates()
            }
        }

        // Load Playlists
        if let data = try? Data(contentsOf: playlistsFileURL),
           // Loaded playlists
           let loadedPlaylists = try? JSONDecoder().decode([Playlist].self, from: data) {
            self.playlists = loadedPlaylists
        }

        // Load Play Counts
        if let data = try? Data(contentsOf: playCountsFileURL),
           // Loaded counts
           let loadedCounts = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.playCounts = Dictionary(loadedCounts.compactMap { key, val in
                UUID(uuidString: key).map { ($0, val) }
            }, uniquingKeysWith: { first, _ in first })
        }

        // Load Playback Positions
        if let data = try? Data(contentsOf: playbackPositionsFileURL),
           // Loaded positions
           let loadedPositions = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            self.playbackPositions = Dictionary(loadedPositions.compactMap { key, val in
                UUID(uuidString: key).map { ($0, val) }
            }, uniquingKeysWith: { first, _ in first })
        }

        // Load Pins
        if let data = try? Data(contentsOf: pinsFileURL),
           // Loaded pins
           let loadedPins = try? JSONDecoder().decode([PinnedItemIdentifier].self, from: data) {
            self.pinnedItemIDs = loadedPins
            self.pinnedAlbumIDs = Set(loadedPins.filter { $0.type == .album }.map { $0.targetID })
        } else {
            // Initial pins
            var initialPins: [PinnedItemIdentifier] = []
            for pl in playlists where pl.isPinned {
                initialPins.append(PinnedItemIdentifier(type: .playlist, targetID: pl.id.uuidString))
            }
            self.pinnedItemIDs = initialPins
            self.pinnedAlbumIDs = []
        }

        AppLogger.storage.info("Persisted state loaded: \(self.tracks.count) tracks, \(self.playlists.count) playlists, \(self.pinnedItemIDs.count) pins, \(self.duplicateGroups.count) duplicate groups, \(self.enrichmentDiffs.count) enrichment diffs, \(self.unmatchedTrackIDs.count) unmatched.")
    }
}
