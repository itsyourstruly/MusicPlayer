import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

// MARK: - Transport Haptic Kinds

/// On-screen transport buttons that play dedicated, prebuilt Core Haptics patterns.
public enum TransportHaptic: Sendable, Hashable {
    case play
    case pause
    case next
    case back
}

// MARK: - Core Haptics & Feedback Orchestrator

/// High-performance, concurrency-safe haptics orchestrator isolated to the `@MainActor`.
/// Leverages CoreHaptics for custom transient, continuous, and dynamic tactile patterns,
/// with seamless, zero-latency fallback to UIKit feedback generators.
@MainActor
public final class HapticManager {
    public static let shared = HapticManager()

    #if canImport(UIKit)
    private let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isContinuousPlaying: Bool = false
    private var supportsCoreHaptics: Bool = false
    /// Tracks whether the engine is currently running so it is only (re)started when needed.
    private var isEngineRunning: Bool = false
    /// Transport patterns (Play / Pause / Next / Back), built once and reused for every press.
    private var transportPatterns: [TransportHaptic: CHHapticPattern] = [:]
    #endif

    #if canImport(UIKit) && canImport(CoreHaptics)
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    private var lastScrubTickTime: TimeInterval = 0

    /// App-wide master switch for tactile haptic feedback (defaults to false / OFF).
    public var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                stopContinuous()
                stopEngine()
            } else if !oldValue {
                prepare()
            }
        }
    }

    private init() {
        #if canImport(CoreHaptics)
        let capabilities = CHHapticEngine.capabilitiesForHardware()
        self.supportsCoreHaptics = capabilities.supportsHaptics
        if self.supportsCoreHaptics {
            self.transportPatterns = Self.buildTransportPatterns()
            setupEngine()
        }
        #endif
        #if canImport(UIKit) && canImport(CoreHaptics)
        observeAppLifecycle()
        #endif
    }

    #if canImport(CoreHaptics)
    private func setupEngine() {
        do {
            let eng = try CHHapticEngine()
            // The engine is kept running while haptics are on; it is stopped explicitly when the
            // app enters the background or haptics are turned off (see stopEngine()).
            eng.isAutoShutdownEnabled = false
            eng.playsHapticsOnly = true

            // Core Haptics calls these handlers off the main thread, so they are @Sendable and hop to the main actor.
            eng.resetHandler = { @Sendable in
                Task { @MainActor in
                    HapticManager.shared.handleEngineReset()
                }
            }

            eng.stoppedHandler = { @Sendable _ in
                // External stop (audio interruption, app suspension, system error). Restarted on the next haptic.
                Task { @MainActor in
                    HapticManager.shared.isEngineRunning = false
                }
            }

            try eng.start()
            self.engine = eng
            self.isEngineRunning = true
        } catch {
            self.engine = nil
            self.isEngineRunning = false
            self.supportsCoreHaptics = false
        }
    }

    /// Recovers after a haptic server reset: players are invalid, patterns are preserved.
    private func handleEngineReset() {
        isEngineRunning = false
        continuousPlayer = nil
        isContinuousPlaying = false
        guard isEnabled, let engine = engine else { return }
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            // Stay silent; the next haptic request will try again.
        }
    }

    public func ensureEngineActive() -> Bool {
        guard isEnabled, supportsCoreHaptics else { return false }
        if engine == nil {
            setupEngine()
        }
        guard let engine = engine else { return false }
        if isEngineRunning { return true }
        do {
            try engine.start()
            isEngineRunning = true
            return true
        } catch {
            return false
        }
    }

    /// Stops the engine to save power (app backgrounded or haptics turned off). Restarted on demand.
    private func stopEngine() {
        guard let engine = engine, isEngineRunning else { return }
        isEngineRunning = false
        engine.stop(completionHandler: nil)
    }

    // MARK: - Transport Patterns

    private static func buildTransportPatterns() -> [TransportHaptic: CHHapticPattern] {
        // (intensity, sharpness, relativeTime in seconds). First tap at 0 so it fires immediately on press.
        func makePattern(_ taps: [(Float, Float, TimeInterval)]) -> CHHapticPattern? {
            let events = taps.map { tap in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.1)
                    ],
                    relativeTime: tap.2
                )
            }
            return try? CHHapticPattern(events: events, parameters: [])
        }

        var patterns: [TransportHaptic: CHHapticPattern] = [:]
        patterns[.play] = makePattern([(0.58, 0.45, 0)])
        patterns[.pause] = makePattern([(0.66, 0.29, 0), (0.36, 0.20, 0.20)])
        patterns[.next] = makePattern([(0.66, 0.00, 0), (0.30, 0.09, 0.11), (0.79, 0.32, 0.21)])
        patterns[.back] = makePattern([(0.34, 0.43, 0), (0.60, 0.24, 0.11), (0.44, 0.26, 0.21)])
        return patterns
    }
    #else
    public func ensureEngineActive() -> Bool {
        return false
    }

    private func stopEngine() {}
    #endif

    // MARK: - App Lifecycle

    #if canImport(UIKit) && canImport(CoreHaptics)
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                HapticManager.shared.stopContinuous()
                HapticManager.shared.stopEngine()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Prewarm so the first press after returning plays without start-up delay.
                _ = HapticManager.shared.ensureEngineActive()
            }
        })
    }
    #endif

    // MARK: - Transport Buttons

    /// Plays the prebuilt Core Haptics pattern for an on-screen transport button.
    /// Does nothing when haptics are off or the device has no haptic hardware (no UIKit fallback).
    public func playTransport(_ kind: TransportHaptic) {
        #if canImport(CoreHaptics)
        guard isEnabled, supportsCoreHaptics, let pattern = transportPatterns[kind] else { return }
        guard ensureEngineActive(), let engine = engine else { return }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Engine may have been stopped externally; mark it so the next press restarts it.
            isEngineRunning = false
        }
        #endif
    }

    // MARK: - Pre-Warming

    /// Pre-warms the haptic hardware ahead of imminent user gestures to eliminate actuation latency.
    public func prepare() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        softGenerator.prepare()
        lightGenerator.prepare()
        mediumGenerator.prepare()
        rigidGenerator.prepare()
        selectionGenerator.prepare()
        notificationGenerator.prepare()
        #endif
        #if canImport(CoreHaptics)
        if supportsCoreHaptics {
            _ = ensureEngineActive()
        }
        #endif
    }

    // MARK: - Core Transient Synthesis

    /// Plays a precise transient haptic event with custom intensity and sharpness.
    public func playTransient(intensity: Float, sharpness: Float) {
        guard isEnabled else { return }
        #if canImport(CoreHaptics)
        if ensureEngineActive(), let engine = engine {
            let clampedIntensity = max(0.05, min(1.0, intensity))
            let clampedSharpness = max(0.05, min(1.0, sharpness))

            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: clampedIntensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: clampedSharpness)
                ],
                relativeTime: 0
            )

            do {
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                // Fall back to UIKit below
                isEngineRunning = false
            }
        }
        #endif

        #if canImport(UIKit)
        if sharpness > 0.70 {
            rigidGenerator.prepare()
            rigidGenerator.impactOccurred(intensity: CGFloat(intensity))
        } else if sharpness < 0.35 {
            softGenerator.prepare()
            softGenerator.impactOccurred(intensity: CGFloat(intensity))
        } else if intensity > 0.75 {
            mediumGenerator.prepare()
            mediumGenerator.impactOccurred(intensity: CGFloat(intensity))
        } else {
            lightGenerator.prepare()
            lightGenerator.impactOccurred(intensity: CGFloat(intensity))
        }
        #endif
    }

    /// Plays a synchronized dual-transient sequence with custom timings.
    public func playDoubleTransient(
        firstIntensity: Float,
        firstSharpness: Float,
        secondIntensity: Float,
        secondSharpness: Float,
        delay: TimeInterval
    ) {
        guard isEnabled else { return }
        #if canImport(CoreHaptics)
        if ensureEngineActive(), let engine = engine {
            let event1 = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.05, min(1.0, firstIntensity))),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0.05, min(1.0, firstSharpness)))
                ],
                relativeTime: 0
            )
            let event2 = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.05, min(1.0, secondIntensity))),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0.05, min(1.0, secondSharpness)))
                ],
                relativeTime: delay
            )

            do {
                let pattern = try CHHapticPattern(events: [event1, event2], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                // Fall back to UIKit below
            }
        }
        #endif

        #if canImport(UIKit)
        let gen1: UIImpactFeedbackGenerator = firstSharpness > 0.70 ? rigidGenerator : (firstSharpness < 0.35 ? softGenerator : (firstIntensity > 0.75 ? mediumGenerator : lightGenerator))
        let gen2: UIImpactFeedbackGenerator = secondSharpness > 0.70 ? rigidGenerator : (secondSharpness < 0.35 ? softGenerator : (secondIntensity > 0.75 ? mediumGenerator : lightGenerator))

        gen1.prepare()
        gen1.impactOccurred(intensity: CGFloat(firstIntensity))
        Task { @MainActor in
            let sleepNs = max(45_000_000, UInt64(delay * 1_000_000_000))
            try? await Task.sleep(nanoseconds: sleepNs)
            gen2.prepare()
            gen2.impactOccurred(intensity: CGFloat(secondIntensity))
        }
        #endif
    }

    // MARK: - Continuous Feedback

    /// Starts smooth continuous haptic feedback for dragging, wheel scrubbing, or slider movements.
    public func startContinuous(intensity: Float = 0.30, sharpness: Float = 0.20) {
        guard isEnabled else { return }
        #if canImport(CoreHaptics)
        guard ensureEngineActive(), let engine = engine else { return }

        stopContinuous()

        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.05, min(1.0, intensity))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0.05, min(1.0, sharpness)))
            ],
            relativeTime: 0,
            duration: 30.0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            self.continuousPlayer = player
            self.isContinuousPlaying = true
        } catch {
            self.continuousPlayer = nil
            self.isContinuousPlaying = false
        }
        #endif
    }

    /// Dynamically modulates active continuous haptics in real time based on drag velocity.
    public func updateContinuous(intensity: Float, sharpness: Float) {
        guard isEnabled else { return }
        #if canImport(CoreHaptics)
        guard isContinuousPlaying, let player = continuousPlayer else { return }

        let clampedIntensity = max(0.05, min(1.0, intensity))
        let clampedSharpness = max(0.05, min(1.0, sharpness))

        let intensityParam = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: clampedIntensity,
            relativeTime: 0
        )
        let sharpnessParam = CHHapticDynamicParameter(
            parameterID: .hapticSharpnessControl,
            value: clampedSharpness,
            relativeTime: 0
        )

        try? player.sendParameters([intensityParam, sharpnessParam], atTime: CHHapticTimeImmediate)
        #endif
    }

    /// Stops any active continuous haptic playback cleanly.
    public func stopContinuous() {
        #if canImport(CoreHaptics)
        if let player = continuousPlayer {
            try? player.stop(atTime: CHHapticTimeImmediate)
            continuousPlayer = nil
        }
        isContinuousPlaying = false
        #endif
    }

    // MARK: - Dynamic Scrub Tick Generator

    /// Dynamic scrub tick that scales intensity, sharpness, and minimum interval with touch velocity.
    /// Supports both standard fine-grained detents and milestone accent ticks.
    public func playScrubTick(velocity: Double = 0.0, isAccent: Bool = false) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let speed = min(abs(velocity), 1200.0) / 1200.0

        if isAccent {
            // Milestone accent tick (e.g. 15s/30s/60s boundary or major division)
            let minAccentInterval: TimeInterval = 0.035
            guard now - lastScrubTickTime >= minAccentInterval else { return }
            lastScrubTickTime = now

            #if canImport(CoreHaptics)
            if ensureEngineActive() {
                playTransient(intensity: 0.95, sharpness: 0.55)
                return
            }
            #endif
            #if canImport(UIKit)
            mediumGenerator.prepare()
            mediumGenerator.impactOccurred(intensity: 0.95)
            #endif
            return
        }

        // Standard fine-grained rotary detent tick:
        // Allows high tick frequency (down to 18ms at high velocity, 50ms at slow crawl)
        let minInterval = 0.050 - (speed * 0.032)
        guard now - lastScrubTickTime >= minInterval else { return }
        lastScrubTickTime = now

        #if canImport(CoreHaptics)
        if ensureEngineActive() {
            // Delicate silky click at low speeds, crisp and defined at high speeds
            let dynamicIntensity = Float(0.55 + (speed * 0.38))
            let dynamicSharpness = Float(0.38 + (speed * 0.42))
            playTransient(intensity: dynamicIntensity, sharpness: dynamicSharpness)
            return
        }
        #endif

        #if canImport(UIKit)
        selectionGenerator.selectionChanged()
        #endif
    }

    // MARK: - Standard Generators Access

    #if canImport(UIKit)
    public var soft: UIImpactFeedbackGenerator { softGenerator }
    public var light: UIImpactFeedbackGenerator { lightGenerator }
    public var medium: UIImpactFeedbackGenerator { mediumGenerator }
    public var rigid: UIImpactFeedbackGenerator { rigidGenerator }
    public var selection: UISelectionFeedbackGenerator { selectionGenerator }
    public var notification: UINotificationFeedbackGenerator { notificationGenerator }
    #endif
}

