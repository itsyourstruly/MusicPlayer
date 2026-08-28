import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import os

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
    public private(set) var queue: [Track] = []
    // Index of current track in active queue
    public private(set) var currentIndex: Int?
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
    // Priority queue for tracks explicitly marked to play next
    public var playNextQueue: [Track] = []
    // Callback invoked whenever a track begins playing
    public var onTrackPlay: ((UUID) -> Void)? = nil
    
    @ObservationIgnored private nonisolated(unsafe) var fadePlayer: AVPlayer?
    @ObservationIgnored private nonisolated(unsafe) var fadeTimeObserverToken: Any?
    @ObservationIgnored private nonisolated(unsafe) var isCrossfading: Bool = false
    @ObservationIgnored private nonisolated(unsafe) var crossfadeTask: Task<Void, Never>?
    
    @ObservationIgnored private nonisolated(unsafe) var smoothSkipTask: Task<Void, Never>?
    
    // MARK: - Internal Audio Engine Properties
    
    @ObservationIgnored private nonisolated(unsafe) var player: AVPlayer?
    @ObservationIgnored private nonisolated(unsafe) var timeObserverToken: Any?
    @ObservationIgnored private nonisolated(unsafe) var playerItemEndObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var playerItemFailedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var itemStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private nonisolated(unsafe) var playerTimeControlObserver: NSKeyValueObservation?
    @ObservationIgnored private nonisolated(unsafe) var audioInterruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var audioRouteChangeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var mediaServicesResetObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private nonisolated(unsafe) var activeTrackSecurityScopeURL: URL?
    @ObservationIgnored private var hasCountedCurrentPlay: Bool = false
    @ObservationIgnored private var playbackAccumulatedTime: TimeInterval = 0
    
    // Initialize with configured properties
    public init() {
        setupAudioSession()
        setupAudioNotifications()
        setupRemoteCommandCenter()
    }
    
    deinit {
        crossfadeTask?.cancel()
        smoothSkipTask?.cancel()
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
        cancelCrossfade()
        // Ensure preconditions are met before proceeding
        guard !queue.isEmpty, let idx = currentIndex else {
            play(track: track)
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
        player.volume = 1.0
        player.isMuted = false
        player.play()
        playbackStatus = .playing
        updateNowPlayingPlaybackState()
        AppLogger.audio.info("Playback resumed.")
    }
    
    /// Pauses playback.
    public func pause() {
        cancelCrossfade()
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
        // If track has been playing for more than 3 seconds, restart and play it
        if currentTime > 3.0 {
            seek(to: 0)
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
            player?.play()
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
        cancelCrossfade()
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
        self.currentIndex = index
        loadAndPlay(track: queue[index])
    }
    
    // MARK: - Internal Audio Engine Logic
    
    // Load and play
    private func loadAndPlay(track: Track) {
        cancelCrossfade()
        self.currentTrack = track
        self.duration = track.duration
        self.currentTime = 0
        self.playbackStatus = .buffering
        self.hasCountedCurrentPlay = false
        self.playbackAccumulatedTime = 0
        
        // 1. Ensure audio session is active
        ensureAudioSessionActive()
        
        // 2. Ensure root folder bookmark is actively accessed and resolve accessible file URL
        _ = SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        // File system location for resolved url
        let resolvedURL = SecurityScopedBookmark.shared.resolveAccessibleURL(for: track.url)
        
        // Retain security-scoped access for individual file if applicable
        if activeTrackSecurityScopeURL?.path != resolvedURL.path {
            activeTrackSecurityScopeURL?.stopAccessingSecurityScopedResource()
            activeTrackSecurityScopeURL = nil
            if resolvedURL.startAccessingSecurityScopedResource() {
                activeTrackSecurityScopeURL = resolvedURL
            }
        }
        
        // Teardown previous observers
        teardownPlayerObservers()
        
        // Trigger background download if track is an undownloaded iCloud ubiquitous item
        if let values = try? resolvedURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: resolvedURL)
        }
        
        // Configure player item for pure, lossless playback using AVURLAsset
        let asset = AVURLAsset(url: resolvedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        // Player item
        let playerItem = AVPlayerItem(asset: asset)
        
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        player?.volume = volume
        player?.isMuted = isMuted
        player?.automaticallyWaitsToMinimizeStalling = true
        
        // Setup Item & Player Observers
        setupPlayerItemObservers(for: playerItem, track: track)
        setupPeriodicTimeObserver()
        
        player?.play()
        setupNowPlayingInfo(for: track)
        AppLogger.audio.info("Now playing: \(track.title) by \(track.artist) at \(resolvedURL.path)")
    }
    
    // Teardown player observers
    private func teardownPlayerObservers() {
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
    }
    
    // Setup player item observers
    private func setupPlayerItemObservers(for playerItem: AVPlayerItem, track: Track) {
        // 1. Observe playerItem.status
        itemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                // Ensure preconditions are met before proceeding
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    // D sec
                    let dSec = CMTimeGetSeconds(item.duration)
                    if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                        self.duration = dSec
                    }
                    if self.playbackStatus == .buffering {
                        self.playbackStatus = .playing
                    }
                    self.player?.play()
                    AppLogger.audio.info("AVPlayerItem ready to play: \(track.title) (duration: \(self.duration)s)")
                case .failed:
                    // Item err
                    let itemErr = item.error?.localizedDescription ?? "None"
                    // Player err
                    let playerErr = self.player?.error?.localizedDescription ?? "None"
                    // Error logs
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
        
        // 2. Observe player.timeControlStatus
        if let player = self.player {
            playerTimeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                Task { @MainActor in
                    // Ensure preconditions are met before proceeding
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
                        self.playbackStatus = .buffering
                        if let reason = p.reasonForWaitingToPlay {
                            AppLogger.audio.info("Player waiting to play: \(reason.rawValue)")
                        }
                    @unknown default:
                        break
                    }
                }
            }
        }
        
        // 3. Observe AVPlayerItem did play to end
        playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnded()
            }
        }
        
        // 4. Observe AVPlayerItem failed to play to end
        playerItemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                // Error
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                AppLogger.audio.error("AVPlayerItem failed to play to end time: \(error?.localizedDescription ?? "unknown error")")
                self?.playbackStatus = .stopped
            }
        }
    }
    
    // Setup periodic time observer
    private func setupPeriodicTimeObserver() {
        // Interval
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Ensure preconditions are met before proceeding
            guard let self = self, !self.isSeeking else { return }
            // Seconds
            let seconds = CMTimeGetSeconds(time)
            if !seconds.isNaN && !seconds.isInfinite {
                self.currentTime = seconds
                if self.duration <= 0, let itemDur = self.player?.currentItem?.duration {
                    // D sec
                    let dSec = CMTimeGetSeconds(itemDur)
                    if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                        self.duration = dSec
                    }
                }
                
                // Count as a listen if track is played for more than 15 seconds (or finishes if shorter)
                if self.playbackStatus == .playing && !self.hasCountedCurrentPlay {
                    self.playbackAccumulatedTime += 0.25
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
    
    // Handle track ended
    private func handleTrackEnded() {
        if !hasCountedCurrentPlay, let track = currentTrack {
            hasCountedCurrentPlay = true
            onTrackPlay?(track.id)
        }
        if isCrossfading {
            // Handled by active crossfade completion
            return
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            player?.play()
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
        isCrossfading = true
        crossfadeTask?.cancel()
        
        // File system location for resolved next url
        let resolvedNextURL = SecurityScopedBookmark.shared.resolveAccessibleURL(for: nextTrack.url)
        _ = resolvedNextURL.startAccessingSecurityScopedResource()
        
        // Next asset
        let nextAsset = AVURLAsset(url: resolvedNextURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        // Next item
        let nextItem = AVPlayerItem(asset: nextAsset)
        
        // Incoming player
        let incomingPlayer = AVPlayer(playerItem: nextItem)
        incomingPlayer.automaticallyWaitsToMinimizeStalling = true
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
            // Ensure preconditions are met before proceeding
            guard let self = self, !self.isSeeking else { return }
            // Seconds
            let seconds = CMTimeGetSeconds(time)
            if !seconds.isNaN && !seconds.isInfinite {
                self.currentTime = seconds
            }
        }
        
        incomingPlayer.play()
        AppLogger.audio.info("Starting crossfade (\(self.crossfadeDuration)s) to: \(nextTrack.title)")
        
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
            // Steps
            let steps = 20
            // Step duration
            let stepDuration: UInt64 = 25_000_000 // 25ms per step → 500ms total
            
            for step in 1...steps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: stepDuration)
                if Task.isCancelled { break }
                
                // Progress
                let progress = Float(step) / Float(steps)
                // Angle
                let angle = progress * (Float.pi / 2.0)
                // Equal-power curve: incoming rises as outgoing falls
                incomingPlayer?.volume = sin(angle) * masterVolume
                outgoingPlayer?.volume = cos(angle) * masterVolume
            }
            
            // Ensure preconditions are met before proceeding
            guard !Task.isCancelled else { return }
            
            // Finalize — restore incoming to full volume and silence/stop outgoing
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
        guard let output = session.currentRoute.outputs.first else {
            currentAudioRouteName = "THIS DEVICE"
            return
        }
        
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver:
            currentAudioRouteName = "THIS DEVICE"
        case .headphones, .headsetMic:
            let name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            currentAudioRouteName = name.isEmpty ? "HEADPHONES" : name.uppercased()
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .carAudio, .usbAudio :
            let name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            currentAudioRouteName = name.isEmpty ? "THIS DEVICE" : name.uppercased()
        default:
            let name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && output.portType != .lineOut {
                currentAudioRouteName = name.uppercased()
            } else {
                currentAudioRouteName = "THIS DEVICE"
            }
        }
#elseif os(macOS)
        currentAudioRouteName = "THIS DEVICE"
#endif
    }
    
    // Setup audio session
    private func setupAudioSession() {
#if os(iOS)
        do {
            // Session
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            updateCurrentAudioRoute()
            AppLogger.audio.info("AVAudioSession active: 2-channel audio.")
        } catch {
            AppLogger.audio.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
#endif
    }
    
    // Ensure audio session active
    private func ensureAudioSessionActive() {
#if os(iOS)
        // Session
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
            updateCurrentAudioRoute()
        } catch {
            AppLogger.audio.warning("Could not activate AVAudioSession: \(error.localizedDescription)")
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
        // Info
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackStatus == .playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // Update now playing elapsed time
    private func updateNowPlayingElapsedTime() {
        // Ensure preconditions are met before proceeding
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackStatus == .playing ? 1.0 : 0.0
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
