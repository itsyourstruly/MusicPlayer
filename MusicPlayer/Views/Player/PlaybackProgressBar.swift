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
    public var audioSpecs: String?
    public var useProgressBar: Bool
    public var onCollapse: (() -> Void)?

    // Gesture direction disambiguation state
    private enum ScrubberGestureMode {
        case idle
        case undecided
        case scrubbing
        case pullingDown
    }
    @State private var gestureMode: ScrubberGestureMode = .idle
    @State private var hasTriggeredCollapse: Bool = false

    // State machine for scrubbing, tapping, and glide transitions
    @State private var dragProgress: Double? = nil
    @State private var pendingSeekProgress: Double? = nil
    @State private var isActivelyDragging: Bool = false
    @State private var isGliding: Bool = false
    @State private var dragStartLocationX: CGFloat = 0
    @State private var lastScrubBucket: Int = -1
    @State private var lastScrubDate: Date = Date()
    @State private var hasHitBoundary: Bool = false
    @State private var glideResetTask: Task<Void, Never>? = nil

    // Initialize with configured properties
    public init(
        playerService: AudioPlayerService,
        foregroundColor: Color = Color.primary,
        secondaryForegroundColor: Color = Color.secondary,
        style: ScrubberStyle = .fullscreen,
        audioSpecs: String? = nil,
        useProgressBar: Bool = false,
        onCollapse: (() -> Void)? = nil
    ) {
        self.playerService = playerService
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.style = style
        self.audioSpecs = audioSpecs
        self.useProgressBar = useProgressBar
        self.onCollapse = onCollapse
    }

    private var effectiveProgress: Double {
        if let drag = dragProgress {
            return drag
        }
        if let pending = pendingSeekProgress {
            return pending
        }
        return playerService.progressRatio
    }

    private var currentDisplayTime: TimeInterval {
        if let drag = dragProgress {
            return drag * playerService.duration
        }
        if let pending = pendingSeekProgress {
            return pending * playerService.duration
        }
        return playerService.currentTime
    }

    private var progressAnimation: Animation? {
        if isActivelyDragging {
            // Direct zero-latency 1:1 tracking while actively dragging
            return nil
        } else if isGliding {
            // Smooth, responsive glide to tapped position
            return .spring(response: 0.28, dampingFraction: 0.86)
        } else {
            // Smooth linear animation during continuous playback
            return .linear(duration: 0.10)
        }
    }

    // Main view layout structure
    public var body: some View {
        Group {
            switch style {
            case .compact:
                compactScrubber
            case .fullscreen:
                if useProgressBar {
                    fullscreenProgressBarScrubber
                } else {
                    fullscreenScrubber
                }
            }
        }
        // Safety net: clear any stale state if the view disappears
        .onDisappear {
            glideResetTask?.cancel()
            dragProgress = nil
            pendingSeekProgress = nil
            isActivelyDragging = false
            isGliding = false
            gestureMode = .idle
            hasTriggeredCollapse = false
            if playerService.isSeeking {
                playerService.isSeeking = false
            }
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

                    // Active progress fill
                    Capsule()
                        .fill(foregroundColor)
                        .frame(
                            width: max(0, min(geometry.size.width * effectiveProgress, geometry.size.width)),
                            height: 4
                        )
                        .animation(progressAnimation, value: effectiveProgress)

                    // Scrubber thumb
                    Circle()
                        .fill(foregroundColor)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, min(geometry.size.width * effectiveProgress - 7, geometry.size.width - 14)))
                        .animation(progressAnimation, value: effectiveProgress)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                // Interactive drag and touch gesture handling
                .gesture(scrubGesture(width: geometry.size.width))
            }
            .frame(height: 20)

            timestampRow(large: false)
        }
    }

    // MARK: - Fullscreen Progress Bar Scrubber (Long rectangle with square playhead)

    private var fullscreenProgressBarScrubber: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let trackHeight: CGFloat = 6
                let playheadSize: CGFloat = 14
                let playheadX = max(0, min(width * effectiveProgress - playheadSize / 2, width - playheadSize))

                ZStack(alignment: .leading) {
                    // Full-length rectangular background track
                    Rectangle()
                        .fill(foregroundColor.opacity(0.20))
                        .frame(width: width, height: trackHeight)

                    // Active progress fill rectangle
                    Rectangle()
                        .fill(foregroundColor)
                        .frame(
                            width: max(0, min(width * effectiveProgress, width)),
                            height: trackHeight
                        )
                        .animation(progressAnimation, value: effectiveProgress)

                    // Square playhead scrubber
                    Rectangle()
                        .fill(foregroundColor)
                        .frame(width: playheadSize, height: playheadSize)
                        .shadow(color: Color.black.opacity(0.40), radius: 2, x: 0, y: 1)
                        .offset(x: playheadX)
                        .animation(progressAnimation, value: effectiveProgress)

                    // Floating time badge above square playhead when scrubbing
                    if isActivelyDragging {
                        Text(TimeFormatting.format(seconds: currentDisplayTime))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .offset(x: max(0, min(width * effectiveProgress - 24, width - 48)), y: -26)
                            .transition(.opacity)
                    }
                }
                .frame(width: width, height: 36)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: width))
            }
            .frame(height: 36)

            timestampRow(large: false)
        }
    }

    // MARK: - Fullscreen Style (Center-Needle Wheel Scrubber with rotating timeline & glass playhead)

    private var fullscreenScrubber: some View {
        CenterNeedleWheelScrubberView(
            playerService: playerService,
            foregroundColor: foregroundColor,
            secondaryForegroundColor: secondaryForegroundColor,
            audioSpecs: audioSpecs,
            onCollapse: onCollapse
        )
    }

    // MARK: - Shared Helpers

    /// Unified drag gesture used by both styles with responsive tap-to-glide and zero-jump seeking.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let now = Date()
                let transX = value.translation.width
                let transY = value.translation.height

                // Disambiguate pull-down from horizontal scrubbing in fullscreen player contexts
                if style == .fullscreen && (gestureMode == .idle || gestureMode == .undecided) {
                    if transY > 12 && transY > abs(transX) * 1.1 {
                        // User touched and pulled down on the progress bar -> collapse player
                        gestureMode = .pullingDown
                        dragProgress = nil
                        isActivelyDragging = false
                        isGliding = false
                        playerService.isSeeking = false
                        if !hasTriggeredCollapse && (transY > 30 || value.predictedEndTranslation.height > 50) {
                            hasTriggeredCollapse = true
                            HapticFeedback.lightImpact()
                            onCollapse?()
                        }
                        return
                    } else if abs(transX) > 6 && abs(transX) >= transY {
                        // User dragged to the side -> lock into scrubbing mode
                        gestureMode = .scrubbing
                        dragStartLocationX = value.location.x
                        isActivelyDragging = true
                        isGliding = false
                        playerService.isSeeking = true
                        lastScrubBucket = -1
                        lastScrubDate = now
                        hasHitBoundary = false
                        HapticFeedback.scrubStart()
                    } else {
                        // Slight touch or holding in place: remain undecided
                        gestureMode = .undecided
                        return
                    }
                }

                // Handle active pull-down mode
                if style == .fullscreen && gestureMode == .pullingDown {
                    if !hasTriggeredCollapse && (transY > 30 || value.predictedEndTranslation.height > 50) {
                        hasTriggeredCollapse = true
                        HapticFeedback.lightImpact()
                        onCollapse?()
                    }
                    return
                }

                let rawProgress = value.location.x / max(1.0, width)
                let targetProgress = max(0, min(rawProgress, 1.0))

                if dragProgress == nil {
                    // Initial contact: user tapped or started touching down
                    dragStartLocationX = value.location.x
                    isActivelyDragging = false
                    isGliding = true
                    playerService.isSeeking = true
                    lastScrubBucket = -1
                    lastScrubDate = now
                    hasHitBoundary = false
                    HapticFeedback.lightImpact()

                    // Trigger smooth spring glide towards tapped position
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dragProgress = targetProgress
                    }

                    glideResetTask?.cancel()
                } else {
                    // If user moved their finger more than 4 points, switch to active 1:1 scrubbing
                    if !isActivelyDragging && abs(value.location.x - dragStartLocationX) > 4 {
                        isActivelyDragging = true
                        isGliding = false
                        HapticFeedback.scrubStart()
                    }

                    if isActivelyDragging {
                        dragProgress = targetProgress

                        // Velocity estimation across the progress bar
                        let dt = max(0.008, now.timeIntervalSince(lastScrubDate))
                        let velocity = 14.0 / dt
                        lastScrubDate = now

                        // Boundary bump if dragged past edges
                        if rawProgress < -0.02 || rawProgress > 1.02 {
                            if !hasHitBoundary {
                                hasHitBoundary = true
                                HapticFeedback.boundaryBump()
                            }
                        } else {
                            hasHitBoundary = false
                        }

                        // Fine-grained mechanical detents every ~14 points of horizontal motion
                        let step = Int(value.location.x / 14.0)
                        if step != lastScrubBucket {
                            lastScrubBucket = step
                            let seekSec = targetProgress * playerService.duration
                            let isAccent = (Int(round(seekSec)) % 30 == 0)
                            HapticFeedback.scrubTick(velocity: velocity, isAccent: isAccent)
                        }
                    }
                }
            }
            .onEnded { value in
                // Pull-down gesture completion
                if style == .fullscreen && gestureMode == .pullingDown {
                    if !hasTriggeredCollapse && (value.translation.height > 20 || value.predictedEndTranslation.height > 35) {
                        hasTriggeredCollapse = true
                        HapticFeedback.lightImpact()
                        onCollapse?()
                    }
                    gestureMode = .idle
                    hasTriggeredCollapse = false
                    dragProgress = nil
                    isActivelyDragging = false
                    isGliding = false
                    playerService.isSeeking = false
                    return
                }

                gestureMode = .idle
                hasTriggeredCollapse = false

                let rawProgress = value.location.x / max(1.0, width)
                let finalProgress = max(0, min(rawProgress, 1.0))
                let seekTargetTime = finalProgress * playerService.duration

                lastScrubBucket = -1
                hasHitBoundary = false

                if isActivelyDragging {
                    HapticFeedback.scrubCommit()
                    isActivelyDragging = false
                } else {
                    // Tap ended: ensure playhead glides cleanly to the tapped location
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dragProgress = finalProgress
                    }
                }

                // Lock seek target so periodic observer doesn't rubberband the playhead
                pendingSeekProgress = finalProgress

                // Commit the seek with completion callback
                playerService.seek(to: seekTargetTime) {
                    Task { @MainActor in
                        if pendingSeekProgress == finalProgress {
                            pendingSeekProgress = nil
                        }
                    }
                }

                // Safety timeout to clear seek lock if audio hardware callback is delayed
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if pendingSeekProgress == finalProgress {
                        pendingSeekProgress = nil
                    }
                }

                // Transition out of glide state once spring settles
                glideResetTask?.cancel()
                glideResetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    if !Task.isCancelled {
                        isGliding = false
                        dragProgress = nil
                    }
                }
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

            if let specs = audioSpecs, !specs.isEmpty {
                Text(specs)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(secondaryForegroundColor.opacity(0.85))
                    .lineLimit(1)

                Spacer()
            }

            Text(TimeFormatting.formatRemaining(current: currentDisplayTime, total: playerService.duration))
                .font(large
                    ? .system(size: 13, weight: .semibold, design: .rounded)
                    : .system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(secondaryForegroundColor)
                .monospacedDigit()
        }
    }
}
