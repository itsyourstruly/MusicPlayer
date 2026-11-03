import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Unified, fluid expandable player card prioritizing iOS touch physics and 120Hz ProMotion smoothness.
/// Floats cleanly above the native iOS tab bar when collapsed and continuously morphs into the
/// full-screen player with a single shared album artwork element, 1:1 gesture tracking, and zero touch blocking.
public struct ExpandablePlayerView: View {
    @Bindable var playerService: AudioPlayerService
    @Bindable var libraryStore: LibraryStore
    @Binding var isExpanded: Bool

    // Continuous progress: 0.0 = collapsed miniplayer, 1.0 = expanded fullscreen player
    @State private var expansionProgress: CGFloat = 0.0
    @State private var dragStartProgress: CGFloat = 0.0
    @State private var isDragging: Bool = false
    /// Direction a fullscreen drag committed to on its first movement, so a dismiss drag can never open the queue.
    @State private var dragIntent: DragIntent = .undecided
    @State private var isCollapsingToMini: Bool = false

    /// Strict guard preventing button presses while dragging, flicking, or collapsing the player.
    private var canTriggerButtonPress: Bool {
        !isDragging && !isCollapsingToMini
    }

    @State private var palette: ArtworkColorExtractor.ColorPalette = ArtworkColorExtractor.ColorPalette(
        primaryColor: Color(red: 0.16, green: 0.16, blue: 0.18),
        isDark: true
    )

    @State private var showingQueue: Bool = false
    @State private var showingFileInfo: Bool = false
    @State private var showingPlaybackSheet: Bool = false
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil

    // Initialize with configured properties
    public init(
        playerService: AudioPlayerService,
        libraryStore: LibraryStore,
        isExpanded: Binding<Bool>
    ) {
        self.playerService = playerService
        self.libraryStore = libraryStore
        self._isExpanded = isExpanded
    }

    // MARK: - iOS Safe Area Metrics

    private var windowBottomSafeArea: CGFloat {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
        let inset = window?.safeAreaInsets.bottom ?? 34
        return max(inset, 34) // Standard modern iPhone bottom safe area
        #else
        return 0
        #endif
    }

    private var windowTopSafeArea: CGFloat {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
        let inset = window?.safeAreaInsets.top ?? 48
        return max(inset, 48) // Standard modern iPhone top safe area (Dynamic Island / Notch)
        #else
        return 0
        #endif
    }

    // Main view layout structure
    public var body: some View {
        if let track = playerService.currentTrack {
            GeometryReader { geo in
                // Top safe area
                let topSafeArea = max(geo.safeAreaInsets.top, windowTopSafeArea)
                // Bottom safe area
                let bottomSafeArea = max(geo.safeAreaInsets.bottom, windowBottomSafeArea)
                // Screen width
                let screenWidth = geo.size.width
                // Screen height
                let screenHeight = geo.size.height

                // Native iOS Tab Bar height (49pt) + home indicator + 14pt floating clearance
                let tabBarTotalHeight: CGFloat = 49 + bottomSafeArea
                // Collapsed bottom offset
                let collapsedBottomOffset: CGFloat = tabBarTotalHeight + 14
                // Mini height
                let miniHeight: CGFloat = 64

                // Total physical vertical travel distance for 1:1 finger tracking
                let totalTravelDistance: CGFloat = max(screenHeight - miniHeight - collapsedBottomOffset, 240)

                MorphingPlayerCard(
                    progress: expansionProgress,
                    track: track,
                    playerService: playerService,
                    libraryStore: libraryStore,
                    palette: palette,
                    backgroundStyle: libraryStore.settings.playerBackgroundStyle,
                    appTheme: libraryStore.settings.appTheme,
                    screenWidth: screenWidth,
                    screenHeight: screenHeight,
                    topSafeArea: topSafeArea,
                    bottomSafeArea: bottomSafeArea,
                    collapsedBottomOffset: collapsedBottomOffset,
                    isExpanded: isExpanded,
                    isDragging: isDragging,
                    canTriggerButtonPress: {
                        canTriggerButtonPress
                    },
                    onTapMiniPlayer: {
                        isCollapsingToMini = false
                        isDragging = false
                        expandPlayer()
                    },
                    onTapCollapse: {
                        collapsePlayer()
                    },
                    onOpenQueue: {
                        guard canTriggerButtonPress else { return }
                        showingQueue = true
                    },
                    onOpenInfo: {
                        guard canTriggerButtonPress else { return }
                        HapticFeedback.lightImpact()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showingFileInfo = true
                        }
                    },
                    onOpenPlayback: {
                        guard canTriggerButtonPress else { return }
                        HapticFeedback.lightImpact()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showingPlaybackSheet = true
                        }
                    },
                    onOpenPlaylistPicker: {
                        guard canTriggerButtonPress else { return }
                        HapticFeedback.lightImpact()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showingPlaylistPicker = true
                        }
                    },
                    onOpenDevicePicker: {
                        guard canTriggerButtonPress else { return }
                        HapticFeedback.lightImpact()
                        RoutePickerManager.shared.presentRoutePicker()
                    },
                    onSelectArtist: { artist in
                        guard canTriggerButtonPress else { return }
                        selectedArtistForNavigation = artist
                    },
                    onSelectAlbum: { album in
                        guard canTriggerButtonPress else { return }
                        selectedAlbumForNavigation = album
                    },
                    onDragChanged: { translation in
                        let deltaY = translation.height
                        let deltaX = translation.width

                        // Only begin driving drag once there is any slight movement (avoids hijacking static taps)
                        guard abs(deltaY) > 0.5 || abs(deltaX) > 0.5 || isDragging else { return }

                        if !isDragging {
                            isDragging = true
                            dragStartProgress = min(1.0, max(0.0, expansionProgress))
                            dragIntent = .undecided
                        }
                        // Lock the fullscreen drag's intent on its first movement.
                        if dragIntent == .undecided && dragStartProgress >= 0.5 {
                            if abs(deltaX) > abs(deltaY) {
                                dragIntent = .horizontal
                            } else {
                                dragIntent = deltaY > 0 ? .dismiss : .queue
                            }
                        }

                        let computed = dragStartProgress - (deltaY / totalTravelDistance)

                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            expansionProgress = min(max(computed, 0.0), 1.0)
                        }
                    },
                    onDragEnded: { translation, predictedEnd in
                        guard isDragging else { return }
                        let intent = dragIntent
                        dragIntent = .undecided
                        let h = translation.height
                        let w = translation.width
                        let predictedH = predictedEnd.height

                        // Horizontal gesture priority for Next/Previous tracks
                        if abs(w) > 45 && abs(w) > abs(h) * 1.5 {
                            if w < -45 {
                                skipNext()
                            } else if w > 45 {
                                skipPrevious()
                            }
                            snapTo(expanded: dragStartProgress > 0.5)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                isDragging = false
                            }
                            return
                        }

