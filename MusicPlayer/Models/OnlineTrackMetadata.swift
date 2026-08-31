import Foundation

/// Available online metadata providers/APIs for querying and enrichment.
public enum MetadataAPIOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "ALL SOURCES"
    case itunes = "APPLE MUSIC"
    case deezer = "DEEZER"
    case musicBrainz = "MUSICBRAINZ"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    public var shortName: String {
        switch self {
        case .all: return "ALL"
        case .itunes: return "APPLE"
        case .deezer: return "DEEZER"
        case .musicBrainz: return "MBRAINZ"
        }
    }
}

/// Lightweight, verified online track & album metadata entity retrieved from iTunes Search API, ShazamKit, Deezer, or MusicBrainz.
public struct OnlineTrackMetadata: Identifiable, Codable, Sendable, Hashable {
    // Unique identifier
    public let id: String
    // Display title
    public let title: String
    // Primary artist name
    public let artist: String
    // Album title
    public let album: String
    // Album artist
    public let albumArtist: String?
    // Release date
    public let releaseDate: Date?
    // Release year
    public let releaseYear: Int?
    // Musical genre
    public let genre: String?
    // Track number
    public let trackNumber: Int?
    // Total tracks
    public let totalTracks: Int?
    // Disc number
    public let discNumber: Int?
    // Duration in seconds
    public let duration: TimeInterval?
    // File system location for artwork url
    public let artworkURL: URL?
    // File system location for preview url
    public let previewURL: URL?
    // Source api
    public let sourceAPI: String
    // Flag indicating if compilation
    public let isCompilation: Bool
    // Flag indicating if shazam match
    public let isShazamMatch: Bool

    // Initialize with configured properties
    public init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        releaseDate: Date? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        artworkURL: URL? = nil,
        previewURL: URL? = nil,
        sourceAPI: String = "iTunes",
        isCompilation: Bool = false,
        isShazamMatch: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.releaseDate = releaseDate
        self.releaseYear = releaseYear
        self.genre = genre
        self.trackNumber = trackNumber
        self.totalTracks = totalTracks
        self.discNumber = discNumber
        self.duration = duration
        self.artworkURL = artworkURL
        self.previewURL = previewURL
        self.sourceAPI = sourceAPI
        self.isCompilation = isCompilation
        self.isShazamMatch = isShazamMatch
    }

    /// Indicates whether this online candidate belongs to a standalone single/EP release rather than a full studio album.
    public var isSingle: Bool {
        // Lower
        let lower = album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "single" || lower.hasSuffix(" - single") || lower.hasSuffix(" (single)") || lower.hasSuffix(" [single]") || lower.hasSuffix(" - ep") || lower.hasSuffix(" (ep)") {
            return true
        }
        if let count = totalTracks, count <= 2, count > 0 {
            return true
        }
        return false
    }
}

/// A lightweight diff comparison between a local audio track's current metadata and verified online metadata.
/// Supports transparent transfer of local tags (year, genre, track #) when online data is missing.
public struct MetadataDiff: Identifiable, Codable, Sendable, Hashable {
    // Unique track identifier
    public var id: UUID { localTrack.id }
    // Local track
    public let localTrack: Track
    // Online metadata
    public let onlineMetadata: OnlineTrackMetadata
    public var preserveLocalTitleAndArtist: Bool = true

    // Initialize with configured properties
    public init(
        localTrack: Track,
        onlineMetadata: OnlineTrackMetadata,
        preserveLocalTitleAndArtist: Bool = true
    ) {
        self.localTrack = localTrack
        self.onlineMetadata = onlineMetadata
        self.preserveLocalTitleAndArtist = preserveLocalTitleAndArtist
    }

    /// Indicates if the local track is explicitly from a deluxe release.
    public var isLocalDeluxe: Bool {
        DeluxeAlbumDetector.isLocalTrackFromDeluxe(localTrack: localTrack)
    }

    /// Indicates if the online album title contains deluxe edition keywords.
    public var isOnlineDeluxe: Bool {
        DeluxeAlbumDetector.isDeluxe(text: onlineMetadata.album)
    }

