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
    @State private var showingDiscographyReviewSheet: Bool = false
    @State private var selectedSectionDestination: ArtistSectionDestination? = nil
    @Environment(\.appTheme) private var appTheme

    private struct ArtistSectionDestination: Identifiable, Hashable {
        var id: String { title }
        let title: String
        let albums: [Album]
    }

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

    /// Dynamically resolves the latest artist state from the library store with O(1) indexed lookup.
    private var currentArtist: Artist {
        if let direct = libraryStore.artistLookupIndex[artist.id] {
            return direct
        }
        let rawKey = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let directByName = libraryStore.artistLookupIndex[rawKey] {
            return directByName
        }
        if let canon = libraryStore.artistLookupIndex[ArtistParser.canonicalArtistKey(artist.name)] {
            return canon
        }
        if let found = libraryStore.findArtist(name: artist.name) {
            return found
        }
        return artist
    }

    // Main view layout structure
    public var body: some View {
        let activeArtist = currentArtist
        let discography = categorizeDiscography(for: activeArtist)
        let studioAlbumsList = discography.studioAlbums
        let ownSinglesList = discography.singles
        let alternatesList = discography.alternates
        let featuredAlbumsList = discography.featuredAlbums
        let tracksList = displayedArtistTracks

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Header Details
                headerView

                // Action Controls
                HStack(spacing: 12) {
                    Button(action: {
                        if let first = activeArtist.tracks.first {
                            playerService.play(track: first, inQueue: activeArtist.tracks)
                        }
                    }) {
                        Text("PLAY ALL")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))

                    Button(action: {
                        var shuffled = activeArtist.tracks
                        shuffled.shuffle()
                        if let first = shuffled.first {
                            playerService.play(track: first, inQueue: shuffled)
                        }
                    }) {
                        Text("SHUFFLE")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))

                    Spacer()
                }

                // 1. Studio Albums Section (Lead Artist, Pristine Studio Releases)
                if !studioAlbumsList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: {
                            selectedSectionDestination = ArtistSectionDestination(title: "ALBUMS", albums: studioAlbumsList)
                        }) {
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
                                    Button(action: {
                                        selectedAlbumForNavigation = album
                                    }) {
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
                        Button(action: {
                            selectedSectionDestination = ArtistSectionDestination(title: "SINGLES & EPs", albums: ownSinglesList)
                        }) {
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
                                    Button(action: {
                                        selectedAlbumForNavigation = single
                                    }) {
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
                        Button(action: {
                            selectedSectionDestination = ArtistSectionDestination(title: "ALTERNATES", albums: alternatesList)
                        }) {
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
                                    Button(action: {
                                        selectedAlbumForNavigation = altAlbum
                                    }) {
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
                        Button(action: {
                            selectedSectionDestination = ArtistSectionDestination(title: "FEATURED ON", albums: featuredAlbumsList)
                        }) {
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
                                    Button(action: {
                                        selectedAlbumForNavigation = featAlbum
                                    }) {
                                        featuredAlbumCard(album: featAlbum)
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
                    let nextTrackID = playerService.queueBadges.nextTrackID
                    let playNextSet = playerService.queueBadges.playNextTrackIDs
                    let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                    LazyVStack(spacing: 4) {
                        ForEach(Array(tracksList.enumerated()), id: \.element.id) { index, track in
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
        .navigationTitle(currentArtist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ArtistDetailToolbarMenuView(
                    currentArtist: currentArtist,
                    libraryStore: libraryStore,
                    showingOnlineDiscovery: $showingOnlineDiscovery
                )
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
                    initialQuery: currentArtist.name,
                    initialOnlineMode: true
                )
            }
        }
        .sheet(isPresented: $showingDiscographyReviewSheet) {
            if let result = libraryStore.discographyScanResult {
                DiscographyReviewSheet(scanResult: result, libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedSectionDestination) { dest in
            ArtistSectionFullListView(
                title: dest.title,
                artistName: currentArtist.name,
                albums: dest.albums,
                libraryStore: libraryStore,
                playerService: playerService
            )
        }
        .enableInteractivePopGesture()
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
        }
        .presentationDetents([.medium])
    }

    private var headerView: some View {
        let activeArtist = currentArtist
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                AlbumArtworkView(
                    artworkKey: activeArtist.mostRecentArtworkKey,
                    title: activeArtist.name,
                    subtitle: activeArtist.discographySummary,
                    cornerRadius: 12,
                    targetDimension: 300
                )
                .frame(width: 88, height: 88)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ARTIST")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(activeArtist.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)

                    Text(activeArtist.ownTotalDuration > 0
                        ? "\(activeArtist.discographySummary) · \(TimeFormatting.formatSummaryDuration(seconds: activeArtist.ownTotalDuration))"
                        : activeArtist.discographySummary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // Multi-Source Discography Scanning Banner & Review Button
            if libraryStore.activeDiscographyScanArtistName == activeArtist.name {
                if libraryStore.isScanningArtistDiscography {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(libraryStore.discographyScanStatusText)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(libraryStore.discographyScanProgress * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: libraryStore.discographyScanProgress)
                            .tint(libraryStore.settings.appTheme.accentColor)
                    }
                    .padding(10)
                    .background(libraryStore.settings.appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity)
                } else if libraryStore.isDiscographyScanComplete, libraryStore.discographyScanResult != nil {
                    Button(action: {
                        HapticFeedback.lightImpact()
                        showingDiscographyReviewSheet = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(libraryStore.settings.appTheme.accentColor)

                            Text("Scan Complete • Tap to Review")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.primary)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(libraryStore.settings.appTheme.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(libraryStore.settings.appTheme.accentColor.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
                }
            } else if libraryStore.isBackgroundCheckingMetadata {
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
        let activeArtist = currentArtist
        if showingFavorites {
            return activeArtist.tracks.sorted { lhs, rhs in
                let pL = libraryStore.playCount(for: lhs.id)
                let pR = libraryStore.playCount(for: rhs.id)
                if pL != pR {
                    return pL > pR
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } else {
            return activeArtist.tracks
        }
    }

    private struct CategorizedDiscography {
        var studioAlbums: [Album] = []
        var singles: [Album] = []
        var alternates: [Album] = []
        var featuredAlbums: [Album] = []
    }

    @MainActor private static var discographyCache: [String: (version: Int, discography: CategorizedDiscography)] = [:]

    private func categorizeDiscography(for activeArtist: Artist) -> CategorizedDiscography {
        let joined = libraryStore.settings.joinedArtists
        let versionKey = activeArtist.albums.count ^ (activeArtist.tracks.count << 4) ^ joined.hashValue

        if let cached = Self.discographyCache[activeArtist.id], cached.version == versionKey {
            return cached.discography
        }

        var result = CategorizedDiscography()
        for album in activeArtist.albums {
            if album.isFeaturedAlbum(for: activeArtist.name, joinedArtists: joined) {
                result.featuredAlbums.append(album)
            } else if album.isLeadOrCollaborativeAlbum(for: activeArtist.name, joinedArtists: joined) {
                if album.isRemix || album.isLive {
                    result.alternates.append(album)
                } else if album.isSingle {
                    result.singles.append(album)
                } else {
                    result.studioAlbums.append(album)
                }
            }
        }
        let sortBlock: (Album, Album) -> Bool = { lhs, rhs in
            let yL = lhs.resolvedYear ?? 0
            let yR = rhs.resolvedYear ?? 0
            if yL != yR { return yL > yR }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        result.studioAlbums.sort(by: sortBlock)
        result.singles.sort(by: sortBlock)
        result.alternates.sort(by: sortBlock)
        result.featuredAlbums.sort(by: sortBlock)

        Self.discographyCache[activeArtist.id] = (versionKey, result)
        return result
    }

    // Album card
    private func albumCard(album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 8,
                targetDimension: 256
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

    // Featured album card
    private func featuredAlbumCard(album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 8,
                targetDimension: 256
            )
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(album.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(album.formattedYear)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
        }
    }
}

// MARK: - Dedicated Toolbar Menu Component

private struct ArtistDetailToolbarMenuView: View {
    let currentArtist: Artist
    @Bindable var libraryStore: LibraryStore
    @Binding var showingOnlineDiscovery: Bool

    var body: some View {
        Menu {
            let summary = JellyfinDownloadManager.shared.artistSummary(for: currentArtist)
            if summary.total > 0 {
                let jellyfinTracks = currentArtist.tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
                if summary.isAllDownloaded {
                    Button(role: .destructive) {
                        HapticFeedback.selectionChanged()
                        for track in jellyfinTracks {
                            JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
                        }
                    } label: {
                        Text("REMOVE DISCOGRAPHY DOWNLOADS")
                    }
                } else if summary.isAnyDownloading {
                    Button {
                        HapticFeedback.selectionChanged()
                        for track in jellyfinTracks {
                            JellyfinDownloadManager.shared.cancelDownload(trackId: track.id)
                        }
                    } label: {
                        Text("CANCEL DOWNLOADS")
                    }
                } else {
                    Button {
                        HapticFeedback.selectionChanged()
                        JellyfinDownloadManager.shared.download(tracks: jellyfinTracks)
                    } label: {
                        Text("DOWNLOAD AVAILABLE DISCOGRAPHY")
                    }
                }

                Divider()
            }

            Menu {
                ForEach(MetadataAPIOption.allCases) { source in
                    Button(action: {
                        HapticFeedback.lightImpact()
                        libraryStore.scanArtistDiscographyMetadata(artistName: currentArtist.name, source: source)
                    }) {
                        Text(source.displayName)
                    }
                }
            } label: {
                Text("FIND METADATA (DISCOGRAPHY)...")
            }

            Button(action: {
                HapticFeedback.lightImpact()
                showingOnlineDiscovery = true
            }) {
                Text("FIND ONLINE")
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


