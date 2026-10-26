import Foundation
import Security
import os

// MARK: - ServerCredentials

/// Secrets for one server source. Stored as a single Keychain item per source ID.
/// Extensible per provider (e.g. Subsonic apiKey/password, Plex account + server tokens) without schema churn.
nonisolated public struct ServerCredentials: Codable, Sendable, Equatable {
    /// Bearer/session token (Jellyfin access token, Plex server access token).
    public var token: String?
    /// Subsonic: OpenSubsonic API key (preferred when the server advertises apiKeyAuthentication).
    public var apiKey: String?
    /// Subsonic: password for token+salt auth (the protocol requires the client to know it).
    public var password: String?
    /// Subsonic: server rejected token auth (error 41) — use hex-encoded password auth.
    public var useLegacyPasswordAuth: Bool?
    /// Plex: plex.tv account token and when it was issued (JWT tokens expire after 7 days).
    public var accountToken: String?
    public var accountTokenIssuedAt: Date?
    public var accountTokenIsJWT: Bool?

    public init(
        token: String? = nil,
        apiKey: String? = nil,
        password: String? = nil,
        useLegacyPasswordAuth: Bool? = nil,
        accountToken: String? = nil,
        accountTokenIssuedAt: Date? = nil,
        accountTokenIsJWT: Bool? = nil
    ) {
        self.token = token
        self.apiKey = apiKey
        self.password = password
        self.useLegacyPasswordAuth = useLegacyPasswordAuth
        self.accountToken = accountToken
        self.accountTokenIssuedAt = accountTokenIssuedAt
        self.accountTokenIsJWT = accountTokenIsJWT
    }
}

// MARK: - ServerCredentialStore

/// Keychain-backed credential storage keyed by source ID (one generic-password item per linked server).
/// Replaces the legacy Jellyfin keychain (keyed by serverId_userId) and migrates its entries on first read.
nonisolated public enum ServerCredentialStore {
    private static let service = "com.musicplayer.server"
    private static let legacyJellyfinService = "com.musicplayer.jellyfin"

    /// In-memory copy of each source's credentials, keyed by source ID. The Keychain stays the source of truth:
    /// only successful reads/saves populate it, and every write path (save, move, delete) updates or clears it,
    /// so URL building (stream, prewarm, getCoverArt) doesn't hit the Keychain per request.
    private static let cache = OSAllocatedUnfairLock<[UUID: ServerCredentials]>(initialState: [:])

    private static func cached(_ id: UUID) -> ServerCredentials? {
        cache.withLock { $0[id] }
    }

    private static func setCached(_ credentials: ServerCredentials?, for id: UUID) {
        cache.withLock { $0[id] = credentials }
    }

    /// Loads credentials for the given sources into the in-memory cache. Call off the main thread.
    public static func warm(_ links: [ServerSourceLink]) {
        for link in links { _ = credentials(for: link) }
    }

    /// Stable per-install device identifier shared by all providers
    /// (Jellyfin DeviceId, future Plex X-Plex-Client-Identifier). Key unchanged so existing Jellyfin sessions stay valid.
    public static var stableDeviceId: String {
        let key = "jellyfin_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    // MARK: Public API

    /// Returns the access token for a source, migrating a legacy Jellyfin keychain entry if needed.
    public static func token(for link: ServerSourceLink) -> String? {
        credentials(for: link)?.token
    }

    /// Returns stored credentials for a source, migrating a legacy Jellyfin keychain entry if needed.
    public static func credentials(for link: ServerSourceLink) -> ServerCredentials? {
        if let hit = cached(link.id) {
            return hit
        }
        if let stored = read(account: link.id.uuidString) {
            setCached(stored, for: link.id)
            return stored
        }
        return migrateLegacyJellyfinToken(for: link)
    }

    @discardableResult
    public static func saveToken(_ token: String, for sourceID: UUID) -> Bool {
        save(ServerCredentials(token: token), for: sourceID)
    }

    @discardableResult
    public static func save(_ credentials: ServerCredentials, for sourceID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let account = sourceID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            setCached(credentials, for: sourceID)
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            setCached(nil, for: sourceID)
            return false
        }
        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let added = SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        setCached(added ? credentials : nil, for: sourceID)
        return added
    }

    /// Moves credentials saved under a provisional source ID onto an existing source (re-sign-in to a linked server).
    public static func moveCredentials(from oldID: UUID, to newID: UUID) {
        guard oldID != newID, let creds = read(account: oldID.uuidString) else { return }
        if save(creds, for: newID) {
            setCached(nil, for: oldID)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: oldID.uuidString
            ] as CFDictionary)
        }
    }

    /// Removes the source's credentials (and any un-migrated legacy Jellyfin entry).
    @discardableResult
    public static func deleteCredentials(for link: ServerSourceLink) -> Bool {
        setCached(nil, for: link.id)
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: link.id.uuidString
        ] as CFDictionary)
        if link.kind == .jellyfin {
            deleteLegacy(account: legacyAccount(for: link))
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Raw secrets (non-source items, e.g. the Plex device signing key)

    public static func secretData(account: String) -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    @discardableResult
    public static func setSecretData(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Private

    private static func read(account: String) -> ServerCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    private static func legacyAccount(for link: ServerSourceLink) -> String {
        "\(link.serverId)_\(link.userId)"
    }

    /// Copies a pre-multi-server Jellyfin token into the per-source item, verifies the read-back,
    /// then deletes the legacy item. Returns nil if there is nothing to migrate.
    private static func migrateLegacyJellyfinToken(for link: ServerSourceLink) -> ServerCredentials? {
        guard link.kind == .jellyfin else { return nil }
        let account = legacyAccount(for: link)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyJellyfinService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }

        let credentials = ServerCredentials(token: token)
        if save(credentials, for: link.id), read(account: link.id.uuidString)?.token == token {
            deleteLegacy(account: account)
        }
        return credentials
    }

    private static func deleteLegacy(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyJellyfinService,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
