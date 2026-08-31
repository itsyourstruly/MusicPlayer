import Foundation
import os

/// High-speed multi-source metadata service actor integrating Deezer REST API and Apple Music / iTunes Search API.
/// Employs a multi-tier search strategy: high-throughput Deezer search (50 req/5s limit) with Apple Music fallback,
/// high-resolution artwork fetching (1000x1000 Deezer cover_xl and 1400x1400bb Apple Music),
/// and actor-isolated query deduplication caching.
public actor MusicMetadataService {
    public static let shared = MusicMetadataService()

    // URL Sessions
    private let urlSession: URLSession
    private let artworkURLSession: URLSession

    // MARK: - In-Memory Query & Exact Match Caches
    private var queryCache: [String: [OnlineTrackMetadata]] = [:]
    private var queryAlbumCache: [String: [OnlineAlbumItem]] = [:]
    private var exactMatchCache: [String: OnlineTrackMetadata] = [:]

    // Serialized FIFO Rate Limiter for iTunes API calls: 3.0s interval (strictly 1 request every 3 seconds to stay under limits)
    private var nextAvailableITunesRequestTime: Date = Date()
    private var minITunesRequestInterval: TimeInterval = 3.0
    private var consecutiveITunesSuccessCount: Int = 0
    private var iTunesCooldownUntil: Date = .distantPast

    /// Checks if iTunes API is currently cooling down after hitting HTTP 429/403 rate limits.
    public var isITunesCoolingDown: Bool {
        Date() < iTunesCooldownUntil
    }

    /// Remaining seconds of iTunes rate limit cooldown.
    public var iTunesCooldownRemainingSeconds: TimeInterval {
        max(0, iTunesCooldownUntil.timeIntervalSince(Date()))
    }

    // Initialize with configured properties
    private init() {
        // Core API URLSession Configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.httpMaximumConnectionsPerHost = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .returnCacheDataElseLoad

        // Allocate memory and disk cache for network caching
        let memoryCapacity = 50 * 1024 * 1024 // 50 MB
        let diskCapacity = 250 * 1024 * 1024  // 250 MB
        config.urlCache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity)
        self.urlSession = URLSession(configuration: config)

        // Artwork URLSession Configuration
        let artConfig = URLSessionConfiguration.default
        artConfig.timeoutIntervalForRequest = 6.0
        artConfig.timeoutIntervalForResource = 10.0
        artConfig.httpMaximumConnectionsPerHost = 12
        artConfig.waitsForConnectivity = false
        artConfig.requestCachePolicy = .returnCacheDataElseLoad

        let artMemory = 80 * 1024 * 1024 // 80 MB
        let artDisk = 400 * 1024 * 1024  // 400 MB
        artConfig.urlCache = URLCache(memoryCapacity: artMemory, diskCapacity: artDisk)
        self.artworkURLSession = URLSession(configuration: artConfig)
    }

    /// Clears all in-memory caches and resets rate limiter state.
    public func clearCache() {
        queryCache.removeAll(keepingCapacity: false)
        queryAlbumCache.removeAll(keepingCapacity: false)
        exactMatchCache.removeAll(keepingCapacity: false)
        consecutiveITunesSuccessCount = 0
        minITunesRequestInterval = 3.0
        nextAvailableITunesRequestTime = Date()
        iTunesCooldownUntil = .distantPast
        AppLogger.metadata.info("[Cache] Cleared in-memory metadata query cache.")
    }

    /// Queries Deezer, Apple Music, and MusicBrainz for songs by an artist using exact artist matching.
    public func searchArtistSongs(artist: String, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata]? {
        let cleanArtist = MetadataSanitizer.cleanArtistSearchTerm(artist)
        guard !cleanArtist.isEmpty && !MetadataSanitizer.isUnknownArtist(cleanArtist) else { return [] }

        let cacheKey = "artist_songs__\(source.rawValue)__\(cleanArtist.lowercased())"
        if let cached = queryCache[cacheKey] {
            AppLogger.metadata.debug("[Query Cache Hit] Artist query (\(source.rawValue)): \(cleanArtist)")
            return cached
        }

        AppLogger.metadata.info("[Stage 1 Artist Search] Fetching exact catalog for \"\(cleanArtist)\" via [\(source.rawValue)]...")

        var combinedResults: [OnlineTrackMetadata] = []

        switch source {
        case .deezer:
            if let results = await searchDeezerArtistSongs(artist: cleanArtist, limit: 100) {
                combinedResults = results
            }
        case .itunes:
            if self.isITunesCoolingDown {
                AppLogger.metadata.info("[iTunes Rate Limited] Falling back to Deezer for artist \"\(cleanArtist)\" (cooldown: \(String(format: "%.1f", self.iTunesCooldownRemainingSeconds))s remaining)")
                if let results = await searchDeezerArtistSongs(artist: cleanArtist, limit: 100) {
                    combinedResults = results
                }
            } else if let results = await searchITunesArtistSongs(artist: cleanArtist, limit: 200) {
                combinedResults = results
            } else if let results = await searchDeezerArtistSongs(artist: cleanArtist, limit: 100) {
                combinedResults = results
            }
        case .musicBrainz:
            if let results = await searchMusicBrainzArtistSongs(artist: cleanArtist, limit: 50) {
                combinedResults = results
            }
        case .all:
            if isITunesCoolingDown {
                // iTunes in cooldown: route immediately to Deezer without delay
                if let results = await searchDeezerArtistSongs(artist: cleanArtist, limit: 100) {
                    combinedResults = results
                }
            } else {
                async let deezerTask = searchDeezerArtistSongs(artist: cleanArtist, limit: 100)
                async let itunesTask = searchITunesArtistSongs(artist: cleanArtist, limit: 200)

                let deezerResults = (await deezerTask) ?? []
                let itunesResults = (await itunesTask) ?? []

                combinedResults.append(contentsOf: itunesResults)
                combinedResults.append(contentsOf: deezerResults)
            }

            if combinedResults.isEmpty {
                if let mbResults = await searchMusicBrainzArtistSongs(artist: cleanArtist, limit: 50) {
                    combinedResults.append(contentsOf: mbResults)
                }
            }
        }

        guard !combinedResults.isEmpty else {
            return nil
        }

        queryCache[cacheKey] = combinedResults
        return combinedResults
    }

    // MARK: - Stage 2: Album-Level Song Catalog Query (Multi-Source)

    /// Queries online sources for all tracks belonging to an album.
    public func searchAlbumSongs(album: String, artist: String, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata]? {
        let cleanAlbum = MetadataSanitizer.cleanSearchTerm(album)
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        guard !cleanAlbum.isEmpty && !MetadataSanitizer.isUnknownAlbum(cleanAlbum) else { return [] }

        var query = cleanAlbum
        if !cleanArtist.isEmpty && !MetadataSanitizer.isUnknownArtist(cleanArtist) {
            query += " \(cleanArtist)"
        }

        let cacheKey = "album_songs__\(source.rawValue)__\(query.lowercased())"
        if let cached = queryCache[cacheKey] {
            AppLogger.metadata.debug("[Query Cache Hit] Album query (\(source.rawValue)): \(query)")
            return cached
        }

        AppLogger.metadata.info("[Stage 2 Album Search] Fetching album cuts for \"\(cleanAlbum)\" by \"\(cleanArtist)\" via [\(source.rawValue)]...")

        switch source {
        case .deezer:
            if let results = await searchDeezerAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 100), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .itunes:
            if self.isITunesCoolingDown {
                AppLogger.metadata.info("[iTunes Rate Limited] Falling back to Deezer for album \"\(cleanAlbum)\" (cooldown: \(String(format: "%.1f", self.iTunesCooldownRemainingSeconds))s remaining)")
                if let results = await searchDeezerAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 100), !results.isEmpty {
                    queryCache[cacheKey] = results
                    return results
                }
            } else if let results = await searchITunesAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 200), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            } else if let results = await searchDeezerAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 100), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .musicBrainz:
            if let results = await searchMusicBrainzAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 50), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .all:
            if isITunesCoolingDown {
                if let deezerResults = await searchDeezerAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 100), !deezerResults.isEmpty {
                    queryCache[cacheKey] = deezerResults
                    return deezerResults
                }
            } else {
                async let deezerTask = searchDeezerAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 100)
                async let itunesTask = searchITunesAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 200)

                let deezerResults = (await deezerTask) ?? []
                let itunesResults = (await itunesTask) ?? []

                var combined: [OnlineTrackMetadata] = []
                combined.append(contentsOf: itunesResults)
                combined.append(contentsOf: deezerResults)

                if !combined.isEmpty {
                    queryCache[cacheKey] = combined
                    return combined
                }
            }

            if let mbResults = await searchMusicBrainzAlbumSongs(album: cleanAlbum, artist: cleanArtist, limit: 50), !mbResults.isEmpty {
                queryCache[cacheKey] = mbResults
                return mbResults
            }
        }

        return nil
    }

    // MARK: - Stage 3: Targeted Song Fallback Query (Multi-Source)

    /// Executes a targeted fallback query using cleaned track and artist keywords.
    public func searchTargetedSong(title: String, artist: String, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata]? {
        let cleanTitle = MetadataSanitizer.cleanSearchTerm(title)
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        guard !cleanTitle.isEmpty else { return [] }

        var query = cleanTitle
        if !cleanArtist.isEmpty && !MetadataSanitizer.isUnknownArtist(cleanArtist) {
            query += " \(cleanArtist)"
        }

        let cacheKey = "targeted_song__\(source.rawValue)__\(query.lowercased())"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        AppLogger.metadata.info("[Stage 3 Targeted Search] Query: \"\(query)\" via [\(source.rawValue)]...")

        switch source {
        case .deezer:
            if let results = await searchDeezerTargetedSong(title: cleanTitle, artist: cleanArtist), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .itunes:
            if self.isITunesCoolingDown {
                AppLogger.metadata.info("[iTunes Rate Limited] Falling back to Deezer for track \"\(cleanTitle)\" (cooldown: \(String(format: "%.1f", self.iTunesCooldownRemainingSeconds))s remaining)")
                if let results = await searchDeezerTargetedSong(title: cleanTitle, artist: cleanArtist), !results.isEmpty {
                    queryCache[cacheKey] = results
                    return results
                }
            } else if let results = await executeITunesSearchQuery(query: query, limit: 25), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            } else if let results = await searchDeezerTargetedSong(title: cleanTitle, artist: cleanArtist), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .musicBrainz:
            if let results = await searchMusicBrainzTargetedSong(title: cleanTitle, artist: cleanArtist), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .all:
            if isITunesCoolingDown {
                if let deezerResults = await searchDeezerTargetedSong(title: cleanTitle, artist: cleanArtist), !deezerResults.isEmpty {
                    queryCache[cacheKey] = deezerResults
                    return deezerResults
                }
            } else {
                let currentQuery = query
                async let deezerTask = searchDeezerTargetedSong(title: cleanTitle, artist: cleanArtist)
                async let itunesTask = executeITunesSearchQuery(query: currentQuery, limit: 25)

                let deezerResults = (await deezerTask) ?? []
                let itunesResults = (await itunesTask) ?? []

                var allResults: [OnlineTrackMetadata] = []
                allResults.append(contentsOf: itunesResults)
                allResults.append(contentsOf: deezerResults)

                if !allResults.isEmpty {
                    queryCache[cacheKey] = allResults
                    return allResults
                }
            }

            if let mbResults = await searchMusicBrainzTargetedSong(title: cleanTitle, artist: cleanArtist), !mbResults.isEmpty {
                queryCache[cacheKey] = mbResults
                return mbResults
            }
        }

        return nil
    }

    /// Secondary fallback querying purely by title when artist search fails.
    public func searchTargetedSong(title: String, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata]? {
        let cleanTitle = MetadataSanitizer.cleanSearchTerm(title)
        guard !cleanTitle.isEmpty else { return [] }

        let cacheKey = "targeted_title__\(source.rawValue)__\(cleanTitle.lowercased())"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        AppLogger.metadata.info("[Stage 3 Title Fallback] Query: \"\(cleanTitle)\" via [\(source.rawValue)]...")

        switch source {
        case .deezer:
            if let results = await searchDeezer(query: cleanTitle, limit: 15), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .itunes:
            if isITunesCoolingDown {
                if let results = await searchDeezer(query: cleanTitle, limit: 15), !results.isEmpty {
                    queryCache[cacheKey] = results
                    return results
                }
            } else if let results = await executeITunesSearchQuery(query: cleanTitle, limit: 15), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            } else if let results = await searchDeezer(query: cleanTitle, limit: 15), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .musicBrainz:
            if let results = await searchMusicBrainz(query: cleanTitle, limit: 15), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .all:
            if isITunesCoolingDown {
                if let results = await searchDeezer(query: cleanTitle, limit: 15), !results.isEmpty {
                    queryCache[cacheKey] = results
                    return results
                }
            } else {
                async let deezerTask = searchDeezer(query: cleanTitle, limit: 15)
                async let itunesTask = executeITunesSearchQuery(query: cleanTitle, limit: 15)

                let deezerResults = (await deezerTask) ?? []
                let itunesResults = (await itunesTask) ?? []

                var allResults: [OnlineTrackMetadata] = []
                allResults.append(contentsOf: itunesResults)
                allResults.append(contentsOf: deezerResults)

                if !allResults.isEmpty {
                    queryCache[cacheKey] = allResults
                    return allResults
                }
            }

            if let mbResults = await searchMusicBrainz(query: cleanTitle, limit: 15), !mbResults.isEmpty {
                queryCache[cacheKey] = mbResults
                return mbResults
            }
        }

        return nil
    }

    public func searchTargetedSong(query: String, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata]? {
        let cleanQuery = MetadataSanitizer.cleanSearchTerm(query)
        guard !cleanQuery.isEmpty else { return [] }

        let cacheKey = "targeted_query__\(source.rawValue)__\(cleanQuery.lowercased())"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        switch source {
        case .deezer:
            if let results = await searchDeezer(query: cleanQuery, limit: 25), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .itunes:
            if let results = await executeITunesSearchQuery(query: cleanQuery, limit: 25), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .musicBrainz:
            if let results = await searchMusicBrainz(query: cleanQuery, limit: 25), !results.isEmpty {
                queryCache[cacheKey] = results
                return results
            }
        case .all:
            async let deezerTask = searchDeezer(query: cleanQuery, limit: 20)
            async let itunesTask = executeITunesSearchQuery(query: cleanQuery, limit: 20)

            let deezerResults = (await deezerTask) ?? []
            let itunesResults = (await itunesTask) ?? []

            var allResults: [OnlineTrackMetadata] = []
            allResults.append(contentsOf: itunesResults)
            allResults.append(contentsOf: deezerResults)

            if allResults.isEmpty {
                if let mbResults = await searchMusicBrainz(query: cleanQuery, limit: 15), !mbResults.isEmpty {
                    allResults.append(contentsOf: mbResults)
                }
            }

            if !allResults.isEmpty {
                queryCache[cacheKey] = allResults
                return allResults
            }
        }

        return nil
    }

    // MARK: - Dedicated Online Album Search & Cuts Retrieval

    /// Searches for online albums matching an artist and/or album query string across iTunes, Deezer, and MusicBrainz.
    public func searchOnlineAlbums(query: String, source: MetadataAPIOption = .all) async -> [OnlineAlbumItem] {
        let cleanQuery = MetadataSanitizer.cleanSearchTerm(query)
        guard !cleanQuery.isEmpty else { return [] }

        let cacheKey = "online_albums__\(source.rawValue)__\(cleanQuery.lowercased())"
        if let cached = queryAlbumCache[cacheKey] {
            return cached
        }

        var results: [OnlineAlbumItem] = []

        switch source {
        case .deezer:
            results = await searchDeezerAlbumsDirect(query: cleanQuery)
        case .itunes:
            if isITunesCoolingDown {
                results = await searchDeezerAlbumsDirect(query: cleanQuery)
            } else {
                results = await searchITunesAlbumsDirect(query: cleanQuery)
            }
        case .musicBrainz:
            results = await searchMusicBrainzAlbumsDirect(query: cleanQuery)
        case .all:
            if isITunesCoolingDown {
                results = await searchDeezerAlbumsDirect(query: cleanQuery)
            } else {
                async let dzTask = searchDeezerAlbumsDirect(query: cleanQuery)
                async let itTask = searchITunesAlbumsDirect(query: cleanQuery)
                let dz = await dzTask
                let it = await itTask
                results.append(contentsOf: it)
                results.append(contentsOf: dz)
            }
            if results.isEmpty {
                results = await searchMusicBrainzAlbumsDirect(query: cleanQuery)
            }
        }

        queryAlbumCache[cacheKey] = results
        return results
    }

    /// Fetches all track cuts and duration for a selected online album item.
    public func fetchOnlineAlbumCuts(albumItem: OnlineAlbumItem) async -> [OnlineTrackMetadata] {
        if albumItem.sourceAPI.contains("Deezer") {
            if let cuts = await fetchDeezerAlbumCutsDirect(albumId: albumItem.id) {
                return cuts
            }
        } else if albumItem.sourceAPI.contains("Apple") || albumItem.sourceAPI.contains("iTunes") {
            if let cuts = await fetchITunesAlbumCutsDirect(collectionId: albumItem.id) {
                return cuts
            }
        }
        // Fallback: search by album and artist
        if let fallback = await searchAlbumSongs(album: albumItem.title, artist: albumItem.artistName, source: .all) {
            return fallback
        }
        return []
    }

    public func searchITunesAlbumsDirect(query: String) async -> [OnlineAlbumItem] {
        let cleanQuery = MetadataSanitizer.cleanSearchTerm(query)
        guard !cleanQuery.isEmpty else { return [] }
        guard let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=album&limit=25") else {
            return []
        }

        guard let data = await executeRateLimitedITunesRequest(url: url),
              let albumResp = try? JSONDecoder().decode(ITunesAlbumSearchResponse.self, from: data) else {
            return []
        }

        return albumResp.results.compactMap { a in
            guard let collectionId = a.collectionId,
                  let title = a.collectionName, !title.isEmpty,
                  let artist = a.artistName, !artist.isEmpty else { return nil }

            let artworkURL = a.artworkUrl100.flatMap {
                URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
            }
            let year = a.releaseDate.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let date = a.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }

            return OnlineAlbumItem(
                id: "\(collectionId)",
                title: title,
                artistName: artist,
                releaseDate: date,
                releaseYear: year,
                genre: a.primaryGenreName,
                trackCount: a.trackCount,
                artworkURL: artworkURL,
                sourceAPI: "Apple Music"
            )
        }
    }

    public func searchDeezerAlbumsDirect(query: String) async -> [OnlineAlbumItem] {
        let cleanQuery = MetadataSanitizer.cleanSearchTerm(query)
        guard !cleanQuery.isEmpty else { return [] }
        guard let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=25") else {
            return []
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let albumResp = try JSONDecoder().decode(DeezerAlbumSearchResponse.self, from: data)

            return albumResp.data.compactMap { a in
                guard !a.title.isEmpty else { return nil }
                let artist = a.artist?.name ?? "Unknown Artist"
                let artworkURL = (a.cover_xl ?? a.cover_big).flatMap { URL(string: $0) }
                let year = a.release_date.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }

                return OnlineAlbumItem(
                    id: "\(a.id)",
                    title: a.title,
                    artistName: artist,
                    releaseDate: nil,
                    releaseYear: year,
                    genre: nil,
                    trackCount: a.nb_tracks,
                    artworkURL: artworkURL,
                    sourceAPI: "Deezer"
                )
            }
        } catch {
            return []
        }
    }

    public func searchMusicBrainzAlbumsDirect(query: String) async -> [OnlineAlbumItem] {
        let cleanQuery = MetadataSanitizer.cleanSearchTerm(query)
        guard !cleanQuery.isEmpty else { return [] }
        guard let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(encoded)&fmt=json&limit=15") else {
            return []
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("SeaPlusPlusMusicPlayer/1.0 ( support@example.com )", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let mbResp = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)

            return mbResp.releases.compactMap { r in
                guard let title = r.title, !title.isEmpty else { return nil }
                let artist = r.artistCredit?.compactMap { $0.name }.joined(separator: ", ") ?? "Unknown Artist"
                let year = r.date.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
                let artworkURL = r.id.flatMap { URL(string: "https://coverartarchive.org/release/\($0)/front-500") }

                return OnlineAlbumItem(
                    id: r.id ?? UUID().uuidString,
                    title: title,
                    artistName: artist,
                    releaseDate: nil,
                    releaseYear: year,
                    genre: r.tags?.first?.name?.capitalized,
                    trackCount: r.trackCount ?? r.media?.first?.trackCount,
                    artworkURL: artworkURL,
                    sourceAPI: "MusicBrainz"
                )
            }
        } catch {
            return []
        }
    }

    public func fetchITunesAlbumCutsDirect(collectionId: String) async -> [OnlineTrackMetadata]? {
        var lookupComponents = URLComponents(string: "https://itunes.apple.com/lookup")
        lookupComponents?.queryItems = [
            URLQueryItem(name: "id", value: collectionId),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let lookupURL = lookupComponents?.url,
              let lookupData = await executeRateLimitedITunesRequest(url: lookupURL),
              let lookupResp = try? JSONDecoder().decode(ITunesSearchResponse.self, from: lookupData) else {
            return nil
        }
        let tracks = parseITunesTrackResults(lookupResp.results)
        return tracks.isEmpty ? nil : tracks
    }

    public func fetchDeezerAlbumCutsDirect(albumId: String) async -> [OnlineTrackMetadata]? {
        guard let url = URL(string: "https://api.deezer.com/album/\(albumId)/tracks?limit=200") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let tracksResp = try JSONDecoder().decode(DeezerAlbumTracksListResponse.self, from: data)

            return tracksResp.data.compactMap { item in
                let durationSec = item.duration.map { Double($0) }
                return OnlineTrackMetadata(
                    id: "dz_\(item.id)",
                    title: item.title,
                    artist: item.artist?.name ?? "",
                    album: "",
                    albumArtist: item.artist?.name ?? "",
                    releaseDate: nil,
                    releaseYear: nil,
                    genre: nil,
                    trackNumber: item.track_position,
                    totalTracks: nil,
                    discNumber: item.disk_number ?? 1,
                    duration: durationSec,
                    artworkURL: nil,
                    previewURL: item.preview.flatMap { URL(string: $0) },
                    sourceAPI: "Deezer",
                    isCompilation: false
                )
            }
        } catch {
            return nil
        }
    }

    // MARK: - Single Track Exact Match Lookup (3-Tier Cascade Hierarchy)

    public func findExactMatch(for track: Track, source: MetadataAPIOption = .all) async -> OnlineTrackMetadata? {
        let signature = MetadataSanitizer.sanitize(track: track)
        let cacheKey = "\(source.rawValue)__\(signature.coreTitle.lowercased())__\(signature.primaryArtist.lowercased())__\(signature.standardAlbum.lowercased())"

        if let cached = exactMatchCache[cacheKey] {
            return cached
        }

        switch source {
        case .itunes:
            if isITunesCoolingDown {
                if let results = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist, source: .deezer),
                   let best = DisambiguationMatcher.bestMatch(for: signature, in: results) {
                    exactMatchCache[cacheKey] = best
                    return best
                }
            } else if let results = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist, source: .itunes),
               let best = DisambiguationMatcher.bestMatch(for: signature, in: results) {
                exactMatchCache[cacheKey] = best
                return best
            } else if let results = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist, source: .deezer),
               let best = DisambiguationMatcher.bestMatch(for: signature, in: results) {
                exactMatchCache[cacheKey] = best
                return best
            }
        case .deezer:
            if let results = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist, source: .deezer),
               let best = DisambiguationMatcher.bestMatch(for: signature, in: results) {
                exactMatchCache[cacheKey] = best
                return best
            }
        case .musicBrainz:
            if let results = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist, source: .musicBrainz),
               let best = DisambiguationMatcher.bestMatch(for: signature, in: results) {
                exactMatchCache[cacheKey] = best
                return best
            }
        case .all:
            // TIER 1: iTunes API (Primary with 1400x1400 artwork upscaling, bypassed if cooling down)
            if !isITunesCoolingDown {
                var tier1Results: [OnlineTrackMetadata] = []
                if !MetadataSanitizer.isUnknownAlbum(signature.standardAlbum) && !MetadataSanitizer.isUnknownArtist(signature.primaryArtist) {
                    if let albumCuts = await searchITunesAlbumSongs(album: signature.standardAlbum, artist: signature.primaryArtist, limit: 100) {
                        tier1Results.append(contentsOf: albumCuts)
                    }
                }
                if tier1Results.isEmpty {
                    let itunesQuery = "\(signature.primaryArtist) \(signature.coreTitle)".trimmingCharacters(in: .whitespacesAndNewlines)
                    if let songResults = await executeITunesSearchQuery(query: itunesQuery, limit: 15) {
                        tier1Results.append(contentsOf: songResults)
                    }
                }

                if let tier1Best = DisambiguationMatcher.bestMatch(for: signature, in: tier1Results) {
                    exactMatchCache[cacheKey] = tier1Best
                    return tier1Best
                }
            }

            // TIER 2: Deezer API (Fast Fallback if Tier 1 yields 0 or iTunes is cooling down)
            var tier2Results: [OnlineTrackMetadata] = []
            if !MetadataSanitizer.isUnknownAlbum(signature.standardAlbum) && !MetadataSanitizer.isUnknownArtist(signature.primaryArtist) {
                if let albumCuts = await searchDeezerAlbumSongs(album: signature.standardAlbum, artist: signature.primaryArtist, limit: 100) {
                    tier2Results.append(contentsOf: albumCuts)
                }
            }
            if tier2Results.isEmpty {
                if let targeted = await searchDeezerTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist) {
                    tier2Results.append(contentsOf: targeted)
                }
            }

            if let tier2Best = DisambiguationMatcher.bestMatch(for: signature, in: tier2Results) {
                exactMatchCache[cacheKey] = tier2Best
                return tier2Best
            }

            // TIER 3: MusicBrainz + AcoustID + Cover Art Archive (Deep Fallback)
            var tier3Results: [OnlineTrackMetadata] = []
            if !MetadataSanitizer.isUnknownAlbum(signature.standardAlbum) && !MetadataSanitizer.isUnknownArtist(signature.primaryArtist) {
                if let mbAlbum = await searchMusicBrainzAlbumSongs(album: signature.standardAlbum, artist: signature.primaryArtist, limit: 25) {
                    tier3Results.append(contentsOf: mbAlbum)
                }
            }
            if tier3Results.isEmpty {
                if let mbTargeted = await searchMusicBrainzTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist) {
                    tier3Results.append(contentsOf: mbTargeted)
                }
            }

            if let tier3Best = DisambiguationMatcher.bestMatch(for: signature, in: tier3Results) {
                exactMatchCache[cacheKey] = tier3Best
                return tier3Best
            }
        }

        return nil
    }

    public func searchOnline(for track: Track, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata] {
        let signature = MetadataSanitizer.sanitize(track: track)
        var allCandidates: [OnlineTrackMetadata] = []
        var seenIDs = Set<String>()

        func appendUnique(_ items: [OnlineTrackMetadata]?) {
            guard let items = items else { return }
            for item in items {
                if seenIDs.insert(item.id).inserted {
                    allCandidates.append(item)
                }
            }
        }

        // 1. Primary Query: Clean Title + Primary Artist
        let primaryResults = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist, source: source)
        appendUnique(primaryResults)

        // 2. Fallback: Query by clean core title alone (crucial for finding tracks with incorrect/missing artist tags)
        if allCandidates.isEmpty || allCandidates.allSatisfy({ (DisambiguationMatcher.evaluateMatch(signature: signature, online: $0) ?? 0) < 700 }) {
            if !signature.coreTitle.isEmpty {
                let titleOnlyResults = await searchTargetedSong(title: signature.coreTitle, source: source)
                appendUnique(titleOnlyResults)
            }
        }

        // 3. Filename Title Fallback: if tag title was corrupted or generic, query filename title
        if let fn = MetadataSanitizer.parseFilename(url: track.url), !fn.title.isEmpty {
            let cleanFnTitle = MetadataSanitizer.cleanSearchTerm(fn.title)
            if cleanFnTitle.lowercased() != signature.coreTitle.lowercased() {
                if !fn.artist.isEmpty && !MetadataSanitizer.isUnknownArtist(fn.artist) {
                    let fnResults = await searchTargetedSong(title: cleanFnTitle, artist: fn.artist, source: source)
                    appendUnique(fnResults)
                }
                let fnTitleOnly = await searchTargetedSong(title: cleanFnTitle, source: source)
                appendUnique(fnTitleOnly)
            }
        }

        // Rank all candidate results so the most accurate match is at index 0
        return DisambiguationMatcher.rankCandidates(for: signature, in: allCandidates)
    }

    public func searchOnline(query: String, source: MetadataAPIOption = .all) async -> [OnlineTrackMetadata] {
        let clean = MetadataSanitizer.cleanSearchTerm(query)
        guard !clean.isEmpty else { return [] }
        let results = (await searchTargetedSong(query: clean, source: source)) ?? []
        let pseudoSignature = MetadataSanitizer.buildSignature(title: query, artist: "", album: "", duration: 0, trackNumber: nil)
        return DisambiguationMatcher.rankCandidates(for: pseudoSignature, in: results)
    }

    // MARK: - Deezer High-Speed Search Implementation

    /// Searches Deezer API for tracks by query string.
    private func searchDeezer(query: String, limit: Int) async -> [OnlineTrackMetadata]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=\(limit)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let searchResp = try JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data)
            return parseDeezerTrackResults(searchResp.data)
        } catch {
            return nil
        }
    }

    /// Searches Deezer for an artist's tracks.
    private func searchDeezerArtistSongs(artist: String, limit: Int) async -> [OnlineTrackMetadata]? {
        let query = "artist:\"\(artist)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=\(limit)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let searchResp = try JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data)
            let parsed = parseDeezerTrackResults(searchResp.data)
            if !parsed.isEmpty { return parsed }
        } catch {}

        // Fallback: general query with artist name
        return await searchDeezer(query: artist, limit: limit)
    }

    /// Searches Deezer for album tracks with deluxe prioritization and compilation filtering.
    private func searchDeezerAlbumSongs(album: String, artist: String, limit: Int) async -> [OnlineTrackMetadata]? {
        let cleanAlbum = MetadataSanitizer.cleanSearchTerm(album)
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        let albumSearchQuery = !cleanArtist.isEmpty ? "\(cleanAlbum) \(cleanArtist)" : cleanAlbum
        guard let encoded = albumSearchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=10") else {
            return nil
        }

        var searchReq = URLRequest(url: searchURL)
        searchReq.setValue("application/json", forHTTPHeaderField: "Accept")
        searchReq.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: searchReq)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let albumResp = try JSONDecoder().decode(DeezerAlbumSearchResponse.self, from: data)

            // Filter out compilations, instrumentals, karaoke, tributes
            let nonCompilations = albumResp.data.filter { a in
                let name = a.title.lowercased()
                let art = (a.artist?.name ?? "").lowercased()
                let isJunk = name.contains("karaoke") || name.contains("tribute") || name.contains("instrumental") || name.contains("ringtone")
                let isComp = name.contains("greatest hits") || name.contains("best of") || art.contains("various artists") || name.contains("100 hits")
                return !isJunk && !isComp
            }

            // Strictly validate that the online album candidate matches the searched album and artist
            let validAlbums = nonCompilations.filter { a in
                let normOnlineAlbum = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(a.title))
                let normTargetAlbum = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(cleanAlbum))
                let albumSim = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(normOnlineAlbum, normTargetAlbum),
                    FuzzyMatcher.jaroWinklerSimilarity(normOnlineAlbum, normTargetAlbum)
                )
                let isAlbumMatch = albumSim >= 0.75 || normOnlineAlbum.contains(normTargetAlbum) || normTargetAlbum.contains(normOnlineAlbum)
                guard isAlbumMatch else { return false }

                if !cleanArtist.isEmpty, let onlineArtist = a.artist?.name, !onlineArtist.isEmpty {
                    let normOnlineArtist = FuzzyMatcher.normalize(onlineArtist)
                    let normTargetArtist = FuzzyMatcher.normalize(cleanArtist)
                    let artistSim = max(
                        FuzzyMatcher.tokenSortLevenshteinSimilarity(normOnlineArtist, normTargetArtist),
                        FuzzyMatcher.jaroWinklerSimilarity(normOnlineArtist, normTargetArtist)
                    )
                    let isArtistMatch = artistSim >= 0.70 || normOnlineArtist.contains(normTargetArtist) || normTargetArtist.contains(normOnlineArtist)
                    guard isArtistMatch else { return false }
                }
                return true
            }

            // Prioritize Deluxe editions, then higher track count, then title match
            let sortedAlbums = validAlbums.sorted { a, b in
                let isDeluxeA = DeluxeAlbumDetector.isDeluxe(text: a.title)
                let isDeluxeB = DeluxeAlbumDetector.isDeluxe(text: b.title)
                if isDeluxeA != isDeluxeB {
                    return isDeluxeA && !isDeluxeB
                }
                let countA = a.nb_tracks ?? 0
                let countB = b.nb_tracks ?? 0
                if countA != countB {
                    return countA > countB
                }
                return FuzzyMatcher.levenshteinSimilarity(a.title, cleanAlbum) > FuzzyMatcher.levenshteinSimilarity(b.title, cleanAlbum)
            }

            if let targetAlbum = sortedAlbums.first {
                let albumTracksURL = URL(string: "https://api.deezer.com/album/\(targetAlbum.id)/tracks?limit=\(limit)")
                if let tracksURL = albumTracksURL {
                    var tracksReq = URLRequest(url: tracksURL)
                    tracksReq.setValue("application/json", forHTTPHeaderField: "Accept")
                    tracksReq.timeoutInterval = 8.0
                    if let (trackData, trackResp) = try? await urlSession.data(for: tracksReq),
                       let trackHttp = trackResp as? HTTPURLResponse, trackHttp.statusCode == 200,
                       let tracksObj = try? JSONDecoder().decode(DeezerAlbumTracksListResponse.self, from: trackData) {
                        let albumCover = targetAlbum.cover_xl.flatMap { URL(string: $0) } ?? targetAlbum.cover_big.flatMap { URL(string: $0) }
                        let albumTitle = targetAlbum.title
                        let albumArtist = targetAlbum.artist?.name ?? cleanArtist
                        let releaseYear = targetAlbum.release_date.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }

                        return tracksObj.data.enumerated().map { (idx, item) in
                            OnlineTrackMetadata(
                                id: "dz_\(item.id)",
                                title: item.title,
                                artist: item.artist?.name ?? albumArtist,
                                album: albumTitle,
                                albumArtist: albumArtist,
                                releaseDate: nil,
                                releaseYear: releaseYear,
                                genre: nil,
                                trackNumber: item.track_position ?? (idx + 1),
                                totalTracks: targetAlbum.nb_tracks ?? tracksObj.data.count,
                                discNumber: item.disk_number ?? 1,
                                duration: Double(item.duration ?? 0),
                                artworkURL: albumCover,
                                previewURL: item.preview.flatMap { URL(string: $0) },
                                sourceAPI: "Deezer",
                                isCompilation: false
                            )
                        }
                    }
                }
            }
        } catch {}

        return nil
    }

    /// Searches Deezer for targeted song by title and artist.
    private func searchDeezerTargetedSong(title: String, artist: String) async -> [OnlineTrackMetadata]? {
        let query = !artist.isEmpty ? "track:\"\(title)\" artist:\"\(artist)\"" : "track:\"\(title)\""
        if let direct = await searchDeezer(query: query, limit: 15), !direct.isEmpty {
            return direct
        }
        return await searchDeezer(query: "\(title) \(artist)", limit: 15)
    }

    /// Parses Deezer track search results into unified OnlineTrackMetadata.
    private func parseDeezerTrackResults(_ items: [DeezerTrackItemResult]) -> [OnlineTrackMetadata] {
        items.compactMap { item -> OnlineTrackMetadata? in
            guard let trackTitle = item.title, !trackTitle.isEmpty,
                  let trackArtist = item.artist?.name, !trackArtist.isEmpty else { return nil }

            let coverURL: URL? = item.album?.cover_xl.flatMap { URL(string: $0) }
                ?? item.album?.cover_big.flatMap { URL(string: $0) }
                ?? item.album?.cover_medium.flatMap { URL(string: $0) }

            let albumTitle = item.album?.title ?? "Single"
            let durationSec = Double(item.duration ?? 0)

            return OnlineTrackMetadata(
                id: "dz_\(item.id)",
                title: trackTitle,
                artist: trackArtist,
                album: albumTitle,
                albumArtist: trackArtist,
                releaseDate: nil,
                releaseYear: nil,
                genre: nil,
                trackNumber: nil,
                totalTracks: nil,
                discNumber: nil,
                duration: durationSec > 0 ? durationSec : nil,
                artworkURL: coverURL,
                previewURL: item.preview.flatMap { URL(string: $0) },
                sourceAPI: "Deezer",
                isCompilation: isCompilationAlbum(albumTitle: albumTitle)
            )
        }
    }

    // MARK: - Apple Music / iTunes Implementation with Adaptive Rate Limiter

    private func searchITunesArtistSongs(artist: String, limit: Int) async -> [OnlineTrackMetadata]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let url = components?.url,
           let data = await executeRateLimitedITunesRequest(url: url),
           let searchResp = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data) {
            let parsed = parseITunesTrackResults(searchResp.results)
            if !parsed.isEmpty {
                return parsed
            }
        }
        return await executeITunesSearchQuery(query: artist, limit: limit)
    }

    private func searchITunesAlbumSongs(album: String, artist: String, limit: Int) async -> [OnlineTrackMetadata]? {
        let cleanAlbum = MetadataSanitizer.cleanSearchTerm(album)
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        let query = !cleanArtist.isEmpty ? "\(cleanAlbum) \(cleanArtist)" : cleanAlbum

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10")
        ]

        if let searchURL = components?.url,
           let data = await executeRateLimitedITunesRequest(url: searchURL),
           let albumResp = try? JSONDecoder().decode(ITunesAlbumSearchResponse.self, from: data),
           !albumResp.results.isEmpty {

            let nonCompilations = albumResp.results.filter { a in
                let name = (a.collectionName ?? "").lowercased()
                let art = (a.artistName ?? "").lowercased()
                let isJunk = name.contains("karaoke") || name.contains("tribute") || name.contains("instrumental") || name.contains("ringtone")
                let isComp = name.contains("greatest hits") || name.contains("best of") || art.contains("various artists") || name.contains("100 hits")
                return !isJunk && !isComp
            }

            // Strictly validate that the online album candidate matches the searched album and artist
            let validAlbums = nonCompilations.filter { a in
                guard let onlineAlbumName = a.collectionName, !onlineAlbumName.isEmpty else { return false }
                let normOnlineAlbum = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(onlineAlbumName))
                let normTargetAlbum = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(cleanAlbum))
                let albumSim = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(normOnlineAlbum, normTargetAlbum),
                    FuzzyMatcher.jaroWinklerSimilarity(normOnlineAlbum, normTargetAlbum)
                )
                let isAlbumMatch = albumSim >= 0.75 || normOnlineAlbum.contains(normTargetAlbum) || normTargetAlbum.contains(normOnlineAlbum)
                guard isAlbumMatch else { return false }

                if !cleanArtist.isEmpty, let onlineArtist = a.artistName, !onlineArtist.isEmpty {
                    let normOnlineArtist = FuzzyMatcher.normalize(onlineArtist)
                    let normTargetArtist = FuzzyMatcher.normalize(cleanArtist)
                    let artistSim = max(
                        FuzzyMatcher.tokenSortLevenshteinSimilarity(normOnlineArtist, normTargetArtist),
                        FuzzyMatcher.jaroWinklerSimilarity(normOnlineArtist, normTargetArtist)
                    )
                    let isArtistMatch = artistSim >= 0.70 || normOnlineArtist.contains(normTargetArtist) || normTargetArtist.contains(normOnlineArtist)
                    guard isArtistMatch else { return false }
                }
                return true
            }

            let sortedAlbums = validAlbums.sorted { a, b in
                let nameA = a.collectionName ?? ""
                let nameB = b.collectionName ?? ""
                let isDeluxeA = DeluxeAlbumDetector.isDeluxe(text: nameA)
                let isDeluxeB = DeluxeAlbumDetector.isDeluxe(text: nameB)
                if isDeluxeA != isDeluxeB {
                    return isDeluxeA && !isDeluxeB
                }
                let countA = a.trackCount ?? 0
                let countB = b.trackCount ?? 0
                if countA != countB {
                    return countA > countB
                }
                return FuzzyMatcher.levenshteinSimilarity(nameA, cleanAlbum) > FuzzyMatcher.levenshteinSimilarity(nameB, cleanAlbum)
            }

            if let targetAlbum = sortedAlbums.first, let collectionId = targetAlbum.collectionId {
                var lookupComponents = URLComponents(string: "https://itunes.apple.com/lookup")
                lookupComponents?.queryItems = [
                    URLQueryItem(name: "id", value: String(collectionId)),
                    URLQueryItem(name: "entity", value: "song"),
                    URLQueryItem(name: "limit", value: "200")
                ]
                if let lookupURL = lookupComponents?.url,
                   let lookupData = await executeRateLimitedITunesRequest(url: lookupURL),
                   let lookupResp = try? JSONDecoder().decode(ITunesSearchResponse.self, from: lookupData) {
                    let tracks = parseITunesTrackResults(lookupResp.results)
                    if !tracks.isEmpty {
                        return tracks
                    }
                }
            }
        }

        return nil
    }

    private func executeITunesSearchQuery(query: String, limit: Int) async -> [OnlineTrackMetadata]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = components?.url else { return [] }
        guard let data = await executeRateLimitedITunesRequest(url: url) else { return nil }

        do {
            let searchResponse = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            return parseITunesTrackResults(searchResponse.results)
        } catch {
            AppLogger.metadata.warning("[iTunes JSON Decode Error] \(error.localizedDescription)")
            return []
        }
    }

    private func parseITunesTrackResults(_ results: [ITunesTrackResult]) -> [OnlineTrackMetadata] {
        results.compactMap { item -> OnlineTrackMetadata? in
            guard let trackTitle = item.trackName, let trackArtist = item.artistName else { return nil }
            if let wrapper = item.wrapperType, wrapper != "track" && item.kind != "song" {
                return nil
            }

            var highResArtworkURL: URL?
            if let artUrl100 = item.artworkUrl100 {
                let upgradedString = artUrl100
                    .replacingOccurrences(of: "100x100bb", with: "1400x1400bb")
                    .replacingOccurrences(of: "60x60bb", with: "1400x1400bb")
                highResArtworkURL = URL(string: upgradedString) ?? URL(string: artUrl100)
            }

            let parsedYear: Int? = item.releaseDate.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let parsedDate: Date? = item.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }
            let durationSec = item.trackTimeMillis.map { $0 / 1000.0 }
            let isComp = isCompilationAlbum(albumTitle: item.collectionName)
            let trackIdentifier = item.trackId.map { "itunes_\($0)" } ?? "itunes_\(Int64.random(in: 100000...999999))"

            return OnlineTrackMetadata(
                id: trackIdentifier,
                title: trackTitle,
                artist: trackArtist,
                album: item.collectionName ?? "Unknown Album",
                albumArtist: item.collectionArtistName ?? trackArtist,
                releaseDate: parsedDate,
                releaseYear: parsedYear,
                genre: item.primaryGenreName,
                trackNumber: item.trackNumber,
                totalTracks: item.trackCount,
                discNumber: item.discNumber,
                duration: durationSec,
                artworkURL: highResArtworkURL,
                previewURL: item.previewUrl.flatMap { URL(string: $0) },
                sourceAPI: "Apple Music / iTunes",
                isCompilation: isComp
            )
        }
    }

    private func executeRateLimitedITunesRequest(url: URL) async -> Data? {
        // If iTunes is in cooldown, reject immediately and let caller fall back to Deezer
        if self.isITunesCoolingDown {
            AppLogger.network.debug("[iTunes In Cooldown] Bypassing iTunes call (remaining: \(String(format: "%.1f", self.iTunesCooldownRemainingSeconds))s).")
            return nil
        }

        let now = Date()
        let scheduledTime = max(now, nextAvailableITunesRequestTime)
        nextAvailableITunesRequestTime = scheduledTime.addingTimeInterval(minITunesRequestInterval)

        let waitInterval = scheduledTime.timeIntervalSince(now)
        if waitInterval > 0 {
            let sleepNs = UInt64(waitInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0

        let startTime = Date()
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            let duration = Date().timeIntervalSince(startTime)

            if httpResponse.statusCode == 200 {
                consecutiveITunesSuccessCount += 1
                AppLogger.network.info("[iTunes REST 200 OK] Response received in \(String(format: "%.2f", duration))s (\(data.count) bytes)")
                return data
            } else if httpResponse.statusCode == 429 || httpResponse.statusCode == 403 {
                consecutiveITunesSuccessCount = 0
                // Trip circuit breaker for 25 seconds
                iTunesCooldownUntil = Date().addingTimeInterval(25.0)
                AppLogger.network.warning("[iTunes Rate Limit \(httpResponse.statusCode)] Circuit breaker tripped! Pausing iTunes for 25s. All requests will automatically fall back to Deezer.")
                return nil
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - MusicBrainz Search Implementation

    /// Searches MusicBrainz API for recordings by query.
    public func searchMusicBrainz(query: String, limit: Int = 15) async -> [OnlineTrackMetadata]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/recording?query=\(encoded)&limit=\(limit)&fmt=json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SeaPlusPlusMusicPlayer/1.0 ( support@example.com )", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let mbResp = try JSONDecoder().decode(MusicBrainzRecordingSearchResponse.self, from: data)
            return parseMusicBrainzRecordings(mbResp.recordings)
        } catch {
            return nil
        }
    }

    /// Searches MusicBrainz for a targeted song by title and artist.
    public func searchMusicBrainzTargetedSong(title: String, artist: String) async -> [OnlineTrackMetadata]? {
        let query = !artist.isEmpty ? "recording:\"\(title)\" AND artist:\"\(artist)\"" : "recording:\"\(title)\""
        if let direct = await searchMusicBrainz(query: query, limit: 15), !direct.isEmpty {
            return direct
        }
        return await searchMusicBrainz(query: "\(title) \(artist)", limit: 15)
    }

    /// Searches MusicBrainz for all tracks in an album.
    public func searchMusicBrainzAlbumSongs(album: String, artist: String, limit: Int = 50) async -> [OnlineTrackMetadata]? {
        let query = !artist.isEmpty ? "release:\"\(album)\" AND artist:\"\(artist)\"" : "release:\"\(album)\""
        return await searchMusicBrainz(query: query, limit: limit)
    }

    /// Searches MusicBrainz for artist tracks.
    public func searchMusicBrainzArtistSongs(artist: String, limit: Int = 50) async -> [OnlineTrackMetadata]? {
        let query = "artist:\"\(artist)\""
        return await searchMusicBrainz(query: query, limit: limit)
    }

    private func parseMusicBrainzRecordings(_ recordings: [MusicBrainzRecordingItem]) -> [OnlineTrackMetadata] {
        recordings.compactMap { rec -> OnlineTrackMetadata? in
            guard let title = rec.title, !title.isEmpty else { return nil }
            let artistName = rec.artistCredit?.compactMap { $0.name }.joined(separator: ", ") ?? "Unknown Artist"
            let firstRelease = rec.releases?.first
            let albumTitle = firstRelease?.title ?? "Single"
            let releaseId = firstRelease?.id
            let releaseDate = firstRelease?.date
            let releaseYear = releaseDate.flatMap { MetadataSanitizer.extract4DigitYear(from: $0) }
            let trackNum = firstRelease?.media?.first?.trackOffset ?? firstRelease?.media?.first?.tracks?.first?.position
            let totalTracks = firstRelease?.trackCount ?? firstRelease?.media?.first?.trackCount
            let artworkURL = releaseId.flatMap { URL(string: "https://coverartarchive.org/release/\($0)/front-500") }
            let durationSec = rec.length.map { Double($0) / 1000.0 }

            return OnlineTrackMetadata(
                id: "mb_\(rec.id)",
                title: title,
                artist: artistName,
                album: albumTitle,
                albumArtist: artistName,
                releaseDate: nil,
                releaseYear: releaseYear,
                genre: rec.tags?.first?.name?.capitalized,
                trackNumber: trackNum,
                totalTracks: totalTracks,
                discNumber: 1,
                duration: durationSec,
                artworkURL: artworkURL,
                previewURL: nil,
                sourceAPI: "MusicBrainz",
                isCompilation: false
            )
        }
    }

    // MARK: - High-Resolution Artwork Downloader

    public func downloadArtworkData(from url: URL) async -> Data? {
        // 1. Try target high-resolution URL first
        if let data = await fetchImageData(from: url) {
            return data
        }

        // 2. Fallbacks for Apple Music CDN (1400 -> 600)
        let urlStr = url.absoluteString
        if urlStr.contains("1400x1400bb") {
            let fallbackStr = urlStr.replacingOccurrences(of: "1400x1400bb", with: "600x600bb")
            if let fallbackURL = URL(string: fallbackStr), let data = await fetchImageData(from: fallbackURL) {
                return data
            }
        }

        // 3. Fallbacks for Deezer CDN (1000x1000 -> 500x500)
        if urlStr.contains("1000x1000-000000-80-0-0.jpg") {
            let fallbackStr = urlStr.replacingOccurrences(of: "1000x1000-000000-80-0-0.jpg", with: "500x500-000000-80-0-0.jpg")
            if let fallbackURL = URL(string: fallbackStr), let data = await fetchImageData(from: fallbackURL) {
                return data
            }
        }

        return nil
    }

    private func fetchImageData(from url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0
            let (data, response) = try await artworkURLSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func isCompilationAlbum(albumTitle: String?) -> Bool {
        guard let title = albumTitle?.lowercased() else { return false }
        let compilationKeywords = [
            "greatest hits", "the best of", "best of", "various artists",
            "soundtrack", "ost", "compilation", "100 hits", "anniversary collection",
            "deluxe edition single", "singles collection", "essential", "anthology"
        ]
        return compilationKeywords.contains { title.contains($0) }
    }
}

// MARK: - Deezer API Codable Models

private struct DeezerTrackSearchResponse: Codable {
    let data: [DeezerTrackItemResult]
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case data, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decodeIfPresent([DeezerTrackItemResult].self, forKey: .data)) ?? []
        total = try? container.decodeIfPresent(Int.self, forKey: .total)
    }
}

