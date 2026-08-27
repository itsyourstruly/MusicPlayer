import SwiftUI

/// Full-page vertical scrollable grid view for an artist's discography section (Albums, Singles, Featured On).
public struct ArtistSectionFullListView: View {
    // Display title
    public let title: String
    // Artist name
    public let artistName: String
    // Albums
    public let albums: [Album]
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    // Columns
    private let columns = [
        GridItem(.adaptive(minimum: 155), spacing: 14)
    ]

    // Initialize with configured properties
    public init(
        title: String,
        artistName: String,
        albums: [Album],
        libraryStore: LibraryStore,
        playerService: AudioPlayerService
    ) {
        self.title = title
        self.artistName = artistName
        self.albums = albums
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    private var displayedAlbums: [Album] {
        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        // Ensure preconditions are met before proceeding
        guard !cleanQuery.isEmpty else { return albums }

        // Scored
        let scored: [(Album, Int)] = albums.compactMap { album in
            // Score
            let score = FuzzyMatcher.scoreAlbum(
                normalizedTitle: album.normalizedTitle,
                normalizedArtist: album.normalizedArtist,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (album, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map { $0.0 }
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // Section Summary Header
                VStack(alignment: .leading, spacing: 2) {
                    Text(artistName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("\(displayedAlbums.count) \(displayedAlbums.count == 1 ? "RELEASE" : "RELEASES")")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if displayedAlbums.isEmpty {
                    EmptyStateView(
                        title: "NO RELEASES FOUND",
                        message: "No albums match '\(searchQuery)'."
                    )
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(displayedAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtworkView(
                                        artworkKey: album.artworkKey,
                                        title: album.title,
                                        subtitle: album.artist,
                                        cornerRadius: 8
                                    )
                                    .aspectRatio(1.0, contentMode: .fit)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)

                                        Text(album.artist)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        Text(album.formattedYear.isEmpty ? album.formattedTrackCount : "\(album.formattedYear) · \(album.formattedTrackCount)")
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
            .padding(.bottom, 140) // Space for floating mini player
        }
        .dismissKeyboardOnDrag()
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "SEARCH \(title)..."
        )
    }
}
