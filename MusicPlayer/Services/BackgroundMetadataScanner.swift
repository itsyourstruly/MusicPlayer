//
//  BackgroundMetadataScanner.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation
import os

/// Lightweight data structure representing scan progress and live category tallies.
public struct MetadataScanProgress: Sendable {
    public let progress: Double
    public let scannedCount: Int
    public let totalCount: Int
    public let statusText: String
    public let enrichmentDiffs: [MetadataDiff]
    public let verifiedGoodDiffs: [MetadataDiff]
    public let unmatchedTrackIDs: Set<UUID>
}

/// Final scan payload delivered off the background queue.
public struct MetadataScanResult: Sendable {
    public let enrichmentDiffs: [MetadataDiff]
    public let verifiedGoodDiffs: [MetadataDiff]
    public let unmatchedTrackIDs: Set<UUID>
}

/// Dedicated, actor-isolated background worker implementing the 3-Tier Hierarchical Batch Reduction Pipeline.
/// Tier 1: Concurrent Artist-level grouping (limit 200) -> Tier 2: Concurrent Album-level grouping (limit 200) -> Tier 3: Targeted concurrent fallback.
public actor BackgroundMetadataScanner {
    public static let shared = BackgroundMetadataScanner()

    private var activeTask: Task<Void, Never>? = nil
    private var isRunning: Bool = false

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

        guard !tracks.isEmpty else {
            onComplete(MetadataScanResult(enrichmentDiffs: [], verifiedGoodDiffs: [], unmatchedTrackIDs: []))
            return
        }

        isRunning = true

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let scanStartTime = Date()

            if forceRecheck {
                await MusicMetadataService.shared.clearCache()
            }

            let existingDiffIDs = existingDiffs.map { $0.localTrack.id }
            let existingGoodIDs = existingGood.map { $0.localTrack.id }
            let processedIDs = Set(existingDiffIDs + existingGoodIDs).union(existingUnmatched)

            let tracksToScan: [Track]
            if forceRecheck {
                tracksToScan = tracks
            } else {
                tracksToScan = tracks.filter { !processedIDs.contains($0.id) }
            }

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

            var currentDiffs = forceRecheck ? [MetadataDiff]() : existingDiffs
            var currentGood = forceRecheck ? [MetadataDiff]() : existingGood
            var currentUnmatched = forceRecheck ? Set<UUID>() : existingUnmatched

            let total = tracksToScan.count
            var scannedCount = 0
            var lastProgressReportTime = Date.distantPast

            // Helper to report progress safely without overwhelming main actor
            func emitProgress(statusMessage: String, force: Bool = false) {
                let now = Date()
                if force || now.timeIntervalSince(lastProgressReportTime) >= 0.08 || scannedCount >= total {
                    lastProgressReportTime = now
                    let progress = total > 0 ? min(1.0, Double(scannedCount) / Double(total)) : 1.0

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

            // MARK: - STAGE 0: Instant Completeness Pre-Check (Zero Network Cost)
            var tracksNeedingOnlineCheck: [Track] = []
            var preCheckedGoodCount = 0

            for track in tracksToScan {
                if MetadataSanitizer.isFullyTagged(track: track) {
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

            AppLogger.metadata.info("[Stage 0: Instant Pre-Check] Verified \(preCheckedGoodCount) tracks locally with zero network requests. \(tracksNeedingOnlineCheck.count) tracks require online lookup.")
            emitProgress(statusMessage: "Verified \(preCheckedGoodCount) complete tracks locally...")

            guard !tracksNeedingOnlineCheck.isEmpty && !Task.isCancelled else {
                emitProgress(statusMessage: "Library analysis complete.", force: true)
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

            // MARK: - STAGE 1: Artist-First Concurrent Batch Matching (1 Request = Up to 200 Discography Songs)
            var artistGroups: [String: (artist: String, entries: [(track: Track, signature: TrackSignature)])] = [:]
            var unknownArtistEntries: [(track: Track, signature: TrackSignature)] = []

            for entry in trackSignatures {
                let sig = entry.signature
                if !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) {
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
            var remainingForFallback: [(track: Track, signature: TrackSignature)] = unknownArtistEntries
            var stage1MatchedCount = 0

            let artistGroupList = Array(artistGroups.values)
            let maxArtistWorkers = min(2, max(1, artistGroupList.count))
            var artistGroupIndex = 0

            func fetchArtistWithRetry(artist: String) async -> [OnlineTrackMetadata]? {
                for attempt in 1...3 {
                    if Task.isCancelled { return nil }
                    if let songs = await MusicMetadataService.shared.searchArtistSongs(artist: artist) {
                        return songs
                    }
                    if attempt < 3 && !Task.isCancelled {
                        print("[Stage 1 Retry] Retrying artist \"\(artist)\" (attempt \(attempt + 1) of 3)...")
                        emitProgress(statusMessage: "Retrying search for \"\(artist)\" (attempt \(attempt + 1) of 3)...", force: true)
                        let sleepNs = UInt64(Double(attempt) * 1.5 * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: sleepNs)
                    }
                }
                return nil
            }

            await withTaskGroup(of: ([(track: Track, signature: TrackSignature)], [OnlineTrackMetadata]?).self) { group in
                while artistGroupIndex < artistGroupList.count && artistGroupIndex < maxArtistWorkers {
                    let artistEntry = artistGroupList[artistGroupIndex]
                    artistGroupIndex += 1
                    group.addTask {
                        let artistSongs = await fetchArtistWithRetry(artist: artistEntry.artist)
                        return (artistEntry.entries, artistSongs)
                    }
                }

                for await (entries, artistSongs) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    let availableSongs = artistSongs ?? []
                    for entry in entries {
                        if let best = DisambiguationMatcher.bestMatch(for: entry.signature, in: availableSongs) {
                            scannedCount += 1
                            stage1MatchedCount += 1
                            currentUnmatched.remove(entry.track.id)

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
                        let nextArtistEntry = artistGroupList[artistGroupIndex]
                        artistGroupIndex += 1
                        group.addTask {
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
            var stage2MatchedCount = 0

            func fetchAlbumWithRetry(album: String, artist: String) async -> [OnlineTrackMetadata]? {
                for attempt in 1...3 {
                    if Task.isCancelled { return nil }
                    if let songs = await MusicMetadataService.shared.searchAlbumSongs(album: album, artist: artist) {
                        return songs
                    }
                    if attempt < 3 && !Task.isCancelled {
                        print("[Stage 2 Retry] Retrying album \"\(album)\" (attempt \(attempt + 1) of 3)...")
                        emitProgress(statusMessage: "Retrying search for \"\(album)\" (attempt \(attempt + 1) of 3)...", force: true)
                        let sleepNs = UInt64(Double(attempt) * 1.5 * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: sleepNs)
                    }
                }
                return nil
            }

            if !remainingForFallback.isEmpty && !Task.isCancelled {
                var albumGroups: [String: (artist: String, album: String, entries: [(track: Track, signature: TrackSignature)])] = [:]

                for entry in remainingForFallback {
                    let sig = entry.signature
                    if !MetadataSanitizer.isUnknownAlbum(sig.standardAlbum) && !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) {
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

                let albumGroupList = Array(albumGroups.values)
                let maxAlbumWorkers = min(2, max(1, albumGroupList.count))
                var albumGroupIndex = 0

                await withTaskGroup(of: ([(track: Track, signature: TrackSignature)], [OnlineTrackMetadata]?).self) { group in
                    while albumGroupIndex < albumGroupList.count && albumGroupIndex < maxAlbumWorkers {
                        let albumEntry = albumGroupList[albumGroupIndex]
                        albumGroupIndex += 1
                        group.addTask {
                            let albumSongs = await fetchAlbumWithRetry(album: albumEntry.album, artist: albumEntry.artist)
                            return (albumEntry.entries, albumSongs)
                        }
                    }

                    for await (entries, albumSongs) in group {
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }

                        let availableSongs = albumSongs ?? []
                        for entry in entries {
                            if let best = DisambiguationMatcher.bestMatch(for: entry.signature, in: availableSongs) {
                                scannedCount += 1
                                stage2MatchedCount += 1
                                currentUnmatched.remove(entry.track.id)

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
                            let nextAlbumEntry = albumGroupList[albumGroupIndex]
                            albumGroupIndex += 1
                            group.addTask {
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

                let maxWorkers = 2
                var trackIndex = 0
                let fallbackCount = remainingForStage3.count

                await withTaskGroup(of: (Track, OnlineTrackMetadata?).self) { group in
                    while trackIndex < fallbackCount && trackIndex < maxWorkers {
                        let entry = remainingForStage3[trackIndex]
                        trackIndex += 1
                        group.addTask {
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
                            let nextEntry = remainingForStage3[trackIndex]
                            trackIndex += 1
                            group.addTask {
                                let nextMatch = await MusicMetadataService.shared.findExactMatch(for: nextEntry.track)
                                return (nextEntry.track, nextMatch)
                            }
                        }
                    }
                }
            }

            emitProgress(statusMessage: "Library analysis complete.", force: true)

            let elapsedSeconds = Date().timeIntervalSince(scanStartTime)
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

    private func finish(
        diffs: [MetadataDiff],
        good: [MetadataDiff],
        unmatched: Set<UUID>,
        onComplete: @escaping @Sendable (MetadataScanResult) -> Void
    ) {
        isRunning = false
        activeTask = nil
        let payload = MetadataScanResult(
            enrichmentDiffs: diffs,
            verifiedGoodDiffs: good,
            unmatchedTrackIDs: unmatched
        )
        onComplete(payload)
    }

    private func persistScanState(
        diffs: [MetadataDiff],
        good: [MetadataDiff],
        unmatched: Set<UUID>,
        storageURL: URL
    ) {
        let enrichmentFileURL = storageURL.appendingPathComponent("enrichment_diffs.json")
        let verifiedGoodFileURL = storageURL.appendingPathComponent("verified_good_diffs.json")
        let unmatchedFileURL = storageURL.appendingPathComponent("unmatched_tracks.json")

        do {
            let diffData = try JSONEncoder().encode(diffs)
            try diffData.write(to: enrichmentFileURL, options: .atomic)

            let goodData = try JSONEncoder().encode(good)
            try goodData.write(to: verifiedGoodFileURL, options: .atomic)

            let unmatchedData = try JSONEncoder().encode(Array(unmatched))
            try unmatchedData.write(to: unmatchedFileURL, options: .atomic)
            AppLogger.storage.info("[Persistence] Saved \(diffs.count) enrichment diffs, \(good.count) verified good, \(unmatched.count) unmatched to disk.")
        } catch {
            AppLogger.storage.error("[Persistence Failed] Background scanner failed to persist state: \(error.localizedDescription)")
        }
    }
}
