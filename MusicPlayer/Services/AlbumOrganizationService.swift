import Foundation

/// Action to perform on an unmatched or non-canonical track during album metadata alignment.
public enum UnmatchedTrackAction: Equatable, Hashable, Sendable {
    case moveToAlternates(reason: String)
    case moveToAlbum(
        albumTitle: String,
        artistName: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkKey: String? = nil,
        artworkURL: URL? = nil,
        trackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        reason: String
    )
    case keepInMain(reason: String)

    public var displayTitle: String {
        switch self {
        case .moveToAlternates:
            return "MOVE TO ALTERNATES"
        case .moveToAlbum(let albumTitle, _, _, _, _, _, _, _, _, _):
            return "MOVE TO \"\(albumTitle.uppercased())\""
        case .keepInMain:
            return "KEEP IN TRACKLIST"
        }
    }

    public var reasonText: String {
        switch self {
        case .moveToAlternates(let reason):
            return reason
        case .moveToAlbum(_, _, _, _, _, _, _, _, _, let reason):
            return reason
        case .keepInMain(let reason):
            return reason
        }
    }

    public var isMoveToAlbum: Bool {
        if case .moveToAlbum = self { return true }
        return false
    }

    public var isMoveToAlternates: Bool {
        if case .moveToAlternates = self { return true }
        return false
    }

    public var isKeepInMain: Bool {
        if case .keepInMain = self { return true }
        return false
    }

    public var targetAlbumTitle: String? {
        if case .moveToAlbum(let albumTitle, _, _, _, _, _, _, _, _, _) = self {
            return albumTitle
        }
        return nil
    }
}

/// High-precision album organization and track assignment engine.
/// Evaluates non-album and unmatched tracks to determine their optimal home:
/// 1. Alternates section of current album (for remixes, live cuts, acoustic/instrumental outtakes, bonus tracks).
/// 2. Target album (if matching another existing album in the user's library or identified as an official release/single).
/// 3. Retaining in main tracklist if requested.
public final class AlbumOrganizationService: Sendable {
    public static let shared = AlbumOrganizationService()

    private init() {}