// MARK: - Public HapticFeedback Namespace

/// Static interface for app-wide tactile feedback.
/// Delivers rich, boosted soft haptics and tailored transient, continuous, and dynamic feedback.
@MainActor
public enum HapticFeedback {

    // MARK: - Engine Pre-Warming

    /// Pre-warms the haptic generators ahead of imminent interaction.
    public static func prepare() {
        HapticManager.shared.prepare()
    }

    // MARK: - Intensified Core Impacts

    /// Generates cushioned, deep soft impact feedback.
    /// Boosted to 0.88 baseline intensity with low sharpness for a pronounced, luxurious physical thump.
    public static func softImpact(intensity: CGFloat = 0.88) {
        let val = Float(max(0.1, min(1.0, intensity)))
        HapticManager.shared.playTransient(intensity: val, sharpness: 0.20)
    }

    /// Generates crisp, clean light impact feedback for standard button taps and navigation.
    public static func lightImpact(intensity: CGFloat = 0.70) {
        let val = Float(max(0.1, min(1.0, intensity)))
        HapticManager.shared.playTransient(intensity: val, sharpness: 0.65)
    }

    /// Generates solid, grounded medium impact feedback for snap-to-expand / snap-to-minimize gestures.
    public static func mediumImpact(intensity: CGFloat = 0.85) {
        let val = Float(max(0.1, min(1.0, intensity)))
        HapticManager.shared.playTransient(intensity: val, sharpness: 0.45)
    }

