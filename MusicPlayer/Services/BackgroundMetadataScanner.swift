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
                // 1. Check if we already have downloaded online metadata in persistent cache
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
                } else if MetadataSanitizer.isFullyTagged(track: track) {
                    // 2. Synthesize complete tags for fully-tagged songs
                    let synth = MetadataSanitizer.synthesizeVerifiedMetadata(for: track)
                    let diff = MetadataDiff(localTrack: track, onlineMetadata: synth, preserveLocalTitleAndArtist: true)
                    currentGood.removeAll { $0.id == track.id }
                    currentDiffs.removeAll { $0.id == track.id }
                    currentGood.append(diff)
                    currentUnmatched.remove(track.id)
                    scannedCount += 1
                    preCheckedGoodCount += 1
                } else {
                    tracksNeedingOnlineCheck.append(track)
                }
            }

            AppLogger.metadata.info("[Stage 0: Instant Pre-Check] Resolved \(preCheckedCachedCount) from persistent cache, \(preCheckedGoodCount) complete tracks locally. \(tracksNeedingOnlineCheck.count) tracks require online lookup.")
            emitProgress(statusMessage: "Checked cache (\(preCheckedCachedCount) cached, \(preCheckedGoodCount) complete)...")

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
                // Sig
                let sig = MetadataSanitizer.sanitize(track: $0)
                AppLogger.metadata.debug("[Signature Extracted] \"\($0.title)\" -> Core: \"\(sig.coreTitle)\", Artist: \"\(sig.primaryArtist)\", Album: \"\(sig.standardAlbum)\"")
                return ($0, sig)
            }

            // MARK: - STAGE 1: Artist-First Concurrent Batch Matching (1 Request = Up to 200 Discography Songs)
            var artistGroups: [String: (artist: String, entries: [(track: Track, signature: TrackSignature)])] = [:]
            // Unknown artist entries
            var unknownArtistEntries: [(track: Track, signature: TrackSignature)] = []

            for entry in trackSignatures {
                // Sig
                let sig = entry.signature
                if !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) {
                    // Key
                    let key = sig.primaryArtist.lowercased()
                    if var existing = artistGroups[key] {
                        existing.entries.append(entry)
                        artistGroups[key] = existing
                    } else {
                        artistGroups[key] = (artist: sig.primaryArtist, entries: [entry])
                    }
                } else {
                    unknownArtistEntries.append(entry)
                }
            }

            print("[Metadata Scanner Stage 1] Grouped \(artistGroups.count) distinct artists covering \(trackSignatures.count - unknownArtistEntries.count) tracks.")
            AppLogger.metadata.info("[Stage 1: Artist-First Batch] Grouped \(artistGroups.count) distinct artists covering \(trackSignatures.count - unknownArtistEntries.count) tracks.")
            // Remaining for fallback
            var remainingForFallback: [(track: Track, signature: TrackSignature)] = unknownArtistEntries
            // Stage 1 matched count
            var stage1MatchedCount = 0

            // Artist group list
            let artistGroupList = Array(artistGroups.values)
            // Max artist workers
            let maxArtistWorkers = min(2, max(1, artistGroupList.count))
            // Artist group index
            var artistGroupIndex = 0

            // Fetch artist with retry
            func fetchArtistWithRetry(artist: String) async -> [OnlineTrackMetadata]? {
                for attempt in 1...3 {
                    if Task.isCancelled { return nil }
                    if let songs = await MusicMetadataService.shared.searchArtistSongs(artist: artist) {
                        return songs
                    }
                    if attempt < 3 && !Task.isCancelled {
                        print("[Stage 1 Retry] Retrying artist \"\(artist)\" (attempt \(attempt + 1) of 3)...")
                        emitProgress(statusMessage: "Retrying search for \"\(artist)\" (attempt \(attempt + 1) of 3)...", force: true)
                        // Sleep ns
                        let sleepNs = UInt64(Double(attempt) * 1.5 * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: sleepNs)
                    }
                }
                return nil
            }

            await withTaskGroup(of: ([(track: Track, signature: TrackSignature)], [OnlineTrackMetadata]?).self) { group in
                while artistGroupIndex < artistGroupList.count && artistGroupIndex < maxArtistWorkers {
                    // Artist entry
                    let artistEntry = artistGroupList[artistGroupIndex]
                    artistGroupIndex += 1
                    group.addTask {
                        // Artist songs
                        let artistSongs = await fetchArtistWithRetry(artist: artistEntry.artist)
                        return (artistEntry.entries, artistSongs)
                    }
                }

                for await (entries, artistSongs) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    // Available songs
                    let availableSongs = artistSongs ?? []
                    for entry in entries {
                        if let best = DisambiguationMatcher.bestMatch(for: entry.signature, in: availableSongs) {
                            scannedCount += 1
                            stage1MatchedCount += 1
                            currentUnmatched.remove(entry.track.id)

                            // Diff
                            let diff = MetadataDiff(
                                localTrack: entry.track,
                                onlineMetadata: best,
                                preserveLocalTitleAndArtist: true
                            )

                            if diff.fieldsEnrichedCount > 0 {
                                currentGood.removeAll { $0.id == entry.track.id }
                                currentDiffs.removeAll { $0.id == entry.track.id }
                                currentDiffs.append(diff)
                                print("[Stage 1 Matched: Enriched] \"\(entry.track.title)\" -> \"\(best.title)\" on \"\(best.album)\" (\(best.releaseYear ?? 0))")
                                AppLogger.metadata.info("[Stage 1 Matched: Enriched] \"\(entry.track.title)\" matched \"\(best.title)\" on \"\(best.album)\" (\(best.releaseYear ?? 0)).")
                            } else {
                                currentDiffs.removeAll { $0.id == entry.track.id }
                                currentGood.removeAll { $0.id == entry.track.id }
                                currentGood.append(diff)
                            }
                        } else {
                            remainingForFallback.append(entry)
                        }
                    }

                    emitProgress(statusMessage: "Analyzed \(scannedCount) of \(total) tracks")

                    if artistGroupIndex < artistGroupList.count && !Task.isCancelled {
                        // Next artist entry
                        let nextArtistEntry = artistGroupList[artistGroupIndex]
                        artistGroupIndex += 1
                        group.addTask {
                            // Next artist songs
                            let nextArtistSongs = await fetchArtistWithRetry(artist: nextArtistEntry.artist)
                            return (nextArtistEntry.entries, nextArtistSongs)
                        }
                    }
                }
            }

            print("[Stage 1 Completed] Matched \(stage1MatchedCount) tracks. Remaining for Stage 2: \(remainingForFallback.count).")
            AppLogger.metadata.info("[Stage 1 Completed] Matched \(stage1MatchedCount) tracks. Remaining for Stage 2 album batching: \(remainingForFallback.count).")

            // MARK: - STAGE 2: Multi-Track Album Batch Matching (1 Request = Complete Album Cuts)
            var remainingForStage3: [(track: Track, signature: TrackSignature)] = []
            // Stage 2 matched count
            var stage2MatchedCount = 0

            // Fetch album with retry
            func fetchAlbumWithRetry(album: String, artist: String) async -> [OnlineTrackMetadata]? {
                for attempt in 1...3 {
                    if Task.isCancelled { return nil }
                    if let songs = await MusicMetadataService.shared.searchAlbumSongs(album: album, artist: artist) {
                        return songs
                    }
                    if attempt < 3 && !Task.isCancelled {
                        print("[Stage 2 Retry] Retrying album \"\(album)\" (attempt \(attempt + 1) of 3)...")
                        emitProgress(statusMessage: "Retrying search for \"\(album)\" (attempt \(attempt + 1) of 3)...", force: true)
                        // Sleep ns
                        let sleepNs = UInt64(Double(attempt) * 1.5 * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: sleepNs)
                    }
                }
                return nil
            }

            if !remainingForFallback.isEmpty && !Task.isCancelled {
                // Album groups
                var albumGroups: [String: (artist: String, album: String, entries: [(track: Track, signature: TrackSignature)])] = [:]

                for entry in remainingForFallback {
                    // Sig
                    let sig = entry.signature
                    if !MetadataSanitizer.isUnknownAlbum(sig.standardAlbum) && !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) {
                        // Group key
                        let groupKey = "\(sig.primaryArtist.lowercased())__\(sig.standardAlbum.lowercased())"
                        if var existing = albumGroups[groupKey] {
                            existing.entries.append(entry)
                            albumGroups[groupKey] = existing
                        } else {
                            albumGroups[groupKey] = (artist: sig.primaryArtist, album: sig.standardAlbum, entries: [entry])
                        }
                    } else {
                        remainingForStage3.append(entry)
                    }
                }

                AppLogger.metadata.info("[Stage 2: Album Batch] Grouped \(albumGroups.count) distinct albums covering \(remainingForFallback.count - remainingForStage3.count) tracks.")

                // Album group list
                let albumGroupList = Array(albumGroups.values)
                // Max album workers
                let maxAlbumWorkers = min(2, max(1, albumGroupList.count))
                // Album group index
                var albumGroupIndex = 0

                await withTaskGroup(of: ([(track: Track, signature: TrackSignature)], [OnlineTrackMetadata]?).self) { group in
                    while albumGroupIndex < albumGroupList.count && albumGroupIndex < maxAlbumWorkers {
                        // Album entry
                        let albumEntry = albumGroupList[albumGroupIndex]
                        albumGroupIndex += 1
                        group.addTask {
                            // Album songs
                            let albumSongs = await fetchAlbumWithRetry(album: albumEntry.album, artist: albumEntry.artist)
                            return (albumEntry.entries, albumSongs)
                        }
                    }

                    for await (entries, albumSongs) in group {
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }

                        // Available songs
                        let availableSongs = albumSongs ?? []
                        for entry in entries {
                            if let best = DisambiguationMatcher.bestMatch(for: entry.signature, in: availableSongs) {
                                scannedCount += 1
                                stage2MatchedCount += 1
                                currentUnmatched.remove(entry.track.id)

                                // Diff
                                let diff = MetadataDiff(
                                    localTrack: entry.track,
                                    onlineMetadata: best,
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

                        emitProgress(statusMessage: "Analyzed \(scannedCount) of \(total) tracks")

                        if albumGroupIndex < albumGroupList.count && !Task.isCancelled {
                            // Next album entry
                            let nextAlbumEntry = albumGroupList[albumGroupIndex]
                            albumGroupIndex += 1
                            group.addTask {
                                // Next album songs
                                let nextAlbumSongs = await fetchAlbumWithRetry(album: nextAlbumEntry.album, artist: nextAlbumEntry.artist)
                                return (nextAlbumEntry.entries, nextAlbumSongs)
                            }
                        }
                    }
                }
            }

            print("[Stage 2 Completed] Matched \(stage2MatchedCount) tracks. Remaining for Stage 3 individual fallback: \(remainingForStage3.count).")
            AppLogger.metadata.info("[Stage 2 Completed] Matched \(stage2MatchedCount) tracks. Remaining for Stage 3 individual fallback: \(remainingForStage3.count).")

            // MARK: - STAGE 3: Concurrent Individual Fallback for Orphan / Loose Tracks
            if !remainingForStage3.isEmpty && !Task.isCancelled {
                print("[Metadata Scanner Stage 3] Querying \(remainingForStage3.count) remaining loose tracks across worker pool...")
                AppLogger.metadata.info("[Stage 3: Individual Fallback] Querying \(remainingForStage3.count) remaining loose tracks across worker pool...")

                // Max workers
                let maxWorkers = 2
                // Track index
                var trackIndex = 0
                // Fallback count
                let fallbackCount = remainingForStage3.count

                await withTaskGroup(of: (Track, OnlineTrackMetadata?).self) { group in
                    while trackIndex < fallbackCount && trackIndex < maxWorkers {
                        // Entry
                        let entry = remainingForStage3[trackIndex]
                        trackIndex += 1
                        group.addTask {
                            // Match
                            let match = await MusicMetadataService.shared.findExactMatch(for: entry.track)
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
                            // Diff
                            let diff = MetadataDiff(
                                localTrack: track,
                                onlineMetadata: match,
                                preserveLocalTitleAndArtist: true
                            )

                            if diff.fieldsEnrichedCount > 0 {
                                currentGood.removeAll { $0.id == track.id }
                                currentDiffs.removeAll { $0.id == track.id }
                                currentDiffs.append(diff)
                                print("[Stage 3 Matched: Enriched] \"\(track.title)\" -> \"\(match.title)\" on \"\(match.album)\"")
                            } else {
                                currentDiffs.removeAll { $0.id == track.id }
                                currentGood.removeAll { $0.id == track.id }
                                currentGood.append(diff)
                            }
                        } else {
                            currentDiffs.removeAll { $0.id == track.id }
                            currentGood.removeAll { $0.id == track.id }
                            currentUnmatched.insert(track.id)
                        }

                        emitProgress(statusMessage: "Analyzing \"\(track.title)\" (\(scannedCount)/\(total))...")

                        if trackIndex < fallbackCount && !Task.isCancelled {
                            // Next entry
                            let nextEntry = remainingForStage3[trackIndex]
                            trackIndex += 1
                            group.addTask {
                                // Next match
                                let nextMatch = await MusicMetadataService.shared.findExactMatch(for: nextEntry.track)
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
            print("[Metadata Pipeline Completed] Scanned \(scannedCount)/\(total) tracks in \(formattedTime). Enriched: \(currentDiffs.count), Verified Good: \(currentGood.count), Unmatched: \(currentUnmatched.count).")
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
