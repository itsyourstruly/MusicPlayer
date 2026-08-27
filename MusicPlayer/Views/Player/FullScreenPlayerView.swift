import SwiftUI

/// Minimal, high-polish full-screen player experience with solid dimmed album background,
/// perfectly centered header, pure text prominent controls, and gestural pull-down navigation.
public struct FullScreenPlayerView: View {
    @Bindable var playerService: AudioPlayerService
    @Bindable var libraryStore: LibraryStore
    public let onDismiss: () -> Void

    @State private var showingQueue: Bool = false
    @State private var showingFileInfo: Bool = false
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var dragOffsetY: CGFloat = 0
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

    public var body: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            let bottomInset = geo.safeAreaInsets.bottom
            let artworkDimension = min(geo.size.width - 44, geo.size.height * 0.42, 350)
            let isPlaying = playerService.playbackStatus.isPlaying

            ZStack {
                // Configurable Player Background
                switch libraryStore.settings.playerBackgroundStyle {
                case .albumColor:
                    Rectangle()
                        .fill(palette.primaryColor)
                        .overlay(Color.black.opacity(0.35))
                        .ignoresSafeArea()

                case .albumBlur:
                    if let track = playerService.currentTrack {
                        AlbumArtworkView(
                            artworkKey: track.artworkKey,
                            title: track.album,
                            subtitle: track.artist,
                            cornerRadius: 0
                        )
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 50)
                        .overlay(Color.black.opacity(0.50))
                        .ignoresSafeArea()
                    } else {
                        Rectangle()
                            .fill(Color.black)
                            .ignoresSafeArea()
                    }

                case .solid:
                    Rectangle()
                        .fill(libraryStore.settings.appTheme.solidPlayerBackground)
                        .overlay(Color.black.opacity(0.20))
                        .ignoresSafeArea()
                }

