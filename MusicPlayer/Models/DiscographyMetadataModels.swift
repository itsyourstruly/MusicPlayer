import Foundation
import SwiftUI

// MARK: - Candidate Provider Models

/// Candidate artist resolved from an online metadata source.
public struct OnlineArtistCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let source: MetadataAPIOption

    public init(id: String, name: String, source: MetadataAPIOption) {
        self.id = id
        self.name = name
        self.source = source
    }
}

/// Candidate release (album/single/EP) fetched from a single provider.
public struct OnlineReleaseCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let artist: String
    public let releaseYear: Int?
    public let releaseDate: Date?
    public let genre: String?
    public let totalTracks: Int?
    public let artworkURL: URL?
    public let isSingleOrEP: Bool
    public let source: MetadataAPIOption

    public init(
        id: String,
        title: String,
        artist: String,
        releaseYear: Int? = nil,
        releaseDate: Date? = nil,
        genre: String? = nil,
        totalTracks: Int? = nil,
        artworkURL: URL? = nil,
        isSingleOrEP: Bool = false,
        source: MetadataAPIOption
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.releaseYear = releaseYear
        self.releaseDate = releaseDate
        self.genre = genre
        self.totalTracks = totalTracks
        self.artworkURL = artworkURL
        self.isSingleOrEP = isSingleOrEP
        self.source = source
    }
}

/// Candidate track fetched from an online provider.
public struct OnlineTrackCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let duration: TimeInterval?
    public let isrc: String?
    public let releaseYear: Int?
    public let genre: String?
    public let artworkURL: URL?
    public let source: MetadataAPIOption

    public init(
        id: String,
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        isrc: String? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil,
        artworkURL: URL? = nil,
        source: MetadataAPIOption
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.isrc = isrc
        self.releaseYear = releaseYear
        self.genre = genre
        self.artworkURL = artworkURL
        self.source = source
    }
}

// MARK: - Unified Composite Models

/// Composite candidate release synthesized across iTunes, Deezer, and MusicBrainz.
public struct UnifiedReleaseCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var artist: String
    public var releaseYear: Int?
    public var genre: String?
    public var artworkURL: URL?
    public var totalTracks: Int?
    public var totalDiscs: Int?
    public var isSingleOrEP: Bool
    public var tracks: [UnifiedTrackCandidate]
    public var sourceAPIs: [MetadataAPIOption]

    public init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        releaseYear: Int? = nil,
        genre: String? = nil,
        artworkURL: URL? = nil,
        totalTracks: Int? = nil,
        totalDiscs: Int? = nil,
        isSingleOrEP: Bool = false,
        tracks: [UnifiedTrackCandidate] = [],
        sourceAPIs: [MetadataAPIOption] = []
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.releaseYear = releaseYear
        self.genre = genre
        self.artworkURL = artworkURL
        self.totalTracks = totalTracks
        self.totalDiscs = totalDiscs
        self.isSingleOrEP = isSingleOrEP
        self.tracks = tracks
        self.sourceAPIs = sourceAPIs
    }
}

/// Composite candidate track synthesized across multiple metadata providers.
public struct UnifiedTrackCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval?
    public var isrc: String?
    public var releaseYear: Int?
    public var genre: String?
    public var artworkURL: URL?
    public var sourceAPIs: [MetadataAPIOption]

    public init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        album: String,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        isrc: String? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil,
        artworkURL: URL? = nil,
        sourceAPIs: [MetadataAPIOption] = []
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.isrc = isrc
        self.releaseYear = releaseYear
        self.genre = genre
        self.artworkURL = artworkURL
        self.sourceAPIs = sourceAPIs
    }
}

// MARK: - Matching & Review Models

/// Supported metadata fields for selective diff review.
public enum DiscographyField: String, CaseIterable, Identifiable, Sendable {
    case title = "Title"
    case trackNumber = "Track #"
    case discNumber = "Disc #"
    case year = "Year"
    case artwork = "Artwork"
    case isrc = "ISRC"

    public var id: String { rawValue }
}

