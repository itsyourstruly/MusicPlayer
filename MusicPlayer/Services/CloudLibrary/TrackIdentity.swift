import Foundation

/// Provides stable, deterministic UUID generation and relative path resolution across app sandboxes and cloud links.
public enum TrackIdentity: Sendable {

    /// Normalizes relative paths to Unicode NFC, lowercases them, and collapses redundant slashes.
    public static func normalizeRelativePath(_ path: String) -> String {
        var normalized = path.precomposedStringWithCanonicalMapping.lowercased()
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        if normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        return normalized
    }

    /// Generates a stable deterministic UUID for local/cloud linked folder tracks.
    public static func localTrackID(folderID: UUID?, relativePath: String) -> UUID {
        let normalizedPath = normalizeRelativePath(relativePath)
        let fID = folderID?.uuidString ?? "root"
        return UUID.deterministic(from: "v2" + fID + normalizedPath)
    }

    /// Deterministic, globally unique ID for a server item, namespaced by source ID and server kind.
    /// For Jellyfin this is byte-for-byte the legacy formula ("jf" + linkUUID + itemID), so migrated
    /// libraries keep identical track IDs (downloads, playlists and play counts stay attached).
    nonisolated public static func serverTrackID(sourceID: UUID, kind: ServerKind, itemID: String) -> UUID {
        return UUID.deterministic(from: kind.identityPrefix + sourceID.uuidString + itemID)
    }

    /// Computes the relative path by stripping the root folder prefix, handling symlinks (/private/var vs /var).
    public static func computeRelativePath(fileURL: URL, folderURL: URL?) -> String {
        guard let folderURL = folderURL else {
            return fileURL.lastPathComponent
        }
        let fileResolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let folderResolved = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        if fileResolved.hasPrefix(folderResolved) {
            var rel = String(fileResolved.dropFirst(folderResolved.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }

        let fileStd = fileURL.standardizedFileURL.path
        let folderStd = folderURL.standardizedFileURL.path
        if fileStd.hasPrefix(folderStd) {
            var rel = String(fileStd.dropFirst(folderStd.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }

        let filePath = fileURL.path
        let folderPath = folderURL.path
        if filePath.hasPrefix(folderPath) {
            var rel = String(filePath.dropFirst(folderPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }

        return fileURL.lastPathComponent
    }
}
