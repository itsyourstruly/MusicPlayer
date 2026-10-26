import Foundation
import Network
#if os(iOS)
import UIKit
#endif

// MARK: - JellyfinClientError

public enum JellyfinClientError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case authenticationFailed(String)
    case networkError(String)
    case invalidResponse
    case localNetworkDenied
    /// The address could not be reached or is not a supported server (shown on the URL field).
    case unreachable(String)
    /// Jellyfin answered 401 to AuthenticateByName (wrong credentials, disabled user or remote access denied).
    case signInRejected
    /// Stored token/credentials were rejected after sign-in (revoked or expired).
    case reauthRequired
    /// The attempt was cancelled by the user or the system; never shown.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "INVALID SERVER ADDRESS"
        case .authenticationFailed(let reason):
            return reason.uppercased()
        case .networkError(let reason), .unreachable(let reason):
            return reason.uppercased()
        case .invalidResponse:
            return "UNEXPECTED SERVER RESPONSE"
        case .localNetworkDenied:
            return "LOCAL NETWORK ACCESS DENIED"
        case .signInRejected:
            return "SIGN-IN REJECTED: CHECK USERNAME/PASSWORD"
        case .reauthRequired:
            return "SIGN IN AGAIN: THE SERVER NO LONGER ACCEPTS THIS LOGIN"
        case .cancelled:
            return nil
        }
    }

    /// Secondary line for errors whose cause the server does not disclose.
    public var hint: String? {
        switch self {
        case .signInRejected: return "OR THE ACCOUNT IS DISABLED / REMOTE ACCESS IS NOT ALLOWED FOR THIS USER"
        default: return nil
        }
    }

    public enum Field: Sendable { case url, credentials }

    /// Sign-in form field the error belongs to.
    public var field: Field? {
        switch self {
        case .invalidURL, .unreachable: return .url
        case .authenticationFailed, .signInRejected: return .credentials
        default: return nil
        }
    }
}

// MARK: - JellyfinClient

public final class JellyfinClient: Sendable {
    nonisolated public static let shared = JellyfinClient()

    /// Interactive session (sign-in, ping, logout, delete): fails fast instead of waiting for connectivity.
    /// waitsForConnectivity would suspend the request timeout until a route exists, leaving only the
    /// resource timeout, so an unroutable host (VPN off, LAN address away from home) hung sign-in for minutes.
    nonisolated public static let dedicatedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// Library sync/API session: no connectivity waiting; a stalled transfer fails after 30 s without data.
    /// The resource cap still allows large paged JSON responses on slow links.
    nonisolated public static let syncSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    public init(session: URLSession = JellyfinClient.dedicatedSession) {
        self.session = session
    }

    // MARK: - Device Info & Auth Header

    nonisolated var deviceName: String {
        #if os(iOS)
        return "iPhone"
        #else
        return "Mac"
        #endif
    }