private struct DeezerTrackItemResult: Codable {
    let id: Int64
    let title: String?
    let duration: Int?
    let preview: String?
    let artist: DeezerArtistSnippet?
    let album: DeezerAlbumSnippet?
    let track_position: Int?
    let disk_number: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, preview, artist, album, track_position, disk_number
    }
}

private struct DeezerArtistSnippet: Codable {
    let id: Int64?
    let name: String?
}

private struct DeezerAlbumSnippet: Codable {
    let id: Int64?
    let title: String?
    let cover_xl: String?
    let cover_big: String?
    let cover_medium: String?
}

private struct DeezerAlbumSearchResponse: Codable {
    let data: [DeezerAlbumSearchResult]

    enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decodeIfPresent([DeezerAlbumSearchResult].self, forKey: .data)) ?? []
    }
}

private struct DeezerAlbumSearchResult: Codable {
    let id: Int64
    let title: String
    let cover_xl: String?
    let cover_big: String?
    let release_date: String?
    let nb_tracks: Int?
    let artist: DeezerArtistSnippet?

    enum CodingKeys: String, CodingKey {
        case id, title, cover_xl, cover_big, release_date, nb_tracks, artist
    }
}

private struct DeezerAlbumTracksListResponse: Codable {
    let data: [DeezerAlbumTrackItem]

    enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decodeIfPresent([DeezerAlbumTrackItem].self, forKey: .data)) ?? []
    }
}

private struct DeezerAlbumTrackItem: Codable {
    let id: Int64
    let title: String
    let duration: Int?
    let track_position: Int?
    let disk_number: Int?
    let preview: String?
    let artist: DeezerArtistSnippet?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, track_position, disk_number, preview, artist
    }
}

// MARK: - iTunes API Codable Models

private struct ITunesAlbumSearchResponse: Codable {
    let resultCount: Int?
    let results: [ITunesAlbumResult]

    enum CodingKeys: String, CodingKey {
        case resultCount, results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultCount = try? container.decodeIfPresent(Int.self, forKey: .resultCount)
        results = (try? container.decodeIfPresent([ITunesAlbumResult].self, forKey: .results)) ?? []
    }
}

private struct ITunesAlbumResult: Codable {
    let wrapperType: String?
    let collectionType: String?
    let collectionId: Int64?
    let collectionName: String?
    let artistName: String?
    let primaryGenreName: String?
    let releaseDate: String?
    let trackCount: Int?
    let artworkUrl100: String?

    enum CodingKeys: String, CodingKey {
        case wrapperType, collectionType, collectionId, collectionName, artistName
        case primaryGenreName, releaseDate, trackCount, artworkUrl100
    }
}

