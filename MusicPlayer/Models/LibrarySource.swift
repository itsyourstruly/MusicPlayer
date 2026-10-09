import Foundation

// MARK: - JellyfinServerLink

/// Represents a linked Jellyfin media server instance.
public struct JellyfinServerLink: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var serverId: String
    public var serverName: String
    public var userId: String
    public var userName: String
    public var serverURL: URL
    public var dateAdded: Date

    public nonisolated init(
        id: UUID = UUID(),
        serverId: String,
        serverName: String,
        userId: String,
        userName: String,
        serverURL: URL,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.userId = userId
        self.userName = userName
        self.serverURL = serverURL
        self.dateAdded = dateAdded
    }

    public var username: String { userName }
}

// MARK: - LibrarySource

/// Unified source representation for local linked folders and remote media servers.
public enum LibrarySource: Identifiable, Sendable {
    case local(LinkedFolder)
    case jellyfin(JellyfinServerLink)

    public var id: UUID {
        switch self {
        case .local(let folder):
            return folder.id
        case .jellyfin(let server):
            return server.id
        }
    }

    public var displayName: String {
        switch self {
        case .local(let folder):
            return folder.name.uppercased()
        case .jellyfin(let server):
            return server.serverName.uppercased()
        }
    }

    public var subtitle: String {
        switch self {
        case .local(let folder):
            return folder.path ?? "LOCAL FOLDER"
        case .jellyfin(let server):
            return "\(server.userName) • \(server.serverURL.host ?? server.serverURL.absoluteString)"
        }
    }
}