/// Individual field comparison and toggle state.
public struct DiscographyFieldDiff: Identifiable, Sendable, Hashable {
    public var id: String { field.rawValue }
    public let field: DiscographyField
    public let localValue: String
    public let onlineValue: String
    public let hasChange: Bool
    public var isAccepted: Bool

    public init(
        field: DiscographyField,
        localValue: String,
        onlineValue: String,
        hasChange: Bool,
        isAccepted: Bool? = nil
    ) {
        self.field = field
        self.localValue = localValue
        self.onlineValue = onlineValue
        self.hasChange = hasChange
        // By default, if there is a real change, accept it unless locked
        self.isAccepted = isAccepted ?? hasChange
    }
}

/// A matched local track against a unified online track candidate.
public struct DiscographyTrackMatch: Identifiable, Sendable, Hashable {
    public var id: UUID { localTrack.id }
    public let localTrack: Track
    public var matchedOnlineTrack: UnifiedTrackCandidate?
    public var targetAlbumTitle: String
    public var isRelocated: Bool
    public var relocationTarget: String?
    public var isAlternate: Bool
    public var alternateReason: String?
    public var score: Double
    public var isLocked: Bool
    public var fieldDiffs: [DiscographyFieldDiff]

    public init(
        localTrack: Track,
        matchedOnlineTrack: UnifiedTrackCandidate?,
        targetAlbumTitle: String,
        isRelocated: Bool = false,
        relocationTarget: String? = nil,
        isAlternate: Bool = false,
        alternateReason: String? = nil,
        score: Double = 0.0,
        isLocked: Bool = false,
        fieldDiffs: [DiscographyFieldDiff] = []
    ) {
        self.localTrack = localTrack
        self.matchedOnlineTrack = matchedOnlineTrack
        self.targetAlbumTitle = targetAlbumTitle
        self.isRelocated = isRelocated
        self.relocationTarget = relocationTarget
        self.isAlternate = isAlternate
        self.alternateReason = alternateReason
        self.score = score
        self.isLocked = isLocked
        self.fieldDiffs = fieldDiffs
    }

    /// Whether this track has any accepted modifications that will overwrite local metadata.
    public var willOverwrite: Bool {
        guard !isLocked else { return false }
        if isRelocated { return true }
        return fieldDiffs.contains { $0.hasChange && $0.isAccepted }
    }

    public var onlineDisplayTitle: String {
        matchedOnlineTrack?.title ?? localTrack.title
    }
}

/// Category filter options for the discography review sheet.
public enum DiscographyReviewCategory: String, CaseIterable, Identifiable, Sendable {
    case albums = "Albums"
    case singles = "Singles"
    case alternates = "Alternates"

    public var id: String { rawValue }
}

/// An individual reviewed album in the discography batch scan, matching local album and child cuts against a verified online album.
public struct DiscographyAlbumReviewItem: Identifiable, Sendable {
    public var id: String { "\(album.id)__\(selectedOnlineAlbum.id)" }
    public let album: Album
    public var selectedOnlineAlbum: OnlineAlbumItem
    public var onlineCuts: [OnlineTrackMetadata]
    public var assignments: [DisambiguationMatcher.AlbumCutAssignment]
    public var unmatchedTracks: [Track]
    public var unmatchedActions: [UUID: UnmatchedTrackAction]
    public var acceptedTrackIDs: Set<UUID>
    public var rejectedTrackIDs: Set<UUID>
    public var lockedTrackIDs: Set<UUID>
    public var category: DiscographyReviewCategory

    public init(
        album: Album,
        selectedOnlineAlbum: OnlineAlbumItem,
        onlineCuts: [OnlineTrackMetadata],
        assignments: [DisambiguationMatcher.AlbumCutAssignment],
        unmatchedTracks: [Track],
        unmatchedActions: [UUID: UnmatchedTrackAction] = [:],
        acceptedTrackIDs: Set<UUID> = [],
        rejectedTrackIDs: Set<UUID> = [],
        lockedTrackIDs: Set<UUID> = [],
        category: DiscographyReviewCategory = .albums
    ) {
        self.album = album
        self.selectedOnlineAlbum = selectedOnlineAlbum
        self.onlineCuts = onlineCuts
        self.assignments = assignments
        self.unmatchedTracks = unmatchedTracks
        self.unmatchedActions = unmatchedActions
        self.acceptedTrackIDs = acceptedTrackIDs
        self.rejectedTrackIDs = rejectedTrackIDs
        self.lockedTrackIDs = lockedTrackIDs
        self.category = category
    }

