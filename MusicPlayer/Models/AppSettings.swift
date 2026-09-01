import SwiftUI

// MARK: - AppTheme

/// Available overall application themes customizing backgrounds, surfaces, text, and accents.
public enum AppTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    // Dark option
    case dark
    // Gray option
    case gray
    // Blue option
    case blue
    // Green option
    case green
    // Orange option
    case orange
    // Red option
    case red
    // Purple option
    case purple
    // Teal option
    case teal

    // Unique track identifier
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "DARK"
        case .gray: return "GRAY"
        case .blue: return "BLUE"
        case .green: return "GREEN"
        case .orange: return "ORANGE"
        case .red: return "RED"
        case .purple: return "PURPLE"
        case .teal: return "TEAL"
        }
    }

    // Accent drives interactive controls, progress bars, and highlighted text.
    public var accentColor: Color {
        switch self {
        case .dark: return Color(red: 0.95, green: 0.95, blue: 0.96)
        case .gray: return Color(red: 0.50, green: 0.65, blue: 0.85)
        case .blue: return Color(red: 0.25, green: 0.60, blue: 1.00)
        case .green: return Color(red: 0.25, green: 0.85, blue: 0.55)
        case .orange: return Color(red: 0.98, green: 0.60, blue: 0.20)
        case .red: return Color(red: 0.95, green: 0.30, blue: 0.45)
        case .purple: return Color(red: 0.75, green: 0.45, blue: 0.98)
        case .teal: return Color(red: 0.20, green: 0.82, blue: 0.80)
        }
    }

    // Deepest layer — used for full-screen backgrounds and modal backdrops.
    public var backgroundColor: Color {
        switch self {
        case .dark: return Color(red: 0.04, green: 0.04, blue: 0.05)
        case .gray: return Color(red: 0.08, green: 0.09, blue: 0.11)
        case .blue: return Color(red: 0.05, green: 0.07, blue: 0.14)
        case .green: return Color(red: 0.04, green: 0.09, blue: 0.06)
        case .orange: return Color(red: 0.09, green: 0.06, blue: 0.04)
        case .red: return Color(red: 0.10, green: 0.04, blue: 0.06)
        case .purple: return Color(red: 0.08, green: 0.04, blue: 0.12)
        case .teal: return Color(red: 0.04, green: 0.08, blue: 0.09)
        }
    }

    // Card/sheet surfaces sit one step above the background.
    public var secondaryBackgroundColor: Color {
        switch self {
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .gray: return Color(red: 0.14, green: 0.16, blue: 0.19)
        case .blue: return Color(red: 0.09, green: 0.13, blue: 0.24)
        case .green: return Color(red: 0.08, green: 0.16, blue: 0.11)
        case .orange: return Color(red: 0.16, green: 0.11, blue: 0.07)
        case .red: return Color(red: 0.18, green: 0.08, blue: 0.11)
        case .purple: return Color(red: 0.15, green: 0.08, blue: 0.22)
        case .teal: return Color(red: 0.08, green: 0.15, blue: 0.17)
        }
    }

    // Third elevation — inset controls, selected rows, pressed states.
    public var tertiaryBackgroundColor: Color {
        switch self {
        case .dark: return Color(red: 0.18, green: 0.18, blue: 0.20)
        case .gray: return Color(red: 0.20, green: 0.22, blue: 0.26)
        case .blue: return Color(red: 0.14, green: 0.20, blue: 0.34)
        case .green: return Color(red: 0.12, green: 0.24, blue: 0.17)
        case .orange: return Color(red: 0.24, green: 0.17, blue: 0.11)
        case .red: return Color(red: 0.26, green: 0.12, blue: 0.16)
        case .purple: return Color(red: 0.22, green: 0.12, blue: 0.32)
        case .teal: return Color(red: 0.12, green: 0.22, blue: 0.25)
        }
    }

    public var primaryTextColor: Color {
        switch self {
        case .dark: return Color(red: 0.98, green: 0.98, blue: 0.99)
        case .gray: return Color(red: 0.96, green: 0.97, blue: 0.99)
        case .blue: return Color(red: 0.94, green: 0.97, blue: 1.00)
        case .green: return Color(red: 0.94, green: 0.99, blue: 0.96)
        case .orange: return Color(red: 1.00, green: 0.97, blue: 0.94)
        case .red: return Color(red: 1.00, green: 0.95, blue: 0.96)
        case .purple: return Color(red: 0.98, green: 0.95, blue: 1.00)
        case .teal: return Color(red: 0.94, green: 0.99, blue: 1.00)
        }
    }

    // Used for subtitles, metadata labels, and secondary UI copy.
    public var secondaryTextColor: Color {
        switch self {
        case .dark: return Color(red: 0.65, green: 0.65, blue: 0.68)
        case .gray: return Color(red: 0.62, green: 0.68, blue: 0.76)
        case .blue: return Color(red: 0.58, green: 0.68, blue: 0.82)
        case .green: return Color(red: 0.58, green: 0.78, blue: 0.68)
        case .orange: return Color(red: 0.80, green: 0.68, blue: 0.58)
        case .red: return Color(red: 0.82, green: 0.62, blue: 0.68)
        case .purple: return Color(red: 0.75, green: 0.64, blue: 0.85)
        case .teal: return Color(red: 0.58, green: 0.76, blue: 0.80)
        }
    }

    // Thin horizontal rules and list dividers.
    public var separatorColor: Color {
        switch self {
        case .dark: return Color(red: 0.22, green: 0.22, blue: 0.25)
        case .gray: return Color(red: 0.24, green: 0.28, blue: 0.34)
        case .blue: return Color(red: 0.18, green: 0.25, blue: 0.40)
        case .green: return Color(red: 0.16, green: 0.30, blue: 0.22)
        case .orange: return Color(red: 0.32, green: 0.22, blue: 0.15)
        case .red: return Color(red: 0.35, green: 0.16, blue: 0.22)
        case .purple: return Color(red: 0.30, green: 0.18, blue: 0.42)
        case .teal: return Color(red: 0.16, green: 0.28, blue: 0.32)
        }
    }

    // Slightly lighter than `backgroundColor` — used when the player background style is set to `solid`.
    public var solidPlayerBackground: Color {
        switch self {
        case .dark: return Color(red: 0.08, green: 0.08, blue: 0.10)
        case .gray: return Color(red: 0.10, green: 0.12, blue: 0.15)
        case .blue: return Color(red: 0.07, green: 0.10, blue: 0.18)
        case .green: return Color(red: 0.06, green: 0.12, blue: 0.09)
        case .orange: return Color(red: 0.12, green: 0.08, blue: 0.05)
        case .red: return Color(red: 0.13, green: 0.06, blue: 0.08)
        case .purple: return Color(red: 0.11, green: 0.06, blue: 0.16)
        case .teal: return Color(red: 0.06, green: 0.11, blue: 0.13)
        }
    }

    /// Backwards compatibility accessor for color
    public var color: Color {
        accentColor
    }
}

