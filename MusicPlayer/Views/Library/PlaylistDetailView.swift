import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Playlist detail view providing album-style header with tap-to-edit cover and name, track sequencing, and playback.
public struct PlaylistDetailView: View {
    // Unique identifier for playlist id
    public let playlistID: UUID
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    // Native search state: lets one tap on the close (X) button end search even while the keyboard is up
    @State private var isSearchPresented: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isScrollingContent: Bool = false
    @State private var lastScrollActivity: Date = .distantPast
    @State private var didJustSubmitSearch: Bool = false
    #endif
    @State private var isEditMode: Bool = false
    @State private var selectedSortCriteria: PlaylistTrackSortCriteria = .custom
    @State private var draggedTrack: Track? = nil
    @State private var draggingTrackID: UUID? = nil
    @State private var accumulatedDragY: CGFloat = 0
    @State private var showingAddTracksSheet: Bool = false
    @State private var showingEditSheet: Bool = false
    @State private var showingDeleteAlert: Bool = false
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil

    // Initialize with configured properties
    public init(
        playlistID: UUID,
        libraryStore: LibraryStore,
        playerService: AudioPlayerService
    ) {
        self.playlistID = playlistID
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    private var currentPlaylist: Playlist? {
        libraryStore.playlists.first(where: { $0.id == playlistID })
    }

    /// One displayed row: the track plus its index in the playback queue (the full sorted playlist),
    /// so tapping a row while search is active still starts the right song with the full queue.
    fileprivate struct PlaylistRow: Identifiable {
        let track: Track
        let queueIndex: Int
        var id: UUID { track.id }
    }

    /// Applies the view-only sort. `.custom` (default) costs nothing; other sorts only run while chosen.
    private func sortedTracks(_ raw: [Track]) -> [Track] {
        switch selectedSortCriteria {
        case .custom:
            return raw
        case .name:
            return raw.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return raw.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:
            return raw.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .favorite:
            let counts = libraryStore.playCounts
            return raw.sorted {
                let p1 = counts[$0.id] ?? 0
                let p2 = counts[$1.id] ?? 0
                if p1 != p2 { return p1 > p2 }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .newest:
            return raw.sorted {
                if let y1 = $0.year, let y2 = $1.year, y1 != y2 {
                    return y1 > y2
                }
                return $0.dateAdded > $1.dateAdded
            }
        case .oldest:
            return raw.sorted {
                if let y1 = $0.year, let y2 = $1.year, y1 != y2 {
                    return y1 < y2
                }
                return $0.dateAdded < $1.dateAdded
            }
        }
    }

    /// Search filter over the queue, keeping each row's queue index.
    private static func displayRows(for queue: [Track], query: String) -> [PlaylistRow] {
        let cleanQuery = FuzzyMatcher.normalize(query)
        guard !cleanQuery.isEmpty else {
            return queue.enumerated().map { PlaylistRow(track: $0.element, queueIndex: $0.offset) }
        }
        let scored: [(PlaylistRow, Int)] = queue.enumerated().compactMap { offset, track in
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (PlaylistRow(track: track, queueIndex: offset), score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    // Main view layout structure
    public var body: some View {
        if let playlist = currentPlaylist {
            // Resolved once per render (O(playlist) via the store's ID index), like AlbumDetailView.
            // Player state is NOT read here; it is read by `PlaylistPlaybackStateReader` below, so
            // play/pause/track changes only re-render the rows, not this whole screen.
            let queue = sortedTracks(libraryStore.tracks(for: playlist))
            let rows = Self.displayRows(for: queue, query: searchQuery)
            VStack(spacing: 0) {
                #if os(macOS)
                // Smooth Top Search Bar (Decoupled from ScrollView, zero layout jitter). iOS uses the native search field.
                if isSearching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("SEARCH TRACKS IN PLAYLIST", text: $searchQuery)
                            .font(.system(size: 13, weight: .medium))
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)

                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.appSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
                #endif

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Album-style Header with interactive cover & title
                        headerView(for: playlist, tracks: queue)

                        // Transport Actions with Edit Mode Pencil Button on the far right
                        HStack(spacing: 12) {
                            Button(action: {
                                if let first = queue.first {
                                    playerService.play(track: first, inQueue: queue, startIndex: 0)
                                }
                            }) {
                                Text("PLAY")
                            }
                            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
                            .disabled(queue.isEmpty)

                            Button(action: {
                                // Shuffled
                                let shuffled = queue.shuffled()
                                if let first = shuffled.first {
                                    playerService.play(track: first, inQueue: shuffled, startIndex: 0)
                                }
                            }) {
                                Text("SHUFFLE")
                            }
                            .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))
                            .disabled(queue.isEmpty)

                            Spacer()

                            PlaylistDownloadButton(tracks: queue, accentColor: appTheme.accentColor)

                            // Pencil icon button with no background to toggle edit mode
                            Button(action: {
                                HapticFeedback.lightImpact()
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                    isEditMode.toggle()
                                }
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(isEditMode ? Color.blue : Color.primary)
                                    .frame(width: 38, height: 38)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        // Tracklist Section (Moves down smoothly when in edit mode)
                        VStack(alignment: .leading, spacing: 10) {
                            // Edit Mode Toolbar (Sort & Add buttons)
                            if isEditMode {
                                HStack(spacing: 10) {
                                    Menu {
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .custom
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .custom ? "CUSTOM (SELECTED)" : "CUSTOM")
                                        }

                                        Divider()

                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .name
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .name ? "NAME (SELECTED)" : "NAME")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .artist
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .artist ? "ARTIST (SELECTED)" : "ARTIST")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .album
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .album ? "ALBUM (SELECTED)" : "ALBUM")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .favorite
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .favorite ? "FAVORITE (MOST PLAYS) (SELECTED)" : "FAVORITE (MOST PLAYS)")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .newest
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .newest ? "NEWEST (SELECTED)" : "NEWEST")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .oldest
                                            }
                                        }) {
                                            Text(selectedSortCriteria == .oldest ? "OLDEST (SELECTED)" : "OLDEST")
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.up.arrow.down")
                                                .font(.system(size: 11, weight: .bold))
                                            Text(selectedSortCriteria == .custom ? "SORT" : "SORT: \(selectedSortCriteria.rawValue.uppercased())")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        }
                                        .foregroundStyle(selectedSortCriteria == .custom ? Color.primary : Color.blue)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color.appSecondaryBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke((selectedSortCriteria == .custom ? Color.appSeparator : Color.blue).opacity(0.4), lineWidth: 0.5)
                                        )
                                    }

                                    Button(action: {
                                        HapticFeedback.lightImpact()
                                        showingAddTracksSheet = true
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 11, weight: .bold))
                                            Text("ADD")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        }
                                        .foregroundStyle(Color.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color.appSecondaryBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Color.appSeparator.opacity(0.4), lineWidth: 0.5)
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()
                                }
                                .padding(.bottom, 2)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            Text("TRACKLIST (\(rows.count))")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            if rows.isEmpty {
                                EmptyStateView(
                                    title: searchQuery.isEmpty ? "PLAYLIST IS EMPTY" : "NO MATCHING TRACKS",
                                    message: searchQuery.isEmpty
                                        ? "No tracks in this playlist yet. Tap 'ADD' above to add tracks."
                                        : "No tracks in this playlist match '\(searchQuery)'."
                                )
                                .padding(.top, 16)
                            } else {
                                let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                                PlaylistPlaybackStateReader(playerService: playerService) { state in
                                    LazyVStack(spacing: 4) {
                                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                            playlistTrackRowView(
                                                row: row,
                                                index: index,
                                                rows: rows,
                                                queue: queue,
                                                state: state,
                                                isTapToPlayNext: isTapToPlayNext,
                                                playlist: playlist
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        // Delete Playlist Action
                        Button(action: { showingDeleteAlert = true }) {
                            Text("DELETE PLAYLIST")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 16)
                        }
                        .padding(.top, 12)
                    }
                    .padding(16)
                    .padding(.bottom, 64)
                }
                .dismissKeyboardOnDrag()
                #if os(iOS)
                // Track scrolling (including the drag that pulls the keyboard down) so hiding the keyboard keeps search open
                .onScrollPhaseChange { _, newPhase in
                    isScrollingContent = newPhase.isScrolling
                    lastScrollActivity = Date()
                }
                #endif
            }
            .enableInteractivePopGesture()
            .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
            // iOS 26 toolbar search: always-attached search button in the top bar that expands into a field
            // (no conditional modifier, so opening/closing search doesn't reset the scroll position)
            .searchable(text: $searchQuery, isPresented: $isSearchPresented, placement: .toolbar, prompt: Text("SEARCH TRACKS IN PLAYLIST"))
            .searchToolbarBehavior(.minimize)
            .searchFocused($isSearchFieldFocused)
            // Close search (and the keyboard) in one tap: when the field loses focus without a scroll, end search
            .onChange(of: isSearchFieldFocused) { _, focused in
                // The keyboard Search key also drops focus: skip that one so search stays open with results
                if !focused && didJustSubmitSearch {
                    didJustSubmitSearch = false
                    return
                }
                // Keyboard pulled down by a drag: focus drops as (or just after) the scroll ends, so allow a short grace window
                let recentlyScrolled = isScrollingContent || Date().timeIntervalSince(lastScrollActivity) < 0.6
                if !focused && isSearchPresented && !recentlyScrolled {
                    isSearchPresented = false
                }
            }
            .onSubmit(of: .search) {
                didJustSubmitSearch = true
                // Safety reset in case focus doesn't change, so the next X tap still closes in one tap
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { didJustSubmitSearch = false }
            }
            #endif
            .toolbar {
                #if os(iOS)
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                    // Try to show the search button without the Liquid Glass background
                    .sharedBackgroundVisibility(.hidden)
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleSearch) {
                        Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                    }
                }
                #endif
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingAddTracksSheet) {
                AddTracksToPlaylistSheet(playlistID: playlist.id, libraryStore: libraryStore)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingEditSheet) {
                editPlaylistSheet(for: playlist)
            }
            .sheet(item: $selectedTrackForInfo) { track in
                TrackInfoSheetView(track: track, libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(item: $selectedTrackForPlaylist) { track in
                playlistPickerSheet(for: [track])
            }
            .navigationDestination(item: $selectedArtistForNavigation) { artist in
                ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
            }
            .navigationDestination(item: $selectedAlbumForNavigation) { album in
                AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
            }
            .alert("DELETE PLAYLIST", isPresented: $showingDeleteAlert) {
                Button("CANCEL", role: .cancel) {}
                Button("DELETE", role: .destructive) {
                    libraryStore.deletePlaylist(id: playlist.id)
                    dismiss()
                }
            } message: {
                Text("Are you sure you want to delete '\(playlist.name)'? Audio files on disk will not be affected.")
            }
        } else {
            EmptyStateView(title: "PLAYLIST NOT FOUND", message: "This playlist may have been deleted.")
        }
    }

    // Handle drag changed
    private func handleDragChanged(for track: Track, at currentIndex: Int, in rows: [PlaylistRow], translationY: CGFloat) {
        if draggingTrackID != track.id {
            draggingTrackID = track.id
            accumulatedDragY = 0
            HapticFeedback.lightImpact()
        }

        // Delta
        let delta = translationY - accumulatedDragY
        // Step threshold
        let stepThreshold: CGFloat = 36.0

        if delta > stepThreshold {
            // Dragging down
            if currentIndex < rows.count - 1 {
                // Target track
                let targetTrack = rows[currentIndex + 1].track
                accumulatedDragY += 46.0
                HapticFeedback.lightImpact()
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    libraryStore.movePlaylistTrack(playlistID: playlistID, sourceID: track.id, targetID: targetTrack.id)
                }
            }
        } else if delta < -stepThreshold {
            // Dragging up
            if currentIndex > 0 {
                // Target track
                let targetTrack = rows[currentIndex - 1].track
                accumulatedDragY -= 46.0
                HapticFeedback.lightImpact()
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    libraryStore.movePlaylistTrack(playlistID: playlistID, sourceID: track.id, targetID: targetTrack.id)
                }
            }
        }
    }

    // Handle drag ended
    private func handleDragEnded() {
        draggingTrackID = nil
        accumulatedDragY = 0
        HapticFeedback.selectionChanged()
        libraryStore.savePlaylists()
    }

    // Sort playlist
    private func sortPlaylist(by criteria: PlaylistTrackSortCriteria) {
        HapticFeedback.selectionChanged()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            libraryStore.sortPlaylistTracks(playlistID: playlistID, by: criteria)
        }
    }

    // Toggle search
    private func toggleSearch() {
        if isSearching {
            isSearchFocused = false
            withAnimation(.easeOut(duration: 0.18)) {
                isSearching = false
                searchQuery = ""
            }
        } else {
            withAnimation(.easeIn(duration: 0.18)) {
                isSearching = true
            }
            isSearchFocused = true
        }
    }

    // Header view
    private func headerView(for playlist: Playlist, tracks: [Track]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: { showingEditSheet = true }) {
                AlbumArtworkView(
                    artworkKey: libraryStore.artworkKey(for: playlist),
                    title: playlist.name,
                    subtitle: "Playlist",
                    cornerRadius: 10
                )
                .frame(width: 124, height: 124)
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text("PLAYLIST")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button(action: { showingEditSheet = true }) {
                    Text(playlist.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)

                if !playlist.description.isEmpty {
                    Text(playlist.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.formattedTrackCount)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // Songs whose source is removed, offline or not yet synced stay in the playlist
                    // but are not playable; say so instead of silently hiding them.
                    let unavailable = libraryStore.unavailableTrackCount(for: playlist)
                    if unavailable > 0 {
                        Text("\(unavailable) UNAVAILABLE")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    // Total dur
                    let totalDur = tracks.reduce(0) { $0 + $1.duration }
                    Text(TimeFormatting.formatSummaryDuration(seconds: totalDur))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Playlist track row view helper
    @ViewBuilder
    private func playlistTrackRowView(
        row: PlaylistRow,
        index: Int,
        rows: [PlaylistRow],
        queue: [Track],
        state: PlaylistRowPlaybackState,
        isTapToPlayNext: Bool,
        playlist: Playlist
    ) -> some View {
        let track = row.track
        HStack(spacing: 8) {
            if isEditMode {
                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        libraryStore.removeTrack(trackID: track.id, fromPlaylistID: playlist.id)
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            TrackRowView(
                track: track,
                indexNumber: index + 1,
                isCurrentTrack: track.id == state.currentTrackID,
                isPlaying: state.isPlaying && track.id == state.currentTrackID,
                isNextTrack: track.id == state.nextTrackID,
                isInPlayNext: state.playNextTrackIDs.contains(track.id),
                isTapToPlayNextEnabled: isTapToPlayNext,
                isSwipeDisabled: isEditMode,
                onPlay: {
                    // Same call as AlbumDetailView: full queue in playlist (or chosen sort) order + exact index.
                    playerService.play(track: track, inQueue: queue, startIndex: row.queueIndex)
                },
                onPlayNext: {
                    playerService.insertPlayNextFront(track: track)
                },
                onQueueNext: {
                    playerService.playNext(track: track)
                },
                onAddToQueue: {
                    playerService.appendToQueue(track: track)
                },
                onAddToPlaylist: {
                    selectedTrackForPlaylist = track
                },
                onRemoveFromPlaylist: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        libraryStore.removeTrack(trackID: track.id, fromPlaylistID: playlist.id)
                    }
                },
                onShowInfo: {
                    selectedTrackForInfo = track
                },
                onSelectArtist: { artistName in
                    if let artistObj = libraryStore.findArtist(name: artistName) {
                        selectedArtistForNavigation = artistObj
                    }
                },
                onSelectAlbum: {
                    if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                        selectedAlbumForNavigation = albumObj
                    }
                },
                quickAddLibraryStore: libraryStore,
                quickAddExcludedPlaylistID: playlist.id
            )

            if isEditMode && selectedSortCriteria == .custom {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(draggingTrackID == track.id ? Color.blue : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { gesture in
                                handleDragChanged(for: track, at: index, in: rows, translationY: gesture.translation.height)
                            }
                            .onEnded { _ in
                                handleDragEnded()
                            }
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(draggingTrackID == track.id ? 1.02 : 1.0)
        .shadow(
            color: draggingTrackID == track.id ? Color.black.opacity(0.2) : Color.clear,
            radius: 6,
            x: 0,
            y: 3
        )
        .zIndex(draggingTrackID == track.id ? 10 : 1)
        .onDrag {
            guard isEditMode && selectedSortCriteria == .custom else {
                return NSItemProvider()
            }
            self.draggedTrack = track
            return NSItemProvider(object: track.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: PlaylistDropDelegate(
                item: track,
                playlistID: playlist.id,
                draggedTrack: $draggedTrack,
                libraryStore: libraryStore
            )
        )
    }

    // Playlist picker sheet
    private func playlistPickerSheet(for tracks: [Track]) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: tracks.lazy.compactMap(\.artworkKey).first) { targetPlaylist in
            for track in tracks {
                libraryStore.addTrack(track, toPlaylistID: targetPlaylist.id)
            }
            selectedTrackForPlaylist = nil
        }
    }

    // Edit playlist sheet
    private func editPlaylistSheet(for playlist: Playlist) -> some View {
        EditPlaylistModalView(playlist: playlist, libraryStore: libraryStore)
    }
}

/// Player values the playlist rows need. Read in its own small view so playback changes
/// (play/pause, next track, Play Next badges) re-render only the rows, not the playlist screen.
struct PlaylistRowPlaybackState {
    let currentTrackID: UUID?
    let isPlaying: Bool
    let nextTrackID: UUID?
    let playNextTrackIDs: Set<UUID>
}

/// Scopes `@Observable` player reads to this view's body.
private struct PlaylistPlaybackStateReader<Content: View>: View {
    let playerService: AudioPlayerService
    @ViewBuilder let content: (PlaylistRowPlaybackState) -> Content

    var body: some View {
        content(
            PlaylistRowPlaybackState(
                currentTrackID: playerService.currentTrack?.id,
                isPlaying: playerService.playbackStatus.isPlaying,
                nextTrackID: playerService.queueBadges.nextTrackID,
                playNextTrackIDs: playerService.queueBadges.playNextTrackIDs
            )
        )
    }
}

/// Download control for server songs in a (possibly mixed-source) playlist. Each song downloads from
/// its own server (`download(tracks:)` routes by `folderID`). Download-state changes re-render only this button.
private struct PlaylistDownloadButton: View {
    let tracks: [Track]
    let accentColor: Color

    var body: some View {
        let summary = JellyfinDownloadManager.shared.playlistSummary(for: tracks)
        let isJellyfinPlaylist = summary.total > 0
        let isAllDownloaded = summary.isAllDownloaded
        let isAnyDownloading = summary.isAnyDownloading

        if isJellyfinPlaylist {
            let jellyfinTracks = tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
            let downloadedCount = summary.downloaded
            Button {
                HapticFeedback.selectionChanged()
                if isAllDownloaded {
                    for track in jellyfinTracks {
                        JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
                    }
                } else if isAnyDownloading {
                    for track in jellyfinTracks {
                        JellyfinDownloadManager.shared.cancelDownload(trackId: track.id)
                    }
                } else {
                    JellyfinDownloadManager.shared.download(tracks: jellyfinTracks)
                }
            } label: {
                HStack(spacing: 5) {
                    if isAllDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(accentColor)
                    } else if isAnyDownloading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accentColor)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.primary)
                    }
                }
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if isAllDownloaded {
                    Button(role: .destructive) {
                        HapticFeedback.selectionChanged()
                        for track in jellyfinTracks {
                            JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
                        }
                    } label: {
                        Text("DELETE PLAYLIST DOWNLOADS")
                    }
                } else if isAnyDownloading {
                    Button {
                        HapticFeedback.selectionChanged()
                        for track in jellyfinTracks {
                            JellyfinDownloadManager.shared.cancelDownload(trackId: track.id)
                        }
                    } label: {
                        Text("CANCEL DOWNLOADS")
                    }
                } else {
                    Button {
                        HapticFeedback.selectionChanged()
                        JellyfinDownloadManager.shared.download(tracks: jellyfinTracks)
                    } label: {
                        Text("DOWNLOAD PLAYLIST (\(jellyfinTracks.count - downloadedCount))")
                    }
                }
            }
        }
    }
}

