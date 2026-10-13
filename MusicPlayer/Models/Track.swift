import Foundation
import CryptoKit

extension UUID {
    /// Generates a deterministic, reproducible UUID from a string (such as a normalized canonical file path).
    public static func deterministic(from string: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        var bytes = Array(digest)
        // Set version 3 (MD5-based UUID) and RFC 4122 variant
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}

/// Origin source of the track's displayed metadata.
public enum MetadataSource: String, Codable, Sendable, Hashable {
    case embeddedTags = "embeddedTags"
    case folderStructure = "folderStructure"
    case server = "server"
}

/// Frozen snapshot of genuine embedded ID3/audio tags read from disk, allowing pristine METADATA mode restores.
public struct TagSnapshot: Codable, Sendable, Hashable {
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String?
    public let year: Int?
    public let trackNumber: Int?
    public let discNumber: Int?

    public init(
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }
}

/// Core immutable audio track entity containing complete metadata and playback specifications.
public struct Track: Identifiable, Codable, Sendable, Hashable {
    public typealias MetadataSource = MusicPlayer.MetadataSource
    public typealias TagSnapshot = MusicPlayer.TagSnapshot

    // Unique identifier
    public let id: UUID
    // Display title
    public let title: String
    // Primary artist name
    public let artist: String
    // Album title
    public let album: String
    // Album artist
    public let albumArtist: String?
    // Musical genre
    public let genre: String?
    // Composer
    public let composer: String?
    // Performer
    public let performer: String?
    // Release year
    public let year: Int?
    // Track number
    public let trackNumber: Int?
    // Total tracks
    public let totalTracks: Int?
    // Disc number
    public let discNumber: Int?
    // Disc total
    public let discTotal: Int?
    // Duration in seconds
    public let duration: TimeInterval
    // Local audio file URL
    public let url: URL
    // Artwork key
    public let artworkKey: String?
    // Date added
    public let dateAdded: Date
    // File info
    public let fileInfo: AudioFileInfo?
    // Track lyrics
    public let lyrics: String?
    // Explicit alternate status
    public let isAlternate: Bool?
    // Linked folder ID containing this track
    public let folderID: UUID?

    // Path inside the linked folder (e.g. "Artist/Album/01 Title.flac")
    public let relativePath: String?
    // Source of the currently active metadata
    public let metadataSource: MetadataSource?
    // Original embedded tags snapshot
    public let tagSnapshot: TagSnapshot?

    // Jellyfin item and album identifiers
    public let jellyfinItemId: String?
    public let jellyfinAlbumId: String?

    /// Checks if local bytes can be read without triggering a cloud download or streaming error.
    public var canReadLocalBytes: Bool {
        !isJellyfinItem && url.isFileURL && CloudFileAvailability.isLocal(url: url)
    }

    /// Indicates if the track resides in iCloud Drive.
    public var isCloudItem: Bool {
        !isJellyfinItem && CloudFileAvailability.isCloudItem(url: url)
    }

    /// Indicates if the track is stored in iCloud Drive and is fully downloaded locally.
    public var isCloudDownloaded: Bool {
        !isJellyfinItem && CloudFileAvailability.isCloudDownloaded(url: url)
    }

    /// Indicates if the track is associated with or streamed from a Jellyfin remote server.
    public var isJellyfinItem: Bool {
        jellyfinItemId != nil || url.scheme == "jellyfin" || metadataSource == .server
    }

    /// Determines whether online or offline metadata matching is supported for this track.
    /// Only supported for locally available files or downloaded Jellyfin items.
    public var supportsMetadataLookup: Bool {
        if isJellyfinItem || metadataSource == .server {
            return JellyfinDownloadManager.shared.isDownloaded(trackId: id)
        }
        return url.isFileURL && canReadLocalBytes
    }

    // Original track number
    public let originalTrackNumber: Int?
    // Deluxe track number
    public let deluxeTrackNumber: Int?

    // Normalized title
    public let normalizedTitle: String
    // Normalized artist
    public let normalizedArtist: String
    // Normalized album
    public let normalizedAlbum: String
    // Search tokens
    public let searchTokens: String

