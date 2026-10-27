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
        let version: String?
    }

    private let lock = NSLock()
    private var mappings: [String: RegistryEntry] = [:]
    /// Last seen server image version per artwork key (persisted) so changed server art replaces the cached copy.
    private var versions: [String: String] = [:]
    private var versionsLoaded = false

    /// Dedicated artwork session: parallel image fetches per host match ServerArtworkGate's cap, no URLCache
    /// (ArtworkCacheService's disk cache is the single artwork cache). Each request carries its own timeout
    /// (`ArtworkFetchSize.requestTimeout`: 10 s list thumbnails, 15 s originals).
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = ServerArtworkGate.maxPerServer
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config.blockingRequestsWhileOffline())
    }()

    private static let versionsURL: URL = ArtworkCacheService.sharedCacheDirectoryURL
        .deletingLastPathComponent()
        .appendingPathComponent("ArtworkVersions.json")

    private init() {}

    /// Registers a mapping from an artwork key to a server image (with optional fallback image, e.g. track art).
    public func register(key: String, link: ServerSourceLink, imageId: String, fallbackImageId: String? = nil, version: String? = nil) {
        guard !key.isEmpty, !imageId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let existing = mappings[key]
        let existingFallback = existing?.fallbackImageId
        let finalFallback = fallbackImageId ?? (existingFallback != imageId ? existingFallback : nil)
        mappings[key] = RegistryEntry(link: link, primaryImageId: imageId, fallbackImageId: finalFallback,
                                      version: version ?? existing?.version)
    }

    /// Caller must hold `lock`.
    private func loadVersionsIfNeeded() {
        guard !versionsLoaded else { return }
        versionsLoaded = true
        if let data = try? Data(contentsOf: Self.versionsURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            versions = stored
        }
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
    /// Two tiers: `.thumbnail` (the size each provider's server natively caches, see `artworkRequests`) for every
    /// non-fullscreen view and `.original` (no resize) for the fullscreen player and lock screen. Requests for the
    /// same image and tier are de-duplicated; the shared request is cancelled once its last waiter has left.
    /// At most `ServerArtworkGate.maxPerServer` run per server, visible requests first. A 429/503 or a timeout opens
    /// one back-off episode (Retry-After, otherwise 2 s; visible requests wait at most 8 s), after which a single
    /// probe request goes out before the rest are released.
    /// Returns `.notFound` only when every request answered 404 (the server has no image), so transient
    /// network failures are retried later instead of being cached as "no artwork".
    public func fetchArtworkData(for key: String, size: ArtworkFetchSize) async -> RemoteArtworkResult {
        // Offline: cached artwork still shows; nothing is requested and nothing is remembered as missing.
        guard !OfflineMode.isEnabled else { return .cancelled }
        let entry: RegistryEntry? = {
            lock.lock()
            defer { lock.unlock() }
            return mappings[key]
        }()
        guard let entry, let provider = ServerProviderRegistry.provider(for: entry.link) else { return .failed }

        let serverID = entry.link.id
        let gate = ServerArtworkGate.shared
        let callerIsVisible = FetchUrgency.current?.isVisible ?? (Task.currentPriority > .utility)
        if !callerIsVisible, await gate.backoffRemaining(serverID, visible: false) > 0 { return .retryLater }

        let dedupKey = "\(serverID.uuidString)|\(entry.primaryImageId)|\(entry.fallbackImageId ?? "")|\(size.cacheTag)"
        return await gate.deduplicated(dedupKey, priority: Task.currentPriority) {
            // The pool runs this with the shared request's urgency as the task-local value.
            let urgency = FetchUrgency.current ?? FetchUrgency(visible: callerIsVisible)
            return await Self.performFetch(entry: entry, provider: provider, urgency: urgency, size: size)
        }
    }

    /// Seconds until a visible row should retry `key` after `.retryLater`: the server's remaining visible
    /// back-off (at most 8 s), never less than 2 s. Nil when the key has no server mapping.
    public func retryDelay(for key: String) async -> TimeInterval? {
        let entry: RegistryEntry? = {
            lock.lock()
            defer { lock.unlock() }
            return mappings[key]
        }()
        guard let entry else { return nil }
        let remaining = await ServerArtworkGate.shared.backoffRemaining(entry.link.id, visible: true)
        return max(2, remaining)
    }

    private static func performFetch(entry: RegistryEntry, provider: any MediaServerProvider, urgency: FetchUrgency, size: ArtworkFetchSize) async -> RemoteArtworkResult {
        let serverID = entry.link.id
        let gate = ServerArtworkGate.shared
        // Background requests give up during a back-off; visible ones queue in the gate, which holds them until
        // the (capped) back-off ends and then lets one probe through. Urgency is re-read, so a visible joiner counts.
        if !urgency.isVisible, await gate.backoffRemaining(serverID, visible: false) > 0 { return .retryLater }
        guard let slot = await gate.acquire(serverID, urgency: urgency) else { return .cancelled }
        let result = await fetchUnderSlot(entry: entry, provider: provider, isVisible: urgency.isVisible, size: size)
        await gate.release(serverID, slot: slot)
        return result
    }

    private static func fetchUnderSlot(entry: RegistryEntry, provider: any MediaServerProvider, isVisible: Bool, size: ArtworkFetchSize) async -> RemoteArtworkResult {
        let serverID = entry.link.id
        var images: [(id: String, version: String?)] = [(entry.primaryImageId, entry.version)]
        if let fallback = entry.fallbackImageId, fallback != entry.primaryImageId {
            images.append((fallback, nil))
        }
        var sawNotFound = false
        var sawFailure = false
        for image in images {
            for request in provider.artworkRequests(imageId: image.id, size: size, version: image.version) {
                if Task.isCancelled { return .cancelled }
                ServerRequestLog.log(request, caller: isVisible ? "artwork" : "artworkPrefetch")
                do {
                    let (data, response) = try await Self.session.data(for: request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if status == 429 || status == 503 {
                        let retryAfter = ServerArtworkGate.parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
                        await ServerArtworkGate.shared.recordThrottle(serverID, status: status, retryAfter: retryAfter)
                        return .retryLater
                    }
                    // Any other answer means the server is serving again (closes a back-off episode).
                    if http != nil { await ServerArtworkGate.shared.recordSuccess(serverID) }
                    if (200...299).contains(status), !data.isEmpty {
                        return .data(data)
                    }
                    if status == 404 { sawNotFound = true } else { sawFailure = true }
                } catch {
                    // URLSession cancels the data task when this task is cancelled (URLError.cancelled).
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .cancelled }
                    // A timeout means the server is overloaded: back off like a 429 instead of retrying at once.
                    if (error as? URLError)?.code == .timedOut {
                        await ServerArtworkGate.shared.recordThrottle(serverID, status: 0, retryAfter: nil)
                        return .retryLater
                    }
                    sawFailure = true
                }
            }
        }
        return sawNotFound && !sawFailure ? .notFound : .failed
    }

    /// Rebuilds mappings from indexed tracks (app launch / after sync).
    public func populateFromTracks(_ tracks: [Track], servers: [ServerSourceLink]) {
        let linksByID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !linksByID.isEmpty else { return }
        var seenVersions: [String: String] = [:]
        defer { applyVersions(seenVersions) }

        for track in tracks where track.isJellyfinItem {
            guard let folderID = track.folderID, let link = linksByID[folderID] else { continue }
            let version = track.serverCredits?.imageVersion ?? track.serverCoverArtId
            if let key = track.artworkKey, !key.isEmpty, let version, !version.isEmpty, seenVersions[key] == nil {
                seenVersions[key] = version
            }

            if link.kind != .jellyfin {
                // Subsonic coverArt id / Plex thumb path captured at sync time.
                guard let coverId = track.serverCoverArtId, !coverId.isEmpty else { continue }
                if let key = track.artworkKey, !key.isEmpty {
                    register(key: key, link: link, imageId: coverId, version: version)
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

            let albumImageVersion = track.serverCredits?.imageVersion
            if let key = track.artworkKey, !key.isEmpty {
                register(key: key, link: link, imageId: primaryId, fallbackImageId: fallbackId, version: albumImageVersion)
            }
            let canonKey = ArtworkCacheService.albumArtworkKey(artist: track.artist, album: track.album)
            register(key: canonKey, link: link, imageId: primaryId, fallbackImageId: fallbackId, version: albumImageVersion)
            if let albId = track.jellyfinAlbumId, !albId.isEmpty {
                register(key: "jf_album_\(albId)", link: link, imageId: albId, fallbackImageId: track.jellyfinItemId, version: albumImageVersion)
            }
            if let itmId = track.jellyfinItemId, !itmId.isEmpty {
                register(key: "jf_track_\(itmId)", link: link, imageId: itmId, fallbackImageId: track.jellyfinAlbumId)
            }
        }
    }

    /// Records the server image versions seen in this pass; keys whose version changed get their cached
    /// files and "no image" marker removed so the new server artwork is fetched.
    private func applyVersions(_ seen: [String: String]) {
        guard !seen.isEmpty else { return }
        var stale: [String] = []
        let snapshot: [String: String]?
        lock.lock()
        loadVersionsIfNeeded()
        var changed = false
        for (key, version) in seen where versions[key] != version {
            if versions[key] != nil { stale.append(key) }
            versions[key] = version
            changed = true
        }
        snapshot = changed ? versions : nil
        lock.unlock()

        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.versionsURL, options: .atomic)
        }
        guard !stale.isEmpty else { return }
        Task.detached(priority: .utility) {
            for key in stale {
                await ArtworkCacheService.shared.removeArtwork(key: key)
                await ArtworkCacheService.shared.clearNotFound(for: key)
            }
        }
    }
}