    /// Whether this album has pending changes that will be written.
    public var willOverwrite: Bool {
        let titleChanged = FuzzyMatcher.normalize(album.title) != FuzzyMatcher.normalize(selectedOnlineAlbum.title)
        if titleChanged { return true }
        if selectedOnlineAlbum.artworkURL != nil && (album.artworkKey == nil || album.artworkKey?.isEmpty == true) {
            return true
        }
        for a in assignments {
            guard let local = a.localTrack else { continue }
            if lockedTrackIDs.contains(local.id) { continue }
            let isLocalInAlbum = album.tracks.contains(where: { $0.id == local.id })
            if isLocalInAlbum {
                if !rejectedTrackIDs.contains(local.id) {
                    if a.isMislabeled || a.cut.title != local.title || (local.trackNumber != nil && a.cut.trackNumber != local.trackNumber) {
                        return true
                    }
                }
            } else {
                if acceptedTrackIDs.contains(local.id) {
                    return true
                }
            }
        }
        if !unmatchedActions.isEmpty {
            return true
        }
        return false
    }

    public var overwritesCount: Int {
        var count = 0
        for a in assignments {
            guard let local = a.localTrack else { continue }
            if lockedTrackIDs.contains(local.id) { continue }
            let isLocalInAlbum = album.tracks.contains(where: { $0.id == local.id })
            if isLocalInAlbum {
                if !rejectedTrackIDs.contains(local.id) {
                    count += 1
                }
            } else {
                if acceptedTrackIDs.contains(local.id) {
                    count += 1
                }
            }
        }
        for u in unmatchedTracks {
            if !lockedTrackIDs.contains(u.id) {
                count += 1
            }
        }
        return count
    }
}

/// An album group card matching a local album and its tracks against a unified online release.
public struct DiscographyAlbumMatch: Identifiable, Sendable, Hashable {
    public var id: String { "\(localAlbumTitle)__\(onlineRelease.id)" }
    public let localAlbum: Album?
    public let localAlbumTitle: String
    public let localAlbumArtist: String
    public let localArtworkKey: String?
    public var onlineRelease: UnifiedReleaseCandidate
    public var trackMatches: [DiscographyTrackMatch]
    public var alternates: [DiscographyTrackMatch]

    public init(
        localAlbum: Album? = nil,
        localAlbumTitle: String,
        localAlbumArtist: String,
        localArtworkKey: String? = nil,
        onlineRelease: UnifiedReleaseCandidate,
        trackMatches: [DiscographyTrackMatch] = [],
        alternates: [DiscographyTrackMatch] = []
    ) {
        self.localAlbum = localAlbum
        self.localAlbumTitle = localAlbumTitle
        self.localAlbumArtist = localAlbumArtist
        self.localArtworkKey = localArtworkKey
        self.onlineRelease = onlineRelease
        self.trackMatches = trackMatches
        self.alternates = alternates
    }

    public var isSingleOrEP: Bool {
        onlineRelease.isSingleOrEP
    }

    /// True if any track in this album or the album artwork/title will be updated.
    public var willOverwrite: Bool {
        let titleChanged = FuzzyMatcher.normalize(localAlbumTitle) != FuzzyMatcher.normalize(onlineRelease.title)
        if titleChanged { return true }
        if onlineRelease.artworkURL != nil && (localArtworkKey == nil || localArtworkKey?.isEmpty == true) {
            return true
        }
        return trackMatches.contains { $0.willOverwrite } || alternates.contains { $0.willOverwrite }
    }

