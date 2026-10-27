import Foundation

// MARK: - ServerDescriptionTarget

/// The server item an artist or album page can show a description for (Navidrome/Subsonic, Jellyfin, Plex).
nonisolated struct ServerDescriptionTarget: Hashable, Sendable {
    let serverID: UUID
    let kind: ServerDescriptionKind
    let itemId: String

    var cacheKey: String { "\(serverID.uuidString)|\(kind.rawValue)|\(itemId)" }

    /// Uses the album's first server track: the raw server album id (Subsonic and Plex ids carry an
    /// 8-character source prefix plus "_"; a synthetic "artist|album" key has no server item).
    static func album(_ album: Album, sources: [ServerSourceLink]) -> ServerDescriptionTarget? {
        for track in album.tracks where OfflineMode.isServerTrack(track) {
            guard let link = supportedLink(for: track, sources: sources),
                  let stored = track.jellyfinAlbumId, !stored.isEmpty else { continue }
            let raw = link.kind == .jellyfin ? stored : String(stored.dropFirst(9))
            guard !raw.isEmpty, !raw.contains("|") else { continue }
            return ServerDescriptionTarget(serverID: link.id, kind: .album, itemId: raw)
        }
        return nil
    }

    /// Uses the server artist id stored next to the matching album-artist credit on the artist's tracks.
    static func artist(_ artist: Artist, sources: [ServerSourceLink]) -> ServerDescriptionTarget? {
        let name = artist.name
        for track in artist.tracks where OfflineMode.isServerTrack(track) {
            guard let link = supportedLink(for: track, sources: sources),
                  let credits = track.serverCredits, let ids = credits.albumArtistIDs else { continue }
            let index = credits.albumArtists.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
                ?? (credits.albumArtists.count == 1 ? 0 : nil)
            guard let index, ids.indices.contains(index), case let id = ids[index], !id.isEmpty else { continue }
            return ServerDescriptionTarget(serverID: link.id, kind: .artist, itemId: id)
        }
        return nil
    }

    private static func supportedLink(for track: Track, sources: [ServerSourceLink]) -> ServerSourceLink? {
        guard let link = sources.first(where: { $0.id == track.folderID }) else { return nil }
        switch link.kind {
        case .subsonic, .jellyfin, .plex: return link
        case .emby: return nil
        }
    }
}

// MARK: - ServerDescriptionCache

/// Artist biographies and album notes, cleaned and stored on disk per server + item, including
/// "no description" answers (empty string). Requests are only made when a page asks, are deduplicated
/// while in flight, and never happen while Offline is on. Failures are not stored, so they retry next open.
actor ServerDescriptionCache {
    static let shared = ServerDescriptionCache()

    private var entries: [String: String] = [:]
    private var isLoaded = false
    private var inFlight: [String: Task<String?, Never>] = [:]

    private let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("ServerDescriptions.json")
    }()

    /// Cleaned description, or nil when the server has none (or the request failed).
    func description(for target: ServerDescriptionTarget, link: ServerSourceLink) async -> String? {
        loadIfNeeded()
        let key = target.cacheKey
        if let cached = entries[key] { return cached.isEmpty ? nil : cached }
        guard !OfflineMode.isEnabled, let provider = ServerProviderRegistry.provider(for: link) else { return nil }
        if let running = inFlight[key] { return await running.value }
        let task = Task<String?, Never> {
            do {
                let raw = try await provider.fetchDescription(target.kind, itemId: target.itemId)
                return Self.clean(raw ?? "")
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        // nil = failed (not stored); "" = the server has no description (stored).
        guard let result else { return nil }
        entries[key] = result
        save()
        return result.isEmpty ? nil : result
    }

    /// Manual rescan: forget this source's "no description" answers so newly added ones can appear.
    func clearMissing(serverID: UUID) {
        loadIfNeeded()
        let prefix = serverID.uuidString + "|"
        let before = entries.count
        entries = entries.filter { !($0.key.hasPrefix(prefix) && $0.value.isEmpty) }
        if entries.count != before { save() }
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Cleaning

    /// Strips HTML, removes Last.fm's "Read more on Last.fm" link, decodes entities and trims.
    nonisolated static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"<a\b[^>]*>\s*Read more on Last\.fm\s*</a>\.?"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"Read more on Last\.fm\.?"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<br\s*/?>|</p\s*>"#, with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    private nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[body.lowercased()]
            }
            result += replacement ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
