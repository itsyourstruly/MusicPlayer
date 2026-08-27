//
//  Artist.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Grouped artist representation containing discography, albums, and associated tracks.
public struct Artist: Identifiable, Codable, Sendable, Hashable {
    public var id: String { name.lowercased() }

    public let name: String
    public let albums: [Album]
    public let tracks: [Track]

    public let normalizedName: String
    public let searchTokens: String

    public init(name: String, albums: [Album] = [], tracks: [Track] = []) {
        self.name = name
        self.albums = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        self.tracks = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let nName = FuzzyMatcher.normalize(name)
        self.normalizedName = nName
        self.searchTokens = nName
    }

    private enum CodingKeys: String, CodingKey {
        case name, albums, tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown Artist"
        let decodedAlbums = try container.decodeIfPresent([Album].self, forKey: .albums) ?? []
        let decodedTracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        self.albums = decodedAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        self.tracks = decodedTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let nName = FuzzyMatcher.normalize(self.name)
        self.normalizedName = nName
        self.searchTokens = nName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(albums, forKey: .albums)
        try container.encode(tracks, forKey: .tracks)
    }

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
        let albumText = totalAlbumCount == 1 ? "1 ALBUM" : "\(totalAlbumCount) ALBUMS"
        let trackText = totalTrackCount == 1 ? "1 TRACK" : "\(totalTrackCount) TRACKS"
        return "\(albumText) · \(trackText)"
    }
}
