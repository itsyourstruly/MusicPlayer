import Foundation

/// Full-enumeration diff shared by providers without a native "changed since" feed (Subsonic, Plex):
/// emits only new/changed tracks, the removed IDs (deletion sweep) and old->new remaps for items whose
/// server ID changed but whose file (path) or metadata (±1 s duration) is the same.
nonisolated enum ServerChangeDiff {
    static func diff(existing: [Track], fresh: [Track]) -> ServerChangeSet {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let freshIDs = Set(fresh.map(\.id))

        var upserted: [Track] = []
        var added: [Track] = []
        for track in fresh {
            if let old = existingByID[track.id] {
                if signature(old) != signature(track) { upserted.append(track) }
            } else {
                upserted.append(track)
                added.append(track)
            }
        }
        let removed = existing.filter { !freshIDs.contains($0.id) }

        var remapped: [UUID: UUID] = [:]
        if !removed.isEmpty && !added.isEmpty {
            var byPath: [String: UUID] = [:]
            var byMeta: [String: [Track]] = [:]
            for t in added {
                if let p = t.relativePath?.lowercased(), !p.isEmpty { byPath[p] = t.id }
                byMeta[metaKey(t), default: []].append(t)
            }
            var claimed = Set<UUID>()
            for old in removed {
                if let p = old.relativePath?.lowercased(), let new = byPath[p], !claimed.contains(new) {
                    remapped[old.id] = new
                    claimed.insert(new)
                } else if let match = byMeta[metaKey(old)]?.first(where: { !claimed.contains($0.id) && abs($0.duration - old.duration) <= 1 }) {
                    remapped[old.id] = match.id
                    claimed.insert(match.id)
                }
            }
        }
        return ServerChangeSet(upserted: upserted, removedIDs: Set(removed.map(\.id)), remappedIDs: remapped)
    }

    private static func metaKey(_ t: Track) -> String {
        [t.title, t.album, t.albumArtist ?? t.artist, String(t.discNumber ?? 0), String(t.trackNumber ?? 0)]
            .map { $0.lowercased() }.joined(separator: "\u{1F}")
    }

    private static func signature(_ t: Track) -> String {
        [t.title, t.artist, t.album, t.albumArtist ?? "", t.genre ?? "", String(t.year ?? 0),
         String(t.trackNumber ?? 0), String(t.discNumber ?? 0), String(Int(t.duration.rounded())),
         t.relativePath ?? "", t.artworkKey ?? "", t.serverCoverArtId ?? "", t.url.absoluteString,
         t.fileInfo?.fileExtension ?? "", String(t.fileInfo?.fileSizeBytes ?? 0)].joined(separator: "\u{1F}")
    }
}

/// Library-relative paths for folder organization (Phase 5): the server's path when it exposes one,
/// otherwise a synthetic "Album Artist/Album/NN - Title.ext" tree.
nonisolated enum ServerPathBuilder {
    static func relativePath(serverPath: String?, roots: [String] = [], albumArtist: String, album: String,
                             disc: Int?, track: Int?, title: String, ext: String) -> String {
        if var path = serverPath?.replacingOccurrences(of: "\\", with: "/"), !path.isEmpty {
            // Strip the longest matching library root (case-insensitive, case-preserving result).
            for root in roots.sorted(by: { $0.count > $1.count }) {
                let r = root.replacingOccurrences(of: "\\", with: "/")
                let rr = r.hasSuffix("/") ? r : r + "/"
                if path.lowercased().hasPrefix(rr.lowercased()) { path = String(path.dropFirst(rr.count)); break }
            }
            while path.hasPrefix("/") { path.removeFirst() }
            if path.contains("/") { return path }
        }
        func clean(_ s: String) -> String {
            let bad = CharacterSet(charactersIn: "/\\:")
            let c = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? "Unknown" : c
        }
        var file = clean(title) + "." + ext
        if let track { file = String(format: "%02d - ", track) + file }
        if let disc, disc > 1 { file = "\(disc)-" + file }
        return "\(clean(albumArtist))/\(clean(album))/\(file)"
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }
}
