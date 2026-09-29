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

    /// Precomputed count of own albums & singles (excluding guest features on other artists' albums).
    public let ownAlbumCount: Int
    /// Precomputed count of tracks across own albums & singles.
    public let ownTrackCount: Int
    /// Precomputed total duration across own albums & singles.
    public let ownTotalDuration: TimeInterval
    /// Precomputed summary string (e.g. `2 ALBUMS · 24 TRACKS`) reflecting only own releases.
    public let discographySummary: String
    /// Precomputed primary visual avatar artwork key for this artist.
    public let mostRecentArtworkKey: String?

    // Initialize with configured properties
    public init(name: String, albums: [Album] = [], tracks: [Track] = [], joinedArtists: [String] = []) {
        self.name = name
        // Albums sorted newest-first so discography views show recent releases at the top.
        let sortedAlbums = albums.sorted { ($0.resolvedYear ?? $0.year ?? 0) > ($1.resolvedYear ?? $1.year ?? 0) }
        self.albums = sortedAlbums
        // Tracks sorted alphabetically for the flat track list view.
        self.tracks = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // N name
        let nName = FuzzyMatcher.normalize(name)
        self.normalizedName = nName
        self.searchTokens = nName

        // Precompute own counts once at creation time for zero-latency UI and search
        var ownCount = 0
        var seenTrackIDs = Set<UUID>()
        var dur: TimeInterval = 0
        for album in sortedAlbums {
            if album.isLeadOrCollaborativeAlbum(for: name, joinedArtists: joinedArtists) {
                ownCount += 1
                for track in album.tracks {
                    if seenTrackIDs.insert(track.id).inserted {
                        dur += track.duration
                    }
                }
            }
        }
        self.ownAlbumCount = ownCount
        self.ownTrackCount = seenTrackIDs.count
        self.ownTotalDuration = dur
        let albumText = ownCount == 1 ? "1 ALBUM" : "\(ownCount) ALBUMS"
        let trackText = seenTrackIDs.count == 1 ? "1 TRACK" : "\(seenTrackIDs.count) TRACKS"
        self.discographySummary = "\(albumText) · \(trackText)"
        self.mostRecentArtworkKey = Artist.resolveMostRecentArtworkKey(name: name, albums: sortedAlbums, tracks: self.tracks)
    }

    // MARK: - Codable

    // Defines CodingKeys cases
    private enum CodingKeys: String, CodingKey {
        // Name option
        case name, albums, tracks
        case ownAlbumCount, ownTrackCount, ownTotalDuration, discographySummary, mostRecentArtworkKey
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
        let sortedAlbums = decodedAlbums.sorted { ($0.resolvedYear ?? $0.year ?? 0) > ($1.resolvedYear ?? $1.year ?? 0) }
        self.albums = sortedAlbums
        self.tracks = decodedTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // N name
        let nName = FuzzyMatcher.normalize(self.name)
        self.normalizedName = nName
        self.searchTokens = nName

        // Fast-path: check if precomputed values were serialized to avoid expensive disk/loop resolution
        if let decodedOwnAlbumCount = try container.decodeIfPresent(Int.self, forKey: .ownAlbumCount),
           let decodedOwnTrackCount = try container.decodeIfPresent(Int.self, forKey: .ownTrackCount),
           let decodedOwnDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .ownTotalDuration),
           let decodedSummary = try container.decodeIfPresent(String.self, forKey: .discographySummary) {
            self.ownAlbumCount = decodedOwnAlbumCount
            self.ownTrackCount = decodedOwnTrackCount
            self.ownTotalDuration = decodedOwnDuration
            self.discographySummary = decodedSummary
        } else {
            // Fallback for legacy persisted caches without serialized precomputed counts
            var ownCount = 0
            var seenTrackIDs = Set<UUID>()
            var dur: TimeInterval = 0
            for album in sortedAlbums {
                if album.isLeadOrCollaborativeAlbum(for: self.name) {
                    ownCount += 1
                    for track in album.tracks {
                        if seenTrackIDs.insert(track.id).inserted {
                            dur += track.duration
                        }
                    }
                }
            }
            self.ownAlbumCount = ownCount
            self.ownTrackCount = seenTrackIDs.count
            self.ownTotalDuration = dur
            let albumText = ownCount == 1 ? "1 ALBUM" : "\(ownCount) ALBUMS"
            let trackText = seenTrackIDs.count == 1 ? "1 TRACK" : "\(seenTrackIDs.count) TRACKS"
            self.discographySummary = "\(albumText) · \(trackText)"
        }

        if let decodedArtwork = try container.decodeIfPresent(String.self, forKey: .mostRecentArtworkKey) {
            self.mostRecentArtworkKey = decodedArtwork
        } else {
            self.mostRecentArtworkKey = Artist.resolveMostRecentArtworkKey(name: self.name, albums: sortedAlbums, tracks: self.tracks)
        }
    }

    // Encode
    public func encode(to encoder: Encoder) throws {
        // Container
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(albums, forKey: .albums)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(ownAlbumCount, forKey: .ownAlbumCount)
        try container.encode(ownTrackCount, forKey: .ownTrackCount)
        try container.encode(ownTotalDuration, forKey: .ownTotalDuration)
        try container.encode(discographySummary, forKey: .discographySummary)
        try container.encodeIfPresent(mostRecentArtworkKey, forKey: .mostRecentArtworkKey)
    }

    // MARK: - Computed Properties

    /// Returns albums primarily attributed to this artist (lead creator or co-lead collaborator), excluding guest feature appearances on others' albums.
    public func ownAlbums(joinedArtists: [String] = []) -> [Album] {
        if joinedArtists.isEmpty {
            return albums.filter { $0.isLeadOrCollaborativeAlbum(for: name) }
        }
        return albums.filter { $0.isLeadOrCollaborativeAlbum(for: name, joinedArtists: joinedArtists) }
    }

    /// Returns unique tracks from this artist's own albums and singles (excluding guest feature appearances on other artists' albums).
    public func ownTracks(joinedArtists: [String] = []) -> [Track] {
        let own = ownAlbums(joinedArtists: joinedArtists)
        var seenIDs = Set<UUID>()
        var result: [Track] = []
        for album in own {
            for track in album.tracks {
                if seenIDs.insert(track.id).inserted {
                    result.append(track)
                }
            }
        }
        return result
    }

    /// Total number of tracks across this artist's own albums and singles (excluding guest feature appearances).
    public var totalTrackCount: Int {
        ownTrackCount
    }

    /// Total number of albums by this artist (excluding guest feature appearances).
    public var totalAlbumCount: Int {
        ownAlbumCount
    }

    /// Total playback duration for this artist's own albums and singles.
    public var totalDuration: TimeInterval {
        ownTotalDuration
    }

    /// Total count of all tracks associated with this artist including guest features.
    public var allTracksCount: Int {
        tracks.count
    }

    /// Total count of all albums associated with this artist including guest features.
    public var allAlbumsCount: Int {
        albums.count
    }

    /// Formatted track count subtitle (e.g. `1 TRACK` or `28 TRACKS`).
    public var formattedTrackCount: String {
        totalTrackCount == 1 ? "1 TRACK" : "\(totalTrackCount) TRACKS"
    }

    /// Formatted album and track count subtitle (e.g., `3 ALBUMS · 28 TRACKS`) reflecting only own albums and singles.
    public func discographySummary(joinedArtists: [String] = []) -> String {
        if joinedArtists.isEmpty {
            return discographySummary
        }
        let own = albums.filter { $0.isLeadOrCollaborativeAlbum(for: name, joinedArtists: joinedArtists) }
        var seen = Set<UUID>()
        for a in own {
            for t in a.tracks { seen.insert(t.id) }
        }
        let albText = own.count == 1 ? "1 ALBUM" : "\(own.count) ALBUMS"
        let trkText = seen.count == 1 ? "1 TRACK" : "\(seen.count) TRACKS"
        return "\(albText) · \(trkText)"
    }

    /// Indicates whether the given album is primarily attributed to this artist (lead creator or co-lead collaborator).
    public func isPrimaryAlbumArtist(for album: Album) -> Bool {
        album.isLeadOrCollaborativeAlbum(for: name)
    }

    /// The most recent studio album released by this artist (excluding singles, EPs, remixes, live albums, and guest features).
    public var mostRecentFullAlbum: Album? {
        let studioLeadAlbums = albums
            .filter { $0.isStudioAlbum && isPrimaryAlbumArtist(for: $0) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }

        if let withArt = studioLeadAlbums.first(where: { $0.effectiveArtworkKey != nil }) {
            return withArt
        }
        if let firstStudio = studioLeadAlbums.first {
            return firstStudio
        }
        // Fallback to any lead full album (including live or remixes)
        let anyLeadFull = albums
            .filter { !$0.isSingle && isPrimaryAlbumArtist(for: $0) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        return anyLeadFull.first(where: { $0.effectiveArtworkKey != nil }) ?? anyLeadFull.first
    }

    /// The most recent album released by this artist (prioritizing studio albums, then singles/EPs).
    public var mostRecentAlbum: Album? {
        if let full = mostRecentFullAlbum {
            return full
        }
        let singles = albums.filter { $0.isSingle }.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        return singles.first(where: { $0.effectiveArtworkKey != nil }) ?? singles.first ?? albums.first
    }

    /// Resolves the primary visual avatar artwork key for this artist:
    /// 1. Prioritizes that artist's most recent studio album (lead artist, non-single, non-remix, non-live), even if released long ago.
    /// 2. If the artist has zero studio albums locally, falls back to their most recent single/remix/live release with artwork.
    /// 3. If no albums with artwork exist, falls back to any track where they are the primary artist.
    private static func resolveMostRecentArtworkKey(name: String, albums: [Album], tracks: [Track]) -> String? {
        // 1. That artist's most recent studio album (lead artist, non-single, non-remix, non-live) sorted by year descending
        let studioLeadAlbums = albums
            .filter { $0.isStudioAlbum && $0.isLeadOrCollaborativeAlbum(for: name) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }

        for album in studioLeadAlbums {
            if let artKey = album.effectiveArtworkKey, !artKey.isEmpty {
                return artKey
            }
        }

        // Fallback: any other full album where they appear
        let otherFullAlbums = albums
            .filter { !$0.isSingle }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }

        for album in otherFullAlbums {
            if let artKey = album.effectiveArtworkKey, !artKey.isEmpty {
                return artKey
            }
        }

        // 2. Singles/EPs
        let sortedSingles = albums
            .filter { $0.isSingle }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }

        for single in sortedSingles {
            if let artKey = single.effectiveArtworkKey, !artKey.isEmpty {
                return artKey
            }
        }

        // 3. Fall back to the most recent individual track with available artwork
        let sortedTracks = tracks.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        for track in sortedTracks {
            if let artKey = track.artworkKey, !artKey.isEmpty {
                return artKey
            }
        }

        return nil
    }
}
