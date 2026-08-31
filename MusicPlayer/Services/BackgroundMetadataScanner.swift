import Foundation
import os

/// Lightweight data structure representing scan progress and live category tallies.
public struct MetadataScanProgress: Sendable {
    // Progress
    public let progress: Double
    // Scanned count
    public let scannedCount: Int
    // Total count
    public let totalCount: Int
    // Status text
    public let statusText: String
    // Enrichment diffs
    public let enrichmentDiffs: [MetadataDiff]
    // Verified good diffs
    public let verifiedGoodDiffs: [MetadataDiff]
    // Unique identifier for unmatched track i ds
    public let unmatchedTrackIDs: Set<UUID>
}

/// Final scan payload delivered off the background queue.
public struct MetadataScanResult: Sendable {
    // Enrichment diffs
    public let enrichmentDiffs: [MetadataDiff]
    // Verified good diffs
    public let verifiedGoodDiffs: [MetadataDiff]
    // Unique identifier for unmatched track i ds
    public let unmatchedTrackIDs: Set<UUID>
}

/// Dedicated, actor-isolated background worker implementing the 3-Tier Hierarchical Batch Reduction Pipeline.
/// Tier 1: Concurrent Artist-level grouping (limit 200) -> Tier 2: Concurrent Album-level grouping (limit 200) -> Tier 3: Targeted concurrent fallback.
public actor BackgroundMetadataScanner {
    public static let shared = BackgroundMetadataScanner()

    private var activeTask: Task<Void, Never>? = nil
    // Controls is running
    private var isRunning: Bool = false

    // Initialize with configured properties
    private init() {}

    /// Checks if a background scan is currently in progress.
    public var isScanning: Bool {
        isRunning
    }

    /// Cancels any currently active background scan immediately.
    public func cancel() {
        if isRunning {
            AppLogger.metadata.info("[Background Scanner] Cancelling active metadata scan task...")
        }
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
    }

    /// Executes the 3-Tier Hierarchical Batch Reduction scan.
    public func startScan(
        tracks: [Track],
        existingDiffs: [MetadataDiff],
        existingGood: [MetadataDiff],
        existingUnmatched: Set<UUID>,
        forceRecheck: Bool,
        storageDirectoryURL: URL,
        source: MetadataAPIOption = .all,
        onProgress: @escaping @Sendable (MetadataScanProgress) -> Void,
        onComplete: @escaping @Sendable (MetadataScanResult) -> Void
    ) {
        cancel()

        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else {
            onComplete(MetadataScanResult(enrichmentDiffs: [], verifiedGoodDiffs: [], unmatchedTrackIDs: []))
            return
        }

        isRunning = true

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Ensure preconditions are met before proceeding
            guard let self = self else { return }

            // Scan start time
            let scanStartTime = Date()

            if forceRecheck {
                await MusicMetadataService.shared.clearCache()
            }

            // Unique identifier for existing diff i ds
            let existingDiffIDs = existingDiffs.map { $0.localTrack.id }
            // Unique identifier for existing good i ds
            let existingGoodIDs = existingGood.map { $0.localTrack.id }
            // Unique identifier for processed i ds
            let processedIDs = Set(existingDiffIDs + existingGoodIDs).union(existingUnmatched)

            // Tracks to scan
            let tracksToScan: [Track]
            if forceRecheck {
                tracksToScan = tracks
            } else {
                tracksToScan = tracks.filter { !processedIDs.contains($0.id) }
            }

            // Ensure preconditions are met before proceeding
            guard !tracksToScan.isEmpty else {
                AppLogger.metadata.info("[Background Scanner] All \(tracks.count) tracks are already processed and up to date.")
                await self.finish(
                    diffs: existingDiffs,
                    good: existingGood,
                    unmatched: existingUnmatched,
                    onComplete: onComplete
                )
                return
            }

            // Current diffs
            var currentDiffs = forceRecheck ? [MetadataDiff]() : existingDiffs
            // Current good
            var currentGood = forceRecheck ? [MetadataDiff]() : existingGood
            // Current unmatched
            var currentUnmatched = forceRecheck ? Set<UUID>() : existingUnmatched

            // Total
            let total = tracksToScan.count
            // Scanned count
            var scannedCount = 0
            // Last progress report time
            var lastProgressReportTime = Date.distantPast

            // Helper to report progress safely without overwhelming main actor
            func emitProgress(statusMessage: String, force: Bool = false) {
                // Now
                let now = Date()
                if force || now.timeIntervalSince(lastProgressReportTime) >= 0.08 || scannedCount >= total {
                    lastProgressReportTime = now
                    // Progress
                    let progress = total > 0 ? min(1.0, Double(scannedCount) / Double(total)) : 1.0

                    // Progress payload
                    let progressPayload = MetadataScanProgress(
                        progress: progress,
                        scannedCount: scannedCount,
                        totalCount: total,
                        statusText: statusMessage,
                        enrichmentDiffs: currentDiffs,
                        verifiedGoodDiffs: currentGood,
                        unmatchedTrackIDs: currentUnmatched
                    )
                    onProgress(progressPayload)
                }
            }

            AppLogger.metadata.info("[Pipeline Initialized] Total library tracks to evaluate: \(total). Force recheck: \(forceRecheck).")

            // MARK: - STAGE 0: Instant Completeness & Persistent Cache Pre-Check (Zero Network Cost)
            var tracksNeedingOnlineCheck: [Track] = []
            var preCheckedGoodCount = 0
            var preCheckedCachedCount = 0

            // Load persistent downloaded metadata cache from disk if available
            let cacheFileURL = storageDirectoryURL.appendingPathComponent("downloaded_metadata_cache.json")
            let persistentCache: PersistentDownloadedMetadataCache? = {
                if let data = try? Data(contentsOf: cacheFileURL),
                   let loaded = try? JSONDecoder().decode(PersistentDownloadedMetadataCache.self, from: data) {
                    return loaded
                }
                return nil
            }()

            for track in tracksToScan {
                // 1. If all 7 core tags are complete and valid, mark "Looks Good" and skip network completely!
                if !forceRecheck && track.isComplete7CoreTags {
                    let syntheticOnline = OnlineTrackMetadata(
                        id: "local_verified_\(track.id)",
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        albumArtist: track.albumArtist,
                        releaseDate: nil,
                        releaseYear: track.year,
                        genre: track.genre,
                        trackNumber: track.trackNumber,
                        totalTracks: track.totalTracks,
                        discNumber: track.discNumber,
                        duration: track.duration,
                        artworkURL: nil,
                        previewURL: nil,
                        sourceAPI: "Local Tags Verified",
                        isCompilation: false
                    )
                    let diff = MetadataDiff(localTrack: track, onlineMetadata: syntheticOnline, preserveLocalTitleAndArtist: true)
                    currentGood.removeAll { $0.id == track.id }
                    currentGood.append(diff)
                    currentUnmatched.remove(track.id)
                    scannedCount += 1
                    preCheckedGoodCount += 1
                    continue
                }

                // 2. When forceRecheck is false, check if we already have downloaded online metadata in persistent cache
                if !forceRecheck {
                    let path = track.url.standardizedFileURL.path
                    let normName = track.url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let size = track.fileInfo?.fileSizeBytes ?? 0
                    let fileSig = "\(normName)__\(size)"
                    let normArtist = FuzzyMatcher.normalize(track.artist)
                    let normTitle = FuzzyMatcher.normalize(track.title)
                    let durInt = Int(track.duration.rounded())
                    let trackSig = "\(normArtist)__\(normTitle)__\(durInt)"

                    let cachedRecord = persistentCache?.recordsByFilePath[path]
                        ?? persistentCache?.recordsByFileSignature[fileSig]
                        ?? (!trackSig.isEmpty ? persistentCache?.recordsBySignature[trackSig] : nil)

                    if let record = cachedRecord {
                        let currentTrack = (track.artworkKey == nil && record.cachedArtworkKey != nil) ? track.withArtworkKey(record.cachedArtworkKey) : track
                        let diff = MetadataDiff(localTrack: currentTrack, onlineMetadata: record.onlineMetadata, preserveLocalTitleAndArtist: true)
                        if record.wasApplied || diff.fieldsEnrichedCount == 0 {
                            currentGood.removeAll { $0.id == track.id }
                            currentGood.append(diff)
                        } else {
                            currentDiffs.removeAll { $0.id == track.id }
                            currentDiffs.append(diff)
                        }
                        currentUnmatched.remove(track.id)
                        scannedCount += 1
                        preCheckedCachedCount += 1
                        continue
                    }
                }
                tracksNeedingOnlineCheck.append(track)
            }

            AppLogger.metadata.info("[Stage 0: Instant Pre-Check] Resolved \(preCheckedGoodCount) verified complete (0 network calls), \(preCheckedCachedCount) from persistent cache. \(tracksNeedingOnlineCheck.count) tracks queued for online catalog verification.")
            emitProgress(statusMessage: "Scanning online catalog for \(tracksNeedingOnlineCheck.count) tracks...", force: true)

            // Ensure preconditions are met before proceeding
            guard !tracksNeedingOnlineCheck.isEmpty && !Task.isCancelled else {
                emitProgress(statusMessage: "Library analysis complete.", force: true)
                // Elapsed seconds
                let elapsedSeconds = Date().timeIntervalSince(scanStartTime)
                AppLogger.metadata.info("[Pipeline Completed] Completed in \(String(format: "%.2fs", elapsedSeconds)). Enriched: \(currentDiffs.count), Verified Good: \(currentGood.count), Unmatched: \(currentUnmatched.count).")
                await self.persistScanState(diffs: currentDiffs, good: currentGood, unmatched: currentUnmatched, storageURL: storageDirectoryURL)
                await self.finish(diffs: currentDiffs, good: currentGood, unmatched: currentUnmatched, onComplete: onComplete)
                return
            }

            // Pre-calculate signatures for tracks needing online lookup
            let trackSignatures: [(track: Track, signature: TrackSignature)] = tracksNeedingOnlineCheck.map {
                let sig = MetadataSanitizer.sanitize(track: $0)
                AppLogger.metadata.debug("[Signature Extracted] \"\($0.title)\" -> Core: \"\(sig.coreTitle)\", Artist: \"\(sig.primaryArtist)\", Album: \"\(sig.standardAlbum)\"")
                return ($0, sig)
            }

            // MARK: - HIERARCHICAL CLUSTERING: Artist Descending (Most Albums -> Least Albums)
            struct ArtistScanCluster {
                let artistName: String
                var albumMap: [String: (albumName: String, entries: [(track: Track, signature: TrackSignature)])] = [:]
                var looseTracks: [(track: Track, signature: TrackSignature)] = []
            }

            var artistClusters: [String: ArtistScanCluster] = [:]
            var unassignedLooseTracks: [(track: Track, signature: TrackSignature)] = []

            for entry in trackSignatures {
                let sig = entry.signature
                let isArtistValid = !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) && !sig.primaryArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isAlbumValid = !MetadataSanitizer.isUnknownAlbum(sig.standardAlbum) && !sig.standardAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if isArtistValid {
                    let artistKey = sig.primaryArtist.lowercased()
                    if artistClusters[artistKey] == nil {
                        artistClusters[artistKey] = ArtistScanCluster(artistName: sig.primaryArtist)
                    }

                    if isAlbumValid {
                        let albumKey = sig.standardAlbum.lowercased()
                        if var existing = artistClusters[artistKey]?.albumMap[albumKey] {
                            existing.entries.append(entry)
                            artistClusters[artistKey]?.albumMap[albumKey] = existing
                        } else {
                            artistClusters[artistKey]?.albumMap[albumKey] = (albumName: sig.standardAlbum, entries: [entry])
                        }
                    } else {
                        artistClusters[artistKey]?.looseTracks.append(entry)
                    }
                } else {
                    unassignedLooseTracks.append(entry)
                }
            }

            // Sort Artists: Start with the artist that has the MOST tracks available locally, down to the least
            let sortedArtistClusters = artistClusters.values.sorted { a, b in
                let totalA = a.albumMap.values.reduce(0) { $0 + $1.entries.count } + a.looseTracks.count
                let totalB = b.albumMap.values.reduce(0) { $0 + $1.entries.count } + b.looseTracks.count
                return totalA > totalB
            }

            AppLogger.metadata.info("[Hierarchical Batching] Clustered \(sortedArtistClusters.count) artists. Processing artist with most tracks first.")

            // MARK: - STAGE 1: Artist Discography Concurrent Batch Ingestion (1 Request = Up to 200 Songs per Artist)
            var stage1MatchedCount = 0
            var unresolvedAlbums: [(artist: String, album: String, entries: [(track: Track, signature: TrackSignature)])] = []
            var remainingForStage3: [(track: Track, signature: TrackSignature)] = unassignedLooseTracks

            func fetchArtistCatalog(artist: String) async -> [OnlineTrackMetadata]? {
                if Task.isCancelled { return nil }
                return await MusicMetadataService.shared.searchArtistSongs(artist: artist, source: source)
            }

            let maxArtistWorkers = min(8, max(1, sortedArtistClusters.count))
            var artistClusterIndex = 0

            await withTaskGroup(of: (ArtistScanCluster, [OnlineTrackMetadata]?).self) { group in
                while artistClusterIndex < sortedArtistClusters.count && artistClusterIndex < maxArtistWorkers {
                    let cluster = sortedArtistClusters[artistClusterIndex]
                    artistClusterIndex += 1
                    group.addTask {
                        let catalog = await fetchArtistCatalog(artist: cluster.artistName)
                        return (cluster, catalog)
                    }
                }

                for await (cluster, onlineSongsOpt) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    let onlineCatalog = onlineSongsOpt ?? []

                    if !onlineCatalog.isEmpty {
                        // Index online songs by normalized standard album name
                        var onlineAlbumMap: [String: [OnlineTrackMetadata]] = [:]
                        for song in onlineCatalog {
                            let std = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(song.album))
                            if !std.isEmpty {
                                onlineAlbumMap[std, default: []].append(song)
                            }
                        }

                        // Match each local album in this artist cluster
                        for (_, albumData) in cluster.albumMap {
                            let normLocalAlbum = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(albumData.albumName))

                            // Find best matching online album cut list in the catalog
                            var matchingAlbumCuts: [OnlineTrackMetadata]?
                            if let direct = onlineAlbumMap[normLocalAlbum], !direct.isEmpty {
                                matchingAlbumCuts = direct
                            } else {
                                // Fuzzy match album keys
                                var bestKey: String?
                                var bestSim: Double = 0.0
                                for key in onlineAlbumMap.keys {
                                    let sim = max(
                                        FuzzyMatcher.tokenSortLevenshteinSimilarity(key, normLocalAlbum),
                                        FuzzyMatcher.jaroWinklerSimilarity(key, normLocalAlbum)
                                    )
                                    if sim >= 0.75 && (sim > bestSim || normLocalAlbum.contains(key) || key.contains(normLocalAlbum)) {
                                        bestSim = sim
                                        bestKey = key
                                    }
                                }
                                if let foundKey = bestKey {
                                    matchingAlbumCuts = onlineAlbumMap[foundKey]
                                }
                            }

                            if let albumCuts = matchingAlbumCuts, !albumCuts.isEmpty {
                                let primaryCut = albumCuts.first(where: { !DeluxeAlbumDetector.isDeluxe(text: $0.album) }) ?? albumCuts.first
                                let verifiedAlbumTitle = primaryCut?.album ?? albumData.albumName
                                let verifiedAlbumArtist = primaryCut?.albumArtist ?? cluster.artistName
                                let verifiedGenre = primaryCut?.genre
                                let verifiedYear = primaryCut?.releaseYear
                                let verifiedArtworkURL = primaryCut?.artworkURL

                                var matchedCutIDs = Set<String>()
                                for entry in albumData.entries {
                                    if let bestCut = DisambiguationMatcher.findTrackCutInAlbum(for: entry.track, signature: entry.signature, in: albumCuts, excludedCutIDs: matchedCutIDs) {
                                        matchedCutIDs.insert(bestCut.id)
                                        scannedCount += 1
                                        stage1MatchedCount += 1
                                        currentUnmatched.remove(entry.track.id)

                                        let isLocalAlbumValid = !MetadataSanitizer.isUnknownAlbum(entry.track.album) &&
                                            !entry.track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        let rawAlbum = isLocalAlbumValid ? entry.track.album : bestCut.album
                                        let isRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: entry.track.title, album: rawAlbum)
                                        let isLive = MetadataSanitizer.isLiveRecording(title: entry.track.title, album: rawAlbum)
                                        let effectiveAlbum: String
                                        if isRemix {
                                            effectiveAlbum = MetadataSanitizer.remixAlbumName(forStandardAlbum: rawAlbum)
                                        } else if isLive {
                                            effectiveAlbum = MetadataSanitizer.liveAlbumName(forStandardAlbum: rawAlbum)
                                        } else {
                                            effectiveAlbum = rawAlbum
                                        }

                                        let isLocalArtistValid = !MetadataSanitizer.isUnknownArtist(entry.track.artist) &&
                                            !entry.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        let effectiveTrackArtist = isLocalArtistValid ? entry.track.artist : bestCut.artist

                                        // Ground truth: preserve local track number if already set (>0)
                                        let effectiveTrackNumber = (entry.track.trackNumber != nil && entry.track.trackNumber! > 0)
                                            ? entry.track.trackNumber
                                            : bestCut.trackNumber

                                        let synthesizedCut = OnlineTrackMetadata(
                                            id: bestCut.id,
                                            title: bestCut.title,
                                            artist: effectiveTrackArtist,
                                            album: effectiveAlbum,
                                            albumArtist: bestCut.albumArtist,
                                            releaseDate: bestCut.releaseDate,
                                            releaseYear: bestCut.releaseYear ?? verifiedYear ?? entry.track.year,
                                            genre: bestCut.genre ?? verifiedGenre ?? entry.track.genre,
                                            trackNumber: effectiveTrackNumber,
                                            totalTracks: bestCut.totalTracks ?? primaryCut?.totalTracks ?? entry.track.totalTracks,
                                            discNumber: bestCut.discNumber ?? entry.track.discNumber,
                                            duration: bestCut.duration ?? entry.track.duration,
                                            artworkURL: bestCut.artworkURL ?? verifiedArtworkURL,
                                            previewURL: bestCut.previewURL,
                                            sourceAPI: bestCut.sourceAPI,
                                            isCompilation: bestCut.isCompilation
                                        )

                                        let diff = MetadataDiff(
                                            localTrack: entry.track,
                                            onlineMetadata: synthesizedCut,
                                            preserveLocalTitleAndArtist: true
                                        )

                                        if diff.fieldsEnrichedCount > 0 {
                                            currentGood.removeAll { $0.id == entry.track.id }
                                            currentDiffs.removeAll { $0.id == entry.track.id }
                                            currentDiffs.append(diff)
                                        } else {
                                            currentDiffs.removeAll { $0.id == entry.track.id }
                                            currentGood.removeAll { $0.id == entry.track.id }
                                            currentGood.append(diff)
                                        }
                                    } else {
                                        // Track was not found in this album cut list: queue for Stage 3
                                        remainingForStage3.append(entry)
                                    }
                                }
                            } else {
                                // This specific album was not in the top 200 catalog: queue for Stage 2 on-demand album search
                                unresolvedAlbums.append((artist: cluster.artistName, album: albumData.albumName, entries: albumData.entries))
                            }
                        }

                        // Match loose tracks for this artist against the catalog
                        for looseEntry in cluster.looseTracks {
                            if let best = DisambiguationMatcher.bestMatch(for: looseEntry.signature, in: onlineCatalog) {
                                scannedCount += 1
                                stage1MatchedCount += 1
                                currentUnmatched.remove(looseEntry.track.id)

                                let diff = MetadataDiff(
                                    localTrack: looseEntry.track,
                                    onlineMetadata: best,
                                    preserveLocalTitleAndArtist: true
                                )

                                if diff.fieldsEnrichedCount > 0 {
                                    currentGood.removeAll { $0.id == looseEntry.track.id }
                                    currentDiffs.removeAll { $0.id == looseEntry.track.id }
                                    currentDiffs.append(diff)
                                } else {
                                    currentDiffs.removeAll { $0.id == looseEntry.track.id }
                                    currentGood.removeAll { $0.id == looseEntry.track.id }
                                    currentGood.append(diff)
                                }
                            } else {
                                remainingForStage3.append(looseEntry)
                            }
                        }
                    } else {
                        // Artist catalog returned 0 results: queue all albums for Stage 2, loose for Stage 3
                        for (_, albumData) in cluster.albumMap {
                            unresolvedAlbums.append((artist: cluster.artistName, album: albumData.albumName, entries: albumData.entries))
                        }
                        remainingForStage3.append(contentsOf: cluster.looseTracks)
                    }

                    emitProgress(statusMessage: "Analyzed \(scannedCount) of \(total) tracks")

                    if artistClusterIndex < sortedArtistClusters.count && !Task.isCancelled {
                        let nextCluster = sortedArtistClusters[artistClusterIndex]
                        artistClusterIndex += 1
                        group.addTask {
                            let nextCatalog = await fetchArtistCatalog(artist: nextCluster.artistName)
                            return (nextCluster, nextCatalog)
                        }
                    }
                }
            }

            // MARK: - STAGE 2: Targeted Album On-Demand Batch Matching (Only for Missing Albums)
            AppLogger.metadata.info("[Stage 1 Completed] Matched \(stage1MatchedCount) tracks. Stage 2 checking \(unresolvedAlbums.count) rare/unresolved albums...")
            var stage2MatchedCount = 0

            func fetchAlbum(album: String, artist: String) async -> [OnlineTrackMetadata]? {
                if Task.isCancelled { return nil }
                return await MusicMetadataService.shared.searchAlbumSongs(album: album, artist: artist, source: source)
            }

            let maxAlbumWorkers = min(8, max(1, unresolvedAlbums.count))
            var albumWorkIndex = 0

            await withTaskGroup(of: (String, String, [(track: Track, signature: TrackSignature)], [OnlineTrackMetadata]?).self) { group in
                while albumWorkIndex < unresolvedAlbums.count && albumWorkIndex < maxAlbumWorkers {
                    let item = unresolvedAlbums[albumWorkIndex]
                    albumWorkIndex += 1
                    group.addTask {
                        let albumSongs = await fetchAlbum(album: item.album, artist: item.artist)
                        return (item.artist, item.album, item.entries, albumSongs)
                    }
                }

                for await (artistName, albumName, entries, albumSongs) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    let availableSongs = albumSongs ?? []
                    if !availableSongs.isEmpty {
                        let primaryCut = availableSongs.first(where: { !DeluxeAlbumDetector.isDeluxe(text: $0.album) }) ?? availableSongs.first
                        let verifiedAlbumTitle = primaryCut?.album ?? albumName
                        let verifiedAlbumArtist = primaryCut?.albumArtist ?? artistName
                        let verifiedGenre = primaryCut?.genre
                        let verifiedYear = primaryCut?.releaseYear
                        let verifiedArtworkURL = primaryCut?.artworkURL

                        var matchedCutIDs = Set<String>()
                        for entry in entries {
                            if let bestCut = DisambiguationMatcher.findTrackCutInAlbum(for: entry.track, signature: entry.signature, in: availableSongs, excludedCutIDs: matchedCutIDs) {
                                matchedCutIDs.insert(bestCut.id)
                                scannedCount += 1
                                stage2MatchedCount += 1
                                currentUnmatched.remove(entry.track.id)

                                let isLocalAlbumValid = !MetadataSanitizer.isUnknownAlbum(entry.track.album) &&
                                    !entry.track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                let rawAlbum = isLocalAlbumValid ? entry.track.album : bestCut.album
                                let isRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: entry.track.title, album: rawAlbum)
                                let isLive = MetadataSanitizer.isLiveRecording(title: entry.track.title, album: rawAlbum)
                                let effectiveAlbum: String
                                if isRemix {
                                    effectiveAlbum = MetadataSanitizer.remixAlbumName(forStandardAlbum: rawAlbum)
                                } else if isLive {
                                    effectiveAlbum = MetadataSanitizer.liveAlbumName(forStandardAlbum: rawAlbum)
                                } else {
                                    effectiveAlbum = rawAlbum
                                }

                                let isLocalArtistValid = !MetadataSanitizer.isUnknownArtist(entry.track.artist) &&
                                    !entry.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                let effectiveTrackArtist = isLocalArtistValid ? entry.track.artist : bestCut.artist

                                // Ground truth: preserve local track number if already set (>0)
                                let effectiveTrackNumber = (entry.track.trackNumber != nil && entry.track.trackNumber! > 0)
                                    ? entry.track.trackNumber
                                    : bestCut.trackNumber

                                let synthesizedCut = OnlineTrackMetadata(
                                    id: bestCut.id,
                                    title: bestCut.title,
                                    artist: effectiveTrackArtist,
                                    album: effectiveAlbum,
                                    albumArtist: bestCut.albumArtist,
                                    releaseDate: bestCut.releaseDate,
                                    releaseYear: bestCut.releaseYear ?? verifiedYear ?? entry.track.year,
                                    genre: bestCut.genre ?? verifiedGenre ?? entry.track.genre,
                                    trackNumber: effectiveTrackNumber,
                                    totalTracks: bestCut.totalTracks ?? primaryCut?.totalTracks ?? entry.track.totalTracks,
                                    discNumber: bestCut.discNumber ?? entry.track.discNumber,
                                    duration: bestCut.duration ?? entry.track.duration,
                                    artworkURL: bestCut.artworkURL ?? verifiedArtworkURL,
                                    previewURL: bestCut.previewURL,
                                    sourceAPI: bestCut.sourceAPI,
                                    isCompilation: bestCut.isCompilation
                                )

                                let diff = MetadataDiff(
                                    localTrack: entry.track,
                                    onlineMetadata: synthesizedCut,
                                    preserveLocalTitleAndArtist: true
                                )

                                if diff.fieldsEnrichedCount > 0 {
                                    currentGood.removeAll { $0.id == entry.track.id }
                                    currentDiffs.removeAll { $0.id == entry.track.id }
                                    currentDiffs.append(diff)
                                } else {
                                    currentDiffs.removeAll { $0.id == entry.track.id }
                                    currentGood.removeAll { $0.id == entry.track.id }
                                    currentGood.append(diff)
                                }
                            } else {
                                remainingForStage3.append(entry)
                            }
                        }
                    } else {
                        remainingForStage3.append(contentsOf: entries)
                    }

                    emitProgress(statusMessage: "Analyzed \(scannedCount) of \(total) tracks")

                    if albumWorkIndex < unresolvedAlbums.count && !Task.isCancelled {
                        let nextItem = unresolvedAlbums[albumWorkIndex]
                        albumWorkIndex += 1
                        group.addTask {
                            let nextAlbumSongs = await fetchAlbum(album: nextItem.album, artist: nextItem.artist)
                            return (nextItem.artist, nextItem.album, nextItem.entries, nextAlbumSongs)
                        }
                    }
                }
            }

            AppLogger.metadata.info("[Stage 2 Complete] Enriched \(stage2MatchedCount) tracks. \(remainingForStage3.count) tracks remaining for Stage 3.")

            // MARK: - Stage 3: Song Fallback Search with Bounded Worker Pool
            if !remainingForStage3.isEmpty {
                let fallbackCount = remainingForStage3.count
                emitProgress(statusMessage: "Deep matching \(fallbackCount) remaining tracks...", force: true)

                let maxSongWorkers = 2
                var trackIndex = 0

                await withTaskGroup(of: (Track, OnlineTrackMetadata?).self) { group in
                    while trackIndex < fallbackCount && trackIndex < maxSongWorkers && !Task.isCancelled {
                        let entry = remainingForStage3[trackIndex]
                        trackIndex += 1
                        group.addTask {
                            let match = await MusicMetadataService.shared.findExactMatch(for: entry.track, source: source)
                            return (entry.track, match)
                        }
                    }

                    for await (track, match) in group {
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }

                        scannedCount += 1
                        currentUnmatched.remove(track.id)

                        if let match = match {
                            let isLocalAlbumValid = !MetadataSanitizer.isUnknownAlbum(track.album) && !track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let isLocalArtistValid = !MetadataSanitizer.isUnknownArtist(track.artist) && !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                            // Ground truth: preserve local track number if already set (>0)
                            let effectiveTrackNumber = (track.trackNumber != nil && track.trackNumber! > 0)
                                ? track.trackNumber
                                : match.trackNumber

                            let effectiveMatch = OnlineTrackMetadata(
                                id: match.id,
                                title: match.title,
                                artist: isLocalArtistValid ? track.artist : match.artist,
                                album: isLocalAlbumValid ? track.album : match.album,
                                albumArtist: match.albumArtist,
                                releaseDate: match.releaseDate,
                                releaseYear: match.releaseYear ?? track.year,
                                genre: match.genre ?? track.genre,
                                trackNumber: effectiveTrackNumber,
                                totalTracks: match.totalTracks ?? track.totalTracks,
                                discNumber: match.discNumber ?? track.discNumber,
                                duration: match.duration ?? track.duration,
                                artworkURL: match.artworkURL,
                                previewURL: match.previewURL,
                                sourceAPI: match.sourceAPI,
                                isCompilation: match.isCompilation
                            )

                            let diff = MetadataDiff(
                                localTrack: track,
                                onlineMetadata: effectiveMatch,
                                preserveLocalTitleAndArtist: true
                            )

                            if diff.fieldsEnrichedCount > 0 {
                                currentGood.removeAll { $0.id == track.id }
                                currentDiffs.removeAll { $0.id == track.id }
                                currentDiffs.append(diff)
                                AppLogger.metadata.info("[Stage 3 Matched: Enriched] \"\(track.title)\" -> \"\(match.title)\" on \"\(effectiveMatch.album)\"")
                            } else {
                                currentDiffs.removeAll { $0.id == track.id }
                                currentGood.removeAll { $0.id == track.id }
                                currentGood.append(diff)
                            }
                        } else {
                            currentDiffs.removeAll { $0.id == track.id }
                            currentGood.removeAll { $0.id == track.id }
                            if MetadataSanitizer.hasAllSpotsFilled(track: track) {
                                let synth = MetadataSanitizer.synthesizeVerifiedMetadata(for: track)
                                let diff = MetadataDiff(localTrack: track, onlineMetadata: synth, preserveLocalTitleAndArtist: true)
                                currentGood.append(diff)
                                AppLogger.metadata.info("[Stage 3: Complete Local Track] \"\(track.title)\" has all spots filled locally. Moved to Looks Good.")
                            } else {
                                currentUnmatched.insert(track.id)
                            }
                        }

                        emitProgress(statusMessage: "Analyzing \"\(track.title)\" (\(scannedCount)/\(total))...")

                        if trackIndex < fallbackCount && !Task.isCancelled {
                            let nextEntry = remainingForStage3[trackIndex]
                            trackIndex += 1
                            group.addTask {
                                let nextMatch = await MusicMetadataService.shared.findExactMatch(for: nextEntry.track, source: source)
                                return (nextEntry.track, nextMatch)
                            }
                        }
                    }
                }
            }

            emitProgress(statusMessage: "Library analysis complete.", force: true)

            // Elapsed seconds
            let elapsedSeconds = Date().timeIntervalSince(scanStartTime)
            // Formatted time
            let formattedTime = String(format: "%.2fs", elapsedSeconds)
            AppLogger.metadata.info("[Pipeline Completed] Scanned \(scannedCount)/\(total) tracks in \(formattedTime). Enriched: \(currentDiffs.count), Verified Good: \(currentGood.count), Unmatched: \(currentUnmatched.count).")

            // Persist scan results atomically
            await self.persistScanState(
                diffs: currentDiffs,
                good: currentGood,
                unmatched: currentUnmatched,
                storageURL: storageDirectoryURL
            )

            await self.finish(
                diffs: currentDiffs,
                good: currentGood,
                unmatched: currentUnmatched,
                onComplete: onComplete
            )
        }
    }

    // Finish
    private func finish(
        diffs: [MetadataDiff],
        good: [MetadataDiff],
        unmatched: Set<UUID>,
        onComplete: @escaping @Sendable (MetadataScanResult) -> Void
    ) {
        isRunning = false
        activeTask = nil
        // Payload
        let payload = MetadataScanResult(
            enrichmentDiffs: diffs,
            verifiedGoodDiffs: good,
            unmatchedTrackIDs: unmatched
        )
        onComplete(payload)
    }

    // Persist scan state
    private func persistScanState(
        diffs: [MetadataDiff],
        good: [MetadataDiff],
        unmatched: Set<UUID>,
        storageURL: URL
    ) {
        // File system location for enrichment file url
        let enrichmentFileURL = storageURL.appendingPathComponent("enrichment_diffs.json")
        // File system location for verified good file url
        let verifiedGoodFileURL = storageURL.appendingPathComponent("verified_good_diffs.json")
        // File system location for unmatched file url
        let unmatchedFileURL = storageURL.appendingPathComponent("unmatched_tracks.json")
        // File system location for downloaded metadata cache
        let cacheFileURL = storageURL.appendingPathComponent("downloaded_metadata_cache.json")

        do {
            // Diff data
            let diffData = try JSONEncoder().encode(diffs)
            try diffData.write(to: enrichmentFileURL, options: .atomic)

            // Good data
            let goodData = try JSONEncoder().encode(good)
            try goodData.write(to: verifiedGoodFileURL, options: .atomic)

            // Unmatched data
            let unmatchedData = try JSONEncoder().encode(Array(unmatched))
            try unmatchedData.write(to: unmatchedFileURL, options: .atomic)

            // Update persistent downloaded metadata cache with all verified and enriched online matches
            var persistentCache: PersistentDownloadedMetadataCache = {
                if let data = try? Data(contentsOf: cacheFileURL),
                   let loaded = try? JSONDecoder().decode(PersistentDownloadedMetadataCache.self, from: data) {
                    return loaded
                }
                return PersistentDownloadedMetadataCache()
            }()

            for item in (diffs + good) {
                let track = item.localTrack
                let path = track.url.standardizedFileURL.path
                let normName = track.url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let size = track.fileInfo?.fileSizeBytes ?? 0
                let fileSig = "\(normName)__\(size)"
                let normArtist = FuzzyMatcher.normalize(track.artist)
                let normTitle = FuzzyMatcher.normalize(track.title)
                let durInt = Int(track.duration.rounded())
                let trackSig = "\(normArtist)__\(normTitle)__\(durInt)"

                let record = CachedTrackMetadataRecord(
                    onlineMetadata: item.onlineMetadata,
                    localTrackSignature: trackSig,
                    filePath: path,
                    fileName: track.url.lastPathComponent,
                    fileSizeBytes: size,
                    cachedArtworkKey: track.artworkKey,
                    downloadedAt: Date(),
                    wasApplied: item.fieldsEnrichedCount == 0
                )

                persistentCache.recordsByFilePath[path] = record
                if !fileSig.isEmpty {
                    persistentCache.recordsByFileSignature[fileSig] = record
                }
                if !trackSig.isEmpty {
                    persistentCache.recordsBySignature[trackSig] = record
                }
            }

            let cacheData = try JSONEncoder().encode(persistentCache)
            try cacheData.write(to: cacheFileURL, options: .atomic)

            AppLogger.storage.info("[Persistence] Saved \(diffs.count) enrichment diffs, \(good.count) verified good, \(unmatched.count) unmatched, \(persistentCache.recordsByFilePath.count) cached records to disk.")
        } catch {
            AppLogger.storage.error("[Persistence Failed] Background scanner failed to persist state: \(error.localizedDescription)")
        }
    }
}
