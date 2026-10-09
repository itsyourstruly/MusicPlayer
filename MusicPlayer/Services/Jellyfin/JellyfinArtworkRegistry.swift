import Foundation

/// Concurrency-safe registry mapping artwork keys to remote Jellyfin item endpoints.
/// Enables on-demand artwork downloads and background prefetching for Jellyfin albums and tracks.
public final class JellyfinArtworkRegistry: @unchecked Sendable {
    public static let shared = JellyfinArtworkRegistry()

    private struct RegistryEntry: Sendable {
        let serverURL: URL
        let token: String
        let primaryItemId: String
        let fallbackItemId: String?
    }

    private let lock = NSLock()
    private var mappings: [String: RegistryEntry] = [:]

    private init() {}

    /// Registers a mapping from an album artwork key to its Jellyfin server endpoint and item ID, with optional fallback ID.
    public func register(key: String, serverURL: URL, token: String, itemId: String, fallbackItemId: String? = nil) {
        guard !key.isEmpty, !itemId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let existingFallback = mappings[key]?.fallbackItemId
        let finalFallback = fallbackItemId ?? (existingFallback != itemId ? existingFallback : nil)
        mappings[key] = RegistryEntry(
            serverURL: serverURL,
            token: token,
            primaryItemId: itemId,
            fallbackItemId: finalFallback
        )
    }

    /// Retrieves endpoint details for a given artwork key if known.
    public func endpoint(for key: String) -> (serverURL: URL, token: String, itemId: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = mappings[key] else { return nil }
        return (entry.serverURL, entry.token, entry.primaryItemId)
    }

    /// Checks whether an endpoint mapping exists for a given artwork key.
    public func hasEndpoint(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mappings[key] != nil
    }

    /// Fetches primary image data from Jellyfin for a given artwork key.
    /// - Parameters:
    ///   - key: Artwork cache key.
    ///   - fullResolution: If true, requests the 100% original untouched uncompressed image from the server without resizing or lossy compression.
    ///                     If false, requests an optimized lightweight thumbnail for browsing.
    public func fetchArtworkData(for key: String, fullResolution: Bool = false) async -> Data? {
        let entry: RegistryEntry? = {
            lock.lock()
            defer { lock.unlock() }
            return mappings[key]
        }()
        guard let entry = entry else { return nil }

        // Attempt 1: Primary item ID (e.g. album ID)
        if let data = await fetchFromItem(
            itemId: entry.primaryItemId,
            serverURL: entry.serverURL,
            token: entry.token,
            fullResolution: fullResolution
        ) {
            return data
        }

        // Attempt 2: Fallback item ID (e.g. track ID if album had no artwork)
        if let fallbackId = entry.fallbackItemId, fallbackId != entry.primaryItemId {
            if let data = await fetchFromItem(
                itemId: fallbackId,
                serverURL: entry.serverURL,
                token: entry.token,
                fullResolution: fullResolution
            ) {
                return data
            }
        }

        return nil
    }

    private func fetchFromItem(itemId: String, serverURL: URL, token: String, fullResolution: Bool) async -> Data? {
        let baseURLString = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast())
            : serverURL.absoluteString
        let fullURLString = "\(baseURLString)/Items/\(itemId)/Images/Primary"
        guard var components = URLComponents(string: fullURLString) else { return nil }

        if fullResolution {
            // First attempt: Request high-resolution artwork with high quality (up to 2048px)
            components.queryItems = [
                URLQueryItem(name: "maxWidth", value: "2048"),
                URLQueryItem(name: "quality", value: "96"),
                URLQueryItem(name: "api_key", value: token)
            ]
            if let url = components.url,
               let data = await performImageRequest(url: url, token: token, timeout: 12),
               !data.isEmpty {
                return data
            }

            // Fallback attempt: Request unconstrained original directly without size constraints
            components.queryItems = [
                URLQueryItem(name: "api_key", value: token)
            ]
            if let url = components.url,
               let data = await performImageRequest(url: url, token: token, timeout: 12),
               !data.isEmpty {
                return data
            }
        } else {
            // Lightweight thumbnail for smooth list/grid scrolling: 800px for crisp Retina display
            components.queryItems = [
                URLQueryItem(name: "maxWidth", value: "800"),
                URLQueryItem(name: "quality", value: "90"),
                URLQueryItem(name: "api_key", value: token)
            ]
            if let url = components.url,
               let data = await performImageRequest(url: url, token: token, timeout: 10),
               !data.isEmpty {
                return data
            }
        }

        return nil
    }

    private func performImageRequest(url: URL, token: String, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(JellyfinClient.shared.authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("image/*, */*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        guard let (data, response) = try? await JellyfinClient.syncSession.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    /// Populates registry mappings from already indexed tracks and configured servers.
    public func populateFromTracks(_ tracks: [Track], servers: [JellyfinServerLink]) {
        // Resolve Keychain tokens once per unique server rather than 30,000 times in the loop
        var serverContextsByID: [UUID: (serverURL: URL, token: String)] = [:]
        for server in servers {
            if let token = JellyfinKeychain.getToken(forServerId: server.serverId, userId: server.userId) {
                serverContextsByID[server.id] = (server.serverURL, token)
            }
        }
        guard !serverContextsByID.isEmpty else { return }

        for track in tracks where track.isJellyfinItem {
            guard let folderID = track.folderID,
                  let context = serverContextsByID[folderID] else {
                continue
            }

            let primaryId: String
            let fallbackId: String?

            if let albId = track.jellyfinAlbumId, !albId.isEmpty {
                primaryId = albId
                fallbackId = track.jellyfinItemId
            } else if let itmId = track.jellyfinItemId, !itmId.isEmpty {
                primaryId = itmId
                fallbackId = nil
            } else {
                // Fallback: extract item ID from stream URL e.g. .../Audio/{itemId}/stream
                let pathComponents = track.url.pathComponents
                if let audioIdx = pathComponents.firstIndex(of: "Audio"), audioIdx + 1 < pathComponents.count {
                    primaryId = pathComponents[audioIdx + 1]
                    fallbackId = nil
                } else {
                    continue
                }
            }

            // Register track's explicit artworkKey
            if let key = track.artworkKey, !key.isEmpty {
                register(key: key, serverURL: context.serverURL, token: context.token, itemId: primaryId, fallbackItemId: fallbackId)
            }

            // Register canonical album artwork key
            let canonKey = ArtworkCacheService.albumArtworkKey(artist: track.artist, album: track.album)
            register(key: canonKey, serverURL: context.serverURL, token: context.token, itemId: primaryId, fallbackItemId: fallbackId)

            // Register direct album ID key
            if let albId = track.jellyfinAlbumId, !albId.isEmpty {
                register(key: "jf_album_\(albId)", serverURL: context.serverURL, token: context.token, itemId: albId, fallbackItemId: track.jellyfinItemId)
            }

            // Register direct track ID key
            if let itmId = track.jellyfinItemId, !itmId.isEmpty {
                register(key: "jf_track_\(itmId)", serverURL: context.serverURL, token: context.token, itemId: itmId, fallbackItemId: track.jellyfinAlbumId)
            }
        }
    }
}
