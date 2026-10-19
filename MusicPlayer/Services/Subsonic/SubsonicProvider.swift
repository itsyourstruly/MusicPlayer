import Foundation
import CryptoKit

// MARK: - Wire Models

/// Subsonic/OpenSubsonic API error (`subsonic-response.error`).
nonisolated struct SubsonicAPIError: Error, Sendable {
    let code: Int
    let message: String

    var clientError: JellyfinClientError {
        switch code {
        case 40, 44: return .authenticationFailed("WRONG USERNAME OR PASSWORD")
        case 41, 42, 43: return .authenticationFailed("SERVER REJECTED THIS SIGN-IN METHOD")
        case 50: return .authenticationFailed("USER IS NOT AUTHORIZED")
        case 20, 30: return .networkError("SERVER API VERSION IS NOT SUPPORTED")
        default: return .networkError(message.isEmpty ? "SERVER ERROR \(code)" : message)
        }
    }
}

nonisolated struct SubsonicSong: Decodable, Sendable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let displayAlbumArtist: String?
    let albumId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let suffix: String?
    let duration: Int?
    let bitRate: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let path: String?
    let created: String?
    let isVideo: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, album, artist, displayAlbumArtist, albumId, track, discNumber, year, genre, coverArt
        case size, suffix, duration, bitRate, samplingRate, channelCount, path, created, isVideo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Servers disagree on number vs string encodings; accept both.
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let i = try? c.decodeIfPresent(Int64.self, forKey: k) { return String(i) }
            return nil
        }
        func int(_ k: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return i }
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return Int(d) }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int(s) }
            return nil
        }
        guard let id = str(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "song id"))
        }
        self.id = id
        title = str(.title)
        album = str(.album)
        artist = str(.artist)
        displayAlbumArtist = str(.displayAlbumArtist)
        albumId = str(.albumId)
        track = int(.track)
        discNumber = int(.discNumber)
        year = int(.year)
        genre = str(.genre)
        coverArt = str(.coverArt)
        size = str(.size).flatMap { Int64($0) }
        suffix = str(.suffix)
        duration = int(.duration)
        bitRate = int(.bitRate)
        samplingRate = int(.samplingRate)
        channelCount = int(.channelCount)
        path = str(.path)
        created = str(.created)
        isVideo = try? c.decodeIfPresent(Bool.self, forKey: .isVideo)
    }
}

nonisolated private struct SubsonicStatus: Decodable {
    struct Body: Decodable {
        struct Err: Decodable { let code: Int; let message: String? }
        let status: String
        let type: String?
        let serverVersion: String?
        let openSubsonic: Bool?
        let error: Err?
    }
    let body: Body
    enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
}

nonisolated private struct SubsonicEnvelope<Payload: Decodable>: Decodable {
    let body: Payload
    enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
}

nonisolated private struct SearchResultBody: Decodable {
    struct Result: Decodable { let song: [SubsonicSong]? }
    let searchResult3: Result?
}

nonisolated private struct AlbumListBody: Decodable {
    struct Album: Decodable { let id: String }
    struct List: Decodable { let album: [Album]? }
    let albumList2: List?
}

nonisolated private struct AlbumBody: Decodable {
    struct Album: Decodable { let song: [SubsonicSong]? }
    let album: Album?
}

nonisolated private struct ExtensionsBody: Decodable {
    struct Ext: Decodable { let name: String }
    let openSubsonicExtensions: [Ext]?
}

nonisolated private struct ScanStatusBody: Decodable {
    struct Status: Decodable { let count: Int?; let lastScan: String? }
    let scanStatus: Status?
}

// MARK: - SubsonicClient

