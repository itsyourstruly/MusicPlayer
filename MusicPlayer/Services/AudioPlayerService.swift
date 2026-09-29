import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import os
#if os(macOS)
import CoreAudio
#endif

/// High-performance, concurrency-safe audio playback manager isolated to the `@MainActor`.
/// Leverages AVFoundation, modern Observation, and MediaPlayer Remote Command integration.
@Observable
@MainActor
public final class AudioPlayerService {
    /// Shared instance accessible for system helpers and local streaming server
    public static weak var shared: AudioPlayerService?

    // MARK: - Observable State
    
    // Currently playing or paused track
    public private(set) var currentTrack: Track?
    // Current playback state (playing, paused, stopped)
    public private(set) var playbackStatus: PlaybackStatus = .stopped {
        didSet {
            #if os(iOS)
            switch playbackStatus {
            case .playing, .buffering:
                MPNowPlayingInfoCenter.default().playbackState = .playing
            case .paused:
                MPNowPlayingInfoCenter.default().playbackState = .paused
            case .stopped:
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
            #endif
        }
    }
    // Elapsed playback time in seconds
    public private(set) var currentTime: TimeInterval = 0
    // Total audio duration in seconds
    public private(set) var duration: TimeInterval = 0
    // Upcoming track queue
    public private(set) var queue: [Track] = [] {
        didSet {
            prewarmNextTrackIfNeeded()
        }
    }
    // Index of current track in active queue
    public private(set) var currentIndex: Int? {
        didSet {
            prewarmNextTrackIfNeeded()
        }
    }
    // Active repeat configuration (off, all, one)
    public var repeatMode: RepeatMode = .off
    // Active shuffle configuration
    public var shuffleMode: ShuffleMode = .off
    
    // True while the user is dragging the scrub bar
    public var isSeeking: Bool = false
    // Target seek timestamp during scrubber interaction
    public var seekPosition: TimeInterval = 0
    // Audio stream buffering progress ratio
    public var bufferProgress: Double { 1.0 }
    // Connected audio output route name (e.g., "THIS DEVICE", "AIRPODS PRO", "HEADPHONES")
    public private(set) var currentAudioRouteName: String = "THIS DEVICE"
    
    /// Indicates whether playback is currently routed to an external audio destination (Bluetooth, CarPlay, AirPlay, etc.)
    public var isExternalAudioRouteActive: Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        return outputs.contains { output in
            output.portType != .builtInSpeaker && output.portType != .builtInReceiver
        }
        #else
        return currentAudioRouteName != "THIS DEVICE"
        #endif
    }
    
    // MARK: - Desktop Volume & Mute State
    
    // Master output volume (0.0 to 1.0)
    public var volume: Float = 1.0 {
        didSet {
            let clamped = min(max(volume, 0.0), 1.0)
            if volume != clamped {
                volume = clamped
            }
            if !isCrossfading && !isFadingOutPause && !isFadingInPlay && !isSmoothSkipping && !isSmoothSeeking {
                player?.volume = volume
            }
            if isMuted && volume > 0 {
                isMuted = false
            }
        }
    }
    
    // Mute state toggle
    public var isMuted: Bool = false {
        didSet {
            player?.isMuted = isMuted
        }
    }
    
    // Toggle mute
    public func toggleMute() {
        isMuted.toggle()
    }
    
    // Increase volume
    public func increaseVolume(by delta: Float = 0.05) {
        volume = min(1.0, volume + delta)
    }
    
    // Decrease volume
    public func decreaseVolume(by delta: Float = 0.05) {
        volume = max(0.0, volume - delta)
    }
    
    // MARK: - Crossfade & Queue Configuration
    
    // Enables smooth audio crossfade between consecutive tracks
    public var isCrossfadeEnabled: Bool = false
    // Length of the crossfade transition in seconds
    public var crossfadeDuration: Double = 4.0
    // Whether selecting a song maintains the active queue context
    public var playTrackInCurrentQueue: Bool = false
    // Play tap action immediately inserts song next in queue
    public var tapToPlayNext: Bool = false
    // Enables micro-fade when skipping tracks to prevent audio pops
    public var smoothSkippingEnabled: Bool = false
    // Automatically plays next track when current track completes
    public var autoPlayNext: Bool = true
    // Enables remembering playback position for tracks exceeding minimum threshold
    public var rememberPlaybackPosition: Bool = true
    // Minimum track length (in minutes) required to save and remember playback position
    public var rememberPlaybackPositionMinMinutes: Double = 10.0
    // Callbacks for persisting and querying playback position
    public var onSavePlaybackPosition: ((UUID, TimeInterval) -> Void)? = nil
    public var onGetPlaybackPosition: ((UUID) -> TimeInterval?)? = nil
    public var onClearPlaybackPosition: ((UUID) -> Void)? = nil
    
    @ObservationIgnored private var localPlaybackPositions: [UUID: TimeInterval] = [:]
    
    // Priority queue for tracks explicitly marked to play next
    public var playNextQueue: [Track] = [] {
        didSet {
            prewarmNextTrackIfNeeded()
        }
    }
    // Callback invoked whenever a track begins playing
    public var onTrackPlay: ((UUID) -> Void)? = nil
    
    @ObservationIgnored private var fadePlayer: AVPlayer?
    @ObservationIgnored private var fadeTimeObserverToken: Any?
    @ObservationIgnored private var isCrossfading: Bool = false
    @ObservationIgnored private var crossfadeTask: Task<Void, Never>?
    
    @ObservationIgnored private var smoothSkipTask: Task<Void, Never>?
    @ObservationIgnored private var skipOutgoingPlayer: AVPlayer?
    @ObservationIgnored private var isSmoothSkipping: Bool = false
    
    @ObservationIgnored private var playPauseFadeTask: Task<Void, Never>?
    @ObservationIgnored private var isFadingOutPause: Bool = false
    @ObservationIgnored private var isFadingInPlay: Bool = false
    
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var isSmoothSeeking: Bool = false
    
    // Pre-warming state for instant zero-latency track transitions
    @ObservationIgnored private var prewarmedTrackID: UUID?
    @ObservationIgnored private var prewarmedPlayerItem: AVPlayerItem?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var lastSkipTimestamp: TimeInterval = 0
    
    // MARK: - Playback Position Helpers
    
    /// Saves the playback position of the currently playing track if it meets duration requirements.
    public func saveCurrentPlaybackPositionIfNeeded() {
        guard rememberPlaybackPosition,
              let track = currentTrack else { return }
        
        let minDuration = rememberPlaybackPositionMinMinutes * 60.0
        guard track.duration >= minDuration else { return }
        
        let pos = currentTime
        // If the track is near completion (within 3 seconds of end) or barely started (<= 2 seconds), clear position
        if pos >= max(0, track.duration - 3.0) || pos <= 2.0 {
            localPlaybackPositions.removeValue(forKey: track.id)
            onClearPlaybackPosition?(track.id)
            AppLogger.audio.info("Cleared saved playback position for track: \(track.title)")
        } else {
            localPlaybackPositions[track.id] = pos
            onSavePlaybackPosition?(track.id, pos)
            AppLogger.audio.info("Saved playback position for track \(track.title): \(pos)s")
        }
    }
    
    /// Queries the saved playback position for a track if it qualifies.
    public func savedPlaybackPosition(for track: Track) -> TimeInterval? {
        guard rememberPlaybackPosition else { return nil }
        let minDuration = rememberPlaybackPositionMinMinutes * 60.0
        guard track.duration >= minDuration else { return nil }
        
        if let pos = onGetPlaybackPosition?(track.id) ?? localPlaybackPositions[track.id],
           pos > 2.0, pos < max(0, track.duration - 3.0) {
            return pos
        }
        return nil
    }
    
    /// Clears any saved playback position for a track.
    public func clearSavedPlaybackPosition(for trackID: UUID) {
        localPlaybackPositions.removeValue(forKey: trackID)
        onClearPlaybackPosition?(trackID)
    }
    
    // MARK: - Sleep Timer Engine
    
    // Indicates whether the sleep timer is currently active
    public private(set) var isSleepTimerEnabled: Bool = false
    // Target duration in minutes selected by user (0 to 90)
    public var sleepTimerMinutes: Double = 0
    // Remaining seconds before active sleep timer triggers pause
    public private(set) var sleepTimerRemainingSeconds: TimeInterval = 0
    
    @ObservationIgnored private nonisolated(unsafe) var sleepTimerTask: Task<Void, Never>?
    
    /// Sets and activates the sleep timer for the given duration in minutes (0 to 90).
    public func setSleepTimer(minutes: Double) {
        let clamped = min(90.0, max(0.0, minutes))
        if clamped <= 0 {
            cancelSleepTimer()
            return
        }
        sleepTimerMinutes = clamped
        isSleepTimerEnabled = true
        sleepTimerRemainingSeconds = clamped * 60.0
        
        sleepTimerTask?.cancel()
        sleepTimerTask = Task { @MainActor in
            while !Task.isCancelled && self.sleepTimerRemainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                
                self.sleepTimerRemainingSeconds -= 1
                if self.sleepTimerRemainingSeconds <= 0 {
                    self.pause()
                    self.cancelSleepTimer()
                    AppLogger.audio.info("Sleep timer fired. Paused playback.")
                    break
                }
            }
        }
        AppLogger.audio.info("Sleep timer set to \(clamped) minutes.")
    }
    
    /// Cancels the active sleep timer.
    public func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        isSleepTimerEnabled = false
        sleepTimerMinutes = 0
        sleepTimerRemainingSeconds = 0
        AppLogger.audio.info("Sleep timer cancelled.")
    }
    
    /// Toggles the sleep timer on or off. Defaults to 30 minutes when turning on.
    public func toggleSleepTimer(defaultMinutes: Double = 30) {
        if isSleepTimerEnabled {
            cancelSleepTimer()
        } else {
            setSleepTimer(minutes: defaultMinutes)
        }
    }
    
    // MARK: - Internal Audio Engine Properties
    
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var playerItemEndObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var playerItemFailedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var itemStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private var playerTimeControlObserver: NSKeyValueObservation?
    @ObservationIgnored private var audioInterruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var audioRouteChangeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var mediaServicesResetObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var activeTrackSecurityScopeURL: URL?
    @ObservationIgnored private var hasCountedCurrentPlay: Bool = false
    @ObservationIgnored private var playbackAccumulatedTime: TimeInterval = 0
    @ObservationIgnored private var isTransitioningTrack: Bool = false
    @ObservationIgnored private var transitionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var isRoutingChanging: Bool = false
