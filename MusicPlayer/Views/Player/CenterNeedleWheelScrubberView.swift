import SwiftUI

/// High-performance, tactile rotating tape/wheel duration scrubber with 3D shadow pin needle playhead.
/// Features exact volume-responsive needle points, 300ms line-to-waveform expansion/contraction lifecycle,
/// white strike with slow phosphor decay, non-linear volume scaling, 60/120fps continuous rotation,
/// and fluid inertial flick-to-scroll.
public struct CenterNeedleWheelScrubberView: View {
    @Bindable var playerService: AudioPlayerService
    public var foregroundColor: Color
    public var secondaryForegroundColor: Color
    public var audioSpecs: String?
    public var onCollapse: (() -> Void)?

    // Slimmer, sleeker configuration
    private let pointsPerSecond: CGFloat = 9.0
    private let dialHeight: CGFloat = 36.0

    // Gesture direction disambiguation state
    private enum ScrubberGestureMode {
        case idle
        case undecided
        case scrubbing
        case pullingDown
    }
    @State private var gestureMode: ScrubberGestureMode = .idle
    @State private var hasTriggeredCollapse: Bool = false

    // Scrub & Drag State Machine with Zero-Jump Catch & Coasting
    @State private var isUserDragging: Bool = false
    @State private var isCoasting: Bool = false
    @State private var dragSeekTime: TimeInterval = 0
    @State private var dragBaseTime: TimeInterval = 0
    @State private var dragGestureInitialTranslation: CGFloat = 0
    @State private var lastHapticBucket: Int = -1
    @State private var hasHitBoundary: Bool = false

    // Smooth proximity & needle magnification animation (enlarges on scroll, shrinks on release)
    @State private var zoomAnimationProgress: CGFloat = 0.0

    // Seek lock preventing premature waveform drift before audio resumes
    @State private var pendingSeekCommitTime: TimeInterval? = nil

    private var isInteracting: Bool {
        (isUserDragging && gestureMode == .scrubbing) || isCoasting
    }

    // Inertial Momentum / Flick-to-Scroll State
    @State private var touchSamples: [(date: Date, translation: CGFloat)] = []
    @State private var inertiaTask: Task<Void, Never>? = nil

    // Smooth Interpolation State for 60/120fps continuous wheel rotation
    @State private var lastObservedTime: TimeInterval = 0
    @State private var lastObservedDate: Date = Date()

    // Waveform Height Expansion / Contraction Animation Lifecycle State
    @State private var waveformExpansionProgress: CGFloat = 0.0
    @State private var trackChangeTask: Task<Void, Never>? = nil
    @State private var loadedTrackID: UUID? = nil

    // High-Resolution Audio Volume / Amplitude Peaks
    @State private var amplitudePeaks: [Float] = []
    @State private var currentTrackURL: URL? = nil

    public init(
        playerService: AudioPlayerService,
        foregroundColor: Color = .white,
        secondaryForegroundColor: Color = .white.opacity(0.65),
        audioSpecs: String? = nil,
        onCollapse: (() -> Void)? = nil
    ) {
        self.playerService = playerService
        self.foregroundColor = foregroundColor
        self.secondaryForegroundColor = secondaryForegroundColor
        self.audioSpecs = audioSpecs
        self.onCollapse = onCollapse
    }

    private var duration: TimeInterval {
        max(1.0, playerService.duration)
    }

