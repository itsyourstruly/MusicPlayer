import Foundation
import SwiftUI
import Observation
import Network
import os

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

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Why a download could not be queued or was rejected after it finished.
public enum DownloadFailureReason: LocalizedError, Sendable {
    case serverNotFound
    case httpStatus(Int)
    case notAudio

    public var errorDescription: String? {
        switch self {
        case .serverNotFound: return "SERVER FOR THIS SONG IS NOT LINKED ANYMORE"
        case .httpStatus(let code): return "SERVER RETURNED STATUS \(code)"
        case .notAudio: return "SERVER DID NOT SEND AN AUDIO FILE"
        }
    }
}

// MARK: - Download Item State & Summaries

/// Lightweight per-track observable state to isolate download progress re-renders to only the individual track row.
@Observable
@MainActor
public final class DownloadItemState {
    public var progress: Double = 0.0
    public var state: JellyfinDownloadState = .notDownloaded

    public init(progress: Double = 0.0, state: JellyfinDownloadState = .notDownloaded) {
        self.progress = progress
        self.state = state
    }
}

/// Precomputed download summary for album and artist detail headers to eliminate per-frame filtering.
public struct DownloadSummary: Sendable, Equatable {
    public let downloaded: Int
    public let total: Int
    public let isAnyDownloading: Bool
    /// Tracks whose last download attempt failed (shown as DOWNLOAD FAILED, TAP TO RETRY).
    public let failed: Int

    public var isAllDownloaded: Bool {
        total > 0 && downloaded == total
    }

    public init(downloaded: Int = 0, total: Int = 0, isAnyDownloading: Bool = false, failed: Int = 0) {
        self.downloaded = downloaded
        self.total = total
        self.isAnyDownloading = isAnyDownloading
        self.failed = failed
    }
}

// MARK: - Download Progress Throttler

/// Thread-safe nonisolated tracker that throttles high-frequency URLSession download updates to ~4 Hz or 5% steps.
private final class DownloadProgressThrottler: @unchecked Sendable {
    static let shared = DownloadProgressThrottler()
    private let lock = NSLock()
    private var lastReported: [Int: (timestamp: TimeInterval, progress: Double)] = [:]

