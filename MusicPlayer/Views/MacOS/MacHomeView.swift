//
//  MacHomeView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI

/// Desktop-tailored Home dashboard with minimalist quick actions, pinned items, and library metrics.
public struct MacHomeView: View {
    public let libraryStore: LibraryStore
    public let playerService: AudioPlayerService
    public let onNavigateToPlaylist: (Playlist) -> Void
    public let onNavigateToAlbum: (Album) -> Void
    public let onNavigateToSearch: () -> Void
    public let onNavigateToDiscovery: () -> Void
    public let onOpenSettings: () -> Void

    @Environment(\.appTheme) private var appTheme

    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        onNavigateToPlaylist: @escaping (Playlist) -> Void,
        onNavigateToAlbum: @escaping (Album) -> Void,
        onNavigateToSearch: @escaping () -> Void,
        onNavigateToDiscovery: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.onNavigateToPlaylist = onNavigateToPlaylist
        self.onNavigateToAlbum = onNavigateToAlbum
        self.onNavigateToSearch = onNavigateToSearch
        self.onNavigateToDiscovery = onNavigateToDiscovery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Top Hero / Header
                if libraryStore.tracks.isEmpty {
                    unlinkedFolderBanner
                } else {
                    desktopQuickActionsDeck
                }

                // Pinned Playlists & Albums Section
                pinnedItemsSection

                // Library Overview Metrics
                if !libraryStore.tracks.isEmpty {
                    libraryStatsSection
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
            Text("NO MUSIC FOLDER LINKED")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(appTheme.primaryTextColor)

            Text("Link a local music folder to index, organize, and play your audio library.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text("LINK FOLDER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(appTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onNavigateToDiscovery) {
                    Text("SEARCH ONLINE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.primaryTextColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(appTheme.tertiaryBackgroundColor)
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

            // 3. Online Discovery
            quickActionButton(
                title: "DISCOVER",
                subtitle: "Online metadata",
                isAccent: false
            ) {
                onNavigateToDiscovery()
            }

            // 4. Rescan
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

    private var pinnedItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PINNED FAVORITES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(appTheme.primaryTextColor)

                Spacer()

                if !libraryStore.pinnedItems.isEmpty {
                    Text("\(libraryStore.pinnedItems.count) PINNED")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if libraryStore.pinnedItems.isEmpty {
                VStack(spacing: 6) {
                    Text("NO PINNED ITEMS")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("Right-click any album or playlist in your library to pin it here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(appTheme.secondaryBackgroundColor.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 14)], spacing: 14) {
                    ForEach(libraryStore.pinnedItems) { item in
                        pinnedItemCard(item: item)
                    }
                }
            }
        }
    }

    private func pinnedItemCard(item: PinnedItem) -> some View {
        Button(action: {
            switch item {
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

    // MARK: - Library Stats Section

    private var libraryStatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIBRARY SPECIFICATIONS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(appTheme.primaryTextColor)

            HStack(spacing: 8) {
                statCard(title: "SONGS", value: "\(libraryStore.tracks.count)")
                statCard(title: "ALBUMS", value: "\(libraryStore.albums.count)")
                statCard(title: "ARTISTS", value: "\(libraryStore.artists.count)")
                statCard(title: "PLAYLISTS", value: "\(libraryStore.playlists.count)")
                statCard(title: "TOTAL TIME", value: TimeFormatting.formatTotalDuration(libraryStore.totalLibraryDuration))
                statCard(title: "STORAGE", value: ByteFormatting.formatBytes(libraryStore.totalLibraryDiskBytes))
            }
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(appTheme.primaryTextColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(appTheme.secondaryBackgroundColor.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(appTheme.separatorColor.opacity(0.25), lineWidth: 0.5)
        )
    }
}
