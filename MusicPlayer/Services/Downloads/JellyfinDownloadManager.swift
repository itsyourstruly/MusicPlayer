import Foundation
import SwiftUI
import Observation

// MARK: - DownloadedTrackRecord

public struct DownloadedTrackRecord: Codable, Sendable, Identifiable {
    public var id: UUID { trackId }
    public let trackId: UUID
    public let serverId: UUID
    public let localFileName: String
    public let fileSizeBytes: Int64
    public let dateDownloaded: Date
    public let originalURLString: String
    public let trackTitle: String
    public let artistName: String
    public let albumTitle: String

    public init(
        trackId: UUID,
        serverId: UUID,
        localFileName: String,
        fileSizeBytes: Int64,
        dateDownloaded: Date = Date(),
        originalURLString: String,
        trackTitle: String,
        artistName: String,
        albumTitle: String
    ) {
        self.trackId = trackId
        self.serverId = serverId
        self.localFileName = localFileName
        self.fileSizeBytes = fileSizeBytes
        self.dateDownloaded = dateDownloaded
        self.originalURLString = originalURLString
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
    }
}

// MARK: - JellyfinDownloadState

public enum JellyfinDownloadState: Equatable, Sendable {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case downloaded
    case failed(String)

    public var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    public var isDownloading: Bool {
        switch self {
        case .downloading, .queued: return true
        default: return false
        }
    }
}

// MARK: - Download Progress Throttler

/// Thread-safe nonisolated tracker that throttles high-frequency URLSession download updates.
private final class DownloadProgressThrottler: @unchecked Sendable {
    static let shared = DownloadProgressThrottler()
    private let lock = NSLock()
    private var lastReported: [Int: (timestamp: TimeInterval, progress: Double)] = [:]

    func shouldDispatch(taskID: Int, progress: Double, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastReported[taskID] {
            if (now - last.timestamp >= 0.1) || abs(progress - last.progress) >= 0.02 || progress >= 1.0 {
                lastReported[taskID] = (now, progress)
                return true
            }
            return false
        } else {
            lastReported[taskID] = (now, progress)
            return true
        }
    }

    func remove(taskID: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastReported.removeValue(forKey: taskID)
    }
}

// MARK: - JellyfinDownloadManager

/// Dedicated background-capable downloader and disk cache manager for remote Jellyfin tracks.
/// Preserves deterministic Track UUIDs, tracks download progress, and stores files permanently in Application Support.
@MainActor
@Observable
public final class JellyfinDownloadManager: NSObject, @unchecked Sendable {

    public static let shared = JellyfinDownloadManager()

    // MARK: - Observable State

    public private(set) var downloadStates: [UUID: JellyfinDownloadState] = [:]
    public private(set) var downloadProgress: [UUID: Double] = [:]
    public private(set) var downloadRecords: [UUID: DownloadedTrackRecord] = [:]
    public private(set) var totalDownloadedBytes: Int64 = 0

    public var allowsCellularAccess: Bool = true {
        didSet {
            guard oldValue != allowsCellularAccess else { return }
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 300
            config.allowsCellularAccess = allowsCellularAccess
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 4
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        }
    }

    // MARK: - Private State

    private let fileManager = FileManager.default
    public nonisolated let downloadsDirectoryURL: URL
    private let indexFileURL: URL

    private var cachedTokensByServerID: [UUID: String] = [:]

    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    private var downloadQueue: [(track: Track, server: JellyfinServerLink)] = []
    private var taskToTrackID: [Int: UUID] = [:]
    private var taskToTrack: [Int: Track] = [:]
    private var taskToServer: [Int: JellyfinServerLink] = [:]
    private let maxConcurrentDownloads = 3

    private var session: URLSession!

    // MARK: - Init

    private override init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("JellyfinDownloads", isDirectory: true)
        self.downloadsDirectoryURL = dir
        self.indexFileURL = dir.appendingPathComponent("downloads.json")

        super.init()

        // Create storage directory if missing
        try? fileManager.createDirectory(at: downloadsDirectoryURL, withIntermediateDirectories: true)

