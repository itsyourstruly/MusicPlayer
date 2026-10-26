import Foundation
import CryptoKit
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Plex client identity / headers

nonisolated enum PlexClient {
    static let accountBase = URL(string: "https://clients.plex.tv/api/v2")!
    static let product = "MusicPlayer"
    /// forwardUrl for the plex.tv auth page; ASWebAuthenticationSession intercepts this scheme.
    static let callbackScheme = "musicplayer-plex"

    static var clientIdentifier: String { ServerCredentialStore.stableDeviceId }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func headers(token: String?) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Platform": "iOS",
            "X-Plex-Platform-Version": ProcessInfo.processInfo.operatingSystemVersionString,
            "X-Plex-Device": "iPhone",
            "X-Plex-Device-Name": JellyfinClient.shared.deviceName,
            "X-Plex-Provides": "player"
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    static func request(_ url: URL, method: String = "GET", token: String?, json: [String: Any]? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    static func json(_ req: URLRequest) async throws -> Any {
        let (data, _) = try await ServerHTTPClient.data(for: req, session: JellyfinClient.syncSession)
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Device key (Ed25519, Keychain)

nonisolated enum PlexDeviceKey {
    private static let account = "plex_device_ed25519"

    static func privateKey() -> Curve25519.Signing.PrivateKey {
        if let data = ServerCredentialStore.secretData(account: account),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        _ = ServerCredentialStore.setSecretData(key.rawRepresentation, account: account)
        return key
    }

    static func keyID(for key: Curve25519.Signing.PrivateKey) -> String {
        let digest = SHA256.hash(data: key.publicKey.rawRepresentation)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func publicJWK(_ key: Curve25519.Signing.PrivateKey) -> [String: Any] {
        ["kty": "OKP", "crv": "Ed25519", "x": base64url(key.publicKey.rawRepresentation),
         "use": "sig", "alg": "EdDSA", "kid": keyID(for: key)]
    }

    /// Self-signed device JWT (aud plex.tv, iss = client identifier, 5 min lifetime).
    static func deviceJWT(extraClaims: [String: Any] = [:]) -> String? {
        let key = privateKey()
        let header: [String: Any] = ["alg": "EdDSA", "typ": "JWT", "kid": keyID(for: key)]
        let now = Int(Date().timeIntervalSince1970)
        var payload: [String: Any] = ["aud": "plex.tv", "iss": PlexClient.clientIdentifier, "iat": now, "exp": now + 300]
        for (k, v) in extraClaims { payload[k] = v }
        guard let h = try? JSONSerialization.data(withJSONObject: header),
              let p = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let signingInput = base64url(h) + "." + base64url(p)
        guard let sig = try? key.signature(for: Data(signingInput.utf8)) else { return nil }
        return signingInput + "." + base64url(sig)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Account auth (PIN + JWT, legacy fallback)

nonisolated enum PlexAccountAuth {
    struct Pin: Sendable {
        let id: Int
        let code: String
        let usesJWT: Bool
    }

    struct AccountToken: Sendable {
        let token: String
        let isJWT: Bool
    }

    struct Server: Sendable, Identifiable {
        let id: String           // machine identifier
        let name: String
        let accessToken: String
        let owned: Bool
        let connections: [PlexConnection]
    }

    /// Creates a strong PIN registering this device's Ed25519 key; silently falls back to a legacy PIN.
    static func createPin() async throws -> Pin {
        let url = PlexClient.accountBase.appendingPathComponent("pins")
        let key = PlexDeviceKey.privateKey()
        if let obj = try? await PlexClient.json(PlexClient.request(url, method: "POST", token: nil,
                                                                   json: ["strong": true, "jwk": PlexDeviceKey.publicJWK(key)])),
           let pin = parsePin(obj, usesJWT: true) {
            return pin
        }
        let obj = try await PlexClient.json(PlexClient.request(url, method: "POST", token: nil, json: ["strong": true]))
        guard let pin = parsePin(obj, usesJWT: false) else { throw JellyfinClientError.invalidResponse }
        return pin
    }

    private static func parsePin(_ obj: Any, usesJWT: Bool) -> Pin? {
        guard let d = obj as? [String: Any], let id = d["id"] as? Int, let code = d["code"] as? String else { return nil }
        return Pin(id: id, code: code, usesJWT: usesJWT)
    }

    /// plex.tv page where the user approves this device.
    static func authURL(for pin: Pin) -> URL? {
        var comps = URLComponents(string: "https://app.plex.tv/auth")!
        var frag = URLComponents()
        frag.queryItems = [
            URLQueryItem(name: "clientID", value: PlexClient.clientIdentifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: PlexClient.product),
            URLQueryItem(name: "forwardUrl", value: "\(PlexClient.callbackScheme)://auth")
        ]
        comps.fragment = "?" + (frag.percentEncodedQuery ?? "")
        return comps.url
    }

    /// One poll; returns the token once the user approved.
    static func checkPin(_ pin: Pin) async throws -> AccountToken? {
        var comps = URLComponents(url: PlexClient.accountBase.appendingPathComponent("pins/\(pin.id)"), resolvingAgainstBaseURL: false)!
        if pin.usesJWT, let jwt = PlexDeviceKey.deviceJWT() {
            comps.queryItems = [URLQueryItem(name: "deviceJWT", value: jwt)]
        }
        let obj = try await PlexClient.json(PlexClient.request(comps.url!, token: nil))
        guard let d = obj as? [String: Any], let token = d["authToken"] as? String, !token.isEmpty else { return nil }
        return AccountToken(token: token, isJWT: token.hasPrefix("eyJ"))
    }

    /// Polls until approved, cancelled, or the PIN expires (~15 min).
    static func waitForToken(_ pin: Pin) async throws -> AccountToken {
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            if let token = try? await checkPin(pin) { return token }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw JellyfinClientError.authenticationFailed("PLEX SIGN-IN TIMED OUT")
    }

    /// Exchanges a nonce-bearing device JWT for a fresh 7-day Plex JWT.
    static func refreshJWT() async throws -> String {
        let nonceObj = try await PlexClient.json(PlexClient.request(PlexClient.accountBase.appendingPathComponent("auth/nonce"), token: nil))
        guard let nonce = (nonceObj as? [String: Any])?["nonce"] as? String,
              let jwt = PlexDeviceKey.deviceJWT(extraClaims: ["nonce": nonce, "scope": "username,email,friendly_name"]) else {
            throw JellyfinClientError.invalidResponse
        }
        let obj = try await PlexClient.json(PlexClient.request(PlexClient.accountBase.appendingPathComponent("auth/token"),
                                                               method: "POST", token: nil, json: ["jwt": jwt]))
        guard let token = (obj as? [String: Any])?["auth_token"] as? String, !token.isEmpty else { throw JellyfinClientError.invalidResponse }
        return token
    }

    static func user(token: String) async throws -> (id: String, name: String) {
        let obj = try await PlexClient.json(PlexClient.request(PlexClient.accountBase.appendingPathComponent("user"), token: token))
        guard let d = obj as? [String: Any] else { throw JellyfinClientError.invalidResponse }
        let id = (d["uuid"] as? String) ?? (d["id"] as? Int).map(String.init) ?? "plex"
        let name = (d["username"] as? String) ?? (d["title"] as? String) ?? "PLEX"
        return (id, name)
    }

    static func servers(token: String) async throws -> [Server] {
        var comps = URLComponents(url: PlexClient.accountBase.appendingPathComponent("resources"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "includeHttps", value: "1"),
                            URLQueryItem(name: "includeRelay", value: "1"),
                            URLQueryItem(name: "includeIPv6", value: "1")]
        let obj = try await PlexClient.json(PlexClient.request(comps.url!, token: token))
        guard let list = obj as? [[String: Any]] else { throw JellyfinClientError.invalidResponse }
        return list.compactMap { r in
            guard let provides = r["provides"] as? String, provides.split(separator: ",").contains("server"),
                  let id = r["clientIdentifier"] as? String else { return nil }
            let raw = r["connections"] as? [[String: Any]] ?? []
            var conns = raw.compactMap { c -> PlexConnection? in
                guard let uri = (c["uri"] as? String).flatMap(URL.init(string:)) else { return nil }
                return PlexConnection(uri: uri, local: c["local"] as? Bool ?? false, relay: c["relay"] as? Bool ?? false)
            }
            // Routers with DNS rebinding protection refuse to resolve *.plex.direct to LAN addresses
            // (https://support.plex.tv/articles/206225077-how-to-use-secure-server-connections/). Unless the
            // server requires secure connections, add plain-http LAN-IP connections, tried only after https local fails.
            if (r["httpsRequired"] as? Bool) != true {
                let existing = Set(conns.map(\.uri))
                for c in raw where (c["local"] as? Bool) == true && (c["relay"] as? Bool) != true {
                    guard let address = c["address"] as? String, !address.isEmpty, !address.contains(":"),
                          let port = c["port"] as? Int,
                          let uri = URL(string: "http://\(address):\(port)"), !existing.contains(uri),
                          !conns.contains(where: { $0.uri == uri }) else { continue }
                    conns.append(PlexConnection(uri: uri, local: true, relay: false, lanHTTPFallback: true))
                }
            }
            return Server(id: id, name: r["name"] as? String ?? "Plex", accessToken: r["accessToken"] as? String ?? token,
                          owned: r["owned"] as? Bool ?? false, connections: conns)
        }
    }

    static func makeLink(server: Server, user: (id: String, name: String)) -> ServerSourceLink {
        ServerSourceLink(
            kind: .plex,
            serverId: server.id,
            serverName: server.name,
            userId: user.id,
            userName: user.name,
            serverURL: PlexConnection.ordered(server.connections).first?.uri ?? URL(string: "https://plex.tv")!
        )
    }
}

// MARK: - Connections

nonisolated struct PlexConnection: Codable, Sendable, Hashable {
    let uri: URL
    let local: Bool
    let relay: Bool
    /// Plain-http LAN-IP connection derived for DNS-rebinding-blocked networks (optional for stored lists).
    var lanHTTPFallback: Bool? = nil

    /// Preference: local secure, then local plain-http fallback, then remote direct, then relay.
    var tier: Int {
        if relay { return 3 }
        if local { return lanHTTPFallback == true ? 1 : 0 }
        return 2
    }
    static let maxTier = 3

    static func ordered(_ list: [PlexConnection]) -> [PlexConnection] {
        list.enumerated().sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }.map(\.element)
    }
}

/// Persisted connection list (non-secret) and the currently selected base URL per Plex source.
nonisolated enum PlexConnectionStore {
    private static let selected = OSAllocatedUnfairLock<[UUID: URL]>(initialState: [:])

    private static func key(_ id: UUID) -> String { "plex_connections_\(id.uuidString)" }

    static func connections(for id: UUID) -> [PlexConnection] {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return [] }
        return (try? JSONDecoder().decode([PlexConnection].self, from: data)) ?? []
    }

    static func save(_ list: [PlexConnection], for id: UUID) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key(id)) }
    }

    static func selectedBase(for id: UUID) -> URL? { selected.withLock { $0[id] } }
    static func select(_ url: URL, for id: UUID) { selected.withLock { $0[id] = url } }

    static func remove(for id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
        _ = selected.withLock { $0.removeValue(forKey: id) }
    }
}
