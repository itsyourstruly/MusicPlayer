//
//  TrackSignature.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation

/// Structured metadata signature capturing clean identity and contextual modifiers for accurate matching.
public struct TrackSignature: Sendable, Hashable {
    /// Minimal, stripped search keywords for broad catalog retrieval (e.g., "HUMBLE Kendrick Lamar").
    public let searchQuery: String

    /// Core title stripped of prefixes, track numbers, and bracketed modifiers.
    public let coreTitle: String

    /// Primary artist isolated from collaborative guest features.
    public let primaryArtist: String

    /// Standard studio album name, stripped of deluxe edition noise.
    public let standardAlbum: String

    /// Isolated guest / featured artist names (e.g., ["Rihanna", "SZA"]).
    public let featuredArtists: [String]

    /// Isolated version modifiers (e.g., "Remix", "Club Mix", "Radio Edit", "Extended", "Acoustic", "Instrumental").
    public let versionModifier: String?

    /// Indicates if the track is explicitly a live recording.
    public let isLive: Bool

    /// Indicates if the track is explicitly marked as a remaster.
    public let isRemaster: Bool

    /// Expected track duration in seconds (if known from local audio file).
    public let duration: TimeInterval

    /// Local track number on disc (if available).
    public let trackNumber: Int?

    public init(
        searchQuery: String,
        coreTitle: String,
        primaryArtist: String,
        standardAlbum: String,
        featuredArtists: [String] = [],
        versionModifier: String? = nil,
        isLive: Bool = false,
        isRemaster: Bool = false,
        duration: TimeInterval = 0,
        trackNumber: Int? = nil
    ) {
        self.searchQuery = searchQuery
        self.coreTitle = coreTitle
        self.primaryArtist = primaryArtist
        self.standardAlbum = standardAlbum
        self.featuredArtists = featuredArtists
        self.versionModifier = versionModifier
        self.isLive = isLive
        self.isRemaster = isRemaster
        self.duration = duration
        self.trackNumber = trackNumber
    }
}
