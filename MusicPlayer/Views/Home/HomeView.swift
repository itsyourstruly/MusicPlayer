import SwiftUI

/// Main Home screen featuring quick playback triggers, pinned playlists, and library specifications.
public struct HomeView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onNavigateToPlaylist: (Playlist) -> Void
    // On open settings
    public let onOpenSettings: () -> Void

    @State private var isStatsExpanded: Bool = false
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var showingShuffleTargetPicker: Bool = false

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        onNavigateToPlaylist: @escaping (Playlist) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.onNavigateToPlaylist = onNavigateToPlaylist
        self.onOpenSettings = onOpenSettings
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Unlinked Folder Banner or Quick Action Deck
                if libraryStore.tracks.isEmpty {
                    emptyLibraryBanner
                } else {
                    quickActionsDeck
                }

                // Pinned Items Section (Albums & Playlists with long-press drag reordering)
                PinnedSection(
                    libraryStore: libraryStore,
                    playerService: playerService,
                    onSelectPlaylist: onNavigateToPlaylist,
                    onSelectAlbum: { album in
                        selectedAlbumForNavigation = album
                    }
                )

                // Library Stats Summary
                if !libraryStore.tracks.isEmpty {
                    libraryStatsSection
                }
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
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(
                album: album,
                libraryStore: libraryStore,
                playerService: playerService
            )
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
        // Count
        let count = customShuffleTracks.count
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
            NavigationLink(destination: GlobalSearchView(libraryStore: libraryStore, playerService: playerService)) {
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

    private var libraryStatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isStatsExpanded.toggle()
                }
            }) {
                HStack {
                    Text("LIBRARY STATS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isStatsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isStatsExpanded {
                VStack(spacing: 10) {
                    statRow(label: "TOTAL TRACKS", value: "\(libraryStore.tracks.count)")
                    statRow(label: "TOTAL ALBUMS", value: "\(libraryStore.albums.count)")
                    statRow(label: "TOTAL ARTISTS", value: "\(libraryStore.artists.count)")
                    statRow(label: "PLAYBACK DURATION", value: TimeFormatting.formatSummaryDuration(seconds: libraryStore.totalLibraryDuration))
                    statRow(label: "STORAGE FOOTPRINT", value: ByteFormatting.formatFileSize(bytes: libraryStore.totalLibraryDiskBytes))
                }
                .semanticCard(cornerRadius: 10, padding: 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // Stat row
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
        }
    }
}
