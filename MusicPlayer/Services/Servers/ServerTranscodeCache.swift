import Foundation
import Observation
import os

/// Fully pre-fetches server-side transcodes (AAC 320 M4A) to local files before playback, so transcoded
/// tracks seek, EQ, pitch-shift and crossfade exactly like local files. Files are keyed by source and track ID,
/// kept in Caches (purgeable by the OS) and trimmed oldest-first beyond `maxCacheBytes`.
actor ServerTranscodeCache {
    static let shared = ServerTranscodeCache()

    private let maxCacheBytes: Int64 = 1_073_741_824 // 1 GB
    private var inFlight: [UUID: Task<URL, Error>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 90   // servers may take a while to start emitting a transcode
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config.blockingRequestsWhileOffline())
    }()

    nonisolated private static var rootDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerTranscodes", isDirectory: true)
    }

    /// Containers a server transcode can come back as (Jellyfin/Plex MP4, Navidrome ADTS AAC, MP3 fallback).
    nonisolated private static let transcodeExtensions = ["m4a", "aac", "mp3"]

    nonisolated private static func directory(sourceID: UUID) -> URL {
        rootDirectory.appendingPathComponent(sourceID.uuidString, isDirectory: true)
    }

    /// Local transcoded file for a track if fully fetched. Cheap and synchronous (used while building player items).
    nonisolated static func cachedFileURL(for track: Track) -> URL? {
        guard let sourceID = track.folderID else { return nil }
        let dir = directory(sourceID: sourceID)
        for ext in transcodeExtensions {
            let url = dir.appendingPathComponent("\(track.id.uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Returns the local transcoded file, downloading it completely first if needed. Requests are tried in order
    /// (AAC first, then the provider's MP3 fallback). Concurrent callers share one fetch.
    func ensureLocal(track: Track, requests: [URLRequest]) async throws -> URL {
        if let cached = Self.cachedFileURL(for: track) { return cached }
        if let running = inFlight[track.id] { return try await running.value }
        guard let sourceID = track.folderID, !requests.isEmpty else { throw URLError(.fileDoesNotExist) }

        let dir = Self.directory(sourceID: sourceID)
        let trackID = track.id
        let session = self.session
        let task = Task<URL, Error> {
            var lastError: Error = URLError(.badServerResponse)
            for request in requests {
                do {
                    let (tempURL, response) = try await session.download(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        try? FileManager.default.removeItem(at: tempURL)
                        throw ServerHTTPError.status((response as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    // Name the file by its real container so AVFoundation picks the right parser.
                    let ext = JellyfinDownloadManager.detectAudioExtension(for: tempURL, preferred: TranscodePolicy.transcodedFileExtension)
                    let finalExt = Self.transcodeExtensions.contains(ext) ? ext : TranscodePolicy.transcodedFileExtension
                    let destination = dir.appendingPathComponent("\(trackID.uuidString).\(finalExt)")
                    let fm = FileManager.default
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: tempURL, to: destination)
                    return destination
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
        inFlight[track.id] = task
        defer { inFlight[track.id] = nil }
        let url = try await task.value
        trimIfNeeded()
        return url
    }

    /// Starts a background pre-fetch (next-track prefetch). Errors are ignored; playback retries on demand.
    func prefetch(track: Track, requests: [URLRequest]) {
        guard Self.cachedFileURL(for: track) == nil, inFlight[track.id] == nil else { return }
        Task { _ = try? await self.ensureLocal(track: track, requests: requests) }
    }

    /// Removes every cached transcode for a source (source removal).
    func removeAll(for sourceID: UUID) {
        try? FileManager.default.removeItem(at: Self.directory(sourceID: sourceID))
    }

    private func trimIfNeeded() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: Self.rootDirectory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > maxCacheBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maxCacheBytes {
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// Main-actor mirror of the finished CACHE IN ADVANCE session files, observed by the queue's cached icon.
@Observable
@MainActor
final class SessionCacheStatus {
    static let shared = SessionCacheStatus()
    private(set) var cachedTrackIDs: Set<UUID> = []
    @ObservationIgnored private var version = 0

    /// Applies a snapshot; older snapshots that arrive late are ignored.
    func apply(_ ids: Set<UUID>, version: Int) {
        guard version > self.version else { return }
        self.version = version
        if ids != cachedTrackIDs { cachedTrackIDs = ids }
    }
}

/// CACHE IN ADVANCE: session-only copies of upcoming streamed (native-format) server tracks, fetched whole with
/// URLSession download tasks into tmp/SessionStreamCache/<sourceID>/<trackID>.<ext>. Not a download: there is no
/// persistent index, nothing here is ever reported as downloaded, and the folder is wiped every launch.
actor SessionStreamCache {
    static let shared = SessionStreamCache()

    nonisolated enum Job: Sendable {
        case stream(trackID: UUID, sourceID: UUID, request: URLRequest, preferredExtension: String?)
        case transcode(track: Track, requests: [URLRequest])

        var trackID: UUID {
            switch self {
            case let .stream(trackID, _, _, _): return trackID
            case let .transcode(track, _): return track.id
            }
        }
    }

    /// In-memory index of finished session files (read synchronously while building player items).
    nonisolated private static let index = OSAllocatedUnfairLock<[UUID: URL]>(initialState: [:])
    /// Stop fetching when the device is this close to full.
    nonisolated private static let minimumFreeBytes: Int64 = 1_073_741_824

    private var pending: [Job] = []
    private var keepIDs: Set<UUID> = []
    private var inFlightID: UUID?
    private var worker: Task<Void, Never>?
    private var workerGeneration = 0
    private var onStored: (@Sendable (UUID) -> Void)?
    private var publishVersion = 0

    /// Sends the current set of finished session files to the main-actor status mirror.
    private func publish() {
        publishVersion += 1
        let version = publishVersion
        let ids = Self.index.withLock { Set($0.keys) }
        Task { @MainActor in SessionCacheStatus.shared.apply(ids, version: version) }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true          // allowed regardless of DOWNLOAD OVER CELLULAR
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config.blockingRequestsWhileOffline())
    }()

    nonisolated private static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SessionStreamCache", isDirectory: true)
    }

    nonisolated private static func directory(sourceID: UUID) -> URL {
        rootDirectory.appendingPathComponent(sourceID.uuidString, isDirectory: true)
    }

    /// Finished session file for a track, or nil. Cheap and synchronous.
    nonisolated static func cachedFileURL(for track: Track) -> URL? {
        guard let url = index.withLock({ $0[track.id] }) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        index.withLock { _ = $0.removeValue(forKey: track.id) }
        return nil
    }

    /// Replaces the wanted set: evicts files outside `keep`, cancels an in-flight fetch that is no longer wanted,
    /// and fetches `jobs` in order (nearest first), one at a time.
    func sync(keep: Set<UUID>, jobs: [Job], onStored: @escaping @Sendable (UUID) -> Void) {
        keepIDs = keep
        self.onStored = onStored
        let stale = Self.index.withLock { (idx: inout [UUID: URL]) -> [URL] in
            let ids = idx.keys.filter { !keep.contains($0) }
            return ids.compactMap { idx.removeValue(forKey: $0) }
        }
        for url in stale { try? FileManager.default.removeItem(at: url) }
        if !stale.isEmpty { publish() }

        pending = jobs
        if let inFlight = inFlightID, !jobs.contains(where: { $0.trackID == inFlight }) {
            cancelWorker()
        }
        if worker == nil, !pending.isEmpty { startWorker() }
    }

    /// Removes every session file (launch, toggle off, stop and clear).
    func removeAll() {
        cancelWorker()
        pending = []
        keepIDs = []
        Self.index.withLock { $0.removeAll() }
        try? FileManager.default.removeItem(at: Self.rootDirectory)
        publish()
    }

    /// Removes the session files of one source (source removal).
    func removeAll(for sourceID: UUID) {
        let dirPath = Self.directory(sourceID: sourceID).path
        Self.index.withLock { idx in
            for (key, url) in idx where url.path.hasPrefix(dirPath) { idx.removeValue(forKey: key) }
        }
        try? FileManager.default.removeItem(at: Self.directory(sourceID: sourceID))
        publish()
    }

    private func cancelWorker() {
        worker?.cancel()
        worker = nil
        inFlightID = nil
        workerGeneration += 1
    }

    private func startWorker() {
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { await self.runWorker(generation: generation) }
    }

    private func nextJob() -> Job? {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            switch job {
            case let .stream(trackID, _, _, _):
                if Self.index.withLock({ $0[trackID] }) == nil { return job }
            case let .transcode(track, _):
                if ServerTranscodeCache.cachedFileURL(for: track) == nil { return job }
            }
        }
        return nil
    }

    private func runWorker(generation: Int) async {
        defer {
            if workerGeneration == generation {
                worker = nil
                inFlightID = nil
            }
        }
        while !Task.isCancelled, workerGeneration == generation, let job = nextJob() {
            guard Self.hasFreeSpace() else { return }
            inFlightID = job.trackID
            switch job {
            case let .stream(trackID, sourceID, request, preferredExtension):
                guard let url = await Self.download(request, session: session, trackID: trackID,
                                                    sourceID: sourceID, preferredExtension: preferredExtension) else { continue }
                // Superseded while downloading: keep the file only if it is still wanted.
                guard !Task.isCancelled, keepIDs.contains(trackID) else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                Self.index.withLock { $0[trackID] = url }
                publish()
                onStored?(trackID)
            case let .transcode(track, requests):
                _ = try? await ServerTranscodeCache.shared.ensureLocal(track: track, requests: requests)
            }
        }
    }

    nonisolated private static func hasFreeSpace() -> Bool {
        let url = FileManager.default.temporaryDirectory
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return true }
        return free > minimumFreeBytes
    }

    /// Downloads the whole file to disk (cancelled with the calling task) and moves it into the session folder.
    nonisolated private static func download(_ request: URLRequest, session: URLSession, trackID: UUID,
                                             sourceID: UUID, preferredExtension: String?) async -> URL? {
        do {
            let (tempURL, response) = try await session.download(for: request)
            let fm = FileManager.default
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !Task.isCancelled else {
                try? fm.removeItem(at: tempURL)
                return nil
            }
            let ext = JellyfinDownloadManager.detectAudioExtension(for: tempURL, preferred: preferredExtension)
            let dir = directory(sourceID: sourceID)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent("\(trackID.uuidString).\(ext)")
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: tempURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
