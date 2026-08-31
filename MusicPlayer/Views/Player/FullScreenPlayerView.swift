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

    // 3D Flip & Lyrics Mode State
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
        isLyricsViewPreferred && currentTrackHasLyrics
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
                if isArtworkFlipped {
                    HapticFeedback.selectionChanged()
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
                if isArtworkAnimationEnabled {
                    start3DFloatingAnimationLoop()
                }
            }
            .onDisappear {
                swayAnimationTask?.cancel()
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
                    resetArtworkOrientation()
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
        // Pull-down-to-minimize interactive gesture (when not interacting with artwork)
        .offset(y: max(0, dragOffsetY))
        .scaleEffect(dragOffsetY > 0 ? max(0.85, 1.0 - (dragOffsetY / 900)) : 1.0, anchor: .bottom)
        .opacity(dragOffsetY > 0 ? max(0.7, 1.0 - (dragOffsetY / 500)) : 1.0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard !isTouchingArtwork else { return }
                    if value.translation.height > 0 {
                        dragOffsetY = value.translation.height
                    }
                }
                .onEnded { value in
                    guard !isTouchingArtwork else { return }
                    let h = value.translation.height
                    let predictedH = value.predictedEndTranslation.height

                    if h > 50 || predictedH > 100 {
                        HapticFeedback.lightImpact()
                        dragOffsetY = 0
                        onDismiss()
                    } else if h < -35 || predictedH < -60 {
                        HapticFeedback.lightImpact()
                        dragOffsetY = 0
                        showingQueue = true
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            dragOffsetY = 0
                        }
                    }
                }
        )
        .sheet(isPresented: $showingQueue) {
            PlayerQueueView(playerService: playerService)
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
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            if let track = playerService.currentTrack {
                playlistPickerSheet(for: track)
            }
        }
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
                style: .fullscreen
            )
            .padding(.horizontal, 28)
            .zIndex(3)

            Spacer(minLength: 12)

            // Pure Text Controls Deck (PREV, PLAY/PAUSE, NEXT, SHUFFLE, REPEAT)
            PlayerControlsView(
                playerService: playerService,
                foregroundColor: palette.foregroundColor,
                secondaryForegroundColor: palette.secondaryForegroundColor
            )
            .padding(.vertical, 4)
            .zIndex(3)

            Spacer(minLength: 12)

            // Bottom Action Bar (QUEUE on left, Audio Route on right)
            HStack(spacing: 24) {
                Button(action: { showingQueue = true }) {
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
                    foregroundColor: palette.foregroundColor
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, max(bottomInset, 20) + 4)
            .zIndex(3)
        }
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
                    style: .fullscreen
                )
                .padding(.horizontal, 28)

                PlayerControlsView(
                    playerService: playerService,
                    foregroundColor: palette.foregroundColor,
                    secondaryForegroundColor: palette.secondaryForegroundColor
                )
                .padding(.vertical, 4)

                // Bottom Action Bar (QUEUE on left, Audio Route on right)
                HStack(spacing: 24) {
                    Button(action: { showingQueue = true }) {
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
                        foregroundColor: palette.foregroundColor
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
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
        let isAlbumColor = libraryStore.settings.playerBackgroundStyle == .albumColor
        let primaryShadowColor: Color = isAlbumColor ?
            Color.black.opacity(isPlaying ? 0.35 : 0.0) :
            palette.primaryColor.opacity(isPlaying ? 0.28 : 0.0)
        let deepShadowColor: Color = Color.black.opacity(
            isPlaying ? (isAlbumColor ? 0.30 : 0.24) : 0.0
        )
        let contactShadowColor: Color = Color.black.opacity(
            isPlaying ? (isAlbumColor ? 0.16 : 0.10) : 0.0
        )

        let effectivePitch: Double = isTouchingArtwork ? touchPitch : currentPitch
        let effectiveYaw: Double = isTouchingArtwork ? touchYaw : currentYaw
        let effectiveRoll: Double = isTouchingArtwork ? touchRoll : currentRoll
        let effectiveElevation: CGFloat = isTouchingArtwork ? touchElevation : currentElevation
        let effectiveStretchX: CGFloat = isTouchingArtwork ? touchStretchX : currentStretchX
        let effectiveStretchY: CGFloat = isTouchingArtwork ? touchStretchY : currentStretchY
        let effectiveScale: CGFloat = (isPlaying ? 1.0 : 0.84) * (isTouchingArtwork ? touchScale : 1.0)

        let shadowOffsetX: CGFloat = isPlaying ? CGFloat(effectiveYaw * -1.85 + effectiveRoll * 0.7) : 0
        let baseShadowOffsetY: Double = 11.5 + effectivePitch * 1.5 + Double(effectiveElevation * 0.75)
        let shadowOffsetY: CGFloat = isPlaying ? CGFloat(baseShadowOffsetY) : 0
        let shadowRadius: CGFloat = isPlaying ? max(14.0, 24.0 + effectiveElevation * 1.2) : 0

        return ZStack {
            // Front Card: Album Artwork
            if !isArtworkFlipped {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 22
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(width: dimension, height: dimension)
                .aspectRatio(1.0, contentMode: .fit)
                .onTapGesture {
                    HapticFeedback.selectionChanged()
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
        .shadow(color: deepShadowColor, radius: isPlaying ? 16 : 0, x: shadowOffsetX * 0.7, y: shadowOffsetY * 0.75)
        .shadow(color: contactShadowColor, radius: isPlaying ? 6 : 0, x: shadowOffsetX * 0.35, y: shadowOffsetY * 0.35)
        .offset(y: isPlaying ? effectiveElevation : 0)
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
            x: isPlaying ? (isArtworkAnimationEnabled ? effectiveStretchX : 1.0) : 1.0,
            y: isPlaying ? (isArtworkAnimationEnabled ? effectiveStretchY : 1.0) : 1.0,
            anchor: .center
        )
        .scaleEffect(effectiveScale, anchor: .center)
        .animation(.spring(response: 0.46, dampingFraction: 0.72), value: isPlaying)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        VStack(spacing: 26) {
            Spacer()

            // 1. LYRICS Button (Large text, no background, blue when enabled)
            Button(action: {
                HapticFeedback.lightImpact()
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
                    .foregroundStyle(isLyricsViewPreferred ? Color.blue : Color.white.opacity(0.40))
            }
            .buttonStyle(.plain)

            // 2. ANIMATE ARTWORK Toggle Button (Large text, no background)
            Button(action: {
                HapticFeedback.lightImpact()
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
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(isArtworkAnimationEnabled ? Color.blue : Color.white.opacity(0.40))
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
                                        Color.white :
                                        Color.white.opacity(0.35)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            // Flip Back Prompt
            Button(action: {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                    isArtworkFlipped = false
                }
            }) {
                Text("TAP TO FLIP BACK")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.30))
            }
            .buttonStyle(.plain)
        }
        .frame(width: dimension, height: dimension)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            HapticFeedback.selectionChanged()
            withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) {
                isArtworkFlipped = false
            }
        }
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
                    HapticFeedback.lightImpact()
                    onDismiss()
                }

            ZStack {
                // Header (Lyrics Mode vs Standard Player Mode)
                if isLyricsViewActive {
                    HStack(spacing: 12) {
                        // Artwork mini thumbnail (Tap to return to player view)
                        Button(action: {
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
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)

                        // Title & Artist moved to top position
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(palette.foregroundColor)
                                .lineLimit(1)

                            Text(track.artist)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.secondaryForegroundColor)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .transition(.opacity)
                } else {
                    // Standard Centered Header with clickable album name
                    VStack(spacing: 2) {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.secondaryForegroundColor)

                        Button(action: {
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
                    }
                    .padding(.horizontal, 64)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
                }

                // Trailing Controls: Previous / Play-Pause / Next when lyrics are active AND expanded, otherwise INFO Menu Button
                HStack {
                    Spacer()

                    if isLyricsViewActive && isLyricsExpanded {
                        HStack(spacing: 16) {
                            Button(action: {
                                HapticFeedback.mediumImpact()
                                playerService.previous()
                            }) {
                                Image(systemName: "chevron.left.chevron.left.dotted")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                HapticFeedback.mediumImpact()
                                playerService.togglePlayPause()
                            }) {
                                Image(systemName: playerService.playbackStatus.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                HapticFeedback.mediumImpact()
                                playerService.next()
                            }) {
                                Image(systemName: "chevron.right.dotted.chevron.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else {
                        Menu {
                            Button(action: { showingPlaybackSheet = true }) {
                                Text("PLAYBACK")
                            }
                            Button(action: { showingPlaylistPicker = true }) {
                                Text("ADD TO PLAYLIST")
                            }
                            Button(action: { showingFileInfo = true }) {
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
            }
            .padding(.horizontal, 20)
        }
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

    // MARK: - Interactive 3D Touch Down & Torque Physics

    private func handleArtworkTouch(location: CGPoint, dimension: CGFloat) {
        let centerX = dimension / 2.0
        let centerY = dimension / 2.0

        let normX = max(-1.0, min(1.0, (location.x - centerX) / (dimension / 2.0)))
        let normY = max(-1.0, min(1.0, (location.y - centerY) / (dimension / 2.0)))

        if !isTouchingArtwork {
            isTouchingArtwork = true
            HapticFeedback.lightImpact()
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
