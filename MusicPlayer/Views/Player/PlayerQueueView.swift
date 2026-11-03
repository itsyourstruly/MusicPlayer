import SwiftUI

/// Ultra-high-performance playback queue view optimized for queues containing 20,000+ songs.
/// Only a window of rows around Now Playing is built (the last 50 past songs and the first 200 upcoming);
/// more past songs lazy-load when the top is reached and more upcoming songs when the end is reached.
/// Rows are prepared once in the view model (one row per item, fixed heights), so opening is instant at any size.
public struct PlayerQueueView: View {
    @Bindable var playerService: AudioPlayerService
    var libraryStore: LibraryStore? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var viewModel = QueueViewModel()
    @State private var selectedArtist: Artist? = nil
    @State private var selectedAlbum: Album? = nil
    /// False until the list has been scrolled to Now Playing on open (about one frame with the windowed rows);
    /// the list stays invisible until then so the user never sees it start at the oldest past song and jump.
    @State private var isPositionedAtNowPlaying = false
    /// False until the windowed rows are built (in onAppear), so the List's very first layout already contains
    /// the final rows instead of starting empty and inserting ~250 rows afterwards.
    @State private var rowsReady = false
    /// Initial scroll position: SwiftUI lays the list out with Now Playing at the top instead of the first row.
    @State private var scrollPosition = ScrollPosition(id: "now_playing_item", anchor: .top)
    /// Where rows sit on screen (measurement only; not observed, so it never redraws anything).
    @State private var queueGeometry = QueueGeometry()

    // Initialize with configured properties
    /// Tracks with a finished CACHE IN ADVANCE session file (empty while the feature is off).
    private var sessionCachedTrackIDs: Set<UUID> {
        playerService.cacheInAdvanceEnabled ? SessionCacheStatus.shared.cachedTrackIDs : []
    }

    public init(playerService: AudioPlayerService, libraryStore: LibraryStore? = nil) {
        self.playerService = playerService
        self.libraryStore = libraryStore
    }

