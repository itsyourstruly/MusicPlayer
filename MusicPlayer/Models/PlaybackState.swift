import Foundation

/// Defines repeat behavior for the playback queue.
public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    // Off option
    case off
    // All option
    case all
    // One option
    case one

    /// Typographic badge/button label.
    public var label: String {
        switch self {
        case .off: return "REPEAT: OFF"
        case .all: return "REPEAT: ALL"
        case .one: return "REPEAT: ONE"
        }
    }

    /// Cycles through repeat modes sequentially.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Defines shuffle behavior for the playback queue.
public enum ShuffleMode: String, Codable, Sendable {
    // Off option
    case off
    // On option
    case on

    /// Typographic badge/button label.
    public var label: String {
        switch self {
        case .off: return "SHUFFLE: OFF"
        case .on: return "SHUFFLE: ON"
        }
    }

    /// Toggles shuffle mode.
    public var toggled: ShuffleMode {
        self == .on ? .off : .on
    }
}

/// Current state of the audio player engine.
public enum PlaybackStatus: String, Sendable {
    // Stopped option
    case stopped
    // Playing option
    case playing
    // Paused option
    case paused
    // Buffering option
    case buffering

    // Controls is playing
    public var isPlaying: Bool {
        self == .playing
    }

    public var label: String {
        switch self {
        case .stopped: return "STOPPED"
        case .playing: return "PLAYING"
        case .paused: return "PAUSED"
        case .buffering: return "BUFFERING"
        }
    }
}

/// Primary library category navigation sections.
public enum LibraryCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    // Artists option
    case artists
    // Albums option
    case albums
    // Playlists option
    case playlists
    // Tracks option
    case tracks

    // Unique track identifier
    public var id: String { rawValue }

    // Display title of the song
    public var title: String {
        switch self {
        case .artists: return "ARTISTS"
        case .albums: return "ALBUMS"
        case .playlists: return "PLAYLISTS"
        case .tracks: return "TRACKS"
        }
    }

    /// The next category in the carousel order.
    public var next: LibraryCategory {
        // All
        let all = Self.allCases
        // Ensure preconditions are met before proceeding
        guard let idx = all.firstIndex(of: self) else { return self }
        // Next idx
        let nextIdx = (idx + 1) % all.count
        return all[nextIdx]
    }

    /// The previous category in the carousel order.
    public var previous: LibraryCategory {
        // All
        let all = Self.allCases
        // Ensure preconditions are met before proceeding
        guard let idx = all.firstIndex(of: self) else { return self }
        // Prev idx
        let prevIdx = (idx - 1 + all.count) % all.count
        return all[prevIdx]
    }
}

/// Track sorting criteria for the all-tracks library view.
public enum TrackSortOption: String, CaseIterable, Identifiable, Sendable {
    // Title option
    case title
    // Artist option
    case artist
    // Album option
    case album
    // Duration option
    case duration
    // Plays option
    case plays

    // Unique track identifier
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .title: return "TITLE"
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .duration: return "DURATION"
        case .plays: return "PLAYS"
        }
    }
}

/// Artist sorting criteria for the artists library view.
public enum ArtistSortOption: String, CaseIterable, Identifiable, Sendable {
    // Name option
    case name
    // Most option
    case most

    // Unique track identifier
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: return "NAME"
        case .most: return "MOST"
        }
    }
}

/// Album sorting criteria for the albums library view.
public enum AlbumSortOption: String, CaseIterable, Identifiable, Sendable {
    // Title option
    case title
    // Most option
    case most
    // Artist option
    case artist
    // Duration option
    case duration

    // Unique track identifier
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .title: return "TITLE"
        case .most: return "MOST"
        case .artist: return "ARTIST"
        case .duration: return "DURATION"
        }
    }
}

/// Playlist sorting criteria for the playlists library view.
public enum PlaylistSortOption: String, CaseIterable, Identifiable, Sendable {
    // Name option
    case name
    // Most option
    case most

    // Unique track identifier
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: return "NAME"
        case .most: return "MOST"
        }
    }
}

/// Sorting criteria for tracks within a playlist in edit mode.
public enum PlaylistTrackSortCriteria: String, CaseIterable, Identifiable, Sendable {
    // Custom option
    case custom
    // Name option
    case name
    // Artist option
    case artist
    // Album option
    case album
    // Favorite option
    case favorite
    // Newest option
    case newest
    // Oldest option
    case oldest

    // Unique track identifier
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .custom: return "Custom"
        case .name: return "Name (A-Z)"
        case .artist: return "Artist"
        case .album: return "Album"
        case .favorite: return "Favorite (Most Plays)"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }
}
