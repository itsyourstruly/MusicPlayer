import Foundation

/// Navigation destinations selectable in the macOS sidebar.
public enum MacNavigationItem: Hashable, Identifiable, Sendable {
    // Home option
    case home
    // Search option
    case search
    // Discovery option
    case discovery
    // All tracks option
    case allTracks
    // Albums option
    case albums
    // Artists option
    case artists
    // Duplicates option
    case duplicates
    // Metadata accuracy option
    case metadataAccuracy
    // Playlist option
    case playlist(UUID)

    // Unique track identifier
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
        // Unique track identifier
        case .playlist(let id): return "playlist_\(id.uuidString)"
        }
    }

    // Display title of the song
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
