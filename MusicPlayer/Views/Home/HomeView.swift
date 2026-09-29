import SwiftUI

/// Main Home screen featuring quick playback triggers, pinned playlists, and library specifications.
public struct HomeView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onNavigateToPlaylist: ((Playlist) -> Void)?
    // On open settings
    public let onOpenSettings: () -> Void

    @Binding var selectedAlbumForNavigation: Album?
    @Binding var selectedPlaylistForNavigation: Playlist?
    @State private var showingShuffleTargetPicker: Bool = false

    @Binding var navigateToSearch: Bool

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        navigateToSearch: Binding<Bool> = .constant(false),
        selectedAlbumForNavigation: Binding<Album?> = .constant(nil),
        selectedPlaylistForNavigation: Binding<Playlist?> = .constant(nil),
        onNavigateToPlaylist: ((Playlist) -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self._navigateToSearch = navigateToSearch
        self._selectedAlbumForNavigation = selectedAlbumForNavigation
        self._selectedPlaylistForNavigation = selectedPlaylistForNavigation
        self.onNavigateToPlaylist = onNavigateToPlaylist
        self.onOpenSettings = onOpenSettings
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Unlinked Folder Banner or Quick Action Deck
                if libraryStore.tracks.isEmpty && !libraryStore.isInitialLoading && libraryStore.settings.linkedFolderName == nil {
                    emptyLibraryBanner
                } else {
                    quickActionsDeck
                }

                // Pinned Items Section (Albums & Playlists with long-press drag reordering)
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
                        }
                    )
                }

                // Recently Listened To Albums ("LATEST PLAYS")
                lastAlbumsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .padding(.bottom, 140) // Padding for floating mini player and tab bar
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("HOME")
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
        .navigationDestination(item: $selectedPlaylistForNavigation) { playlist in
            PlaylistDetailView(
                playlistID: playlist.id,
                libraryStore: libraryStore,
                playerService: playerService
            )
        }
    }

    @ViewBuilder
    private var lastAlbumsSection: some View {
        let recent = libraryStore.recentAlbums
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("LATEST PLAYS")
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
                            .contextMenu {
                                Button(action: {
                                    let tracks = album.tracks
                                    if let first = tracks.first {
                                        playerService.play(track: first, inQueue: tracks)
                                    }
                                }) {
                                    Label("PLAY ALBUM", systemImage: "play.fill")
                                }
                                Button(action: {
                                    let tracks = album.tracks
                                    playerService.playNext(tracks: tracks)
                                }) {
                                    Label("PLAY NEXT", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button(action: {
                                    let tracks = album.tracks
                                    playerService.appendToQueue(tracks: tracks)
                                }) {
                                    Label("ADD TO QUEUE", systemImage: "text.line.last.and.arrowtriangle.forward")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var emptyLibraryBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NO MUSIC DIRECTORY LINKED")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("Link a folder on this device to scan and automatically categorize all your audio tracks, albums, and artists.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            HStack(spacing: 8) {
                Button(action: onOpenSettings) {
                    Text("LINK FOLDER")
                }
                .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
            }
            .padding(.top, 4)
        }
        .semanticCard(cornerRadius: 12, padding: 16)
    }

    private var customShuffleTracks: [Track] {
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            return libraryStore.tracks
        case .artist(let name):
            // Unique identifier for artist track i ds
            let artistTrackIDs = Set(libraryStore.findArtist(name: name)?.tracks.map { $0.id } ?? [])
            return libraryStore.tracks.filter { artistTrackIDs.contains($0.id) || $0.artist.localizedCaseInsensitiveContains(name) }
        // Display title of the song
        case .album(let title, let artist):
            return libraryStore.findAlbum(title: title, artist: artist)?.tracks ?? []
        // Unique track identifier
        case .playlist(let id, _):
            return libraryStore.tracks(forPlaylistID: id)
        }
    }

    private var shuffleButtonTitle: String {
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            return "SHUFFLE ALL"
        case .artist(let name):
            return "SHUFFLE \(name.uppercased())"
        // Display title of the song
        case .album(let title, _):
            return "SHUFFLE \(title.uppercased())"
        case .playlist(_, let name):
            return "SHUFFLE \(name.uppercased())"
        }
    }

    private var shuffleButtonSubtitle: String {
        let count: Int
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            count = libraryStore.tracks.count
        case .artist(let name):
            count = libraryStore.findArtist(name: name)?.tracks.count ?? 0
        case .album(let title, let artist):
            count = libraryStore.findAlbum(title: title, artist: artist)?.tracks.count ?? 0
        case .playlist(let id, _):
            count = libraryStore.playlists.first(where: { $0.id == id })?.trackIDs.count ?? 0
        }
        switch libraryStore.settings.customShuffleTarget {
        case .all:
            return "\(count) TRACKS"
        case .artist:
            return "ARTIST • \(count) TRACKS"
        case .album:
            return "ALBUM • \(count) TRACKS"
        case .playlist:
            return "PLAYLIST • \(count) TRACKS"
        }
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
                    Text("SET")
                }

                if !libraryStore.settings.customShuffleTarget.isAll {
                    Button(action: {
                        HapticFeedback.lightImpact()
                        libraryStore.settings.customShuffleTarget = .all
                        libraryStore.saveSettings()
                    }) {
                        Text("RESET TO ALL TRACKS")
                    }
                }
            }

            // Search Library Navigation Button
            Button(action: {
                HapticFeedback.selectionChanged()
                navigateToSearch = true
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SEARCH")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    Text("LIBRARY")
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