        // Session setup
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 300
        config.allowsCellularAccess = allowsCellularAccess
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)

        loadIndex()
    }

    // MARK: - Index Persistence & Self-Healing

    private func loadIndex() {
        var validRecords: [UUID: DownloadedTrackRecord] = [:]
        var totalBytes: Int64 = 0
        var didHeal = false

        if fileManager.fileExists(atPath: indexFileURL.path),
           let data = try? Data(contentsOf: indexFileURL),
           let decoded = try? JSONDecoder().decode([UUID: DownloadedTrackRecord].self, from: data) {
            for (id, record) in decoded {
                var currentRecord = record
                var fileURL = downloadsDirectoryURL.appendingPathComponent(currentRecord.localFileName)

                if fileManager.fileExists(atPath: fileURL.path) {
                    if fileURL.pathExtension.lowercased() == "tmp" {
                        let detectedExt = Self.detectAudioExtension(for: fileURL, preferred: nil)
                        let healedName = "\(id.uuidString).\(detectedExt)"
                        let healedURL = downloadsDirectoryURL.appendingPathComponent(healedName)
                        try? fileManager.removeItem(at: healedURL)
                        if (try? fileManager.moveItem(at: fileURL, to: healedURL)) != nil {
                            fileURL = healedURL
                            currentRecord = DownloadedTrackRecord(
                                trackId: currentRecord.trackId,
                                serverId: currentRecord.serverId,
                                localFileName: healedName,
                                fileSizeBytes: currentRecord.fileSizeBytes,
                                dateDownloaded: currentRecord.dateDownloaded,
                                originalURLString: currentRecord.originalURLString,
                                trackTitle: currentRecord.trackTitle,
                                artistName: currentRecord.artistName,
                                albumTitle: currentRecord.albumTitle
                            )
                            didHeal = true
                        }
                    }
                    validRecords[id] = currentRecord
                    downloadStates[id] = .downloaded
                    totalBytes += currentRecord.fileSizeBytes
                } else if let (foundURL, _) = findExistingFileOnDisk(for: id) {
                    let fileName = foundURL.lastPathComponent
                    let fileSize = (try? fileManager.attributesOfItem(atPath: foundURL.path)[.size] as? Int64) ?? currentRecord.fileSizeBytes
                    let healedRecord = DownloadedTrackRecord(
                        trackId: id,
                        serverId: currentRecord.serverId,
                        localFileName: fileName,
                        fileSizeBytes: fileSize,
                        dateDownloaded: currentRecord.dateDownloaded,
                        originalURLString: currentRecord.originalURLString,
                        trackTitle: currentRecord.trackTitle,
                        artistName: currentRecord.artistName,
                        albumTitle: currentRecord.albumTitle
                    )
                    validRecords[id] = healedRecord
                    downloadStates[id] = .downloaded
                    totalBytes += fileSize
                    didHeal = true
                }
            }
        }

        // Scan directory for any .tmp files or orphaned tracks to heal them
        if let fileNames = try? fileManager.contentsOfDirectory(atPath: downloadsDirectoryURL.path) {
            for fileName in fileNames {
                guard fileName.lowercased().hasSuffix(".tmp") else { continue }
                let tmpURL = downloadsDirectoryURL.appendingPathComponent(fileName)
                let stem = (fileName as NSString).deletingPathExtension
                if let uuid = UUID(uuidString: stem) {
                    let detectedExt = Self.detectAudioExtension(for: tmpURL, preferred: nil)
                    let healedName = "\(uuid.uuidString).\(detectedExt)"
                    let healedURL = downloadsDirectoryURL.appendingPathComponent(healedName)
                    try? fileManager.removeItem(at: healedURL)
                    if (try? fileManager.moveItem(at: tmpURL, to: healedURL)) != nil {
                        let fileSize = (try? fileManager.attributesOfItem(atPath: healedURL.path)[.size] as? Int64) ?? 0
                        if validRecords[uuid] == nil {
                            let rec = DownloadedTrackRecord(
                                trackId: uuid,
                                serverId: UUID(),
                                localFileName: healedName,
                                fileSizeBytes: fileSize,
                                originalURLString: healedURL.absoluteString,
                                trackTitle: "",
                                artistName: "",
                                albumTitle: ""
                            )
                            validRecords[uuid] = rec
                            downloadStates[uuid] = .downloaded
                            totalBytes += fileSize
                        }
                        didHeal = true
                    }
                }
            }
        }

        self.downloadRecords = validRecords
        self.totalDownloadedBytes = totalBytes
        if didHeal {
            saveIndex()
        }
    }

    private func saveIndex() {
        let records = self.downloadRecords
        let url = self.indexFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Public Queries

    private func findExistingFileOnDisk(for trackId: UUID) -> (url: URL, ext: String)? {
        let commonExtensions = ["flac", "mp3", "m4a", "wav", "aac", "alac", "aiff", "ogg"]
        for ext in commonExtensions {
            let candidate = downloadsDirectoryURL.appendingPathComponent("\(trackId.uuidString).\(ext)")
            if fileManager.fileExists(atPath: candidate.path) {
                return (candidate, ext)
            }
        }
        let tmpCandidate = downloadsDirectoryURL.appendingPathComponent("\(trackId.uuidString).tmp")
        if fileManager.fileExists(atPath: tmpCandidate.path) {
            let detectedExt = Self.detectAudioExtension(for: tmpCandidate, preferred: nil)
            let healedName = "\(trackId.uuidString).\(detectedExt)"
            let healedURL = downloadsDirectoryURL.appendingPathComponent(healedName)
            try? fileManager.removeItem(at: healedURL)
            if (try? fileManager.moveItem(at: tmpCandidate, to: healedURL)) != nil {
                return (healedURL, detectedExt)
            }
        }
        return nil
    }

    /// Returns local file URL if track has been downloaded and exists on disk as a playable audio file.
    public func localFileURL(for trackId: UUID) -> URL? {
        if let record = downloadRecords[trackId] {
            let fileURL = downloadsDirectoryURL.appendingPathComponent(record.localFileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                if fileURL.pathExtension.lowercased() == "tmp" {
                    let detectedExt = Self.detectAudioExtension(for: fileURL, preferred: nil)
                    let healedName = "\(trackId.uuidString).\(detectedExt)"
                    let healedURL = downloadsDirectoryURL.appendingPathComponent(healedName)
                    try? fileManager.removeItem(at: healedURL)
                    if (try? fileManager.moveItem(at: fileURL, to: healedURL)) != nil {
                        let updated = DownloadedTrackRecord(
                            trackId: record.trackId,
                            serverId: record.serverId,
                            localFileName: healedName,
                            fileSizeBytes: record.fileSizeBytes,
                            dateDownloaded: record.dateDownloaded,
                            originalURLString: record.originalURLString,
                            trackTitle: record.trackTitle,
                            artistName: record.artistName,
                            albumTitle: record.albumTitle
                        )
                        downloadRecords[trackId] = updated
                        saveIndex()
                        return healedURL
                    }
                }
                return fileURL
            }
        }

        // Fallback: search disk for this trackId
        if let (foundURL, _) = findExistingFileOnDisk(for: trackId) {
            if downloadRecords[trackId] == nil {
                let fileSize = (try? fileManager.attributesOfItem(atPath: foundURL.path)[.size] as? Int64) ?? 0
                let newRecord = DownloadedTrackRecord(
                    trackId: trackId,
                    serverId: UUID(),
                    localFileName: foundURL.lastPathComponent,
                    fileSizeBytes: fileSize,
                    originalURLString: foundURL.absoluteString,
                    trackTitle: "",
                    artistName: "",
                    albumTitle: ""
                )
                downloadRecords[trackId] = newRecord
                downloadStates[trackId] = .downloaded
                saveIndex()
            }
            return foundURL
        }

        return nil
    }

    /// Returns true if track is currently downloaded.
    public func isDownloaded(trackId: UUID) -> Bool {
        if downloadRecords[trackId] != nil {
            return true
        }
        return localFileURL(for: trackId) != nil
    }

    /// Returns download state for a track ID.
    public func downloadState(for trackId: UUID) -> JellyfinDownloadState {
        if isDownloaded(trackId: trackId) {
            return .downloaded
        }
        return downloadStates[trackId] ?? .notDownloaded
    }

    public func progress(for trackId: UUID) -> Double {
        downloadProgress[trackId] ?? 0.0
    }

    public var downloadedTracksList: [DownloadedTrackRecord] {
        Array(downloadRecords.values).sorted { $0.dateDownloaded > $1.dateDownloaded }
    }

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedBytes, countStyle: .file)
    }

    // MARK: - Download Actions

    /// Enqueues a single track for download.
    public func download(track: Track, server: JellyfinServerLink) {
        guard !isDownloaded(trackId: track.id) else { return }
        guard !downloadStates[track.id, default: .notDownloaded].isDownloading else { return }

        downloadStates[track.id] = .queued
        downloadProgress[track.id] = 0.0
        downloadQueue.append((track, server))
        processNextInQueue()
    }

    /// Enqueues multiple tracks for download.
    public func download(tracks: [Track], server: JellyfinServerLink) {
        var didEnqueue = false
        for track in tracks {
            guard !isDownloaded(trackId: track.id) else { continue }
            guard !downloadStates[track.id, default: .notDownloaded].isDownloading else { continue }

            downloadStates[track.id] = .queued
            downloadProgress[track.id] = 0.0
            downloadQueue.append((track, server))
            didEnqueue = true
        }
        if didEnqueue {
            processNextInQueue()
        }
    }

    /// Enqueues a single track for download by matching its folderID to a JellyfinServerLink.
    public func download(track: Track, servers: [JellyfinServerLink]) {
        guard let server = servers.first(where: { $0.id == track.folderID }) ?? servers.first else { return }
        download(track: track, server: server)
    }

    /// Enqueues multiple tracks for download by matching their folderID to JellyfinServerLink items.
    public func download(tracks: [Track], servers: [JellyfinServerLink]) {
        let serversByID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fallback = servers.first
        var didEnqueue = false
        for track in tracks {
            guard !isDownloaded(trackId: track.id) else { continue }
            guard !downloadStates[track.id, default: .notDownloaded].isDownloading else { continue }
            guard let server = (track.folderID.flatMap { serversByID[$0] }) ?? fallback else { continue }

            downloadStates[track.id] = .queued
            downloadProgress[track.id] = 0.0
            downloadQueue.append((track, server))
            didEnqueue = true
        }
        if didEnqueue {
            processNextInQueue()
        }
    }

    /// Enqueues a single track for download, resolving the Jellyfin server automatically.
    public func download(track: Track) {
        let server = (track.folderID.flatMap { JellyfinSessionCache.shared.serverLink(for: $0) })
            ?? JellyfinSessionCache.shared.allLinks.first
        guard let server else { return }
        download(track: track, server: server)
    }

    /// Enqueues multiple tracks for download, resolving servers automatically.
    public func download(tracks: [Track]) {
        download(tracks: tracks, servers: JellyfinSessionCache.shared.allLinks)
    }

    /// Cancels an in-progress or queued download.
    public func cancelDownload(trackId: UUID) {
        if let task = activeTasks[trackId] {
            task.cancel()
            let taskID = task.taskIdentifier
            activeTasks.removeValue(forKey: trackId)
            taskToTrackID.removeValue(forKey: taskID)
            taskToTrack.removeValue(forKey: taskID)
            taskToServer.removeValue(forKey: taskID)
            DownloadProgressThrottler.shared.remove(taskID: taskID)
        }
        downloadQueue.removeAll { $0.track.id == trackId }
        downloadStates.removeValue(forKey: trackId)
        downloadProgress.removeValue(forKey: trackId)
        processNextInQueue()
    }

    /// Deletes downloaded file from disk and cleans up index.
    public func deleteDownload(trackId: UUID) {
        guard let record = downloadRecords[trackId] else { return }
        let fileURL = downloadsDirectoryURL.appendingPathComponent(record.localFileName)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        downloadRecords.removeValue(forKey: trackId)
        downloadStates.removeValue(forKey: trackId)
        downloadProgress.removeValue(forKey: trackId)
        totalDownloadedBytes = max(0, totalDownloadedBytes - record.fileSizeBytes)
        saveIndex()
    }

    /// Deletes all downloaded Jellyfin tracks from disk.
    public func deleteAllDownloads() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        downloadQueue.removeAll()
        taskToTrackID.removeAll()
        taskToTrack.removeAll()
        taskToServer.removeAll()

        let localFileNames = downloadRecords.values.map { $0.localFileName }
        let dir = downloadsDirectoryURL
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for fileName in localFileNames {
                let fileURL = dir.appendingPathComponent(fileName)
                try? fm.removeItem(at: fileURL)
            }
        }

        downloadRecords.removeAll()
        downloadStates.removeAll()
        downloadProgress.removeAll()
        totalDownloadedBytes = 0
        saveIndex()
    }

    // MARK: - Queue Processing

    private func processNextInQueue() {
        guard activeTasks.count < maxConcurrentDownloads, !downloadQueue.isEmpty else { return }

        let item = downloadQueue.removeFirst()
        let track = item.track
        let server = item.server

        // Determine token and stream URL with local cache to avoid synchronous Keychain IPC calls
        let token: String
        if let cached = cachedTokensByServerID[server.id], !cached.isEmpty {
            token = cached
        } else {
            let sessionInfo = JellyfinSessionCache.shared.resolveSession(for: server.id, servers: [server])
            let resolved = sessionInfo?.token ?? JellyfinKeychain.getToken(forServerId: server.serverId, userId: server.userId) ?? ""
            if !resolved.isEmpty {
                cachedTokensByServerID[server.id] = resolved
            }
            token = resolved
        }
        let sessionInfo = JellyfinSessionCache.shared.resolveSession(for: server.id, servers: [server])
        let serverURL = sessionInfo?.serverURL ?? server.serverURL

        let itemId = track.jellyfinItemId ?? track.url.lastPathComponent
        guard !itemId.isEmpty else {
            downloadStates[track.id] = .failed("INVALID ITEM ID")
            processNextInQueue()
            return
        }

        // Determine stream URL: if the track is in a container that AVFoundation cannot play (e.g. ogg, opus, wma, webm), request mp3 stream
        let ext = (track.fileInfo?.fileExtension ?? track.url.pathExtension).lowercased()
        let needsTranscode = ["ogg", "opus", "wma", "webm", "ape", "wv", "mka", "mpc", "dsf", "dff"].contains(ext)
        let streamPath = needsTranscode ? "Audio/\(itemId)/stream.mp3" : "Audio/\(itemId)/stream"

        var components = URLComponents(url: serverURL.appendingPathComponent(streamPath), resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "api_key", value: token)
        ]
        if !needsTranscode {
            queryItems.append(URLQueryItem(name: "static", value: "true"))
        }
        components?.queryItems = queryItems

        guard let requestURL = components?.url else {
            downloadStates[track.id] = .failed("INVALID URL")
            processNextInQueue()
            return
        }

        var request = URLRequest(url: requestURL)
        request.setValue("MediaBrowser Client=\"MusicPlayer\", Device=\"Apple\", DeviceId=\"MusicPlayerClient\", Version=\"1.0.0\", Token=\"\(token)\"", forHTTPHeaderField: "X-Emby-Authorization")

        let task = session.downloadTask(with: request)
        activeTasks[track.id] = task
        taskToTrackID[task.taskIdentifier] = track.id
        taskToTrack[task.taskIdentifier] = track
        taskToServer[task.taskIdentifier] = server
        downloadStates[track.id] = .downloading(progress: 0.0)
        task.resume()
    }

    // MARK: - Task Completion Callbacks

    fileprivate func trackID(forTaskID taskID: Int) -> UUID? {
        taskToTrackID[taskID]
    }

    fileprivate func downloadContext(forTaskID taskID: Int) -> (track: Track?, server: JellyfinServerLink?, trackID: UUID?) {
        (taskToTrack[taskID], taskToServer[taskID], taskToTrack[taskID]?.id ?? taskToTrackID[taskID])
    }

    fileprivate func handleDownloadProgress(taskID: Int, progress: Double) {
        guard let trackID = taskToTrackID[taskID] else { return }
        downloadProgress[trackID] = progress
        downloadStates[trackID] = .downloading(progress: progress)
    }

    fileprivate func handleDownloadFinished(
        taskID: Int,
        trackID: UUID,
        record: DownloadedTrackRecord,
        fileSize: Int64
    ) {
        activeTasks.removeValue(forKey: trackID)
        taskToTrackID.removeValue(forKey: taskID)
        taskToTrack.removeValue(forKey: taskID)
        taskToServer.removeValue(forKey: taskID)
        DownloadProgressThrottler.shared.remove(taskID: taskID)

        downloadRecords[trackID] = record
        downloadStates[trackID] = .downloaded
        downloadProgress[trackID] = 1.0
        totalDownloadedBytes += fileSize
        saveIndex()
        processNextInQueue()
    }

    fileprivate func handleDownloadFinishedError(
        taskID: Int,
        trackID: UUID,
        error: Error
    ) {
        activeTasks.removeValue(forKey: trackID)
        taskToTrackID.removeValue(forKey: taskID)
        taskToTrack.removeValue(forKey: taskID)
        taskToServer.removeValue(forKey: taskID)
        DownloadProgressThrottler.shared.remove(taskID: taskID)

        downloadStates[trackID] = .failed(error.localizedDescription)
        processNextInQueue()
    }

    fileprivate func handleDownloadError(taskID: Int, error: Error?) {
        guard let trackID = taskToTrackID[taskID] else { return }
        activeTasks.removeValue(forKey: trackID)
        taskToTrackID.removeValue(forKey: taskID)
        taskToTrack.removeValue(forKey: taskID)
        taskToServer.removeValue(forKey: taskID)
        DownloadProgressThrottler.shared.remove(taskID: taskID)

        if let err = error as? URLError, err.code == .cancelled {
            downloadStates.removeValue(forKey: trackID)
        } else {
            downloadStates[trackID] = .failed(error?.localizedDescription ?? "UNKNOWN ERROR")
        }

        processNextInQueue()
    }

    // MARK: - Magic Bytes & Format Detection

    public nonisolated static func detectAudioExtension(for fileURL: URL, preferred: String?) -> String {
        // 1. Try reading the first 64 bytes for magic bytes
        if let fileHandle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? fileHandle.close() }
            let headerData = (try? fileHandle.read(upToCount: 64)) ?? Data()
            if headerData.count >= 4 {
                let bytes = [UInt8](headerData)

                // FLAC: 0x66, 0x4C, 0x61, 0x43 ("fLaC")
                if bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43 {
                    return "flac"
                }

                // Ogg: 0x4F, 0x67, 0x67, 0x53 ("OggS")
                if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
                    return "ogg"
                }

                // MP3 with ID3v2 tag: 0x49, 0x44, 0x33 ("ID3")
                if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 {
                    return "mp3"
                }

                // MP3 MPEG frame sync: 0xFF followed by 0xFB, 0xF3, or 0xF2
                if bytes[0] == 0xFF && ((bytes[1] & 0xFE) == 0xFA || (bytes[1] & 0xFE) == 0xF2) {
                    return "mp3"
                }

                // WAV: "RIFF" at 0..3 and "WAVE" at 8..11
                if bytes.count >= 12,
                   bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46,
                   bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45 {
                    return "wav"
                }

                // AIFF: "FORM" at 0..3 and ("AIFF" or "AIFC") at 8..11
                if bytes.count >= 12,
                   bytes[0] == 0x46 && bytes[1] == 0x4F && bytes[2] == 0x52 && bytes[3] == 0x4D,
                   bytes[8] == 0x41 && bytes[9] == 0x49 && bytes[10] == 0x46 && (bytes[11] == 0x46 || bytes[11] == 0x43) {
                    return "aiff"
                }

                // ISO / MP4 / M4A: "ftyp" at offset 4
                if bytes.count >= 8,
                   bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
                    return "m4a"
                }

                // AAC ADTS sync word: 0xFF followed by (byte & 0xF6 == 0xF0)
                if bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0 {
                    return "aac"
                }
            }
        }

        // 2. If magic bytes didn't definitively match, check preferred extension
        if let preferred = preferred?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty, preferred != "tmp" {
            return preferred
        }

        // 3. Fallback: m4a
        return "m4a"
    }
}