    // Initialize with configured properties
    public nonisolated init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        composer: String? = nil,
        performer: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        originalTrackNumber: Int? = nil,
        deluxeTrackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        duration: TimeInterval,
        url: URL,
        artworkKey: String? = nil,
        dateAdded: Date = Date(),
        fileInfo: AudioFileInfo? = nil,
        lyrics: String? = nil,
        isAlternate: Bool? = nil,
        folderID: UUID? = nil,
        relativePath: String? = nil,
        metadataSource: MetadataSource? = nil,
        tagSnapshot: TagSnapshot? = nil,
        jellyfinItemId: String? = nil,
        jellyfinAlbumId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.composer = composer
        self.performer = performer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.originalTrackNumber = originalTrackNumber ?? trackNumber
        self.deluxeTrackNumber = deluxeTrackNumber
        self.totalTracks = totalTracks
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.duration = duration
        self.url = url
        self.artworkKey = artworkKey
        self.dateAdded = dateAdded
        self.fileInfo = fileInfo
        self.lyrics = lyrics
        self.isAlternate = isAlternate
        self.folderID = folderID
        self.relativePath = relativePath
        self.metadataSource = metadataSource
        self.tagSnapshot = tagSnapshot
        self.jellyfinItemId = jellyfinItemId
        self.jellyfinAlbumId = jellyfinAlbumId

        // N title
        let nTitle = FuzzyMatcher.normalize(title)
        // N artist
        let nArtist = FuzzyMatcher.normalize(artist)
        // N album
        let nAlbum = FuzzyMatcher.normalize(album)
        // N genre
        let nGenre = genre.map { FuzzyMatcher.normalize($0) } ?? ""

        self.normalizedTitle = nTitle
        self.normalizedArtist = nArtist
        self.normalizedAlbum = nAlbum
        self.searchTokens = "\(nTitle) \(nArtist) \(nAlbum) \(nGenre)"
    }

