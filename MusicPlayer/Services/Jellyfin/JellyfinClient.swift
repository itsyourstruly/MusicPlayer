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

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "INVALID SERVER ADDRESS"
        case .authenticationFailed(let reason):
            return reason.uppercased()
        case .networkError(let reason):
            return reason.uppercased()
        case .invalidResponse:
            return "UNEXPECTED SERVER RESPONSE"
        case .localNetworkDenied:
            return "LOCAL NETWORK ACCESS IS OFF"
        }
    }
}

// MARK: - JellyfinClient

public final class JellyfinClient: Sendable {
    nonisolated public static let shared = JellyfinClient()

    /// Dedicated session with waitsForConnectivity enabled so requests don't fail while the Local Network prompt is presented.
    public static let dedicatedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// Dedicated session for library syncing with waitsForConnectivity disabled and tighter request timeouts to avoid VPN stalls.
    public static let syncSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 45
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

    public static func normalizeServerURL(_ input: String) -> URL? {
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

    public static func isTailscaleOrVPNHost(_ host: String) -> Bool {
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

    public static func isLocalHost(_ host: String) -> Bool {
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

            // Safety fallback timeout: reduced to 2.5 seconds so remote/VPN hostnames never freeze execution
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                resumeOnce(with: .success(()))
            }

            connection.start(queue: .global())
        }
    }

    // MARK: - Error Mapping

    public static func mapNetworkError(_ error: Error) -> JellyfinClientError {
        if let clientErr = error as? JellyfinClientError {
            return clientErr
        }
        if let httpErr = error as? ServerHTTPError {
            switch httpErr {
            case .status(let code): return mapHTTPStatusError(code)
            case .invalidResponse: return .invalidResponse
            }
        }

        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut:
                return .networkError("SERVER DIDN'T RESPOND")
            case .cannotConnectToHost:
                return .networkError("SERVER REFUSED THE CONNECTION, CHECK THE ADDRESS AND PORT")
            case .cannotFindHost, .dnsLookupFailed:
                return .networkError("ADDRESS NOT FOUND")
            case .notConnectedToInternet, .networkConnectionLost:
                return .networkError("NO NETWORK")
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return .networkError("CERTIFICATE ERROR - USE A VALID CERTIFICATE (E.G. LET'S ENCRYPT) OR HTTP")
            default:
                return .networkError(urlErr.localizedDescription.uppercased())
            }
        }

        return .networkError(error.localizedDescription.uppercased())
    }

    public static func mapHTTPStatusError(_ statusCode: Int) -> JellyfinClientError {
        if statusCode == 401 {
            return .authenticationFailed("HTTP 401: WRONG USERNAME OR PASSWORD")
        } else if statusCode == 404 {
            return .networkError("HTTP 404: WRONG ADDRESS")
        } else {
            return .networkError("HTTP STATUS \(statusCode)")
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
            let (_, probeResponse) = try await session.data(for: probeRequest)
            guard let http = probeResponse as? HTTPURLResponse else {
                throw JellyfinClientError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw Self.mapHTTPStatusError(http.statusCode)
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

        var authData: Data?
        var authResponse: URLResponse?
        var lastError: Error?

        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request)
                authData = data
                authResponse = response
                break
            } catch let urlErr as URLError where urlErr.code == .timedOut {
                lastError = urlErr
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
            } catch {
                lastError = error
                break
            }
        }

        guard let data = authData, let http = authResponse as? HTTPURLResponse else {
            if let err = lastError {
                throw Self.mapNetworkError(err)
            }
            throw JellyfinClientError.networkError("SERVER DIDN'T RESPOND")
        }

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
