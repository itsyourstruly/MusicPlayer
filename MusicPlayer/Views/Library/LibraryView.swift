import SwiftUI

/// Main Library screen with categorized navigation (Artists, Albums, Playlists, Tracks),
/// real-time search, and top-right Settings navigation trigger.
public struct LibraryView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Binding var isSearchFocused: Bool
    public let onOpenSettings: () -> Void
    @Environment(LibrarySelectionStore.self) private var librarySelection: LibrarySelectionStore?
    @State private var showingSelectionPlaylistPicker: Bool = false
    @State private var showingSelectionSheet: Bool = false

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        isSearchFocused: Binding<Bool> = .constant(false),
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self._isSearchFocused = isSearchFocused
        self.onOpenSettings = onOpenSettings
    }

    // Main view layout structure
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Category Switcher moves with the rest of the page and overscrolls naturally
                    categorySegmentPicker
                        .id("categoryTopSegment")
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    // Active Category Content
                    Group {
                        switch libraryStore.selectedCategory {
                        case .artists:
                            ArtistsListView(libraryStore: libraryStore, playerService: playerService)
                        case .albums:
                            AlbumsListView(libraryStore: libraryStore, playerService: playerService)
                        case .playlists:
                            PlaylistsListView(libraryStore: libraryStore, playerService: playerService)
                        case .tracks:
                            AllTracksListView(libraryStore: libraryStore, playerService: playerService)
                        case .folders:
                            FoldersListView(libraryStore: libraryStore)
                        }
                    }
                    .transaction { $0.animation = nil }
                }
                .padding(.bottom, 140)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: libraryStore.selectedCategory) {
                proxy.scrollTo("categoryTopSegment", anchor: .top)
            }
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(AppCapitalization.format("LIBRARY", enabled: libraryStore.settings.isCapitalizationEnabled))
        .navigationBarTitleDisplayMode(.large)
        .environment(\.isCapitalizationEnabled, libraryStore.settings.isCapitalizationEnabled)
        .searchable(
            text: $libraryStore.searchQuery,
            isPresented: $isSearchFocused,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchPrompt
        )
        .toolbar {
            if let selection = librarySelection, selection.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    LibrarySelectionCounterMenu(
                        libraryStore: libraryStore,
                        playerService: playerService,
                        selection: selection,
                        onAddToPlaylist: { showingSelectionPlaylistPicker = true },
                        onShowSelection: { showingSelectionSheet = true }
                    )
                }
                // Plain number: no iOS 26 Liquid Glass background
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .sheet(isPresented: $showingSelectionPlaylistPicker) {
            PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: librarySelection?.tracks(in: libraryStore).lazy.compactMap(\.artworkKey).first) { playlist in
                if let selection = librarySelection {
                    let tracks = selection.tracks(in: libraryStore)
                    if !tracks.isEmpty {
                        libraryStore.addTracks(tracks, toPlaylistID: playlist.id)
                        HapticFeedback.notificationSuccess()
                        selection.end()
                    }
                }
                showingSelectionPlaylistPicker = false
            }
        }
        .sheet(isPresented: $showingSelectionSheet) {
            if let selection = librarySelection {
                LibrarySelectionSheet(libraryStore: libraryStore, selection: selection)
            }
        }
        .onAppear {
            if libraryStore.selectedCategory == .folders && totalSourcesCount <= 1 {
                libraryStore.selectedCategory = .tracks
            }
        }
    }

    private var totalSourcesCount: Int {
        libraryStore.settings.linkedFolders.count + libraryStore.settings.serverSources.count
    }

    private var hasMultipleSources: Bool {
        totalSourcesCount > 1
    }

    private var hasAnyServers: Bool {
        !libraryStore.settings.serverSources.isEmpty
    }

    private func title(for category: LibraryCategory) -> String {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        let raw: String
        if category == .folders {
            raw = (hasMultipleSources || hasAnyServers) ? "SOURCES" : "FOLDERS"
        } else {
            raw = category.title
        }
        return AppCapitalization.format(raw, enabled: isCaps)
    }

    private var visibleCategories: [LibraryCategory] {
        if totalSourcesCount > 1 {
            return [.artists, .albums, .playlists, .tracks, .folders]
        } else {
            return [.artists, .albums, .playlists, .tracks]
        }
    }

    private var searchPrompt: String {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        let findWord = AppCapitalization.format("FIND", enabled: isCaps)
        switch libraryStore.selectedCategory {
        case .artists:
            let count = libraryStore.activeArtists.count
            let word = AppCapitalization.format(count == 1 ? "ARTIST" : "ARTISTS", enabled: isCaps)
            return "\(findWord) \(count) \(word)"
        case .albums:
            let count = libraryStore.activeAlbums.count
            let word = AppCapitalization.format(count == 1 ? "ALBUM" : "ALBUMS", enabled: isCaps)
            return "\(findWord) \(count) \(word)"
        case .playlists:
            let count = libraryStore.playlists.count
            let word = AppCapitalization.format(count == 1 ? "PLAYLIST" : "PLAYLISTS", enabled: isCaps)
            return "\(findWord) \(count) \(word)"
        case .tracks:
            let count = libraryStore.activeTracks.count
            let word = AppCapitalization.format(count == 1 ? "TRACK" : "TRACKS", enabled: isCaps)
            return "\(findWord) \(count) \(word)"
        case .folders:
            let count = totalSourcesCount
            let isSources = hasMultipleSources || hasAnyServers
            let rawWord = isSources ? (count == 1 ? "SOURCE" : "SOURCES") : (count == 1 ? "FOLDER" : "FOLDERS")
            let word = AppCapitalization.format(rawWord, enabled: isCaps)
            return "\(findWord) \(count) \(word)"
        }
    }

    private func nextCategory() -> LibraryCategory {
        let cats = visibleCategories
        guard let idx = cats.firstIndex(of: libraryStore.selectedCategory) else { return cats.first ?? .artists }
        return cats[(idx + 1) % cats.count]
    }

    private func previousCategory() -> LibraryCategory {
        let cats = visibleCategories
        guard let idx = cats.firstIndex(of: libraryStore.selectedCategory) else { return cats.first ?? .artists }
        return cats[(idx - 1 + cats.count) % cats.count]
    }

    private var headerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .local)
            .onEnded { value in
                // Horizontal amount
                let horizontalAmount = value.translation.width
                // Vertical amount
                let verticalAmount = value.translation.height
                if abs(horizontalAmount) > abs(verticalAmount) * 2.5 && abs(horizontalAmount) > 40 {
                    if horizontalAmount < -40 {
                        // Swiped Left -> Next tab in carousel
                        HapticFeedback.selectionChanged()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            libraryStore.selectedCategory = nextCategory()
                        }
                    } else if horizontalAmount > 40 {
                        // Swiped Right -> Previous tab in carousel
                        HapticFeedback.selectionChanged()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            libraryStore.selectedCategory = previousCategory()
                        }
                    }
                }
            }
    }

    private var categorySegmentPicker: some View {
        HStack(spacing: 8) {
            ForEach(visibleCategories) { category in
                // Flag indicating if selected
                let isSelected = libraryStore.selectedCategory == category
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                        libraryStore.selectedCategory = category
                    }
                }) {
                    Text(title(for: category))
                        .font(.system(size: 13, weight: isSelected ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(CategoryTabContextMenuModifier(category: category, libraryStore: libraryStore))
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .simultaneousGesture(headerSwipeGesture)
    }
}

// MARK: - Category Tab Context Menu (Columns selection for ARTISTS, ALBUMS, PLAYLISTS)

private struct CategoryTabContextMenuModifier: ViewModifier {
    let category: LibraryCategory
    @Bindable var libraryStore: LibraryStore

    func body(content: Content) -> some View {
        if category == .artists || category == .albums || category == .playlists {
            content.contextMenu {
                let current = libraryStore.settings.gridColumnCount(for: category)
                let isCaps = libraryStore.settings.isCapitalizationEnabled
                Menu {
                    ForEach([2, 3, 4], id: \.self) { count in
                        Button {
                            HapticFeedback.selectionChanged()
                            libraryStore.settings.setGridColumnCount(count, for: category)
                            libraryStore.saveSettings()
                        } label: {
                            if current == count {
                                Label("\(count)", systemImage: "checkmark")
                            } else {
                                Text("\(count)")
                            }
                        }
                    }
                } label: {
                    Text(AppCapitalization.format("COLUMNS", enabled: isCaps))
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Library Multi-Select

/// In-memory Library selection: ordered track IDs plus a Set for O(1) row lookups. Albums add their tracks.
/// Never persisted, so relaunching the app starts outside select mode.
@Observable
final class LibrarySelectionStore {
    private(set) var isActive: Bool = false
    private(set) var orderedIDs: [UUID] = []
    private(set) var idSet: Set<UUID> = []

    var count: Int { orderedIDs.count }

    func contains(_ id: UUID) -> Bool { idSet.contains(id) }

    /// Closure for a row's SELECT / tap toggle.
    func toggler(for track: Track) -> () -> Void {
        { [weak self] in self?.toggle(track) }
    }

    /// Adds or removes a track; entering select mode if needed, leaving it when the last one goes.
    func toggle(_ track: Track) {
        if idSet.contains(track.id) {
            remove(ids: [track.id])
        } else {
            add([track])
        }
    }

    func isAlbumSelected(_ album: Album) -> Bool {
        !album.tracks.isEmpty && album.tracks.allSatisfy { idSet.contains($0.id) }
    }

    /// Fully selected album: removes all its tracks. Otherwise adds the missing ones in album order.
    func toggle(album: Album) {
        if isAlbumSelected(album) {
            remove(ids: Set(album.tracks.map(\.id)))
        } else {
            add(album.tracks)
        }
    }

    func add(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        var ids = orderedIDs
        var set = idSet
        for track in tracks where set.insert(track.id).inserted {
            ids.append(track.id)
        }
        if !isActive { isActive = true }
        orderedIDs = ids
        idSet = set
    }

    func remove(ids: Set<UUID>) {
        orderedIDs.removeAll { ids.contains($0) }
        idSet.subtract(ids)
        if orderedIDs.isEmpty { end() }
    }

    /// Replaces the order (used by the SHOW SELECTION sheet's drag-to-reorder).
    func setOrder(_ ids: [UUID]) {
        orderedIDs = ids
        idSet = Set(ids)
        if ids.isEmpty { end() }
    }

    /// Clears the selection and leaves select mode.
    func end() {
        isActive = false
        orderedIDs = []
        idSet = []
    }

    /// Selected tracks in selection order (tracks no longer in the library are skipped).
    func tracks(in libraryStore: LibraryStore) -> [Track] {
        orderedIDs.compactMap { libraryStore.track(forID: $0) }
    }
}

/// Top-left Library counter: the number of selected songs; tapping opens the selection actions.
private struct LibrarySelectionCounterMenu: View {
    let libraryStore: LibraryStore
    let playerService: AudioPlayerService
    let selection: LibrarySelectionStore
    let onAddToPlaylist: () -> Void
    let onShowSelection: () -> Void
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    var body: some View {
        Menu {
            Button(action: onAddToPlaylist) {
                Text(AppCapitalization.format("ADD TO PLAYLIST", enabled: isCaps))
            }

            QuickAddToPlaylistMenu(libraryStore: libraryStore, onAdded: { selection.end() }) {
                selection.tracks(in: libraryStore)
            }

            Button(action: {
                let tracks = selection.tracks(in: libraryStore)
                guard !tracks.isEmpty else { return }
                playerService.insertPlayNextFront(tracks: tracks)
                HapticFeedback.notificationSuccess()
                selection.end()
            }) {
                Text(AppCapitalization.format("PLAY NEXT", enabled: isCaps))
            }

            Button(action: {
                let tracks = selection.tracks(in: libraryStore)
                guard !tracks.isEmpty else { return }
                playerService.appendToQueue(tracks: tracks)
                HapticFeedback.notificationSuccess()
                selection.end()
            }) {
                Text(AppCapitalization.format("QUEUE", enabled: isCaps))
            }

            Button(action: onShowSelection) {
                Text(AppCapitalization.format("SHOW SELECTION", enabled: isCaps))
            }

            Button(role: .destructive) {
                HapticFeedback.lightImpact()
                selection.end()
            } label: {
                Text(AppCapitalization.format("END SELECTION", enabled: isCaps))
            }
        } label: {
            Text("\(selection.count)")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                .monospacedDigit()
        }
        .tint(libraryStore.settings.appTheme.accentColor)
    }
}

/// SHOW SELECTION: the selected songs in action order. Swipe left to remove, long-press and drag to reorder.
private struct LibrarySelectionSheet: View {
    let libraryStore: LibraryStore
    let selection: LibrarySelectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    var body: some View {
        let theme = libraryStore.settings.appTheme
        let tracks = selection.tracks(in: libraryStore)
        VStack(spacing: 0) {
            Text(AppCapitalization.format("SELECTION (\(tracks.count))", enabled: isCaps))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .padding(.top, 22)
                .padding(.bottom, 12)

            List {
                ForEach(tracks) { track in
                    TrackRowView(
                        track: track,
                        isSwipeDisabled: true,
                        onPlay: {},
                        isContextMenuDisabled: true
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    .listRowBackground(theme.backgroundColor)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            HapticFeedback.lightImpact()
                            selection.remove(ids: [track.id])
                        } label: {
                            Text(AppCapitalization.format("REMOVE", enabled: isCaps))
                        }
                    }
                }
                .onMove { source, destination in
                    var ids = tracks.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    selection.setOrder(ids)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.backgroundColor)
        .tint(theme.accentColor)
        .environment(\.appTheme, theme)
        .onChange(of: selection.count) { _, newCount in
            if newCount == 0 { dismiss() }
        }
    }
}
