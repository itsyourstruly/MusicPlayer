import Foundation
import SwiftUI
import ImageIO
import os

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Server artwork fetch tiers. Each provider's `artworkRequests` maps a tier to what its server natively
/// pre-generates or caches, so views stay server-agnostic and never force an extra server-side resize.
nonisolated public enum ArtworkFetchSize: Sendable {
    /// Every non-fullscreen view (lists, grids, rows, headers, prefetch): the server's native list size;
    /// every smaller cell is downsampled locally.
    case thumbnail
    /// The stored image with no server resize: fullscreen player (lock screen caps it locally at 1024 px).
    case original

    /// Key component for de-duplicating requests of the same image and tier.
    public var cacheTag: String { self == .thumbnail ? "thumb" : "orig" }

    /// Per-request timeout: short for list thumbnails, longer for originals.
    public var requestTimeout: TimeInterval { self == .thumbnail ? 10 : 15 }
}

/// Outcome of a remote artwork fetch: `notFound` (the server has no image) is cached negatively; `failed` retries.
/// `retryLater`: the server throttled (429/503) or is in back-off; nothing is cached and a later load retries.
nonisolated public enum RemoteArtworkResult: Sendable {
    case data(Data)
    case notFound
    case failed
    case retryLater
    /// Every caller waiting on the request was cancelled (e.g. the row scrolled away); nothing is cached.
    case cancelled
}