// MARK: - FetchUrgency

/// Whether a shared request currently serves a visible caller. Set when a visible caller joins, or inherited from a
/// linked outer request (e.g. the decode task that waits on this download); read at every scheduling decision, so
/// a visible joiner promotes work that a background caller started.
nonisolated final class FetchUrgency: @unchecked Sendable {
    /// The urgency of the shared request the current task is running for.
    @TaskLocal static var current: FetchUrgency?

    private let lock = NSLock()
    private var visible: Bool
    private var sources: [FetchUrgency] = []

    init(visible: Bool) { self.visible = visible }

    var isVisible: Bool {
        lock.lock()
        let (own, linked) = (visible, sources)
        lock.unlock()
        return own || linked.contains { $0.isVisible }
    }

    func promote() {
        lock.lock()
        visible = true
        lock.unlock()
    }

    func link(_ source: FetchUrgency) {
        guard source !== self else { return }
        lock.lock()
        if !sources.contains(where: { $0 === source }) { sources.append(source) }
        lock.unlock()
    }
}

// MARK: - ServerArtworkGate

/// Per-server artwork request coordination: cancellable in-flight de-duplication per image and tier, a
/// concurrency cap with visible requests served first, and 429/503/timeout back-off counted per episode.
actor ServerArtworkGate {
    static let shared = ServerArtworkGate()
    /// Concurrent artwork requests per server (also the artwork session's connections per host).
    nonisolated static let maxPerServer = 4
    /// Longest a visible request waits out a back-off before the probe request may go.
    nonisolated static let visibleBackoffCap: TimeInterval = 8

    private struct SlotWaiter {
        let id: UUID
        let urgency: FetchUrgency
        let continuation: CheckedContinuation<UUID?, Never>
    }

    private struct ServerState {
        var active = 0
        var waiters: [SlotWaiter] = []
        /// Non-nil while a back-off episode is open (from the first throttle until the next server answer).
        var backoffUntil: Date?
        /// When visible requests may send the probe (back-off capped at `visibleBackoffCap`).
        var visibleUntil: Date?
        /// Episodes in a row whose probe was throttled again (sets the exponential delay without Retry-After).
        var episodes = 0
        /// The single request allowed while an episode is open.
        var probe: UUID?
    }

    private var servers: [UUID: ServerState] = [:]
    private let shared = SharedTaskPool<RemoteArtworkResult>(cancelledValue: .cancelled)

    /// One request per key; cancelled (slot released) once every waiting caller has been cancelled.
    nonisolated func deduplicated(_ key: String, priority: TaskPriority, _ work: @escaping @Sendable () async -> RemoteArtworkResult) async -> RemoteArtworkResult {
        await shared.run(key, priority: priority, work)
    }

    /// Remaining back-off for a visible (capped) or background request.
    func backoffRemaining(_ server: UUID, visible: Bool) -> TimeInterval {
        guard let state = servers[server], let until = visible ? (state.visibleUntil ?? state.backoffUntil) : state.backoffUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    /// Waits for a request slot and returns its token, or nil when the caller is cancelled while queued.
    func acquire(_ server: UUID, urgency: FetchUrgency) async -> UUID? {
        if Task.isCancelled { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                servers[server, default: ServerState()].waiters.append(
                    SlotWaiter(id: waiterID, urgency: urgency, continuation: continuation))
                drain(server)
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(server, waiterID) }
        }
    }

    private func cancelSlotWaiter(_ server: UUID, _ waiterID: UUID) {
        guard var state = servers[server], let index = state.waiters.firstIndex(where: { $0.id == waiterID }) else {
            return // already handed a slot; the fetch sees the cancellation and releases it
        }
        let waiter = state.waiters.remove(at: index)
        servers[server] = state
        waiter.continuation.resume(returning: nil)
    }

    func release(_ server: UUID, slot: UUID) {
        guard var state = servers[server] else { return }
        state.active = max(0, state.active - 1)
        if state.probe == slot { state.probe = nil }
        servers[server] = state
        drain(server)
    }

    /// Hands free slots to waiters, visible first. While an episode is open only one probe runs, and only once
    /// the waiter's back-off (capped for visible requests) has passed.
    private func drain(_ server: UUID) {
        guard var state = servers[server] else { return }
        let now = Date()
        while state.active < Self.maxPerServer, !state.waiters.isEmpty {
            let visibleFlags = state.waiters.map { $0.urgency.isVisible }
            func eligible(_ index: Int) -> Bool {
                guard let until = state.backoffUntil else { return true }
                guard state.probe == nil else { return false }
                return now >= (visibleFlags[index] ? (state.visibleUntil ?? until) : until)
            }
            guard let index = state.waiters.indices.first(where: { visibleFlags[$0] && eligible($0) })
                    ?? state.waiters.indices.first(where: { !visibleFlags[$0] && eligible($0) }) else { break }
            let waiter = state.waiters.remove(at: index)
            let token = UUID()
            state.active += 1
            if state.backoffUntil != nil { state.probe = token }
            servers[server] = state
            waiter.continuation.resume(returning: token)
        }
        servers[server] = state
    }

    private func scheduleDrain(_ server: UUID, at date: Date) {
        let delay = max(0, date.timeIntervalSinceNow)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.drain(server)
        }
    }

    /// The server answered (anything but 429/503): closes the episode and releases queued requests.
    func recordSuccess(_ server: UUID) {
        guard servers[server]?.backoffUntil != nil else { return }
        servers[server]?.backoffUntil = nil
        servers[server]?.visibleUntil = nil
        servers[server]?.episodes = 0
        servers[server]?.probe = nil
        drain(server)
    }

    /// One episode per throttling burst: answers from requests already in flight when the episode opened are
    /// ignored; only a throttled probe (after the visible back-off ended) starts the next, longer episode.
    func recordThrottle(_ server: UUID, status: Int, retryAfter: TimeInterval?) {
        var state = servers[server] ?? ServerState()
        let now = Date()
        if state.backoffUntil != nil, let visibleUntil = state.visibleUntil, now < visibleUntil { return }
        state.episodes += 1
        let delay = min(60, retryAfter ?? 2 * pow(2, Double(min(state.episodes - 1, 5))))
        let until = now.addingTimeInterval(delay)
        let visibleUntil = now.addingTimeInterval(min(delay, Self.visibleBackoffCap))
        state.backoffUntil = until
        state.visibleUntil = visibleUntil
        servers[server] = state
        scheduleDrain(server, at: visibleUntil)
        if until > visibleUntil { scheduleDrain(server, at: until) }
        AppLogger.network.warning("Artwork HTTP \(status): backing off server for \(Int(delay)) s (retry-after: \(retryAfter.map { String(Int($0)) } ?? "none"))")
    }

    /// Retry-After as delta-seconds or an HTTP date.
    nonisolated static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

