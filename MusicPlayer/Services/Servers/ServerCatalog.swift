import Foundation

/// Server-provided sort names for one media-server source (artists and albums), so the library sorts exactly like the server.
nonisolated public struct ServerCatalog: Codable, Sendable, Equatable {
    /// Artist sort names keyed by `ServerCredits.nameKey(artist name)`.
    public var artistSortNames: [String: String]
    /// Album sort names keyed by the source's album identifier in `Track.jellyfinAlbumId` format.
    public var albumSortNames: [String: String]
    /// Release types (OpenSubsonic `releaseTypes`/`isCompilation`/`version`) keyed like `albumSortNames`. Nil in catalogs fetched before release info existed.
    public var albumReleaseInfo: [String: ReleaseTypeInfo]?
    /// Marker of the release-info format; a lower/missing value forces one catalog refetch.
    public var releaseInfoVersion: Int?

    /// 2: adds Plex album Format/Subformat release info.
    public static let currentReleaseInfoVersion = 2

    public init(artistSortNames: [String: String] = [:], albumSortNames: [String: String] = [:]) {
        self.artistSortNames = artistSortNames
        self.albumSortNames = albumSortNames
    }

    public mutating func addReleaseInfo(key: String?, releaseTypes: [String]?, isCompilation: Bool?, version: String?, source: String) {
        guard let key, !key.isEmpty,
              let info = ReleaseTypeInfo.from(rawTypes: releaseTypes ?? [], isCompilation: isCompilation, version: version, source: source) else { return }
        if albumReleaseInfo == nil { albumReleaseInfo = [:] }
        albumReleaseInfo?[key] = info
    }

    /// Records a sort name only when it differs from the display name (keeps the file small).
    public mutating func addArtist(name: String?, sortName: String?) {
        guard let name, let sort = sortName?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty, sort != name else { return }
        artistSortNames[ServerCredits.nameKey(name)] = sort
    }

    public mutating func addAlbum(key: String?, title: String?, sortName: String?) {
        guard let key, !key.isEmpty, let sort = sortName?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty, sort != title else { return }
        albumSortNames[key] = sort
    }
}

/// Lock-guarded, file-backed store of per-source catalogs. Read synchronously by the off-main library builder.
nonisolated public final class ServerCatalogStore: @unchecked Sendable {
    public static let shared = ServerCatalogStore()

    private let lock = NSLock()
    private static let writeQueue = DispatchQueue(label: "ServerCatalogStore.write", qos: .utility)
    private var catalogs: [UUID: ServerCatalog] = [:]
    private var isLoaded = false
    private var revisionCounter = 0
    private let directory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = appSupport
            .appendingPathComponent("MusicPlayerData", isDirectory: true)
            .appendingPathComponent("ServerCatalogs", isDirectory: true)
    }

    private func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).json")
    }

    /// Caller must hold `lock`.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let catalog = try? decoder.decode(ServerCatalog.self, from: data) else { continue }
            catalogs[id] = catalog
        }
    }

    /// Increments whenever any catalog changes.
    public var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return revisionCounter
    }

    /// Sources whose one-time release-info refetch was already attempted this launch (success or failure),
    /// so a failing server is not refetched on every sync.
    private var refreshAttempted: Set<UUID> = []

    /// True when the stored catalog predates the current release-info format and no refetch was attempted yet this launch.
    public func needsReleaseInfoRefresh(for sourceID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if refreshAttempted.contains(sourceID) { return false }
        guard let catalog = catalogs[sourceID] else { return true }
        return (catalog.releaseInfoVersion ?? 0) < ServerCatalog.currentReleaseInfoVersion
    }

    /// Records that a catalog fetch was attempted for the source this launch.
    public func markReleaseInfoRefreshAttempted(for sourceID: UUID) {
        lock.lock(); refreshAttempted.insert(sourceID); lock.unlock()
    }

    public func hasCatalog(for sourceID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return catalogs[sourceID] != nil
    }

    /// All catalogs (one locked copy per library build).
    public func snapshot() -> [UUID: ServerCatalog] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return catalogs
    }

    /// Stores a freshly fetched catalog. Returns true when it differs from the stored one.
    @discardableResult
    public func update(_ catalog: ServerCatalog, for sourceID: UUID) -> Bool {
        lock.lock()
        loadIfNeeded()
        let changed = catalogs[sourceID] != catalog
        if changed { catalogs[sourceID] = catalog; revisionCounter += 1 }
        lock.unlock()
        guard changed else { return false }
        // Encode and write off the caller's thread (the sync runs on the main actor).
        let dir = directory, url = fileURL(for: sourceID)
        Self.writeQueue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(catalog) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return true
    }

    public func remove(sourceID: UUID) {
        lock.lock()
        loadIfNeeded()
        catalogs[sourceID] = nil
        revisionCounter += 1
        lock.unlock()
        let url = fileURL(for: sourceID)
        Self.writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }
}