                        // Vertical gesture handling with momentum flick support
                        if dragStartProgress < 0.5 {
                            // Started from Miniplayer
                            if h < -25 || predictedH < -50 || expansionProgress > 0.30 {
                                // Upward drag/flick threshold met -> Expand to Fullscreen
                                isCollapsingToMini = false
                                expandPlayer()
                            } else {
                                // Snap back to Miniplayer
                                collapsePlayer()
                            }
                        } else {
                            // Started from Fullscreen or mid-transition
                            if h > 30 || predictedH > 60 || expansionProgress < 0.70 {
                                // Downward drag/flick threshold met -> Collapse to Miniplayer
                                isCollapsingToMini = true
                                collapsePlayer()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                                    isCollapsingToMini = false
                                }
                            } else if intent == .queue && (h < -35 || predictedH < -60) {
                                // Upward swipe while in Fullscreen -> Open Queue!
                                snapTo(expanded: true)
                                showingQueue = true
                            } else {
                                // Snap back to Fullscreen
                                snapTo(expanded: true)
                            }
                        }

                        // Maintain isDragging for 150ms to suppress any button actions fired on touch-release
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            isDragging = false
                        }
                    }
                )
                .environment(\.isPlayerDraggingOrDismissing, isDragging || isCollapsingToMini)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingQueue) {
                PlayerQueueView(playerService: playerService, libraryStore: libraryStore)
            }
            .sheet(isPresented: $showingFileInfo) {
                TrackInfoSheetView(track: track, libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(isPresented: $showingPlaybackSheet) {
                PlaybackControlsSheetView(playerService: playerService, libraryStore: libraryStore)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                playlistPickerSheet(for: track)
            }
            // Modal presentation sheet
            .sheet(item: $selectedArtistForNavigation) { artist in
                NavigationStack {
                    ArtistDetailView(
                        artist: artist,
                        libraryStore: libraryStore,
                        playerService: playerService
                    )
                }
            }
            // Modal presentation sheet
            .sheet(item: $selectedAlbumForNavigation) { album in
                NavigationStack {
                    AlbumDetailView(
                        album: album,
                        libraryStore: libraryStore,
                        playerService: playerService
                    )
                }
            }// Always maintain full-screen frame so geometry and safe area insets NEVER jump during drag or springs.
            // Hit testing is strictly constrained to the card and active backdrop, preserving 100% interactive background taps.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            // Triggered when view appears
            .onAppear {
                isDragging = false
                isCollapsingToMini = false
                expansionProgress = isExpanded ? 1.0 : 0.0
            }
            // React to state changes
            .onChange(of: isExpanded) { _, newValue in
                // Ensure preconditions are met before proceeding
                guard !isDragging else { return }
                if newValue {
                    isCollapsingToMini = false
                }
                // Target
                let target: CGFloat = newValue ? 1.0 : 0.0
                // Ensure preconditions are met before proceeding
                guard expansionProgress != target else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0.08)) {
                    expansionProgress = target
                }
            }
            .onChange(of: playerService.isSeeking) { _, isSeeking in
                if isSeeking && isDragging && isExpanded {
                    isDragging = false
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                        expansionProgress = 1.0
                    }
                }
            }
            // Async lifecycle task
            .task(id: track.artworkKey) {
                // New palette
                let newPalette = await ArtworkColorExtractor.shared.extractPrimaryColor(
                    for: track.artworkKey,
                    fallback: Color(red: 0.16, green: 0.16, blue: 0.18)
                )
                withAnimation(.easeInOut(duration: 0.65)) {
                    self.palette = newPalette
                }
            }
        }
    }

    // MARK: - State Transition Triggers

    // Expand player
    private func expandPlayer() {
        isCollapsingToMini = false
        HapticFeedback.snap(intensity: 0.52)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0.08)) {
            isExpanded = true
            expansionProgress = 1.0
        }
    }

    // Collapse player
    private func collapsePlayer() {
        HapticFeedback.snap(intensity: 0.46)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0.08)) {
            isExpanded = false
            expansionProgress = 0.0
        }
    }

    // Snap to
    private func snapTo(expanded: Bool) {
        HapticFeedback.snap(intensity: expanded ? 0.52 : 0.46)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.08)) {
            isExpanded = expanded
            expansionProgress = expanded ? 1.0 : 0.0
        }
    }

    // Skip next
    private func skipNext() {
        // Ensure preconditions are met before proceeding
        guard playerService.hasNextTrack else { return }
        HapticFeedback.transport(.next)
        playerService.next()
    }

    // Skip previous
    private func skipPrevious() {
        // Ensure preconditions are met before proceeding
        guard playerService.hasPreviousTrack else { return }
        HapticFeedback.transport(.back)
        playerService.previous()
    }

    // Playlist picker sheet
    private func playlistPickerSheet(for track: Track) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: track.artworkKey) { playlist in
            HapticFeedback.notificationSuccess()
            libraryStore.addTrack(track, toPlaylistID: playlist.id)
            showingPlaylistPicker = false
        }
    }
}

// MARK: - Animatable Morphing Player Card

/// Core animatable layout container that drives continuous 120Hz frame interpolation for all dimensions and views.
private struct MorphingPlayerCard: View, Animatable {
    // Progress
    var progress: CGFloat
    // Track
    let track: Track
    // Player service
    let playerService: AudioPlayerService
    // Library store
    let libraryStore: LibraryStore
    let palette: ArtworkColorExtractor.ColorPalette
    // Background style
    let backgroundStyle: PlayerBackgroundStyle
    // App theme
    let appTheme: AppTheme
    // Screen width
    let screenWidth: CGFloat
    // Screen height
    let screenHeight: CGFloat
    // Top safe area
    let topSafeArea: CGFloat
    // Bottom safe area
    let bottomSafeArea: CGFloat
    // Collapsed bottom offset
    let collapsedBottomOffset: CGFloat
    // Flag indicating if expanded
    let isExpanded: Bool
    let isDragging: Bool
    let canTriggerButtonPress: () -> Bool

    // On tap mini player
    let onTapMiniPlayer: () -> Void
    // On tap collapse
    let onTapCollapse: () -> Void
    // Serial queue for on open queue
    let onOpenQueue: () -> Void
    // On open info
    let onOpenInfo: () -> Void
    // On open playlist picker
    let onOpenPlayback: () -> Void
    let onOpenPlaylistPicker: () -> Void
    let onOpenDevicePicker: () -> Void
    // On select artist
    let onSelectArtist: (Artist) -> Void
    // On select album
    let onSelectAlbum: (Album) -> Void
    // On drag changed
    let onDragChanged: (CGSize) -> Void
    // On drag ended
    let onDragEnded: (CGSize, CGSize) -> Void

    // Animatable data
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @State private var isArtworkFlipped: Bool = false
    private var isLyricsViewPreferred: Bool {
        get { libraryStore.settings.isLyricsViewPreferred }
        nonmutating set {
            libraryStore.settings.isLyricsViewPreferred = newValue
            libraryStore.saveSettings()
        }
    }
    @State private var currentTrackHasLyrics: Bool = true
    @State private var isArtworkAnimationEnabled: Bool = true
    @State private var isLyricsExpanded: Bool = false

    private var isLyricsViewActive: Bool {
        isLyricsViewPreferred
    }

    @State private var lyricsGlobalFrame: CGRect = .zero

    // Play/pause morph geometry: mini glyph measured at rest in the card space (per mode),
    // fullscreen glyph measured in the fullscreen layer's own space (per layout, per screen size).
    @State private var miniPlayGlyphIconFrame: CGRect = .zero
    @State private var miniPlayGlyphTextFrame: CGRect = .zero
    @State private var fullPlayGlyphStandardFrame: CGRect = .zero
    @State private var fullPlayGlyphLyricsFrame: CGRect = .zero
    @State private var fullPlayGlyphScreenSize: CGSize = .zero

    private func isLocationInsideLyrics(_ location: CGPoint) -> Bool {
        // If a card drag is already actively ongoing, don't interrupt it
        guard !isDragging else { return false }
        guard isLyricsViewActive && (progress > 0.75 || isExpanded) else { return false }
        if lyricsGlobalFrame != .zero {
            let expandedFrame = lyricsGlobalFrame.insetBy(dx: -4, dy: -4)
            if expandedFrame.contains(location) {
                return true
            }
        }
        let topBoundary = topSafeArea + 50
        let bottomBoundary = isLyricsExpanded ? (screenHeight - 40) : (screenHeight - 160)
        return location.y >= topBoundary && location.y <= bottomBoundary
    }

    @State private var currentPitch: Double = 0.0
    @State private var currentYaw: Double = 0.0
    @State private var currentRoll: Double = 0.0
    @State private var currentElevation: CGFloat = 0.0
    @State private var currentStretchX: CGFloat = 1.0
    @State private var currentStretchY: CGFloat = 1.0
    @State private var isTouchingArtwork: Bool = false
    @State private var touchPitch: Double = 0.0
    @State private var touchYaw: Double = 0.0
    @State private var touchRoll: Double = 0.0
    @State private var touchElevation: CGFloat = 0.0
    @State private var touchScale: CGFloat = 1.0
    @State private var touchStretchX: CGFloat = 1.0
    @State private var touchStretchY: CGFloat = 1.0
    @State private var swayAnimationTask: Task<Void, Never>? = nil

    // Lerp
    private func lerp(start: CGFloat, end: CGFloat, t: CGFloat) -> CGFloat {
        start + (end - start) * max(0.0, min(1.0, t))
    }

