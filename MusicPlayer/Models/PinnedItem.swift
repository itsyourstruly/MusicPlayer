import Foundation

/// Type of entity that can be pinned to the Home screen.
public enum PinnedItemType: String, Codable, Sendable {
    // Playlist option
    case playlist
    // Album option
    case album
}

/// Persistent identifier for a pinned item maintaining explicit user ordering.
public struct PinnedItemIdentifier: Codable, Identifiable, Hashable, Sendable {
    // Unique track identifier
    public var id: String { "\(type.rawValue):\(targetID)" }
    // Type
    public let type: PinnedItemType
    // Unique identifier for target id
    public let targetID: String

    // Initialize with configured properties
    public init(type: PinnedItemType, targetID: String) {
        self.type = type
        self.targetID = targetID
    }
}

/// Resolved pinned item representation for rendering in the Home view PINS section.
public enum PinnedItem: Identifiable, Hashable, Sendable {
    // Playlist option
    case playlist(Playlist)
    // Album option
    case album(Album)

    // Unique track identifier
    public var id: String {
        switch self {
        case .playlist(let p): return "playlist:\(p.id.uuidString)"
        case .album(let a): return "album:\(a.id)"
        }
    }

    // Display title of the song
    public var title: String {
        switch self {
        case .playlist(let p): return p.name
        case .album(let a): return a.title
        }
    }

    public var subtitle: String {
        switch self {
        case .playlist: return "Playlist"
        case .album(let a): return a.artist
        }
    }

    // Cache lookup key for album artwork
    public var artworkKey: String? {
        switch self {
        case .playlist(let p): return p.customArtworkKey
        case .album(let a): return a.artworkKey
        }
    }

    public var typeLabel: String {
        switch self {
        case .playlist: return "PLAYLIST"
        case .album: return "ALBUM"
        }
    }
}