    nonisolated public func authHeader(token: String? = nil) -> String {
        var header = "MediaBrowser Client=\"MusicPlayer\", Device=\"\(deviceName)\", DeviceId=\"\(ServerCredentialStore.stableDeviceId)\", Version=\"1.0.0\""
        if let token = token, !token.isEmpty {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    // MARK: - URL Normalization & Local Host Detection

    nonisolated public static func normalizeServerURL(_ input: String) -> URL? {
        var str = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while str.hasSuffix("/") {
            str.removeLast()
        }
        guard !str.isEmpty else { return nil }

        if !str.lowercased().hasPrefix("http://") && !str.lowercased().hasPrefix("https://") {
            str = "http://" + str
        }

        guard var components = URLComponents(string: str),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // For an http URL with no port, add :8096. Keep any port the user typed.
        if components.scheme?.lowercased() == "http" && components.port == nil {
            components.port = 8096
        }

        return components.url
    }

    nonisolated public static func isTailscaleOrVPNHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix(".ts.net") || lower.hasSuffix(".tailscale.net") {
            return true
        }
        if lower.hasPrefix("fd7a:") || lower.contains(":fd7a:") {
            return true
        }
        let parts = lower.split(separator: ".")
        if parts.count == 4,
           let p0 = Int(parts[0]), let p1 = Int(parts[1]),
           p0 == 100 && (64...127).contains(p1) {
            return true
        }
        return false
    }

    nonisolated public static func isLocalHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Tailscale and VPN overlay networks do not require iOS local network permission
        if isTailscaleOrVPNHost(lower) {
            return false
        }
        if lower == "localhost" || lower.hasSuffix(".local") {
            return true
        }
        // Bare hostname without dots or colons
        if !lower.contains(".") && !lower.contains(":") {
            return true
        }
        // IPv4 private & loopback ranges
        let parts = lower.split(separator: ".")
        if parts.count == 4,
           let p0 = Int(parts[0]), let p1 = Int(parts[1]), let p2 = Int(parts[2]), let p3 = Int(parts[3]),
           (0...255).contains(p0), (0...255).contains(p1), (0...255).contains(p2), (0...255).contains(p3) {
            if p0 == 10 { return true }
            if p0 == 127 { return true }
            if p0 == 192 && p1 == 168 { return true }
            if p0 == 172 && (16...31).contains(p1) { return true }
            if p0 == 169 && p1 == 254 { return true }
            return false
        }
        // IPv6 local ranges (excluding Tailscale ULA)
        if lower.hasPrefix("fc") || (lower.hasPrefix("fd") && !lower.hasPrefix("fd7a")) || lower.hasPrefix("fe80") || lower == "::1" {
            return true
        }
        return false
    }

    // MARK: - Local Network Prompt Trigger

    public static func triggerLocalNetworkPrompt(host: String, port: Int) async throws {
        guard isLocalHost(host) else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let nwHost = NWEndpoint.Host(host)
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false

            func resumeOnce(with result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    connection.stateUpdateHandler = nil
                    #if os(iOS)
                    connection.pathUpdateHandler = nil
                    #endif
                    connection.cancel()
                    continuation.resume(with: result)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(with: .success(()))

                case .waiting:
                    #if os(iOS)
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        resumeOnce(with: .failure(JellyfinClientError.localNetworkDenied))
                        return
                    }
                    #endif

                case .failed:
                    #if os(iOS)
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        resumeOnce(with: .failure(JellyfinClientError.localNetworkDenied))
                        return
                    }
                    #endif
                    // If connection failed for reasons other than permission denial (e.g. refused port), let HTTP probe report exact cause
                    resumeOnce(with: .success(()))

