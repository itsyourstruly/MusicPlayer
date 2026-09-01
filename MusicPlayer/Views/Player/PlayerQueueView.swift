import SwiftUI

/// Clean, minimal playback queue view featuring a unified scrollable list of
/// past history, currently playing track, and upcoming songs with unrestricted
/// cross-section and intra-section drag-and-drop reordering, swipe actions,
/// and fast navigation to artists and albums.
public struct PlayerQueueView: View {
    @Bindable var playerService: AudioPlayerService
    var libraryStore: LibraryStore? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var selectedArtist: Artist? = nil
    @State private var selectedAlbum: Album? = nil

    // Initialize with configured properties
    public init(playerService: AudioPlayerService, libraryStore: LibraryStore? = nil) {
        self.playerService = playerService
        self.libraryStore = libraryStore
    }

    private var currentIdx: Int {
        playerService.currentIndex ?? 0
    }

    private var pastTracks: [Track] {
        guard !playerService.queue.isEmpty, currentIdx > 0 else { return [] }
        let end = min(currentIdx, playerService.queue.count)
        return Array(playerService.queue[0..<end])
    }

    private var upcomingTracks: [(index: Int, track: Track)] {
        guard !playerService.queue.isEmpty else { return [] }
        let start = min(currentIdx + 1, playerService.queue.count)
        guard start < playerService.queue.count else { return [] }
        return Array(playerService.queue[start..<playerService.queue.count].enumerated()).map {
            (index: start + $0.offset, track: $0.element)
        }
    }

    private struct UnifiedQueueItem: Identifiable, Equatable {
        enum Kind: Equatable {
            case playNext(index: Int)
            case upNext(queueIndex: Int, upcomingIndex: Int)
        }

        let id: String
        let track: Track
        let kind: Kind
    }