#if os(iOS)
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var appLifecycleObservers: [any NSObjectProtocol] = []
#endif
    
    // Initialize with configured properties
    public init() {
        AudioPlayerService.shared = self
        setupAudioNotifications()
        setupAudioSession()
        setupRemoteCommandCenter()
#if os(iOS)
        setupLifecycleObservers()
#endif
        EqualizerManager.shared.playerService = self
    }
    
    deinit {
        crossfadeTask?.cancel()
        smoothSkipTask?.cancel()
        playPauseFadeTask?.cancel()
        prewarmTask?.cancel()
        sleepTimerTask?.cancel()
        if let fadeToken = fadeTimeObserverToken {
            fadePlayer?.removeTimeObserver(fadeToken)
        }
        fadePlayer?.pause()
        fadePlayer = nil
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObs = playerItemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            playerItemEndObserver = nil
        }
        if let failedObs = playerItemFailedObserver {
            NotificationCenter.default.removeObserver(failedObs)
            playerItemFailedObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        playerTimeControlObserver?.invalidate()
        playerTimeControlObserver = nil
        player?.pause()
        player = nil
        if let intObs = audioInterruptionObserver {
            NotificationCenter.default.removeObserver(intObs)
        }
        if let routeObs = audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(routeObs)
        }
        if let resetObs = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(resetObs)
        }
#if os(iOS)
        let taskID = backgroundTaskID
        if taskID != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
        for obs in appLifecycleObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        appLifecycleObservers.removeAll()
