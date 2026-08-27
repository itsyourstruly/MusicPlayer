import Foundation

/// Grouped artist representation containing discography, albums, and associated tracks.
public struct Artist: Identifiable, Codable, Sendable, Hashable {
    /// Lowercased name used as a stable, case-insensitive identifier.
    public var id: String { name.lowercased() }

    // Name
    public let name: String
    // Albums
    public let albums: [Album]
    // Tracks
    public let tracks: [Track]

    // Pre-normalized for fuzzy search — computed once to avoid repeated string work at query time.
    public let normalizedName: String
    // Search tokens
    public let searchTokens: String

    // Initialize with configured properties
    public init(name: String, albums: [Album] = [], tracks: [Track] = []) {
        self.name = name
        // Albums sorted newest-first so discography views show recent releases at the top.
        self.albums = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        // Tracks sorted alphabetically for the flat track list view.
        self.tracks = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // N name
        let nName = FuzzyMatcher.normalize(name)
        self.normalizedName = nName
        self.searchTokens = nName
    }

    // MARK: - Codable

    // Defines CodingKeys cases
    private enum CodingKeys: String, CodingKey {
        // Name option
        case name, albums, tracks
    }

    /// Custom decoder so sort order is enforced after loading from persisted JSON.
    public init(from decoder: Decoder) throws {
        // Container
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown Artist"
        // Decoded albums
        let decodedAlbums = try container.decodeIfPresent([Album].self, forKey: .albums) ?? []
        // Decoded tracks
        let decodedTracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        self.albums = decodedAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        self.tracks = decodedTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // N name
        let nName = FuzzyMatcher.normalize(self.name)
        self.normalizedName = nName
        self.searchTokens = nName
    }

    // Encode
    public func encode(to encoder: Encoder) throws {
        // Container
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(albums, forKey: .albums)
        try container.encode(tracks, forKey: .tracks)
    }

    // MARK: - Computed Properties

    /// Total number of tracks by this artist.
    public var totalTrackCount: Int {
        tracks.count
    }

    /// Total number of albums by this artist.
    public var totalAlbumCount: Int {
        albums.count
    }

    /// Total playback duration for this artist.
    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    /// Formatted track count subtitle (e.g. `1 TRACK` or `28 TRACKS`).
    public var formattedTrackCount: String {
        totalTrackCount == 1 ? "1 TRACK" : "\(totalTrackCount) TRACKS"
    }

    /// Formatted album and track count subtitle (e.g., `3 ALBUMS · 28 TRACKS`).
    public var discographySummary: String {
        // Album text
        let albumText = totalAlbumCount == 1 ? "1 ALBUM" : "\(totalAlbumCount) ALBUMS"
        // Track text
        let trackText = totalTrackCount == 1 ? "1 TRACK" : "\(totalTrackCount) TRACKS"
        return "\(albumText) · \(trackText)"
    }
}
