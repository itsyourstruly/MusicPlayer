import Foundation

// MARK: - ServerKind

/// The media server protocol family a linked server speaks.
nonisolated public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case emby
    case subsonic
    case plex

    /// Uppercase label used in the Sources UI (e.g. "JELLYFIN - USER").
    public var displayLabel: String { rawValue.uppercased() }

    /// Stable namespace prefix for deterministic track identity.
    /// `jellyfin` MUST remain "jf" — existing libraries, downloads and playlists depend on it.
    var identityPrefix: String {
        switch self {
        case .jellyfin: return "jf"
        case .emby: return "em"
        case .subsonic: return "ss"
        case .plex: return "px"
        }
    }
}

// MARK: - ServerSourceLink

/// A linked remote media server source. `id` is the source ID: it is stored as `Track.folderID`
/// and namespaces every track ID, download and artwork key belonging to this source.
nonisolated public struct ServerSourceLink: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var kind: ServerKind
    public var serverId: String
    public var serverName: String
    public var userId: String
    public var userName: String
    public var serverURL: URL
    public var dateAdded: Date
    /// Server product reported at sign-in (e.g. "navidrome", "gonic"); drives the row label.
    public var productName: String?

    public nonisolated init(
        id: UUID = UUID(),
        kind: ServerKind = .jellyfin,
        serverId: String,
        serverName: String,
        userId: String,
        userName: String,
        serverURL: URL,
        dateAdded: Date = Date(),
        productName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.serverId = serverId
        self.serverName = serverName
        self.userId = userId
        self.userName = userName
        self.serverURL = serverURL
        self.dateAdded = dateAdded
        self.productName = productName
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, serverId, serverName, userId, userName, serverURL, dateAdded, productName
    }

    /// Links persisted before multi-server support have no `kind`; they are all Jellyfin.
    /// Decoding them with the same `id` keeps every existing track ID, download and playlist valid.
    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decodeIfPresent(ServerKind.self, forKey: .kind) ?? .jellyfin
        self.serverId = try c.decode(String.self, forKey: .serverId)
        self.serverName = try c.decode(String.self, forKey: .serverName)
        self.userId = try c.decode(String.self, forKey: .userId)
        self.userName = try c.decode(String.self, forKey: .userName)
        self.serverURL = try c.decode(URL.self, forKey: .serverURL)
        self.dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        self.productName = try c.decodeIfPresent(String.self, forKey: .productName)
    }

    public var username: String { userName }

    /// Uppercase server label for the Sources UI: the reported product (NAVIDROME, GONIC…) or the protocol (JELLYFIN, PLEX).
    public var displayLabel: String {
        if let product = productName?.trimmingCharacters(in: .whitespacesAndNewlines), !product.isEmpty {
            return product.uppercased()
        }
        return kind.displayLabel
    }
}

// MARK: - LibrarySource

/// Unified source representation for local linked folders and remote media servers.
public enum LibrarySource: Identifiable, Sendable {
    case local(LinkedFolder)
    case server(ServerSourceLink)

    public var id: UUID {
        switch self {
        case .local(let folder): return folder.id
        case .server(let server): return server.id
        }
    }

    public var displayName: String {
        switch self {
        case .local(let folder): return folder.name.uppercased()
        case .server(let server): return server.serverName.uppercased()
        }
    }

    public var subtitle: String {
        switch self {
        case .local(let folder):
            return folder.path ?? "LOCAL FOLDER"
        case .server(let server):
            return "\(server.userName) • \(server.serverURL.host ?? server.serverURL.absoluteString)"
        }
    }
}