/// Sheet to edit a playlist's name, description and cover. Tap the cover for Photos / Files. Swipe down discards.
struct EditPlaylistModalView: View {
    // Playlist
    let playlist: Playlist
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var selectedArtworkKey: String?
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showingPhotosPicker: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var isProcessingImage: Bool = false
    // NEW PLAYLIST mode: SAVE creates the playlist (then `onCreated`, if any) instead of updating `playlist`
    private let isNew: Bool
    private let previewArtworkKey: String?
    private let onCreated: ((Playlist) -> Void)?

    // Initialize with configured properties
    init(playlist: Playlist, libraryStore: LibraryStore) {
        self.playlist = playlist
        self.libraryStore = libraryStore
        self.isNew = false
        self.previewArtworkKey = nil
        self.onCreated = nil
        _name = State(initialValue: playlist.name)
        _description = State(initialValue: playlist.description)
        _selectedArtworkKey = State(initialValue: playlist.customArtworkKey)
    }

    /// NEW PLAYLIST: blank fields; the picture previews `previewArtworkKey` (the automatic cover once songs are added).
    init(newPlaylistWith libraryStore: LibraryStore, previewArtworkKey: String? = nil, onCreated: ((Playlist) -> Void)? = nil) {
        self.playlist = Playlist(name: "")
        self.libraryStore = libraryStore
        self.isNew = true
        self.previewArtworkKey = previewArtworkKey
        self.onCreated = onCreated
        _name = State(initialValue: "")
        _description = State(initialValue: "")
        _selectedArtworkKey = State(initialValue: nil)
    }

    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingImage
    }

    // Body
    var body: some View {
        let theme = libraryStore.settings.appTheme
        VStack(spacing: 0) {
            // Header: title centered, SAVE on the right
            ZStack {
                Text(isNew ? "NEW PLAYLIST" : "EDIT PLAYLIST")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)

                HStack {
                    Spacer()
                    Button(action: saveAndDismiss) {
                        Text("SAVE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSaveDisabled ? Color.secondary : theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaveDisabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 14) {
                // Cover: tap for Photos / Files
                Menu {
                    Button(action: { showingPhotosPicker = true }) {
                        Text("CHOOSE FROM PHOTOS")
                    }
                    Button(action: { showingFileImporter = true }) {
                        Text("CHOOSE FROM FILES")
                    }
                } label: {
                    ZStack {
                        AlbumArtworkView(
                            artworkKey: selectedArtworkKey ?? (isNew ? previewArtworkKey : libraryStore.artworkKey(for: playlist)),
                            title: name.isEmpty ? "Playlist" : name,
                            subtitle: "Playlist",
                            cornerRadius: 10
                        )
                        .frame(width: 96, height: 96)
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)

                        if isProcessingImage {
                            ProgressView()
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(spacing: 8) {
                    TextField("NAME", text: $name)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    TextField("DESCRIPTION (OPTIONAL)", text: $description, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(2...4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .photosPicker(isPresented: $showingPhotosPicker, selection: $selectedPhotoItem, matching: .images)
        // React to state changes
        .onChange(of: selectedPhotoItem) { _, newItem in
            // Ensure preconditions are met before proceeding
            guard let newItem = newItem else { return }
            Task {
                isProcessingImage = true
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    // Custom key
                    let customKey = "custom_playlist_\(playlist.id.uuidString)_\(UUID().uuidString)"
                    await ArtworkCacheService.shared.saveArtwork(data: data, key: customKey)
                    selectedArtworkKey = customKey
                }
                isProcessingImage = false
                selectedPhotoItem = nil
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                // Ensure preconditions are met before proceeding
                guard let url = urls.first else { return }
                let playlistID = playlist.id
                Task {
                    isProcessingImage = true
                    // Read the file off the main thread
                    let data: Data? = await Task.detached(priority: .userInitiated) {
                        guard url.startAccessingSecurityScopedResource() else { return nil }
                        defer { url.stopAccessingSecurityScopedResource() }
                        return try? Data(contentsOf: url)
                    }.value
                    if let data {
                        // Custom key
                        let customKey = "custom_playlist_\(playlistID.uuidString)_\(UUID().uuidString)"
                        await ArtworkCacheService.shared.saveArtwork(data: data, key: customKey)
                        selectedArtworkKey = customKey
                    }
                    isProcessingImage = false
                }
            case .failure(let error):
                AppLogger.library.error("Failed to import image from file: \(error.localizedDescription)")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.backgroundColor)
        .tint(theme.accentColor)
        .environment(\.appTheme, theme)
    }

    // Save and dismiss
    private func saveAndDismiss() {
        if isNew {
            let created = libraryStore.createPlaylist(name: name, description: description)
            // Custom picture only if one was picked; otherwise the automatic cover (first song's artwork)
            if let selectedArtworkKey {
                libraryStore.updatePlaylist(
                    id: created.id,
                    name: created.name,
                    description: created.description,
                    customArtworkKey: selectedArtworkKey
                )
            }
            dismiss()
            onCreated?(created)
            return
        }
        libraryStore.updatePlaylist(
            id: playlist.id,
            name: name,
            description: description,
            customArtworkKey: selectedArtworkKey
        )
        dismiss()
    }
}

/// Drop delegate providing native long-press drag-and-drop playlist track reordering.
struct PlaylistDropDelegate: DropDelegate {
    // Item
    let item: Track
    // Unique identifier for playlist id
    let playlistID: UUID
    @Binding var draggedTrack: Track?
    let libraryStore: LibraryStore

    // Drop entered
    func dropEntered(info: DropInfo) {
        // Ensure preconditions are met before proceeding
        guard let draggedTrack = draggedTrack,
              draggedTrack.id != item.id else { return }

        HapticFeedback.lightImpact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            libraryStore.movePlaylistTrack(playlistID: playlistID, sourceID: draggedTrack.id, targetID: item.id)
        }
    }

    // Drop updated
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    // Perform drop
    func performDrop(info: DropInfo) -> Bool {
        draggedTrack = nil
        return true
    }
}
