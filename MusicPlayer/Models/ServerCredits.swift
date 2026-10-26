import Foundation

/// Artist credits and quality facts for a media-server track, stored exactly as the server reports them.
/// The library mirrors the server's own organization from these values; no client-side name splitting is applied.
nonisolated public struct ServerCredits: Codable, Sendable, Hashable {
    /// Album artists as the server lists them for the track's album (order preserved).
    public let albumArtists: [String]
    /// Track artists as the server lists them.
    public let artists: [String]
    /// True when `artists` are separate server artist entities (Jellyfin ArtistItems, OpenSubsonic `artists[]`),
    /// which is what makes an "Appears on" entry. False for display strings (Plex, legacy Subsonic).
    public let artistsAreEntities: Bool
    /// Bits per sample when the server reports it; used to rank duplicate copies.
    public let bitDepth: Int?
    /// Server artwork version (Jellyfin primary image tag, Subsonic cover-art id, Plex thumb path).
    public let imageVersion: String?
    /// Server artist ids parallel to `albumArtists` (OpenSubsonic `albumArtists[].id`, Jellyfin `AlbumArtists[].Id`,
    /// Plex `grandparentRatingKey`); an empty string marks an entry the server sent without an id.
    /// Optional so credits stored before ids were kept still decode (nil = unknown).
    public let albumArtistIDs: [String]?
    /// Server artist ids parallel to `artists`; nil when the server sent none.
    public let artistIDs: [String]?
    /// Credits format version; older stored credits decode as nil and are refreshed by one full sync.
    public let version: Int?

    /// Bump when the stored credits gain information that existing tracks need a full re-sync to pick up.
    public static let currentVersion = 2

    public init(albumArtists: [String], artists: [String], artistsAreEntities: Bool, bitDepth: Int?, imageVersion: String?,
                albumArtistIDs: [String?]? = nil, artistIDs: [String?]? = nil) {
        let albums = ServerCredits.cleaned(albumArtists, ids: albumArtistIDs)
        let tracks = ServerCredits.cleaned(artists, ids: artistIDs)
        self.albumArtists = albums.names
        self.artists = tracks.names
        self.artistsAreEntities = artistsAreEntities
        self.bitDepth = bitDepth
        self.imageVersion = imageVersion
        self.albumArtistIDs = albums.ids
        self.artistIDs = tracks.ids
        self.version = ServerCredits.currentVersion
    }

    /// True when these credits predate the current format and need one full sync.
    public var isOutdated: Bool { (version ?? 1) < ServerCredits.currentVersion }

    /// (server id, name) pairs for the album artists; id is nil when the server sent none.
    public var albumArtistRefs: [(id: String?, name: String)] { ServerCredits.refs(albumArtists, albumArtistIDs) }
    /// (server id, name) pairs for the track artists; id is nil when the server sent none.
    public var artistRefs: [(id: String?, name: String)] { ServerCredits.refs(artists, artistIDs) }

    private static func refs(_ names: [String], _ ids: [String]?) -> [(id: String?, name: String)] {
        names.enumerated().map { index, name in
            let id = (ids != nil && index < ids!.count && !ids![index].isEmpty) ? ids![index] : nil
            return (id: id, name: name)
        }
    }

    /// Strict name identity used to match the same artist/album across sources:
    /// case, diacritics, width and whitespace runs are folded; punctuation and wording are kept.
    public static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Trims, drops empties and de-duplicates (by id when present, else by name key), keeping ids aligned with names.
    private static func cleaned(_ names: [String], ids: [String?]?) -> (names: [String], ids: [String]?) {
        var seen = Set<String>()
        var result: [String] = []
        var resultIDs: [String] = []
        var anyID = false
        for (index, raw) in names.enumerated() {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (ids.flatMap { index < $0.count ? $0[index] : nil } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(id.isEmpty ? "n:" + nameKey(name) : "i:" + id).inserted else { continue }
            result.append(name)
            resultIDs.append(id)
            if !id.isEmpty { anyID = true }
        }
        return (result, anyID ? resultIDs : nil)
    }
}

nonisolated extension Track {
    /// True when the user's manual edit changed the album artist away from the server value.
    var hasEditedServerAlbumArtist: Bool {
        guard let snapshot = tagSnapshot else { return false }
        return (snapshot.albumArtist ?? "") != (albumArtist ?? "")
    }

    /// True when the user's manual edit changed the track artist away from the server value.
    var hasEditedServerArtist: Bool {
        guard let snapshot = tagSnapshot else { return false }
        return snapshot.artist != artist
    }

    /// Album artists for a server track: the server's credits, or the user's edited album artist verbatim.
    var serverAlbumArtistNames: [String] {
        if !hasEditedServerAlbumArtist, let credits = serverCredits, !credits.albumArtists.isEmpty {
            return credits.albumArtists
        }
        if let albumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !albumArtist.isEmpty {
            return [albumArtist]
        }
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedArtist.isEmpty ? [] : [trimmedArtist]
    }

    /// Album artists as (server id, name); ids are dropped when the user edited the album artist.
    var serverAlbumArtistRefs: [(id: String?, name: String)] {
        if !hasEditedServerAlbumArtist, let credits = serverCredits, !credits.albumArtists.isEmpty {
            return credits.albumArtistRefs
        }
        return serverAlbumArtistNames.map { (id: nil, name: $0) }
    }

    /// Track-artist entities as (server id, name); empty unless the server sent separate entities.
    var serverArtistEntityRefs: [(id: String?, name: String)] {
        guard !hasEditedServerArtist, let credits = serverCredits, credits.artistsAreEntities else { return [] }
        return credits.artistRefs
    }

    /// Track-artist entities credited by the server (only these create "Appears on" entries).
    var serverArtistEntityNames: [String] {
        guard !hasEditedServerArtist, let credits = serverCredits, credits.artistsAreEntities else { return [] }
        return credits.artists
    }
}
