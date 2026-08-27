import SwiftUI

/// Categorized native macOS sidebar adhering to Apple HIG, minimalist aesthetics, and strict typographic restraint.
public struct MacSidebarView: View {
    // Library store
    public let libraryStore: LibraryStore
    // Player service
    public let playerService: AudioPlayerService
    @Binding var selectedItem: MacNavigationItem?
    public let onOpenSettings: () -> Void
    // On create playlist
    public let onCreatePlaylist: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        selectedItem: Binding<MacNavigationItem?>,
        onOpenSettings: @escaping () -> Void,
        onCreatePlaylist: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self._selectedItem = selectedItem
        self.onOpenSettings = onOpenSettings
        self.onCreatePlaylist = onCreatePlaylist
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 0) {
            // App Branding Header
            sidebarBrandHeader

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.25))

            // Navigation Sections
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Section 1: Overview
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("OVERVIEW")
                        sidebarRow(item: .home, title: "Home")
                        sidebarRow(item: .search, title: "Search")
                        sidebarRow(item: .discovery, title: "Online Discovery")
                    }

                    // Section 2: Library
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("LIBRARY")
                        sidebarRow(item: .allTracks, title: "All Songs", count: libraryStore.tracks.count)
                        sidebarRow(item: .albums, title: "Albums", count: libraryStore.albums.count)
                        sidebarRow(item: .artists, title: "Artists", count: libraryStore.artists.count)
                    }

                    // Section 3: Intelligence
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("INTELLIGENCE")
                        sidebarRow(
                            item: .duplicates,
                            title: "Duplicates",
                            count: libraryStore.duplicateGroups.count,
                            highlightBadge: !libraryStore.duplicateGroups.isEmpty
                        )
                        sidebarRow(
                            item: .metadataAccuracy,
                            title: "Metadata Accuracy",
                            count: libraryStore.unmatchedTracksCount,
                            highlightBadge: libraryStore.unmatchedTracksCount > 0
                        )
                    }

                    // Section 4: Playlists
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            sectionHeader("PLAYLISTS")
                            Spacer()
                            Button(action: onCreatePlaylist) {
                                Text("+ NEW")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(appTheme.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(appTheme.accentColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 8)

                        if libraryStore.playlists.isEmpty {
                            Text("No playlists yet")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(libraryStore.playlists) { playlist in
                                playlistRow(playlist: playlist)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.25))

            // Footer Status & Settings
            sidebarFooterView
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
        .background(appTheme.secondaryBackgroundColor.opacity(0.45))
    }

    // MARK: - Subviews

    private var sidebarBrandHeader: some View {
        HStack(spacing: 8) {
            Text("MUSIC")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(appTheme.primaryTextColor)

            Spacer()

            if libraryStore.isScanning {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("SCANNING")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(appTheme.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // Section header
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(.secondary.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // Sidebar row
    private func sidebarRow(
        item: MacNavigationItem,
        title: String,
        count: Int? = nil,
        highlightBadge: Bool = false
    ) -> some View {
        // Flag indicating if selected
        let isSelected = selectedItem == item

        return Button(action: {
            selectedItem = item
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? appTheme.primaryTextColor : .secondary)
                    .lineLimit(1)

                Spacer()

                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            highlightBadge
                                ? Color.orange.opacity(0.2)
                                : (isSelected ? appTheme.accentColor.opacity(0.25) : appTheme.tertiaryBackgroundColor)
                        )
                        .foregroundStyle(
                            highlightBadge
                                ? Color.orange
                                : (isSelected ? appTheme.primaryTextColor : .secondary)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? appTheme.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Playlist row
    private func playlistRow(playlist: Playlist) -> some View {
        // Nav item
        let navItem = MacNavigationItem.playlist(playlist.id)
        // Flag indicating if selected
        let isSelected = selectedItem == navItem
        // Flag indicating if pinned
        let isPinned = libraryStore.isPlaylistPinned(playlist)

        return Button(action: {
            selectedItem = navItem
        }) {
            HStack(spacing: 6) {
                Text(playlist.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? appTheme.primaryTextColor : .secondary)
                    .lineLimit(1)

                Spacer()

                if isPinned {
                    Text("PIN")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(appTheme.tertiaryBackgroundColor)
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }

                Text("\(playlist.trackIDs.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? appTheme.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("PLAY") {
                // Tracks
                let tracks = libraryStore.tracks(for: playlist)
                if let first = tracks.first {
                    playerService.play(track: first, inQueue: tracks)
                }
            }
            Button("PLAY NEXT") {
                // Tracks
                let tracks = libraryStore.tracks(for: playlist)
                playerService.playNext(tracks: tracks)
            }
            Button(isPinned ? "UNPIN" : "PIN") {
                libraryStore.togglePinPlaylist(playlist)
            }
            Divider()
            Button("DELETE", role: .destructive) {
                libraryStore.deletePlaylist(playlist)
                if selectedItem == navItem {
                    selectedItem = .home
                }
            }
        }
    }

    private var sidebarFooterView: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(libraryStore.settings.linkedFolderName ?? "NO FOLDER LINKED")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(appTheme.primaryTextColor.opacity(0.85))
                    .lineLimit(1)

                if let lastScan = libraryStore.settings.lastScanDate {
                    Text("\(libraryStore.tracks.count) tracks indexed")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onOpenSettings) {
                Text("SETTINGS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.primaryTextColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(appTheme.tertiaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
