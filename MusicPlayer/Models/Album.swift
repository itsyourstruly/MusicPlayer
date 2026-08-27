import Foundation

// MARK: - Album

/// Grouped album representation containing sorted tracks and discography metadata.
public struct Album: Identifiable, Codable, Sendable, Hashable {

    // MARK: - Identity

    /// Stable ID derived from artist + title + year so albums with the same name by different artists don't collide.
    public var id: String {
        // Clean artist
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Clean title
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let y = year, y > 0 {
            return "\(cleanArtist)_\(cleanTitle)_\(y)"
        }
        return "\(cleanArtist)_\(cleanTitle)"
    }

    // MARK: - Stored Properties

    // Display title
    public let title: String
    // Primary artist name
    public let artist: String
    // Release year
    public let year: Int?
    // Musical genre
    public let genre: String?
    // Artwork key
    public let artworkKey: String?
    // Tracks
    public let tracks: [Track]

    // Pre-normalized forms used by fuzzy search — computed once at init to avoid repeated lowercasing.
    public let normalizedTitle: String
    // Normalized artist
    public let normalizedArtist: String
    // Search tokens
    public let searchTokens: String

    // MARK: - Init

    // Initialize with configured properties
    public init(
        title: String,
        artist: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkKey: String? = nil,
        tracks: [Track] = []
    ) {
        self.title = title
        self.artist = artist
        self.year = year
        self.genre = genre
        self.artworkKey = artworkKey

        // N title
        let nTitle = FuzzyMatcher.normalize(title)
        // N artist
        let nArtist = FuzzyMatcher.normalize(artist)
        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.searchTokens = "\(nTitle) \(nArtist)"

        // Sort tracks by disc number then track number, then title
        self.tracks = tracks.sorted { lhs, rhs in
            // Lhs disc
            let lhsDisc = lhs.discNumber ?? 1
            // Rhs disc
            let rhsDisc = rhs.discNumber ?? 1
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            // Lhs num
            let lhsNum = lhs.trackNumber ?? 0
            // Rhs num
            let rhsNum = rhs.trackNumber ?? 0
            if lhsNum > 0 && rhsNum > 0 && lhsNum != rhsNum {
                return lhsNum < rhsNum
            }
            // Numbered tracks always sort before un-numbered ones
            if lhsNum > 0 && rhsNum == 0 { return true }
            if lhsNum == 0 && rhsNum > 0 { return false }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: - Codable

    // Defines CodingKeys cases
    private enum CodingKeys: String, CodingKey {
        // Title option
        case title, artist, year, genre, artworkKey, tracks
    }

    /// Custom decoder so we can recompute normalised fields after decoding stored data.
    public init(from decoder: Decoder) throws {
        // Container
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Album"
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        self.year = try container.decodeIfPresent(Int.self, forKey: .year)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.artworkKey = try container.decodeIfPresent(String.self, forKey: .artworkKey)
        self.tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []

        // N title
        let nTitle = FuzzyMatcher.normalize(self.title)
        // N artist
        let nArtist = FuzzyMatcher.normalize(self.artist)
        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.searchTokens = "\(nTitle) \(nArtist)"
    }

    // Encode
    public func encode(to encoder: Encoder) throws {
        // Container
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try container.encode(tracks, forKey: .tracks)
    }

    // MARK: - Computed Properties

    /// Total cumulative duration of all tracks in this album.
    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    /// Human-readable track count string (e.g., `12 TRACKS` or `1 TRACK`).
    public var formattedTrackCount: String {
        // Count
        let count = tracks.count
        return count == 1 ? "1 TRACK" : "\(count) TRACKS"
    }

    /// Resolved release year: prefers the most-common year across tracks, falls back to the album-level tag.
    public var resolvedYear: Int? {
        // Track years
        let trackYears = tracks.compactMap { $0.year }.filter { $0 > 0 }
        // Frequencies
        let frequencies = Dictionary(grouping: trackYears, by: { $0 }).mapValues { $0.count }

        // Find the most frequent year across tracks in the album
        if let mostFrequent = frequencies.max(by: { $0.value < $1.value }) {
            return mostFrequent.key
        }

        // Release year
        if let year = year, year > 0 {
            return year
        }

        return nil
    }

    /// Indicates whether this album is a standalone single or EP release.
    public var isSingle: Bool {
        // Lower
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "single" || lower.hasSuffix(" - single") || lower.hasSuffix(" (single)") || lower.hasSuffix(" [single]") || lower.hasSuffix(" - ep") || lower.hasSuffix(" (ep)") || lower.hasSuffix(" [ep]") {
            return true
        }
        return tracks.count <= 2
    }

    // MARK: - Artist Attribution

    /// Determines if a given artist is a lead creator or primary collaborator on this album.
    /// Returns true for solo albums and multi-artist collaboration albums, and false for simple guest features.
    /// If an album's artist or tracks belong to a joined artist rule, it only matches if `artistName` is that joined artist.
    public func isLeadOrCollaborativeAlbum(for artistName: String, joinedArtists: [String] = []) -> Bool {
        // Clean name
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !cleanName.isEmpty else { return false }

        // 1. Direct album artist match (e.g. Album.artist == "Pete & Bas" or "Drake")
        if artist.localizedCaseInsensitiveCompare(cleanName) == .orderedSame {
            return true
        }

        // Check if the album itself is governed by a joined artist rule
        let albumArtistCanonical = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for joined in joinedArtists {
            // Joined canonical
            let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if albumArtistCanonical == joinedCanonical {
                // This album is explicitly a joined artist album
                return cleanName.lowercased() == joinedCanonical
            }
            // Joined parts
            let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
            if joinedParts.count > 1 {
                // Album parts
                let albumParts = ArtistParser.parseArtists(from: artist).map { $0.lowercased() }
                if Set(joinedParts).isSubset(of: Set(albumParts)) {
                    return cleanName.lowercased() == joinedCanonical
                }
            }
        }

        // 2. Album artist tag includes artist as a co-creator (e.g. "Drake & 21 Savage")
        let albumArtists = ArtistParser.parseArtists(from: artist)
        if albumArtists.contains(where: { $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) {
            return true
        }

        // 3. Track-level multi-artist collaboration analysis:
        var tracksWhereArtistIsPrimary = 0
        for track in tracks {
            // Track artist canonical
            let trackArtistCanonical = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Flag indicating if track joined under other
            var isTrackJoinedUnderOther = false
            for joined in joinedArtists {
                // Joined canonical
                let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trackArtistCanonical == joinedCanonical {
                    if cleanName.lowercased() != joinedCanonical {
                        isTrackJoinedUnderOther = true
                    }
                    break
                }
                // Joined parts
                let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
                if joinedParts.count > 1 {
                    // Track parts
                    let trackParts = ArtistParser.parseArtists(from: track.artist).map { $0.lowercased() }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) {
                        if cleanName.lowercased() != joinedCanonical {
                            isTrackJoinedUnderOther = true
                        }
                        break
                    }
                }
            }
            if isTrackJoinedUnderOther {
                continue
            }

            // Primary artists
            let primaryArtists = ArtistParser.parseArtists(from: track.artist)
            if primaryArtists.contains(where: { $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) {
                tracksWhereArtistIsPrimary += 1
            }
        }

        // For 1-2 track releases (singles), being a primary artist on at least 1 track makes it their single
        if tracks.count <= 2 {
            return tracksWhereArtistIsPrimary > 0
        }

        // For full albums (3+ tracks): if artist is primary on >= 3 tracks AND represents >= 35% of tracks, it's a collaboration album
        let ratio = Double(tracksWhereArtistIsPrimary) / Double(tracks.count)
        if tracksWhereArtistIsPrimary >= 3 && ratio >= 0.35 {
            return true
        }

        // If artist is primary on the vast majority (> 50%) of tracks
        if ratio >= 0.50 {
            return true
        }

        return false
    }

    /// Determines if a given artist is featured as a guest on this album (via title `(feat. )` or minor track credits).
    public func isFeaturedAlbum(for artistName: String, joinedArtists: [String] = []) -> Bool {
        // Clean name
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !cleanName.isEmpty else { return false }

        // If this is the artist's own lead or collaboration album, it is not a guest feature
        if isLeadOrCollaborativeAlbum(for: cleanName, joinedArtists: joinedArtists) {
            return false
        }

        // Check if the album is a joined artist collaboration that cleanName is part of; if so, it should NOT appear here
        for joined in joinedArtists {
            // Joined canonical
            let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Joined parts
            let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
            if joinedParts.contains(cleanName.lowercased()) {
                // Album parts
                let albumParts = ArtistParser.parseArtists(from: artist).map { $0.lowercased() }
                if Set(joinedParts).isSubset(of: Set(albumParts)) || artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == joinedCanonical {
                    return false
                }
            }
        }

        // Check if any track on this album features the artist in the title or artist tag
        for track in tracks {
            // If the track is a joined artist track that cleanName is part of, skip it
            var isTrackJoined = false
            for joined in joinedArtists {
                // Joined canonical
                let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // Joined parts
                let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
                if joinedParts.contains(cleanName.lowercased()) {
                    // Track parts
                    let trackParts = ArtistParser.parseArtists(from: track.artist).map { $0.lowercased() }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) || track.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == joinedCanonical {
                        isTrackJoined = true
                        break
                    }
                }
            }
            if isTrackJoined {
                continue
            }

            if ArtistParser.isArtistFeatured(name: cleanName, inTitle: track.title) {
                return true
            }
            // Track artists
            let trackArtists = ArtistParser.parseArtists(from: track.artist)
            if trackArtists.contains(where: { $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) {
                return true
            }
        }

        return false
    }

    /// Formatted release year string (e.g. `2024` or `UNKNOWN YEAR`).
    public var formattedYear: String {
        // Release year
        if let year = resolvedYear, year > 0 {
            return String(year)
        }
        return "UNKNOWN YEAR"
    }
}