    private var unifiedUpcomingItems: [UnifiedQueueItem] {
        var items: [UnifiedQueueItem] = []
        for (idx, track) in playerService.playNextQueue.enumerated() {
            items.append(UnifiedQueueItem(
                id: "pn_\(track.id.uuidString)_\(idx)",
                track: track,
                kind: .playNext(index: idx)
            ))
        }
        for (upcomingIdx, item) in upcomingTracks.enumerated() {
            items.append(UnifiedQueueItem(
                id: "un_\(item.track.id.uuidString)_\(item.index)",
                track: item.track,
                kind: .upNext(queueIndex: item.index, upcomingIndex: upcomingIdx)
            ))
        }
        return items
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                if playerService.queue.isEmpty && playerService.currentTrack == nil && playerService.playNextQueue.isEmpty {
                    EmptyStateView(
                        title: "QUEUE IS EMPTY",
                        message: "Play tracks from your library to populate the queue."
                    )
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appTheme.backgroundColor.ignoresSafeArea())
                } else {
                    List {
                        // 1. PAST SONGS SECTION (Scroll up to view history)
                        if !pastTracks.isEmpty {
                            Section {
                                ForEach(Array(pastTracks.enumerated()), id: \.element.id) { idx, track in
                                    pastTrackRow(track: track, queueIndex: idx)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                            } header: {
                                Text("PAST SONGS (\(pastTracks.count))")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }

                        // 2. NOW PLAYING SECTION (Top of default visible queue)
                        if let current = playerService.currentTrack {
                            Section {
                                nowPlayingRow(track: current)
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

                        // 3. UNIFIED UPCOMING QUEUE SECTION (Supports unrestricted dragging across QUEUE & UP NEXT)
                        if !unifiedUpcomingItems.isEmpty {
                            Section {
                                ForEach(Array(unifiedUpcomingItems.enumerated()), id: \.element.id) { unifiedIdx, item in
                                    VStack(spacing: 0) {
                                        // Dynamic inline header for QUEUE (Play Next)
                                        if unifiedIdx == 0 && isPlayNext(item: item) {
                                            sectionHeaderView(
                                                title: "QUEUE (\(playerService.playNextQueue.count))",
                                                titleColor: appTheme.accentColor,
                                                onClear: {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        playerService.clearPlayNextQueue()
                                                    }
                                                }
                                            )
                                            .padding(.bottom, 6)
                                        }

                                        // Dynamic inline header for UP NEXT
                                        if isFirstUpNextItem(unifiedIndex: unifiedIdx, item: item) {
                                            sectionHeaderView(
                                                title: "UP NEXT (\(upcomingTracks.count))",
                                                titleColor: .secondary,
                                                onClear: {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        clearUpcoming()
                                                    }
                                                }
                                            )
                                            .padding(.top, playerService.playNextQueue.isEmpty ? 0 : 12)
                                            .padding(.bottom, 6)
                                        }

                                        // Render the appropriate track row based on its current section
                                        switch item.kind {
                                        case .playNext(let playNextIdx):
                                            playNextTrackRow(track: item.track, index: playNextIdx, unifiedIndex: unifiedIdx)

                                        case .upNext(let queueIdx, _):
                                            upcomingTrackRow(track: item.track, queueIndex: queueIdx, unifiedIndex: unifiedIdx)
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .draggable(item.track.id.uuidString)
                                    .dropDestination(for: String.self) { droppedIDs, _ in
                                        guard let droppedID = droppedIDs.first else { return false }
                                        return handleDrop(droppedIDString: droppedID, targetUnifiedIndex: unifiedIdx)
                                    }
                                }
                                .onMove(perform: handleUnifiedMove)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(appTheme.backgroundColor.ignoresSafeArea())
                    .onAppear {
                        // Scroll to Now Playing on appearance so it starts at the top
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("now_playing_item", anchor: .top)
                            }
                        }
                    }
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("QUEUE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Text("DONE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                    }
                }
            }
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
    }

    // MARK: - Section Header Helpers
    private func isPlayNext(item: UnifiedQueueItem) -> Bool {
        if case .playNext = item.kind { return true }
        return false
    }

    private func isFirstUpNextItem(unifiedIndex: Int, item: UnifiedQueueItem) -> Bool {
        if case .upNext = item.kind {
            if unifiedIndex == 0 { return true }
            let prevItem = unifiedUpcomingItems[unifiedIndex - 1]
            if case .playNext = prevItem.kind { return true }
        }
        return false
    }

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

    // MARK: - Unrestricted Cross-Section Move Engine
    private func handleUnifiedMove(source: IndexSet, destination: Int) {
        guard let sourceIndex = source.first else { return }
        let playNextCount = playerService.playNextQueue.count
        let baseUpcomingQueueIndex = (playerService.currentIndex ?? 0) + 1

        let isSourcePlayNext = sourceIndex < playNextCount

        if isSourcePlayNext {
            // Dragging an item that was originally in Play Next Queue
            let playNextSourceIndex = sourceIndex

            if destination <= playNextCount {
                // Case 1: Reordering within Play Next Queue
                var adjustedSource = IndexSet()
                adjustedSource.insert(playNextSourceIndex)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.movePlayNextItem(fromOffsets: adjustedSource, toOffset: destination)
                }
            } else {
                // Case 2: Moving from Play Next Queue down into UP NEXT
                let destinationUpcomingOffset = destination - playNextCount
                let destinationQueueIndex = min(baseUpcomingQueueIndex + destinationUpcomingOffset, playerService.queue.count)

                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.moveFromPlayNextToQueue(
                        playNextIndex: playNextSourceIndex,
                        queueDestinationIndex: destinationQueueIndex
                    )
                }
            }
        } else {
            // Dragging an item that was originally in UP NEXT
            let upcomingSourceOffset = sourceIndex - playNextCount
            let queueSourceIndex = baseUpcomingQueueIndex + upcomingSourceOffset

            if destination < playNextCount {
                // Case 3: Moving from UP NEXT up into Play Next Queue
                let destinationPlayNextIndex = min(destination, playerService.playNextQueue.count)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.moveFromQueueToPlayNext(
                        queueIndex: queueSourceIndex,
                        playNextDestinationIndex: destinationPlayNextIndex
                    )
                }
            } else {
                // Case 4: Reordering within UP NEXT
                let destinationUpcomingOffset = destination - playNextCount
                let destinationQueueIndex = min(baseUpcomingQueueIndex + destinationUpcomingOffset, playerService.queue.count)

                var adjustedSource = IndexSet()
                adjustedSource.insert(queueSourceIndex)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.moveQueueItem(fromOffsets: adjustedSource, toOffset: destinationQueueIndex)
                }
            }
        }
        HapticFeedback.lightImpact()
    }

    // MARK: - Drag & Drop Pointer Target Handler
    private func handleDrop(droppedIDString: String, targetUnifiedIndex: Int) -> Bool {
        guard let droppedUUID = UUID(uuidString: droppedIDString) else { return false }
        let playNextCount = playerService.playNextQueue.count
        let baseUpcomingQueueIndex = (playerService.currentIndex ?? 0) + 1

        // Find the dropped item's origin
        if let playNextIdx = playerService.playNextQueue.firstIndex(where: { $0.id == droppedUUID }) {
            if targetUnifiedIndex < playNextCount {
                // Intra-move within Play Next
                var source = IndexSet()
                source.insert(playNextIdx)
                let dest = targetUnifiedIndex > playNextIdx ? min(targetUnifiedIndex + 1, playerService.playNextQueue.count) : targetUnifiedIndex
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.movePlayNextItem(fromOffsets: source, toOffset: dest)
                }
                HapticFeedback.lightImpact()
                return true
            } else {
                // Move from Play Next down to Up Next
                let upcomingOffset = targetUnifiedIndex - playNextCount
                let destQueueIndex = min(baseUpcomingQueueIndex + upcomingOffset, playerService.queue.count)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.moveFromPlayNextToQueue(playNextIndex: playNextIdx, queueDestinationIndex: destQueueIndex)
                }
                HapticFeedback.lightImpact()
                return true
            }
        } else if let queueIdx = playerService.queue.firstIndex(where: { $0.id == droppedUUID }) {
            if targetUnifiedIndex < playNextCount {
                // Move from Up Next up to Play Next
                let destPlayNextIndex = min(targetUnifiedIndex, playerService.playNextQueue.count)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.moveFromQueueToPlayNext(queueIndex: queueIdx, playNextDestinationIndex: destPlayNextIndex)
                }
                HapticFeedback.lightImpact()
                return true
            } else {
                // Intra-move within Up Next
                var source = IndexSet()
                source.insert(queueIdx)
                let upcomingOffset = targetUnifiedIndex - playNextCount
                let destQueueIndex = min(baseUpcomingQueueIndex + upcomingOffset, playerService.queue.count)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    playerService.moveQueueItem(fromOffsets: source, toOffset: destQueueIndex)
                }
                HapticFeedback.lightImpact()
                return true
            }
        }

        return false
    }

    private func moveItemFromPlayNextToUpNext(playNextIndex: Int) {
        let baseIndex = (playerService.currentIndex ?? 0) + 1
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            playerService.moveFromPlayNextToQueue(playNextIndex: playNextIndex, queueDestinationIndex: baseIndex)
        }
        HapticFeedback.lightImpact()
    }

    private func moveItemFromUpNextToPlayNext(queueIndex: Int) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            playerService.moveFromQueueToPlayNext(queueIndex: queueIndex, playNextDestinationIndex: playerService.playNextQueue.count)
        }
        HapticFeedback.lightImpact()
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

    // Now playing row
    private func nowPlayingRow(track: Track) -> some View {
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
            let artists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if !artists.isEmpty {
                if artists.count == 1, let first = artists.first {
                    Button {
                        navigateToArtist(name: first, fallbackTrack: track)
                    } label: {
                        Text("GO TO ARTIST")
                    }
                } else {
                    Menu {
                        ForEach(artists, id: \.self) { name in
                            Button {
                                navigateToArtist(name: name, fallbackTrack: track)
                            } label: {
                                Text(name)
                            }
                        }
                    } label: {
                        Text("GO TO ARTIST")
                    }
                }
            }

            if !track.album.isEmpty {
                Button {
                    navigateToAlbum(title: track.album, artist: track.artist, fallbackTrack: track)
                } label: {
                    Text("GO TO ALBUM")
                }
            }
        }
    }

    // Past track row
    private func pastTrackRow(track: Track, queueIndex: Int) -> some View {
        Button(action: {
            playerService.play(track: track, inQueue: playerService.queue, startIndex: queueIndex)
        }) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 6
                )
                .frame(width: 38, height: 38)
                .opacity(0.55)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                moveItemFromUpNextToPlayNext(queueIndex: queueIndex)
            } label: {
                Text("MOVE TO QUEUE")
            }

            let artists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if !artists.isEmpty {
                if artists.count == 1, let first = artists.first {
                    Button {
                        navigateToArtist(name: first, fallbackTrack: track)
                    } label: {
                        Text("GO TO ARTIST")
                    }
                } else {
                    Menu {
                        ForEach(artists, id: \.self) { name in
                            Button {
                                navigateToArtist(name: name, fallbackTrack: track)
                            } label: {
                                Text(name)
                            }
                        }
                    } label: {
                        Text("GO TO ARTIST")
                    }
                }
            }

            if !track.album.isEmpty {
                Button {
                    navigateToAlbum(title: track.album, artist: track.artist, fallbackTrack: track)
                } label: {
                    Text("GO TO ALBUM")
                }
            }
        }
    }

    // Play next track row
    private func playNextTrackRow(track: Track, index: Int, unifiedIndex: Int) -> some View {
        Button(action: {
            playerService.playFromPlayNext(at: index)
        }) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: track.artworkKey,
                        title: track.album,
                        subtitle: track.artist,
                        cornerRadius: 6
                    )
                    .frame(width: 40, height: 40)

                    if index == 0 {
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    playerService.removePlayNextItem(at: index)
                }
            } label: {
                Text("REMOVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
            }
            .tint(Color.black.opacity(0.88))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                moveItemFromPlayNextToUpNext(playNextIndex: index)
            } label: {
                Text("TO UP NEXT")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.blue)
            }
            .tint(Color.blue.opacity(0.85))
        }
        .contextMenu {
            Button {
                moveItemFromPlayNextToUpNext(playNextIndex: index)
            } label: {
                Text("MOVE TO UP NEXT")
            }

            let artists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if !artists.isEmpty {
                if artists.count == 1, let first = artists.first {
                    Button {
                        navigateToArtist(name: first, fallbackTrack: track)
                    } label: {
                        Text("GO TO ARTIST")
                    }
                } else {
                    Menu {
                        ForEach(artists, id: \.self) { name in
                            Button {
                                navigateToArtist(name: name, fallbackTrack: track)
                            } label: {
                                Text(name)
                            }
                        }
                    } label: {
                        Text("GO TO ARTIST")
                    }
                }
            }

            if !track.album.isEmpty {
                Button {
                    navigateToAlbum(title: track.album, artist: track.artist, fallbackTrack: track)
                } label: {
                    Text("GO TO ALBUM")
                }
            }

            Button(role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    playerService.removePlayNextItem(at: index)
                }
            } label: {
                Text("REMOVE FROM QUEUE")
            }
        }
    }

    // Upcoming track row
    private func upcomingTrackRow(track: Track, queueIndex: Int, unifiedIndex: Int) -> some View {
        Button(action: {
            playerService.play(track: track, inQueue: playerService.queue, startIndex: queueIndex)
        }) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: track.artworkKey,
                        title: track.album,
                        subtitle: track.artist,
                        cornerRadius: 6
                    )
                    .frame(width: 40, height: 40)

                    if playerService.playNextQueue.isEmpty && queueIndex == currentIdx + 1 {
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    playerService.removeQueueItem(at: queueIndex)
                }
            } label: {
                Text("REMOVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
            }
            .tint(Color.black.opacity(0.88))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                moveItemFromUpNextToPlayNext(queueIndex: queueIndex)
            } label: {
                Text("TO QUEUE")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.blue)
            }
            .tint(Color.blue.opacity(0.85))
        }
        .contextMenu {
            Button {
                moveItemFromUpNextToPlayNext(queueIndex: queueIndex)
            } label: {
                Text("MOVE TO QUEUE")
            }

            let artists = ArtistParser.parse(rawArtist: track.artist).map { $0.name }
            if !artists.isEmpty {
                if artists.count == 1, let first = artists.first {
                    Button {
                        navigateToArtist(name: first, fallbackTrack: track)
                    } label: {
                        Text("GO TO ARTIST")
                    }
                } else {
                    Menu {
                        ForEach(artists, id: \.self) { name in
                            Button {
                                navigateToArtist(name: name, fallbackTrack: track)
                            } label: {
                                Text(name)
                            }
                        }
                    } label: {
                        Text("GO TO ARTIST")
                    }
                }
            }

            if !track.album.isEmpty {
                Button {
                    navigateToAlbum(title: track.album, artist: track.artist, fallbackTrack: track)
                } label: {
                    Text("GO TO ALBUM")
                }
            }

            Button(role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    playerService.removeQueueItem(at: queueIndex)
                }
            } label: {
                Text("REMOVE FROM UP NEXT")
            }
        }
    }

    // Clear upcoming
    private func clearUpcoming() {
        guard !playerService.queue.isEmpty, let current = playerService.currentTrack else { return }
        let currentIdx = playerService.currentIndex ?? 0
        let preserved = Array(playerService.queue[0...min(currentIdx, playerService.queue.count - 1)])
        playerService.play(track: current, inQueue: preserved, startIndex: currentIdx)
    }
}
