import Foundation

// MARK: - Codable Models for Jellyfin Responses

private struct JellyfinViewsResponse: Codable, Sendable {
    let items: [JellyfinViewItem]?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

private struct JellyfinViewItem: Codable, Sendable {
    let id: String
    let collectionType: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case collectionType = "CollectionType"
    }
}

private struct JellyfinItemsResponse: Codable, Sendable {
    let items: [JellyfinAudioItem]?
    let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

private struct JellyfinNameIdPair: Codable, Sendable {
    let name: String?
    let id: String?
    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
    }
}

private struct JellyfinMediaSource: Codable, Sendable {
    let container: String?
    let bitRate: Int?
    let size: Int64?
    let mediaStreams: [JellyfinMediaStream]?
    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case bitRate = "Bitrate"
        case size = "Size"
        case mediaStreams = "MediaStreams"
    }
}

private struct JellyfinMediaStream: Codable, Sendable {
    let codec: String?
    let sampleRate: Int?
    let bitRate: Int?
    let channels: Int?
    let type: String?
    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case sampleRate = "SampleRate"
        case bitRate = "BitRate"
        case channels = "Channels"
        case type = "Type"
    }
}

private struct JellyfinAudioItem: Codable, Sendable {
    let id: String
    let name: String?
    let artists: [String]?
    let albumArtist: String?
    let albumArtists: [JellyfinNameIdPair]?
    let album: String?
    let productionYear: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let runTimeTicks: Double?
    let container: String?
    let path: String?
    let dateCreated: String?
    let albumId: String?
    let albumPrimaryImageTag: String?
    let imageTags: [String: String]?
    let genres: [String]?
    let mediaSources: [JellyfinMediaSource]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case artists = "Artists"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
        case album = "Album"
        case productionYear = "ProductionYear"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case container = "Container"
        case path = "Path"
        case dateCreated = "DateCreated"
        case albumId = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case imageTags = "ImageTags"
        case genres = "Genres"
        case mediaSources = "MediaSources"
    }
}

private struct JellyfinIdOnlyResponse: Codable, Sendable {
    let items: [JellyfinIdItem]?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

private struct JellyfinIdItem: Codable, Sendable {
    let id: String
    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

// MARK: - JellyfinSyncService

public final class JellyfinSyncService: Sendable {
    public static let shared = JellyfinSyncService()

    private let session: URLSession

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init(session: URLSession = JellyfinClient.syncSession) {
        self.session = session
    }

