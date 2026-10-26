import Foundation
import os

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
    /// `.thumbnail`: exactly what this server pre-generates or caches for its own official clients' lists (no
    /// arbitrary sizes); `.original`: the stored image with no resize. All other sizing happens on device.
    /// `version` is the server's image tag/version where the protocol supports cache-busting.
    func artworkRequests(imageId: String, size: ArtworkFetchSize, version: String?) -> [URLRequest]

    /// Server sort names for artists and albums (best effort; empty when the server has none).
    func fetchCatalog() async throws -> ServerCatalog

    /// Lyrics for a server track (LRC text when synced, plain text otherwise). Nil when unsupported or absent.
    func fetchLyrics(for track: Track) async -> String?

    /// Playback reporting / scrobbling (fire-and-forget).
    @MainActor func reportPlayback(_ event: ServerPlaybackEvent, track: Track)

    /// Revokes the server session where the protocol supports it.
    func signOut() async
}

public extension MediaServerProvider {
    nonisolated func prepareSession() async throws {}
    nonisolated func fetchRelativePaths() async throws -> [String: String] { [:] }
    nonisolated func transcodeFallbackRequest(for track: Track) -> URLRequest? { nil }
    nonisolated func fetchCatalog() async throws -> ServerCatalog { ServerCatalog() }
    nonisolated func fetchLyrics(for track: Track) async -> String? { nil }
}

// MARK: - ServerStreamError

/// Why a signed server media request could not be built. Shown through the player's existing error label.
nonisolated public enum ServerStreamError: LocalizedError, Sendable, Equatable {
    case credentialsMissing
    case noProvider

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "SIGN IN AGAIN"
        case .noProvider: return "SERVER UNAVAILABLE"
        }
    }
}

// MARK: - ServerStreamRequestBuilder

/// The single builder for server audio requests (playback, prewarm, crossfade, smooth skip, downloads).
/// It only ever returns an authenticated request; a server track's `track.url` is an identity value and is
/// never fetched.
nonisolated public enum ServerStreamRequestBuilder {
    public static func request(for track: Track, link: ServerSourceLink?, purpose: ServerMediaPurpose,
                               caller: String) throws -> URLRequest {
        let endpoint = purpose == .download ? "download" : "stream"
        guard let link, let provider = ServerProviderRegistry.provider(for: link) else {
            ServerRequestLog.failure(endpoint: endpoint, caller: caller, reason: "noProvider")
            throw ServerStreamError.noProvider
        }
        guard ServerCredentialStore.credentials(for: link) != nil else {
            ServerRequestLog.failure(endpoint: endpoint, caller: caller, reason: "credentialsMissing")
            throw ServerStreamError.credentialsMissing
        }
        guard let request = provider.mediaRequest(for: track, purpose: purpose), request.url != nil else {
            ServerRequestLog.failure(endpoint: endpoint, caller: caller, reason: "noRequest")
            throw ServerStreamError.noProvider
        }
        guard ServerRequestLog.isSigned(request) else {
            ServerRequestLog.failure(endpoint: endpoint, caller: caller, reason: "unsigned")
            throw ServerStreamError.credentialsMissing
        }
        ServerRequestLog.log(request, caller: caller)
        return request
    }
}

// MARK: - ServerRequestLog

/// One os.Logger line per server request (category "ServerRequest"): endpoint, signed yes/no and caller.
/// Never logs the query string or header values, so passwords, tokens, salts and API keys are not written.
nonisolated public enum ServerRequestLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.musicplayer.app",
                                       category: "ServerRequest")
    private static let queryAuthNames: Set<String> = ["t", "p", "apikey", "api_key", "x-plex-token"]
    private static let headerAuthNames: Set<String> = ["authorization", "x-emby-token", "x-emby-authorization",
                                                       "x-mediabrowser-token", "x-plex-token"]

    /// True when the request carries credentials (Subsonic token/apiKey, Jellyfin/Emby or Plex token).
    public static func isSigned(_ request: URLRequest) -> Bool {
        if let headers = request.allHTTPHeaderFields,
           headers.keys.contains(where: { headerAuthNames.contains($0.lowercased()) }) { return true }
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { queryAuthNames.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty }
    }

    /// Endpoint name only (e.g. "stream.view", "Items/…/Download"), never query or credentials.
    public static func endpoint(of url: URL?) -> String {
        guard let url else { return "?" }
        let parts = url.path.split(separator: "/")
        if let last = parts.last, last.hasSuffix(".view") { return String(last) }
        return parts.suffix(2).joined(separator: "/")
    }

    public static func log(_ request: URLRequest, caller: String) {
        let endpoint = endpoint(of: request.url)
        let signed = isSigned(request) ? "yes" : "no"
        let host = request.url?.host ?? "?"
        logger.info("request endpoint=\(endpoint, privacy: .public) signed=\(signed, privacy: .public) caller=\(caller, privacy: .public) host=\(host, privacy: .public)")
    }

    public static func failure(endpoint: String, caller: String, reason: String) {
        logger.error("request not built endpoint=\(endpoint, privacy: .public) caller=\(caller, privacy: .public) reason=\(reason, privacy: .public)")
    }
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
