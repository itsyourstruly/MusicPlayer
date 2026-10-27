import Foundation
import os

/// The one Offline gate. While enabled the app shows only tracks stored on this device and sends nothing to
/// connected servers: no streams, artwork, lyrics, descriptions, syncs, rescans, downloads or play reports.
/// Mirrored from `AppSettings.isOfflineModeEnabled` by `LibraryStore.applyOfflineMode()`; readable from any thread.
nonisolated public enum OfflineMode {
    private static let state = OSAllocatedUnfairLock<Bool>(initialState: false)

    public static var isEnabled: Bool { state.withLock { $0 } }

    /// Returns true when the value changed.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        state.withLock { current in
            guard current != enabled else { return false }
            current = enabled
            return true
        }
    }

    /// Error used for every request refused while Offline is on.
    public static var blockedError: URLError { URLError(.notConnectedToInternet) }

    /// Posted on the main actor when downloaded server tracks are added or removed, so the offline Library refreshes.
    public static let downloadedTracksChanged = Notification.Name("OfflineModeDownloadedTracksChanged")

    /// True when the track plays without any server request: every local-folder track, and server tracks
    /// with a finished download. A set lookup only (no file system access), so it stays cheap for large libraries.
    public static func isOnDevice(_ track: Track, downloadedTrackIDs: Set<UUID>) -> Bool {
        guard isServerTrack(track) else { return true }
        return downloadedTrackIDs.contains(track.id)
    }

    /// Same test the player uses to decide a track must be streamed from a server.
    public static func isServerTrack(_ track: Track) -> Bool {
        track.isJellyfinItem || track.metadataSource == .server
    }
}

/// Backstop installed in every server URLSession: refuses any request that reaches the network while Offline is on.
nonisolated final class OfflineRequestBlocker: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { OfflineMode.isEnabled }
    override class func canInit(with task: URLSessionTask) -> Bool { OfflineMode.isEnabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: OfflineMode.blockedError) }
    override func stopLoading() {}
}

nonisolated extension URLSessionConfiguration {
    /// Adds the Offline backstop in front of the system protocols.
    func blockingRequestsWhileOffline() -> URLSessionConfiguration {
        protocolClasses = [OfflineRequestBlocker.self] + (protocolClasses ?? [])
        return self
    }
}
