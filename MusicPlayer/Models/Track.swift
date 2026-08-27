//
//  Track.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation

/// Core immutable audio track entity containing complete metadata and playback specifications.
public struct Track: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String?
    public let genre: String?
    public let year: Int?
    public let trackNumber: Int?
    public let totalTracks: Int?
    public let discNumber: Int?
    public let duration: TimeInterval
    public let url: URL
    public let artworkKey: String?
    public let dateAdded: Date
    public let fileInfo: AudioFileInfo?
    public let lyrics: String?

    public let originalTrackNumber: Int?
    public let deluxeTrackNumber: Int?

    public let normalizedTitle: String
    public let normalizedArtist: String
    public let normalizedAlbum: String
    public let searchTokens: String

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        originalTrackNumber: Int? = nil,
        deluxeTrackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval,
        url: URL,
        artworkKey: String? = nil,
        dateAdded: Date = Date(),
        fileInfo: AudioFileInfo? = nil,
        lyrics: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.originalTrackNumber = originalTrackNumber ?? trackNumber
        self.deluxeTrackNumber = deluxeTrackNumber
        self.totalTracks = totalTracks
        self.discNumber = discNumber
        self.duration = duration
        self.url = url
        self.artworkKey = artworkKey
        self.dateAdded = dateAdded
        self.fileInfo = fileInfo
        self.lyrics = lyrics

        let nTitle = FuzzyMatcher.normalize(title)
        let nArtist = FuzzyMatcher.normalize(artist)
        let nAlbum = FuzzyMatcher.normalize(album)
        let nGenre = genre != nil ? FuzzyMatcher.normalize(genre!) : ""

        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.normalizedAlbum = nAlbum
        self.searchTokens = "\(nTitle) \(nArtist) \(nAlbum) \(nGenre)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Title"
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        self.album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        self.albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.year = try container.decodeIfPresent(Int.self, forKey: .year)
        self.trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        self.originalTrackNumber = try container.decodeIfPresent(Int.self, forKey: .originalTrackNumber) ?? self.trackNumber
        self.deluxeTrackNumber = try container.decodeIfPresent(Int.self, forKey: .deluxeTrackNumber)
        self.totalTracks = try container.decodeIfPresent(Int.self, forKey: .totalTracks)
        self.discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        if let decodedURL = try? container.decode(URL.self, forKey: .url) {
            self.url = decodedURL
        } else if let urlString = try? container.decode(String.self, forKey: .url) {
            if urlString.hasPrefix("file://") {
                if let url = URL(string: urlString) {
                    self.url = url
                } else {
                    let rawPath = urlString.replacingOccurrences(of: "file://", with: "")
                    let unescaped = rawPath.removingPercentEncoding ?? rawPath
                    self.url = URL(fileURLWithPath: unescaped)
                }
            } else {
                self.url = URL(fileURLWithPath: urlString)
            }
        } else {
            self.url = URL(fileURLWithPath: "")
        }
        self.artworkKey = try container.decodeIfPresent(String.self, forKey: .artworkKey)
        self.dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        self.fileInfo = try container.decodeIfPresent(AudioFileInfo.self, forKey: .fileInfo)
        self.lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)

        let nTitle = FuzzyMatcher.normalize(self.title)
        let nArtist = FuzzyMatcher.normalize(self.artist)
        let nAlbum = FuzzyMatcher.normalize(self.album)
        let nGenre = self.genre != nil ? FuzzyMatcher.normalize(self.genre!) : ""

        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.normalizedAlbum = nAlbum
        self.searchTokens = "\(nTitle) \(nArtist) \(nAlbum) \(nGenre)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumArtist, genre, year, trackNumber, originalTrackNumber, deluxeTrackNumber, totalTracks, discNumber, duration, url, artworkKey, dateAdded, fileInfo, lyrics
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(originalTrackNumber, forKey: .originalTrackNumber)
        try container.encodeIfPresent(deluxeTrackNumber, forKey: .deluxeTrackNumber)
        try container.encodeIfPresent(totalTracks, forKey: .totalTracks)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encode(duration, forKey: .duration)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encodeIfPresent(fileInfo, forKey: .fileInfo)
        try container.encodeIfPresent(lyrics, forKey: .lyrics)
    }

    /// Formatted display string for artist and album pairing.
    public var artistAlbumSubtitle: String {
        if !artist.isEmpty && !album.isEmpty {
            return "\(artist) — \(album)"
        } else if !artist.isEmpty {
            return artist
        } else if !album.isEmpty {
            return album
        } else {
            return "Unknown Artist"
        }
    }

    /// Formatted track index number with fallback.
    public var formattedTrackNumber: String {
        if let trackNum = trackNumber, trackNum > 0 {
            return String(format: "%02d", trackNum)
        }
        return "—"
    }

    /// Accessor for track file URL.
    public var fileURL: URL {
        url
    }

    /// Accessor for track audio file info.
    public var audioFileInfo: AudioFileInfo? {
        fileInfo
    }

    /// Formatted technical specification summary (e.g. "FLAC • 96 kHz" or "MP3 • 320 kbps").
    public var technicalSummary: String {
        if let info = fileInfo {
            let fmt = info.fileExtension.uppercased()
            if info.bitRate > 0 {
                let kbps = Int(info.bitRate / 1000.0)
                return "\(fmt) • \(kbps) kbps"
            } else if info.sampleRate > 0 {
                let rate = Int(info.sampleRate / 1000.0)
                return "\(fmt) • \(rate) kHz"
            } else {
                return fmt
            }
        }
        return ""
    }
}
