import Foundation

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
