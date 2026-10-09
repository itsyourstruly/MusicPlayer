import SwiftUI

/// Pure minimal typographic playback control deck without backgrounds.
/// Features prominent text buttons with zero background boxes.
public struct PlayerControlsView: View {
    @Bindable var playerService: AudioPlayerService
    public var foregroundColor: Color
    public var secondaryForegroundColor: Color
    public var canPerformAction: (() -> Bool)? = nil

    @Environment(\.isPlayerDraggingOrDismissing) private var isPlayerDraggingOrDismissing: Bool

    // Initialize with configured properties
    public init(
        playerService: AudioPlayerService,
        foregroundColor: Color = Color.primary,
        secondaryForegroundColor: Color = Color.secondary,
        canPerformAction: (() -> Bool)? = nil
    ) {
        self.playerService = playerService
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.canPerformAction = canPerformAction
    }

    private var canTriggerButtonPress: Bool {
        if isPlayerDraggingOrDismissing { return false }
        if let canPerformAction = canPerformAction, !canPerformAction() { return false }
        return true
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 22) {
            // Main Transport Controls (BACK, PLAY/PAUSE, NEXT) - Pure Prominent Text with Zero Drift
            HStack(spacing: 26) {
                // Previous button
                Button(action: {
                    guard canTriggerButtonPress else { return }
                    guard playerService.hasPreviousTrack else { return }
                    HapticFeedback.trackSkip(forward: false)
                    playerService.previous()
                }) {
                    Text("BACK")
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
                    guard canTriggerButtonPress else { return }
                    if playerService.cloudWaitTrackID != nil { return }
                    HapticFeedback.playPause(isPlaying: !playerService.playbackStatus.isPlaying)
                    playerService.togglePlayPause()
                }) {
                    Group {
                        if playerService.cloudWaitTrackID != nil {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: foregroundColor))
                                .scaleEffect(1.3)
                        } else {
                            Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                                .font(.system(size: 34, weight: .black, design: .monospaced))
                                .foregroundStyle(foregroundColor)
                                .contentTransition(.interpolate)
                        }
                    }
                    .frame(width: 136, height: 52, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Next button
                Button(action: {
                    guard canTriggerButtonPress else { return }
                    guard playerService.hasNextTrack else { return }
                    HapticFeedback.trackSkip(forward: true)
                    playerService.next()
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
                    guard canTriggerButtonPress else { return }
                    HapticFeedback.modeToggle(isOn: playerService.shuffleMode == .off)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        playerService.toggleShuffle()
                    }
                }) {
                    Text("SHUFFLE")
                        .font(.system(size: 12, weight: playerService.shuffleMode == .on ? .black : .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.shuffleMode == .on
                                ? foregroundColor
                                : secondaryForegroundColor.opacity(0.45)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.interpolate)
                        .frame(width: 80, height: 34, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: {
                    guard canTriggerButtonPress else { return }
                    HapticFeedback.modeToggle(isOn: playerService.repeatMode == .off)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        playerService.cycleRepeatMode()
                    }
                }) {
                    Text("REPEAT")
                        .font(.system(size: 12, weight: playerService.repeatMode != .off ? .black : .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.repeatMode != .off
                                ? foregroundColor
                                : secondaryForegroundColor.opacity(0.45)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.interpolate)
                        .frame(width: 80, height: 34, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
