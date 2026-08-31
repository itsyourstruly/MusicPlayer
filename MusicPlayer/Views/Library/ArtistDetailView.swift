import SwiftUI

/// Detailed discography and track view for a specific artist.
public struct ArtistDetailView: View {
    // Primary artist name
    public let artist: Artist
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil
    @State private var showingFavorites: Bool = false
    @State private var showingOnlineDiscovery: Bool = false

    // Initialize with configured properties
    public init(
        artist: Artist,
        libraryStore: LibraryStore,
        playerService: AudioPlayerService
    ) {
        self.artist = artist
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        let studioAlbumsList = ownStudioAlbums
        let ownSinglesList = ownSingles
        let alternatesList = ownAlternates
        let featuredAlbumsList = featuredAlbums
        let tracksList = displayedArtistTracks

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Header Details
                headerView

                // Action Controls
                HStack(spacing: 12) {
                    Button(action: {
                        if let first = artist.tracks.first {
                            playerService.play(track: first, inQueue: artist.tracks)
                        }
                    }) {
                        Text("PLAY ALL")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))

                    Button(action: {
                        var shuffled = artist.tracks
                        shuffled.shuffle()
                        if let first = shuffled.first {
                            playerService.play(track: first, inQueue: shuffled)
                        }
                    }) {
                        Text("SHUFFLE")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))
                }

                // 1. Studio Albums Section (Lead Artist, Pristine Studio Releases)
                if !studioAlbumsList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "ALBUMS",
                            artistName: artist.name,
                            albums: studioAlbumsList,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("ALBUMS (\(studioAlbumsList.count))")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(studioAlbumsList) { album in
                                    NavigationLink(destination: AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)) {
                                        albumCard(album: album)
                                    }
                                    .buttonStyle(.plain)
                                    .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService)
                                }
                            }
                        }
                    }
                }

                // 2. Singles & EPs Section (Lead Artist, Singles)
                if !ownSinglesList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "SINGLES & EPs",
                            artistName: artist.name,
                            albums: ownSinglesList,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("SINGLES & EPs (\(ownSinglesList.count))")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(ownSinglesList) { single in
                                    NavigationLink(destination: AlbumDetailView(album: single, libraryStore: libraryStore, playerService: playerService)) {
                                        albumCard(album: single)
                                    }
                                    .buttonStyle(.plain)
                                    .albumContextMenu(album: single, libraryStore: libraryStore, playerService: playerService)
                                }
                            }
                        }
                    }
                }

                // 3. Alternates Section (Remixes, Live recordings, Alternate versions, Acoustic cuts)
                if !alternatesList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "ALTERNATES",
                            artistName: artist.name,
                            albums: alternatesList,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("ALTERNATES (\(alternatesList.count))")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(alternatesList) { altAlbum in
                                    NavigationLink(destination: AlbumDetailView(album: altAlbum, libraryStore: libraryStore, playerService: playerService)) {
                                        albumCard(album: altAlbum)
                                    }
                                    .buttonStyle(.plain)
                                    .albumContextMenu(album: altAlbum, libraryStore: libraryStore, playerService: playerService)
                                }
                            }
                        }
                    }
                }

                // 5. Featured On Section (Guest appearances on other artists' albums)
                if !featuredAlbumsList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "FEATURED ON",
                            artistName: artist.name,
                            albums: featuredAlbumsList,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("FEATURED ON (\(featuredAlbumsList.count))")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(featuredAlbumsList) { featAlbum in
                                    NavigationLink(destination: AlbumDetailView(album: featAlbum, libraryStore: libraryStore, playerService: playerService)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            AlbumArtworkView(
                                                artworkKey: featAlbum.artworkKey,
                                                title: featAlbum.title,
                                                subtitle: featAlbum.artist,
                                                cornerRadius: 8
                                            )
                                            .frame(width: 110, height: 110)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(featAlbum.title)
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(Color.primary)
                                                    .lineLimit(1)

                                                Text(featAlbum.artist)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)

                                                Text(featAlbum.formattedYear)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 110, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .albumContextMenu(album: featAlbum, libraryStore: libraryStore, playerService: playerService)
                                }
                            }
                        }
                    }
                }


                // All Artist Tracks / Favorites Section
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(showingFavorites ? "YOUR FAVORITES (\(tracksList.count))" : "ALL TRACKS (\(artist.tracks.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(action: {
                            HapticFeedback.selectionChanged()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                showingFavorites.toggle()
                            }
                        }) {
                            Text(showingFavorites ? "ALL" : "FAVORITES")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.appSecondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    let currentTrackID = playerService.currentTrack?.id
                    let isCurrentPlaying = playerService.playbackStatus.isPlaying
                    let nextTrackID = playerService.nextTrack?.id
                    let playNextSet = Set(playerService.playNextQueue.map { $0.id })
                    let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                    LazyVStack(spacing: 4) {
                        ForEach(0..<tracksList.count, id: \.self) { index in
                            let track = tracksList[index]
                            let count = libraryStore.playCount(for: track.id)
                            let trailingLabel = showingFavorites ? (count == 1 ? "1 PLAY" : "\(count) PLAYS") : nil

                            TrackRowView(
                                track: track,
                                indexNumber: index + 1,
                                isCurrentTrack: track.id == currentTrackID,
                                isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                isNextTrack: track.id == nextTrackID,
                                isInPlayNext: playNextSet.contains(track.id),
                                isTapToPlayNextEnabled: isTapToPlayNext,
                                trailingText: trailingLabel,
                                onPlay: {
                                    playerService.play(track: track, inQueue: tracksList, startIndex: index)
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
                                    selectedTrackForPlaylist = track
                                },
                                onShowInfo: {
                                    selectedTrackForInfo = track
                                },
                                onSelectArtist: { artistName in
                                    if let artistObj = libraryStore.findArtist(name: artistName) {
                                        selectedArtistForNavigation = artistObj
                                    }
                                },
                                onSelectAlbum: {
                                    if let albumObj = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                                        selectedAlbumForNavigation = albumObj
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 64)
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        ForEach(MetadataAPIOption.allCases) { source in
                            Button(action: {
                                HapticFeedback.lightImpact()
                                libraryStore.scanArtistDiscographyMetadata(artistName: artist.name, source: source)
                            }) {
                                Text(source.displayName)
                            }
                        }
                    } label: {
                        Label("FIND METADATA (DISCOGRAPHY)...", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button(action: {
                        HapticFeedback.lightImpact()
                        showingOnlineDiscovery = true
                    }) {
                        Label("FIND ONLINE", systemImage: "network")
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }
            }
        }
        // Modal presentation sheet
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            playlistPickerSheet(for: [track])
        }
        .sheet(isPresented: $showingOnlineDiscovery) {
            NavigationStack {
                GlobalSearchView(
                    libraryStore: libraryStore,
                    playerService: playerService,
                    initialQuery: artist.name,
                    initialOnlineMode: true
                )
            }
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
    }

    // Playlist picker sheet
    private func playlistPickerSheet(for tracks: [Track]) -> some View {
        NavigationStack {
            List {
                if libraryStore.playlists.isEmpty {
                    EmptyStateView(
                        title: "NO PLAYLISTS FOUND",
                        message: "Create a playlist first from the Library tab."
                    )
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(libraryStore.playlists) { playlist in
                        Button(action: {
                            for track in tracks {
                                libraryStore.addTrack(track, toPlaylistID: playlist.id)
                            }
                            selectedTrackForPlaylist = nil
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color.primary)

                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("ADD")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        selectedTrackForPlaylist = nil
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                AlbumArtworkView(
                    artworkKey: artist.mostRecentArtworkKey,
                    title: artist.name,
                    subtitle: artist.discographySummary,
                    cornerRadius: 12
                )
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ARTIST")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(artist.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)

                    Text("\(artist.discographySummary) · \(TimeFormatting.formatSummaryDuration(seconds: artist.totalDuration))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if libraryStore.isBackgroundCheckingMetadata {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(libraryStore.backgroundCheckStatusText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(libraryStore.backgroundCheckProgress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: libraryStore.backgroundCheckProgress)
                        .tint(Color.blue)
                }
                .padding(10)
                .background(libraryStore.settings.appTheme.secondaryBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    // MARK: - Filtered & Sorted Discography Rows

    private var displayedArtistTracks: [Track] {
        if showingFavorites {
            return artist.tracks.sorted { lhs, rhs in
                // P l
                let pL = libraryStore.playCount(for: lhs.id)
                // P r
                let pR = libraryStore.playCount(for: rhs.id)
                if pL != pR {
                    return pL > pR
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } else {
            return artist.tracks
        }
    }

    private var ownStudioAlbums: [Album] {
        let joined = libraryStore.settings.joinedArtists
        let list = artist.albums.filter {
            $0.isLeadOrCollaborativeAlbum(for: artist.name, joinedArtists: joined) && $0.isStudioAlbum
        }
        return list.sorted { lhs, rhs in
            let yL = lhs.resolvedYear ?? 0
            let yR = rhs.resolvedYear ?? 0
            if yL != yR { return yL > yR }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var ownSingles: [Album] {
        let joined = libraryStore.settings.joinedArtists
        let list = artist.albums.filter {
            $0.isLeadOrCollaborativeAlbum(for: artist.name, joinedArtists: joined) && $0.isSingle
        }
        return list.sorted { lhs, rhs in
            let yL = lhs.resolvedYear ?? 0
            let yR = rhs.resolvedYear ?? 0
            if yL != yR { return yL > yR }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var ownAlternates: [Album] {
        let joined = libraryStore.settings.joinedArtists
        let list = artist.albums.filter {
            $0.isLeadOrCollaborativeAlbum(for: artist.name, joinedArtists: joined) && ($0.isRemix || $0.isLive)
        }
        return list.sorted { lhs, rhs in
            let yL = lhs.resolvedYear ?? 0
            let yR = rhs.resolvedYear ?? 0
            if yL != yR { return yL > yR }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var featuredAlbums: [Album] {
        let joined = libraryStore.settings.joinedArtists
        let list = artist.albums.filter {
            $0.isFeaturedAlbum(for: artist.name, joinedArtists: joined)
        }
        return list.sorted { lhs, rhs in
            let yL = lhs.resolvedYear ?? 0
            let yR = rhs.resolvedYear ?? 0
            if yL != yR { return yL > yR }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    // Album card
    private func albumCard(album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 8
            )
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(album.formattedYear)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
        }
    }
}