private struct ITunesSearchResponse: Codable {
    let resultCount: Int?
    let results: [ITunesTrackResult]

    enum CodingKeys: String, CodingKey {
        case resultCount, results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultCount = try? container.decodeIfPresent(Int.self, forKey: .resultCount)
        results = (try? container.decodeIfPresent([ITunesTrackResult].self, forKey: .results)) ?? []
    }
}

private struct ITunesTrackResult: Codable {
    let wrapperType: String?
    let kind: String?
    let trackId: Int64?
    let collectionId: Int64?
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let collectionArtistName: String?
    let releaseDate: String?
    let primaryGenreName: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let trackTimeMillis: Double?
    let artworkUrl100: String?
    let previewUrl: String?

    enum CodingKeys: String, CodingKey {
        case wrapperType, kind, trackId, collectionId, trackName, artistName, collectionName
        case collectionArtistName, releaseDate, primaryGenreName, trackNumber, trackCount
        case discNumber, trackTimeMillis, artworkUrl100, previewUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wrapperType = try? container.decodeIfPresent(String.self, forKey: .wrapperType)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)

        if let idInt = try? container.decodeIfPresent(Int64.self, forKey: .trackId) {
            trackId = idInt
        } else if let idStr = try? container.decodeIfPresent(String.self, forKey: .trackId), let idInt = Int64(idStr) {
            trackId = idInt
        } else {
            trackId = nil
        }