    public var body: some View {
        NavigationStack {
            Group {
                if playerService.queue.isEmpty && playerService.currentTrack == nil && playerService.playNextQueue.isEmpty {
                    EmptyStateView(
                        title: "QUEUE IS EMPTY",
                        message: "Play tracks from your library to populate the queue."
                    )
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appTheme.backgroundColor.ignoresSafeArea())
                } else if !rowsReady {
                    // One frame at most: rows are built in onAppear before the list is first laid out.
                    appTheme.backgroundColor
                        .ignoresSafeArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            // 1. PAST SONGS SECTION (Scroll up from Now Playing to view history)
                            if viewModel.totalPastCount > 0 {
                                Section {
                                    // Invisible top sentinel: loads the previous batch of past songs when reached.
                                    if viewModel.hasMorePast {
                                        loadSentinel()
                                            .id("past_load_sentinel")
                                            .onAppear {
                                                viewModel.isPastSentinelVisible = true
                                                loadEarlierPast(proxy: proxy)
                                            }
                                            .onDisappear {
                                                viewModel.isPastSentinelVisible = false
                                            }
                                    }

                                    ForEach(viewModel.pastRows) { row in
                                        let track = row.track
                                        QueueRowView(
                                            entryID: row.id,
                                            trackID: track.id,
                                            title: track.title,
                                            artist: track.artist,
                                            durationText: row.durationText,
                                            artworkKey: track.artworkKey,
                                            albumTitle: track.album,
                                            isNext: false,
                                            kind: .past,
                                            isSessionCached: sessionCachedTrackIDs.contains(track.id),
                                            onTap: {
                                                playerService.playQueueEntry(id: row.id)
                                            },
                                            onRemove: nil,
                                            onMoveSection: {
                                                if let idx = playerService.queue.firstIndex(where: { $0.id == row.id }) {
                                                    playerService.moveFromQueueToPlayNext(
                                                        queueIndex: idx,
                                                        playNextDestinationIndex: playerService.playNextQueue.count
                                                    )
                                                    HapticFeedback.dragDrop()
                                                }
                                            },
                                            onNavigateToArtist: { name in
                                                navigateToArtist(name: name, fallbackTrack: track)
                                            },
                                            onNavigateToAlbum: { title, artist in
                                                navigateToAlbum(title: title, artist: artist, fallbackTrack: track)
                                            }
                                        )
                                        .equatable()
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                    }
                                } header: {
                                    Text("PAST SONGS (\(viewModel.totalPastCount))")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }

                            // 2. NOW PLAYING SECTION (List opens positioned here, anchored at the top).
                            // No section header: a pinned header would sit on top of the row when it is at the top,
                            // so the "NOW PLAYING" label is drawn inside the row instead.
                            if let current = playerService.currentTrack {
                                Section {
                                    NowPlayingQueueRowView(
                                        track: current,
                                        playerService: playerService,
                                        onNavigateToArtist: { name in
                                            navigateToArtist(name: name, fallbackTrack: current)
                                        },
                                        onNavigateToAlbum: { title, artist in
                                            navigateToAlbum(title: title, artist: artist, fallbackTrack: current)
                                        }
                                    )
                                    .id("now_playing_item")
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                }
                            }

                            // 3. QUEUE (PLAY NEXT) SECTION (shown in full)
                            if !viewModel.playNextRows.isEmpty {
                                Section {
                                    ForEach(viewModel.playNextRows) { row in
                                        let track = row.track
                                        QueueRowView(
                                            entryID: row.id,
                                            trackID: track.id,
                                            title: track.title,
                                            artist: track.artist,
                                            durationText: row.durationText,
                                            artworkKey: track.artworkKey,
                                            albumTitle: track.album,
                                            isNext: row.id == viewModel.nextEntryID,
                                            kind: .playNext,
                                            isSessionCached: sessionCachedTrackIDs.contains(track.id),
                                            onTap: {
                                                if let idx = playerService.playNextQueue.firstIndex(where: { $0.id == row.id }) {
                                                    playerService.playFromPlayNext(at: idx)
                                                }
                                            },
                                            onRemove: {
                                                if let idx = playerService.playNextQueue.firstIndex(where: { $0.id == row.id }) {
                                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                        playerService.removePlayNextItem(at: idx)
                                                    }
                                                }
                                            },
                                            onMoveSection: {
                                                if let idx = playerService.playNextQueue.firstIndex(where: { $0.id == row.id }) {
                                                    let baseIndex = (playerService.currentIndex ?? 0) + 1
                                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                        playerService.moveFromPlayNextToQueue(
                                                            playNextIndex: idx,
                                                            queueDestinationIndex: baseIndex
                                                        )
                                                    }
                                                    HapticFeedback.dragDrop()
                                                }
                                            },
                                            onNavigateToArtist: { name in
                                                navigateToArtist(name: name, fallbackTrack: track)
                                            },
                                            onNavigateToAlbum: { title, artist in
                                                navigateToAlbum(title: title, artist: artist, fallbackTrack: track)
                                            }
                                        )
                                        .equatable()
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                    }
                                    .onMove { source, destination in
                                        // Map row offsets to Play Next offsets by entry ID (rows skip unresolvable tracks).
                                        let entries = playerService.playNextQueue
                                        let rows = viewModel.playNextRows
                                        guard let mapped = Self.mapMove(source: source, destination: destination, rows: rows, entries: entries) else { return }
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            playerService.movePlayNextItem(fromOffsets: mapped.source, toOffset: mapped.destination)
                                        }
                                        HapticFeedback.dragDrop()
                                    }
                                } header: {
                                    sectionHeaderView(
                                        title: "QUEUE (\(viewModel.playNextRows.count))",
                                        titleColor: appTheme.accentColor,
                                        onClear: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                playerService.clearPlayNextQueue()
                                            }
                                        }
                                    )
                                }
                            }

                            // 4. UP NEXT SECTION (first window shown; more load at the end)
                            if viewModel.totalUpNextCount > 0 {
                                Section {
                                    ForEach(viewModel.upNextRows) { row in
                                        let track = row.track
                                        QueueRowView(
                                            entryID: row.id,
                                            trackID: track.id,
                                            title: track.title,
                                            artist: track.artist,
                                            durationText: row.durationText,
                                            artworkKey: track.artworkKey,
                                            albumTitle: track.album,
                                            isNext: row.id == viewModel.nextEntryID,
                                            kind: .upNext,
                                            isSessionCached: sessionCachedTrackIDs.contains(track.id),
                                            onTap: {
                                                playerService.playQueueEntry(id: row.id)
                                            },
                                            onRemove: {
                                                if let idx = playerService.queue.firstIndex(where: { $0.id == row.id }) {
                                                    playerService.removeQueueItem(at: idx)
                                                }
                                            },
                                            onMoveSection: {
                                                if let idx = playerService.queue.firstIndex(where: { $0.id == row.id }) {
                                                    playerService.moveFromQueueToPlayNext(
                                                        queueIndex: idx,
                                                        playNextDestinationIndex: playerService.playNextQueue.count
                                                    )
                                                    HapticFeedback.dragDrop()
                                                }
                                            },
                                            onNavigateToArtist: { name in
                                                navigateToArtist(name: name, fallbackTrack: track)
                                            },
                                            onNavigateToAlbum: { title, artist in
                                                navigateToAlbum(title: title, artist: artist, fallbackTrack: track)
                                            }
                                        )
                                        .equatable()
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                    }
                                    .onMove { source, destination in
                                        // Map row offsets to queue indices by entry ID (the window starts after Now Playing).
                                        let entries = playerService.queue
                                        let rows = viewModel.upNextRows
                                        guard let mapped = Self.mapMove(source: source, destination: destination, rows: rows, entries: entries) else { return }
                                        playerService.moveQueueItem(fromOffsets: mapped.source, toOffset: mapped.destination)
                                        HapticFeedback.dragDrop()
                                    }

                                    // Invisible bottom sentinel: appends the next batch of upcoming songs when reached.
                                    if viewModel.hasMoreUpNext {
                                        loadSentinel()
                                            .id("up_next_load_sentinel")
                                            .onAppear {
                                                loadMoreUpNext()
                                            }
                                    }
                                } header: {
                                    sectionHeaderView(
                                        title: "UP NEXT (\(viewModel.totalUpNextCount))",
                                        titleColor: .secondary,
                                        onClear: {
                                            clearUpcoming()
                                        }
                                    )
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(appTheme.backgroundColor.ignoresSafeArea())
                        .scrollPosition($scrollPosition, anchor: .top)
                        .opacity(isPositionedAtNowPlaying ? 1 : 0)
                        .task {
                            // Runs once per open (not on track changes). The initial ScrollPosition should already
                            // lay the list out at Now Playing. As a fallback (List support for ScrollPosition is not
                            // documented, and off-screen row heights are estimated until measured), re-apply the
                            // position without animation over two layout passes while the list is still hidden,
                            // then reveal it. If the list is already positioned these scrolls are no-ops.
                            queueGeometry.proxy = proxy
                            if playerService.currentTrack != nil {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                await Task.yield()
                                withTransaction(transaction) {
                                    proxy.scrollTo("now_playing_item", anchor: .top)
                                }
                                // Wait about one frame so rows above Now Playing are measured, then correct.
                                try? await Task.sleep(for: .milliseconds(17))
                                withTransaction(transaction) {
                                    proxy.scrollTo("now_playing_item", anchor: .top)
                                }
                                await Task.yield()
                            }
                            // Any top-sentinel appearance came from the hidden pre-positioned layout; ignore it.
                            // Lazy-loading resumes when the user actually scrolls the sentinel into view.
                            viewModel.isPastSentinelVisible = false
                            isPositionedAtNowPlaying = true
                        }
                    }
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            // Measurement only (outer container, not the List): the scroll view's visible area in global coordinates.
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).minY
            } action: { minY in
                queueGeometry.containerMinY = minY
            }
            .onScrollGeometryChange(for: QueueScrollMetrics.self) { geometry in
                QueueScrollMetrics(
                    insetTop: geometry.contentInsets.top,
                    visibleHeight: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                )
            } action: { _, metrics in
                queueGeometry.scrollMetrics = metrics
            }
            .environment(\.queueGeometry, queueGeometry)
            .navigationTitle("QUEUE")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedArtist) { artist in
                if let store = libraryStore {
                    ArtistDetailView(artist: artist, libraryStore: store, playerService: playerService)
                }
            }
            .navigationDestination(item: $selectedAlbum) { album in
                if let store = libraryStore {
                    AlbumDetailView(album: album, libraryStore: store, playerService: playerService)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Build the windowed rows before the list's first layout (the list is gated on rowsReady).
            if !viewModel.hasLoaded {
                refreshEntries()
            }
            rowsReady = true
        }
        .onChange(of: playerService.queue) { _, _ in
            refreshEntries()
        }
        .onChange(of: playerService.playNextQueue) { oldValue, newValue in
            // Playing a Play Next song (tap or auto-advance) removes it from Play Next: that is a song change.
            if let playedID = Self.playedPlayNextEntryID(old: oldValue, new: newValue, currentTrackID: playerService.currentTrack?.id),
               viewModel.hasSameQueue(playerService.queue) {
                rebuildForTrackChange(newCurrentRowID: playedID)
            } else {
                refreshEntries()
            }
        }
        .onChange(of: playerService.currentIndex) { _, newValue in
            // A song change within the same queue (tap, auto-advance, previous) keeps the list in place.
            // Anything else (a new queue, shuffle) is a plain rebuild, as before.
            if viewModel.hasSameQueue(playerService.queue),
               viewModel.layoutIndex != max(newValue ?? 0, 0) {
                let queue = playerService.queue
                let newID = newValue.flatMap { queue.indices.contains($0) ? queue[$0].id : nil }
                rebuildForTrackChange(newCurrentRowID: newID)
            } else {
                refreshEntries()
            }
        }
    }

    // MARK: - Keeping the Position on Song Changes

    /// Rebuilds the sections for a song change (the new song becomes the real Now Playing row, the rows above it
    /// become past songs) and, in the same update, scrolls without animation so the list does not jump:
    /// the new Now Playing row takes its old row's spot on screen if that row was visible,
    /// otherwise the topmost visible row stays where it was. Without a usable anchor it behaves as before.
    private func rebuildForTrackChange(newCurrentRowID: UUID?) {
        let anchor = trackChangeAnchor(newCurrentRowID: newCurrentRowID) // measured before the rebuild
        if anchor != nil {
            // Release the opening position only now (tap / auto-advance time), so it cannot pull the list
            // back to Now Playing. Opening behavior is unchanged.
            scrollPosition.isPositionedByUser = true
        }
        refreshEntries()
        if let anchor {
            applyAnchor(anchor)
        }
    }

    private func trackChangeAnchor(newCurrentRowID: UUID?) -> QueueScrollAnchor? {
        let geo = queueGeometry
        guard isPositionedAtNowPlaying, geo.proxy != nil, geo.visibleHeight > 0 else { return nil }
        let visibleTop = geo.visibleTop
        let visibleBottom = visibleTop + geo.visibleHeight
        func isVisible(_ top: CGFloat) -> Bool {
            top < visibleBottom && top + 40 > visibleTop
        }
        if let id = newCurrentRowID, let top = geo.rowTops[id], isVisible(top) {
            return .nowPlaying(top: top)
        }
        if let topmost = geo.rowTops.filter({ isVisible($0.value) }).min(by: { $0.value < $1.value }) {
            return .row(id: topmost.key, top: topmost.value)
        }
        return nil
    }

    /// Scrolls (no animation) so the anchor row's content top lands at its saved screen position, then corrects
    /// up to twice from the measured position (the List estimates heights of rows it has not laid out yet).
    private func applyAnchor(_ anchor: QueueScrollAnchor) {
        let geo = queueGeometry
        guard let proxy = geo.proxy else { return }
        let target: CGFloat
        let cellHeight: CGFloat
        let scroll: (UnitPoint) -> Void
        let measure: () -> CGFloat?
        switch anchor {
        case .nowPlaying(let top):
            guard playerService.currentTrack != nil else { return }
            target = top
            cellHeight = 76 + 8 // row + list row insets
            scroll = { proxy.scrollTo("now_playing_item", anchor: $0) }
            measure = { geo.nowPlayingTop }
        case .row(let id, let top):
            guard viewModel.containsRow(id) else { return }
            target = top
            cellHeight = (viewModel.isPastRow(id) ? 46 : 48) + 8
            scroll = { proxy.scrollTo(id, anchor: $0) }
            measure = { geo.rowTops[id] }
        }

        geo.isReanchoring = true
        geo.reanchorGeneration += 1
        let generation = geo.reanchorGeneration
        var transaction = Transaction()
        transaction.disablesAnimations = true
        var fraction = anchorFraction(contentTop: target, cellHeight: cellHeight)
        withTransaction(transaction) {
            scroll(UnitPoint(x: 0.5, y: fraction))
        }

        Task { @MainActor in
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(17))
                guard generation == geo.reanchorGeneration else { return }
                let available = geo.visibleHeight - cellHeight
                guard let measured = measure(), available > 1 else { break }
                let error = measured - target
                guard abs(error) > 0.5 else { break }
                let corrected = min(max(fraction - error / available, 0), 1)
                guard abs(corrected - fraction) > 0.0001 else { break } // clamped at the list's edge
                fraction = corrected
                withTransaction(transaction) {
                    scroll(UnitPoint(x: 0.5, y: fraction))
                }
            }
            await Task.yield()
            guard generation == geo.reanchorGeneration else { return }
            geo.isReanchoring = false
            // Lazy loading was paused during the re-anchor; resume anything that was requested meanwhile.
            if viewModel.isPastSentinelVisible {
                loadEarlierPast(proxy: proxy)
            }
            if geo.pendingUpNextLoad {
                geo.pendingUpNextLoad = false
                loadMoreUpNext()
            }
        }
    }

    /// scrollTo with anchor y = f aligns that point of the row with the same point of the visible area,
    /// so the row's top lands at visibleTop + f * (visibleHeight - rowHeight). Solved for f.
    private func anchorFraction(contentTop: CGFloat, cellHeight: CGFloat) -> CGFloat {
        let geo = queueGeometry
        let available = geo.visibleHeight - cellHeight
        guard available > 1 else { return 0 }
        let cellTop = contentTop - 4 // list row inset above the row content
        return min(max((cellTop - geo.visibleTop) / available, 0), 1)
    }

    /// If `new` is `old` minus exactly one entry and that entry is the song now playing, returns its ID.
    private static func playedPlayNextEntryID(old: [QueueEntry], new: [QueueEntry], currentTrackID: UUID?) -> UUID? {
        guard let currentTrackID, old.count == new.count + 1 else { return nil }
        var i = 0
        while i < new.count && old[i].id == new[i].id {
            i += 1
        }
        guard old[i].trackID == currentTrackID,
              old[(i + 1)...].map(\.id) == new[i...].map(\.id) else { return nil }
        return old[i].id
    }

    // MARK: - Windowing

    /// Rebuilds the windowed rows from the player's current queue state (never scrolls).
    private func refreshEntries() {
        let service = playerService
        viewModel.update(
            queue: service.queue,
            playNextQueue: service.playNextQueue,
            currentIndex: service.currentIndex,
            resolve: { entry in service.track(for: entry) }
        )
    }

    /// Thin invisible row used to trigger lazy loading at the top or bottom of the window.
    private func loadSentinel() -> some View {
        Color.clear
            .frame(height: 1)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
    }

    /// Prepends the previous batch of past songs and keeps the previously-top row anchored so nothing jumps.
    private func loadEarlierPast(proxy: ScrollViewProxy) {
        guard isPositionedAtNowPlaying, !queueGeometry.isReanchoring, !viewModel.isLoadingPast, viewModel.hasMorePast else { return }
        viewModel.isLoadingPast = true
        let anchorID = viewModel.pastRows.first?.id
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.loadEarlierPast()
        }
        Task { @MainActor in
            await Task.yield()
            if let anchorID {
                withTransaction(transaction) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
            await Task.yield()
            viewModel.isLoadingPast = false
        }
    }

    /// Appends the next batch of upcoming songs (rows are added below, so the scroll position is unaffected).
    private func loadMoreUpNext() {
        if queueGeometry.isReanchoring {
            // Paused while re-anchoring; resumed when the re-anchor finishes.
            queueGeometry.pendingUpNextLoad = true
            return
        }
        guard !viewModel.isLoadingUpNext, viewModel.hasMoreUpNext else { return }
        viewModel.isLoadingUpNext = true
        viewModel.loadMoreUpNext()
        Task { @MainActor in
            await Task.yield()
            viewModel.isLoadingUpNext = false
        }
    }

    /// Maps List row offsets (from .onMove) to offsets in the underlying entry array, matching by entry ID.
    private static func mapMove(source: IndexSet, destination: Int, rows: [QueueRowData], entries: [QueueEntry]) -> (source: IndexSet, destination: Int)? {
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            indexByID[entry.id] = index
        }
        var mappedSource = IndexSet()
        for offset in source where rows.indices.contains(offset) {
            if let index = indexByID[rows[offset].id] {
                mappedSource.insert(index)
            }
        }
        guard !mappedSource.isEmpty else { return nil }
        let mappedDestination: Int
        if rows.indices.contains(destination), let index = indexByID[rows[destination].id] {
            mappedDestination = index
        } else if let last = rows.last, let index = indexByID[last.id] {
            mappedDestination = index + 1
        } else {
            return nil
        }
        return (mappedSource, mappedDestination)
    }

    // MARK: - Section Header View
    private func sectionHeaderView(title: String, titleColor: Color, onClear: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(titleColor)
                .textCase(nil)

            Spacer()

            Button(action: {
                HapticFeedback.lightImpact()
                onClear()
            }) {
                Text("CLEAR")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func clearUpcoming() {
        guard !playerService.queue.isEmpty, let currentIdx = playerService.currentIndex else { return }
        let preserved = Array(playerService.queue[0...min(currentIdx, playerService.queue.count - 1)])
        playerService.setQueue(preserved, currentIndex: currentIdx)
    }

    private func navigateToArtist(name: String, fallbackTrack: Track) {
        if let store = libraryStore {
            selectedArtist = store.findArtist(name: name) ?? Artist(name: name, tracks: [fallbackTrack])
        }
    }

    private func navigateToAlbum(title: String, artist: String, fallbackTrack: Track) {
        guard !title.isEmpty else { return }
        if let store = libraryStore {
            selectedAlbum = store.findAlbum(title: title, artist: artist) ?? Album(title: title, artist: artist, tracks: [fallbackTrack])
        }
    }
}

// MARK: - Queue Geometry (measurement only)
/// Visible area of the queue's scroll view, from its scroll geometry.
struct QueueScrollMetrics: Equatable {
    var insetTop: CGFloat = 0
    var visibleHeight: CGFloat = 0
}

/// On-screen positions of the queue rows, written by the rows themselves. A plain (not observed) class,
/// so writing to it while scrolling never invalidates any view.
@MainActor
final class QueueGeometry {
    /// Global minY of each visible row's content, by queue entry ID.
    var rowTops: [UUID: CGFloat] = [:]
    /// Global minY of the Now Playing row's content, while it is on screen.
    var nowPlayingTop: CGFloat? = nil
    /// Global minY of the scroll view's frame.
    var containerMinY: CGFloat = 0
    var scrollMetrics = QueueScrollMetrics()
    var proxy: ScrollViewProxy? = nil
    /// True while a song-change re-anchor is in progress (lazy loading waits).
    var isReanchoring = false
    var reanchorGeneration = 0
    /// An Up Next batch was requested during a re-anchor.
    var pendingUpNextLoad = false

    /// Visible area of the list in global coordinates (below the top inset, above the bottom inset).
    var visibleTop: CGFloat { containerMinY + scrollMetrics.insetTop }
    var visibleHeight: CGFloat { scrollMetrics.visibleHeight }
}

extension EnvironmentValues {
    @Entry var queueGeometry: QueueGeometry? = nil
}

/// What to keep in place on screen across a song-change rebuild.
enum QueueScrollAnchor {
    /// Put the Now Playing row's content top at this global y (where the tapped / next row was).
    case nowPlaying(top: CGFloat)
    /// Keep this row's content top at this global y.
    case row(id: UUID, top: CGFloat)
}

// MARK: - Prepared Queue Row Data
/// One prepared row per queue entry: the track is resolved and the duration formatted once, off the row body path.
struct QueueRowData: Identifiable {
    /// The queue entry ID (unique per queue position).
    let id: UUID
    let track: Track
    let durationText: String
}

// MARK: - Queue View Model
@Observable
@MainActor
final class QueueViewModel {
    static let initialPastCount = 50
    static let initialUpNextCount = 200
    static let pastBatchSize = 200
    static let upNextBatchSize = 500

    private(set) var pastRows: [QueueRowData] = []
    private(set) var playNextRows: [QueueRowData] = []
    private(set) var upNextRows: [QueueRowData] = []
    private(set) var nextEntryID: UUID? = nil
    /// Full counts (not just the loaded window) for the section headers.
    private(set) var totalPastCount = 0
    private(set) var totalUpNextCount = 0
    private(set) var hasMorePast = false
    private(set) var hasMoreUpNext = false

    /// True once `update` has run at least once for this queue sheet.
    @ObservationIgnored private(set) var hasLoaded = false
    /// Guards against repeated sentinel triggers while a batch is being inserted.
    @ObservationIgnored var isLoadingPast = false
    @ObservationIgnored var isLoadingUpNext = false
    @ObservationIgnored var isPastSentinelVisible = false

    @ObservationIgnored private var queue: [QueueEntry] = []
    @ObservationIgnored private var playNextQueue: [QueueEntry] = []
    @ObservationIgnored private var currentIdx = 0
    @ObservationIgnored private var resolve: (QueueEntry) -> Track? = { _ in nil }
    /// First queue index included in the past window.
    @ObservationIgnored private var pastStart = 0
    /// Number of upcoming songs included in the Up Next window.
    @ObservationIgnored private var upNextLimit = QueueViewModel.initialUpNextCount
    /// Identity of the current queue, used to reset the windows when a different queue is set.
    @ObservationIgnored private var queueFirstEntryID: UUID? = nil

    func update(queue: [QueueEntry], playNextQueue: [QueueEntry], currentIndex: Int?, resolve: @escaping (QueueEntry) -> Track?) {
        let newIdx = max(currentIndex ?? 0, 0)
        let isNewQueue = !hasLoaded || queue.first?.id != queueFirstEntryID
        let pastEnd = queue.isEmpty ? 0 : min(newIdx, queue.count)

        if isNewQueue {
            pastStart = max(0, pastEnd - Self.initialPastCount)
            upNextLimit = Self.initialUpNextCount
        } else if pastStart > pastEnd {
            // Jumped back before the loaded history: re-window around the new position.
            pastStart = max(0, pastEnd - Self.initialPastCount)
        }
        // Otherwise the past window keeps its start, so advancing only appends rows at its bottom
        // and nothing above the user's scroll position is removed.

        self.queue = queue
        self.playNextQueue = playNextQueue
        self.currentIdx = newIdx
        self.resolve = resolve
        self.queueFirstEntryID = queue.first?.id
        hasLoaded = true
        rebuild()
    }

    /// The queue index the current rows are laid out around.
    var layoutIndex: Int { currentIdx }

    /// True if the rows were built from exactly this queue.
    func hasSameQueue(_ queue: [QueueEntry]) -> Bool {
        hasLoaded && queue == self.queue
    }

    func containsRow(_ id: UUID) -> Bool {
        pastRows.contains { $0.id == id } || playNextRows.contains { $0.id == id } || upNextRows.contains { $0.id == id }
    }

    func isPastRow(_ id: UUID) -> Bool {
        pastRows.contains { $0.id == id }
    }

    func loadEarlierPast() {
        guard pastStart > 0 else { return }
        pastStart = max(0, pastStart - Self.pastBatchSize)
        rebuild()
    }

    func loadMoreUpNext() {
        guard hasMoreUpNext else { return }
        upNextLimit += Self.upNextBatchSize
        rebuild()
    }

    private func rebuild() {
        let pastEnd = queue.isEmpty ? 0 : min(currentIdx, queue.count)
        let start = min(pastStart, pastEnd)
        pastRows = makeRows(queue[start..<pastEnd])
        totalPastCount = pastEnd
        hasMorePast = start > 0

        playNextRows = makeRows(playNextQueue[...])

        let upStart = queue.isEmpty ? 0 : min(currentIdx + 1, queue.count)
        let upEnd = min(queue.count, upStart + upNextLimit)
        upNextRows = makeRows(queue[upStart..<upEnd])
        totalUpNextCount = queue.count - upStart
        hasMoreUpNext = upEnd < queue.count

        // Next badge resolution
        if let firstPlayNext = playNextQueue.first {
            nextEntryID = firstPlayNext.id
        } else if upStart < queue.count {
            nextEntryID = queue[upStart].id
        } else {
            nextEntryID = nil
        }
    }

    private func makeRows(_ entries: ArraySlice<QueueEntry>) -> [QueueRowData] {
        var rows: [QueueRowData] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            if let track = resolve(entry) {
                rows.append(QueueRowData(id: entry.id, track: track, durationText: TimeFormatting.format(seconds: track.duration)))
            }
        }
        return rows
    }
}

