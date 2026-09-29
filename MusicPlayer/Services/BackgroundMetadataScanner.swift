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
    // Controls is paused
    private var isPaused: Bool = false

    // Initialize with configured properties
    private init() {}

    /// Checks if a background scan is currently in progress.
    public var isScanning: Bool {
        isRunning
    }

    /// Checks if a background scan is currently paused.
    public var isScanPaused: Bool {
        isPaused
    }

    /// Pauses any currently active background scan.
    public func pause() {
        if isRunning && !isPaused {
            AppLogger.metadata.info("[Background Scanner] Pausing active metadata scan...")
            isPaused = true
        }
    }

    /// Resumes a paused background scan.
    public func resume() {
        if isRunning && isPaused {
            AppLogger.metadata.info("[Background Scanner] Resuming paused metadata scan...")
            isPaused = false
        }
    }

    /// Wait helper that yields execution while paused.
    public func waitIfPaused() async {
        while isPaused && isRunning && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Cancels any currently active background scan immediately.
    public func cancel() {
        if isRunning {
            AppLogger.metadata.info("[Background Scanner] Cancelling active metadata scan task...")
        }
        isPaused = false
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

        activeTask = Task.detached(priority: .utility) { [weak self] in
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

            // Dictionary indexing for O(1) removals and updates (eliminating O(N^2) scans)
            var diffsByID: [UUID: MetadataDiff] = Dictionary(
                existingDiffs.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var goodByID: [UUID: MetadataDiff] = Dictionary(
                existingGood.filter { diff in
                    let y = diff.localTrack.year ?? 0
                    return y >= 1900 && y <= Calendar.current.component(.year, from: Date()) + 2
                }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Current unmatched
            var currentUnmatched = existingUnmatched

            // Total
            let total = tracksToScan.count
            // Scanned count
            var scannedCount = 0
            // Last progress report time
            var lastProgressReportTime = Date.distantPast

            // Helper to report progress safely without overwhelming main actor
            func emitProgress(statusMessage: String, force: Bool = false) {
                let now = Date()
                if force || now.timeIntervalSince(lastProgressReportTime) >= 0.75 || scannedCount >= total {
                    lastProgressReportTime = now
                    let progress = total > 0 ? min(1.0, Double(scannedCount) / Double(total)) : 1.0

                    let progressPayload = MetadataScanProgress(
                        progress: progress,
                        scannedCount: scannedCount,
                        totalCount: total,
                        statusText: statusMessage,
                        enrichmentDiffs: Array(diffsByID.values),
                        verifiedGoodDiffs: Array(goodByID.values),
                        unmatchedTrackIDs: currentUnmatched
                    )
                    onProgress(progressPayload)
                }
            }

            AppLogger.metadata.info("[Pipeline Initialized] Total library tracks to evaluate: \(total). Force recheck: \(forceRecheck).")

            // MARK: - STAGE 0: Instant Pure App-Cache & Complete Verification Check (Zero Disk File Reads)
            emitProgress(statusMessage: "Checking app cache...", force: true)

            var tracksNeedingOnlineCheck: [Track] = []
            tracksNeedingOnlineCheck.reserveCapacity(tracksToScan.count)

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
                await self.waitIfPaused()
                if Task.isCancelled { break }

                // 1. Check if track already has all 7 core tags and artwork populated in app cache
                var effectiveTrack = track
                var isComplete = effectiveTrack.isComplete7CoreTags

                // If missing artwork key in memory, check if artwork is already in the app's artwork cache
                if !isComplete && effectiveTrack.artworkKey == nil {
                    let albumArtKey = ArtworkCacheService.albumArtworkKey(artist: effectiveTrack.artist, album: effectiveTrack.album)
                    if await ArtworkCacheService.shared.hasArtwork(key: albumArtKey) {
                        effectiveTrack = effectiveTrack.withArtworkKey(albumArtKey)
                        isComplete = effectiveTrack.isComplete7CoreTags
                    }
                }

                if isComplete {
                    let syntheticOnline = OnlineTrackMetadata(
                        id: "local_verified_\(effectiveTrack.id)",
                        title: effectiveTrack.title,
                        artist: effectiveTrack.artist,
                        album: effectiveTrack.album,
                        albumArtist: effectiveTrack.albumArtist,
                        releaseDate: nil,
                        releaseYear: effectiveTrack.year,
                        genre: effectiveTrack.genre,
                        trackNumber: effectiveTrack.trackNumber,
                        totalTracks: effectiveTrack.totalTracks,
                        discNumber: effectiveTrack.discNumber,
                        duration: effectiveTrack.duration,
                        artworkURL: nil,
                        previewURL: nil,
                        sourceAPI: "Cache Tags Verified",
                        isCompilation: false
                    )
                    let diff = MetadataDiff(localTrack: effectiveTrack, onlineMetadata: syntheticOnline, preserveLocalTitleAndArtist: true)
                    goodByID[effectiveTrack.id] = diff
                    diffsByID.removeValue(forKey: effectiveTrack.id)
                    currentUnmatched.remove(effectiveTrack.id)
                    scannedCount += 1
                    preCheckedGoodCount += 1
                    emitProgress(statusMessage: "Checking cache: \(goodByID.count) good (\(scannedCount)/\(total))...")
                    continue
                }

                // 2. Check if track was already verified as good (strictly requiring a valid release year >= 1900)
                if let existingGoodDiff = goodByID[effectiveTrack.id], existingGoodDiff.fieldsEnrichedCount == 0,
                   let y = effectiveTrack.year, y >= 1900 {
                    scannedCount += 1
                    preCheckedGoodCount += 1
                    emitProgress(statusMessage: "Checking cache: \(goodByID.count) good (\(scannedCount)/\(total))...")
                    continue
                }

                // 3. Check if we already have downloaded online metadata in persistent cache
                let path = effectiveTrack.url.standardizedFileURL.path
                let normName = effectiveTrack.url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let size = effectiveTrack.fileInfo?.fileSizeBytes ?? 0
                let fileSig = "\(normName)__\(size)"
                let normArtist = FuzzyMatcher.normalize(effectiveTrack.artist)
                let normTitle = FuzzyMatcher.normalize(effectiveTrack.title)
                let durInt = Int(effectiveTrack.duration.rounded())
                let trackSig = "\(normArtist)__\(normTitle)__\(durInt)"

                let cachedRecord = persistentCache?.recordsByFilePath[path]
                    ?? persistentCache?.recordsByFileSignature[fileSig]
                    ?? (!trackSig.isEmpty ? persistentCache?.recordsBySignature[trackSig] : nil)

                if let record = cachedRecord {
                    let currentTrack = (effectiveTrack.artworkKey == nil && record.cachedArtworkKey != nil) ? effectiveTrack.withArtworkKey(record.cachedArtworkKey) : effectiveTrack
                    let diff = MetadataDiff(localTrack: currentTrack, onlineMetadata: record.onlineMetadata, preserveLocalTitleAndArtist: true)
                    let hasValidYear = (currentTrack.year ?? 0) >= 1900
                    if hasValidYear && (record.wasApplied || diff.fieldsEnrichedCount == 0) {
                        goodByID[currentTrack.id] = diff
                        diffsByID.removeValue(forKey: currentTrack.id)
                        currentUnmatched.remove(currentTrack.id)
                    } else if diff.fieldsEnrichedCount > 0 {
                        diffsByID[currentTrack.id] = diff
                        goodByID.removeValue(forKey: currentTrack.id)
                        currentUnmatched.remove(currentTrack.id)
                    } else {
                        // Missing valid year: queue for online matching
                        diffsByID.removeValue(forKey: currentTrack.id)
                        goodByID.removeValue(forKey: currentTrack.id)
                        tracksNeedingOnlineCheck.append(effectiveTrack)
                        continue
                    }
                    scannedCount += 1
                    preCheckedCachedCount += 1
                    emitProgress(statusMessage: "Checking cache: \(goodByID.count) good (\(scannedCount)/\(total))...")
                    continue
                }

                // 4. Check if diffsByID already has a pending enrichment diff for this track
                if diffsByID[effectiveTrack.id] != nil {
                    scannedCount += 1
                    emitProgress(statusMessage: "Checking cache: \(goodByID.count) good (\(scannedCount)/\(total))...")
                    continue
                }

                // 5. Track is not complete and not in cache: queue for online catalog verification
                tracksNeedingOnlineCheck.append(effectiveTrack)
            }

            AppLogger.metadata.info("[Stage 0: Instant Pre-Check] Resolved \(preCheckedGoodCount) verified complete (0 network calls), \(preCheckedCachedCount) from persistent cache. \(tracksNeedingOnlineCheck.count) tracks queued for online catalog verification.")
            emitProgress(statusMessage: "Checked cache: \(goodByID.count) good, \(preCheckedCachedCount) cached. Scanning \(tracksNeedingOnlineCheck.count) queued tracks...", force: true)

            // Ensure preconditions are met before proceeding
            guard !tracksNeedingOnlineCheck.isEmpty && !Task.isCancelled else {
                emitProgress(statusMessage: "Library analysis complete. All \(goodByID.count) tracks verified good.", force: true)
                // Elapsed seconds
                let elapsedSeconds = Date().timeIntervalSince(scanStartTime)
                let finalDiffs = Array(diffsByID.values)
                let finalGood = Array(goodByID.values)
                AppLogger.metadata.info("[Pipeline Completed] Completed in \(String(format: "%.2fs", elapsedSeconds)). Enriched: \(finalDiffs.count), Verified Good: \(finalGood.count), Unmatched: \(currentUnmatched.count).")
                await self.persistScanState(diffs: finalDiffs, good: finalGood, unmatched: currentUnmatched, storageURL: storageDirectoryURL)
                await self.finish(diffs: finalDiffs, good: finalGood, unmatched: currentUnmatched, onComplete: onComplete)
                return
            }

            // Pre-calculate signatures for tracks needing online lookup
            let trackSignatures: [(track: Track, signature: TrackSignature)] = tracksNeedingOnlineCheck.map {
                let sig = MetadataSanitizer.sanitize(track: $0)
                AppLogger.metadata.debug("[Signature Extracted] \"\($0.title)\" -> Core: \"\(sig.coreTitle)\", Artist: \"\(sig.primaryArtist)\", Album: \"\(sig.standardAlbum)\"")
                return ($0, sig)
            }

            // MARK: - SMART QUEUE CLUSTERING: Album Batches -> Artist Loose Batches -> Standalone Singles
            struct AlbumQueueBatch {
                let artistName: String
                let albumName: String
                var entries: [(track: Track, signature: TrackSignature)]
            }

            var albumBatchMap: [String: AlbumQueueBatch] = [:]
            var artistLooseBatches: [String: [(track: Track, signature: TrackSignature)]] = [:]
            var standaloneSingles: [(track: Track, signature: TrackSignature)] = []

            for entry in trackSignatures {
                let sig = entry.signature
                let isArtistValid = !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) && !sig.primaryArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isAlbumValid = !MetadataSanitizer.isUnknownAlbum(sig.standardAlbum) && !sig.standardAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if isArtistValid && isAlbumValid {
                    let key = "\(sig.primaryArtist.lowercased())__\(sig.standardAlbum.lowercased())"
                    if var existing = albumBatchMap[key] {
                        existing.entries.append(entry)
                        albumBatchMap[key] = existing
                    } else {
                        albumBatchMap[key] = AlbumQueueBatch(artistName: sig.primaryArtist, albumName: sig.standardAlbum, entries: [entry])
                    }
                } else if isArtistValid {
                    artistLooseBatches[sig.primaryArtist.lowercased(), default: []].append(entry)
                } else {
                    standaloneSingles.append(entry)
                }
            }

            // Sort albums descending by number of local tracks in the album (fetching albums with most tracks first for maximum throughput)
            let sortedAlbumBatches = albumBatchMap.values.sorted { $0.entries.count > $1.entries.count }
            AppLogger.metadata.info("[Smart Clustering] \(sortedAlbumBatches.count) album batches, \(artistLooseBatches.count) artist loose groups, \(standaloneSingles.count) standalone singles.")

            // MARK: - STAGE 1: Concurrent Album Batch Matching (1 Request Resolves 10–25 Tracks)
            var stage1MatchedCount = 0
            var looseForStage2: [String: [(track: Track, signature: TrackSignature)]] = artistLooseBatches
            var stage3Fallback: [(track: Track, signature: TrackSignature)] = standaloneSingles

            func fetchAlbum(album: String, artist: String) async -> [OnlineTrackMetadata]? {
                if Task.isCancelled { return nil }
                return await MusicMetadataService.shared.searchAlbumSongs(album: album, artist: artist, source: source)
            }

            let maxAlbumWorkers = min(6, max(1, sortedAlbumBatches.count))
            var albumBatchIndex = 0

            await withTaskGroup(of: (AlbumQueueBatch, [OnlineTrackMetadata]?).self) { group in
                while albumBatchIndex < sortedAlbumBatches.count && albumBatchIndex < maxAlbumWorkers {
                    let batch = sortedAlbumBatches[albumBatchIndex]
                    albumBatchIndex += 1
                    group.addTask {
                        let albumSongs = await fetchAlbum(album: batch.albumName, artist: batch.artistName)
                        return (batch, albumSongs)
                    }
                }

                for await (batch, albumSongsOpt) in group {
                    await self.waitIfPaused()
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    let albumSongs = albumSongsOpt ?? []
                    if !albumSongs.isEmpty {
                        let primaryCut = albumSongs.first(where: { !DeluxeAlbumDetector.isDeluxe(text: $0.album) }) ?? albumSongs.first
                        let verifiedAlbumTitle = primaryCut?.album ?? batch.albumName
                        let verifiedAlbumArtist = primaryCut?.albumArtist ?? batch.artistName
                        let verifiedGenre = primaryCut?.genre
                        let verifiedYear = primaryCut?.releaseYear
                        let verifiedArtworkURL = primaryCut?.artworkURL

                        var matchedCutIDs = Set<String>()
                        for entry in batch.entries {
                            if let bestCut = DisambiguationMatcher.findTrackCutInAlbum(for: entry.track, signature: entry.signature, in: albumSongs, excludedCutIDs: matchedCutIDs) {
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

                                let hasValidLocalYear = (entry.track.year ?? 0) >= 1900
                                if diff.fieldsEnrichedCount > 0 {
                                    diffsByID[entry.track.id] = diff
                                    goodByID.removeValue(forKey: entry.track.id)
                                } else if hasValidLocalYear {
                                    goodByID[entry.track.id] = diff
                                    diffsByID.removeValue(forKey: entry.track.id)
                                } else {
                                    diffsByID.removeValue(forKey: entry.track.id)
                                    goodByID.removeValue(forKey: entry.track.id)
                                    looseForStage2[batch.artistName.lowercased(), default: []].append(entry)
                                }
                            } else {
                                // Track cut was not in this online album cut list: push to Stage 2 loose tracks for this artist
                                looseForStage2[batch.artistName.lowercased(), default: []].append(entry)
                            }
                        }
                    } else {
                        // Album not found online: push all tracks to Stage 2 loose tracks for this artist
                        looseForStage2[batch.artistName.lowercased(), default: []].append(contentsOf: batch.entries)
                    }

                    emitProgress(statusMessage: "Analyzed \(scannedCount) of \(total) tracks")

                    if albumBatchIndex < sortedAlbumBatches.count && !Task.isCancelled {
                        await self.waitIfPaused()
                        let nextBatch = sortedAlbumBatches[albumBatchIndex]
                        albumBatchIndex += 1
                        group.addTask {
                            let nextAlbumSongs = await fetchAlbum(album: nextBatch.albumName, artist: nextBatch.artistName)
                            return (nextBatch, nextAlbumSongs)
                        }
                    }
                }
            }

            if Task.isCancelled {
                let finalDiffs = Array(diffsByID.values)
                let finalGood = Array(goodByID.values)
                await self.persistScanState(diffs: finalDiffs, good: finalGood, unmatched: currentUnmatched, storageURL: storageDirectoryURL)
                await self.finish(diffs: finalDiffs, good: finalGood, unmatched: currentUnmatched, onComplete: onComplete)
                return
            }

            // MARK: - STAGE 2: Artist Discography Concurrent Batch Ingestion (For Loose & Unresolved Tracks)
            AppLogger.metadata.info("[Stage 1 Completed] Matched \(stage1MatchedCount) tracks. Stage 2 checking loose tracks across \(looseForStage2.count) artists...")
            var stage2MatchedCount = 0

            struct ArtistLooseBatch {
                let artistName: String
                let entries: [(track: Track, signature: TrackSignature)]
            }

            let sortedArtistLooseBatches: [ArtistLooseBatch] = looseForStage2.compactMap { (key, entries) in
                guard !entries.isEmpty else { return nil }
                let artistName = entries.first?.signature.primaryArtist ?? key
                return ArtistLooseBatch(artistName: artistName, entries: entries)
            }.sorted { $0.entries.count > $1.entries.count }

            func fetchArtistCatalog(artist: String) async -> [OnlineTrackMetadata]? {
                if Task.isCancelled { return nil }
                return await MusicMetadataService.shared.searchArtistSongs(artist: artist, source: source)
            }

            let maxArtistWorkers = min(6, max(1, sortedArtistLooseBatches.count))
            var artistBatchIndex = 0

            await withTaskGroup(of: (ArtistLooseBatch, [OnlineTrackMetadata]?).self) { group in
                while artistBatchIndex < sortedArtistLooseBatches.count && artistBatchIndex < maxArtistWorkers {
                    let batch = sortedArtistLooseBatches[artistBatchIndex]
                    artistBatchIndex += 1
                    group.addTask {
                        let catalog = await fetchArtistCatalog(artist: batch.artistName)
                        return (batch, catalog)
                    }
                }

                for await (batch, catalogOpt) in group {
                    await self.waitIfPaused()
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    let catalog = catalogOpt ?? []
                    if !catalog.isEmpty {
                        for entry in batch.entries {
                            if let best = DisambiguationMatcher.bestMatch(for: entry.signature, in: catalog) {
                                scannedCount += 1
                                stage2MatchedCount += 1
                                currentUnmatched.remove(entry.track.id)

                                let isLocalAlbumValid = !MetadataSanitizer.isUnknownAlbum(entry.track.album) &&
                                    !entry.track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                let isLocalArtistValid = !MetadataSanitizer.isUnknownArtist(entry.track.artist) &&
                                    !entry.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                                let effectiveTrackNumber = (entry.track.trackNumber != nil && entry.track.trackNumber! > 0)
                                    ? entry.track.trackNumber
                                    : best.trackNumber

                                let effectiveBest = OnlineTrackMetadata(
                                    id: best.id,
                                    title: best.title,
                                    artist: isLocalArtistValid ? entry.track.artist : best.artist,
                                    album: isLocalAlbumValid ? entry.track.album : best.album,
                                    albumArtist: best.albumArtist,
                                    releaseDate: best.releaseDate,
                                    releaseYear: best.releaseYear ?? entry.track.year,
                                    genre: best.genre ?? entry.track.genre,
                                    trackNumber: effectiveTrackNumber,
                                    totalTracks: best.totalTracks ?? entry.track.totalTracks,
                                    discNumber: best.discNumber ?? entry.track.discNumber,
                                    duration: best.duration ?? entry.track.duration,
                                    artworkURL: best.artworkURL,
                                    previewURL: best.previewURL,
                                    sourceAPI: best.sourceAPI,
                                    isCompilation: best.isCompilation
                                )

                                let diff = MetadataDiff(
                                    localTrack: entry.track,
                                    onlineMetadata: effectiveBest,
                                    preserveLocalTitleAndArtist: true
                                )

                                let hasValidLocalYear = (entry.track.year ?? 0) >= 1900
                                if diff.fieldsEnrichedCount > 0 {
                                    diffsByID[entry.track.id] = diff
                                    goodByID.removeValue(forKey: entry.track.id)
                                } else if hasValidLocalYear {
                                    goodByID[entry.track.id] = diff
                                    diffsByID.removeValue(forKey: entry.track.id)
                                } else {
                                    diffsByID.removeValue(forKey: entry.track.id)
                                    goodByID.removeValue(forKey: entry.track.id)
                                    stage3Fallback.append(entry)
                                }
                            } else {
                                stage3Fallback.append(entry)
                            }
                        }
                    } else {
                        stage3Fallback.append(contentsOf: batch.entries)
                    }

                    emitProgress(statusMessage: "Analyzed \(scannedCount) of \(total) tracks")

                    if artistBatchIndex < sortedArtistLooseBatches.count && !Task.isCancelled {
                        await self.waitIfPaused()
                        let nextBatch = sortedArtistLooseBatches[artistBatchIndex]
                        artistBatchIndex += 1
                        group.addTask {
                            let nextCatalog = await fetchArtistCatalog(artist: nextBatch.artistName)
                            return (nextBatch, nextCatalog)
                        }
                    }
                }
            }

            if Task.isCancelled {
                let finalDiffs = Array(diffsByID.values)
                let finalGood = Array(goodByID.values)
                await self.persistScanState(diffs: finalDiffs, good: finalGood, unmatched: currentUnmatched, storageURL: storageDirectoryURL)
                await self.finish(diffs: finalDiffs, good: finalGood, unmatched: currentUnmatched, onComplete: onComplete)
                return
            }

            AppLogger.metadata.info("[Stage 2 Complete] Enriched \(stage2MatchedCount) tracks. \(stage3Fallback.count) tracks remaining for Stage 3.")

            // MARK: - STAGE 3: Song Fallback Search with Bounded Worker Pool
            if !stage3Fallback.isEmpty {
                let fallbackCount = stage3Fallback.count
                emitProgress(statusMessage: "Deep matching \(fallbackCount) remaining tracks...", force: true)

                let maxSongWorkers = 2
                var trackIndex = 0

                await withTaskGroup(of: (Track, OnlineTrackMetadata?).self) { group in
                    while trackIndex < fallbackCount && trackIndex < maxSongWorkers && !Task.isCancelled {
                        let entry = stage3Fallback[trackIndex]
                        trackIndex += 1
                        group.addTask {
                            let match = await MusicMetadataService.shared.findExactMatch(for: entry.track, source: source)
                            return (entry.track, match)
                        }
                    }

                    for await (track, match) in group {
                        await self.waitIfPaused()
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

                            let hasValidLocalYear = (track.year ?? 0) >= 1900
                            if diff.fieldsEnrichedCount > 0 {
                                diffsByID[track.id] = diff
                                goodByID.removeValue(forKey: track.id)
                                AppLogger.metadata.info("[Stage 3 Matched: Enriched] \"\(track.title)\" -> \"\(match.title)\" on \"\(effectiveMatch.album)\"")
                            } else if hasValidLocalYear {
                                goodByID[track.id] = diff
                                diffsByID.removeValue(forKey: track.id)
                            } else {
                                diffsByID.removeValue(forKey: track.id)
                                goodByID.removeValue(forKey: track.id)
                                currentUnmatched.insert(track.id)
                            }
                        } else {
                            diffsByID.removeValue(forKey: track.id)
                            goodByID.removeValue(forKey: track.id)
                            if MetadataSanitizer.hasAllSpotsFilled(track: track) {
                                let synth = MetadataSanitizer.synthesizeVerifiedMetadata(for: track)
                                let diff = MetadataDiff(localTrack: track, onlineMetadata: synth, preserveLocalTitleAndArtist: true)
                                goodByID[track.id] = diff
                                AppLogger.metadata.info("[Stage 3: Complete Local Track] \"\(track.title)\" has all spots filled locally. Moved to Looks Good.")
                            } else {
                                currentUnmatched.insert(track.id)
                            }
                        }

                        emitProgress(statusMessage: "Analyzing \"\(track.title)\" (\(scannedCount)/\(total))...")

                        if trackIndex < fallbackCount && !Task.isCancelled {
                            await self.waitIfPaused()
                            let nextEntry = stage3Fallback[trackIndex]
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
            let finalDiffs = Array(diffsByID.values)
            let finalGood = Array(goodByID.values)
            AppLogger.metadata.info("[Pipeline Completed] Scanned \(scannedCount)/\(total) tracks in \(formattedTime). Enriched: \(finalDiffs.count), Verified Good: \(finalGood.count), Unmatched: \(currentUnmatched.count).")

            // Persist scan results atomically
            await self.persistScanState(
                diffs: finalDiffs,
                good: finalGood,
                unmatched: currentUnmatched,
                storageURL: storageDirectoryURL
            )

            await self.finish(
                diffs: finalDiffs,
                good: finalGood,
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
