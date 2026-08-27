import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Playlist detail view providing album-style header with tap-to-edit cover and name, track sequencing, and playback.
public struct PlaylistDetailView: View {
    public let playlistID: UUID
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool
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

    private var playlistTracks: [Track] {
        guard let pl = currentPlaylist else { return [] }
        let raw = libraryStore.tracks(for: pl)
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
            return raw.sorted {
                let p1 = libraryStore.playCount(for: $0.id)
                let p2 = libraryStore.playCount(for: $1.id)
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

    private var displayedTracks: [Track] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        guard !cleanQuery.isEmpty else { return playlistTracks }
        let scored: [(Track, Int)] = playlistTracks.compactMap { track in
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (track, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    public var body: some View {
        if let playlist = currentPlaylist {
            VStack(spacing: 0) {
                // Smooth Top Search Bar (Decoupled from ScrollView, zero layout jitter)
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

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Album-style Header with interactive cover & title
                        headerView(for: playlist)

                        // Transport Actions with Edit Mode Pencil Button on the far right
                        HStack(spacing: 12) {
                            Button(action: {
                                if let first = playlistTracks.first {
                                    playerService.play(track: first, inQueue: playlistTracks)
                                }
                            }) {
                                Text("PLAY")
                            }
                            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
                            .disabled(playlistTracks.isEmpty)

                            Button(action: {
                                var shuffled = playlistTracks
                                shuffled.shuffle()
                                if let first = shuffled.first {
                                    playerService.play(track: first, inQueue: shuffled)
                                }
                            }) {
                                Text("SHUFFLE")
                            }
                            .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))
                            .disabled(playlistTracks.isEmpty)

                            Spacer()

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
                                            Label("Custom", systemImage: selectedSortCriteria == .custom ? "checkmark" : "slider.horizontal.3")
                                        }

                                        Divider()

                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .name
                                            }
                                        }) {
                                            Label("Name", systemImage: selectedSortCriteria == .name ? "checkmark" : "textformat")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .artist
                                            }
                                        }) {
                                            Label("Artist", systemImage: selectedSortCriteria == .artist ? "checkmark" : "person.fill")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .album
                                            }
                                        }) {
                                            Label("Album", systemImage: selectedSortCriteria == .album ? "checkmark" : "opticaldisc")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .favorite
                                            }
                                        }) {
                                            Label("Favorite (Most Plays)", systemImage: selectedSortCriteria == .favorite ? "checkmark" : "star.fill")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .newest
                                            }
                                        }) {
                                            Label("Newest", systemImage: selectedSortCriteria == .newest ? "checkmark" : "calendar.badge.plus")
                                        }
                                        Button(action: {
                                            HapticFeedback.selectionChanged()
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selectedSortCriteria = .oldest
                                            }
                                        }) {
                                            Label("Oldest", systemImage: selectedSortCriteria == .oldest ? "checkmark" : "calendar.badge.minus")
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

                            Text("TRACKLIST (\(displayedTracks.count))")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            if displayedTracks.isEmpty {
                                EmptyStateView(
                                    title: searchQuery.isEmpty ? "PLAYLIST IS EMPTY" : "NO MATCHING TRACKS",
                                    message: searchQuery.isEmpty
                                        ? "No tracks in this playlist yet. Tap 'ADD' above to add tracks."
                                        : "No tracks in this playlist match '\(searchQuery)'."
                                )
                                .padding(.top, 16)
                            } else {
                                LazyVStack(spacing: 4) {
                                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
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
                                                isCurrentTrack: track.id == playerService.currentTrack?.id,
                                                isPlaying: playerService.playbackStatus.isPlaying && track.id == playerService.currentTrack?.id,
                                                isNextTrack: playerService.nextTrack?.id == track.id,
                                                isInPlayNext: playerService.playNextQueue.contains(where: { $0.id == track.id }),
                                                isTapToPlayNextEnabled: libraryStore.settings.tapToPlayNext,
                                                isSwipeDisabled: isEditMode,
                                                onPlay: {
                                                    let originalIndex = playlistTracks.firstIndex(where: { $0.id == track.id }) ?? index
                                                    playerService.play(track: track, inQueue: playlistTracks, startIndex: originalIndex)
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
                                                onRemoveFromPlaylist: {
                                                    HapticFeedback.lightImpact()
                                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                                        libraryStore.removeTrack(trackID: track.id, fromPlaylistID: playlist.id)
                                                    }
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
                                                }
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
                                                                handleDragChanged(for: track, at: index, translationY: gesture.translation.height)
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
            }
            .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleSearch) {
                        Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .sheet(isPresented: $showingAddTracksSheet) {
                AddTracksToPlaylistSheet(playlistID: playlist.id, libraryStore: libraryStore)
            }
            .sheet(isPresented: $showingEditSheet) {
                editPlaylistSheet(for: playlist)
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

    private func handleDragChanged(for track: Track, at currentIndex: Int, translationY: CGFloat) {
        if draggingTrackID != track.id {
            draggingTrackID = track.id
            accumulatedDragY = 0
            HapticFeedback.lightImpact()
        }

        let delta = translationY - accumulatedDragY
        let stepThreshold: CGFloat = 36.0

        if delta > stepThreshold {
            // Dragging down
            if currentIndex < displayedTracks.count - 1 {
                let targetTrack = displayedTracks[currentIndex + 1]
                accumulatedDragY += 46.0
                HapticFeedback.lightImpact()
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    libraryStore.movePlaylistTrack(playlistID: playlistID, sourceID: track.id, targetID: targetTrack.id)
                }
            }
        } else if delta < -stepThreshold {
            // Dragging up
            if currentIndex > 0 {
                let targetTrack = displayedTracks[currentIndex - 1]
                accumulatedDragY -= 46.0
                HapticFeedback.lightImpact()
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    libraryStore.movePlaylistTrack(playlistID: playlistID, sourceID: track.id, targetID: targetTrack.id)
                }
            }
        }
    }

    private func handleDragEnded() {
        draggingTrackID = nil
        accumulatedDragY = 0
        HapticFeedback.selectionChanged()
        libraryStore.savePlaylists()
    }

    private func sortPlaylist(by criteria: PlaylistTrackSortCriteria) {
        HapticFeedback.selectionChanged()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            libraryStore.sortPlaylistTracks(playlistID: playlistID, by: criteria)
        }
    }

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

    private func headerView(for playlist: Playlist) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: { showingEditSheet = true }) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: libraryStore.artworkKey(for: playlist),
                        title: playlist.name,
                        subtitle: "Playlist",
                        cornerRadius: 10
                    )
                    .frame(width: 124, height: 124)
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)

                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white, Color.black.opacity(0.65))
                        .padding(4)
                }
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

                    let totalDur = playlistTracks.reduce(0) { $0 + $1.duration }
                    Text(TimeFormatting.formatSummaryDuration(seconds: totalDur))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editPlaylistSheet(for playlist: Playlist) -> some View {
        EditPlaylistModalView(playlist: playlist, libraryStore: libraryStore)
    }
}

