import Foundation
import SwiftUI
import os

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Concurrency-safe actor managing high-speed in-memory and disk caching for embedded audio artwork.
public actor ArtworkCacheService {
    public static let shared = ArtworkCacheService()

    // In-memory cache for raw data cache
    private let rawDataCache = NSCache<NSString, NSData>()
    // In-memory cache for decoded image cache
    private let decodedImageCache = NSCache<NSString, PlatformImage>()
    // File manager
    private let fileManager = FileManager.default
    // File system location for cache directory url
    private let cacheDirectoryURL: URL

    // Initialize with configured properties
    private init() {
        // High-performance cache limits (250 decoded UI images, 1000 raw cover datas)
        decodedImageCache.countLimit = 250
        rawDataCache.countLimit = 1000
        rawDataCache.totalCostLimit = 100 * 1024 * 1024

        // Paths
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        // File system location for base cache url
        let baseCacheURL = paths.first ?? fileManager.temporaryDirectory
        self.cacheDirectoryURL = baseCacheURL.appendingPathComponent("ArtworkCache", isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        }
    }

    /// Checks if artwork is already cached in memory or on disk.
    public func hasArtwork(key: String) -> Bool {
        // Ensure preconditions are met before proceeding
        guard !key.isEmpty else { return false }
        // Ns key
        let nsKey = key as NSString
        if rawDataCache.object(forKey: nsKey) != nil || decodedImageCache.object(forKey: nsKey) != nil {
            return true
        }
        // File system location for file url
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Fast, lightweight raw artwork staging during directory scans (zero image decoding, deduplicated atomic disk write).
    public func storeRawArtwork(data: Data, key: String) {
        // Ensure preconditions are met before proceeding
        guard !data.isEmpty, !key.isEmpty else { return }
        // Ns key
        let nsKey = key as NSString
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: data.count)

        // File system location for file url
        let fileURL = cacheDirectoryURL.appendingPathComponent(sanitizedKey(key) + ".art")
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Stores artwork data in memory and writes it to disk asynchronously if not already present.
    public func saveArtwork(data: Data, key: String) {
        // Ensure preconditions are met before proceeding
        guard !data.isEmpty, !key.isEmpty else { return }

        // Ns key
        let nsKey = key as NSString
        // Already in memory
        let alreadyInMemory = rawDataCache.object(forKey: nsKey) != nil
        rawDataCache.setObject(data as NSData, forKey: nsKey, cost: data.count)

        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            decodedImageCache.setObject(image, forKey: nsKey)
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            decodedImageCache.setObject(image, forKey: nsKey)
        }
        #endif

        if alreadyInMemory { return }

        // File system location for file url
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

    /// Loads artwork directly as an already-decoded PlatformImage (UIImage / NSImage) on a background thread.
    public func loadDecodedArtwork(key: String) -> PlatformImage? {
        // Ensure preconditions are met before proceeding
        guard !key.isEmpty else { return nil }

        // Ns key
        let nsKey = key as NSString
        if let cachedImage = decodedImageCache.object(forKey: nsKey) {
            return cachedImage
        }

        if let data = loadArtwork(key: key) {
            #if canImport(UIKit)
            if let image = UIImage(data: data) {
                decodedImageCache.setObject(image, forKey: nsKey)
                return image
            }
            #elseif canImport(AppKit)
            if let image = NSImage(data: data) {
                decodedImageCache.setObject(image, forKey: nsKey)
                return image
            }
            #endif
        }
        return nil
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

    /// Clears both memory cache and disk artwork cache.
    public func clearCache() {
        rawDataCache.removeAllObjects()
        decodedImageCache.removeAllObjects()
        if let files = try? fileManager.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
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

    /// Replaces forbidden file system characters with safe underscores.
    private func sanitizedKey(_ key: String) -> String {
        // Invalid characters
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return key.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
}
