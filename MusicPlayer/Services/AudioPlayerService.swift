import Foundation
import AVFoundation
import MediaPlayer
import ImageIO
import Observation
import SwiftUI
import os
#if os(macOS)
import CoreAudio
#endif

/// Lightweight, stable identifier and track reference for an item in the playback queue.
public struct QueueEntry: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let trackID: UUID

    public init(id: UUID = UUID(), trackID: UUID) {
        self.id = id
        self.trackID = trackID
    }
}

/// Lightweight observable model publishing queue badge states so list rows do not observe the entire player service.
@Observable
@MainActor
public final class QueueBadgesModel {
    public var playNextTrackIDs: Set<UUID> = []
    public var nextTrackID: UUID? = nil

    public init() {}

    public func update(playNextEntries: [QueueEntry], nextTrackID: UUID?) {
        self.playNextTrackIDs = Set(playNextEntries.map { $0.trackID })
        self.nextTrackID = nextTrackID
    }
}

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
    // Dedicated progress model observed by scrubber and progress bar
    public let progress = AudioProgressModel()
    // Elapsed playback time in seconds
    public private(set) var currentTime: TimeInterval = 0 {
        didSet {
            progress.currentTime = currentTime
        }
    }
    // Total audio duration in seconds
    public private(set) var duration: TimeInterval = 0 {
        didSet {
            progress.duration = duration
        }
    }
    public private(set) var queueBadges = QueueBadgesModel()

    @ObservationIgnored private var localTrackLookupMap: [UUID: Track] = [:]
    public var onResolveTrack: ((UUID) -> Track?)? = nil

    /// Registers one or more tracks into the local fast lookup table
    public func registerTracks(_ tracks: [Track]) {
        for t in tracks {
            localTrackLookupMap[t.id] = t
        }
    }

    /// Resolves a track by its UUID from local cache, current playing track, or external store
    public func track(for trackID: UUID) -> Track? {
        if let local = localTrackLookupMap[trackID] {
            return local
        }
        if let current = currentTrack, current.id == trackID {
            return current
        }
        if let resolved = onResolveTrack?(trackID) {
            return resolved
        }
        return nil
    }

    /// Resolves a track from a queue entry
    public func track(for entry: QueueEntry) -> Track? {
        track(for: entry.trackID)
    }

    /// Updates the queue badges model with latest playNext set and next track ID
    public func updateQueueBadges() {
        let nextID = nextPlaybackTarget()?.track.id
        queueBadges.update(playNextEntries: playNextQueue, nextTrackID: nextID)
    }

    // Upcoming track queue
    public private(set) var queue: [QueueEntry] = [] {
        didSet {
            updateQueueBadges()
            prewarmNextTrackIfNeeded()
        }
    }
    // Index of current track in active queue
    public private(set) var currentIndex: Int? {
        didSet {
            updateQueueBadges()
        }
    }
    // Active repeat configuration (off, all, one)
    public var repeatMode: RepeatMode = .off
    // Active shuffle configuration
    public var shuffleMode: ShuffleMode = .off
    
    // True while the user is dragging the scrub bar
    public var isSeeking: Bool = false {
        didSet {
            progress.isSeeking = isSeeking
        }
    }
    // Target seek timestamp during scrubber interaction
    public var seekPosition: TimeInterval = 0 {
        didSet {
            progress.seekPosition = seekPosition
        }
    }
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
    // Pre-fetches upcoming queue tracks over Wi-Fi when nearing end of current track
    public var downloadNextSongOnWiFi: Bool = true
    // Callbacks for persisting and querying playback position
    public var onSavePlaybackPosition: ((UUID, TimeInterval) -> Void)? = nil
    public var onGetPlaybackPosition: ((UUID) -> TimeInterval?)? = nil
    public var onClearPlaybackPosition: ((UUID) -> Void)? = nil
    
    @ObservationIgnored private var localPlaybackPositions: [UUID: TimeInterval] = [:]
    
    // Priority queue for tracks explicitly marked to play next
    public var playNextQueue: [QueueEntry] = [] {
        didSet {
            updateQueueBadges()
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

    // Cloud streaming, prefetch & Jellyfin reporting state
    public private(set) var cloudWaitTrackID: UUID?
    public var cloudPlaybackError: String?
    public var serverSources: [ServerSourceLink] = []
    public var autoDownloadOnPlay: Bool = false
    public var downloadOnCellular: Bool = true

    /// Provider for a server track's source, or nil for local tracks / unsupported server kinds.
    private func serverProvider(for track: Track) -> (any MediaServerProvider)? {
        guard let link = serverSource(for: track.folderID) ?? serverSources.first else { return nil }
        return ServerProviderRegistry.provider(for: link)
    }

    /// Provider for play reports and scrobbles. Nil while Offline is on: plays are dropped, never queued.
    private func playReportingProvider(for track: Track) -> (any MediaServerProvider)? {
        guard !OfflineMode.isEnabled else { return nil }
        return serverProvider(for: track)
    }

    /// Called when Offline turns on. A streamed current track stops at once and its network item is released,
    /// so AVPlayer stops buffering from the server; a prewarmed stream is dropped too. Pressing play again then
    /// shows OFFLINE. Downloaded, local and already-cached tracks keep playing untouched.
    func offlineModeDidEnable() {
        if let prewarmed = prewarmedPlayerItem, let asset = prewarmed.asset as? AVURLAsset, !asset.url.isFileURL {
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmingTrackID = nil
        }
        guard let player, let asset = player.currentItem?.asset as? AVURLAsset, !asset.url.isFileURL else { return }
        cancelCrossfade()
        pause(smooth: false)
        player.replaceCurrentItem(with: nil)
    }

    /// Signed server audio request via the single ServerStreamRequestBuilder (throws instead of falling back
    /// to the unsigned identity URL).
    func signedServerRequest(for track: Track, purpose: ServerMediaPurpose, caller: String) throws -> URLRequest {
        try ServerStreamRequestBuilder.request(for: track, link: serverSource(for: track.folderID) ?? serverSources.first,
                                               purpose: purpose, caller: caller)
    }

    /// Provider used for a server track's lyrics (nil for local tracks).
    public func lyricsProvider(for track: Track) -> (any MediaServerProvider)? {
        serverProvider(for: track)
    }

    /// AAC transcode request followed by the provider's fallback (MP3 320) if it has one.
    private func transcodeRequests(for track: Track) -> [URLRequest] {
        guard let provider = serverProvider(for: track) else { return [] }
        return [try? signedServerRequest(for: track, purpose: .stream, caller: "transcodePrefetch"),
                provider.transcodeFallbackRequest(for: track)].compactMap { $0 }
    }

    /// True when a server track needs a server-side transcode that has not been fully fetched to disk yet.
    private func needsTranscodePrefetch(_ track: Track) -> Bool {
        (track.isJellyfinItem || track.metadataSource == .server)
            && TranscodePolicy.requiresTranscode(track)
            && JellyfinDownloadManager.shared.localFileURL(for: track.id) == nil
            && ServerTranscodeCache.cachedFileURL(for: track) == nil
    }

    private func serverSource(for folderID: UUID?) -> ServerSourceLink? {
        guard let folderID = folderID else { return nil }
        if let match = serverSources.first(where: { $0.id == folderID }) {
            return match
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let settingsURL = appSupport.appendingPathComponent("settings.json")
            if let data = try? Data(contentsOf: settingsURL),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                self.serverSources = settings.serverSources
                return settings.serverSources.first(where: { $0.id == folderID })
            }
        }
        return nil
    }
    @ObservationIgnored private var cloudDownloadTask: Task<Void, Never>?
    /// Next track whose signed request failed during crossfade (avoids retrying every time tick).
    @ObservationIgnored private var crossfadeFailedTrackID: UUID?
    @ObservationIgnored private var hasTriggeredWiFiPrefetch: Bool = false
    @ObservationIgnored private var lastJellyfinReportedSeconds: TimeInterval = 0
    @ObservationIgnored private var isSmoothSkipping: Bool = false
    @ObservationIgnored private var pendingSmoothSkipAction: (() -> Void)?
    
    @ObservationIgnored private var skipOutgoingPlayer: AVPlayer?
    @ObservationIgnored private var skipIncomingPlayer: AVPlayer?
    @ObservationIgnored private var skipTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var isStaggeredTransitioning: Bool = false
    
    @ObservationIgnored private var playPauseFadeTask: Task<Void, Never>?
    @ObservationIgnored private var isFadingOutPause: Bool = false
    @ObservationIgnored private var isFadingInPlay: Bool = false
    
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var isSmoothSeeking: Bool = false
    
    // Pre-warming state for instant zero-latency track transitions
    @ObservationIgnored private var prewarmedTrackID: UUID?
    @ObservationIgnored private var prewarmedPlayerItem: AVPlayerItem?
    @ObservationIgnored private var prewarmingTrackID: UUID?
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
    @ObservationIgnored private var playerItemErrorLogObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var playerItemAccessLogObserver: (any NSObjectProtocol)?
    public private(set) var lastPlaybackError: String?
    @ObservationIgnored private var itemStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private var playerTimeControlObserver: NSKeyValueObservation?
    @ObservationIgnored private var audioInterruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var audioRouteChangeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var mediaServicesResetObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var originalQueue: [QueueEntry] = []
    @ObservationIgnored private var activeTrackSecurityScopeURL: URL?
    @ObservationIgnored private var hasCountedCurrentPlay: Bool = false
    @ObservationIgnored private var playbackAccumulatedTime: TimeInterval = 0
    @ObservationIgnored private var isTransitioningTrack: Bool = false
    @ObservationIgnored private var transitionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var isRoutingChanging: Bool = false
    @ObservationIgnored private var boundaryObserverTokens: [Any] = []
    @ObservationIgnored private var itemLikelyToKeepUpObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemBufferEmptyObserver: NSKeyValueObservation?
    @ObservationIgnored private var playerItemStalledObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wasPlayingBeforeInterruption: Bool = false
    @ObservationIgnored private var userPausedManually: Bool = false
#if os(iOS)
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
        skipTransitionTask?.cancel()
        skipOutgoingPlayer?.pause()
        skipOutgoingPlayer = nil
        skipIncomingPlayer?.pause()
        skipIncomingPlayer = nil
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
        if let errLogObs = playerItemErrorLogObserver {
            NotificationCenter.default.removeObserver(errLogObs)
            playerItemErrorLogObserver = nil
        }
        if let accLogObs = playerItemAccessLogObserver {
            NotificationCenter.default.removeObserver(accLogObs)
            playerItemAccessLogObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        itemLikelyToKeepUpObserver?.invalidate()
        itemLikelyToKeepUpObserver = nil
        itemBufferEmptyObserver?.invalidate()
        itemBufferEmptyObserver = nil
        if let stalledObs = playerItemStalledObserver {
            NotificationCenter.default.removeObserver(stalledObs)
            playerItemStalledObserver = nil
        }
        for token in boundaryObserverTokens {
            player?.removeTimeObserver(token)
        }
        boundaryObserverTokens.removeAll()
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
        nextPlaybackTarget()?.track
    }

    /// Returns the next playback target tuple, prioritizing Up Next (playNextQueue), then repeat and queue order.
    public func nextPlaybackTarget() -> (track: Track, isFromPlayNext: Bool, nextIndex: Int?)? {
        if let firstPlayNext = playNextQueue.first, let t = track(for: firstPlayNext) {
            return (track: t, isFromPlayNext: true, nextIndex: currentIndex)
        }
        guard let index = currentIndex, !queue.isEmpty else { return nil }
        if index + 1 < queue.count, let t = track(for: queue[index + 1]) {
            return (track: t, isFromPlayNext: false, nextIndex: index + 1)
        } else if repeatMode == .all, let first = queue.first, let t = track(for: first) {
            return (track: t, isFromPlayNext: false, nextIndex: 0)
        }
        return nil
    }
    
    // MARK: - Playback Control APIs
    
    /// Plays a track within the active queue: inserts immediately after the current song and starts playback.
    public func playInCurrentQueue(track: Track) {
        registerTracks([track])
        let entry = QueueEntry(trackID: track.id)
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            guard !queue.isEmpty, let idx = currentIndex else {
                performPlay(track: track, inQueue: [track], startIndex: 0)
                return
            }
            let insertIndex = idx + 1
            startStaggeredSkipTransition(to: track, nextIndex: insertIndex) { [weak self] in
                guard let self = self else { return }
                if insertIndex <= self.queue.count {
                    self.queue.insert(entry, at: insertIndex)
                } else {
                    self.queue.append(entry)
                }
                self.currentIndex = insertIndex
            }
            return
        }
        performPlayInCurrentQueue(track: track)
    }

    private func performPlayInCurrentQueue(track: Track) {
        cancelCrossfade()
        cancelStaggeredTransition()
        registerTracks([track])
        let entry = QueueEntry(trackID: track.id)
        guard !queue.isEmpty, let idx = currentIndex else {
            performPlay(track: track, inQueue: [track], startIndex: 0)
            return
        }
        let insertIndex = idx + 1
        if insertIndex <= queue.count {
            queue.insert(entry, at: insertIndex)
        } else {
            queue.append(entry)
        }
        self.currentIndex = insertIndex
        loadAndPlay(track: track)
    }
    
    /// Begins playback of a specific track within a provided playlist or queue context.
    public func play(track: Track, inQueue newQueue: [Track] = [], startIndex: Int? = nil) {
        PlaybackTiming.tap(track.id)
        registerTracks([track])
        if !newQueue.isEmpty {
            registerTracks(newQueue)
        }
        if playTrackInCurrentQueue && !queue.isEmpty && currentIndex != nil {
            playInCurrentQueue(track: track)
            return
        }
        let queueEntries = newQueue.map { QueueEntry(trackID: $0.id) }
        let targetIdx = startIndex ?? newQueue.firstIndex(where: { $0.id == track.id })
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            startStaggeredSkipTransition(to: track, nextIndex: targetIdx) { [weak self] in
                guard let self = self else { return }
                if !queueEntries.isEmpty {
                    self.originalQueue = queueEntries
                    self.queue = queueEntries
                    self.currentIndex = targetIdx
                }
            }
            return
        }
        performPlay(track: track, inQueue: newQueue, startIndex: startIndex)
    }

    private func performPlay(track: Track, inQueue newQueue: [Track], startIndex: Int?) {
        cancelCrossfade()
        registerTracks([track])
        if !newQueue.isEmpty {
            registerTracks(newQueue)
        }
        let entries = newQueue.isEmpty ? [QueueEntry(trackID: track.id)] : newQueue.map { QueueEntry(trackID: $0.id) }
        self.originalQueue = entries
        
        if shuffleMode == .on {
            var shuffled = entries
            if let idx = shuffled.firstIndex(where: { $0.trackID == track.id }) {
                let first = shuffled.remove(at: idx)
                shuffled.insert(first, at: 0)
            }
            self.queue = shuffled
            self.currentIndex = 0
        } else {
            self.queue = entries
            self.currentIndex = startIndex ?? entries.firstIndex(where: { $0.trackID == track.id }) ?? 0
        }
        
        loadAndPlay(track: track)
    }

    /// Sets the queue directly from existing QueueEntry items without copying Track models
    public func setQueue(_ entries: [QueueEntry], currentIndex: Int?) {
        self.queue = entries
        self.originalQueue = entries
        self.currentIndex = currentIndex
    }

    /// Plays a track identified by its QueueEntry UUID
    public func playQueueEntry(id entryID: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == entryID }) else { return }
        playTrackInQueue(at: index)
    }
    
    /// Remaps track IDs across active playback queues during migration.
    public func remapTrackIDs(using map: [UUID: UUID]) {
        for i in 0..<queue.count {
            if let newID = map[queue[i].trackID] {
                queue[i] = QueueEntry(id: queue[i].id, trackID: newID)
            }
        }
        for i in 0..<playNextQueue.count {
            if let newID = map[playNextQueue[i].trackID] {
                playNextQueue[i] = QueueEntry(id: playNextQueue[i].id, trackID: newID)
            }
        }
        if let cur = currentTrack, let newID = map[cur.id] {
            currentTrack = cur.withIdentity(id: newID, relativePath: cur.relativePath, metadataSource: cur.metadataSource, tagSnapshot: cur.tagSnapshot)
        }
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
            if let currentItem = player.currentItem, let currentURL = currentTrack?.url {
                if let algo = appropriateTimePitchAlgorithm(for: currentURL) {
                    currentItem.audioTimePitchAlgorithm = algo
                }
                AppLogger.audio.info("Applied live playback speed: \(clamped)x, item audioTimePitchAlgorithm: \(currentItem.audioTimePitchAlgorithm.rawValue), EqualizerManager.playbackSpeed: \(EqualizerManager.shared.playbackSpeed)")
            }
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
            if let track = currentTrack ?? (queue.first.flatMap { track(for: $0) }) {
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
        
        userPausedManually = false
        AudioSessionManager.shared.markPlaying()
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        player.defaultRate = speed
        player.isMuted = isMuted
        let isRemote = (currentTrack?.isJellyfinItem == true || currentTrack?.metadataSource == .server) && JellyfinDownloadManager.shared.localFileURL(for: currentTrack?.id ?? UUID()) == nil
        player.automaticallyWaitsToMinimizeStalling = isRemote

        let wasFadingOut = isFadingOutPause
        playPauseFadeTask?.cancel()
        playPauseFadeTask = nil
        isFadingOutPause = false

        let masterVol = volume
        if smoothSkippingEnabled && masterVol > 0 && !isMuted {
            isFadingInPlay = true
            // If reversing an in-flight pause fade, resume from current attenuated volume; otherwise start from a subtle audible level (20%) so sound is heard immediately
            let startVol = wasFadingOut ? min(player.volume, masterVol) : (masterVol * 0.20)
            player.volume = startVol
            player.play()
            playbackStatus = .playing
            updateNowPlayingPlaybackState()

            playPauseFadeTask = Task { @MainActor in
                let steps = 8
                let stepDuration: UInt64 = 15_000_000 // 15ms per step -> 120ms total snappy micro-fade

                for step in 1...steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: stepDuration)
                    if Task.isCancelled { break }

                    let progress = Float(step) / Float(steps)
                    let currentVol = startVol + (masterVol - startVol) * progress
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
        cancelStaggeredTransition()
        smoothSkipTask?.cancel()
        smoothSkipTask = nil
        isSmoothSkipping = false
        pendingSmoothSkipAction = nil

        userPausedManually = true
        AudioSessionManager.shared.markPaused()

        guard let player = player else {
            playbackStatus = .paused
            updateNowPlayingPlaybackState()
            return
        }

        playbackStatus = .paused
        updateNowPlayingPlaybackState()
        saveCurrentPlaybackPositionIfNeeded()

        let startVol = player.volume
        if smooth && smoothSkippingEnabled && startVol > 0 && !isMuted {
            isFadingOutPause = true
            playPauseFadeTask = Task { @MainActor in
                let steps = 6
                let stepDuration: UInt64 = 15_000_000 // 15ms per step -> 90ms total snappy fade duration

                for step in 1...steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: stepDuration)
                    if Task.isCancelled { break }

                    let progress = Float(step) / Float(steps)
                    let factor = (1.0 - progress) * (1.0 - progress)
                    player.volume = min(self.volume, max(0.0, startVol * factor))
                }

                guard !Task.isCancelled else { return }
                player.pause()
                player.volume = 0.0
                self.isFadingOutPause = false
                AppLogger.audio.info("Playback smoothly paused.")
            }
        } else {
            isFadingOutPause = false
            player.pause()
            player.volume = volume
            AppLogger.audio.info("Playback paused immediately.")
        }
    }
    
    /// Advances to the next track in the queue, prioritizing Play Next before regular upcoming items.
    public func next() {
        if smoothSkippingEnabled && playbackStatus == .playing {
            if let (nextSong, nextIdx, commit) = getNextTrackInfo() {
                startStaggeredSkipTransition(to: nextSong, nextIndex: nextIdx, commitQueueAction: commit)
                return
            }
        }
        performNext()
    }
    
    private func getNextTrackInfo() -> (track: Track, index: Int?, commit: () -> Void)? {
        // 1. Dedicated Play Next queue
        if !playNextQueue.isEmpty {
            let nextEntry = playNextQueue[0]
            guard let nextSong = track(for: nextEntry) else { return nil }
            return (nextSong, currentIndex, { [weak self] in
                guard let self = self, !self.playNextQueue.isEmpty else { return }
                self.playNextQueue.removeFirst()
            })
        }
        
        // 2. Standard queue
        guard !queue.isEmpty, let idx = currentIndex else { return nil }
        let nextIdx = idx + 1
        if nextIdx < queue.count, let nextSong = track(for: queue[nextIdx]) {
            return (nextSong, nextIdx, { [weak self] in
                self?.currentIndex = nextIdx
            })
        } else if repeatMode == .all, let first = queue.first, let firstSong = track(for: first) {
            return (firstSong, 0, { [weak self] in
                self?.currentIndex = 0
            })
        }
        return nil
    }

    // Perform next
    private func performNext() {
        cancelCrossfade()
        cancelStaggeredTransition()
        
        // 1. Play from dedicated Play Next queue if available
        if !playNextQueue.isEmpty {
            let nextEntry = playNextQueue.removeFirst()
            if let nextSong = track(for: nextEntry) {
                loadAndPlay(track: nextSong)
            }
            return
        }
        
        // 2. Otherwise advance in standard queue
        guard !queue.isEmpty, let idx = currentIndex else { return }
        
        let nextIdx = idx + 1
        if nextIdx < queue.count {
            currentIndex = nextIdx
            if let nextSong = track(for: queue[nextIdx]) {
                loadAndPlay(track: nextSong)
            }
        } else if repeatMode == .all {
            currentIndex = 0
            if let first = queue.first, let firstSong = track(for: first) {
                loadAndPlay(track: firstSong)
            }
        } else {
            pause(smooth: false)
            seek(to: 0)
            playbackStatus = .stopped
            AppLogger.audio.info("Reached end of queue.")
        }
    }
    
    /// Moves to the previous track or restarts the current track.
    public func previous() {
        cancelCrossfade()
        cancelStaggeredTransition()
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        // If track has been playing for more than 3 seconds, restart and play it
        if currentTime > 3.0 {
            seek(to: 0)
            player?.defaultRate = speed
            player?.play()
            playbackStatus = .playing
            return
        }
        
        if smoothSkippingEnabled && playbackStatus == .playing {
            if let (prevSong, prevIdx, commit) = getPreviousTrackInfo() {
                startStaggeredSkipTransition(to: prevSong, nextIndex: prevIdx, commitQueueAction: commit)
                return
            }
        }
        performPrevious()
    }
    
    private func getPreviousTrackInfo() -> (track: Track, index: Int?, commit: () -> Void)? {
        guard !queue.isEmpty, let idx = currentIndex else { return nil }
        let prevIdx = idx - 1
        if prevIdx >= 0, let prevSong = track(for: queue[prevIdx]) {
            return (prevSong, prevIdx, { [weak self] in
                self?.currentIndex = prevIdx
            })
        } else if repeatMode == .all, let last = queue.last, let lastSong = track(for: last) {
            let lastIdx = queue.count - 1
            return (lastSong, lastIdx, { [weak self] in
                self?.currentIndex = lastIdx
            })
        }
        return nil
    }

    // Perform previous
    private func performPrevious() {
        cancelCrossfade()
        cancelStaggeredTransition()
        guard !queue.isEmpty, let idx = currentIndex else { return }
        
        let prevIdx = idx - 1
        if prevIdx >= 0 {
            currentIndex = prevIdx
            if let prevSong = track(for: queue[prevIdx]) {
                loadAndPlay(track: prevSong)
            }
        } else if repeatMode == .all {
            let lastIdx = queue.count - 1
            currentIndex = lastIdx
            if let last = queue.last, let lastSong = track(for: last) {
                loadAndPlay(track: lastSong)
            }
        } else {
            seek(to: 0)
            let speed = Float(EqualizerManager.shared.playbackSpeed)
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
        let timescale = player.currentItem?.duration.timescale ?? 600
        let targetCMTime = CMTime(seconds: clampedTime, preferredTimescale: timescale)
        
        // If not actively playing (e.g. paused or stopped), seek directly without volume micro-fading
        guard playbackStatus == .playing && player.rate > 0 else {
            seekTask?.cancel()
            seekTask = nil
            isSmoothSeeking = false
            
            player.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        completion?()
                        return
                    }
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
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        completion?()
                        return
                    }
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
                Task { @MainActor [weak self] in
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
            var remaining = queue.filter { $0.trackID != current.id }
            remaining.shuffle()
            let currentEntry = queue.first(where: { $0.trackID == current.id }) ?? QueueEntry(trackID: current.id)
            self.queue = [currentEntry] + remaining
            self.currentIndex = 0
        } else {
            self.queue = originalQueue
            self.currentIndex = originalQueue.firstIndex(where: { $0.trackID == current.id }) ?? 0
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
            self.currentIndex = queue.firstIndex(where: { $0.trackID == current.id })
        }
    }
    
    /// Removes an item from the queue.
    public func removeQueueItem(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard queue.indices.contains(index) else { return }
        // Removed track entry
        let removedEntry = queue.remove(at: index)
        
        if let current = currentTrack {
            if removedEntry.trackID == current.id {
                // If removing current track, play next
                if index < queue.count, let song = track(for: queue[index]) {
                    self.currentIndex = index
                    loadAndPlay(track: song)
                } else if !queue.isEmpty, let song = track(for: queue[0]) {
                    self.currentIndex = 0
                    loadAndPlay(track: song)
                } else {
                    stopAndClear()
                }
            } else {
                self.currentIndex = queue.firstIndex(where: { $0.trackID == current.id })
            }
        }
    }
    
    /// Adds a track to the dedicated Play Next queue (played before upcoming playlist tracks).
    /// By default, adding multiple tracks to play next will add them to the end of the play next queue.
    public func playNext(track: Track) {
        registerTracks([track])
        if currentTrack == nil && queue.isEmpty {
            play(track: track)
            return
        }
        playNextQueue.append(QueueEntry(trackID: track.id))
        AppLogger.audio.info("Added track to Play Next queue: \(track.title)")
    }
    
    /// Inserts a track to the very front of the Play Next queue (to play immediately next).
    public func insertPlayNextFront(track: Track) {
        registerTracks([track])
        if currentTrack == nil && queue.isEmpty {
            play(track: track)
            return
        }
        playNextQueue.insert(QueueEntry(trackID: track.id), at: 0)
        AppLogger.audio.info("Inserted track at front of Play Next queue: \(track.title)")
    }
    
    /// Adds multiple tracks to the dedicated Play Next queue.
    public func playNext(tracks: [Track]) {
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }
        registerTracks(tracks)
        if currentTrack == nil && queue.isEmpty {
            if let first = tracks.first {
                play(track: first, inQueue: tracks)
            }
            return
        }
        let entries = tracks.map { QueueEntry(trackID: $0.id) }
        playNextQueue.append(contentsOf: entries)
        AppLogger.audio.info("Added \(tracks.count) tracks to Play Next queue.")
    }
    
    /// Inserts multiple tracks to the very front of the Play Next queue.
    public func insertPlayNextFront(tracks: [Track]) {
        // Ensure preconditions are met before proceeding
        guard !tracks.isEmpty else { return }
        registerTracks(tracks)
        if currentTrack == nil && queue.isEmpty {
            if let first = tracks.first {
                play(track: first, inQueue: tracks)
            }
            return
        }
        let entries = tracks.map { QueueEntry(trackID: $0.id) }
        playNextQueue.insert(contentsOf: entries, at: 0)
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
        let entry = playNextQueue.remove(at: playNextIndex)
        let clampedIndex = max(0, min(queueDestinationIndex, queue.count))
        queue.insert(entry, at: clampedIndex)
        if let current = currentTrack {
            self.currentIndex = queue.firstIndex(where: { $0.trackID == current.id })
        }
    }

    /// Moves a track from the main queue to the Play Next queue at a destination index.
    public func moveFromQueueToPlayNext(queueIndex: Int, playNextDestinationIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        let entry = queue.remove(at: queueIndex)
        let clampedIndex = max(0, min(playNextDestinationIndex, playNextQueue.count))
        playNextQueue.insert(entry, at: clampedIndex)
        if let current = currentTrack {
            self.currentIndex = queue.firstIndex(where: { $0.trackID == current.id })
        }
    }
    
    /// Clears all tracks from the Play Next queue.
    public func clearPlayNextQueue() {
        playNextQueue.removeAll()
    }
    
    /// Immediately plays a track selected directly from the Play Next queue.
    public func playFromPlayNext(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard playNextQueue.indices.contains(index), let track = track(for: playNextQueue[index]) else { return }
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            startStaggeredSkipTransition(to: track, nextIndex: currentIndex) { [weak self] in
                guard let self = self, self.playNextQueue.indices.contains(index) else { return }
                self.playNextQueue.remove(at: index)
            }
            return
        }
        playNextQueue.remove(at: index)
        loadAndPlay(track: track)
    }
    
    /// Appends a track to the end of the current queue.
    public func appendToQueue(track: Track) {
        registerTracks([track])
        if queue.isEmpty {
            play(track: track)
        } else {
            queue.append(QueueEntry(trackID: track.id))
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
        registerTracks(tracks)
        if queue.isEmpty {
            if let first = tracks.first {
                play(track: first, inQueue: tracks)
            }
            return
        }
        let entries = tracks.map { QueueEntry(trackID: $0.id) }
        queue.append(contentsOf: entries)
    }
    
    /// Convenience alias for appendToQueue(tracks:).
    public func enqueue(tracks: [Track]) {
        appendToQueue(tracks: tracks)
    }
    
    /// Clears the queue and stops playback.
    public func stopAndClear() {
        saveCurrentPlaybackPositionIfNeeded()
        cancelCrossfade()
        cancelStaggeredTransition()
        smoothSkipTask?.cancel()
        smoothSkipTask = nil
        isSmoothSkipping = false
        pendingSmoothSkipAction = nil
        playPauseFadeTask?.cancel()
        playPauseFadeTask = nil
        isFadingOutPause = false
        isFadingInPlay = false
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmedTrackID = nil
        prewarmedPlayerItem = nil
        prewarmingTrackID = nil
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

    /// Prunes tracks with the given IDs from playback, upcoming queue, play next, and cache.
    public func pruneTracks(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let current = currentTrack, ids.contains(current.id) {
            stopAndClear()
            return
        }
        for id in ids {
            localTrackLookupMap.removeValue(forKey: id)
        }
        playNextQueue.removeAll { ids.contains($0.trackID) }
        queue.removeAll { ids.contains($0.trackID) }
        originalQueue.removeAll { ids.contains($0.trackID) }
        if let curr = currentTrack, let idx = queue.firstIndex(where: { $0.trackID == curr.id }) {
            currentIndex = idx
        } else if queue.isEmpty {
            currentIndex = nil
        }
        if let pw = prewarmedTrackID, ids.contains(pw) {
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmingTrackID = nil
        }
        updateQueueBadges()
        prewarmNextTrackIfNeeded()
    }
    
    /// Clears upcoming tracks from the queue while keeping current track playing.
    public func clearQueue() {
        if let current = currentTrack {
            let entry = queue.first(where: { $0.trackID == current.id }) ?? QueueEntry(trackID: current.id)
            queue = [entry]
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
        localTrackLookupMap[updatedTrack.id] = updatedTrack
        if currentTrack?.id == updatedTrack.id {
            self.currentTrack = updatedTrack
            self.setupNowPlayingInfo(for: updatedTrack)
        }
    }
    
    /// Plays a specific track in the existing queue by its queue index.
    public func playTrackInQueue(at index: Int) {
        // Ensure preconditions are met before proceeding
        guard queue.indices.contains(index), let track = track(for: queue[index]) else { return }
        if smoothSkippingEnabled && playbackStatus == .playing && currentTrack?.id != track.id {
            startStaggeredSkipTransition(to: track, nextIndex: index) { [weak self] in
                self?.currentIndex = index
            }
            return
        }
        self.currentIndex = index
        loadAndPlay(track: track)
    }
    
    // MARK: - Internal Audio Engine Logic
    
    /// Prepares and configures a uniform AVPlayerItem for any track, applying the appropriate audio time-pitch algorithm and EQ audio mix tap.
    /// Throws ServerStreamError for server tracks whose signed request cannot be built (never plays track.url).
    public func makePlayerItem(for track: Track, caller: String = "play") throws -> AVPlayerItem {
        let resolvedURL: URL
        var assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]

        if let downloadedURL = JellyfinDownloadManager.shared.localFileURL(for: track.id),
           FileManager.default.fileExists(atPath: downloadedURL.path) {
            resolvedURL = downloadedURL
            AppLogger.audio.debug("Resolved Jellyfin downloaded local file: \(downloadedURL.path)")
        } else if track.url.isFileURL {
            resolvedURL = SecurityScopedBookmark.shared.ensureAccess(for: track.url, folderID: track.folderID)
            let exists = FileManager.default.fileExists(atPath: resolvedURL.path)
            if !exists {
                AppLogger.audio.warning("Local track file does not exist at resolved path: \(resolvedURL.path) (original track url: \(track.url.path))")
            } else {
                AppLogger.audio.debug("Resolved local audio file (\(exists ? "EXISTS" : "MISSING")): \(resolvedURL.path)")
            }
        } else if let transcodedURL = ServerTranscodeCache.cachedFileURL(for: track) {
            resolvedURL = transcodedURL
            AppLogger.audio.debug("Resolved pre-fetched server transcode: \(transcodedURL.lastPathComponent)")
        } else if track.isJellyfinItem || track.metadataSource == .server {
            let request = try signedServerRequest(for: track, purpose: .stream, caller: caller)
            guard let url = request.url else { throw ServerStreamError.noProvider }
            resolvedURL = url
            if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            AppLogger.audio.debug("Resolved server stream (transcode: \(TranscodePolicy.requiresTranscode(track))) for track \(track.id.uuidString)")
        } else {
            resolvedURL = track.url
            AppLogger.audio.debug("Resolved standard track URL: \(resolvedURL.absoluteString)")
        }

        let isPCMFile = ["wav", "wave", "aif", "aiff", "caf"].contains(resolvedURL.pathExtension.lowercased())
        let item = isPCMFile ? AVPlayerItem(url: resolvedURL) : AVPlayerItem(asset: AVURLAsset(url: resolvedURL, options: assetOptions))
        if let algorithm = appropriateTimePitchAlgorithm(for: resolvedURL) {
            item.audioTimePitchAlgorithm = algorithm
        }
        AppLogger.audio.info("Item audioTimePitchAlgorithm: \(item.audioTimePitchAlgorithm.rawValue), EqualizerManager.playbackSpeed: \(EqualizerManager.shared.playbackSpeed)")
        let isRemoteJellyfin = (track.isJellyfinItem || track.metadataSource == .server) && JellyfinDownloadManager.shared.localFileURL(for: track.id) == nil
        if isRemoteJellyfin {
            item.preferredForwardBufferDuration = 0.0 // 0 = let AVFoundation choose (fixed 30 s buffer rejected)
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        } else {
            item.preferredForwardBufferDuration = 0.0
        }
        attachAudioMix(to: item)
        return item
    }

    // Load and play
    private func loadAndPlay(track: Track) {
        PlaybackTiming.tap(track.id)
        if let current = currentTrack, current.id != track.id {
            saveCurrentPlaybackPositionIfNeeded()
        }
        cancelCrossfade()
        cloudDownloadTask?.cancel()
        cloudDownloadTask = nil
        self.isTransitioningTrack = true
        transitionTimeoutTask?.cancel()
        transitionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.isTransitioningTrack = false
        }
        self.isSeeking = false
        self.currentTrack = track
        self.duration = track.duration
        self.hasTriggeredWiFiPrefetch = false
        if self.cloudPlaybackError != "CAN'T PLAY FILE" {
            self.cloudPlaybackError = nil
        }
        self.lastPlaybackError = nil

        let resumePosition = savedPlaybackPosition(for: track) ?? 0.0
        self.currentTime = resumePosition
        self.hasCountedCurrentPlay = false
        self.playbackAccumulatedTime = 0

        let ext = (track.fileInfo?.fileExtension ?? track.url.pathExtension).uppercased()
        let isLocal = track.url.isFileURL && FileManager.default.fileExists(atPath: track.url.path)
        let isJellyfin = track.isJellyfinItem || track.metadataSource == .server
        AppLogger.audio.info("Initiating playback: \"\(track.title)\" by \"\(track.artist)\" [ID: \(track.id.uuidString)] [Type: .\(ext)] [Local: \(isLocal ? "YES" : "NO")] [Server: \(isJellyfin ? "YES" : "NO")] [Resume: \(resumePosition > 0 ? "\(String(format: "%.2f", resumePosition))s" : "start")]")

        // If track is a file URL but not downloaded yet, pause/buffer and wait for download
        if track.url.isFileURL && (!CloudFileAvailability.isLocal(url: track.url) || CloudFileAvailability.isCloudItem(url: track.url)) {
            let isCurrentOnDisk: Bool = {
                if let res = try? track.url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                   res.isUbiquitousItem == true {
                    return res.ubiquitousItemDownloadingStatus == .current
                }
                return CloudFileAvailability.isLocal(url: track.url)
            }()

            if !isCurrentOnDisk {
                self.playbackStatus = .buffering
                self.cloudWaitTrackID = track.id
                cloudDownloadTask = Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    do {
                        let localURL = try await CloudDownloadCenter.shared.ensureLocal(track: track)
                        guard self.cloudWaitTrackID == track.id, self.currentTrack?.id == track.id else {
                            return
                        }
                        if let res = try? localURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                           res.ubiquitousItemDownloadingStatus != .current {
                            throw CloudDownloadError.downloadFailed("FILE STILL MATERIALIZING")
                        }
                        self.cloudWaitTrackID = nil
                        self.finishLoadAndPlay(track: track, resumePosition: resumePosition)
                    } catch {
                        guard self.cloudWaitTrackID == track.id else { return }
                        self.cloudWaitTrackID = nil
                        self.playbackStatus = .paused
                        self.cloudPlaybackError = error.localizedDescription
                        HapticFeedback.notificationError()
                        AppLogger.audio.error("Failed to download cloud track: \(error.localizedDescription)")
                    }
                }
                return
            }
        }

        // Unsupported server formats are transcoded to AAC and fully fetched before playback so seeking,
        // EQ, pitch and crossfade behave exactly like local files.
        if needsTranscodePrefetch(track) {
            let requests = transcodeRequests(for: track)
            guard !requests.isEmpty else {
                self.playbackStatus = .paused
                self.cloudPlaybackError = "SERVER UNAVAILABLE"
                return
            }
            self.playbackStatus = .buffering
            self.cloudWaitTrackID = track.id
            cloudDownloadTask = Task { @MainActor [weak self] in
                do {
                    _ = try await ServerTranscodeCache.shared.ensureLocal(track: track, requests: requests)
                    guard let self, self.cloudWaitTrackID == track.id, self.currentTrack?.id == track.id else { return }
                    self.cloudWaitTrackID = nil
                    self.finishLoadAndPlay(track: track, resumePosition: resumePosition)
                } catch {
                    guard let self, self.cloudWaitTrackID == track.id else { return }
                    self.cloudWaitTrackID = nil
                    self.playbackStatus = .paused
                    self.cloudPlaybackError = "TRANSCODE FAILED"
                    HapticFeedback.notificationError()
                    AppLogger.audio.error("Server transcode pre-fetch failed: \(error.localizedDescription)")
                }
            }
            return
        }

        self.cloudWaitTrackID = nil
        self.finishLoadAndPlay(track: track, resumePosition: resumePosition)
    }

    private func finishLoadAndPlay(track: Track, resumePosition: TimeInterval) {
        // Immediately set playback status to playing for instantaneous UI responsiveness
        self.playbackStatus = .playing

        // 1. Ensure audio session is active
        Task {
            await AudioSessionManager.shared.activateSessionIfNeeded()
        }

        // Teardown item-specific observers (keeps player-level time observer intact)
        teardownItemObservers()

        // 2. Use pre-warmed item if available, otherwise instantiate with pristine audio algorithm
        let playerItem: AVPlayerItem
        if prewarmedTrackID == track.id, let prewarmed = prewarmedPlayerItem {
            playerItem = prewarmed
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmingTrackID = nil
        } else {
            do {
                playerItem = try makePlayerItem(for: track, caller: "play")
            } catch {
                player?.pause()
                self.playbackStatus = .paused
                self.cloudPlaybackError = error.localizedDescription
                HapticFeedback.notificationError()
                AppLogger.audio.error("Cannot build signed server stream: \(error.localizedDescription)")
                return
            }
        }
        PlaybackTiming.mark("itemCreated", trackID: track.id)
        if playerItem.audioMix == nil {
            attachAudioMix(to: playerItem)
        }
        let isRemoteStream = (track.isJellyfinItem || track.metadataSource == .server) && JellyfinDownloadManager.shared.localFileURL(for: track.id) == nil
        playerItem.preferredForwardBufferDuration = 0.0 // 0 = system-chosen buffer for local and remote

        if (track.isJellyfinItem || track.metadataSource == .server) && autoDownloadOnPlay {
            if let server = serverSource(for: track.folderID) {
                JellyfinDownloadManager.shared.download(track: track, server: server)
            }
        }

        if resumePosition > 0 {
            let initialCMTime = CMTime(seconds: resumePosition, preferredTimescale: 600)
            playerItem.seek(to: initialCMTime, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }

        if player == nil {
            let newPlayer = AVQueuePlayer(playerItem: playerItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = isRemoteStream
            newPlayer.allowsExternalPlayback = true
            #if os(iOS)
            newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
            #endif
            self.player = newPlayer
            setupPeriodicTimeObserver()
            setupPlayerObservers(for: newPlayer)
        } else {
            player?.automaticallyWaitsToMinimizeStalling = isRemoteStream
            player?.allowsExternalPlayback = true
            #if os(iOS)
            player?.usesExternalPlaybackWhileExternalScreenIsActive = true
            #endif
            if let qPlayer = player as? AVQueuePlayer {
                qPlayer.removeAllItems()
                qPlayer.insert(playerItem, after: nil)
            } else {
                player?.replaceCurrentItem(with: playerItem)
            }
        }
        if let pl = player {
            setupBoundaryTimeObservers(for: pl, track: track, duration: track.duration)
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
            let masterVol = self.volume
            let initialVol = masterVol * 0.20
            player?.volume = initialVol
            player?.play()
            playPauseFadeTask?.cancel()
            playPauseFadeTask = Task { @MainActor in
                let steps = 6
                let stepDuration: UInt64 = 12_000_000 // 12ms per step -> 72ms total snappy micro-fade
                for step in 1...steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: stepDuration)
                    if Task.isCancelled { break }
                    let progress = Float(step) / Float(steps)
                    let currentVol = initialVol + (masterVol - initialVol) * progress
                    self.player?.volume = min(masterVol, max(0.0, currentVol))
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

        // Jellyfin playback reporting start
        if track.metadataSource == .server {
            playReportingProvider(for: track)?.reportPlayback(.started, track: track)
        }

        AppLogger.audio.info("Now playing: \(track.title) by \(track.artist) (rate: \(currentSpeed)x, resumed at: \(resumePosition)s)")
    }

    /// Selects the audio time-pitch algorithm.
    /// At 1.0x speed, returns nil for local items so AVFoundation passes audio through unchanged
    /// (avoiding CoreMedia -17770 initialization errors on integer LPCM WAV/AIFF/CAF files).
    /// At other speeds, returns .spectral for all formats.
    public nonisolated static func determineTimePitchAlgorithm(for url: URL, speed: Double) -> AVAudioTimePitchAlgorithm? {
        if abs(speed - 1.0) < 0.001 {
            if url.isFileURL {
                return nil
            }
            return nil
        } else {
            return .spectral
        }
    }

    private func appropriateTimePitchAlgorithm(for url: URL) -> AVAudioTimePitchAlgorithm? {
        Self.determineTimePitchAlgorithm(for: url, speed: EqualizerManager.shared.playbackSpeed)
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
        let audioTracks = playerItem.tracks.compactMap { $0.assetTrack }.filter { $0.mediaType == .audio }
        guard !audioTracks.isEmpty else {
            // Tracks not ready yet; will be attached when item transitions to readyToPlay
            AppLogger.audio.debug("Audio mix deferred: player item has 0 loaded audio tracks (total item tracks: \(playerItem.tracks.count)).")
            return
        }

        var inputParams: [AVAudioMixInputParameters] = []
        for track in audioTracks {
            let params = AVMutableAudioMixInputParameters(track: track)
            if let tap = AudioDSPProcessor.shared.createAudioProcessingTap() {
                params.audioTapProcessor = tap
                inputParams.append(params)
            } else {
                AppLogger.audio.warning("AudioDSPProcessor failed to create MTAudioProcessingTap for audio track ID: \(track.trackID).")
            }
        }

        guard !inputParams.isEmpty else { return }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParams
        playerItem.audioMix = audioMix
        AppLogger.audio.info("Attached AudioDSPProcessor tap to player item (\(inputParams.count) audio track(s)).")
    }

    /// Attaches the DSP tap before the item ever plays, using the asset's audio tracks.
    /// Works for plain AVPlayerItem(url:) (WAV/AIFF/CAF): it loads tracks on the item's own asset (no options),
    /// so the tap is never attached to a live item (which rebuilds the render chain and causes a dropout).
    private func attachAudioMixBeforePlayback(to playerItem: AVPlayerItem) async {
        let needsDSP = EqualizerManager.shared.isEqualizerEnabled || abs(EqualizerManager.shared.volumeBoosterDB) > 0.05
        guard needsDSP, playerItem.audioMix == nil else { return }
        guard let audioTracks = try? await playerItem.asset.loadTracks(withMediaType: .audio),
              !audioTracks.isEmpty,
              playerItem.audioMix == nil else { return }
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
        AppLogger.audio.info("Attached AudioDSPProcessor tap before playback (\(inputParams.count) audio track(s)).")
    }

    /// Waits (on the main actor) until the item is ready to play. Returns false on failure, timeout or cancellation.
    private func waitUntilReadyToPlay(_ item: AVPlayerItem, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: break
            }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// Dynamically ensures the audio mix DSP tap is attached on the currently playing item if needed.
    public func updateAudioMixForCurrentItem() {
        // Do not attach or detach audioMix on a live playing item.
        // Toggling audioMix rebuilds the render chain and causes an audible gap.
        // Live parameter changes are applied lock-free to AudioDSPProcessor.
        // The tap is attached once at item creation and detached only on track change.
    }

    // Pre-warms the next track in queue asynchronously so skipping to it is instantaneous
    private func prewarmNextTrackIfNeeded() {
        guard let currentItem = player?.currentItem, currentItem.status == .readyToPlay else {
            return
        }
        guard let next = nextTrack else {
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmingTrackID = nil
            prewarmTask?.cancel()
            prewarmTask = nil
            return
        }
        // Guard so the same next track is prewarmed only once
        if (prewarmedTrackID == next.id && prewarmedPlayerItem != nil) || (prewarmingTrackID == next.id && prewarmTask != nil) {
            return
        }
        // Never open, decode or prewarm cloud-only tracks that are not downloaded
        guard next.canReadLocalBytes || next.metadataSource == .server else {
            return
        }
        // Next track needs a transcode: fetch it fully in the background; it is prewarmed from disk once ready.
        if needsTranscodePrefetch(next) {
            let requests = transcodeRequests(for: next)
            if !requests.isEmpty {
                Task { await ServerTranscodeCache.shared.prefetch(track: next, requests: requests) }
            }
            return
        }
        
        prewarmingTrackID = next.id
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            guard let self = self else { return }
            guard let item = try? self.makePlayerItem(for: next, caller: "prewarm") else {
                self.prewarmingTrackID = nil
                return
            }
            item.preferredForwardBufferDuration = 0.0
            // Attach the EQ/boost tap now, while the item is not playing.
            await self.attachAudioMixBeforePlayback(to: item)
            
            // Only prewarm waveform amplitude peaks for local files
            if next.canReadLocalBytes {
                _ = await AudioWaveformSpectrogramGenerator.shared.fetchSubSecondWaveformPeaks(
                    for: next.url,
                    duration: next.duration,
                    samplesPerSecond: 2
                )
            } else if next.isJellyfinItem || next.metadataSource == .server {
                if let urlAsset = item.asset as? AVURLAsset {
                    _ = try? await urlAsset.load(.isPlayable, .duration)
                }
            }
            
            guard !Task.isCancelled else {
                self.prewarmingTrackID = nil
                return
            }
            self.prewarmedTrackID = next.id
            self.prewarmedPlayerItem = item
            self.prewarmingTrackID = nil
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
        if let errLogObs = playerItemErrorLogObserver {
            NotificationCenter.default.removeObserver(errLogObs)
            playerItemErrorLogObserver = nil
        }
        if let accLogObs = playerItemAccessLogObserver {
            NotificationCenter.default.removeObserver(accLogObs)
            playerItemAccessLogObserver = nil
        }
        if let stalledObs = playerItemStalledObserver {
            NotificationCenter.default.removeObserver(stalledObs)
            playerItemStalledObserver = nil
        }
        itemLikelyToKeepUpObserver?.invalidate()
        itemLikelyToKeepUpObserver = nil
        itemBufferEmptyObserver?.invalidate()
        itemBufferEmptyObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        clearBoundaryTimeObservers()
    }

    // Clear boundary time observers
    private func clearBoundaryTimeObservers(for targetPlayer: AVPlayer? = nil) {
        let p = targetPlayer ?? self.player
        for token in boundaryObserverTokens {
            p?.removeTimeObserver(token)
        }
        boundaryObserverTokens.removeAll()
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
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch p.timeControlStatus {
                case .playing:
                    self.isTransitioningTrack = false
                    self.transitionTimeoutTask?.cancel()
                    self.isRoutingChanging = false // Clear routing flag when confirmed playing
                    self.playbackStatus = .playing
                    self.updateNowPlayingPlaybackState()
                case .paused:
                    // If currently loading / replacing a track item, seeking, switching routes, smoothly fading out, or transitioning tracks, do not let the transient state trigger an unexpected pause
                    if self.isTransitioningTrack || self.isSeeking || self.isRoutingChanging || self.isFadingOutPause || self.isSmoothSkipping || self.isStaggeredTransitioning || self.isCrossfading {
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
                    self.playbackStatus = .buffering
                @unknown default:
                    break
                }
            }
        }
    }
    
    // Setup player item observers
    private func setupPlayerItemObservers(for playerItem: AVPlayerItem, track: Track, isHandoff: Bool = false) {
        // 1. Observe playerItem.status
        itemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    PlaybackTiming.mark("readyToPlay", trackID: track.id)
                    // A handed-off item is already playing with its tap attached: never touch audioMix live.
                    if !isHandoff {
                        self.attachAudioMix(to: item)
                    }
                    let dSec = CMTimeGetSeconds(item.duration)
                    if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                        self.duration = dSec
                        self.progress.duration = dSec
                        self.updateNowPlayingDuration(dSec)
                    }
                    if let p = self.player {
                        self.setupBoundaryTimeObservers(for: p, track: track, duration: self.duration)
                    }
                    if self.playbackStatus != .stopped {
                        self.playbackStatus = .playing
                    }
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    if !isHandoff {
                        self.player?.defaultRate = speed
                        self.player?.play()
                    }

                    let audioTracks = item.tracks.compactMap { $0.assetTrack }.filter { $0.mediaType == .audio }
                    let formats = audioTracks.compactMap { $0.formatDescriptions.first }.map { String(describing: $0) }.joined(separator: ", ")
                    let formatInfo = formats.isEmpty ? "Native" : formats
                    AppLogger.audio.info("AVPlayerItem ready to play: \"\(track.title)\" (duration: \(String(format: "%.2f", self.duration))s, speed: \(speed)x, tracks: \(audioTracks.count), format: \(formatInfo))")
                    self.prewarmNextTrackIfNeeded()
                case .failed:
                    self.isTransitioningTrack = false
                    self.transitionTimeoutTask?.cancel()

                    let itemErr = item.error as? NSError
                    let itemErrDesc = itemErr?.localizedDescription ?? "None"
                    let itemDomain = itemErr?.domain ?? "UnknownDomain"
                    let itemCode = itemErr?.code ?? 0
                    let underlyingErr = itemErr?.userInfo[NSUnderlyingErrorKey] as? NSError
                    let underlyingDomain = underlyingErr?.domain ?? "None"
                    let underlyingCode = underlyingErr.map { String($0.code) } ?? "None"
                    let underlyingDesc = underlyingErr?.localizedDescription ?? "None"

                    let playerErr = self.player?.error as? NSError
                    let playerErrDesc = playerErr?.localizedDescription ?? "None"
                    let playerDomain = playerErr?.domain ?? "UnknownDomain"
                    let playerCode = playerErr?.code ?? 0

                    let algo = item.audioTimePitchAlgorithm.rawValue
                    let speed = EqualizerManager.shared.playbackSpeed

                    let errorEvents = item.errorLog()?.events ?? []
                    let errorLogDetails = errorEvents.map { evt in
                        "[\(evt.errorDomain):\(evt.errorStatusCode) \"\(evt.errorComment ?? "NoComment")\" URI:\(evt.uri ?? "nil")]"
                    }.joined(separator: "; ")
                    let logStr = errorLogDetails.isEmpty ? "None" : errorLogDetails

                    let isLocal = track.url.isFileURL
                    let reachable = isLocal ? FileManager.default.fileExists(atPath: track.url.path) : true
                    let ext = (track.fileInfo?.fileExtension ?? track.url.pathExtension).uppercased()

                    let fullReport = "AVPlayerItem failed for \"\(track.title)\" [ID:\(track.id.uuidString)] [Type:.\(ext)] [Reachable:\(reachable)]. ItemError: \(itemDomain)(\(itemCode)) \"\(itemErrDesc)\". Underlying: \(underlyingDomain)(\(underlyingCode)) \"\(underlyingDesc)\". PlayerError: \(playerDomain)(\(playerCode)) \"\(playerErrDesc)\". Algorithm: \(algo). Speed: \(speed)x. CoreMedia ErrorLog: \(logStr)"
                    AppLogger.audio.error(fullReport)
                    self.lastPlaybackError = fullReport

                    // Show short UPPERCASE error, fire haptic, and skip to the next track. Never sit silently on PLAY.
                    self.cloudPlaybackError = "CAN'T PLAY FILE"
                    HapticFeedback.notificationError()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if self?.cloudPlaybackError == "CAN'T PLAY FILE" {
                            self?.cloudPlaybackError = nil
                        }
                    }

                    if self.nextTrack != nil {
                        AppLogger.audio.error("Skipping to next track after item failure on \"\(track.title)\".")
                        self.performNext()
                    } else {
                        self.playbackStatus = .stopped
                    }
                case .unknown:
                    AppLogger.audio.debug("AVPlayerItem status in pending state: unknown for \"\(track.title)\"")
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
            Task { @MainActor [weak self] in
                AppLogger.audio.info("AVPlayerItem reached end of track: \"\(track.title)\"")
                self?.handleTrackEnded()
            }
        }
        
        // 3. Observe AVPlayerItem failed to play to end
        playerItemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let nsErr = error as? NSError
            let errorDesc = error?.localizedDescription ?? "unknown error"
            let domain = nsErr?.domain ?? "UnknownDomain"
            let code = nsErr?.code ?? 0
            let underlyingErr = nsErr?.userInfo[NSUnderlyingErrorKey] as? NSError
            let underlyingDomain = underlyingErr?.domain ?? "None"
            let underlyingCode = underlyingErr.map { String($0.code) } ?? "None"
            let underlyingDesc = underlyingErr?.localizedDescription ?? "None"
            let timeSec = CMTimeGetSeconds(playerItem.currentTime())
            let timeStr = (!timeSec.isNaN && !timeSec.isInfinite) ? String(format: "%.2f", timeSec) : "unknown"

            let algo = playerItem.audioTimePitchAlgorithm.rawValue
            let speed = EqualizerManager.shared.playbackSpeed

            let errorEvents = playerItem.errorLog()?.events ?? []
            let errorLogDetails = errorEvents.map { evt in
                "[\(evt.errorDomain):\(evt.errorStatusCode) \"\(evt.errorComment ?? "NoComment")\" URI:\(evt.uri ?? "nil")]"
            }.joined(separator: "; ")
            let logStr = errorLogDetails.isEmpty ? "None" : errorLogDetails

            Task { @MainActor [weak self] in
                let failReport = "AVPlayerItem failed during active playback of \"\(track.title)\" at \(timeStr)s. Error: \(domain)(\(code)) \"\(errorDesc)\". Underlying: \(underlyingDomain)(\(underlyingCode)) \"\(underlyingDesc)\". Algorithm: \(algo). Speed: \(speed)x. CoreMedia ErrorLog: \(logStr)"
                AppLogger.audio.warning(failReport)
                guard let self = self else { return }
                self.lastPlaybackError = failReport

                // If playback failed while audio processing tap was attached, detach audioMix immediately
                if playerItem.audioMix != nil {
                    AppLogger.audio.warning("Output route rejected audio processing tap on \"\(track.title)\". Detaching audioMix and recovering playback immediately.")
                    playerItem.audioMix = nil
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    self.player?.defaultRate = speed
                    self.player?.play()
                    return
                }

                if self.duration > 0 && self.currentTime >= self.duration - 2.0 {
                    AppLogger.audio.info("Playback error occurred at end of track boundary (\(timeStr)s / \(String(format: "%.2f", self.duration))s); handling as natural track end.")
                    self.handleTrackEnded()
                } else {
                    // Show short UPPERCASE error, fire haptic, and skip to the next track. Never sit silently on PLAY.
                    self.cloudPlaybackError = "CAN'T PLAY FILE"
                    HapticFeedback.notificationError()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if self?.cloudPlaybackError == "CAN'T PLAY FILE" {
                            self?.cloudPlaybackError = nil
                        }
                    }

                    if self.nextTrack != nil {
                        AppLogger.audio.error("Advancing to next track after playback failure on \"\(track.title)\": \(failReport)")
                        self.performNext()
                    } else {
                        AppLogger.audio.error("Stopping playback due to unrecoverable error on \"\(track.title)\" with empty queue.")
                        self.playbackStatus = .stopped
                    }
                }
            }
        }

        // 4. Observe AVPlayerItem real-time error log entries (captures low-level network/TLS/codec stalls)
        playerItemErrorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let event = playerItem.errorLog()?.events.last {
                    let logMsg = "AVPlayerItem error log entry for \"\(track.title)\": Code \(event.errorStatusCode) [\(event.errorDomain)] \"\(event.errorComment ?? "NoComment")\" URI: \(event.uri ?? "nil") Server: \(event.serverAddress ?? "nil")"
                    AppLogger.audio.warning(logMsg)
                    self.lastPlaybackError = logMsg
                }
            }
        }

        // 5. Observe AVPlayerItem playback stalled for remote streams
        playerItemStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let currentPos = CMTimeGetSeconds(playerItem.currentTime())
                let posStr = (!currentPos.isNaN && !currentPos.isInfinite) ? String(format: "%.2f", currentPos) : "unknown"
                AppLogger.audio.warning("AVPlayerItem playback stalled at \(posStr)s for \"\(track.title)\", awaiting network buffer...")
                if self.playbackStatus == .playing {
                    self.playbackStatus = .buffering
                }
            }
        }

        // 6. Observe isPlaybackLikelyToKeepUp to resume from buffering
        itemLikelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if item.isPlaybackLikelyToKeepUp && self.playbackStatus == .buffering {
                    AppLogger.audio.info("AVPlayerItem buffer refilled and likely to keep up; resuming \"\(track.title)\".")
                    self.playbackStatus = .playing
                    let speed = Float(EqualizerManager.shared.playbackSpeed)
                    self.player?.defaultRate = speed
                    self.player?.play()
                }
            }
        }
        
        // 7. Observe isPlaybackBufferEmpty to detect network starvation
        itemBufferEmptyObserver = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if item.isPlaybackBufferEmpty && self.playbackStatus == .playing {
                    AppLogger.audio.warning("AVPlayerItem buffer empty for \"\(track.title)\", entering buffering state.")
                    self.playbackStatus = .buffering
                }
            }
        }
    }

    // Setup boundary time observers for one-time triggers:
    // - 10s Wi-Fi prefetch
    // - 15s play count (or 90% if track is shorter than 15s)
    // - Crossfade trigger at (duration - crossfadeDuration)
    private func setupBoundaryTimeObservers(for targetPlayer: AVPlayer, track: Track, duration: Double) {
        clearBoundaryTimeObservers(for: targetPlayer)
        
        var times: [CMTime] = []
        
        let prefetchTime = CMTime(seconds: 10.0, preferredTimescale: 600)
        times.append(prefetchTime)
        
        let countSeconds = (duration > 0 && duration < 15.0) ? (duration * 0.9) : 15.0
        let countTime = CMTime(seconds: countSeconds, preferredTimescale: 600)
        times.append(countTime)
        
        if isCrossfadeEnabled && crossfadeDuration >= 0.5 && duration > (crossfadeDuration * 1.2) {
            // Lead time so preparation (tap attach, ready, preroll) finishes before the fade must start.
            let xfadeSeconds = max(0.0, duration - crossfadeDuration - Self.crossfadePrepLead)
            let xfadeTime = CMTime(seconds: xfadeSeconds, preferredTimescale: 600)
            times.append(xfadeTime)
        }
        
        let triggerSlack = Self.crossfadeTriggerSlack
        let nsValues = times.map { NSValue(time: $0) }
        let token = targetPlayer.addBoundaryTimeObserver(forTimes: nsValues, queue: .main) { [weak self] in
            guard let self = self else { return }
            // Read the player's own clock (self.currentTime is only refreshed every 0.35 s).
            let playerSec = CMTimeGetSeconds(targetPlayer.currentTime())
            let cur = (playerSec.isNaN || playerSec.isInfinite) ? self.currentTime : playerSec
            
            // 1. Wi-Fi prefetch check
            if !self.hasTriggeredWiFiPrefetch && cur >= 9.8 {
                self.hasTriggeredWiFiPrefetch = true
                if self.downloadNextSongOnWiFi,
                   let nextTarget = self.nextPlaybackTarget()?.track,
                   !nextTarget.canReadLocalBytes,
                   nextTarget.metadataSource != .server {
                    Task {
                        _ = try? await CloudDownloadCenter.shared.ensureLocal(track: nextTarget)
                    }
                }
            }
            
            // 2. Play count check
            if !self.hasCountedCurrentPlay && (cur >= countSeconds - 0.2) {
                self.hasCountedCurrentPlay = true
                if let current = self.currentTrack {
                    self.onTrackPlay?(current.id)
                }
            }
            
            // 3. Crossfade check
            if self.isCrossfadeEnabled && !self.isCrossfading && self.duration > 0 {
                let remaining = self.duration - cur
                if remaining <= self.crossfadeDuration + triggerSlack && remaining > 0 {
                    self.checkAndTriggerCrossfadeIfNeeded()
                }
            }
        }
        boundaryObserverTokens.append(token)
    }

    // Setup periodic time observer (raised interval to 0.35s to eliminate main thread pressure)
    private func setupPeriodicTimeObserver() {
        if timeObserverToken != nil { return }
        let interval = CMTime(seconds: 0.35, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            let seconds = CMTimeGetSeconds(time)
            guard !seconds.isNaN && !seconds.isInfinite else { return }
            self.currentTime = seconds
            self.progress.currentTime = seconds
            if seconds > 0, (self.player?.rate ?? 0) > 0 {
                PlaybackTiming.mark("firstAudio", trackID: self.currentTrack?.id)
            }
            
            // Duration refined after load (VBR MP3, server streams): rebuild the boundaries so the crossfade point is right.
            // The observer is delivered on the main queue, so main-actor isolation holds here.
            MainActor.assumeIsolated {
            if !self.isCrossfading, self.duration > 0, let itemDur = self.player?.currentItem?.duration,
               self.player?.currentItem?.status == .readyToPlay {
                let dSec = CMTimeGetSeconds(itemDur)
                if !dSec.isNaN && !dSec.isInfinite && dSec > 0 && abs(dSec - self.duration) > 0.5 {
                    self.duration = dSec
                    self.progress.duration = dSec
                    self.updateNowPlayingDuration(dSec)
                    if let p = self.player, let cur = self.currentTrack {
                        self.setupBoundaryTimeObservers(for: p, track: cur, duration: dSec)
                    }
                }
            }
            // Backup crossfade trigger in case the one-shot boundary was missed (idempotent).
            if self.isCrossfadeEnabled && !self.isCrossfading && self.duration > 0 {
                self.checkAndTriggerCrossfadeIfNeeded()
            }
            }
            
            if self.duration <= 0, let itemDur = self.player?.currentItem?.duration {
                let dSec = CMTimeGetSeconds(itemDur)
                if !dSec.isNaN && !dSec.isInfinite && dSec > 0 {
                    self.duration = dSec
                    self.progress.duration = dSec
                    if let p = self.player, let cur = self.currentTrack {
                        self.setupBoundaryTimeObservers(for: p, track: cur, duration: dSec)
                    }
                }
            }
            
            // Periodic Jellyfin progress reporting (every 10s)
            if let track = self.currentTrack, track.metadataSource == .server {
                if Int(seconds) / 10 != Int(self.lastJellyfinReportedSeconds) / 10 {
                    self.lastJellyfinReportedSeconds = seconds
                    self.playReportingProvider(for: track)?.reportPlayback(
                        .progress(position: seconds, isPaused: self.playbackStatus != .playing),
                        track: track
                    )
                }
            }
        }
    }
    
    // Handle track ended
    private func handleTrackEnded() {
        if let track = currentTrack, track.metadataSource == .server {
            playReportingProvider(for: track)?.reportPlayback(.stopped(position: duration), track: track)
        }
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
              repeatMode != .one,
              duration > (crossfadeDuration * 1.2),
              playbackStatus == .playing,
              autoPlayNext || repeatMode != .off else { return }
        
        // Remaining, from the player's own clock
        let playerSec = player.map { CMTimeGetSeconds($0.currentTime()) } ?? currentTime
        let now = (playerSec.isNaN || playerSec.isInfinite) ? currentTime : playerSec
        let remaining = duration - now
        if remaining <= crossfadeDuration + Self.crossfadeTriggerSlack && remaining > 0 {
            // Next-item creation waits until the current item is ready to play.
            guard player?.currentItem?.status == .readyToPlay else { return }
            guard let target = nextPlaybackTarget() else { return }
            if crossfadeFailedTrackID == target.track.id { return }
            // Do not crossfade into an undownloaded cloud file
            if !target.track.canReadLocalBytes && target.track.metadataSource != .server {
                return
            }
            // Never crossfade into a transcode that is not fully on disk yet
            if needsTranscodePrefetch(target.track) {
                return
            }
            startCrossfade(to: target.track, nextIndex: target.nextIndex, isFromPlayNext: target.isFromPlayNext)
        }
    }
    
    /// Extra lead before (duration - crossfadeDuration) so preparation completes and the full fade is kept.
    private static let crossfadePrepLead: Double = 0.3
    /// Tolerance when checking the trigger window (avoids missing the one-shot boundary).
    private static let crossfadeTriggerSlack: Double = 0.5

    // Start crossfade
    private func startCrossfade(to nextTrack: Track, nextIndex: Int?, isFromPlayNext: Bool = false) {
        // Ensure preconditions are met before proceeding
        guard !isCrossfading, let outgoingPlayer = self.player else { return }
        // Next item: reuse the prewarmed item if it matches, else unified makePlayerItem (signed).
        // On failure the track ends normally and the regular advance surfaces the error.
        let nextItem: AVPlayerItem
        if prewarmedTrackID == nextTrack.id, let prewarmed = prewarmedPlayerItem {
            nextItem = prewarmed
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmingTrackID = nil
        } else {
            do {
                nextItem = try makePlayerItem(for: nextTrack, caller: "crossfade")
            } catch {
                crossfadeFailedTrackID = nextTrack.id
                AppLogger.audio.error("Crossfade skipped: \(error.localizedDescription)")
                return
            }
        }
        saveCurrentPlaybackPositionIfNeeded()
        isCrossfading = true
        crossfadeTask?.cancel()
        
        if isFromPlayNext && !playNextQueue.isEmpty {
            playNextQueue.removeFirst()
        }
        
        nextItem.preferredForwardBufferDuration = 0.0
        
        // Old-track bookkeeping, run against the OLD track before switching
        if let oldTrack = self.currentTrack {
            if oldTrack.metadataSource == .server {
                playReportingProvider(for: oldTrack)?.reportPlayback(.stopped(position: duration), track: oldTrack)
            }
            if !hasCountedCurrentPlay {
                hasCountedCurrentPlay = true
                onTrackPlay?(oldTrack.id)
            }
            clearSavedPlaybackPosition(for: oldTrack.id)
        }
        
        // Detach the outgoing player's clock, boundaries and item observers so only the incoming clock drives the UI
        // and the old item's end notification cannot act on the new track.
        if let token = self.timeObserverToken {
            outgoingPlayer.removeTimeObserver(token)
            self.timeObserverToken = nil
        }
        teardownItemObservers() // also clears boundary observers on the outgoing player
        
        // Incoming player
        let isRemoteStream = (nextTrack.isJellyfinItem || nextTrack.metadataSource == .server) && JellyfinDownloadManager.shared.localFileURL(for: nextTrack.id) == nil
        let incomingPlayer = AVPlayer(playerItem: nextItem)
        incomingPlayer.automaticallyWaitsToMinimizeStalling = isRemoteStream
        incomingPlayer.allowsExternalPlayback = true
        #if os(iOS)
        incomingPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        incomingPlayer.volume = 0.0
        incomingPlayer.isMuted = false
        self.fadePlayer = incomingPlayer
        
        // Switch the UI to the next track at fade start, progress from 0
        self.currentTrack = nextTrack
        self.currentIndex = nextIndex
        self.duration = nextTrack.duration
        self.currentTime = 0.0
        self.progress.currentTime = 0.0
        self.progress.duration = nextTrack.duration
        self.hasCountedCurrentPlay = false
        self.playbackAccumulatedTime = 0
        self.hasTriggeredWiFiPrefetch = false
        self.lastJellyfinReportedSeconds = 0
        
        // Single progress clock: the incoming player
        let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
        self.fadeTimeObserverToken = incomingPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSeeking else { return }
                let seconds = CMTimeGetSeconds(time)
                if !seconds.isNaN && !seconds.isInfinite {
                    self.currentTime = seconds
                    self.progress.currentTime = seconds
                }
            }
        }
        
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        incomingPlayer.defaultRate = speed
        
        let totalFadeDuration = max(self.crossfadeDuration, 0.5)
        // Fade steps
        let fadeSteps = 40
        // Step duration
        let stepDuration = totalFadeDuration / Double(fadeSteps)
        
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Prepare before the incoming track is heard: tap attached, per-track EQ, ready, preroll.
            await self.attachAudioMixBeforePlayback(to: nextItem)
            guard !Task.isCancelled else { return }
            EqualizerManager.shared.trackWillPlay(track: nextTrack)
            let ready = await self.waitUntilReadyToPlay(nextItem, timeout: isRemoteStream ? 8.0 : 2.5)
            guard !Task.isCancelled else { return }
            if ready {
                if nextItem.audioMix == nil {
                    self.attachAudioMix(to: nextItem) // still not playing
                }
                if !isRemoteStream && incomingPlayer.status == .readyToPlay && incomingPlayer.rate == 0 {
                    _ = await incomingPlayer.preroll(atRate: speed)
                }
                guard !Task.isCancelled else { return }
            } else if nextItem.status == .failed {
                AppLogger.audio.error("Crossfade incoming item failed; handing over to regular playback.")
            }
            incomingPlayer.play()
            AppLogger.audio.info("Starting crossfade (\(self.crossfadeDuration)s) to: \(nextTrack.title) at \(speed)x")
            
            for step in 1...fadeSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
                if Task.isCancelled { break }
                
                // Progress
                let progress = Float(step) / Float(fadeSteps)
                // Angle
                let angle = progress * (Float.pi / 2.0)
                // Smooth equal-power curve (prevents volume dip in middle of crossfade) scaled by master volume
                outgoingPlayer.volume = max(0.0, cos(angle)) * self.volume
                incomingPlayer.volume = min(1.0, sin(angle)) * self.volume
            }
            
            // Ensure preconditions are met before proceeding
            guard !Task.isCancelled else { return }
            
            // Finalize crossfade handoff: stop listening to the old player's state first, then pause it
            self.playerTimeControlObserver?.invalidate()
            self.playerTimeControlObserver = nil
            outgoingPlayer.pause()
            outgoingPlayer.volume = 0.0
            outgoingPlayer.replaceCurrentItem(with: nil)
            
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
                self.progress.currentTime = currentSec
            }
            
            // Attach observers to active player (handoff: no live tap attach, no extra play/rate)
            self.setupPlayerItemObservers(for: nextItem, track: nextTrack, isHandoff: true)
            self.setupPeriodicTimeObserver()
            self.setupPlayerObservers(for: incomingPlayer)
            if incomingPlayer.timeControlStatus == .playing {
                self.playbackStatus = .playing
            }
            self.setupNowPlayingInfo(for: nextTrack)
            self.updateNowPlayingElapsedTime()
            
            AppLogger.audio.info("Crossfade cleanly completed at exact track position: \(self.currentTime)s")
        }
    }
    
    /// Transitions cleanly between tracks when smooth skipping is enabled using a 2-phase staggered envelope:
    /// Phase 1: Incoming track begins playback at 0.0 volume and smoothly fades in first to master volume while current track continues playing.
    /// Phase 2: Once the incoming track is at full volume, current track fades out second to 0.0, pauses, unloads, and completes handoff.
    private func startStaggeredSkipTransition(
        to nextTrack: Track,
        nextIndex: Int?,
        commitQueueAction: @escaping () -> Void
    ) {
        cancelCrossfade()
        
        // 1. Rapid skip cleanup: if a transition is already in flight, cleanly terminate it without pop
        if isStaggeredTransitioning {
            skipTransitionTask?.cancel()
            skipTransitionTask = nil
            
            if let outgoing = skipOutgoingPlayer {
                outgoing.volume = 0.0
                outgoing.pause()
                outgoing.replaceCurrentItem(with: nil)
                self.skipOutgoingPlayer = nil
            }
            
            if let incoming = skipIncomingPlayer {
                incoming.volume = 0.0
                incoming.pause()
                incoming.replaceCurrentItem(with: nil)
                self.skipIncomingPlayer = nil
            }
            
            if let token = fadeTimeObserverToken {
                player?.removeTimeObserver(token)
                fadeTimeObserverToken = nil
            }
        }
        
        guard let outgoingPlayer = self.player, playbackStatus == .playing else {
            commitQueueAction()
            loadAndPlay(track: nextTrack)
            return
        }
        
        // 2. Commit queue updates synchronously and update UI immediately (0ms delay)
        commitQueueAction()
        self.isStaggeredTransitioning = true
        self.isTransitioningTrack = true
        self.transitionTimeoutTask?.cancel()
        self.transitionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.isTransitioningTrack = false
            self?.isStaggeredTransitioning = false
        }
        
        self.currentTrack = nextTrack
        self.duration = nextTrack.duration
        self.currentTime = 0.0
        self.playbackStatus = .playing
        self.hasCountedCurrentPlay = false
        self.playbackAccumulatedTime = 0
        // Now Playing / artwork is updated after the fade (keeps main-thread work out of the transition).
        
        // Retain outgoing player
        self.skipOutgoingPlayer = outgoingPlayer
        let masterVol = self.volume
        
        // Remove time observer from outgoing player so UI tracks incoming track from 0:00
        if let token = self.timeObserverToken {
            outgoingPlayer.removeTimeObserver(token)
            self.timeObserverToken = nil
        }
        teardownItemObservers()
        
        // 3. Prepare incoming player item using unified makePlayerItem
        let playerItem: AVPlayerItem
        if prewarmedTrackID == nextTrack.id, let prewarmed = prewarmedPlayerItem {
            playerItem = prewarmed
            prewarmedTrackID = nil
            prewarmedPlayerItem = nil
            prewarmingTrackID = nil
        } else {
            do {
                playerItem = try makePlayerItem(for: nextTrack, caller: "smoothSkip")
            } catch {
                // Hand over to the regular path, which stops playback and shows the error.
                self.isStaggeredTransitioning = false
                loadAndPlay(track: nextTrack)
                return
            }
        }
        playerItem.preferredForwardBufferDuration = 0.0
        
        // 4. Instantiate incoming player with 0 volume and immediate buffering
        let incoming = AVPlayer(playerItem: playerItem)
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.allowsExternalPlayback = true
        #if os(iOS)
        incoming.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        incoming.volume = 0.0
        incoming.isMuted = isMuted
        let speed = Float(EqualizerManager.shared.playbackSpeed)
        incoming.defaultRate = speed
        self.skipIncomingPlayer = incoming
        
        // Attach time observer to incoming player so dial and progress bar track smoothly
        let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
        self.fadeTimeObserverToken = incoming.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSeeking else { return }
                let seconds = CMTimeGetSeconds(time)
                if !seconds.isNaN && !seconds.isInfinite {
                    self.currentTime = seconds
                }
            }
        }
        
        // 5. Prepare first (tap attached, per-track EQ applied, item ready + prerolled), then play and run the envelope:
        // Phase 1: Incoming track fades in from 0.0 to masterVol (~240 ms) while current track plays at full volume
        // Phase 2: Once incoming track is fully faded in, outgoing track fades out to 0.0, pauses, and unloads
        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Attach the EQ/boost tap while the item is not playing (never after play()).
            await self.attachAudioMixBeforePlayback(to: playerItem)
            guard !Task.isCancelled else { return }
            
            // Apply the per-track EQ before the incoming track is heard.
            EqualizerManager.shared.trackWillPlay(track: nextTrack)
            
            // Play only once the item is ready.
            let ready = await self.waitUntilReadyToPlay(playerItem, timeout: 2.5)
            guard !Task.isCancelled else { return }
            guard ready else {
                // Hand over to the regular path, which handles errors and slow items.
                if let token = self.fadeTimeObserverToken {
                    incoming.removeTimeObserver(token)
                    self.fadeTimeObserverToken = nil
                }
                incoming.pause()
                incoming.replaceCurrentItem(with: nil)
                self.skipIncomingPlayer = nil
                self.skipOutgoingPlayer = nil
                self.isStaggeredTransitioning = false
                self.loadAndPlay(track: nextTrack)
                return
            }
            // Fallback: if the asset path could not attach the tap, attach now (item still not playing).
            if playerItem.audioMix == nil {
                self.attachAudioMix(to: playerItem)
            }
            if incoming.status == .readyToPlay && incoming.rate == 0 {
                _ = await incoming.preroll(atRate: speed)
            }
            guard !Task.isCancelled else { return }
            incoming.play()
            
            // --- Phase 1: Next track fades in (equal-power, 240ms: 16 steps * 15ms) while current track plays at full volume ---
            let fadeInSteps = 16
            let fadeInDuration: UInt64 = 15_000_000
            for step in 1...fadeInSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: fadeInDuration)
                if Task.isCancelled { break }
                let progress = Float(step) / Float(fadeInSteps)
                incoming.volume = min(masterVol, max(0.0, masterVol * sin(progress * Float.pi / 2.0)))
                outgoingPlayer.volume = masterVol
            }
            
            guard !Task.isCancelled else { return }
            incoming.volume = masterVol
            outgoingPlayer.volume = masterVol
            
            // --- Phase 2: Current track fades out second while next track plays at full volume (105ms: 7 steps * 15ms) ---
            let fadeOutSteps = 7
            let fadeOutDuration: UInt64 = 15_000_000
            for step in 1...fadeOutSteps {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: fadeOutDuration)
                if Task.isCancelled { break }
                let progress = Float(step) / Float(fadeOutSteps)
                outgoingPlayer.volume = max(0.0, masterVol * (1.0 - progress))
                incoming.volume = masterVol
            }
            
            guard !Task.isCancelled else { return }
            
            // Finalize Handoff
            outgoingPlayer.volume = 0.0
            outgoingPlayer.pause()
            outgoingPlayer.replaceCurrentItem(with: nil)
            
            if let token = self.fadeTimeObserverToken {
                incoming.removeTimeObserver(token)
                self.fadeTimeObserverToken = nil
            }
            
            self.teardownPlayerObservers()
            self.player = incoming
            self.player?.volume = masterVol
            self.player?.isMuted = self.isMuted
            self.skipOutgoingPlayer = nil
            self.skipIncomingPlayer = nil
            self.isStaggeredTransitioning = false
            self.isTransitioningTrack = false
            self.transitionTimeoutTask?.cancel()
            
            let currentSec = CMTimeGetSeconds(incoming.currentTime())
            if !currentSec.isNaN && !currentSec.isInfinite {
                self.currentTime = currentSec
            }
            self.updateNowPlayingElapsedTime()
            
            self.setupPlayerItemObservers(for: playerItem, track: nextTrack, isHandoff: true)
            self.setupPeriodicTimeObserver()
            self.setupPlayerObservers(for: incoming)
            self.setupNowPlayingInfo(for: nextTrack)
        }
    }
    
    private func cancelStaggeredTransition() {
        skipTransitionTask?.cancel()
        skipTransitionTask = nil
        
        if let outgoing = skipOutgoingPlayer {
            outgoing.volume = 0.0
            outgoing.pause()
            outgoing.replaceCurrentItem(with: nil)
            skipOutgoingPlayer = nil
        }
        if let incoming = skipIncomingPlayer {
            if player !== incoming {
                incoming.volume = 0.0
                incoming.pause()
                incoming.replaceCurrentItem(with: nil)
            }
            skipIncomingPlayer = nil
        }
        if let token = fadeTimeObserverToken {
            skipIncomingPlayer?.removeTimeObserver(token)
            fadePlayer?.removeTimeObserver(token)
            fadeTimeObserverToken = nil
        }
        isStaggeredTransitioning = false
    }
    
    // Cancel crossfade
    private func cancelCrossfade() {
        seekTask?.cancel()
        seekTask = nil
        isSmoothSeeking = false
        cancelStaggeredTransition()
        
        if isCrossfading {
            crossfadeTask?.cancel()
            crossfadeTask = nil
            if let token = fadeTimeObserverToken {
                fadePlayer?.removeTimeObserver(token)
                fadeTimeObserverToken = nil
            }
            if let nextPlayer = fadePlayer {
                player?.pause()
                teardownPlayerObservers()
                player = nextPlayer
                player?.volume = self.volume
                player?.isMuted = self.isMuted
                setupPlayerObservers(for: nextPlayer)
                setupPeriodicTimeObserver()
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
                    self?.wasPlayingBeforeInterruption = (self?.playbackStatus == .playing)
                    AudioSessionManager.shared.notifyInterruptionBegan()
                    self?.pause()
                case .ended:
                    guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                        return
                    }
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    let shouldResume = options.contains(.shouldResume)
                    let reactivated = await AudioSessionManager.shared.notifyInterruptionEnded(shouldResume: shouldResume)
                    if reactivated && shouldResume && (self?.wasPlayingBeforeInterruption == true) && (self?.userPausedManually == false) {
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
            let userInfo = notification.userInfo
            let reasonValue = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previousRoute = userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateCurrentAudioRoute()
                self.scheduleDelayedRouteUpdates()

                guard let reasonValue = reasonValue,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                    return
                }

                switch reason {
                case .oldDeviceUnavailable:
                    // Check if switching back from AirPlay to built-in speaker in the AirPlay picker
                    if let previousRoute = previousRoute {
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
                    // Re-read AVAudioSession sample rate and hand it to DSP
                    let currentSR = AVAudioSession.sharedInstance().sampleRate
                    if currentSR > 0 {
                        AudioDSPProcessor.shared.updateSampleRate(currentSR)
                    }

                default:
                    break
                }
            }
        }
        
        // 3. Media Services Reset Notification (OS audio server restart)
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
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
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.playbackStatus == .playing {
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
            Task { @MainActor [weak self] in
                self?.refreshAudioSessionAndRoute()
            }
        }
        appLifecycleObservers.append(activeObs)

        let fgObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioSessionAndRoute()
            }
        }
        appLifecycleObservers.append(fgObs)

        let resignObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Keep Now Playing info current so car stereo displays correct metadata
                if self.playbackStatus == .playing {
                    self.updateNowPlayingPlaybackState()
                }
            }
        }
        appLifecycleObservers.append(resignObs)
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
            Task { @MainActor [weak self] in
                self?.play()
            }
            return .success
        }
        
        // Pause Command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }
        
        // Toggle Play/Pause Command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }
        
        // Next Track Command (Standard next button)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
            return .success
        }
        
        // Previous Track Command (Standard previous button)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previous()
            }
            return .success
        }
        
        // Change Playback Position (Scrubber on Lock Screen & Control Center)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: positionTime)
            }
            return .success
        }
        
        // Seek Forward / Backward Commands (Vehicle steering wheel hold-to-seek buttons)
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else { return .commandFailed }
            let isBegin = seekEvent.type == .beginSeeking
            Task { @MainActor [weak self] in
                guard let self = self, isBegin else { return }
                self.seek(to: min(self.duration, self.currentTime + 10))
            }
            return .success
        }
        
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else { return .commandFailed }
            let isBegin = seekEvent.type == .beginSeeking
            Task { @MainActor [weak self] in
                guard let self = self, isBegin else { return }
                self.seek(to: max(0, self.currentTime - 10))
            }
            return .success
        }
        
        // Explicitly disable 15s skip buttons so Lock Screen shows standard previous/next track buttons
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        
        // Stop Command (Car stereos send stop on engine shutoff or source switch)
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }
        
        // Shuffle & Repeat Commands
        commandCenter.changeShuffleModeCommand.isEnabled = true
        commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
            let shuffleType = (event as? MPChangeShuffleModeCommandEvent)?.shuffleType
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let shuffleType = shuffleType {
                    switch shuffleType {
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
            let repeatType = (event as? MPChangeRepeatModeCommandEvent)?.repeatType
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let repeatType = repeatType {
                    switch repeatType {
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

        // Artwork: the 600 px tier first, then the original (requested on demand for the current track only;
        // never prefetched). A generation token drops late results that belong to a previous track.
        nowPlayingArtworkGeneration &+= 1
        let generation = nowPlayingArtworkGeneration
        let trackID = track.id
        Task { [weak self] in
            guard let self else { return }
            let artKey = track.artworkKey ?? ""
            var shownData: Data?
            if !artKey.isEmpty, let data = await ArtworkCacheService.shared.loadArtworkAsync(key: artKey) {
                shownData = data
            }
            if let artwork = await NowPlayingArtworkSource.makeArtwork(data: shownData) {
                guard self.applyNowPlayingArtwork(artwork, generation: generation, trackID: trackID) else { return }
            }
            guard !artKey.isEmpty,
                  let original = await ArtworkCacheService.shared.loadArtworkAsync(key: artKey, fullResolution: true),
                  original != shownData,
                  let artwork = await NowPlayingArtworkSource.makeArtwork(data: original) else { return }
            _ = self.applyNowPlayingArtwork(artwork, generation: generation, trackID: trackID)
        }
    }

    /// Bumped on every Now Playing setup; artwork from an older setup (previous track) is ignored.
    private var nowPlayingArtworkGeneration = 0

    /// Sets the artwork if it still belongs to the current track. Returns false when it was stale.
    private func applyNowPlayingArtwork(_ artwork: MPMediaItemArtwork, generation: Int, trackID: Track.ID) -> Bool {
        guard generation == nowPlayingArtworkGeneration, currentTrack?.id == trackID,
              var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return false }
        currentInfo[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
        return true
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
    

    // MARK: - Diagnostics

    /// Gathers detailed internal engine state for troubleshooting and error inspection.
    public func playerDiagnostics() -> [String: String] {
        var dict: [String: String] = [:]
        dict["playbackStatus"] = "\(playbackStatus)"
        dict["lastPlaybackError"] = lastPlaybackError ?? "None"
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
                dict["player_error"] = "\(err.localizedDescription) (Domain: \((err as NSError).domain), Code: \((err as NSError).code))"
            }
            if let item = player.currentItem {
                dict["item_status"] = "\(item.status.rawValue)"
                if let itemErr = item.error {
                    dict["item_error"] = "\(itemErr.localizedDescription) (Domain: \((itemErr as NSError).domain), Code: \((itemErr as NSError).code))"
                }
                dict["item_playbackLikelyToKeepUp"] = "\(item.isPlaybackLikelyToKeepUp)"
                dict["item_playbackBufferEmpty"] = "\(item.isPlaybackBufferEmpty)"
                dict["item_playbackBufferFull"] = "\(item.isPlaybackBufferFull)"

                if let errorLog = item.errorLog(), !errorLog.events.isEmpty {
                    dict["item_errorLogCount"] = "\(errorLog.events.count)"
                    if let evt = errorLog.events.last {
                        dict["item_lastErrorCode"] = "\(evt.errorStatusCode)"
                        dict["item_lastErrorDomain"] = evt.errorDomain
                        dict["item_lastErrorComment"] = evt.errorComment ?? "None"
                        if let uri = evt.uri {
                            dict["item_lastErrorURI"] = uri
                        }
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

/// Thread-safe source for `MPMediaItemArtwork`. The request handler can be called on any thread, so it is
/// nonisolated and only touches immutable data plus a lock-protected cache. Each requested bounds size is
/// produced with an ImageIO thumbnail (downsampled on decode, never the full image); on the main thread it
/// returns the image prepared off the main thread at creation instead of decoding.
nonisolated final class NowPlayingArtworkSource: @unchecked Sendable {
    private let data: Data
    private let prepared: PlatformImage
    private let lock = NSLock()
    /// Longest side of any Now Playing artwork image, in pixels.
    private static let maxPixels = 1024
    private var rendered: [Int: PlatformImage] = [:]

    private init(data: Data, prepared: PlatformImage) {
        self.data = data
        self.prepared = prepared
    }

    /// Builds the artwork off the main thread; falls back to the bundled placeholder when there is no data.
    static func makeArtwork(data: Data?) async -> MPMediaItemArtwork? {
        await Task.detached(priority: .userInitiated) { () -> MPMediaItemArtwork? in
            if let data, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
               w > 0, h > 0,
               let prepared = thumbnail(source: source, maxPixels: min(max(w, h), maxPixels)) {
                let artworkSource = NowPlayingArtworkSource(data: data, prepared: prepared)
                // Advertise the pixel size scaled to fit within maxPixels, keeping the aspect ratio.
                let fit = min(1, CGFloat(maxPixels) / CGFloat(max(w, h)))
                let bounds = CGSize(width: max(1, (CGFloat(w) * fit).rounded()), height: max(1, (CGFloat(h) * fit).rounded()))
                return MPMediaItemArtwork(boundsSize: bounds) { size in
                    artworkSource.image(for: size)
                }
            }
            #if os(iOS)
            guard let placeholder = UIImage(named: "art"), placeholder.size.width > 0 else { return nil }
            #else
            guard let placeholder = NSImage(named: "art"), placeholder.size.width > 0 else { return nil }
            #endif
            return MPMediaItemArtwork(boundsSize: placeholder.size) { _ in placeholder }
        }.value
    }

    private func image(for size: CGSize) -> PlatformImage {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return prepared }
        // Longest side is capped at maxPixels regardless of the requested size.
        let pixels = min(Int(max(size.width, size.height).rounded(.up)), Self.maxPixels)
        lock.lock()
        if let cached = rendered[pixels] { lock.unlock(); return cached }
        lock.unlock()
        if Thread.isMainThread { return prepared }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = Self.thumbnail(source: source, maxPixels: pixels) else { return prepared }
        lock.lock()
        if rendered.count >= 4 { rendered.removeAll() }
        rendered[pixels] = image
        lock.unlock()
        return image
    }

    private static func thumbnail(source: CGImageSource, maxPixels: Int) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixels)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}
