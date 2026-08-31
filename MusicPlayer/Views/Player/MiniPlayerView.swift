import SwiftUI

/// Flat, dynamic album-colored miniplayer with pure text prominent controls,
/// tap/swipe expansion, and strictly bounded hit-testing that never blocks the background UI.
public struct MiniPlayerView: View {
    @Bindable var playerService: AudioPlayerService
    public let onExpand: () -> Void

    @State private var palette: ArtworkColorExtractor.ColorPalette = ArtworkColorExtractor.ColorPalette(
        primaryColor: Color.appSecondaryBackground,
        isDark: true
    )
    @State private var dragOffset: CGSize = .zero

    // Initialize with configured properties
    public init(
        playerService: AudioPlayerService,
        onExpand: @escaping () -> Void
    ) {
        self.playerService = playerService
        self.onExpand = onExpand
    }

    // Main view layout structure
    public var body: some View {
        if let track = playerService.currentTrack {
            HStack(spacing: 12) {
                // Leading Album Artwork Thumbnail
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 8
                )
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)

                // Track Title & Artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.foregroundColor)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryForegroundColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 4)

                // Play / Pause Pure Text Button
                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) {
                        playerService.togglePlayPause()
                    }
                }) {
                    Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(palette.foregroundColor)
                        .contentTransition(.interpolate)
                        .frame(width: 58, height: 36, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 24)
            .padding(.vertical, 8)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.primaryColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.foregroundColor.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 12, x: 0, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .offset(x: dragOffset.width * 0.3, y: min(0, dragOffset.height * 0.4))
            .onTapGesture {
                HapticFeedback.lightImpact()
                onExpand()
            }
            // Interactive drag and touch gesture handling
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        // H
                        let h = value.translation.height
                        // W
                        let w = value.translation.width

                        // Swipe Up -> Expand Full Screen
                        if h < -35 && abs(h) > abs(w) {
                            HapticFeedback.lightImpact()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                dragOffset = .zero
                                onExpand()
                            }
                        }
                        // Swipe Left -> Next Track
                        else if w < -40 && abs(w) > abs(h) {
                            HapticFeedback.selectionChanged()
                            dragOffset = .zero
                            playerService.next()
                        }
                        // Swipe Right -> Previous Track
                        else if w > 40 && abs(w) > abs(h) {
                            HapticFeedback.selectionChanged()
                            dragOffset = .zero
                            playerService.previous()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = .zero
                            }
                            if abs(w) < 10 && abs(h) < 10 {
                                HapticFeedback.lightImpact()
                                onExpand()
                            }
                        }
                    }
            )
            // Async lifecycle task
            .task(id: track.artworkKey) {
                // New palette
                let newPalette = await ArtworkColorExtractor.shared.extractPrimaryColor(
                    for: track.artworkKey,
                    fallback: Color.appSecondaryBackground
                )
                withAnimation(.easeInOut(duration: 0.65)) {
                    self.palette = newPalette
                }
            }
        }
    }
}
