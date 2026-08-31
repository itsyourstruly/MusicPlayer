import SwiftUI

/// Grid view displaying indexed artists in a clean 2-column typographic layout.
public struct ArtistsListView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Environment(\.appTheme) private var appTheme

    // Columns
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 10) {
            // Sort Selector Bar (NAME, MOST) with enlarged hit target and reverse blue toggle
            SortSelectorBar(
                options: ArtistSortOption.allCases,
                selectedOption: $libraryStore.artistSortOption,
                isReversed: $libraryStore.isArtistSortReversed,
                labelForOption: { $0.label }
            )

            if libraryStore.filteredArtists.isEmpty {
                EmptyStateView(
                    title: "NO ARTISTS FOUND",
                    message: libraryStore.searchQuery.isEmpty
                        ? "Link a music directory in Settings to index artists."
                        : "No artists match '\(libraryStore.searchQuery)'."
                )
                .padding(.top, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(libraryStore.filteredArtists) { artist in
                        NavigationLink(destination: ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)) {
                            HStack(spacing: 12) {
                                AlbumArtworkView(
                                    artworkKey: artist.mostRecentArtworkKey,
                                    title: artist.name,
                                    subtitle: artist.discographySummary,
                                    cornerRadius: 6
                                )
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artist.name)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Text(artist.discographySummary)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(appTheme.secondaryBackgroundColor.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
