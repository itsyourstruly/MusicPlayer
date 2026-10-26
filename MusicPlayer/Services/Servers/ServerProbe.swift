import Foundation

/// Auto-detects the server type behind a URL by probing Jellyfin, Subsonic and Plex endpoints in parallel.
nonisolated enum ServerProbe {
    struct Detection: Sendable {
        let kind: ServerKind
        let baseURL: URL
        /// Product name reported by the server (e.g. "navidrome", "Jellyfin Server", "Emby Server").
        let product: String?
        /// Subsonic: server advertises OpenSubsonic apiKeyAuthentication.
        let supportsAPIKey: Bool
    }

    /// Default ports tried for a plain-http address without a port (Jellyfin, Navidrome, Gonic, Plex, 80).
    static let candidatePorts = [8096, 4533, 4747, 32400, 80]
    static let timeout: TimeInterval = 4

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Candidate base URLs for user input. Explicit scheme: used as typed (http adds the default ports when no
    /// port is given). No scheme: LAN/Tailscale hosts get http (default ports unless one is typed); public hosts
    /// get https only, since plain http to the internet is never chosen automatically.
    static func candidates(for input: String) -> [URL] {
        var str = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while str.hasSuffix("/") { str.removeLast() }
        for suffix in ["/rest", "/web/index.html", "/web"] where str.lowercased().hasSuffix(suffix) {
            str = String(str.dropLast(suffix.count))
        }
        guard !str.isEmpty else { return [] }
        let hasScheme = str.lowercased().hasPrefix("http://") || str.lowercased().hasPrefix("https://")
        if !hasScheme {
            let hostPart = String(str.split(separator: "/", maxSplits: 1).first ?? "")
            let bareHost = hostPart.hasPrefix("[") ? hostPart : String(hostPart.split(separator: ":").first ?? "")
            let host = bareHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let privateHost = JellyfinClient.isLocalHost(host) || JellyfinClient.isTailscaleOrVPNHost(host)
            str = (privateHost ? "http://" : "https://") + str
        }
        guard var comps = URLComponents(string: str), let host = comps.host, !host.isEmpty else { return [] }
        comps.user = nil
        comps.password = nil
        if let port = comps.port, !(1...65535).contains(port) { return [] }
        if comps.port != nil || comps.scheme?.lowercased() == "https" {
            return comps.url.map { [$0] } ?? []
        }
        return candidatePorts.compactMap { port in
            comps.port = port == 80 ? nil : port
            return comps.url
        }
    }

    /// Probes every candidate for every (or only the requested) kind and returns the best match:
    /// Jellyfin/Emby, then Subsonic, then Plex; within a kind the first candidate port wins.
    /// Throws only `JellyfinClientError.localNetworkDenied` (a probe failure is otherwise "not detected").
    static func detect(input: String, only kind: ServerKind? = nil) async throws -> Detection? {
        let urls = candidates(for: input)
        guard !urls.isEmpty else { return nil }
        if let first = urls.first, let host = first.host {
            do {
                try await JellyfinClient.triggerLocalNetworkPrompt(host: host, port: first.port ?? 80)
            } catch JellyfinClientError.localNetworkDenied {
                throw JellyfinClientError.localNetworkDenied
            } catch {}
        }
        let results = await withTaskGroup(of: (Int, Detection?).self) { group in
            for (i, url) in urls.enumerated() {
                if kind == nil || kind == .jellyfin || kind == .emby {
                    group.addTask { (i, await probeJellyfin(url)) }
                }
                if kind == nil || kind == .subsonic {
                    group.addTask { (i, await probeSubsonic(url)) }
                }
                if kind == nil || kind == .plex {
                    group.addTask { (i, await probePlex(url)) }
                }
            }
            var found: [(Int, Detection)] = []
            for await (i, d) in group { if let d { found.append((i, d)) } }
            return found
        }
        func rank(_ k: ServerKind) -> Int {
            switch k { case .jellyfin, .emby: return 0; case .subsonic: return 1; case .plex: return 2 }
        }
        return results.sorted { (rank($0.1.kind), $0.0) < (rank($1.1.kind), $1.0) }.first?.1
    }

    private static func getJSON(_ url: URL, accept: Bool = false) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if accept { req.setValue("application/json", forHTTPHeaderField: "Accept") }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func probeJellyfin(_ base: URL) async -> Detection? {
        guard let json = await getJSON(base.appendingPathComponent("System/Info/Public")),
              json["Id"] is String else { return nil }
        let product = json["ProductName"] as? String
        let isEmby = product?.lowercased().contains("emby") == true
        return Detection(kind: isEmby ? .emby : .jellyfin, baseURL: base, product: product, supportsAPIKey: false)
    }

    private static func probeSubsonic(_ base: URL) async -> Detection? {
        guard let info = await SubsonicClient.probe(base: base, timeout: timeout, session: session) else { return nil }
        return Detection(kind: .subsonic, baseURL: base, product: info.type, supportsAPIKey: info.supportsAPIKey)
    }

    private static func probePlex(_ base: URL) async -> Detection? {
        guard let json = await getJSON(base.appendingPathComponent("identity"), accept: true),
              let container = json["MediaContainer"] as? [String: Any],
              container["machineIdentifier"] is String else { return nil }
        return Detection(kind: .plex, baseURL: base, product: "Plex Media Server", supportsAPIKey: false)
    }
}
