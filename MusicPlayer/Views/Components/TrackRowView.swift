import SwiftUI

/// Reusable track row displaying album cover artwork thumbnail, metadata, duration, status indicators,
/// and an optimized, fluid swipe-left gesture to trigger "PLAY NEXT" without interfering with scrolling.
public struct TrackRowView: View {
    // Track
    public let track: Track
    // Index number
    public let indexNumber: Int?
    // Flag indicating if current track
    public let isCurrentTrack: Bool
    // Flag indicating if playing
    public let isPlaying: Bool
    // Flag indicating if next track
    public let isNextTrack: Bool
    // Flag indicating if in play next
    public let isInPlayNext: Bool
    // Flag indicating if tap to play next enabled
    public let isTapToPlayNextEnabled: Bool
    // Show album subtitle
    public let showAlbumSubtitle: Bool
    // On play
    public let onPlay: () -> Void
    // On play next
    public let onPlayNext: () -> Void
    // On queue next
    public let onQueueNext: () -> Void
    // Serial queue for on add to queue
    public let onAddToQueue: () -> Void
    // On add to playlist
    public let onAddToPlaylist: () -> Void
    // On show info
    public let onShowInfo: () -> Void
    // On select artist
    public let onSelectArtist: ((String) -> Void)?
    // On select album
    public let onSelectAlbum: (() -> Void)?
    // On remove from playlist
    public let onRemoveFromPlaylist: (() -> Void)?
    // Flag indicating if swipe disabled
    public let isSwipeDisabled: Bool
    // Trailing text
    public let trailingText: String?

    @Environment(\.appTheme) private var appTheme
    @GestureState private var gestureDragOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var isTapPlayNextTriggered: Bool = false
    @State private var showPlayNowSuccess: Bool = false
    @State private var showPlayNextSuccess: Bool = false
    @State private var showQueueSuccess: Bool = false
    @State private var showPlayNextAgain: Bool = false
    @State private var showQueueAgain: Bool = false
    @State private var isLeadingBadgeVisible: Bool = false
    @State private var isTrailingBadgeVisible: Bool = false
    @State private var dismissTask: Task<Void, Never>? = nil

    // Activation thresholds - leading has longer badge (PLAYING NEXT / PLAY NOW), trailing is shorter (QUEUE)
    private let leadingActivationThreshold: CGFloat = 118
    private let trailingActivationThreshold: CGFloat = 96

    private var activationThreshold: CGFloat {
        leadingActivationThreshold
    }

    // Initialize with configured properties
    public init(
        track: Track,
        indexNumber: Int? = nil,
        isCurrentTrack: Bool = false,
        isPlaying: Bool = false,
        isNextTrack: Bool = false,
        isInPlayNext: Bool = false,
        isTapToPlayNextEnabled: Bool = false,
        showAlbumSubtitle: Bool = true,
        isSwipeDisabled: Bool = false,
        trailingText: String? = nil,
        onPlay: @escaping () -> Void,
        onPlayNext: @escaping () -> Void = {},
        onQueueNext: @escaping () -> Void = {},
        onAddToQueue: @escaping () -> Void = {},
        onAddToPlaylist: @escaping () -> Void = {},
        onRemoveFromPlaylist: (() -> Void)? = nil,
        onShowInfo: @escaping () -> Void = {},
        onSelectArtist: ((String) -> Void)? = nil,
        onSelectAlbum: (() -> Void)? = nil
    ) {
        self.track = track
        self.indexNumber = indexNumber
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying
        self.isNextTrack = isNextTrack
        self.isInPlayNext = isInPlayNext
        self.isTapToPlayNextEnabled = isTapToPlayNextEnabled
        self.showAlbumSubtitle = showAlbumSubtitle
        self.isSwipeDisabled = isSwipeDisabled
        self.trailingText = trailingText
        self.onPlay = onPlay
        self.onPlayNext = onPlayNext
        self.onQueueNext = onQueueNext
        self.onAddToQueue = onAddToQueue
        self.onAddToPlaylist = onAddToPlaylist
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onShowInfo = onShowInfo
        self.onSelectArtist = onSelectArtist
        self.onSelectAlbum = onSelectAlbum
    }

