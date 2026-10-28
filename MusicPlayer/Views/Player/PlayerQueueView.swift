import SwiftUI

/// Ultra-high-performance playback queue view optimized for queues containing 20,000+ songs.
/// Leverages lightweight `QueueEntry` values, native UICollectionView-backed `List` lazy recycling,
/// precomputed slice arrays off the body path, isolated state views, and Equatable row diffing.
public struct PlayerQueueView: View {
    @Bindable var playerService: AudioPlayerService
    var libraryStore: LibraryStore? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var viewModel = QueueViewModel()
    @State private var selectedArtist: Artist? = nil
    @State private var selectedAlbum: Album? = nil
    /// False until the list has been scrolled to Now Playing on open; the list stays invisible until then so
    /// the user never sees it start at the oldest past song and jump.
    @State private var isPositionedAtNowPlaying = false

    // Initialize with configured properties
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
                } else {
                    ScrollViewReader { proxy in
                        List {
                            // 1. PAST SONGS SECTION (Scroll up from Now Playing to view history)
                            if !viewModel.pastEntries.isEmpty {
                                Section {
                                    ForEach(viewModel.pastEntries) { entry in
                                        if let track = playerService.track(for: entry) {
                                            QueueRowView(
                                                entryID: entry.id,
                                                trackID: track.id,
                                                title: track.title,
                                                artist: track.artist,
                                                durationText: TimeFormatting.format(seconds: track.duration),
                                                artworkKey: track.artworkKey,
                                                albumTitle: track.album,
                                                isNext: false,
                                                kind: .past,
                                                onTap: {
                                                    playerService.playQueueEntry(id: entry.id)
                                                },
                                                onRemove: nil,
                                                onMoveSection: {
                                                    if let idx = playerService.queue.firstIndex(where: { $0.id == entry.id }) {
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
                                    }
                                } header: {
                                    Text("PAST SONGS (\(viewModel.pastEntries.count))")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }

                            // 2. NOW PLAYING SECTION (List opens scrolled here, anchored at the top)
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
                                } header: {
                                    Text("NOW PLAYING")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(appTheme.accentColor)
                                        .textCase(nil)
                                }
                            }

                            // 3. QUEUE (PLAY NEXT) SECTION
                            if !viewModel.playNextEntries.isEmpty {
                                Section {
                                    ForEach(viewModel.playNextEntries) { entry in
                                        if let track = playerService.track(for: entry) {
                                            QueueRowView(
                                                entryID: entry.id,
                                                trackID: track.id,
                                                title: track.title,
                                                artist: track.artist,
                                                durationText: TimeFormatting.format(seconds: track.duration),
                                                artworkKey: track.artworkKey,
                                                albumTitle: track.album,
                                                isNext: entry.id == viewModel.nextEntryID,
                                                kind: .playNext,
                                                onTap: {
                                                    if let idx = playerService.playNextQueue.firstIndex(where: { $0.id == entry.id }) {
                                                        playerService.playFromPlayNext(at: idx)
                                                    }
                                                },
                                                onRemove: {
                                                    if let idx = playerService.playNextQueue.firstIndex(where: { $0.id == entry.id }) {
                                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                            playerService.removePlayNextItem(at: idx)
                                                        }
                                                    }
                                                },
                                                onMoveSection: {
                                                    if let idx = playerService.playNextQueue.firstIndex(where: { $0.id == entry.id }) {
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
                                    }
                                    .onMove { source, destination in
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            playerService.movePlayNextItem(fromOffsets: source, toOffset: destination)
                                        }
                                        HapticFeedback.dragDrop()
                                    }
                                } header: {
                                    sectionHeaderView(
                                        title: "QUEUE (\(viewModel.playNextEntries.count))",
                                        titleColor: appTheme.accentColor,
                                        onClear: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                playerService.clearPlayNextQueue()
                                            }
                                        }
                                    )
                                }
                            }

                            // 4. UP NEXT SECTION
                            if !viewModel.upNextEntries.isEmpty {
                                Section {
                                    ForEach(viewModel.upNextEntries) { entry in
                                        if let track = playerService.track(for: entry) {
                                            QueueRowView(
                                                entryID: entry.id,
                                                trackID: track.id,
                                                title: track.title,
                                                artist: track.artist,
                                                durationText: TimeFormatting.format(seconds: track.duration),
                                                artworkKey: track.artworkKey,
                                                albumTitle: track.album,
                                                isNext: entry.id == viewModel.nextEntryID,
                                                kind: .upNext,
                                                onTap: {
                                                    playerService.playQueueEntry(id: entry.id)
                                                },
                                                onRemove: {
                                                    if let idx = playerService.queue.firstIndex(where: { $0.id == entry.id }) {
                                                        playerService.removeQueueItem(at: idx)
                                                    }
                                                },
                                                onMoveSection: {
                                                    if let idx = playerService.queue.firstIndex(where: { $0.id == entry.id }) {
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
                                    }
                                    .onMove { source, destination in
                                        let baseIndex = (playerService.currentIndex ?? 0) + 1
                                        var adjustedSource = IndexSet()
                                        for offset in source {
                                            adjustedSource.insert(baseIndex + offset)
                                        }
                                        let adjustedDestination = baseIndex + destination
                                        playerService.moveQueueItem(fromOffsets: adjustedSource, toOffset: adjustedDestination)
                                        HapticFeedback.dragDrop()
                                    }
                                } header: {
                                    sectionHeaderView(
                                        title: "UP NEXT (\(viewModel.upNextEntries.count))",
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
                        .opacity(isPositionedAtNowPlaying ? 1 : 0)
                        .task {
                            // Runs once per open (not on track changes). Past rows must exist and the List must
                            // have laid them out before scrollTo can land on Now Playing, so load the entries if
                            // the outer onAppear hasn't yet, then scroll after the next layout passes and reveal.
                            if !viewModel.hasLoaded {
                                viewModel.update(
                                    queue: playerService.queue,
                                    playNextQueue: playerService.playNextQueue,
                                    currentIndex: playerService.currentIndex
                                )
                            }
                            if playerService.currentTrack != nil {
                                await Task.yield()
                                proxy.scrollTo("now_playing_item", anchor: .top)
                                try? await Task.sleep(for: .milliseconds(32))
                                proxy.scrollTo("now_playing_item", anchor: .top)
                                try? await Task.sleep(for: .milliseconds(16))
                            }
                            isPositionedAtNowPlaying = true
                        }
                    }
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
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
            viewModel.update(
                queue: playerService.queue,
                playNextQueue: playerService.playNextQueue,
                currentIndex: playerService.currentIndex
            )
        }
        .onChange(of: playerService.queue) { _, newQueue in
            viewModel.update(
                queue: newQueue,
                playNextQueue: playerService.playNextQueue,
                currentIndex: playerService.currentIndex
            )
        }
        .onChange(of: playerService.playNextQueue) { _, newPlayNext in
            viewModel.update(
                queue: playerService.queue,
                playNextQueue: newPlayNext,
                currentIndex: playerService.currentIndex
            )
        }
        .onChange(of: playerService.currentIndex) { _, newIndex in
            viewModel.update(
                queue: playerService.queue,
                playNextQueue: playerService.playNextQueue,
                currentIndex: newIndex
            )
        }
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

// MARK: - Queue View Model
@Observable
@MainActor
final class QueueViewModel {
    var pastEntries: [QueueEntry] = []
    var playNextEntries: [QueueEntry] = []
    var upNextEntries: [QueueEntry] = []
    var nextEntryID: UUID? = nil
    /// True once `update` has run at least once for this queue sheet.
    @ObservationIgnored private(set) var hasLoaded = false

    func update(queue: [QueueEntry], playNextQueue: [QueueEntry], currentIndex: Int?) {
        hasLoaded = true
        let currentIdx = currentIndex ?? 0

        // Past entries
        if !queue.isEmpty && currentIdx > 0 {
            let end = min(currentIdx, queue.count)
            self.pastEntries = Array(queue[0..<end])
        } else {
            self.pastEntries = []
        }

        // Play Next entries
        self.playNextEntries = playNextQueue

        // Up Next entries
        if !queue.isEmpty {
            let start = min(currentIdx + 1, queue.count)
            if start < queue.count {
                self.upNextEntries = Array(queue[start..<queue.count])
            } else {
                self.upNextEntries = []
            }
        } else {
            self.upNextEntries = []
        }

        // Next badge resolution
        if let firstPlayNext = playNextQueue.first {
            self.nextEntryID = firstPlayNext.id
        } else if let firstUpNext = self.upNextEntries.first {
            self.nextEntryID = firstUpNext.id
        } else {
            self.nextEntryID = nil
        }
    }
}

// MARK: - Isolated Now Playing Row
private struct NowPlayingQueueRowView: View {
    let track: Track
    @Bindable var playerService: AudioPlayerService
    @Environment(\.appTheme) private var appTheme
    let onNavigateToArtist: (String) -> Void
    let onNavigateToAlbum: (String, String) -> Void

    var body: some View {
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

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
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

    let onTap: () -> Void
    let onRemove: (() -> Void)?
    let onMoveSection: (() -> Void)?
    let onNavigateToArtist: (String) -> Void
    let onNavigateToAlbum: (String, String) -> Void

    static func == (lhs: QueueRowView, rhs: QueueRowView) -> Bool {
        lhs.entryID == rhs.entryID &&
        lhs.trackID == rhs.trackID &&
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.durationText == rhs.durationText &&
        lhs.artworkKey == rhs.artworkKey &&
        lhs.albumTitle == rhs.albumTitle &&
        lhs.isNext == rhs.isNext &&
        lhs.kind == rhs.kind
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

                Text(durationText)
                    .font(.system(size: kind == .past ? 11 : 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(kind == .past ? Color.secondary.opacity(0.6) : Color.secondary)

                if kind != .past {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
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
