import Foundation

// MARK: - Album

/// Grouped album representation containing sorted tracks and discography metadata.
nonisolated public struct Album: Identifiable, Codable, Sendable, Hashable {

    // MARK: - Identity

    /// Stable ID derived from artist + title + year so albums with the same name by different artists don't collide.
    /// In folder mode, groupKey disambiguates distinct folders that share the same album title.
    public var id: String {
        if let key = groupKey, !key.isEmpty {
            return key
        }
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

    // Disambiguation key for folder-mode hierarchy grouping
    public let groupKey: String?
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
    /// Normalized album-artist names (`ServerCredits.nameKey`) when this album mirrors media-server credits.
    /// Nil for local-only albums, whose attribution keeps using ArtistParser rules.
    public let albumArtistKeys: [String]?
    /// Normalized names of server track-artist entities credited on this album who are not album artists ("Appears on").
    public let featuredArtistKeys: [String]?
    /// Server-provided sort title (e.g. Jellyfin SortName, Subsonic sortName, Plex titleSort).
    public let sortName: String?

    /// Unique identifiers of all tracks contained in this album.
    public var trackIDs: [UUID] {
        tracks.map { $0.id }
    }

    // Pre-normalized forms used by fuzzy search — computed once at init to avoid repeated lowercasing.
    public let normalizedTitle: String
    // Normalized artist
    public let normalizedArtist: String
    // Search tokens
    public let searchTokens: String

    // Pre-computed classification and partition properties
    public let resolvedYear: Int?
    public let mainTracks: [Track]
    public let alternateTracks: [Track]

    // MARK: - Init

    /// Memberwise restore initializer that directly assigns precomputed fields without sorting or parsing.
    public init(
        restoredFrom record: AlbumRecord,
        tracks: [Track],
        mainTracks: [Track],
        alternateTracks: [Track]
    ) {
        self.groupKey = record.groupKey
        self.title = record.title
        self.artist = record.artist
        self.year = record.year
        self.genre = record.genre
        self.artworkKey = record.artworkKey
        self.tracks = tracks
        self.albumArtistKeys = record.albumArtistKeys
        self.featuredArtistKeys = record.featuredArtistKeys
        self.sortName = record.sortName
        self.normalizedTitle = record.normalizedTitle
        self.normalizedArtist = record.normalizedArtist
        self.searchTokens = record.searchTokens
        self.resolvedYear = record.resolvedYear
        self.mainTracks = mainTracks
        self.alternateTracks = alternateTracks
    }

    // Initialize with configured properties
    public init(
        title: String,
        artist: String,
        year: Int? = nil,
        genre: String? = nil,
        artworkKey: String? = nil,
        tracks: [Track] = [],
        groupKey: String? = nil,
        albumArtistKeys: [String]? = nil,
        featuredArtistKeys: [String]? = nil,
        sortName: String? = nil
    ) {
        var cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.hasSuffix(" (Alternates)") {
            cleanTitle = String(cleanTitle.dropLast(" (Alternates)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if cleanTitle.hasSuffix("(Alternates)") {
            cleanTitle = String(cleanTitle.dropLast("(Alternates)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        self.groupKey = groupKey
        self.albumArtistKeys = albumArtistKeys
        self.featuredArtistKeys = featuredArtistKeys
        self.sortName = sortName
        self.title = cleanTitle
        self.artist = artist
        self.year = year
        self.genre = genre
        self.artworkKey = Album.computeConsensusArtworkKey(tracks: tracks, fallbackKey: artworkKey)

        // N title
        let nTitle = FuzzyMatcher.normalize(cleanTitle)
        // N artist
        let nArtist = FuzzyMatcher.normalize(artist)
        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.searchTokens = "\(nTitle) \(nArtist)"

        // Sort tracks by disc number then track number, then title
        let sortedTracks = tracks.sorted { lhs, rhs in
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
        self.tracks = sortedTracks

        self.resolvedYear = Album.computeResolvedYear(tracks: sortedTracks, fallbackYear: year)

        let partitions = Album.computeTrackPartitions(tracks: sortedTracks)
        self.mainTracks = partitions.main
        self.alternateTracks = partitions.alts
    }

    // MARK: - Codable

    // Defines CodingKeys cases
    private enum CodingKeys: String, CodingKey {
        // Title option
        case groupKey, title, artist, year, genre, artworkKey, tracks
        case albumArtistKeys, featuredArtistKeys, sortName
    }

    /// Custom decoder so we can recompute normalised fields after decoding stored data.
    public init(from decoder: Decoder) throws {
        // Container
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groupKey = try container.decodeIfPresent(String.self, forKey: .groupKey)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Album"
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        self.year = try container.decodeIfPresent(Int.self, forKey: .year)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.albumArtistKeys = try container.decodeIfPresent([String].self, forKey: .albumArtistKeys)
        self.featuredArtistKeys = try container.decodeIfPresent([String].self, forKey: .featuredArtistKeys)
        self.sortName = try container.decodeIfPresent(String.self, forKey: .sortName)
        let storedArtworkKey = try container.decodeIfPresent(String.self, forKey: .artworkKey)
        let decodedTracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        self.artworkKey = Album.computeConsensusArtworkKey(tracks: decodedTracks, fallbackKey: storedArtworkKey)

        // N title
        let nTitle = FuzzyMatcher.normalize(self.title)
        // N artist
        let nArtist = FuzzyMatcher.normalize(self.artist)
        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.searchTokens = "\(nTitle) \(nArtist)"

        let sortedTracks = decodedTracks.sorted { lhs, rhs in
            let lhsDisc = lhs.discNumber ?? 1
            let rhsDisc = rhs.discNumber ?? 1
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            let lhsNum = lhs.trackNumber ?? 0
            let rhsNum = rhs.trackNumber ?? 0
            if lhsNum > 0 && rhsNum > 0 && lhsNum != rhsNum {
                return lhsNum < rhsNum
            }
            if lhsNum > 0 && rhsNum == 0 { return true }
            if lhsNum == 0 && rhsNum > 0 { return false }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        self.tracks = sortedTracks

        self.resolvedYear = Album.computeResolvedYear(tracks: sortedTracks, fallbackYear: self.year)

        let partitions = Album.computeTrackPartitions(tracks: sortedTracks)
        self.mainTracks = partitions.main
        self.alternateTracks = partitions.alts
    }

    // Encode
    public func encode(to encoder: Encoder) throws {
        // Container
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(groupKey, forKey: .groupKey)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(albumArtistKeys, forKey: .albumArtistKeys)
        try container.encodeIfPresent(featuredArtistKeys, forKey: .featuredArtistKeys)
        try container.encodeIfPresent(sortName, forKey: .sortName)
    }

    /// Returns this album with a different track list, keeping identity (groupKey), attribution keys and sort name.
    public func withTracks(_ newTracks: [Track]) -> Album {
        Album(
            title: title,
            artist: artist,
            year: year,
            genre: genre,
            artworkKey: artworkKey,
            tracks: newTracks,
            groupKey: groupKey,
            albumArtistKeys: albumArtistKeys,
            featuredArtistKeys: featuredArtistKeys,
            sortName: sortName
        )
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

    // MARK: - Internal Precomputation Helpers

    /// Computes the consensus artwork key: selects the most-common (majority) artwork key across tracks.
    public static func computeConsensusArtworkKey(tracks: [Track], fallbackKey: String? = nil) -> String? {
        let validKeys = tracks.compactMap { $0.artworkKey }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validKeys.isEmpty else {
            return fallbackKey
        }
        var counts: [String: Int] = [:]
        for key in validKeys {
            counts[key, default: 0] += 1
        }
        let maxCount = counts.values.max() ?? 0
        if let fallback = fallbackKey, counts[fallback] == maxCount {
            return fallback
        }
        for key in validKeys {
            if counts[key] == maxCount {
                return key
            }
        }
        return fallbackKey ?? validKeys.first
    }

    /// Computes the resolved release year: prefers the most-common year across tracks, falls back to the album-level tag.
    private static func computeResolvedYear(tracks: [Track], fallbackYear: Int?) -> Int? {
        let trackYears = tracks.compactMap { $0.year }.filter { $0 > 0 }
        let frequencies = Dictionary(grouping: trackYears, by: { $0 }).mapValues { $0.count }
        if let mostFrequent = frequencies.max(by: { $0.value < $1.value }) {
            return mostFrequent.key
        }
        if let year = fallbackYear, year > 0 {
            return year
        }
        return nil
    }

    /// Partitions tracks into main canonical tracks and alternate/bonus cuts once upon creation.
    private static func computeTrackPartitions(tracks: [Track]) -> (main: [Track], alts: [Track]) {
        let rawAlts = tracks.filter(DiscographyClassifier.isAlternateTrack)

        if rawAlts.isEmpty {
            return (tracks, [])
        }
        if rawAlts.count == tracks.count && !tracks.contains(where: { $0.isAlternate == true }) {
            return (tracks, [])
        }

        let altSet = Set(rawAlts.map { $0.id })
        let main = tracks.filter { !altSet.contains($0.id) }
        let sortedAlts = sortAlternateTracks(alts: rawAlts, canonicalTracks: main)
        return (main, sortedAlts)
    }

    private struct AltSortKey {
        let parentIndex: Int
        let discNumber: Int
        let trackNumber: Int
        let title: String
    }

    /// Ultra-fast alternate track sorting using precomputed sort keys (Schwartzian transform).
    private static func sortAlternateTracks(alts: [Track], canonicalTracks: [Track]) -> [Track] {
        guard alts.count > 1 else { return alts }

        var mainIndices: [String: Int] = [:]
        var mainNorms: [(norm: String, idx: Int)] = []

        for (idx, track) in canonicalTracks.enumerated() {
            let sig = MetadataSanitizer.buildSignature(title: track.title, artist: track.artist, album: track.album)
            let core = FuzzyMatcher.normalize(sig.coreTitle)
            if !core.isEmpty && mainIndices[core] == nil {
                mainIndices[core] = idx
            }
            let norm = FuzzyMatcher.normalize(track.title)
            if !norm.isEmpty {
                mainNorms.append((norm, idx))
            }
        }

        let keyed: [(track: Track, key: AltSortKey)] = alts.map { track in
            let sig = MetadataSanitizer.buildSignature(title: track.title, artist: track.artist, album: track.album)
            let core = FuzzyMatcher.normalize(sig.coreTitle)

            var parentIdx = mainIndices[core]
            if parentIdx == nil && !core.isEmpty {
                parentIdx = mainNorms.first(where: { $0.norm.contains(core) || core.contains($0.norm) })?.idx
            }

            let disc = track.discNumber ?? 1
            let num = track.trackNumber ?? 0

            return (track, AltSortKey(
                parentIndex: parentIdx ?? Int.max,
                discNumber: disc,
                trackNumber: num,
                title: track.title
            ))
        }

        return keyed.sorted { lhs, rhs in
            if lhs.key.parentIndex != rhs.key.parentIndex {
                return lhs.key.parentIndex < rhs.key.parentIndex
            }
            let lDisc = lhs.key.discNumber
            let rDisc = rhs.key.discNumber
            if lDisc != rDisc { return lDisc < rDisc }

            let lNum = lhs.key.trackNumber
            let rNum = rhs.key.trackNumber
            if lNum > 0 && rNum > 0 && lNum != rNum {
                return lNum < rNum
            }
            if lNum > 0 && rNum == 0 { return true }
            if lNum == 0 && rNum > 0 { return false }

            return lhs.key.title.localizedCaseInsensitiveCompare(rhs.key.title) == .orderedAscending
        }.map { $0.track }
    }

    /// Resolved visual artwork key for this album (album tag artworkKey, falling back to first track with artwork).
    public var effectiveArtworkKey: String? {
        if let key = artworkKey, !key.isEmpty {
            return key
        }
        return tracks.compactMap { $0.artworkKey }.first(where: { !$0.isEmpty })
    }

    // MARK: - Artist Attribution

    /// Server credit keys contain the artist: exact name key first, then the punctuation-insensitive canonical key
    /// (the same identity `Artist.id` uses), so the merged library artist always finds its server albums.
    static func serverKeys(_ keys: [String], contain artistName: String) -> Bool {
        guard !keys.isEmpty else { return false }
        if keys.contains(ServerCredits.nameKey(artistName)) { return true }
        let canonical = ArtistParser.canonicalArtistKey(artistName)
        guard !canonical.isEmpty else { return false }
        return keys.contains { ArtistParser.canonicalArtistKey($0) == canonical }
    }

    /// Determines if a given artist is a lead creator or primary collaborator on this album.
    /// Returns true for solo albums and multi-artist collaboration albums, and false for simple guest features.
    /// If an album's artist or tracks belong to a joined artist rule, it only matches if `artistName` is that joined artist.
    public func isLeadOrCollaborativeAlbum(for artistName: String, joinedArtists: [String] = []) -> Bool {
        // Clean name
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        // Server-mirrored albums: the server's album-artist list is authoritative. The library artist is resolved
        // from the server's artist id at grouping time, so a punctuation variant ("Anderson Paak" vs "Anderson .Paak")
        // of the same artist still matches.
        if let keys = albumArtistKeys {
            return Album.serverKeys(keys, contain: cleanName)
        }
        let canonicalCleanName = ArtistParser.canonicalArtistKey(cleanName)

        // 1. Direct album artist match (e.g. Album.artist == "Pete & Bas" or "Drake" or "J. Cole" vs "J Cole")
        if artist.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
           ArtistParser.canonicalArtistKey(artist) == canonicalCleanName {
            return true
        }

        // Check if cleanName is one of the co-lead artists parsed from the album's artist string
        let albumParts = ArtistParser.parseArtists(from: artist)
        if albumParts.contains(where: {
            $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
            ArtistParser.canonicalArtistKey($0) == canonicalCleanName
        }) {
            return true
        }

        // Check if any track's albumArtist matches cleanName or contains it as a parsed artist
        for track in tracks {
            if let trackAlb = track.albumArtist, !trackAlb.isEmpty {
                if trackAlb.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
                   ArtistParser.canonicalArtistKey(trackAlb) == canonicalCleanName ||
                   ArtistParser.parseArtists(from: trackAlb).contains(where: {
                       $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
                       ArtistParser.canonicalArtistKey($0) == canonicalCleanName
                   }) {
                    return true
                }
            }
        }

        // Check if the album itself is governed by a joined artist rule
        let albumArtistCanonical = ArtistParser.canonicalArtistKey(artist)
        for joined in joinedArtists {
            let joinedCanonical = ArtistParser.canonicalArtistKey(joined)
            if albumArtistCanonical == joinedCanonical {
                return canonicalCleanName == joinedCanonical
            }
            let joinedParts = ArtistParser.parseArtists(from: joined).map { ArtistParser.canonicalArtistKey($0) }
            if joinedParts.count > 1 {
                let albumParts = ArtistParser.parseArtists(from: artist).map { ArtistParser.canonicalArtistKey($0) }
                if Set(joinedParts).isSubset(of: Set(albumParts)) {
                    return canonicalCleanName == joinedCanonical
                }
            }
        }

        // 2. Resolve collaborative album artists using unified logic
        let resolvedAlbumArtists = ArtistParser.resolveAlbumArtists(
            for: tracks,
            explicitAlbumArtist: artist,
            joinedArtists: joinedArtists
        )

        return resolvedAlbumArtists.contains {
            $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
            ArtistParser.canonicalArtistKey($0) == canonicalCleanName
        }
    }

    /// Determines if a given artist is featured as a guest on this album (via title `(feat. )` or minor track credits).
    public func isFeaturedAlbum(for artistName: String, joinedArtists: [String] = []) -> Bool {
        // Clean name
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        // Server-mirrored albums: "Appears on" only where the server credits the artist as a track-artist entity.
        if let keys = albumArtistKeys {
            return !Album.serverKeys(keys, contain: cleanName)
                && Album.serverKeys(featuredArtistKeys ?? [], contain: cleanName)
        }
        let canonicalCleanName = ArtistParser.canonicalArtistKey(cleanName)

        // If this is the artist's own lead or collaboration album, it is not a guest feature
        if isLeadOrCollaborativeAlbum(for: cleanName, joinedArtists: joinedArtists) {
            return false
        }

        // Check if the album is a joined artist collaboration that cleanName is part of; if so, it should NOT appear here
        for joined in joinedArtists {
            let joinedCanonical = ArtistParser.canonicalArtistKey(joined)
            let joinedParts = ArtistParser.parseArtists(from: joined).map { ArtistParser.canonicalArtistKey($0) }
            if joinedParts.contains(canonicalCleanName) {
                let albumParts = ArtistParser.parseArtists(from: artist).map { ArtistParser.canonicalArtistKey($0) }
                if Set(joinedParts).isSubset(of: Set(albumParts)) || ArtistParser.canonicalArtistKey(artist) == joinedCanonical {
                    return false
                }
            }
        }

        // Check if any track on this album features the artist in the title or artist tag
        for track in tracks {
            // If the track is a joined artist track that cleanName is part of, skip it
            var isTrackJoined = false
            for joined in joinedArtists {
                let joinedCanonical = ArtistParser.canonicalArtistKey(joined)
                let joinedParts = ArtistParser.parseArtists(from: joined).map { ArtistParser.canonicalArtistKey($0) }
                if joinedParts.contains(canonicalCleanName) {
                    let trackParts = ArtistParser.parseArtists(from: track.artist).map { ArtistParser.canonicalArtistKey($0) }
                    if Set(joinedParts).isSubset(of: Set(trackParts)) || ArtistParser.canonicalArtistKey(track.artist) == joinedCanonical {
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
            let trackArtists = ArtistParser.parseArtists(from: track.artist)
            if trackArtists.contains(where: {
                $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
                ArtistParser.canonicalArtistKey($0) == canonicalCleanName
            }) {
                return true
            }
        }

        return false
    }

    /// Formatted release year string (e.g. `2024` or `UNKNOWN YEAR`).
    public var formattedYear: String {
        // Release year
        if let year = resolvedYear ?? year, year > 0 {
            return String(year)
        }
        return "UNKNOWN YEAR"
    }

    /// Display release year string if known (e.g. "2024"), or nil if unknown.
    public var displayYear: String? {
        if let year = resolvedYear ?? year, year > 0 {
            return String(year)
        }
        if let trackYear = tracks.compactMap({ $0.year }).first(where: { $0 > 0 }) {
            return String(trackYear)
        }
        return nil
    }

    /// Canonical release type title for top bar display: "ALBUM", "SINGLE", "EP", or "ALTERNATE".
    public var releaseTypeDisplayTitle: String {
        DiscographyClassifier.displayTitle(for: self)
    }

    // MARK: - Classification (thin wrappers over DiscographyClassifier, the single source of truth)

    /// Discography section for this album as the artist's own release (plan §3.8).
    public var releaseSection: DiscographySection { DiscographyClassifier.releaseSection(for: self) }
    /// Classified as a single or EP.
    public var isSingle: Bool { releaseSection == .singlesAndEPs }
    /// Classified as an alternate release (remix, live, deluxe-style qualifier, version, …).
    public var isAlternateRelease: Bool { releaseSection == .alternates }
    /// Classified as a regular studio album.
    public var isStudioAlbum: Bool { releaseSection == .albums }
}
