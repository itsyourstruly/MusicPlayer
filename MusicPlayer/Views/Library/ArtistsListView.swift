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

    @State private var selectedArtist: Artist? = nil
    @State private var displayLimit: Int = 80

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        let artists = libraryStore.filteredArtists

        VStack(spacing: 10) {
            // Sort Selector Bar (NAME, MOST) with enlarged hit target and reverse blue toggle
            SortSelectorBar(
                options: ArtistSortOption.allCases,
                selectedOption: $libraryStore.artistSortOption,
                isReversed: $libraryStore.isArtistSortReversed,
                labelForOption: { $0.label }
            )

            if artists.isEmpty {
                let hasSources = !libraryStore.settings.linkedFolders.isEmpty || !libraryStore.settings.jellyfinServers.isEmpty
                if (!libraryStore.isInitialLoading || !hasSources) && !libraryStore.searchModel.isSearching {
                    EmptyStateView(
                        title: "NO ARTISTS FOUND",
                        message: libraryStore.searchQuery.isEmpty
                            ? (!hasSources
                                ? "Link a music directory or Jellyfin server in Settings."
                                : "No artists found in library.")
                            : "No artists match '\(libraryStore.searchQuery)'."
                    )
                    .padding(.top, 24)
                }
            } else {
                let visibleCount = min(artists.count, displayLimit)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(0..<visibleCount, id: \.self) { index in
                        let artist = artists[index]
                        Button(action: {
                            selectedArtist = artist
                        }) {
                            HStack(spacing: 12) {
                                AlbumArtworkView(
                                    artworkKey: artist.mostRecentArtworkKey,
                                    title: artist.name,
                                    subtitle: artist.discographySummary,
                                    cornerRadius: 6
                                )
                                .frame(width: 48, height: 48)

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
                        .onAppear {
                            if index >= visibleCount - 20 && visibleCount < artists.count {
                                displayLimit = min(artists.count, displayLimit + 80)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
        .onChange(of: libraryStore.searchQuery) { _, _ in
            displayLimit = 80
        }
        .onChange(of: libraryStore.artistSortOption) { _, _ in
            displayLimit = 80
        }
        .onChange(of: libraryStore.isArtistSortReversed) { _, _ in
            displayLimit = 80
        }
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
    }
}