    /// Generates sharp, clicky impact feedback for physical toggle switches.
    public static func rigidImpact(intensity: CGFloat = 0.85) {
        let val = Float(max(0.1, min(1.0, intensity)))
        HapticManager.shared.playTransient(intensity: val, sharpness: 0.85)
    }

    /// Generates crisp, instantaneous selection feedback for list item tapping and picker browsing.
    public static func selectionChanged() {
        guard HapticManager.shared.isEnabled else { return }
        #if canImport(UIKit)
        HapticManager.shared.selection.selectionChanged()
        #else
        HapticManager.shared.playTransient(intensity: 0.55, sharpness: 0.85)
        #endif
    }

    // MARK: - Action-Specific Tactile Signatures

    /// Dedicated Core Haptics patterns for the on-screen Play / Pause / Next / Back controls.
    public static func transport(_ kind: TransportHaptic) {
        HapticManager.shared.playTransport(kind)
    }

    /// Tactile signature for Play / Pause toggle:
    /// - Play: Instantaneous, crisp, authoritative mechanical switch-on snap (1.0 intensity, 0.92 sharpness).
    /// - Pause: Deep, weighted, cushioned magnetic brake latch (1.0 intensity, 0.15 sharpness).
    public static func playPause(isPlaying: Bool) {
        guard HapticManager.shared.isEnabled else { return }
        if isPlaying {
            #if canImport(CoreHaptics)
            if HapticManager.shared.ensureEngineActive() {
                HapticManager.shared.playDoubleTransient(
                    firstIntensity: 0.85,
                    firstSharpness: 0.80,
                    secondIntensity: 1.00,
                    secondSharpness: 0.92,
                    delay: 0.024
                )
                return
            }
            #endif
            #if canImport(UIKit)
            HapticManager.shared.rigid.prepare()
            HapticManager.shared.rigid.impactOccurred(intensity: 1.0)
            #endif
        } else {
            #if canImport(CoreHaptics)
            if HapticManager.shared.ensureEngineActive() {
                HapticManager.shared.playTransient(intensity: 1.0, sharpness: 0.15)
                return
            }
            #endif
            #if canImport(UIKit)
            HapticManager.shared.soft.prepare()
            HapticManager.shared.soft.impactOccurred(intensity: 1.0)
            #endif
        }
    }

