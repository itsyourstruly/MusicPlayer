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
    /// When false, the leading artwork is replaced by the list index (or a status label).
    public let showsArtwork: Bool
    /// When true, the row fill is clear so the page backdrop shows through (album pages).
    public let usesClearBackground: Bool
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
    // On hide track
    public let onHideTrack: (() -> Void)?
    // Library store used only by the QUICK ADD TO... submenu (read inside the submenu, not the row)
    public let quickAddLibraryStore: LibraryStore?
    // Playlist hidden from QUICK ADD TO... (the playlist currently being viewed)
    public let quickAddExcludedPlaylistID: UUID?
    // Flag indicating if swipe disabled
    public let isSwipeDisabled: Bool
    // Trailing text
    public let trailingText: String?
    // Library select mode: selected badge, tap toggles, swipes off
    public let isSelected: Bool
    public let isSelectMode: Bool
    // SELECT / DESELECT in the long-press menu (nil hides it)
    public let onToggleSelect: (() -> Void)?
    // Leaves the long-press menu off (e.g. rows in a drag-to-reorder list)
    public let isContextMenuDisabled: Bool

    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool
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
        showsArtwork: Bool = true,
        usesClearBackground: Bool = false,
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
        onSelectAlbum: (() -> Void)? = nil,
        onHideTrack: (() -> Void)? = nil,
        quickAddLibraryStore: LibraryStore? = nil,
        quickAddExcludedPlaylistID: UUID? = nil,
        isSelected: Bool = false,
        isSelectMode: Bool = false,
        onToggleSelect: (() -> Void)? = nil,
        isContextMenuDisabled: Bool = false
    ) {
        self.track = track
        self.indexNumber = indexNumber
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying
        self.isNextTrack = isNextTrack
        self.isInPlayNext = isInPlayNext
        self.isTapToPlayNextEnabled = isTapToPlayNextEnabled
        self.showAlbumSubtitle = showAlbumSubtitle
        self.showsArtwork = showsArtwork
        self.usesClearBackground = usesClearBackground
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
        self.onHideTrack = onHideTrack
        self.quickAddLibraryStore = quickAddLibraryStore
        self.quickAddExcludedPlaylistID = quickAddExcludedPlaylistID
        self.isSelected = isSelected
        self.isSelectMode = isSelectMode
        self.onToggleSelect = onToggleSelect
        self.isContextMenuDisabled = isContextMenuDisabled
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
    private var rowContent: some View {
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
                    let queueText = showQueueSuccess ? "QUEUED" : (showQueueAgain ? "AGAIN?" : "QUEUE")
                    Text(AppCapitalization.format(queueText, enabled: isCaps))
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
                // Leading artwork (default) or list index / status (album pages)
                if let onSelectAlbum = onSelectAlbum {
                    leadingAccessoryView
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if abs(currentOffset) > 5 {
                                resetOffset()
                                return
                            }
                            if isSelectMode {
                                toggleSelection()
                                return
                            }
                            HapticFeedback.lightImpact()
                            onSelectAlbum()
                        }
                } else {
                    leadingAccessoryView
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

                // Track Duration or Custom Trailing Label (e.g. Play Count) with Cloud Status Badge
                HStack(spacing: 5) {
                    CloudStatusBadge(track: track, tintColor: isCurrentTrack ? appTheme.accentColor : .secondary)

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
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(rowBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if abs(currentOffset) > 5 {
                    resetOffset()
                    return
                }
                if isSelectMode {
                    toggleSelection()
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
            .simultaneousGesture(
                (isSwipeDisabled || isSelectMode) ? nil : DragGesture(minimumDistance: 24, coordinateSpace: .global)
                    .updating($gestureDragOffset) { value, state, _ in
                        let translationX = value.translation.width
                        let translationY = value.translation.height

                        // Yield immediately to system screen-edge swipe-to-go-back gesture
                        if value.startLocation.x <= 44 && translationX > 0 {
                            state = 0
                            return
                        }

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

                        // Yield immediately if swipe originated near the left screen edge
                        if value.startLocation.x <= 44 && translationX > 0 {
                            if dragOffset != 0 {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                                    dragOffset = 0
                                }
                            }
                            return
                        }

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
    }

    // Main view layout structure
    public var body: some View {
        if isContextMenuDisabled {
            rowContent
        } else {
            rowContent.contextMenu { contextMenuItems }
        }
    }

    // Long-press menu items
    @ViewBuilder
    private var contextMenuItems: some View {
            Button(action: triggerPlayNext) {
                Text(AppCapitalization.format("PLAY NEXT", enabled: isCaps))
            }
            Button(action: { triggerQueue(appendToEnd: true) }) {
                Text(AppCapitalization.format("QUEUE", enabled: isCaps))
            }

            // Artists
            let artists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if !artists.isEmpty, let onSelectArtist = onSelectArtist {
                if artists.count == 1, let firstArtist = artists.first {
                    Button(action: {
                        onSelectArtist(firstArtist)
                    }) {
                        Text(AppCapitalization.format("GO TO ARTIST", enabled: isCaps))
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
                        Text(AppCapitalization.format("GO TO ARTIST", enabled: isCaps))
                    }
                }
            }

            if let onSelectAlbum = onSelectAlbum, !track.album.isEmpty {
                Button(action: onSelectAlbum) {
                    Text(AppCapitalization.format("GO TO ALBUM", enabled: isCaps))
                }
            }

            Button(action: onAddToPlaylist) {
                Text(AppCapitalization.format("ADD TO PLAYLIST", enabled: isCaps))
            }

            if let quickAddLibraryStore {
                QuickAddToPlaylistMenu(tracks: [track], libraryStore: quickAddLibraryStore, excludedPlaylistID: quickAddExcludedPlaylistID)
            }

            // Playlist rows (the only rows with REMOVE FROM PLAYLIST) skip download, SELECT and HIDE TRACK.
            if onRemoveFromPlaylist == nil {
                // Current/next state comes in as values so rows don't observe the player during render.
                TrackDownloadMenuItems(track: track, isPlayingOrNext: isCurrentTrack || isNextTrack, removeDownloadAtBottom: true)
            }

            Button(action: onShowInfo) {
                Text(AppCapitalization.format("FILE INFO", enabled: isCaps))
            }

            if let onRemove = onRemoveFromPlaylist {
                Button(role: .destructive, action: onRemove) {
                    Text(AppCapitalization.format("REMOVE FROM PLAYLIST", enabled: isCaps))
                }
            } else {
                libraryOnlyMenuItems
            }
    }

    // SELECT / HIDE TRACK or REMOVE DOWNLOAD (not shown in playlists)
    @ViewBuilder
    private var libraryOnlyMenuItems: some View {
            if let onToggleSelect {
                Button(action: onToggleSelect) {
                    Text(AppCapitalization.format(isSelected ? "DESELECT" : "SELECT", enabled: isCaps))
                }
            }

            TrackMenuBottomItem(track: track, isPlayingOrNext: isCurrentTrack || isNextTrack) {
                HapticFeedback.notificationWarning()
                if let onHideTrack = onHideTrack {
                    onHideTrack()
                } else {
                    NotificationCenter.default.post(name: .hideTrackRequested, object: nil, userInfo: ["track": track])
                }
            }
    }

    // Select-mode tap: toggle this track in the Library selection
    private func toggleSelection() {
        resetOffset()
        HapticFeedback.selectionChanged()
        onToggleSelect?()
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

    // Trigger queue (swipe left uses onQueueNext; the context menu appends to the end of the queue)
    private func triggerQueue(appendToEnd: Bool = false) {
        dismissTask?.cancel()
        HapticFeedback.notificationSuccess()
        if appendToEnd {
            onAddToQueue()
        } else {
            onQueueNext()
        }
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

    private var rowBackgroundColor: Color {
        if usesClearBackground {
            return Color.clear
        }
        return isCurrentTrack
            ? appTheme.secondaryBackgroundColor.opacity(0.5)
            : appTheme.backgroundColor
    }

    /// Same priority as the artwork badges: SELECTED, PLAYING/PAUSED, NEXT; otherwise the list index.
    private var leadingStatusOrIndexText: String {
        if isSelected {
            return "SELECTED"
        }
        if isCurrentTrack {
            return isPlaying ? "PLAYING" : "PAUSED"
        }
        if isNextTrack {
            return "NEXT"
        }
        if let indexNumber, indexNumber > 0 {
            return "\(indexNumber)"
        }
        return "—"
    }

    private var leadingStatusOrIndexIsStatus: Bool {
        isSelected || isCurrentTrack || isNextTrack
    }

    @ViewBuilder
    private var leadingAccessoryView: some View {
        if showsArtwork {
            albumThumbnailView
        } else {
            Text(leadingStatusOrIndexText)
                .font(.system(
                    size: leadingStatusOrIndexIsStatus ? 8 : 13,
                    weight: .bold,
                    design: .monospaced
                ))
                .foregroundStyle(isCurrentTrack || isSelected ? appTheme.accentColor : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 42, height: 42)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: isPlaying)
                .contentShape(Rectangle())
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

            if isSelected {
                Text("SELECTED")
                    .font(.system(size: 6.5, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.appInvertedBackground)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.5)
                    .background(appTheme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .offset(x: 2, y: 2)
                    .contentTransition(.opacity)
            } else if isCurrentTrack {
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

/// Shared download menu items for a single track (server downloads, or evicting a downloaded iCloud file).
/// A separate view so the download state is only read when the menu content renders.
public struct TrackDownloadMenuItems: View {
    public let track: Track
    public let isPlayingOrNext: Bool
    /// When true, REMOVE DOWNLOAD is left out here because the menu shows it at the bottom (TrackMenuBottomItem).
    public let removeDownloadAtBottom: Bool

    public init(track: Track, isPlayingOrNext: Bool, removeDownloadAtBottom: Bool = false) {
        self.track = track
        self.isPlayingOrNext = isPlayingOrNext
        self.removeDownloadAtBottom = removeDownloadAtBottom
    }

    public var body: some View {
        let removeShownAtBottom = removeDownloadAtBottom
            && trackMenuBottomAction(for: track, isPlayingOrNext: isPlayingOrNext) == .removeDownload
        if track.canReadLocalBytes && track.metadataSource != .server {
            let isUbiquitous = (try? track.url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            if isUbiquitous && !isPlayingOrNext && !removeShownAtBottom {
                Button(role: .destructive) {
                    removeTrackDownload(track)
                } label: {
                    Text("REMOVE DOWNLOAD")
                }
            }
        } else if track.isJellyfinItem || track.metadataSource == .server {
            if JellyfinDownloadManager.shared.isDownloaded(trackId: track.id) {
                if !removeShownAtBottom {
                    Button(role: .destructive) {
                        removeTrackDownload(track)
                    } label: {
                        Text("REMOVE DOWNLOAD")
                    }
                }
            } else {
                let state = JellyfinDownloadManager.shared.downloadStates[track.id, default: .notDownloaded]
                if state.isDownloading {
                    if JellyfinDownloadManager.shared.isWaitingForWiFi {
                        Button {} label: {
                            Text("WAITING FOR WI-FI")
                        }
                        .disabled(true)
                    }
                    Button {
                        HapticFeedback.selectionChanged()
                        JellyfinDownloadManager.shared.cancelDownload(trackId: track.id)
                    } label: {
                        Text("CANCEL DOWNLOAD")
                    }
                } else if state.isFailed {
                    Button {
                        HapticFeedback.selectionChanged()
                        JellyfinDownloadManager.shared.download(track: track)
                    } label: {
                        Text("DOWNLOAD FAILED, TAP TO RETRY")
                    }
                } else {
                    Button {
                        HapticFeedback.selectionChanged()
                        JellyfinDownloadManager.shared.download(track: track)
                    } label: {
                        Text("DOWNLOAD TRACK")
                    }
                }
            }
        }
    }
}

/// What a track menu shows in its bottom (red) slot.
public enum TrackMenuBottomAction: Equatable {
    case hide
    case removeDownload
    case none
}

/// Downloaded tracks (server download, or an iCloud file stored on the phone) show REMOVE DOWNLOAD instead of HIDE TRACK;
/// a server track that is downloading shows neither; an iCloud track playing or up next (can't be removed) and plain local files show HIDE.
@MainActor public func trackMenuBottomAction(for track: Track, isPlayingOrNext: Bool) -> TrackMenuBottomAction {
    #if os(macOS)
    return .hide
    #else
    if track.canReadLocalBytes && track.metadataSource != .server {
        let isUbiquitous = (try? track.url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        return isUbiquitous && !isPlayingOrNext ? .removeDownload : .hide
    }
    if track.isJellyfinItem || track.metadataSource == .server {
        if JellyfinDownloadManager.shared.isDownloaded(trackId: track.id) { return .removeDownload }
        let state = JellyfinDownloadManager.shared.downloadStates[track.id, default: .notDownloaded]
        return state.isDownloading ? .none : .hide
    }
    return .hide
    #endif
}

/// Removes a track's local download: deletes a server download, or evicts a downloaded iCloud file (never the playing/next track).
@MainActor public func removeTrackDownload(_ track: Track) {
    if track.isJellyfinItem || track.metadataSource == .server {
        HapticFeedback.selectionChanged()
        JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
    } else {
        // Re-check live player state at tap time (callers that omit the flags stay safe).
        let player = AudioPlayerService.shared
        guard player?.currentTrack?.id != track.id, player?.nextTrack?.id != track.id else { return }
        try? FileManager.default.evictUbiquitousItem(at: track.url)
    }
}

/// Bottom item of a track's long-press menu: REMOVE DOWNLOAD, HIDE TRACK, or nothing (see `trackMenuBottomAction`).
public struct TrackMenuBottomItem: View {
    public let track: Track
    public let isPlayingOrNext: Bool
    public let onHide: () -> Void

    public init(track: Track, isPlayingOrNext: Bool, onHide: @escaping () -> Void) {
        self.track = track
        self.isPlayingOrNext = isPlayingOrNext
        self.onHide = onHide
    }

    public var body: some View {
        switch trackMenuBottomAction(for: track, isPlayingOrNext: isPlayingOrNext) {
        case .removeDownload:
            Button(role: .destructive) {
                removeTrackDownload(track)
            } label: {
                Text("REMOVE DOWNLOAD")
            }
        case .hide:
            Button(role: .destructive, action: onHide) {
                Text("HIDE TRACK")
            }
        case .none:
            EmptyView()
        }
    }
}
