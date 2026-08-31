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
    // MARK: - Observable State
    
    // Currently playing or paused track
    public private(set) var currentTrack: Track?
    // Current playback state (playing, paused, stopped)
    public private(set) var playbackStatus: PlaybackStatus = .stopped
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
    
    // MARK: - Desktop Volume & Mute State
    
    // Master output volume (0.0 to 1.0)
    public var volume: Float = 1.0 {
        didSet {
            let clamped = min(max(volume, 0.0), 1.0)
            if volume != clamped {
                volume = clamped
            }
            if !isCrossfading {
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
    
    // Pre-warming state for instant zero-latency track transitions
    @ObservationIgnored private var prewarmedTrackID: UUID?
    @ObservationIgnored private var prewarmedPlayerItem: AVPlayerItem?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    
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
    
    // Initialize with configured properties
    public init() {
        setupAudioSession()
        setupAudioNotifications()
        setupRemoteCommandCenter()
        EqualizerManager.shared.playerService = self
    }
    
    deinit {
        crossfadeTask?.cancel()
        smoothSkipTask?.cancel()
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
        if playbackStatus == .playing {
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
                player.playImmediately(atRate: clamped)
                player.rate = clamped
            }
        }
        updateNowPlayingPlaybackState()
        AppLogger.audio.info("Applied live playback speed: \(clamped)x (status: \(self.playbackStatus.rawValue))")
    }

    /// Resumes playback.
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
        
        ensureAudioSessionActive()
        player.volume = volume
        player.isMuted = isMuted
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        player.playImmediately(atRate: speed)
        playbackStatus = .playing
        updateNowPlayingPlaybackState()
        AppLogger.audio.info("Playback resumed at \(speed)x.")
    }
    
    /// Pauses playback.
    public func pause() {
        cancelCrossfade()
        saveCurrentPlaybackPositionIfNeeded()
        player?.pause()
        playbackStatus = .paused
        updateNowPlayingPlaybackState()
        AppLogger.audio.info("Playback paused.")
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
            player?.playImmediately(atRate: speed)
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
            player?.playImmediately(atRate: speed)
            playbackStatus = .playing
        }
    }
    
    /// Seeks to a specific timestamp in seconds.
    public func seek(to timeInSeconds: TimeInterval) {
        cancelCrossfade()
        // Ensure preconditions are met before proceeding
        guard let player = player else { return }
        // Clamped time
        let clampedTime = max(0, min(timeInSeconds, duration))
        self.currentTime = clampedTime
        
        // Target cm time
        let targetCMTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        // Tolerance
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: targetCMTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            // Ensure preconditions are met before proceeding
            guard let self = self else { return }
            Task { @MainActor in
                self.updateNowPlayingElapsedTime()
            }
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
        if let current = currentTrack, current.id != track.id {
            saveCurrentPlaybackPositionIfNeeded()
        }
        cancelCrossfade()
        self.currentTrack = track
        self.duration = track.duration
        
        let resumePosition = savedPlaybackPosition(for: track) ?? 0.0
        self.currentTime = resumePosition
        // Immediately set playback status to playing for instantaneous UI responsiveness
        self.playbackStatus = .playing
        self.hasCountedCurrentPlay = false
        self.playbackAccumulatedTime = 0
        
        // 1. Ensure audio session is active
        ensureAudioSessionActive()
        
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
        
        // Use pre-warmed item if available for instant zero-latency start, otherwise instantiate with low-latency timeDomain algorithm
        let playerItem: AVPlayerItem
        if prewarmedTrackID == track.id, let prewarmed = prewarmedPlayerItem {
            playerItem = prewarmed
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
        } else {
            let asset = AVURLAsset(url: resolvedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            playerItem = AVPlayerItem(asset: asset)
            playerItem.audioTimePitchAlgorithm = .timeDomain
            attachAudioMixIfNeeded(to: playerItem)
        }
        
        if resumePosition > 0 {
            let initialCMTime = CMTime(seconds: resumePosition, preferredTimescale: 600)
            playerItem.seek(to: initialCMTime, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        
        if player == nil {
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            newPlayer.allowsExternalPlayback = false
            #if os(iOS)
            newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
            #endif
            self.player = newPlayer
            setupPeriodicTimeObserver()
            setupPlayerObservers(for: newPlayer)
        } else {
            player?.automaticallyWaitsToMinimizeStalling = false
            player?.allowsExternalPlayback = false
            #if os(iOS)
            player?.usesExternalPlaybackWhileExternalScreenIsActive = false
            #endif
            player?.replaceCurrentItem(with: playerItem)
        }
        player?.volume = volume
        player?.isMuted = isMuted
        
        // Load track-specific or default equalizer profile
        EqualizerManager.shared.trackWillPlay(track: track)

        // Setup Item Observers
        setupPlayerItemObservers(for: playerItem, track: track)
        
        let currentSpeed = Float(EqualizerManager.shared.playbackSpeed)
        player?.playImmediately(atRate: currentSpeed)
        setupNowPlayingInfo(for: track)
        if resumePosition > 0 {
            updateNowPlayingElapsedTime()
        }
        
        // Pre-warm next upcoming track in the queue for instantaneous zero-latency skipping
        prewarmNextTrackIfNeeded()
        
        AppLogger.audio.info("Now playing: \(track.title) by \(track.artist) at \(resolvedURL.path) (rate: \(currentSpeed)x, resumed at: \(resumePosition)s)")
    }
    
    // Attach audio mix DSP tap (10-Band Equalizer & Volume Booster) only when actively in use
    private func attachAudioMixIfNeeded(to playerItem: AVPlayerItem) {
        let isEQActive = EqualizerManager.shared.isEqualizerEnabled || abs(EqualizerManager.shared.volumeBoosterDB) > 0.05
        guard isEQActive else {
            playerItem.audioMix = nil
            return
        }
        guard let tap = AudioDSPProcessor.shared.createAudioProcessingTap() else { return }
        let inputParams = AVMutableAudioMixInputParameters()
        inputParams.audioTapProcessor = tap
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        playerItem.audioMix = audioMix
        AppLogger.audio.info("Attached AudioDSPProcessor tap.")
    }
    
    /// Dynamically updates or attaches the audio mix on the currently playing item
    public func updateAudioMixForCurrentItem() {
        guard let item = player?.currentItem else { return }
        attachAudioMixIfNeeded(to: item)
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
            item.audioTimePitchAlgorithm = .timeDomain
            
            await MainActor.run { [weak self] in
                guard let self = self, !Task.isCancelled else { return }
                self.attachAudioMixIfNeeded(to: item)
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
                    self.playbackStatus = .playing
                    self.updateNowPlayingPlaybackState()
                case .paused:
                    if self.playbackStatus != .stopped {
                        self.playbackStatus = .paused
                        self.updateNowPlayingPlaybackState()
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Only display buffering if player was previously stopped
                    if self.playbackStatus == .stopped {
                        self.playbackStatus = .buffering
                    }
                    if let reason = p.reasonForWaitingToPlay {
                        AppLogger.audio.info("Player waiting to play: \(reason.rawValue)")
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
                    let dSec = CMTimeGetSeconds(item.duration)
                    if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                        self.duration = dSec
                    }
                    if self.playbackStatus == .buffering {
                        self.playbackStatus = .playing
                    }
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    self.player?.playImmediately(atRate: speed)
                    AppLogger.audio.info("AVPlayerItem ready to play: \(track.title) (duration: \(self.duration)s) at \(speed)x")
                case .failed:
                    let itemErr = item.error?.localizedDescription ?? "None"
                    let playerErr = self.player?.error?.localizedDescription ?? "None"
                    let errorLogs = item.errorLog()?.events.compactMap { $0.errorComment }.joined(separator: "; ") ?? "None"
                    AppLogger.audio.error("AVPlayerItem failed for \(track.title). Item Error: \(itemErr). Player Error: \(playerErr). ErrorLog: \(errorLogs)")
                    self.playbackStatus = .stopped
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
                AppLogger.audio.error("AVPlayerItem failed to play to end time: \(error?.localizedDescription ?? "unknown error")")
                self?.playbackStatus = .stopped
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
            player?.playImmediately(atRate: speed)
        case .all, .off:
            next()
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
              playbackStatus == .playing else { return }
        
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
        nextItem.audioTimePitchAlgorithm = .timeDomain
        attachAudioMixIfNeeded(to: nextItem)
        
        // Incoming player
        let incomingPlayer = AVPlayer(playerItem: nextItem)
        incomingPlayer.allowsExternalPlayback = false
        #if os(iOS)
        incomingPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
        incomingPlayer.automaticallyWaitsToMinimizeStalling = false
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
        incomingPlayer.playImmediately(atRate: speed)
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
    
    /// Simultaneously fades in the next track while fading out the current one on skip.
    /// Used by next() and previous() when smoothSkippingEnabled is true.
    private func smoothSkip(then action: @escaping () -> Void) {
        smoothSkipTask?.cancel()
        
        // Capture the outgoing player and master volume before swapping tracks
        let outgoingPlayer = self.player
        // Master volume
        let masterVolume = self.volume
        
        // ⚠️ Detach the outgoing player's periodic time observer BEFORE nilling self.player.
        // If we nil first, teardownPlayerObservers() inside loadAndPlay can't reach the old player,
        // leaving a live observer that races with the new player's observer to write self.currentTime.
        if let token = timeObserverToken {
            outgoingPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        // Also invalidate KVO and notification observers tied to the outgoing player item
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        playerTimeControlObserver?.invalidate()
        playerTimeControlObserver = nil
        if let endObs = playerItemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            playerItemEndObserver = nil
        }
        if let failedObs = playerItemFailedObserver {
            NotificationCenter.default.removeObserver(failedObs)
            playerItemFailedObserver = nil
        }
        
        // Temporarily nil self.player so loadAndPlay creates a brand-new AVPlayer for the
        // incoming track, allowing both players to run simultaneously during the crossfade
        self.player = nil
        
        // Load the next track — a fresh AVPlayer is created since self.player is nil
        action()
        
        // Capture the new player as a local constant so the fade loop holds a stable reference
        // even if self.player is reassigned again (e.g. user taps next a second time)
        let incomingPlayer = self.player
        
        // Immediately silence the incoming player so the fade-in starts from zero
        incomingPlayer?.volume = 0
        
        smoothSkipTask = Task { @MainActor in
            let fadeInSteps = 10
            let fadeOutSteps = 10
            let stepDuration: UInt64 = 20_000_000 // 20ms per step → 200ms fade-in, 200ms fade-out
            
            // Phase 1: Fade in the next track while current track plays
            for step in 1...fadeInSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: stepDuration)
                if Task.isCancelled { break }
                
                let progress = Float(step) / Float(fadeInSteps)
                let angle = progress * (Float.pi / 2.0)
                incomingPlayer?.volume = sin(angle) * masterVolume
                outgoingPlayer?.volume = masterVolume
            }
            
            guard !Task.isCancelled else { return }
            incomingPlayer?.volume = masterVolume
            
            // Phase 2: Fade out the current track while next track plays at full volume
            for step in 1...fadeOutSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: stepDuration)
                if Task.isCancelled { break }
                
                let progress = Float(step) / Float(fadeOutSteps)
                let angle = progress * (Float.pi / 2.0)
                outgoingPlayer?.volume = cos(angle) * masterVolume
                incomingPlayer?.volume = masterVolume
            }
            
            // Ensure preconditions are met before proceeding
            guard !Task.isCancelled else { return }
            
            // Finalize — incoming is at full volume, outgoing is silenced and paused
            incomingPlayer?.volume = masterVolume
            outgoingPlayer?.pause()
            outgoingPlayer?.volume = 0
        }
    }
    
    // Cancel crossfade
    private func cancelCrossfade() {
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
                return nil
            }
        }
        
        if !names.isEmpty {
            currentAudioRouteName = names.joined(separator: " + ")
        } else {
            currentAudioRouteName = "THIS DEVICE"
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
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
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
                &name
            )
            if nameStatus == noErr {
                let nameStr = (name as String).trimmingCharacters(in: .whitespacesAndNewlines)
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
    
    // Setup audio session asynchronously off the main thread
    private func setupAudioSession() {
#if os(iOS)
        Task.detached(priority: .userInitiated) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                try session.setActive(true)
                await MainActor.run { [weak self] in
                    self?.updateCurrentAudioRoute()
                }
                AppLogger.audio.info("AVAudioSession active: longFormAudio category configured asynchronously.")
            } catch {
                AppLogger.audio.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
            }
        }
#endif
    }
    
    // Ensure audio session active asynchronously off the main thread
    private func ensureAudioSessionActive() {
#if os(iOS)
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                if session.category != .playback || session.routeSharingPolicy != .longFormAudio {
                    try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                }
                try session.setActive(true)
                await MainActor.run { [weak self] in
                    self?.updateCurrentAudioRoute()
                }
            } catch {
                AppLogger.audio.warning("Could not activate AVAudioSession: \(error.localizedDescription)")
            }
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
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Ensure preconditions are met before proceeding
            guard let userInfo = notification.userInfo,
                  // Type value
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  // Type
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            Task { @MainActor in
                self?.updateCurrentAudioRoute()
                switch type {
                case .began:
                    self?.pause()
                case .ended:
                    // Ensure preconditions are met before proceeding
                    guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                    // Options
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
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
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateCurrentAudioRoute()
            }
            // Ensure preconditions are met before proceeding
            guard let userInfo = notification.userInfo,
                  // Reason value
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  // Reason
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }
            Task { @MainActor in
                switch reason {
                case .oldDeviceUnavailable:
                    // Safely pause audio when headphones/AirPods disconnect
                    self?.pause()
                case .newDeviceAvailable, .routeConfigurationChange, .override, .categoryChange:
                    // Keep audio session active and maintain playback smoothly across external route transitions
                    self?.ensureAudioSessionActive()
                    self?.updateCurrentAudioRoute()
                    if self?.playbackStatus == .playing, let player = self?.player {
                        let speed = Float(EqualizerManager.shared.playbackSpeed)
                        player.playImmediately(atRate: speed)
                    }
                default:
                    break
                }
            }
        }
        
        // 3. Media Services Reset Notification (OS audio server restart)
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupAudioSession()
                self?.updateCurrentAudioRoute()
                if let current = self?.currentTrack {
                    self?.loadAndPlay(track: current)
                }
            }
        }
