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
    #if os(iOS)
    // Native search state: lets one tap on the close (X) button end search even while the keyboard is up
    @State private var isSearchPresented: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isScrollingContent: Bool = false
    @State private var lastScrollActivity: Date = .distantPast
    @State private var didJustSubmitSearch: Bool = false
    #endif
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil
    @State private var showingAlbumMetadataSheet: Bool = false
    @State private var serverDescription: ServerDescription? = nil
    @Environment(\.appTheme) private var appTheme
    @Environment(LibrarySelectionStore.self) private var librarySelection: LibrarySelectionStore?

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
            #if os(macOS)
            // Smooth Top Search Bar (Decoupled from ScrollView, zero layout jitter). iOS uses the native search field.
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
            #endif

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


                        // Music note icon button with Album Metadata, Search Online & Playlist Actions
                        Menu {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                playerService.insertPlayNextFront(tracks: activeAlbum.tracks)
                            }) {
                                Text("PLAY NEXT")
                            }

                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                playerService.appendToQueue(tracks: activeAlbum.tracks)
                            }) {
                                Text("QUEUE")
                            }

                            Divider()

                            // Local-source albums only
                            let isLocalAlbum = activeAlbum.tracks.contains(where: { !OfflineMode.isServerTrack($0) })
                            if isLocalAlbum && activeAlbum.tracks.contains(where: { $0.supportsMetadataLookup }) {
                                Button(action: {
                                    showingAlbumMetadataSheet = true
                                }) {
                                    Text("ALBUM METADATA")
                                }
                            }

                            // Local albums only; an album that is already collaborative can still be reverted.
                            if libraryStore.isCollaborativeAlbum(activeAlbum) || isLocalAlbum {
                                Button(action: {
                                    HapticFeedback.notificationSuccess()
                                    libraryStore.toggleCollaborativeAlbum(activeAlbum)
                                }) {
                                    Text(libraryStore.isCollaborativeAlbum(activeAlbum) ? "REVERT COLLABORATIVE ALBUM" : "MAKE COLLABORATIVE ALBUM")
                                }
                            }

                            Divider()

                            Button(action: {
                                showingPlaylistPicker = true
                            }) {
                                Text("ADD TO PLAYLIST")
                            }

                            QuickAddToPlaylistMenu(tracks: activeAlbum.tracks, libraryStore: libraryStore)

                            Divider()

                            // Server albums only
                            AlbumDownloadMenuItems(album: activeAlbum)

                            Button(action: {
                                HapticFeedback.lightImpact()
                                libraryStore.togglePinAlbum(activeAlbum)
                            }) {
                                Text(libraryStore.isAlbumPinned(activeAlbum) ? "UNPIN ALBUM" : "PIN ALBUM")
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
                                        onSelectAlbum: nil,
                                        quickAddLibraryStore: libraryStore,
                                        isSelected: librarySelection?.contains(track.id) ?? false,
                                        isSelectMode: librarySelection?.isActive ?? false,
                                        onToggleSelect: librarySelection?.toggler(for: track)
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
                                        onSelectAlbum: nil,
                                        quickAddLibraryStore: libraryStore,
                                        isSelected: librarySelection?.contains(track.id) ?? false,
                                        isSelectMode: librarySelection?.isActive ?? false,
                                        onToggleSelect: librarySelection?.toggler(for: track)
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
            #if os(iOS)
            // Track scrolling (including the drag that pulls the keyboard down) so hiding the keyboard keeps search open
            .onScrollPhaseChange { _, newPhase in
                isScrollingContent = newPhase.isScrolling
                lastScrollActivity = Date()
            }
            #endif
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(activeAlbum.releaseTypeDisplayTitle)
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        // iOS 26 toolbar search: always-attached search button in the top bar that expands into a field
        // (no conditional modifier, so opening/closing search doesn't reset the scroll position)
        .searchable(text: $searchQuery, isPresented: $isSearchPresented, placement: .toolbar, prompt: Text("SEARCH TRACKS IN ALBUM"))
        .searchToolbarBehavior(.minimize)
        .searchFocused($isSearchFieldFocused)
        // Close search (and the keyboard) in one tap: when the field loses focus without a scroll, end search
        .onChange(of: isSearchFieldFocused) { _, focused in
            // The keyboard Search key also drops focus: skip that one so search stays open with results
            if !focused && didJustSubmitSearch {
                didJustSubmitSearch = false
                return
            }
            // Keyboard pulled down by a drag: focus drops as (or just after) the scroll ends, so allow a short grace window
            let recentlyScrolled = isScrollingContent || Date().timeIntervalSince(lastScrollActivity) < 0.6
            if !focused && isSearchPresented && !recentlyScrolled {
                isSearchPresented = false
            }
        }
        .onSubmit(of: .search) {
            didJustSubmitSearch = true
            // Safety reset in case focus doesn't change, so the next X tap still closes in one tap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { didJustSubmitSearch = false }
        }
        #endif
        .toolbar {
            #if os(iOS)
            DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                // Try to show the search button without the Liquid Glass background
                .sharedBackgroundVisibility(.hidden)
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
            #endif
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
        PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: albumTracks.lazy.compactMap(\.artworkKey).first) { playlist in
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

