import SwiftUI

/// Pushed from Home carousel headers onto the existing Library list screens (iOS Home).
public enum HomeLibraryListDestination: String, Identifiable, Hashable {
    case artists, albums, playlists, tracks
    public var id: String { rawValue }
}

/// Main Home screen featuring quick playback triggers, pinned playlists, and library specifications.
public struct HomeView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onNavigateToPlaylist: ((Playlist) -> Void)?
    // On open settings
    public let onOpenSettings: () -> Void

    @Binding var selectedAlbumForNavigation: Album?
    @Binding var selectedPlaylistForNavigation: Playlist?
    @Binding var selectedArtistForNavigationHome: Artist?
    @Binding var libraryListDestination: HomeLibraryListDestination?
    @State private var showingShuffleTargetPicker: Bool = false

    @Binding var navigateToSearch: Bool
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    /// Cap horizontal carousels so Home stays light.
    private static let carouselLimit = 24

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        navigateToSearch: Binding<Bool> = .constant(false),
        selectedAlbumForNavigation: Binding<Album?> = .constant(nil),
        selectedPlaylistForNavigation: Binding<Playlist?> = .constant(nil),
        selectedArtistForNavigationHome: Binding<Artist?> = .constant(nil),
        libraryListDestination: Binding<HomeLibraryListDestination?> = .constant(nil),
        onNavigateToPlaylist: ((Playlist) -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self._navigateToSearch = navigateToSearch
        self._selectedAlbumForNavigation = selectedAlbumForNavigation
        self._selectedPlaylistForNavigation = selectedPlaylistForNavigation
        self._selectedArtistForNavigationHome = selectedArtistForNavigationHome
        self._libraryListDestination = libraryListDestination
        self.onNavigateToPlaylist = onNavigateToPlaylist
        self.onOpenSettings = onOpenSettings
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                if isShowingNoSourceState {
                    emptyLibraryBanner
                } else {
#if os(iOS)
                    ForEach(libraryStore.settings.homeSections.filter(\.isEnabled)) { section in
                        homeSectionView(for: section.id)
                    }
#else
                    quickActionsDeck

                    if !libraryStore.pinnedItems.isEmpty {
                        PinnedSection(
                            libraryStore: libraryStore,
                            playerService: playerService,
                            onSelectPlaylist: { playlist in
                                if let customNav = onNavigateToPlaylist {
                                    customNav(playlist)
                                } else {
                                    selectedPlaylistForNavigation = playlist
                                }
                            },
                            onSelectAlbum: { album in
                                selectedAlbumForNavigation = album
                            },
                            onSelectArtist: { artist in
                                selectedArtistForNavigationHome = artist
                            }
                        )
                    }

                    lastAlbumsSection
#endif
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .padding(.bottom, 140) // Padding for floating mini player and tab bar
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(AppCapitalization.format("HOME", enabled: isCaps))
        .navigationBarTitleDisplayMode(.large)
        // Modal presentation sheet
        .sheet(isPresented: $showingShuffleTargetPicker) {
            ShuffleTargetPickerSheet(libraryStore: libraryStore)
        }
        .navigationDestination(isPresented: $navigateToSearch) {
            GlobalSearchView(
                libraryStore: libraryStore,
                playerService: playerService
            )
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(
                album: album,
                libraryStore: libraryStore,
                playerService: playerService
            )
        }
        .navigationDestination(item: $selectedArtistForNavigationHome) { artist in
            ArtistDetailView(
                artist: artist,
                libraryStore: libraryStore,
                playerService: playerService
            )
        }
        .navigationDestination(item: $selectedPlaylistForNavigation) { playlist in
            PlaylistDetailView(
                playlistID: playlist.id,
                libraryStore: libraryStore,
                playerService: playerService
            )
        }
#if os(iOS)
        .navigationDestination(item: $libraryListDestination) { destination in
            switch destination {
            case .artists:
                ArtistsListView(libraryStore: libraryStore, playerService: playerService, isStandalone: true)
                    .navigationTitle(AppCapitalization.format("ARTISTS", enabled: isCaps))
                    .navigationBarTitleDisplayMode(.inline)
            case .albums:
                AlbumsListView(libraryStore: libraryStore, playerService: playerService, isStandalone: true)
                    .navigationTitle(AppCapitalization.format("ALBUMS", enabled: isCaps))
                    .navigationBarTitleDisplayMode(.inline)
            case .playlists:
                PlaylistsListView(libraryStore: libraryStore, playerService: playerService, isStandalone: true)
                    .navigationTitle(AppCapitalization.format("PLAYLISTS", enabled: isCaps))
                    .navigationBarTitleDisplayMode(.inline)
            case .tracks:
                AllTracksListView(libraryStore: libraryStore, playerService: playerService, isStandalone: true)
                    .navigationTitle(AppCapitalization.format("TRACKS", enabled: isCaps))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
#endif
    }

#if os(iOS)
    @ViewBuilder
    private func homeSectionView(for id: HomeSectionID) -> some View {
        switch id {
        case .shuffleSearch:
            quickActionsDeck
        case .pins:
            pinsHomeSection
        case .latestPlays:
            lastAlbumsSection
        case .artists:
            artistsCarouselSection
        case .albums:
            albumsCarouselSection
        case .playlists:
            playlistsCarouselSection
        case .tracks:
            tracksCarouselSection
        }
    }

    private var pinsHomeSection: some View {
        Group {
            if libraryStore.pinnedItems.isEmpty {
                homeSectionHeader(title: "PINS", destination: nil)
            } else {
                PinnedSection(
                    libraryStore: libraryStore,
                    playerService: playerService,
                    onSelectPlaylist: { playlist in
                        if let customNav = onNavigateToPlaylist {
                            customNav(playlist)
                        } else {
                            selectedPlaylistForNavigation = playlist
                        }
                    },
                    onSelectAlbum: { album in
                        selectedAlbumForNavigation = album
                    },
                    onSelectArtist: { artist in
                        selectedArtistForNavigationHome = artist
                    }
                )
            }
        }
    }

    private func homeSectionHeader(title: String, destination: HomeLibraryListDestination?) -> some View {
        Group {
            if let destination {
                Button {
                    HapticFeedback.selectionChanged()
                    libraryListDestination = destination
                } label: {
                    HStack {
                        Text(AppCapitalization.format(title, enabled: isCaps))
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(AppCapitalization.format(title, enabled: isCaps))
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var artistsCarouselSection: some View {
        let items = Array(libraryStore.sortedArtistsForBrowsing.prefix(Self.carouselLimit))
        return VStack(alignment: .leading, spacing: 12) {
            homeSectionHeader(title: "ARTISTS", destination: .artists)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { artist in
                            Button {
                                selectedArtistForNavigationHome = artist
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
                                    .frame(width: 130, height: 130)

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
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var albumsCarouselSection: some View {
        let items = Array(libraryStore.sortedAlbumsForBrowsing.prefix(Self.carouselLimit))
        return VStack(alignment: .leading, spacing: 12) {
            homeSectionHeader(title: "ALBUMS", destination: .albums)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { album in
                            Button {
                                selectedAlbumForNavigation = album
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 8
                                    )
                                    .frame(width: 130, height: 130)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                        Text(album.artist)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService, onGoToArtist: { selectedArtistForNavigationHome = $0 })
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var playlistsCarouselSection: some View {
        let items = Array(libraryStore.sortedPlaylistsForBrowsing.prefix(Self.carouselLimit))
        return VStack(alignment: .leading, spacing: 12) {
            homeSectionHeader(title: "PLAYLISTS", destination: .playlists)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { playlist in
                            Button {
                                if let customNav = onNavigateToPlaylist {
                                    customNav(playlist)
                                } else {
                                    selectedPlaylistForNavigation = playlist
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        AlbumArtworkView(
                                            artworkKey: libraryStore.artworkKey(for: playlist),
                                            title: playlist.name,
                                            subtitle: "Playlist",
                                            cornerRadius: 8
                                        )
                                        .frame(width: 130, height: 130)

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
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .playlistContextMenu(playlist: playlist, libraryStore: libraryStore, playerService: playerService)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var tracksCarouselSection: some View {
        let allTracks = libraryStore.sortedTracksForBrowsing
        let items = Array(allTracks.prefix(Self.carouselLimit))
        return VStack(alignment: .leading, spacing: 12) {
            homeSectionHeader(title: "TRACKS", destination: .tracks)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { track in
                            Button {
                                if let idx = allTracks.firstIndex(where: { $0.id == track.id }) {
                                    playerService.play(track: track, inQueue: allTracks, startIndex: idx)
                                } else {
                                    playerService.play(track: track, inQueue: items)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtworkView(
                                        artworkKey: track.artworkKey,
                                        title: track.title,
                                        subtitle: track.artist,
                                        cornerRadius: 8
                                    )
                                    .frame(width: 130, height: 130)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
#endif

    @ViewBuilder
    private var lastAlbumsSection: some View {
        let recent = libraryStore.recentAlbums
#if os(iOS)
        // Enabled Latest Plays always shows its header, even when empty.
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCapitalization.format("LATEST PLAYS", enabled: isCaps))
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            if !recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(recent) { album in
                            Button(action: {
                                selectedAlbumForNavigation = album
                            }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 8
                                    )
                                    .frame(width: 130, height: 130)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)

                                        Text(album.artist)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService, onGoToArtist: { selectedArtistForNavigationHome = $0 })
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
#else
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppCapitalization.format("LATEST PLAYS", enabled: isCaps))
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(recent) { album in
                            Button(action: {
                                selectedAlbumForNavigation = album
                            }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 8
                                    )
                                    .frame(width: 130, height: 130)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)

                                        Text(album.artist)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService, onGoToArtist: { selectedArtistForNavigationHome = $0 })
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
#endif
    }

    /// No tracks and no linked folders or servers: Home shows only the "NO SOURCE CONNECTED" state.
    private var isShowingNoSourceState: Bool {
        libraryStore.tracks.isEmpty && !libraryStore.isInitialLoading && libraryStore.settings.linkedFolders.isEmpty && libraryStore.settings.serverSources.isEmpty
    }

    /// Centered empty state (no background): title and a large ADD SOURCE button that opens Settings.
    private var emptyLibraryBanner: some View {
        VStack(spacing: 20) {
            Text(AppCapitalization.format("NO SOURCE CONNECTED", enabled: isCaps))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)

            Button(action: onOpenSettings) {
                Text(AppCapitalization.format("ADD SOURCE", enabled: isCaps))
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
            }
            // Opens a sheet, so it gets the system Liquid Glass background
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        // Center vertically in the visible Home area
        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            max(length - 172, 0) // minus the page padding, so the page fits without scrolling
        }
    }

    /// Offline: only tracks on this device join the shuffle.
    private var customShuffleTracks: [Track] {
        let tracks = unfilteredCustomShuffleTracks
        return libraryStore.isOfflineFiltering ? tracks.filter(libraryStore.isPlayableNow) : tracks
    }

    private var unfilteredCustomShuffleTracks: [Track] {
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            return libraryStore.tracks
        case .artist(let name):
            // Unique identifier for artist track i ds
            let artistTrackIDs = Set(libraryStore.findArtist(name: name)?.tracks.map { $0.id } ?? [])
            return libraryStore.tracks.filter { artistTrackIDs.contains($0.id) || $0.artist.localizedCaseInsensitiveContains(name) }
        // Display title of the song
        case .album(let title, let artist):
            return libraryStore.findAlbum(title: title, artist: artist)?.tracks ?? libraryStore.tracks.filter { $0.album.localizedCaseInsensitiveCompare(title) == .orderedSame }
        // Unique track identifier
        case .playlist(let id, _):
            return libraryStore.tracks(forPlaylistID: id)
        }
    }

    private var shuffleButtonTitle: String {
        let title: String
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            title = "SHUFFLE ALL"
        case .artist(let name):
            title = "SHUFFLE \(name)"
        // Display title of the song
        case .album(let albumTitle, _):
            title = "SHUFFLE \(albumTitle)"
        case .playlist(_, let name):
            title = "SHUFFLE \(name)"
        }
        return AppCapitalization.format(title, enabled: isCaps)
    }

    private var shuffleButtonSubtitle: String {
        let count: Int
        switch libraryStore.isOfflineFiltering ? nil : libraryStore.settings.customShuffleTarget {
        case nil:
            count = customShuffleTracks.count
        case .all:
            count = libraryStore.tracks.count
        case .artist(let name):
            count = libraryStore.findArtist(name: name)?.tracks.count ?? libraryStore.tracks.filter { $0.artist.localizedCaseInsensitiveContains(name) }.count
        case .album(let title, let artist):
            count = libraryStore.findAlbum(title: title, artist: artist)?.tracks.count ?? libraryStore.tracks.filter { $0.album.localizedCaseInsensitiveCompare(title) == .orderedSame }.count
        case .playlist(let id, _):
            count = libraryStore.playlists.first(where: { $0.id == id })?.trackIDs.count ?? 0
        }
        let raw: String
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            raw = "\(count) TRACKS"
        case .artist:
            raw = "ARTIST • \(count) TRACKS"
        case .album:
            raw = "ALBUM • \(count) TRACKS"
        case .playlist:
            raw = "PLAYLIST • \(count) TRACKS"
        }
        return AppCapitalization.format(raw, enabled: isCaps)
    }

    private var quickActionsDeck: some View {
        HStack(spacing: 12) {
            // Shuffle All button (with long-press context menu to SET custom target)
            Button(action: {
                // Pool
                var pool = customShuffleTracks
                // Ensure preconditions are met before proceeding
                guard !pool.isEmpty else { return }
                pool.shuffle()
                if let first = pool.first {
                    playerService.play(track: first, inQueue: pool)
                }
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shuffleButtonTitle)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .lineLimit(1)

                    Text(shuffleButtonSubtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground.opacity(0.8))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(action: {
                    showingShuffleTargetPicker = true
                }) {
                    Text(AppCapitalization.format("SET", enabled: isCaps))
                }

                if !libraryStore.settings.customShuffleTarget.isAll {
                    Button(action: {
                        HapticFeedback.lightImpact()
                        libraryStore.settings.customShuffleTarget = .all
                        libraryStore.saveSettings()
                    }) {
                        Text(AppCapitalization.format("RESET TO ALL TRACKS", enabled: isCaps))
                    }
                }
            }

            // Search Library Navigation Button
            Button(action: {
                HapticFeedback.selectionChanged()
                navigateToSearch = true
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppCapitalization.format("SEARCH", enabled: isCaps))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    Text(AppCapitalization.format("LIBRARY", enabled: isCaps))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.appSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.appSeparator.opacity(0.4), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