/// Modal view to edit playlist name, description, and cover artwork
struct EditPlaylistModalView: View {
    let playlist: Playlist
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var selectedArtworkKey: String?
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showingFileImporter: Bool = false
    @State private var isProcessingImage: Bool = false

    init(playlist: Playlist, libraryStore: LibraryStore) {
        self.playlist = playlist
        self.libraryStore = libraryStore
        _name = State(initialValue: playlist.name)
        _description = State(initialValue: playlist.description)
        _selectedArtworkKey = State(initialValue: playlist.customArtworkKey)
    }

    private var availableArtworkKeys: [String] {
        let plTracks = libraryStore.tracks(for: playlist)
        let plKeys = plTracks.compactMap { $0.artworkKey }
        let allKeys = libraryStore.tracks.compactMap { $0.artworkKey }
        var unique: [String] = []
        for k in plKeys + allKeys {
            if !unique.contains(k) {
                unique.append(k)
            }
        }
        return unique
    }

    var body: some View {
        NavigationStack {
            Form {
                // Live Artwork Preview
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            AlbumArtworkView(
                                artworkKey: selectedArtworkKey ?? libraryStore.artworkKey(for: playlist),
                                title: name.isEmpty ? "Playlist" : name,
                                subtitle: "Preview",
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
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }

                Section("PLAYLIST NAME") {
                    TextField("NAME", text: $name)
                        .font(.system(size: 15, weight: .medium))

                    TextField("DESCRIPTION (OPTIONAL)", text: $description, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(2...4)
                }

                Section("PLAYLIST COVER ARTWORK") {
                    Button(action: {
                        selectedArtworkKey = nil
                    }) {
                        HStack {
                            Text("USE DEFAULT (AUTOMATIC)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if selectedArtworkKey == nil {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if !availableArtworkKeys.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(availableArtworkKeys.prefix(20), id: \.self) { artKey in
                                    Button(action: {
                                        selectedArtworkKey = artKey
                                    }) {
                                        ZStack(alignment: .topTrailing) {
                                            AlbumArtworkView(
                                                artworkKey: artKey,
                                                title: "Cover",
                                                subtitle: "",
                                                cornerRadius: 8
                                            )
                                            .frame(width: 64, height: 64)

                                            if selectedArtworkKey == artKey {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(Color.white, Color.blue)
                                                    .padding(2)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("ADD IMAGE FROM DEVICE") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack {
                            Label("CHOOSE FROM PHOTOS", systemImage: "photo.on.rectangle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { showingFileImporter = true }) {
                        HStack {
                            Label("CHOOSE FROM FILES", systemImage: "folder")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("EDIT PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("CANCEL") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("SAVE") {
                        saveAndDismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem = newItem else { return }
                Task {
                    isProcessingImage = true
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        let customKey = "custom_playlist_\(playlist.id.uuidString)_\(UUID().uuidString)"
                        await ArtworkCacheService.shared.saveArtwork(data: data, key: customKey)
                        await MainActor.run {
                            selectedArtworkKey = customKey
                            isProcessingImage = false
                        }
                    } else {
                        await MainActor.run {
                            isProcessingImage = false
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url) {
                            let customKey = "custom_playlist_\(playlist.id.uuidString)_\(UUID().uuidString)"
                            Task {
                                isProcessingImage = true
                                await ArtworkCacheService.shared.saveArtwork(data: data, key: customKey)
                                await MainActor.run {
                                    selectedArtworkKey = customKey
                                    isProcessingImage = false
                                }
                            }
                        }
                    }
                case .failure(let error):
                    AppLogger.library.error("Failed to import image from file: \(error.localizedDescription)")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveAndDismiss() {
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
    let item: Track
    let playlistID: UUID
    @Binding var draggedTrack: Track?
    let libraryStore: LibraryStore

    func dropEntered(info: DropInfo) {
        guard let draggedTrack = draggedTrack,
              draggedTrack.id != item.id else { return }

        HapticFeedback.lightImpact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            libraryStore.movePlaylistTrack(playlistID: playlistID, sourceID: draggedTrack.id, targetID: item.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTrack = nil
        return true
    }
}
