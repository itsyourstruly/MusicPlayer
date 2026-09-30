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
    public nonisolated func cachedImage(key: String, maxDimension: CGFloat = 128) -> PlatformImage? {
        guard !key.isEmpty else { return nil }
        let nsKey = key as NSString
        if let cached = decodedImageCache.object(forKey: nsKey) {
            return cached
        }
        let fallbackKey = "\(key)_\(Int(maxDimension))" as NSString
        return decodedImageCache.object(forKey: fallbackKey)
    }

    /// Clears only the volatile in-memory cache without affecting disk persistence.
    public func clearMemoryCache() {
        decodedImageCache.removeAllObjects()
        rawDataCache.removeAllObjects()
    }

    /// Checks if artwork is already cached in memory or on disk.
    public func hasArtwork(key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let nsKey = key as NSString
        if rawDataCache.object(forKey: nsKey) != nil || decodedImageCache.object(forKey: nsKey) != nil {
            return true
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Fast, lightweight raw artwork staging during directory scans (zero image decoding, deduplicated atomic disk write).
    public func storeRawArtwork(data: Data, key: String) {
        guard !data.isEmpty, !key.isEmpty else { return }
        let nsKey = key as NSString
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: min(data.count, 500_000))

        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Invalidates in-memory raw and decoded image caches for a specific artwork key.
    public func invalidateCachedImage(for key: String) {
        guard !key.isEmpty else { return }
        let nsKey = key as NSString
        rawDataCache.removeObject(forKey: nsKey)
        decodedImageCache.removeObject(forKey: nsKey)
        // Evict common thumbnail dimensions from decoded cache
        for dim in [64, 86, 100, 120, 124, 128, 200, 256, 300, 350, 400, 512, 600, 800, 1024, 1400, 3000] {
            decodedImageCache.removeObject(forKey: "\(key)_\(dim)" as NSString)
        }
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
        } catch {
            AppLogger.storage.error("Failed to write artwork to disk for key \(key): \(error.localizedDescription)")
        }
    }

    /// Loads artwork on-demand at full native resolution and quality without compression or downsampling.
    public func loadDecodedArtwork(key: String, maxDimension: CGFloat = 512) -> PlatformImage? {
        guard !key.isEmpty else { return nil }

        let nsKey = key as NSString
        if let cachedImage = decodedImageCache.object(forKey: nsKey) {
            return cachedImage
        }

        // File URL on disk
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")

        // Decode directly from disk file URL or raw data preserving full native resolution
        let nativeImage: PlatformImage? = {
            if fileManager.fileExists(atPath: fileURL.path) {
                return decodeNativeImage(from: fileURL)
            } else if let rawData = rawDataCache.object(forKey: key as NSString) {
                return decodeNativeImage(from: rawData as Data)
            }
            return nil
        }()

        if let image = nativeImage {
            #if canImport(UIKit)
            let pixelW = max(1, Int(image.size.width * image.scale))
            let pixelH = max(1, Int(image.size.height * image.scale))
            #elseif canImport(AppKit)
            let pixelW = max(1, Int(image.representations.first?.pixelsWide ?? Int(image.size.width)))
            let pixelH = max(1, Int(image.representations.first?.pixelsHigh ?? Int(image.size.height)))
            #endif
            let cost = pixelW * pixelH * 4
            decodedImageCache.setObject(image, forKey: nsKey, cost: cost)
            decodedImageCache.setObject(image, forKey: "\(key)_\(Int(maxDimension))" as NSString, cost: cost)
            return image
        }

        return nil
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
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary

        if let fullResCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions) {
            #if canImport(UIKit)
            return UIImage(cgImage: fullResCGImage)
            #elseif canImport(AppKit)
            return NSImage(cgImage: fullResCGImage, size: NSSize(width: fullResCGImage.width, height: fullResCGImage.height))
            #endif
        }

        if let fullResCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
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
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary

        if let fullResCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions) {
            #if canImport(UIKit)
            return UIImage(cgImage: fullResCGImage)
            #elseif canImport(AppKit)
            return NSImage(cgImage: fullResCGImage, size: NSSize(width: fullResCGImage.width, height: fullResCGImage.height))
            #endif
        }

        if let fullResCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
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

    /// Clears both memory cache and disk artwork cache instantaneously via atomic directory recreation.
    public func clearCache() {
        rawDataCache.removeAllObjects()
        decodedImageCache.removeAllObjects()
        try? fileManager.removeItem(at: cacheDirectoryURL)
        try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        AppLogger.storage.info("Artwork cache purged successfully.")
    }

    /// Calculates total size in bytes consumed by artwork on disk.
    public func calculateDiskSize() -> Int64 {
        // Ensure preconditions are met before proceeding
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        // Total size
        var totalSize: Int64 = 0
        for file in files {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
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
