import Foundation
import os

/// Release-type info read from local file tags (FLAC/Ogg Vorbis comments, ID3 TXXX/TCMP, MP4 freeform/cpil), keyed by `Track.id`.
/// Lock-guarded and file-backed (MusicPlayerData/LocalReleaseTags.json). Only tracks that carry tags are stored.
/// Read by `ReleaseTypeRegistry` for albums with no server album ID (plan §3.7).
nonisolated public final class LocalReleaseTagStore: @unchecked Sendable {
    public static let shared = LocalReleaseTagStore()

    private struct Persisted: Codable {
        var infos: [String: ReleaseTypeInfo]
    }

    private let lock = NSLock()
    private var infos: [UUID: ReleaseTypeInfo] = [:]
    private var isLoaded = false
    private var revisionCounter = 0
    private var saveScheduled = false
    private var backfillStarted = false
    private let fileURL: URL
    private static let ioQueue = DispatchQueue(label: "LocalReleaseTagStore.io", qos: .utility)
    private static let backfillDoneKey = "LocalReleaseTagBackfill.v1"

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = appSupport
            .appendingPathComponent("MusicPlayerData", isDirectory: true)
            .appendingPathComponent("LocalReleaseTags.json")
    }

    /// Caller must hold `lock`.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        for (key, info) in persisted.infos {
            if let id = UUID(uuidString: key) { infos[id] = info }
        }
    }

    /// Increments whenever any stored info changes.
    public var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return revisionCounter
    }

    public func info(for trackID: UUID) -> ReleaseTypeInfo? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return infos[trackID]
    }

    /// Most common tag info across the tracks (ties: first seen). Nil when no track carries release tags.
    public func dominantInfo(for tracks: [Track]) -> ReleaseTypeInfo? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard !infos.isEmpty else { return nil }
        var counts: [ReleaseTypeInfo: Int] = [:]
        var order: [ReleaseTypeInfo] = []
        for track in tracks {
            guard let info = infos[track.id] else { continue }
            if counts[info] == nil { order.append(info) }
            counts[info, default: 0] += 1
        }
        var best: ReleaseTypeInfo?
        var bestCount = 0
        for info in order where counts[info, default: 0] > bestCount {
            best = info
            bestCount = counts[info, default: 0]
        }
        return best
    }

    /// Records the tag info read for a track during a scan (nil clears a stale entry). Persists with a short debounce.
    public func record(trackID: UUID, info: ReleaseTypeInfo?) {
        lock.lock()
        loadIfNeeded()
        let changed = infos[trackID] != info
        if changed {
            infos[trackID] = info
            revisionCounter += 1
        }
        let shouldSchedule = changed && !saveScheduled
        if shouldSchedule { saveScheduled = true }
        lock.unlock()
        if shouldSchedule {
            Self.ioQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
        }
    }

    private func save() {
        lock.lock()
        saveScheduled = false
        var out: [String: ReleaseTypeInfo] = [:]
        out.reserveCapacity(infos.count)
        for (id, info) in infos { out[id.uuidString] = info }
        lock.unlock()
        guard let data = try? JSONEncoder().encode(Persisted(infos: out)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// One-time background pass that reads release-type tags (header-only) for local tracks scanned before tags were captured.
    /// Runs at most once per launch; marked complete when most readable files were read, so it does not repeat on later launches.
    public func backfillIfNeeded(tracks: [Track]) {
        guard !UserDefaults.standard.bool(forKey: Self.backfillDoneKey) else { return }
        lock.lock()
        let alreadyStarted = backfillStarted
        backfillStarted = true
        lock.unlock()
        guard !alreadyStarted else { return }
        let candidates = tracks.filter { $0.canReadLocalBytes }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            var read = 0
            for (i, track) in candidates.enumerated() {
                if Task.isCancelled { return }
                let accessing = track.url.startAccessingSecurityScopedResource()
                let meta = FastAudioMetadataReader.readMetadata(for: track.url)
                if accessing { track.url.stopAccessingSecurityScopedResource() }
                if let meta {
                    read += 1
                    if let info = meta.releaseTypeInfo { self.record(trackID: track.id, info: info) }
                }
                if i % 200 == 199 { await Task.yield() }
            }
            if read * 10 >= candidates.count * 9 {
                UserDefaults.standard.set(true, forKey: Self.backfillDoneKey)
            }
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicPlayer", category: "LocalReleaseTags").info("Local release-tag backfill read \(read)/\(candidates.count) files.")
        }
    }
}