/// Backwards compatibility alias for AccentTheme
public typealias AccentTheme = AppTheme

// MARK: - PlayerBackgroundStyle

/// Available background styling modes for the audio player cards.
public enum PlayerBackgroundStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    // Album color option
    case albumColor
    // Album blur option
    case albumBlur
    // Solid option
    case solid

    // Unique track identifier
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .albumColor: return "ALBUM COLOR"
        case .albumBlur: return "ALBUM BLUR"
        case .solid: return "SOLID"
        }
    }

    public var descriptionText: String {
        switch self {
        case .albumColor: return "Extracts dynamic dominant color tone from artwork."
        case .albumBlur: return "Renders a blurred version of the album cover artwork."
        case .solid: return "Uses the active theme's solid background color."
        }
    }
}

// MARK: - LibraryScanMethod

/// Available library scanning and organization modes.
public enum LibraryScanMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Method 1 (Default): Standard ID3 tag organization (Artist > Album > Track)
    case id3Tags = "ID3_TAGS"
    /// Method 2: Filesystem-based organization (Parent Folder (Artist) > Subfolder (Album) > Files (Tracks))
    case folderHierarchy = "FOLDER_HIERARCHY"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .id3Tags: return "STANDARD ID3 TAGS"
        case .folderHierarchy: return "FOLDER HIERARCHY"
        }
    }

    public var descriptionText: String {
        switch self {
        case .id3Tags: return "Organizes music using embedded ID3/audio tags (Artist > Album > Track)."
        case .folderHierarchy: return "Organizes music from folder structure (Artist Folder > Album Folder > Tracks)."
        }
    }
}

