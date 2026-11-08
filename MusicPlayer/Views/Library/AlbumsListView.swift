import SwiftUI

/// Grid view displaying indexed music albums with artwork thumbnails and release years.
public struct AlbumsListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let isStandalone: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 155), spacing: 14)
    ]

    @State private var selectedAlbum: Album? = nil
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var displayLimit: Int = 80
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

    private var baseAlbums: [Album] {
        isStandalone ? libraryStore.sortedAlbumsForBrowsing : libraryStore.filteredAlbums
    }

    private var albums: [Album] {
#if os(iOS)
        guard isStandalone else { return baseAlbums }
        let cleanQuery = FuzzyMatcher.normalize(localSearchQuery)
        guard !cleanQuery.isEmpty else { return baseAlbums }
        let scored: [(Album, Int)] = baseAlbums.compactMap { album in
            let score = FuzzyMatcher.scoreAlbum(
                normalizedTitle: album.normalizedTitle,
                normalizedArtist: album.normalizedArtist,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (album, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map(\.0)
#else
        baseAlbums
#endif
    }

    public var body: some View {
        Group {
            if isStandalone {
#if os(iOS)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        listBody
                            .id("albumsStandaloneTop")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollPhaseChange { _, newPhase in
                        isScrollingContent = newPhase.isScrolling
                        lastScrollActivity = Date()
                    }
                    .onAppear {
                        proxy.scrollTo("albumsStandaloneTop", anchor: .top)
                    }
                }
                .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
                .searchable(
                    text: $localSearchQuery,
                    isPresented: $isSearchPresented,
                    placement: .toolbar,
                    prompt: Text("SEARCH ALBUMS")
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
        .onChange(of: libraryStore.searchQuery) { _, _ in
            if !isStandalone { displayLimit = 80 }
        }
#if os(iOS)
        .onChange(of: localSearchQuery) { _, _ in displayLimit = 80 }
#endif
        .onChange(of: libraryStore.albumSortOption) { _, _ in displayLimit = 80 }
        .onChange(of: libraryStore.isAlbumSortReversed) { _, _ in displayLimit = 80 }
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
    }

    private var listBody: some View {
        let albums = self.albums
        return VStack(spacing: 10) {
            SortSelectorBar(
                options: AlbumSortOption.allCases,
                selectedOption: $libraryStore.albumSortOption,
                isReversed: $libraryStore.isAlbumSortReversed,
                labelForOption: { $0.label }
            )

            if albums.isEmpty {
                let hasSources = !libraryStore.settings.linkedFolders.isEmpty || !libraryStore.settings.serverSources.isEmpty
                if (!libraryStore.isInitialLoading || !hasSources) {
#if os(iOS)
                    let searching = isStandalone ? !localSearchQuery.isEmpty : libraryStore.searchModel.isSearching
#else
                    let searching = libraryStore.searchModel.isSearching
#endif
                    if !searching {
                        EmptyStateView(title: "EMPTY", message: "")
                    }
                }
            } else {
                let visibleAlbums = Array(albums.prefix(displayLimit))
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(visibleAlbums.enumerated()), id: \.element.id) { index, album in
                        let isPinned = libraryStore.isAlbumPinned(album)
                        Button(action: { selectedAlbum = album }) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 8,
                                        targetDimension: 350
                                    )
                                    .aspectRatio(1.0, contentMode: .fit)

                                    if isPinned {
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
                                    Text(album.title)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(album.formattedTrackCount)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .albumSelectModeTap(album: album) { selectedAlbum = album }
                        .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService, onGoToArtist: { selectedArtistForNavigation = $0 })
                        .onAppear {
                            if index >= visibleAlbums.count - 20 && visibleAlbums.count < albums.count {
                                displayLimit = min(albums.count, displayLimit + 80)
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
