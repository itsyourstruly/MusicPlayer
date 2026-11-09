import SwiftUI

/// Grid of artists matching the album tile look (square art, name + stats under, no card fill).
public struct ArtistsListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    /// When true (Home header push): owns scrolling + album-style toolbar search; ignores Library search drawer.
    public let isStandalone: Bool

    private var columns: [GridItem] {
        if let count = libraryStore.settings.artistsGridColumnCount, (2...4).contains(count) {
            return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
        }
        return [GridItem(.adaptive(minimum: 155), spacing: 14)]
    }

    @State private var selectedArtist: Artist? = nil
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

    private var baseArtists: [Artist] {
        isStandalone ? libraryStore.sortedArtistsForBrowsing : libraryStore.filteredArtists
    }

    private var artists: [Artist] {
#if os(iOS)
        guard isStandalone else { return baseArtists }
        let cleanQuery = FuzzyMatcher.normalize(localSearchQuery)
        guard !cleanQuery.isEmpty else { return baseArtists }
        let scored: [(Artist, Int)] = baseArtists.compactMap { artist in
            let score = FuzzyMatcher.scoreArtist(name: artist.name, query: localSearchQuery)
            return score > 0 ? (artist, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }.map(\.0)
#else
        baseArtists
#endif
    }

    public var body: some View {
        Group {
            if isStandalone {
#if os(iOS)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        listBody
                            .id("artistsStandaloneTop")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollPhaseChange { _, newPhase in
                        isScrollingContent = newPhase.isScrolling
                        lastScrollActivity = Date()
                    }
                    .onAppear {
                        proxy.scrollTo("artistsStandaloneTop", anchor: .top)
                    }
                }
                .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
                .searchable(
                    text: $localSearchQuery,
                    isPresented: $isSearchPresented,
                    placement: .toolbar,
                    prompt: Text(AppCapitalization.format("SEARCH ARTISTS", enabled: libraryStore.settings.isCapitalizationEnabled))
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
        .onChange(of: localSearchQuery) { _, _ in
            displayLimit = 80
        }
#endif
        .onChange(of: libraryStore.artistSortOption) { _, _ in
            displayLimit = 80
        }
        .onChange(of: libraryStore.isArtistSortReversed) { _, _ in
            displayLimit = 80
        }
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
    }

    private var listBody: some View {
        let artists = self.artists
        return VStack(spacing: 10) {
            SortSelectorBar(
                options: ArtistSortOption.allCases,
                selectedOption: $libraryStore.artistSortOption,
                isReversed: $libraryStore.isArtistSortReversed,
                labelForOption: { $0.label }
            )

            if artists.isEmpty {
                let hasSources = !libraryStore.settings.linkedFolders.isEmpty || !libraryStore.settings.serverSources.isEmpty
                if (!libraryStore.isInitialLoading || !hasSources) {
#if os(iOS)
                    let searching = isStandalone ? !localSearchQuery.isEmpty : libraryStore.searchModel.isSearching
#else
                    let searching = libraryStore.searchModel.isSearching
#endif
                    if !searching {
                        EmptyStateView(title: AppCapitalization.format("EMPTY", enabled: libraryStore.settings.isCapitalizationEnabled), message: "")
                            .padding(.top, 24)
                    }
                }
            } else {
                let visibleArtists = Array(artists.prefix(displayLimit))
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(visibleArtists.enumerated()), id: \.element.id) { index, artist in
                        Button {
                            selectedArtist = artist
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumArtworkView(
                                    artworkKey: artist.mostRecentArtworkKey,
                                    title: artist.name,
                                    subtitle: artist.discographySummary,
                                    cornerRadius: 8,
                                    targetDimension: 350,
                                    artistImage: ServerArtistImage.resolve(artist, sources: libraryStore.settings.serverSources)
                                )
                                .aspectRatio(1.0, contentMode: .fit)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)

                                    Text(artist.discographySummary)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if index >= visibleArtists.count - 20 && visibleArtists.count < artists.count {
                                displayLimit = min(artists.count, displayLimit + 80)
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