#endif
        activeTrackSecurityScopeURL?.stopAccessingSecurityScopedResource()
        activeTrackSecurityScopeURL = nil
    }
    
    // MARK: - Computed Properties
    
    public var progressRatio: Double {
        // Ensure preconditions are met before proceeding
        guard duration > 0 else { return 0 }
        // Time
        let time = isSeeking ? seekPosition : currentTime
        return min(max(time / duration, 0), 1)
    }
    
    // Controls has next track
    public var hasNextTrack: Bool {
        if !playNextQueue.isEmpty { return true }
        // Ensure preconditions are met before proceeding
        guard let index = currentIndex, !queue.isEmpty else { return false }
        return index + 1 < queue.count || repeatMode == .all
    }
    
    // Controls has previous track
    public var hasPreviousTrack: Bool {
        // Ensure preconditions are met before proceeding
        guard let index = currentIndex, !queue.isEmpty else { return false }
        return index > 0 || currentTime > 3.0
    }
    
    /// The upcoming next track in the queue, prioritizing Play Next before upcoming queue songs.
    public var nextTrack: Track? {
        if let firstPlayNext = playNextQueue.first {
            return firstPlayNext
        }
        // Ensure preconditions are met before proceeding
        guard let index = currentIndex, !queue.isEmpty, index + 1 < queue.count else { return nil }
        return queue[index + 1]
    }
    
    // MARK: - Playback Control APIs
    
    /// Plays a track within the active queue: inserts immediately after the current song and starts playback.
    public func playInCurrentQueue(track: Track) {
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            smoothSkip {
                self.performPlayInCurrentQueue(track: track)
            }
            return
        }
        performPlayInCurrentQueue(track: track)
    }

    private func performPlayInCurrentQueue(track: Track) {
        cancelCrossfade()
        // Ensure preconditions are met before proceeding
        guard !queue.isEmpty, let idx = currentIndex else {
            performPlay(track: track, inQueue: [], startIndex: nil)
            return
        }
        // Insert index
        let insertIndex = idx + 1
        if insertIndex <= queue.count {
            queue.insert(track, at: insertIndex)
        } else {
            queue.append(track)
        }
        self.currentIndex = insertIndex
        loadAndPlay(track: track)
    }
    
    /// Begins playback of a specific track within a provided playlist or queue context.
    public func play(track: Track, inQueue newQueue: [Track] = [], startIndex: Int? = nil) {
        if playTrackInCurrentQueue && !queue.isEmpty && currentIndex != nil {
            playInCurrentQueue(track: track)
            return
        }
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            smoothSkip {
                self.performPlay(track: track, inQueue: newQueue, startIndex: startIndex)
            }
            return
        }
        performPlay(track: track, inQueue: newQueue, startIndex: startIndex)
    }

    private func performPlay(track: Track, inQueue newQueue: [Track], startIndex: Int?) {
        cancelCrossfade()
        // Serial queue for active queue
        let activeQueue = newQueue.isEmpty ? [track] : newQueue
        self.originalQueue = activeQueue
        
        if shuffleMode == .on {
            // Shuffled
            var shuffled = activeQueue
            // Keep the selected track at the head of the shuffled queue
            if let idx = shuffled.firstIndex(where: { $0.id == track.id }) {
                shuffled.remove(at: idx)
                shuffled.insert(track, at: 0)
            }
            self.queue = shuffled
            self.currentIndex = 0
        } else {
            self.queue = activeQueue
            self.currentIndex = startIndex ?? activeQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        }
        
        loadAndPlay(track: track)
    }
    
    /// Toggles play and pause state.
    public func togglePlayPause() {
        if playbackStatus == .playing || isFadingInPlay {
            pause()
        } else {
            play()
        }
    }
    
    /// Dynamically applies playback rate to the active player.
    public func applyPlaybackSpeed(_ speed: Double) {
        let clamped = Float(min(2.0, max(0.25, speed)))
        if let player = player {
            player.defaultRate = clamped
            if playbackStatus == .playing || player.timeControlStatus == .playing {
                player.rate = clamped
            }
        }
        updateNowPlayingPlaybackState()
        AppLogger.audio.info("Applied live playback speed: \(clamped)x (status: \(self.playbackStatus.rawValue))")
    }

    /// Resumes playback. When TRANSITION TRACKS WHEN SKIPPING is enabled, smoothly fades in audio
    /// quickly at first, then smoothens out nicely to full volume.
    public func play() {
        // Ensure preconditions are met before proceeding
        guard let player = player, player.currentItem != nil else {
            if let track = currentTrack ?? queue.first {
                loadAndPlay(track: track)
            }
            return
        }
        
        // If at or near end of track, rewind to start
        if currentTime >= duration && duration > 0 {
            seek(to: 0)
        }
        
        isTransitioningTrack = false
        transitionTimeoutTask?.cancel()
        Task {
            await AudioSessionManager.shared.activateSessionIfNeeded()
        }
        
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        player.defaultRate = speed
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = false

        let wasFadingOut = isFadingOutPause
        playPauseFadeTask?.cancel()
        playPauseFadeTask = nil
        isFadingOutPause = false

        let masterVol = volume
        if smoothSkippingEnabled && masterVol > 0 && !isMuted {
            isFadingInPlay = true
            // If reversing an in-flight pause fade, resume from current attenuated volume; otherwise start from complete silence (0.0)
            let startVol = wasFadingOut ? min(player.volume, masterVol) : 0.0
            player.volume = startVol
            player.play()
            playbackStatus = .playing
            updateNowPlayingPlaybackState()

            playPauseFadeTask = Task { @MainActor in
                let steps = 45
                let stepDuration: UInt64 = 20_000_000 // 20ms per step -> 900ms total smooth fade-in duration

                for step in 1...steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: stepDuration)
                    if Task.isCancelled { break }

                    let progress = Float(step) / Float(steps)
                    // Slower, smoother ramp (smoothstep): starts gently from silence, ramps up smoothly, then seamlessly flattens to master volume
                    let factor = progress * progress * (3.0 - 2.0 * progress)
                    let currentVol = startVol + (masterVol - startVol) * factor
                    player.volume = min(masterVol, max(0.0, currentVol))
                }

                guard !Task.isCancelled else { return }
                player.volume = masterVol
                self.isFadingInPlay = false
            }
        } else {
            isFadingInPlay = false
            player.volume = masterVol
            player.play()
            playbackStatus = .playing
            updateNowPlayingPlaybackState()
        }

        AppLogger.audio.info("Playback resumed at \(speed)x.")
    }
    
    /// Pauses playback. When TRANSITION TRACKS WHEN SKIPPING is enabled, smoothly fades out audio
    /// with an S-curve: starts slower, ramps up its descent, then flattens out nicely into silence.
    public func pause(smooth: Bool = true) {
        isTransitioningTrack = false
        transitionTimeoutTask?.cancel()
        cancelCrossfade()
        smoothSkipTask?.cancel()
        smoothSkipTask = nil
        if let outgoing = skipOutgoingPlayer {
            outgoing.pause()
            outgoing.volume = 0
            skipOutgoingPlayer = nil
        }

        playPauseFadeTask?.cancel()
        playPauseFadeTask = nil
        isFadingInPlay = false

        guard let player = player else {
            playbackStatus = .paused
            updateNowPlayingPlaybackState()
            return
        }

        playbackStatus = .paused
        updateNowPlayingPlaybackState()

        Task.detached(priority: .utility) { [weak self] in
            await MainActor.run {
                self?.saveCurrentPlaybackPositionIfNeeded()
            }
        }

        let startVol = player.volume
        if smooth && smoothSkippingEnabled && startVol > 0 && !isMuted {
            isFadingOutPause = true
            playPauseFadeTask = Task { @MainActor in
                let steps = 18
                let stepDuration: UInt64 = 20_000_000 // 20ms per step -> 360ms total fade duration (slightly faster)

                for step in 1...steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: stepDuration)
                    if Task.isCancelled { break }

                    let progress = Float(step) / Float(steps)
                    // Drops faster at first, then flattens out smoothly at zero
                    let factor = (1.0 - progress) * (1.0 - progress)
                    player.volume = min(self.volume, max(0.0, startVol * factor))
                }

                guard !Task.isCancelled else { return }
                player.pause()
                player.volume = 0.0 // Keep player at 0.0 while paused so subsequent resume never starts with a sudden burst
                self.isFadingOutPause = false
                AppLogger.audio.info("Playback smoothly paused with fast-start ease-out fade.")
            }
        } else {
            isFadingOutPause = false
            player.pause()
            player.volume = volume
            AppLogger.audio.info("Playback paused immediately.")
        }
    }
    
    /// Advances to the next track in the queue, prioritizing Play Next before regular upcoming items.
    /// When smooth skipping is enabled, fades out the current track before loading and fading in the next.
    public func next() {
        if smoothSkippingEnabled && playbackStatus == .playing {
            smoothSkip {
                self.performNext()
            }
            return
        }
        performNext()
    }
    
    // Perform next
    private func performNext() {
        cancelCrossfade()
        
        // 1. Play from dedicated Play Next queue if available
        if !playNextQueue.isEmpty {
            // Next song
            let nextSong = playNextQueue.removeFirst()
            loadAndPlay(track: nextSong)
            return
        }
        
        // 2. Otherwise advance in standard queue
        guard !queue.isEmpty, let idx = currentIndex else { return }
        
        // Next idx
        let nextIdx = idx + 1
        if nextIdx < queue.count {
            currentIndex = nextIdx
            loadAndPlay(track: queue[nextIdx])
        } else if repeatMode == .all {
            currentIndex = 0
            loadAndPlay(track: queue[0])
        } else {
            // Reached end of queue without repeat all
            pause()
            seek(to: 0)
            playbackStatus = .stopped
            AppLogger.audio.info("Reached end of queue.")
        }
    }
    
    /// Moves to the previous track or restarts the current track.
    /// When smooth skipping is enabled, fades out before switching.
    public func previous() {
        if smoothSkippingEnabled && playbackStatus == .playing {
            smoothSkip {
                self.performPrevious()
            }
            return
        }
        performPrevious()
    }
    
    // Perform previous
    private func performPrevious() {
        cancelCrossfade()
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        // If track has been playing for more than 3 seconds, restart and play it
        if currentTime > 3.0 {
            seek(to: 0)
            player?.defaultRate = speed
            player?.play()
            playbackStatus = .playing
            return
        }
        
        // Ensure preconditions are met before proceeding
        guard !queue.isEmpty, let idx = currentIndex else { return }
        
        // Prev idx
        let prevIdx = idx - 1
        if prevIdx >= 0 {
            currentIndex = prevIdx
            loadAndPlay(track: queue[prevIdx])
        } else {
            seek(to: 0)
            player?.defaultRate = speed
            player?.play()
            playbackStatus = .playing
        }
    }
    
    /// Seeks to a specific timestamp in seconds with smooth, click-free audio micro-fading and instant resumption.
    public func seek(to timeInSeconds: TimeInterval, completion: (@Sendable () -> Void)? = nil) {
        cancelCrossfade()
        // Ensure preconditions are met before proceeding
        guard let player = player else {
            self.isSeeking = false
            completion?()
            return
        }
        self.isSeeking = true
        // Clamped time
        let clampedTime = duration > 0 ? max(0, min(timeInSeconds, duration)) : max(0, timeInSeconds)
        self.currentTime = clampedTime
        self.seekPosition = clampedTime
        AppLogger.audio.debug("Seeking to \(String(format: "%.2f", clampedTime))s (duration: \(String(format: "%.2f", self.duration))s)")
        
        // Dynamically match the track asset's native timescale (e.g. 48000 for 48k car audio, 44100, etc.)
        let timescale = player.currentItem?.asset.duration.timescale ?? 600
        let targetCMTime = CMTime(seconds: clampedTime, preferredTimescale: timescale)
        
        // If not actively playing (e.g. paused or stopped), seek directly without volume micro-fading
        guard playbackStatus == .playing && player.rate > 0 else {
            seekTask?.cancel()
            seekTask = nil
            isSmoothSeeking = false
            
            player.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else {
                    completion?()
                    return
                }
                Task { @MainActor in
                    self.isSeeking = false
                    self.updateNowPlayingElapsedTime()
                    AppLogger.audio.debug("Paused seek finished at \(String(format: "%.2f", self.currentTime))s")
                    completion?()
                }
            }
            return
        }
        
        // Active playback: cancel any in-flight seek so the latest seek target position executes immediately
        seekTask?.cancel()
        
        let masterVol = self.volume
        if masterVol <= 0 || isMuted {
            isSmoothSeeking = false
            let tolerance = CMTime(seconds: 0.03, preferredTimescale: timescale)
            player.seek(to: targetCMTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                guard let self = self else {
                    completion?()
                    return
                }
                Task { @MainActor in
                    self.isSeeking = false
                    self.updateNowPlayingElapsedTime()
                    completion?()
                }
            }
            return
        }
        
        isSmoothSeeking = true
        
        seekTask = Task { @MainActor [weak self] in
            guard let self = self, let activePlayer = self.player else {
                completion?()
                return
            }
            
            // Phase 1: Micro-dip to 0 to decouple outgoing buffer and avoid click
            activePlayer.volume = 0.0
            
            // Phase 2: Dispatch seek immediately with high-performance tolerance
            let tolerance = CMTime(seconds: 0.03, preferredTimescale: timescale)
            activePlayer.seek(to: targetCMTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isSmoothSeeking = false
                    self.isSeeking = false
                    self.player?.volume = masterVol
                    self.updateNowPlayingElapsedTime()
                    AppLogger.audio.debug("Smooth instant seek finished at \(String(format: "%.2f", self.currentTime))s")
                    completion?()
                }
            }
            
            let speed = Float(EqualizerManager.shared.playbackSpeed)
            if activePlayer.rate == 0 {
                activePlayer.rate = speed
            }
            
            // Phase 3: Ultra-fast smoothstep micro-fade in (~14ms) from silence to full master volume
            // Does not wait in silence for the seek completion callback; as soon as AVPlayer delivers
            // the new audio frames, volume is already restored and AudioDSPProcessor's 128-sample ramp
            // curves the new signal in cleanly with zero pop and zero gap.
            let fadeInSteps = 4
            let fadeInStepDuration: UInt64 = 3_500_000 // 3.5ms per step -> 14ms total
            for step in 1...fadeInSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: fadeInStepDuration)
                if Task.isCancelled { break }
                let progress = Float(step) / Float(fadeInSteps)
                let factor = progress * progress * (3.0 - 2.0 * progress)
                activePlayer.volume = min(masterVol, max(0.0, masterVol * factor))
            }
            
            guard !Task.isCancelled else { return }
            activePlayer.volume = masterVol
        }
    }
    
    /// Toggles shuffle mode, reordering the queue while keeping the active track.
    public func toggleShuffle() {
        shuffleMode = shuffleMode.toggled
        // Ensure preconditions are met before proceeding
        guard let current = currentTrack else { return }
        
        if shuffleMode == .on {
            // Remaining
            var remaining = queue.filter { $0.id != current.id }
            remaining.shuffle()
            self.queue = [current] + remaining
            self.currentIndex = 0
        } else {
            self.queue = originalQueue
            self.currentIndex = originalQueue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
        AppLogger.audio.info("Shuffle mode updated: \(self.shuffleMode.label)")
    }
    
    /// Cycles repeat mode: Off -> All -> One -> Off.
    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
        AppLogger.audio.info("Repeat mode updated: \(self.repeatMode.label)")
    }
    
    /// Reorders queue items.
    public func moveQueueItem(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        if let current = currentTrack {
            self.currentIndex = queue.firstIndex(where: { $0.id == current.id })
        }
    }
    
    /// Removes an item from the queue.
    public func removeQueueItem(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard queue.indices.contains(index) else { return }
        // Removed track
        let removedTrack = queue.remove(at: index)
        
        if let current = currentTrack {
            if removedTrack.id == current.id {
                // If removing current track, play next
                if index < queue.count {
                    self.currentIndex = index
                    loadAndPlay(track: queue[index])
                } else if !queue.isEmpty {
                    self.currentIndex = 0
                    loadAndPlay(track: queue[0])
                } else {
                    stopAndClear()
                }
            } else {
                self.currentIndex = queue.firstIndex(where: { $0.id == current.id })
            }
        }
    }
    
    /// Adds a track to the dedicated Play Next queue (played before upcoming playlist tracks).
    /// By default, adding multiple tracks to play next will add them to the end of the play next queue.
    public func playNext(track: Track) {
        if currentTrack == nil && queue.isEmpty {
            play(track: track)
            return
        }
        playNextQueue.append(track)
        AppLogger.audio.info("Added track to Play Next queue: \(track.title)")
    }
    
    /// Inserts a track to the very front of the Play Next queue (to play immediately next).
    public func insertPlayNextFront(track: Track) {
        if currentTrack == nil && queue.isEmpty {
            play(track: track)
            return
        }
        playNextQueue.insert(track, at: 0)
        AppLogger.audio.info("Inserted track at front of Play Next queue: \(track.title)")
    }
    
    /// Adds multiple tracks to the dedicated Play Next queue.
    public func playNext(tracks: [Track]) {
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }
        if currentTrack == nil && queue.isEmpty {
            if let first = tracks.first {
                play(track: first, inQueue: tracks)
            }
            return
        }
        playNextQueue.append(contentsOf: tracks)
        AppLogger.audio.info("Added \(tracks.count) tracks to Play Next queue.")
    }
    
    /// Inserts multiple tracks to the very front of the Play Next queue.
    public func insertPlayNextFront(tracks: [Track]) {
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }
        if currentTrack == nil && queue.isEmpty {
            if let first = tracks.first {
                play(track: first, inQueue: tracks)
            }
            return
        }
        playNextQueue.insert(contentsOf: tracks, at: 0)
        AppLogger.audio.info("Inserted \(tracks.count) tracks at front of Play Next queue.")
    }
    
    /// Removes an item from the Play Next queue.
    public func removePlayNextItem(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard playNextQueue.indices.contains(index) else { return }
        playNextQueue.remove(at: index)
    }
    
    /// Reorders items within the Play Next queue.
    public func movePlayNextItem(fromOffsets source: IndexSet, toOffset destination: Int) {
        playNextQueue.move(fromOffsets: source, toOffset: destination)
    }

    /// Moves a track from the Play Next queue to the main queue at a destination index.
    public func moveFromPlayNextToQueue(playNextIndex: Int, queueDestinationIndex: Int) {
        guard playNextQueue.indices.contains(playNextIndex) else { return }
        let track = playNextQueue.remove(at: playNextIndex)
        let clampedIndex = max(0, min(queueDestinationIndex, queue.count))
        queue.insert(track, at: clampedIndex)
        if let current = currentTrack {
            self.currentIndex = queue.firstIndex(where: { $0.id == current.id })
        }
    }

    /// Moves a track from the main queue to the Play Next queue at a destination index.
    public func moveFromQueueToPlayNext(queueIndex: Int, playNextDestinationIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        let track = queue.remove(at: queueIndex)
        let clampedIndex = max(0, min(playNextDestinationIndex, playNextQueue.count))
        playNextQueue.insert(track, at: clampedIndex)
        if let current = currentTrack {
            self.currentIndex = queue.firstIndex(where: { $0.id == current.id })
        }
    }
    
    /// Clears all tracks from the Play Next queue.
    public func clearPlayNextQueue() {
        playNextQueue.removeAll()
    }
    
    /// Immediately plays a track selected directly from the Play Next queue.
    public func playFromPlayNext(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard playNextQueue.indices.contains(index) else { return }
        // Track
        let track = playNextQueue.remove(at: index)
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            smoothSkip {
                self.loadAndPlay(track: track)
            }
            return
        }
        loadAndPlay(track: track)
    }
    
    /// Appends a track to the end of the current queue.
    public func appendToQueue(track: Track) {
        if queue.isEmpty {
            play(track: track)
        } else {
            queue.append(track)
        }
    }
    
    /// Convenience alias for appendToQueue(track:).
    public func enqueue(track: Track) {
        appendToQueue(track: track)
    }
    
    /// Appends multiple tracks to the end of the current queue.
    public func appendToQueue(tracks: [Track]) {
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }
        if queue.isEmpty {
            if let first = tracks.first {
                play(track: first, inQueue: tracks)
            }
            return
        }
        queue.append(contentsOf: tracks)
    }
    
    /// Convenience alias for appendToQueue(tracks:).
    public func enqueue(tracks: [Track]) {
        appendToQueue(tracks: tracks)
    }
    
    /// Clears the queue and stops playback.
    public func stopAndClear() {
        saveCurrentPlaybackPositionIfNeeded()
        cancelCrossfade()
        smoothSkipTask?.cancel()
        smoothSkipTask = nil
        playPauseFadeTask?.cancel()
        playPauseFadeTask = nil
        isFadingOutPause = false
        isFadingInPlay = false
        if let outgoing = skipOutgoingPlayer {
            outgoing.pause()
            outgoing.volume = 0
            skipOutgoingPlayer = nil
        }
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmedTrackID = nil
        prewarmedPlayerItem = nil
        teardownPlayerObservers()
        player?.pause()
        player = nil
        currentTrack = nil
        playNextQueue.removeAll()
        queue = []
        originalQueue = []
        currentIndex = nil
        currentTime = 0
        duration = 0
        playbackStatus = .stopped
        activeTrackSecurityScopeURL?.stopAccessingSecurityScopedResource()
        activeTrackSecurityScopeURL = nil
        clearNowPlayingInfo()
    }
    
    /// Clears upcoming tracks from the queue while keeping current track playing.
    public func clearQueue() {
        if let current = currentTrack {
            queue = [current]
            currentIndex = 0
        } else {
            queue = []
            currentIndex = nil
        }
    }
    
    /// Removes an item at specific index from queue (alias for removeQueueItem).
    public func removeFromQueue(at index: Int) {
        removeQueueItem(at: index)
    }

    /// Refreshes in-memory metadata of the current playing track and queue if it was edited externally.
    public func syncTrackMetadata(updatedTrack: Track) {
        if currentTrack?.id == updatedTrack.id {
            self.currentTrack = updatedTrack
            self.setupNowPlayingInfo(for: updatedTrack)
        }
        for i in 0..<queue.count {
            if queue[i].id == updatedTrack.id {
                queue[i] = updatedTrack
            }
        }
        for i in 0..<originalQueue.count {
            if originalQueue[i].id == updatedTrack.id {
                originalQueue[i] = updatedTrack
            }
        }
    }
    
    /// Plays a specific track in the existing queue by its queue index.
    public func playTrackInQueue(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            smoothSkip {
                self.currentIndex = index
                self.loadAndPlay(track: track)
            }
            return
        }
        self.currentIndex = index
        loadAndPlay(track: track)
    }
    
    // MARK: - Internal Audio Engine Logic
    
    // Load and play
    private func loadAndPlay(track: Track) {
#if os(iOS)
        beginBackgroundTaskAssertion()
#endif
        if let current = currentTrack, current.id != track.id {
            saveCurrentPlaybackPositionIfNeeded()
        }
        cancelCrossfade()
        self.isTransitioningTrack = true
        transitionTimeoutTask?.cancel()
        transitionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.isTransitioningTrack = false
        }
        self.isSeeking = false
        self.currentTrack = track
        self.duration = track.duration
        
        let resumePosition = savedPlaybackPosition(for: track) ?? 0.0
        self.currentTime = resumePosition
        // Immediately set playback status to playing for instantaneous UI responsiveness
        self.playbackStatus = .playing
        self.hasCountedCurrentPlay = false
        self.playbackAccumulatedTime = 0
        
        // 1. Ensure audio session is active
        Task {
            await AudioSessionManager.shared.activateSessionIfNeeded()
        }
        
        // 2. Ensure root folder bookmark is actively accessed and resolve accessible file URL
        _ = SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        let resolvedURL = SecurityScopedBookmark.shared.resolveAccessibleURL(for: track.url)
        
        // Retain security-scoped access for individual file if applicable
        if activeTrackSecurityScopeURL?.path != resolvedURL.path {
            activeTrackSecurityScopeURL?.stopAccessingSecurityScopedResource()
            activeTrackSecurityScopeURL = nil
            if resolvedURL.startAccessingSecurityScopedResource() {
                activeTrackSecurityScopeURL = resolvedURL
            }
        }
        
        // Teardown item-specific observers (keeps player-level time observer intact)
        teardownItemObservers()
        
        // Trigger background download if track is an undownloaded iCloud ubiquitous item asynchronously
        Task.detached(priority: .utility) {
            if let values = try? resolvedURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
               values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: resolvedURL)
            }
        }
        
        // Use pre-warmed item if available, otherwise instantiate with studio-grade spectral algorithm for pristine music fidelity
        let playerItem: AVPlayerItem
        if prewarmedTrackID == track.id, let prewarmed = prewarmedPlayerItem {
            playerItem = prewarmed
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
        } else {
            let asset = AVURLAsset(url: resolvedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            playerItem = AVPlayerItem(asset: asset)
            playerItem.audioTimePitchAlgorithm = .spectral
            attachAudioMix(to: playerItem)
        }
        if playerItem.audioMix == nil {
            attachAudioMix(to: playerItem)
        }
        
        if resumePosition > 0 {
            let initialCMTime = CMTime(seconds: resumePosition, preferredTimescale: 600)
            playerItem.seek(to: initialCMTime, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        
        if player == nil {
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            newPlayer.allowsExternalPlayback = true
            #if os(iOS)
            newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
            #endif
            self.player = newPlayer
            setupPeriodicTimeObserver()
            setupPlayerObservers(for: newPlayer)
        } else {
            player?.automaticallyWaitsToMinimizeStalling = false
            player?.allowsExternalPlayback = true
            #if os(iOS)
            player?.usesExternalPlaybackWhileExternalScreenIsActive = true
            #endif
            player?.replaceCurrentItem(with: playerItem)
        }
        player?.volume = isSmoothSkipping ? 0.0 : volume
        player?.isMuted = isMuted
        
        // Load track-specific or default equalizer profile
        EqualizerManager.shared.trackWillPlay(track: track)

        // Setup Item Observers
        setupPlayerItemObservers(for: playerItem, track: track)
        
        let currentSpeed = Float(EqualizerManager.shared.playbackSpeed)
        player?.defaultRate = currentSpeed

        if smoothSkippingEnabled && !isSmoothSkipping && volume > 0 && !isMuted {
            isFadingInPlay = true
            player?.volume = 0.0
            player?.play()
            let masterVol = self.volume
            playPauseFadeTask?.cancel()
            playPauseFadeTask = Task { @MainActor in
                let steps = 45
                let stepDuration: UInt64 = 20_000_000 // 20ms per step -> 900ms total smooth fade-in duration
                for step in 1...steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: stepDuration)
                    if Task.isCancelled { break }
                    let progress = Float(step) / Float(steps)
                    // Slower, smoother ramp (smoothstep): starts gently from silence, ramps up smoothly, then seamlessly flattens to master volume
                    let factor = progress * progress * (3.0 - 2.0 * progress)
                    self.player?.volume = min(masterVol, max(0.0, masterVol * factor))
                }
                guard !Task.isCancelled else { return }
                self.player?.volume = masterVol
                self.isFadingInPlay = false
            }
        } else {
            player?.volume = isSmoothSkipping ? 0.0 : volume
            player?.play()
        }
        setupNowPlayingInfo(for: track)
        if resumePosition > 0 {
            updateNowPlayingElapsedTime()
        }
        
        // Pre-warm next upcoming track in the queue for instantaneous zero-latency skipping
        prewarmNextTrackIfNeeded()
        
        AppLogger.audio.info("Now playing: \(track.title) by \(track.artist) at \(resolvedURL.path) (rate: \(currentSpeed)x, resumed at: \(resumePosition)s)")
    }
    
    // Attach audio mix DSP tap (10-Band Equalizer & Volume Booster)
    private func attachAudioMix(to playerItem: AVPlayerItem) {
        let isEQ = EqualizerManager.shared.isEqualizerEnabled
        let boost = EqualizerManager.shared.volumeBoosterDB
        let needsDSP = isEQ || abs(boost) > 0.05

        // If DSP is not active, ensure audioMix is nil for pure native direct hardware playback
        if !needsDSP {
            if playerItem.audioMix != nil {
                playerItem.audioMix = nil
            }
            return
        }

        if playerItem.audioMix != nil { return }

        // Match audio processing tap to valid audio tracks
        let audioTracks = playerItem.asset.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            // Tracks not ready yet; will be attached when item transitions to readyToPlay
            return
        }

        var inputParams: [AVAudioMixInputParameters] = []
        for track in audioTracks {
            let params = AVMutableAudioMixInputParameters(track: track)
            if let tap = AudioDSPProcessor.shared.createAudioProcessingTap() {
                params.audioTapProcessor = tap
                inputParams.append(params)
            }
        }

        guard !inputParams.isEmpty else { return }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParams
        playerItem.audioMix = audioMix
        AppLogger.audio.info("Attached AudioDSPProcessor tap to player item (\(inputParams.count) audio track(s)).")
    }

    /// Dynamically ensures the audio mix DSP tap is attached on the currently playing item if needed.
    public func updateAudioMixForCurrentItem() {
        guard let item = player?.currentItem else { return }
        let isEQ = EqualizerManager.shared.isEqualizerEnabled
        let boost = EqualizerManager.shared.volumeBoosterDB
        let needsDSP = isEQ || abs(boost) > 0.05

        if needsDSP {
            if item.audioMix == nil {
                attachAudioMix(to: item)
            }
        } else {
            if item.audioMix != nil {
                item.audioMix = nil
                AppLogger.audio.info("Detached AudioDSPProcessor tap (DSP inactive).")
            }
        }
    }

    // Pre-warms the next track in queue asynchronously so skipping to it is instantaneous
    private func prewarmNextTrackIfNeeded() {
        guard let next = nextTrack else {
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmTask?.cancel()
            prewarmTask = nil
            return
        }
        if prewarmedTrackID == next.id && prewarmedPlayerItem != nil {
            return
        }
        
        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            let resolvedURL = SecurityScopedBookmark.shared.resolveAccessibleURL(for: next.url)
            let asset = AVURLAsset(url: resolvedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            
            // Also prewarm waveform amplitude peaks in background for zero-latency dial rendering
            _ = await AudioWaveformSpectrogramGenerator.shared.fetchSubSecondWaveformPeaks(
                for: next.url,
                duration: next.duration,
                samplesPerSecond: 2
            )
            
            await MainActor.run { [weak self] in
                guard let self = self, !Task.isCancelled else { return }
                self.attachAudioMix(to: item)
                self.prewarmedTrackID = next.id
                self.prewarmedPlayerItem = item
            }
        }
    }

    // Teardown item-specific observers
    private func teardownItemObservers() {
        if let endObs = playerItemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            playerItemEndObserver = nil
        }
        if let failedObs = playerItemFailedObserver {
            NotificationCenter.default.removeObserver(failedObs)
            playerItemFailedObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
    }

    // Teardown all player and item observers (used on deinit or stopAndClear)
    private func teardownPlayerObservers() {
        teardownItemObservers()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerTimeControlObserver?.invalidate()
        playerTimeControlObserver = nil
    }
    
    // Setup player-level observers (called once when AVPlayer instance is created)
    private func setupPlayerObservers(for player: AVPlayer) {
        playerTimeControlObserver?.invalidate()
        playerTimeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch p.timeControlStatus {
                case .playing:
                    self.isTransitioningTrack = false
                    self.transitionTimeoutTask?.cancel()
                    self.isRoutingChanging = false // Clear routing flag when confirmed playing
                    self.playbackStatus = .playing
                    self.updateNowPlayingPlaybackState()
                case .paused:
                    // If currently loading / replacing a track item, seeking, switching routes, or smoothly fading out, do not let the transient state trigger an unexpected pause
                    if self.isTransitioningTrack || self.isSeeking || self.isRoutingChanging || self.isFadingOutPause {
                        // Safety: if playback status is .playing but the player is actually paused,
                        // schedule a recovery attempt after a delay to prevent permanent stall
                        if self.playbackStatus == .playing {
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s safety timeout
                                guard let self = self else { return }
                                // Only recover if player is still actually paused (not buffering/waitingToPlay)
                                if self.playbackStatus == .playing,
                                   let player = self.player,
                                   player.timeControlStatus == .paused {
                                    self.isRoutingChanging = false
                                    self.isTransitioningTrack = false
                                    self.transitionTimeoutTask?.cancel()
                                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                                    player.defaultRate = speed
                                    player.play()
                                    AppLogger.audio.info("Safety recovery: forced playback after 2s paused stall")
                                }
                            }
                        }
                        return
                    }
                    if self.playbackStatus != .stopped {
                        self.playbackStatus = .paused
                        self.updateNowPlayingPlaybackState()
                    }
                case .waitingToPlayAtSpecifiedRate:
                    if let reason = p.reasonForWaitingToPlay {
                        AppLogger.audio.info("Player waiting to play: \(reason.rawValue)")
                    }
                    // Only display buffering if player was previously stopped
                    if self.playbackStatus == .stopped {
                        self.playbackStatus = .buffering
                    }
                @unknown default:
                    break
                }
            }
        }
    }
    
    // Setup player item observers
    private func setupPlayerItemObservers(for playerItem: AVPlayerItem, track: Track) {
        // 1. Observe playerItem.status
        itemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.attachAudioMix(to: item)
                    let dSec = CMTimeGetSeconds(item.duration)
                    if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                        self.duration = dSec
                        self.updateNowPlayingDuration(dSec)
                    }
                    if self.playbackStatus != .stopped {
                        self.playbackStatus = .playing
                    }
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    self.player?.defaultRate = speed
                    self.player?.play()