    /// Directional, snappy skip click for Next / Previous track buttons:
    /// - Next: Progressive rising ratchet flick ("tick-SNAP!").
    /// - Previous: Progressive falling ratchet pull ("SNAP-tick!").
    public static func trackSkip(forward: Bool = true) {
        guard HapticManager.shared.isEnabled else { return }
        if forward {
            #if canImport(CoreHaptics)
            if HapticManager.shared.ensureEngineActive() {
                HapticManager.shared.playDoubleTransient(
                    firstIntensity: 0.70,
                    firstSharpness: 0.60,
                    secondIntensity: 1.00,
                    secondSharpness: 0.95,
                    delay: 0.038
                )
                return
            }
            #endif
            #if canImport(UIKit)
            HapticManager.shared.light.prepare()
            HapticManager.shared.light.impactOccurred(intensity: 0.70)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                HapticManager.shared.rigid.prepare()
                HapticManager.shared.rigid.impactOccurred(intensity: 1.0)
            }
            #endif
        } else {
            #if canImport(CoreHaptics)
            if HapticManager.shared.ensureEngineActive() {
                HapticManager.shared.playDoubleTransient(
                    firstIntensity: 1.00,
                    firstSharpness: 0.85,
                    secondIntensity: 0.60,
                    secondSharpness: 0.25,
                    delay: 0.038
                )
                return
            }
            #endif
            #if canImport(UIKit)
            HapticManager.shared.medium.prepare()
            HapticManager.shared.medium.impactOccurred(intensity: 1.0)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                HapticManager.shared.soft.prepare()
                HapticManager.shared.soft.impactOccurred(intensity: 0.70)
            }
            #endif
        }
    }

    /// Deep, cushioned physical 3D card flip impact (0.92 intensity).
    public static func cardFlip() {
        HapticManager.shared.playTransient(intensity: 0.92, sharpness: 0.20)
    }

    /// Firm, tactile grab pulse when touching down on the needle wheel or progress bar.
    public static func scrubStart() {
        HapticManager.shared.playTransient(intensity: 0.88, sharpness: 0.40)
    }

    /// Dynamic scrub tick that scales intensity and frequency with scrubbing velocity.
    /// Supports milestone accents on whole divisions (15s, 30s, 60s).
    public static func scrubTick(velocity: Double = 0.0, isAccent: Bool = false) {
        HapticManager.shared.playScrubTick(velocity: velocity, isAccent: isAccent)
    }

    /// Reassuring seek completion latch when finger releases after seeking.
    public static func scrubCommit() {
        HapticManager.shared.playTransient(intensity: 0.90, sharpness: 0.30)
    }

    /// Starts subtle continuous friction texture while dragging.
    public static func startContinuousScrub(intensity: Float = 0.30) {
        HapticManager.shared.startContinuous(intensity: intensity, sharpness: 0.20)
    }

    /// Updates continuous drag friction based on velocity.
    public static func updateContinuousScrub(velocity: Double) {
        let speed = Float(min(abs(velocity), 1000.0) / 1000.0)
        let dynamicIntensity = 0.20 + (speed * 0.25)
        HapticManager.shared.updateContinuous(intensity: dynamicIntensity, sharpness: 0.20 + (speed * 0.15))
    }

    /// Stops continuous drag friction.
    public static func stopContinuousScrub() {
        HapticManager.shared.stopContinuous()
    }

    /// Heavy, damped limit bump when reaching the start (0:00) or end of a track or slider limit.
    public static func boundaryBump() {
        HapticManager.shared.playTransient(intensity: 0.95, sharpness: 0.15)
    }

    /// Springy lift-off transient pulse when picking up a track to reorder in the queue.
    public static func dragPickup() {
        HapticManager.shared.playTransient(intensity: 0.80, sharpness: 0.60)
    }

    /// Solid magnetic slot-in lock when dropping a track into place.
    public static func dragDrop() {
        HapticManager.shared.playTransient(intensity: 0.88, sharpness: 0.40)
    }

    /// Delightful warm sparkle when favoriting / liking a track, and soft release when unliking.
    public static func favorite(isFavorite: Bool) {
        if isFavorite {
            HapticManager.shared.playDoubleTransient(
                firstIntensity: 0.78,
                firstSharpness: 0.45,
                secondIntensity: 0.96,
                secondSharpness: 0.85,
                delay: 0.065
            )
        } else {
            HapticManager.shared.playTransient(intensity: 0.60, sharpness: 0.30)
        }
    }

    /// Crisp notch click when passing neutral points (such as 0dB on the EQ or 1.0x playback speed).
    public static func detentSnap() {
        HapticManager.shared.playTransient(intensity: 0.78, sharpness: 0.70)
    }

    /// Cushioned magnetic snap for expanding, minimizing, or sheet detent changes.
    public static func snap(intensity: CGFloat = 0.85) {
        let val = Float(max(0.1, min(1.0, intensity)))
        HapticManager.shared.playTransient(intensity: val, sharpness: 0.30)
    }

    /// Dynamic toggle feedback with distinct on/off tactile accents for Shuffle, Repeat, and settings switches.
    public static func toggle(isOn: Bool) {
        modeToggle(isOn: isOn)
    }

    /// Crisp tactile actuation for mode toggles.
    public static func modeToggle(isOn: Bool) {
        if isOn {
            HapticManager.shared.playTransient(intensity: 0.85, sharpness: 0.80)
        } else {
            HapticManager.shared.playTransient(intensity: 0.65, sharpness: 0.60)
        }
    }

    // MARK: - Notifications

    /// Refined, warm double-pulse for successful operations.
    public static func notificationSuccess() {
        HapticManager.shared.playDoubleTransient(
            firstIntensity: 0.75,
            firstSharpness: 0.35,
            secondIntensity: 0.92,
            secondSharpness: 0.55,
            delay: 0.075
        )
    }

    /// Gentle warning feedback.
    public static func notificationWarning() {
        HapticManager.shared.playTransient(intensity: 0.75, sharpness: 0.60)
    }

    /// Firm double-pulse for errors or destructive alerts.
    public static func notificationError() {
        HapticManager.shared.playDoubleTransient(
            firstIntensity: 0.75,
            firstSharpness: 0.70,
            secondIntensity: 0.88,
            secondSharpness: 0.80,
            delay: 0.065
        )
    }
}