    /// Analyzes an unmatched track in the context of an album scan and determines the most accurate organization action.
    public func resolveUnmatchedTrack(
        track: Track,
        currentAlbum: Album,
        onlineAlbum: OnlineAlbumItem,
        onlineCuts: [OnlineTrackMetadata],
        libraryAlbums: [Album]
    ) async -> UnmatchedTrackAction {
        let cleanTrackTitle = FuzzyMatcher.normalize(track.title)
        let signature = MetadataSanitizer.sanitize(track: track)
        let normCoreTitle = FuzzyMatcher.normalize(signature.coreTitle)

        // 1. Check if it is an alternate version of an official track in this album
        for cut in onlineCuts {
            let cutNorm = FuzzyMatcher.normalize(cut.title)
            let cutSignature = MetadataSanitizer.buildSignature(
                title: cut.title,
                artist: cut.artist,
                album: cut.album
            )
            let cutCoreNorm = FuzzyMatcher.normalize(cutSignature.coreTitle)

            // Direct core title match, or title contains the cut title
            if !normCoreTitle.isEmpty && (normCoreTitle == cutCoreNorm || normCoreTitle == cutNorm) {
                return .moveToAlternates(reason: "Alternate cut of \"\(cut.title)\"")
            }
            if !cleanTrackTitle.isEmpty && cleanTrackTitle.contains(cutCoreNorm) && cutCoreNorm.count >= 4 {
                return .moveToAlternates(reason: "Alternate version of \"\(cut.title)\"")
            }
        }

        // 2. Check if track title has explicit remix, live, acoustic, instrumental, demo, or bonus indicators
        if MetadataSanitizer.isRemixOrAlternateVersion(title: track.title, album: currentAlbum.title) {
            return .moveToAlternates(reason: "Alternate or remix cut")
        }
        if MetadataSanitizer.isLiveRecording(title: track.title, album: currentAlbum.title) {
            return .moveToAlternates(reason: "Live recording outtake")
        }
        if MetadataSanitizer.isFreestyleOrBonusTrack(title: track.title, album: currentAlbum.title) {
            return .moveToAlternates(reason: "Bonus or outtake cut")
        }

        // 3. Check if track matches another album already in the user's library
        let currentNormAlbum = FuzzyMatcher.normalize(currentAlbum.title)
        let trackArtistNorm = FuzzyMatcher.normalize(track.artist)
        let currentArtistNorm = FuzzyMatcher.normalize(currentAlbum.artist)

        for otherAlbum in libraryAlbums {
            let otherNorm = FuzzyMatcher.normalize(otherAlbum.title)
            // Skip the current album
            guard otherNorm != currentNormAlbum else { continue }

            let otherArtistNorm = FuzzyMatcher.normalize(otherAlbum.artist)
            let isArtistRelated = otherArtistNorm == trackArtistNorm ||
                otherArtistNorm == currentArtistNorm ||
                otherArtistNorm.contains(trackArtistNorm) ||
                trackArtistNorm.contains(otherArtistNorm)

            guard isArtistRelated else { continue }

            // Check if any track in otherAlbum has this title
            for otherTrack in otherAlbum.tracks {
                let otherTrackNorm = FuzzyMatcher.normalize(otherTrack.title)
                if otherTrackNorm == cleanTrackTitle || (!normCoreTitle.isEmpty && otherTrackNorm == normCoreTitle) {
                    return .moveToAlbum(
                        albumTitle: otherAlbum.title,
                        artistName: otherAlbum.artist,
                        year: otherAlbum.year ?? otherTrack.year,
                        genre: otherAlbum.genre ?? otherTrack.genre,
                        artworkKey: otherAlbum.artworkKey ?? otherTrack.artworkKey,
                        artworkURL: nil,
                        trackNumber: otherTrack.trackNumber,
                        totalTracks: otherAlbum.tracks.count,
                        discNumber: otherTrack.discNumber,
                        reason: "Belongs to \"\(otherAlbum.title)\" in library"
                    )
                }
            }

            // Check if track's file path contains otherAlbum's title
            let filePath = track.url.path.lowercased()
            let otherTitleClean = otherAlbum.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if otherTitleClean.count >= 4 && filePath.contains("/\(otherTitleClean)/") {
                return .moveToAlbum(
                    albumTitle: otherAlbum.title,
                    artistName: otherAlbum.artist,
                    year: otherAlbum.year,
                    genre: otherAlbum.genre,
                    artworkKey: otherAlbum.artworkKey,
                    artworkURL: nil,
                    trackNumber: nil,
                    totalTracks: otherAlbum.tracks.count,
                    discNumber: nil,
                    reason: "File path matches \"\(otherAlbum.title)\""
                )
            }
        }

        // 4. Check online metadata service to find the song's official release album
        if let onlineResults = await MusicMetadataService.shared.searchTargetedSong(title: track.title, artist: track.artist), !onlineResults.isEmpty {
            for result in onlineResults {
                let resultTitleNorm = FuzzyMatcher.normalize(result.title)
                let score = FuzzyMatcher.score(text: result.title, query: track.title)
                guard score >= 70 || resultTitleNorm == cleanTrackTitle || resultTitleNorm == normCoreTitle else { continue }

                let resultAlbumNorm = FuzzyMatcher.normalize(result.album)
                let currentAlbumNorm = FuzzyMatcher.normalize(onlineAlbum.title)

                // If online album title is valid and noticeably different from current album
                if !result.album.isEmpty &&
                   !MetadataSanitizer.isUnknownAlbum(result.album) &&
                   resultAlbumNorm != currentAlbumNorm &&
                   !resultAlbumNorm.contains(currentAlbumNorm) &&
                   !currentAlbumNorm.contains(resultAlbumNorm) {
                    return .moveToAlbum(
                        albumTitle: result.album,
                        artistName: result.artist,
                        year: result.releaseYear,
                        genre: result.genre,
                        artworkKey: nil,
                        artworkURL: result.artworkURL,
                        trackNumber: result.trackNumber,
                        totalTracks: result.totalTracks,
                        discNumber: result.discNumber,
                        reason: "Official release on \"\(result.album)\""
                    )
                } else if resultAlbumNorm == currentAlbumNorm || resultAlbumNorm.contains(currentAlbumNorm) {
                    // Found under this album or a deluxe/special release of this album
                    return .moveToAlternates(reason: "Bonus track on extended release")
                }
            }
        }

        // 5. Default fallback: move to Alternates of current album so the main tracklist remains strictly canonical
        return .moveToAlternates(reason: "Not on official tracklist")
    }

