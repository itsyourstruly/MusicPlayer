import SwiftUI

/// Grid view displaying indexed music albums with artwork thumbnails and release years.
public struct AlbumsListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    private let columns = [
        GridItem(.adaptive(minimum: 155), spacing: 14)
    ]

    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    public var body: some View {
        VStack(spacing: 10) {
            // Sort Selector Bar (TITLE, MOST, ARTIST, DURATION) with enlarged hit target and reverse blue toggle
            SortSelectorBar(
                options: AlbumSortOption.allCases,
                selectedOption: $libraryStore.albumSortOption,
                isReversed: $libraryStore.isAlbumSortReversed,
                labelForOption: { $0.label }
            )

            if libraryStore.filteredAlbums.isEmpty {
                EmptyStateView(
                    title: "NO ALBUMS FOUND",
                    message: libraryStore.searchQuery.isEmpty
                        ? "Link a music directory in Settings to index albums."
                        : "No albums match '\(libraryStore.searchQuery)'."
                )
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(libraryStore.filteredAlbums) { album in
                        let isPinned = libraryStore.isAlbumPinned(album)
                        NavigationLink(destination: AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 8
                                    )
                                    .aspectRatio(1.0, contentMode: .fit)

                                    if isPinned {
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
                .padding(.horizontal, 16)
            }
        }
    }
}