    // Initialize with configured properties
    public nonisolated init(from decoder: Decoder) throws {
        // Container
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Title"
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        self.album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        self.albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        self.composer = try container.decodeIfPresent(String.self, forKey: .composer)
        self.performer = try container.decodeIfPresent(String.self, forKey: .performer)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.year = try container.decodeIfPresent(Int.self, forKey: .year)
        self.trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        self.originalTrackNumber = try container.decodeIfPresent(Int.self, forKey: .originalTrackNumber) ?? self.trackNumber
        self.deluxeTrackNumber = try container.decodeIfPresent(Int.self, forKey: .deluxeTrackNumber)
        self.totalTracks = try container.decodeIfPresent(Int.self, forKey: .totalTracks)
        self.discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        self.discTotal = try container.decodeIfPresent(Int.self, forKey: .discTotal)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        // File path location
        if let decodedURL = try? container.decode(URL.self, forKey: .url) {
            self.url = decodedURL
        } else if let urlString = try? container.decode(String.self, forKey: .url) {
            if urlString.hasPrefix("file://") {
                // Local file URL pointing to the audio asset
                if let url = URL(string: urlString) {
                    self.url = url
                } else {
                    // File system location for raw path
                    let rawPath = urlString.replacingOccurrences(of: "file://", with: "")
                    // Unescaped
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
        self.isAlternate = try container.decodeIfPresent(Bool.self, forKey: .isAlternate)
        self.folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        self.relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        self.metadataSource = try container.decodeIfPresent(MetadataSource.self, forKey: .metadataSource)
        self.tagSnapshot = try container.decodeIfPresent(TagSnapshot.self, forKey: .tagSnapshot)
        self.jellyfinItemId = try container.decodeIfPresent(String.self, forKey: .jellyfinItemId)
        self.jellyfinAlbumId = try container.decodeIfPresent(String.self, forKey: .jellyfinAlbumId)

        // Fast-path: deserialize precomputed search tokens if cached, avoiding expensive runtime normalization
        if let nTitle = try container.decodeIfPresent(String.self, forKey: .normalizedTitle),
           let nArtist = try container.decodeIfPresent(String.self, forKey: .normalizedArtist),
           let nAlbum = try container.decodeIfPresent(String.self, forKey: .normalizedAlbum),
           let sTokens = try container.decodeIfPresent(String.self, forKey: .searchTokens) {
            self.normalizedTitle = nTitle
            self.normalizedArtist = nArtist
            self.normalizedAlbum = nAlbum
            self.searchTokens = sTokens
        } else {
            let nTitle = FuzzyMatcher.normalize(self.title)
            let nArtist = FuzzyMatcher.normalize(self.artist)
            let nAlbum = FuzzyMatcher.normalize(self.album)
            let nGenre = self.genre.map { FuzzyMatcher.normalize($0) } ?? ""

            self.normalizedTitle = nTitle
            self.normalizedArtist = nArtist
            self.normalizedAlbum = nAlbum
            self.searchTokens = "\(nTitle) \(nArtist) \(nAlbum) \(nGenre)"
        }
    }

    // Defines CodingKeys cases
    private enum CodingKeys: String, CodingKey {
        // Id option
        case id, title, artist, album, albumArtist, composer, performer, genre, year, trackNumber, originalTrackNumber, deluxeTrackNumber, totalTracks, discNumber, discTotal, duration, url, artworkKey, dateAdded, fileInfo, lyrics, isAlternate, folderID
        case relativePath, metadataSource, tagSnapshot
        case jellyfinItemId, jellyfinAlbumId
        case normalizedTitle, normalizedArtist, normalizedAlbum, searchTokens
    }

    // Encode
    public nonisolated func encode(to encoder: Encoder) throws {
        // Container
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(composer, forKey: .composer)
        try container.encodeIfPresent(performer, forKey: .performer)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(originalTrackNumber, forKey: .originalTrackNumber)
        try container.encodeIfPresent(deluxeTrackNumber, forKey: .deluxeTrackNumber)
        try container.encodeIfPresent(totalTracks, forKey: .totalTracks)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encodeIfPresent(discTotal, forKey: .discTotal)
        try container.encode(duration, forKey: .duration)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encodeIfPresent(fileInfo, forKey: .fileInfo)
        try container.encodeIfPresent(lyrics, forKey: .lyrics)
        try container.encodeIfPresent(isAlternate, forKey: .isAlternate)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encodeIfPresent(relativePath, forKey: .relativePath)
        try container.encodeIfPresent(metadataSource, forKey: .metadataSource)
        try container.encodeIfPresent(tagSnapshot, forKey: .tagSnapshot)
        try container.encodeIfPresent(jellyfinItemId, forKey: .jellyfinItemId)
        try container.encodeIfPresent(jellyfinAlbumId, forKey: .jellyfinAlbumId)
        try container.encode(normalizedTitle, forKey: .normalizedTitle)
        try container.encode(normalizedArtist, forKey: .normalizedArtist)
        try container.encode(normalizedAlbum, forKey: .normalizedAlbum)
        try container.encode(searchTokens, forKey: .searchTokens)
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
            // Fmt
            let fmt = info.fileExtension.uppercased()
            if info.bitRate > 0 {
                // Kbps
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

    /// Returns a copy of the track with an updated artworkKey.
    public nonisolated func withArtworkKey(_ key: String?) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: key,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with an updated artist.
    public func withArtist(_ newArtist: String) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: newArtist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with an updated albumArtist.
    public func withAlbumArtist(_ newAlbumArtist: String?) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: newAlbumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with an updated release year.
    public func withYear(_ newYear: Int?) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: newYear,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with updated user-editable tags.
    public func withUpdatedTags(
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        composer: String?,
        performer: String?,
        genre: String?,
        year: Int?,
        trackNumber: Int?,
        totalTracks: Int?,
        discNumber: Int?,
        discTotal: Int?
    ) -> Track {
        Track(
            id: self.id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            composer: composer,
            performer: performer,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: totalTracks,
            discNumber: discNumber,
            discTotal: discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with updated metadata source and tag snapshot.
    public func withUpdatedTags(
        metadataSource: MetadataSource? = nil,
        tagSnapshot: TagSnapshot? = nil
    ) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: metadataSource ?? self.metadataSource,
            tagSnapshot: tagSnapshot ?? self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with an updated alternate status.
    public func withAlternateStatus(_ isAlternate: Bool?) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track moved to a different album.
    public func withAlbum(_ newAlbum: String, albumArtist: String? = nil, isAlternate: Bool? = nil) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: newAlbum,
            albumArtist: albumArtist ?? self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: isAlternate ?? self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track assigned to a specific folder.
    public func withFolderID(_ newFolderID: UUID?) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: newFolderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with organized metadata (e.g. for METADATA vs FOLDER mode).
    public func withOrganizedMetadata(
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        year: Int?,
        trackNumber: Int?,
        discNumber: Int?
    ) -> Track {
        Track(
            id: self.id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: year,
            trackNumber: trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with updated identity identifiers.
    public func withIdentity(
        id: UUID,
        relativePath: String? = nil,
        folderID: UUID? = nil,
        metadataSource: MetadataSource? = nil,
        tagSnapshot: TagSnapshot? = nil
    ) -> Track {
        Track(
            id: id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: folderID ?? self.folderID,
            relativePath: relativePath ?? self.relativePath,
            metadataSource: metadataSource ?? self.metadataSource,
            tagSnapshot: tagSnapshot ?? self.tagSnapshot,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinAlbumId: self.jellyfinAlbumId
        )
    }

    /// Returns a copy of the track with updated Jellyfin identifiers.
    public func withJellyfinIds(itemId: String?, albumId: String?) -> Track {
        Track(
            id: self.id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            albumArtist: self.albumArtist,
            composer: self.composer,
            performer: self.performer,
            genre: self.genre,
            year: self.year,
            trackNumber: self.trackNumber,
            originalTrackNumber: self.originalTrackNumber,
            deluxeTrackNumber: self.deluxeTrackNumber,
            totalTracks: self.totalTracks,
            discNumber: self.discNumber,
            discTotal: self.discTotal,
            duration: self.duration,
            url: self.url,
            artworkKey: self.artworkKey,
            dateAdded: self.dateAdded,
            fileInfo: self.fileInfo,
            lyrics: self.lyrics,
            isAlternate: self.isAlternate,
            folderID: self.folderID,
            relativePath: self.relativePath,
            metadataSource: self.metadataSource,
            tagSnapshot: self.tagSnapshot,
            jellyfinItemId: itemId ?? self.jellyfinItemId,
            jellyfinAlbumId: albumId ?? self.jellyfinAlbumId
        )
    }

    // MARK: - 7 Core Tag Completeness & Classification

    /// Validates if the title is present and not a generic placeholder.
    public var hasValidTitle: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        if lower == "unknown title" || lower == "untitled" || lower == "—" || lower == "-" { return false }
        if lower.hasPrefix("track ") && lower.count <= 8 { return false }
        return true
    }

    /// Validates if the artist is present and not a generic placeholder.
    public var hasValidArtist: Bool {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return false }
        let lower = a.lowercased()
        if lower == "unknown artist" || lower == "unknown" || lower == "—" || lower == "-" { return false }
        return true
    }

    /// Validates if the album is present and not a generic placeholder.
    public var hasValidAlbum: Bool {
        let al = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if al.isEmpty { return false }
        let lower = al.lowercased()
        if lower == "unknown album" || lower == "unknown" || lower == "—" || lower == "-" { return false }
        return true
    }

    /// Validates if the genre is present and not a generic placeholder.
    public var hasValidGenre: Bool {
        guard let g = genre?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return false }
        let lower = g.lowercased()
        if lower == "unknown genre" || lower == "unknown" || lower == "other" || lower == "—" || lower == "-" { return false }
        return true
    }

    /// Validates if the release year is present and within a valid 4-digit range.
    public var hasValidYear: Bool {
        guard let y = year, y >= 1900, y <= Calendar.current.component(.year, from: Date()) + 2 else { return false }
        return true
    }

    /// Validates if the track number is present and greater than 0.
    public var hasValidTrackNumber: Bool {
        guard let tn = trackNumber, tn > 0 else { return false }
        return true
    }

    /// Validates if artwork is present.
    public var hasValidArtwork: Bool {
        guard let ak = artworkKey?.trimmingCharacters(in: .whitespacesAndNewlines), !ak.isEmpty else { return false }
        return true
    }

    /// Indicates if all 7 core metadata fields (Title, Artist, Album, Genre, Year, TrackNumber, Artwork) are present and valid.
    public nonisolated var isComplete7CoreTags: Bool {
        hasValidTitle &&
        hasValidArtist &&
        hasValidAlbum &&
        hasValidGenre &&
        hasValidYear &&
        hasValidTrackNumber &&
        hasValidArtwork
    }

    /// Lists any missing or invalid tags out of the 7 core fields.
    public var missingCoreTags: [String] {
        var missing: [String] = []
        if !hasValidTitle { missing.append("Title") }
        if !hasValidArtist { missing.append("Artist") }
        if !hasValidAlbum { missing.append("Album") }
        if !hasValidGenre { missing.append("Genre") }
        if !hasValidYear { missing.append("Year") }
        if !hasValidTrackNumber { missing.append("Track #") }
        if !hasValidArtwork { missing.append("Artwork") }
        return missing
    }

    /// The tag completeness status for scanning ("Looks Good" vs "Ready to Enrich").
    public var tagCompletenessStatus: TagCompletenessStatus {
        isComplete7CoreTags ? .looksGood : .readyToEnrich
    }
}

/// Category classification for local track metadata completeness.
public enum TagCompletenessStatus: String, Sendable, Codable {
    case looksGood = "Looks Good"
    case readyToEnrich = "Ready to Enrich"
}

extension Notification.Name {
    public static let hideTrackRequested = Notification.Name("MusicPlayer.hideTrackRequested")
}

