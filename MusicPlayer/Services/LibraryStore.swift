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
    public var trackSortOption: TrackSortOption = .title
    // Controls is track sort reversed
    public var isTrackSortReversed: Bool = false

    public var artistSortOption: ArtistSortOption = .name
    // Controls is artist sort reversed
    public var isArtistSortReversed: Bool = false

    public var albumSortOption: AlbumSortOption = .title
    // Controls is album sort reversed
    public var isAlbumSortReversed: Bool = false

    public var playlistSortOption: PlaylistSortOption = .name
    // Controls is playlist sort reversed
    public var isPlaylistSortReversed: Bool = false

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
        // Source list
        let sourceList: [Track]
        if settings.autoHideDuplicates && !duplicateGroups.isEmpty {
            // Unique identifier for hidden track i ds
            let hiddenTrackIDs = Set(duplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track.id } })
            sourceList = tracks.filter { !hiddenTrackIDs.contains($0.id) }
        } else {
            sourceList = tracks
        }

        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if !cleanQuery.isEmpty {
            // Scored
            let scored: [(Track, Int)] = sourceList.compactMap { track in
                // Score
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
        } else {
            return sortTracks(sourceList, by: trackSortOption, isReversed: isTrackSortReversed)
        }
    }

    /// Standardized, high-performance album search scoring title, artist, and track titles.
    public func searchAlbums(query: String) -> [Album] {
        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(query)
        // Ensure preconditions are met before proceeding
        guard !cleanQuery.isEmpty else { return albums }

        // Scored
        let scored: [(Album, Int)] = albums.compactMap { album in
            // Max score
            var maxScore = FuzzyMatcher.scoreAlbum(
                normalizedTitle: album.normalizedTitle,
                normalizedArtist: album.normalizedArtist,
                cleanQuery: cleanQuery
            )
            for track in album.tracks {
                // Track score
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
        // Trimmed
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return searchAlbums(query: trimmed)
        } else {
            return sortAlbums(albums, by: albumSortOption, isReversed: isAlbumSortReversed)
        }
    }

    public var filteredArtists: [Artist] {
        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if !cleanQuery.isEmpty {
            // Scored
            let scored: [(Artist, Int)] = artists.compactMap { artist in
                // Score
                let score = FuzzyMatcher.scoreArtist(normalizedName: artist.normalizedName, cleanQuery: cleanQuery)
                return score > 0 ? (artist, score) : nil
            }
            return scored.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
            }.map { $0.0 }
        } else {
            return sortArtists(artists, by: artistSortOption, isReversed: isArtistSortReversed)
        }
    }

    public var filteredPlaylists: [Playlist] {
        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        if !cleanQuery.isEmpty {
            // Scored
            let scored: [(Playlist, Int)] = playlists.compactMap { playlist in
                // Name score
                let nameScore = FuzzyMatcher.evaluateScore(cleanText: playlist.normalizedName, cleanQuery: cleanQuery)
                // Token score
                let tokenScore = FuzzyMatcher.evaluateScore(cleanText: playlist.searchTokens, cleanQuery: cleanQuery)
                // Max score
                let maxScore = max(nameScore * 2, tokenScore)
                return maxScore > 0 ? (playlist, maxScore) : nil
            }
            return scored.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
            }.map { $0.0 }
        } else {
            return sortPlaylists(playlists, by: playlistSortOption, isReversed: isPlaylistSortReversed)
        }
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
        tracks.filter { $0.artworkKey == nil || $0.artworkKey!.isEmpty }.count
    }

    public var tracksMissingMetadataCount: Int {
        tracks.filter { $0.year == nil || $0.trackNumber == nil || $0.artworkKey == nil }.count
    }

    // MARK: - Direct Collection Lookups

    /// Finds an Album matching the specified title and optional artist name.
    public func findAlbum(title: String, artist: String? = nil) -> Album? {
        // Clean title
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = albums.first(where: {
            $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame &&
            (artist == nil || $0.artist.localizedCaseInsensitiveCompare(artist!) == .orderedSame)
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

    /// Finds an Artist matching the specified name (exact or individual parsed artist match).
    public func findArtist(name: String) -> Artist? {
        // Trimmed name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = artists.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return direct
        }
        // Match tracks containing this artist in all metadata (direct or featured in title)
        let matchingTracks = tracks.filter { track in
            // Track raw artist
            let trackRawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            // Track canonical
            let trackCanonical = trackRawArtist.lowercased()
            // Album raw artist
            let albumRawArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Album canonical
            let albumCanonical = albumRawArtist.lowercased()

            // If this track belongs to a joined artist, only match if trimmedName is that joined artist
            var matchedJoined: String? = nil
            for joined in settings.joinedArtists {
                // Joined canonical
                let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trackCanonical == joinedCanonical || albumCanonical == joinedCanonical {
                    matchedJoined = joined
                    break
                }
                // Joined parts
                let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
                if joinedParts.count > 1 {
                    // Track parts
                    let trackParts = ArtistParser.parseArtists(from: trackRawArtist).map { $0.lowercased() }
                    // Album parts
                    let albumParts = ArtistParser.parseArtists(from: albumRawArtist).map { $0.lowercased() }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) || (!albumParts.isEmpty && Set(joinedParts).isSubset(of: Set(albumParts))) {
                        matchedJoined = joined
                        break
                    }
                }
            }

            if let joined = matchedJoined {
                return joined.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
            }

            // All
            let all = ArtistParser.allArtists(forTitle: track.title, artist: track.artist, albumArtist: track.albumArtist)
            return all.contains { $0.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }
        }
        if !matchingTracks.isEmpty {
            // Matching albums
            let matchingAlbums = albums.filter { album in
                album.tracks.contains { t in matchingTracks.contains { $0.id == t.id } }
            }
            return Artist(name: trimmedName, albums: matchingAlbums, tracks: matchingTracks)
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

        // Scanned tracks
        let scannedTracks = await AudioScannerService.shared.scanDirectory(at: url) { [weak self] current, total, name in
            Task { @MainActor in
                // Ensure preconditions are met before proceeding
                guard let self = self else { return }
                self.scanProgress = total > 0 ? Double(current) / Double(total) : 0.0
                self.scanStatusText = "Processing (\(current)/\(total)): \(name)"
            }
        }

        self.tracks = scannedTracks
        rebuildAlbumsAndArtists()

        // Automatically reattach persistently cached downloaded metadata and artwork
        let reattached = reattachCachedMetadataToTracks()
        if reattached > 0 {
            rebuildAlbumsAndArtists()
        }

        self.settings.lastScanDate = Date()
        self.settings.totalScannedFiles = scannedTracks.count
        self.isScanning = false
        self.scanProgress = 1.0
        self.scanStatusText = "Scan complete. Indexed \(scannedTracks.count) tracks (reattached \(reattached) cached)."

        saveLibrary()
        saveSettings()
        saveEnrichmentCache()
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
        // Track map
        let trackMap = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
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

    // Rebuild albums and artists
    private func rebuildAlbumsAndArtists() {
        // 1. Initial grouping strictly by normalized album title
        let rawAlbumGroups = Dictionary(grouping: tracks) { track -> String in
            // Trimmed album
            let trimmedAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            // Norm album
            let normAlbum = normalizeAlbumTitleForClustering(trimmedAlbum)

            if normAlbum == "unknown album" || normAlbum.isEmpty {
                return "unknown_album_\(track.id.uuidString)"
            }
            return normAlbum
        }

        // New albums
        var newAlbums: [Album] = []

        for (normAlbum, groupTracks) in rawAlbumGroups {
            if normAlbum.hasPrefix("unknown_album_") {
                for singleTrack in groupTracks {
                    // Album title
                    let album = Album(
                        title: singleTrack.album.isEmpty ? "Unknown Album" : singleTrack.album,
                        artist: singleTrack.artist.isEmpty ? "Unknown Artist" : singleTrack.artist,
                        year: singleTrack.year,
                        artworkKey: singleTrack.artworkKey,
                        tracks: [singleTrack]
                    )
                    newAlbums.append(album)
                }
                continue
            }

            // Cluster tracks within the same normalized album name
            // Group tracks together unless they clearly belong to completely disjoint/unrelated lead artists
            var clusters: [[Track]] = []

            for track in groupTracks {
                // Track artists
                let trackArtists = Set(
                    ArtistParser.allArtists(
                        forTitle: track.title,
                        artist: track.artist,
                        albumArtist: track.albumArtist
                    ).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                )
                // Explicit album artist
                let explicitAlbumArtist = track.albumArtist?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                // Matched cluster index
                var matchedClusterIndex: Int? = nil
                for (idx, cluster) in clusters.enumerated() {
                    // Cluster artists
                    let clusterArtists = Set(
                        cluster.flatMap {
                            ArtistParser.allArtists(
                                forTitle: $0.title,
                                artist: $0.artist,
                                albumArtist: $0.albumArtist
                            ).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                    )
                    // Cluster explicit album artists
                    let clusterExplicitAlbumArtists = Set(
                        cluster.compactMap { $0.albumArtist?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    )

                    // Flag indicating if artist overlap
                    let hasArtistOverlap = !trackArtists.isDisjoint(with: clusterArtists)
                    // Flag indicating if explicit album artist match
                    let hasExplicitAlbumArtistMatch = explicitAlbumArtist != nil && !explicitAlbumArtist!.isEmpty && clusterExplicitAlbumArtists.contains(explicitAlbumArtist!)

                    if hasArtistOverlap || hasExplicitAlbumArtistMatch {
                        matchedClusterIndex = idx
                        break
                    }
                }

                if let idx = matchedClusterIndex {
                    clusters[idx].append(track)
                } else {
                    clusters.append([track])
                }
            }

            // If an album with the same normalized title has multiple non-overlapping clusters,
            // check if they should merge (e.g. compilations / multi-artist tracks in same folder):
            if clusters.count > 1 {
                // Merged clusters
                var mergedClusters: [[Track]] = []
                for cluster in clusters {
                    if let firstCluster = mergedClusters.first,
                       cluster.allSatisfy({ t in
                           // File system location for f path
                           let fPath = t.url.deletingLastPathComponent().path
                           return firstCluster.contains(where: { $0.url.deletingLastPathComponent().path == fPath })
                       }) {
                        mergedClusters[0].append(contentsOf: cluster)
                    } else {
                        mergedClusters.append(cluster)
                    }
                }
                clusters = mergedClusters
            }

            for clusterTracks in clusters {
                // Ensure preconditions are met before proceeding
                guard let first = clusterTracks.first else { continue }

                // Consolidated Title: prefer the richest / longest title (e.g. "Album (Deluxe Edition)" over "Album")
                let longestTitle = clusterTracks.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .max(by: { $0.count < $1.count }) ?? first.album

                // Album title
                let albumTitle = longestTitle.isEmpty ? "Unknown Album" : longestTitle

                // Consolidated Album Artist:
                let explicitAlbumArtist = clusterTracks.compactMap { $0.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty })
                // Display artist
                let displayArtist: String

                if let explicit = explicitAlbumArtist {
                    displayArtist = explicit
                } else {
                    // Artist occurrences
                    var artistOccurrences: [String: Int] = [:]
                    for track in clusterTracks {
                        // Parsed
                        let parsed = ArtistParser.parseArtists(from: track.artist)
                        for a in parsed {
                            // Clean
                            let clean = a.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                artistOccurrences[clean, default: 0] += 1
                            }
                        }
                    }

                    // Total count
                    let totalCount = clusterTracks.count
                    // Dominant artists
                    let dominantArtists = artistOccurrences.filter { _, count in
                        if totalCount <= 2 { return count >= 1 }
                        return Double(count) / Double(totalCount) >= 0.35
                    }.sorted { $0.value > $1.value }

                    if dominantArtists.count == 1 {
                        displayArtist = dominantArtists[0].key
                    } else if dominantArtists.count == 2 {
                        displayArtist = "\(dominantArtists[0].key) & \(dominantArtists[1].key)"
                    } else if dominantArtists.count > 2 && totalCount > 4 {
                        if let top = dominantArtists.first, Double(top.value) / Double(totalCount) >= 0.50 {
                            displayArtist = top.key
                        } else {
                            displayArtist = "Various Artists"
                        }
                    } else {
                        displayArtist = dominantArtists.first?.key ?? first.artist
                    }
                }

                // Propagate artwork consensus across album tracks
                let albumArtworkKey = clusterTracks.compactMap({ $0.artworkKey }).first(where: { !$0.isEmpty })

                // Sort and deduplicate tracks within the album
                var seenTrackIDs = Set<UUID>()
                // Unique cluster tracks
                var uniqueClusterTracks: [Track] = []
                for t in clusterTracks {
                    if !seenTrackIDs.contains(t.id) {
                        seenTrackIDs.insert(t.id)
                        uniqueClusterTracks.append(t)
                    }
                }

                // Sorted album tracks
                let sortedAlbumTracks = uniqueClusterTracks.sorted { t1, t2 in
                    // D 1
                    let d1 = t1.discNumber ?? 1
                    // D 2
                    let d2 = t2.discNumber ?? 1
                    if d1 != d2 { return d1 < d2 }

                    // N 1
                    let n1 = t1.trackNumber ?? 0
                    // N 2
                    let n2 = t2.trackNumber ?? 0
                    if n1 > 0 && n2 > 0 && n1 != n2 {
                        return n1 < n2
                    }
                    if n1 > 0 && n2 == 0 { return true }
                    if n1 == 0 && n2 > 0 { return false }

                    return t1.title.localizedCaseInsensitiveCompare(t2.title) == .orderedAscending
                }

                // Determine release year from track consensus
                let trackYears = uniqueClusterTracks.compactMap { $0.year }.filter { $0 > 0 }
                // Year frequencies
                let yearFrequencies = Dictionary(grouping: trackYears, by: { $0 }).mapValues { $0.count }
                // Consensus year
                let consensusYear: Int? = {
                    if let mostFrequent = yearFrequencies.max(by: { $0.value < $1.value }) {
                        return mostFrequent.key
                    }
                    return uniqueClusterTracks.compactMap({ $0.year }).first(where: { $0 > 0 }) ?? first.year
                }()

                // Album title
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
        }

        // Deduplicate any colliding album IDs to guarantee 100% unique IDs
        var uniqueAlbums: [Album] = []
        // Unique identifier for seen album i ds
        var seenAlbumIDs = Set<String>()
        for album in newAlbums {
            if !seenAlbumIDs.contains(album.id) {
                seenAlbumIDs.insert(album.id)
                uniqueAlbums.append(album)
            }
        }

        self.albums = uniqueAlbums.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        // 2. Multi-Artist & Title Feature Extraction (with Joined Artists support)
        var artistTracksMap: [String: (displayName: String, tracks: [Track])] = [:]

        for track in tracks {
            // Track raw artist
            let trackRawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            // Track canonical
            let trackCanonical = trackRawArtist.lowercased()
            // Album raw artist
            let albumRawArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Album canonical
            let albumCanonical = albumRawArtist.lowercased()

            // Determine if this track or its album matches any active joined artist rule
            var matchedJoinedArtist: String? = nil
            for joinedRule in settings.joinedArtists {
                // Joined canonical
                let joinedCanonical = joinedRule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trackCanonical == joinedCanonical || albumCanonical == joinedCanonical {
                    matchedJoinedArtist = joinedRule
                    break
                }
                // Joined parts
                let joinedParts = ArtistParser.parseArtists(from: joinedRule).map { $0.lowercased() }
                if joinedParts.count > 1 {
                    // Track parts
                    let trackParts = ArtistParser.parseArtists(from: trackRawArtist).map { $0.lowercased() }
                    // Album parts
                    let albumParts = ArtistParser.parseArtists(from: albumRawArtist).map { $0.lowercased() }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) || (!albumParts.isEmpty && Set(joinedParts).isSubset(of: Set(albumParts))) {
                        matchedJoinedArtist = joinedRule
                        break
                    }
                }
            }

            // All track artists
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
                // Canonical key
                let canonicalKey = artistName.lowercased()
                if var existing = artistTracksMap[canonicalKey] {
                    if !existing.tracks.contains(where: { $0.id == track.id }) {
                        existing.tracks.append(track)
                    }
                    if artistName != artistName.lowercased() && existing.displayName == existing.displayName.lowercased() {
                        existing.displayName = artistName
                    }
                    artistTracksMap[canonicalKey] = existing
                } else {
                    artistTracksMap[canonicalKey] = (displayName: artistName, tracks: [track])
                }
            }
        }

        // New artists
        var newArtists: [Artist] = []
        for (_, artistData) in artistTracksMap {
            // Artist name
            let artistName = artistData.displayName
            // Artist tracks
            let artistTracks = artistData.tracks

            // Relevant albums
            let relevantAlbums = self.albums.filter { album in
                album.tracks.contains { track in
                    artistTracks.contains { $0.id == track.id }
                }
            }

            // Primary artist name
            let artist = Artist(
                name: artistName,
                albums: relevantAlbums,
                tracks: artistTracks
            )
            newArtists.append(artist)
        }

        self.artists = newArtists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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

        // Final title
        let finalTitle = (preserveLocalTitleAndArtist && !existingTrack.title.isEmpty && !existingTrack.title.lowercased().hasPrefix("track"))
            ? existingTrack.title
            : onlineMetadata.title

        // Final artist
        let finalArtist = (preserveLocalTitleAndArtist && !existingTrack.artist.isEmpty && existingTrack.artist.lowercased() != "unknown artist")
            ? existingTrack.artist
            : onlineMetadata.artist

        // Handle Deluxe Editions: do not pull deluxe album name unless local track is from deluxe edition
        let isLocalDeluxe = DeluxeAlbumDetector.isLocalTrackFromDeluxe(localTrack: existingTrack)
        // Flag indicating if online deluxe
        let isOnlineDeluxe = DeluxeAlbumDetector.isDeluxe(text: onlineMetadata.album)
        // Effective online album
        let effectiveOnlineAlbum = (!isLocalDeluxe && isOnlineDeluxe)
            ? DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album)
            : onlineMetadata.album

        // If local track already has a valid album and online candidate is a compilation or single, preserve local album
        let isLocalAlbumValid = !existingTrack.album.isEmpty &&
                                existingTrack.album.lowercased() != "unknown album" &&
                                !existingTrack.album.lowercased().hasSuffix(" - single") &&
                                !existingTrack.album.lowercased().hasSuffix(" (single)") &&
                                existingTrack.album.lowercased() != "single"

        // Final album
        let finalAlbum: String
        if isLocalAlbumValid && (onlineMetadata.isCompilation || onlineMetadata.isSingle) {
            finalAlbum = existingTrack.album
        } else if !effectiveOnlineAlbum.isEmpty && effectiveOnlineAlbum.lowercased() != "unknown album" && (!onlineMetadata.isSingle || !isLocalAlbumValid) {
            finalAlbum = effectiveOnlineAlbum
        } else {
            finalAlbum = existingTrack.album
        }

        // Final artwork key
        var finalArtworkKey = existingTrack.artworkKey
        if let art = artworkData, !art.isEmpty {
            // Key
            let key = "\(finalArtist)_\(finalAlbum)".lowercased()
            await ArtworkCacheService.shared.saveArtwork(data: art, key: key)
            finalArtworkKey = key
        // File path location
        } else if let artURL = onlineMetadata.artworkURL {
            // Key
            let key = "\(finalArtist)_\(finalAlbum)".lowercased()
            if let downloaded = await MusicMetadataService.shared.downloadArtworkData(from: artURL) {
                await ArtworkCacheService.shared.saveArtwork(data: downloaded, key: key)
                finalArtworkKey = key
            }
        }

        // Fallback transfer: preserve local tags when online values are missing or zero
        let finalYear = (onlineMetadata.releaseYear != nil && onlineMetadata.releaseYear! > 0)
            ? onlineMetadata.releaseYear
            : existingTrack.year

        // Final genre
        let finalGenre = existingTrack.genre

        // Track number management:
        // Always preserve local track number, unless the track is in a deluxe album:
        // Then save local track number in originalTrackNumber, create deluxeTrackNumber, and use deluxeTrackNumber for the deluxe album
        let originalTrackNumber = existingTrack.originalTrackNumber ?? existingTrack.trackNumber
        // Final original track number
        let finalOriginalTrackNumber: Int?
        // Final deluxe track number
        let finalDeluxeTrackNumber: Int?
        // Final track number
        let finalTrackNumber: Int?

        if isLocalDeluxe {
            finalOriginalTrackNumber = originalTrackNumber
            finalDeluxeTrackNumber = onlineMetadata.trackNumber ?? existingTrack.trackNumber
            finalTrackNumber = finalDeluxeTrackNumber
        } else {
            finalOriginalTrackNumber = originalTrackNumber
            finalDeluxeTrackNumber = existingTrack.deluxeTrackNumber
            finalTrackNumber = existingTrack.trackNumber ?? onlineMetadata.trackNumber
        }

        // Final total tracks
        let finalTotalTracks = (onlineMetadata.totalTracks != nil && onlineMetadata.totalTracks! > 0)
            ? onlineMetadata.totalTracks
            : existingTrack.totalTracks

        // Final disc number
        let finalDiscNumber = (onlineMetadata.discNumber != nil && onlineMetadata.discNumber! > 0)
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
                let albumKey = "\(finalArtist)_\(finalAlbum)".lowercased()
                if artworkURLsByAlbumKey[albumKey] == nil {
                    artworkURLsByAlbumKey[albumKey] = artURL
                }
            }
        }

        // MARK: - Step 1: Bounded Parallel Artwork Download (Up to 4 parallel downloads)
        var downloadedArtworkByKey: [String: Data] = [:]
        if !artworkURLsByAlbumKey.isEmpty {
            // Unique list
            let uniqueList = Array(artworkURLsByAlbumKey)
            // Total unique art
            let totalUniqueArt = uniqueList.count
            // Downloaded count
            var downloadedCount = 0
            onProgress?(0.05, "Step 1/3: Downloading album artwork (0/\(totalUniqueArt))...")

            // Max art workers
            let maxArtWorkers = 4
            // Art index
            var artIndex = 0

            await withTaskGroup(of: (String, Data?).self) { group in
                while artIndex < totalUniqueArt && artIndex < maxArtWorkers {
                    let (key, url) = uniqueList[artIndex]
                    artIndex += 1
                    group.addTask {
                        // Data
                        let data = await MusicMetadataService.shared.downloadArtworkData(from: url)
                        return (key, data)
                    }
                }

                for await (key, data) in group {
                    if let data = data, !data.isEmpty {
                        downloadedArtworkByKey[key] = data
                        await ArtworkCacheService.shared.saveArtwork(data: data, key: key)
                    }
                    downloadedCount += 1
                    // P
                    let p = 0.05 + (Double(downloadedCount) / Double(max(1, totalUniqueArt))) * 0.30
                    onProgress?(p, "Downloading artwork (\(downloadedCount)/\(totalUniqueArt))...")

                    if artIndex < totalUniqueArt {
                        let (nextKey, nextUrl) = uniqueList[artIndex]
                        artIndex += 1
                        group.addTask {
                            // Next data
                            let nextData = await MusicMetadataService.shared.downloadArtworkData(from: nextUrl)
                            return (nextKey, nextData)
                        }
                    }
                }
            }
        } else {
            onProgress?(0.35, "Artwork verification complete.")
        }

        // MARK: - Step 2: Single-Pass In-Memory Track Mutation with Smooth Progress Yielding
        var enrichedCount = 0
        // Serial queue for file tagging queue
        var fileTaggingQueue: [(url: URL, track: Track, artData: Data?)] = []
        // Unique identifier for processed track i ds
        var processedTrackIDs = Set<UUID>()
        // New verified good
        var newVerifiedGood: [MetadataDiff] = []

        // Track index map
        var trackIndexMap: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackIndexMap[t.id] = i
        }

        for (idx, diff) in diffs.enumerated() {
            // Ensure preconditions are met before proceeding
            guard let trackIndex = trackIndexMap[diff.localTrack.id], trackIndex < tracks.count else { continue }
            // Existing track
            let existingTrack = tracks[trackIndex]
            // Online metadata
            let onlineMetadata = diff.onlineMetadata

            // Final title
            let finalTitle = (preserveLocalTitleAndArtist && !existingTrack.title.isEmpty && !existingTrack.title.lowercased().hasPrefix("track"))
                ? existingTrack.title
                : onlineMetadata.title

            // Final artist
            let finalArtist = (preserveLocalTitleAndArtist && !existingTrack.artist.isEmpty && existingTrack.artist.lowercased() != "unknown artist")
                ? existingTrack.artist
                : onlineMetadata.artist

            // Flag indicating if local deluxe
            let isLocalDeluxe = DeluxeAlbumDetector.isLocalTrackFromDeluxe(localTrack: existingTrack)
            // Flag indicating if online deluxe
            let isOnlineDeluxe = DeluxeAlbumDetector.isDeluxe(text: onlineMetadata.album)
            // Effective online
            let effectiveOnline = (!isLocalDeluxe && isOnlineDeluxe)
                ? DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album)
                : onlineMetadata.album

            // Flag indicating if local album valid
            let isLocalAlbumValid = !existingTrack.album.isEmpty &&
                                    existingTrack.album.lowercased() != "unknown album" &&
                                    !existingTrack.album.lowercased().hasSuffix(" - single") &&
                                    !existingTrack.album.lowercased().hasSuffix(" (single)") &&
                                    existingTrack.album.lowercased() != "single"

            // Final album
            let finalAlbum: String
            if isLocalAlbumValid && (onlineMetadata.isCompilation || onlineMetadata.isSingle) {
                finalAlbum = existingTrack.album
            } else if !effectiveOnline.isEmpty && effectiveOnline.lowercased() != "unknown album" && (!onlineMetadata.isSingle || !isLocalAlbumValid) {
                finalAlbum = effectiveOnline
            } else {
                finalAlbum = existingTrack.album
            }

            // Album key
            let albumKey = "\(finalArtist)_\(finalAlbum)".lowercased()
            // Art data
            let artData = downloadedArtworkByKey[albumKey]
            // Final artwork key
            var finalArtworkKey = existingTrack.artworkKey
            if artData != nil {
                finalArtworkKey = albumKey
            }

            // Final year
            let finalYear = (onlineMetadata.releaseYear != nil && onlineMetadata.releaseYear! > 0)
                ? onlineMetadata.releaseYear
                : existingTrack.year

            // Final genre
            let finalGenre: String?
            if let g = onlineMetadata.genre, !g.isEmpty && g != "Unknown Genre" {
                finalGenre = g
            } else if let localG = existingTrack.genre, !localG.isEmpty && localG != "Unknown Genre" {
                finalGenre = localG
            } else {
                finalGenre = existingTrack.genre
            }

            // Track number management:
            // Always preserve local track number, unless track is in a deluxe album:
            // Then save local track number in originalTrackNumber, create deluxeTrackNumber, and use deluxeTrackNumber here
            let originalTrackNumber = existingTrack.originalTrackNumber ?? existingTrack.trackNumber
            // Final original track number
            let finalOriginalTrackNumber: Int?
            // Final deluxe track number
            let finalDeluxeTrackNumber: Int?
            // Final track number
            let finalTrackNumber: Int?

            if isLocalDeluxe {
                finalOriginalTrackNumber = originalTrackNumber
                finalDeluxeTrackNumber = onlineMetadata.trackNumber ?? existingTrack.trackNumber
                finalTrackNumber = finalDeluxeTrackNumber
            } else {
                finalOriginalTrackNumber = originalTrackNumber
                finalDeluxeTrackNumber = existingTrack.deluxeTrackNumber
                finalTrackNumber = existingTrack.trackNumber ?? onlineMetadata.trackNumber
            }

            // Final total tracks
            let finalTotalTracks = (onlineMetadata.totalTracks != nil && onlineMetadata.totalTracks! > 0)
                ? onlineMetadata.totalTracks
                : existingTrack.totalTracks

            // Final disc number
            let finalDiscNumber = (onlineMetadata.discNumber != nil && onlineMetadata.discNumber! > 0)
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

            tracks[trackIndex] = updatedTrack
            processedTrackIDs.insert(diff.localTrack.id)
            enrichedCount += 1
            fileTaggingQueue.append((url: existingTrack.url, track: updatedTrack, artData: artData))

            // Permanently cache downloaded online metadata and applied state
            self.cacheDownloadedMetadata(
                track: updatedTrack,
                onlineMetadata: onlineMetadata,
                artworkKey: finalArtworkKey,
                wasApplied: true
            )

            // Updated diff
            let updatedDiff = MetadataDiff(
                localTrack: updatedTrack,
                onlineMetadata: onlineMetadata,
                preserveLocalTitleAndArtist: preserveLocalTitleAndArtist
            )
            newVerifiedGood.append(updatedDiff)

            // Progress val
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

        // MARK: - Step 2.5: Lossless Audio File Tag Writing with Bounded Worker Pool & NSFileCoordinator
        if settings.writeMetadataToAudioFiles && !fileTaggingQueue.isEmpty {
            // Tagging total
            let taggingTotal = fileTaggingQueue.count
            // Tagging done
            var taggingDone = 0
            onProgress?(0.75, "Step 3/3: Embedding tags into audio files on disk (0/\(taggingTotal))...")

            // Max tag workers
            let maxTagWorkers = 4
            // Queue index
            var queueIndex = 0

            await withTaskGroup(of: Void.self) { group in
                while queueIndex < taggingTotal && queueIndex < maxTagWorkers {
                    // Item
                    let item = fileTaggingQueue[queueIndex]
                    queueIndex += 1
                    group.addTask {
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
                            artworkData: item.artData
                        )
                    }
                }

                for await _ in group {
                    taggingDone += 1
                    // P
                    let p = 0.75 + (Double(taggingDone) / Double(max(1, taggingTotal))) * 0.15
                    // Active track name
                    let activeTrackName = taggingDone <= fileTaggingQueue.count ? fileTaggingQueue[taggingDone - 1].track.title : ""
                    onProgress?(p, "Writing audio tags (\(taggingDone)/\(taggingTotal)): \(activeTrackName)")

                    if queueIndex < taggingTotal {
                        // Next item
                        let nextItem = fileTaggingQueue[queueIndex]
                        queueIndex += 1
                        group.addTask {
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
                                artworkData: nextItem.artData
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

        // MARK: - Step 4: Verification & Resource Cleanup
        onProgress?(0.99, "Verifying applied changes and finalizing...")
        downloadedArtworkByKey.removeAll(keepingCapacity: false)
        fileTaggingQueue.removeAll(keepingCapacity: false)
        await MusicMetadataService.shared.clearCache()

        AppLogger.metadata.info("[Enrichment Complete] Successfully enriched \(enrichedCount) tracks with verified online metadata.")
        onProgress?(1.0, "Enrichment complete! Successfully enriched \(enrichedCount) tracks.")
        return enrichedCount
    }

    /// Checks metadata for all tracks in a specific album and returns their side-by-side diffs.
    public func checkMetadataForAlbum(album: Album) async -> [MetadataDiff] {
        // Catalog songs
        let catalogSongs = await MusicMetadataService.shared.searchAlbumSongs(
            album: album.title,
            artist: album.artist
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
            } else if let single = await MusicMetadataService.shared.findExactMatch(for: local) {
                // Diff
                let diff = MetadataDiff(localTrack: local, onlineMetadata: single, preserveLocalTitleAndArtist: true)
                diffs.append(diff)
            }
        }
        return diffs
    }

    /// Finds local tracks matching an online album and generates side-by-side enrichment diffs.
    public func checkMetadataForOnlineAlbum(title: String, artist: String) async -> [MetadataDiff] {
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
            artist: artist
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
            } else if let single = await MusicMetadataService.shared.findExactMatch(for: local) {
                // Diff
                let diff = MetadataDiff(localTrack: local, onlineMetadata: single, preserveLocalTitleAndArtist: true)
                diffs.append(diff)
            }
        }
        return diffs
    }


    /// Launches an isolated background metadata scan off the main thread.
    public func startBackgroundMetadataScan(forceRecheck: Bool = false) {
        // Ensure preconditions are met before proceeding
        guard !isBackgroundCheckingMetadata else { return }
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }

        isBackgroundCheckingMetadata = true
        backgroundCheckProgress = 0.0
        backgroundCheckStatusText = "Initializing metadata scan..."

        if forceRecheck {
            self.enrichmentDiffs.removeAll()
            self.verifiedGoodDiffs.removeAll()
            self.unmatchedTrackIDs.removeAll()
        }

        // Tracks to scan
        let tracksToScan = self.tracks
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
                        // Ensure preconditions are met before proceeding
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
                        // Ensure preconditions are met before proceeding
                        guard let self = self else { return }
                        self.enrichmentDiffs = result.enrichmentDiffs
                        self.verifiedGoodDiffs = result.verifiedGoodDiffs
                        self.unmatchedTrackIDs = result.unmatchedTrackIDs
                        self.isBackgroundCheckingMetadata = false
                        self.backgroundCheckProgress = 1.0
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

    /// Re-checks all verified good tracks.
    public func recheckAllVerifiedGoodTracks() {
        // Tracks to recheck
        let tracksToRecheck = verifiedGoodDiffs.map { $0.localTrack }
        self.verifiedGoodDiffs.removeAll()
        saveEnrichmentCache()
        for track in tracksToRecheck {
            Task {
                _ = await recheckVerifiedGoodTrack(track)
            }
        }
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

    /// Re-checks all currently unmatched / ignored tracks.
    public func recheckAllUnmatchedTracks() {
        // Ensure preconditions are met before proceeding
        guard !unmatchedTrackIDs.isEmpty else { return }
        self.unmatchedTrackIDs.removeAll()
        saveEnrichmentCache()
        startBackgroundMetadataScan(forceRecheck: false)
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

    // Save downloaded metadata cache
    public func saveDownloadedMetadataCache() {
        do {
            let data = try JSONEncoder().encode(downloadedMetadataCache)
            try data.write(to: downloadedMetadataCacheFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save downloaded metadata cache: \(error.localizedDescription)")
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
        try? fileManager.removeItem(at: downloadedMetadataCacheFileURL)
        Task {
            await ArtworkCacheService.shared.clearCache()
        }
        AppLogger.storage.info("Manually cleared downloaded metadata and artwork cache.")
    }

    /// Stores a downloaded online track metadata record across multiple lookup indices.
    public func cacheDownloadedMetadata(
        track: Track,
        onlineMetadata: OnlineTrackMetadata,
        artworkKey: String? = nil,
        wasApplied: Bool = false
    ) {
        let sig = computeTrackSignature(artist: track.artist, title: track.title, duration: track.duration)
        let fileSig = computeFileSignature(fileName: track.url.lastPathComponent, size: track.fileInfo?.fileSizeBytes ?? 0)
        let path = track.url.standardizedFileURL.path

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

        saveDownloadedMetadataCache()
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
        var existingDiffMap = Dictionary(uniqueKeysWithValues: enrichmentDiffs.map { ($0.localTrack.id, $0) })
        for d in newDiffs {
            existingDiffMap[d.localTrack.id] = d
        }
        self.enrichmentDiffs = Array(existingDiffMap.values)

        var existingGoodMap = Dictionary(uniqueKeysWithValues: verifiedGoodDiffs.map { ($0.localTrack.id, $0) })
        for g in newVerified {
            existingGoodMap[g.localTrack.id] = g
        }
        self.verifiedGoodDiffs = Array(existingGoodMap.values)

        saveEnrichmentCache()
        AppLogger.storage.info("Reattached cached metadata to \(reattachedCount) tracks.")
        return reattachedCount
    }

    // Save enrichment cache
    public func saveEnrichmentCache() {
        do {
            // Diff data
            let diffData = try JSONEncoder().encode(enrichmentDiffs)
            try diffData.write(to: enrichmentFileURL, options: .atomic)

            // Good data
            let goodData = try JSONEncoder().encode(verifiedGoodDiffs)
            try goodData.write(to: verifiedGoodFileURL, options: .atomic)

            // Unmatched data
            let unmatchedData = try JSONEncoder().encode(Array(unmatchedTrackIDs))
            try unmatchedData.write(to: unmatchedFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save enrichment cache: \(error.localizedDescription)")
        }
    }

    // Save duplicates
    public func saveDuplicates() {
        do {
            // Data
            let data = try JSONEncoder().encode(duplicateGroups)
            try data.write(to: duplicatesFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save duplicates: \(error.localizedDescription)")
        }
    }

    // Save settings
    public func saveSettings() {
        do {
            // Data
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    // Save library
    public func saveLibrary() {
        do {
            // Data
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: libraryFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save library tracks: \(error.localizedDescription)")
        }
    }

    // Save playlists
    public func savePlaylists() {
        do {
            // Data
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: playlistsFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save playlists: \(error.localizedDescription)")
        }
    }

    // Save play counts
    public func savePlayCounts() {
        do {
            // String keyed
            let stringKeyed = Dictionary(uniqueKeysWithValues: playCounts.map { ($0.key.uuidString, $0.value) })
            // Data
            let data = try JSONEncoder().encode(stringKeyed)
            try data.write(to: playCountsFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save play counts: \(error.localizedDescription)")
        }
    }

    // Save pins
    public func savePins() {
        do {
            // Data
            let data = try JSONEncoder().encode(pinnedItemIDs)
            try data.write(to: pinsFileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to save pins: \(error.localizedDescription)")
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
            self.playCounts = Dictionary(uniqueKeysWithValues: loadedCounts.compactMap { key, val in
                UUID(uuidString: key).map { ($0, val) }
            })
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