    /// Fetches all audio items from the server for the specified server link, returning mapped Tracks.
    nonisolated public func fetchAudioTracks(
        for link: JellyfinServerLink,
        token: String,
        existingTracks: [Track] = [],
        lastSyncDate: Date? = nil,
        statusHandler: ((String) -> Void)? = nil,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async throws -> [Track] {
        if let host = link.serverURL.host, JellyfinClient.isLocalHost(host) {
            let port = link.serverURL.port ?? (link.serverURL.scheme?.lowercased() == "https" ? 443 : 8096)
            try await JellyfinClient.triggerLocalNetworkPrompt(host: host, port: port)
        }

        statusHandler?("DISCOVERING LIBRARIES...")
        let parentIDs = await fetchMusicParentIDs(link: link, token: token)
        let parentIDsToQuery: [String?] = parentIDs.isEmpty ? [nil] : parentIDs.map { Optional($0) }

        statusHandler?("FETCHING TRACKS...")

        if let lastSyncDate = lastSyncDate, !existingTracks.isEmpty {
            do {
                return try await fetchIncrementalTracks(
                    for: link,
                    token: token,
                    existingTracks: existingTracks,
                    lastSyncDate: lastSyncDate,
                    parentIDs: parentIDsToQuery,
                    progressHandler: progressHandler
                )
            } catch {
                AppLogger.library.warning("Incremental Jellyfin sync failed, falling back to full sync: \(error.localizedDescription)")
            }
        }

        return try await fetchFullTracks(
            for: link,
            token: token,
            existingTracks: existingTracks,
            parentIDs: parentIDsToQuery,
            progressHandler: progressHandler
        )
    }

    // MARK: - Parent ID Discovery

    nonisolated private func fetchMusicParentIDs(link: JellyfinServerLink, token: String) async -> [String] {
        // 1. Try GET /UserViews?userId={userId}
        var components = URLComponents(url: link.serverURL.appendingPathComponent("UserViews"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "userId", value: link.userId)]
        if let url = components?.url {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let views = try? JSONDecoder().decode(JellyfinViewsResponse.self, from: data),
               let items = views.items {
                let musicIDs = Self.filterMusicViewIDs(from: items)
                if !musicIDs.isEmpty {
                    return musicIDs
                }
            }
        }

        // 2. Fallback to GET /Users/{userId}/Views
        let fallbackURL = link.serverURL.appendingPathComponent("Users/\(link.userId)/Views")
        var fallbackReq = URLRequest(url: fallbackURL)
        fallbackReq.httpMethod = "GET"
        fallbackReq.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        fallbackReq.timeoutInterval = 20
        if let (data, response) = try? await session.data(for: fallbackReq),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let views = try? JSONDecoder().decode(JellyfinViewsResponse.self, from: data),
           let items = views.items {
            let musicIDs = Self.filterMusicViewIDs(from: items)
            if !musicIDs.isEmpty {
                return musicIDs
            }
        }

        return []
    }

    nonisolated private static func filterMusicViewIDs(from items: [JellyfinViewItem]) -> [String] {
        let musicIDs = items.filter { item in
            guard let type = item.collectionType?.lowercased() else { return false }
            return type == "music" || type == "audio"
        }.map { $0.id }
        if !musicIDs.isEmpty {
            return musicIDs
        }
        // If no explicit music library found, include mixed libraries or libraries without video-only types
        let nonVideoIDs = items.filter { item in
            guard let type = item.collectionType?.lowercased() else { return true }
            return !["movies", "tvshows", "boxsets", "livetv"].contains(type)
        }.map { $0.id }
        return nonVideoIDs
    }

    // MARK: - Incremental Sync Pipeline

    nonisolated private func fetchIncrementalTracks(
        for link: JellyfinServerLink,
        token: String,
        existingTracks: [Track],
        lastSyncDate: Date,
        parentIDs: [String?],
        progressHandler: ((Int, Int) -> Void)?
    ) async throws -> [Track] {
        // 1. Fast ID pass to detect deleted tracks
        var allServerIDs = Set<String>()
        for parentID in parentIDs {
            let ids = try await fetchAllAudioItemIDs(link: link, token: token, parentID: parentID)
            allServerIDs.formUnion(ids)
        }

        let validServerTrackIDs = Set(allServerIDs.map { TrackIdentity.jellyfinTrackID(serverLinkID: link.id, itemID: $0) })
        var survivingTracksMap: [UUID: Track] = [:]
        for track in existingTracks {
            if validServerTrackIDs.contains(track.id) {
                survivingTracksMap[track.id] = track
            }
        }

        // 2. Fetch tracks added or updated since lastSyncDate (with 10-second skew buffer)
        let adjustedDate = lastSyncDate.addingTimeInterval(-10)
        let minDateStr = Self.iso8601Standard.string(from: adjustedDate)

        var changedItemsMap: [String: JellyfinAudioItem] = [:]
        for parentID in parentIDs {
            let items = try await fetchAudioItems(
                link: link,
                token: token,
                parentID: parentID,
                minDateLastSaved: minDateStr,
                progressHandler: progressHandler
            )
            for item in items {
                changedItemsMap[item.id] = item
            }
        }

        if changedItemsMap.isEmpty {
            progressHandler?(survivingTracksMap.count, survivingTracksMap.count)
            return Array(survivingTracksMap.values)
        }

        let changedPaths = changedItemsMap.values.compactMap { $0.path }
        let commonPrefix = findCommonPathPrefix(paths: changedPaths)

        for item in changedItemsMap.values {
            if let track = mapItemToTrack(
                item: item,
                link: link,
                token: token,
                commonPrefix: commonPrefix,
                existingTracksByID: survivingTracksMap
            ) {
                survivingTracksMap[track.id] = track
            }
        }

        prefetchAlbumArtworks(items: Array(changedItemsMap.values), link: link, token: token)
        progressHandler?(survivingTracksMap.count, survivingTracksMap.count)
        return Array(survivingTracksMap.values)
    }

    // MARK: - Full Sync Pipeline

    nonisolated private func fetchFullTracks(
        for link: JellyfinServerLink,
        token: String,
        existingTracks: [Track],
        parentIDs: [String?],
        progressHandler: ((Int, Int) -> Void)?
    ) async throws -> [Track] {
        var allItemsMap: [String: JellyfinAudioItem] = [:]
        for parentID in parentIDs {
            let items = try await fetchAudioItems(
                link: link,
                token: token,
                parentID: parentID,
                minDateLastSaved: nil,
                progressHandler: progressHandler
            )
            for item in items {
                allItemsMap[item.id] = item
            }
        }

        let rawPaths = allItemsMap.values.compactMap { $0.path }
        let commonPrefix = findCommonPathPrefix(paths: rawPaths)
        let existingTracksByID = Dictionary(existingTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var resultTracks: [Track] = []
        resultTracks.reserveCapacity(allItemsMap.count)
        for item in allItemsMap.values {
            if let track = mapItemToTrack(
                item: item,
                link: link,
                token: token,
                commonPrefix: commonPrefix,
                existingTracksByID: existingTracksByID
            ) {
                resultTracks.append(track)
            }
        }

        prefetchAlbumArtworks(items: Array(allItemsMap.values), link: link, token: token)
        return resultTracks
    }

    // MARK: - Parallel Paged Items Fetching

    nonisolated private func fetchAudioItems(
        link: JellyfinServerLink,
        token: String,
        parentID: String?,
        minDateLastSaved: String?,
        progressHandler: ((Int, Int) -> Void)?
    ) async throws -> [JellyfinAudioItem] {
        let firstPageLimit = 100
        let pageLimit = 250

        // Fetch first page to obtain items and total count quickly
        let firstPage = try await fetchItemsPage(
            link: link,
            token: token,
            parentID: parentID,
            startIndex: 0,
            limit: firstPageLimit,
            isFirstPage: true,
            minDateLastSaved: minDateLastSaved
        )

        let firstItems = firstPage.items ?? []
        let totalRecordCount = firstPage.totalRecordCount ?? firstItems.count

        var itemsMap: [String: JellyfinAudioItem] = [:]
        itemsMap.reserveCapacity(totalRecordCount)
        for item in firstItems {
            itemsMap[item.id] = item
        }

        // Immediately update progress so UI never sits at 0%
        progressHandler?(itemsMap.count, totalRecordCount)

        guard totalRecordCount > firstPageLimit else {
            return Array(itemsMap.values)
        }

        let remainingIndices = Array(stride(from: firstPageLimit, to: totalRecordCount, by: pageLimit))
        let maxConcurrent = 2
        var indexIterator = remainingIndices.makeIterator()
        var lastProgressDate = Date()

        try await withThrowingTaskGroup(of: [JellyfinAudioItem].self) { group in
            for _ in 0..<maxConcurrent {
                if let nextIndex = indexIterator.next() {
                    group.addTask {
                        let page = try await self.fetchItemsPage(
                            link: link,
                            token: token,
                            parentID: parentID,
                            startIndex: nextIndex,
                            limit: pageLimit,
                            isFirstPage: false,
                            minDateLastSaved: minDateLastSaved
                        )
                        return page.items ?? []
                    }
                }
            }

            while let pageItems = try await group.next() {
                for item in pageItems {
                    itemsMap[item.id] = item
                }

                let currentCount = itemsMap.count
                let now = Date()
                if now.timeIntervalSince(lastProgressDate) >= 0.25 || currentCount >= totalRecordCount {
                    lastProgressDate = now
                    progressHandler?(currentCount, totalRecordCount)
                }

                if let nextIndex = indexIterator.next() {
                    group.addTask {
                        let page = try await self.fetchItemsPage(
                            link: link,
                            token: token,
                            parentID: parentID,
                            startIndex: nextIndex,
                            limit: pageLimit,
                            isFirstPage: false,
                            minDateLastSaved: minDateLastSaved
                        )
                        return page.items ?? []
                    }
                }
            }
        }

        progressHandler?(itemsMap.count, totalRecordCount)
        return Array(itemsMap.values)
    }

    nonisolated private func fetchItemsPage(
        link: JellyfinServerLink,
        token: String,
        parentID: String?,
        startIndex: Int,
        limit: Int,
        isFirstPage: Bool,
        minDateLastSaved: String?
    ) async throws -> JellyfinItemsResponse {
        let endpoint = link.serverURL.appendingPathComponent("Users/\(link.userId)/Items")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName,Id"),
            URLQueryItem(name: "EnableUserData", value: "false"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "Fields", value: "Path,DateCreated,AlbumId,AlbumPrimaryImageTag,ImageTags,Genres,MediaSources,MediaStreams,AlbumArtists"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "EnableTotalRecordCount", value: isFirstPage ? "true" : "false")
        ]
        if let parentID = parentID, !parentID.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        if let minDateLastSaved = minDateLastSaved, !minDateLastSaved.isEmpty {
            queryItems.append(URLQueryItem(name: "MinDateLastSaved", value: minDateLastSaved))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw JellyfinClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45

        var lastError: Error?
        let decoder = JSONDecoder()

        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw JellyfinClient.mapHTTPStatusError(code)
                }
                return try decoder.decode(JellyfinItemsResponse.self, from: data)
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        if let err = lastError {
            throw JellyfinClient.mapNetworkError(err)
        }
        throw JellyfinClientError.networkError("SERVER DIDN'T RESPOND")
    }

    // MARK: - Fast ID Enumeration for Deletion Detection

    nonisolated private func fetchAllAudioItemIDs(
        link: JellyfinServerLink,
        token: String,
        parentID: String?
    ) async throws -> Set<String> {
        var validIDs = Set<String>()
        var startIndex = 0
        let limit = 10_000
        let decoder = JSONDecoder()

        while true {
            let endpoint = link.serverURL.appendingPathComponent("Users/\(link.userId)/Items")
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            var queryItems = [
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "EnableImages", value: "false"),
                URLQueryItem(name: "EnableUserData", value: "false"),
                URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
                URLQueryItem(name: "Fields", value: ""),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "StartIndex", value: String(startIndex))
            ]
            if let parentID = parentID, !parentID.isEmpty {
                queryItems.append(URLQueryItem(name: "ParentId", value: parentID))
            }
            components?.queryItems = queryItems

            guard let url = components?.url else { break }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 45

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw JellyfinClient.mapHTTPStatusError(code)
            }
            let idResponse = try decoder.decode(JellyfinIdOnlyResponse.self, from: data)
            guard let items = idResponse.items, !items.isEmpty else { break }
            for item in items {
                validIDs.insert(item.id)
            }
            if items.count < limit {
                break
            }
            startIndex += items.count
        }