#if os(iOS)
                    self.endBackgroundTaskAssertion()
#endif
                    AppLogger.audio.info("AVPlayerItem ready to play: \(track.title) (duration: \(self.duration)s) at \(speed)x")
                case .failed:
                    self.isTransitioningTrack = false
                    self.transitionTimeoutTask?.cancel()
                    let itemErr = item.error?.localizedDescription ?? "None"
                    let playerErr = self.player?.error?.localizedDescription ?? "None"
                    let errorLogs = item.errorLog()?.events.compactMap { $0.errorComment }.joined(separator: "; ") ?? "None"
                    AppLogger.audio.error("AVPlayerItem failed for \(track.title). Item Error: \(itemErr). Player Error: \(playerErr). ErrorLog: \(errorLogs)")
                    self.playbackStatus = .stopped
#if os(iOS)
                    self.endBackgroundTaskAssertion()
#endif
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        
        // 2. Observe AVPlayerItem did play to end
        playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnded()
            }
        }
        
        // 3. Observe AVPlayerItem failed to play to end
        playerItemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                AppLogger.audio.warning("AVPlayerItem playback error: \(error?.localizedDescription ?? "unknown error")")
                guard let self = self else { return }

                // If playback failed while audio processing tap was attached, the connected output route
                // (e.g. car head unit) may have rejected dynamic CoreMedia tap format negotiation (-12885 / -12082).
                // Detach audioMix immediately and resume native playback so audio never stops.
                if playerItem.audioMix != nil {
                    AppLogger.audio.warning("Output route rejected audio processing tap. Detaching audioMix and recovering playback immediately.")
                    playerItem.audioMix = nil
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    self.player?.defaultRate = speed
                    self.player?.play()
                    return
                }

                if self.duration > 0 && self.currentTime >= self.duration - 2.0 {
                    self.handleTrackEnded()
                } else if self.playbackStatus == .playing, let player = self.player {
                    AppLogger.audio.info("Attempting auto-recovery from transient audio stall")
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    player.defaultRate = speed
                    player.play()
                } else if !self.queue.isEmpty {
                    AppLogger.audio.info("Advancing to next track after unrecoverable stall")
                    self.next()
                } else {
                    self.playbackStatus = .stopped
#if os(iOS)
                    self.endBackgroundTaskAssertion()
#endif
                }
            }
        }
    }
    
    // Setup periodic time observer
    private func setupPeriodicTimeObserver() {
        if timeObserverToken != nil { return }
        let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSeeking else { return }
                let seconds = CMTimeGetSeconds(time)
                if !seconds.isNaN && !seconds.isInfinite {
                    self.currentTime = seconds
                    if self.duration <= 0, let itemDur = self.player?.currentItem?.duration {
                        let dSec = CMTimeGetSeconds(itemDur)
                        if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                            self.duration = dSec
                        }
                    }
                    
                    // Count as a listen if track is played for more than 15 seconds (or finishes if shorter)
                    if self.playbackStatus == .playing && !self.hasCountedCurrentPlay {
                        self.playbackAccumulatedTime += 0.08
                        if self.playbackAccumulatedTime >= 15.0 || self.currentTime >= 15.0 || (self.duration > 0 && self.duration < 15.0 && self.currentTime >= self.duration * 0.9) {
                            self.hasCountedCurrentPlay = true
                            if let track = self.currentTrack {
                                self.onTrackPlay?(track.id)
                            }
                        }
                    }
                    
                    self.checkAndTriggerCrossfadeIfNeeded()
                }
            }
        }
    }
    
    // Handle track ended
    private func handleTrackEnded() {
#if os(iOS)
        beginBackgroundTaskAssertion()
#endif
        if !hasCountedCurrentPlay, let track = currentTrack {
            hasCountedCurrentPlay = true
            onTrackPlay?(track.id)
        }
        if let track = currentTrack {
            clearSavedPlaybackPosition(for: track.id)
        }
        if isCrossfading {
            // Handled by active crossfade completion
            return
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            let speed = Float(EqualizerManager.shared.playbackSpeed)
            player?.defaultRate = speed
            player?.play()
        case .all:
            next()
        case .off:
            if autoPlayNext {
                next()
            } else {
                pause()
                seek(to: 0)
                playbackStatus = .stopped
            }
        }
    }
    
    // MARK: - Crossfade Transition Engine
    
    // Check and trigger crossfade if needed
    private func checkAndTriggerCrossfadeIfNeeded() {
        // Ensure preconditions are met before proceeding
        guard isCrossfadeEnabled,
              crossfadeDuration >= 0.5,
              !isCrossfading,
              duration > (crossfadeDuration * 1.2),
              playbackStatus == .playing,
              autoPlayNext || repeatMode != .off else { return }
        
        // Remaining
        let remaining = duration - currentTime
        if remaining <= crossfadeDuration && remaining > 0 {
            // Ensure preconditions are met before proceeding
            guard let idx = currentIndex, !queue.isEmpty else { return }
            // Next idx
            let nextIdx: Int
            if idx + 1 < queue.count {
                nextIdx = idx + 1
            } else if repeatMode == .all {
                nextIdx = 0
            } else {
                return
            }
            // Next track
            let nextTrack = queue[nextIdx]
            startCrossfade(to: nextTrack, nextIndex: nextIdx)
        }
    }
    
    // Start crossfade
    private func startCrossfade(to nextTrack: Track, nextIndex: Int) {
        // Ensure preconditions are met before proceeding
        guard !isCrossfading else { return }
        saveCurrentPlaybackPositionIfNeeded()
        isCrossfading = true
        crossfadeTask?.cancel()
        
        // File system location for resolved next url
        let resolvedNextURL = SecurityScopedBookmark.shared.resolveAccessibleURL(for: nextTrack.url)
        _ = resolvedNextURL.startAccessingSecurityScopedResource()
        
        // Next asset
        let nextAsset = AVURLAsset(url: resolvedNextURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        // Next item
        let nextItem = AVPlayerItem(asset: nextAsset)
        nextItem.audioTimePitchAlgorithm = .spectral
        attachAudioMix(to: nextItem)
        
        // Incoming player
        let incomingPlayer = AVPlayer(playerItem: nextItem)
        incomingPlayer.automaticallyWaitsToMinimizeStalling = false
        incomingPlayer.allowsExternalPlayback = true
        #if os(iOS)
        incomingPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        incomingPlayer.volume = 0.0
        incomingPlayer.isMuted = false
        self.fadePlayer = incomingPlayer
        
        // Outgoing player
        let outgoingPlayer = self.player
        
        // Immediately update track metadata & UI to next track
        self.currentTrack = nextTrack
        self.currentIndex = nextIndex
        self.duration = nextTrack.duration
        self.currentTime = 0.0
        self.setupNowPlayingInfo(for: nextTrack)
        
        // Remove time observer from outgoing player
        if let token = self.timeObserverToken {
            outgoingPlayer?.removeTimeObserver(token)
            self.timeObserverToken = nil
        }
        
        // Attach real-time observer to incoming player so UI progress bar tracks next track smoothly from 0.0s
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        self.fadeTimeObserverToken = incomingPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSeeking else { return }
                let seconds = CMTimeGetSeconds(time)
                if !seconds.isNaN && !seconds.isInfinite {
                    self.currentTime = seconds
                }
            }
        }
        
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        incomingPlayer.defaultRate = speed
        incomingPlayer.play()
        AppLogger.audio.info("Starting crossfade (\(self.crossfadeDuration)s) to: \(nextTrack.title) at \(speed)x")
        
        // Total fade duration
        let totalFadeDuration = max(self.crossfadeDuration, 0.5)
        // Fade steps
        let fadeSteps = 40
        // Step duration
        let stepDuration = totalFadeDuration / Double(fadeSteps)
        
        crossfadeTask = Task { @MainActor in
            for step in 1...fadeSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
                if Task.isCancelled { break }
                
                // Progress
                let progress = Float(step) / Float(fadeSteps)
                // Angle
                let angle = progress * (Float.pi / 2.0)
                // Smooth equal-power curve (prevents volume dip in middle of crossfade) scaled by master volume
                outgoingPlayer?.volume = max(0.0, cos(angle)) * self.volume
                incomingPlayer.volume = min(1.0, sin(angle)) * self.volume
            }
            
            // Ensure preconditions are met before proceeding
            guard !Task.isCancelled else { return }
            
            // Finalize crossfade handoff
            outgoingPlayer?.pause()
            outgoingPlayer?.volume = 0.0
            
            if let token = self.fadeTimeObserverToken {
                incomingPlayer.removeTimeObserver(token)
                self.fadeTimeObserverToken = nil
            }
            
            self.teardownPlayerObservers()
            
            self.player = incomingPlayer
            self.player?.volume = self.volume
            self.player?.isMuted = self.isMuted
            self.fadePlayer = nil
            self.isCrossfading = false
            
            // Ensure exact playback position of incoming player is preserved with no jitter
            let currentSec = CMTimeGetSeconds(incomingPlayer.currentTime())
            if !currentSec.isNaN && !currentSec.isInfinite {
                self.currentTime = currentSec
            }
            self.updateNowPlayingElapsedTime()
            
            // Attach observers to active player
            self.setupPlayerItemObservers(for: nextItem, track: nextTrack)
            self.setupPeriodicTimeObserver()
            
            AppLogger.audio.info("Crossfade cleanly completed at exact track position: \(self.currentTime)s")
        }
    }
    
    /// Transitions in the next track first, then fades out the current playing track.
    /// Dual players play concurrently so the transition is fluid, uninterrupted, and pop-free.
    private func smoothSkip(then action: @escaping () -> Void) {
        smoothSkipTask?.cancel()
        smoothSkipTask = nil
        
        let now = ProcessInfo.processInfo.systemUptime
        let isRapidSpam = (now - lastSkipTimestamp) < 0.38
        lastSkipTimestamp = now
        
        // Immediately pause and clean up any prior outgoing player from a rapid previous skip
        if let prevOutgoing = skipOutgoingPlayer {
            prevOutgoing.pause()
            prevOutgoing.volume = 0
            skipOutgoingPlayer = nil
        }
        
        // If rapidly spamming skips, execute action immediately with master volume
        // to keep playback uninterrupted
        if isRapidSpam {
            self.isSmoothSkipping = false
            action()
            self.player?.volume = self.volume
            return
        }
        
        guard let outgoingPlayer = self.player, playbackStatus == .playing else {
            action()
            return
        }
        
        // Retain outgoing player so it continues playing through the transition
        self.skipOutgoingPlayer = outgoingPlayer
        let masterVolume = self.volume
        
        // Detach observers from outgoing player before switching
        if let token = timeObserverToken {
            outgoingPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        teardownItemObservers()
        
        // Temporarily nil self.player and mark isSmoothSkipping so loadAndPlay creates
        // a fresh AVPlayer with volume = 0, avoiding any initial audio pop/blast
        self.player = nil
        self.isSmoothSkipping = true
        
        // Load the next track (triggers loadAndPlay)
        action()
        
        self.isSmoothSkipping = false
        
        guard let incomingPlayer = self.player else {
            outgoingPlayer.pause()
            outgoingPlayer.volume = 0
            skipOutgoingPlayer = nil
            return
        }
        
        // 2-Phase Smooth Transition:
        // Phase 1: Incoming track fades in from 0 to masterVolume while current track plays at full volume
        // Phase 2: Once incoming track is fully faded in, current playing track fades out to 0 and pauses
        smoothSkipTask = Task { @MainActor in
            let steps = 16
            let stepDuration: UInt64 = 25_000_000 // 25ms per step -> 400ms per phase (800ms total smooth transition)
            
            // Phase 1: Next track transitions in from 0 to masterVolume while current track plays (starts slower, ramps up, flattens out)
            for step in 1...steps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: stepDuration)
                if Task.isCancelled { break }
                let progress = Float(step) / Float(steps)
                let factor = progress * progress * (3.0 - 2.0 * progress)
                incomingPlayer.volume = factor * masterVolume
                outgoingPlayer.volume = masterVolume
            }
            
            guard !Task.isCancelled else { return }
            incomingPlayer.volume = masterVolume
            
            // Phase 2: Current playing track fades out to 0 while next track plays at full volume (starts slower, ramps down, flattens out into silence)
            for step in 1...steps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: stepDuration)
                if Task.isCancelled { break }
                let progress = Float(step) / Float(steps)
                let factor = 1.0 - (progress * progress * (3.0 - 2.0 * progress))
                outgoingPlayer.volume = factor * masterVolume
                incomingPlayer.volume = masterVolume
            }
            
            guard !Task.isCancelled else { return }
            
            // Finalize: incoming is at full volume, outgoing is silenced and paused
            incomingPlayer.volume = masterVolume
            outgoingPlayer.pause()
            outgoingPlayer.volume = 0.0
            self.skipOutgoingPlayer = nil
        }
    }
    
    // Cancel crossfade
    private func cancelCrossfade() {
        seekTask?.cancel()
        seekTask = nil
        isSmoothSeeking = false
        
        if !isSmoothSkipping, let outgoing = skipOutgoingPlayer {
            outgoing.pause()
            outgoing.volume = 0
            skipOutgoingPlayer = nil
        }
        if isCrossfading {
            crossfadeTask?.cancel()
            crossfadeTask = nil
            if let token = fadeTimeObserverToken {
                fadePlayer?.removeTimeObserver(token)
                fadeTimeObserverToken = nil
            }
            if let nextPlayer = fadePlayer {
                player?.pause()
                player = nextPlayer
                player?.volume = 1.0
                player?.isMuted = false
                fadePlayer = nil
            }
            isCrossfading = false
        }
    }
    
    // Update current audio route description
    public func updateCurrentAudioRoute() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        guard !outputs.isEmpty else {
            currentAudioRouteName = "THIS DEVICE"
            return
        }
        
        let externalOutputs = outputs.filter {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
        
        if externalOutputs.isEmpty {
            currentAudioRouteName = "THIS DEVICE"
            return
        }
        
        let names = externalOutputs.compactMap { output -> String? in
            let trimmed = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.uppercased()
            }
            switch output.portType {
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return "BLUETOOTH"
            case .airPlay:
                return "AIRPLAY"
            case .headphones, .headsetMic:
                return "HEADPHONES"
            case .carAudio:
                return "CARPLAY"
            case .usbAudio:
                return "USB AUDIO"
            case .HDMI, .lineOut:
                return "EXTERNAL SPEAKER"
            default:
                return "EXTERNAL DEVICE"
            }
        }
        
        if !names.isEmpty {
            currentAudioRouteName = names.joined(separator: " + ")
        } else {
            currentAudioRouteName = "BLUETOOTH"
        }
