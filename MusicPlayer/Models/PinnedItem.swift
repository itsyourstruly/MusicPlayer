import Foundation

/// Type of entity that can be pinned to the Home screen.
public enum PinnedItemType: String, Codable, Sendable {
    case playlist
    case album
}

/// Persistent identifier for a pinned item maintaining explicit user ordering.
public struct PinnedItemIdentifier: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(type.rawValue):\(targetID)" }
    public let type: PinnedItemType
    public let targetID: String

    public init(type: PinnedItemType, targetID: String) {
        self.type = type
        self.targetID = targetID
    }
}

/// Resolved pinned item representation for rendering in the Home view PINS section.
public enum PinnedItem: Identifiable, Hashable, Sendable {
    case playlist(Playlist)
    case album(Album)

    public var id: String {
        switch self {
        case .playlist(let p): return "playlist:\(p.id.uuidString)"
        case .album(let a): return "album:\(a.id)"
        }
    }

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
