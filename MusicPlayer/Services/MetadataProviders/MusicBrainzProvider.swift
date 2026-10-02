import Foundation

/// MusicBrainz metadata provider enforcing strict 1 req/sec rate limiting via AsyncSemaphore.
/// Serves as the authoritative source for discography structure, multi-disc configurations,
/// canonical release dates, and disambiguation.
public final class MusicBrainzProvider: MetadataProvider, @unchecked Sendable {
    public let source: MetadataAPIOption = .musicBrainz
    private let urlSession: URLSession
    private let semaphore: AsyncSemaphore
    private let userAgent: String

    public init(
        urlSession: URLSession = .shared,
        semaphore: AsyncSemaphore = AsyncSemaphore(minInterval: 1.0),
        userAgent: String = "MusicPlayer/1.0 (support@example.com)"
    ) {
        self.urlSession = urlSession
        self.semaphore = semaphore
        self.userAgent = userAgent
    }

    public func searchArtist(name: String) async throws -> OnlineArtistCandidate? {
        await semaphore.wait()

        let clean = MetadataSanitizer.cleanArtistSearchTerm(name)
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=artist:\(encoded)&limit=5&fmt=json") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10.0

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(MusicBrainzArtistQueryResponse.self, from: data)
        guard let match = decoded.artists.first(where: {
            FuzzyMatcher.score(text: $0.name, query: clean) >= 60 ||
                $0.name.localizedCaseInsensitiveContains(clean) ||
                clean.localizedCaseInsensitiveContains($0.name)
        }) ?? decoded.artists.first else {
            return nil
        }

        return OnlineArtistCandidate(
            id: match.id,
            name: match.name,
            source: .musicBrainz
        )
    }

    public func fetchDiscography(artistId: String, artistName: String) async throws -> [OnlineReleaseCandidate] {
        await semaphore.wait()

        guard let url = URL(string: "https://musicbrainz.org/ws/2/release-group?artist=\(artistId)&type=album|single|ep&limit=100&fmt=json") else {
            return []
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10.0

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(MusicBrainzReleaseGroupResponse.self, from: data)
        var releases: [OnlineReleaseCandidate] = []

        for rg in decoded.releaseGroups {
            let year = rg.firstReleaseDate.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let isSingle = rg.primaryType?.lowercased() == "single" || rg.primaryType?.lowercased() == "ep"
            let coverURL = URL(string: "https://coverartarchive.org/release-group/\(rg.id)/front")

            releases.append(OnlineReleaseCandidate(
                id: rg.id,
                title: rg.title,
                artist: artistName,
                releaseYear: year,
                releaseDate: nil,
                genre: rg.tags?.first?.name?.capitalized,
                totalTracks: nil,
                artworkURL: coverURL,
                isSingleOrEP: isSingle,
                source: .musicBrainz
            ))
        }

        return releases
    }

    public func fetchReleaseTracks(releaseId: String) async throws -> [OnlineTrackCandidate] {
        await semaphore.wait()

        // Query official release belonging to this release-group with media and recordings
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(releaseId)&inc=recordings+artist-credits+media&limit=1&fmt=json") else {
            return []
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10.0

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(MusicBrainzReleasesResponse.self, from: data)
        guard let release = decoded.releases.first else { return [] }

        var tracks: [OnlineTrackCandidate] = []
        let releaseYear = release.date.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
        let coverURL = URL(string: "https://coverartarchive.org/release/\(release.id)/front")

        for (mediaIdx, media) in (release.media ?? []).enumerated() {
            let discNum = media.position ?? (mediaIdx + 1)
            for track in (media.tracks ?? []) {
                let dur = track.length.map { Double($0) / 1000.0 }
                let artist = track.recording?.artistCredit?.first?.name ?? release.artistCredit?.first?.name ?? ""

                tracks.append(OnlineTrackCandidate(
                    id: track.id,
                    title: track.title,
                    artist: artist,
                    album: release.title,
                    albumArtist: release.artistCredit?.first?.name,
                    trackNumber: track.position,
                    discNumber: discNum,
                    duration: dur,
                    isrc: nil,
                    releaseYear: releaseYear,
                    genre: nil,
                    artworkURL: coverURL,
                    source: .musicBrainz
                ))
            }
        }

        return tracks
    }
}

// MARK: - Codable Helpers

private struct MusicBrainzArtistQueryResponse: Codable, Sendable {
    let artists: [MusicBrainzArtistResult]
}

private struct MusicBrainzArtistResult: Codable, Sendable {
    let id: String
    let name: String
}

private struct MusicBrainzReleaseGroupResponse: Codable, Sendable {
    let releaseGroups: [MusicBrainzReleaseGroupItem]

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

private struct MusicBrainzReleaseGroupItem: Codable, Sendable {
    let id: String
    let title: String
    let primaryType: String?
    let firstReleaseDate: String?
    let tags: [MusicBrainzTagItem]?

    enum CodingKeys: String, CodingKey {
        case id, title
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
        case tags
    }
}

private struct MusicBrainzTagItem: Codable, Sendable {
    let name: String?
}

private struct MusicBrainzReleasesResponse: Codable, Sendable {
    let releases: [MusicBrainzReleaseDetail]
}

private struct MusicBrainzReleaseDetail: Codable, Sendable {
    let id: String
    let title: String
    let date: String?
    let artistCredit: [MusicBrainzArtistCredit]?
    let media: [MusicBrainzMediaItem]?

    enum CodingKeys: String, CodingKey {
        case id, title, date
        case artistCredit = "artist-credit"
        case media
    }
}

private struct MusicBrainzMediaItem: Codable, Sendable {
    let position: Int?
    let tracks: [MusicBrainzMediaTrack]?
}

private struct MusicBrainzMediaTrack: Codable, Sendable {
    let id: String
    let position: Int?
    let title: String
    let length: Int?
    let recording: MusicBrainzRecordingSnippet?
}

private struct MusicBrainzRecordingSnippet: Codable, Sendable {
    let id: String?
    let artistCredit: [MusicBrainzArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id
        case artistCredit = "artist-credit"
    }
}

private struct MusicBrainzArtistCredit: Codable, Sendable {
    let name: String?
}
