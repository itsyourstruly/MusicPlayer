//
//  Album.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Grouped album representation containing sorted tracks and discography metadata.
public struct Album: Identifiable, Codable, Sendable, Hashable {
    public var id: String {
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let y = year, y > 0 {
            return "\(cleanArtist)_\(cleanTitle)_\(y)"
        }
        return "\(cleanArtist)_\(cleanTitle)"
    }

    public let title: String
    public let artist: String
    public let year: Int?
    public let genre: String?
    public let artworkKey: String?
    public let tracks: [Track]

    public let normalizedTitle: String
    public let normalizedArtist: String
    public let searchTokens: String

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

        let nTitle = FuzzyMatcher.normalize(title)
        let nArtist = FuzzyMatcher.normalize(artist)
        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.searchTokens = "\(nTitle) \(nArtist)"

        // Sort tracks by disc number then track number, then title
        self.tracks = tracks.sorted { lhs, rhs in
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
    }

    private enum CodingKeys: String, CodingKey {
        case title, artist, year, genre, artworkKey, tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Album"
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        self.year = try container.decodeIfPresent(Int.self, forKey: .year)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.artworkKey = try container.decodeIfPresent(String.self, forKey: .artworkKey)
        self.tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []

        let nTitle = FuzzyMatcher.normalize(self.title)
        let nArtist = FuzzyMatcher.normalize(self.artist)
        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.searchTokens = "\(nTitle) \(nArtist)"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try container.encode(tracks, forKey: .tracks)
    }

    /// Total cumulative duration of all tracks in this album.
    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    /// Human-readable track count string (e.g., `12 TRACKS` or `1 TRACK`).
    public var formattedTrackCount: String {
        let count = tracks.count
        return count == 1 ? "1 TRACK" : "\(count) TRACKS"
    }

    /// Resolved release year: attaches the year from tracks or album metadata.
    public var resolvedYear: Int? {
        let trackYears = tracks.compactMap { $0.year }.filter { $0 > 0 }
        let frequencies = Dictionary(grouping: trackYears, by: { $0 }).mapValues { $0.count }

        // Find the most frequent year across tracks in the album
        if let mostFrequent = frequencies.max(by: { $0.value < $1.value }) {
            return mostFrequent.key
        }

        if let year = year, year > 0 {
            return year
        }

        return nil
    }

    /// Indicates whether this album is a standalone single or EP release.
    public var isSingle: Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "single" || lower.hasSuffix(" - single") || lower.hasSuffix(" (single)") || lower.hasSuffix(" [single]") || lower.hasSuffix(" - ep") || lower.hasSuffix(" (ep)") || lower.hasSuffix(" [ep]") {
            return true
        }
        return tracks.count <= 2
    }

    /// Determines if a given artist is a lead creator or primary collaborator on this album.
    /// Returns true for solo albums and multi-artist collaboration albums, and false for simple guest features.
    /// If an album's artist or tracks belong to a joined artist rule, it only matches if `artistName` is that joined artist.
    public func isLeadOrCollaborativeAlbum(for artistName: String, joinedArtists: [String] = []) -> Bool {
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }

        // 1. Direct album artist match (e.g. Album.artist == "Pete & Bas" or "Drake")
        if artist.localizedCaseInsensitiveCompare(cleanName) == .orderedSame {
            return true
        }

        // Check if the album itself is governed by a joined artist rule
        let albumArtistCanonical = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for joined in joinedArtists {
            let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if albumArtistCanonical == joinedCanonical {
                // This album is explicitly a joined artist album
                return cleanName.lowercased() == joinedCanonical
            }
            let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
            if joinedParts.count > 1 {
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
            let trackArtistCanonical = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var isTrackJoinedUnderOther = false
            for joined in joinedArtists {
                let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trackArtistCanonical == joinedCanonical {
                    if cleanName.lowercased() != joinedCanonical {
                        isTrackJoinedUnderOther = true
                    }
                    break
                }
                let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
                if joinedParts.count > 1 {
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
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }

        // If this is the artist's own lead or collaboration album, it is not a guest feature
        if isLeadOrCollaborativeAlbum(for: cleanName, joinedArtists: joinedArtists) {
            return false
        }

        // Check if the album is a joined artist collaboration that cleanName is part of; if so, it should NOT appear here
        for joined in joinedArtists {
            let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
            if joinedParts.contains(cleanName.lowercased()) {
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
                let joinedCanonical = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let joinedParts = ArtistParser.parseArtists(from: joined).map { $0.lowercased() }
                if joinedParts.contains(cleanName.lowercased()) {
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
            let trackArtists = ArtistParser.parseArtists(from: track.artist)
            if trackArtists.contains(where: { $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) {
                return true
            }
        }

        return false
    }

    /// Formatted release year string (e.g. `2024` or `UNKNOWN YEAR`).
    public var formattedYear: String {
        if let year = resolvedYear, year > 0 {
            return String(year)
        }
        return "UNKNOWN YEAR"
    }
}

