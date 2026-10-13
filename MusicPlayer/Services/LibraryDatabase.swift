import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Unified SQLite + FTS5 persistent storage engine for the music library.
/// Uses native libsqlite3 with Write-Ahead Logging (WAL) and FTS5 full-text indexing.
public final class LibraryDatabase: @unchecked Sendable {
    public static let shared = LibraryDatabase()

    private let dbPath: String
    private var writeDB: OpaquePointer?
    private var readDB: OpaquePointer?

    private let writeQueue = DispatchQueue(label: "com.musicplayer.database.write", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "com.musicplayer.database.read", qos: .userInitiated, attributes: .concurrent)

    // Tokenizer determined via runtime probe
    public private(set) var isTrigramTokenizerSupported: Bool = false
    public private(set) var ftsTokenizerName: String = "unicode61 remove_diacritics 2"

    // Prepared statements for write operations
    private var insertTrackStmt: OpaquePointer?
    private var insertAlbumStmt: OpaquePointer?
    private var insertArtistStmt: OpaquePointer?
    private var insertAlbumTrackStmt: OpaquePointer?
    private var insertFtsStmt: OpaquePointer?
    private var deleteTrackFtsStmt: OpaquePointer?
    private var deleteAlbumFtsStmt: OpaquePointer?
    private var deleteArtistFtsStmt: OpaquePointer?
    private var deleteTrackStmt: OpaquePointer?
    private var deleteAlbumStmt: OpaquePointer?
    private var deleteArtistStmt: OpaquePointer?
    private var deleteAlbumTracksForAlbumStmt: OpaquePointer?
    private var deleteAlbumTracksForTrackStmt: OpaquePointer?
    private var setMetaStmt: OpaquePointer?

    public init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("MusicPlayerData", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.dbPath = dir.appendingPathComponent("library.sqlite").path

        openConnections()
        probeFtsTokenizer()
        createSchema()
        prepareStatements()
    }

    deinit {
        finalizeStatements()
        if let w = writeDB { sqlite3_close_v2(w) }
        if let r = readDB { sqlite3_close_v2(r) }
    }

    // MARK: - Connections & Pragmas