// MARK: - AppSettings

/// User preferences and persistent application configuration.
public struct AppSettings: Codable, Sendable {
    public var appTheme: AppTheme
    public var defaultLibraryCategory: LibraryCategory
    public var playerBackgroundStyle: PlayerBackgroundStyle
    public var libraryScanMethod: LibraryScanMethod
    public var autoPlayNext: Bool
    public var rememberPlaybackPosition: Bool
    // Minimum track length (in minutes) required to save and remember playback position
    public var rememberPlaybackPositionMinMinutes: Double
    public var showAudioSpecsInPlayer: Bool
    // Enables smooth audio crossfade between consecutive tracks
    public var isCrossfadeEnabled: Bool
    // Length of the crossfade transition in seconds
    public var crossfadeDuration: Double
    public var lastScanDate: Date?
    public var linkedFolderName: String?
    public var totalScannedFiles: Int

    public var autoHideDuplicates: Bool
    public var autoEnrichMissingArtwork: Bool
    public var writeMetadataToAudioFiles: Bool
    // Whether selecting a song maintains the active queue context
    public var playTrackInCurrentQueue: Bool
    // Play tap action immediately inserts song next in queue
    public var tapToPlayNext: Bool
    public var customShuffleTarget: ShuffleTarget
    public var joinedArtists: [String]
    // Enables micro-fade when skipping tracks to prevent audio pops
    public var smoothSkippingEnabled: Bool
    // Persistent user preference for lyrics mode display
    public var isLyricsViewPreferred: Bool

    /// Backwards compatibility property
    public var accentTheme: AppTheme {
        get { appTheme }
        set { appTheme = newValue }
    }

    // Initialize with configured properties
    public init(
        appTheme: AppTheme = .dark,
        defaultLibraryCategory: LibraryCategory = .artists,
        playerBackgroundStyle: PlayerBackgroundStyle = .albumColor,
        libraryScanMethod: LibraryScanMethod = .id3Tags,
        autoPlayNext: Bool = true,
        rememberPlaybackPosition: Bool = true,
        rememberPlaybackPositionMinMinutes: Double = 10.0,
        showAudioSpecsInPlayer: Bool = true,
        isCrossfadeEnabled: Bool = false,
        crossfadeDuration: Double = 4.0,
        lastScanDate: Date? = nil,
        linkedFolderName: String? = nil,
        totalScannedFiles: Int = 0,
        autoHideDuplicates: Bool = true,
        autoEnrichMissingArtwork: Bool = true,
        writeMetadataToAudioFiles: Bool = false,
        playTrackInCurrentQueue: Bool = false,
        tapToPlayNext: Bool = false,
        customShuffleTarget: ShuffleTarget = .all,
        joinedArtists: [String] = [],
        smoothSkippingEnabled: Bool = false,
        isLyricsViewPreferred: Bool = false
    ) {
        self.appTheme = appTheme
        self.defaultLibraryCategory = defaultLibraryCategory
        self.playerBackgroundStyle = playerBackgroundStyle
        self.libraryScanMethod = libraryScanMethod
        self.autoPlayNext = autoPlayNext
        self.rememberPlaybackPosition = rememberPlaybackPosition
        self.rememberPlaybackPositionMinMinutes = rememberPlaybackPositionMinMinutes
        self.showAudioSpecsInPlayer = showAudioSpecsInPlayer
        self.isCrossfadeEnabled = isCrossfadeEnabled
        self.crossfadeDuration = crossfadeDuration
        self.lastScanDate = lastScanDate
        self.linkedFolderName = linkedFolderName
        self.totalScannedFiles = totalScannedFiles
        self.autoHideDuplicates = autoHideDuplicates
        self.autoEnrichMissingArtwork = autoEnrichMissingArtwork
        self.writeMetadataToAudioFiles = writeMetadataToAudioFiles
        self.playTrackInCurrentQueue = playTrackInCurrentQueue
        self.tapToPlayNext = tapToPlayNext
        self.customShuffleTarget = customShuffleTarget
        self.joinedArtists = joinedArtists
        self.smoothSkippingEnabled = smoothSkippingEnabled
        self.isLyricsViewPreferred = isLyricsViewPreferred
    }