/// Stateless Subsonic/OpenSubsonic request helpers (auth parameters, endpoint URLs, response checking).
nonisolated enum SubsonicClient {
    static let apiVersion = "1.16.1"
    static let clientName = "MusicPlayer"

    struct ServerInfo: Sendable {
        let type: String?
        let serverVersion: String?
        let openSubsonic: Bool
        let supportsAPIKey: Bool
    }

    /// Auth parameters for the stored credentials. apiKey must not be combined with `u` (error 43).
    static func authItems(userName: String, credentials: ServerCredentials) -> [URLQueryItem] {
        if let apiKey = credentials.apiKey, !apiKey.isEmpty {
            return [URLQueryItem(name: "apiKey", value: apiKey)]
        }
        let password = credentials.password ?? ""
        if credentials.useLegacyPasswordAuth == true {
            let hex = password.utf8.map { String(format: "%02x", $0) }.joined()
            return [URLQueryItem(name: "u", value: userName), URLQueryItem(name: "p", value: "enc:\(hex)")]
        }
        let salt = (0..<12).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return [URLQueryItem(name: "u", value: userName),
                URLQueryItem(name: "t", value: token),
                URLQueryItem(name: "s", value: salt)]
    }

    /// `<base>/rest/<endpoint>.view?...` with protocol parameters (and auth when given).
    static func url(base: URL, endpoint: String, params: [URLQueryItem], auth: [URLQueryItem]?) -> URL? {
        guard var comps = URLComponents(url: base.appendingPathComponent("rest/\(endpoint).view"), resolvingAgainstBaseURL: false) else { return nil }
        var items = params + [URLQueryItem(name: "v", value: apiVersion),
                              URLQueryItem(name: "c", value: clientName),
                              URLQueryItem(name: "f", value: "json")]
        if let auth { items += auth }
        comps.queryItems = items
        return comps.url
    }

    /// Fetches and decodes one endpoint, surfacing `status: failed` as SubsonicAPIError.
    static func request<Payload: Decodable>(
        _ type: Payload.Type,
        base: URL,
        endpoint: String,
        params: [URLQueryItem] = [],
        auth: [URLQueryItem]?,
        timeout: TimeInterval = 30,
        session: URLSession = JellyfinClient.syncSession
    ) async throws -> Payload {
        guard let url = url(base: base, endpoint: endpoint, params: params, auth: auth) else { throw JellyfinClientError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, _) = try await ServerHTTPClient.data(for: req, session: session)
        let status = try JSONDecoder().decode(SubsonicStatus.self, from: data).body
        if status.status != "ok" {
            throw SubsonicAPIError(code: status.error?.code ?? 0, message: status.error?.message ?? "")
        }
        return try JSONDecoder().decode(SubsonicEnvelope<Payload>.self, from: data).body
    }

    /// Unauthenticated ping: identifies a Subsonic-compatible server (it answers with a subsonic-response even on auth failure).
    static func probe(base: URL, timeout: TimeInterval = 4, session: URLSession = JellyfinClient.syncSession) async -> ServerInfo? {
        guard let url = url(base: base, endpoint: "ping", params: [], auth: nil) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, _) = try? await session.data(for: req),
              let body = try? JSONDecoder().decode(SubsonicStatus.self, from: data).body else { return nil }
        var supportsAPIKey = false
        if body.openSubsonic == true,
           let ext = try? await request(ExtensionsBody.self, base: base, endpoint: "getOpenSubsonicExtensions", auth: nil, timeout: timeout, session: session) {
            supportsAPIKey = ext.openSubsonicExtensions?.contains { $0.name == "apiKeyAuthentication" } ?? false
        }
        return ServerInfo(type: body.type, serverVersion: body.serverVersion, openSubsonic: body.openSubsonic == true, supportsAPIKey: supportsAPIKey)
    }

    /// Signs in: apiKey when given, else token+salt, falling back to `enc:` password auth on error 41.
    static func authenticate(base: URL, userName: String, password: String, apiKey: String?) async throws -> (ServerSourceLink, ServerCredentials) {
        let info = await probe(base: base)
        var creds: ServerCredentials
        if let apiKey, !apiKey.isEmpty {
            creds = ServerCredentials(apiKey: apiKey)
        } else {
            creds = ServerCredentials(password: password)
        }
        do {
            _ = try await request(SubsonicStatus.Body?.self, base: base, endpoint: "ping", auth: authItems(userName: userName, credentials: creds))
        } catch let err as SubsonicAPIError where err.code == 41 && creds.apiKey == nil {
            creds.useLegacyPasswordAuth = true
            do {
                _ = try await request(SubsonicStatus.Body?.self, base: base, endpoint: "ping", auth: authItems(userName: userName, credentials: creds))
            } catch let err as SubsonicAPIError {
                throw err.clientError
            }
        } catch let err as SubsonicAPIError {
            throw err.clientError
        }

        let product = info?.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = base.absoluteString.lowercased() + "|" + userName.lowercased()
        let link = ServerSourceLink(
            kind: .subsonic,
            serverId: UUID.deterministic(from: "subsonic|" + identity).uuidString,
            serverName: (product?.isEmpty == false ? product! : base.host ?? "Subsonic").capitalized,
            userId: userName,
            userName: userName,
            serverURL: base,
            productName: product?.isEmpty == false ? product : nil
        )
        return (link, creds)
    }
}