                if let track = playerService.currentTrack {
                    VStack(spacing: 0) {
                        // Top Navigation Bar (Positioned safely below Notch / Dynamic Island)
                        topBar(track: track)
                            .padding(.top, max(topInset, 44) + 6)
                            .zIndex(3)

                        Spacer(minLength: 16)

                        // Hero Artwork Section (Subtle 3D Floating Effect & Interactive Press)
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

                        // Bottom Action Bar (QUEUE on left, AirPlay on right)
                        HStack(spacing: 24) {
                            Button(action: { showingQueue = true }) {
                                HStack(spacing: 6) {
                                    Text("QUEUE")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    Text("↑")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(palette.foregroundColor)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            ZStack {
                                AirPlayButtonView()
                                    .frame(width: 36, height: 36)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, max(bottomInset, 20) + 4)
                        .zIndex(3)
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
            .task(id: playerService.currentTrack?.artworkKey) {
                let newPalette = await ArtworkColorExtractor.shared.extractPrimaryColor(
                    for: playerService.currentTrack?.artworkKey,
                    fallback: Color.appSecondaryBackground
                )
                withAnimation(.easeInOut(duration: 0.65)) {
                    self.palette = newPalette
                }
            }
            .onAppear {
                start3DFloatingAnimationLoop()
            }
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
            .onChange(of: playerService.currentTrack?.id) { _, _ in
                if playerService.playbackStatus.isPlaying {
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

                    // Pull down past threshold -> Minimize back to miniplayer
                    if h > 50 || predictedH > 100 {
                        HapticFeedback.lightImpact()
                        dragOffsetY = 0
                        onDismiss()
                    } else if h < -35 || predictedH < -60 {
                        // Upward swipe -> Open Queue
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
            }
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

    // MARK: - Interactive 3D Touch Down & Torque Physics

    private func handleArtworkTouch(location: CGPoint, dimension: CGFloat) {
        let centerX = dimension / 2.0
        let centerY = dimension / 2.0

        // Normalized touch offsets from center (-1.0 to 1.0)
        let normX = max(-1.0, min(1.0, (location.x - centerX) / (dimension / 2.0)))
        let normY = max(-1.0, min(1.0, (location.y - centerY) / (dimension / 2.0)))

        if !isTouchingArtwork {
            isTouchingArtwork = true
            HapticFeedback.lightImpact()
        }

        // 3D Torque Press Physics:
        // Tapping Top (normY < 0) -> positive pitch pushes top edge into screen
        // Tapping Bottom (normY > 0) -> negative pitch pushes bottom edge into screen
        // Tapping Right (normX > 0) -> positive yaw pushes right edge into screen
        // Tapping Left (normX < 0) -> negative yaw pushes left edge into screen
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
                // If user is actively touching/pressing the artwork, yield loop until released
                if isTouchingArtwork {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                // 1. Active wander phase duration: 4 to 7 seconds
                let activePhaseTargetDuration = Double.random(in: 4.0...7.0)
                let phaseStartTime = Date()

                while !Task.isCancelled && playerService.playbackStatus.isPlaying && Date().timeIntervalSince(phaseStartTime) < activePhaseTargetDuration {
                    if isTouchingArtwork {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }

                    // Weighted pose selection: 45% subtle free wander, 35% corner/side tilts, 20% deep pitch
                    let poseRoll = Double.random(in: 0.0...1.0)
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
                    let biasedFactor = pow(rawDistribution, 2.2)
                    let strength = 0.22 + biasedFactor * 1.28

                    var targetPitch: Double = 0.0
                    var targetYaw: Double = 0.0
                    var targetRoll: Double = 0.0
                    var targetElevation: CGFloat = 0.0

                    switch poseType {
                    case 0:
                        // Corner Tilt (Top-Left, Top-Right, Bottom-Left, Bottom-Right)
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

    // MARK: - Subviews

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

        // Effective 3D angles & offsets blending touch interaction and floating engine
        let effectivePitch: Double = isTouchingArtwork ? touchPitch : currentPitch
        let effectiveYaw: Double = isTouchingArtwork ? touchYaw : currentYaw
        let effectiveRoll: Double = isTouchingArtwork ? touchRoll : currentRoll
        let effectiveElevation: CGFloat = isTouchingArtwork ? touchElevation : currentElevation
        let effectiveStretchX: CGFloat = isTouchingArtwork ? touchStretchX : currentStretchX
        let effectiveStretchY: CGFloat = isTouchingArtwork ? touchStretchY : currentStretchY
        let effectiveScale: CGFloat = (isPlaying ? 1.0 : 0.84) * (isTouchingArtwork ? touchScale : 1.0)

        // Dynamically adjusted shadow projection responding in real-time to current 3D orientation & altitude
        let shadowOffsetX: CGFloat = isPlaying ? CGFloat(effectiveYaw * -1.85 + effectiveRoll * 0.7) : 0
        let baseShadowOffsetY: Double = 11.5 + effectivePitch * 1.5 + Double(effectiveElevation * 0.75)
        let shadowOffsetY: CGFloat = isPlaying ? CGFloat(baseShadowOffsetY) : 0
        let shadowRadius: CGFloat = isPlaying ? max(14.0, 24.0 + effectiveElevation * 1.2) : 0

        return AlbumArtworkView(
            artworkKey: track.artworkKey,
            title: track.album,
            subtitle: track.artist,
            cornerRadius: 22
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(width: dimension, height: dimension)
        .aspectRatio(1.0, contentMode: .fit)
        // 1. Ambient wide shadow with dynamic light angle & altitude dilation
        .shadow(
            color: primaryShadowColor,
            radius: shadowRadius,
            x: shadowOffsetX,
            y: shadowOffsetY
        )
        // 2. Deep soft shadow
        .shadow(
            color: deepShadowColor,
            radius: isPlaying ? 16 : 0,
            x: shadowOffsetX * 0.7,
            y: shadowOffsetY * 0.75
        )
        // 3. Contact floor shadow
        .shadow(
            color: contactShadowColor,
            radius: isPlaying ? 6 : 0,
            x: shadowOffsetX * 0.35,
            y: shadowOffsetY * 0.35
        )
        // Floating vertical altitude bob
        .offset(y: isPlaying ? effectiveElevation : 0)
        // Subtle natural 2D roll tilt
        .rotationEffect(.degrees(effectiveRoll))
        // Natural 3D Pitch (X-axis)
        .rotation3DEffect(
            .degrees(effectivePitch),
            axis: (x: 1.0, y: 0.0, z: 0.0),
            anchor: .center,
            perspective: 0.55
        )
        // Natural 3D Yaw (Y-axis)
        .rotation3DEffect(
            .degrees(effectiveYaw),
            axis: (x: 0.0, y: 1.0, z: 0.0),
            anchor: .center,
            perspective: 0.55
        )
        // Subtle organic stretch elasticity
        .scaleEffect(
            x: isPlaying ? effectiveStretchX : 1.0,
            y: isPlaying ? effectiveStretchY : 1.0,
            anchor: .center
        )
        // Dynamic Play/Pause & Touch Press Spring Scale Effect
        .scaleEffect(effectiveScale, anchor: .center)
        .animation(.spring(response: 0.46, dampingFraction: 0.72), value: isPlaying)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .gesture(
            LongPressGesture(minimumDuration: 1.0)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
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
                // Exactly Centered Title Header with clickable album name
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

                // Trailing Clean INFO Text Button
                HStack {
                    Spacer()

                    Menu {
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
                }
            }
            .padding(.horizontal, 20)
        }
    }

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