        return validIDs
    }

    // MARK: - Track Mapping & Helpers

    nonisolated private func mapItemToTrack(
        item: JellyfinAudioItem,
        link: JellyfinServerLink,
        token: String,
        commonPrefix: String,
        existingTracksByID: [UUID: Track]
    ) -> Track? {
        JellyfinSessionCache.shared.register(serverLink: link, token: token)

        let name = item.name ?? "Unknown Title"
        let artist: String
        if let artList = item.artists, !artList.isEmpty {
            artist = artList.joined(separator: ", ")
        } else {
            artist = item.albumArtist ?? "Unknown Artist"
        }
        let album = item.album ?? "Unknown Album"
        let albumArtist = item.albumArtists?.first?.name ?? item.albumArtist
        let genre = item.genres?.first
        let year = item.productionYear
        let trackNumber = item.indexNumber
        let discNumber = item.parentIndexNumber

        var duration: TimeInterval = 0
        if let ticks = item.runTimeTicks {
            duration = ticks / 10_000_000.0
        }

        let container = item.container?.lowercased() ?? ""
        let needsTranscoding = container == "wma" || container == "webm" || container == "dsf" || container == "dff"

        // Canonical stream URL without baked-in api_key token for safe persistence
        let streamURL: URL
        if needsTranscoding {
            streamURL = link.serverURL.appendingPathComponent("Audio/\(item.id)/stream.mp3")
        } else {
            streamURL = link.serverURL.appendingPathComponent("Audio/\(item.id)/stream")
        }

        var streamComponents = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = []
        if !needsTranscoding {
            queryItems.append(URLQueryItem(name: "static", value: "true"))
        }
        streamComponents?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let finalStreamURL = streamComponents?.url else { return nil }

        // Construct AudioFileInfo if media source specifications are present
        var fileInfo: AudioFileInfo? = nil
        let mediaSource = item.mediaSources?.first
        let audioStream = mediaSource?.mediaStreams?.first(where: { $0.type?.lowercased() == "audio" }) ?? mediaSource?.mediaStreams?.first
        let ext = item.container ?? mediaSource?.container ?? "mp3"
        let sRate = Double(audioStream?.sampleRate ?? 44100)
        let chCount = audioStream?.channels ?? 2
        let bRate = Double(audioStream?.bitRate ?? mediaSource?.bitRate ?? 0)
        let codecDesc = audioStream?.codec?.uppercased() ?? ext.uppercased()
        let fSize = mediaSource?.size ?? 0

        fileInfo = AudioFileInfo(
            filePath: finalStreamURL.absoluteString,
            fileName: "\(name).\(ext)",
            fileExtension: ext,
            fileSizeBytes: fSize,
            sampleRate: sRate,
            channelCount: chCount,
            bitRate: bRate,
            formatDescription: codecDesc,
            durationSeconds: duration
        )

        var relativePath: String?
        if let rawPath = item.path, !rawPath.isEmpty {
            if !commonPrefix.isEmpty && rawPath.hasPrefix(commonPrefix) {
                var stripped = String(rawPath.dropFirst(commonPrefix.count))
                while stripped.hasPrefix("/") {
                    stripped.removeFirst()
                }
                relativePath = TrackIdentity.normalizeRelativePath(stripped)
            } else {
                let filename = (rawPath as NSString).lastPathComponent
                relativePath = TrackIdentity.normalizeRelativePath("\(artist)/\(album)/\(filename)")
            }
        } else {
            relativePath = TrackIdentity.normalizeRelativePath("\(artist)/\(album)/\(name).mp3")
        }

        let trackID = TrackIdentity.jellyfinTrackID(serverLinkID: link.id, itemID: item.id)
        let existingTrack = existingTracksByID[trackID]
        let parsedDate = Self.parseDateCreated(item.dateCreated)
        let finalDateAdded = existingTrack?.dateAdded ?? parsedDate ?? Date()
        let lyrics = existingTrack?.lyrics
        let isAlternate = existingTrack?.isAlternate

        let tagSnap = TagSnapshot(
            title: name,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            year: year,
            trackNumber: trackNumber,
            discNumber: discNumber
        )

        let artworkKey: String
        if let albId = item.albumId, !albId.isEmpty {
            artworkKey = "jf_album_\(albId)"
        } else {
            artworkKey = ArtworkCacheService.albumArtworkKey(artist: artist, album: album)
        }
        let primaryItemID = item.albumId ?? item.id
        let fallbackItemID: String? = (item.albumId != nil && item.albumId != item.id) ? item.id : nil
        JellyfinArtworkRegistry.shared.register(
            key: artworkKey,
            serverURL: link.serverURL,
            token: token,
            itemId: primaryItemID,
            fallbackItemId: fallbackItemID
        )
        let canonKey = ArtworkCacheService.albumArtworkKey(artist: artist, album: album)
        if canonKey != artworkKey {
            JellyfinArtworkRegistry.shared.register(
                key: canonKey,
                serverURL: link.serverURL,
                token: token,
                itemId: primaryItemID,
                fallbackItemId: fallbackItemID
            )
        }

        return Track(
            id: trackID,
            title: name,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            url: finalStreamURL,
            artworkKey: artworkKey,
            dateAdded: finalDateAdded,
            fileInfo: fileInfo,
            lyrics: lyrics,
            isAlternate: isAlternate,
            folderID: link.id,
            relativePath: relativePath,
            metadataSource: .server,
            tagSnapshot: tagSnap,
            jellyfinItemId: item.id,
            jellyfinAlbumId: item.albumId
        )
    }