// MARK: - SubsonicProvider

/// Subsonic/OpenSubsonic adapter (Navidrome, Gonic, Airsonic-Advanced, LMS, ...).
nonisolated public struct SubsonicProvider: MediaServerProvider {
    public let link: ServerSourceLink

    private static let pageSize = 500
    private static let pageConcurrency = 4
    private static let fullSweepInterval: TimeInterval = 24 * 3600

    public init(link: ServerSourceLink) {
        self.link = link
    }

    private var credentials: ServerCredentials? { ServerCredentialStore.credentials(for: link) }

    private func auth() throws -> [URLQueryItem] {
        guard let creds = credentials else { throw JellyfinClientError.authenticationFailed("TOKEN MISSING: PLEASE SIGN IN AGAIN") }
        return SubsonicClient.authItems(userName: link.userName, credentials: creds)
    }

    private func call<P: Decodable>(_ type: P.Type, _ endpoint: String, _ params: [URLQueryItem] = []) async throws -> P {
        do {
            return try await SubsonicClient.request(type, base: link.serverURL, endpoint: endpoint, params: params, auth: try auth())
        } catch let err as SubsonicAPIError {
            throw err.clientError
        }
    }

    private var scanMarkerKey: String { "subsonic_scan_marker_\(link.id.uuidString)" }

    // MARK: Sync

    public func fetchTrackChanges(
        existingTracks: [Track],
        lastSyncDate: Date?,
        statusHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ServerChangeSet {
        // Cheap change check: skip enumeration when the server's last scan is unchanged and a full
        // sweep (deletion detection) ran within 24 h. Manual rescans clear the marker first.
        var marker: String?
        if let scan = try? await call(ScanStatusBody.self, "getScanStatus").scanStatus {
            marker = scan.lastScan ?? scan.count.map { "count:\($0)" }
        }
        if let marker, !existingTracks.isEmpty, let lastSyncDate,
           Date().timeIntervalSince(lastSyncDate) < Self.fullSweepInterval,
           UserDefaults.standard.string(forKey: scanMarkerKey) == marker {
            return ServerChangeSet(upserted: [], removedIDs: [])
        }

        statusHandler?("READING LIBRARY...")
        var songs = try await fetchAllSongsViaSearch(existingCount: existingTracks.count, progressHandler: progressHandler)
        if songs.isEmpty {
            songs = try await fetchAllSongsViaAlbums(statusHandler: statusHandler)
        }

        let existingByID = Dictionary(existingTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var seenPaths = Set<String>()
        var mapped: [Track] = []
        mapped.reserveCapacity(songs.count)
        for song in songs where song.isVideo != true && seen.insert(song.id).inserted {
            if let path = song.path, !path.isEmpty {
                if !seenPaths.insert(path.lowercased()).inserted {
                    continue
                }
            }
            let id = TrackIdentity.serverTrackID(sourceID: link.id, kind: .subsonic, itemID: song.id)
            mapped.append(mapSong(song, id: id, existing: existingByID[id]))
        }

        let change = ServerChangeDiff.diff(existing: existingTracks, fresh: mapped)
        if let marker { UserDefaults.standard.set(marker, forKey: scanMarkerKey) }
        progressHandler?(mapped.count, mapped.count)
        return change
    }

    private func fetchAllSongsViaSearch(existingCount: Int, progressHandler: (@Sendable (Int, Int) -> Void)?) async throws -> [SubsonicSong] {
        var all: [SubsonicSong] = []
        var seenInSearch = Set<String>()
        var offset = 0
        var finished = false
        while !finished {
            try Task.checkCancellation()
            let offsets = (0..<Self.pageConcurrency).map { offset + $0 * Self.pageSize }
            let pages = try await withThrowingTaskGroup(of: (Int, [SubsonicSong]).self) { group in
                for o in offsets {
                    group.addTask {
                        let body = try await call(SearchResultBody.self, "search3", [
                            URLQueryItem(name: "query", value: ""),
                            URLQueryItem(name: "artistCount", value: "0"),
                            URLQueryItem(name: "albumCount", value: "0"),
                            URLQueryItem(name: "songCount", value: String(Self.pageSize)),
                            URLQueryItem(name: "songOffset", value: String(o))
                        ])
                        return (o, body.searchResult3?.song ?? [])
                    }
                }
                var result: [(Int, [SubsonicSong])] = []
                for try await page in group { result.append(page) }
                return result.sorted { $0.0 < $1.0 }
            }
            for (_, songs) in pages {
                for s in songs {
                    if seenInSearch.insert(s.id).inserted {
                        all.append(s)
                    }
                }
                if songs.count < Self.pageSize { finished = true; break }
            }
            offset += Self.pageSize * Self.pageConcurrency
            progressHandler?(all.count, max(all.count, existingCount))
        }
        return all
    }

    /// Fallback for servers whose search3 ignores the empty query: walk albums.
    private func fetchAllSongsViaAlbums(statusHandler: (@Sendable (String) -> Void)?) async throws -> [SubsonicSong] {
        var albumIDs: [String] = []
        var seenAlbumIDs = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let body = try await call(AlbumListBody.self, "getAlbumList2", [
                URLQueryItem(name: "type", value: "alphabeticalByName"),
                URLQueryItem(name: "size", value: "500"),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            let page = body.albumList2?.album ?? []
            for alb in page {
                if seenAlbumIDs.insert(alb.id).inserted {
                    albumIDs.append(alb.id)
                }
            }
            if page.count < 500 { break }
            offset += 500
        }
        var songs: [SubsonicSong] = []
        var index = 0
        while index < albumIDs.count {
            try Task.checkCancellation()
            let chunk = albumIDs[index..<min(index + 8, albumIDs.count)]
            let results = try await withThrowingTaskGroup(of: [SubsonicSong].self) { group in
                for id in chunk {
                    group.addTask { try await call(AlbumBody.self, "getAlbum", [URLQueryItem(name: "id", value: id)]).album?.song ?? [] }
                }
                var r: [SubsonicSong] = []
                for try await s in group { r += s }
                return r
            }
            songs += results
            index += chunk.count
            statusHandler?("READING ALBUMS \(index)/\(albumIDs.count)")
        }
        return songs
    }

    private func mapSong(_ song: SubsonicSong, id: UUID, existing: Track?) -> Track {
        let title = song.title ?? "Unknown Title"
        let album = song.album ?? "Unknown Album"
        let albumArtist = song.displayAlbumArtist.flatMap { $0.isEmpty ? nil : $0 }
        let artist = song.artist ?? albumArtist ?? "Unknown Artist"
        let pathExt = song.path.map { ($0 as NSString).pathExtension }
        let ext = (song.suffix ?? pathExt ?? "mp3").lowercased()
        let duration = Double(song.duration ?? 0)
        let canonicalURL = SubsonicClient.url(base: link.serverURL, endpoint: "stream",
                                              params: [URLQueryItem(name: "id", value: song.id)], auth: nil)
            ?? link.serverURL
        let fileInfo = AudioFileInfo(
            filePath: canonicalURL.absoluteString,
            fileName: "\(title).\(ext)",
            fileExtension: ext,
            fileSizeBytes: song.size ?? 0,
            sampleRate: Double(song.samplingRate ?? 44100),
            channelCount: song.channelCount ?? 2,
            bitRate: Double((song.bitRate ?? 0) * 1000),
            formatDescription: ext.uppercased(),
            durationSeconds: duration
        )
        let sourcePrefix = String(link.id.uuidString.prefix(8))
        let albumKey = song.albumId ?? "\(albumArtist ?? artist)|\(album)"
        let artworkKey = song.coverArt == nil ? nil : "ss_\(sourcePrefix)_\(albumKey)"
        let relativePath = ServerPathBuilder.relativePath(serverPath: song.path, albumArtist: albumArtist ?? artist,
                                                          album: album, disc: song.discNumber, track: song.track,
                                                          title: title, ext: ext)
        return Track(
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: song.genre,
            year: song.year,
            trackNumber: song.track,
            discNumber: song.discNumber,
            duration: duration,
            url: canonicalURL,
            artworkKey: artworkKey,
            dateAdded: existing?.dateAdded ?? ServerPathBuilder.parseDate(song.created) ?? Date(),
            fileInfo: fileInfo,
            lyrics: existing?.lyrics,
            isAlternate: existing?.isAlternate,
            folderID: link.id,
            relativePath: relativePath,
            metadataSource: .server,
            tagSnapshot: TagSnapshot(title: title, artist: artist, album: album, albumArtist: albumArtist,
                                     year: song.year, trackNumber: song.track, discNumber: song.discNumber),
            jellyfinItemId: song.id,
            jellyfinAlbumId: "\(sourcePrefix)_\(albumKey)",
            serverCoverArtId: song.coverArt
        )
    }

    // MARK: Media

    private func endpointRequest(_ endpoint: String, _ params: [URLQueryItem], timeout: TimeInterval = 60) -> URLRequest? {
        guard let auth = try? auth(),
              let url = SubsonicClient.url(base: link.serverURL, endpoint: endpoint, params: params, auth: auth) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return req
    }

    public func mediaRequest(for track: Track, purpose: ServerMediaPurpose) -> URLRequest? {
        guard let itemID = track.jellyfinItemId else { return nil }
        let id = URLQueryItem(name: "id", value: itemID)
        if !TranscodePolicy.requiresTranscode(track) {
            return purpose == .download
                ? endpointRequest("download", [id], timeout: 300)
                : endpointRequest("stream", [id, URLQueryItem(name: "format", value: "raw")])
        }
        return endpointRequest("stream", [id, URLQueryItem(name: "format", value: "aac"),
                                          URLQueryItem(name: "maxBitRate", value: "320")], timeout: 300)
    }

    public func transcodeFallbackRequest(for track: Track) -> URLRequest? {
        guard let itemID = track.jellyfinItemId, TranscodePolicy.requiresTranscode(track) else { return nil }
        return endpointRequest("stream", [URLQueryItem(name: "id", value: itemID),
                                          URLQueryItem(name: "format", value: "mp3"),
                                          URLQueryItem(name: "maxBitRate", value: "320")], timeout: 300)
    }

    public func artworkRequests(imageId: String, fullResolution: Bool) -> [URLRequest] {
        var params = [URLQueryItem(name: "id", value: imageId)]
        if !fullResolution { params.append(URLQueryItem(name: "size", value: "800")) }
        return [endpointRequest("getCoverArt", params, timeout: fullResolution ? 12 : 10)].compactMap { $0 }
    }

    // MARK: Reporting

    @MainActor public func reportPlayback(_ event: ServerPlaybackEvent, track: Track) {
        guard let itemID = track.jellyfinItemId else { return }
        let submission: String
        switch event {
        case .started: submission = "false"
        case .stopped(let position):
            // Scrobble only meaningful listens (half the track or 4 minutes, per common scrobbling rules).
            guard position >= min(240, max(track.duration, 1) / 2) else { return }
            submission = "true"
        case .progress: return
        }
        guard let req = endpointRequest("scrobble", [URLQueryItem(name: "id", value: itemID),
                                                     URLQueryItem(name: "submission", value: submission)], timeout: 15) else { return }
        Task.detached { _ = try? await ServerHTTPClient.data(for: req, session: JellyfinClient.syncSession, maxAttempts: 2) }
    }

    public func signOut() async {
        UserDefaults.standard.removeObject(forKey: scanMarkerKey)
    }
}
