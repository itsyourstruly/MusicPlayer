import Foundation

/// Per-track field overrides saved when editing metadata in a specific organization mode.
public struct TrackMetadataOverride: Codable, Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        composer: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil &&
        composer == nil && genre == nil && year == nil && trackNumber == nil && discNumber == nil
    }
}

/// State specific to one organization mode (pins, recent albums, and manual track overrides).
public struct OrganizationModeState: Codable, Sendable {
    public var pinnedItemIDs: [PinnedItemIdentifier]
    public var recentAlbumIDs: [String]
    public var trackOverrides: [UUID: TrackMetadataOverride]

    public var overrides: [UUID: TrackMetadataOverride] {
        get { trackOverrides }
        set { trackOverrides = newValue }
    }

    public init(
        pinnedItemIDs: [PinnedItemIdentifier] = [],
        recentAlbumIDs: [String] = [],
        trackOverrides: [UUID: TrackMetadataOverride] = [:]
    ) {
        self.pinnedItemIDs = pinnedItemIDs
        self.recentAlbumIDs = recentAlbumIDs
        self.trackOverrides = trackOverrides
    }
}

/// Root persistent container for organization_modes.json
public struct OrganizationModesContainer: Codable, Sendable {
    public var metadataMode: OrganizationModeState
    public var folderMode: OrganizationModeState

    public init(
        metadataMode: OrganizationModeState = OrganizationModeState(),
        folderMode: OrganizationModeState = OrganizationModeState()
    ) {
        self.metadataMode = metadataMode
        self.folderMode = folderMode
    }

    public func state(for method: LibraryScanMethod) -> OrganizationModeState {
        switch method {
        case .id3Tags: return metadataMode
        case .folderHierarchy: return folderMode
        }
    }

    public mutating func setState(_ state: OrganizationModeState, for method: LibraryScanMethod) {
        switch method {
        case .id3Tags: metadataMode = state
        case .folderHierarchy: folderMode = state
        }
    }

    public mutating func update(state: OrganizationModeState, for method: LibraryScanMethod) {
        setState(state, for: method)
    }
}