    private func openConnections() {
        // Open write connection
        let writeFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &writeDB, writeFlags, nil) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(writeDB))
            AppLogger.storage.error("Failed to open write SQLite connection at \(self.dbPath): \(err)")
        }

        // Apply WAL and performance pragmas to write connection
        executePragmas(on: writeDB)

        // Open read-only connection for concurrent queries
        let readFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &readDB, readFlags, nil) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(readDB))
            AppLogger.storage.warning("Failed to open read SQLite connection: \(err). Falling back to write connection.")
            readDB = writeDB
        } else {
            executePragmas(on: readDB)
        }
    }

    private func executePragmas(on connection: OpaquePointer?) {
        guard let db = connection else { return }
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456;", nil, nil, nil) // 256 MB
        sqlite3_exec(db, "PRAGMA cache_size = -64000;", nil, nil, nil)   // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
    }

    // MARK: - Tokenizer Probe

    private func probeFtsTokenizer() {
        guard let db = writeDB else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let probeSQL = "CREATE VIRTUAL TABLE IF NOT EXISTS temp.fts_probe USING fts5(x, tokenize='trigram');"
        if sqlite3_exec(db, probeSQL, nil, nil, &errMsg) == SQLITE_OK {
            sqlite3_exec(db, "DROP TABLE IF EXISTS temp.fts_probe;", nil, nil, nil)
            self.isTrigramTokenizerSupported = true
            self.ftsTokenizerName = "trigram"
            AppLogger.storage.info("SQLite FTS5 trigram tokenizer available and selected.")
        } else {
            if let err = errMsg {
                AppLogger.storage.info("SQLite FTS5 trigram probe failed (\(String(cString: err))). Falling back to unicode61.")
                sqlite3_free(errMsg)
            }
            self.isTrigramTokenizerSupported = false
            self.ftsTokenizerName = "unicode61 remove_diacritics 2"
        }
    }

    // MARK: - Schema

    private func createSchema() {
        guard let db = writeDB else { return }

        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY,
            folder_id TEXT,
            jellyfin_item_id TEXT,
            date_last_saved REAL,
            title TEXT,
            artist TEXT,
            album TEXT,
            genre TEXT,
            search_tokens TEXT,
            duration REAL,
            year INTEGER,
            track_number INTEGER,
            disc_number INTEGER,
            data BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS albums (
            id TEXT PRIMARY KEY,
            artist_key TEXT,
            title TEXT,
            artist TEXT,
            year INTEGER,
            genre TEXT,
            artwork_key TEXT,
            group_key TEXT,
            track_count INTEGER,
            data BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS artists (
            id TEXT PRIMARY KEY,
            name TEXT,
            artist_key TEXT,
            data BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS album_tracks (
            album_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (album_id, track_id)
        );

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_tracks_jellyfin ON tracks(jellyfin_item_id);
        CREATE INDEX IF NOT EXISTS idx_tracks_folder ON tracks(folder_id);
        CREATE INDEX IF NOT EXISTS idx_albums_artist_key ON albums(artist_key);
        CREATE INDEX IF NOT EXISTS idx_album_tracks_album ON album_tracks(album_id);
        CREATE INDEX IF NOT EXISTS idx_album_tracks_track ON album_tracks(track_id);

        CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
            kind UNINDEXED,
            entity_id UNINDEXED,
            title,
            artist,
            album,
            search_tokens,
            tokenize='\(ftsTokenizerName)'
        );
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, schemaSQL, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                AppLogger.storage.error("Schema creation failed: \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Prepared Statements

    private func prepareStatements() {
        guard let db = writeDB else { return }

        let prepare = { (sql: String, ptr: inout OpaquePointer?) in
            sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &ptr, nil)
        }

        prepare("""
        INSERT OR REPLACE INTO tracks(
            id, folder_id, jellyfin_item_id, date_last_saved, title, artist, album,
            genre, search_tokens, duration, year, track_number, disc_number, data
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, &insertTrackStmt)

        prepare("""
        INSERT OR REPLACE INTO albums(
            id, artist_key, title, artist, year, genre, artwork_key, group_key, track_count, data
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, &insertAlbumStmt)

        prepare("""
        INSERT OR REPLACE INTO artists(id, name, artist_key, data) VALUES(?, ?, ?, ?);
        """, &insertArtistStmt)

        prepare("""
        INSERT OR REPLACE INTO album_tracks(album_id, track_id, position) VALUES(?, ?, ?);
        """, &insertAlbumTrackStmt)

        prepare("""
        INSERT INTO search_fts(kind, entity_id, title, artist, album, search_tokens)
        VALUES(?, ?, ?, ?, ?, ?);
        """, &insertFtsStmt)

        prepare("DELETE FROM search_fts WHERE kind = 'track' AND entity_id = ?;", &deleteTrackFtsStmt)
        prepare("DELETE FROM search_fts WHERE kind = 'album' AND entity_id = ?;", &deleteAlbumFtsStmt)
        prepare("DELETE FROM search_fts WHERE kind = 'artist' AND entity_id = ?;", &deleteArtistFtsStmt)

        prepare("DELETE FROM tracks WHERE id = ?;", &deleteTrackStmt)
        prepare("DELETE FROM albums WHERE id = ?;", &deleteAlbumStmt)
        prepare("DELETE FROM artists WHERE id = ?;", &deleteArtistStmt)
        prepare("DELETE FROM album_tracks WHERE album_id = ?;", &deleteAlbumTracksForAlbumStmt)
        prepare("DELETE FROM album_tracks WHERE track_id = ?;", &deleteAlbumTracksForTrackStmt)

        prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);", &setMetaStmt)
    }

    private func finalizeStatements() {
        sqlite3_finalize(insertTrackStmt)
        sqlite3_finalize(insertAlbumStmt)
        sqlite3_finalize(insertArtistStmt)
        sqlite3_finalize(insertAlbumTrackStmt)
        sqlite3_finalize(insertFtsStmt)
        sqlite3_finalize(deleteTrackFtsStmt)
        sqlite3_finalize(deleteAlbumFtsStmt)
        sqlite3_finalize(deleteArtistFtsStmt)
        sqlite3_finalize(deleteTrackStmt)
        sqlite3_finalize(deleteAlbumStmt)
        sqlite3_finalize(deleteArtistStmt)
        sqlite3_finalize(deleteAlbumTracksForAlbumStmt)
        sqlite3_finalize(deleteAlbumTracksForTrackStmt)
        sqlite3_finalize(setMetaStmt)
    }

    // MARK: - Database Inspection

    public func hasTracks() -> Bool {
        return readQueue.sync {
            guard let db = readDB ?? writeDB else { return false }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT 1 FROM tracks LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
                return sqlite3_step(stmt) == SQLITE_ROW
            }
            return false
        }
    }

    public func getMeta(key: String) -> String? {
        return readQueue.sync {
            guard let db = readDB ?? writeDB else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
                    return String(cString: cStr)
                }
            }
            return nil
        }
    }

    public func setMeta(key: String, value: String) {
        writeQueue.sync {
            guard let stmt = setMetaStmt else { return }
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Full Library Read (< 20 ms)

    public func readLibrary() -> (
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        artistLookupIndex: [String: Artist]
    ) {
        return readQueue.sync {
            guard let db = readDB ?? writeDB else {
                return ([], [], [], [:])
            }

            let decoder = PropertyListDecoder()

            // 1. Read all tracks
            var tracks: [Track] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT data FROM tracks;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let blob = sqlite3_column_blob(stmt, 0) {
                        let bytes = sqlite3_column_bytes(stmt, 0)
                        let data = Data(bytes: blob, count: Int(bytes))
                        if let track = try? decoder.decode(Track.self, from: data) {
                            tracks.append(track)
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
            stmt = nil

            // 2. Read all albums
            var albums: [Album] = []
            if sqlite3_prepare_v2(db, "SELECT data FROM albums;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let blob = sqlite3_column_blob(stmt, 0) {
                        let bytes = sqlite3_column_bytes(stmt, 0)
                        let data = Data(bytes: blob, count: Int(bytes))
                        if let album = try? decoder.decode(Album.self, from: data) {
                            albums.append(album)
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
            stmt = nil

            // 3. Read all artists & build lookup
            var artists: [Artist] = []
            var lookup: [String: Artist] = [:]
            lookup.reserveCapacity(albums.count)
            if sqlite3_prepare_v2(db, "SELECT data FROM artists;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let blob = sqlite3_column_blob(stmt, 0) {
                        let bytes = sqlite3_column_bytes(stmt, 0)
                        let data = Data(bytes: blob, count: Int(bytes))
                        if let artist = try? decoder.decode(Artist.self, from: data) {
                            artists.append(artist)
                            let canon = ArtistParser.canonicalArtistKey(artist.name)
                            if !canon.isEmpty { lookup[canon] = artist }
                            let lower = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            if !lower.isEmpty { lookup[lower] = artist }
                            lookup[artist.id] = artist
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)

            return (tracks, albums, artists, lookup)
        }
    }

    // MARK: - Save Library (Batch Transaction)

    public func saveLibrary(tracks: [Track], albums: [Album], artists: [Artist]) {
        writeQueue.sync {
            guard let db = writeDB else { return }
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

            // Clear existing data for full overwrite
            sqlite3_exec(db, "DELETE FROM tracks;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM albums;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM artists;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM album_tracks;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM search_fts;", nil, nil, nil)

            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary

            // 1. Insert tracks & search_fts
            for track in tracks {
                self.bindAndStepTrack(track, encoder: encoder)
                self.bindAndStepFts(
                    kind: "track",
                    entityID: track.id.uuidString,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    searchTokens: track.searchTokens
                )
            }

            // 2. Insert albums, album_tracks, & search_fts
            for album in albums {
                self.bindAndStepAlbum(album, encoder: encoder)
                self.bindAndStepFts(
                    kind: "album",
                    entityID: album.id,
                    title: album.title,
                    artist: album.artist,
                    album: "",
                    searchTokens: album.searchTokens
                )

                if let stmt = insertAlbumTrackStmt {
                    for (pos, t) in album.tracks.enumerated() {
                        sqlite3_reset(stmt)
                        sqlite3_bind_text(stmt, 1, (album.id as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (t.id.uuidString as NSString).utf8String, -1, nil)
                        sqlite3_bind_int(stmt, 3, Int32(pos))
                        sqlite3_step(stmt)
                    }
                }
            }

            // 3. Insert artists & search_fts
            for artist in artists {
                self.bindAndStepArtist(artist, encoder: encoder)
                self.bindAndStepFts(
                    kind: "artist",
                    entityID: artist.id,
                    title: "",
                    artist: artist.name,
                    album: "",
                    searchTokens: artist.searchTokens
                )
            }

            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    // MARK: - Incremental Track Changes

    public func applyTrackChanges(
        inserted: [Track] = [],
        updated: [Track] = [],
        removedIDs: Set<UUID> = [],
        updatedAlbums: [Album] = [],
        updatedArtists: [Artist] = [],
        removedAlbumIDs: Set<String> = [],
        removedArtistIDs: Set<String> = []
    ) {
        writeQueue.sync {
            guard let db = writeDB else { return }
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary

            // 1. Delete removed tracks
            for id in removedIDs {
                let idStr = id.uuidString
                if let stmt = deleteTrackStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                if let stmt = deleteTrackFtsStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                if let stmt = deleteAlbumTracksForTrackStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
            }

            // 2. Upsert updated tracks
            for track in updated {
                let idStr = track.id.uuidString
                if let stmt = deleteTrackFtsStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                self.bindAndStepTrack(track, encoder: encoder)
                self.bindAndStepFts(
                    kind: "track",
                    entityID: idStr,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    searchTokens: track.searchTokens
                )
            }

            // 3. Insert new tracks
            for track in inserted {
                let idStr = track.id.uuidString
                self.bindAndStepTrack(track, encoder: encoder)
                self.bindAndStepFts(
                    kind: "track",
                    entityID: idStr,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    searchTokens: track.searchTokens
                )
            }

            // 4. Delete removed albums
            for albID in removedAlbumIDs {
                if let stmt = deleteAlbumStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (albID as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                if let stmt = deleteAlbumFtsStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (albID as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                if let stmt = deleteAlbumTracksForAlbumStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (albID as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
            }

            // 5. Upsert updated albums
            for album in updatedAlbums {
                if let stmt = deleteAlbumFtsStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (album.id as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                if let stmt = deleteAlbumTracksForAlbumStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (album.id as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }

                self.bindAndStepAlbum(album, encoder: encoder)
                self.bindAndStepFts(
                    kind: "album",
                    entityID: album.id,
                    title: album.title,
                    artist: album.artist,
                    album: "",
                    searchTokens: album.searchTokens
                )

                if let stmt = insertAlbumTrackStmt {
                    for (pos, t) in album.tracks.enumerated() {
                        sqlite3_reset(stmt)
                        sqlite3_bind_text(stmt, 1, (album.id as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (t.id.uuidString as NSString).utf8String, -1, nil)
                        sqlite3_bind_int(stmt, 3, Int32(pos))
                        sqlite3_step(stmt)
                    }
                }
            }

            // 6. Delete removed artists
            for artID in removedArtistIDs {
                if let stmt = deleteArtistStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (artID as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                if let stmt = deleteArtistFtsStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (artID as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
            }

            // 7. Upsert updated artists
            for artist in updatedArtists {
                if let stmt = deleteArtistFtsStmt {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (artist.id as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                self.bindAndStepArtist(artist, encoder: encoder)
                self.bindAndStepFts(
                    kind: "artist",
                    entityID: artist.id,
                    title: "",
                    artist: artist.name,
                    album: "",
                    searchTokens: artist.searchTokens
                )
            }

            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    // MARK: - Internal Statement Helpers

    private func bindAndStepTrack(_ track: Track, encoder: PropertyListEncoder) {
        guard let stmt = insertTrackStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, (track.id.uuidString as NSString).utf8String, -1, nil)
        if let fID = track.folderID {
            sqlite3_bind_text(stmt, 2, (fID.uuidString as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let jID = track.jellyfinItemId {
            sqlite3_bind_text(stmt, 3, (jID as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, track.dateAdded.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, (track.title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (track.artist as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (track.album as NSString).utf8String, -1, nil)
        if let g = track.genre {
            sqlite3_bind_text(stmt, 8, (g as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_text(stmt, 9, (track.searchTokens as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 10, track.duration)
        if let y = track.year {
            sqlite3_bind_int(stmt, 11, Int32(y))
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        if let tn = track.trackNumber {
            sqlite3_bind_int(stmt, 12, Int32(tn))
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        if let dn = track.discNumber {
            sqlite3_bind_int(stmt, 13, Int32(dn))
        } else {
            sqlite3_bind_null(stmt, 13)
        }

        if let data = try? encoder.encode(track) {
            data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 14, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        sqlite3_step(stmt)
    }

    private func bindAndStepAlbum(_ album: Album, encoder: PropertyListEncoder) {
        guard let stmt = insertAlbumStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, (album.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (album.normalizedArtist as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (album.title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (album.artist as NSString).utf8String, -1, nil)
        if let y = album.resolvedYear ?? album.year {
            sqlite3_bind_int(stmt, 5, Int32(y))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let g = album.genre {
            sqlite3_bind_text(stmt, 6, (g as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let art = album.artworkKey {
            sqlite3_bind_text(stmt, 7, (art as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let gk = album.groupKey {
            sqlite3_bind_text(stmt, 8, (gk as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int(stmt, 9, Int32(album.tracks.count))

        if let data = try? encoder.encode(album) {
            data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 10, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_step(stmt)
    }

    private func bindAndStepArtist(_ artist: Artist, encoder: PropertyListEncoder) {
        guard let stmt = insertArtistStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, (artist.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (artist.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (artist.normalizedName as NSString).utf8String, -1, nil)

        if let data = try? encoder.encode(artist) {
            data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_step(stmt)
    }

    private func bindAndStepFts(
        kind: String,
        entityID: String,
        title: String,
        artist: String,
        album: String,
        searchTokens: String
    ) {
        guard let stmt = insertFtsStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, (kind as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (entityID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (artist as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (album as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (searchTokens as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    // MARK: - FTS5 Search API (< 1 ms on Dedicated Read Connection)

    public func searchFTS(
        query: String,
        maxTracks: Int = 80,
        maxAlbums: Int = 40,
        maxArtists: Int = 40,
        maxPlaylists: Int = 20
    ) -> (trackIDs: [UUID], albumIDs: [String], artistIDs: [String], playlistIDs: [UUID]) {
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard !cleanQuery.isEmpty else {
            return ([], [], [], [])
        }

        return readQueue.sync {
            guard let db = readDB ?? writeDB else {
                return ([], [], [], [])
            }

            var trackIDs: [UUID] = []
            var albumIDs: [String] = []
            var artistIDs: [String] = []
            var playlistIDs: [UUID] = []

            let isTrigram = self.isTrigramTokenizerSupported
            let queryCount = cleanQuery.count

            if isTrigram && queryCount >= 3 {
                // 1. Trigram Substring Search
                let escaped = cleanQuery.replacingOccurrences(of: "\"", with: "\"\"")
                let matchExpression = "\"\(escaped)\""

                let ftsSQL = """
                SELECT entity_id, kind
                FROM search_fts
                WHERE search_fts MATCH ?
                ORDER BY bm25(search_fts, 1.0, 1.0, 5.0, 3.0, 2.0, 1.5) ASC
                LIMIT ?;
                """

                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let totalLimit = Int32(maxTracks + maxAlbums + maxArtists + maxPlaylists + 50)
                if sqlite3_prepare_v2(db, ftsSQL, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (matchExpression as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(stmt, 2, totalLimit)

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let idPtr = sqlite3_column_text(stmt, 0),
                              let kindPtr = sqlite3_column_text(stmt, 1) else { continue }
                        let idStr = String(cString: idPtr)
                        let kindStr = String(cString: kindPtr)

                        switch kindStr {
                        case "track":
                            if trackIDs.count < maxTracks, let u = UUID(uuidString: idStr) {
                                trackIDs.append(u)
                            }
                        case "album":
                            if albumIDs.count < maxAlbums {
                                albumIDs.append(idStr)
                            }
                        case "artist":
                            if artistIDs.count < maxArtists {
                                artistIDs.append(idStr)
                            }
                        case "playlist":
                            if playlistIDs.count < maxPlaylists, let u = UUID(uuidString: idStr) {
                                playlistIDs.append(u)
                            }
                        default:
                            break
                        }
                    }
                }
            } else {
                // 2. Token Prefix Search (unicode61 or 1-2 char queries)
                // Format query as prefix match: word1* word2*
                let tokens = cleanQuery.split(separator: " ", omittingEmptySubsequences: true)
                let matchExpression: String
                if tokens.isEmpty {
                    matchExpression = "\(cleanQuery)*"
                } else {
                    matchExpression = tokens.map { "\($0)*" }.joined(separator: " ")
                }

                // If trigram and query < 3 chars, FTS trigram cannot index < 3 chars, so use fast LIKE on main tables
                if isTrigram && queryCount < 3 {
                    let likePattern = "\(cleanQuery)%"
                    var stmt: OpaquePointer?

                    // Search Tracks
                    if sqlite3_prepare_v2(db, "SELECT id FROM tracks WHERE title LIKE ? OR artist LIKE ? LIMIT ?;", -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, (likePattern as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (likePattern as NSString).utf8String, -1, nil)
                        sqlite3_bind_int(stmt, 3, Int32(maxTracks))
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            if let ptr = sqlite3_column_text(stmt, 0), let u = UUID(uuidString: String(cString: ptr)) {
                                trackIDs.append(u)
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                    stmt = nil

                    // Search Albums
                    if sqlite3_prepare_v2(db, "SELECT id FROM albums WHERE title LIKE ? OR artist LIKE ? LIMIT ?;", -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, (likePattern as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (likePattern as NSString).utf8String, -1, nil)
                        sqlite3_bind_int(stmt, 3, Int32(maxAlbums))
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            if let ptr = sqlite3_column_text(stmt, 0) {
                                albumIDs.append(String(cString: ptr))
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                    stmt = nil

                    // Search Artists
                    if sqlite3_prepare_v2(db, "SELECT id FROM artists WHERE name LIKE ? LIMIT ?;", -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, (likePattern as NSString).utf8String, -1, nil)
                        sqlite3_bind_int(stmt, 2, Int32(maxArtists))
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            if let ptr = sqlite3_column_text(stmt, 0) {
                                artistIDs.append(String(cString: ptr))
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                } else {
                    let ftsSQL = """
                    SELECT entity_id, kind
                    FROM search_fts
                    WHERE search_fts MATCH ?
                    ORDER BY bm25(search_fts, 1.0, 1.0, 5.0, 3.0, 2.0, 1.5) ASC
                    LIMIT ?;
                    """

                    var stmt: OpaquePointer?
                    defer { sqlite3_finalize(stmt) }
                    let totalLimit = Int32(maxTracks + maxAlbums + maxArtists + maxPlaylists + 50)
                    if sqlite3_prepare_v2(db, ftsSQL, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, (matchExpression as NSString).utf8String, -1, nil)
                        sqlite3_bind_int(stmt, 2, totalLimit)

                        while sqlite3_step(stmt) == SQLITE_ROW {
                            guard let idPtr = sqlite3_column_text(stmt, 0),
                                  let kindPtr = sqlite3_column_text(stmt, 1) else { continue }
                            let idStr = String(cString: idPtr)
                            let kindStr = String(cString: kindPtr)

                            switch kindStr {
                            case "track":
                                if trackIDs.count < maxTracks, let u = UUID(uuidString: idStr) {
                                    trackIDs.append(u)
                                }
                            case "album":
                                if albumIDs.count < maxAlbums {
                                    albumIDs.append(idStr)
                                }
                            case "artist":
                                if artistIDs.count < maxArtists {
                                    artistIDs.append(idStr)
                                }
                            case "playlist":
                                if playlistIDs.count < maxPlaylists, let u = UUID(uuidString: idStr) {
                                    playlistIDs.append(u)
                                }
                            default:
                                break
                            }
                        }
                    }
                }
            }

            return (trackIDs, albumIDs, artistIDs, playlistIDs)
        }
    }

    // MARK: - WAL Checkpointing

    public func walCheckpoint() {
        writeQueue.async { [weak self] in
            guard let self = self, let db = self.writeDB else { return }
            var logSize: Int32 = 0
            var checkpointed: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, &logSize, &checkpointed)
            if rc == SQLITE_OK {
                AppLogger.storage.info("WAL checkpointed successfully (log: \(logSize), checkpointed: \(checkpointed) frames).")
            } else {
                AppLogger.storage.warning("WAL checkpoint returned code \(rc).")
            }
        }
    }
}
