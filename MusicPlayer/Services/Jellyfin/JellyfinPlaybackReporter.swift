import Foundation

// MARK: - JellyfinPlaybackReporter

public final class JellyfinPlaybackReporter: @unchecked Sendable {
    public static let shared = JellyfinPlaybackReporter()

    private let session: URLSession
    private var currentReportingTrack: Track?
    private var currentServerLink: JellyfinServerLink?
    private var lastReportedTime: TimeInterval = 0

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Extract Jellyfin Item ID

    public static func extractItemId(from track: Track) -> String? {
        if let jfId = track.jellyfinItemId, !jfId.isEmpty {
            return jfId
        }
        guard track.metadataSource == .server || track.isJellyfinItem else { return nil }
        let components = track.url.pathComponents
        if let audioIdx = components.firstIndex(of: "Audio"), audioIdx + 1 < components.count {
            return components[audioIdx + 1]
        }
        return nil
    }

    // MARK: - Reporting Lifecycle

    public func reportPlaybackStart(track: Track, serverLink: JellyfinServerLink) {
        currentReportingTrack = track
        currentServerLink = serverLink
        lastReportedTime = 0

        guard let itemId = Self.extractItemId(from: track),
              let token = JellyfinKeychain.getToken(forServerId: serverLink.serverId, userId: serverLink.userId) else {
            return
        }

        let endpoint = serverLink.serverURL.appendingPathComponent("Sessions/Playing")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let body: [String: Any] = [
            "QueueableMediaTypes": ["Audio"],
            "CanSeek": true,
            "ItemId": itemId,
            "MediaSourceId": itemId,
            "PlayMethod": "DirectPlay"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            _ = try? await session.data(for: request)
        }
    }

    public func reportPlaybackProgress(seconds: TimeInterval, isPaused: Bool, eventName: String? = nil) {
        guard let track = currentReportingTrack,
              let serverLink = currentServerLink,
              let itemId = Self.extractItemId(from: track),
              let token = JellyfinKeychain.getToken(forServerId: serverLink.serverId, userId: serverLink.userId) else {
            return
        }

        let ticks = Int64(seconds * 10_000_000.0)
        let endpoint = serverLink.serverURL.appendingPathComponent("Sessions/Playing/Progress")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        var body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": itemId,
            "PositionTicks": ticks,
            "IsPaused": isPaused,
            "PlayMethod": "DirectPlay"
        ]
        if let event = eventName {
            body["EventName"] = event
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            _ = try? await session.data(for: request)
        }
    }

    public func reportPlaybackProgress(track: Track, positionSeconds: TimeInterval, isPaused: Bool, serverLink: JellyfinServerLink) {
        currentReportingTrack = track
        currentServerLink = serverLink
        reportPlaybackProgress(seconds: positionSeconds, isPaused: isPaused)
    }

    public func reportPlaybackStopped(seconds: TimeInterval) {
        guard let track = currentReportingTrack,
              let serverLink = currentServerLink,
              let itemId = Self.extractItemId(from: track),
              let token = JellyfinKeychain.getToken(forServerId: serverLink.serverId, userId: serverLink.userId) else {
            currentReportingTrack = nil
            currentServerLink = nil
            return
        }

        let ticks = Int64(seconds * 10_000_000.0)
        let endpoint = serverLink.serverURL.appendingPathComponent("Sessions/Playing/Stopped")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": itemId,
            "PositionTicks": ticks
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        currentReportingTrack = nil
        currentServerLink = nil

        Task {
            _ = try? await session.data(for: request)
        }
    }

    public func reportPlaybackStopped(track: Track, positionSeconds: TimeInterval, serverLink: JellyfinServerLink) {
        currentReportingTrack = track
        currentServerLink = serverLink
        reportPlaybackStopped(seconds: positionSeconds)
    }
}
