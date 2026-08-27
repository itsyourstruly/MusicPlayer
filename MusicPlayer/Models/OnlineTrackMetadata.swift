import Foundation

/// Lightweight, verified online track & album metadata entity retrieved from iTunes Search API, ShazamKit, or Deezer.
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

    /// The resolved online album name: cleaned to standard studio album title unless the track is from a deluxe edition.
    public var effectiveOnlineAlbum: String {
        if !isLocalDeluxe && isOnlineDeluxe {
            return DeluxeAlbumDetector.cleanToStandardAlbumName(onlineMetadata.album)
        }
        return onlineMetadata.album
    }

    // Controls is exact album match
    public var isExactAlbumMatch: Bool {
        // Norm local
        let normLocal = localTrack.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Norm online
        let normOnline = effectiveOnlineAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normLocal.isEmpty && normLocal != "unknown album" && normLocal == normOnline
    }

    // Controls is album override ignored to preserve local album
    public var isAlbumOverrideIgnoredToPreserveLocalAlbum: Bool {
        // Local has valid album
        let localHasValidAlbum = !localTrack.album.isEmpty &&
                                 localTrack.album.lowercased() != "unknown album" &&
                                 !localTrack.album.lowercased().hasSuffix(" - single") &&
                                 !localTrack.album.lowercased().hasSuffix(" (single)") &&
                                 localTrack.album.lowercased() != "single"
        return localHasValidAlbum && (onlineMetadata.isSingle || onlineMetadata.isCompilation)
    }

    // Controls is single ignored to preserve local album
    public var isSingleIgnoredToPreserveLocalAlbum: Bool {
        isAlbumOverrideIgnoredToPreserveLocalAlbum
    }

    // Controls has local feature credit
    public var hasLocalFeatureCredit: Bool {
        // Title lower
        let titleLower = localTrack.title.lowercased()
        // Artist lower
        let artistLower = localTrack.artist.lowercased()
        return titleLower.contains("feat.") || titleLower.contains("feat ") ||
               titleLower.contains("ft.") || titleLower.contains("ft ") ||
               artistLower.contains("feat.") || artistLower.contains("ft.") ||
               artistLower.contains(" & ")
    }

    public var titleChanged: Bool {
        localTrack.title.trimmingCharacters(in: .whitespacesAndNewlines) != onlineMetadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var artistChanged: Bool {
        localTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines) != onlineMetadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
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
        (onlineMetadata.releaseYear == nil || onlineMetadata.releaseYear == 0) && (localTrack.year != nil && localTrack.year! > 0)
    }

    public var genreChanged: Bool {
        false
    }

    // Controls is genre transferred from local
    public var isGenreTransferredFromLocal: Bool {
        false
    }

    public var trackNumberChanged: Bool {
        // If the track is from a deluxe release, preserve local track number if already set
        if (isLocalDeluxe || isOnlineDeluxe) && (localTrack.trackNumber != nil && localTrack.trackNumber! > 0) {
            return false
        }
        // Ensure preconditions are met before proceeding
        guard let onlineTrackNum = onlineMetadata.trackNumber, onlineTrackNum > 0 else { return false }
        return localTrack.trackNumber != onlineTrackNum
    }

    // Controls is track number transferred from local
    public var isTrackNumberTransferredFromLocal: Bool {
        // Flag indicating if deluxe protected
        let isDeluxeProtected = (isLocalDeluxe || isOnlineDeluxe) && (localTrack.trackNumber != nil && localTrack.trackNumber! > 0)
        // Online missing
        let onlineMissing = (onlineMetadata.trackNumber == nil || onlineMetadata.trackNumber == 0)
        return (onlineMissing || isDeluxeProtected) && (localTrack.trackNumber != nil && localTrack.trackNumber! > 0)
    }

    public var artworkUpgraded: Bool {
        // Ensure preconditions are met before proceeding
        guard onlineMetadata.artworkURL != nil else { return false }
        // Missing local artwork
        if localTrack.artworkKey == nil || localTrack.artworkKey?.isEmpty == true {
            return true
        }
        // Different album or artist cover from official online release
        if albumChanged || artistChanged {
            return true
        }
        return false
    }

    /// Number of distinct metadata fields that will be enriched or improved.
    public var fieldsEnrichedCount: Int {
        // Count
        var count = 0
        if yearChanged { count += 1 }
        if trackNumberChanged { count += 1 }
        if artworkUpgraded { count += 1 }
        if albumChanged { count += 1 }
        if !preserveLocalTitleAndArtist {
            if titleChanged { count += 1 }
            if artistChanged { count += 1 }
        }
        return count
    }
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
