import SwiftUI

/// Unified global library search screen that searches tracks, albums, artists, and playlists simultaneously.
/// Automatically focuses search bar and activates keyboard on appear.
public struct GlobalSearchView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    // SearchResults representation
    public struct SearchResults {
        // All tracks loaded in the user library
        public var tracks: [Track] = []
        // Grouped album entities
        public var albums: [Album] = []
        // Grouped artist entities
        public var artists: [Artist] = []
        // User-created and smart playlists
        public var playlists: [Playlist] = []

        // Controls has results
        public var hasResults: Bool {
            !tracks.isEmpty || !albums.isEmpty || !artists.isEmpty || !playlists.isEmpty
        }

        public static let empty = SearchResults()
    }

    @State private var searchQuery: String = ""
    @State private var isSearchPresented: Bool = true
    @State private var results: SearchResults = .empty

    @State private var isTracksCollapsed: Bool = false
    @State private var isAlbumsCollapsed: Bool = false
    @State private var isArtistsCollapsed: Bool = false
    @State private var isPlaylistsCollapsed: Bool = false
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    // Online Search Mode State
    @State private var isOnlineMode: Bool = false
    @State private var onlineResults: OnlineSearchResults = OnlineSearchResults()
    @State private var isOnlineSearching: Bool = false

    // Online columns
    private let onlineColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        initialQuery: String = "",
        initialOnlineMode: Bool = false
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self._searchQuery = State(initialValue: initialQuery)
        self._isOnlineMode = State(initialValue: initialOnlineMode)
        self._isSearchPresented = State(initialValue: true)
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if isOnlineMode {
                onlineContentView
            } else {
                libraryContentView
            }
        }
        .dismissKeyboardOnDrag()
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(isOnlineMode ? "SEARCH ONLINE" : "SEARCH LIBRARY")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchQuery,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: isOnlineMode ? "ANYTHING" : "FIND.."
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isOnlineMode.toggle()
                    }
                    if isOnlineMode {
                        triggerOnlineSearch(query: searchQuery, immediate: true)
                    } else {
                        performSearch(for: searchQuery)
                    }
                }) {
                    Image(systemName: isOnlineMode ? "network" : "network.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isOnlineMode ? Color.blue : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        // Triggered when view appears
        .onAppear {
            isSearchPresented = true
            if isOnlineMode {
                triggerOnlineSearch(query: searchQuery, immediate: true)
            } else {
                performSearch(for: searchQuery)
            }
        }
        // React to state changes
        .onChange(of: searchQuery) { _, newQuery in
            searchTask?.cancel()
            // Clean
            let clean = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                self.results = .empty
                self.onlineResults = OnlineSearchResults()
                self.isOnlineSearching = false
            } else {
                if isOnlineMode {
                    triggerOnlineSearch(query: newQuery, immediate: false)
                } else {
                    searchTask = Task(priority: .userInitiated) {
                        performSearch(for: newQuery)
                    }
                }
            }
        }
        // Triggered when view disappears
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var libraryContentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            if trimmedQuery.isEmpty {
                initialStateView
            } else if !results.hasResults {
                EmptyStateView(
                    title: "NO RESULTS FOUND",
                    message: "No tracks, albums, artists, or playlists match '\(searchQuery)'."
                )
                .padding(.top, 40)
            } else {
                // Tracks Section
                if !results.tracks.isEmpty {
                    tracksSection
                }

                // Albums Section
                if !results.albums.isEmpty {
                    albumsSection
                }

                // Artists Section
                if !results.artists.isEmpty {
                    artistsSection
                }

                // Playlists Section
                if !results.playlists.isEmpty {
                    playlistsSection
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .padding(.bottom, 140) // Space for player bar
    }

    private var onlineContentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isOnlineSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("SEARCHING ONLINE CATALOG...")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else if trimmedQuery.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 40)

                    Text("Search any Artist, Album, or Track to find out more, and 30-second audio previews.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity)
            } else if onlineResults.isEmpty {
                EmptyStateView(
                    title: "NO ONLINE MATCHES",
                    message: "No online tracks, albums, or artists found for '\(searchQuery)'."
                )
                .padding(.top, 40)
            } else {
                // Online Artists
                if !onlineResults.artists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ARTISTS (\(onlineResults.artists.count))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: onlineColumns, spacing: 14) {
                            ForEach(onlineResults.artists) { artist in
                                OnlineArtistGridCard(artist: artist)
                            }
                        }
                    }
                }

                // Online Albums
                if !onlineResults.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ALBUMS (\(onlineResults.albums.count))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: onlineColumns, spacing: 14) {
                            ForEach(onlineResults.albums) { album in
                                OnlineAlbumGridCard(album: album)
                            }
                        }
                    }
                }

                // Online Tracks
                if !onlineResults.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TRACKS (\(onlineResults.tracks.count))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: onlineColumns, spacing: 14) {
                            ForEach(onlineResults.tracks) { track in
                                OnlineTrackGridCard(track: track)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .padding(.bottom, 140) // Space for player bar
    }

    // Trigger online search
    private func triggerOnlineSearch(query: String, immediate: Bool = false) {
        searchTask?.cancel()

        // Clean
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !clean.isEmpty else {
            self.onlineResults = OnlineSearchResults()
            self.isOnlineSearching = false
            return
        }

        self.isOnlineSearching = true
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { return }

            // Results
            let results = await OnlineDiscoveryService.shared.search(query: clean)
            if !Task.isCancelled {
                self.onlineResults = results
                self.isOnlineSearching = false
            }
        }
    }

    // Perform search
    private func performSearch(for query: String) {
        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(query)
        // Ensure preconditions are met before proceeding
        guard !cleanQuery.isEmpty else {
            self.results = .empty
            return
        }

        // Scored tracks
        let scoredTracks: [(Track, Int)] = libraryStore.tracks.compactMap { track in
            // Score
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (track, score) : nil
        }
        // Matched tracks
        let matchedTracks = scoredTracks.sorted { $0.1 > $1.1 }.map { $0.0 }

        // Matched albums
        let matchedAlbums = libraryStore.searchAlbums(query: cleanQuery)

        // Scored artists
        let scoredArtists: [(Artist, Int)] = libraryStore.artists.compactMap { artist in
            // Score
            let score = FuzzyMatcher.scoreArtist(normalizedName: artist.normalizedName, cleanQuery: cleanQuery)
            return score > 0 ? (artist, score) : nil
        }
        // Matched artists
        let matchedArtists = scoredArtists.sorted { $0.1 > $1.1 }.map { $0.0 }

        // Scored playlists
        let scoredPlaylists: [(Playlist, Int)] = libraryStore.playlists.compactMap { playlist in
            // Name score
            let nameScore = FuzzyMatcher.evaluateScore(cleanText: playlist.normalizedName, cleanQuery: cleanQuery)
            // Token score
            let tokenScore = FuzzyMatcher.evaluateScore(cleanText: playlist.searchTokens, cleanQuery: cleanQuery)
            // Max score
            let maxScore = max(nameScore * 2, tokenScore)
            return maxScore > 0 ? (playlist, maxScore) : nil
        }
        // Matched playlists
        let matchedPlaylists = scoredPlaylists.sorted { $0.1 > $1.1 }.map { $0.0 }

        if !Task.isCancelled {
            self.results = SearchResults(
                tracks: matchedTracks,
                albums: matchedAlbums,
                artists: matchedArtists,
                playlists: matchedPlaylists
            )
        }
    }

    private var initialStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .padding(.top, 40)

            Text("Type to search across your entire Library.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections with Tap-to-Collapse Headers

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isTracksCollapsed.toggle()
                }
            }) {
                HStack {
                    Text("TRACKS (\(results.tracks.count))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isTracksCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isTracksCollapsed {
                LazyVStack(spacing: 4) {
                    ForEach(Array(results.tracks.prefix(30).enumerated()), id: \.element.id) { index, track in
                        TrackRowView(
                            track: track,
                            indexNumber: index + 1,
                            isCurrentTrack: track.id == playerService.currentTrack?.id,
                            isPlaying: playerService.playbackStatus.isPlaying && track.id == playerService.currentTrack?.id,
                            isNextTrack: playerService.nextTrack?.id == track.id,
                            isInPlayNext: playerService.playNextQueue.contains(where: { $0.id == track.id }),
                            isTapToPlayNextEnabled: libraryStore.settings.tapToPlayNext,
                            onPlay: {
                                playerService.play(track: track, inQueue: results.tracks, startIndex: index)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isAlbumsCollapsed.toggle()
                }
            }) {
                HStack {
                    Text("ALBUMS (\(results.albums.count))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isAlbumsCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isAlbumsCollapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 18) {
                    ForEach(results.albums) { album in
                        NavigationLink(destination: AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)) {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumArtworkView(
                                    artworkKey: album.artworkKey,
                                    title: album.title,
                                    subtitle: album.artist,
                                    cornerRadius: 8
                                )
                                .aspectRatio(1.0, contentMode: .fit)

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
                        .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isArtistsCollapsed.toggle()
                }
            }) {
                HStack {
                    Text("ARTISTS (\(results.artists.count))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isArtistsCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isArtistsCollapsed {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(results.artists) { artist in
                        NavigationLink(destination: ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(artist.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                Text(artist.discographySummary)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(appTheme.secondaryBackgroundColor.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isPlaylistsCollapsed.toggle()
                }
            }) {
                HStack {
                    Text("PLAYLISTS (\(results.playlists.count))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isPlaylistsCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isPlaylistsCollapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 18) {
                    ForEach(results.playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlistID: playlist.id, libraryStore: libraryStore, playerService: playerService)) {
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
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.white)
                                            .padding(5)
                                            .background(Color.black.opacity(0.65))
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
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