    /// Indicates if this record represents a single release.
    public var isSingleRelease: Bool {
        if onlineMetadata.isSingle { return true }
        let onlineAlbumLower = onlineMetadata.album.lowercased()
        if onlineAlbumLower.hasSuffix(" - single") || onlineAlbumLower.hasSuffix(" (single)") || onlineAlbumLower.hasSuffix(" [single]") || onlineAlbumLower == "single" {
            return true
        }
        let localAlbumLower = localTrack.album.lowercased()
        if localAlbumLower.hasSuffix(" - single") || localAlbumLower.hasSuffix(" (single)") || localAlbumLower == "single" {
            return true
        }
        let cleanOnlineAlbum = DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album).lowercased()
        let cleanOnlineTitle = DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.title).lowercased()
        if !cleanOnlineTitle.isEmpty && cleanOnlineAlbum == cleanOnlineTitle && (onlineMetadata.totalTracks == nil || onlineMetadata.totalTracks! <= 2) {
            return true
        }
        return false
    }

    /// Resolves the edition preference for this track (normal, deluxe, or unspecified defaulting to deluxe).
    public var editionPreference: AlbumEditionPreference {
        DeluxeAlbumDetector.resolveEditionPreference(localTrack: localTrack)
    }

    /// The resolved online album name based on the edition preference:
    /// - If the track is a single: album name IS the track title!
    /// - If local track has Deluxe in album name, NEVER overwrite for the non-deluxe version.
    /// - If normal: clean to standard studio album title.
    /// - If deluxe or unspecified: use full deluxe album title.
    public var effectiveOnlineAlbum: String {
        // If it's a single release, name the album as the track name!
        if isSingleRelease {
            return effectiveOnlineTitle
        }

        if isLocalDeluxe && !isOnlineDeluxe {
            return localTrack.album
        }

        switch editionPreference {
        case .normal:
            if isOnlineDeluxe {
                return DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album)
            }
            return onlineMetadata.album
        case .deluxe, .unspecified:
            return onlineMetadata.album
        }
    }

    // Controls is exact album match
    public var isExactAlbumMatch: Bool {
        let normLocal = localTrack.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normOnline = effectiveOnlineAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normLocal.isEmpty && normLocal != "unknown album" && normLocal == normOnline
    }

    // Controls is album override ignored to preserve local album
    public var isAlbumOverrideIgnoredToPreserveLocalAlbum: Bool {
        if isLocalDeluxe && !isOnlineDeluxe {
            return true // Never overwrite local Deluxe album with a non-deluxe candidate
        }

        let localHasValidStudioAlbum = !localTrack.album.isEmpty &&
                                       localTrack.album.lowercased() != "unknown album" &&
                                       !localTrack.album.lowercased().hasSuffix(" - single") &&
                                       !localTrack.album.lowercased().hasSuffix(" (single)") &&
                                       localTrack.album.lowercased() != "single" &&
                                       localTrack.album.lowercased() != localTrack.title.lowercased()
        return localHasValidStudioAlbum && onlineMetadata.isCompilation
    }

    // Controls is single ignored to preserve local album
    public var isSingleIgnoredToPreserveLocalAlbum: Bool {
        isAlbumOverrideIgnoredToPreserveLocalAlbum
    }

    /// Indicates if the local track has multiple artists or collaborative credits.
    public var hasMultipleLocalArtists: Bool {
        let artistLower = localTrack.artist.lowercased()
        if artistLower.contains(" & ") || artistLower.contains(", ") ||
           artistLower.contains(" feat.") || artistLower.contains(" feat ") ||
           artistLower.contains(" ft.") || artistLower.contains(" ft ") ||
           artistLower.contains(" with ") || artistLower.contains(" x ") ||
           artistLower.contains(" vs. ") || artistLower.contains(" vs ") {
            return true
        }
        return ArtistParser.parseArtists(from: localTrack.artist).count > 1
    }

    // Controls has local feature credit in title or artist
    public var hasLocalFeatureCredit: Bool {
        let titleLower = localTrack.title.lowercased()
        return titleLower.contains("feat.") || titleLower.contains("feat ") ||
               titleLower.contains("ft.") || titleLower.contains("ft ") ||
               titleLower.contains("with ") ||
               hasMultipleLocalArtists
    }

    /// Smart decision whether local artist metadata is richer / multi-artist and should not be overwritten by a single artist.
    public var shouldPreserveLocalArtist: Bool {
        if preserveLocalTitleAndArtist { return true }
        if hasMultipleLocalArtists {
            let onlineArtists = ArtistParser.parseArtists(from: onlineMetadata.artist)
            // If local has multiple artists and online only has 1 artist or fewer, keep local!
            if onlineArtists.count <= 1 {
                return true
            }
        }
        return false
    }

    /// Smart decision whether local title metadata has feature credits that should be preserved.
    public var shouldPreserveLocalTitle: Bool {
        if preserveLocalTitleAndArtist { return true }
        let localHasFeature = localTrack.title.lowercased().contains("feat") || localTrack.title.lowercased().contains("ft.")
        let onlineHasFeature = onlineMetadata.title.lowercased().contains("feat") || onlineMetadata.title.lowercased().contains("ft.")
        if localHasFeature && !onlineHasFeature {
            return true
        }
        return false
    }

    /// The effective artist name to apply: protects local multi-artist tags from single-artist downgrades.
    public var effectiveOnlineArtist: String {
        shouldPreserveLocalArtist ? localTrack.artist : onlineMetadata.artist
    }

    /// The effective title to apply: protects local featured artists in titles from stripping.
    public var effectiveOnlineTitle: String {
        shouldPreserveLocalTitle ? localTrack.title : onlineMetadata.title
    }

    public var titleChanged: Bool {
        if shouldPreserveLocalTitle { return false }
        return localTrack.title.trimmingCharacters(in: .whitespacesAndNewlines) != onlineMetadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var artistChanged: Bool {
        if shouldPreserveLocalArtist { return false }
        return localTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines) != onlineMetadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var albumChanged: Bool {
        if isAlbumOverrideIgnoredToPreserveLocalAlbum {
            return false // Preserve valid local album name instead of overwriting with single release or compilation
        }
        // Target album
        let targetAlbum = effectiveOnlineAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
        return localTrack.album.trimmingCharacters(in: .whitespacesAndNewlines) != targetAlbum
    }

    public var yearChanged: Bool {
        // Ensure preconditions are met before proceeding
        guard let onlineYear = onlineMetadata.releaseYear, onlineYear > 0 else { return false }
        return localTrack.year != onlineYear
    }

    // Controls is year transferred from local
    public var isYearTransferredFromLocal: Bool {
        (onlineMetadata.releaseYear == nil || onlineMetadata.releaseYear == 0) && ((localTrack.year ?? 0) > 0)
    }

    public var genreChanged: Bool {
        guard let onlineGenre = onlineMetadata.genre, !onlineGenre.isEmpty, onlineGenre != "Unknown Genre", onlineGenre != "—" else { return false }
        let isLocalGenreMissing = localTrack.genre == nil || localTrack.genre?.isEmpty == true || localTrack.genre == "Unknown Genre" || localTrack.genre == "—"
        return isLocalGenreMissing
    }

    // Controls is genre transferred from local
    public var isGenreTransferredFromLocal: Bool {
        let isOnlineGenreMissing = onlineMetadata.genre == nil || onlineMetadata.genre?.isEmpty == true || onlineMetadata.genre == "Unknown Genre" || onlineMetadata.genre == "—"
        let hasLocalGenre = localTrack.genre != nil && !localTrack.genre!.isEmpty && localTrack.genre != "Unknown Genre" && localTrack.genre != "—"
        return isOnlineGenreMissing && hasLocalGenre
    }

    public var trackNumberChanged: Bool {
        // If local track already has a valid track number (> 0), never overwrite with online data!
        if let localNum = localTrack.trackNumber, localNum > 0 {
            return false
        }
        // Infill missing local track number if online provides one
        guard let onlineTrackNum = onlineMetadata.trackNumber, onlineTrackNum > 0 else { return false }
        return true
    }

    // Controls is track number transferred from local
    public var isTrackNumberTransferredFromLocal: Bool {
        (localTrack.trackNumber ?? 0) > 0
    }

    public var artworkUpgraded: Bool {
        // Ensure online artwork exists
        guard onlineMetadata.artworkURL != nil else { return false }
        // 1. Missing local artwork -> upgrade!
        let hasLocalArtwork = localTrack.artworkKey != nil && !localTrack.artworkKey!.isEmpty
        if !hasLocalArtwork {
            return true
        }
        // 2. Only change artwork if the album changed!
        if albumChanged {
            return true
        }
        // Retain verified local artwork
        return false
    }

    /// Number of distinct metadata fields that will be enriched or improved.
    public var fieldsEnrichedCount: Int {
        // Count
        var count = 0
        if yearChanged { count += 1 }
        if trackNumberChanged { count += 1 }
        if genreChanged { count += 1 }
        if artworkUpgraded { count += 1 }
        if albumChanged { count += 1 }
        if titleChanged { count += 1 }
        if artistChanged { count += 1 }
        return count
    }

    /// Human-readable list of specific metadata fields being filled or enriched for this track.
    public var tagInfillSummary: [String] {
        var summary: [String] = []
        if titleChanged { summary.append("Title: \(effectiveOnlineTitle)") }
        if artistChanged { summary.append("Artist: \(effectiveOnlineArtist)") }
        if albumChanged { summary.append("Album: \(effectiveOnlineAlbum)") }
        if yearChanged, let y = onlineMetadata.releaseYear { summary.append("Year: \(y)") }
        if trackNumberChanged, let tn = onlineMetadata.trackNumber { summary.append("Track #: \(tn)") }
        if genreChanged, let g = onlineMetadata.genre { summary.append("Genre: \(g)") }
        if artworkUpgraded { summary.append("High-Res Artwork") }
        return summary
    }
}

