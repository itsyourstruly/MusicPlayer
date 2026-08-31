import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Concurrency-safe dominant color analyzer for audio artwork.
///
/// Downsamples artwork to a 16×16 thumbnail before averaging, keeping CPU time
/// well under a millisecond while still capturing the overall color mood of the image.
public final class ArtworkColorExtractor: @unchecked Sendable {
    public static let shared = ArtworkColorExtractor()

    /// Derived palette returned for a piece of artwork.
    public struct ColorPalette: Sendable {
        // Primary color
        public let primaryColor: Color
        /// Whether the dominant color is dark enough that white text should be placed on top of it.
        public let isDark: Bool

        /// Contrasting text color appropriate for overlay on the primary color.
        public var foregroundColor: Color {
            isDark ? .white : .black
        }

        /// Dimmed secondary text, still readable against the primary color.
        public var secondaryForegroundColor: Color {
            isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)
        }
    }

    // NSCache is inherently thread-safe for concurrent read/write
    private let cache = NSCache<NSString, WrappedPalette>()

    // Thin wrapper so NSCache can hold a value type
    private final class WrappedPalette: @unchecked Sendable {
        let palette: ColorPalette
        // Initialize with configured properties
        init(_ palette: ColorPalette) { self.palette = palette }
    }

    // Initialize with configured properties
    private init() {
        // Cap at 100 artworks — enough for a full album grid view without excessive memory pressure
        cache.countLimit = 100
    }

    // MARK: - Public API

    /// Asynchronously extracts the primary dominant color from image data with memory caching.
    ///
    /// Falls back to `fallback` when the key is nil/empty or artwork data cannot be loaded.
    public func extractPrimaryColor(for key: String?, fallback: Color = Color.appSecondaryBackground) async -> ColorPalette {
        // Ensure preconditions are met before proceeding
        guard let key = key, !key.isEmpty else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        // Check cache before doing any async work
        if let cached = cache.object(forKey: key as NSString) {
            return cached.palette
        }

        // Ensure preconditions are met before proceeding
        guard let data = await ArtworkCacheService.shared.loadArtwork(key: key) else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        // Offload pixel analysis to a background thread — CGContext rendering is CPU-bound
        let palette = await Task.detached(priority: .userInitiated) { () -> ColorPalette in
            #if canImport(UIKit)
            // Ensure preconditions are met before proceeding
            guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
                return ColorPalette(primaryColor: fallback, isDark: true)
            }
            return Self.analyze(cgImage: cgImage, fallback: fallback)
            #elseif canImport(AppKit)
            // Ensure preconditions are met before proceeding
            guard let nsImage = NSImage(data: data),
                  // Cg image
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return ColorPalette(primaryColor: fallback, isDark: true)
            }
            return Self.analyze(cgImage: cgImage, fallback: fallback)
            #else
            return ColorPalette(primaryColor: fallback, isDark: true)
            #endif
        }.value

        cache.setObject(WrappedPalette(palette), forKey: key as NSString)
        return palette
    }

    // MARK: - Analysis

    /// Downsamples the image to 16×16 and averages non-transparent pixels to find the dominant color.
    private static func analyze(cgImage: CGImage, fallback: Color) -> ColorPalette {
        // 16×16 is the minimum size that gives a stable color average while keeping render cost trivial
        let width = 16
        // Height
        let height = 16
        // Color space
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Bytes per pixel
        let bytesPerPixel = 4
        // Bytes per row
        let bytesPerRow = bytesPerPixel * width
        // Bits per component
        let bitsPerComponent = 8
        // Raw data
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        // Ensure preconditions are met before proceeding
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

        // Total r
        var totalR: Double = 0
        // Total g
        var totalG: Double = 0
        // Total b
        var totalB: Double = 0
        // Count
        var count: Double = 0

        for i in stride(from: 0, to: rawData.count, by: bytesPerPixel) {
            // A
            let a = Double(rawData[i + 3]) / 255.0
            // Skip pixels that are mostly transparent — they'd dilute the true album color
            guard a > 0.4 else { continue }
            // R
            let r = Double(rawData[i]) / 255.0
            // G
            let g = Double(rawData[i + 1]) / 255.0
            // B
            let b = Double(rawData[i + 2]) / 255.0

            totalR += r
            totalG += g
            totalB += b
            count += 1
        }

        // Ensure preconditions are met before proceeding
        guard count > 0 else {
            return ColorPalette(primaryColor: fallback, isDark: true)
        }

        // Avg r
        let avgR = totalR / count
        // Avg g
        let avgG = totalG / count
        // Avg b
        let avgB = totalB / count

        // ITU-R BT.709 coefficients for perceptual luminance — green contributes far more than blue
        let luminance = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
        // Threshold slightly above 0.5 so mid-grey leans dark, keeping white text readable by default
        let isDark = luminance < 0.55

        // Color
        let color = Color(red: avgR, green: avgG, blue: avgB)
        return ColorPalette(primaryColor: color, isDark: isDark)
    }
}
