import Foundation

/// In-memory cache holding active server URLs and auth tokens per server ID.
/// Allows audio playback, artwork fetches, and downloads to dynamically resolve credentials
/// without relying on mutable tokens baked permanently into persisted library files.
nonisolated public final class ServerSessionCache: @unchecked Sendable {
    public static let shared = ServerSessionCache()

    private let lock = NSLock()
    private var sessions: [UUID: (serverURL: URL, token: String, serverId: String, userId: String)] = [:]
    private var links: [UUID: ServerSourceLink] = [:]

    private init() {}

    /// Registers or updates a session for a server link with a verified token.
    public func register(serverLink: ServerSourceLink, token: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions[serverLink.id] = (serverLink.serverURL, token, serverLink.serverId, serverLink.userId)
        links[serverLink.id] = serverLink
    }

    /// Retrieves registered server link by ID.
    public func serverLink(for serverLinkID: UUID) -> ServerSourceLink? {
        lock.lock()
        defer { lock.unlock() }
        return links[serverLinkID]
    }

    /// All registered links in memory.
    public var allLinks: [ServerSourceLink] {
        lock.lock()
        defer { lock.unlock() }
        return Array(links.values)
    }

    /// Retrieves cached server URL and token for a given server link ID.
    public func session(for serverLinkID: UUID) -> (serverURL: URL, token: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = sessions[serverLinkID] else { return nil }
        return (entry.serverURL, entry.token)
    }

    /// Resolves a session for a server link ID, reloading from Keychain if missing.
    public func resolveSession(for serverLinkID: UUID, servers: [ServerSourceLink]) -> (serverURL: URL, token: String)? {
        if let existing = session(for: serverLinkID) {
            return existing
        }
        guard let link = servers.first(where: { $0.id == serverLinkID }) else { return nil }
        if let token = ServerCredentialStore.token(for: link) {
            register(serverLink: link, token: token)
            return (link.serverURL, token)
        }
        return nil
    }

    /// Refreshes the token from Keychain for a server link ID (e.g. after a 401 response).
    @discardableResult
    public func refreshToken(for serverLinkID: UUID, servers: [ServerSourceLink]) -> String? {
        guard let link = servers.first(where: { $0.id == serverLinkID }) else { return nil }
        if let token = ServerCredentialStore.token(for: link) {
            register(serverLink: link, token: token)
            return token
        }
        return nil
    }

    /// Removes a session from the in-memory cache upon server unlink or logout.
    public func removeSession(for serverLinkID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: serverLinkID)
        links.removeValue(forKey: serverLinkID)
    }
}
