import Foundation
import CryptoKit
import os

// MARK: - Wire Models

/// Subsonic/OpenSubsonic API error (`subsonic-response.error`).
nonisolated struct SubsonicAPIError: Error, Sendable {
    let code: Int
    let message: String

    var clientError: JellyfinClientError {
        // OpenSubsonic error codes: https://opensubsonic.netlify.app/docs/responses/error/
        switch code {
        case 40: return .authenticationFailed("WRONG USERNAME OR PASSWORD")
        case 44: return .authenticationFailed("INVALID API KEY")
        case 41: return .authenticationFailed("SERVER REJECTED TOKEN SIGN-IN (LDAP USER): USE HTTPS OR AN API KEY")
        case 42, 43: return .authenticationFailed("SERVER REJECTED THIS SIGN-IN METHOD")
        case 50: return .authenticationFailed("ACCESS DENIED BY SERVER")
        case 20: return .networkError("APP TOO OLD FOR THIS SERVER")
        case 30: return .networkError("SERVER TOO OLD (UPDATE SERVER)")
        case 60: return .networkError("SUBSONIC LICENSE EXPIRED")
        case 70: return .networkError("ITEM NOT FOUND ON SERVER")
        case 10: return .networkError("SERVER REJECTED REQUEST (CODE 10)")
        default: return .networkError(message.isEmpty ? "SERVER ERROR (CODE \(code))" : "SERVER ERROR (CODE \(code)): \(message.uppercased())")
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
    /// OpenSubsonic credits (artist entities with ids) and display strings.
    let displayArtist: String?
    let artistId: String?
    let artists: [SubsonicArtistRef]?
    let albumArtists: [SubsonicArtistRef]?
    let bitDepth: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, album, artist, artistId, displayAlbumArtist, albumId, track, discNumber, year, genre, coverArt
        case size, suffix, duration, bitRate, samplingRate, channelCount, path, created, isVideo
        case displayArtist, artists, albumArtists, bitDepth
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
        displayArtist = str(.displayArtist)
        artistId = str(.artistId)
        artists = (try? c.decodeIfPresent([SubsonicArtistRef].self, forKey: .artists))?.filter { $0.name != nil }
        albumArtists = (try? c.decodeIfPresent([SubsonicArtistRef].self, forKey: .albumArtists))?.filter { $0.name != nil }
        bitDepth = int(.bitDepth)
    }
}

/// OpenSubsonic `ArtistID3` as embedded in a song's `artists[]` / `albumArtists[]` (only `id` and `name` are needed).
nonisolated struct SubsonicArtistRef: Decodable, Sendable {
    let id: String?
    let name: String?

    enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .id) {
            id = s
        } else if let i = try? c.decodeIfPresent(Int64.self, forKey: .id) {
            id = String(i)
        } else {
            id = nil
        }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
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
    struct Album: Decodable, Sendable {
        let id: String
        let name: String?
        let sortName: String?
        let releaseTypes: [String]?
        let isCompilation: Bool?
        let version: String?
        /// The album's own cover art id (Navidrome `al-…`), served from the server's album artwork cache.
        let coverArt: String?

        enum CodingKeys: String, CodingKey { case id, name, sortName, releaseTypes, isCompilation, version, coverArt }

        // Lenient: unexpected release-info shapes are ignored rather than failing the catalog.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            sortName = try? c.decodeIfPresent(String.self, forKey: .sortName)
            let types = (try? c.decodeIfPresent([String].self, forKey: .releaseTypes)) ?? nil
            releaseTypes = (types?.isEmpty ?? true) ? nil : types
            isCompilation = (try? c.decodeIfPresent(Bool.self, forKey: .isCompilation)) ?? nil
            version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
            coverArt = (try? c.decodeIfPresent(String.self, forKey: .coverArt)) ?? nil
        }
    }
    struct List: Decodable { let album: [Album]? }
    let albumList2: List?
}