// MARK: - Isolated Now Playing Row
private struct NowPlayingQueueRowView: View {
    let track: Track
    @Bindable var playerService: AudioPlayerService
    @Environment(\.appTheme) private var appTheme
    @Environment(\.queueGeometry) private var queueGeometry
    let onNavigateToArtist: (String) -> Void
    let onNavigateToAlbum: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Former section header, drawn in the row so nothing pins over Now Playing when it is at the top.
            Text("NOW PLAYING")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)
                .textCase(nil)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            nowPlayingButton
        }
        .frame(height: 76) // fixed height (14 label + 6 spacing + 56 row) so the List never has to measure rows
        // Measurement only: records where this row sits on screen. No layout or drawing effect.
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .global).minY
        } action: { minY in
            queueGeometry?.nowPlayingTop = minY
        }
        .onDisappear {
            queueGeometry?.nowPlayingTop = nil
        }
    }

    private var nowPlayingButton: some View {
        Button(action: {
            playerService.togglePlayPause()
        }) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: track.artworkKey,
                        title: track.album,
                        subtitle: track.artist,
                        cornerRadius: 6
                    )
                    .frame(width: 44, height: 44)

                    Text(playerService.playbackStatus.isPlaying ? "PLAYING" : "PAUSED")
                        .font(.system(size: 6.5, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1.5)
                        .background(appTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        .offset(x: 2, y: 2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.22), value: playerService.playbackStatus.isPlaying)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(appTheme.accentColor)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    if playerService.cacheInAdvanceEnabled && SessionCacheStatus.shared.cachedTrackIDs.contains(track.id) {
                        Image(systemName: "checkmark.icloud")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(appTheme.accentColor.opacity(0.8))
                    }

                    Text(TimeFormatting.format(seconds: track.duration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(height: 56) // fixed height so the List never has to measure rows
            .background(appTheme.secondaryBackgroundColor.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            let parsedArtists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if parsedArtists.count == 1, let first = parsedArtists.first {
                Button {
                    onNavigateToArtist(first)
                } label: {
                    Text("GO TO ARTIST")
                }
            } else if !parsedArtists.isEmpty {
                Menu {
                    ForEach(parsedArtists, id: \.self) { name in
                        Button {
                            onNavigateToArtist(name)
                        } label: {
                            Text(name)
                        }
                    }
                } label: {
                    Text("GO TO ARTIST")
                }
            }

            if !track.album.isEmpty {
                Button {
                    onNavigateToAlbum(track.album, track.artist)
                } label: {
                    Text("GO TO ALBUM")
                }
            }
        }
    }
}

// MARK: - Equatable Queue Row View
private struct QueueRowView: View, Equatable {
    enum Kind {
        case past
        case playNext
        case upNext
    }

    let entryID: UUID
    let trackID: UUID
    let title: String
    let artist: String
    let durationText: String
    let artworkKey: String?
    let albumTitle: String
    let isNext: Bool
    let kind: Kind
    /// CACHE IN ADVANCE finished for this track (shows checkmark.icloud next to the duration).
    var isSessionCached: Bool = false

    let onTap: () -> Void
    let onRemove: (() -> Void)?
    let onMoveSection: (() -> Void)?
    let onNavigateToArtist: (String) -> Void
    let onNavigateToAlbum: (String, String) -> Void
    /// Measurement only; not part of ==.
    @Environment(\.queueGeometry) private var queueGeometry

    static func == (lhs: QueueRowView, rhs: QueueRowView) -> Bool {
        lhs.entryID == rhs.entryID &&
        lhs.trackID == rhs.trackID &&
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.durationText == rhs.durationText &&
        lhs.artworkKey == rhs.artworkKey &&
        lhs.albumTitle == rhs.albumTitle &&
        lhs.isNext == rhs.isNext &&
        lhs.kind == rhs.kind &&
        lhs.isSessionCached == rhs.isSessionCached
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: artworkKey,
                        title: albumTitle,
                        subtitle: artist,
                        cornerRadius: 6
                    )
                    .frame(width: kind == .past ? 38 : 40, height: kind == .past ? 38 : 40)
                    .opacity(kind == .past ? 0.55 : 1.0)

                    if isNext {
                        Text("NEXT")
                            .font(.system(size: 6.5, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                            .offset(x: 2, y: 2)
                            .contentTransition(.opacity)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: kind == .past ? 13 : 14, weight: kind == .past ? .medium : .medium))
                        .foregroundStyle(kind == .past ? Color.primary.opacity(0.6) : Color.primary)
                        .lineLimit(1)

                    Text(artist)
                        .font(.system(size: kind == .past ? 11 : 12, weight: .regular))
                        .foregroundStyle(kind == .past ? Color.secondary.opacity(0.65) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    if isSessionCached {
                        Image(systemName: "checkmark.icloud")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(kind == .past ? 0.4 : 0.65))
                    }

                    Text(durationText)
                        .font(.system(size: kind == .past ? 11 : 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(kind == .past ? Color.secondary.opacity(0.6) : Color.secondary)
                }

                if kind != .past {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .frame(height: kind == .past ? 46 : 48) // fixed height so the List never has to measure rows
            .contentShape(Rectangle())
            // Measurement only, inside the button label (away from the row's swipe actions and list settings).
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).minY
            } action: { minY in
                queueGeometry?.rowTops[entryID] = minY
            }
            .onDisappear {
                queueGeometry?.rowTops[entryID] = nil
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Text("REMOVE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.red)
                }
                .tint(Color.black.opacity(0.88))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onMoveSection = onMoveSection {
                Button(action: onMoveSection) {
                    Text(kind == .playNext ? "TO UP NEXT" : "TO QUEUE")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
                .tint(Color.blue.opacity(0.85))
            }
        }
        .contextMenu {
            if let onMoveSection = onMoveSection {
                Button(action: onMoveSection) {
                    Text(kind == .playNext ? "MOVE TO UP NEXT" : "MOVE TO QUEUE")
                }
            }

            let parsedArtists = ArtistParser.parse(rawArtist: artist).map { $0.name }
            if parsedArtists.count == 1, let first = parsedArtists.first {
                Button {
                    onNavigateToArtist(first)
                } label: {
                    Text("GO TO ARTIST")
                }
            } else if !parsedArtists.isEmpty {
                Menu {
                    ForEach(parsedArtists, id: \.self) { name in
                        Button {
                            onNavigateToArtist(name)
                        } label: {
                            Text(name)
                        }
                    }
                } label: {
                    Text("GO TO ARTIST")
                }
            }

            if !albumTitle.isEmpty {
                Button {
                    onNavigateToAlbum(albumTitle, artist)
                } label: {
                    Text("GO TO ALBUM")
                }
            }

            if let onRemove = onRemove {
                Button(role: .destructive, action: onRemove) {
                    Text(kind == .playNext ? "REMOVE FROM QUEUE" : "REMOVE FROM UP NEXT")
                }
            }
        }
    }
}