// MARK: - SharedTaskPool

/// Shares one unstructured task per key between concurrent callers. Each caller waits on its own continuation,
/// so a cancelled caller returns `cancelledValue` at once; when the last waiting caller is cancelled the shared
/// task is cancelled and its entry removed, and a later caller starts a fresh task. The task runs with a
/// `FetchUrgency` (task-local) that takes the most urgent waiter's level: a visible joiner promotes it.
actor SharedTaskPool<Value: Sendable> {
    private struct Entry {
        let generation: UUID
        let task: Task<Void, Never>
        let urgency: FetchUrgency
        var waiters: [UUID: CheckedContinuation<Value, Never>]
        /// Set while the entry has no waiters and a deferred cancel is pending; a re-join clears it.
        var pendingCancel: UUID?
    }

    private var entries: [String: Entry] = [:]
    private let cancelledValue: Value
    /// Grace period before an unwaited task is really cancelled, so a quick re-request (re-render, size
    /// change, row scrolled back) reuses the running work instead of restarting it.
    private let cancelGraceNanoseconds: UInt64

    init(cancelledValue: Value, cancelGraceSeconds: Double = 2) {
        self.cancelledValue = cancelledValue
        self.cancelGraceNanoseconds = UInt64(cancelGraceSeconds * 1_000_000_000)
    }

    func run(_ key: String, priority: TaskPriority, _ work: @escaping @Sendable () async -> Value) async -> Value {
        let waiterID = UUID()
        let callerUrgency = FetchUrgency.current
        let callerIsVisible = callerUrgency?.isVisible ?? (priority > .utility)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                join(key, waiterID: waiterID, continuation: continuation, priority: priority,
                     callerUrgency: callerUrgency, callerIsVisible: callerIsVisible, work: work)
            }
        } onCancel: {
            // The leaving waiter is answered at once; the work itself is only cancelled after the grace period.
            Task { await self.leave(key, waiterID: waiterID) }
        }
    }

    private func join(_ key: String, waiterID: UUID, continuation: CheckedContinuation<Value, Never>,
                      priority: TaskPriority, callerUrgency: FetchUrgency?, callerIsVisible: Bool,
                      work: @escaping @Sendable () async -> Value) {
        // Cancellation is flagged before the cancel handler runs, so a caller cancelled before joining stops here.
        if Task.isCancelled {
            continuation.resume(returning: cancelledValue)
            return
        }
        if var entry = entries[key] {
            if let callerUrgency { entry.urgency.link(callerUrgency) } else if callerIsVisible { entry.urgency.promote() }
            entry.waiters[waiterID] = continuation
            entry.pendingCancel = nil
            entries[key] = entry
            return
        }
        let urgency = FetchUrgency(visible: callerUrgency == nil && callerIsVisible)
        if let callerUrgency { urgency.link(callerUrgency) }
        let generation = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            let value = await FetchUrgency.$current.withValue(urgency) { await work() }
            await self?.finish(key, generation: generation, value: value)
        }
        entries[key] = Entry(generation: generation, task: task, urgency: urgency,
                             waiters: [waiterID: continuation], pendingCancel: nil)
    }

    private func finish(_ key: String, generation: UUID, value: Value) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entries[key] = nil
        for continuation in entry.waiters.values {
            continuation.resume(returning: value)
        }
    }

    private func leave(_ key: String, waiterID: UUID) {
        // Not joined (cancelled first, answered by join) or already answered by finish: nothing to do.
        guard var entry = entries[key], let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: cancelledValue)
        if entry.waiters.isEmpty {
            let token = UUID()
            entry.pendingCancel = token
            let generation = entry.generation
            let grace = cancelGraceNanoseconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: grace)
                await self?.cancelIfIdle(key, generation: generation, token: token)
            }
        }
        entries[key] = entry
    }

    private func cancelIfIdle(_ key: String, generation: UUID, token: UUID) {
        guard let entry = entries[key], entry.generation == generation,
              entry.pendingCancel == token, entry.waiters.isEmpty else { return }
        entry.task.cancel()
        entries[key] = nil
    }
}
