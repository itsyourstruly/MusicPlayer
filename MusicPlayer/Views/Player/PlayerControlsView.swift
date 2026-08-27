import SwiftUI

/// Pure minimal typographic playback control deck without backgrounds.
/// Features prominent text buttons with zero background boxes.
public struct PlayerControlsView: View {
    @Bindable var playerService: AudioPlayerService
    public var foregroundColor: Color
    public var secondaryForegroundColor: Color

    // Initialize with configured properties
    public init(
        playerService: AudioPlayerService,
        foregroundColor: Color = Color.primary,
        secondaryForegroundColor: Color = Color.secondary
    ) {
        self.playerService = playerService
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 22) {
            // Main Transport Controls (PREV, PLAY/PAUSE, NEXT) - Pure Prominent Text with Zero Drift
            HStack(spacing: 26) {
                // Previous button
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        playerService.previous()
                    }
                }) {
                    Text("PREV")
                        .font(.system(size: 19, weight: .heavy, design: .monospaced))
                        .foregroundStyle(
                            playerService.hasPreviousTrack
                                ? foregroundColor
                                : secondaryForegroundColor.opacity(0.3)
                        )
                        .frame(width: 72, height: 52, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!playerService.hasPreviousTrack)

                // Play / Pause prominent text button
                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) {
                        playerService.togglePlayPause()
                    }
                }) {
                    Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                        .font(.system(size: 34, weight: .black, design: .monospaced))
                        .foregroundStyle(foregroundColor)
                        .contentTransition(.interpolate)
                        .frame(width: 136, height: 52, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Next button
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        playerService.next()
                    }
                }) {
                    Text("NEXT")
                        .font(.system(size: 19, weight: .heavy, design: .monospaced))
                        .foregroundStyle(
                            playerService.hasNextTrack
                                ? foregroundColor
                                : secondaryForegroundColor.opacity(0.3)
                        )
                        .frame(width: 72, height: 52, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!playerService.hasNextTrack)
            }

            // Secondary Mode Toggles (SHUFFLE & REPEAT) - Pure Text (Strict Single Row, Zero Wrap)
            HStack(spacing: 20) {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        playerService.toggleShuffle()
                    }
                }) {
                    Text(playerService.shuffleMode.label)
                        .font(.system(size: 12, weight: playerService.shuffleMode == .on ? .black : .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.shuffleMode == .on
                                ? foregroundColor
                                : secondaryForegroundColor.opacity(0.45)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.interpolate)
                        .frame(width: 114, height: 34, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        playerService.cycleRepeatMode()
                    }
                }) {
                    Text(playerService.repeatMode.label)
                        .font(.system(size: 12, weight: playerService.repeatMode != .off ? .black : .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.repeatMode != .off
                                ? foregroundColor
                                : secondaryForegroundColor.opacity(0.45)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.interpolate)
                        .frame(width: 114, height: 34, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
