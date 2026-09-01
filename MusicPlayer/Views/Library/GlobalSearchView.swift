import SwiftUI

// MARK: - Discography Category

public enum DiscographyCategory: String, Sendable, Equatable {
    case albums = "ALBUMS"
    case singles = "SINGLES"
    case alternates = "ALTERNATES"
    case featuredOn = "FEATURED ON"
}

// MARK: - Filter Enums & Tree Data Structures

public enum SearchCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case artists = "ARTISTS"
    case albums = "ALBUMS"
    case tracks = "TRACKS"

    public var id: String { rawValue }
}

public struct GlobalSearchResults: Sendable, Equatable {
    public var artistTreeNodes: [SearchTreeArtistNode]
    public var playlists: [Playlist]
    public var directMatchedAlbums: [(album: Album, artist: Artist)]
    public var directMatchedTracks: [SearchTreeTrackNode]

    public let totalArtistsCount: Int
    public let totalAlbumsCount: Int
    public let totalTracksCount: Int

    public let matchedArtists: [SearchTreeArtistNode]
    public let matchedAlbums: [(album: Album, artist: Artist)]
    public let matchedTracks: [SearchTreeTrackNode]

    public static let empty = GlobalSearchResults(
        artistTreeNodes: [],
        playlists: [],
        directMatchedAlbums: [],
        directMatchedTracks: []
    )

    public init(
        artistTreeNodes: [SearchTreeArtistNode],
        playlists: [Playlist],
        directMatchedAlbums: [(album: Album, artist: Artist)],
        directMatchedTracks: [SearchTreeTrackNode]
    ) {
        self.artistTreeNodes = artistTreeNodes
        self.playlists = playlists
        self.directMatchedAlbums = directMatchedAlbums
        self.directMatchedTracks = directMatchedTracks

        self.totalArtistsCount = artistTreeNodes.count

        var albumSet = Set<String>()
        for artist in artistTreeNodes {
            for album in artist.albums {
                albumSet.insert(album.album.id)
            }
        }
        for (alb, _) in directMatchedAlbums {
            albumSet.insert(alb.id)
        }
        self.totalAlbumsCount = albumSet.count

        var trackSet = Set<UUID>()
        for artist in artistTreeNodes {
            for album in artist.albums {
                for track in album.tracks {
                    trackSet.insert(track.track.id)
                }
            }
        }
        for track in directMatchedTracks {
            trackSet.insert(track.track.id)
        }
        self.totalTracksCount = trackSet.count

        self.matchedArtists = artistTreeNodes.filter { $0.isDirectlyMatched }
        self.matchedAlbums = directMatchedAlbums
        self.matchedTracks = directMatchedTracks
    }

    public var hasResults: Bool {
        !artistTreeNodes.isEmpty || !playlists.isEmpty || !directMatchedAlbums.isEmpty || !directMatchedTracks.isEmpty
    }

    public static func == (lhs: GlobalSearchResults, rhs: GlobalSearchResults) -> Bool {
        lhs.totalArtistsCount == rhs.totalArtistsCount &&
        lhs.totalAlbumsCount == rhs.totalAlbumsCount &&
        lhs.totalTracksCount == rhs.totalTracksCount &&
        lhs.playlists.count == rhs.playlists.count &&
        lhs.directMatchedAlbums.count == rhs.directMatchedAlbums.count &&
        lhs.directMatchedTracks.count == rhs.directMatchedTracks.count &&
        lhs.artistTreeNodes == rhs.artistTreeNodes &&
        lhs.directMatchedTracks == rhs.directMatchedTracks &&
        lhs.directMatchedAlbums.map { $0.album.id } == rhs.directMatchedAlbums.map { $0.album.id } &&
        lhs.playlists.map { $0.id } == rhs.playlists.map { $0.id }
    }
}

public struct SearchTreeArtistNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let artist: Artist
    public var albums: [SearchTreeAlbumNode]
    public var isDirectlyMatched: Bool
    public var relevanceScore: Int
    public let studioAlbumNodes: [SearchTreeAlbumNode]
    public let singlesNodes: [SearchTreeAlbumNode]
    public let alternatesNodes: [SearchTreeAlbumNode]
    public let featuredAlbumNodes: [SearchTreeAlbumNode]

    public init(
        id: String,
        artist: Artist,
        albums: [SearchTreeAlbumNode],
        isDirectlyMatched: Bool,
        relevanceScore: Int
    ) {
        self.id = id
        self.artist = artist
        self.albums = albums
        self.isDirectlyMatched = isDirectlyMatched
        self.relevanceScore = relevanceScore
        self.studioAlbumNodes = albums.filter { $0.category == .albums }
        self.singlesNodes = albums.filter { $0.category == .singles }
        self.alternatesNodes = albums.filter { $0.category == .alternates }
        self.featuredAlbumNodes = albums.filter { $0.category == .featuredOn }
    }

    public static func == (lhs: SearchTreeArtistNode, rhs: SearchTreeArtistNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.artist.id == rhs.artist.id &&
        lhs.albums.count == rhs.albums.count &&
        lhs.isDirectlyMatched == rhs.isDirectlyMatched &&
        lhs.relevanceScore == rhs.relevanceScore
    }
}

