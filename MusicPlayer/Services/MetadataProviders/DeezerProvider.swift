import Foundation

/// Fast Deezer REST API provider with strict rate limiting (max 10 req/s, burst 50/5s),
/// authoritative track duration matching, ISRC codes, and cover_xl artwork.
public final class DeezerProvider: MetadataProvider, @unchecked Sendable {
    public let source: MetadataAPIOption = .deezer
    private let urlSession: URLSession
    private let rateLimiter: TokenBucketRateLimiter

    public init(
        urlSession: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter = TokenBucketRateLimiter(capacity: 50.0, refillRatePerSecond: 10.0)
    ) {
        self.urlSession = urlSession
        self.rateLimiter = rateLimiter
    }

    public func searchArtist(name: String) async throws -> OnlineArtistCandidate? {
        await rateLimiter.acquire()

        let clean = MetadataSanitizer.cleanArtistSearchTerm(name)
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=5") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(DeezerArtistSearchResponse.self, from: data)
        guard let match = decoded.data.first(where: {
            FuzzyMatcher.score(text: $0.name, query: clean) >= 60 ||
                $0.name.localizedCaseInsensitiveContains(clean) ||
                clean.localizedCaseInsensitiveContains($0.name)
        }) ?? decoded.data.first else {
            return nil
        }

        return OnlineArtistCandidate(
            id: String(match.id),
            name: match.name,
            source: .deezer
        )
    }

    public func fetchDiscography(artistId: String, artistName: String) async throws -> [OnlineReleaseCandidate] {
        await rateLimiter.acquire()

        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/albums?limit=100") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(DeezerArtistAlbumsResponse.self, from: data)
        var releases: [OnlineReleaseCandidate] = []

        for item in decoded.data {
            let lower = item.title.lowercased()
            if lower.contains("karaoke") || lower.contains("tribute to") || lower.contains("ringtone") {
                continue
            }

            let releaseYear = item.release_date.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let artwork = (item.cover_xl ?? item.cover_big ?? item.cover_medium).flatMap { URL(string: $0) }
            let isSingle = item.record_type?.lowercased() == "single" || item.record_type?.lowercased() == "ep" ||
                lower.hasSuffix(" - single") || lower.hasSuffix(" (single)") || (item.nb_tracks != nil && item.nb_tracks! <= 3)

            releases.append(OnlineReleaseCandidate(
                id: String(item.id),
                title: item.title,
                artist: artistName,
                releaseYear: releaseYear,
                releaseDate: nil,
                genre: item.genre_id != nil ? "Genre \(item.genre_id!)" : nil,
                totalTracks: item.nb_tracks,
                artworkURL: artwork,
                isSingleOrEP: isSingle,
                source: .deezer
            ))
        }

        return releases
    }

    public func fetchReleaseTracks(releaseId: String) async throws -> [OnlineTrackCandidate] {
        await rateLimiter.acquire()

        guard let url = URL(string: "https://api.deezer.com/album/\(releaseId)/tracks?limit=100") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(DeezerAlbumTracksResponse.self, from: data)
        var tracks: [OnlineTrackCandidate] = []

        for item in decoded.data {
            let dur = item.duration.map { TimeInterval($0) }
            tracks.append(OnlineTrackCandidate(
                id: String(item.id),
                title: item.title,
                artist: item.artist?.name ?? "",
                album: "",
                albumArtist: item.artist?.name,
                trackNumber: item.track_position,
                discNumber: item.disk_number ?? 1,
                duration: dur,
                isrc: item.isrc,
                releaseYear: nil,
                genre: nil,
                artworkURL: nil,
                source: .deezer
            ))
        }

        return tracks
    }
}

// MARK: - Codable Helpers

private struct DeezerArtistSearchResponse: Codable, Sendable {
    let data: [DeezerArtistItem]
}

private struct DeezerArtistItem: Codable, Sendable {
    let id: Int64
    let name: String
}

private struct DeezerArtistAlbumsResponse: Codable, Sendable {
    let data: [DeezerAlbumItem]
}

private struct DeezerAlbumItem: Codable, Sendable {
    let id: Int64
    let title: String
    let cover_xl: String?
    let cover_big: String?
    let cover_medium: String?
    let genre_id: Int?
    let nb_tracks: Int?
    let record_type: String?
    let release_date: String?
}

private struct DeezerAlbumTracksResponse: Codable, Sendable {
    let data: [DeezerTrackItem]
}

private struct DeezerTrackItem: Codable, Sendable {
    let id: Int64
    let title: String
    let duration: Int?
    let track_position: Int?
    let disk_number: Int?
    let isrc: String?
    let artist: DeezerTrackArtistItem?
}

private struct DeezerTrackArtistItem: Codable, Sendable {
    let id: Int64?
    let name: String?
}