    // MARK: - Custom Codable to seamlessly decode older settings JSON
    enum CodingKeys: String, CodingKey {
        // App theme option
        case appTheme
        // Accent theme option
        case accentTheme   // Legacy key retained for backwards decoding
        // Default library category option
        case defaultLibraryCategory
        // Player background style option
        case playerBackgroundStyle
        // Library scan method option
        case libraryScanMethod
        // Auto play next option
        case autoPlayNext
        // Remember playback position option
        case rememberPlaybackPosition
        // Minimum track length in minutes to remember playback position
        case rememberPlaybackPositionMinMinutes
        // Show audio specs in player option
        case showAudioSpecsInPlayer
        // Is crossfade enabled option
        case isCrossfadeEnabled
        // Crossfade duration option
        case crossfadeDuration
        // Last scan date option
        case lastScanDate
        // Linked folder name option
        case linkedFolderName
        // Total scanned files option
        case totalScannedFiles
        // Auto hide duplicates option
        case autoHideDuplicates
        // Auto enrich missing artwork option
        case autoEnrichMissingArtwork
        // Write metadata to audio files option
        case writeMetadataToAudioFiles
        // Play track in current queue option
        case playTrackInCurrentQueue
        // Tap to play next option
        case tapToPlayNext
        // Custom shuffle target option
        case customShuffleTarget
        // Joined artists option
        case joinedArtists
        // Smooth skipping enabled option
        case smoothSkippingEnabled
        // Persistent lyrics view preference option
        case isLyricsViewPreferred
    }

