import Foundation

/// Pure in-memory track metadata organizer that applies FOLDER vs METADATA modes and per-mode user overrides.
public enum LibraryOrganizer: Sendable {
    public typealias Mode = LibraryScanMethod

    /// Reorganizes a track according to the specified scan mode and optional user override.
    /// Never changes duration, genre, artwork, lyrics, or audio file format.
    public static func organize(
        track: Track,
        mode: LibraryScanMethod,
        override: TrackMetadataOverride? = nil
    ) -> Track {
        // Base values from mode
        var baseTitle: String
        var baseArtist: String
        var baseAlbum: String
        var baseAlbumArtist: String?
        var baseYear: Int?
        var baseTrackNumber: Int?
        var baseDiscNumber: Int?

        let relPath = track.relativePath ?? track.url.lastPathComponent
        let parsed = FolderPathMetadataParser.parse(relativePath: relPath)

        switch mode {
        case .folderHierarchy:
            // FOLDER mode: parser values for every track
            // Fall back to tags for missing year/track/disc or no relativePath
            baseTitle = parsed.title
            baseArtist = parsed.artist
            baseAlbum = parsed.album
            baseAlbumArtist = parsed.albumArtist
            baseYear = parsed.year ?? track.tagSnapshot?.year ?? track.year
            baseTrackNumber = parsed.trackNumber ?? track.tagSnapshot?.trackNumber ?? track.trackNumber
            baseDiscNumber = parsed.discNumber ?? track.tagSnapshot?.discNumber ?? track.discNumber

        case .id3Tags:
            // METADATA mode: real tags for local tracks; folder values for cloud-only placeholders until downloaded
            if let snapshot = track.tagSnapshot {
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
            } else {
                // Cloud-only placeholder: folder values until downloaded
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

    /// Organizes an array of tracks in batch off the main actor.
    public static func organizeBatch(
        tracks: [Track],
        mode: LibraryScanMethod,
        overrides: [UUID: TrackMetadataOverride]
    ) -> [Track] {
        tracks.map { track in
            let ov = overrides[track.id]
            return organize(track: track, mode: mode, override: ov)
        }
    }
}
