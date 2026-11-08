import SwiftUI

/// Flat list view of all indexed tracks with real-time sorting and context actions.
public struct AllTracksListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let isStandalone: Bool

    @State private var selectedTrackForInfo: Track?
    @State private var selectedTrackForPlaylist: Track?
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var displayLimit: Int = 120
    @Environment(LibrarySelectionStore.self) private var librarySelection: LibrarySelectionStore?

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

    private var baseTracks: [Track] {
        isStandalone ? libraryStore.sortedTracksForBrowsing : libraryStore.filteredTracks
    }

    private var tracks: [Track] {
#if os(iOS)
        guard isStandalone else { return baseTracks }
        let cleanQuery = FuzzyMatcher.normalize(localSearchQuery)
        guard !cleanQuery.isEmpty else { return baseTracks }
        let scored: [(Track, Int)] = baseTracks.compactMap { track in
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (track, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
#else
        baseTracks
#endif
    }

    public var body: some View {
        Group {
            if isStandalone {
#if os(iOS)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        listBody
                            .id("tracksStandaloneTop")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollPhaseChange { _, newPhase in
                        isScrollingContent = newPhase.isScrolling
                        lastScrollActivity = Date()
                    }
                    .onAppear {
                        proxy.scrollTo("tracksStandaloneTop", anchor: .top)
                    }
                }
                .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
                .searchable(
                    text: $localSearchQuery,
                    isPresented: $isSearchPresented,
                    placement: .toolbar,
                    prompt: Text("SEARCH TRACKS")
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
            if !isStandalone { displayLimit = 120 }
        }
#if os(iOS)
        .onChange(of: localSearchQuery) { _, _ in displayLimit = 120 }
#endif
        .onChange(of: libraryStore.trackSortOption) { _, _ in displayLimit = 120 }
        .onChange(of: libraryStore.isTrackSortReversed) { _, _ in displayLimit = 120 }
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            playlistPickerSheet(for: track)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
    }

    private var listBody: some View {
        let tracks = self.tracks
        return VStack(spacing: 10) {
            SortSelectorBar(
                options: TrackSortOption.allCases,
                selectedOption: $libraryStore.trackSortOption,
                isReversed: $libraryStore.isTrackSortReversed,
                labelForOption: { $0.label }
            )

            if tracks.isEmpty {
                let hasSources = !libraryStore.settings.linkedFolders.isEmpty || !libraryStore.settings.serverSources.isEmpty
                if (!libraryStore.isInitialLoading || !hasSources) {
#if os(iOS)
                    let searching = isStandalone ? !localSearchQuery.isEmpty : libraryStore.searchModel.isSearching
#else
                    let searching = libraryStore.searchModel.isSearching
#endif
                    if !searching {
                        EmptyStateView(title: "EMPTY", message: "")
                            .padding(.top, 24)
                    }
                }
            } else {
                let currentTrackID = playerService.currentTrack?.id
                let isCurrentPlaying = playerService.playbackStatus.isPlaying
                let nextTrackID = playerService.queueBadges.nextTrackID
                let playNextSet = playerService.queueBadges.playNextTrackIDs
                let isTapToPlayNext = libraryStore.settings.tapToPlayNext
                let isSelectMode = librarySelection?.isActive ?? false
                let visibleTracks = Array(tracks.prefix(displayLimit))
                let visibleCount = visibleTracks.count

                LazyVStack(spacing: 4) {
                    ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                        AllTracksRowItem(
                            track: track,
                            indexNumber: index + 1,
                            isCurrentTrack: track.id == currentTrackID,
                            isPlaying: isCurrentPlaying && track.id == currentTrackID,
                            isNextTrack: track.id == nextTrackID,
                            isInPlayNext: playNextSet.contains(track.id),
                            isTapToPlayNext: isTapToPlayNext,
                            isSelected: librarySelection?.contains(track.id) ?? false,
                            isSelectMode: isSelectMode,
                            onPlay: {
                                playerService.play(track: track, inQueue: tracks, startIndex: index)
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
                            onToggleSelect: librarySelection?.toggler(for: track),
                            libraryStore: libraryStore
                        )
                        .onAppear {
                            if index >= visibleCount - 30 && visibleCount < tracks.count {
                                displayLimit = min(tracks.count, displayLimit + 120)
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

    private func playlistPickerSheet(for track: Track) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: track.artworkKey) { playlist in
            libraryStore.addTrack(track, toPlaylistID: playlist.id)
            selectedTrackForPlaylist = nil
        }
    }
}

private struct AllTracksRowItem: View, Equatable {
    let track: Track
    let indexNumber: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isNextTrack: Bool
    let isInPlayNext: Bool
    let isTapToPlayNext: Bool
    let isSelected: Bool
    let isSelectMode: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onQueueNext: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onShowInfo: () -> Void
    let onSelectArtist: (String) -> Void
    let onSelectAlbum: () -> Void
    let onToggleSelect: (() -> Void)?
    let libraryStore: LibraryStore

    static func == (lhs: AllTracksRowItem, rhs: AllTracksRowItem) -> Bool {
        lhs.track.id == rhs.track.id &&
        lhs.indexNumber == rhs.indexNumber &&
        lhs.isCurrentTrack == rhs.isCurrentTrack &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isNextTrack == rhs.isNextTrack &&
        lhs.isInPlayNext == rhs.isInPlayNext &&
        lhs.isTapToPlayNext == rhs.isTapToPlayNext &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isSelectMode == rhs.isSelectMode
    }

    var body: some View {
        TrackRowView(
            track: track,
            indexNumber: indexNumber,
            isCurrentTrack: isCurrentTrack,
            isPlaying: isPlaying,
            isNextTrack: isNextTrack,
            isInPlayNext: isInPlayNext,
            isTapToPlayNextEnabled: isTapToPlayNext,
            onPlay: onPlay,
            onPlayNext: onPlayNext,
            onQueueNext: onQueueNext,
            onAddToQueue: onAddToQueue,
            onAddToPlaylist: onAddToPlaylist,
            onShowInfo: onShowInfo,
            onSelectArtist: onSelectArtist,
            onSelectAlbum: onSelectAlbum,
            quickAddLibraryStore: libraryStore,
            isSelected: isSelected,
            isSelectMode: isSelectMode,
            onToggleSelect: onToggleSelect
        )
    }
}
