import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// High-performance asynchronous album artwork view with decoded image caching and typographic fallback.
public struct AlbumArtworkView: View {
    @Environment(LibraryStore.self) private var libraryStore: LibraryStore?

    // Artwork key
    public let artworkKey: String?
    // Display title
    public let title: String
    // Subtitle
    public let subtitle: String?
    public var cornerRadius: CGFloat = 8
    public var targetDimension: CGFloat = 128
    public var isArtworkRounded: Bool? = nil

    @State private var loadedImage: Image?
    @State private var isLoading: Bool = false

    // Initialize with configured properties
    public init(
        artworkKey: String?,
        title: String,
        subtitle: String? = nil,
        cornerRadius: CGFloat = 8,
        targetDimension: CGFloat = 128,
        isArtworkRounded: Bool? = nil
    ) {
        self.artworkKey = artworkKey
        self.title = title
        self.subtitle = subtitle
        self.cornerRadius = cornerRadius
        self.targetDimension = targetDimension
        self.isArtworkRounded = isArtworkRounded

        if let key = artworkKey, !key.isEmpty,
           let cached = ArtworkCacheService.shared.cachedImage(key: key, maxDimension: targetDimension) {
            #if canImport(UIKit)
            _loadedImage = State(initialValue: Image(uiImage: cached))
            #elseif canImport(AppKit)
            _loadedImage = State(initialValue: Image(nsImage: cached))
            #endif
        } else {
            _loadedImage = State(initialValue: nil)
        }
    }

    private static let hasArtAsset: Bool = {
        #if canImport(UIKit)
        return UIImage(named: "art") != nil
        #elseif canImport(AppKit)
        return NSImage(named: "art") != nil
        #else
        return true
        #endif
    }()

    private var effectiveCornerRadius: CGFloat {
        let isRounded = isArtworkRounded ?? libraryStore?.settings.isArtworkRounded ?? (UserDefaults.standard.object(forKey: "isArtworkRounded") as? Bool ?? true)
        return isRounded ? cornerRadius : 0
    }

    public var body: some View {
        ZStack {
            if let image = loadedImage {
                image
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(1.0, contentMode: .fill)
            } else {
                defaultArtworkPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous))
        .task(id: artworkKey) {
            await loadArtwork()
        }
    }

    @ViewBuilder
    private var defaultArtworkPlaceholder: some View {
        #if canImport(UIKit)
        if Self.hasArtAsset {
            Image("art")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(1.0, contentMode: .fill)
        } else {
            typographicPlaceholder
        }
        #elseif canImport(AppKit)
        if Self.hasArtAsset {
            Image("art")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(1.0, contentMode: .fill)
        } else {
            typographicPlaceholder
        }
        #else
        Image("art")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(1.0, contentMode: .fill)
        #endif
    }

    private var typographicPlaceholder: some View {
        ZStack {
            Color.appSecondaryBackground

            VStack(spacing: 4) {
                Text(initials(from: title))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.8))

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(4)
        }
        .aspectRatio(1.0, contentMode: .fill)
    }

    // Load artwork
    private func loadArtwork() async {
        guard let key = artworkKey, !key.isEmpty else {
            if loadedImage != nil { loadedImage = nil }
            return
        }

        // Fast synchronous memory cache check
        if let cached = ArtworkCacheService.shared.cachedImage(key: key, maxDimension: targetDimension) {
            #if canImport(UIKit)
            self.loadedImage = Image(uiImage: cached)
            #elseif canImport(AppKit)
            self.loadedImage = Image(nsImage: cached)
            #endif
            return
        }

        // Load full native quality decoded artwork from cache
        let platformImg = await ArtworkCacheService.shared.loadDecodedArtwork(key: key, maxDimension: targetDimension)
        guard !Task.isCancelled else { return }

        if let platformImg = platformImg {
            #if canImport(UIKit)
            let img = Image(uiImage: platformImg)
            #elseif canImport(AppKit)
            let img = Image(nsImage: platformImg)
            #endif
            self.loadedImage = img
        } else {
            self.loadedImage = nil
        }
    }

    // Initials
    private func initials(from text: String) -> String {
        // Words
        let words = text.split(separator: " ")
        if words.count >= 2 {
            // First
            let first = words[0].prefix(1)
            // Second
            let second = words[1].prefix(1)
            return "\(first)\(second)".uppercased()
        } else if let firstWord = words.first {
            return String(firstWord.prefix(2)).uppercased()
        }
        return "AUDIO"
    }
}
