import Foundation
import Network
#if os(iOS)
import UIKit
#endif

// MARK: - CloudDownloadError

public enum CloudDownloadError: LocalizedError, Sendable {
    case offline
    case itemNotFound
    case timeout
    case coordinationFailed
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "OFFLINE: CONNECT TO THE INTERNET TO DOWNLOAD"
        case .itemNotFound:
            return "FILE NOT FOUND ON ICLOUD"
        case .timeout:
            return "DOWNLOAD TIMED OUT"
        case .coordinationFailed:
            return "FAILED TO COORDINATE FILE ACCESS"
        case .downloadFailed(let reason):
            return "DOWNLOAD FAILED: \(reason.uppercased())"
        }
    }
}

// MARK: - CloudDownloadCenter

/// Central coordinator for downloading cloud-only files on demand.
@MainActor
@Observable
public final class CloudDownloadCenter {

    public static let shared = CloudDownloadCenter()

    // MARK: - Observable State

    public private(set) var downloadingTrackIDs: Set<UUID> = []
    public private(set) var downloadProgress: [UUID: Double] = [:]
    public var cloudPlaybackError: String?
    public private(set) var isOnline: Bool = true
    public private(set) var isExpensive: Bool = false
    public private(set) var isConstrained: Bool = false

    public var isWiFiConnected: Bool {
        isOnline && !isExpensive && !isConstrained
    }

    // MARK: - Callback

    /// Notified on main actor when a track finishes downloading to local disk.
    public var onTrackDownloaded: ((UUID, URL) -> Void)?

    // MARK: - Private State

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.musicplayer.networkmonitor", qos: .utility)
    private var activeTasks: [UUID: Task<URL, Error>] = [:]

    private init() {
        startNetworkMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isOnline = (path.status == .satisfied)
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Public API

    /// Ensures the track's audio file is downloaded locally, returning the local file URL.
    /// Dedupes simultaneous requests for the same track and coordinates downloads safely.
    @discardableResult
    public func ensureLocal(track: Track) async throws -> URL {
        cloudPlaybackError = nil

        // If track is already local, immediately return its URL
        if CloudFileAvailability.isLocal(url: track.url) {
            return track.url
        }

        // Remote Jellyfin or streaming URLs don't need ubiquitous downloading
        if !track.url.isFileURL {
            return track.url
        }

        // If download already in flight for this track, join existing task
        if let existingTask = activeTasks[track.id] {
            return try await existingTask.value
        }

        guard isOnline else {
            let err = CloudDownloadError.offline
            cloudPlaybackError = err.localizedDescription
            throw err
        }

        let downloadTask = Task<URL, Error> { @MainActor () -> URL in
            defer {
                self.activeTasks.removeValue(forKey: track.id)
                self.downloadingTrackIDs.remove(track.id)
                self.downloadProgress.removeValue(forKey: track.id)
            }

            self.downloadingTrackIDs.insert(track.id)
            self.downloadProgress[track.id] = 0.0

            #if os(iOS)
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "CloudDownload-\(track.id)") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            #endif

            let fileURL = track.url
            let fm = FileManager.default

            // Request ubiquitous download
            do {
                try fm.startDownloadingUbiquitousItem(at: fileURL)
            } catch {
                // If the file might be an .icloud stub path or normal path
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain {
                    let failErr = CloudDownloadError.downloadFailed(error.localizedDescription)
                    self.cloudPlaybackError = failErr.localizedDescription
                    throw failErr
                }
            }

            // Coordinate with NSFileCoordinator to prioritize fetch without blocking MainActor
            let coordinationResult: (url: URL, error: NSError?) = await Task.detached(priority: .userInitiated) {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var error: NSError?
                var resolvedURL = fileURL

                coordinator.coordinate(readingItemAt: fileURL, options: [], error: &error) { readURL in
                    resolvedURL = readURL
                }

                return (resolvedURL, error)
            }.value

            if let coordErr = coordinationResult.error {
                let failErr = CloudDownloadError.downloadFailed(coordErr.localizedDescription)
                self.cloudPlaybackError = failErr.localizedDescription
                throw failErr
            }

            let targetURL = coordinationResult.url

            // Polling timeout: 45s on Wi-Fi, 60s on expensive/constrained (cellular)
            let timeoutSeconds: TimeInterval = (self.isExpensive || self.isConstrained) ? 60.0 : 45.0
            let startTime = Date()
            var delayMs: UInt64 = 200

            while !CloudFileAvailability.isLocal(url: targetURL) {
                try Task.checkCancellation()

                if Date().timeIntervalSince(startTime) > timeoutSeconds {
                    let timeoutErr = CloudDownloadError.timeout
                    self.cloudPlaybackError = timeoutErr.localizedDescription
                    throw timeoutErr
                }

                if let progress = CloudFileAvailability.downloadProgress(for: targetURL) {
                    self.downloadProgress[track.id] = progress
                }

                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                if delayMs < 1000 {
                    delayMs = min(delayMs * 2, 1000)
                }
            }

            self.downloadProgress[track.id] = 1.0
            self.onTrackDownloaded?(track.id, targetURL)
            return targetURL
        }

        activeTasks[track.id] = downloadTask
        do {
            return try await downloadTask.value
        } catch {
            if !(error is CancellationError) {
                cloudPlaybackError = error.localizedDescription
            }
            throw error
        }
    }

    /// Cancels any active download task for the given track.
    public func cancelDownload(for trackID: UUID) {
        activeTasks[trackID]?.cancel()
        activeTasks.removeValue(forKey: trackID)
        downloadingTrackIDs.remove(trackID)
        downloadProgress.removeValue(forKey: trackID)
    }
}