    /// Fast, non-blocking in-memory evaluation for instantaneous feedback when toggling tracks to move in the UI.
    public func fastLocalResolveUnmatchedTrack(
        track: Track,
        currentAlbum: Album,
        onlineCuts: [OnlineTrackMetadata],
        otherAlbums: [Album]
    ) -> UnmatchedTrackAction {
        let cleanTrackTitle = FuzzyMatcher.normalize(track.title)
        let signature = MetadataSanitizer.sanitize(track: track)
        let normCoreTitle = FuzzyMatcher.normalize(signature.coreTitle)

        // 1. Check if it is an alternate version of an official cut in this album
        for cut in onlineCuts {
            let cutNorm = FuzzyMatcher.normalize(cut.title)
            let cutSignature = MetadataSanitizer.buildSignature(
                title: cut.title,
                artist: cut.artist,
                album: cut.album
            )
            let cutCoreNorm = FuzzyMatcher.normalize(cutSignature.coreTitle)

            if !normCoreTitle.isEmpty && (normCoreTitle == cutCoreNorm || normCoreTitle == cutNorm) {
                return .moveToAlternates(reason: "Alternate cut of \"\(cut.title)\"")
            }
            if !cleanTrackTitle.isEmpty && cleanTrackTitle.contains(cutCoreNorm) && cutCoreNorm.count >= 4 {
                return .moveToAlternates(reason: "Alternate version of \"\(cut.title)\"")
            }
        }

        // 2. Check remix / live / bonus indicators in title
        if MetadataSanitizer.isRemixOrAlternateVersion(title: track.title, album: currentAlbum.title) {
            return .moveToAlternates(reason: "Alternate or remix cut")
        }
        if MetadataSanitizer.isLiveRecording(title: track.title, album: currentAlbum.title) {
            return .moveToAlternates(reason: "Live recording outtake")
        }
        if MetadataSanitizer.isFreestyleOrBonusTrack(title: track.title, album: currentAlbum.title) {
            return .moveToAlternates(reason: "Bonus or outtake cut")
        }

        // 3. Fast match against other albums by this artist
        for otherAlbum in otherAlbums {
            for otherTrack in otherAlbum.tracks {
                let otherTrackNorm = FuzzyMatcher.normalize(otherTrack.title)
                if otherTrackNorm == cleanTrackTitle || (!normCoreTitle.isEmpty && otherTrackNorm == normCoreTitle) {
                    return .moveToAlbum(
                        albumTitle: otherAlbum.title,
                        artistName: otherAlbum.artist,
                        year: otherAlbum.year ?? otherTrack.year,
                        genre: otherAlbum.genre ?? otherTrack.genre,
                        artworkKey: otherAlbum.artworkKey ?? otherTrack.artworkKey,
                        artworkURL: nil,
                        trackNumber: otherTrack.trackNumber,
                        totalTracks: otherAlbum.tracks.count,
                        discNumber: otherTrack.discNumber,
                        reason: "Belongs to \"\(otherAlbum.title)\" in library"
                    )
                }
            }
        }

        return .moveToAlternates(reason: "Not on official tracklist")
    }

    /// Evaluates all unmatched tracks in parallel and returns an action dictionary keyed by track ID.
    public func resolveAllUnmatchedTracks(
        tracks: [Track],
        currentAlbum: Album,
        onlineAlbum: OnlineAlbumItem,
        onlineCuts: [OnlineTrackMetadata],
        libraryAlbums: [Album]
    ) async -> [UUID: UnmatchedTrackAction] {
        await withTaskGroup(of: (UUID, UnmatchedTrackAction).self) { group in
            for track in tracks {
                group.addTask {
                    let action = await self.resolveUnmatchedTrack(
                        track: track,
                        currentAlbum: currentAlbum,
                        onlineAlbum: onlineAlbum,
                        onlineCuts: onlineCuts,
                        libraryAlbums: libraryAlbums
                    )
                    return (track.id, action)
                }
            }

            var resolutions: [UUID: UnmatchedTrackAction] = [:]
            for await (trackID, action) in group {
                resolutions[trackID] = action
            }
            return resolutions
        }
    }
}
