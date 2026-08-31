import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// High-performance asynchronous album artwork view with decoded image caching and typographic fallback.
public struct AlbumArtworkView: View {
    // Artwork key
    public let artworkKey: String?
    // Display title
    public let title: String
    // Subtitle
    public let subtitle: String?
    public var cornerRadius: CGFloat = 8

    @State private var loadedImage: Image?
    @State private var isLoading: Bool = false

    // Initialize with configured properties
    public init(
        artworkKey: String?,
        title: String,
        subtitle: String? = nil,
        cornerRadius: CGFloat = 8
    ) {
        self.artworkKey = artworkKey
        self.title = title
        self.subtitle = subtitle
        self.cornerRadius = cornerRadius
    }

    // Main view layout structure
    public var body: some View {
        ZStack {
            if let image = loadedImage {
                image
                    .resizable()
                    .aspectRatio(1.0, contentMode: .fill)
                    .transition(.opacity)
            } else {
                typographicPlaceholder
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            Task {
                await loadArtwork()
            }
        }
        .onDisappear {
            // Free the decoded image bitmap immediately upon exiting the viewport to keep memory minimal
            self.loadedImage = nil
        }
        .task(id: artworkKey) {
            await loadArtwork()
        }
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

        // Load downsampled decoded artwork from disk cache with zero memory bloat
        let platformImg = await ArtworkCacheService.shared.loadDecodedArtwork(key: key, maxDimension: 400)
        guard !Task.isCancelled else { return }

        if let platformImg = platformImg {
            #if canImport(UIKit)
            let img = Image(uiImage: platformImg)
            #elseif canImport(AppKit)
            let img = Image(nsImage: platformImg)
            #endif
            withAnimation(.easeOut(duration: 0.18)) {
                self.loadedImage = img
            }
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
