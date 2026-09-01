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
    // File system location for cache directory url
    private let cacheDirectoryURL: URL

    // Initialize with configured properties
    private init() {
        // Strict memory-bounded limits (max 40 thumbnails, 10MB total image cost)
        decodedImageCache.countLimit = 40
        decodedImageCache.totalCostLimit = 10 * 1024 * 1024

        rawDataCache.countLimit = 15
        rawDataCache.totalCostLimit = 2 * 1024 * 1024

        // Paths
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let baseCacheURL = paths.first ?? FileManager.default.temporaryDirectory
        self.cacheDirectoryURL = baseCacheURL.appendingPathComponent("ArtworkCache", isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        }

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak decodedImageCache, weak rawDataCache] _ in
            decodedImageCache?.removeAllObjects()
            rawDataCache?.removeAllObjects()
            AppLogger.storage.warning("Purged artwork memory cache in response to OS memory pressure.")
        }
        #endif
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

    /// Stores artwork data in memory and writes it to disk asynchronously if not already present.
    public func saveArtwork(data: Data, key: String) {
        guard !data.isEmpty, !key.isEmpty else { return }
        let nsKey = key as NSString
        let alreadyInMemory = rawDataCache.object(forKey: nsKey) != nil
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: min(data.count, 500_000))

        if alreadyInMemory { return }

        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        if fileManager.fileExists(atPath: fileURL.path) { return }

        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.storage.error("Failed to write artwork to disk for key \(key): \(error.localizedDescription)")
        }
    }

    /// Loads artwork on-demand with hardware-accelerated thumbnail downsampling (ImageIO) to minimize RAM consumption.
    public func loadDecodedArtwork(key: String, maxDimension: CGFloat = 512) -> PlatformImage? {
        guard !key.isEmpty else { return nil }

        let nsKey = "\(key)_\(Int(maxDimension))" as NSString
        if let cachedImage = decodedImageCache.object(forKey: nsKey) {
            return cachedImage
        }

        // File URL on disk
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")

        // Downsample directly from disk file URL or raw data using ImageIO
        let downsampledImage: PlatformImage? = {
            if fileManager.fileExists(atPath: fileURL.path) {
                return decodeDownsampledImage(from: fileURL, maxDimension: maxDimension)
            } else if let rawData = rawDataCache.object(forKey: key as NSString) {
                return decodeDownsampledImage(from: rawData as Data, maxDimension: maxDimension)
            }
            return nil
        }()

        if let image = downsampledImage {
            let cost = Int(maxDimension * maxDimension * 4)
            decodedImageCache.setObject(image, forKey: nsKey, cost: cost)
            return image
        }

        return nil
    }

    /// Efficient ImageIO downsampling directly from a file URL on disk.
    private func decodeDownsampledImage(from url: URL, maxDimension: CGFloat) -> PlatformImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }

        let maxPixelSize = max(64, Int(maxDimension))
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let downsampledCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }

        #if canImport(UIKit)
        return UIImage(cgImage: downsampledCGImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: downsampledCGImage, size: NSSize(width: maxDimension, height: maxDimension))
        #endif
    }

    /// Efficient ImageIO downsampling directly from raw data.
    private func decodeDownsampledImage(from data: Data, maxDimension: CGFloat) -> PlatformImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            return nil
        }

        let maxPixelSize = max(64, Int(maxDimension))
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let downsampledCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }

        #if canImport(UIKit)
        return UIImage(cgImage: downsampledCGImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: downsampledCGImage, size: NSSize(width: maxDimension, height: maxDimension))
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
}