#endif
    }
    
    // MARK: - MediaPlayer Now Playing & Remote Commands
    
    // Setup remote command center
    private func setupRemoteCommandCenter() {
        // Command center
        let commandCenter = MPRemoteCommandCenter.shared()
        
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
        
        // Explicitly disable 15s skip buttons so Lock Screen shows standard previous/next track buttons
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        
        // Shuffle & Repeat Commands
        commandCenter.changeShuffleModeCommand.isEnabled = true
        commandCenter.changeShuffleModeCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.toggleShuffle()
            }
            return .success
        }
        
        commandCenter.changeRepeatModeCommand.isEnabled = true
        commandCenter.changeRepeatModeCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.cycleRepeatMode()
            }
            return .success
        }
    }
    
    // Setup now playing info
    private func setupNowPlayingInfo(for track: Track) {
        let activeSpeed = EqualizerManager.shared.playbackSpeed
        // Info
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: activeSpeed
        ]
        
        if let artKey = track.artworkKey {
            Task {
                if let artData = await ArtworkCacheService.shared.loadArtwork(key: artKey),
                   // Image
                   let image = platformImage(from: artData) {
                    // Mp artwork
                    let mpArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    info[MPMediaItemPropertyArtwork] = mpArtwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Update now playing playback state
    private func updateNowPlayingPlaybackState() {
        // Ensure preconditions are met before proceeding
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let activeSpeed = EqualizerManager.shared.playbackSpeed
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackStatus == .playing ? activeSpeed : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Update now playing elapsed time
    private func updateNowPlayingElapsedTime() {
        // Ensure preconditions are met before proceeding
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let activeSpeed = EqualizerManager.shared.playbackSpeed
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackStatus == .playing ? activeSpeed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Clear now playing info
    private func clearNowPlayingInfo() {
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
}