// MARK: - URLSessionDownloadDelegate

extension JellyfinDownloadManager: URLSessionDownloadDelegate {

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = downloadTask.taskIdentifier

        // Throttle MainActor progress dispatches: maximum 10Hz (100ms) or when progress steps by >= 2%
        let now = Date().timeIntervalSinceReferenceDate
        guard DownloadProgressThrottler.shared.shouldDispatch(taskID: taskID, progress: fraction, now: now) else {
            return
        }

        Task { @MainActor in
            JellyfinDownloadManager.shared.handleDownloadProgress(taskID: taskID, progress: fraction)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let dir = JellyfinDownloadManager.shared.downloadsDirectoryURL

        // Quickly move to temporary path synchronously before system deletes location
        let tempDir = FileManager.default.temporaryDirectory
        let tempTarget = tempDir.appendingPathComponent(UUID().uuidString + "_" + location.lastPathComponent)
        try? FileManager.default.moveItem(at: location, to: tempTarget)

        // Detach all file moving, disk write, and attribute calculations entirely from MainActor
        Task.detached(priority: .utility) {
            let context = await JellyfinDownloadManager.shared.downloadContext(forTaskID: taskID)
            guard let trackID = context.trackID else {
                try? FileManager.default.removeItem(at: tempTarget)
                return
            }
            let track = context.track
            let server = context.server

            // Determine preferred extension from track metadata, suggested filename, or MIME type
            var preferredExt: String? = nil
            if let mime = downloadTask.response?.mimeType?.lowercased() {
                if mime.contains("flac") { preferredExt = "flac" }
                else if mime.contains("mpeg") || mime.contains("mp3") { preferredExt = "mp3" }
                else if mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") { preferredExt = "m4a" }
                else if mime.contains("wav") { preferredExt = "wav" }
                else if mime.contains("aiff") { preferredExt = "aiff" }
                else if mime.contains("ogg") { preferredExt = "ogg" }
            }
            if preferredExt == nil, let suggested = downloadTask.response?.suggestedFilename {
                let sExt = (suggested as NSString).pathExtension.lowercased()
                if !sExt.isEmpty && sExt != "tmp" {
                    preferredExt = sExt
                }
            }
            if preferredExt == nil, let tExt = track?.fileInfo?.fileExtension.lowercased(), !tExt.isEmpty && tExt != "tmp" {
                preferredExt = tExt
            }
            if preferredExt == nil, let uExt = track?.url.pathExtension.lowercased(), !uExt.isEmpty && uExt != "tmp" {
                preferredExt = uExt
            }

            let ext = JellyfinDownloadManager.detectAudioExtension(for: tempTarget, preferred: preferredExt)
            let fileName = "\(trackID.uuidString).\(ext)"
            let destinationURL = dir.appendingPathComponent(fileName)
            let fm = FileManager.default

            do {
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.moveItem(at: tempTarget, to: destinationURL)

                let attributes = try? fm.attributesOfItem(atPath: destinationURL.path)
                let fileSize = (attributes?[.size] as? Int64) ?? 0

                let record = DownloadedTrackRecord(
                    trackId: trackID,
                    serverId: server?.id ?? UUID(),
                    localFileName: fileName,
                    fileSizeBytes: fileSize,
                    dateDownloaded: Date(),
                    originalURLString: track?.url.absoluteString ?? destinationURL.absoluteString,
                    trackTitle: track?.title ?? "",
                    artistName: track?.artist ?? "",
                    albumTitle: track?.album ?? ""
                )

                await JellyfinDownloadManager.shared.handleDownloadFinished(
                    taskID: taskID,
                    trackID: trackID,
                    record: record,
                    fileSize: fileSize
                )
            } catch {
                try? fm.removeItem(at: tempTarget)
                await JellyfinDownloadManager.shared.handleDownloadFinishedError(
                    taskID: taskID,
                    trackID: trackID,
                    error: error
                )
            }
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            JellyfinDownloadManager.shared.handleDownloadError(taskID: taskID, error: error)
        }
    }
}
