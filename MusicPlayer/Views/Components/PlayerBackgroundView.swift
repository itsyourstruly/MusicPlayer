import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// High-performance, stationary full-screen player background supporting Solid Theme,
/// Dynamic Album Color, and Blurred Artwork modes with pure in-place crossfade transitions.
public struct PlayerBackgroundView: View {
    public let style: PlayerBackgroundStyle
    public let appTheme: AppTheme
    public let primaryColor: Color
    public let artworkKey: String?
    public var cornerRadius: CGFloat = 0
    public var overlayOpacity: Double = 0.50

    @State private var currentImage: PlatformImage? = nil
    @State private var previousImage: PlatformImage? = nil
    @State private var crossfadeOpacity: Double = 1.0
    @State private var currentColor: Color = Color.black
    @State private var previousColor: Color? = nil
    @State private var colorCrossfadeOpacity: Double = 1.0
    @State private var loadTask: Task<Void, Never>? = nil

    public init(
        style: PlayerBackgroundStyle,
        appTheme: AppTheme,
        primaryColor: Color,
        artworkKey: String?,
        cornerRadius: CGFloat = 0,
        overlayOpacity: Double = 0.50
    ) {
        self.style = style
        self.appTheme = appTheme
        self.primaryColor = primaryColor
        self.artworkKey = artworkKey
        self.cornerRadius = cornerRadius
        self.overlayOpacity = overlayOpacity
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // Base Dark Background
                Color.black
                    .frame(width: width, height: height)
                    .transition(.identity)

                // 1. Solid Theme Layer
                appTheme.solidPlayerBackground
                    .overlay(Color.black.opacity(0.20))
                    .frame(width: width, height: height)
                    .opacity(style == .solid ? 1.0 : 0.0)
                    .transition(.identity)

                // 2. Dynamic Primary Album Color Layer (Pure In-Place Color Crossfade)
                ZStack {
                    if let prevColor = previousColor {
                        prevColor
                            .overlay(Color.black.opacity(0.35))
                            .frame(width: width, height: height)
                            .transition(.identity)
                    }

                    currentColor
                        .overlay(Color.black.opacity(0.35))
                        .frame(width: width, height: height)
                        .opacity(colorCrossfadeOpacity)
                        .transition(.identity)
                }
                .frame(width: width, height: height)
                .opacity(style == .albumColor ? 1.0 : 0.0)
                .transition(.identity)

                // 3. Blurred Album Artwork Layer (Completely in-place crossfade)
                ZStack {
                    // Outgoing Artwork (Frozen in place during transition)
                    if let prev = previousImage {
                        platformImageView(for: prev)
                            .scaledToFill()
                            .frame(width: width, height: height, alignment: .center)
                            .clipped()
                            .blur(radius: 50, opaque: true)
                            .transition(.identity)
                    }

                    // Incoming Artwork (Smoothly fades in over previous)
                    if let curr = currentImage {
                        platformImageView(for: curr)
                            .scaledToFill()
                            .frame(width: width, height: height, alignment: .center)
                            .clipped()
                            .blur(radius: 50, opaque: true)
                            .opacity(crossfadeOpacity)
                            .transition(.identity)
                    }
                }
                .overlay(Color.black.opacity(overlayOpacity))
                .frame(width: width, height: height)
                .opacity(style == .albumBlur ? 1.0 : 0.0)
                .transition(.identity)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: artworkKey) {
                await handleArtworkChange(newKey: artworkKey)
            }
            .onChange(of: primaryColor) { _, newColor in
                handleColorChange(newColor: newColor)
            }
            .onAppear {
                currentColor = primaryColor
            }
        }
        .animation(.easeInOut(duration: 0.45), value: style)
    }

    @ViewBuilder
    private func platformImageView(for image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
        #endif
    }

    private func handleArtworkChange(newKey: String?) async {
        loadTask?.cancel()

        guard let key = newKey, !key.isEmpty else {
            withAnimation(.easeInOut(duration: 0.45)) {
                previousImage = currentImage
                currentImage = nil
                crossfadeOpacity = 1.0
            }
            return
        }

        let loaded = await ArtworkCacheService.shared.loadDecodedArtwork(key: key, maxDimension: 128)

        guard !Task.isCancelled else { return }

        if let loaded = loaded {
            if currentImage == nil {
                // Initial load: instant display
                currentImage = loaded
                previousImage = nil
                crossfadeOpacity = 1.0
            } else if loaded !== currentImage {
                // New artwork: preserve previous in place and crossfade incoming in
                previousImage = currentImage
                currentImage = loaded
                crossfadeOpacity = 0.0

                withAnimation(.easeInOut(duration: 0.55)) {
                    crossfadeOpacity = 1.0
                }

                // After crossfade ends, clear previous image
                loadTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled {
                        previousImage = nil
                    }
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.45)) {
                previousImage = currentImage
                currentImage = nil
                crossfadeOpacity = 1.0
            }
        }
    }

    private func handleColorChange(newColor: Color) {
        guard newColor != currentColor else { return }
        previousColor = currentColor
        currentColor = newColor
        colorCrossfadeOpacity = 0.0

        withAnimation(.easeInOut(duration: 0.55)) {
            colorCrossfadeOpacity = 1.0
        }

        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled {
                previousColor = nil
            }
        }
    }
}