    private var currentOffset: CGFloat {
        gestureDragOffset != 0 ? gestureDragOffset : dragOffset
    }

    private var trailingRevealProgress: Double {
        min(1.0, max(0.0, Double(-currentOffset) / Double(trailingActivationThreshold)))
    }

    private var leadingRevealProgress: Double {
        min(1.0, max(0.0, Double(currentOffset) / Double(leadingActivationThreshold)))
    }

    private var isLeadingSurfaceVisible: Bool {
        currentOffset > 0 || isLeadingBadgeVisible
    }

    private var isTrailingSurfaceVisible: Bool {
        currentOffset < 0 || isTrailingBadgeVisible
    }

    private var leadingActionText: String {
        if isTapToPlayNextEnabled {
            if isTapPlayNextTriggered {
                return "PLAYING NEXT"
            } else if showPlayNowSuccess {
                return "PLAYING"
            } else {
                return "PLAY NOW"
            }
        } else {
            if showPlayNextSuccess {
                return "QUEUED"
            } else if showPlayNextAgain {
                return "AGAIN?"
            } else {
                return "PLAY NEXT"
            }
        }
    }

    private var leadingActionColor: Color {
        if isTapToPlayNextEnabled {
            if isTapPlayNextTriggered || showPlayNowSuccess {
                return Color.green
            } else {
                return appTheme.accentColor
            }
        } else {
            if showPlayNextSuccess {
                return Color.green
            } else if showPlayNextAgain {
                return Color.orange
            } else {
                return appTheme.accentColor
            }
        }
    }