/// Concurrency-safe actor managing high-speed in-memory and disk caching for embedded audio artwork.
/// Optimized for ultra-low memory footprint using disk-backed storage and ImageIO thumbnail downsampling.
public actor ArtworkCacheService {
    public static let shared = ArtworkCacheService()

    // In-memory cache for raw data (low capacity staging)
    private let rawDataCache = NSCache<NSString, NSData>()
    // In-memory cache for decoded UI images (strictly bounded)
    private let decodedImageCache = NSCache<NSString, PlatformImage>()
    // File manager
    private let fileManager = FileManager.default
    // In-memory set of artwork keys known to exist on disk/cache to avoid repeated fileManager.fileExists & disk writes
    private var knownPersistedKeys = Set<String>()

    /// Remote artwork loader hook for fetching server artwork on demand when not in the local cache.
    nonisolated(unsafe) public static var remoteArtworkLoader: (@Sendable (_ key: String, _ size: ArtworkFetchSize) async -> RemoteArtworkResult)?

    /// Decode tasks in flight, keyed like the decoded-image cache (one task per key and size bucket). The task
    /// records its own result (memory + disk), so a finished download is always cached even if every caller left;
    /// it is cancelled (with its server request) only after staying unwaited for the pool's grace period.
    private let inFlightDecodes = SharedTaskPool<DecodeOutcome>(cancelledValue: DecodeOutcome(cancelled: true))
    /// Bucket key -> key the image is actually cached under, when the source was smaller than the bucket
    /// (e.g. the 600 px server tier asked for at 640/1024): one decoded copy instead of identical duplicates.
    private var bucketAliases: [String: String] = [:]
    /// Keys the server reported as having no image, with the time of that answer (24 h TTL).
    private var negativeKeys: [String: Date] = [:]
    private var negativeLoaded = false
    private var negativeSaveTask: Task<Void, Never>?

    /// Decoded-thumbnail size buckets (pixels). Requests are rounded up to one of these.
    private nonisolated static let thumbnailBuckets = [160, 320, 640, 1024]

    /// Rounds a requested pixel size up to a decode bucket.
    public nonisolated static func decodeBucket(for pixels: CGFloat) -> Int {
        thumbnailBuckets.first { CGFloat($0) >= pixels } ?? 1024
    }

    // Pre-computed static disk cache path and invalid characters for microsecond lookups
    public static let sharedCacheDirectoryURL: URL = {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let baseCacheURL = paths.first ?? FileManager.default.temporaryDirectory
        let dir = baseCacheURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private static let safeKeyCharacterSet = CharacterSet(charactersIn: "\\/:*?\"<>|#%&{}<>*?$!'\":@+`|=")

    // File system location for cache directory url
    private let cacheDirectoryURL: URL

    // Initialize with configured properties
    private init() {
        // Memory-bounded limits (500 full-quality images, 300MB total image cost)
        decodedImageCache.countLimit = 500
        decodedImageCache.totalCostLimit = 300 * 1024 * 1024

        rawDataCache.countLimit = 50
        rawDataCache.totalCostLimit = 100 * 1024 * 1024

        self.cacheDirectoryURL = ArtworkCacheService.sharedCacheDirectoryURL

        #if canImport(UIKit)
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { _ in
                Task {
                    await ArtworkCacheService.shared.clearMemoryCache()
                    AppLogger.storage.warning("Purged artwork memory cache in response to OS memory pressure.")
                }
            }
        }
        #endif
    }

    /// Synchronously retrieves a cached decoded image from the in-memory cache if available.
    /// Any decoded bucket at least as large as requested (or the decoded original) satisfies a thumbnail request.
    public nonisolated func cachedImage(key: String, maxDimension: CGFloat = 128, isOriginal: Bool = false) -> PlatformImage? {
        guard !key.isEmpty else { return nil }
        if isOriginal || maxDimension >= 1200 {
            return decodedImageCache.object(forKey: "\(key)_orig" as NSString)
        }
        let bucket = Self.decodeBucket(for: maxDimension)
        for size in Self.thumbnailBuckets where size >= bucket {
            if let cached = decodedImageCache.object(forKey: "\(key)_\(size)" as NSString) {
                return cached
            }
        }
        return decodedImageCache.object(forKey: "\(key)_orig" as NSString)
    }

    /// Clears only the volatile in-memory cache without affecting disk persistence.
    public func clearMemoryCache() {
        decodedImageCache.removeAllObjects()
        bucketAliases.removeAll()
        rawDataCache.removeAllObjects()
    }

    /// Checks if artwork is already cached in memory or on disk.
    public func hasArtwork(key: String) -> Bool {
        guard !key.isEmpty else { return false }
        if knownPersistedKeys.contains(key) {
            return true
        }
        let nsKey = key as NSString
        if rawDataCache.object(forKey: nsKey) != nil || decodedImageCache.object(forKey: nsKey) != nil {
            knownPersistedKeys.insert(key)
            return true
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        if fileManager.fileExists(atPath: fileURL.path) {
            knownPersistedKeys.insert(key)
            return true
        }
        return false
    }

    /// Fast, lightweight raw artwork staging during directory scans (zero image decoding, deduplicated atomic disk write).
    public func storeRawArtwork(data: Data, key: String) {
        guard !data.isEmpty, !key.isEmpty else { return }
        if knownPersistedKeys.contains(key) {
            return
        }

        let nsKey = key as NSString
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: min(data.count, 500_000))

        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        knownPersistedKeys.insert(key)
        clearNotFound(for: key)
    }

    /// Invalidates in-memory raw and decoded image caches for a specific artwork key.
    public func invalidateCachedImage(for key: String) {
        guard !key.isEmpty else { return }
        knownPersistedKeys.remove(key)
        knownPersistedKeys.remove("\(key)_orig")
        knownPersistedKeys.remove("\(key)_full")
        let nsKey = key as NSString
        rawDataCache.removeObject(forKey: nsKey)
        decodedImageCache.removeObject(forKey: nsKey)
        decodedImageCache.removeObject(forKey: "\(key)_orig" as NSString)
        decodedImageCache.removeObject(forKey: "\(key)_full" as NSString)
        let origFileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_orig.art")
        try? fileManager.removeItem(at: origFileURL)
        let fullFileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_full.art")
        try? fileManager.removeItem(at: fullFileURL)
        try? fileManager.removeItem(at: cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_s.art"))
        try? fileManager.removeItem(at: cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_m.art"))
        for size in Self.thumbnailBuckets {
            decodedImageCache.removeObject(forKey: "\(key)_\(size)" as NSString)
            bucketAliases["\(key)_\(size)"] = nil
        }
    }

    /// Deletes every cached variant (thumbnail, _orig, _full) of an artwork key (server source removal).
    public func removeArtwork(key: String) {
        guard !key.isEmpty else { return }
        invalidateCachedImage(for: key)
        try? fileManager.removeItem(at: cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art"))
    }

    /// Stores original untouched raw artwork data atomically to disk as _orig.art
    public func saveOrigArtwork(data: Data, key: String) {
        guard !data.isEmpty, !key.isEmpty else { return }
        let origFileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_orig.art")
        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        }
        do {
            try data.write(to: origFileURL, options: .atomic)
            knownPersistedKeys.insert("\(key)_orig")
        } catch {
            AppLogger.storage.error("Failed to write original artwork to disk for key \(key): \(error.localizedDescription)")
        }
    }

    /// Stores full-resolution raw artwork data atomically to disk as _full.art
    public func saveFullArtwork(data: Data, key: String) {
        saveOrigArtwork(data: data, key: key)
    }

    /// Helper to store decoded image in memory cache with computed byte cost.
    private func cacheDecoded(image: PlatformImage, targetKey: NSString) {
        #if canImport(UIKit)
        let pixelW = max(1, Int(image.size.width * image.scale))
        let pixelH = max(1, Int(image.size.height * image.scale))
        #elseif canImport(AppKit)
        let pixelW = max(1, Int(image.representations.first?.pixelsWide ?? Int(image.size.width)))
        let pixelH = max(1, Int(image.representations.first?.pixelsHigh ?? Int(image.size.height)))
        #endif
        let cost = pixelW * pixelH * 4
        decodedImageCache.setObject(image, forKey: targetKey, cost: cost)
    }

    /// Stores artwork data in memory, invalidates stale decoded thumbnails, and writes it to disk atomically.
    public func saveArtwork(data: Data, key: String) {
        guard !data.isEmpty, !key.isEmpty else { return }
        let nsKey = key as NSString
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: min(data.count, 500_000))
        invalidateCachedImage(for: key)

        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")

        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            knownPersistedKeys.insert(key)
            clearNotFound(for: key)
        } catch {
            AppLogger.storage.error("Failed to write artwork to disk for key \(key): \(error.localizedDescription)")
        }
    }

    // MARK: - Decoded Artwork Pipeline

    /// Disk layout per key: `<key>.art` (embedded art, the server's native list size, or 640 px scaled locally from an
    /// original), `<key>_s.art` (320 px, scaled locally), `<key>_m.art` (legacy 600 px tier from an earlier build: still read, never written),
    /// `<key>_orig.art` / `<key>_full.art` (full resolution). Decoded images are cached per size bucket.
    private struct DecodeRequest: Sendable {
        let key: String
        let fileStem: String
        let bucket: Int
        let isFullRes: Bool
        let rawData: Data?
        let allowRemote: Bool
    }

    private struct DecodeOutcome: Sendable {
        var image: PlatformImage?
        var remoteNotFound = false
        var wroteThumbnail = false
        var remoteRetryLater = false
        var cancelled = false
    }

    /// Loads artwork on-demand with ImageIO downsampling to a fixed size bucket (160/320/640/1024 px),
    /// or the full-resolution original. Disk reads, network fetches and decoding run in a detached task
    /// (never on this actor); concurrent requests for the same key and size share one task, which is cancelled
    /// (and its server request with it) once every requesting view has disappeared.
    /// Visible callers (priority above `.utility`) whose server answered `.retryLater` retry automatically once
    /// the back-off ends, at most `maxVisibleRetries` times. The wait is cancelled with the caller's task (a
    /// SwiftUI `.task` ends when the row disappears), so only rows still on screen retry; retries go through
    /// the same de-dup, per-server cap and back-off as any other request.
    public func loadDecodedArtwork(
        key: String,
        maxDimension: CGFloat = 512,
        isOriginal: Bool = false,
        priority: TaskPriority = .userInitiated
    ) async -> PlatformImage? {
        var outcome = await decodeOnce(key: key, maxDimension: maxDimension, isOriginal: isOriginal, priority: priority)
        guard priority > .utility else { return outcome.image }
        var retries = 0
        var retriedFailure = false
        // Visible callers retry: throttling (back-off delay), a cancelled shared request while this caller is still
        // live, and one plain failure (e.g. a timeout). A caller that was itself cancelled stops here.
        while outcome.image == nil, retries < Self.maxVisibleRetries, !Task.isCancelled {
            let delay: TimeInterval
            if outcome.remoteRetryLater {
                guard let backoff = await ServerArtworkRegistry.shared.retryDelay(for: key) else { break }
                delay = backoff
            } else if outcome.cancelled {
                delay = 0
            } else if !retriedFailure, !outcome.remoteNotFound, !isNegativelyCached(key),
                      await ServerArtworkRegistry.shared.retryDelay(for: key) != nil {
                retriedFailure = true
                delay = 1
            } else {
                break
            }
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { break }
            }
            retries += 1
            AppLogger.network.debug("Artwork retry \(retries) after \(Int(delay))s back-off")
            outcome = await decodeOnce(key: key, maxDimension: maxDimension, isOriginal: isOriginal, priority: priority)
        }
        return outcome.image
    }

    private static let maxVisibleRetries = 4

    private func decodeOnce(
        key: String,
        maxDimension: CGFloat,
        isOriginal: Bool,
        priority: TaskPriority
    ) async -> DecodeOutcome {
        guard !key.isEmpty else { return DecodeOutcome() }
        let isFullRes = isOriginal || maxDimension >= 1200
        let bucket = isFullRes ? 0 : Self.decodeBucket(for: maxDimension)
        let targetKey = isFullRes ? "\(key)_orig" : "\(key)_\(bucket)"
        if let cached = decodedImageCache.object(forKey: targetKey as NSString)
            ?? bucketAliases[targetKey].flatMap({ decodedImageCache.object(forKey: $0 as NSString) }) {
            var hit = DecodeOutcome()
            hit.image = cached
            return hit
        }
        let request = DecodeRequest(
            key: key,
            fileStem: cacheDirectoryURL.appendingPathComponent(sanitizedKey(key)).path,
            bucket: bucket,
            isFullRes: isFullRes,
            rawData: rawDataCache.object(forKey: key as NSString) as Data?,
            allowRemote: !isNegativelyCached(key)
        )
        return await inFlightDecodes.run(targetKey, priority: priority) { [weak self] in
            let outcome = await ArtworkCacheService.produce(request)
            await self?.record(outcome, key: key, targetKey: targetKey, bucket: bucket, isFullRes: isFullRes)
            return outcome
        }
    }

    /// Stores a produced outcome in the decoded-image cache and the key bookkeeping (runs inside the shared task).
    private func record(_ outcome: DecodeOutcome, key: String, targetKey: String, bucket: Int, isFullRes: Bool) {
        if outcome.cancelled { return }
        if let image = outcome.image {
            var storeKey = targetKey
            if !isFullRes {
                let actual = Self.decodeBucket(for: Self.maxPixelSide(of: image))
                if actual < bucket {
                    storeKey = "\(key)_\(actual)"
                    bucketAliases[targetKey] = storeKey
                }
            }
            cacheDecoded(image: image, targetKey: storeKey as NSString)
        }
        if outcome.wroteThumbnail {
            knownPersistedKeys.insert(key)
        }
        if outcome.remoteNotFound {
            markNotFound(key)
        }
    }

    private nonisolated static func produce(_ request: DecodeRequest) async -> DecodeOutcome {
        func fileURL(_ suffix: String) -> URL { URL(fileURLWithPath: request.fileStem + suffix) }
        // A missing file simply fails to open: no separate fileExists round trip.
        func read(_ suffix: String) -> Data? {
            guard let data = try? Data(contentsOf: fileURL(suffix), options: .mappedIfSafe), !data.isEmpty else { return nil }
            return data
        }
        var outcome = DecodeOutcome()

        if request.isFullRes {
            for suffix in ["_orig.art", "_full.art"] {
                if let data = read(suffix), let image = decodeNativeImage(from: data) {
                    outcome.image = image
                    return outcome
                }
            }
            if request.allowRemote, let loader = remoteArtworkLoader {
                switch await loader(request.key, .original) {
                case .data(let data):
                    try? data.write(to: fileURL("_orig.art"), options: .atomic)
                    outcome.wroteThumbnail = writeDownscaledTiers(from: data, stem: request.fileStem)
                    if let image = decodeNativeImage(from: data) {
                        outcome.image = image
                        return outcome
                    }
                case .notFound:
                    outcome.remoteNotFound = true
                case .retryLater:
                    outcome.remoteRetryLater = true
                case .cancelled:
                    outcome.cancelled = true
                    return outcome
                case .failed:
                    break
                }
            }
            // Local files keep their embedded artwork in `.art`; offline server art falls back to the cached tiers.
            for data in [read(".art"), request.rawData, read("_m.art"), read("_s.art")].compactMap({ $0 }) {
                if let image = decodeNativeImage(from: data) {
                    outcome.image = image
                    return outcome
                }
            }
            return outcome
        }

        // Smallest local tier that covers the bucket; `_m.art` is the legacy 600 px tier (read only).
        let pixels = request.bucket
        let localOrder: [String]
        switch pixels {
        case ...320: localOrder = ["_s.art", ".art", "_m.art", "_orig.art", "_full.art"]
        case ...640: localOrder = [".art", "_m.art", "_orig.art", "_full.art"]
        default: localOrder = ["_orig.art", "_full.art", "_m.art", ".art"]
        }
        for suffix in localOrder {
            if let data = read(suffix), let image = await decodeThumbnailImage(from: data, maxPixels: pixels) {
                outcome.image = image
                return outcome
            }
        }
        if let raw = request.rawData, let image = await decodeThumbnailImage(from: raw, maxPixels: pixels) {
            outcome.image = image
            return outcome
        }
        if request.allowRemote, let loader = remoteArtworkLoader {
            // Non-fullscreen views fetch the server's native list tier; smaller tiers are scaled locally (ImageIO).
            switch await loader(request.key, .thumbnail) {
            case .data(let data):
                outcome.wroteThumbnail = storeServerThumbnail(data, stem: request.fileStem)
                if let image = await decodeThumbnailImage(from: data, maxPixels: pixels) {
                    outcome.image = image
                    return outcome
                }
            case .notFound:
                outcome.remoteNotFound = true
            case .retryLater:
                outcome.remoteRetryLater = true
            case .cancelled:
                outcome.cancelled = true
                return outcome
            case .failed:
                break
            }
        }
        // Offline / server failure: show the best smaller tier already on disk.
        let smallerTiers = pixels > 320 ? ["_s.art"] : []
        for suffix in smallerTiers {
            if let data = read(suffix), let image = await decodeThumbnailImage(from: data, maxPixels: pixels) {
                outcome.image = image
                return outcome
            }
        }
        return outcome
    }

    /// Writes locally downscaled 640 px (`.art`) and 320 px (`_s.art`) JPEG tiers from an original server image
    /// with ImageIO. Runs on the caller's (background) executor; never call it on the main thread.
    nonisolated static func writeDownscaledTiers(from data: Data, stem: String,
                                                 tiers: [(Int, String)] = [(640, ".art"), (320, "_s.art")]) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        var wrote = false
        for (pixels, suffix) in tiers {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            if (try? (output as Data).write(to: URL(fileURLWithPath: stem + suffix), options: .atomic)) != nil {
                wrote = true
            }
        }
        return wrote
    }

    /// Stores a server list-tier image: an untouched original (larger than 640 px, e.g. Jellyfin/Plex) becomes the
    /// `_orig.art` tier with 640/320 px tiers scaled locally; a server-resized image (e.g. Navidrome 300 px)
    /// becomes `.art` with a local 320 px tier when it is larger than that.
    nonisolated static func storeServerThumbnail(_ data: Data, stem: String) -> Bool {
        let side = pixelSide(of: data)
        if side > 640 {
            try? data.write(to: URL(fileURLWithPath: stem + "_orig.art"), options: .atomic)
            return writeDownscaledTiers(from: data, stem: stem)
        }
        let wroteMain = (try? data.write(to: URL(fileURLWithPath: stem + ".art"), options: .atomic)) != nil
        let wroteSmall = side > 320 && writeDownscaledTiers(from: data, stem: stem, tiers: [(320, "_s.art")])
        return wroteMain || wroteSmall
    }

    /// Largest pixel dimension from the image header (no decode).
    private nonisolated static func pixelSide(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }

    /// Downsampled decode via ImageIO (decodes straight to the target size; never inflates the full image).
    private nonisolated static func decodeThumbnailImage(from data: Data, maxPixels: Int) async -> PlatformImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixels)
        ]
        guard let thumbCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions as CFDictionary) else {
            return nil
        }
        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: thumbCGImage)
        return await uiImage.byPreparingForDisplay() ?? uiImage
        #elseif canImport(AppKit)
        return NSImage(cgImage: thumbCGImage, size: NSSize(width: thumbCGImage.width, height: thumbCGImage.height))
        #endif
    }

    /// Longest side of a decoded image in pixels.
    private nonisolated static func maxPixelSide(of image: PlatformImage) -> CGFloat {
        #if canImport(UIKit)
        return max(image.size.width, image.size.height) * image.scale
        #elseif canImport(AppKit)
        let rep = image.representations.first
        return CGFloat(max(rep?.pixelsWide ?? Int(image.size.width), rep?.pixelsHigh ?? Int(image.size.height)))
        #endif
    }

    /// Full-resolution decode in the image's native 8-bit format and color profile (no float/HDR expansion).
    private nonisolated static func decodeNativeImage(from data: Data) -> PlatformImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            #if canImport(UIKit)
            return UIImage(data: data)
            #elseif canImport(AppKit)
            return NSImage(data: data)
            #endif
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    // MARK: - Negative Cache (server reports no image)

    private static let negativeTTL: TimeInterval = 24 * 3600
    private static let negativeCacheURL: URL = sharedCacheDirectoryURL
        .deletingLastPathComponent()
        .appendingPathComponent("ArtworkNegativeCache.json")

    private func isNegativelyCached(_ key: String) -> Bool {
        if !negativeLoaded {
            negativeLoaded = true
            if let data = try? Data(contentsOf: Self.negativeCacheURL),
               let stored = try? JSONDecoder().decode([String: Date].self, from: data) {
                negativeKeys = stored.filter { Date().timeIntervalSince($0.value) < Self.negativeTTL }
            }
        }
        guard let date = negativeKeys[key] else { return false }
        if Date().timeIntervalSince(date) < Self.negativeTTL { return true }
        negativeKeys[key] = nil
        scheduleNegativeSave()
        return false
    }

    private func markNotFound(_ key: String) {
        negativeKeys[key] = Date()
        scheduleNegativeSave()
    }

    /// Forgets a "no image" result (artwork was saved, or the server image version changed).
    public func clearNotFound(for key: String) {
        guard negativeKeys.removeValue(forKey: key) != nil else { return }
        scheduleNegativeSave()
    }

    private func scheduleNegativeSave() {
        guard negativeSaveTask == nil else { return }
        negativeSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            self.flushNegativeCache()
        }
    }

    private func flushNegativeCache() {
        negativeSaveTask = nil
        let snapshot = negativeKeys
        let url = Self.negativeCacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Loads raw artwork data from in-memory cache first, falling back to disk cache.
    public func loadArtwork(key: String) -> Data? {
        // Ensure preconditions are met before proceeding
        guard !key.isEmpty else { return nil }

        // Ns key
        let nsKey = key as NSString
        // File system location for file url
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")

        if let cached = rawDataCache.object(forKey: nsKey) {
            return cached as Data
        }

        // A missing file just fails to open (no separate fileExists round trip).
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return nil
        }
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: data.count)
        return data
    }

    /// Scales the local tiers on a background task (keeps ImageIO work off the actor and the main thread).
    private nonisolated static func writeTiersDetached(data: Data, stem: String,
                                                       tiers: [(Int, String)] = [(640, ".art"), (320, "_s.art")]) async -> Bool {
        await Task.detached(priority: .utility) { writeDownscaledTiers(from: data, stem: stem, tiers: tiers) }.value
    }

    /// Asynchronously loads raw artwork data from in-memory cache first, disk cache next, and the server if needed.
    public func loadArtworkAsync(key: String, fullResolution: Bool = false) async -> Data? {
        guard !key.isEmpty else { return nil }
        let stem = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key)).path
        let allowRemote = !isNegativelyCached(key)
        let loader = ArtworkCacheService.remoteArtworkLoader
        if fullResolution {
            for suffix in ["_orig.art", "_full.art"] {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: stem + suffix)), !data.isEmpty {
                    return data
                }
            }
            if allowRemote, let loader {
                switch await loader(key, .original) {
                case .data(let data):
                    saveOrigArtwork(data: data, key: key)
                    if await Self.writeTiersDetached(data: data, stem: stem) { knownPersistedKeys.insert(key) }
                    return data
                case .notFound:
                    markNotFound(key)
                    return loadArtwork(key: key)
                case .failed, .retryLater, .cancelled:
                    break
                }
            }
        }
        if let data = loadArtwork(key: key) {
            return data
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: stem + "_m.art")), !data.isEmpty {
            return data
        }
        if allowRemote, let loader {
            // Non-fullscreen use (e.g. Now Playing info): the server's native list tier; smaller tiers are scaled locally.
            switch await loader(key, .thumbnail) {
            case .data(let data):
                if await Task.detached(priority: .utility, operation: { Self.storeServerThumbnail(data, stem: stem) }).value {
                    knownPersistedKeys.insert(key)
                }
                return data
            case .notFound:
                markNotFound(key)
            case .failed, .retryLater, .cancelled:
                break
            }
        }
        return try? Data(contentsOf: URL(fileURLWithPath: stem + "_s.art"))
    }

    /// Clears both memory cache and disk artwork cache instantaneously via atomic directory recreation.
    public func clearCache() {
        rawDataCache.removeAllObjects()
        decodedImageCache.removeAllObjects()
        bucketAliases.removeAll()
        knownPersistedKeys.removeAll()
        try? fileManager.removeItem(at: cacheDirectoryURL)
        try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        AppLogger.storage.info("Artwork cache purged successfully.")
    }

    /// Calculates total size in bytes consumed by artwork on disk.
    public func calculateDiskSize() -> Int64 {
        // Ensure preconditions are met before proceeding
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: [URLResourceKey.fileSizeKey]) else {
            return 0
        }

        // Total size
        var totalSize: Int64 = 0
        for file in files {
            if let values = try? file.resourceValues(forKeys: [URLResourceKey.fileSizeKey]),
               // Size
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// Alias for calculateDiskSize().
    public func diskCacheSizeBytes() -> Int64 {
        calculateDiskSize()
    }

    /// Generates a canonical album-level artwork key to ensure deduplicated storage across tracks.
    public static func albumArtworkKey(artist: String, album: String) -> String {
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(cleanArtist)_\(cleanAlbum)"
        if combined.isEmpty || combined == "unknown artist_unknown album" {
            return "album_art_unknown"
        }
        return "album_art_\(combined)"
    }

    /// Alias for albumArtworkKey.
    public static func generateKey(artist: String, album: String) -> String {
        albumArtworkKey(artist: artist, album: album)
    }

    /// Replaces forbidden file system characters with safe underscores.
    private func sanitizedKey(_ key: String) -> String {
        // Invalid characters
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|#%&{}<>*?$!'\":@+`|=")
        return key.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    /// Synchronously checks if artwork file exists on disk for the given key.
    public static func hasCachedArtworkFile(key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let baseCacheURL = paths.first ?? FileManager.default.temporaryDirectory
        let cacheDir = baseCacheURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|#%&{}<>*?$!'\":@+`|=")
        let sanitized = key.components(separatedBy: invalidCharacters).joined(separator: "_")
        let fileURL = cacheDir.appendingPathComponent(sanitized + ".art")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
