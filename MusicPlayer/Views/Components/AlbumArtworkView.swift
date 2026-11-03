import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// High-performance asynchronous album artwork view with decoded image caching and typographic fallback.
public struct AlbumArtworkView: View {
    @Environment(LibraryStore.self) private var libraryStore: LibraryStore?
    @Environment(\.displayScale) private var displayScale: CGFloat

    // Artwork key
    public let artworkKey: String?
    // Display title
    public let title: String
    // Subtitle
    public let subtitle: String?
    public var cornerRadius: CGFloat = 8
    public var targetDimension: CGFloat = 128
    public var isOriginalResolution: Bool = false
    public var isArtworkRounded: Bool? = nil
    /// Server artist photo shown over the album art once it has loaded (artist rows only).
    public var artistImage: ServerArtistImage? = nil

    @State private var loadedImage: Image?
    @State private var artistPhoto: Image?
    /// Rendered side length in points (measured), so thumbnails decode at the size actually displayed.
    @State private var renderedSide: CGFloat = 0

    // Initialize with configured properties
    public init(
        artworkKey: String?,
        title: String,
        subtitle: String? = nil,
        cornerRadius: CGFloat = 8,
        targetDimension: CGFloat = 128,
        isOriginalResolution: Bool = false,
        isArtworkRounded: Bool? = nil,
        artistImage: ServerArtistImage? = nil
    ) {
        self.artworkKey = artworkKey
        self.title = title
        self.subtitle = subtitle
        self.cornerRadius = cornerRadius
        self.targetDimension = targetDimension
        self.isOriginalResolution = isOriginalResolution
        self.isArtworkRounded = isArtworkRounded
        self.artistImage = artistImage

        if let artistKey = artistImage?.key,
           let cached = ArtworkCacheService.shared.cachedImage(key: artistKey, maxDimension: targetDimension,
                                                               isOriginal: isOriginalResolution || artistImage?.prefersOriginal == true)
            ?? ArtworkCacheService.shared.cachedImage(key: artistKey, maxDimension: targetDimension) {
            _artistPhoto = State(initialValue: Self.image(cached))
        } else {
            _artistPhoto = State(initialValue: nil)
        }

        if let key = artworkKey, !key.isEmpty {
            if let cached = ArtworkCacheService.shared.cachedImage(key: key, maxDimension: targetDimension, isOriginal: isOriginalResolution) {
                #if canImport(UIKit)
                _loadedImage = State(initialValue: Image(uiImage: cached))
                #elseif canImport(AppKit)
                _loadedImage = State(initialValue: Image(nsImage: cached))
                #endif
            } else if (isOriginalResolution || targetDimension >= 1200),
                      let thumb = ArtworkCacheService.shared.cachedImage(key: key, maxDimension: 160) {
                #if canImport(UIKit)
                _loadedImage = State(initialValue: Image(uiImage: thumb))
                #elseif canImport(AppKit)
                _loadedImage = State(initialValue: Image(nsImage: thumb))
                #endif
            } else {
                _loadedImage = State(initialValue: nil)
            }
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

            if let artistPhoto {
                artistPhoto
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(1.0, contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { proxy in
            min(proxy.size.width, proxy.size.height)
        } action: { side in
            renderedSide = side
        }
        .task(id: loadIdentity) {
            await loadArtwork()
        }
        .task(id: artistLoadIdentity) {
            await loadArtistPhoto()
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

    /// Pixel size to decode: the measured on-screen size × display scale (falls back to `targetDimension`
    /// until layout reports a size), rounded up to the cache's size buckets.
    private var requestedPixels: CGFloat {
        if isOriginalResolution { return targetDimension }
        let points = renderedSide > 0 ? renderedSide : targetDimension
        return points * displayScale
    }

    /// The load restarts only when the artwork (or the original/thumbnail tier) changes, never when layout
    /// reports a size: the bucket is chosen inside the task once the size is known.
    private var loadIdentity: String {
        "\(artworkKey ?? "")_\(isOriginalResolution ? "orig" : "thumb")"
    }

    // Load artwork
    private func loadArtwork() async {
        guard let key = artworkKey, !key.isEmpty else {
            if loadedImage != nil { loadedImage = nil }
            return
        }

        // Pick the bucket after layout: wait (a few frames at most) for the measured size instead of decoding at a
        // guessed size; the size change itself does not restart this task.
        var framesWaited = 0
        while renderedSide == 0 && !isOriginalResolution && framesWaited < 6 {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            framesWaited += 1
        }

        let dimensionToRequest = requestedPixels

        // Fast synchronous memory cache check for requested dimension
        if let cached = ArtworkCacheService.shared.cachedImage(key: key, maxDimension: dimensionToRequest, isOriginal: isOriginalResolution) {
            #if canImport(UIKit)
            self.loadedImage = Image(uiImage: cached)
            #elseif canImport(AppKit)
            self.loadedImage = Image(nsImage: cached)
            #endif
            return
        }

        // If full resolution is requested and no image is shown yet, display thumbnail as interim state
        if (isOriginalResolution || targetDimension >= 1200) && loadedImage == nil {
            if let thumb = ArtworkCacheService.shared.cachedImage(key: key, maxDimension: 160) {
                #if canImport(UIKit)
                self.loadedImage = Image(uiImage: thumb)
                #elseif canImport(AppKit)
                self.loadedImage = Image(nsImage: thumb)
                #endif
            }
        }

        // Load full native quality decoded artwork from cache / remote
        let platformImg = await ArtworkCacheService.shared.loadDecodedArtwork(key: key, maxDimension: dimensionToRequest, isOriginal: isOriginalResolution)
        guard !Task.isCancelled else { return }

        if let platformImg = platformImg {
            #if canImport(UIKit)
            let img = Image(uiImage: platformImg)
            #elseif canImport(AppKit)
            let img = Image(nsImage: platformImg)
            #endif
            withAnimation(.easeIn(duration: 0.15)) {
                self.loadedImage = img
            }
        } else if loadedImage == nil {
            self.loadedImage = nil
        }
    }

    private var artistLoadIdentity: String {
        "\(artistImage?.key ?? "")_\(isOriginalResolution || artistImage?.prefersOriginal == true ? "orig" : "thumb")"
    }

    /// Rows wait this long before asking for an artist photo that is not cached, so rows flown past during a
    /// fast scroll never send a request (their task is cancelled first). Cached photos and album art are instant.
    private static let artistPhotoSettleDelay: Duration = .milliseconds(200)

    /// Loads the server artist photo through the shared artwork cache (memory → disk → server, decoded off the
    /// main thread, "no image" answers remembered) and fades it in over the album art.
    private func loadArtistPhoto() async {
        guard let artistImage else {
            if artistPhoto != nil { artistPhoto = nil }
            return
        }
        artistImage.register()
        let wantsOriginal = isOriginalResolution || artistImage.prefersOriginal

        var framesWaited = 0
        while renderedSide == 0 && !wantsOriginal && framesWaited < 6 {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            framesWaited += 1
        }
        let dimensionToRequest = requestedPixels

        if let cached = ArtworkCacheService.shared.cachedImage(key: artistImage.key, maxDimension: dimensionToRequest, isOriginal: wantsOriginal) {
            artistPhoto = Self.image(cached)
            return
        }
        if wantsOriginal, let thumb = ArtworkCacheService.shared.cachedImage(key: artistImage.key, maxDimension: dimensionToRequest) {
            // Header: show the cached list-size photo while the full-size one loads.
            artistPhoto = Self.image(thumb)
        } else if artistPhoto != nil {
            // A reused view must not keep the previous artist's photo while this one loads.
            artistPhoto = nil
        }

        if !wantsOriginal && !ArtworkCacheService.hasCachedArtworkFile(key: artistImage.key) {
            do { try await Task.sleep(for: Self.artistPhotoSettleDelay) } catch { return }
        }

        let platformImg = await ArtworkCacheService.shared.loadDecodedArtwork(key: artistImage.key, maxDimension: dimensionToRequest, isOriginal: wantsOriginal)
        guard !Task.isCancelled, let platformImg else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            artistPhoto = Self.image(platformImg)
        }
    }

    #if canImport(UIKit)
    private static func image(_ platform: UIImage) -> Image { Image(uiImage: platform) }
    #elseif canImport(AppKit)
    private static func image(_ platform: NSImage) -> Image { Image(nsImage: platform) }
    #endif

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
