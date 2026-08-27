//
//  PlaybackProgressBar.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI

/// Scrubber display style.
public enum ScrubberStyle {
    /// Thin 4pt bar with a small circle thumb. Used in compact/mini contexts.
    case compact
    /// Expanding bar (no persistent thumb) that grows on drag. Used in full-screen player.
    case fullscreen
}

/// High-performance interactive playback scrubber with dynamic contrast and timestamps.
/// Supports two visual styles: compact (mini-player) and fullscreen (expanding native bar).
public struct PlaybackProgressBar: View {
    @Bindable var playerService: AudioPlayerService
    public var foregroundColor: Color
    public var secondaryForegroundColor: Color
    public var style: ScrubberStyle

    // @GestureState auto-resets to false when the gesture ends or is cancelled —
    // eliminates the isSeeking-stuck-dirty bug from view rebuilds mid-drag.
    @GestureState private var isDragging: Bool = false
    @State private var dragProgress: Double? = nil

    public init(
        playerService: AudioPlayerService,
        foregroundColor: Color = Color.primary,
        secondaryForegroundColor: Color = Color.secondary,
        style: ScrubberStyle = .compact
    ) {
        self.playerService = playerService
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.style = style
    }

    private var effectiveProgress: Double {
        if let drag = dragProgress {
            return drag
        }
        return playerService.progressRatio
    }

    private var currentDisplayTime: TimeInterval {
        if let drag = dragProgress {
            return drag * playerService.duration
        }
        return playerService.currentTime
    }

    public var body: some View {
        switch style {
        case .compact:
            compactScrubber
        case .fullscreen:
            fullscreenScrubber
        }
    }

    // MARK: - Compact Style (existing thin bar + thumb)

    private var compactScrubber: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(foregroundColor.opacity(0.18))
                        .frame(height: 4)

                    // Active progress fill — linear animation in sync with the 0.25s tick interval
                    // to avoid fighting external spring/smooth animations
                    Capsule()
                        .fill(foregroundColor)
                        .frame(
                            width: max(0, min(geometry.size.width * effectiveProgress, geometry.size.width)),
                            height: 4
                        )
                        .animation(isDragging ? nil : .linear(duration: 0.22), value: effectiveProgress)

                    // Scrubber thumb
                    Circle()
                        .fill(foregroundColor)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, min(geometry.size.width * effectiveProgress - 7, geometry.size.width - 14)))
                        .animation(isDragging ? nil : .linear(duration: 0.22), value: effectiveProgress)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geometry.size.width))
            }
            .frame(height: 20)

            timestampRow(large: false)
        }
        // Sync isSeeking with drag state — @GestureState guarantees this resets on cancel
        .onChange(of: isDragging) { _, dragging in
            playerService.isSeeking = dragging
            if !dragging {
                dragProgress = nil
            }
        }
        .onDisappear {
            // Safety net: clear any stale seeking state if the view disappears mid-drag
            if playerService.isSeeking {
                playerService.isSeeking = false
            }
            dragProgress = nil
        }
    }

    // MARK: - Fullscreen Style (expanding bar, no thumb at rest)

    private var fullscreenScrubber: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let trackHeight: CGFloat = isDragging ? 14 : 5

                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(foregroundColor.opacity(0.2))
                        .frame(height: trackHeight)

                    // Active progress fill
                    Capsule()
                        .fill(foregroundColor)
                        .frame(
                            width: max(0, min(geometry.size.width * effectiveProgress, geometry.size.width)),
                            height: trackHeight
                        )
                        // Linear ticks when idle; instant response during drag
                        .animation(isDragging ? nil : .linear(duration: 0.22), value: effectiveProgress)
                }
                // Bar height springs smoothly when drag starts/ends
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.72), value: isDragging)
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geometry.size.width))
            }
            .frame(height: 28)

            timestampRow(large: true)
        }
        .onChange(of: isDragging) { _, dragging in
            playerService.isSeeking = dragging
            if !dragging {
                dragProgress = nil
            }
        }
        .onDisappear {
            if playerService.isSeeking {
                playerService.isSeeking = false
            }
            dragProgress = nil
        }
    }

    // MARK: - Shared Helpers

    /// Unified drag gesture used by both styles.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                dragProgress = max(0, min(value.location.x / width, 1.0))
            }
            .onEnded { value in
                let progress = max(0, min(value.location.x / width, 1.0))
                playerService.seek(to: progress * playerService.duration)
                // dragProgress and isSeeking are cleared by onChange(of: isDragging)
                // when @GestureState resets to false automatically after onEnded
            }
    }

    /// Elapsed / remaining timestamp row.
    private func timestampRow(large: Bool) -> some View {
        HStack {
            Text(TimeFormatting.format(seconds: currentDisplayTime))
                .font(large
                    ? .system(size: 13, weight: .semibold, design: .rounded)
                    : .system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(secondaryForegroundColor)
                .monospacedDigit()

            Spacer()

            Text(TimeFormatting.formatRemaining(current: currentDisplayTime, total: playerService.duration))
                .font(large
                    ? .system(size: 13, weight: .semibold, design: .rounded)
                    : .system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(secondaryForegroundColor)
                .monospacedDigit()
        }
    }
}