    nonisolated private static func parseDateCreated(_ dateStr: String?) -> Date? {
        guard let dateStr = dateStr, !dateStr.isEmpty else { return nil }
        if let date = iso8601WithFractional.date(from: dateStr) {
            return date
        }
        return iso8601Standard.date(from: dateStr)
    }

    nonisolated private func findCommonPathPrefix(paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        if paths.count == 1 {
            return (first as NSString).deletingLastPathComponent
        }
        var currentPrefix = (first as NSString).deletingLastPathComponent
        for path in paths.dropFirst() {
            while !currentPrefix.isEmpty && !path.hasPrefix(currentPrefix) {
                let nextPrefix = (currentPrefix as NSString).deletingLastPathComponent
                if nextPrefix == currentPrefix {
                    currentPrefix = ""
                    break
                }
                currentPrefix = nextPrefix
            }
            if currentPrefix.isEmpty {
                break
            }
        }
        guard currentPrefix.count > 1 else { return "" }
        return currentPrefix
    }

    nonisolated private func prefetchAlbumArtworks(
        items: [JellyfinAudioItem],
        link: JellyfinServerLink,
        token: String
    ) {
        Task.detached(priority: .utility) {
            var keyToItem: [String: String] = [:]
            for item in items {
                let key: String
                if let albId = item.albumId, !albId.isEmpty {
                    key = "jf_album_\(albId)"
                } else {
                    let artist = item.artists?.first ?? item.albumArtist ?? "Unknown Artist"
                    let album = item.album ?? "Unknown Album"
                    key = ArtworkCacheService.albumArtworkKey(artist: artist, album: album)
                }
                if keyToItem[key] == nil {
                    keyToItem[key] = item.albumId ?? item.id
                }
            }

            var keysToFetch: [(key: String, itemId: String)] = []
            for (key, itemId) in keyToItem {
                let exists = await ArtworkCacheService.shared.hasArtwork(key: key)
                if !exists {
                    keysToFetch.append((key, itemId))
                }
            }

            guard !keysToFetch.isEmpty else { return }

            let maxConcurrent = 2
            var iterator = keysToFetch.makeIterator()

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<maxConcurrent {
                    if let entry = iterator.next() {
                        group.addTask {
                            if let data = await JellyfinArtworkRegistry.shared.fetchArtworkData(for: entry.key), !data.isEmpty {
                                await ArtworkCacheService.shared.storeRawArtwork(data: data, key: entry.key)
                            }
                        }
                    }
                }

                while await group.next() != nil {
                    if let nextEntry = iterator.next() {
                        group.addTask {
                            if let data = await JellyfinArtworkRegistry.shared.fetchArtworkData(for: nextEntry.key), !data.isEmpty {
                                await ArtworkCacheService.shared.storeRawArtwork(data: data, key: nextEntry.key)
                            }
                        }
                    }
                }
            }
        }
    }
}
