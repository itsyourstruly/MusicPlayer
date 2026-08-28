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

    @State private var palette: ArtworkColorExtractor.ColorPalette = ArtworkColorExtractor.ColorPalette(
        primaryColor: Color(red: 0.16, green: 0.16, blue: 0.18),
        isDark: true
    )

    @State private var showingQueue: Bool = false
    @State private var showingFileInfo: Bool = false
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil

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
                    onTapMiniPlayer: {
                        expandPlayer()
                    },
                    onTapCollapse: {
                        collapsePlayer()
                    },
                    onOpenQueue: {
                        HapticFeedback.lightImpact()
                        showingQueue = true
                    },
                    onOpenInfo: {
                        showingFileInfo = true
                    },
                    onOpenPlaylistPicker: {
                        showingPlaylistPicker = true
                    },
                    onSelectArtist: { artist in
                        selectedArtistForNavigation = artist
                    },
                    onSelectAlbum: { album in
                        selectedAlbumForNavigation = album
                    },
                    onDragChanged: { translation in
                        if !isDragging {
                            isDragging = true
                            dragStartProgress = expansionProgress
                        }

                        // Delta y
                        let deltaY = translation.height
                        // Computed
                        let computed = dragStartProgress - (deltaY / totalTravelDistance)

                        // Transaction
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            expansionProgress = min(max(computed, 0.0), 1.0)
                        }
                    },
                    onDragEnded: { translation, predictedEnd in
                        isDragging = false
                        // H
                        let h = translation.height
                        // W
                        let w = translation.width
                        // Predicted h
                        let predictedH = predictedEnd.height

                        if dragStartProgress <= 0.3 {
                            // Started from Miniplayer
                            if abs(w) > abs(h) && w < -35 {
                                // Horizontal swipe left -> Next track
                                skipNext()
                                snapTo(expanded: false)
                            } else if abs(w) > abs(h) && w > 35 {
                                // Horizontal swipe right -> Previous track
                                skipPrevious()
                                snapTo(expanded: false)
                            } else if h < -40 || predictedH < -80 || expansionProgress > 0.35 {
                                // Upward drag/flick threshold met -> Expand to Fullscreen
                                expandPlayer()
                            } else {
                                // Drag not far enough -> Spring back to Miniplayer
                                snapTo(expanded: false)
                            }
                        } else {
                            // Started from Fullscreen or mid-transition
                            if h > 40 || predictedH > 80 || expansionProgress < 0.65 {
                                // Downward drag/flick threshold met -> Collapse to Miniplayer
                                collapsePlayer()
                            } else if h < -35 || predictedH < -60 {
                                // Upward swipe while in Fullscreen -> Open Queue!
                                snapTo(expanded: true)
                                showingQueue = true
                            } else {
                                // Snap back to Fullscreen
                                snapTo(expanded: true)
                            }
                        }
                    }
                )
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingQueue) {
                PlayerQueueView(playerService: playerService)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingFileInfo) {
                TrackInfoSheetView(track: track, libraryStore: libraryStore)
            }
            // Modal presentation sheet
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
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("DONE") {
                                selectedArtistForNavigation = nil
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
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
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("DONE") {
                                selectedAlbumForNavigation = nil
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
                }
            }// Always maintain full-screen frame so geometry and safe area insets NEVER jump during drag or springs.
            // Hit testing is strictly constrained to the card and active backdrop, preserving 100% interactive background taps.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            // Triggered when view appears
            .onAppear {
                expansionProgress = isExpanded ? 1.0 : 0.0
            }
            // React to state changes
            .onChange(of: isExpanded) { _, newValue in
                // Ensure preconditions are met before proceeding
                guard !isDragging else { return }
                // Target
                let target: CGFloat = newValue ? 1.0 : 0.0
                // Ensure preconditions are met before proceeding
                guard expansionProgress != target else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0.08)) {
                    expansionProgress = target
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
            // Modal presentation sheet
            .sheet(isPresented: $showingQueue) {
                PlayerQueueView(playerService: playerService)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingFileInfo) {
                TrackInfoSheetView(track: track, libraryStore: libraryStore)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingPlaylistPicker) {
                playlistPickerSheet(for: track)
            }
        }
    }

    // MARK: - State Transition Triggers

    // Expand player
    private func expandPlayer() {
        HapticFeedback.lightImpact()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0.08)) {
            isExpanded = true
            expansionProgress = 1.0
        }
    }

    // Collapse player
    private func collapsePlayer() {
        HapticFeedback.lightImpact()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0.08)) {
            isExpanded = false
            expansionProgress = 0.0
        }
    }

    // Snap to
    private func snapTo(expanded: Bool) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.08)) {
            isExpanded = expanded
            expansionProgress = expanded ? 1.0 : 0.0
        }
    }

    // Skip next
    private func skipNext() {
        // Ensure preconditions are met before proceeding
        guard playerService.hasNextTrack else { return }
        HapticFeedback.selectionChanged()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
            playerService.next()
        }
    }

    // Skip previous
    private func skipPrevious() {
        // Ensure preconditions are met before proceeding
        guard playerService.hasPreviousTrack else { return }
        HapticFeedback.selectionChanged()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
            playerService.previous()
        }
    }

    // Playlist picker sheet
    private func playlistPickerSheet(for track: Track) -> some View {
        NavigationStack {
            List {
                if libraryStore.playlists.isEmpty {
                    Text("No playlists created yet.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryStore.playlists) { playlist in
                        Button(action: {
                            HapticFeedback.notificationSuccess()
                            libraryStore.addTrack(track, toPlaylistID: playlist.id)
                            showingPlaylistPicker = false
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 15, weight: .bold))
                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("ADD")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        showingPlaylistPicker = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    // On tap mini player
    let onTapMiniPlayer: () -> Void
    // On tap collapse
    let onTapCollapse: () -> Void
    // Serial queue for on open queue
    let onOpenQueue: () -> Void
    // On open info
    let onOpenInfo: () -> Void
    // On open playlist picker
    let onOpenPlaylistPicker: () -> Void
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
        let miniArtworkSize: CGFloat = 46
        // Mini artwork corner
        let miniArtworkCorner: CGFloat = 10
        // Mini artwork x
        let miniArtworkX: CGFloat = 12
        // Mini artwork y
        let miniArtworkY: CGFloat = (miniHeight - miniArtworkSize) / 2 // 9pt centered

        // Full artwork dimension
        let fullArtworkDimension: CGFloat = min(screenWidth - 44, screenHeight * 0.42, 350)
        // Full artwork corner
        let fullArtworkCorner: CGFloat = 22
        // Full artwork x
        let fullArtworkX: CGFloat = (screenWidth - fullArtworkDimension) / 2
        // Full artwork y
        let fullArtworkY: CGFloat = topSafeArea + 70

        // Current artwork size
        let currentArtworkSize: CGFloat = lerp(start: miniArtworkSize, end: fullArtworkDimension, t: clampedProgress)
        // Current artwork corner
        let currentArtworkCorner: CGFloat = lerp(start: miniArtworkCorner, end: fullArtworkCorner, t: clampedProgress)
        // Current artwork x
        let currentArtworkX: CGFloat = lerp(start: miniArtworkX, end: fullArtworkX, t: clampedProgress)
        // Current artwork y
        let currentArtworkY: CGFloat = lerp(start: miniArtworkY, end: fullArtworkY, t: clampedProgress)

        // Play pause scale
        let playPauseScale: CGFloat = isPlaying ? 1.0 : 0.84
        // Base artwork scale
        let baseArtworkScale: CGFloat = lerp(start: 1.0, end: playPauseScale, t: clampedProgress)
        // Dynamic artwork scale
        let dynamicArtworkScale: CGFloat = isTouchingArtwork ? (baseArtworkScale * touchScale) : baseArtworkScale

        // Continuous Non-Jitter Layer Opacities and Offsets
        let miniOpacity: Double = max(0.0, min(1.0, Double(1.0 - clampedProgress * 2.8)))
        // Full opacity
        let fullOpacity: Double = max(0.0, min(1.0, Double((clampedProgress - 0.18) / 0.78)))

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

                // 2. Miniplayer Layer (Interactive & tap-to-expand)
                miniplayerContent(miniArtworkSize: miniArtworkSize)
                    .opacity(miniOpacity)
                    .offset(x: -clampedProgress * 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTapMiniPlayer()
                    }
                    .allowsHitTesting(clampedProgress < 0.15)

                // 3. Fullscreen Layer (Controls, progress bar, title, queue)
                fullscreenContent(fullArtworkSize: fullArtworkDimension)
                    .opacity(fullOpacity)
                    .offset(y: (1.0 - clampedProgress) * 28)
                    .allowsHitTesting(clampedProgress > 0.80)
                    .zIndex(5)

                // 4. SINGLE SHARED ALBUM ARTWORK (Hero continuous transition with subtle 3D floating depth & touch press)
                let isAlbumColor = backgroundStyle == .albumColor

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

                // Pitch degrees
                let pitchDegrees: Double = isPlaying ? (effectiveRawPitch * Double(clampedProgress)) : 0.0
                // Yaw degrees
                let yawDegrees: Double = isPlaying ? (effectiveRawYaw * Double(clampedProgress)) : 0.0
                // Roll degrees
                let rollDegrees: Double = isPlaying ? (effectiveRawRoll * Double(clampedProgress)) : 0.0
                // Elevation val
                let elevationVal: CGFloat = isPlaying ? (effectiveRawElevation * clampedProgress) : 0.0
                // Stretch x val
                let stretchXVal: CGFloat = isPlaying ? (1.0 + (effectiveRawStretchX - 1.0) * clampedProgress) : 1.0
                // Stretch y val
                let stretchYVal: CGFloat = isPlaying ? (1.0 + (effectiveRawStretchY - 1.0) * clampedProgress) : 1.0

                // Shadow offset x
                let shadowOffsetX: CGFloat = isPlaying ? CGFloat((effectiveRawYaw * -1.85 + effectiveRawRoll * 0.7) * Double(clampedProgress)) : 0
                // Base shadow offset y
                let baseShadowOffsetY: Double = (11.5 + pitchDegrees * 1.5 + Double(elevationVal * 0.75)) * Double(clampedProgress)
                // Shadow offset y
                let shadowOffsetY: CGFloat = isPlaying ? CGFloat(baseShadowOffsetY) : 0
                // Dynamic shadow radius
                let dynamicShadowRadius: CGFloat = isPlaying ? lerp(start: 0, end: max(14.0, 24.0 + elevationVal * 1.2), t: clampedProgress) : 0

                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: currentArtworkCorner
                )
                .clipShape(RoundedRectangle(cornerRadius: currentArtworkCorner, style: .continuous))
                .frame(width: currentArtworkSize, height: currentArtworkSize)
                // Multi-tier 3D Floating Shadows (Active and elevated when playing, completely removed when paused)
                // 1. Ambient Floating Glow / Deep Drop Shadow with dynamic angle & altitude dilation
                .shadow(
                    color: isAlbumColor ?
                        Color.black.opacity(isPlaying ? (0.35 * Double(clampedProgress)) : 0.0) :
                        palette.primaryColor.opacity(isPlaying ? (0.28 * Double(clampedProgress)) : 0.0),
                    radius: dynamicShadowRadius,
                    x: shadowOffsetX,
                    y: shadowOffsetY
                )
                // 2. Soft Deep Floating Drop Shadow
                .shadow(
                    color: Color.black.opacity(
                        isPlaying ? ((isAlbumColor ? 0.30 : 0.24) * Double(clampedProgress)) : 0.0
                    ),
                    radius: isPlaying ? lerp(start: 0, end: 16, t: clampedProgress) : 0,
                    x: shadowOffsetX * 0.7,
                    y: shadowOffsetY * 0.75
                )
                // 3. Subtle Contact Floor Shadow
                .shadow(
                    color: Color.black.opacity(
                        isPlaying ? ((isAlbumColor ? 0.16 : 0.10) * Double(clampedProgress)) : 0.0
                    ),
                    radius: isPlaying ? lerp(start: 0, end: 6, t: clampedProgress) : 0,
                    x: shadowOffsetX * 0.35,
                    y: shadowOffsetY * 0.35
                )
                // Floating vertical altitude bob
                .offset(y: elevationVal)
                // Subtle natural 2D roll tilt
                .rotationEffect(.degrees(rollDegrees))
                // Natural 3D Pitch (X-axis)
                .rotation3DEffect(
                    .degrees(pitchDegrees),
                    axis: (x: 1.0, y: 0.0, z: 0.0),
                    anchor: .center,
                    perspective: 0.55
                )
                // Natural 3D Yaw (Y-axis)
                .rotation3DEffect(
                    .degrees(yawDegrees),
                    axis: (x: 0.0, y: 1.0, z: 0.0),
                    anchor: .center,
                    perspective: 0.55
                )
                // Subtle organic stretch elasticity
                .scaleEffect(
                    x: stretchXVal,
                    y: stretchYVal,
                    anchor: .center
                )
                // Dynamic Play/Pause Spring Scale Effect (Smooth & non-jittery transform scaling)
                .scaleEffect(dynamicArtworkScale, anchor: .center)
                // Smooth UI transition animation
                .animation(.spring(response: 0.46, dampingFraction: 0.72), value: isPlaying)
                .contentShape(RoundedRectangle(cornerRadius: currentArtworkCorner, style: .continuous))
                // Interactive drag and touch gesture handling
                .gesture(
                    LongPressGesture(minimumDuration: 1.0)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onChanged { value in
                            // Ensure preconditions are met before proceeding
                            guard clampedProgress > 0.75 else { return }
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
                            // Ensure preconditions are met before proceeding
                            guard clampedProgress > 0.75 else { return }
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
                .offset(x: currentArtworkX, y: currentArtworkY)
                .zIndex(2)
                .allowsHitTesting(clampedProgress > 0.75)
            }
            .frame(width: screenWidth - (horizontalMargin * 2), height: cardHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .shadow(
                color: Color.black.opacity(lerp(start: 0.16, end: 0.38, t: clampedProgress)),
                radius: lerp(start: 10, end: 26, t: clampedProgress),
                x: 0,
                y: lerp(start: 4, end: 12, t: clampedProgress)
            )
            .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            // Interactive drag and touch gesture handling
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        // Ensure preconditions are met before proceeding
                        guard !isTouchingArtwork else { return }
                        onDragChanged(value.translation)
                    }
                    .onEnded { value in
                        // Ensure preconditions are met before proceeding
                        guard !isTouchingArtwork else { return }
                        onDragEnded(value.translation, value.predictedEndTranslation)
                    }
            )
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
        // React to state changes
        .onChange(of: track.id) { _, _ in
            if playerService.playbackStatus.isPlaying {
                start3DFloatingAnimationLoop()
            }
        }
        // React to state changes
        .onChange(of: isExpanded) { _, _ in
            if playerService.playbackStatus.isPlaying {
                start3DFloatingAnimationLoop()
            }
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
            HapticFeedback.lightImpact()
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
            if Task.isCancelled || !playerService.playbackStatus.isPlaying { return }

            // Infinite continuous fluid wander loop
            while !Task.isCancelled && playerService.playbackStatus.isPlaying {
                if isTouchingArtwork {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                // 1. Active wander phase duration: 4 to 7 seconds
                let activePhaseTargetDuration = Double.random(in: 4.0...7.0)
                // Phase start time
                let phaseStartTime = Date()

                while !Task.isCancelled && playerService.playbackStatus.isPlaying && Date().timeIntervalSince(phaseStartTime) < activePhaseTargetDuration {
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

    // Card background
    private func cardBackground(cornerRadius: CGFloat, progress: CGFloat) -> some View {
        ZStack {
            switch backgroundStyle {
            case .albumColor:
                // Deep dark base
                Color(red: 0.12, green: 0.12, blue: 0.14)

                // Dynamic primary color
                palette.primaryColor
                    .opacity(0.85)

                // Contrast dark overlay
                Color.black
                    .opacity(lerp(start: 0.28, end: 0.48, t: progress))

            case .albumBlur:
                // Deep dark base
                Color(red: 0.10, green: 0.10, blue: 0.12)

                // Blurred album artwork scaled to cover background
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 0
                )
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 40)
                .clipped()

                // Contrast dark overlay ensuring crisp text readability
                Color.black
                    .opacity(lerp(start: 0.40, end: 0.52, t: progress))

            case .solid:
                // Solid theme background color
                appTheme.solidPlayerBackground

                // Subtle depth overlay
                Color.black
                    .opacity(lerp(start: 0.12, end: 0.30, t: progress))
            }

            // Border highlight
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(max(0.0, 0.14 * Double(1.0 - progress))), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Miniplayer Layer

    // Miniplayer content
    private func miniplayerContent(miniArtworkSize: CGFloat) -> some View {
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

            // Play / Pause Button
            Button(action: {
                HapticFeedback.lightImpact()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                    playerService.togglePlayPause()
                }
            }) {
                Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .contentTransition(.interpolate)
                    .frame(width: 58, height: 36, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .frame(height: 64)
    }

    // MARK: - Fullscreen Layer

    // Fullscreen content
    private func fullscreenContent(fullArtworkSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 1. Top Navigation Bar
            topBar()
                .padding(.top, topSafeArea + 6)

            // Space reserved for hero artwork (aligned with downward repositioned 3D artwork)
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

            // 3. Interactive Seek Scrubber
            PlaybackProgressBar(
                playerService: playerService,
                foregroundColor: Color.white,
                secondaryForegroundColor: Color.white.opacity(0.65)
            )
            .padding(.horizontal, 28)

            Spacer(minLength: 12)

            // 4. Pure Text Controls Deck
            PlayerControlsView(
                playerService: playerService,
                foregroundColor: Color.white,
                secondaryForegroundColor: Color.white.opacity(0.65)
            )
            .padding(.vertical, 4)

            Spacer(minLength: 12)

            // 5. Bottom Action Bar (QUEUE on left, Audio Route on right)
            HStack(spacing: 24) {
                Button(action: onOpenQueue) {
                    HStack(spacing: 6) {
                        Text("QUEUE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        Text("↑")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer()

                AirPlayButtonView(
                    routeName: playerService.currentAudioRouteName,
                    foregroundColor: Color.white
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, max(bottomSafeArea, 16) + 12)
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .top)
    }

    // Top bar
    private func topBar() -> some View {
        VStack(spacing: 8) {
            // Pull Grab Bar (Tap or drag down to minimize)
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 38, height: 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTapCollapse()
                }

            ZStack {
                // Exactly Centered Title Header with clickable album name
                VStack(spacing: 2) {
                    Text("NOW PLAYING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))

                    Button(action: {
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
                }
                .padding(.horizontal, 64)
                .frame(maxWidth: .infinity, alignment: .center)

                // Trailing Clean INFO Menu Button
                HStack {
                    Spacer()

                    Menu {
                        Button(action: onOpenPlaylistPicker) {
                            Text("ADD TO PLAYLIST")
                        }
                        Button(action: onOpenInfo) {
                            Text("FILE INFO")
                        }
                    } label: {
                        Text("INFO")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
