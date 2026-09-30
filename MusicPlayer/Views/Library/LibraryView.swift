import SwiftUI

/// Main Library screen with categorized navigation (Artists, Albums, Playlists, Tracks),
/// real-time search, and top-right Settings navigation trigger.
public struct LibraryView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Binding var isSearchFocused: Bool
    public let onOpenSettings: () -> Void

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
        .navigationTitle("LIBRARY")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $libraryStore.searchQuery,
            isPresented: $isSearchFocused,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchPrompt
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .onAppear {
            if libraryStore.selectedCategory == .folders && libraryStore.settings.linkedFolders.count <= 1 {
                libraryStore.selectedCategory = .tracks
            }
        }
    }

    private var visibleCategories: [LibraryCategory] {
        if libraryStore.settings.linkedFolders.count > 1 {
            return [.artists, .albums, .playlists, .tracks, .folders]
        } else {
            return [.artists, .albums, .playlists, .tracks]
        }
    }

    private var searchPrompt: String {
        switch libraryStore.selectedCategory {
        case .artists:
            // Count
            let count = libraryStore.artists.count
            return "FIND \(count) \(count == 1 ? "ARTIST" : "ARTISTS")"
        case .albums:
            // Count
            let count = libraryStore.albums.count
            return "FIND \(count) \(count == 1 ? "ALBUM" : "ALBUMS")"
        case .playlists:
            // Count
            let count = libraryStore.playlists.count
            return "FIND \(count) \(count == 1 ? "PLAYLIST" : "PLAYLISTS")"
        case .tracks:
            // Count
            let count = libraryStore.tracks.count
            return "FIND \(count) \(count == 1 ? "TRACK" : "TRACKS")"
        case .folders:
            let count = libraryStore.settings.linkedFolders.count
            return "FIND \(count) \(count == 1 ? "FOLDER" : "FOLDERS")"
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
                    Text(category.title)
                        .font(.system(size: 13, weight: isSelected ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .simultaneousGesture(headerSwipeGesture)
    }
}