public struct SearchTreeAlbumNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let album: Album
    public var tracks: [SearchTreeTrackNode]
    public var isDirectlyMatched: Bool
    public var relevanceScore: Int
    public var category: DiscographyCategory

    public static func == (lhs: SearchTreeAlbumNode, rhs: SearchTreeAlbumNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.album.id == rhs.album.id &&
        lhs.tracks.count == rhs.tracks.count &&
        lhs.isDirectlyMatched == rhs.isDirectlyMatched &&
        lhs.relevanceScore == rhs.relevanceScore &&
        lhs.category == rhs.category
    }
}

public struct SearchTreeTrackNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let track: Track
    public var isDirectlyMatched: Bool
    public var relevanceScore: Int

    public static func == (lhs: SearchTreeTrackNode, rhs: SearchTreeTrackNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.track.id == rhs.track.id &&
        lhs.isDirectlyMatched == rhs.isDirectlyMatched &&
        lhs.relevanceScore == rhs.relevanceScore
    }
}

// MARK: - Main Global Search View

public struct GlobalSearchView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var searchQuery: String = ""
    @State private var results: GlobalSearchResults = .empty
    @State private var isSearching: Bool = false
    @State private var activeCategoryFilter: SearchCategoryFilter? = nil
    @FocusState private var isSearchFocused: Bool

    // Expansion sets for artists and independent multiple albums
    @State private var expandedArtistIDs: Set<String> = []
    @State private var expandedAlbumIDs: Set<String> = []
    @State private var collapseTrigger: Int = 0
    @State private var isPlaylistsCollapsed: Bool = false

    // Selection states for navigation & sheets
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil

    // Debounced async search task
    @State private var searchTask: Task<Void, Never>? = nil

    // Online Search Mode State
    @State private var isOnlineMode: Bool = false
    @State private var onlineResults: OnlineSearchResults = OnlineSearchResults()
    @State private var isOnlineSearching: Bool = false
    @State private var previewManager = OnlineAudioPreviewManager.shared

    private let onlineColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        initialQuery: String = "",
        initialOnlineMode: Bool = false
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self._searchQuery = State(initialValue: initialQuery)
        self._isOnlineMode = State(initialValue: initialOnlineMode)
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            libraryStore.settings.appTheme.backgroundColor
                .ignoresSafeArea()

            if isOnlineMode {
                onlineContentView
            } else {
                libraryContentView
            }
        }
        .navigationTitle(isOnlineMode ? "SEARCH ONLINE" : "SEARCH LIBRARY")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(isOnlineMode ? "SEARCH ONLINE CATALOG..." : "SEARCH TRACKS, ARTISTS, ALBUMS...")
        )
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    isOnlineMode.toggle()
                }) {
                    Image(systemName: "globe")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isOnlineMode ? Color.blue : Color.primary)
                }
            }
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            playlistPickerSheet(for: track)
        }
        .onAppear {
            let t = libraryStore.tracks
            let a = libraryStore.albums
            let ar = libraryStore.artists
            let p = libraryStore.playlists
            let j = libraryStore.settings.joinedArtists
            Task.detached(priority: .utility) {
                await SearchEngine.shared.updateIndex(
                    tracks: t,
                    albums: a,
                    artists: ar,
                    playlists: p,
                    joinedArtists: j
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
        .onDisappear {
            previewManager.stop()
        }
        .task(id: "\(searchQuery)_\(isOnlineMode)") {
            let clean = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2 else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.results = .empty
                    self.expandedArtistIDs = []
                    self.expandedAlbumIDs = []
                    self.isSearching = false
                }
                return
            }

            if isOnlineMode {
                triggerOnlineSearch(query: searchQuery, immediate: false)
                return
            }

            // Immediately reset active expansion so new incoming results render collapsed first
            self.expandedArtistIDs = []
            self.expandedAlbumIDs = []
            self.isSearching = true

            do {
                // 100ms debounce: quick 100ms delay after typing stops before searching
                try await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }

                // Progressively stream results (topmost relevant direct matches first, then complete tree)
                for await progressiveResults in await SearchEngine.shared.searchStream(
                    query: clean,
                    tracksFallback: libraryStore.tracks,
                    albumsFallback: libraryStore.albums,
                    artistsFallback: libraryStore.artists,
                    playlistsFallback: libraryStore.playlists,
                    joinedArtistsFallback: libraryStore.settings.joinedArtists
                ) {
                    guard !Task.isCancelled, self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == clean else { return }

                    withAnimation(.easeInOut(duration: 0.20)) {
                        self.results = progressiveResults
                        self.isSearching = false
                    }
                }

                guard !Task.isCancelled, self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == clean else { return }

                // Wait shortly after artists are all rendered in smoothly first before expanding
                try await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == clean else { return }

                let topArtistID = self.results.artistTreeNodes.first?.id
                let topAlbumID = self.results.artistTreeNodes.first?.albums.first?.id ?? self.results.directMatchedAlbums.first?.album.id
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    if let topArtistID {
                        self.expandedArtistIDs = [topArtistID]
                    }
                    if let topAlbumID {
                        self.expandedAlbumIDs = [topAlbumID]
                    }
                }
            } catch {
                // Preempted by next keystroke: cancelled cleanly with 0 CPU overhead
            }
        }
    }

    // MARK: - Library Tree Content View

    @ViewBuilder
    private var libraryContentView: some View {
        if trimmedQuery.count < 2 {
            initialStateView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        } else if isSearching && results.artistTreeNodes.isEmpty && results.playlists.isEmpty {
            searchingIndicatorView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        } else if results.hasResults {
            LibrarySearchResultsContainer(
                results: results,
                activeCategoryFilter: activeCategoryFilter,
                expandedArtistIDs: expandedArtistIDs,
                expandedAlbumIDs: expandedAlbumIDs,
                collapseTrigger: collapseTrigger,
                isPlaylistsCollapsed: isPlaylistsCollapsed,
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectArtist: { selectedArtistForNavigation = $0 },
                onSelectAlbum: { selectedAlbumForNavigation = $0 },
                onSelectTrackForInfo: { selectedTrackForInfo = $0 },
                onSelectTrackForPlaylist: { selectedTrackForPlaylist = $0 },
                onToggleArtistExpansion: { artistID in
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        if expandedArtistIDs.contains(artistID) {
                            expandedArtistIDs.remove(artistID)
                        } else {
                            expandedArtistIDs.insert(artistID)
                        }
                    }
                },
                onToggleAlbumExpansion: { albumID, artistID in
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        expandedArtistIDs.insert(artistID)
                        if expandedAlbumIDs.contains(albumID) {
                            expandedAlbumIDs.remove(albumID)
                        } else {
                            expandedAlbumIDs.insert(albumID)
                        }
                    }
                },
                onCollapseAll: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        expandedArtistIDs.removeAll()
                        expandedAlbumIDs.removeAll()
                        collapseTrigger += 1
                    }
                },
                onToggleCategoryFilter: { category in
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        activeCategoryFilter = (activeCategoryFilter == category) ? nil : category
                    }
                },
                onTogglePlaylistsCollapse: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        isPlaylistsCollapsed.toggle()
                    }
                }
            )
            .equatable()
            .transition(.opacity)
        } else {
            emptyResultsView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Online Mode View

    private var onlineContentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                onlineSearchBarIndicator

                if isOnlineSearching && onlineResults.isEmpty {
                    searchingIndicatorView
                        .padding(.top, 24)
                } else if !onlineResults.isEmpty {
                    if !onlineResults.tracks.isEmpty {
                        onlineTracksSection
                    }
                    if !onlineResults.albums.isEmpty {
                        onlineAlbumsSection
                    }
                    if !onlineResults.artists.isEmpty {
                        onlineArtistsSection
                    }
                } else if trimmedQuery.count >= 2 && !isOnlineSearching {
                    emptyOnlineResultsView
                        .padding(.top, 40)
                } else {
                    initialOnlineStateView
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 140)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var onlineSearchBarIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.blue)

            Text("ONLINE CATALOG DISCOVERY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.blue)

            Spacer()

            if isOnlineSearching {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var onlineTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRACKS (\(onlineResults.tracks.count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(onlineResults.tracks) { item in
                    NavigationLink(destination: OnlineTrackDetailView(track: item)) {
                        HStack(spacing: 12) {
                            ZStack(alignment: .center) {
                                AsyncImage(url: item.artworkURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                                    }
                                }
                                .frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                if item.previewURL != nil {
                                    Button(action: {
                                        previewManager.togglePreview(track: item)
                                    }) {
                                        Image(systemName: previewManager.currentTrackID == item.id && previewManager.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Color.white)
                                            .frame(width: 26, height: 26)
                                            .background(Color.black.opacity(0.7))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(previewManager.currentTrackID == item.id && previewManager.isPlaying ? appTheme.accentColor : Color.primary)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(item.artistName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if !item.albumTitle.isEmpty {
                                        Text("·")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)

                                        Text(item.albumTitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }

                            Spacer()

                            if item.previewURL != nil {
                                Button(action: {
                                    previewManager.togglePreview(track: item)
                                }) {
                                    Text(previewManager.currentTrackID == item.id && previewManager.isPlaying ? "PAUSE" : "PREVIEW")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3.5)
                                        .background(previewManager.currentTrackID == item.id && previewManager.isPlaying ? appTheme.accentColor : appTheme.accentColor.opacity(0.18))
                                        .foregroundStyle(previewManager.currentTrackID == item.id && previewManager.isPlaying ? Color.appInvertedBackground : appTheme.accentColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            Text(TimeFormatting.format(seconds: item.duration))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var onlineAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALBUMS (\(onlineResults.albums.count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: onlineColumns, spacing: 14) {
                ForEach(onlineResults.albums) { item in
                    NavigationLink(destination: OnlineAlbumDetailView(album: item)) {
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: item.artworkURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                                }
                            }
                            .aspectRatio(1.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)

                                Text(item.artistName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if let count = item.trackCount, count > 0 {
                                    Text("\(count) TRACKS")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var onlineArtistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ARTISTS (\(onlineResults.artists.count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(onlineResults.artists) { item in
                    NavigationLink(destination: OnlineArtistDetailView(artist: item)) {
                        HStack(spacing: 12) {
                            AsyncImage(url: item.imageURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Circle().fill(Color.primary.opacity(0.08))
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)

                                if let genre = item.genre, !genre.isEmpty {
                                    Text(genre)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - State Views

    private var initialStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .padding(.top, 40)

            Text("Search by tracks, artists, or albums to view results in a clean, minimal tree.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
    }

    private var initialOnlineStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 32))
                .foregroundStyle(.blue.opacity(0.8))

            Text("Search online music catalogues for tracks, albums, and artists.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
    }

    private var searchingIndicatorView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .padding(.top, 40)

            Text("Searching...")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "slash.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .padding(.top, 40)

            Text("No results for \"\(trimmedQuery)\"")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)

            Text("Try searching for alternative spellings or part of a name.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
    }

    private var emptyOnlineResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No online results found for \"\(trimmedQuery)\"")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
        }
    }

    // MARK: - Playlist Picker Sheet

    private func playlistPickerSheet(for track: Track) -> some View {
        NavigationStack {
            List {
                ForEach(libraryStore.playlists) { playlist in
                    Button(action: {
                        libraryStore.addTrack(track, toPlaylistID: playlist.id)
                        HapticFeedback.notificationSuccess()
                        selectedTrackForPlaylist = nil
                    }) {
                        HStack(spacing: 12) {
                            AlbumArtworkView(
                                artworkKey: libraryStore.artworkKey(for: playlist),
                                title: playlist.name,
                                subtitle: "Playlist",
                                cornerRadius: 6
                            )
                            .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.primary)

                                Text("\(playlist.trackIDs.count) tracks")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        selectedTrackForPlaylist = nil
                    }
                }
            }
        }
    }

    // MARK: - Online Search Execution

    private func triggerOnlineSearch(query: String, immediate: Bool) {
        searchTask?.cancel()
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else {
            withAnimation(.easeInOut(duration: 0.18)) {
                self.onlineResults = OnlineSearchResults()
                self.isOnlineSearching = false
            }
            return
        }

        self.isOnlineSearching = true
        searchTask = Task.detached(priority: .userInitiated) {
            if !immediate {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }

            let results = await OnlineDiscoveryService.shared.search(query: clean)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == clean else { return }
                withAnimation(.easeInOut(duration: 0.20)) {
                    self.onlineResults = results
                    self.isOnlineSearching = false
                }
            }
        }
    }
}

// MARK: - Search Tree Track Row Component

/// Tree track row with connector, playback indicator, and animated side swipe on context menu actions
public struct SearchTreeTrackRowView: View {
    public let trackNode: SearchTreeTrackNode
    public let allAlbumTracks: [Track]
    public let trackIndex: Int
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onAddToPlaylist: (Track) -> Void
    public let onShowInfo: (Track) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var showPlayNextSuccess: Bool = false
    @State private var showQueueNextSuccess: Bool = false

    private var track: Track { trackNode.track }
    private var isCurrent: Bool { playerService.currentTrack?.id == track.id }
    private var isPlaying: Bool { isCurrent && playerService.playbackStatus.isPlaying }

    public var body: some View {
        ZStack {
            // Leading "PLAY NEXT" reveal surface
            if dragOffset > 0 || showPlayNextSuccess {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 10, weight: .bold))
                        Text(showPlayNextSuccess ? "QUEUED" : "PLAY NEXT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Spacer()
                }
            }

            // Trailing "QUEUE NEXT" reveal surface
            if dragOffset < 0 || showQueueNextSuccess {
                HStack {
                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                            .font(.system(size: 10, weight: .bold))
                        Text(showQueueNextSuccess ? "QUEUED" : "QUEUE NEXT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Foreground Track Content
            Button(action: {
                playerService.play(
                    track: track,
                    inQueue: allAlbumTracks,
                    startIndex: allAlbumTracks.firstIndex(where: { $0.id == track.id }) ?? trackIndex
                )
            }) {
                HStack(spacing: 8) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 22, alignment: .leading)
                    } else if isCurrent {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 22, alignment: .leading)
                    } else if let trackNum = track.trackNumber, trackNum > 0 {
                        Text(String(format: "%02d", trackNum))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .leading)
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 10, height: 1.5)
                            .frame(width: 22, alignment: .leading)
                    }

                    Text(track.title)
                        .font(.system(size: 13, weight: (isCurrent || trackNode.isDirectlyMatched) ? .bold : .medium))
                        .foregroundStyle(trackNode.isDirectlyMatched ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(TimeFormatting.format(seconds: track.duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
            )
            .offset(x: dragOffset)
        }
        .contextMenu {
            Button(action: {
                playerService.play(
                    track: track,
                    inQueue: allAlbumTracks,
                    startIndex: allAlbumTracks.firstIndex(where: { $0.id == track.id }) ?? trackIndex
                )
            }) {
                Text("PLAY")
            }

            Button(action: triggerPlayNext) {
                Text("PLAY NEXT")
            }

            Button(action: triggerQueueNext) {
                Text("QUEUE NEXT")
            }

            Button(action: {
                onAddToPlaylist(track)
            }) {
                Text("ADD TO PLAYLIST")
            }

            Button(action: {
                onShowInfo(track)
            }) {
                Text("GET INFO")
            }

            Button(action: {
                if let artistObj = libraryStore.findArtist(name: track.artist) {
                    onSelectArtist(artistObj)
                }
            }) {
                Text("GO TO ARTIST")
            }

            Button(action: {
                if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                    onSelectAlbum(albumObj)
                }
            }) {
                Text("GO TO ALBUM")
            }
        }
    }

    private func triggerPlayNext() {
        HapticFeedback.notificationSuccess()
        playerService.insertPlayNextFront(track: track)
        showPlayNextSuccess = true

        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            dragOffset = 65
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                dragOffset = 0
                showPlayNextSuccess = false
            }
        }
    }

    private func triggerQueueNext() {
        HapticFeedback.notificationSuccess()
        playerService.playNext(track: track)
        showQueueNextSuccess = true

        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            dragOffset = -65
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                dragOffset = 0
                showQueueNextSuccess = false
            }
        }
    }
}

// MARK: - Search Album Tree Node Row

public struct SearchAlbumTreeNodeRow: View {
    public let albumNode: SearchTreeAlbumNode
    public let artistNode: SearchTreeArtistNode
    public let isExpanded: Bool
    public let onToggleExpand: () -> Void
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onSelectTrackForPlaylist: (Track) -> Void
    public let onSelectTrackForInfo: (Track) -> Void

    public var body: some View {
        let resolvedAlbumArt = albumNode.album.artworkKey ?? albumNode.album.tracks.first(where: { $0.artworkKey != nil })?.artworkKey

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 10, height: 1.5)

                AlbumArtworkView(
                    artworkKey: resolvedAlbumArt,
                    title: albumNode.album.title,
                    subtitle: albumNode.album.artist,
                    cornerRadius: 6
                )
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(albumNode.album.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(albumNode.album.formattedYear)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Text("\(albumNode.tracks.count) \(albumNode.tracks.count == 1 ? "TRACK" : "TRACKS")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button(action: {
                    onSelectAlbum(albumNode.album)
                }) {
                    Text("OPEN")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }
            .albumContextMenu(album: albumNode.album, libraryStore: libraryStore, playerService: playerService)

            if isExpanded && !albumNode.tracks.isEmpty {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(albumNode.tracks.enumerated()), id: \.element.id) { index, trackNode in
                        SearchTreeTrackRowView(
                            trackNode: trackNode,
                            allAlbumTracks: albumNode.album.tracks,
                            trackIndex: index,
                            libraryStore: libraryStore,
                            playerService: playerService,
                            onSelectArtist: onSelectArtist,
                            onSelectAlbum: onSelectAlbum,
                            onAddToPlaylist: onSelectTrackForPlaylist,
                            onShowInfo: onSelectTrackForInfo
                        )
                    }
                }
                .padding(.leading, 26)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1.5)
                        .padding(.leading, 15)
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Search Artist Tree Node Row

public struct SearchArtistTreeNodeRow: View {
    public let artistNode: SearchTreeArtistNode
    public let isExpanded: Bool
    public let expandedAlbumIDs: Set<String>
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onSelectTrackForPlaylist: (Track) -> Void
    public let onSelectTrackForInfo: (Track) -> Void
    public let onToggleArtistExpansion: (String) -> Void
    public let onToggleAlbumExpansion: (String, String) -> Void

    public var body: some View {
        let totalTracks = artistNode.albums.reduce(0) { $0 + $1.tracks.count }
        let summary = "\(artistNode.albums.count) \(artistNode.albums.count == 1 ? "ALBUM" : "ALBUMS") · \(totalTracks) \(totalTracks == 1 ? "TRACK" : "TRACKS")"

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: artistNode.artist.mostRecentArtworkKey ?? artistNode.albums.first?.album.artworkKey,
                    title: artistNode.artist.name,
                    subtitle: summary,
                    cornerRadius: 8
                )
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(artistNode.artist.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: {
                    onSelectArtist(artistNode.artist)
                }) {
                    Text("OPEN")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleArtistExpansion(artistNode.id)
            }
            .contextMenu {
                Button(action: {
                    onSelectArtist(artistNode.artist)
                }) {
                    Text("VIEW ARTIST")
                }

                Button(action: {
                    if let first = artistNode.artist.tracks.first {
                        playerService.play(track: first, inQueue: artistNode.artist.tracks)
                    }
                }) {
                    Text("PLAY ARTIST")
                }

                Button(action: {
                    var shuffled = artistNode.artist.tracks
                    shuffled.shuffle()
                    if let first = shuffled.first {
                        playerService.play(track: first, inQueue: shuffled)
                    }
                }) {
                    Text("SHUFFLE ARTIST")
                }
            }

            if isExpanded && !artistNode.albums.isEmpty {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let studioAlbums = artistNode.studioAlbumNodes
                    let singles = artistNode.singlesNodes
                    let alternates = artistNode.alternatesNodes
                    let featured = artistNode.featuredAlbumNodes

                    if !studioAlbums.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Text("ALBUMS (\(studioAlbums.count))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.65))
                                .padding(.leading, 10)

                            ForEach(studioAlbums) { albumNode in
                                SearchAlbumTreeNodeRow(
                                    albumNode: albumNode,
                                    artistNode: artistNode,
                                    isExpanded: expandedAlbumIDs.contains(albumNode.id),
                                    onToggleExpand: {
                                        onToggleAlbumExpansion(albumNode.id, artistNode.id)
                                    },
                                    libraryStore: libraryStore,
                                    playerService: playerService,
                                    onSelectArtist: onSelectArtist,
                                    onSelectAlbum: onSelectAlbum,
                                    onSelectTrackForPlaylist: onSelectTrackForPlaylist,
                                    onSelectTrackForInfo: onSelectTrackForInfo
                                )
                            }
                        }
                    }

                    if !singles.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Text("SINGLES (\(singles.count))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.65))
                                .padding(.leading, 10)

                            ForEach(singles) { albumNode in
                                SearchAlbumTreeNodeRow(
                                    albumNode: albumNode,
                                    artistNode: artistNode,
                                    isExpanded: expandedAlbumIDs.contains(albumNode.id),
                                    onToggleExpand: {
                                        onToggleAlbumExpansion(albumNode.id, artistNode.id)
                                    },
                                    libraryStore: libraryStore,
                                    playerService: playerService,
                                    onSelectArtist: onSelectArtist,
                                    onSelectAlbum: onSelectAlbum,
                                    onSelectTrackForPlaylist: onSelectTrackForPlaylist,
                                    onSelectTrackForInfo: onSelectTrackForInfo
                                )
                            }
                        }
                    }

                    if !alternates.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Text("ALTERNATES (\(alternates.count))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.65))
                                .padding(.leading, 10)

                            ForEach(alternates) { albumNode in
                                SearchAlbumTreeNodeRow(
                                    albumNode: albumNode,
                                    artistNode: artistNode,
                                    isExpanded: expandedAlbumIDs.contains(albumNode.id),
                                    onToggleExpand: {
                                        onToggleAlbumExpansion(albumNode.id, artistNode.id)
                                    },
                                    libraryStore: libraryStore,
                                    playerService: playerService,
                                    onSelectArtist: onSelectArtist,
                                    onSelectAlbum: onSelectAlbum,
                                    onSelectTrackForPlaylist: onSelectTrackForPlaylist,
                                    onSelectTrackForInfo: onSelectTrackForInfo
                                )
                            }
                        }
                    }

                    if !featured.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Text("FEATURED ON (\(featured.count))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.65))
                                .padding(.leading, 10)

                            ForEach(featured) { albumNode in
                                SearchAlbumTreeNodeRow(
                                    albumNode: albumNode,
                                    artistNode: artistNode,
                                    isExpanded: expandedAlbumIDs.contains(albumNode.id),
                                    onToggleExpand: {
                                        onToggleAlbumExpansion(albumNode.id, artistNode.id)
                                    },
                                    libraryStore: libraryStore,
                                    playerService: playerService,
                                    onSelectArtist: onSelectArtist,
                                    onSelectAlbum: onSelectAlbum,
                                    onSelectTrackForPlaylist: onSelectTrackForPlaylist,
                                    onSelectTrackForInfo: onSelectTrackForInfo
                                )
                            }
                        }
                    }
                }
                .padding(.leading, 24)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1.5)
                        .padding(.leading, 12)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Equatable Library Search Results Container

public struct LibrarySearchResultsContainer: View, Equatable {
    public let results: GlobalSearchResults
    public let activeCategoryFilter: SearchCategoryFilter?
    public let expandedArtistIDs: Set<String>
    public let expandedAlbumIDs: Set<String>
    public let collapseTrigger: Int
    public let isPlaylistsCollapsed: Bool

    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onSelectTrackForInfo: (Track) -> Void
    public let onSelectTrackForPlaylist: (Track) -> Void
    public let onToggleArtistExpansion: (String) -> Void
    public let onToggleAlbumExpansion: (String, String) -> Void
    public let onCollapseAll: () -> Void
    public let onToggleCategoryFilter: (SearchCategoryFilter) -> Void
    public let onTogglePlaylistsCollapse: () -> Void

    public static func == (lhs: LibrarySearchResultsContainer, rhs: LibrarySearchResultsContainer) -> Bool {
        lhs.results == rhs.results &&
        lhs.activeCategoryFilter == rhs.activeCategoryFilter &&
        lhs.expandedArtistIDs == rhs.expandedArtistIDs &&
        lhs.expandedAlbumIDs == rhs.expandedAlbumIDs &&
        lhs.collapseTrigger == rhs.collapseTrigger &&
        lhs.isPlaylistsCollapsed == rhs.isPlaylistsCollapsed
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Tree Header Controls with interactive filter text
                treeControlsBar

                switch activeCategoryFilter {
                case .artists:
                    filteredArtistsList
                case .albums:
                    filteredAlbumsList
                case .tracks:
                    filteredTracksList
                case nil:
                    if !results.artistTreeNodes.isEmpty {
                        // Tree Nodes (Artist -> Album -> Track)
                        ForEach(Array(results.artistTreeNodes.enumerated()), id: \.element.id) { index, artistNode in
                            SearchArtistTreeNodeRow(
                                artistNode: artistNode,
                                isExpanded: expandedArtistIDs.contains(artistNode.id),
                                expandedAlbumIDs: expandedAlbumIDs,
                                libraryStore: libraryStore,
                                playerService: playerService,
                                onSelectArtist: onSelectArtist,
                                onSelectAlbum: onSelectAlbum,
                                onSelectTrackForPlaylist: onSelectTrackForPlaylist,
                                onSelectTrackForInfo: onSelectTrackForInfo,
                                onToggleArtistExpansion: onToggleArtistExpansion,
                                onToggleAlbumExpansion: onToggleAlbumExpansion
                            )
                        }
                    } else if !results.directMatchedAlbums.isEmpty {
                        filteredAlbumsList
                    } else if !results.directMatchedTracks.isEmpty {
                        filteredTracksList
                    }

                    // Playlists Section (if matched)
                    if !results.playlists.isEmpty {
                        playlistsSection
                            .padding(.top, 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 140)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Tree Controls Bar
    private var treeControlsBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    onToggleCategoryFilter(.artists)
                }) {
                    Text("\(results.totalArtistsCount) ARTISTS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCategoryFilter == .artists ? Color.white : Color.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("·")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    onToggleCategoryFilter(.albums)
                }) {
                    Text("\(results.totalAlbumsCount) ALBUMS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCategoryFilter == .albums ? Color.white : Color.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("·")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    onToggleCategoryFilter(.tracks)
                }) {
                    Text("\(results.totalTracksCount) TRACKS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCategoryFilter == .tracks ? Color.white : Color.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if activeCategoryFilter == nil {
                Button(action: onCollapseAll) {
                    Text("COLLAPSE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    if let cur = activeCategoryFilter {
                        onToggleCategoryFilter(cur)
                    }
                }) {
                    Text("SHOW ALL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Filtered Views
    private var filteredArtistsList: some View {
        let list = results.matchedArtists.isEmpty ? results.artistTreeNodes : results.matchedArtists
        return LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(list) { artistNode in
                let totalTracks = artistNode.albums.reduce(0) { $0 + $1.tracks.count }
                let summary = "\(artistNode.albums.count) \(artistNode.albums.count == 1 ? "ALBUM" : "ALBUMS") · \(totalTracks) \(totalTracks == 1 ? "TRACK" : "TRACKS")"

                Button(action: {
                    onSelectArtist(artistNode.artist)
                }) {
                    HStack(spacing: 12) {
                        AlbumArtworkView(
                            artworkKey: artistNode.artist.mostRecentArtworkKey ?? artistNode.albums.first?.album.artworkKey,
                            title: artistNode.artist.name,
                            subtitle: summary,
                            cornerRadius: 8
                        )
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(artistNode.artist.name)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            Text(summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("OPEN")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(action: {
                        onSelectArtist(artistNode.artist)
                    }) {
                        Text("VIEW ARTIST")
                    }
                }
            }
        }
    }

    private var filteredAlbumsList: some View {
        let list = results.matchedAlbums

        return LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(list, id: \.album.id) { pair in
                let (album, artist) = pair
                let resolvedAlbumArt = album.artworkKey ?? album.tracks.compactMap { $0.artworkKey }.first ?? libraryStore.findAlbum(title: album.title, artist: album.artist)?.artworkKey

                Button(action: {
                    onSelectAlbum(album)
                }) {
                    HStack(spacing: 12) {
                        AlbumArtworkView(
                            artworkKey: resolvedAlbumArt,
                            title: album.title,
                            subtitle: album.artist,
                            cornerRadius: 6
                        )
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(album.artist.isEmpty ? artist.name : album.artist)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)

                                Text(album.formattedYear)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        Text("OPEN")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService)
            }
        }
    }

    private var filteredTracksList: some View {
        let list = results.matchedTracks
        let allTracks = list.map { $0.track }
        let currentTrackID = playerService.currentTrack?.id
        let isCurrentPlaying = playerService.playbackStatus.isPlaying
        let nextTrackID = playerService.nextTrack?.id
        let playNextSet = Set(playerService.playNextQueue.map { $0.id })
        let isTapToPlayNext = libraryStore.settings.tapToPlayNext

        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, trackNode in
                let track = trackNode.track
                TrackRowView(
                    track: track,
                    isCurrentTrack: track.id == currentTrackID,
                    isPlaying: isCurrentPlaying && track.id == currentTrackID,
                    isNextTrack: track.id == nextTrackID,
                    isInPlayNext: playNextSet.contains(track.id),
                    isTapToPlayNextEnabled: isTapToPlayNext,
                    onPlay: {
                        playerService.play(track: track, inQueue: allTracks, startIndex: index)
                    },
                    onPlayNext: {
                        playerService.insertPlayNextFront(track: track)
                    },
                    onQueueNext: {
                        playerService.playNext(track: track)
                    },
                    onAddToQueue: {
                        playerService.appendToQueue(track: track)
                    },
                    onAddToPlaylist: {
                        onSelectTrackForPlaylist(track)
                    },
                    onShowInfo: {
                        onSelectTrackForInfo(track)
                    },
                    onSelectArtist: { artistName in
                        if let artistObj = libraryStore.findArtist(name: artistName) {
                            onSelectArtist(artistObj)
                        }
                    },
                    onSelectAlbum: {
                        if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                            onSelectAlbum(albumObj)
                        }
                    }
                )
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTogglePlaylistsCollapse) {
                HStack {
                    Text("PLAYLISTS (\(results.playlists.count))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isPlaylistsCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isPlaylistsCollapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 14) {
                    ForEach(results.playlists) { playlist in
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
                                            .foregroundStyle(Color.white)
                                            .padding(5)
                                            .background(Color.black.opacity(0.65))
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
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
