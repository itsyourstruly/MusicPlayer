import SwiftUI

/// Minimal, high-polish full-screen player experience with solid dimmed album background,
/// 3D flip artwork options, synchronized/solid lyrics player with compact and expanded modes,
/// prominent playback controls, and gestural pull-down navigation.
public struct FullScreenPlayerView: View {
    @Bindable var playerService: AudioPlayerService
    @Bindable var libraryStore: LibraryStore
    public let onDismiss: () -> Void

    @State private var showingQueue: Bool = false
    @State private var showingFileInfo: Bool = false
    @State private var showingPlaybackSheet: Bool = false
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var dragOffsetY: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var isDismissing: Bool = false

    /// Strict guard preventing button presses while dragging or pulling down to dismiss the full-screen player.
    private var canTriggerButtonPress: Bool {
        !isDragging && !isDismissing && dragOffsetY == 0
    }

    // 3D Flip & Lyrics Mode State
    @State private var isArtworkFlipped: Bool = false
    private var isArtworkRounded: Bool {
        get { libraryStore.settings.isArtworkRounded }
        nonmutating set {
            libraryStore.settings.isArtworkRounded = newValue
            libraryStore.saveSettings()
        }
    }
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

    // Temporary Added to Playlist Banner State
    private struct AddedToPlaylistBannerState: Equatable {
        let playlistID: UUID
        var playlistName: String
    }
    @State private var addedToPlaylistBanner: AddedToPlaylistBannerState? = nil
    @State private var bannerDismissTask: Task<Void, Never>? = nil
    @State private var showingChangePlaylistSheet: Bool = false

    private var isLyricsViewActive: Bool {
        isLyricsViewPreferred
    }

    // 3D Floating & Physics State
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

    @State private var palette: ArtworkColorExtractor.ColorPalette = ArtworkColorExtractor.ColorPalette(
        primaryColor: Color.appSecondaryBackground,
        isDark: true
    )

    public init(
        playerService: AudioPlayerService,
        libraryStore: LibraryStore,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.playerService = playerService
        self.libraryStore = libraryStore
        self.onDismiss = onDismiss
    }

    // Main view layout structure
    public var body: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            let bottomInset = geo.safeAreaInsets.bottom
            let artworkDimension = min(geo.size.width - 44, geo.size.height * 0.42, 350)
            let isPlaying = playerService.playbackStatus.isPlaying