    // Initialize with configured properties
    public init(from decoder: Decoder) throws {
        // Container
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Prefer the current `appTheme` key; fall back to the old `accentTheme` string and remap renamed cases.
        if let theme = try container.decodeIfPresent(AppTheme.self, forKey: .appTheme) {
            self.appTheme = theme
        } else if let oldAccent = try container.decodeIfPresent(String.self, forKey: .accentTheme) {
            switch oldAccent.lowercased() {
            case "slate": self.appTheme = .gray
            case "cobalt": self.appTheme = .blue
            case "emerald": self.appTheme = .green
            case "amber": self.appTheme = .orange
            default: self.appTheme = .dark
            }
        } else {
            self.appTheme = .dark
        }

        // All other settings use safe decodeIfPresent with sensible defaults so missing keys don't throw.
        self.defaultLibraryCategory = try container.decodeIfPresent(LibraryCategory.self, forKey: .defaultLibraryCategory) ?? .artists
        self.playerBackgroundStyle = try container.decodeIfPresent(PlayerBackgroundStyle.self, forKey: .playerBackgroundStyle) ?? .albumColor
        self.libraryScanMethod = try container.decodeIfPresent(LibraryScanMethod.self, forKey: .libraryScanMethod) ?? .id3Tags
        self.autoPlayNext = try container.decodeIfPresent(Bool.self, forKey: .autoPlayNext) ?? true
        self.rememberPlaybackPosition = try container.decodeIfPresent(Bool.self, forKey: .rememberPlaybackPosition) ?? true
        self.rememberPlaybackPositionMinMinutes = try container.decodeIfPresent(Double.self, forKey: .rememberPlaybackPositionMinMinutes) ?? 10.0
        self.showAudioSpecsInPlayer = try container.decodeIfPresent(Bool.self, forKey: .showAudioSpecsInPlayer) ?? true
        self.isCrossfadeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCrossfadeEnabled) ?? false
        self.crossfadeDuration = try container.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? 4.0
        self.lastScanDate = try container.decodeIfPresent(Date.self, forKey: .lastScanDate)
        self.linkedFolderName = try container.decodeIfPresent(String.self, forKey: .linkedFolderName)
        self.totalScannedFiles = try container.decodeIfPresent(Int.self, forKey: .totalScannedFiles) ?? 0
        self.autoHideDuplicates = try container.decodeIfPresent(Bool.self, forKey: .autoHideDuplicates) ?? true
        self.autoEnrichMissingArtwork = try container.decodeIfPresent(Bool.self, forKey: .autoEnrichMissingArtwork) ?? true
        self.writeMetadataToAudioFiles = try container.decodeIfPresent(Bool.self, forKey: .writeMetadataToAudioFiles) ?? false
        self.playTrackInCurrentQueue = try container.decodeIfPresent(Bool.self, forKey: .playTrackInCurrentQueue) ?? false
        self.tapToPlayNext = try container.decodeIfPresent(Bool.self, forKey: .tapToPlayNext) ?? false
        self.customShuffleTarget = try container.decodeIfPresent(ShuffleTarget.self, forKey: .customShuffleTarget) ?? .all
        self.joinedArtists = try container.decodeIfPresent([String].self, forKey: .joinedArtists) ?? []
        self.smoothSkippingEnabled = try container.decodeIfPresent(Bool.self, forKey: .smoothSkippingEnabled) ?? false
        self.isLyricsViewPreferred = try container.decodeIfPresent(Bool.self, forKey: .isLyricsViewPreferred) ?? false
    }

    // Encode
    public func encode(to encoder: Encoder) throws {
        // Container
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appTheme, forKey: .appTheme)
        try container.encode(defaultLibraryCategory, forKey: .defaultLibraryCategory)
        try container.encode(playerBackgroundStyle, forKey: .playerBackgroundStyle)
        try container.encode(libraryScanMethod, forKey: .libraryScanMethod)
        try container.encode(autoPlayNext, forKey: .autoPlayNext)
        try container.encode(rememberPlaybackPosition, forKey: .rememberPlaybackPosition)
        try container.encode(rememberPlaybackPositionMinMinutes, forKey: .rememberPlaybackPositionMinMinutes)
        try container.encode(showAudioSpecsInPlayer, forKey: .showAudioSpecsInPlayer)
        try container.encode(isCrossfadeEnabled, forKey: .isCrossfadeEnabled)
        try container.encode(crossfadeDuration, forKey: .crossfadeDuration)
        try container.encodeIfPresent(lastScanDate, forKey: .lastScanDate)
        try container.encodeIfPresent(linkedFolderName, forKey: .linkedFolderName)
        try container.encode(totalScannedFiles, forKey: .totalScannedFiles)
        try container.encode(autoHideDuplicates, forKey: .autoHideDuplicates)
        try container.encode(autoEnrichMissingArtwork, forKey: .autoEnrichMissingArtwork)
        try container.encode(writeMetadataToAudioFiles, forKey: .writeMetadataToAudioFiles)
        try container.encode(playTrackInCurrentQueue, forKey: .playTrackInCurrentQueue)
        try container.encode(tapToPlayNext, forKey: .tapToPlayNext)
        try container.encode(customShuffleTarget, forKey: .customShuffleTarget)
        try container.encode(joinedArtists, forKey: .joinedArtists)
        try container.encode(smoothSkippingEnabled, forKey: .smoothSkippingEnabled)
        try container.encode(isLyricsViewPreferred, forKey: .isLyricsViewPreferred)
    }
}

// MARK: - ShuffleTarget

/// Target entity for the custom Home shuffle trigger.
public enum ShuffleTarget: Codable, Equatable, Sendable {
    // All option
    case all
    case artist(name: String)
    case album(title: String, artist: String)
    case playlist(id: UUID, name: String)

    // Controls is all
    public var isAll: Bool {
        if case .all = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .all: return "ALL"
        case .artist(let name): return name.uppercased()
        // Display title of the song
        case .album(let title, _): return title.uppercased()
        case .playlist(_, let name): return name.uppercased()
        }
    }

    /// Short category label shown alongside `displayName` in the Home shuffle button.
    public var typeLabel: String {
        switch self {
        case .all: return "LIBRARY"
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .playlist: return "PLAYLIST"
        }
    }
}