        if let colInt = try? container.decodeIfPresent(Int64.self, forKey: .collectionId) {
            collectionId = colInt
        } else if let colStr = try? container.decodeIfPresent(String.self, forKey: .collectionId), let colInt = Int64(colStr) {
            collectionId = colInt
        } else {
            collectionId = nil
        }

        trackName = try? container.decodeIfPresent(String.self, forKey: .trackName)
        artistName = try? container.decodeIfPresent(String.self, forKey: .artistName)
        collectionName = try? container.decodeIfPresent(String.self, forKey: .collectionName)
        collectionArtistName = try? container.decodeIfPresent(String.self, forKey: .collectionArtistName)
        releaseDate = try? container.decodeIfPresent(String.self, forKey: .releaseDate)
        primaryGenreName = try? container.decodeIfPresent(String.self, forKey: .primaryGenreName)

        if let num = try? container.decodeIfPresent(Int.self, forKey: .trackNumber) {
            trackNumber = num
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .trackNumber), let num = Int(str) {
            trackNumber = num
        } else {
            trackNumber = nil
        }

        if let cnt = try? container.decodeIfPresent(Int.self, forKey: .trackCount) {
            trackCount = cnt
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .trackCount), let cnt = Int(str) {
            trackCount = cnt
        } else {
            trackCount = nil
        }

