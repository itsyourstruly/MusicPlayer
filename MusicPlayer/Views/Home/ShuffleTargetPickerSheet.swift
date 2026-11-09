import SwiftUI

/// Sheet for choosing what the Home SHUFFLE button plays: ALL TRACKS, a recently played album,
/// or any artist, album or playlist found through search.
public struct ShuffleTargetPickerSheet: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    @State private var searchQuery: String = ""
    @State private var selectedTargetForConfirmation: ShuffleTarget? = nil
    @State private var showConfirmationAlert: Bool = false

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    /// Ranked results from the Library search engine for `query` (kept on screen until newer ones arrive).
    private struct TargetSearchResults {
        var query: String = ""
        var artists: [Artist] = []
        var albums: [Album] = []
        var playlists: [Playlist] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && playlists.isEmpty }
    }

    @State private var results = TargetSearchResults()

    private var cleanQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same rule as Library search: fewer than 2 characters shows the default list.
    private var isQueryActive: Bool {
        SearchNormalizer.meetsMinimumLength(cleanQuery)
    }

    /// Debounced, cancellable search through the shared Library search engine (runs off the main thread,
    /// normalizes the query itself, returns ranked and capped results). A newer keystroke cancels this run.
    private func runSearch() async {
        let query = cleanQuery
        guard SearchNormalizer.meetsMinimumLength(query) else {
            if !results.query.isEmpty { results = TargetSearchResults() }
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        let flat = await SearchEngine.shared.searchFlat(
            query: query,
            maxTrackResults: 0,
            maxAlbumResults: 40,
            maxArtistResults: 25,
            maxPlaylistResults: 20
        )
        guard !Task.isCancelled, query == cleanQuery else { return }

        let playlistsByID = Dictionary(libraryStore.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = TargetSearchResults(
            query: query,
            artists: flat.artistIDs.compactMap { libraryStore.artist(forID: $0) },
            albums: flat.albumIDs.compactMap { libraryStore.album(forID: $0) },
            playlists: flat.playlistIDs.compactMap { playlistsByID[$0] }
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !isQueryActive {
                        defaultContent
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .dismissKeyboardOnDrag()
            .task(id: searchQuery) {
                await runSearch()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle(AppCapitalization.format("SET SHUFFLE TARGET", enabled: isCaps))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Same monospaced header as before, shown as the top-bar title
                ToolbarItem(placement: .principal) {
                    Text(AppCapitalization.format("SET SHUFFLE TARGET", enabled: isCaps))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                #if os(iOS)
                .sharedBackgroundVisibility(.hidden)
                #endif
            }
            #if os(iOS)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            #endif
            .nativeSearchField(text: $searchQuery, prompt: "SEARCH ARTISTS, ALBUMS, PLAYLISTS")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appTheme.backgroundColor)
        .alert(
            confirmationTitle,
            isPresented: $showConfirmationAlert,
            presenting: selectedTargetForConfirmation
        ) { target in
            Button("CONFIRM") {
                HapticFeedback.notificationSuccess()
                libraryStore.settings.customShuffleTarget = target
                libraryStore.saveSettings()
                dismiss()
            }
            Button("CANCEL", role: .cancel) {}
        }
    }

    // MARK: - Empty Search: ALL TRACKS + LATEST PLAYS

    @ViewBuilder
    private var defaultContent: some View {
        targetRow(
            title: "ALL TRACKS",
            subtitle: "\(libraryStore.tracks.count) TRACKS",
            target: .all
        ) {
            Image(systemName: "shuffle")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(appTheme.accentColor)
                .frame(width: 40, height: 40)
        }

        let recent = libraryStore.recentAlbums
        sectionHeader("LATEST PLAYS")
        if recent.isEmpty {
            messageText("NO RECENT PLAYS · SEARCH TO FIND MORE")
        } else {
            ForEach(recent) { album in
                albumRow(album: album)
            }
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResults: some View {
        let artists = results.artists
        let albums = results.albums
        let playlists = results.playlists

        if results.isEmpty {
            // Only say NO RESULTS once the current query has actually been searched
            if results.query == cleanQuery {
                messageText("NO RESULTS")
            }
        } else {
            if !artists.isEmpty {
                sectionHeader("ARTISTS (\(artists.count))")
                ForEach(artists) { artist in
                    targetRow(title: artist.name, subtitle: artist.formattedTrackCount.uppercased(), target: .artist(name: artist.name)) {
                        EmptyView()
                    }
                }
            }
            if !albums.isEmpty {
                sectionHeader("ALBUMS (\(albums.count))")
                ForEach(albums) { album in
                    albumRow(album: album)
                }
            }
            if !playlists.isEmpty {
                sectionHeader("PLAYLISTS (\(playlists.count))")
                ForEach(playlists) { playlist in
                    targetRow(title: playlist.name, subtitle: playlist.formattedTrackCount.uppercased(), target: .playlist(id: playlist.id, name: playlist.name)) {
                        AlbumArtworkView(
                            artworkKey: libraryStore.artworkKey(for: playlist),
                            title: playlist.name,
                            subtitle: "Playlist",
                            cornerRadius: 6
                        )
                        .frame(width: 40, height: 40)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func albumRow(album: Album) -> some View {
        targetRow(
            title: album.title,
            subtitle: "\(album.artist) · \(album.formattedTrackCount)".uppercased(),
            target: .album(title: album.title, artist: album.artist)
        ) {
            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 6
            )
            .frame(width: 40, height: 40)
        }
    }

    /// Plain row (like ADD TO PLAYLIST): optional leading artwork, bold title, monospaced subtitle, divider.
    private func targetRow<Leading: View>(
        title: String,
        subtitle: String,
        target: ShuffleTarget,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: {
                selectedTargetForConfirmation = target
                showConfirmationAlert = true
            }) {
                HStack(spacing: 12) {
                    leading()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    private func messageText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 32)
    }

    // MARK: - Confirmation

    private var confirmationTitle: String {
        guard let target = selectedTargetForConfirmation else { return "SET SHUFFLE TARGET?" }
        switch target {
        case .all:
            return "SHUFFLE ALL TRACKS?"
        case .artist(let name):
            return "SHUFFLE \(name.uppercased())?"
        case .album(let title, _):
            return "SHUFFLE \(title.uppercased())?"
        case .playlist(_, let name):
            return "SHUFFLE \(name.uppercased())?"
        }
    }
}
