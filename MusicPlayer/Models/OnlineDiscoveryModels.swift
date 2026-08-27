//
//  OnlineDiscoveryModels.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation

/// Item type for online discovery search results.
public enum OnlineDiscoveryItemType: String, CaseIterable, Identifiable, Sendable {
    case all = "ALL"
    case tracks = "TRACKS"
    case albums = "ALBUMS"
    case artists = "ARTISTS"

    public var id: String { rawValue }
}

/// An artist discovered via online search with deep metadata and biography.
public struct OnlineArtistItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let genre: String?
    public let imageURL: URL?
    public let appleMusicURL: URL?
    public var biography: String?
    public var topTracks: [OnlineTrackItem]
    public var albums: [OnlineAlbumItem]
    public var featuredAlbums: [OnlineAlbumItem]

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

/// An album discovered via online search with deep metadata, record label, and tracklist.
public struct OnlineAlbumItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let artistName: String
    public let artistId: String?
    public let releaseDate: Date?
    public let releaseYear: Int?
    public let recordLabel: String?
    public let copyright: String?
    public let genre: String?
    public let trackCount: Int?
    public let discCount: Int?
    public let artworkURL: URL?
    public var description: String?
    public var tracklist: [OnlineTrackItem]

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
        self.tracklist = tracklist
    }

    /// Formatted date or year string for display.
    public var formattedReleaseDate: String {
        if let date = releaseDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date).uppercased()
        } else if let year = releaseYear, year > 0 {
            return "\(year)"
        }
        return "—"
    }
}

/// A track discovered via online search with audio preview, credits, and specs.
public struct OnlineTrackItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let albumId: String?
    public let releaseDate: Date?
    public let releaseYear: Int?
    public let genre: String?
    public let trackNumber: Int?
    public let totalTracks: Int?
    public let discNumber: Int?
    public let duration: TimeInterval
    public let previewURL: URL?
    public let artworkURL: URL?
    public let recordLabel: String?
    public let isExplicit: Bool
    public let composer: String?
    public let performers: String?
    public let producers: String?
    public let bpm: Int?

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
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date).uppercased()
        } else if let year = releaseYear, year > 0 {
            return "\(year)"
        }
        return "—"
    }
}

/// Unified search results container.
public struct OnlineSearchResults: Sendable {
    public let artists: [OnlineArtistItem]
    public let albums: [OnlineAlbumItem]
    public let tracks: [OnlineTrackItem]

    public init(
        artists: [OnlineArtistItem] = [],
        albums: [OnlineAlbumItem] = [],
        tracks: [OnlineTrackItem] = []
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }

    public var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && tracks.isEmpty
    }

    public var totalCount: Int {
        artists.count + albums.count + tracks.count
    }
}
