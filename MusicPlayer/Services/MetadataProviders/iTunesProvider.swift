import Foundation

/// Fast Apple Music / iTunes provider delivering mainstream discography metadata
/// and high-resolution 1400x1400 artwork.
public final class iTunesProvider: MetadataProvider, @unchecked Sendable {
    public let source: MetadataAPIOption = .itunes
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func searchArtist(name: String) async throws -> OnlineArtistCandidate? {
        let clean = MetadataSanitizer.cleanArtistSearchTerm(name)
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=musicArtist&limit=5") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(ITunesArtistSearchResponse.self, from: data)
        guard let first = decoded.results.first(where: {
            guard let artistName = $0.artistName else { return false }
            return FuzzyMatcher.score(text: artistName, query: clean) >= 60 ||
                artistName.localizedCaseInsensitiveContains(clean) ||
                clean.localizedCaseInsensitiveContains(artistName)
        }) ?? decoded.results.first, let artistId = first.artistId else {
            return nil
        }

        return OnlineArtistCandidate(
            id: String(artistId),
            name: first.artistName ?? clean,
            source: .itunes
        )
    }

    public func fetchDiscography(artistId: String, artistName: String) async throws -> [OnlineReleaseCandidate] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=200") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(ITunesLookupResponse.self, from: data)
        var releases: [OnlineReleaseCandidate] = []

        for item in decoded.results {
            guard item.wrapperType == "collection",
                  let colId = item.collectionId,
                  let colName = item.collectionName,
                  !colName.isEmpty else {
                continue
            }

            // Exclude obvious karaoke/tribute junk
            let lower = colName.lowercased()
            if lower.contains("karaoke") || lower.contains("tribute to") || lower.contains("ringtone") {
                continue
            }

            let releaseYear = item.releaseDate.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let parsedDate: Date? = {
                guard let dStr = item.releaseDate else { return nil }
                let isoFormatter = ISO8601DateFormatter()
                return isoFormatter.date(from: dStr)
            }()

            let highResArtwork = item.artworkUrl100.flatMap { Self.makeHighResArtworkURL(from: $0) }
            let isSingleOrEP = item.trackCount.map { $0 <= 3 } ?? (lower.contains("single") || lower.contains(" - ep"))

            releases.append(OnlineReleaseCandidate(
                id: String(colId),
                title: colName,
                artist: item.artistName ?? artistName,
                releaseYear: releaseYear,
                releaseDate: parsedDate,
                genre: item.primaryGenreName,
                totalTracks: item.trackCount,
                artworkURL: highResArtwork,
                isSingleOrEP: isSingleOrEP,
                source: .itunes
            ))
        }

        return releases
    }

    public func fetchReleaseTracks(releaseId: String) async throws -> [OnlineTrackCandidate] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(releaseId)&entity=song&limit=200") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(ITunesTrackLookupResponse.self, from: data)
        var tracks: [OnlineTrackCandidate] = []

        for item in decoded.results {
            guard item.wrapperType == "track",
                  let trackId = item.trackId,
                  let trackName = item.trackName else {
                continue
            }

            let durSec = item.trackTimeMillis.map { Double($0) / 1000.0 }
            let releaseYear = item.releaseDate.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let artworkURL = item.artworkUrl100.flatMap { Self.makeHighResArtworkURL(from: $0) }

            tracks.append(OnlineTrackCandidate(
                id: String(trackId),
                title: trackName,
                artist: item.artistName ?? "",
                album: item.collectionName ?? "",
                albumArtist: item.collectionArtistName ?? item.artistName,
                trackNumber: item.trackNumber,
                discNumber: item.discNumber,
                duration: durSec,
                isrc: item.isrc,
                releaseYear: releaseYear,
                genre: item.primaryGenreName,
                artworkURL: artworkURL,
                source: .itunes
            ))
        }

        return tracks
    }

    /// Rewrites thumbnail dimensions to pristine 1400x1400bb.jpg
    public static func makeHighResArtworkURL(from rawString: String) -> URL? {
        guard !rawString.isEmpty else { return nil }
        var updated = rawString
        let patterns = [
            #"/\d+x\d+bb\.(?:jpg|png|jpeg)"#,
            #"/\d+x\d+\.(?:jpg|png|jpeg)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: updated.utf16.count)
                updated = regex.stringByReplacingMatches(in: updated, options: [], range: range, withTemplate: "/1400x1400bb.jpg")
            }
        }
        return URL(string: updated)
    }
}

// MARK: - Codable Helpers

private struct ITunesArtistSearchResponse: Codable, Sendable {
    let resultCount: Int?
    let results: [ITunesArtistResult]
}

private struct ITunesArtistResult: Codable, Sendable {
    let artistId: Int64?
    let artistName: String?
    let primaryGenreName: String?
}

private struct ITunesLookupResponse: Codable, Sendable {
    let resultCount: Int?
    let results: [ITunesLookupItem]
}

private struct ITunesLookupItem: Codable, Sendable {
    let wrapperType: String?
    let collectionId: Int64?
    let collectionName: String?
    let artistName: String?
    let primaryGenreName: String?
    let releaseDate: String?
    let trackCount: Int?
    let artworkUrl100: String?
}

private struct ITunesTrackLookupResponse: Codable, Sendable {
    let resultCount: Int?
    let results: [ITunesTrackLookupItem]
}

private struct ITunesTrackLookupItem: Codable, Sendable {
    let wrapperType: String?
    let trackId: Int64?
    let trackName: String?
    let collectionName: String?
    let artistName: String?
    let collectionArtistName: String?
    let trackNumber: Int?
    let discNumber: Int?
    let trackTimeMillis: Int64?
    let releaseDate: String?
    let primaryGenreName: String?
    let artworkUrl100: String?
    let isrc: String?
}