#elseif os(macOS)
        var defaultDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        if status == noErr, defaultDeviceID != 0 {
            var unmanagedName: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let nameStatus = AudioObjectGetPropertyData(
                defaultDeviceID,
                &nameAddress,
                0,
                nil,
                &nameSize,
                &unmanagedName
            )
            if nameStatus == noErr, let cfName = unmanagedName?.takeRetainedValue() {
                let nameStr = (cfName as String).trimmingCharacters(in: .whitespacesAndNewlines)
                if !nameStr.isEmpty {
                    let lower = nameStr.lowercased()
                    if lower.contains("built-in") || lower.contains("internal speaker") || lower.contains("macbook") || lower.contains("imac") || lower.contains("mac mini") || lower.contains("mac studio") || lower.contains("mac pro") {
                        currentAudioRouteName = "THIS DEVICE"
                    } else {
                        currentAudioRouteName = nameStr.uppercased()
                    }
                    return
                }
            }
        }
        currentAudioRouteName = "THIS DEVICE"
#endif
    }
    
    // Setup audio session asynchronously with playback category, longFormAudio policy, and non-blocking activation
    private func setupAudioSession() {
#if os(iOS)
        Task { @MainActor [weak self] in
            await AudioSessionManager.shared.activateSessionIfNeeded()
            self?.updateCurrentAudioRoute()
        }
#endif
    }
    
    // Ensure audio session active asynchronously for playback without blocking the main thread
    public func ensureAudioSessionActive(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
#if os(iOS)
        Task { @MainActor in
            let succeeded = await AudioSessionManager.shared.activateSessionIfNeeded()
            completion?(succeeded)
        }
#else
        completion?(true)
#endif
    }

    /// Full refresh of audio session and route (used on app foreground, didBecomeActive, and view mount)
    public func refreshAudioSessionAndRoute() {
#if os(iOS)
        updateCurrentAudioRoute()
        scheduleDelayedRouteUpdates()
#elseif os(macOS)
        updateCurrentAudioRoute()
#endif
    }

    private var delayedRouteUpdateTask: Task<Void, Never>?

    /// Schedules follow-up route queries to allow asynchronous Bluetooth friendly name resolution.
    private func scheduleDelayedRouteUpdates() {
#if os(iOS)
        delayedRouteUpdateTask?.cancel()
        delayedRouteUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms
            guard !Task.isCancelled, let self = self else { return }
            self.updateCurrentAudioRoute()

            try? await Task.sleep(nanoseconds: 650_000_000) // 1.0s total
            guard !Task.isCancelled else { return }
            self.updateCurrentAudioRoute()
        }
