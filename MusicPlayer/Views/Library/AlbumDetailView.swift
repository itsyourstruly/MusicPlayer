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
    @State private var serverDescription: ServerDescription? = nil
    @Environment(\.appTheme) private var appTheme

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

    private var currentAlbum: Album {
        if let direct = libraryStore.album(forID: album.id) {
            return direct
        }
        if let normMatch = libraryStore.album(normalizedArtist: album.normalizedArtist, normalizedTitle: album.normalizedTitle) {
            return libraryStore.album(forID: normMatch.id) ?? normMatch
        }
        let validTracks = album.tracks.filter { libraryStore.tracksByID[$0.id] != nil }
        if validTracks.count != album.tracks.count {
            return album.withTracks(validTracks)
        }
        return album
    }

    private func displayedMainTracks(for activeAlbum: Album) -> [Track] {
        let list = activeAlbum.mainTracks
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

    private func displayedAlternateTracks(for activeAlbum: Album) -> [Track] {
        let mainTrackIDs = Set(displayedMainTracks(for: activeAlbum).map(\.id))
        let list = activeAlbum.alternateTracks.filter { !mainTrackIDs.contains($0.id) }
        guard !list.isEmpty else { return [] }
        if list.count == activeAlbum.tracks.count && !activeAlbum.tracks.contains(where: { $0.isAlternate == true }) {
            return []
        }
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
        let activeAlbum = currentAlbum
        let mainTracks = displayedMainTracks(for: activeAlbum)
        let altTracks = displayedAlternateTracks(for: activeAlbum)

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
                    headerView(for: activeAlbum)

                    // Play / Shuffle Actions with Music Note Button on the far right
                    HStack(spacing: 12) {
                        Button(action: {
                            if let first = activeAlbum.tracks.first {
                                playerService.play(track: first, inQueue: activeAlbum.tracks)
                            }
                        }) {
                            Text("PLAY ALBUM")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))

                        Button(action: {
                            // Shuffled
                            var shuffled = activeAlbum.tracks
                            shuffled.shuffle()
                            if let first = shuffled.first {
                                playerService.play(track: first, inQueue: shuffled)
                            }
                        }) {
                            Text("SHUFFLE")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))

                        Spacer()

                        let summary = JellyfinDownloadManager.shared.albumSummary(for: activeAlbum)
                        let isJellyfinAlbum = summary.total > 0
                        let isAllDownloaded = summary.isAllDownloaded
                        let isAnyDownloading = summary.isAnyDownloading

                        // Music note icon button with Album Metadata, Search Online & Playlist Actions
                        Menu {
                            if isJellyfinAlbum {
                                let jellyfinTracks = activeAlbum.tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
                                if isAllDownloaded {
                                    Button(role: .destructive) {
                                        HapticFeedback.selectionChanged()
                                        for track in jellyfinTracks {
                                            JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
                                        }
                                    } label: {
                                        Text("REMOVE ALBUM DOWNLOADS")
                                    }
                                } else if isAnyDownloading {
                                    if JellyfinDownloadManager.shared.isWaitingForWiFi {
                                        Button {} label: {
                                            Text("WAITING FOR WI-FI")
                                        }
                                        .disabled(true)
                                    }
                                    Button {
                                        HapticFeedback.selectionChanged()
                                        for track in jellyfinTracks {
                                            JellyfinDownloadManager.shared.cancelDownload(trackId: track.id)
                                        }
                                    } label: {
                                        Text("CANCEL DOWNLOADS")
                                    }
                                } else {
                                    Button {
                                        HapticFeedback.selectionChanged()
                                        JellyfinDownloadManager.shared.download(tracks: jellyfinTracks)
                                    } label: {
                                        Text(summary.failed > 0 ? "DOWNLOAD FAILED, TAP TO RETRY" : "DOWNLOAD ALBUM")
                                    }
                                }

                                Divider()
                            }

                            if activeAlbum.tracks.contains(where: { $0.supportsMetadataLookup }) {
                                Button(action: {
                                    showingAlbumMetadataSheet = true
                                }) {
                                    Text("ALBUM METADATA")
                                }
                            }

                            // Local albums only; an album that is already collaborative can still be reverted.
                            if libraryStore.isCollaborativeAlbum(activeAlbum) || activeAlbum.tracks.contains(where: { !OfflineMode.isServerTrack($0) }) {
                                Button(action: {
                                    HapticFeedback.notificationSuccess()
                                    libraryStore.toggleCollaborativeAlbum(activeAlbum)
                                }) {
                                    Text(libraryStore.isCollaborativeAlbum(activeAlbum) ? "REVERT COLLABORATIVE ALBUM" : "MAKE COLLABORATIVE ALBUM")
                                }
                            }

                            Button(action: {
                                HapticFeedback.lightImpact()
                                libraryStore.togglePinAlbum(activeAlbum)
                            }) {
                                Text(libraryStore.isAlbumPinned(activeAlbum) ? "UNPIN ALBUM" : "PIN ALBUM")
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
                                            libraryStore.addTracks(activeAlbum.tracks, toPlaylistID: playlist.id)
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
                        Text("TRACKLIST (\(mainTracks.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        if mainTracks.isEmpty && altTracks.isEmpty {
                            EmptyStateView(
                                title: "NO MATCHING TRACKS",
                                message: "No tracks in this album match '\(searchQuery)'."
                            )
                            .padding(.top, 16)
                        } else {
                            let currentTrackID = playerService.currentTrack?.id
                            let isCurrentPlaying = playerService.playbackStatus.isPlaying
                            let nextTrackID = playerService.queueBadges.nextTrackID
                            let playNextSet = playerService.queueBadges.playNextTrackIDs
                            let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                            LazyVStack(spacing: 4) {
                                ForEach(Array(mainTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRowView(
                                        track: track,
                                        indexNumber: index + 1,
                                        isCurrentTrack: track.id == currentTrackID,
                                        isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                        isNextTrack: track.id == nextTrackID,
                                        isInPlayNext: playNextSet.contains(track.id),
                                        isTapToPlayNextEnabled: isTapToPlayNext,
                                        showAlbumSubtitle: false,
                                        onPlay: {
                                            playerService.play(track: track, inQueue: mainTracks, startIndex: index)
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
                                        onSelectAlbum: nil
                                    )
                                }
                            }
                        }
                    }

                    // Alternates Section (Instrumentals, Remixes, Acoustics, Live Versions, etc.)
                    if !altTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ALTERNATES")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            let currentTrackID = playerService.currentTrack?.id
                            let isCurrentPlaying = playerService.playbackStatus.isPlaying
                            let nextTrackID = playerService.queueBadges.nextTrackID
                            let playNextSet = playerService.queueBadges.playNextTrackIDs
                            let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                            LazyVStack(spacing: 4) {
                                ForEach(Array(altTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRowView(
                                        track: track,
                                        indexNumber: nil,
                                        isCurrentTrack: track.id == currentTrackID,
                                        isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                        isNextTrack: track.id == nextTrackID,
                                        isInPlayNext: playNextSet.contains(track.id),
                                        isTapToPlayNextEnabled: isTapToPlayNext,
                                        showAlbumSubtitle: false,
                                        onPlay: {
                                            playerService.play(track: track, inQueue: altTracks, startIndex: index)
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
                                        onSelectAlbum: nil
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
        .navigationTitle(activeAlbum.releaseTypeDisplayTitle)
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
            playlistPickerSheet(for: activeAlbum.tracks)
        }
        // Dedicated Album Metadata Online Search & Apply Sheet
        .sheet(isPresented: $showingAlbumMetadataSheet) {
            AlbumMetadataSheet(album: activeAlbum, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .enableInteractivePopGesture()
    }


    // Playlist picker sheet
    private func playlistPickerSheet(for albumTracks: [Track]) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore) { playlist in
            HapticFeedback.notificationSuccess()
            libraryStore.addTracks(albumTracks, toPlaylistID: playlist.id)
            showingPlaylistPicker = false
            selectedTrackForPlaylist = nil
        }
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

    @ViewBuilder
    private func headerView(for activeAlbum: Album) -> some View {
        HStack(alignment: .top, spacing: 16) {
            AlbumArtworkView(
                artworkKey: activeAlbum.artworkKey,
                title: activeAlbum.title,
                subtitle: activeAlbum.artist,
                cornerRadius: 10,
                targetDimension: 600
            )
            .frame(width: 124, height: 124)
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(activeAlbum.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                MultiArtistButtonsView(
                    rawArtist: activeAlbum.artist,
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
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .contextMenu {
                    if ArtistParser.parseArtists(from: activeAlbum.artist).count > 1 || libraryStore.isArtistJoined(rawArtist: activeAlbum.artist) {
                        if libraryStore.isArtistJoined(rawArtist: activeAlbum.artist) {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.unjoinArtists(for: activeAlbum.artist)
                            }) {
                                Text("SEPARATE ARTISTS")
                            }
                        } else {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.joinArtists(for: activeAlbum.artist)
                            }) {
                                Text("JOIN ARTISTS")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(TimeFormatting.formatSummaryDuration(seconds: activeAlbum.totalDuration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let year = activeAlbum.displayYear {
                        Text(year)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let serverDescription {
                        ServerDescriptionButton(description: serverDescription, title: activeAlbum.title)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .loadsServerDescription(ServerDescriptionTarget.album(activeAlbum, sources: libraryStore.settings.serverSources),
                                sources: libraryStore.settings.serverSources, into: $serverDescription)
    }
}