nonisolated private struct ArtistsBody: Decodable {
    struct Artist: Decodable { let name: String?; let sortName: String? }
    struct Index: Decodable { let artist: [Artist]? }
    struct Artists: Decodable { let index: [Index]? }
    let artists: Artists?
}

nonisolated private struct AlbumBody: Decodable {
    struct Album: Decodable { let song: [SubsonicSong]? }
    let album: Album?
}

nonisolated private struct ExtensionsBody: Decodable {
    struct Ext: Decodable { let name: String }
    let openSubsonicExtensions: [Ext]?
}

/// OpenSubsonic `getLyricsBySongId` payload (songLyrics extension). `start` is milliseconds.
nonisolated private struct LyricsListBody: Decodable {
    struct Line: Decodable { let start: Int?; let value: String? }
    struct Structured: Decodable { let lang: String?; let synced: Bool?; let offset: Int?; let line: [Line]? }
    struct List: Decodable { let structuredLyrics: [Structured]? }
    let lyricsList: List?
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
        /// OpenSubsonic `songLyrics` extension, read from the same `getOpenSubsonicExtensions` reply; nil when unknown.
        let supportsSongLyrics: Bool?
    }

    /// Probe results for this app session, keyed by server address, so detecting a server and signing in
    /// to it ask `ping` / `getOpenSubsonicExtensions` once.
    private static let probeCache = OSAllocatedUnfairLock<[String: ServerInfo]>(initialState: [:])

    static func cachedProbe(for base: URL) -> ServerInfo? {
        probeCache.withLock { $0[base.absoluteString.lowercased()] }
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
        // Errors arrive as HTTP 200 with status "failed"; anything that is not a subsonic-response
        // (reverse-proxy HTML, SPA index, wrong subpath) means the address is not a Subsonic API.
        guard let status = try? JSONDecoder().decode(SubsonicStatus.self, from: data).body else {
            throw JellyfinClientError.unreachable("NOT A SUBSONIC SERVER (CHECK ADDRESS/PATH)")
        }
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
        var supportsSongLyrics: Bool? = body.openSubsonic == true ? nil : false
        if body.openSubsonic == true,
           let ext = try? await request(ExtensionsBody.self, base: base, endpoint: "getOpenSubsonicExtensions", auth: nil, timeout: timeout, session: session) {
            supportsAPIKey = ext.openSubsonicExtensions?.contains { $0.name == "apiKeyAuthentication" } ?? false
            supportsSongLyrics = ext.openSubsonicExtensions?.contains { $0.name == "songLyrics" } ?? false
        }
        let info = ServerInfo(type: body.type, serverVersion: body.serverVersion, openSubsonic: body.openSubsonic == true,
                              supportsAPIKey: supportsAPIKey, supportsSongLyrics: supportsSongLyrics)
        probeCache.withLock { $0[base.absoluteString.lowercased()] = info }
        return info
    }

    /// Signs in: apiKey when given, else token+salt, falling back to `enc:` password auth on error 41.
    static func authenticate(base: URL, userName: String, password: String, apiKey: String?) async throws -> (ServerSourceLink, ServerCredentials) {
        // Reuses the detection probe from the sign-in sheet instead of asking the server again.
        let info: ServerInfo?
        if let cached = cachedProbe(for: base) {
            info = cached
        } else {
            info = await probe(base: base)
        }
        var creds: ServerCredentials
        if let apiKey, !apiKey.isEmpty {
            creds = ServerCredentials(apiKey: apiKey)
        } else {
            creds = ServerCredentials(password: password)
        }
        do {
            _ = try await request(SubsonicStatus.Body?.self, base: base, endpoint: "ping", auth: authItems(userName: userName, credentials: creds))
        } catch let err as SubsonicAPIError where err.code == 41 && creds.apiKey == nil
                    && base.scheme?.lowercased() == "https" {
            // Legacy `enc:` auth sends a reversibly encoded password: only over HTTPS.
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

    /// Fail-fast pre-sync check: an authenticated ping (8 s) verifies reachability and credentials together.
    public func prepareSession() async throws {
        do {
            _ = try await SubsonicClient.request(SubsonicStatus.Body?.self, base: link.serverURL, endpoint: "ping",
                                                 auth: try auth(), timeout: 8)
        } catch let err as SubsonicAPIError {
            throw (err.code == 40 || err.code == 44) ? JellyfinClientError.reauthRequired : err.clientError
        }
    }

    // MARK: Sync

    public func fetchTrackChanges(
        existingTracks: [Track],
        lastSyncDate: Date?,
        statusHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ServerChangeSet {
        // Cheap change check: skip enumeration when the server's last scan is unchanged and a full
        // sweep (deletion detection) ran within 24 h. Manual rescans clear the marker first.
        Self.albumHandoff.clear(for: link.id)
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
        // Album entities (getAlbumList2) carry the album's own coverArt id; songs fall back to their own. Only the
        // album walk needs them, so a failed listing does not fail a search-based sync.
        let walked: [AlbumListBody.Album]?
        if songs.isEmpty {
            walked = try await fetchAlbumEntities()
        } else {
            walked = try? await fetchAlbumEntities()
        }
        // One getAlbumList2 walk per sync: fetchCatalog() reuses this list.
        if let walked { Self.albumHandoff.set(walked, for: link.id) }
        let albums = walked ?? []
        try Task.checkCancellation()
        if songs.isEmpty {
            songs = try await fetchAllSongsViaAlbums(albumIDs: albums.map(\.id), statusHandler: statusHandler)
        }
        var albumCoverArt: [String: String] = [:]
        for album in albums {
            if let cover = album.coverArt, !cover.isEmpty { albumCoverArt[album.id] = cover }
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
            let albumCover = song.albumId.flatMap { albumCoverArt[$0] }
            mapped.append(mapSong(song, id: id, existing: existingByID[id], albumCoverArt: albumCover))
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
        // One page at a time, stopping at the first short page: no request past the end of the library.
        while !finished {
            try Task.checkCancellation()
            let songs = try await call(SearchResultBody.self, "search3", [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: String(Self.pageSize)),
                URLQueryItem(name: "songOffset", value: String(offset))
            ]).searchResult3?.song ?? []
            for s in songs where seenInSearch.insert(s.id).inserted {
                all.append(s)
            }
            if songs.count < Self.pageSize { finished = true }
            offset += Self.pageSize
            progressHandler?(all.count, max(all.count, existingCount))
        }
        return all
    }

    /// Every album entity (getAlbumList2, 500 per page), de-duplicated by id.
    private func fetchAlbumEntities() async throws -> [AlbumListBody.Album] {
        var albums: [AlbumListBody.Album] = []
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
            for alb in page where seenAlbumIDs.insert(alb.id).inserted {
                albums.append(alb)
            }
            if page.count < 500 { break }
            offset += 500
        }
        return albums
    }

    /// Fallback for servers whose search3 ignores the empty query: walk albums.
    private func fetchAllSongsViaAlbums(albumIDs: [String], statusHandler: (@Sendable (String) -> Void)?) async throws -> [SubsonicSong] {
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

    /// `albumCoverArt` is the album entity's coverArt id; every track of the album then shares one image id and
    /// version (so first-wins and last-wins registration agree). Falls back to the song's own coverArt.
    private func mapSong(_ song: SubsonicSong, id: UUID, existing: Track?, albumCoverArt: String?) -> Track {
        let title = song.title ?? "Unknown Title"
        let album = song.album ?? "Unknown Album"
        let albumArtist = song.displayAlbumArtist.flatMap { $0.isEmpty ? nil : $0 }
        let artist = song.displayArtist.flatMap { $0.isEmpty ? nil : $0 } ?? song.artist ?? albumArtist ?? "Unknown Artist"
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
        let coverArtId = albumCoverArt ?? song.coverArt
        let artworkKey = coverArtId == nil ? nil : "ss_\(sourcePrefix)_\(albumKey)"
        let relativePath = ServerPathBuilder.relativePath(serverPath: song.path, albumArtist: albumArtist ?? artist,
                                                          album: album, disc: song.discNumber, track: song.track,
                                                          title: title, ext: ext)
        // OpenSubsonic servers list album-artist / artist entities (ArtistID3 id + name); legacy servers only give
        // display strings, which become a single credit (with the legacy `artistId` when present).
        let entityArtists = song.artists ?? []
        let albumArtistEntities = song.albumArtists ?? []
        let legacyAlbumArtistID: String? = albumArtist == nil ? song.artistId : nil
        let credits = ServerCredits(
            albumArtists: albumArtistEntities.isEmpty ? [albumArtist ?? artist] : albumArtistEntities.compactMap(\.name),
            artists: entityArtists.isEmpty ? [artist] : entityArtists.compactMap(\.name),
            artistsAreEntities: !entityArtists.isEmpty,
            bitDepth: song.bitDepth.flatMap { $0 > 0 ? $0 : nil },
            imageVersion: coverArtId,
            albumArtistIDs: albumArtistEntities.isEmpty ? [legacyAlbumArtistID] : albumArtistEntities.map(\.id),
            artistIDs: entityArtists.isEmpty ? [song.artistId] : entityArtists.map(\.id)
        )
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
            serverCoverArtId: coverArtId,
            serverCredits: credits
        )
    }

    // MARK: Catalog

    /// Artist and album sort names (OpenSubsonic `sortName`); servers without them yield an empty catalog.
    public func fetchCatalog() async throws -> ServerCatalog {
        var catalog = ServerCatalog()
        let artists = try await call(ArtistsBody.self, "getArtists")
        for index in artists.artists?.index ?? [] {
            for artist in index.artist ?? [] {
                catalog.addArtist(name: artist.name, sortName: artist.sortName)
            }
        }
        let sourcePrefix = String(link.id.uuidString.prefix(8))
        // The sync's own album walk when there was one; otherwise walk once here.
        let albums: [AlbumListBody.Album]
        if let handedOff = Self.albumHandoff.take(for: link.id) {
            albums = handedOff
        } else {
            albums = try await fetchAlbumEntities()
        }
        for album in albums {
            catalog.addAlbum(key: "\(sourcePrefix)_\(album.id)", title: album.name, sortName: album.sortName)
            catalog.addReleaseInfo(key: "\(sourcePrefix)_\(album.id)", releaseTypes: album.releaseTypes, isCompilation: album.isCompilation, version: album.version, source: "subsonic")
        }
        return catalog
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

    public func artworkRequests(imageId: String, size: ArtworkFetchSize, version: String?) -> [URLRequest] {
        var params = [URLQueryItem(name: "id", value: imageId)]
        if size == .thumbnail {
            // Navidrome precaches every cover at its UI cover size (UICoverArtSize, default 300) with square=true,
            // and its web UI lists request exactly that key, so this is served from the resize cache.
            params += [URLQueryItem(name: "size", value: "300"), URLQueryItem(name: "square", value: "true")]
        }
        return [endpointRequest("getCoverArt", params, timeout: size.requestTimeout)].compactMap { $0 }
    }

    // MARK: Lyrics

    /// Per-source cache of whether the server advertises the OpenSubsonic `songLyrics` extension.
    private static let lyricsSupport = SubsonicExtensionSupportCache()
    private static let albumHandoff = SubsonicAlbumHandoff()

    /// Lyrics via OpenSubsonic `getLyricsBySongId` (signed). Falls back to nil when the server lacks the
    /// songLyrics extension, has no lyrics, or the request fails.
    public func fetchLyrics(for track: Track) async -> String? {
        guard let itemID = track.jellyfinItemId, let auth = try? auth() else { return nil }
        if await !supportsSongLyrics(auth: auth) { return nil }
        guard let body = try? await SubsonicClient.request(
            LyricsListBody.self, base: link.serverURL, endpoint: "getLyricsBySongId",
            params: [URLQueryItem(name: "id", value: itemID)], auth: auth, timeout: 15) else { return nil }
        let entries = body.lyricsList?.structuredLyrics ?? []
        guard let pick = entries.first(where: { $0.synced == true }) ?? entries.first,
              let lines = pick.line, !lines.isEmpty else { return nil }
        let text: String
        if pick.synced == true {
            let offset = pick.offset ?? 0
            text = lines.map { line in
                let ms = max(0, (line.start ?? 0) - offset)
                let cs = (ms % 1000) / 10
                return String(format: "[%02d:%02d.%02d]", ms / 60000, (ms / 1000) % 60, cs) + (line.value ?? "")
            }.joined(separator: "\n")
        } else {
            text = lines.compactMap(\.value).joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func supportsSongLyrics(auth: [URLQueryItem]) async -> Bool {
        if let known = Self.lyricsSupport.value(for: link.id) { return known }
        // Signed in this session: the sign-in probe already read the extension list.
        if let probed = SubsonicClient.cachedProbe(for: link.serverURL)?.supportsSongLyrics {
            Self.lyricsSupport.set(probed, for: link.id)
            return probed
        }
        guard let ext = try? await SubsonicClient.request(
            ExtensionsBody.self, base: link.serverURL, endpoint: "getOpenSubsonicExtensions",
            auth: auth, timeout: 10) else {
            // Cached for this session too, so a failing server is not asked again on every song.
            Self.lyricsSupport.set(false, for: link.id)
            return false
        }
        let supported = ext.openSubsonicExtensions?.contains { $0.name == "songLyrics" } ?? false
        Self.lyricsSupport.set(supported, for: link.id)
        return supported
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

/// Small lock-protected UUID -> Bool map (OpenSubsonic extension support per source).
nonisolated final class SubsonicExtensionSupportCache: Sendable {
    private let state = OSAllocatedUnfairLock<[UUID: Bool]>(initialState: [:])
    func value(for id: UUID) -> Bool? { state.withLock { $0[id] } }
    func set(_ value: Bool, for id: UUID) { state.withLock { $0[id] = value } }
}

/// Album list from a sync's getAlbumList2 walk, handed to the catalog fetch of the same sync.
nonisolated private final class SubsonicAlbumHandoff: Sendable {
    private let state = OSAllocatedUnfairLock<[UUID: [AlbumListBody.Album]]>(initialState: [:])
    func set(_ albums: [AlbumListBody.Album], for id: UUID) { state.withLock { $0[id] = albums } }
    func clear(for id: UUID) { _ = state.withLock { $0.removeValue(forKey: id) } }
    /// Returns and forgets the list, so it is used once and not kept in memory.
    func take(for id: UUID) -> [AlbumListBody.Album]? { state.withLock { $0.removeValue(forKey: id) } }
}

// MARK: - Descriptions (getArtistInfo2 biography / getAlbumInfo2 notes)

nonisolated private struct ArtistInfo2Body: Decodable {
    struct Info: Decodable { let biography: String? }
    let artistInfo2: Info?
}

nonisolated private struct AlbumInfo2Body: Decodable {
    struct Info: Decodable { let notes: String? }
    let albumInfo: Info?
}

nonisolated extension SubsonicProvider {
    /// One request per page open. `count=0` asks for no similar artists, only the biography.
    /// Error 70 (data not found) means the server has no description, which is a valid answer.
    public func fetchDescription(_ kind: ServerDescriptionKind, itemId: String) async throws -> String? {
        let idItem = URLQueryItem(name: "id", value: itemId)
        do {
            switch kind {
            case .artist:
                let body = try await SubsonicClient.request(
                    ArtistInfo2Body.self, base: link.serverURL, endpoint: "getArtistInfo2",
                    params: [idItem, URLQueryItem(name: "count", value: "0")], auth: try auth(), timeout: 15)
                return body.artistInfo2?.biography
            case .album:
                let body = try await SubsonicClient.request(
                    AlbumInfo2Body.self, base: link.serverURL, endpoint: "getAlbumInfo2",
                    params: [idItem], auth: try auth(), timeout: 15)
                return body.albumInfo?.notes
            }
        } catch let error as SubsonicAPIError where error.code == 70 {
            return nil
        }
    }
}