#endif
    }
    
    // MARK: - Background Audio Notifications & Lifecycle
    
    // Setup audio notifications
    private func setupAudioNotifications() {
#if os(iOS)
        // 1. Interruption Notification (Phone Calls, Siri, Alarms)
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            Task { @MainActor in
                self?.updateCurrentAudioRoute()
                switch type {
                case .began:
                    AudioSessionManager.shared.notifyInterruptionBegan()
                    self?.pause()
                case .ended:
                    guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                        return
                    }
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    let shouldResume = options.contains(.shouldResume)
                    let reactivated = await AudioSessionManager.shared.notifyInterruptionEnded(shouldResume: shouldResume)
                    if reactivated && shouldResume {
                        // Delay resume slightly to let car stereo re-establish A2DP audio sink
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        self?.play()
                    }
                @unknown default:
                    break
                }
            }
        }
        
        // 2. Route Change Notification (Headphones / AirPods / Bluetooth Disconnection / Connection)
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.updateCurrentAudioRoute()
            self.scheduleDelayedRouteUpdates()

            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }

            switch reason {
            case .oldDeviceUnavailable:
                // Check if switching back from AirPlay to built-in speaker in the AirPlay picker
                if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                    let wasAirPlay = previousRoute.outputs.contains { $0.portType == .airPlay }
                    let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
                    let isNowBuiltIn = currentOutputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
                    if wasAirPlay && isNowBuiltIn {
                        // Switching back from AirPlay to this device: smoothly maintain playback without pausing
                        return
                    }
                }
                // Safely pause audio immediately when physical headphones/AirPods/Bluetooth disconnect
                self.pause(smooth: false)

            case .newDeviceAvailable, .routeConfigurationChange, .override, .categoryChange, .wakeFromSleep:
                // Hardware route changed or settled. AVPlayer natively handles audio routing to the new destination.
                // Do not force-reactivate the audio session or hammer player.play(), allowing Bluetooth A2DP
                // and vehicle head unit DAC clock handshakes to complete cleanly.
                break

            default:
                break
            }
        }
        
        // 3. Media Services Reset Notification (OS audio server restart)
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AudioSessionManager.shared.notifyMediaServicesWereReset()
                await AudioSessionManager.shared.activateSessionIfNeeded(force: true)
                self?.updateCurrentAudioRoute()
                if let current = self?.currentTrack {
                    self?.loadAndPlay(track: current)
                }
            }
        }
