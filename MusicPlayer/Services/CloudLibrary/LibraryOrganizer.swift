import Foundation

/// Pure in-memory track metadata organizer that applies FOLDER vs METADATA modes and per-mode user overrides.
nonisolated public enum LibraryOrganizer: Sendable {
    public typealias Mode = LibraryScanMethod

    /// Reorganizes a track according to the specified scan mode and optional user override.
    /// Never changes duration, genre, artwork, lyrics, or audio file format.
    public static func organize(
        track: Track,
        mode: LibraryScanMethod,
        override: TrackMetadataOverride? = nil,
        layout: FolderHierarchyLayout = .auto,
        rootFolderName: String? = nil
    ) -> Track {
        // Jellyfin tracks are ALWAYS folder-organized (smart AUTO layout), regardless of the local mode.
        if track.isJellyfinItem {
            return organizeJellyfin(track: track, override: override)
        }
        let effectiveMode: LibraryScanMethod = mode

        // Base values from mode
        var baseTitle: String
        var baseArtist: String
        var baseAlbum: String
        var baseAlbumArtist: String?
        var baseYear: Int?
        var baseTrackNumber: Int?
        var baseDiscNumber: Int?

        let relPath = track.relativePath ?? track.url.lastPathComponent
        let parsed = FolderPathMetadataParser.parse(relativePath: relPath, layout: layout, rootFolderName: rootFolderName)

        switch effectiveMode {
        case .folderHierarchy:
            // FOLDER mode: title/artist/album/album artist come ONLY from the path.
            // Year/track/disc fall back to genuine embedded tags, then stored values.
            baseTitle = parsed.title
            baseArtist = parsed.artist
            baseAlbum = parsed.album
            baseAlbumArtist = parsed.albumArtist
            let realTags = track.metadataSource == .folderStructure ? nil : track.tagSnapshot
            baseYear = parsed.year ?? realTags?.year ?? track.year
            baseTrackNumber = parsed.trackNumber ?? realTags?.trackNumber ?? track.trackNumber
            baseDiscNumber = parsed.discNumber ?? realTags?.discNumber ?? track.discNumber

        case .id3Tags:
            // METADATA mode: real tags for local tracks; folder values for cloud-only placeholders until downloaded
            if let snapshot = track.tagSnapshot, track.metadataSource != .folderStructure {
                baseTitle = snapshot.title
                baseArtist = snapshot.artist
                baseAlbum = snapshot.album
                baseAlbumArtist = snapshot.albumArtist
                baseYear = snapshot.year
                baseTrackNumber = snapshot.trackNumber
                baseDiscNumber = snapshot.discNumber
            } else if track.metadataSource == .server {
                // Server tracks already hold their server-provided metadata
                baseTitle = track.title
                baseArtist = track.artist
                baseAlbum = track.album
                baseAlbumArtist = track.albumArtist
                baseYear = track.year
                baseTrackNumber = track.trackNumber
                baseDiscNumber = track.discNumber
            } else if track.metadataSource == .embeddedTags {
                baseTitle = track.title
                baseArtist = track.artist
                baseAlbum = track.album
                baseAlbumArtist = track.albumArtist
                baseYear = track.year
                baseTrackNumber = track.trackNumber
                baseDiscNumber = track.discNumber
            } else if track.metadataSource == nil {
                // Legacy local track without a tag snapshot: keep its stored values (rescan to refresh)
                baseTitle = track.title
                baseArtist = track.artist
                baseAlbum = track.album
                baseAlbumArtist = track.albumArtist
                baseYear = track.year
                baseTrackNumber = track.trackNumber
                baseDiscNumber = track.discNumber
            } else {
                // Cloud-only placeholder (or legacy folder-scanned track): folder values until (re)parsed
                baseTitle = parsed.title
                baseArtist = parsed.artist
                baseAlbum = parsed.album
                baseAlbumArtist = parsed.albumArtist
                baseYear = parsed.year ?? track.year
                baseTrackNumber = parsed.trackNumber ?? track.trackNumber
                baseDiscNumber = parsed.discNumber ?? track.discNumber
            }
        }

        // Apply active mode override if present
        if let ov = override {
            if let t = ov.title, !t.isEmpty { baseTitle = t }
            if let a = ov.artist, !a.isEmpty { baseArtist = a }
            if let al = ov.album, !al.isEmpty { baseAlbum = al }
            if let aa = ov.albumArtist { baseAlbumArtist = aa.isEmpty ? nil : aa }
            if let y = ov.year { baseYear = y }
            if let tn = ov.trackNumber { baseTrackNumber = tn }
            if let dn = ov.discNumber { baseDiscNumber = dn }
        }

        return track.withOrganizedMetadata(
            title: baseTitle,
            artist: baseArtist,
            album: baseAlbum,
            albumArtist: baseAlbumArtist,
            year: baseYear,
            trackNumber: baseTrackNumber,
            discNumber: baseDiscNumber
        )
    }

    /// Server-relative folder path usable for Jellyfin folder organization, or nil when the track has
    /// no genuine path (legacy lowercased/synthesized paths) or sits directly in the library root.
    public static func jellyfinFolderPath(for track: Track) -> String? {
        guard track.isJellyfinItem, let rel = track.relativePath, !rel.isEmpty else { return nil }
        // Legacy syncs stored lowercased (or metadata-synthesized) paths; those can't name folders.
        guard rel != rel.lowercased() else { return nil }
        let folders = rel.split(separator: "/", omittingEmptySubsequences: true)
        guard folders.count >= 2 else { return nil }
        return rel
    }

    /// Jellyfin: artist/album/title/track/disc from the server folder path (AUTO layout);
    /// falls back to the server metadata snapshot when no usable path exists.
    private static func organizeJellyfin(track: Track, override: TrackMetadataOverride?) -> Track {
        let server = track.tagSnapshot
        var baseTitle = server?.title ?? track.title
        var baseArtist = server?.artist ?? track.artist
        var baseAlbum = server?.album ?? track.album
        var baseAlbumArtist = server != nil ? server?.albumArtist : track.albumArtist
        var baseYear = server?.year ?? track.year
        var baseTrackNumber = server?.trackNumber ?? track.trackNumber
        var baseDiscNumber = server?.discNumber ?? track.discNumber

        if let folderPath = jellyfinFolderPath(for: track) {
            let parsed = FolderPathMetadataParser.parse(relativePath: folderPath, layout: .auto)
            baseTitle = parsed.title
            baseArtist = parsed.artist
            baseAlbum = parsed.album
            baseAlbumArtist = parsed.albumArtist
            baseYear = parsed.year ?? baseYear
            baseTrackNumber = parsed.trackNumber ?? baseTrackNumber
            baseDiscNumber = parsed.discNumber ?? baseDiscNumber
        }

        if let ov = override {
            if let t = ov.title, !t.isEmpty { baseTitle = t }
            if let a = ov.artist, !a.isEmpty { baseArtist = a }
            if let al = ov.album, !al.isEmpty { baseAlbum = al }
            if let aa = ov.albumArtist { baseAlbumArtist = aa.isEmpty ? nil : aa }
            if let y = ov.year { baseYear = y }
            if let tn = ov.trackNumber { baseTrackNumber = tn }
            if let dn = ov.discNumber { baseDiscNumber = dn }
        }

        return track.withOrganizedMetadata(
            title: baseTitle,
            artist: baseArtist,
            album: baseAlbum,
            albumArtist: baseAlbumArtist,
            year: baseYear,
            trackNumber: baseTrackNumber,
            discNumber: baseDiscNumber
        )
    }

    /// Organizes an array of tracks in batch off the main actor.
    public static func organizeBatch(
        tracks: [Track],
        mode: LibraryScanMethod,
        overrides: [UUID: TrackMetadataOverride],
        layout: FolderHierarchyLayout = .auto,
        rootFolderNames: [UUID: String] = [:]
    ) -> [Track] {
        tracks.map { track in
            let ov = overrides[track.id]
            let rootName = track.folderID.flatMap { rootFolderNames[$0] }
            return organize(track: track, mode: mode, override: ov, layout: layout, rootFolderName: rootName)
        }
    }
}
