import SwiftUI

/// Flat list view of all indexed tracks with real-time sorting and context actions.
public struct AllTracksListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var selectedTrackForInfo: Track?
    @State private var selectedTrackForPlaylist: Track?
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 10) {
            // Sort Selector Bar (TITLE, ARTIST, ALBUM) with enlarged tap target and reverse blue toggle
            SortSelectorBar(
                options: TrackSortOption.allCases,
                selectedOption: $libraryStore.trackSortOption,
                isReversed: $libraryStore.isTrackSortReversed,
                labelForOption: { $0.label }
            )

            if libraryStore.filteredTracks.isEmpty {
                EmptyStateView(
                    title: "NO TRACKS FOUND",
                    message: libraryStore.searchQuery.isEmpty
                        ? "Link a music directory in Settings to scan audio files."
                        : "No tracks match '\(libraryStore.searchQuery)'."
                )
                .padding(.top, 24)
            } else {
                let tracks = libraryStore.filteredTracks
                let currentTrackID = playerService.currentTrack?.id
                let isCurrentPlaying = playerService.playbackStatus.isPlaying
                let nextTrackID = playerService.nextTrack?.id
                let playNextSet = Set(playerService.playNextQueue.map { $0.id })
                let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                LazyVStack(spacing: 4) {
                    ForEach(0..<tracks.count, id: \.self) { index in
                        let track = tracks[index]
                        TrackRowView(
                            track: track,
                            indexNumber: index + 1,
                            isCurrentTrack: track.id == currentTrackID,
                            isPlaying: isCurrentPlaying && track.id == currentTrackID,
                            isNextTrack: track.id == nextTrackID,
                            isInPlayNext: playNextSet.contains(track.id),
                            isTapToPlayNextEnabled: isTapToPlayNext,
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
                    }
                }
                .padding(.horizontal, 16)
            }
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
        NavigationStack {
            List {
                if libraryStore.playlists.isEmpty {
                    Text("No playlists created yet.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryStore.playlists) { playlist in
                        Button(action: {
                            libraryStore.addTrack(track, toPlaylistID: playlist.id)
                            selectedTrackForPlaylist = nil
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 15, weight: .bold))
                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("ADD")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        selectedTrackForPlaylist = nil
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
