import Foundation
import Security

// MARK: - JellyfinKeychain

public enum JellyfinKeychain {
    private static let serviceName = "com.musicplayer.jellyfin"

    public static var stableDeviceId: String {
        let key = "jellyfin_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    public static func saveToken(_ token: String, forServerId serverId: String, userId: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let account = "\(serverId)_\(userId)"

        // Delete existing item first
        deleteToken(forServerId: serverId, userId: userId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func getToken(forServerId serverId: String, userId: String) -> String? {
        let account = "\(serverId)_\(userId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func deleteToken(forServerId serverId: String, userId: String) -> Bool {
        let account = "\(serverId)_\(userId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
