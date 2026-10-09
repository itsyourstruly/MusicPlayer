import Foundation
import Observation

// MARK: - TrackAvailability

public enum TrackAvailability: Equatable, Sendable {
    case local
    case jellyfinDownloaded(localURL: URL)
    case jellyfinRemote(isDownloading: Bool, progress: Double)
    case cloudDownloaded
    case cloudRemote(isDownloading: Bool, progress: Double)

    public var isAvailableOffline: Bool {
        switch self {
        case .local, .jellyfinDownloaded, .cloudDownloaded:
            return true
        default:
            return false
        }
    }

    public var isDownloading: Bool {
        switch self {
        case .jellyfinRemote(let downloading, _):
            return downloading
        case .cloudRemote(let downloading, _):
            return downloading
        default:
            return false
        }
    }

    public var downloadProgress: Double {
        switch self {
        case .jellyfinRemote(_, let p):
            return p
        case .cloudRemote(_, let p):
            return p
        default:
            return 0.0
        }
    }
}

// MARK: - AvailabilityCenter

/// Unified query center providing instantaneous offline availability status for any track in the app.
@MainActor
@Observable
public final class AvailabilityCenter {

    public static let shared = AvailabilityCenter()

    private init() {}

    /// Evaluates the current offline vs remote availability status of a track.
    public func availability(for track: Track) -> TrackAvailability {
        // 1. Jellyfin remote track
        if track.isJellyfinItem || track.metadataSource == .server {
            if let localURL = JellyfinDownloadManager.shared.localFileURL(for: track.id) {
                return .jellyfinDownloaded(localURL: localURL)
            }
            let state = JellyfinDownloadManager.shared.downloadState(for: track.id)
            switch state {
            case .downloading(let p):
                return .jellyfinRemote(isDownloading: true, progress: p)
            case .queued:
                return .jellyfinRemote(isDownloading: true, progress: 0.0)
            default:
                return .jellyfinRemote(isDownloading: false, progress: 0.0)
            }
        }

        // 2. Local audio files
        if track.canReadLocalBytes {
            return .local
        }

        // 3. iCloud ubiquitous audio files
        if CloudDownloadCenter.shared.downloadingTrackIDs.contains(track.id) {
            let p = CloudDownloadCenter.shared.downloadProgress[track.id] ?? 0.0
            return .cloudRemote(isDownloading: true, progress: p)
        }

        return .cloudRemote(isDownloading: false, progress: 0.0)
    }
}