    // Body
    var body: some View {
        // Clamped progress
        let clampedProgress = max(0.0, min(1.0, progress))
        // Flag indicating if playing
        let isPlaying = playerService.playbackStatus.isPlaying

        // Dynamic Card Geometry
        // Dynamic Card Geometry
        let miniHeight: CGFloat = 64
        // Card height
        let cardHeight: CGFloat = lerp(start: miniHeight, end: screenHeight, t: clampedProgress)
        // Horizontal margin
        let horizontalMargin: CGFloat = lerp(start: 12, end: 0, t: clampedProgress)
        // Bottom padding
        let bottomPadding: CGFloat = lerp(start: collapsedBottomOffset, end: 0, t: clampedProgress)
        // Card corner radius
        let cardCornerRadius: CGFloat = lerp(start: 16, end: 0, t: clampedProgress)

        // Single Shared Artwork Geometry
        let isArtworkRounded = libraryStore.settings.isArtworkRounded
        let miniArtworkSize: CGFloat = 46
        let miniArtworkCorner: CGFloat = isArtworkRounded ? 10 : 0
        let miniArtworkX: CGFloat = 12
        let miniArtworkY: CGFloat = (miniHeight - miniArtworkSize) / 2 // 9pt centered

        // Full artwork dimension in standard mode vs lyrics header mode
        let fullArtworkDimension: CGFloat = min(screenWidth - 44, screenHeight * 0.42, 350)
        let fullArtworkCorner: CGFloat = isArtworkRounded ? 22 : 0
        let fullArtworkX: CGFloat = (screenWidth - fullArtworkDimension) / 2
        let fullArtworkY: CGFloat = topSafeArea + 70

        // Target coordinates in full screen mode (smoothly adopts top header coordinates in lyrics mode)
        let targetFullArtworkDimension: CGFloat = isLyricsViewActive ? 38 : fullArtworkDimension
        let targetFullArtworkCorner: CGFloat = isArtworkRounded ? (isLyricsViewActive ? 6 : fullArtworkCorner) : 0
        let targetFullArtworkX: CGFloat = isLyricsViewActive ? 20 : fullArtworkX
        let targetFullArtworkY: CGFloat = isLyricsViewActive ? (topSafeArea + 19) : fullArtworkY

        // Current artwork geometry
        let currentArtworkSize: CGFloat = lerp(start: miniArtworkSize, end: targetFullArtworkDimension, t: clampedProgress)
        let currentArtworkCorner: CGFloat = lerp(start: miniArtworkCorner, end: targetFullArtworkCorner, t: clampedProgress)
        let currentArtworkX: CGFloat = lerp(start: miniArtworkX, end: targetFullArtworkX, t: clampedProgress)
        let currentArtworkY: CGFloat = lerp(start: miniArtworkY, end: targetFullArtworkY, t: clampedProgress)

        // Play pause scale
        let playPauseScale: CGFloat = (isPlaying || isLyricsViewActive) ? 1.0 : 0.84
        // Base artwork scale
        let baseArtworkScale: CGFloat = lerp(start: 1.0, end: playPauseScale, t: clampedProgress)
        // Dynamic artwork scale
        let dynamicArtworkScale: CGFloat = isTouchingArtwork ? (baseArtworkScale * touchScale) : baseArtworkScale

        // Continuous Non-Jitter Layer Opacities and Offsets
        let miniOpacity: Double = max(0.0, min(1.0, Double(1.0 - clampedProgress * 2.8)))
        // Full opacity
        let fullOpacity: Double = max(0.0, min(1.0, Double((clampedProgress - 0.18) / 0.78)))
        // Fullscreen layer's transition offset (shared by the layer and the play/pause morph target)
        let fullLayerOffsetY: CGFloat = (1.0 - clampedProgress) * 28

        // Play/pause morph: a single floating glyph replaces the mini and fullscreen buttons mid-transition.
        // Falls back to the plain crossfade when unmeasured, in expanded lyrics, or while a cloud track loads.
        let useIcons = libraryStore.settings.usePlayerIcons
        let miniPlayGlyphFrame: CGRect = useIcons ? miniPlayGlyphIconFrame : miniPlayGlyphTextFrame
        let fullPlayGlyphFrame: CGRect = isLyricsViewActive ? fullPlayGlyphLyricsFrame : fullPlayGlyphStandardFrame
        let canMorphPlayPause: Bool = miniPlayGlyphFrame != .zero
            && fullPlayGlyphFrame != .zero
            && fullPlayGlyphScreenSize == CGSize(width: screenWidth, height: screenHeight)
            && !(isLyricsViewActive && isLyricsExpanded)
            && playerService.cloudWaitTrackID == nil
        let isPlayPauseMorphing: Bool = canMorphPlayPause && clampedProgress > 0.001 && clampedProgress < 0.999

        ZStack(alignment: .bottom) {
            // Backdrop Dimmer (Smoothly dims background content without blocking miniplayer tabs)
            if clampedProgress > 0.05 {
                Color.black
                    .opacity(Double(clampedProgress * 0.48))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTapCollapse()
                    }
                    .allowsHitTesting(clampedProgress > 0.25)
            }

            // Main Card (Transforms smoothly from floating pill to full screen)
            ZStack(alignment: .topLeading) {
                // 1. Unified Dynamic Background
                cardBackground(cornerRadius: cardCornerRadius, progress: clampedProgress)

                // 2. Miniplayer Layer (Always active when collapsed, handles tap-to-expand)
                miniplayerContent(
                    miniArtworkSize: miniArtworkSize,
                    hidesPlayPause: isPlayPauseMorphing,
                    isAtRest: clampedProgress < 0.001
                )
                    .opacity(miniOpacity)
                    .offset(x: -clampedProgress * 24)
                    .allowsHitTesting(clampedProgress < 0.25)
                    .zIndex(2)
                    .onPreferenceChange(MiniPlayGlyphIconFrameKey.self) { frame in
                        if frame != .zero && frame != self.miniPlayGlyphIconFrame {
                            self.miniPlayGlyphIconFrame = frame
                        }
                    }
                    .onPreferenceChange(MiniPlayGlyphTextFrameKey.self) { frame in
                        if frame != .zero && frame != self.miniPlayGlyphTextFrame {
                            self.miniPlayGlyphTextFrame = frame
                        }
                    }

                // 3. Fullscreen Layer (Controls, progress bar, title, queue, lyrics)
                if clampedProgress > 0.01 {
                    fullscreenContent(
                        fullArtworkSize: fullArtworkDimension,
                        progress: clampedProgress,
                        hidesPlayPause: isPlayPauseMorphing
                    )
                    .opacity(fullOpacity)
                    .offset(y: fullLayerOffsetY)
                    .allowsHitTesting(clampedProgress > 0.75)
                    .zIndex(5)
                }

                // 3b. Floating play/pause morph. Driven purely by progress (like the shared artwork), so it
                // follows drags and spring-backs; moves card-space mini center -> fullscreen center and grows.
                if isPlayPauseMorphing {
                    let fullCenterY: CGFloat = fullPlayGlyphFrame.midY + fullLayerOffsetY
                    morphingPlayPauseGlyph(t: clampedProgress, useIcons: useIcons, isPlaying: isPlaying)
                        .position(
                            x: lerp(start: miniPlayGlyphFrame.midX, end: fullPlayGlyphFrame.midX, t: clampedProgress),
                            y: lerp(start: miniPlayGlyphFrame.midY, end: fullCenterY, t: clampedProgress)
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        // Appears/disappears instantly at the hand-offs (never fades in on its own)
                        .transition(.identity)
                        .zIndex(6)
                }

                // 4. SINGLE SHARED ALBUM ARTWORK (Continuous transition in all modes: hero 3D in standard, header in lyrics mode)
                // Effective raw pitch
                let effectiveRawPitch: Double = isTouchingArtwork ? touchPitch : currentPitch
                // Effective raw yaw
                let effectiveRawYaw: Double = isTouchingArtwork ? touchYaw : currentYaw
                // Effective raw roll
                let effectiveRawRoll: Double = isTouchingArtwork ? touchRoll : currentRoll
                // Effective raw elevation
                let effectiveRawElevation: CGFloat = isTouchingArtwork ? touchElevation : currentElevation
                // Effective raw stretch x
                let effectiveRawStretchX: CGFloat = isTouchingArtwork ? touchStretchX : currentStretchX
                // Effective raw stretch y
                let effectiveRawStretchY: CGFloat = isTouchingArtwork ? touchStretchY : currentStretchY

                // Pitch degrees (smoothly adopts 3D pitch, centering cleanly when paused or lyrics active)
                let pitchDegrees: Double = !isLyricsViewActive ? (effectiveRawPitch * Double(clampedProgress)) : 0.0
                // Yaw degrees
                let yawDegrees: Double = !isLyricsViewActive ? (effectiveRawYaw * Double(clampedProgress)) : 0.0
                // Roll degrees
                let rollDegrees: Double = !isLyricsViewActive ? (effectiveRawRoll * Double(clampedProgress)) : 0.0
                // Elevation val
                let elevationVal: CGFloat = !isLyricsViewActive ? (effectiveRawElevation * clampedProgress) : 0.0
                // Stretch x val
                let stretchXVal: CGFloat = !isLyricsViewActive ? (1.0 + (effectiveRawStretchX - 1.0) * clampedProgress) : 1.0
                // Stretch y val
                let stretchYVal: CGFloat = !isLyricsViewActive ? (1.0 + (effectiveRawStretchY - 1.0) * clampedProgress) : 1.0

                // Shadow calculations (gracefully transitions between playing dynamic depth and subtle grounded pause shadow)
                let shadowBaseOpacity: Double = isPlaying ? 0.32 : 0.16
                let shadowBaseRadius: CGFloat = isPlaying ? max(14.0, 24.0 + elevationVal * 1.2) : 10.0
                let shadowOffsetYVal: CGFloat = isPlaying ? (11.5 + pitchDegrees * 1.5 + Double(elevationVal * 0.75)) : 5.0
                let shadowOffsetXVal: CGFloat = isPlaying ? CGFloat((effectiveRawYaw * -1.85 + effectiveRawRoll * 0.7) * Double(clampedProgress)) : 0.0

                let dynamicShadowRadius: CGFloat = !isLyricsViewActive ? lerp(start: 0, end: shadowBaseRadius, t: clampedProgress) : 0
                let dynamicShadowOffsetY: CGFloat = !isLyricsViewActive ? CGFloat(shadowOffsetYVal * Double(clampedProgress)) : 0
                let dynamicShadowOffsetX: CGFloat = !isLyricsViewActive ? shadowOffsetXVal : 0
                let dynamicShadowOpacity: Double = !isLyricsViewActive ? (shadowBaseOpacity * Double(clampedProgress)) : 0

                // 4. SINGLE SHARED ALBUM ARTWORK (Hero continuous transition with subtle 3D floating depth & touch press & 180 flip)
                ZStack {
                    if !isArtworkFlipped {
                        AlbumArtworkView(
                            artworkKey: track.artworkKey,
                            title: track.album,
                            subtitle: track.artist,
                            cornerRadius: currentArtworkCorner,
                            targetDimension: 1200,
                            isOriginalResolution: true
                        )
                        .clipShape(RoundedRectangle(cornerRadius: currentArtworkCorner, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: currentArtworkCorner, style: .continuous))
                        .onTapGesture {
                            guard canTriggerButtonPress() else { return }
                            if clampedProgress < 0.25 {
                                onTapMiniPlayer()
                            } else if isLyricsViewActive {
                                HapticFeedback.lightImpact()
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                    isLyricsViewPreferred = false
                                }
                            } else if clampedProgress > 0.85 {
                                HapticFeedback.cardFlip()
                                withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                                    isArtworkFlipped = true
                                }
                            }
                        }
                    } else {
                        artworkBackView(dimension: currentArtworkSize)
                            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                    }
                }
                .frame(width: currentArtworkSize, height: currentArtworkSize)
                // Multi-tier 3D Floating Shadows (Active in standard mode, subtle in lyrics mode)
                .shadow(
                    color: Color.black.opacity(dynamicShadowOpacity),
                    radius: dynamicShadowRadius,
                    x: dynamicShadowOffsetX,
                    y: dynamicShadowOffsetY
                )
                .shadow(
                    color: Color.black.opacity(dynamicShadowOpacity * 0.5),
                    radius: !isLyricsViewActive ? lerp(start: 0, end: isPlaying ? 12 : 5, t: clampedProgress) : 0,
                    x: dynamicShadowOffsetX * 0.5,
                    y: dynamicShadowOffsetY * 0.6
                )
                // Floating vertical altitude bob
                .offset(y: elevationVal)
                // Subtle natural 2D roll tilt
                .rotationEffect(.degrees((isArtworkAnimationEnabled && !isLyricsViewActive) ? rollDegrees : 0))
                // Natural 3D Pitch (X-axis)
                .rotation3DEffect(
                    .degrees(isArtworkFlipped ? 180 : ((isArtworkAnimationEnabled && !isLyricsViewActive) ? pitchDegrees : 0)),
                    axis: (x: isArtworkFlipped ? 0 : 1.0, y: isArtworkFlipped ? 1.0 : 0.0, z: 0.0),
                    anchor: .center,
                    perspective: 0.55
                )
                // Natural 3D Yaw (Y-axis)
                .rotation3DEffect(
                    .degrees(isArtworkFlipped ? 0 : ((isArtworkAnimationEnabled && !isLyricsViewActive) ? yawDegrees : 0)),
                    axis: (x: 0.0, y: 1.0, z: 0.0),
                    anchor: .center,
                    perspective: 0.55
                )
                // Subtle organic stretch elasticity
                .scaleEffect(
                    x: (isArtworkAnimationEnabled && !isLyricsViewActive) ? stretchXVal : 1.0,
                    y: (isArtworkAnimationEnabled && !isLyricsViewActive) ? stretchYVal : 1.0,
                    anchor: .center
                )
                // Dynamic Play/Pause Spring Scale Effect
                .scaleEffect(dynamicArtworkScale, anchor: .center)
                .animation(.spring(response: 0.38, dampingFraction: 0.74), value: isPlaying)
                // Interactive drag and touch gesture handling
                .gesture(
                    LongPressGesture(minimumDuration: 1.0)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onChanged { value in
                            guard clampedProgress > 0.75 && !isArtworkFlipped && !isLyricsViewActive && !isDragging else { return }
                            switch value {
                            case .second(true, let drag):
                                if let drag = drag {
                                    handleArtworkTouch(location: drag.location, dimension: currentArtworkSize)
                                }
                            default:
                                break
                            }
                        }
                        .onEnded { value in
                            guard clampedProgress > 0.75 && !isArtworkFlipped && !isLyricsViewActive && !isDragging else { return }
                            switch value {
                            case .second(true, _):
                                handleArtworkTouchEnded()
                            default:
                                if isTouchingArtwork {
                                    handleArtworkTouchEnded()
                                }
                            }
                        }
                )
                .position(
                    x: currentArtworkX + currentArtworkSize / 2,
                    y: currentArtworkY + currentArtworkSize / 2
                )
                .zIndex(10)
            }
            .coordinateSpace(.named(playerCardMorphSpace))
            .frame(width: screenWidth - (horizontalMargin * 2), height: cardHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .shadow(
                color: Color.black.opacity(lerp(start: 0.16, end: 0.38, t: clampedProgress)),
                radius: lerp(start: 10, end: 26, t: clampedProgress),
                x: 0,
                y: lerp(start: 4, end: 12, t: clampedProgress)
            )
            .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            // Interactive drag gesture (minimum 8pt threshold prevents interfering with tap gestures)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { value in
                        // Ensure preconditions are met before proceeding
                        guard !isTouchingArtwork else { return }
                        guard !playerService.isSeeking else { return }
                        guard !isLocationInsideLyrics(value.startLocation) else { return }
                        onDragChanged(value.translation)
                    }
                    .onEnded { value in
                        // Ensure preconditions are met before proceeding
                        guard !isTouchingArtwork else { return }
                        guard !playerService.isSeeking else { return }
                        guard !isLocationInsideLyrics(value.startLocation) else { return }
                        onDragEnded(value.translation, value.predictedEndTranslation)
                    }
            )
            .onPreferenceChange(LyricsGlobalFramePreferenceKey.self) { frame in
                self.lyricsGlobalFrame = frame
            }
            .padding(.horizontal, horizontalMargin)
            .padding(.bottom, bottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Triggered when view appears
        .onAppear {
            start3DFloatingAnimationLoop()
        }
        // Triggered when view disappears
        .onDisappear {
            swayAnimationTask?.cancel()
            currentPitch = 0.0
            currentYaw = 0.0
            currentRoll = 0.0
            currentElevation = 0.0
            currentStretchX = 1.0
            currentStretchY = 1.0
            isTouchingArtwork = false
            touchPitch = 0.0
            touchYaw = 0.0
            touchRoll = 0.0
            touchElevation = 0.0
            touchScale = 1.0
            touchStretchX = 1.0
            touchStretchY = 1.0
        }
        // React to state changes
        .onChange(of: playerService.playbackStatus.isPlaying) { _, isPlaying in
            if isPlaying {
                start3DFloatingAnimationLoop()
            } else {
                swayAnimationTask?.cancel()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    currentPitch = 0.0
                    currentYaw = 0.0
                    currentRoll = 0.0
                    currentElevation = 0.0
                    currentStretchX = 1.0
                    currentStretchY = 1.0
                    isTouchingArtwork = false
                    touchPitch = 0.0
                    touchYaw = 0.0
                    touchRoll = 0.0
                    touchElevation = 0.0
                    touchScale = 1.0
                    touchStretchX = 1.0
                    touchStretchY = 1.0
                }
            }
        }
        .task(id: track.id) {
            await checkLyricsAvailabilityForCurrentTrack()
        }
        // React to state changes
        .onChange(of: track.id) { _, _ in
            if playerService.playbackStatus.isPlaying {
                start3DFloatingAnimationLoop()
            }
        }
        // React to state changes
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                isArtworkFlipped = false
                isLyricsExpanded = false
                swayAnimationTask?.cancel()
            } else if playerService.playbackStatus.isPlaying && isArtworkAnimationEnabled {
                start3DFloatingAnimationLoop()
            }
        }
        .onChange(of: isLyricsViewActive) { _, active in
            if !active {
                isLyricsExpanded = false
            }
        }
        .onChange(of: playerService.currentTrack?.id) { _, _ in
            isLyricsExpanded = false
        }
    }

    // MARK: - Interactive 3D Touch Down & Torque Physics

    // Handle artwork touch
    private func handleArtworkTouch(location: CGPoint, dimension: CGFloat) {
        // Center x
        let centerX = dimension / 2.0
        // Center y
        let centerY = dimension / 2.0

        // Norm x
        let normX = max(-1.0, min(1.0, (location.x - centerX) / (dimension / 2.0)))
        // Norm y
        let normY = max(-1.0, min(1.0, (location.y - centerY) / (dimension / 2.0)))

        if !isTouchingArtwork {
            isTouchingArtwork = true
            HapticFeedback.dragPickup()
        }

        // Max angle
        let maxAngle: Double = 12.0
        // Calculated pitch
        let calculatedPitch = -Double(normY) * maxAngle
        // Calculated yaw
        let calculatedYaw = Double(normX) * maxAngle
        // Calculated roll
        let calculatedRoll = Double(normX * normY) * -2.8

        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.72, blendDuration: 0.08)) {
            touchPitch = calculatedPitch
            touchYaw = calculatedYaw
            touchRoll = calculatedRoll
            touchElevation = -4.5
            touchScale = 0.965
            touchStretchX = 1.0 - abs(normX) * 0.015
            touchStretchY = 1.0 - abs(normY) * 0.015
        }
    }

    // Handle artwork touch ended
    private func handleArtworkTouchEnded() {
        // Ensure preconditions are met before proceeding
        guard isTouchingArtwork else { return }

        // Retain the tilted touch pose in the main rotation state so the cover stays in this position
        currentPitch = touchPitch
        currentYaw = touchYaw
        currentRoll = touchRoll
        currentElevation = touchElevation
        currentStretchX = touchStretchX
        currentStretchY = touchStretchY

        isTouchingArtwork = false

        // Smoothly restore touch scale cushion with a soft spring without resetting angles
        withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) {
            touchScale = 1.0
            currentElevation = 0.0
        }
    }

    // MARK: - Dynamic Multi-Directional 3D Floating Engine (Sides, Corners, 2D Roll, Variable Pitches)

    // Start 3 d floating animation loop
    private func start3DFloatingAnimationLoop() {
        swayAnimationTask?.cancel()
        guard isExpanded && playerService.playbackStatus.isPlaying && isArtworkAnimationEnabled else {
            currentPitch = 0.0
            currentYaw = 0.0
            currentRoll = 0.0
            currentElevation = 0.0
            currentStretchX = 1.0
            currentStretchY = 1.0
            return
        }
        swayAnimationTask = Task { @MainActor in
            // 1. Initial 1.5-second delay when opening or starting playback with perfectly centered artwork
            withAnimation(.easeInOut(duration: 0.45)) {
                currentPitch = 0.0
                currentYaw = 0.0
                currentRoll = 0.0
                currentElevation = 0.0
                currentStretchX = 1.0
                currentStretchY = 1.0
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled || !isExpanded || !playerService.playbackStatus.isPlaying { return }

            // Infinite continuous fluid wander loop
            while !Task.isCancelled && isExpanded && playerService.playbackStatus.isPlaying {
                if isTouchingArtwork {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                // 1. Active wander phase duration: 4 to 7 seconds
                let activePhaseTargetDuration = Double.random(in: 4.0...7.0)
                // Phase start time
                let phaseStartTime = Date()

                while !Task.isCancelled && isExpanded && playerService.playbackStatus.isPlaying && Date().timeIntervalSince(phaseStartTime) < activePhaseTargetDuration {
                    if isTouchingArtwork {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }

                    // Weighted pose selection: 45% subtle free wander, 35% corner/side tilts, 20% deep pitch
                    let poseRoll = Double.random(in: 0.0...1.0)
                    // Pose type
                    let poseType: Int
                    if poseRoll < 0.45 {
                        poseType = 3 // Asymmetric Free Wander
                    } else if poseRoll < 0.80 {
                        poseType = Bool.random() ? 0 : 1 // Corner or Side Tilt
                    } else {
                        poseType = 2 // Deep Pitch
                    }

                    // Non-linear power distribution prioritizing smaller, subtle baseline movements (~75% gentle, ~25% bold)
                    let rawDistribution = Double.random(in: 0.0...1.0)
                    // Biased factor
                    let biasedFactor = pow(rawDistribution, 2.2)
                    // Strength
                    let strength = 0.22 + biasedFactor * 1.28

                    // Target pitch
                    var targetPitch: Double = 0.0
                    // Target yaw
                    var targetYaw: Double = 0.0
                    // Target roll
                    var targetRoll: Double = 0.0
                    // Target elevation
                    var targetElevation: CGFloat = 0.0

                    switch poseType {
                    case 0:
                        // Corner Tilt (Top-Left, Top-Right, Bottom-Left, Bottom-Right)
                        let isTop = Bool.random()
                        // Flag indicating if left
                        let isLeft = Bool.random()
                        // Pitch mag
                        let pitchMag = Double.random(in: 3.5...6.5) * strength
                        // Yaw mag
                        let yawMag = Double.random(in: 3.5...6.2) * strength
                        // Roll mag
                        let rollMag = Double.random(in: 1.0...2.2) * strength

                        targetPitch = isTop ? -pitchMag * 0.75 : pitchMag
                        targetYaw = isLeft ? yawMag : -yawMag
                        targetRoll = (isTop == isLeft) ? rollMag : -rollMag
                        targetElevation = CGFloat.random(in: (-3.5)...3.5) * strength

                    case 1:
                        // Side Tilt (Left or Right edge lifted)
                        let isLeft = Bool.random()
                        targetPitch = Double.random(in: 1.5...4.0) * strength
                        targetYaw = (isLeft ? 1.0 : -1.0) * Double.random(in: 4.5...7.5) * strength
                        targetRoll = (isLeft ? -1.0 : 1.0) * Double.random(in: 1.2...2.4) * strength
                        targetElevation = CGFloat.random(in: (-2.8)...2.8) * strength

                    case 2:
                        // Deep Pitch (Top edge lifted or bottom dipped)
                        let isForward = Bool.random()
                        targetPitch = (isForward ? 1.0 : -0.6) * Double.random(in: 4.8...8.2) * strength
                        targetYaw = Double.random(in: (-3.0)...3.0) * strength
                        targetRoll = Double.random(in: (-1.0)...1.0) * strength
                        targetElevation = CGFloat.random(in: (-3.0)...3.0) * strength

                    default:
                        // Asymmetric Free Wander (Gentle calm baseline)
                        targetPitch = Double.random(in: 1.8...5.2) * strength
                        targetYaw = Double.random(in: (-5.0)...5.0) * strength
                        targetRoll = Double.random(in: (-1.5)...1.5) * strength
                        targetElevation = CGFloat.random(in: (-2.5)...2.5) * strength
                    }

                    // Subtle organic stretch elasticity responding to 3D corner/side momentum & strength (more pronounced on rare big moves)
                    let stretchXCalc = 1.0 + (abs(targetYaw) / 8.0) * 0.018 * min(1.2, strength) - (abs(targetPitch) / 9.0) * 0.008 * min(1.2, strength)
                    // Stretch y calc
                    let stretchYCalc = 1.0 + (abs(targetPitch) / 9.0) * 0.016 * min(1.2, strength) - (abs(targetYaw) / 8.0) * 0.008 * min(1.2, strength)

                    // Paced waypoint interval (1.15s to 1.75s) with seamless easeInOut deceleration
                    let stepDuration = Double.random(in: 1.15...1.75)

                    if !isTouchingArtwork {
                        withAnimation(.easeInOut(duration: stepDuration)) {
                            currentPitch = targetPitch
                            currentYaw = targetYaw
                            currentRoll = targetRoll
                            currentElevation = targetElevation
                            currentStretchX = max(0.980, min(1.022, CGFloat(stretchXCalc)))
                            currentStretchY = max(0.980, min(1.022, CGFloat(stretchYCalc)))
                        }
                    }

                    try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
                    if Task.isCancelled || !playerService.playbackStatus.isPlaying { break }
                }

                if Task.isCancelled || !playerService.playbackStatus.isPlaying { break }

                // 2. Return to center every 4-7 seconds for exactly 2.0 seconds (smooth 1.15s glide + 0.85s centered rest)
                if !isTouchingArtwork {
                    // Center glide duration
                    let centerGlideDuration: Double = 1.15
                    withAnimation(.easeInOut(duration: centerGlideDuration)) {
                        currentPitch = 0.0
                        currentYaw = 0.0
                        currentRoll = 0.0
                        currentElevation = 0.0
                        currentStretchX = 1.0
                        currentStretchY = 1.0
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                if Task.isCancelled || !playerService.playbackStatus.isPlaying { break }
            }

            // Clean reset to level center on cancellation or pause
            withAnimation(.easeInOut(duration: 0.5)) {
                currentPitch = 0.0
                currentYaw = 0.0
                currentRoll = 0.0
                currentElevation = 0.0
                currentStretchX = 1.0
                currentStretchY = 1.0
            }
        }
    }

    // MARK: - Card Background

    // Card background (Smooth In-Place Crossfade & Blend Transition)
    private func cardBackground(cornerRadius: CGFloat, progress: CGFloat) -> some View {
        let style = backgroundStyle

        return ZStack {
            // Card-sized base keeps the card's layout unchanged; the background is laid out once at full-screen size,
            // anchored to the card's top, and only clipped by the card. The miniplayer shows the top of the same
            // background, and expanding reveals the rest, so it never rescales or re-blurs during the transition.
            // Inputs are constant so the blur is not re-rendered per animation frame.
            Color.clear
                .overlay(alignment: .top) {
                    PlayerBackgroundView(
                        style: style,
                        appTheme: appTheme,
                        primaryColor: palette.primaryColor,
                        artworkKey: track.artworkKey,
                        cornerRadius: 0,
                        overlayOpacity: 0.50
                    )
                    .frame(width: screenWidth, height: screenHeight)
                    // Oversized layer: clipping doesn't limit hit testing, so keep it from catching taps outside the card
                    .allowsHitTesting(false)
                }

            // Border highlight
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(max(0.0, 0.14 * Double(1.0 - progress))), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Miniplayer Layer

    // Miniplayer content
    private func miniplayerContent(miniArtworkSize: CGFloat, hidesPlayPause: Bool, isAtRest: Bool) -> some View {
        HStack(spacing: 12) {
            // Tappable leading area to expand player
            HStack(spacing: 12) {
                // Space reserved for the shared artwork
                Color.clear
                    .frame(width: miniArtworkSize, height: miniArtworkSize)

                // Track Title & Artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTapMiniPlayer()
            }

            // Play / Pause Button with immediate zero-latency touch delivery
            Button(action: {
                guard canTriggerButtonPress() else { return }
                HapticFeedback.transport(playerService.willPauseOnToggle ? .pause : .play)
                playerService.togglePlayPause()
            }) {
                Group {
                    if libraryStore.settings.usePlayerIcons {
                        // Icons mode: the icon's right edge sits exactly where the centered "PAUSE" text's right edge
                        // would be (invisible same-font reference), so switching modes doesn't move the control's edge.
                        ZStack(alignment: .trailing) {
                            Text("PAUSE")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .hidden()

                            ZStack {
                                Image(systemName: playerService.playbackStatus.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20, weight: .black))
                                    .foregroundStyle(Color.white)
                                    .id(playerService.playbackStatus.isPlaying)
                                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            }
                            .animation(.easeInOut(duration: 0.2), value: playerService.playbackStatus.isPlaying)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: MiniPlayGlyphIconFrameKey.self,
                                        value: isAtRest ? proxy.frame(in: .named(playerCardMorphSpace)) : .zero
                                    )
                                }
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(playerService.playbackStatus.isPlaying ? "Pause" : "Play")
                    } else {
                        Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .contentTransition(.interpolate)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: MiniPlayGlyphTextFrameKey.self,
                                        value: isAtRest ? proxy.frame(in: .named(playerCardMorphSpace)) : .zero
                                    )
                                }
                            )
                    }
                }
                // Hidden (instantly) while the floating morph glyph stands in for it
                .opacity(hidesPlayPause ? 0 : 1)
                .animation(nil, value: hidesPlayPause)
                .frame(width: 58, height: 36, alignment: .center)
                .contentShape(Rectangle())
                // Lay out and move as one unit with the card so nothing inside can jump during expansion
                .geometryGroup()
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .frame(height: 64)
    }

    // MARK: - Fullscreen Layer

    // Fullscreen content
    private func fullscreenContent(fullArtworkSize: CGFloat, progress: CGFloat, hidesPlayPause: Bool) -> some View {
        VStack(spacing: 0) {
            // 1. Top Navigation Bar
            topBar()
                .padding(.top, topSafeArea + 6)
                .zIndex(20)

            if isLyricsViewActive {
                // MARK: - Lyrics Mode Layout with Floating Glass Layer
                ZStack(alignment: .bottom) {
                    // Underlying Bottom Controls Deck
                    VStack(spacing: 12) {
                        Spacer()

                        PlaybackProgressBar(
                            playerService: playerService,
                            foregroundColor: Color.white,
                            secondaryForegroundColor: Color.white.opacity(0.65),
                            style: .fullscreen,
                            useProgressBar: libraryStore.settings.useProgressBar,
                            onCollapse: onTapCollapse
                        )
                        .padding(.horizontal, 28)

                        PlayerControlsView(
                            playerService: playerService,
                            foregroundColor: Color.white,
                            secondaryForegroundColor: Color.white.opacity(0.65),
                            canPerformAction: canTriggerButtonPress,
                            useIcons: libraryStore.settings.usePlayerIcons,
                            hidesPlayPauseGlyph: hidesPlayPause
                        )
                        .onPreferenceChange(PlayerPlayPauseGlyphFrameKey.self) { frame in
                            recordFullPlayGlyphFrame(frame, isLyricsLayout: true)
                        }
                        .padding(.vertical, 4)

                        // Bottom Action Bar (QUEUE on left, Audio Route on right)
                        HStack(spacing: 24) {
                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                onOpenQueue()
                            }) {
                                Group {
                                    if libraryStore.settings.usePlayerIcons {
                                        Image(systemName: "arrow.up.and.down.text.horizontal")
                                            .font(.system(size: 18, weight: .semibold))
                                            .frame(minWidth: 54, alignment: .leading)
                                            .accessibilityLabel("Queue")
                                    } else {
                                        HStack(spacing: 6) {
                                            Text("QUEUE")
                                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            Text("↑")
                                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        }
                                    }
                                }
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            AirPlayButtonView(
                                routeName: playerService.currentAudioRouteName,
                                foregroundColor: Color.white,
                                onTap: onOpenDevicePicker,
                                useIcon: libraryStore.settings.usePlayerIcons
                            )
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, max(bottomSafeArea, 16) + 12)
                    }
                    .opacity(max(0.0, min(1.0, Double((progress - 0.35) / 0.60))))
                    .zIndex(1)

                    // Central Lyrics View (Floating Glass on top when expanded)
                    LyricsPlayerView(
                        playerService: playerService,
                        rawLyrics: track.lyrics,
                        trackURL: track.url,
                        isVisible: isExpanded,
                        duration: track.duration,
                        foregroundColor: Color.white,
                        secondaryForegroundColor: Color.white.opacity(0.65),
                        onSeek: { targetTime in
                            HapticFeedback.scrubCommit()
                            playerService.seek(to: targetTime)
                        },
                        onLyricsAvailabilityChanged: { hasLyrics in
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                currentTrackHasLyrics = hasLyrics
                            }
                        },
                        onExpansionChanged: { expanded in
                            withAnimation(.spring(response: 0.40, dampingFraction: 0.86)) {
                                isLyricsExpanded = expanded
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(max(0.0, min(1.0, Double((progress - 0.20) / 0.70))))
                    .zIndex(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                // MARK: - Standard FullScreen Player Layout
                // Space reserved for hero artwork
                Color.clear
                    .frame(width: fullArtworkSize, height: fullArtworkSize)
                    .padding(.top, 28)

                Spacer(minLength: 8)

                // 2. Track Title & Artist Subtitle with clickable multi-artists
                VStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    if let cloudError = playerService.cloudPlaybackError {
                        Text(cloudError.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    MultiArtistButtonsView(
                        rawArtist: track.artist,
                        joinedArtists: libraryStore.settings.joinedArtists,
                        font: .system(size: 16, weight: .medium),
                        foregroundColor: Color.white.opacity(0.85),
                        separatorColor: Color.white.opacity(0.60),
                        lineLimit: 1,
                        onSelectArtist: { artistName in
                            if let artistObj = libraryStore.findArtist(name: artistName) {
                                onSelectArtist(artistObj)
                            }
                        }
                    )
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 12)

                // 3. Interactive Seek Scrubber with Audio Specs under needle
                PlaybackProgressBar(
                    playerService: playerService,
                    foregroundColor: Color.white,
                    secondaryForegroundColor: Color.white.opacity(0.65),
                    style: .fullscreen,
                    audioSpecs: libraryStore.settings.showAudioSpecsInPlayer ? track.technicalSummary : nil,
                    useProgressBar: libraryStore.settings.useProgressBar,
                    onCollapse: onTapCollapse
                )
                .padding(.horizontal, 28)

                Spacer(minLength: 12)

                // 4. Pure Text Controls Deck
                PlayerControlsView(
                    playerService: playerService,
                    foregroundColor: Color.white,
                    secondaryForegroundColor: Color.white.opacity(0.65),
                    canPerformAction: canTriggerButtonPress,
                    useIcons: libraryStore.settings.usePlayerIcons,
                    hidesPlayPauseGlyph: hidesPlayPause
                )
                .onPreferenceChange(PlayerPlayPauseGlyphFrameKey.self) { frame in
                    recordFullPlayGlyphFrame(frame, isLyricsLayout: false)
                }
                .padding(.vertical, 4)

                Spacer(minLength: 12)

                // Bottom Action Bar (QUEUE on left, Audio Route on right)
                HStack(spacing: 24) {
                    Button(action: {
                        guard canTriggerButtonPress() else { return }
                        onOpenQueue()
                    }) {
                        Group {
                            if libraryStore.settings.usePlayerIcons {
                                Image(systemName: "arrow.up.and.down.text.horizontal")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(minWidth: 54, alignment: .leading)
                                    .accessibilityLabel("Queue")
                            } else {
                                HStack(spacing: 6) {
                                    Text("QUEUE")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    Text("↑")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                }
                            }
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            guard canTriggerButtonPress() else { return }
                            onOpenQueue()
                        }
                    )

                    Spacer()

                    AirPlayButtonView(
                        routeName: playerService.currentAudioRouteName,
                        foregroundColor: Color.white,
                        onTap: onOpenDevicePicker,
                        useIcon: libraryStore.settings.usePlayerIcons
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, max(bottomSafeArea, 16) + 12)
            }
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .top)
        .coordinateSpace(.named(PlayerMorphSpace.fullscreen))
        .overlay {
            if isArtworkFlipped {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard canTriggerButtonPress() else { return }
                        HapticFeedback.cardFlip()
                        withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                            isArtworkFlipped = false
                        }
                    }
            }
        }
    }

    // MARK: - Play/Pause Morph

    // Stores the fullscreen play/pause glyph frame for the layout it came from; a screen size change
    // invalidates both layouts so a stale target is never used.
    private func recordFullPlayGlyphFrame(_ frame: CGRect, isLyricsLayout: Bool) {
        guard frame != .zero else { return }
        let size = CGSize(width: screenWidth, height: screenHeight)
        if fullPlayGlyphScreenSize != size {
            fullPlayGlyphScreenSize = size
            fullPlayGlyphStandardFrame = .zero
            fullPlayGlyphLyricsFrame = .zero
        }
        if isLyricsLayout {
            if fullPlayGlyphLyricsFrame != frame { fullPlayGlyphLyricsFrame = frame }
        } else {
            if fullPlayGlyphStandardFrame != frame { fullPlayGlyphStandardFrame = frame }
        }
    }

    // Floating play/pause glyph. Icons: symbol size is interpolated (20 -> 50; symbols scale proportionally).
    // Text: laid out once at the fullscreen 34pt size and scaled (12/34 -> 1) so it never re-lays out per frame
    // (per-size tracking and pixel snapping made it wobble); scaleEffect stays crisp without drawingGroup.
    @ViewBuilder
    private func morphingPlayPauseGlyph(t: CGFloat, useIcons: Bool, isPlaying: Bool) -> some View {
        if useIcons {
            ZStack {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: lerp(start: 20, end: 50, t: t), weight: .black))
                    .foregroundStyle(Color.white)
                    .id(isPlaying)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            .animation(.easeInOut(duration: 0.2), value: isPlaying)
        } else {
            Text(isPlaying ? "PAUSE" : "PLAY")
                .font(.system(size: 34, weight: .black, design: .monospaced))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.identity)
                .scaleEffect(lerp(start: 12, end: 34, t: t) / 34, anchor: .center)
        }
    }

    // Top bar
    private func topBar() -> some View {
        VStack(spacing: 8) {
            // Pull Grab Bar (Tap or drag down to minimize)
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 38, height: 5)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture().onEnded {
                        onTapCollapse()
                    }
                )

            ZStack {
                if isLyricsViewActive {
                    // Lyrics Mode Header: Space reserved for single shared artwork on left, title & artist next to it, trailing controls on right
                    HStack(spacing: 12) {
                        // Invisible placeholder reserving space for the single shared artwork
                        Color.clear
                            .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)

                            Text(track.artist)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.75))
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(.trailing, 60)
                    .transition(.opacity)
                } else {
                    // Standard Centered Title Header with clickable album name
                    VStack(spacing: 2) {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.65))

                        Button(action: {
                            guard canTriggerButtonPress() else { return }
                            HapticFeedback.lightImpact()
                            if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                                onSelectAlbum(albumObj)
                            }
                        }) {
                            Text(track.album)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.70)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                HapticFeedback.notificationSuccess()
                                playAlbumNext(for: track)
                            } label: {
                                Text("PLAY ALBUM NEXT")
                            }
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                guard canTriggerButtonPress() else { return }
                                HapticFeedback.lightImpact()
                                if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                                    onSelectAlbum(albumObj)
                                }
                            }
                        )
                    }
                    .padding(.horizontal, 64)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
                }

                // Trailing Controls: Previous / Play-Pause / Next when lyrics are active AND expanded, otherwise INFO Menu Button
                HStack {
                    Spacer()

                    if isLyricsViewActive && isLyricsExpanded {
                        // Same symbols and states as the player's icons mode (PlayerControlsView), at header size
                        HStack(spacing: 22) {
                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                guard playerService.hasPreviousTrack else { return }
                                HapticFeedback.transport(.back)
                                playerService.previous()
                            }) {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(
                                        playerService.hasPreviousTrack
                                            ? Color.white
                                            : Color.white.opacity(0.65).opacity(0.3)
                                    )
                                    .accessibilityLabel("Previous Track")
                            }
                            .buttonStyle(.plain)
                            .disabled(!playerService.hasPreviousTrack)

                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                HapticFeedback.transport(playerService.willPauseOnToggle ? .pause : .play)
                                playerService.togglePlayPause()
                            }) {
                                // In-place crossfade with a subtle scale (~0.2s) between play and pause, as in icons mode
                                ZStack {
                                    Image(systemName: playerService.playbackStatus.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 21, weight: .black))
                                        .foregroundStyle(Color.white)
                                        .id(playerService.playbackStatus.isPlaying)
                                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                                }
                                .animation(.easeInOut(duration: 0.2), value: playerService.playbackStatus.isPlaying)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(playerService.playbackStatus.isPlaying ? "Pause" : "Play")
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                guard playerService.hasNextTrack else { return }
                                HapticFeedback.transport(.next)
                                playerService.next()
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(
                                        playerService.hasNextTrack
                                            ? Color.white
                                            : Color.white.opacity(0.65).opacity(0.3)
                                    )
                                    .accessibilityLabel("Next Track")
                            }
                            .buttonStyle(.plain)
                            .disabled(!playerService.hasNextTrack)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else {
                        Menu {
                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                onOpenPlayback()
                            }) {
                                Text("PLAYBACK")
                            }
                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                onOpenPlaylistPicker()
                            }) {
                                Text("ADD TO PLAYLIST")
                            }
                            Button(action: {
                                guard canTriggerButtonPress() else { return }
                                onOpenInfo()
                            }) {
                                Text("FILE INFO")
                            }
                        } label: {
                            Text("i")
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityLabel("Info")
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func playAlbumNext(for track: Track) {
        let albumTracks: [Track]
        if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist), !albumObj.tracks.isEmpty {
            albumTracks = albumObj.tracks
        } else {
            let matched = libraryStore.tracks.filter {
                $0.album.localizedCaseInsensitiveCompare(track.album) == .orderedSame &&
                ($0.artist.localizedCaseInsensitiveCompare(track.artist) == .orderedSame ||
                 $0.albumArtist?.localizedCaseInsensitiveCompare(track.artist) == .orderedSame)
            }
            albumTracks = matched.isEmpty ? libraryStore.tracks.filter {
                $0.album.localizedCaseInsensitiveCompare(track.album) == .orderedSame
            } : matched
        }
        guard !albumTracks.isEmpty else { return }
        playerService.insertPlayNextFront(tracks: albumTracks)
    }

    // MARK: - Artwork Back View

    private func artworkBackView(dimension: CGFloat) -> some View {
        VStack(spacing: 26) {
            Spacer()

            // 1. LYRICS Button (Large text, no background, theme accent color when enabled)
            Button(action: {
                guard canTriggerButtonPress() else { return }
                HapticFeedback.modeToggle(isOn: !isLyricsViewPreferred)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    isLyricsViewPreferred.toggle()
                    if isLyricsViewPreferred {
                        currentTrackHasLyrics = true
                        isArtworkFlipped = false
                    }
                }
            }) {
                Text("LYRICS")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(isLyricsViewPreferred ? libraryStore.settings.appTheme.accentColor : Color.white.opacity(0.40))
            }
            .buttonStyle(.plain)

            // 2. ANIMATE ARTWORK Toggle Button (Large text, no background)
            Button(action: {
                guard canTriggerButtonPress() else { return }
                HapticFeedback.modeToggle(isOn: !isArtworkAnimationEnabled)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isArtworkAnimationEnabled.toggle()
                    if !isArtworkAnimationEnabled {
                        swayAnimationTask?.cancel()
                        currentPitch = 0.0
                        currentYaw = 0.0
                        currentRoll = 0.0
                        currentElevation = 0.0
                        currentStretchX = 1.0
                        currentStretchY = 1.0
                    } else if playerService.playbackStatus.isPlaying {
                        start3DFloatingAnimationLoop()
                    }
                }
            }) {
                Text("ANIMATE ARTWORK")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(isArtworkAnimationEnabled ? libraryStore.settings.appTheme.accentColor : Color.white.opacity(0.40))
            }
            .buttonStyle(.plain)

            // 3. BACKGROUND Picker (Large text, gray when unselected, white when selected)
            VStack(spacing: 12) {
                Text("BACKGROUND")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.40))

                HStack(spacing: 14) {
                    ForEach(PlayerBackgroundStyle.allCases, id: \.self) { style in
                        Button(action: {
                            guard canTriggerButtonPress() else { return }
                            HapticFeedback.selectionChanged()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                libraryStore.settings.playerBackgroundStyle = style
                                libraryStore.saveSettings()
                            }
                        }) {
                            Text(style.displayName.uppercased())
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(
                                    libraryStore.settings.playerBackgroundStyle == style ?
                                        libraryStore.settings.appTheme.accentColor :
                                        Color.white.opacity(0.35)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 4. ROUNDED and ICONS Toggle Buttons (rounded artwork; icon controls in the fullscreen player)
            HStack(spacing: 24) {
                Button(action: {
                    guard canTriggerButtonPress() else { return }
                    HapticFeedback.modeToggle(isOn: !libraryStore.settings.isArtworkRounded)
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                        libraryStore.settings.isArtworkRounded.toggle()
                        libraryStore.saveSettings()
                    }
                }) {
                    Text("ROUNDED")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.isArtworkRounded ? libraryStore.settings.appTheme.accentColor : Color.white.opacity(0.40))
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: {
                    guard canTriggerButtonPress() else { return }
                    HapticFeedback.modeToggle(isOn: !libraryStore.settings.usePlayerIcons)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        libraryStore.settings.usePlayerIcons.toggle()
                        libraryStore.saveSettings()
                    }
                }) {
                    Text("ICONS")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.usePlayerIcons ? libraryStore.settings.appTheme.accentColor : Color.white.opacity(0.40))
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Flip back prompt
            Text("TAP ANYWHERE TO FLIP BACK")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.30))
                .padding(.bottom, 12)
        }
        .frame(width: dimension, height: dimension)
        .background(
            RoundedRectangle(cornerRadius: libraryStore.settings.isArtworkRounded ? 22 : 0, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.95))
        )
        .clipShape(RoundedRectangle(cornerRadius: libraryStore.settings.isArtworkRounded ? 22 : 0, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: libraryStore.settings.isArtworkRounded ? 22 : 0, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: libraryStore.settings.isArtworkRounded ? 22 : 0, style: .continuous))
        .onTapGesture {
            HapticFeedback.cardFlip()
            withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                isArtworkFlipped = false
            }
        }
    }

    private func checkLyricsAvailabilityForCurrentTrack() async {
        if let raw = track.lyrics, !raw.isEmpty {
            let parsed = LyricsParser.parse(raw)
            let hasLyrics = !parsed.isEmpty
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentTrackHasLyrics = hasLyrics
            }
            return
        }

        // No file or network I/O on track change: only a result the lyrics view already loaded counts.
        // Unknown songs keep the lyrics button; the lyrics view reports a miss once it has looked.
        let cached = await LyricsCache.shared.cachedResult(for: track.id)
        if !Task.isCancelled {
            let hasLyrics = cached.map { !LyricsParser.parse($0).isEmpty } ?? true
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentTrackHasLyrics = hasLyrics
            }
        }
    }
}

// MARK: - Play/Pause Morph Geometry (mini player)

/// Card-level coordinate space the mini play/pause glyph is measured in and the floating morph is positioned in.
private let playerCardMorphSpace = "PlayerCardMorphSpace"

/// Mini player play/pause icon frame (ICONS mode), measured at rest in `playerCardMorphSpace`.
private struct MiniPlayGlyphIconFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// Mini player PLAY/PAUSE text frame (text mode), measured at rest in `playerCardMorphSpace`.
private struct MiniPlayGlyphTextFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// First-movement direction of a player drag (fullscreen only).
private enum DragIntent {
    case undecided
    case dismiss
    case queue
    case horizontal
}
