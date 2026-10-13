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

    /// Remote artwork loader hook for fetching remote artwork (e.g. Jellyfin) on demand when not in local cache.
    nonisolated(unsafe) public static var remoteArtworkLoader: (@Sendable (_ key: String, _ fullResolution: Bool) async -> Data?)?

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
    public nonisolated func cachedImage(key: String, maxDimension: CGFloat = 128, isOriginal: Bool = false) -> PlatformImage? {
        guard !key.isEmpty else { return nil }
        let isFullRes = isOriginal || maxDimension >= 1200
        let targetKey = isFullRes ? ("\(key)_orig" as NSString) : ("\(key)_\(Int(maxDimension))" as NSString)

        if let cached = decodedImageCache.object(forKey: targetKey) {
            return cached
        }
        return nil
    }

    /// Clears only the volatile in-memory cache without affecting disk persistence.
    public func clearMemoryCache() {
        decodedImageCache.removeAllObjects()
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
        // Evict common thumbnail dimensions from decoded cache
        for dim in [64, 86, 100, 120, 124, 128, 200, 256, 300, 350, 400, 512, 600, 800, 1024, 1400, 2000, 2048, 2400, 3000] {
            decodedImageCache.removeObject(forKey: "\(key)_\(dim)" as NSString)
        }
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
        } catch {
            AppLogger.storage.error("Failed to write artwork to disk for key \(key): \(error.localizedDescription)")
        }
    }

    /// Loads artwork on-demand with hardware-accelerated ImageIO downsampling for thumbnails,
    /// or fetches and decodes the 100% original untouched artwork when original/fullscreen resolution is requested.
    public func loadDecodedArtwork(key: String, maxDimension: CGFloat = 512, isOriginal: Bool = false) async -> PlatformImage? {
        guard !key.isEmpty else { return nil }

        let nsKey = key as NSString
        let isFullRes = isOriginal || maxDimension >= 1200
        let targetKey = isFullRes ? ("\(key)_orig" as NSString) : ("\(key)_\(Int(maxDimension))" as NSString)
        if let cachedImage = decodedImageCache.object(forKey: targetKey) {
            return cachedImage
        }

        let origFileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_orig.art")
        let fullFileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_full.art")
        let thumbFileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")

        if isFullRes {
            // 1. Check if true original resolution is already cached on disk (_orig.art or _full.art)
            if fileManager.fileExists(atPath: origFileURL.path),
               let image = decodeNativeImage(from: origFileURL) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }

            if fileManager.fileExists(atPath: fullFileURL.path),
               let image = decodeNativeImage(from: fullFileURL) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }

            // 2. Fetch original untouched resolution from remote server (Jellyfin: high-res unconstrained)
            if let loader = ArtworkCacheService.remoteArtworkLoader,
               let origData = await loader(key, true),
               !origData.isEmpty {
                saveOrigArtwork(data: origData, key: key)
                if let image = decodeNativeImage(from: origData) {
                    cacheDecoded(image: image, targetKey: targetKey)
                    return image
                }
            }

            // 3. Fallback for local files: embedded raw artwork is stored in thumbFileURL (.art)
            if fileManager.fileExists(atPath: thumbFileURL.path),
               let image = decodeNativeImage(from: thumbFileURL) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            } else if let rawData = rawDataCache.object(forKey: nsKey) as Data?,
                      let image = decodeNativeImage(from: rawData) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }
        } else {
            // MARK: - Fast Lightweight Thumbnail (Lists, Grids, MiniPlayer)
            if fileManager.fileExists(atPath: thumbFileURL.path),
               let image = await decodeThumbnailImage(from: thumbFileURL, maxDimension: maxDimension) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }

            if fileManager.fileExists(atPath: origFileURL.path),
               let image = await decodeThumbnailImage(from: origFileURL, maxDimension: maxDimension) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }

            if fileManager.fileExists(atPath: fullFileURL.path),
               let image = await decodeThumbnailImage(from: fullFileURL, maxDimension: maxDimension) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }

            if let rawData = rawDataCache.object(forKey: nsKey) as Data?,
               let image = await decodeThumbnailImage(from: rawData, maxDimension: maxDimension) {
                cacheDecoded(image: image, targetKey: targetKey)
                return image
            }

            if let loader = ArtworkCacheService.remoteArtworkLoader,
               let thumbData = await loader(key, false),
               !thumbData.isEmpty {
                saveArtwork(data: thumbData, key: key)
                if let image = await decodeThumbnailImage(from: thumbData, maxDimension: maxDimension) {
                    cacheDecoded(image: image, targetKey: targetKey)
                    return image
                }
            }
        }

        return nil
    }

    /// Decodes a downsampled thumbnail from disk URL using hardware-accelerated ImageIO.
    private func decodeThumbnailImage(from url: URL, maxDimension: CGFloat) async -> PlatformImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }

        let maxPx = max(32, Int(maxDimension))
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx
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

    /// Decodes a downsampled thumbnail from raw data using hardware-accelerated ImageIO.
    private func decodeThumbnailImage(from data: Data, maxDimension: CGFloat) async -> PlatformImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            return nil
        }

        let maxPx = max(32, Int(maxDimension))
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx
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

    /// Decodes an image from disk URL preserving its full native quality, resolution, and color profile.
    private func decodeNativeImage(from url: URL) -> PlatformImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            #if canImport(UIKit)
            return UIImage(contentsOfFile: url.path)
            #elseif canImport(AppKit)
            return NSImage(contentsOf: url)
            #endif
        }

        let decodeOptions = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary

        if let fullResCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions) {
            #if canImport(UIKit)
            return UIImage(cgImage: fullResCGImage)
            #elseif canImport(AppKit)
            return NSImage(cgImage: fullResCGImage, size: NSSize(width: fullResCGImage.width, height: fullResCGImage.height))
            #endif
        }

        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path)
        #elseif canImport(AppKit)
        return NSImage(contentsOf: url)
        #endif
    }

    /// Decodes an image from raw data preserving its full native quality, resolution, and color profile.
    private func decodeNativeImage(from data: Data) -> PlatformImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            #if canImport(UIKit)
            return UIImage(data: data)
            #elseif canImport(AppKit)
            return NSImage(data: data)
            #endif
        }

        let decodeOptions = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary

        if let fullResCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions) {
            #if canImport(UIKit)
            return UIImage(cgImage: fullResCGImage)
            #elseif canImport(AppKit)
            return NSImage(cgImage: fullResCGImage, size: NSSize(width: fullResCGImage.width, height: fullResCGImage.height))
            #endif
        }

        #if canImport(UIKit)
        return UIImage(data: data)
        #elseif canImport(AppKit)
        return NSImage(data: data)
        #endif
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
            // Data
            let data = cached as Data
            if !fileManager.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL, options: .atomic)
            }
            return data
        }

        // Ensure preconditions are met before proceeding
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            // Data
            let data = try Data(contentsOf: fileURL)
            rawDataCache.setObject(data as NSData, forKey: nsKey, cost: data.count)
            return data
        } catch {
            AppLogger.storage.error("Failed to read artwork from disk for key \(key): \(error.localizedDescription)")
            return nil
        }
    }

    /// Asynchronously loads raw artwork data from in-memory cache first, disk cache next, and remote loader if needed.
    public func loadArtworkAsync(key: String, fullResolution: Bool = false) async -> Data? {
        if fullResolution {
            let origURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_orig.art")
            if let data = try? Data(contentsOf: origURL), !data.isEmpty {
                return data
            }
            let fullURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + "_full.art")
            if let data = try? Data(contentsOf: fullURL), !data.isEmpty {
                return data
            }
            if let loader = ArtworkCacheService.remoteArtworkLoader,
               let remoteData = await loader(key, true),
               !remoteData.isEmpty {
                saveOrigArtwork(data: remoteData, key: key)
                return remoteData
            }
        }
        if let data = loadArtwork(key: key) {
            return data
        }
        if let loader = ArtworkCacheService.remoteArtworkLoader,
           let remoteData = await loader(key, false),
           !remoteData.isEmpty {
            saveArtwork(data: remoteData, key: key)
            return remoteData
        }
        return nil
    }

    /// Clears both memory cache and disk artwork cache instantaneously via atomic directory recreation.
    public func clearCache() {
        rawDataCache.removeAllObjects()
        decodedImageCache.removeAllObjects()
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
