import SwiftUI

/// Grid view displaying user playlists in the same layout as albums, with cover art, track count, and context menu.
public struct PlaylistsListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let isStandalone: Bool

    @State private var showingCreateSheet: Bool = false
    @State private var selectedPlaylistID: UUID? = nil
    @State private var displayLimit: Int = 80

    private let columns = [
        GridItem(.adaptive(minimum: 155), spacing: 14)
    ]

#if os(iOS)
    @State private var localSearchQuery: String = ""
    @State private var isSearchPresented: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isScrollingContent: Bool = false
    @State private var lastScrollActivity: Date = .distantPast
    @State private var didJustSubmitSearch: Bool = false
#endif

    public init(libraryStore: LibraryStore, playerService: AudioPlayerService, isStandalone: Bool = false) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.isStandalone = isStandalone
    }

    private var basePlaylists: [Playlist] {
        isStandalone ? libraryStore.sortedPlaylistsForBrowsing : libraryStore.filteredPlaylists
    }

    private var playlists: [Playlist] {
#if os(iOS)
        guard isStandalone else { return basePlaylists }
        let cleanQuery = FuzzyMatcher.normalize(localSearchQuery)
        guard !cleanQuery.isEmpty else { return basePlaylists }
        return basePlaylists.filter {
            FuzzyMatcher.normalize($0.name).contains(cleanQuery) || $0.name.localizedCaseInsensitiveContains(localSearchQuery)
        }
#else
        basePlaylists
#endif
    }

    public var body: some View {
        Group {
            if isStandalone {
#if os(iOS)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        listBody
                            .id("playlistsStandaloneTop")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollPhaseChange { _, newPhase in
                        isScrollingContent = newPhase.isScrolling
                        lastScrollActivity = Date()
                    }
                    .onAppear {
                        proxy.scrollTo("playlistsStandaloneTop", anchor: .top)
                    }
                }
                .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
                .searchable(
                    text: $localSearchQuery,
                    isPresented: $isSearchPresented,
                    placement: .toolbar,
                    prompt: Text("SEARCH PLAYLISTS")
                )
                .searchToolbarBehavior(.minimize)
                .searchFocused($isSearchFieldFocused)
                .onChange(of: isSearchFieldFocused) { _, focused in
                    if !focused && didJustSubmitSearch {
                        didJustSubmitSearch = false
                        return
                    }
                    let recentlyScrolled = isScrollingContent || Date().timeIntervalSince(lastScrollActivity) < 0.6
                    if !focused && isSearchPresented && !recentlyScrolled {
                        isSearchPresented = false
                    }
                }
                .onSubmit(of: .search) {
                    didJustSubmitSearch = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { didJustSubmitSearch = false }
                }
#else
                listBody
#endif
            } else {
                listBody
            }
        }
#if os(iOS)
        .onChange(of: localSearchQuery) { _, _ in displayLimit = 80 }
#endif
        .onChange(of: libraryStore.playlistSortOption) { _, _ in displayLimit = 80 }
        .onChange(of: libraryStore.isPlaylistSortReversed) { _, _ in displayLimit = 80 }
        .sheet(isPresented: $showingCreateSheet) {
            EditPlaylistModalView(newPlaylistWith: libraryStore)
        }
        .navigationDestination(item: $selectedPlaylistID) { playlistID in
            PlaylistDetailView(playlistID: playlistID, libraryStore: libraryStore, playerService: playerService)
        }
    }

    private var listBody: some View {
        let playlists = self.playlists
        return VStack(spacing: 10) {
            SortSelectorBar(
                options: PlaylistSortOption.allCases,
                selectedOption: $libraryStore.playlistSortOption,
                isReversed: $libraryStore.isPlaylistSortReversed,
                labelForOption: { $0.label }
            )

            HStack {
                Button(action: { showingCreateSheet = true }) {
                    HStack(spacing: 4) {
                        Text("+ NEW PLAYLIST")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
                .buttonStyle(TypographicButtonStyle(variant: .primary, size: .mini))
                Spacer()
            }
            .padding(.horizontal, 16)

            if playlists.isEmpty {
#if os(iOS)
                let searching = isStandalone ? !localSearchQuery.isEmpty : libraryStore.searchModel.isSearching
#else
                let searching = libraryStore.searchModel.isSearching
#endif
                if !searching {
                    EmptyStateView(title: "EMPTY", message: "")
                        .padding(.top, 32)
                }
            } else {
                let visible = Array(playlists.prefix(displayLimit))
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, playlist in
                        Button(action: { selectedPlaylistID = playlist.id }) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    AlbumArtworkView(
                                        artworkKey: libraryStore.artworkKey(for: playlist),
                                        title: playlist.name,
                                        subtitle: "Playlist",
                                        cornerRadius: 8
                                    )
                                    .aspectRatio(1.0, contentMode: .fit)

                                    if playlist.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.appInvertedBackground)
                                            .padding(4)
                                            .background(Color.primary.opacity(0.85))
                                            .clipShape(Circle())
                                            .padding(6)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .playlistContextMenu(playlist: playlist, libraryStore: libraryStore, playerService: playerService)
                        .onAppear {
                            if index >= visible.count - 20 && visible.count < playlists.count {
                                displayLimit = min(playlists.count, displayLimit + 80)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, isStandalone ? 140 : 0)
    }
}