    /// Converts this legacy album match into a standardized DiscographyAlbumReviewItem.
    public func toReviewItem(category: DiscographyReviewCategory = .albums) -> DiscographyAlbumReviewItem {
        let alb = localAlbum ?? Album(
            title: localAlbumTitle,
            artist: localAlbumArtist,
            artworkKey: localArtworkKey,
            tracks: trackMatches.map(\.localTrack) + alternates.map(\.localTrack)
        )
        let onlineItem = OnlineAlbumItem(
            id: onlineRelease.id,
            title: onlineRelease.title,
            artistName: onlineRelease.artist,
            releaseDate: nil,
            releaseYear: onlineRelease.releaseYear,
            genre: onlineRelease.genre,
            trackCount: onlineRelease.totalTracks,
            artworkURL: onlineRelease.artworkURL,
            sourceAPI: onlineRelease.sourceAPIs.first?.displayName ?? "Online"
        )
        let cuts = onlineRelease.tracks.map { ut in
            OnlineTrackMetadata(
                id: ut.id,
                title: ut.title,
                artist: ut.artist,
                album: ut.album,
                albumArtist: onlineRelease.artist,
                releaseDate: nil,
                releaseYear: ut.releaseYear ?? onlineRelease.releaseYear,
                genre: ut.genre ?? onlineRelease.genre,
                trackNumber: ut.trackNumber,
                totalTracks: onlineRelease.totalTracks,
                discNumber: ut.discNumber ?? 1,
                duration: ut.duration,
                artworkURL: ut.artworkURL ?? onlineRelease.artworkURL,
                sourceAPI: ut.sourceAPIs.first?.displayName ?? "Online"
            )
        }
        let assignments = trackMatches.map { tm in
            let cut = cuts.first(where: { $0.id == tm.matchedOnlineTrack?.id }) ?? OnlineTrackMetadata(
                id: tm.matchedOnlineTrack?.id ?? UUID().uuidString,
                title: tm.onlineDisplayTitle,
                artist: tm.matchedOnlineTrack?.artist ?? onlineRelease.artist,
                album: onlineRelease.title,
                trackNumber: tm.matchedOnlineTrack?.trackNumber
            )
            return DisambiguationMatcher.AlbumCutAssignment(
                cut: cut,
                localTrack: tm.localTrack,
                confidenceScore: Int(tm.score * 1000),
                isMislabeled: tm.isRelocated,
                mislabelReason: tm.relocationTarget != nil ? "Relocate to \(tm.relocationTarget!)" : nil
            )
        }
        let unmatched = alternates.map(\.localTrack)
        var actions: [UUID: UnmatchedTrackAction] = [:]
        for alt in alternates {
            actions[alt.localTrack.id] = .moveToAlternates(reason: alt.alternateReason ?? "Alternate version")
        }

        return DiscographyAlbumReviewItem(
            album: alb,
            selectedOnlineAlbum: onlineItem,
            onlineCuts: cuts,
            assignments: assignments,
            unmatchedTracks: unmatched,
            unmatchedActions: actions,
            category: category
        )
    }
}

/// The complete review dataset for an artist's discography scan.
public struct DiscographyScanResult: Sendable {
    public let artistName: String
    public var albums: [DiscographyAlbumReviewItem]
    public var singles: [DiscographyAlbumReviewItem]
    public var alternates: [DiscographyAlbumReviewItem]

    public init(
        artistName: String,
        albums: [DiscographyAlbumReviewItem] = [],
        singles: [DiscographyAlbumReviewItem] = [],
        alternates: [DiscographyAlbumReviewItem] = []
    ) {
        self.artistName = artistName
        self.albums = albums
        self.singles = singles
        self.alternates = alternates
    }

    public init(
        artistName: String,
        albums: [DiscographyAlbumMatch],
        singles: [DiscographyAlbumMatch],
        alternates: [DiscographyAlbumMatch]
    ) {
        self.artistName = artistName
        self.albums = albums.map { $0.toReviewItem(category: .albums) }
        self.singles = singles.map { $0.toReviewItem(category: .singles) }
        self.alternates = alternates.map { $0.toReviewItem(category: .alternates) }
    }

    public var totalMatchesCount: Int {
        albums.count + singles.count + alternates.count
    }

    public var totalOverwritesCount: Int {
        albums.reduce(0) { $0 + $1.overwritesCount } +
        singles.reduce(0) { $0 + $1.overwritesCount } +
        alternates.reduce(0) { $0 + $1.overwritesCount }
    }
}
