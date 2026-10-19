import Foundation

// MARK: - Supporting Types

/// Result of a provider sync: tracks to upsert and stable track IDs that disappeared from the server.
nonisolated public struct ServerChangeSet: Sendable {
    public var upserted: [Track]
    public var removedIDs: Set<UUID>
    /// Old track ID -> new track ID for items whose server ID changed (file moved/re-tagged) but were
    /// rematched by path or metadata, so playlists and play counts can follow them.
    public var remappedIDs: [UUID: UUID]

    public init(upserted: [Track], removedIDs: Set<UUID>, remappedIDs: [UUID: UUID] = [:]) {
        self.upserted = upserted
        self.removedIDs = removedIDs
        self.remappedIDs = remappedIDs
    }
}

/// Why a media request is being built (both follow TranscodePolicy: original when native, AAC 320 otherwise).
nonisolated public enum ServerMediaPurpose: Sendable {
    case stream
    case download
}

nonisolated public enum ServerPlaybackEvent: Sendable {
    case started
    case progress(position: TimeInterval, isPaused: Bool)
    case stopped(position: TimeInterval)
}

// MARK: - MediaServerProvider

/// One adapter per server protocol (Jellyfin today; Subsonic/Plex later). A provider is a lightweight value
/// bound to one source link; credentials come from ServerCredentialStore / ServerSessionCache.
nonisolated public protocol MediaServerProvider: Sendable {
    var link: ServerSourceLink { get }

    /// Refreshes expiring credentials and selects a reachable connection before sync/playback (no-op by default).
    func prepareSession() async throws

    /// Incremental-when-possible sync. `existingTracks` are this source's tracks currently in the library.
    func fetchTrackChanges(
        existingTracks: [Track],
        lastSyncDate: Date?,
        statusHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ServerChangeSet

    /// Library-relative paths keyed by server item ID (folder organization backfill). Empty if unsupported.
    func fetchRelativePaths() async throws -> [String: String]

    /// Authenticated request for the track's audio (original or AAC 320 per TranscodePolicy).
    func mediaRequest(for track: Track, purpose: ServerMediaPurpose) -> URLRequest?

    /// Fallback transcode request when the primary AAC transcode is unavailable (e.g. MP3 320). Nil if none.
    func transcodeFallbackRequest(for track: Track) -> URLRequest?

    /// Ordered artwork requests to try for a server image identifier.
    func artworkRequests(imageId: String, fullResolution: Bool) -> [URLRequest]

    /// Playback reporting / scrobbling (fire-and-forget).
    @MainActor func reportPlayback(_ event: ServerPlaybackEvent, track: Track)

    /// Revokes the server session where the protocol supports it.
    func signOut() async
}

public extension MediaServerProvider {
    func prepareSession() async throws {}
    func fetchRelativePaths() async throws -> [String: String] { [:] }
    func transcodeFallbackRequest(for track: Track) -> URLRequest? { nil }
}

// MARK: - ServerProviderRegistry

nonisolated public enum ServerProviderRegistry {
    /// Returns the adapter for a source, or nil if its server kind is not implemented yet.
    public static func provider(for link: ServerSourceLink) -> (any MediaServerProvider)? {
        switch link.kind {
        case .jellyfin:
            return JellyfinProvider(link: link)
        case .subsonic:
            return SubsonicProvider(link: link)
        case .plex:
            return PlexProvider(link: link)
        case .emby:
            return nil
        }
    }
}
