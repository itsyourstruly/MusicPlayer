import SwiftUI

/// Detailed album view displaying artwork, metadata tags, summary duration, and sorted tracks.
public struct AlbumDetailView: View {
    // Album title
    public let album: Album
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil
    @State private var showingAlbumMetadataSheet: Bool = false
    @State private var navigateToOnlineSearch: Bool = false

    // Initialize with configured properties
    public init(
        album: Album,
        libraryStore: LibraryStore,
        playerService: AudioPlayerService
    ) {
        self.album = album
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    private var displayedMainTracks: [Track] {
        let list = album.mainTracks
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        guard !cleanQuery.isEmpty else { return list }
        let scored: [(Track, Int)] = list.compactMap { track in
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

    private var displayedAlternateTracks: [Track] {
        let list = album.alternateTracks
        guard !list.isEmpty && list.count < album.tracks.count else { return [] }
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        guard !cleanQuery.isEmpty else { return list }
        let scored: [(Track, Int)] = list.compactMap { track in
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

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 0) {
            // Smooth Top Search Bar (Decoupled from ScrollView, zero layout jitter)
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("SEARCH TRACKS IN ALBUM", text: $searchQuery)
                        .font(.system(size: 13, weight: .medium))
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)

                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
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
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Header with Artwork & Album Info
                    headerView

                    // Play / Shuffle Actions with Music Note Button on the far right
                    HStack(spacing: 12) {
                        Button(action: {
                            if let first = album.tracks.first {
                                playerService.play(track: first, inQueue: album.tracks)
                            }
                        }) {
                            Text("PLAY ALBUM")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))

                        Button(action: {
                            // Shuffled
                            var shuffled = album.tracks
                            shuffled.shuffle()
                            if let first = shuffled.first {
                                playerService.play(track: first, inQueue: shuffled)
                            }
                        }) {
                            Text("SHUFFLE")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))

                        Spacer()

                        // Music note icon button with Album Metadata, Search Online & Playlist Actions
                        Menu {
                            Button(action: {
                                showingAlbumMetadataSheet = true
                            }) {
                                Text("ALBUM METADATA")
                            }

                            Button(action: {
                                navigateToOnlineSearch = true
                            }) {
                                Text("SEARCH ONLINE")
                            }

                            Divider()

                            Button(action: {
                                showingPlaylistPicker = true
                            }) {
                                Text("ADD TO PLAYLIST")
                            }

                            if !libraryStore.playlists.isEmpty {
                                Menu {
                                    ForEach(libraryStore.playlists) { playlist in
                                        Button(action: {
                                            HapticFeedback.notificationSuccess()
                                            libraryStore.addTracks(album.tracks, toPlaylistID: playlist.id)
                                        }) {
                                            Text(playlist.name)
                                        }
                                    }
                                } label: {
                                    Text("QUICK ADD TO...")
                                }
                            }
                        } label: {
                            Image(systemName: "music.note")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Tracklist Section (Main canonical tracks)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TRACKLIST (\(displayedMainTracks.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        if displayedMainTracks.isEmpty && displayedAlternateTracks.isEmpty {
                            EmptyStateView(
                                title: "NO MATCHING TRACKS",
                                message: "No tracks in this album match '\(searchQuery)'."
                            )
                            .padding(.top, 16)
                        } else {
                            let currentTrackID = playerService.currentTrack?.id
                            let isCurrentPlaying = playerService.playbackStatus.isPlaying
                            let nextTrackID = playerService.nextTrack?.id
                            let playNextSet = Set(playerService.playNextQueue.map { $0.id })
                            let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                            LazyVStack(spacing: 4) {
                                ForEach(0..<displayedMainTracks.count, id: \.self) { index in
                                    let track = displayedMainTracks[index]
                                    TrackRowView(
                                        track: track,
                                        indexNumber: index + 1,
                                        isCurrentTrack: track.id == currentTrackID,
                                        isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                        isNextTrack: track.id == nextTrackID,
                                        isInPlayNext: playNextSet.contains(track.id),
                                        isTapToPlayNextEnabled: isTapToPlayNext,
                                        onPlay: {
                                            playerService.play(track: track, inQueue: displayedMainTracks, startIndex: index)
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
                                            // Already in album view
                                        }
                                    )
                                }
                            }
                        }
                    }

                    // Alternates Section (Instrumentals, Remixes, Acoustics, Live Versions, etc.)
                    if !displayedAlternateTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ALTERNATES")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            let currentTrackID = playerService.currentTrack?.id
                            let isCurrentPlaying = playerService.playbackStatus.isPlaying
                            let nextTrackID = playerService.nextTrack?.id
                            let playNextSet = Set(playerService.playNextQueue.map { $0.id })
                            let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                            LazyVStack(spacing: 4) {
                                ForEach(0..<displayedAlternateTracks.count, id: \.self) { index in
                                    let track = displayedAlternateTracks[index]
                                    TrackRowView(
                                        track: track,
                                        indexNumber: nil,
                                        isCurrentTrack: track.id == currentTrackID,
                                        isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                        isNextTrack: track.id == nextTrackID,
                                        isInPlayNext: playNextSet.contains(track.id),
                                        isTapToPlayNextEnabled: isTapToPlayNext,
                                        onPlay: {
                                            playerService.play(track: track, inQueue: displayedAlternateTracks, startIndex: index)
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
                                            // Already in album view
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 64)
            }
            .dismissKeyboardOnDrag()
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        // Modal presentation sheet
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            playlistPickerSheet(for: [track])
        }
        // Modal presentation sheet
        .sheet(isPresented: $showingPlaylistPicker) {
            playlistPickerSheet(for: album.tracks)
        }
        // Dedicated Album Metadata Online Search & Apply Sheet
        .sheet(isPresented: $showingAlbumMetadataSheet) {
            AlbumMetadataSheet(album: album, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(isPresented: $navigateToOnlineSearch) {
            GlobalSearchView(
                libraryStore: libraryStore,
                playerService: playerService,
                initialQuery: "\(album.artist) \(album.title)",
                initialOnlineMode: true
            )
        }
    }


    // Playlist picker sheet
    private func playlistPickerSheet(for albumTracks: [Track]) -> some View {
        NavigationStack {
            List {
                if libraryStore.playlists.isEmpty {
                    EmptyStateView(
                        title: "NO PLAYLISTS FOUND",
                        message: "Create a playlist first from the Library tab."
                    )
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(libraryStore.playlists) { playlist in
                        Button(action: {
                            HapticFeedback.notificationSuccess()
                            libraryStore.addTracks(albumTracks, toPlaylistID: playlist.id)
                            showingPlaylistPicker = false
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color.primary)
                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("ADD ALL (\(albumTracks.count))")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.appSecondaryBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("CANCEL") {
                        showingPlaylistPicker = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

    private var headerView: some View {
        HStack(alignment: .top, spacing: 16) {
            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 10
            )
            .frame(width: 124, height: 124)
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("ALBUM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(album.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                MultiArtistButtonsView(
                    rawArtist: album.artist,
                    joinedArtists: libraryStore.settings.joinedArtists,
                    font: .system(size: 14, weight: .medium),
                    foregroundColor: Color.primary,
                    separatorColor: .secondary,
                    lineLimit: nil,
                    onSelectArtist: { artistName in
                        if let artistObj = libraryStore.findArtist(name: artistName) {
                            selectedArtistForNavigation = artistObj
                        }
                    }
                )
                .contentShape(Rectangle())
                .contextMenu {
                    if ArtistParser.parseArtists(from: album.artist).count > 1 || libraryStore.isArtistJoined(rawArtist: album.artist) {
                        if libraryStore.isArtistJoined(rawArtist: album.artist) {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.unjoinArtists(for: album.artist)
                            }) {
                                Text("SEPARATE ARTISTS")
                            }
                        } else {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.joinArtists(for: album.artist)
                            }) {
                                Text("JOIN ARTISTS")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.formattedTrackCount)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(TimeFormatting.formatSummaryDuration(seconds: album.totalDuration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