            ZStack {
                // Configurable Player Background (Smooth In-Place Crossfade & Blend Transition)
                PlayerBackgroundView(
                    style: libraryStore.settings.playerBackgroundStyle,
                    appTheme: libraryStore.settings.appTheme,
                    primaryColor: palette.primaryColor,
                    artworkKey: playerService.currentTrack?.artworkKey,
                    overlayOpacity: 0.50
                )
                .ignoresSafeArea()

                if let track = playerService.currentTrack {
                    VStack(spacing: 0) {
                        // Top Navigation Bar (Positioned safely below Notch / Dynamic Island)
                        topBar(track: track)
                            .padding(.top, max(topInset, 44) + 6)
                            .zIndex(3)

                        if isLyricsViewActive {
                            // MARK: - Lyrics View Layout
                            lyricsModeLayout(track: track, containerHeight: geo.size.height)
                        } else {
                            // MARK: - Standard FullScreen Player Layout
                            standardPlayerLayout(track: track, artworkDimension: artworkDimension, isPlaying: isPlaying, bottomInset: bottomInset)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "NO TRACK SELECTED",
                        message: "Choose an audio track from your library to start playing.",
                        actionTitle: "DISMISS",
                        action: { onDismiss() }
                    )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canTriggerButtonPress else { return }
                if isArtworkFlipped {
                    HapticFeedback.cardFlip()
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                        isArtworkFlipped = false
                    }
                }
            }
            .task(id: playerService.currentTrack?.artworkKey) {
                let newPalette = await ArtworkColorExtractor.shared.extractPrimaryColor(
                    for: playerService.currentTrack?.artworkKey,
                    fallback: Color.appSecondaryBackground
                )
                withAnimation(.easeInOut(duration: 0.65)) {
                    self.palette = newPalette
                }
            }
            .task(id: playerService.currentTrack?.id) {
                await checkLyricsAvailabilityForCurrentTrack()
            }
            .onAppear {
                isDragging = false
                isDismissing = false
                dragOffsetY = 0
                if isArtworkAnimationEnabled {
                    start3DFloatingAnimationLoop()
                }
            }
            .onDisappear {
                swayAnimationTask?.cancel()
                bannerDismissTask?.cancel()
                addedToPlaylistBanner = nil
                resetArtworkOrientation()
                isArtworkFlipped = false
                isLyricsExpanded = false
            }
            .onChange(of: isLyricsViewActive) { _, active in
                if !active {
                    isLyricsExpanded = false
                }
            }
            .onChange(of: playerService.playbackStatus.isPlaying) { _, isPlaying in
                if isPlaying && isArtworkAnimationEnabled {
                    start3DFloatingAnimationLoop()
                } else {
                    swayAnimationTask?.cancel()
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        resetArtworkOrientation()
                    }
                }
            }
            .onChange(of: playerService.currentTrack?.id) { _, _ in
                isLyricsExpanded = false
                if playerService.playbackStatus.isPlaying && isArtworkAnimationEnabled {
                    start3DFloatingAnimationLoop()
                }
            }
        }
        .ignoresSafeArea()
        // Pull-down-to-minimize interactive gesture visual transformation
        .offset(y: max(0, dragOffsetY))
        .scaleEffect(dragOffsetY > 0 ? max(0.85, 1.0 - (dragOffsetY / 900)) : 1.0, anchor: .bottom)
        .opacity(dragOffsetY > 0 ? max(0.7, 1.0 - (dragOffsetY / 500)) : 1.0)
        .environment(\.isPlayerDraggingOrDismissing, isDragging || isDismissing || dragOffsetY != 0)
        .sheet(isPresented: $showingQueue) {
            PlayerQueueView(playerService: playerService, libraryStore: libraryStore)
        }
        .sheet(isPresented: $showingFileInfo) {
            if let track = playerService.currentTrack {
                TrackInfoSheetView(track: track, libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
        }
        .sheet(isPresented: $showingPlaybackSheet) {
            PlaybackControlsSheetView(playerService: playerService)
                .environment(\.appTheme, libraryStore.settings.appTheme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            if let track = playerService.currentTrack {
                playlistPickerSheet(for: track)
            }
        }
        .sheet(isPresented: $showingChangePlaylistSheet) {
            if let track = playerService.currentTrack, let banner = addedToPlaylistBanner {
                changePlaylistSheet(for: track, currentPlaylistID: banner.playlistID)
            }
        }
        .sheet(item: $selectedArtistForNavigation) { artist in
            NavigationStack {
                ArtistDetailView(
                    artist: artist,
                    libraryStore: libraryStore,
                    playerService: playerService
                )
            }
        }
        .sheet(item: $selectedAlbumForNavigation) { album in
            NavigationStack {
                AlbumDetailView(
                    album: album,
                    libraryStore: libraryStore,
                    playerService: playerService
                )
            }
        }
    }

    // MARK: - Standard FullScreen Player Layout

    private func standardPlayerLayout(track: Track, artworkDimension: CGFloat, isPlaying: Bool, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            // Hero Artwork Section with 3D Flip capability
            heroArtworkView(track: track, dimension: artworkDimension, isPlaying: isPlaying)
                .zIndex(1)

            Spacer(minLength: 12)

            // Track Details Header with tap-to-open multi-artist buttons
            VStack(spacing: 4) {
                Text(track.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(palette.foregroundColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                MultiArtistButtonsView(
                    rawArtist: track.artist,
                    joinedArtists: libraryStore.settings.joinedArtists,
                    font: .system(size: 16, weight: .medium),
                    foregroundColor: palette.secondaryForegroundColor,
                    separatorColor: palette.secondaryForegroundColor.opacity(0.65),
                    lineLimit: 1,
                    onSelectArtist: { artistName in
                        if let artistObj = libraryStore.findArtist(name: artistName) {
                            selectedArtistForNavigation = artistObj
                        }
                    }
                )
            }
            .padding(.horizontal, 28)
            .zIndex(3)

            Spacer(minLength: 12)

            // Interactive Seek Scrubber
            PlaybackProgressBar(
                playerService: playerService,
                foregroundColor: palette.foregroundColor,
                secondaryForegroundColor: palette.secondaryForegroundColor,
                style: .fullscreen,
                audioSpecs: libraryStore.settings.showAudioSpecsInPlayer ? track.technicalSummary : nil,
                useProgressBar: libraryStore.settings.useProgressBar,
                onCollapse: {
                    onDismiss()
                }
            )
            .padding(.horizontal, 28)
            .zIndex(3)

            Spacer(minLength: 12)

            // Pure Text Controls Deck (PREV, PLAY/PAUSE, NEXT, SHUFFLE, REPEAT)
            PlayerControlsView(
                playerService: playerService,
                foregroundColor: palette.foregroundColor,
                secondaryForegroundColor: palette.secondaryForegroundColor,
                canPerformAction: { canTriggerButtonPress }
            )
            .padding(.vertical, 4)
            .zIndex(3)

            Spacer(minLength: 12)

            // Bottom Action Bar (QUEUE on left, Audio Route on right)
            HStack(spacing: 24) {
                Button(action: {
                    guard canTriggerButtonPress else { return }
                    showingQueue = true
                }) {
                    HStack(spacing: 6) {
                        Text("QUEUE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        Text("↑")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(palette.foregroundColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer()

                AirPlayButtonView(
                    routeName: playerService.currentAudioRouteName,
                    foregroundColor: palette.foregroundColor,
                    onTap: {
                        guard canTriggerButtonPress else { return }
                        HapticFeedback.lightImpact()
                        RoutePickerManager.shared.presentRoutePicker()
                    }
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, max(bottomInset, 20) + 4)
            .zIndex(3)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    if value.translation.height > 0 {
                        isDragging = true
                        dragOffsetY = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 80 {
                        isDismissing = true
                        onDismiss()
                    } else if value.translation.height < -50 {
                        showingQueue = true
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffsetY = 0
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isDragging = false
                    }
                }
        )
    }

    // MARK: - Lyrics Mode Layout

    private func lyricsModeLayout(track: Track, containerHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // Compact Bottom Controls Deck
            VStack(spacing: 12) {
                Spacer()

                PlaybackProgressBar(
                    playerService: playerService,
                    foregroundColor: palette.foregroundColor,
                    secondaryForegroundColor: palette.secondaryForegroundColor,
                    style: .fullscreen,
                    audioSpecs: libraryStore.settings.showAudioSpecsInPlayer ? track.technicalSummary : nil,
                    useProgressBar: libraryStore.settings.useProgressBar,
                    onCollapse: {
                        onDismiss()
                    }
                )
                .padding(.horizontal, 28)

                PlayerControlsView(
                    playerService: playerService,
                    foregroundColor: palette.foregroundColor,
                    secondaryForegroundColor: palette.secondaryForegroundColor,
                    canPerformAction: { canTriggerButtonPress }
                )
                .padding(.vertical, 4)

                // Bottom Action Bar (QUEUE on left, Audio Route on right)
                HStack(spacing: 24) {
                    Button(action: {
                        guard canTriggerButtonPress else { return }
                        showingQueue = true
                    }) {
                        HStack(spacing: 6) {
                            Text("QUEUE")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                            Text("↑")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(palette.foregroundColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    AirPlayButtonView(
                        routeName: playerService.currentAudioRouteName,
                        foregroundColor: palette.foregroundColor,
                        onTap: {
                            guard canTriggerButtonPress else { return }
                            HapticFeedback.lightImpact()
                            RoutePickerManager.shared.presentRoutePicker()
                        }
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        if value.translation.height > 0 {
                            isDragging = true
                            dragOffsetY = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 80 {
                            isDismissing = true
                            onDismiss()
                        } else if value.translation.height < -50 {
                            showingQueue = true
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                dragOffsetY = 0
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            isDragging = false
                        }
                    }
            )
            .zIndex(1)

            // Central Lyrics Engine View (Floats over bottom controls when expanded)
            LyricsPlayerView(
                playerService: playerService,
                rawLyrics: track.lyrics,
                trackURL: track.url,
                duration: track.duration,
                foregroundColor: palette.foregroundColor,
                secondaryForegroundColor: palette.secondaryForegroundColor,
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
            .zIndex(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 3D Artwork Hero View (With 180° Flip Card)

    private func heroArtworkView(track: Track, dimension: CGFloat, isPlaying: Bool) -> some View {
        let effectivePitch: Double = isTouchingArtwork ? touchPitch : currentPitch
        let effectiveYaw: Double = isTouchingArtwork ? touchYaw : currentYaw
        let effectiveRoll: Double = isTouchingArtwork ? touchRoll : currentRoll
        let effectiveElevation: CGFloat = isTouchingArtwork ? touchElevation : currentElevation
        let effectiveStretchX: CGFloat = isTouchingArtwork ? touchStretchX : currentStretchX
        let effectiveStretchY: CGFloat = isTouchingArtwork ? touchStretchY : currentStretchY
        let effectiveScale: CGFloat = (isPlaying ? 1.0 : 0.84) * (isTouchingArtwork ? touchScale : 1.0)

        let shadowBaseOpacity: Double = isPlaying ? 0.32 : 0.16
        let shadowRadius: CGFloat = isPlaying ? max(14.0, 24.0 + effectiveElevation * 1.2) : 10.0
        let shadowOffsetY: CGFloat = isPlaying ? CGFloat(11.5 + effectivePitch * 1.5 + Double(effectiveElevation * 0.75)) : 5.0
        let shadowOffsetX: CGFloat = isPlaying ? CGFloat(effectiveYaw * -1.85 + effectiveRoll * 0.7) : 0.0

        let primaryShadowColor: Color = Color.black.opacity(shadowBaseOpacity)
        let contactShadowColor: Color = Color.black.opacity(shadowBaseOpacity * 0.5)

        return ZStack {
            // Front Card: Album Artwork
            if !isArtworkFlipped {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: isArtworkRounded ? 22 : 0,
                    targetDimension: 1200,
                    isOriginalResolution: true
                )
                .clipShape(RoundedRectangle(cornerRadius: isArtworkRounded ? 22 : 0, style: .continuous))
                .frame(width: dimension, height: dimension)
                .aspectRatio(1.0, contentMode: .fit)
                .onTapGesture {
                    HapticFeedback.cardFlip()
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                        isArtworkFlipped = true
                    }
                }
            } else {
                // Back Card: Settings & Switch to Lyrics
                artworkBackView(dimension: dimension)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .frame(width: dimension, height: dimension)
        .shadow(color: primaryShadowColor, radius: shadowRadius, x: shadowOffsetX, y: shadowOffsetY)
        .shadow(color: contactShadowColor, radius: isPlaying ? 12 : 5, x: shadowOffsetX * 0.5, y: shadowOffsetY * 0.6)
        .offset(y: effectiveElevation)
        .rotationEffect(.degrees(isArtworkAnimationEnabled ? effectiveRoll : 0))
        .rotation3DEffect(
            .degrees(isArtworkFlipped ? 180 : (isArtworkAnimationEnabled ? effectivePitch : 0)),
            axis: (x: isArtworkFlipped ? 0 : 1.0, y: isArtworkFlipped ? 1.0 : 0.0, z: 0.0),
            anchor: .center,
            perspective: 0.55
        )
        .rotation3DEffect(
            .degrees(isArtworkFlipped ? 0 : (isArtworkAnimationEnabled ? effectiveYaw : 0)),
            axis: (x: 0.0, y: 1.0, z: 0.0),
            anchor: .center,
            perspective: 0.55
        )
        .scaleEffect(
            x: isArtworkAnimationEnabled ? effectiveStretchX : 1.0,
            y: isArtworkAnimationEnabled ? effectiveStretchY : 1.0,
            anchor: .center
        )
        .scaleEffect(effectiveScale, anchor: .center)
        .animation(.spring(response: 0.38, dampingFraction: 0.74), value: isPlaying)
        .contentShape(RoundedRectangle(cornerRadius: isArtworkRounded ? 22 : 0, style: .continuous))
        .gesture(
            LongPressGesture(minimumDuration: 1.0)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    guard !isArtworkFlipped else { return }
                    switch value {
                    case .second(true, let drag):
                        if let drag = drag {
                            handleArtworkTouch(location: drag.location, dimension: dimension)
                        }
                    default:
                        break
                    }
                }
                .onEnded { value in
                    guard !isArtworkFlipped else { return }
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
        .padding(.top, 14)
        .padding(.horizontal, 32)
    }

    // MARK: - Artwork Back View

    private func artworkBackView(dimension: CGFloat) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canTriggerButtonPress else { return }
                    HapticFeedback.cardFlip()
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                        isArtworkFlipped = false
                    }
                }

            // 1. LYRICS Button (Large text, no background, blue when enabled)
            Button(action: {
                guard canTriggerButtonPress else { return }
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
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(isLyricsViewPreferred ? Color.blue : Color.white.opacity(0.40))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 2. ANIMATE ARTWORK Toggle Button (Large text, no background)
            Button(action: {
                guard canTriggerButtonPress else { return }
                HapticFeedback.modeToggle(isOn: !isArtworkAnimationEnabled)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isArtworkAnimationEnabled.toggle()
                    if !isArtworkAnimationEnabled {
                        swayAnimationTask?.cancel()
                        resetArtworkOrientation()
                    } else if playerService.playbackStatus.isPlaying {
                        start3DFloatingAnimationLoop()
                    }
                }
            }) {
                Text("ANIMATE ARTWORK")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(isArtworkAnimationEnabled ? Color.blue : Color.white.opacity(0.40))
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 3. BACKGROUND Picker (Large text, gray when unselected, white when selected)
            VStack(spacing: 8) {
                Text("BACKGROUND")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.40))

                HStack(spacing: 10) {
                    ForEach(PlayerBackgroundStyle.allCases, id: \.self) { style in
                        Button(action: {
                            guard canTriggerButtonPress else { return }
                            HapticFeedback.selectionChanged()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                libraryStore.settings.playerBackgroundStyle = style
                                libraryStore.saveSettings()
                            }
                        }) {
                            Text(style.displayName.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.80)
                                .foregroundStyle(
                                    libraryStore.settings.playerBackgroundStyle == style ?
                                        Color.white :
                                        Color.white.opacity(0.35)
                                )
                                .padding(.horizontal, 4)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 4. ROUNDED Toggle Button (Toggle rounded vs sharp square artwork)
            Button(action: {
                guard canTriggerButtonPress else { return }
                HapticFeedback.modeToggle(isOn: !isArtworkRounded)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                    isArtworkRounded.toggle()
                }
            }) {
                Text("ROUNDED")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(isArtworkRounded ? Color.blue : Color.white.opacity(0.40))
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canTriggerButtonPress else { return }
                    HapticFeedback.cardFlip()
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                        isArtworkFlipped = false
                    }
                }

            // Flip back prompt
            Button(action: {
                guard canTriggerButtonPress else { return }
                HapticFeedback.cardFlip()
                withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                    isArtworkFlipped = false
                }
            }) {
                Text("TAP ANYWHERE TO FLIP BACK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.30))
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: dimension, height: dimension)
        .background(
            RoundedRectangle(cornerRadius: isArtworkRounded ? 22 : 0, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.95))
        )
        .clipShape(RoundedRectangle(cornerRadius: isArtworkRounded ? 22 : 0, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isArtworkRounded ? 22 : 0, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var backgroundDisplayName: String {
        switch libraryStore.settings.playerBackgroundStyle {
        case .albumColor: return "ALBUM COLOR"
        case .albumBlur: return "ALBUM BLUR"
        case .solid: return "THEME COLOR"
        }
    }

    // MARK: - Top Navigation Bar

    private func topBar(track: Track) -> some View {
        VStack(spacing: 8) {
            // Pull Grab Bar
            Capsule()
                .fill(palette.foregroundColor.opacity(0.3))
                .frame(width: 38, height: 4.5)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canTriggerButtonPress else { return }
                    HapticFeedback.lightImpact()
                    onDismiss()
                }

            ZStack {
                // Header (Lyrics Mode vs Standard Player Mode)
                if isLyricsViewActive {
                    HStack(spacing: 12) {
                        // Artwork mini thumbnail (Tap to return to player view)
                        Button(action: {
                            guard canTriggerButtonPress else { return }
                            HapticFeedback.lightImpact()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                isLyricsViewPreferred = false
                            }
                        }) {
                            AlbumArtworkView(
                                artworkKey: track.artworkKey,
                                title: track.album,
                                subtitle: track.artist,
                                cornerRadius: 6
                            )
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: isArtworkRounded ? 6 : 0, style: .continuous))
                            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)

                        // Title & Artist moved to top position (or banner when active)
                        VStack(alignment: .leading, spacing: 2) {
                            if let banner = addedToPlaylistBanner {
                                Button(action: {
                                    guard canTriggerButtonPress else { return }
                                    HapticFeedback.lightImpact()
                                    showingChangePlaylistSheet = true
                                }) {
                                    HStack(spacing: 4) {
                                        Text("ADDED TO \(banner.playlistName.uppercased())")
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.blue)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity)
                            } else {
                                Text(track.title)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(palette.foregroundColor)
                                    .lineLimit(1)

                                Text(track.artist)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(palette.secondaryForegroundColor)
                                    .lineLimit(1)
                            }
                        }
                        .animation(.easeInOut(duration: 0.35), value: addedToPlaylistBanner)

                        Spacer()
                    }
                    .transition(.opacity)
                } else {
                    // Standard Centered Header with clickable album name or banner
                    VStack(spacing: 2) {
                        if let banner = addedToPlaylistBanner {
                            Button(action: {
                                guard canTriggerButtonPress else { return }
                                HapticFeedback.lightImpact()
                                showingChangePlaylistSheet = true
                            }) {
                                HStack(spacing: 5) {
                                    Text("ADDED TO \(banner.playlistName.uppercased())")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.blue)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.70)
                                        .truncationMode(.tail)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.blue)
                                }
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        } else {
                            Text("NOW PLAYING")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.secondaryForegroundColor)

                            Button(action: {
                                guard canTriggerButtonPress else { return }
                                HapticFeedback.lightImpact()
                                if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                                    selectedAlbumForNavigation = albumObj
                                }
                            }) {
                                Text(track.album)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(palette.foregroundColor)
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
                                    Label("PLAY ALBUM NEXT", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 64)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .animation(.easeInOut(duration: 0.35), value: addedToPlaylistBanner)
                    .transition(.opacity)
                }

                // Trailing Controls: Previous / Play-Pause / Next when lyrics are active AND expanded, plus INFO Menu Button
                HStack(spacing: 12) {
                    Spacer()

                    if isLyricsViewActive && isLyricsExpanded {
                        HStack(spacing: 16) {
                            Button(action: {
                                guard canTriggerButtonPress else { return }
                                HapticFeedback.trackSkip(forward: false)
                                playerService.previous()
                            }) {
                                Image(systemName: "chevron.left.chevron.left.dotted")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                guard canTriggerButtonPress else { return }
                                HapticFeedback.playPause(isPlaying: !playerService.playbackStatus.isPlaying)
                                playerService.togglePlayPause()
                            }) {
                                Image(systemName: playerService.playbackStatus.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                guard canTriggerButtonPress else { return }
                                HapticFeedback.trackSkip(forward: true)
                                playerService.next()
                            }) {
                                Image(systemName: "chevron.right.dotted.chevron.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }

                    Menu {
                        Button(action: {
                            guard canTriggerButtonPress else { return }
                            HapticFeedback.lightImpact()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                showingPlaybackSheet = true
                            }
                        }) {
                            Text("PLAYBACK")
                        }
                        Button(action: {
                            guard canTriggerButtonPress else { return }
                            HapticFeedback.lightImpact()
                            handleAddToPlaylist(track: track)
                        }) {
                            Text("ADD TO PLAYLIST")
                        }
                        Button(action: {
                            guard canTriggerButtonPress else { return }
                            HapticFeedback.lightImpact()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                showingFileInfo = true
                            }
                        }) {
                            Text("FILE INFO")
                        }
                    } label: {
                        Text("INFO")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.foregroundColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .padding(.horizontal, 20)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if value.translation.height > 0 {
                        isDragging = true
                        dragOffsetY = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 80 {
                        isDismissing = true
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffsetY = 0
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isDragging = false
                    }
                }
        )
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

    // MARK: - Playlist Picker Sheet

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
                            libraryStore.addTrack(track, toPlaylistID: playlist.id)
                            HapticFeedback.notificationSuccess()
                            showingPlaylistPicker = false
                            triggerAddedToPlaylistBanner(playlistID: playlist.id, playlistName: playlist.name)
                        }) {
                            HStack {
                                Text(playlist.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Text(playlist.formattedTrackCount)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("CANCEL") {
                        showingPlaylistPicker = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Change Playlist Sheet (Move Track)

    private func changePlaylistSheet(for track: Track, currentPlaylistID: UUID) -> some View {
        NavigationStack {
            List {
                if libraryStore.playlists.isEmpty {
                    Text("No playlists created yet.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryStore.playlists) { playlist in
                        let isCurrent = playlist.id == currentPlaylistID
                        Button(action: {
                            if !isCurrent {
                                libraryStore.moveTrack(track, fromPlaylistID: currentPlaylistID, toPlaylistID: playlist.id)
                                HapticFeedback.notificationSuccess()
                                triggerAddedToPlaylistBanner(playlistID: playlist.id, playlistName: playlist.name)
                            }
                            showingChangePlaylistSheet = false
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isCurrent ? Color.blue : Color.primary)
                                    if isCurrent {
                                        Text("CURRENT PLAYLIST")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.blue)
                                    }
                                }
                                Spacer()
                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.blue)
                                } else {
                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("MOVE TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        showingChangePlaylistSheet = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
    }

    private func handleAddToPlaylist(track: Track) {
        if let lastID = libraryStore.lastAddedPlaylistID,
           let targetPlaylist = libraryStore.playlists.first(where: { $0.id == lastID }) {
            libraryStore.addTrack(track, toPlaylistID: targetPlaylist.id)
            HapticFeedback.notificationSuccess()
            triggerAddedToPlaylistBanner(playlistID: targetPlaylist.id, playlistName: targetPlaylist.name)
        } else if libraryStore.playlists.count == 1, let singlePlaylist = libraryStore.playlists.first {
            libraryStore.addTrack(track, toPlaylistID: singlePlaylist.id)
            HapticFeedback.notificationSuccess()
            triggerAddedToPlaylistBanner(playlistID: singlePlaylist.id, playlistName: singlePlaylist.name)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showingPlaylistPicker = true
            }
        }
    }

    private func triggerAddedToPlaylistBanner(playlistID: UUID, playlistName: String) {
        bannerDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            addedToPlaylistBanner = AddedToPlaylistBannerState(playlistID: playlistID, playlistName: playlistName)
        }
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                addedToPlaylistBanner = nil
            }
        }
    }

    // MARK: - Interactive 3D Touch Down & Torque Physics

    private func handleArtworkTouch(location: CGPoint, dimension: CGFloat) {
        let centerX = dimension / 2.0
        let centerY = dimension / 2.0

        let normX = max(-1.0, min(1.0, (location.x - centerX) / (dimension / 2.0)))
        let normY = max(-1.0, min(1.0, (location.y - centerY) / (dimension / 2.0)))

        if !isTouchingArtwork {
            isTouchingArtwork = true
            HapticFeedback.dragPickup()
        }

        let maxAngle: Double = 12.0
        let calculatedPitch = -Double(normY) * maxAngle
        let calculatedYaw = Double(normX) * maxAngle
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

    private func handleArtworkTouchEnded() {
        guard isTouchingArtwork else { return }

        currentPitch = touchPitch
        currentYaw = touchYaw
        currentRoll = touchRoll
        currentElevation = touchElevation
        currentStretchX = touchStretchX
        currentStretchY = touchStretchY

        isTouchingArtwork = false

        withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) {
            touchScale = 1.0
            currentElevation = 0.0
        }
    }

    // MARK: - Dynamic Multi-Directional 3D Floating Engine

    private func start3DFloatingAnimationLoop() {
        guard isArtworkAnimationEnabled else { return }
        swayAnimationTask?.cancel()
        swayAnimationTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.45)) {
                resetArtworkOrientation()
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled || !playerService.playbackStatus.isPlaying || !isArtworkAnimationEnabled { return }

            while !Task.isCancelled && playerService.playbackStatus.isPlaying && isArtworkAnimationEnabled {
                if isTouchingArtwork || isArtworkFlipped {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                let activePhaseTargetDuration = Double.random(in: 4.0...7.0)
                let phaseStartTime = Date()

                while !Task.isCancelled && playerService.playbackStatus.isPlaying && isArtworkAnimationEnabled && Date().timeIntervalSince(phaseStartTime) < activePhaseTargetDuration {
                    let poseType = Int.random(in: 0...3)
                    let rawDistribution = Double.random(in: 0.0...1.0)
                    let biasedFactor = pow(rawDistribution, 2.2)
                    let strength = 0.22 + biasedFactor * 1.28

                    var targetPitch: Double = 0.0
                    var targetYaw: Double = 0.0
                    var targetRoll: Double = 0.0
                    var targetElevation: CGFloat = 0.0

                    switch poseType {
                    case 0:
                        let isTop = Bool.random()
                        let isLeft = Bool.random()
                        let pitchMag = Double.random(in: 3.5...6.5) * strength
                        let yawMag = Double.random(in: 3.5...6.2) * strength
                        let rollMag = Double.random(in: 1.0...2.2) * strength

                        targetPitch = isTop ? -pitchMag * 0.75 : pitchMag
                        targetYaw = isLeft ? yawMag : -yawMag
                        targetRoll = (isTop == isLeft) ? rollMag : -rollMag
                        targetElevation = CGFloat.random(in: (-3.5)...3.5) * strength

                    case 1:
                        let isLeft = Bool.random()
                        targetPitch = Double.random(in: 1.5...4.0) * strength
                        targetYaw = (isLeft ? 1.0 : -1.0) * Double.random(in: 4.5...7.5) * strength
                        targetRoll = (isLeft ? -1.0 : 1.0) * Double.random(in: 1.2...2.4) * strength
                        targetElevation = CGFloat.random(in: (-2.8)...2.8) * strength

                    case 2:
                        let isForward = Bool.random()
                        targetPitch = (isForward ? 1.0 : -0.6) * Double.random(in: 4.8...8.2) * strength
                        targetYaw = Double.random(in: (-3.0)...3.0) * strength
                        targetRoll = Double.random(in: (-1.0)...1.0) * strength
                        targetElevation = CGFloat.random(in: (-3.0)...3.0) * strength

                    default:
                        targetPitch = Double.random(in: 1.8...5.2) * strength
                        targetYaw = Double.random(in: (-5.0)...5.0) * strength
                        targetRoll = Double.random(in: (-1.5)...1.5) * strength
                        targetElevation = CGFloat.random(in: (-2.5)...2.5) * strength
                    }

                    let stretchXCalc = 1.0 + (abs(targetYaw) / 8.0) * 0.018 * min(1.2, strength) - (abs(targetPitch) / 9.0) * 0.008 * min(1.2, strength)
                    let stretchYCalc = 1.0 + (abs(targetPitch) / 9.0) * 0.016 * min(1.2, strength) - (abs(targetYaw) / 8.0) * 0.008 * min(1.2, strength)

                    let stepDuration = Double.random(in: 1.15...1.75)

                    if !isTouchingArtwork && !isArtworkFlipped {
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
                    if Task.isCancelled || !playerService.playbackStatus.isPlaying || !isArtworkAnimationEnabled { break }
                }

                if Task.isCancelled || !playerService.playbackStatus.isPlaying || !isArtworkAnimationEnabled { break }

                if !isTouchingArtwork && !isArtworkFlipped {
                    let centerGlideDuration: Double = 1.15
                    withAnimation(.easeInOut(duration: centerGlideDuration)) {
                        resetArtworkOrientation()
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                if Task.isCancelled || !playerService.playbackStatus.isPlaying || !isArtworkAnimationEnabled { break }
            }

            withAnimation(.easeInOut(duration: 0.5)) {
                resetArtworkOrientation()
            }
        }
    }

    private func checkLyricsAvailabilityForCurrentTrack() async {
        guard let track = playerService.currentTrack else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentTrackHasLyrics = false
            }
            return
        }

        if let raw = track.lyrics, !raw.isEmpty {
            let parsed = LyricsParser.parse(raw)
            let hasLyrics = !parsed.isEmpty
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentTrackHasLyrics = hasLyrics
            }
            return
        }

        let extracted = await AudioScannerService.extractLyrics(from: track.url)
        if !Task.isCancelled {
            let parsed = LyricsParser.parse(extracted)
            let hasLyrics = !parsed.isEmpty
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentTrackHasLyrics = hasLyrics
            }
        }
    }

    private func resetArtworkOrientation() {
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

