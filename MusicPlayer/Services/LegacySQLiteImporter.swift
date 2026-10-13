import Foundation
import SQLite3

/// Temporary one-time rescue importer for legacy `library.sqlite`.
/// Reads tracks data blobs off the main thread, decodes them, and cleans up sqlite files.
public enum LegacySQLiteImporter {
    public static func importTracksIfNeeded(storageDirectoryURL: URL) -> [Track]? {
        let dbURL = storageDirectoryURL.appendingPathComponent("library.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT data FROM tracks;", -1, &stmt, nil) != SQLITE_OK {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let decoder = PropertyListDecoder()
        var tracks: [Track] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let bytes = sqlite3_column_bytes(stmt, 0)
                let data = Data(bytes: blob, count: Int(bytes))
                if let track = try? decoder.decode(Track.self, from: data) {
                    tracks.append(track)
                }
            }
        }

        return tracks.isEmpty ? nil : tracks
    }

    public static func importAndCleanup(storageDirectoryURL: URL) -> [Track] {
        let tracks = importTracksIfNeeded(storageDirectoryURL: storageDirectoryURL) ?? []
        cleanupLegacyDatabase(storageDirectoryURL: storageDirectoryURL)
        return tracks
    }

    public static func cleanupLegacyDatabase(storageDirectoryURL: URL) {
        let fileManager = FileManager.default
        let dbURL = storageDirectoryURL.appendingPathComponent("library.sqlite")
        let walURL = storageDirectoryURL.appendingPathComponent("library.sqlite-wal")
        let shmURL = storageDirectoryURL.appendingPathComponent("library.sqlite-shm")
        try? fileManager.removeItem(at: dbURL)
        try? fileManager.removeItem(at: walURL)
        try? fileManager.removeItem(at: shmURL)
    }
}
