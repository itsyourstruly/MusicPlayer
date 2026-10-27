import SwiftUI

/// Flat list view of all indexed tracks with real-time sorting and context actions.
public struct AllTracksListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var selectedTrackForInfo: Track?
    @State private var selectedTrackForPlaylist: Track?
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var displayLimit: Int = 120

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        let tracks = libraryStore.filteredTracks

        VStack(spacing: 10) {
            // Sort Selector Bar (TITLE, ARTIST, ALBUM) with enlarged tap target and reverse blue toggle
            SortSelectorBar(
                options: TrackSortOption.allCases,
                selectedOption: $libraryStore.trackSortOption,
                isReversed: $libraryStore.isTrackSortReversed,
                labelForOption: { $0.label }
            )

            if tracks.isEmpty {
                let hasSources = !libraryStore.settings.linkedFolders.isEmpty || !libraryStore.settings.serverSources.isEmpty
                if (!libraryStore.isInitialLoading || !hasSources) && !libraryStore.searchModel.isSearching {
                    EmptyStateView(title: "EMPTY", message: "")
                    .padding(.top, 24)
                }
            } else {
                let currentTrackID = playerService.currentTrack?.id
                let isCurrentPlaying = playerService.playbackStatus.isPlaying
                let nextTrackID = playerService.queueBadges.nextTrackID
                let playNextSet = playerService.queueBadges.playNextTrackIDs
                let isTapToPlayNext = libraryStore.settings.tapToPlayNext
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
                            }
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
        .onChange(of: libraryStore.searchQuery) { _, _ in
            displayLimit = 120
        }
        .onChange(of: libraryStore.trackSortOption) { _, _ in
            displayLimit = 120
        }
        .onChange(of: libraryStore.isTrackSortReversed) { _, _ in
            displayLimit = 120
        }
        // Modal presentation sheet
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        // Modal presentation sheet
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

    // Playlist picker sheet
    private func playlistPickerSheet(for track: Track) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore) { playlist in
            libraryStore.addTrack(track, toPlaylistID: playlist.id)
            selectedTrackForPlaylist = nil
        }
    }
}

// MARK: - Isolated Child Row Component for Smooth 60 FPS Scrolling

private struct AllTracksRowItem: View, Equatable {
    let track: Track
    let indexNumber: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isNextTrack: Bool
    let isInPlayNext: Bool
    let isTapToPlayNext: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onQueueNext: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onShowInfo: () -> Void
    let onSelectArtist: (String) -> Void
    let onSelectAlbum: () -> Void

    static func == (lhs: AllTracksRowItem, rhs: AllTracksRowItem) -> Bool {
        lhs.track.id == rhs.track.id &&
        lhs.indexNumber == rhs.indexNumber &&
        lhs.isCurrentTrack == rhs.isCurrentTrack &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isNextTrack == rhs.isNextTrack &&
        lhs.isInPlayNext == rhs.isInPlayNext &&
        lhs.isTapToPlayNext == rhs.isTapToPlayNext
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
            onSelectAlbum: onSelectAlbum
        )
    }
}
