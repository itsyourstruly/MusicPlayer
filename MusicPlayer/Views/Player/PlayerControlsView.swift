import SwiftUI

/// Pure minimal typographic playback control deck without backgrounds.
/// Features prominent text buttons with zero background boxes.
public struct PlayerControlsView: View {
    @Bindable var playerService: AudioPlayerService
    public var foregroundColor: Color
    public var secondaryForegroundColor: Color
    public var canPerformAction: (() -> Bool)? = nil
    /// When true, the controls show symbol icons instead of text labels (same frames and tap areas).
    public var useIcons: Bool = false
    /// When true, the play/pause glyph is invisible (frame and tap area unchanged) while the expandable
    /// player draws its own floating morphing copy in its place.
    public var hidesPlayPauseGlyph: Bool = false

    @Environment(\.isPlayerDraggingOrDismissing) private var isPlayerDraggingOrDismissing: Bool

    // Initialize with configured properties
    public init(
        playerService: AudioPlayerService,
        foregroundColor: Color = Color.primary,
        secondaryForegroundColor: Color = Color.secondary,
        canPerformAction: (() -> Bool)? = nil,
        useIcons: Bool = false,
        hidesPlayPauseGlyph: Bool = false
    ) {
        self.playerService = playerService
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.canPerformAction = canPerformAction
        self.useIcons = useIcons
        self.hidesPlayPauseGlyph = hidesPlayPauseGlyph
    }

    private var repeatAccessibilityValue: String {
        switch playerService.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
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
                    HapticFeedback.transport(.back)
                    playerService.previous()
                }) {
                    Group {
                        if useIcons {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 26, weight: .heavy))
                                .accessibilityLabel("Previous Track")
                        } else {
                            Text("BACK")
                                .font(.system(size: 19, weight: .heavy, design: .monospaced))
                        }
                    }
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
                    HapticFeedback.transport(playerService.willPauseOnToggle ? .pause : .play)
                    playerService.togglePlayPause()
                }) {
                    Group {
                        if playerService.cloudWaitTrackID != nil {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: foregroundColor))
                                .scaleEffect(1.3)
                        } else {
                            if useIcons {
                                // In-place crossfade with a subtle scale (~0.2s) between play and pause.
                                // The two glyphs overlap in the ZStack while one fades out and the other fades in.
                                ZStack {
                                    Image(systemName: playerService.playbackStatus.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 50, weight: .black))
                                        .foregroundStyle(foregroundColor)
                                        .id(playerService.playbackStatus.isPlaying)
                                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                                }
                                .animation(.easeInOut(duration: 0.2), value: playerService.playbackStatus.isPlaying)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(playerService.playbackStatus.isPlaying ? "Pause" : "Play")
                            } else {
                                Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                                    .font(.system(size: 34, weight: .black, design: .monospaced))
                                    .foregroundStyle(foregroundColor)
                                    .contentTransition(.interpolate)
                            }
                        }
                    }
                    // Reports the glyph's frame for the expandable player's play/pause morph
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PlayerPlayPauseGlyphFrameKey.self,
                                value: proxy.frame(in: .named(PlayerMorphSpace.fullscreen))
                            )
                        }
                    )
                    .opacity(hidesPlayPauseGlyph ? 0 : 1)
                    .animation(nil, value: hidesPlayPauseGlyph)
                    .frame(width: 136, height: 52, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Next button
                Button(action: {
                    guard canTriggerButtonPress else { return }
                    guard playerService.hasNextTrack else { return }
                    HapticFeedback.transport(.next)
                    playerService.next()
                }) {
                    Group {
                        if useIcons {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 26, weight: .heavy))
                                .accessibilityLabel("Next Track")
                        } else {
                            Text("NEXT")
                                .font(.system(size: 19, weight: .heavy, design: .monospaced))
                        }
                    }
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
                    Group {
                        if useIcons {
                            Image(systemName: "shuffle")
                                .font(.system(size: 18, weight: playerService.shuffleMode == .on ? .bold : .semibold))
                                .accessibilityLabel("Shuffle")
                                .accessibilityValue(playerService.shuffleMode == .on ? "On" : "Off")
                        } else {
                            Text("SHUFFLE")
                                .font(.system(size: 12, weight: playerService.shuffleMode == .on ? .black : .bold, design: .monospaced))
                        }
                    }
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
                    Group {
                        if useIcons {
                            Image(systemName: playerService.repeatMode == .one ? "repeat.1" : "repeat")
                                .font(.system(size: 18, weight: playerService.repeatMode != .off ? .bold : .semibold))
                                .contentTransition(.symbolEffect(.replace, options: .speed(2.0)))
                                .accessibilityLabel("Repeat")
                                .accessibilityValue(repeatAccessibilityValue)
                        } else {
                            Text(playerService.repeatMode == .one ? "ONE" : playerService.repeatMode == .all ? "ALL" : "REPEAT")
                                .font(.system(size: 12, weight: playerService.repeatMode != .off ? .black : .bold, design: .monospaced))
                        }
                    }
                        .foregroundStyle(
                            playerService.repeatMode != .off
                                ? Color.white
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

// MARK: - Play/Pause Morph Geometry

/// Coordinate space names shared with the expandable player's play/pause morph.
public enum PlayerMorphSpace {
    /// Named on the expandable player's fullscreen layer (unaffected by the layer's own transition offset).
    public static let fullscreen = "PlayerMorphFullscreenSpace"
}

/// Frame of the fullscreen play/pause glyph in `PlayerMorphSpace.fullscreen`.
public struct PlayerPlayPauseGlyphFrameKey: PreferenceKey {
    public static var defaultValue: CGRect = .zero
    public static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}