#endif
    }
    
#if os(iOS)
    // Setup app lifecycle observers for background and foreground playback reliability
    private func setupLifecycleObservers() {
        let bgObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.playbackStatus == .playing {
                    // Begin background assertion to prevent suspension during car stereo playback
                    self.beginBackgroundTaskAssertion()
                    self.updateNowPlayingPlaybackState()
                }
            }
        }
        appLifecycleObservers.append(bgObs)

        let activeObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAudioSessionAndRoute()
            }
        }
        appLifecycleObservers.append(activeObs)

        let fgObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAudioSessionAndRoute()
            }
        }
        appLifecycleObservers.append(fgObs)

        let resignObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Keep Now Playing info current so car stereo displays correct metadata
                if self.playbackStatus == .playing {
                    self.updateNowPlayingPlaybackState()
                }
            }
        }
        appLifecycleObservers.append(resignObs)
    }
    
    // Begin background execution assertion to prevent suspension during track transitions
    private func beginBackgroundTaskAssertion() {
        endBackgroundTaskAssertion()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AudioPlaybackTransition") { [weak self] in
            self?.endBackgroundTaskAssertion()
        }
    }
    
    // End background execution assertion safely
    private func endBackgroundTaskAssertion() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
#endif
    
    // MARK: - MediaPlayer Now Playing & Remote Commands
    
    // Setup remote command center
    private func setupRemoteCommandCenter() {
        // Command center
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Remove prior targets to prevent duplicate listener accumulation
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.seekForwardCommand.removeTarget(nil)
        commandCenter.seekBackwardCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.changeShuffleModeCommand.removeTarget(nil)
        commandCenter.changeRepeatModeCommand.removeTarget(nil)
        
        // Play Command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.play()
            }
            return .success
        }
        
        // Pause Command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }
        
        // Toggle Play/Pause Command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }
        
        // Next Track Command (Standard next button)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
            return .success
        }
        
        // Previous Track Command (Standard previous button)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.previous()
            }
            return .success
        }
        
        // Change Playback Position (Scrubber on Lock Screen & Control Center)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            // Ensure preconditions are met before proceeding
            guard let self = self,
                  // Position event
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self.seek(to: positionEvent.positionTime)
            }
            return .success
        }
        
        // Seek Forward / Backward Commands (Vehicle steering wheel hold-to-seek buttons)
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let self = self, let seekEvent = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                if seekEvent.type == .beginSeeking {
                    self.seek(to: min(self.duration, self.currentTime + 10))
                }
            }
            return .success
        }
        
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let self = self, let seekEvent = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                if seekEvent.type == .beginSeeking {
                    self.seek(to: max(0, self.currentTime - 10))
                }
            }
            return .success
        }
        
        // Explicitly disable 15s skip buttons so Lock Screen shows standard previous/next track buttons
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        
        // Stop Command (Car stereos send stop on engine shutoff or source switch)
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }
        
        // Shuffle & Repeat Commands
        commandCenter.changeShuffleModeCommand.isEnabled = true
        commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                if let shuffleEvent = event as? MPChangeShuffleModeCommandEvent {
                    switch shuffleEvent.shuffleType {
                    case .off:
                        if self.shuffleMode == .on { self.toggleShuffle() }
                    case .collections, .items:
                        if self.shuffleMode == .off { self.toggleShuffle() }
                    @unknown default:
                        self.toggleShuffle()
                    }
                } else {
                    self.toggleShuffle()
                }
            }
            return .success
        }
        
        commandCenter.changeRepeatModeCommand.isEnabled = true
        commandCenter.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                if let repeatEvent = event as? MPChangeRepeatModeCommandEvent {
                    switch repeatEvent.repeatType {
                    case .off:
                        self.repeatMode = .off
                    case .one:
                        self.repeatMode = .one
                    case .all:
                        self.repeatMode = .all
                    @unknown default:
                        self.cycleRepeatMode()
                    }
                } else {
                    self.cycleRepeatMode()
                }
            }
            return .success
        }
    }
    
    // Setup now playing info
    private func setupNowPlayingInfo(for track: Track) {
        let activeSpeed = EqualizerManager.shared.playbackSpeed
        let effectiveDuration = max(0.1, track.duration > 0 ? track.duration : (self.duration > 0 ? self.duration : 1.0))
        let cleanTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty 
            ? track.url.deletingPathExtension().lastPathComponent 
            : track.title
        let cleanArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty 
            ? "Unknown Artist" 
            : track.artist
        let cleanAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty 
            ? "Unknown Album" 
            : track.album

        // Info
        var info: [String: Any] = [
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPMediaItemPropertyTitle: cleanTitle,
            MPMediaItemPropertyArtist: cleanArtist,
            MPMediaItemPropertyAlbumTitle: cleanAlbum,
            MPMediaItemPropertyPlaybackDuration: effectiveDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, currentTime),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: playbackStatus == .playing ? activeSpeed : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: max(1, queue.count),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex ?? 0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        
        if let trackNum = track.trackNumber, trackNum > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNum
        }
        if let totalTracks = track.totalTracks, totalTracks > 0 {
            info[MPMediaItemPropertyAlbumTrackCount] = totalTracks
        }
        if let discNum = track.discNumber, discNum > 0 {
            info[MPMediaItemPropertyDiscNumber] = discNum
        }
        if let genre = track.genre, !genre.isEmpty {
            info[MPMediaItemPropertyGenre] = genre
        }
        
        #if os(iOS)
        MPNowPlayingInfoCenter.default().playbackState = (playbackStatus == .playing || playbackStatus == .buffering) ? .playing : (playbackStatus == .paused ? .paused : .stopped)
        #endif
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
        Task { [weak self] in
            guard let self = self else { return }
            var image: PlatformImage? = nil
            if let artKey = track.artworkKey, !artKey.isEmpty {
                if let artData = await ArtworkCacheService.shared.loadArtwork(key: artKey) {
                    image = self.platformImage(from: artData)
                }
            }
            if image == nil {
                #if os(iOS)
                image = UIImage(named: "art")
                #elseif os(macOS)
                image = NSImage(named: "art")
                #endif
            }
            guard let image = image else { return }

            #if os(iOS)
            guard image.size.width > 0 && image.size.height > 0 else { return }
            // Bound artwork dimensions to prevent blowing out Bluetooth AVRCP throughput
            let maxDimension: CGFloat = 600
            let originalSize = image.size
            let scale = min(maxDimension / originalSize.width, maxDimension / originalSize.height, 1.0)
            let boundedSize = CGSize(
                width: max(1, (originalSize.width * scale).rounded()),
                height: max(1, (originalSize.height * scale).rounded())
            )
            let mpArtwork = MPMediaItemArtwork(boundsSize: boundedSize) { requestedSize in
                guard requestedSize.width > 0 && requestedSize.height > 0,
                      !requestedSize.width.isNaN && !requestedSize.height.isNaN,
                      !requestedSize.width.isInfinite && !requestedSize.height.isInfinite else {
                    return image
                }
                let renderWidth = max(1, min(requestedSize.width, maxDimension))
                let renderHeight = max(1, min(requestedSize.height, maxDimension))
                let targetSize = CGSize(width: renderWidth, height: renderHeight)
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1.0
                let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
                return renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: targetSize))
                }
            }
            #elseif os(macOS)
            guard image.size.width > 0 && image.size.height > 0 else { return }
            let mpArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            #endif
            await MainActor.run {
                guard var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                currentInfo[MPMediaItemPropertyArtwork] = mpArtwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
            }
        }
    }
    
    /// Updates the playback duration dynamically in MPNowPlayingInfoCenter as soon as the AVPlayerItem resolves it
    private func updateNowPlayingDuration(_ duration: TimeInterval) {
        guard duration > 0, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Update now playing playback state
    private func updateNowPlayingPlaybackState() {
        #if os(iOS)
        switch playbackStatus {
        case .playing, .buffering:
            MPNowPlayingInfoCenter.default().playbackState = .playing
        case .paused:
            MPNowPlayingInfoCenter.default().playbackState = .paused
        case .stopped:
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        #endif
        
        // Ensure preconditions are met before proceeding
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let activeSpeed = EqualizerManager.shared.playbackSpeed
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackStatus == .playing ? activeSpeed : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = max(1, queue.count)
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex ?? 0
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Update now playing elapsed time
    private func updateNowPlayingElapsedTime() {
        // Ensure preconditions are met before proceeding
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let activeSpeed = EqualizerManager.shared.playbackSpeed
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackStatus == .playing ? activeSpeed : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Clear now playing info
    private func clearNowPlayingInfo() {
        #if os(iOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
#if os(iOS)
    // Platform image
    private func platformImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }
#else
    // Platform image
    private func platformImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }
#endif

    // MARK: - Diagnostics

    /// Gathers detailed internal engine state for troubleshooting and error inspection.
    public func playerDiagnostics() -> [String: String] {
        var dict: [String: String] = [:]
        dict["playbackStatus"] = "\(playbackStatus)"
        dict["currentTime"] = String(format: "%.2f", currentTime)
        dict["duration"] = String(format: "%.2f", duration)
        dict["queueCount"] = "\(queue.count)"
        dict["upNextCount"] = "\(playNextQueue.count)"
        dict["currentIndex"] = currentIndex.map(String.init) ?? "nil"
        dict["shuffleMode"] = "\(shuffleMode)"
        dict["repeatMode"] = "\(repeatMode)"
        dict["currentAudioRouteName"] = currentAudioRouteName
        dict["isExternalAudioRouteActive"] = "\(isExternalAudioRouteActive)"

        if let player = self.player {
            dict["player_rate"] = "\(player.rate)"
            dict["player_timeControlStatus"] = "\(player.timeControlStatus.rawValue)"
            if let reason = player.reasonForWaitingToPlay {
                dict["player_reasonForWaitingToPlay"] = reason.rawValue
            }
            if let err = player.error {
                dict["player_error"] = err.localizedDescription
            }
            if let item = player.currentItem {
                dict["item_status"] = "\(item.status.rawValue)"
                if let itemErr = item.error {
                    dict["item_error"] = itemErr.localizedDescription
                }
                dict["item_playbackLikelyToKeepUp"] = "\(item.isPlaybackLikelyToKeepUp)"
                dict["item_playbackBufferEmpty"] = "\(item.isPlaybackBufferEmpty)"
                dict["item_playbackBufferFull"] = "\(item.isPlaybackBufferFull)"

                if let errorLog = item.errorLog(), !errorLog.events.isEmpty {
                    dict["item_errorLogCount"] = "\(errorLog.events.count)"
                    if let evt = errorLog.events.last {
                        dict["item_lastErrorCode"] = "\(evt.errorStatusCode)"
                        dict["item_lastErrorDomain"] = evt.errorDomain ?? "Unknown"
                        dict["item_lastErrorComment"] = evt.errorComment ?? "None"
                    }
                }
            } else {
                dict["item_status"] = "no_current_item"
            }
        } else {
            dict["player"] = "nil"
        }
        return dict
    }
}