    // Main view layout structure
    public var body: some View {
        ZStack {
            // Leading "PLAY NEXT" / "PLAY NOW" / "PLAYING" Action Surface Revealed on Swipe Right or Tap-to-Play-Next
            if isLeadingSurfaceVisible {
                HStack(spacing: 0) {
                    Text(leadingActionText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minWidth: 84)
                        .background(leadingActionColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .scaleEffect(0.90 + (0.10 * leadingRevealProgress))
                        .opacity(isLeadingBadgeVisible ? 1.0 : leadingRevealProgress)
                    Spacer()
                }
                .padding(.leading, 8)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: leadingActionText)
                .animation(.easeInOut(duration: 0.2), value: leadingActionColor)
            }

            // Trailing "QUEUE" Action Surface Revealed on Swipe Left
            if isTrailingSurfaceVisible {
                HStack(spacing: 0) {
                    Spacer()
                    Text(showQueueSuccess ? "QUEUED" : (showQueueAgain ? "AGAIN?" : "QUEUE"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minWidth: 70)
                        .background(
                            showQueueSuccess
                                ? Color.green
                                : (showQueueAgain ? Color.orange : appTheme.accentColor)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .scaleEffect(0.90 + (0.10 * trailingRevealProgress))
                        .opacity(isTrailingBadgeVisible ? 1.0 : trailingRevealProgress)
                }
                .padding(.trailing, 8)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: showQueueSuccess)
                .animation(.easeInOut(duration: 0.2), value: showQueueAgain)
            }

            // Main Row Content
            HStack(spacing: 12) {
                // Leading Album Cover Thumbnail (Tappable to Open Album)
                if let onSelectAlbum = onSelectAlbum {
                    albumThumbnailView
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if abs(currentOffset) > 5 {
                                resetOffset()
                                return
                            }
                            HapticFeedback.lightImpact()
                            onSelectAlbum()
                        }
                } else {
                    albumThumbnailView
                }

                // Track Title & Subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: isCurrentTrack ? .bold : .medium))
                        .foregroundStyle(isCurrentTrack ? appTheme.accentColor : Color.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Track Duration or Custom Trailing Label (e.g. Play Count)
                if let customText = trailingText {
                    Text(customText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isCurrentTrack ? appTheme.accentColor : .secondary)
                } else {
                    Text(TimeFormatting.format(seconds: track.duration))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(isCurrentTrack ? appTheme.accentColor : .secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                isCurrentTrack
                    ? appTheme.secondaryBackgroundColor.opacity(0.5)
                    : appTheme.backgroundColor
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if abs(currentOffset) > 5 {
                    resetOffset()
                    return
                }
                if isTapToPlayNextEnabled {
                    triggerTapPlayNext()
                } else {
                    onPlay()
                }
            }
            .offset(x: currentOffset)
            // Interactive drag and touch gesture handling
            .highPriorityGesture(
                isSwipeDisabled ? nil : DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .updating($gestureDragOffset) { value, state, _ in
                        let translationX = value.translation.width
                        let translationY = value.translation.height

                        // Immediately yield to vertical scrolling if any vertical motion occurs
                        if abs(translationY) > 4 && abs(translationY) * 1.2 >= abs(translationX) {
                            state = 0
                            return
                        }

                        // Only track horizontal displacement if horizontal motion clearly dominates
                        if abs(translationX) > 20 && abs(translationX) > abs(translationY) * 1.8 {
                            if translationX > leadingActivationThreshold {
                                let extra = translationX - leadingActivationThreshold
                                state = leadingActivationThreshold + (extra * 0.35)
                            } else if translationX < -trailingActivationThreshold {
                                let extra = translationX + trailingActivationThreshold
                                state = -trailingActivationThreshold + (extra * 0.35)
                            } else {
                                state = translationX
                            }
                        } else {
                            state = 0
                        }
                    }
                    .onEnded { value in
                        let translationX = value.translation.width
                        let translationY = value.translation.height

                        // Require clearly horizontal motion
                        let isSwipeRight = translationX >= leadingActivationThreshold && translationX > abs(translationY) * 1.8
                        let isSwipeLeft = translationX <= -trailingActivationThreshold && abs(translationX) > abs(translationY) * 1.8

                        guard isSwipeRight || isSwipeLeft else {
                            if dragOffset != 0 {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                                    dragOffset = 0
                                }
                            }
                            return
                        }

                        if translationX <= -trailingActivationThreshold {
                            let clampedOffset = max(translationX, -trailingActivationThreshold * 1.25)
                            dragOffset = clampedOffset
                            triggerQueue()
                        } else if translationX >= leadingActivationThreshold {
                            let clampedOffset = min(translationX, leadingActivationThreshold * 1.25)
                            dragOffset = clampedOffset
                            if isTapToPlayNextEnabled {
                                triggerPlayNow()
                            } else {
                                triggerPlayNext()
                            }
                        }
                    }
            )
            .onDisappear {
                resetOffset()
            }
        }
        .contextMenu {
            if isTapToPlayNextEnabled {
                Button(action: onPlay) {
                    Text("PLAY NOW")
                }
            }
            Button(action: triggerPlayNext) {
                Text("PLAY NEXT")
            }
            Button(action: triggerQueue) {
                Text("QUEUE")
            }

            // Artists
            let artists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if !artists.isEmpty, let onSelectArtist = onSelectArtist {
                if artists.count == 1, let firstArtist = artists.first {
                    Button(action: {
                        onSelectArtist(firstArtist)
                    }) {
                        Text("GO TO ARTIST")
                    }
                } else {
                    Menu {
                        ForEach(artists, id: \.self) { artistName in
                            Button(action: {
                                onSelectArtist(artistName)
                            }) {
                                Text(artistName)
                            }
                        }
                    } label: {
                        Text("GO TO ARTIST")
                    }
                }
            }

            if let onSelectAlbum = onSelectAlbum, !track.album.isEmpty {
                Button(action: onSelectAlbum) {
                    Text("GO TO ALBUM")
                }
            }

            Button(action: onAddToPlaylist) {
                Text("ADD TO PLAYLIST")
            }

            if let onRemove = onRemoveFromPlaylist {
                Button(role: .destructive, action: onRemove) {
                    Text("REMOVE FROM PLAYLIST")
                }
            }

            Button(action: onShowInfo) {
                Text("FILE INFO")
            }
        }
    }

    // Trigger tap play next (used when tap-to-play-next is enabled and track is tapped)
    private func triggerTapPlayNext() {
        dismissTask?.cancel()
        HapticFeedback.notificationSuccess()
        onPlayNext()
        isTapPlayNextTriggered = true
        isLeadingBadgeVisible = true
        showPlayNowSuccess = false
        showPlayNextSuccess = false
        showPlayNextAgain = false

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragOffset = activationThreshold
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                dragOffset = 0
                isLeadingBadgeVisible = false
                isTapPlayNextTriggered = false
            }
        }
    }

