import Foundation

/// Concurrency-safe registry mapping artwork cache keys to a server source and image identifier.
/// Image URLs are built on demand by the source's provider (Jellyfin item images, Subsonic getCoverArt,
/// Plex photo transcoder), so tokens are never persisted with artwork keys.
nonisolated public final class ServerArtworkRegistry: @unchecked Sendable {
    public static let shared = ServerArtworkRegistry()

    private struct RegistryEntry: Sendable {
        let link: ServerSourceLink
        let primaryImageId: String
        let fallbackImageId: String?
    }

    private let lock = NSLock()
    private var mappings: [String: RegistryEntry] = [:]

    private init() {}

    /// Registers a mapping from an artwork key to a server image (with optional fallback image, e.g. track art).
    public func register(key: String, link: ServerSourceLink, imageId: String, fallbackImageId: String? = nil) {
        guard !key.isEmpty, !imageId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let existingFallback = mappings[key]?.fallbackImageId
        let finalFallback = fallbackImageId ?? (existingFallback != imageId ? existingFallback : nil)
        mappings[key] = RegistryEntry(link: link, primaryImageId: imageId, fallbackImageId: finalFallback)
    }

    public func hasEndpoint(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mappings[key] != nil
    }

    /// Drops every mapping that belongs to a source (source removal).
    public func removeAll(for sourceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        mappings = mappings.filter { $0.value.link.id != sourceID }
    }

    /// Drops all mappings across all sources.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        mappings.removeAll()
    }

    /// Fetches artwork for a key: primary image first, then the fallback image.
    /// - Parameter fullResolution: original-quality image instead of a list/grid thumbnail.
    public func fetchArtworkData(for key: String, fullResolution: Bool = false) async -> Data? {
        let entry: RegistryEntry? = {
            lock.lock()
            defer { lock.unlock() }
            return mappings[key]
        }()
        guard let entry, let provider = ServerProviderRegistry.provider(for: entry.link) else { return nil }

        var imageIds = [entry.primaryImageId]
        if let fallback = entry.fallbackImageId, fallback != entry.primaryImageId {
            imageIds.append(fallback)
        }
        for imageId in imageIds {
            for request in provider.artworkRequests(imageId: imageId, fullResolution: fullResolution) {
                if let (data, response) = try? await JellyfinClient.syncSession.data(for: request),
                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    /// Rebuilds mappings from indexed tracks (app launch / after sync).
    public func populateFromTracks(_ tracks: [Track], servers: [ServerSourceLink]) {
        let linksByID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !linksByID.isEmpty else { return }

        for track in tracks where track.isJellyfinItem {
            guard let folderID = track.folderID, let link = linksByID[folderID] else { continue }

            if link.kind != .jellyfin {
                // Subsonic coverArt id / Plex thumb path captured at sync time.
                guard let coverId = track.serverCoverArtId, !coverId.isEmpty else { continue }
                if let key = track.artworkKey, !key.isEmpty {
                    register(key: key, link: link, imageId: coverId)
                }
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

            if let key = track.artworkKey, !key.isEmpty {
                register(key: key, link: link, imageId: primaryId, fallbackImageId: fallbackId)
            }
            let canonKey = ArtworkCacheService.albumArtworkKey(artist: track.artist, album: track.album)
            register(key: canonKey, link: link, imageId: primaryId, fallbackImageId: fallbackId)
            if let albId = track.jellyfinAlbumId, !albId.isEmpty {
                register(key: "jf_album_\(albId)", link: link, imageId: albId, fallbackImageId: track.jellyfinItemId)
            }
            if let itmId = track.jellyfinItemId, !itmId.isEmpty {
                register(key: "jf_track_\(itmId)", link: link, imageId: itmId, fallbackImageId: track.jellyfinAlbumId)
            }
        }
    }
}
