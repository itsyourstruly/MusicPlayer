import Foundation

/// Online album metadata model used by album metadata lookup, matching and apply flows.

// MARK: - OnlineAlbumItem

/// An album discovered via online search with deep metadata and record label.
public struct OnlineAlbumItem: Identifiable, Sendable, Hashable {
    // Unique identifier
    public let id: String
    // Display title
    public let title: String
    // Artist name
    public let artistName: String
    // Unique identifier for artist id
    public let artistId: String?
    // Release date
    public let releaseDate: Date?
    /// Stored separately so we can display just the year even when the full date is unavailable.
    public let releaseYear: Int?
    // Record label
    public let recordLabel: String?
    // Copyright
    public let copyright: String?
    // Musical genre
    public let genre: String?
    // Track count
    public let trackCount: Int?
    // Disc count
    public let discCount: Int?
    // File system location for artwork url
    public let artworkURL: URL?
    /// Editorial description returned by the online source (may be nil for lesser-known releases).
    public var description: String?
    /// Provider source API (e.g. "Apple Music", "Deezer", "MusicBrainz")
    public let sourceAPI: String

    // Initialize with configured properties
    public init(
        id: String,
        title: String,
        artistName: String,
        artistId: String? = nil,
        releaseDate: Date? = nil,
        releaseYear: Int? = nil,
        recordLabel: String? = nil,
        copyright: String? = nil,
        genre: String? = nil,
        trackCount: Int? = nil,
        discCount: Int? = nil,
        artworkURL: URL? = nil,
        description: String? = nil,
        sourceAPI: String = "Apple Music"
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistId = artistId
        self.releaseDate = releaseDate
        self.releaseYear = releaseYear
        self.recordLabel = recordLabel
        self.copyright = copyright
        self.genre = genre
        self.trackCount = trackCount
        self.discCount = discCount
        self.artworkURL = artworkURL
        self.description = description
        self.sourceAPI = sourceAPI
    }

    /// Formatted date or year string for display.
    public var formattedReleaseDate: String {
        if let date = releaseDate {
            // Formatter
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date).uppercased()
        // Release year
        } else if let year = releaseYear, year > 0 {
            return "\(year)"
        }
        return "—"
    }
}
