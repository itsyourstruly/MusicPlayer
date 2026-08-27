//
//  ArtworkColorExtractor.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Concurrency-safe dominant color analyzer for audio artwork.
public final class ArtworkColorExtractor: @unchecked Sendable {
    public static let shared = ArtworkColorExtractor()

    public struct ColorPalette: Sendable {
        public let primaryColor: Color
        public let isDark: Bool

        public var foregroundColor: Color {
            isDark ? .white : .black
        }

        public var secondaryForegroundColor: Color {
            isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
        }
    }

    private let cache = NSCache<NSString, WrappedPalette>()
    private let lock = NSLock()

    private final class WrappedPalette {
        let palette: ColorPalette
        init(_ palette: ColorPalette) { self.palette = palette }
    }

    private init() {
        cache.countLimit = 100
    }

    /// Asynchronously extracts the primary dominant color from image data with memory caching.
    public func extractPrimaryColor(for key: String?, fallback: Color = Color.appSecondaryBackground) async -> ColorPalette {
        guard let key = key, !key.isEmpty else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        lock.lock()
        if let cached = cache.object(forKey: key as NSString) {
            lock.unlock()
            return cached.palette
        }
        lock.unlock()

        guard let data = await ArtworkCacheService.shared.loadArtwork(key: key) else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        let palette = await Task.detached(priority: .userInitiated) { () -> ColorPalette in
            #if canImport(UIKit)
            guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
                return ColorPalette(primaryColor: fallback, isDark: true)
            }
            return Self.analyze(cgImage: cgImage, fallback: fallback)
            #elseif canImport(AppKit)
            guard let nsImage = NSImage(data: data),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return ColorPalette(primaryColor: fallback, isDark: true)
            }
            return Self.analyze(cgImage: cgImage, fallback: fallback)
            #else
            return ColorPalette(primaryColor: fallback, isDark: true)
            #endif
        }.value

        lock.lock()
        cache.setObject(WrappedPalette(palette), forKey: key as NSString)
        lock.unlock()

        return palette
    }

    private static func analyze(cgImage: CGImage, fallback: Color) -> ColorPalette {
        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        var count: Double = 0

        for i in stride(from: 0, to: rawData.count, by: bytesPerPixel) {
            let a = Double(rawData[i + 3]) / 255.0
            guard a > 0.4 else { continue }
            let r = Double(rawData[i]) / 255.0
            let g = Double(rawData[i + 1]) / 255.0
            let b = Double(rawData[i + 2]) / 255.0

            totalR += r
            totalG += g
            totalB += b
            count += 1
        }

        guard count > 0 else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        let avgR = totalR / count
        let avgG = totalG / count
        let avgB = totalB / count

        // Calculate relative luminance to determine light or dark background
        let luminance = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
        let isDark = luminance < 0.55

        let color = Color(red: avgR, green: avgG, blue: avgB)
        return ColorPalette(primaryColor: color, isDark: isDark)
    }
}