        if let d = try? container.decodeIfPresent(Int.self, forKey: .discNumber) {
            discNumber = d
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .discNumber), let d = Int(str) {
            discNumber = d
        } else {
            discNumber = nil
        }

        if let ms = try? container.decodeIfPresent(Double.self, forKey: .trackTimeMillis) {
            trackTimeMillis = ms
        } else if let msInt = try? container.decodeIfPresent(Int64.self, forKey: .trackTimeMillis) {
            trackTimeMillis = Double(msInt)
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .trackTimeMillis), let ms = Double(str) {
            trackTimeMillis = ms
        } else {
            trackTimeMillis = nil
        }

        artworkUrl100 = try? container.decodeIfPresent(String.self, forKey: .artworkUrl100)
        previewUrl = try? container.decodeIfPresent(String.self, forKey: .previewUrl)
    }
}

// MARK: - MusicBrainz API Codable Models

private struct MusicBrainzReleaseSearchResponse: Codable {
    let releases: [MusicBrainzReleaseItem]

    enum CodingKeys: String, CodingKey {
        case releases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        releases = (try? container.decodeIfPresent([MusicBrainzReleaseItem].self, forKey: .releases)) ?? []
    }
}

private struct MusicBrainzRecordingSearchResponse: Codable {
    let recordings: [MusicBrainzRecordingItem]

