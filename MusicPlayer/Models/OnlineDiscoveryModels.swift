import Foundation

// MARK: - OnlineDiscoveryItemType

/// Item type for online discovery search results.
public enum OnlineDiscoveryItemType: String, CaseIterable, Identifiable, Sendable {
    // All option
    case all = "ALL"
    // Tracks option
    case tracks = "TRACKS"
    // Albums option
    case albums = "ALBUMS"
    // Artists option
    case artists = "ARTISTS"

    // Unique track identifier
    public var id: String { rawValue }
}

// MARK: - OnlineArtistItem

/// An artist discovered via online search with deep metadata and biography.
public struct OnlineArtistItem: Identifiable, Sendable, Hashable {
    // Unique identifier
    public let id: String
    // Name
    public let name: String
    // Musical genre
    public let genre: String?
    // File system location for image url
    public let imageURL: URL?
    // File system location for apple music url
    public let appleMusicURL: URL?
    /// Populated lazily when the user taps through to the artist detail view.
    public var biography: String?
    /// Highlights — typically the artist's most-streamed tracks.
    public var topTracks: [OnlineTrackItem]
    /// Full studio discography from the online source.
    public var albums: [OnlineAlbumItem]
    /// Albums where this artist appears as a guest or featured collaborator.
    public var featuredAlbums: [OnlineAlbumItem]

    // Initialize with configured properties
    public init(
        id: String,
        name: String,
        genre: String? = nil,
        imageURL: URL? = nil,
        appleMusicURL: URL? = nil,
        biography: String? = nil,
        topTracks: [OnlineTrackItem] = [],
        albums: [OnlineAlbumItem] = [],
        featuredAlbums: [OnlineAlbumItem] = []
    ) {
        self.id = id
        self.name = name
        self.genre = genre
        self.imageURL = imageURL
        self.appleMusicURL = appleMusicURL
        self.biography = biography
        self.topTracks = topTracks
        self.albums = albums
        self.featuredAlbums = featuredAlbums
    }
}

// MARK: - OnlineAlbumItem

/// An album discovered via online search with deep metadata, record label, and tracklist.
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
    /// Populated on demand when the album detail view is loaded.
    public var tracklist: [OnlineTrackItem]

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
        sourceAPI: String = "Apple Music",
        tracklist: [OnlineTrackItem] = []
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
        self.tracklist = tracklist
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

// MARK: - OnlineTrackItem

/// A track discovered via online search with audio preview, credits, and specs.
public struct OnlineTrackItem: Identifiable, Sendable, Hashable {
    // Unique identifier
    public let id: String
    // Display title
    public let title: String
    // Artist name
    public let artistName: String
    // Album title
    public let albumTitle: String
    // Unique identifier for album id
    public let albumId: String?
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
    public let duration: TimeInterval
    /// 30-second preview clip URL provided by the online source (may be nil).
    public let previewURL: URL?
    // File system location for artwork url
    public let artworkURL: URL?
    // Record label
    public let recordLabel: String?
    // Flag indicating if explicit
    public let isExplicit: Bool
    // Composer
    public let composer: String?
    // Performers
    public let performers: String?
    // Producers
    public let producers: String?
    // Bpm
    public let bpm: Int?

    // Initialize with configured properties
    public init(
        id: String,
        title: String,
        artistName: String,
        albumTitle: String,
        albumId: String? = nil,
        releaseDate: Date? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        previewURL: URL? = nil,
        artworkURL: URL? = nil,
        recordLabel: String? = nil,
        isExplicit: Bool = false,
        composer: String? = nil,
        performers: String? = nil,
        producers: String? = nil,
        bpm: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.albumId = albumId
        self.releaseDate = releaseDate
        self.releaseYear = releaseYear
        self.genre = genre
        self.trackNumber = trackNumber
        self.totalTracks = totalTracks
        self.discNumber = discNumber
        self.duration = duration
        self.previewURL = previewURL
        self.artworkURL = artworkURL
        self.recordLabel = recordLabel
        self.isExplicit = isExplicit
        self.composer = composer
        self.performers = performers
        self.producers = producers
        self.bpm = bpm
    }

    /// Formatted release date string for display.
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

// MARK: - OnlineSearchResults

/// Unified search results container grouping artists, albums, and tracks from a single query.
public struct OnlineSearchResults: Sendable {
    // Artists
    public let artists: [OnlineArtistItem]
    // Albums
    public let albums: [OnlineAlbumItem]
    // Tracks
    public let tracks: [OnlineTrackItem]

    // Initialize with configured properties
    public init(
        artists: [OnlineArtistItem] = [],
        albums: [OnlineAlbumItem] = [],
        tracks: [OnlineTrackItem] = []
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }

    // Controls is empty
    public var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && tracks.isEmpty
    }

    public var totalCount: Int {
        artists.count + albums.count + tracks.count
    }
}
