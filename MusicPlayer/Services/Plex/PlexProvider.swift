import Foundation

/// Plex Media Server adapter: plex.tv JWT account auth (auto-refresh, silent legacy fallback), connection
/// selection (local → remote → relay with failover), section paging, direct play, universal transcode.
nonisolated public struct PlexProvider: MediaServerProvider {
    public let link: ServerSourceLink

    private static let pageSize = 1000
    private static let pageConcurrency = 4
    private static let jwtRefreshAge: TimeInterval = 6 * 24 * 3600
    private static let fullSweepInterval: TimeInterval = 24 * 3600

    public init(link: ServerSourceLink) {
        self.link = link
    }

    private var credentials: ServerCredentials? { ServerCredentialStore.credentials(for: link) }
    private var serverToken: String? { credentials?.token }
    private var base: URL { PlexConnectionStore.selectedBase(for: link.id) ?? link.serverURL }
    private var scanMarkerKey: String { "plex_scan_marker_\(link.id.uuidString)" }

    // MARK: Session

    public func prepareSession() async throws {
        try await refreshAccountIfNeeded(force: false)
        try await selectConnection()
    }

    /// Refreshes the 7-day account JWT when old (or forced after 401/498) and re-reads this server's
    /// access token and connections. Legacy tokens never expire, so they only re-read resources when needed.
    private func refreshAccountIfNeeded(force: Bool) async throws {
        guard var creds = credentials else { throw JellyfinClientError.authenticationFailed("TOKEN MISSING: PLEASE SIGN IN AGAIN") }
        var accountToken = creds.accountToken
        let age = creds.accountTokenIssuedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        var changed = false
        if creds.accountTokenIsJWT == true && (force || age > Self.jwtRefreshAge) {
            if let fresh = try? await PlexAccountAuth.refreshJWT() {
                accountToken = fresh
                creds.accountToken = fresh
                creds.accountTokenIssuedAt = Date()
                changed = true
            } else if age > 7 * 24 * 3600 {
                throw JellyfinClientError.authenticationFailed("PLEX SIGN-IN EXPIRED: PLEASE SIGN IN AGAIN")
            }
        }
        let needsResources = changed || force || PlexConnectionStore.connections(for: link.id).isEmpty
        if needsResources, let accountToken,
           let server = try? await PlexAccountAuth.servers(token: accountToken).first(where: { $0.id == link.serverId }) {
            creds.token = server.accessToken
            PlexConnectionStore.save(server.connections, for: link.id)
            changed = true
        }
        if changed { _ = ServerCredentialStore.save(creds, for: link.id) }
    }

    /// Races /identity per tier (local, remote, relay); the first reachable connection of the best tier wins.
    private func selectConnection() async throws {
        var connections = PlexConnection.ordered(PlexConnectionStore.connections(for: link.id))
        if connections.isEmpty { connections = [PlexConnection(uri: link.serverURL, local: false, relay: false)] }
        let token = serverToken
        let machineID = link.serverId
        for tier in 0...2 {
            let candidates = connections.filter { $0.tier == tier }
            guard !candidates.isEmpty else { continue }
            let winner = await withTaskGroup(of: URL?.self) { group -> URL? in
                for c in candidates {
                    group.addTask {
                        var req = PlexClient.request(c.uri.appendingPathComponent("identity"), token: token, timeout: 4)
                        req.timeoutInterval = 4
                        guard let (data, resp) = try? await JellyfinClient.syncSession.data(for: req),
                              (resp as? HTTPURLResponse)?.statusCode == 200,
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let mc = obj["MediaContainer"] as? [String: Any],
                              (mc["machineIdentifier"] as? String) == machineID else { return nil }
                        return c.uri
                    }
                }
                for await r in group { if let r { group.cancelAll(); return r } }
                return nil
            }
            if let winner {
                PlexConnectionStore.select(winner, for: link.id)
                return
            }
        }
        throw JellyfinClientError.networkError("PLEX SERVER IS UNREACHABLE")
    }

    // MARK: Requests

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        var items = query
        if let token = serverToken { items.append(URLQueryItem(name: "X-Plex-Token", value: token)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    private func getJSON(_ path: String, _ query: [URLQueryItem] = [], extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        guard let u = url(path, query) else { throw JellyfinClientError.invalidURL }
        var req = PlexClient.request(u, token: serverToken, timeout: 60)
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await ServerHTTPClient.data(for: req, session: JellyfinClient.syncSession)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mc = obj["MediaContainer"] as? [String: Any] else { throw JellyfinClientError.invalidResponse }
        return mc
    }

    // MARK: Sync

    public func fetchTrackChanges(
        existingTracks: [Track],
        lastSyncDate: Date?,
        statusHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ServerChangeSet {
        do {
            return try await sync(existingTracks: existingTracks, lastSyncDate: lastSyncDate, statusHandler: statusHandler, progressHandler: progressHandler)
        } catch ServerHTTPError.status(let code) where code == 401 || code == 498 {
            // Expired/revoked token: refresh once, reselect, retry.
            try await refreshAccountIfNeeded(force: true)
            try await selectConnection()
            return try await sync(existingTracks: existingTracks, lastSyncDate: lastSyncDate, statusHandler: statusHandler, progressHandler: progressHandler)
        }
    }

    private struct Section { let key: String; let roots: [String]; let marker: String }

    private func sections() async throws -> [Section] {
        let mc = try await getJSON("/library/sections")
        return (mc["Directory"] as? [[String: Any]] ?? []).compactMap { d in
            guard (d["type"] as? String) == "artist", let key = d["key"] as? String else { return nil }
            let roots = (d["Location"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            let marker = "\(key):\(d["updatedAt"] ?? 0):\(d["scannedAt"] ?? 0):\(d["contentChangedAt"] ?? 0)"
            return Section(key: key, roots: roots, marker: marker)
        }
    }

    private func sync(
        existingTracks: [Track],
        lastSyncDate: Date?,
        statusHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ServerChangeSet {
        let sections = try await sections()
        let marker = sections.map(\.marker).joined(separator: "|")
        if !existingTracks.isEmpty, let lastSyncDate,
           Date().timeIntervalSince(lastSyncDate) < Self.fullSweepInterval,
           UserDefaults.standard.string(forKey: scanMarkerKey) == marker {
            return ServerChangeSet(upserted: [], removedIDs: [])
        }

        statusHandler?("READING LIBRARY...")
        let existingByID = Dictionary(existingTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var mapped: [Track] = []
        var seen = Set<String>()
        var seenFiles = Set<String>()
        for section in sections {
            let items = try await fetchSectionTracks(section.key, existingCount: existingTracks.count, already: mapped.count, progressHandler: progressHandler)
            for item in items {
                guard let ratingKey = item["ratingKey"] as? String, seen.insert(ratingKey).inserted else { continue }
                if let media = (item["Media"] as? [[String: Any]])?.first,
                   let part = (media["Part"] as? [[String: Any]])?.first,
                   let file = part["file"] as? String, !file.isEmpty {
                    if !seenFiles.insert(file.lowercased()).inserted {
                        continue
                    }
                }
                let id = TrackIdentity.serverTrackID(sourceID: link.id, kind: .plex, itemID: ratingKey)
                if let t = mapTrack(item, ratingKey: ratingKey, id: id, roots: section.roots, existing: existingByID[id]) {
                    mapped.append(t)
                }
            }
        }
        let change = ServerChangeDiff.diff(existing: existingTracks, fresh: mapped)
        UserDefaults.standard.set(marker, forKey: scanMarkerKey)
        progressHandler?(mapped.count, mapped.count)
        return change
    }

    private func fetchSectionTracks(_ key: String, existingCount: Int, already: Int,
                                    progressHandler: (@Sendable (Int, Int) -> Void)?) async throws -> [[String: Any]] {
        func page(_ start: Int) async throws -> (items: [[String: Any]], total: Int?) {
            let mc = try await getJSON("/library/sections/\(key)/all", [
                URLQueryItem(name: "type", value: "10"),
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.pageSize))
            ], extraHeaders: ["X-Plex-Container-Start": String(start), "X-Plex-Container-Size": String(Self.pageSize)])
            return (mc["Metadata"] as? [[String: Any]] ?? [], mc["totalSize"] as? Int)
        }
        let first = try await page(0)
        var all = first.items
        let total = first.total ?? (first.items.count < Self.pageSize ? first.items.count : Int.max)
        var start = Self.pageSize
        progressHandler?(already + all.count, max(already + (first.total ?? all.count), existingCount))
        while start < total && !(first.total == nil && all.count < start) {
            try Task.checkCancellation()
            let starts = (0..<Self.pageConcurrency).map { start + $0 * Self.pageSize }.filter { $0 < total }
            let pages = try await withThrowingTaskGroup(of: (Int, [[String: Any]]).self) { group in
                for s in starts { group.addTask { (s, try await page(s).items) } }
                var r: [(Int, [[String: Any]])] = []
                for try await p in group { r.append(p) }
                return r.sorted { $0.0 < $1.0 }
            }
            var short = false
            for (_, items) in pages {
                all += items
                if items.count < Self.pageSize { short = true }
            }
            start += Self.pageSize * Self.pageConcurrency
            progressHandler?(already + all.count, max(already + (first.total ?? all.count), existingCount))
            if short { break }
        }
        return all
    }

    private func mapTrack(_ m: [String: Any], ratingKey: String, id: UUID, roots: [String], existing: Track?) -> Track? {
        guard let media = (m["Media"] as? [[String: Any]])?.first,
              let part = (media["Part"] as? [[String: Any]])?.first,
              let partKey = part["key"] as? String else { return nil }
        let title = m["title"] as? String ?? "Unknown Title"
        let album = m["parentTitle"] as? String ?? "Unknown Album"
        let albumArtist = m["grandparentTitle"] as? String
        let artist = (m["originalTitle"] as? String) ?? albumArtist ?? "Unknown Artist"
        let file = part["file"] as? String
        var ext = ((part["container"] as? String) ?? (media["container"] as? String) ?? file.map { ($0 as NSString).pathExtension } ?? "mp3").lowercased()
        if ext == "mp4" { ext = "m4a" }
        let durationMs = (m["duration"] as? Double) ?? (media["duration"] as? Double) ?? 0
        let duration = durationMs / 1000
        let trackNo = m["index"] as? Int
        let disc = m["parentIndex"] as? Int
        let year = (m["parentYear"] as? Int) ?? (m["year"] as? Int)
        let albumID = (m["parentRatingKey"] as? String) ?? "\(albumArtist ?? artist)|\(album)"
        let sourcePrefix = String(link.id.uuidString.prefix(8))
        let thumb = (m["parentThumb"] as? String) ?? (m["thumb"] as? String)

        // Canonical URL stores the part path on the sign-in base; the live base is substituted per request.
        guard let canonicalURL = URL(string: partKey, relativeTo: link.serverURL)?.absoluteURL else { return nil }
        let fileInfo = AudioFileInfo(
            filePath: canonicalURL.absoluteString,
            fileName: file.map { ($0 as NSString).lastPathComponent } ?? "\(title).\(ext)",
            fileExtension: ext,
            fileSizeBytes: (part["size"] as? Int64) ?? Int64(part["size"] as? Int ?? 0),
            sampleRate: Double(media["audioSampleRate"] as? Int ?? 44100),
            channelCount: media["audioChannels"] as? Int ?? 2,
            bitRate: Double((media["bitrate"] as? Int ?? 0) * 1000),
            formatDescription: ((media["audioCodec"] as? String) ?? ext).uppercased(),
            durationSeconds: duration
        )
        let relativePath = ServerPathBuilder.relativePath(serverPath: file, roots: roots, albumArtist: albumArtist ?? artist,
                                                          album: album, disc: disc, track: trackNo, title: title, ext: ext)
        let added = (m["addedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Track(
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            year: year,
            trackNumber: trackNo,
            discNumber: disc,
            duration: duration,
            url: canonicalURL,
            artworkKey: thumb == nil ? nil : "px_\(sourcePrefix)_\(albumID)",
            dateAdded: existing?.dateAdded ?? added ?? Date(),
            fileInfo: fileInfo,
            lyrics: existing?.lyrics,
            isAlternate: existing?.isAlternate,
            folderID: link.id,
            relativePath: relativePath,
            metadataSource: .server,
            tagSnapshot: TagSnapshot(title: title, artist: artist, album: album, albumArtist: albumArtist,
                                     year: year, trackNumber: trackNo, discNumber: disc),
            jellyfinItemId: ratingKey,
            jellyfinAlbumId: "\(sourcePrefix)_\(albumID)",
            serverCoverArtId: thumb
        )
    }

    // MARK: Media

    private func request(_ u: URL?, timeout: TimeInterval) -> URLRequest? {
        guard let u else { return nil }
        return PlexClient.request(u, token: serverToken, timeout: timeout)
    }

    private func transcodeRequest(for track: Track, container: String, ext: String) -> URLRequest? {
        guard let ratingKey = track.jellyfinItemId else { return nil }
        let query = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "musicBitrate", value: "320"),
            URLQueryItem(name: "maxAudioBitrate", value: "320"),
            URLQueryItem(name: "session", value: UUID().uuidString),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexClient.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: PlexClient.product),
            URLQueryItem(name: "X-Plex-Platform", value: "iOS")
        ]
        guard var req = request(url("/music/:/transcode/universal/start.\(ext)", query), timeout: 300) else { return nil }
        req.setValue("add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=\(container)&audioCodec=\(container == "mp3" ? "mp3" : "aac"))",
                     forHTTPHeaderField: "X-Plex-Client-Profile-Extra")
        return req
    }

    public func mediaRequest(for track: Track, purpose: ServerMediaPurpose) -> URLRequest? {
        if TranscodePolicy.requiresTranscode(track) {
            return transcodeRequest(for: track, container: "mp4", ext: "m4a")
        }
        guard let comps = URLComponents(url: track.url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [URLQueryItem] = []
        if purpose == .download { query.append(URLQueryItem(name: "download", value: "1")) }
        return request(url(comps.path, query), timeout: purpose == .download ? 300 : 60)
    }

    public func transcodeFallbackRequest(for track: Track) -> URLRequest? {
        guard TranscodePolicy.requiresTranscode(track) else { return nil }
        return transcodeRequest(for: track, container: "mp3", ext: "mp3")
    }

    public func artworkRequests(imageId: String, fullResolution: Bool) -> [URLRequest] {
        if fullResolution {
            return [request(url(imageId), timeout: 12)].compactMap { $0 }
        }
        let q = [URLQueryItem(name: "url", value: imageId), URLQueryItem(name: "width", value: "800"),
                 URLQueryItem(name: "height", value: "800"), URLQueryItem(name: "minSize", value: "1"),
                 URLQueryItem(name: "upscale", value: "0")]
        return [request(url("/photo/:/transcode", q), timeout: 10), request(url(imageId), timeout: 10)].compactMap { $0 }
    }

    // MARK: Reporting

    @MainActor public func reportPlayback(_ event: ServerPlaybackEvent, track: Track) {
        guard let ratingKey = track.jellyfinItemId else { return }
        let state: String
        let positionMs: Int
        switch event {
        case .started: state = "playing"; positionMs = 0
        case .progress(let pos, let paused): state = paused ? "paused" : "playing"; positionMs = Int(pos * 1000)
        case .stopped(let pos): state = "stopped"; positionMs = Int(pos * 1000)
        }
        var requests: [URLRequest] = []
        if var req = request(url("/:/timeline", [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(positionMs)),
            URLQueryItem(name: "duration", value: String(Int(track.duration * 1000)))
        ]), timeout: 15) {
            req.httpMethod = "POST"
            requests.append(req)
        }
        if case .stopped(let pos) = event, pos >= min(240, max(track.duration, 1) / 2),
           var req = request(url("/:/scrobble", [URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                                                 URLQueryItem(name: "key", value: ratingKey)]), timeout: 15) {
            req.httpMethod = "PUT"
            requests.append(req)
        }
        let reqs = requests
        Task.detached {
            for r in reqs { _ = try? await ServerHTTPClient.data(for: r, session: JellyfinClient.syncSession, maxAttempts: 1) }
        }
    }

    public func signOut() async {
        UserDefaults.standard.removeObject(forKey: scanMarkerKey)
        PlexConnectionStore.remove(for: link.id)
    }
}
