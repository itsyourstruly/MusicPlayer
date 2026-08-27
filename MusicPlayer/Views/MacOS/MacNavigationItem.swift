//
//  MacNavigationItem.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import Foundation

/// Navigation destinations selectable in the macOS sidebar.
public enum MacNavigationItem: Hashable, Identifiable, Sendable {
    case home
    case search
    case discovery
    case allTracks
    case albums
    case artists
    case duplicates
    case metadataAccuracy
    case playlist(UUID)

    public var id: String {
        switch self {
        case .home: return "home"
        case .search: return "search"
        case .discovery: return "discovery"
        case .allTracks: return "allTracks"
        case .albums: return "albums"
        case .artists: return "artists"
        case .duplicates: return "duplicates"
        case .metadataAccuracy: return "metadataAccuracy"
        case .playlist(let id): return "playlist_\(id.uuidString)"
        }
    }

    public var title: String {
        switch self {
        case .home: return "HOME"
        case .search: return "SEARCH"
        case .discovery: return "ONLINE DISCOVERY"
        case .allTracks: return "ALL SONGS"
        case .albums: return "ALBUMS"
        case .artists: return "ARTISTS"
        case .duplicates: return "DUPLICATES"
        case .metadataAccuracy: return "METADATA ACCURACY"
        case .playlist: return "PLAYLIST"
        }
    }
}