/// Album edition preference categorization for matching and tag injection.
public enum AlbumEditionPreference: String, Sendable, Codable {
    case normal
    case deluxe
    case unspecified
}

/// Utility engine for detecting Deluxe / Expanded / Collector's / Anniversary editions,
/// cleaning album titles to standard studio releases, and protecting local track numbering.
public enum DeluxeAlbumDetector {
    private static let deluxeKeywords: [String] = [
        "deluxe",
        "deluxe edition",
        "deluxe version",
        "expanded",
        "expanded edition",
        "expanded version",
        "collector's edition",
        "collectors edition",
        "special edition",
        "anniversary edition",
        "anniversary deluxe",
        "complete edition",
        "bonus track version",
        "bonus tracks edition",
        "super deluxe",
        "reissue",
        "platinum edition",
        "tour edition",
        "international edition"
    ]

    /// Determines if an album or track title string contains deluxe edition keywords.
    public static func isDeluxe(text: String) -> Bool {
        // Lower
        let lower = text.lowercased()
        for kw in deluxeKeywords {
            if lower.contains(kw) {
                return true
            }
        }
        return false
    }

    /// Determines if a local track is explicitly from a deluxe edition (via its local album tag or title).
    public static func isLocalTrackFromDeluxe(localTrack: Track) -> Bool {
        isDeluxe(text: localTrack.album) || isDeluxe(text: localTrack.title)
    }