    func shouldDispatch(taskID: Int, progress: Double, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastReported[taskID] {
            // Lowered to ~4 Hz (0.25s) or 5% (0.05) steps, or 100%
            if (now - last.timestamp >= 0.25) || abs(progress - last.progress) >= 0.05 || progress >= 1.0 {
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
    @ObservationIgnored public private(set) var downloadProgress: [UUID: Double] = [:]
    public private(set) var downloadRecords: [UUID: DownloadedTrackRecord] = [:]
    public private(set) var totalDownloadedBytes: Int64 = 0
    public private(set) var albumSummaries: [String: DownloadSummary] = [:]

    /// DOWNLOAD OVER CELLULAR. Enforced on the download session (`allowsCellularAccess`); when off, the queue
    /// also holds while the only route is cellular and resumes on Wi-Fi/wired. Changing it moves in-flight
    /// tasks onto a new session (cancel with resume data, requeue at the front). Streaming never uses this session.
    public var allowsCellularAccess: Bool = false {
        didSet {
            guard oldValue != allowsCellularAccess else { return }
            rebuildSessionRequeueingActiveTasks()
        }
    }

    /// True while downloads are held because cellular is the only route and DOWNLOAD OVER CELLULAR is off.
    public private(set) var isWaitingForWiFi: Bool = false

    // MARK: - Private State

    private let fileManager = FileManager.default
    public nonisolated let downloadsDirectoryURL: URL
    private let indexFileURL: URL

    @ObservationIgnored private var perTrackStates: [UUID: DownloadItemState] = [:]
    @ObservationIgnored private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var downloadQueue: [(track: Track, server: ServerSourceLink)] = []
    @ObservationIgnored private var taskToTrackID: [Int: UUID] = [:]
    @ObservationIgnored private var taskToTrack: [Int: Track] = [:]
    @ObservationIgnored private var taskToServer: [Int: ServerSourceLink] = [:]
    @ObservationIgnored private var saveIndexTask: Task<Void, Never>?
    private let maxConcurrentDownloads = 3

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var resumeDataByTrack: [UUID: Data] = [:]
    @ObservationIgnored private var isCellularOnlyPath = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    /// Identifies the current session so delegate callbacks from a replaced session (whose task IDs can
    /// collide with the new session's) are ignored.
    private nonisolated static let currentSessionTag = OSAllocatedUnfairLock<String>(initialState: "")

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 300
        config.allowsCellularAccess = allowsCellularAccess
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        let newSession = URLSession(configuration: config.blockingRequestsWhileOffline(), delegate: self, delegateQueue: queue)
        let tag = UUID().uuidString
        newSession.sessionDescription = tag
        Self.currentSessionTag.withLock { $0 = tag }
        return newSession
    }

    fileprivate nonisolated static func isCurrent(_ session: URLSession) -> Bool {
        let tag = session.sessionDescription
        return currentSessionTag.withLock { $0 == tag }
    }

    private var isBlockedByCellularPolicy: Bool { !allowsCellularAccess && isCellularOnlyPath }

    private func updateWaitingState() {
        let waiting = isBlockedByCellularPolicy && (!downloadQueue.isEmpty || !activeTasks.isEmpty)
        if isWaitingForWiFi != waiting { isWaitingForWiFi = waiting }
    }

    /// Cancels every in-flight task with resume data, requeues it at the front, and starts a new session
    /// under the current policy. The old session finishes its cancellations and is invalidated.
    private func rebuildSessionRequeueingActiveTasks() {
        let oldSession = session
        let inFlight = activeTasks
        var requeue: [(track: Track, server: ServerSourceLink)] = []
        for (trackID, task) in inFlight {
            let taskID = task.taskIdentifier
            if let track = taskToTrack[taskID], let server = taskToServer[taskID] {
                requeue.append((track, server))
                task.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    Task { @MainActor in
                        let manager = JellyfinDownloadManager.shared
                        // Keep it only if the track is still waiting to start.
                        if manager.activeTasks[trackID] == nil, manager.downloadQueue.contains(where: { $0.track.id == trackID }) {
                            manager.resumeDataByTrack[trackID] = data
                        }
                    }
                })
            } else {
                task.cancel()
            }
            taskToTrackID.removeValue(forKey: taskID)
            taskToTrack.removeValue(forKey: taskID)
            taskToServer.removeValue(forKey: taskID)
            DownloadProgressThrottler.shared.remove(taskID: taskID)
            downloadStates[trackID] = .queued
            perTrackStates[trackID]?.state = .queued
        }
        activeTasks.removeAll()
        downloadQueue.insert(contentsOf: requeue, at: 0)
        session = makeSession()
        oldSession?.finishTasksAndInvalidate()
        invalidateSummaries()
        processNextInQueue()
    }