    // Trigger play now (used when swipe-right while tap-to-play-next is enabled)
    private func triggerPlayNow() {
        dismissTask?.cancel()
        HapticFeedback.notificationSuccess()
        onPlay()
        showPlayNowSuccess = true
        isLeadingBadgeVisible = true
        isTapPlayNextTriggered = false
        showPlayNextSuccess = false
        showPlayNextAgain = false

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragOffset = activationThreshold
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                dragOffset = 0
                isLeadingBadgeVisible = false
                showPlayNowSuccess = false
            }
        }
    }

    // Trigger play next (swipe right when tap-to-play-next is disabled)
    private func triggerPlayNext() {
        dismissTask?.cancel()
        HapticFeedback.notificationSuccess()
        onPlayNext()
        showPlayNextSuccess = true
        isLeadingBadgeVisible = true
        showPlayNextAgain = false

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragOffset = activationThreshold
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                dragOffset = 0
                isLeadingBadgeVisible = false
                showPlayNextSuccess = false
            }
        }
    }

    // Trigger queue (swipe left)
    private func triggerQueue() {
        dismissTask?.cancel()
        HapticFeedback.notificationSuccess()
        onQueueNext()
        showQueueSuccess = true
        isTrailingBadgeVisible = true
        showQueueAgain = false

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragOffset = -trailingActivationThreshold
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                dragOffset = 0
                isTrailingBadgeVisible = false
                showQueueSuccess = false
            }
        }
    }

    // Confirm again
    private func confirmAgain(isPlayNext: Bool) {
        dismissTask?.cancel()
        HapticFeedback.notificationSuccess()

        if isPlayNext {
            showPlayNextAgain = false
            showPlayNextSuccess = true
            isLeadingBadgeVisible = true
            onPlayNext()
        } else {
            showQueueAgain = false
            showQueueSuccess = true
            isTrailingBadgeVisible = true
            onQueueNext()
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                dragOffset = 0
                isLeadingBadgeVisible = false
                isTrailingBadgeVisible = false
                showPlayNextSuccess = false
                showQueueSuccess = false
            }
        }
    }

    private var albumThumbnailView: some View {
        ZStack(alignment: .bottomTrailing) {
            AlbumArtworkView(
                artworkKey: track.artworkKey,
                title: track.album,
                subtitle: track.artist,
                cornerRadius: 6
            )
            .frame(width: 42, height: 42)

            if isCurrentTrack {
                Text(isPlaying ? "PLAYING" : "PAUSED")
                    .font(.system(size: 6.5, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.appInvertedBackground)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.5)
                    .background(appTheme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .offset(x: 2, y: 2)
                    .contentTransition(.opacity)
                    // Smooth UI transition animation
                    .animation(.easeInOut(duration: 0.22), value: isPlaying)
            } else if isNextTrack {
                Text("NEXT")
                    .font(.system(size: 6.5, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.5)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .offset(x: 2, y: 2)
                    .contentTransition(.opacity)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .contentShape(Rectangle())
    }

    // Reset offset immediately
    private func resetOffset() {
        dismissTask?.cancel()
        dismissTask = nil
        dragOffset = 0
        isLeadingBadgeVisible = false
        isTrailingBadgeVisible = false
        showPlayNextAgain = false
        showQueueAgain = false
        showPlayNextSuccess = false
        showQueueSuccess = false
        showPlayNowSuccess = false
        isTapPlayNextTriggered = false
    }
}