    public var body: some View {
        TimelineView(.animation(paused: !playerService.playbackStatus.isPlaying && !isInteracting && zoomAnimationProgress <= 0.001)) { timeline in
            let current = computeCurrentTime(at: timeline.date)

            VStack(spacing: 4) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let centerX = width / 2.0
                    let centerY = dialHeight / 2.0

                    ZStack {
                        // 1. Rotating Tape/Dial Timeline (Volume-responsive uniform needle points on baseline)
                        ScrubberDialCanvas(
                            width: width,
                            centerX: centerX,
                            centerY: centerY,
                            current: current,
                            waveformExpansion: waveformExpansionProgress,
                            zoomProgress: zoomAnimationProgress,
                            amplitudePeaks: amplitudePeaks,
                            foregroundColor: foregroundColor,
                            secondaryForegroundColor: secondaryForegroundColor,
                            pointsPerSecond: pointsPerSecond,
                            duration: duration
                        )
                        // Cylindrical 3D edge vignette mask (fades out left and right edges like a curved wheel)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black.opacity(0.55), location: 0.12),
                                    .init(color: .black, location: 0.24),
                                    .init(color: .black, location: 0.76),
                                    .init(color: .black.opacity(0.55), location: 0.88),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                        // 2. Fixed Center 3D Pin Needle Playhead with Realistic Cast Shadow
                        center3DPinNeedle(centerY: centerY)
                            .scaleEffect(1.0 + 0.18 * zoomAnimationProgress)
                            .position(x: centerX, y: centerY)

                        // 3. Floating Timestamp Directly Centered Above Pin Needle (Numbers only, no background/icon)
                        floatingTimeBadge
                            .position(x: centerX, y: centerY - 25)
                            .opacity(isInteracting ? 1.0 : 0.0)
                            .animation(.easeOut(duration: 0.18), value: isInteracting)
                    }
                    .frame(width: width, height: dialHeight)
                    .contentShape(Rectangle())
                    // Interactive fluid drag & inertial flick gesture handling
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let now = Date()

                                // Cancel any ongoing inertia glide immediately on touch contact
                                if inertiaTask != nil {
                                    inertiaTask?.cancel()
                                    inertiaTask = nil
                                }
                                let wasCoasting = isCoasting
                                isCoasting = false

                                let transX = value.translation.width
                                let transY = value.translation.height

                                // 1. Initial Contact Disambiguation
                                if gestureMode == .idle || gestureMode == .undecided {
                                    if transY > 12 && transY > abs(transX) * 1.1 {
                                        // Downward pull detected first: switch to pulling down to collapse!
                                        gestureMode = .pullingDown
                                        isUserDragging = false
                                        playerService.isSeeking = false
                                        withAnimation(.spring(response: 0.30, dampingFraction: 0.8)) {
                                            zoomAnimationProgress = 0.0
                                        }
                                        if !hasTriggeredCollapse && (transY > 30 || value.predictedEndTranslation.height > 50) {
                                            hasTriggeredCollapse = true
                                            HapticFeedback.lightImpact()
                                            onCollapse?()
                                        }
                                        return
                                    } else if abs(transX) > 6 && abs(transX) >= transY {
                                        // Horizontal scrub detected first: lock into scrubbing!
                                        gestureMode = .scrubbing
                                        isUserDragging = true
                                        playerService.isSeeking = true
                                        pendingSeekCommitTime = nil

                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                                            zoomAnimationProgress = 1.0
                                        }

                                        let currentPos = wasCoasting ? dragSeekTime : computeCurrentTime(at: now)
                                        dragBaseTime = currentPos
                                        dragSeekTime = currentPos
                                        dragGestureInitialTranslation = transX
                                        touchSamples = [(now, transX)]
                                        lastHapticBucket = Int(round(currentPos * 2.0))
                                        hasHitBoundary = false
                                        HapticFeedback.scrubStart()
                                    } else {
                                        // Slight touch / holding in place: remain undecided
                                        gestureMode = .undecided
                                        return
                                    }
                                }

                                // 2. Pulling Down Mode: drive collapse without interfering with playhead
                                if gestureMode == .pullingDown {
                                    if !hasTriggeredCollapse && (transY > 30 || value.predictedEndTranslation.height > 50) {
                                        hasTriggeredCollapse = true
                                        HapticFeedback.lightImpact()
                                        onCollapse?()
                                    }
                                    return
                                }

                                // 3. Scrubbing Mode: function normally as high-precision scrubber
                                if gestureMode == .scrubbing {
                                    touchSamples.append((now, value.translation.width))
                                    touchSamples.removeAll { now.timeIntervalSince($0.date) > 0.08 }

                                    // 1:1 physical translation relative to this touch contact point
                                    let deltaTranslation = value.translation.width - dragGestureInitialTranslation
                                    let deltaSeconds = -Double(deltaTranslation) / Double(pointsPerSecond)
                                    let newTime = max(0, min(dragBaseTime + deltaSeconds, duration))
                                    dragSeekTime = newTime

                                    // Instantaneous velocity (points per second) for dynamic tick modulation
                                    var instantaneousVelocity: Double = 0
                                    if let firstSample = touchSamples.first, touchSamples.count >= 2 {
                                        let dt = now.timeIntervalSince(firstSample.date)
                                        if dt > 0.008 {
                                            instantaneousVelocity = Double((value.translation.width - firstSample.translation) / CGFloat(dt))
                                        }
                                    }

                                    // Boundary bump when dragging beyond min or max
                                    let isAtMin = (dragBaseTime + deltaSeconds < -0.05)
                                    let isAtMax = (dragBaseTime + deltaSeconds > duration + 0.05)
                                    if isAtMin || isAtMax {
                                        if !hasHitBoundary {
                                            hasHitBoundary = true
                                            HapticFeedback.boundaryBump()
                                        }
                                    } else {
                                        hasHitBoundary = false
                                    }

                                    // Haptic tick for every graduation mark (0.5s intervals, matching dial canvas marks)
                                    let currentStep = Int(round(newTime * 2.0))
                                    if currentStep != lastHapticBucket {
                                        lastHapticBucket = currentStep
                                        let isWholeSecond = (currentStep % 2 == 0)
                                        let second = Int(round(newTime))
                                        let isAccent = isWholeSecond && (second % 15 == 0)
                                        HapticFeedback.scrubTick(velocity: instantaneousVelocity, isAccent: isAccent)
                                    }
                                }
                            }
                            .onEnded { value in
                                let now = Date()

                                // End Pull-Down Gesture
                                if gestureMode == .pullingDown {
                                    if !hasTriggeredCollapse && (value.translation.height > 20 || value.predictedEndTranslation.height > 35) {
                                        hasTriggeredCollapse = true
                                        HapticFeedback.lightImpact()
                                        onCollapse?()
                                    }
                                    withAnimation(.spring(response: 0.30, dampingFraction: 0.8)) {
                                        zoomAnimationProgress = 0.0
                                    }
                                    isUserDragging = false
                                    playerService.isSeeking = false
                                    gestureMode = .idle
                                    hasTriggeredCollapse = false
                                    return
                                }

                                // End Scrubbing Gesture
                                if gestureMode == .scrubbing {
                                    gestureMode = .idle
                                    hasTriggeredCollapse = false
                                    touchSamples.append((now, value.translation.width))
                                    touchSamples.removeAll { now.timeIntervalSince($0.date) > 0.08 }

                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                                        zoomAnimationProgress = 0.0
                                    }

                                    isUserDragging = false

                                    // Calculate release velocity (points per second)
                                    var velocityX: CGFloat = 0
                                    if let firstSample = touchSamples.first, touchSamples.count >= 2 {
                                        let dt = now.timeIntervalSince(firstSample.date)
                                        if dt > 0.012 {
                                            velocityX = (value.translation.width - firstSample.translation) / CGFloat(dt)
                                        }
                                    }

                                    // If finger paused before releasing, velocity is zero (intentional placement)
                                    let timeSinceLastMovement = now.timeIntervalSince(touchSamples.last?.date ?? now)
                                    if timeSinceLastMovement > 0.08 {
                                        velocityX = 0
                                    }

                                    // Convert to time velocity (seconds per second)
                                    let velocityTime = -Double(velocityX) / Double(pointsPerSecond)

                                    // Clamped velocity for weighted, controlled feel
                                    let maxVelocity: Double = 22.0
                                    let initialVelocity = max(-maxVelocity, min(maxVelocity, velocityTime))

                                    // When scrolling and releasing, continue smoothly but come to a quick, satisfying stop
                                    if abs(initialVelocity) > 0.25 {
                                        startInertialScroll(initialVelocityTime: initialVelocity)
                                    } else {
                                        commitSeek(to: dragSeekTime)
                                    }
                                    return
                                }