    /// Offline turned on: in-flight downloads are cancelled with resume data and held in the queue.
    /// Offline turned off: the held queue starts again.
    func offlineModeChanged() {
        if OfflineMode.isEnabled {
            if !activeTasks.isEmpty { rebuildSessionRequeueingActiveTasks() }
        } else {
            processNextInQueue()
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            let cellularOnly = path.status == .satisfied
                && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                let manager = JellyfinDownloadManager.shared
                guard manager.isCellularOnlyPath != cellularOnly else { return }
                manager.isCellularOnlyPath = cellularOnly
                manager.processNextInQueue()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "JellyfinDownloadManager.path"))
    }

    /// A failure caused by the cellular policy, or by losing Wi-Fi while cellular is disallowed: requeue, don't fail.
    private func shouldRequeueForCellularPolicy(_ error: Error?) -> Bool {
        guard !allowsCellularAccess, let err = error as? URLError else { return false }
        if err.networkUnavailableReason == .cellular { return true }
        guard isCellularOnlyPath else { return false }
        switch err.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

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
        self.session = makeSession()
        startPathMonitor()

        loadIndex()
    }

    // MARK: - Index Persistence & Self-Healing

    private func loadIndex() {
        if fileManager.fileExists(atPath: indexFileURL.path),
           let data = try? Data(contentsOf: indexFileURL),
           let decoded = try? JSONDecoder().decode([UUID: DownloadedTrackRecord].self, from: data) {
            self.downloadRecords = decoded
            var bytes: Int64 = 0
            for (id, record) in decoded {
                self.downloadStates[id] = .downloaded
                bytes += record.fileSizeBytes
            }
            self.totalDownloadedBytes = bytes
        }

        // Reconcile with disk once at launch in a detached background task
        Task.detached(priority: .utility) { [weak self] in
            await self?.reconcileWithDisk()
        }
    }

    /// Background self-healing reconciliation with disk run once at launch off the main thread.
    private func reconcileWithDisk() async {
        let fm = FileManager.default
        let dir = downloadsDirectoryURL
        var updatedRecords = await self.downloadRecords
        var didHeal = false
        var totalBytes: Int64 = 0

        // 1. Verify existing records and heal .tmp or moved files
        for (id, record) in updatedRecords {
            var fileURL = dir.appendingPathComponent(record.localFileName)
            if fm.fileExists(atPath: fileURL.path) {
                if fileURL.pathExtension.lowercased() == "tmp" {
                    let detectedExt = Self.detectAudioExtension(for: fileURL, preferred: nil)
                    let healedName = "\(id.uuidString).\(detectedExt)"
                    let healedURL = dir.appendingPathComponent(healedName)
                    try? fm.removeItem(at: healedURL)
                    if (try? fm.moveItem(at: fileURL, to: healedURL)) != nil {
                        fileURL = healedURL
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
                        updatedRecords[id] = updated
                        didHeal = true
                    }
                }
                totalBytes += record.fileSizeBytes
            } else if let (foundURL, _) = findExistingFileOnDisk(for: id) {
                let fileName = foundURL.lastPathComponent
                let fileSize = (try? fm.attributesOfItem(atPath: foundURL.path)[.size] as? Int64) ?? record.fileSizeBytes
                let healedRecord = DownloadedTrackRecord(
                    trackId: id,
                    serverId: record.serverId,
                    localFileName: fileName,
                    fileSizeBytes: fileSize,
                    dateDownloaded: record.dateDownloaded,
                    originalURLString: record.originalURLString,
                    trackTitle: record.trackTitle,
                    artistName: record.artistName,
                    albumTitle: record.albumTitle
                )
                updatedRecords[id] = healedRecord
                totalBytes += fileSize
                didHeal = true
            }
        }

        // 2. Scan directory for orphaned files or unhealed .tmp files
        if let fileNames = try? fm.contentsOfDirectory(atPath: dir.path) {
            for fileName in fileNames {
                guard fileName.lowercased().hasSuffix(".tmp") else { continue }
                let tmpURL = dir.appendingPathComponent(fileName)
                let stem = (fileName as NSString).deletingPathExtension
                if let uuid = UUID(uuidString: stem) {
                    let detectedExt = Self.detectAudioExtension(for: tmpURL, preferred: nil)
                    let healedName = "\(uuid.uuidString).\(detectedExt)"
                    let healedURL = dir.appendingPathComponent(healedName)
                    try? fm.removeItem(at: healedURL)
                    if (try? fm.moveItem(at: tmpURL, to: healedURL)) != nil {
                        let fileSize = (try? fm.attributesOfItem(atPath: healedURL.path)[.size] as? Int64) ?? 0
                        if updatedRecords[uuid] == nil {
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
                            updatedRecords[uuid] = rec
                            totalBytes += fileSize
                        }
                        didHeal = true
                    }
                }
            }
        }

        let finalRecords = updatedRecords
        let finalTotalBytes = totalBytes
        let wasHealed = didHeal
        await MainActor.run {
            self.downloadRecords = finalRecords
            self.totalDownloadedBytes = finalTotalBytes
            for id in finalRecords.keys {
                self.downloadStates[id] = .downloaded
            }
            self.invalidateSummaries()
            if wasHealed {
                self.saveIndex(immediate: true)
            }
        }
    }

    /// Saves download index with a 1.0s debouncing coalescer to prevent disk thrashing.
    public func saveIndex(immediate: Bool = false) {
        saveIndexTask?.cancel()
        if immediate {
            flushIndex()
            return
        }
        saveIndexTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s debounce
            guard !Task.isCancelled, let self = self else { return }
            self.flushIndex()
        }
    }

    /// Immediately flushes download index to disk (called on scenePhase == .background or completion).
    public func flushIndex() {
        saveIndexTask?.cancel()
        saveIndexTask = nil
        let records = self.downloadRecords
        let url = self.indexFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Public Queries

    private nonisolated func findExistingFileOnDisk(for trackId: UUID) -> (url: URL, ext: String)? {
        let fm = FileManager.default
        let commonExtensions = ["flac", "mp3", "m4a", "wav", "aac", "alac", "aiff", "ogg"]
        for ext in commonExtensions {
            let candidate = downloadsDirectoryURL.appendingPathComponent("\(trackId.uuidString).\(ext)")
            if fm.fileExists(atPath: candidate.path) {
                return (candidate, ext)
            }
        }
        let tmpCandidate = downloadsDirectoryURL.appendingPathComponent("\(trackId.uuidString).tmp")
        if fm.fileExists(atPath: tmpCandidate.path) {
            let detectedExt = Self.detectAudioExtension(for: tmpCandidate, preferred: nil)
            let healedName = "\(trackId.uuidString).\(detectedExt)"
            let healedURL = downloadsDirectoryURL.appendingPathComponent(healedName)
            try? fm.removeItem(at: healedURL)
            if (try? fm.moveItem(at: tmpCandidate, to: healedURL)) != nil {
                return (healedURL, detectedExt)
            }
        }
        return nil
    }

    /// Returns local file URL if track has been downloaded and exists in the in-memory record index.
    public func localFileURL(for trackId: UUID) -> URL? {
        guard let record = downloadRecords[trackId] else { return nil }
        return downloadsDirectoryURL.appendingPathComponent(record.localFileName)
    }

    /// IDs of all downloaded server tracks (in-memory index snapshot).
    public var downloadedTrackIDs: Set<UUID> {
        Set(downloadRecords.keys)
    }

    /// Fast in-memory check for downloaded status. Never performs disk I/O in view bodies.
    public func isDownloaded(trackId: UUID) -> Bool {
        downloadRecords[trackId] != nil
    }

    /// Returns download state for a track ID.
    public func downloadState(for trackId: UUID) -> JellyfinDownloadState {
        if isDownloaded(trackId: trackId) {
            return .downloaded
        }
        return downloadStates[trackId] ?? .notDownloaded
    }

    /// Returns or creates an isolated per-track progress model so progress updates only invalidate that row.
    public func itemState(for trackId: UUID) -> DownloadItemState {
        if let existing = perTrackStates[trackId] {
            return existing
        }
        let st: JellyfinDownloadState
        if isDownloaded(trackId: trackId) {
            st = .downloaded
        } else {
            st = downloadStates[trackId] ?? .notDownloaded
        }
        let item = DownloadItemState(progress: downloadProgress[trackId] ?? 0.0, state: st)
        perTrackStates[trackId] = item
        return item
    }

    public func progress(for trackId: UUID) -> Double {
        downloadProgress[trackId] ?? 0.0
    }

    // MARK: - Precomputed Album & Artist Summaries

    public func invalidateSummaries() {
        albumSummaries.removeAll()
    }

    public func albumSummary(for album: Album) -> DownloadSummary {
        if let cached = albumSummaries[album.id] {
            return cached
        }
        let jellyfinTracks = album.tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
        guard !jellyfinTracks.isEmpty else {
            let empty = DownloadSummary(downloaded: 0, total: 0, isAnyDownloading: false)
            albumSummaries[album.id] = empty
            return empty
        }
        let downloadedCount = jellyfinTracks.filter { downloadRecords[$0.id] != nil }.count
        let anyDownloading = jellyfinTracks.contains { downloadStates[$0.id]?.isDownloading == true }
        let failedCount = jellyfinTracks.filter { downloadStates[$0.id]?.isFailed == true }.count
        let summary = DownloadSummary(downloaded: downloadedCount, total: jellyfinTracks.count, isAnyDownloading: anyDownloading, failed: failedCount)
        albumSummaries[album.id] = summary
        return summary
    }

    public func artistSummary(for artist: Artist) -> DownloadSummary {
        let jellyfinTracks = artist.tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
        guard !jellyfinTracks.isEmpty else {
            return DownloadSummary(downloaded: 0, total: 0, isAnyDownloading: false)
        }
        let downloadedCount = jellyfinTracks.filter { downloadRecords[$0.id] != nil }.count
        let anyDownloading = jellyfinTracks.contains { downloadStates[$0.id]?.isDownloading == true }
        let failedCount = jellyfinTracks.filter { downloadStates[$0.id]?.isFailed == true }.count
        return DownloadSummary(downloaded: downloadedCount, total: jellyfinTracks.count, isAnyDownloading: anyDownloading, failed: failedCount)
    }

    public func playlistSummary(for tracks: [Track]) -> DownloadSummary {
        let jellyfinTracks = tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
        guard !jellyfinTracks.isEmpty else {
            return DownloadSummary(downloaded: 0, total: 0, isAnyDownloading: false)
        }
        let downloadedCount = jellyfinTracks.filter { downloadRecords[$0.id] != nil }.count
        let anyDownloading = jellyfinTracks.contains { downloadStates[$0.id]?.isDownloading == true }
        let failedCount = jellyfinTracks.filter { downloadStates[$0.id]?.isFailed == true }.count
        return DownloadSummary(downloaded: downloadedCount, total: jellyfinTracks.count, isAnyDownloading: anyDownloading, failed: failedCount)
    }

    public var downloadedTracksList: [DownloadedTrackRecord] {
        Array(downloadRecords.values).sorted { $0.dateDownloaded > $1.dateDownloaded }
    }

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedBytes, countStyle: .file)
    }

    // MARK: - Download Actions

    /// Enqueues a single track for download.
    public func download(track: Track, server: ServerSourceLink) {
        guard !isDownloaded(trackId: track.id) else { return }
        guard !downloadStates[track.id, default: .notDownloaded].isDownloading else { return }

        downloadStates[track.id] = .queued
        downloadProgress[track.id] = 0.0
        if let item = perTrackStates[track.id] {
            item.state = .queued
            item.progress = 0.0
        }
        invalidateSummaries()
        downloadQueue.append((track, server))
        processNextInQueue()
    }

    /// Enqueues multiple tracks for download.
    public func download(tracks: [Track], server: ServerSourceLink) {
        var didEnqueue = false
        for track in tracks {
            guard !isDownloaded(trackId: track.id) else { continue }
            guard !downloadStates[track.id, default: .notDownloaded].isDownloading else { continue }

            downloadStates[track.id] = .queued
            downloadProgress[track.id] = 0.0
            if let item = perTrackStates[track.id] {
                item.state = .queued
                item.progress = 0.0
            }
            downloadQueue.append((track, server))
            didEnqueue = true
        }
        if didEnqueue {
            invalidateSummaries()
            processNextInQueue()
        }
    }

    /// Enqueues a single track for download on the server it belongs to (`folderID` = source ID).
    /// No fallback to another server: a song whose source is not linked is marked failed with a clear reason.
    public func download(track: Track, servers: [ServerSourceLink]) {
        guard let server = servers.first(where: { $0.id == track.folderID }) else {
            markFailed(trackID: track.id, reason: .serverNotFound)
            return
        }
        download(track: track, server: server)
    }

    private func markFailed(trackID: UUID, reason: DownloadFailureReason) {
        let state = JellyfinDownloadState.failed(reason.localizedDescription)
        downloadStates[trackID] = state
        perTrackStates[trackID]?.state = state
        invalidateSummaries()
    }

    /// Enqueues multiple tracks for download by matching their folderID to ServerSourceLink items.
    public func download(tracks: [Track], servers: [ServerSourceLink]) {
        let serversByID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var didEnqueue = false
        for track in tracks {
            guard !isDownloaded(trackId: track.id) else { continue }
            guard !downloadStates[track.id, default: .notDownloaded].isDownloading else { continue }
            guard let server = track.folderID.flatMap({ serversByID[$0] }) else {
                markFailed(trackID: track.id, reason: .serverNotFound)
                continue
            }

            downloadStates[track.id] = .queued
            downloadProgress[track.id] = 0.0
            if let item = perTrackStates[track.id] {
                item.state = .queued
                item.progress = 0.0
            }
            downloadQueue.append((track, server))
            didEnqueue = true
        }
        if didEnqueue {
            invalidateSummaries()
            processNextInQueue()
        }
    }

    /// Enqueues a single track for download on its own server, resolved from the linked sources in settings
    /// (the same lookup playback uses), so it works before any server session has been opened.
    public func download(track: Track) {
        download(track: track, servers: LibraryStore.shared?.settings.serverSources ?? [])
    }

    /// Enqueues multiple tracks for download, each on its own server (see `download(track:)`).
    public func download(tracks: [Track]) {
        download(tracks: tracks, servers: LibraryStore.shared?.settings.serverSources ?? [])
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
        resumeDataByTrack.removeValue(forKey: trackId)
        downloadStates.removeValue(forKey: trackId)
        downloadProgress.removeValue(forKey: trackId)
        perTrackStates[trackId]?.state = .notDownloaded
        perTrackStates[trackId]?.progress = 0.0
        invalidateSummaries()
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
        perTrackStates[trackId]?.state = .notDownloaded
        perTrackStates[trackId]?.progress = 0.0
        invalidateSummaries()
        totalDownloadedBytes = max(0, totalDownloadedBytes - record.fileSizeBytes)
        saveIndex()
        NotificationCenter.default.post(name: OfflineMode.downloadedTracksChanged, object: nil)
    }

    /// Deletes all downloaded Jellyfin tracks from disk.
    public func deleteAllDownloads() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        downloadQueue.removeAll()
        resumeDataByTrack.removeAll()
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
        for item in perTrackStates.values {
            item.state = .notDownloaded
            item.progress = 0.0
        }
        invalidateSummaries()
        totalDownloadedBytes = 0
        saveIndex()
        NotificationCenter.default.post(name: OfflineMode.downloadedTracksChanged, object: nil)
    }

    // MARK: - Queue Processing

    private func processNextInQueue() {
        defer { updateWaitingState() }
        // Hold queued downloads while cellular is the only route and cellular downloads are off.
        guard !isBlockedByCellularPolicy else { return }
        // Offline: queued downloads wait until Offline is turned off.
        guard !OfflineMode.isEnabled else { return }
        guard activeTasks.count < maxConcurrentDownloads, !downloadQueue.isEmpty else { return }

        let item = downloadQueue.removeFirst()
        let track = item.track
        let server = item.server

        // Original file for AVPlayer-native formats, AAC 320 M4A for everything else (TranscodePolicy via provider).
        let request: URLRequest
        do {
            request = try ServerStreamRequestBuilder.request(for: track, link: server, purpose: .download, caller: "download")
        } catch {
            let state = JellyfinDownloadState.failed(error.localizedDescription)
            downloadStates[track.id] = state
            perTrackStates[track.id]?.state = state
            invalidateSummaries()
            processNextInQueue()
            return
        }

        let task: URLSessionDownloadTask
        if let resumeData = resumeDataByTrack.removeValue(forKey: track.id) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        activeTasks[track.id] = task
        taskToTrackID[task.taskIdentifier] = track.id
        taskToTrack[task.taskIdentifier] = track
        taskToServer[task.taskIdentifier] = server
        downloadStates[track.id] = .downloading(progress: 0.0)
        perTrackStates[track.id]?.state = .downloading(progress: 0.0)
        perTrackStates[track.id]?.progress = 0.0
        invalidateSummaries()
        task.resume()
        // Fill remaining slots (e.g. several queued tracks when Wi-Fi returns).
        processNextInQueue()
    }

    // MARK: - Task Completion Callbacks

    fileprivate func trackID(forTaskID taskID: Int) -> UUID? {
        taskToTrackID[taskID]
    }

    fileprivate func downloadContext(forTaskID taskID: Int) -> (track: Track?, server: ServerSourceLink?, trackID: UUID?) {
        (taskToTrack[taskID], taskToServer[taskID], taskToTrack[taskID]?.id ?? taskToTrackID[taskID])
    }

    fileprivate func handleDownloadProgress(taskID: Int, progress: Double) {
        guard let trackID = taskToTrackID[taskID] else { return }
        downloadProgress[trackID] = progress
        perTrackStates[trackID]?.progress = progress
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
        if let item = perTrackStates[trackID] {
            item.progress = 1.0
            item.state = .downloaded
        }
        invalidateSummaries()
        totalDownloadedBytes += fileSize
        saveIndex()
        NotificationCenter.default.post(name: OfflineMode.downloadedTracksChanged, object: nil)
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

        let state = JellyfinDownloadState.failed(error.localizedDescription)
        downloadStates[trackID] = state
        perTrackStates[trackID]?.state = state
        invalidateSummaries()
        processNextInQueue()
    }

    fileprivate func handleDownloadError(taskID: Int, error: Error?) {
        guard let trackID = taskToTrackID[taskID] else { return }
        if shouldRequeueForCellularPolicy(error), let track = taskToTrack[taskID], let server = taskToServer[taskID] {
            if let data = (error as? URLError)?.downloadTaskResumeData {
                resumeDataByTrack[trackID] = data
            }
            activeTasks.removeValue(forKey: trackID)
            taskToTrackID.removeValue(forKey: taskID)
            taskToTrack.removeValue(forKey: taskID)
            taskToServer.removeValue(forKey: taskID)
            DownloadProgressThrottler.shared.remove(taskID: taskID)
            downloadStates[trackID] = .queued
            perTrackStates[trackID]?.state = .queued
            downloadQueue.insert((track, server), at: 0)
            invalidateSummaries()
            processNextInQueue()
            return
        }
        activeTasks.removeValue(forKey: trackID)
        taskToTrackID.removeValue(forKey: taskID)
        taskToTrack.removeValue(forKey: taskID)
        taskToServer.removeValue(forKey: taskID)
        DownloadProgressThrottler.shared.remove(taskID: taskID)

        if let err = error as? URLError, err.code == .cancelled {
            downloadStates.removeValue(forKey: trackID)
            perTrackStates[trackID]?.state = .notDownloaded
        } else {
            let state = JellyfinDownloadState.failed(error?.localizedDescription ?? "UNKNOWN ERROR")
            downloadStates[trackID] = state
            perTrackStates[trackID]?.state = state
        }
        invalidateSummaries()
        processNextInQueue()
    }

    // MARK: - Magic Bytes & Format Detection

    public nonisolated static func detectAudioExtension(for fileURL: URL, preferred: String?) -> String {
        // 1. Magic bytes
        if let sniffed = sniffedAudioExtension(for: fileURL) {
            return sniffed
        }

        // 2. If magic bytes didn't definitively match, check preferred extension
        if let preferred = preferred?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty, preferred != "tmp" {
            return preferred
        }

        // 3. Fallback: m4a
        return "m4a"
    }

    /// Audio container recognized from the file's first bytes, or nil when the header is not a known audio format.
    public nonisolated static func sniffedAudioExtension(for fileURL: URL) -> String? {
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
        return nil
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
        guard totalBytesExpectedToWrite > 0, Self.isCurrent(session) else { return }
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
        guard Self.isCurrent(session) else { return }
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

            // Accept only a successful response carrying audio. Subsonic answers errors with HTTP 200 and an
            // XML/JSON body, so the status alone is not enough: require an audio MIME type or audio magic bytes.
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let responseMIME = downloadTask.response?.mimeType?.lowercased() ?? ""
            let failure: DownloadFailureReason?
            if !(200...299).contains(statusCode) {
                failure = .httpStatus(statusCode)
            } else if !responseMIME.hasPrefix("audio/"),
                      JellyfinDownloadManager.sniffedAudioExtension(for: tempTarget) == nil {
                failure = .notAudio
            } else {
                failure = nil
            }
            if let failure {
                try? FileManager.default.removeItem(at: tempTarget)
                await JellyfinDownloadManager.shared.handleDownloadFinishedError(
                    taskID: taskID,
                    trackID: trackID,
                    error: failure
                )
                return
            }

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
        guard let error = error, Self.isCurrent(session) else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            JellyfinDownloadManager.shared.handleDownloadError(taskID: taskID, error: error)
        }
    }
}
