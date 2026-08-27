//
//  PlaybackState.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Defines repeat behavior for the playback queue.
public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off
    case all
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
    case off
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
    case stopped
    case playing
    case paused
    case buffering

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
    case artists
    case albums
    case playlists
    case tracks

    public var id: String { rawValue }

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
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return self }
        let nextIdx = (idx + 1) % all.count
        return all[nextIdx]
    }

    /// The previous category in the carousel order.
    public var previous: LibraryCategory {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return self }
        let prevIdx = (idx - 1 + all.count) % all.count
        return all[prevIdx]
    }
}

/// Track sorting criteria for the all-tracks library view.
public enum TrackSortOption: String, CaseIterable, Identifiable, Sendable {
    case title
    case artist
    case album
    case duration
    case plays

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
    case name
    case most

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
    case title
    case most
    case artist
    case duration

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
    case name
    case most

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
    case custom
    case name
    case artist
    case album
    case favorite
    case newest
    case oldest

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
