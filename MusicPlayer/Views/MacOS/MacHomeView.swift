import SwiftUI

/// Desktop-tailored Home dashboard with minimalist quick actions, pinned items, and library metrics.
public struct MacHomeView: View {
    // Library store
    public let libraryStore: LibraryStore
    // Player service
    public let playerService: AudioPlayerService
    // On navigate to playlist
    public let onNavigateToPlaylist: (Playlist) -> Void
    // On navigate to album
    public let onNavigateToAlbum: (Album) -> Void
    // On navigate to search
    public let onNavigateToSearch: () -> Void
    // On open settings
    public let onOpenSettings: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        onNavigateToPlaylist: @escaping (Playlist) -> Void,
        onNavigateToAlbum: @escaping (Album) -> Void,
        onNavigateToSearch: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.onNavigateToPlaylist = onNavigateToPlaylist
        self.onNavigateToAlbum = onNavigateToAlbum
        self.onNavigateToSearch = onNavigateToSearch
        self.onOpenSettings = onOpenSettings
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Top Hero / Header
                if libraryStore.tracks.isEmpty && !libraryStore.isInitialLoading && libraryStore.settings.linkedFolders.isEmpty && libraryStore.settings.serverSources.isEmpty {
                    unlinkedFolderBanner
                } else if !libraryStore.tracks.isEmpty {
                    desktopQuickActionsDeck
                }

                // Pinned Playlists & Albums Section
                if !libraryStore.pinnedItems.isEmpty {
                    pinnedItemsSection
                }

                // Latest Plays Section
                if !libraryStore.recentAlbums.isEmpty {
                    latestPlaysSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(appTheme.backgroundColor)
    }

    // MARK: - Subviews

    private var unlinkedFolderBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NO MUSIC SOURCE LINKED")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(appTheme.primaryTextColor)

            Text("Link a music folder or connect a Jellyfin server to index, organize, and play your audio library.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text("ADD SOURCE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(appTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .background(appTheme.secondaryBackgroundColor.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(appTheme.separatorColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var desktopQuickActionsDeck: some View {
        HStack(spacing: 10) {
            // 1. Shuffle All
            quickActionButton(
                title: "SHUFFLE ALL",
                subtitle: "\(libraryStore.tracks.count) tracks",
                isAccent: true
            ) {
                // All
                var all = libraryStore.tracks
                all.shuffle()
                if let first = all.first {
                    playerService.play(track: first, inQueue: all)
                }
            }

            // 2. Search
            quickActionButton(
                title: "SEARCH",
                subtitle: "Global library",
                isAccent: false
            ) {
                onNavigateToSearch()
            }

            // 3. Rescan
            quickActionButton(
                title: "RESCAN",
                subtitle: libraryStore.isScanning ? "Scanning..." : "Update files",
                isAccent: false
            ) {
                Task {
                    await libraryStore.rescanCurrentDirectory()
                }
            }
        }
    }

    // Quick action button
    private func quickActionButton(
        title: String,
        subtitle: String,
        isAccent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isAccent ? Color.appInvertedBackground : appTheme.primaryTextColor)

                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(isAccent ? Color.appInvertedBackground.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isAccent
                    ? appTheme.accentColor
                    : appTheme.secondaryBackgroundColor.opacity(0.65)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isAccent
                            ? Color.clear
                            : appTheme.separatorColor.opacity(0.35),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pinned Items Section

    @ViewBuilder
    private var pinnedItemsSection: some View {
        if !libraryStore.pinnedItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("PINNED FAVORITES")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(appTheme.primaryTextColor)

                    Spacer()

                    Text("\(libraryStore.pinnedItems.count) PINNED")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 14)], spacing: 14) {
                    ForEach(libraryStore.pinnedItems) { item in
                        pinnedItemCard(item: item)
                    }
                }
            }
        }
    }

    // Pinned item card
    private func pinnedItemCard(item: PinnedItem) -> some View {
        Button(action: {
            switch item {
            // Album or release title
            case .album(let album):
                onNavigateToAlbum(album)
            case .playlist(let playlist):
                onNavigateToPlaylist(playlist)
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                AlbumArtworkView(
                    artworkKey: item.artworkKey,
                    title: item.title,
                    subtitle: item.subtitle,
                    cornerRadius: 5
                )
                .aspectRatio(1, contentMode: .fit)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appTheme.primaryTextColor)
                        .lineLimit(1)

                    HStack {
                        Text(item.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Text(item.typeLabel)
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(appTheme.tertiaryBackgroundColor)
                            .foregroundStyle(.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                }
            }
            .padding(8)
            .background(appTheme.secondaryBackgroundColor.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(appTheme.separatorColor.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Latest Plays Section

    @ViewBuilder
    private var latestPlaysSection: some View {
        let recent = libraryStore.recentAlbums
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("LATEST PLAYS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(appTheme.primaryTextColor)

                    Spacer()

                    Text("\(recent.count) ALBUMS")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(recent) { album in
                            Button(action: {
                                onNavigateToAlbum(album)
                            }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 5
                                    )
                                    .frame(width: 120, height: 120)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(appTheme.primaryTextColor)
                                            .lineLimit(1)

                                        Text(album.artist)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 120, alignment: .leading)
                                }
                                .padding(8)
                                .background(appTheme.secondaryBackgroundColor.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(appTheme.separatorColor.opacity(0.25), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(action: {
                                    let tracks = album.tracks
                                    if let first = tracks.first {
                                        playerService.play(track: first, inQueue: tracks)
                                    }
                                }) {
                                    Text("PLAY ALBUM")
                                }
                                Button(action: {
                                    playerService.playNext(tracks: album.tracks)
                                }) {
                                    Text("PLAY NEXT")
                                }
                                Button(action: {
                                    playerService.appendToQueue(tracks: album.tracks)
                                }) {
                                    Text("ADD TO QUEUE")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