                default:
                    break
                }
            }

            #if os(iOS)
            connection.pathUpdateHandler = { path in
                if path.unsatisfiedReason == .localNetworkDenied {
                    resumeOnce(with: .failure(JellyfinClientError.localNetworkDenied))
                }
            }
            #endif

            // Safety fallback: give the first-run Local Network prompt time to be answered (the caller's
            // sign-in deadline still bounds the whole attempt); an unreachable host just proceeds to HTTP.
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                resumeOnce(with: .success(()))
            }

            connection.start(queue: .global())
        }
    }

    // MARK: - Error Mapping

    nonisolated public static func mapNetworkError(_ error: Error) -> JellyfinClientError {
        if let clientErr = error as? JellyfinClientError {
            return clientErr
        }
        if error is CancellationError { return .cancelled }
        if error is ServerDeadline.Exceeded { return .unreachable("SERVER DID NOT RESPOND (TIMED OUT)") }
        if let httpErr = error as? ServerHTTPError {
            switch httpErr {
            case .status(let code): return mapHTTPStatusError(code)
            case .invalidResponse: return .invalidResponse
            case .serverStarting: return .networkError("SERVER IS STARTING UP, TRY AGAIN SHORTLY")
            }
        }
        if error is DecodingError {
            return .unreachable("NOT A SUPPORTED SERVER (CHECK ADDRESS/PATH)")
        }

        if let urlErr = error as? URLError {
            let host = urlErr.failingURL?.host ?? ""
            let vpnHint = isTailscaleOrVPNHost(host) ? " - IS TAILSCALE/VPN CONNECTED?" : ""
            switch urlErr.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .unreachable("SERVER DID NOT RESPOND (TIMED OUT)" + vpnHint)
            case .cannotConnectToHost, .networkConnectionLost:
                return .unreachable("CANNOT REACH SERVER (CHECK ADDRESS, PORT AND THAT IT IS RUNNING)" + vpnHint)
            case .cannotFindHost, .dnsLookupFailed:
                if host.lowercased().hasSuffix(".plex.direct") {
                    return .unreachable("ROUTER IS BLOCKING PLEX SECURE CONNECTIONS (DNS REBINDING)")
                }
                return .unreachable("SERVER NOT FOUND (CHECK ADDRESS)" + vpnHint)
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .networkError("NO INTERNET CONNECTION")
            case .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                return .unreachable("CERTIFICATE NOT TRUSTED - USE A VALID CERTIFICATE (E.G. LET'S ENCRYPT) OR HTTP ON YOUR LAN")
            case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
                return .unreachable("SECURE CONNECTION FAILED")
            case .appTransportSecurityRequiresSecureConnection:
                return .unreachable("INSECURE CONNECTION BLOCKED")
            case .badURL, .unsupportedURL:
                return .invalidURL
            case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
                return .unreachable("NOT A SUPPORTED SERVER (CHECK ADDRESS/PATH)")
            default:
                return .networkError("CONNECTION FAILED (\(urlErr.code.rawValue))")
            }
        }

        return .networkError("CONNECTION FAILED")
    }

    /// Maps a non-2xx status from an authenticated call. 401/498 mean the stored login is no longer valid.
    nonisolated public static func mapHTTPStatusError(_ statusCode: Int) -> JellyfinClientError {
        switch statusCode {
        case 401, 498: return .reauthRequired
        case 403: return .authenticationFailed("ACCESS DENIED BY SERVER")
        case 404: return .unreachable("NOT A SUPPORTED SERVER (CHECK ADDRESS/PATH)")
        case 429: return .networkError("SERVER BUSY, TRY AGAIN SHORTLY")
        case 502, 503, 504: return .networkError("SERVER UNAVAILABLE (PROXY ERROR \(statusCode))")
        case 500...599: return .networkError("SERVER ERROR \(statusCode)")
        default: return .networkError("UNEXPECTED SERVER RESPONSE (HTTP \(statusCode))")
        }
    }

    // MARK: - Ping / System Info

    public func ping(serverURL: URL) async throws -> (serverId: String, serverName: String) {
        let endpoint = serverURL.appendingPathComponent("System/Info")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            ServerRequestLog.log(request, caller: "jellyfinClient")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JellyfinClientError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw Self.mapHTTPStatusError(http.statusCode)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["Id"] as? String else {
                throw JellyfinClientError.invalidResponse
            }
            let name = (json["ServerName"] as? String) ?? "Jellyfin Server"
            return (serverId: id, serverName: name)
        } catch {
            throw Self.mapNetworkError(error)
        }
    }

    // MARK: - Authenticate

    /// Oldest Jellyfin release whose API this client relies on.
    nonisolated static let minimumVersion = [10, 8]

    nonisolated static func meetsMinimumVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (i, required) in minimumVersion.enumerated() {
            let have = i < parts.count ? parts[i] : 0
            if have != required { return have > required }
        }
        return true
    }

    public func authenticate(
        serverURL: URL,
        username: String,
        password: String
    ) async throws -> (token: String, userId: String, serverId: String, serverName: String) {
        // Trigger Local Network prompt and wait for .ready before sending HTTP request
        if let host = serverURL.host {
            let port = serverURL.port ?? (serverURL.scheme?.lowercased() == "https" ? 443 : 8096)
            try await Self.triggerLocalNetworkPrompt(host: host, port: port)
        }

        // Probe GET /System/Info/Public first with a 10s timeout without discarding failures
        let probeURL = serverURL.appendingPathComponent("System/Info/Public")
        var probeRequest = URLRequest(url: probeURL)
        probeRequest.httpMethod = "GET"
        probeRequest.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        probeRequest.timeoutInterval = 10

        do {
            ServerRequestLog.log(probeRequest, caller: "jellyfinClient")
            let (probeData, probeResponse) = try await session.data(for: probeRequest)
            guard let http = probeResponse as? HTTPURLResponse else {
                throw JellyfinClientError.invalidResponse
            }
            if http.statusCode == 503 && http.value(forHTTPHeaderField: "Message") != nil {
                throw ServerHTTPError.serverStarting
            }
            guard (200...299).contains(http.statusCode) else {
                throw Self.mapHTTPStatusError(http.statusCode)
            }
            guard let info = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any], info["Id"] is String else {
                throw JellyfinClientError.unreachable("NOT A JELLYFIN SERVER (CHECK ADDRESS/PATH)")
            }
            if let version = info["Version"] as? String, !Self.meetsMinimumVersion(version) {
                throw JellyfinClientError.networkError("SERVER TOO OLD (JELLYFIN \(Self.minimumVersion.map(String.init).joined(separator: ".")) OR NEWER REQUIRED)")
            }
        } catch {
            throw Self.mapNetworkError(error)
        }

        let endpoint = serverURL.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "Username": username,
            "Pw": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Single attempt: the reachability probe above just succeeded, and retrying a timed-out
        // sign-in only doubles the wait. The caller bounds the whole attempt with a deadline.
        let data: Data
        let http: HTTPURLResponse
        do {
            ServerRequestLog.log(request, caller: "jellyfinClient")
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw JellyfinClientError.invalidResponse }
            data = d
            http = h
        } catch {
            throw Self.mapNetworkError(error)
        }

        // Jellyfin 10.6+ answers 401 for wrong credentials, disabled users, remote access denied and
        // parental schedules alike, so the message covers all of them.
        if http.statusCode == 401 { throw JellyfinClientError.signInRejected }
        guard (200...299).contains(http.statusCode) else {
            throw Self.mapHTTPStatusError(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["AccessToken"] as? String,
              let userObj = json["User"] as? [String: Any],
              let userId = userObj["Id"] as? String,
              let serverId = json["ServerId"] as? String else {
            throw JellyfinClientError.invalidResponse
        }

        var serverName = "Jellyfin"
        if let sName = json["ServerName"] as? String, !sName.isEmpty {
            serverName = sName
        } else if let pingResult = try? await ping(serverURL: serverURL) {
            serverName = pingResult.serverName
        }

        return (token: token, userId: userId, serverId: serverId, serverName: serverName)
    }

    // MARK: - Logout

    public func logout(link: ServerSourceLink) async {
        guard let token = ServerCredentialStore.token(for: link) else {
            ServerCredentialStore.deleteCredentials(for: link)
            return
        }

        let endpoint = link.serverURL.appendingPathComponent("Sessions/Logout")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        ServerRequestLog.log(request, caller: "jellyfinClient")
        _ = try? await session.data(for: request)
        ServerCredentialStore.deleteCredentials(for: link)
    }

    // MARK: - Delete Item

    public func deleteItem(itemId: String, serverLink: ServerSourceLink) async throws {
        let sessionInfo = ServerSessionCache.shared.resolveSession(for: serverLink.id, servers: [serverLink])
        guard let token = sessionInfo?.token ?? ServerCredentialStore.token(for: serverLink) else {
            throw JellyfinClientError.authenticationFailed("MISSING JELLYFIN AUTH TOKEN")
        }

        let endpoint = serverLink.serverURL.appendingPathComponent("Items/\(itemId)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            ServerRequestLog.log(request, caller: "jellyfinClient")
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JellyfinClientError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw JellyfinClientError.authenticationFailed("CANNOT DELETE: PERMISSION DENIED ON JELLYFIN SERVER")
            }
            guard (200...299).contains(http.statusCode) || http.statusCode == 204 else {
                throw Self.mapHTTPStatusError(http.statusCode)
            }
        } catch let clientErr as JellyfinClientError {
            throw clientErr
        } catch {
            throw Self.mapNetworkError(error)
        }
    }
}
