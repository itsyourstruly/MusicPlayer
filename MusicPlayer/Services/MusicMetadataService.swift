import Foundation
import os

/// Dedicated Apple Music / iTunes REST API service actor for track and album metadata identification.
/// Features a strict actor-isolated rate limiter enforcing a minimum 3.0-second delay between calls (~20 req/min),
/// exponential backoff for HTTP 429/403, and in-memory deduplication caching.
public actor MusicMetadataService {
    public static let shared = MusicMetadataService()

    // Url session
    private let urlSession: URLSession
    // Artwork url session
    private let artworkURLSession: URLSession

    // In-memory query cache so identical search terms are never executed twice
    // MARK: - In-Memory Query & Exact Match Caches
    private var queryCache: [String: [OnlineTrackMetadata]] = [:]
    private var exactMatchCache: [String: OnlineTrackMetadata] = [:]

    // Serialized FIFO Rate Limiter: Baseline 0.55s interval (~110 req/min)
    // Synchronously advances time-slot reservations BEFORE yielding/sleeping
    private var nextAvailableRequestTime: Date = Date()
    private var minRequestInterval: TimeInterval = 0.55
    private var consecutiveSuccessCount: Int = 0

    // Initialize with configured properties
    private init() {
        // Config
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 25.0
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = true
        config.requestCachePolicy = .returnCacheDataElseLoad

        // Allocate memory and disk cache for network caching
        let memoryCapacity = 30 * 1024 * 1024 // 30 MB
        // Disk capacity
        let diskCapacity = 150 * 1024 * 1024  // 150 MB
        config.urlCache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity)

        self.urlSession = URLSession(configuration: config)

        // Art config
        let artConfig = URLSessionConfiguration.default
        artConfig.timeoutIntervalForRequest = 15.0
        artConfig.timeoutIntervalForResource = 30.0
        artConfig.httpMaximumConnectionsPerHost = 4
        artConfig.waitsForConnectivity = true
        artConfig.requestCachePolicy = .returnCacheDataElseLoad
        // Art memory
        let artMemory = 50 * 1024 * 1024 // 50 MB
        // Art disk
        let artDisk = 250 * 1024 * 1024  // 250 MB
        artConfig.urlCache = URLCache(memoryCapacity: artMemory, diskCapacity: artDisk)
        self.artworkURLSession = URLSession(configuration: artConfig)
    }

    /// Clears all in-memory caches.
    public func clearCache() {
        queryCache.removeAll(keepingCapacity: false)
        exactMatchCache.removeAll(keepingCapacity: false)
        consecutiveSuccessCount = 0
        minRequestInterval = 0.55
        nextAvailableRequestTime = Date()
        AppLogger.metadata.info("[Cache] Cleared in-memory metadata query cache.")
    }

    // MARK: - Stage 1: Artist-Level Song Catalog Query (limit=200)

    /// Queries Apple Music for up to 200 songs by an artist in a single call.
    /// Returns nil on network timeout/failure so callers can retry the same artist.
    public func searchArtistSongs(artist: String) async -> [OnlineTrackMetadata]? {
        // Clean artist
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        // Ensure preconditions are met before proceeding
        guard !cleanArtist.isEmpty && !MetadataSanitizer.isUnknownArtist(cleanArtist) else { return [] }

        // In-memory cache for cache key
        let cacheKey = "artist_songs__\(cleanArtist.lowercased())"
        if let cached = queryCache[cacheKey] {
            AppLogger.metadata.debug("[Query Cache Hit] Artist query: \(cleanArtist)")
            return cached
        }

        AppLogger.metadata.info("[Stage 1 Artist Search] Fetching catalog for \"\(cleanArtist)\" (limit 200)...")
        // Ensure preconditions are met before proceeding
        guard let results = await executeSearchQuery(query: cleanArtist, limit: 200) else {
            // Do NOT cache network failures or timeouts!
            return nil
        }
        queryCache[cacheKey] = results
        return results
    }

    // MARK: - Stage 2: Album-Level Song Catalog Query (limit=200)

    /// Queries Apple Music for all tracks belonging to an album in a single call.
    /// Returns nil on network timeout/failure so callers can retry the same album.
    public func searchAlbumSongs(album: String, artist: String) async -> [OnlineTrackMetadata]? {
        // Clean album
        let cleanAlbum = MetadataSanitizer.cleanSearchTerm(album)
        // Clean artist
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        // Ensure preconditions are met before proceeding
        guard !cleanAlbum.isEmpty && !MetadataSanitizer.isUnknownAlbum(cleanAlbum) else { return [] }

        // Query
        var query = cleanAlbum
        if !cleanArtist.isEmpty && !MetadataSanitizer.isUnknownArtist(cleanArtist) {
            query += " \(cleanArtist)"
        }

        // In-memory cache for cache key
        let cacheKey = "album_songs__\(query.lowercased())"
        if let cached = queryCache[cacheKey] {
            AppLogger.metadata.debug("[Query Cache Hit] Album query: \(query)")
            return cached
        }

        AppLogger.metadata.info("[Stage 2 Album Search] Fetching album cuts for \"\(cleanAlbum)\" by \"\(cleanArtist)\" (limit 200)...")
        // Ensure preconditions are met before proceeding
        guard let results = await executeSearchQuery(query: query, limit: 200) else {
            // Do NOT cache network failures or timeouts!
            return nil
        }
        queryCache[cacheKey] = results
        return results
    }

    // MARK: - Stage 3: Targeted Song Fallback Query (limit=25)

    /// Executes a targeted fallback query using cleaned track and artist keywords.
    public func searchTargetedSong(title: String, artist: String) async -> [OnlineTrackMetadata]? {
        // Clean title
        let cleanTitle = MetadataSanitizer.cleanSearchTerm(title)
        // Clean artist
        let cleanArtist = MetadataSanitizer.cleanSearchTerm(artist)
        // Ensure preconditions are met before proceeding
        guard !cleanTitle.isEmpty else { return [] }

        // Query
        var query = cleanTitle
        if !cleanArtist.isEmpty && !MetadataSanitizer.isUnknownArtist(cleanArtist) {
            query += " \(cleanArtist)"
        }

        // In-memory cache for cache key
        let cacheKey = "targeted_song__\(query.lowercased())"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        AppLogger.metadata.info("[Stage 3 Targeted Search] Query: \"\(query)\" (limit 25)...")
        // Ensure preconditions are met before proceeding
        guard let results = await executeSearchQuery(query: query, limit: 25) else {
            return nil
        }
        queryCache[cacheKey] = results
        return results
    }

    /// Secondary fallback querying purely by title when artist search fails.
    public func searchTargetedSong(title: String) async -> [OnlineTrackMetadata]? {
        // Clean title
        let cleanTitle = MetadataSanitizer.cleanSearchTerm(title)
        // Ensure preconditions are met before proceeding
        guard !cleanTitle.isEmpty else { return [] }

        // In-memory cache for cache key
        let cacheKey = "targeted_title__\(cleanTitle.lowercased())"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        AppLogger.metadata.info("[Stage 3 Title Fallback] Query: \"\(cleanTitle)\" (limit 20)...")
        // Ensure preconditions are met before proceeding
        guard let results = await executeSearchQuery(query: cleanTitle, limit: 20) else {
            return nil
        }
        queryCache[cacheKey] = results
        return results
    }

    // Search targeted song
    public func searchTargetedSong(query: String) async -> [OnlineTrackMetadata]? {
        // Clean query
        let cleanQuery = MetadataSanitizer.cleanSearchTerm(query)
        // Ensure preconditions are met before proceeding
        guard !cleanQuery.isEmpty else { return [] }

        // In-memory cache for cache key
        let cacheKey = "targeted_song__\(cleanQuery.lowercased())"
        if let cached = queryCache[cacheKey] {
            return cached
        }

        // Ensure preconditions are met before proceeding
        guard let results = await executeSearchQuery(query: cleanQuery, limit: 25) else {
            return nil
        }
        queryCache[cacheKey] = results
        return results
    }

    // MARK: - Single Track Exact Match Lookup (Used in manual search / detail sheets)

    // Find exact match
    public func findExactMatch(for track: Track) async -> OnlineTrackMetadata? {
        // Signature
        let signature = MetadataSanitizer.sanitize(track: track)
        // In-memory cache for cache key
        let cacheKey = "\(signature.coreTitle.lowercased())__\(signature.primaryArtist.lowercased())__\(signature.standardAlbum.lowercased())"

        if let cached = exactMatchCache[cacheKey] {
            return cached
        }

        // 1. Try Artist Catalog if artist is known
        if !MetadataSanitizer.isUnknownArtist(signature.primaryArtist) {
            if let artistResults = await searchArtistSongs(artist: signature.primaryArtist) {
                if let best = DisambiguationMatcher.bestMatch(for: signature, in: artistResults) {
                    exactMatchCache[cacheKey] = best
                    return best
                }
            }
        }

        // 2. Try Album Catalog if album is known
        if !MetadataSanitizer.isUnknownAlbum(signature.standardAlbum) && !MetadataSanitizer.isUnknownArtist(signature.primaryArtist) {
            if let albumResults = await searchAlbumSongs(album: signature.standardAlbum, artist: signature.primaryArtist) {
                if let best = DisambiguationMatcher.bestMatch(for: signature, in: albumResults) {
                    exactMatchCache[cacheKey] = best
                    return best
                }
            }
        }

        // 3. Fallback to Targeted Song Query (Title + Artist)
        if let targetedResults = await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist) {
            if let best = DisambiguationMatcher.bestMatch(for: signature, in: targetedResults) {
                exactMatchCache[cacheKey] = best
                return best
            }
        }

        // 4. Secondary Fallback to Pure Title Query
        if let titleOnlyResults = await searchTargetedSong(title: signature.coreTitle) {
            if let best = DisambiguationMatcher.bestMatch(for: signature, in: titleOnlyResults) {
                exactMatchCache[cacheKey] = best
                return best
            }
        }

        return nil
    }

    // Search online
    public func searchOnline(for track: Track) async -> [OnlineTrackMetadata] {
        // Signature
        let signature = MetadataSanitizer.sanitize(track: track)
        // Results
        var results = (await searchTargetedSong(title: signature.coreTitle, artist: signature.primaryArtist)) ?? []
        if results.isEmpty {
            // Fallback query
            let fallbackQuery = "\(signature.coreTitle) \(signature.primaryArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallbackQuery.isEmpty {
                results = (await executeSearchQuery(query: fallbackQuery, limit: 25)) ?? []
            }
        }
        if results.isEmpty && !signature.coreTitle.isEmpty {
            results = (await executeSearchQuery(query: signature.coreTitle, limit: 20)) ?? []
        }
        return results
    }

    // Search online
    public func searchOnline(query: String) async -> [OnlineTrackMetadata] {
        // Clean
        let clean = MetadataSanitizer.cleanSearchTerm(query)
        // Ensure preconditions are met before proceeding
        guard !clean.isEmpty else { return [] }
        return (await executeSearchQuery(query: clean, limit: 25)) ?? []
    }

    // MARK: - Core Search Request Builder

    // Execute search query
    private func executeSearchQuery(query: String, limit: Int) async -> [OnlineTrackMetadata]? {
        // Components
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        // Ensure preconditions are met before proceeding
        guard let url = components?.url else { return [] }
        // Ensure preconditions are met before proceeding
        guard let data = await executeRateLimitedRequest(url: url) else { return nil }

        do {
            // Search response
            let searchResponse = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            return parseTrackResults(searchResponse.results)
        } catch {
            AppLogger.metadata.warning("[iTunes JSON Decode Error] \(error.localizedDescription)")
            return []
        }
    }

    // Parse track results
    private func parseTrackResults(_ results: [ITunesTrackResult]) -> [OnlineTrackMetadata] {
        return results.compactMap { (item: ITunesTrackResult) -> OnlineTrackMetadata? in
            // Ensure preconditions are met before proceeding
            guard let trackTitle = item.trackName, let trackArtist = item.artistName else { return nil }
            if let wrapper = item.wrapperType, wrapper != "track" && item.kind != "song" {
                return nil
            }

            // File system location for high res artwork url
            var highResArtworkURL: URL?
            if let artUrl100 = item.artworkUrl100 {
                // Upgraded string
                let upgradedString = artUrl100
                    .replacingOccurrences(of: "100x100bb", with: "1400x1400bb")
                    .replacingOccurrences(of: "60x60bb", with: "1400x1400bb")
                highResArtworkURL = URL(string: upgradedString) ?? URL(string: artUrl100)
            }

            // Parsed year
            let parsedYear: Int? = item.releaseDate.flatMap { Int($0.prefix(4)) }
            // Parsed date
            let parsedDate: Date? = item.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }
            // Duration sec
            let durationSec = item.trackTimeMillis.map { $0 / 1000.0 }
            // Flag indicating if comp
            let isComp = isCompilationAlbum(albumTitle: item.collectionName)
            // Track identifier
            let trackIdentifier: String = {
                if let tid = item.trackId {
                    return "itunes_\(tid)"
                } else {
                    return "itunes_\(Int64.random(in: 100000...999999))"
                }
            }()

            return OnlineTrackMetadata(
                id: trackIdentifier,
                title: trackTitle,
                artist: trackArtist,
                album: item.collectionName ?? "Unknown Album",
                albumArtist: item.collectionArtistName ?? trackArtist,
                releaseDate: parsedDate,
                releaseYear: parsedYear,
                genre: nil,
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

    // MARK: - Adaptive Rate-Limited HTTP Execution with FIFO Slot Reservation

    // Execute rate limited request
    private func executeRateLimitedRequest(url: URL) async -> Data? {
        // Retries
        var retries = 3
        // Backoff seconds
        var backoffSeconds: Double = 1.5

        while retries > 0 {
            // Synchronously reserve a unique future time-slot for this request within the actor
            let now = Date()
            // Scheduled time
            let scheduledTime = max(now, nextAvailableRequestTime)
            nextAvailableRequestTime = scheduledTime.addingTimeInterval(minRequestInterval)

            // Wait interval
            let waitInterval = scheduledTime.timeIntervalSince(now)
            if waitInterval > 0 {
                // Sleep ns
                let sleepNs = UInt64(waitInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNs)
            }

            // Request
            var request = URLRequest(url: url)
            request.timeoutInterval = 15.0

            // Start time
            let startTime = Date()
            do {
                let (data, response) = try await urlSession.data(for: request)
                // Ensure preconditions are met before proceeding
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("[iTunes Network] Non-HTTP response for: \(url.absoluteString)")
                    return nil
                }
                // Duration in seconds
                let duration = Date().timeIntervalSince(startTime)

                if httpResponse.statusCode == 200 {
                    consecutiveSuccessCount += 1
                    if consecutiveSuccessCount > 15 && minRequestInterval > 0.45 {
                        minRequestInterval = max(0.45, minRequestInterval - 0.05)
                    }
                    print("[iTunes REST 200 OK] (\(data.count) bytes in \(String(format: "%.2f", duration))s) for \(url.absoluteString)")
                    AppLogger.network.info("[iTunes REST 200 OK] Response received in \(String(format: "%.2f", duration))s (\(data.count) bytes) for \(url.absoluteString)")
                    return data
                } else if httpResponse.statusCode == 429 || httpResponse.statusCode == 403 {
                    consecutiveSuccessCount = 0
                    minRequestInterval = min(3.5, minRequestInterval + 0.5)
                    nextAvailableRequestTime = max(Date(), nextAvailableRequestTime).addingTimeInterval(backoffSeconds)
                    print("[iTunes REST \(httpResponse.statusCode)] Rate limit. Backing off for \(backoffSeconds)s...")
                    AppLogger.network.warning("[iTunes REST \(httpResponse.statusCode)] Rate limit reached. Backing off for \(backoffSeconds)s before retry (\(retries - 1) retries remaining)...")
                    // Sleep ns
                    let sleepNs = UInt64(backoffSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: sleepNs)
                    backoffSeconds *= 2.0
                    retries -= 1
                    continue
                } else {
                    print("[iTunes REST HTTP Error \(httpResponse.statusCode)] for: \(url.absoluteString)")
                    AppLogger.network.warning("[iTunes REST \(httpResponse.statusCode)] HTTP error \(httpResponse.statusCode) for: \(url.absoluteString)")
                    return nil
                }
            } catch {
                consecutiveSuccessCount = 0
                minRequestInterval = min(3.0, minRequestInterval + 0.3)
                nextAvailableRequestTime = max(Date(), nextAvailableRequestTime).addingTimeInterval(backoffSeconds)
                print("[iTunes Network Error/Timeout] Failure: \(error.localizedDescription) for \(url.absoluteString). Backing off for \(backoffSeconds)s (retries left: \(retries - 1))...")
                AppLogger.network.error("[iTunes REST Error] Network failure/timeout: \(error.localizedDescription) for \(url.absoluteString)")
                // Sleep ns
                let sleepNs = UInt64(backoffSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNs)
                backoffSeconds *= 2.0
                retries -= 1
            }
        }
        return nil
    }

    // MARK: - On-Demand Artwork Downloader

    // Download artwork data
    public func downloadArtworkData(from url: URL) async -> Data? {
        // 1. Try high-resolution target URL first
        if let data = await fetchImageData(from: url) {
            return data
        }

        // 2. Fallback: If 1400x1400 failed or timed out, try standard 600x600 resolution
        let urlStr = url.absoluteString
        if urlStr.contains("1400x1400bb") {
            // Fallback str
            let fallbackStr = urlStr.replacingOccurrences(of: "1400x1400bb", with: "600x600bb")
            // File path location
            if let fallbackURL = URL(string: fallbackStr), let data = await fetchImageData(from: fallbackURL) {
                return data
            }
        }

        return nil
    }

    // Fetch image data
    private func fetchImageData(from url: URL) async -> Data? {
        do {
            // Request
            var request = URLRequest(url: url)
            request.timeoutInterval = 12.0
            let (data, response) = try await artworkURLSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // Is compilation album
    private func isCompilationAlbum(albumTitle: String?) -> Bool {
        // Ensure preconditions are met before proceeding
        guard let title = albumTitle?.lowercased() else { return false }
        // Compilation keywords
        let compilationKeywords = [
            "greatest hits", "the best of", "best of", "various artists",
            "soundtrack", "ost", "compilation", "100 hits", "anniversary collection",
            "deluxe edition single", "singles collection", "essential", "anthology"
        ]
        return compilationKeywords.contains { title.contains($0) }
    }
}

// ITunesSearchResponse representation
private struct ITunesSearchResponse: Codable {
    // Result count
    let resultCount: Int?
    // Results
    let results: [ITunesTrackResult]

    // Defines CodingKeys cases
    enum CodingKeys: String, CodingKey {
        // Result count option
        case resultCount, results
    }

    // Initialize with configured properties
    init(from decoder: Decoder) throws {
        // Container
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultCount = try? container.decodeIfPresent(Int.self, forKey: .resultCount)
        results = (try? container.decodeIfPresent([ITunesTrackResult].self, forKey: .results)) ?? []
    }
}

// ITunesTrackResult representation
private struct ITunesTrackResult: Codable {
    // Wrapper type
    let wrapperType: String?
    // Kind
    let kind: String?
    // Unique identifier for track id
    let trackId: Int64?
    // Unique identifier for collection id
    let collectionId: Int64?
    // Track name
    let trackName: String?
    // Artist name
    let artistName: String?
    // Collection name
    let collectionName: String?
    // Collection artist name
    let collectionArtistName: String?
    // Release date
    let releaseDate: String?
    // Primary genre name
    let primaryGenreName: String?
    // Track number
    let trackNumber: Int?
    // Track count
    let trackCount: Int?
    // Disc number
    let discNumber: Int?
    // Track time millis
    let trackTimeMillis: Double?
    // Artwork url 100
    let artworkUrl100: String?
    // File system location for preview url
    let previewUrl: String?

    // Defines CodingKeys cases
    enum CodingKeys: String, CodingKey {
        // Wrapper type option
        case wrapperType, kind, trackId, collectionId, trackName, artistName, collectionName
        // Collection artist name option
        case collectionArtistName, releaseDate, primaryGenreName, trackNumber, trackCount
        // Disc number option
        case discNumber, trackTimeMillis, artworkUrl100, previewUrl
    }

    // Initialize with configured properties
    init(from decoder: Decoder) throws {
        // Container
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
