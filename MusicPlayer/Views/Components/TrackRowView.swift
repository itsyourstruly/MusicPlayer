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
    @State private var dragOffset: CGFloat = 0
    @State private var hasPassedThreshold: Bool = false
    @State private var showPlayNextSuccess: Bool = false
    @State private var showQueueNextSuccess: Bool = false
    @State private var showPlayNextAgain: Bool = false
    @State private var showQueueNextAgain: Bool = false
    @State private var isHorizontalDragActive: Bool = false
    @State private var againDismissTask: Task<Void, Never>? = nil

    // Activation threshold
    private let activationThreshold: CGFloat = 75

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

    private var trailingRevealProgress: Double {
        min(1.0, max(0.0, Double(-dragOffset) / Double(activationThreshold)))
    }

    private var leadingRevealProgress: Double {
        min(1.0, max(0.0, Double(dragOffset) / Double(activationThreshold)))
    }

    // Main view layout structure
    public var body: some View {
        ZStack {
            // Leading "PLAY NEXT" Action Surface Revealed on Swipe Right
            if dragOffset > 0 || showPlayNextSuccess || showPlayNextAgain {
                HStack {
                    Button(action: {
                        if showPlayNextAgain {
                            confirmAgain(isPlayNext: true)
                        }
                    }) {
                        Text(showPlayNextSuccess ? "QUEUED" : (showPlayNextAgain ? "AGAIN?" : "PLAY NEXT"))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.appInvertedBackground)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                showPlayNextSuccess
                                    ? Color.green
                                    : (showPlayNextAgain ? Color.orange : appTheme.accentColor)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .scaleEffect(0.90 + (0.10 * leadingRevealProgress))
                            .opacity((showPlayNextSuccess || showPlayNextAgain) ? 1.0 : leadingRevealProgress)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.leading, 6)
            }

            // Trailing "QUEUE NEXT" Action Surface Revealed on Swipe Left
            if dragOffset < 0 || showQueueNextSuccess || showQueueNextAgain {
                HStack {
                    Spacer()
                    Button(action: {
                        if showQueueNextAgain {
                            confirmAgain(isPlayNext: false)
                        }
                    }) {
                        Text(showQueueNextSuccess ? "QUEUED" : (showQueueNextAgain ? "AGAIN?" : "QUEUE NEXT"))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.appInvertedBackground)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                showQueueNextSuccess
                                    ? Color.green
                                    : (showQueueNextAgain ? Color.orange : appTheme.accentColor)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .scaleEffect(0.90 + (0.10 * trailingRevealProgress))
                            .opacity((showQueueNextSuccess || showQueueNextAgain) ? 1.0 : trailingRevealProgress)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 6)
            }

            // Main Row Content
            HStack(spacing: 12) {
                // Leading Album Cover Thumbnail (Tappable to Open Album)
                if let onSelectAlbum = onSelectAlbum {
                    Button(action: {
                        HapticFeedback.lightImpact()
                        onSelectAlbum()
                    }) {
                        albumThumbnailView
                    }
                    .buttonStyle(.plain)
                } else {
                    albumThumbnailView
                }

                // Track Title & Subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: isCurrentTrack ? .bold : .medium))
                        .foregroundStyle(isCurrentTrack ? appTheme.accentColor : Color.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(track.artist)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if showAlbumSubtitle && !track.album.isEmpty {
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary.opacity(0.6))

                            Text(track.album)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
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
                if showPlayNextAgain {
                    confirmAgain(isPlayNext: true)
                } else if showQueueNextAgain {
                    confirmAgain(isPlayNext: false)
                } else if abs(dragOffset) > 5 {
                    resetOffset()
                } else if isTapToPlayNextEnabled {
                    triggerQueueNext()
                } else {
                    onPlay()
                }
            }
            .offset(x: dragOffset)
            // Interactive drag and touch gesture handling
            .simultaneousGesture(
                isSwipeDisabled ? nil : DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { value in
                        // Translation x
                        let translationX = value.translation.width
                        // Translation y
                        let translationY = value.translation.height

                        // Only capture horizontal swipe if movement is predominantly horizontal
                        if !isHorizontalDragActive {
                            if abs(translationX) > 12 && abs(translationX) > (abs(translationY) * 1.5) {
                                isHorizontalDragActive = true
                            }
                        }

                        if isHorizontalDragActive {
                            dragOffset = translationX

                            // Passed
                            let passed = (translationX <= -activationThreshold) || (translationX >= activationThreshold)
                            if passed != hasPassedThreshold {
                                hasPassedThreshold = passed
                                if passed {
                                    HapticFeedback.lightImpact()
                                }
                            }
                        }
                    }
                    .onEnded { value in
                        if isHorizontalDragActive {
                            isHorizontalDragActive = false
                            if value.translation.width <= -activationThreshold {
                                triggerQueueNext()
                            } else if value.translation.width >= activationThreshold {
                                triggerPlayNext()
                            } else {
                                resetOffset()
                            }
                        } else {
                            resetOffset()
                        }
                    }
            )
        }
        .contextMenu {
            Button(action: onPlayNext) {
                Text("PLAY NEXT")
            }
            Button(action: onQueueNext) {
                Text("QUEUE NEXT")
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

    // Trigger play next
    private func triggerPlayNext() {
        if isInPlayNext {
            HapticFeedback.notificationWarning()
            showPlayNextAgain = true
            showPlayNextSuccess = false

            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                dragOffset = activationThreshold
            }

            againDismissTask?.cancel()
            againDismissTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            dragOffset = 0
                            hasPassedThreshold = false
                            showPlayNextAgain = false
                        }
                    }
                }
            }
        } else {
            HapticFeedback.notificationSuccess()
            showPlayNextSuccess = true
            showPlayNextAgain = false
            onPlayNext()

            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                dragOffset = activationThreshold
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    dragOffset = 0
                    hasPassedThreshold = false
                    showPlayNextSuccess = false
                }
            }
        }
    }

    // Trigger queue next
    private func triggerQueueNext() {
        if isInPlayNext {
            HapticFeedback.notificationWarning()
            showQueueNextAgain = true
            showQueueNextSuccess = false

            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                dragOffset = -activationThreshold
            }

            againDismissTask?.cancel()
            againDismissTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            dragOffset = 0
                            hasPassedThreshold = false
                            showQueueNextAgain = false
                        }
                    }
                }
            }
        } else {
            HapticFeedback.notificationSuccess()
            showQueueNextSuccess = true
            showQueueNextAgain = false
            onQueueNext()

            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                dragOffset = -activationThreshold
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    dragOffset = 0
                    hasPassedThreshold = false
                    showQueueNextSuccess = false
                }
            }
        }
    }

    // Confirm again
    private func confirmAgain(isPlayNext: Bool) {
        againDismissTask?.cancel()
        againDismissTask = nil
        HapticFeedback.notificationSuccess()

        if isPlayNext {
            showPlayNextAgain = false
            showPlayNextSuccess = true
            onPlayNext()
        } else {
            showQueueNextAgain = false
            showQueueNextSuccess = true
            onQueueNext()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                dragOffset = 0
                hasPassedThreshold = false
                showPlayNextSuccess = false
                showQueueNextSuccess = false
                showPlayNextAgain = false
                showQueueNextAgain = false
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

    // Reset offset
    private func resetOffset() {
        againDismissTask?.cancel()
        againDismissTask = nil
        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            dragOffset = 0
            hasPassedThreshold = false
            isHorizontalDragActive = false
            showPlayNextAgain = false
            showQueueNextAgain = false
        }
    }
}