    enum CodingKeys: String, CodingKey {
        case recordings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordings = (try? container.decodeIfPresent([MusicBrainzRecordingItem].self, forKey: .recordings)) ?? []
    }
}

private struct MusicBrainzRecordingItem: Codable {
    let id: String
    let title: String?
    let length: Int?
    let artistCredit: [MusicBrainzArtistCreditItem]?
    let releases: [MusicBrainzReleaseItem]?
    let tags: [MusicBrainzTagItem]?

    enum CodingKeys: String, CodingKey {
        case id, title, length, tags
        case artistCredit = "artist-credit"
        case releases
    }
}

private struct MusicBrainzArtistCreditItem: Codable {
    let name: String?
}

private struct MusicBrainzReleaseItem: Codable {
    let id: String?
    let title: String?
    let date: String?
    let trackCount: Int?
    let media: [MusicBrainzMediaItem]?
    let artistCredit: [MusicBrainzArtistCreditItem]?
    let tags: [MusicBrainzTagItem]?

    enum CodingKeys: String, CodingKey {
        case id, title, date, media, tags
        case artistCredit = "artist-credit"
        case trackCount = "track-count"
    }
}

private struct MusicBrainzMediaItem: Codable {
    let trackOffset: Int?
    let trackCount: Int?
    let tracks: [MusicBrainzTrackItem]?

    enum CodingKeys: String, CodingKey {
        case tracks
        case trackOffset = "track-offset"
        case trackCount = "track-count"
    }
}

private struct MusicBrainzTrackItem: Codable {
    let position: Int?
}

private struct MusicBrainzTagItem: Codable {
    let name: String?
}
