import SwiftUI

/// Grid view displaying user playlists in the same layout as albums, with cover art, track count, and context menu.
public struct PlaylistsListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var showingCreateSheet: Bool = false

    // Columns
    private let columns = [
        GridItem(.adaptive(minimum: 155), spacing: 14)
    ]

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 10) {
            // New Playlist Action Trigger Bar
            HStack {
                Button(action: { showingCreateSheet = true }) {
                    HStack(spacing: 4) {
                        Text("+ NEW PLAYLIST")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
                .buttonStyle(TypographicButtonStyle(variant: .primary, size: .mini))

                Spacer()
            }
            .padding(.horizontal, 16)

            // Sort Selector Bar (NAME, MOST) with enlarged hit target and reverse blue toggle
            SortSelectorBar(
                options: PlaylistSortOption.allCases,
                selectedOption: $libraryStore.playlistSortOption,
                isReversed: $libraryStore.isPlaylistSortReversed,
                labelForOption: { $0.label }
            )

            if libraryStore.filteredPlaylists.isEmpty {
                EmptyStateView(
                    title: "EMPTY",
                    message: "Create a playlist to organize your favorite music.",
                    actionTitle: "NEW PLAYLIST",
                    action: { showingCreateSheet = true }
                )
                .padding(.top, 32)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(libraryStore.filteredPlaylists) { playlist in
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
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(action: {
                                HapticFeedback.lightImpact()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    libraryStore.togglePinPlaylist(id: playlist.id)
                                }
                            }) {
                                Label(playlist.isPinned ? "UNPIN" : "PIN", systemImage: playlist.isPinned ? "pin.slash" : "pin")
                            }

                            Button(role: .destructive, action: {
                                libraryStore.deletePlaylist(id: playlist.id)
                            }) {
                                Label("DELETE PLAYLIST", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        // Modal presentation sheet
        .sheet(isPresented: $showingCreateSheet) {
            CreatePlaylistSheet(libraryStore: libraryStore)
        }
    }
}