    /// Resolves the album edition preference according to the user's exact specification:
    /// - Normal album: local metadata has a normal album with nothing else -> `.normal`
    /// - Deluxe album: local metadata explicitly has deluxe keywords in album or title -> `.deluxe`
    /// - Nothing: local metadata has empty or unknown album -> defaults to `.deluxe`
    public static func resolveEditionPreference(localTrack: Track) -> AlbumEditionPreference {
        let trimmedAlbum = localTrack.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAlbum.isEmpty || trimmedAlbum.lowercased() == "unknown album" || trimmedAlbum.lowercased() == "unknown" {
            return .deluxe
        }
        if isLocalTrackFromDeluxe(localTrack: localTrack) {
            return .deluxe
        }
        return .normal
    }

    /// Strips deluxe, expanded, anniversary, and collector's edition noise from an album name,
    /// returning the clean standard studio album title.
    ///
    /// Examples:
    /// - `"DAMN. (Collector's Edition)"` -> `"DAMN."`
    /// - `"good kid, m.A.A.d city (Deluxe Version)"` -> `"good kid, m.A.A.d city"`
    /// - `"Thriller (25th Anniversary Deluxe Edition)"` -> `"Thriller"`
    /// - `"Blonde - Deluxe"` -> `"Blonde"`
    public static func cleanToStandardAlbumName(_ rawAlbum: String) -> String {
        // Clean
        var clean = rawAlbum
        // Patterns
        let patterns = [
            #"\s*[\(\[\{](?:(?:\d+(?:th|st|nd|rd)\s+)?anniversary\s+)?(?:deluxe|super\s+deluxe|expanded|collector's|collectors|special|complete|platinum|tour|international|bonus\s+track(?:s)?)(?:\s+(?:edition|version|reissue))?[\)\]\}]"#,
            #"\s*-\s*(?:(?:\d+(?:th|st|nd|rd)\s+)?anniversary\s+)?(?:deluxe|super\s+deluxe|expanded|collector's|collectors|special|complete|platinum|tour|international|bonus\s+track(?:s)?)(?:\s+(?:edition|version|reissue))?.*$"#
        ]
        for pattern in patterns {
            clean = clean.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? rawAlbum : clean
    }
}