                                // End Tap / Undecided Contact: static tap committed at current touch position
                                gestureMode = .idle
                                hasTriggeredCollapse = false
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                                    zoomAnimationProgress = 0.0
                                }
                                isUserDragging = false
                                commitSeek(to: computeCurrentTime(at: now))
                            }
                    )
                }
                .frame(height: dialHeight)

                // Slim Bottom Timestamp Row
                bottomTimestampRow(current: current)
            }
        }
        .onAppear {
            lastObservedTime = playerService.currentTime
            lastObservedDate = Date()
            handleTrackChanged(track: playerService.currentTrack)
        }
        .onChange(of: playerService.currentTrack?.id) { _, _ in
            handleTrackChanged(track: playerService.currentTrack)
        }
        .onChange(of: playerService.currentTime) { _, newTime in
            if !isInteracting {
                // If a seek is currently in flight, ignore interim ticks so the waveform does not jump
                guard pendingSeekCommitTime == nil else { return }

                let now = Date()
                let currentRendered: TimeInterval
                if playerService.playbackStatus.isPlaying {
                    let elapsed = now.timeIntervalSince(lastObservedDate)
                    currentRendered = lastObservedTime + max(0, min(elapsed, 0.25))
                } else {
                    currentRendered = lastObservedTime
                }

                let drift = newTime - currentRendered
                if abs(drift) > 0.40 {
                    // Significant jump (e.g. track jump or external control) -> snap cleanly
                    lastObservedTime = newTime
                    lastObservedDate = now
                } else {
                    // Smoothly converge without sudden jitter
                    lastObservedTime = currentRendered + drift * 0.25
                    lastObservedDate = now
                }
                dragSeekTime = newTime
            }
        }
        .onDisappear {
            trackChangeTask?.cancel()
            trackChangeTask = nil
            inertiaTask?.cancel()
            inertiaTask = nil
            gestureMode = .idle
            hasTriggeredCollapse = false
            if isInteracting {
                playerService.isSeeking = false
                isUserDragging = false
                isCoasting = false
            }
        }
    }

    // MARK: - Track Change & Waveform Expansion Lifecycle

    private func handleTrackChanged(track: Track?) {
        trackChangeTask?.cancel()
        trackChangeTask = nil
        inertiaTask?.cancel()
        inertiaTask = nil
        isUserDragging = false
        isCoasting = false
        dragSeekTime = 0
        dragBaseTime = 0
        pendingSeekCommitTime = nil
        zoomAnimationProgress = 0.0

        // Reset observation state immediately so current time calculation never carries over stale position
        let initialTime = playerService.currentTime
        lastObservedTime = initialTime
        lastObservedDate = Date()
        playerService.isSeeking = false

        guard let track = track else {
            amplitudePeaks = []
            currentTrackURL = nil
            loadedTrackID = nil
            waveformExpansionProgress = 0.0
            return
        }

        let trackID = track.id
        let trackURL = track.url
        let trackDuration = max(1.0, track.duration)

        // 1. Instantly display cached peaks or deterministic baseline envelope so dial never bugs out or shows flat line
        if let cached = WaveformCache.shared.peaks(for: trackURL) {
            self.amplitudePeaks = cached
            self.currentTrackURL = trackURL
            self.loadedTrackID = trackID
            self.waveformExpansionProgress = 1.0
        } else {
            self.amplitudePeaks = WaveformCache.placeholderPeaks(for: trackID, duration: trackDuration)
            self.currentTrackURL = trackURL
            self.loadedTrackID = trackID
            self.waveformExpansionProgress = 1.0
        }

        trackChangeTask = Task { @MainActor in
            // 2. Fetch the dynamic high-resolution waveform for this track in background
            let peaks = await AudioWaveformSpectrogramGenerator.shared.fetchSubSecondWaveformPeaks(
                for: trackURL,
                duration: trackDuration,
                samplesPerSecond: 2
            )
            guard !Task.isCancelled else { return }
            guard playerService.currentTrack?.id == trackID else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                self.amplitudePeaks = peaks
                self.waveformExpansionProgress = 1.0
            }
        }
    }

    // MARK: - Inertial Momentum / Fluid Flick Engine

    private func startInertialScroll(initialVelocityTime: Double) {
        inertiaTask?.cancel()
        isCoasting = true

        inertiaTask = Task { @MainActor in
            var velocity = initialVelocityTime
            var currentSeek = dragSeekTime
            var lastTick = Date()

            // Crisp, well-damped mechanical friction: 0.89 per 16ms frame
            // Continues naturally upon release but comes to a quick, satisfying stop (~400ms)
            let friction: Double = 0.89

            while !Task.isCancelled && abs(velocity) > 0.25 {
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60fps frame tick
                guard !Task.isCancelled else { break }

                let now = Date()
                let dt = min(now.timeIntervalSince(lastTick), 0.04)
                lastTick = now

                velocity *= pow(friction, dt / 0.016)
                currentSeek += velocity * dt

                // Boundary bounce check with haptic feedback
                if currentSeek <= 0 {
                    currentSeek = 0
                    HapticFeedback.boundaryBump()
                    break
                }
                if currentSeek >= duration {
                    currentSeek = duration
                    HapticFeedback.boundaryBump()
                    break
                }

                dragSeekTime = currentSeek

                // Haptic ticks while coasting matching dial graduation marks
                let step = Int(round(currentSeek * 2.0))
                if step != lastHapticBucket {
                    lastHapticBucket = step
                    let isWholeSecond = (step % 2 == 0)
                    let second = Int(round(currentSeek))
                    let isAccent = isWholeSecond && (second % 15 == 0)
                    HapticFeedback.scrubTick(velocity: velocity * Double(pointsPerSecond), isAccent: isAccent)
                }
            }

            if !Task.isCancelled {
                commitSeek(to: currentSeek)
            }
        }
    }

    private func commitSeek(to time: TimeInterval) {
        pendingSeekCommitTime = time
        lastObservedTime = time
        lastObservedDate = Date()
        dragSeekTime = time
        isUserDragging = false
        isCoasting = false
        HapticFeedback.scrubCommit()

        withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
            zoomAnimationProgress = 0.0
        }

        playerService.seek(to: time) {
            Task { @MainActor in
                guard pendingSeekCommitTime == time else { return }
                lastObservedTime = time
                lastObservedDate = Date()
                pendingSeekCommitTime = nil
            }
        }

        // Safety timeout to release seek lock if player observer doesn't notify
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if pendingSeekCommitTime == time {
                pendingSeekCommitTime = nil
                lastObservedTime = playerService.currentTime
                lastObservedDate = Date()
            }
        }
    }

    // MARK: - Time Calculation with Continuous Interpolation

    private func computeCurrentTime(at date: Date) -> TimeInterval {
        if isInteracting {
            return dragSeekTime
        }
        if let pending = pendingSeekCommitTime {
            return pending
        }
        if playerService.playbackStatus.isPlaying {
            let elapsed = date.timeIntervalSince(lastObservedDate)
            let clampedElapsed = max(0, min(elapsed, 0.20))
            return min(duration, max(0, lastObservedTime + clampedElapsed))
        }
        return playerService.currentTime
    }

    // MARK: - 1. Timeline Dial Canvas (Animatable proximity zoom & waveform expansion)

    private struct ScrubberDialCanvas: View, Animatable {
        var width: CGFloat
        var centerX: CGFloat
        var centerY: CGFloat
        var current: TimeInterval
        var waveformExpansion: CGFloat
        var zoomProgress: CGFloat
        var amplitudePeaks: [Float]
        var foregroundColor: Color
        var secondaryForegroundColor: Color
        var pointsPerSecond: CGFloat
        var duration: TimeInterval

        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(waveformExpansion, zoomProgress) }
            set {
                waveformExpansion = newValue.first
                zoomProgress = newValue.second
            }
        }

        var body: some View {
            Canvas { context, size in
                let totalDur = duration

                // Subtle baseline track
                let baselineY = centerY
                var baselinePath = Path()
                baselinePath.move(to: CGPoint(x: 0, y: baselineY))
                baselinePath.addLine(to: CGPoint(x: width, y: baselineY))
                context.stroke(
                    baselinePath,
                    with: .color(foregroundColor.opacity(0.14)),
                    lineWidth: 1.0
                )

                // Visible time window calculation with 30pt bleed (0.5s step for dynamic non-repetitive rhythm)
                let halfVisibleSeconds = Double(centerX + 30.0) / Double(pointsPerSecond)
                let startTime = max(0, floor((current - halfVisibleSeconds) * 2.0) / 2.0)
                let endTime = min(totalDur, ceil((current + halfVisibleSeconds) * 2.0) / 2.0)

                guard startTime <= endTime else { return }

                let focusRadius: CGFloat = 70.0

                for time in stride(from: startTime, through: endTime, by: 0.5) {
                    let timeOffset = time - current
                    let x = centerX + CGFloat(timeOffset) * pointsPerSecond
                    guard x >= -10 && x <= width + 10 else { continue }

                    // Color calculation: when a line passes the needle, it turns pure white,
                    // and then slowly fades back to normal color over 4 seconds as it moves to the left.
                    let timeDelta = current - time
                    let tickColor: Color
                    if timeDelta < 0 {
                        // Future / upcoming tick (approaching from the right)
                        tickColor = secondaryForegroundColor.opacity(0.30)
                    } else {
                        // Tick at or past the needle (moving to the left):
                        // Starts pure white (1.0) and slowly fades to normal color (0.35) over 4 seconds
                        let fadeDuration: Double = 4.0
                        let progress = min(1.0, max(0.0, timeDelta / fadeDuration))
                        let decay = pow(progress, 0.70)
                        let opacity = 1.0 - (1.0 - 0.35) * decay
                        tickColor = Color.white.opacity(opacity)
                    }

                    // Volume/amplitude height modulation (sampled at 0.5s intervals)
                    let sampleIndex = Int(round(time * 2.0))
                    let rawAmplitude: Float = (sampleIndex >= 0 && sampleIndex < amplitudePeaks.count)
                        ? amplitudePeaks[sampleIndex]
                        : 0.0

                    // Dynamic height curve: quietest part of track is at minimum height (5pt)
                    // and loudest part reaches maximum height (20pt) with rich perceptual contrast
                    let clampedAmp = Double(max(0.0, min(1.0, rawAmplitude)))
                    let curvedAmplitude = CGFloat(pow(clampedAmp, 1.85))

                    // Proximity magnification when dial is being scrolled:
                    // Points closer to the center enlarge smoothly
                    let distanceFromCenter = abs(x - centerX)
                    let proximityScale: CGFloat
                    if zoomProgress > 0.001 && distanceFromCenter < focusRadius {
                        let proximity = 1.0 - (distanceFromCenter / focusRadius)
                        let bell = (1.0 + cos((1.0 - proximity) * .pi)) / 2.0
                        proximityScale = 1.0 + (bell * 0.45 * zoomProgress)
                    } else {
                        proximityScale = 1.0
                    }

                    // Full dynamic height range: 5pt (quietest part) up to 20pt (loudest part)
                    let baseTargetHeight: CGFloat = 5.0 + curvedAmplitude * 15.0
                    let fullTargetHeight: CGFloat = baseTargetHeight * proximityScale
                    let baselineLineHeight: CGFloat = 2.0

                    // Smooth expansion from flat line (progress 0) to full waveform size (progress 1)
                    let needleHeight: CGFloat = baselineLineHeight + (fullTargetHeight - baselineLineHeight) * waveformExpansion
                    let halfH = needleHeight / 2.0

                    // Uniform needle line
                    var needlePath = Path()
                    needlePath.move(to: CGPoint(x: x, y: baselineY - halfH))
                    needlePath.addLine(to: CGPoint(x: x, y: baselineY + halfH))

                    let pointLineWidth = 1.4 + (0.35 * (proximityScale - 1.0))
                    context.stroke(
                        needlePath,
                        with: .color(tickColor),
                        style: StrokeStyle(lineWidth: pointLineWidth, lineCap: .round)
                    )

                    // Micro precision tip at top and bottom of each needle line
                    let tipRadius: CGFloat = 0.85 * waveformExpansion * (1.0 + 0.25 * (proximityScale - 1.0))
                    if tipRadius > 0.25 {
                        let topDot = Path(ellipseIn: CGRect(x: x - tipRadius, y: baselineY - halfH - tipRadius, width: tipRadius * 2, height: tipRadius * 2))
                        let bottomDot = Path(ellipseIn: CGRect(x: x - tipRadius, y: baselineY + halfH - tipRadius, width: tipRadius * 2, height: tipRadius * 2))
                        context.fill(topDot, with: .color(tickColor.opacity(Double(waveformExpansion))))
                        context.fill(bottomDot, with: .color(tickColor.opacity(Double(waveformExpansion))))
                    }
                }
            }
        }
    }

    // MARK: - 2. Minimal Clean 3D Faceted Needle Playhead

    private func center3DPinNeedle(centerY: CGFloat) -> some View {
        let needleHeight: CGFloat = 32.0
        let needleWidth: CGFloat = 2.6

        return ZStack {
            // Realistic Physical 3D Cast Shadow onto the dial tape
            Capsule()
                .fill(Color.black.opacity(0.35))
                .frame(width: needleWidth, height: needleHeight)
                .blur(radius: 1.5)
                .offset(x: 1.0, y: 1.2)

            // Direct contact occlusion shadow
            Capsule()
                .fill(Color.black.opacity(0.25))
                .frame(width: needleWidth, height: needleHeight)
                .blur(radius: 0.8)
                .offset(x: 0.5, y: 0.6)

            // 3D Faceted Baton Needle with Split Lighting (Left Specular Highlight, Right Shadow)
            HStack(spacing: 0) {
                // Left 3D Highlight Facet (catches light)
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white, location: 0.0),
                                .init(color: Color(white: 0.94), location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: needleWidth / 2.0, height: needleHeight)

                // Right 3D Shadow Facet (gives deep 3D cylindrical ridge)
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(white: 0.80), location: 0.0),
                                .init(color: Color(white: 0.65), location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: needleWidth / 2.0, height: needleHeight)
            }
            .clipShape(Capsule())
            .overlay(
                // Specular micro-bevel edge along the needle rim
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.95), location: 0.0),
                                .init(color: Color.white.opacity(0.35), location: 0.40),
                                .init(color: Color.black.opacity(0.15), location: 0.80),
                                .init(color: Color.black.opacity(0.30), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
    }

    // MARK: - 3. Floating Timestamp Directly Centered Above Pin Needle (Numbers only, no background/icon)

    private var floatingTimeBadge: some View {
        Text(TimeFormatting.format(seconds: dragSeekTime))
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white)
            .monospacedDigit()
            .shadow(color: Color.black.opacity(0.85), radius: 2.5, x: 0, y: 1)
    }

    // MARK: - 4. Bottom Timestamp Row

    private func bottomTimestampRow(current: TimeInterval) -> some View {
        HStack {
            Text(TimeFormatting.format(seconds: current))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .monospacedDigit()

            Spacer()

            if let specs = audioSpecs, !specs.isEmpty {
                Text(specs)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(secondaryForegroundColor.opacity(0.85))
                    .lineLimit(1)

                Spacer()
            }

            Text(TimeFormatting.formatRemaining(current: current, total: duration))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(secondaryForegroundColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 2)
    }
}
