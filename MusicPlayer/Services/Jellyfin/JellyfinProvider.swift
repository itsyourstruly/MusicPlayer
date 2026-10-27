import Foundation

/// Jellyfin adapter for MediaServerProvider. Wraps the existing Jellyfin sync/client/reporter internals
/// and owns Jellyfin media URL construction (single place for stream, download and transcode URLs).
nonisolated public struct JellyfinProvider: MediaServerProvider {
    public let link: ServerSourceLink

    public init(link: ServerSourceLink) {
        self.link = link
    }

    // MARK: Session

    private func session() throws -> (serverURL: URL, token: String) {
        if let cached = ServerSessionCache.shared.resolveSession(for: link.id, servers: [link]) {
            return cached
        }
        throw JellyfinClientError.authenticationFailed("TOKEN MISSING: PLEASE SIGN IN AGAIN")
    }

    /// Fail-fast pre-sync check: one cheap authenticated call (8 s) proves the server is reachable and the
    /// token is still accepted before a long sync starts. 401 means the token was revoked: sign in again.
    public func prepareSession() async throws {
        let (serverURL, token) = try session()
        var request = URLRequest(url: serverURL.appendingPathComponent("System/Info"), timeoutInterval: 8)
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        ServerRequestLog.log(request, caller: "jellyfinProvider")
        let (_, response) = try await JellyfinClient.syncSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.invalidResponse }
        if http.statusCode == 503 && http.value(forHTTPHeaderField: "Message") != nil { throw ServerHTTPError.serverStarting }
        guard (200...299).contains(http.statusCode) else { throw JellyfinClient.mapHTTPStatusError(http.statusCode) }
    }

    // MARK: Sync

    public func fetchTrackChanges(
        existingTracks: [Track],
        lastSyncDate: Date?,
        statusHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ServerChangeSet {
        let token = try session().token
        let (upserted, removedIDs) = try await JellyfinSyncService.shared.fetchAudioTrackChanges(
            for: link,
            token: token,
            existingTracks: existingTracks,
            lastSyncDate: lastSyncDate,
            statusHandler: statusHandler,
            progressHandler: progressHandler
        )
        return ServerChangeSet(upserted: upserted, removedIDs: removedIDs)
    }

    public func fetchRelativePaths() async throws -> [String: String] {
        let token = try session().token
        return try await JellyfinSyncService.shared.fetchRelativeItemPaths(for: link, token: token)
    }

    public func fetchCatalog() async throws -> ServerCatalog {
        let token = try session().token
        return try await JellyfinSyncService.shared.fetchCatalog(for: link, token: token)
    }

    // MARK: Media URLs

    /// Original file for AVPlayer-native formats (`/Audio/{id}/stream?static=true`).
    /// Unsupported formats: `/Audio/{id}/universal` transcoding to AAC 320 kbps in an MP4 container over
    /// progressive HTTP. `container` lists what the client direct-plays so the server never transcodes those;
    /// `transcodingProtocol=http` prevents the server from choosing HLS.
    public func mediaRequest(for track: Track, purpose: ServerMediaPurpose) -> URLRequest? {
        guard let (serverURL, token) = try? session() else { return nil }
        let itemId = track.jellyfinItemId ?? track.url.lastPathComponent
        guard !itemId.isEmpty else { return nil }

        let transcode = TranscodePolicy.requiresTranscode(track)
        let path = transcode ? "Audio/\(itemId)/universal" : "Audio/\(itemId)/stream"
        var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        var query = [URLQueryItem(name: "api_key", value: token)]
        if transcode {
            query += [
                URLQueryItem(name: "userId", value: link.userId),
                URLQueryItem(name: "deviceId", value: ServerCredentialStore.stableDeviceId),
                URLQueryItem(name: "container", value: "mp3,aac,m4a|aac,m4a|alac,m4b|aac,flac,wav,aiff"),
                URLQueryItem(name: "audioCodec", value: "aac"),
                URLQueryItem(name: "audioBitRate", value: String(TranscodePolicy.transcodeBitRate)),
                URLQueryItem(name: "maxStreamingBitrate", value: String(TranscodePolicy.transcodeBitRate)),
                URLQueryItem(name: "transcodingContainer", value: "mp4"),
                URLQueryItem(name: "transcodingProtocol", value: "http")
            ]
        } else {
            query.append(URLQueryItem(name: "static", value: "true"))
        }
        components?.queryItems = query
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Artwork

    public func artworkRequests(imageId: String, size: ArtworkFetchSize, version: String?) -> [URLRequest] {
        guard let (serverURL, token) = try? session() else { return [] }
        // Jellyfin pre-generates no thumbnail sizes. Swiftfin (official iOS client) requests posters as
        // Images/Primary?tag=… with no size or quality, which Jellyfin serves as the stored image without
        // resizing; both tiers use that one URL and every smaller size is scaled on device.
        let tag = version.flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "tag", value: $0)] } ?? []
        var components = URLComponents(url: serverURL.appendingPathComponent("Items/\(imageId)/Images/Primary"), resolvingAgainstBaseURL: true)
        components?.queryItems = tag + [URLQueryItem(name: "api_key", value: token)]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: size.requestTimeout)
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("image/*, */*", forHTTPHeaderField: "Accept")
        return [request]
    }

    // MARK: Reporting

    @MainActor public func reportPlayback(_ event: ServerPlaybackEvent, track: Track) {
        switch event {
        case .started:
            JellyfinPlaybackReporter.shared.reportPlaybackStart(track: track, serverLink: link)
        case .progress(let position, let isPaused):
            JellyfinPlaybackReporter.shared.reportPlaybackProgress(track: track, positionSeconds: position, isPaused: isPaused, serverLink: link)
        case .stopped(let position):
            JellyfinPlaybackReporter.shared.reportPlaybackStopped(track: track, positionSeconds: position, serverLink: link)
        }
    }

    // MARK: Session lifecycle

    public func signOut() async {
        await JellyfinClient.shared.logout(link: link)
    }
}

// MARK: - Descriptions (BaseItemDto.Overview)

nonisolated extension JellyfinProvider {
    /// GET /Items/{itemId}?userId= returns the item's BaseItemDto, whose Overview holds the description.
    public func fetchDescription(_ kind: ServerDescriptionKind, itemId: String) async throws -> String? {
        let (serverURL, token) = try session()
        guard var components = URLComponents(url: serverURL.appendingPathComponent("Items/\(itemId)"),
                                             resolvingAgainstBaseURL: false) else { throw JellyfinClientError.invalidURL }
        components.queryItems = [URLQueryItem(name: "userId", value: link.userId)]
        guard let url = components.url else { throw JellyfinClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        let (data, _) = try await ServerHTTPClient.data(for: request, session: JellyfinClient.syncSession)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JellyfinClientError.invalidResponse
        }
        return object["Overview"] as? String
    }
}
