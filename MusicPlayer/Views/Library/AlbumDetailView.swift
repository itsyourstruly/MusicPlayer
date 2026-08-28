import SwiftUI

/// Detailed album view displaying artwork, metadata tags, summary duration, and sorted tracks.
public struct AlbumDetailView: View {
    // Album title
    public let album: Album
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil
    @State private var showingMetadataSheet: Bool = false
    @State private var isCheckingMetadata: Bool = false
    @State private var albumDiffs: [MetadataDiff] = []
    @State private var navigateToOnlineSearch: Bool = false

    // Initialize with configured properties
    public init(
        album: Album,
        libraryStore: LibraryStore,
        playerService: AudioPlayerService
    ) {
        self.album = album
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    private var displayedTracks: [Track] {
        // Clean query
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        // Ensure preconditions are met before proceeding
        guard !cleanQuery.isEmpty else { return album.tracks }
        // Scored
        let scored: [(Track, Int)] = album.tracks.compactMap { track in
            // Score
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (track, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 0) {
            // Smooth Top Search Bar (Decoupled from ScrollView, zero layout jitter)
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("SEARCH TRACKS IN ALBUM", text: $searchQuery)
                        .font(.system(size: 13, weight: .medium))
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)

                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Header with Artwork & Album Info
                    headerView

                    // Play / Shuffle Actions with Music Note Button on the far right
                    HStack(spacing: 12) {
                        Button(action: {
                            if let first = album.tracks.first {
                                playerService.play(track: first, inQueue: album.tracks)
                            }
                        }) {
                            Text("PLAY ALBUM")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))

                        Button(action: {
                            // Shuffled
                            var shuffled = album.tracks
                            shuffled.shuffle()
                            if let first = shuffled.first {
                                playerService.play(track: first, inQueue: shuffled)
                            }
                        }) {
                            Text("SHUFFLE")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))

                        Spacer()

                        // Music note icon button with Search Online, Check Metadata & Playlist Actions
                        Menu {
                            Button(action: {
                                navigateToOnlineSearch = true
                            }) {
                                Label("SEARCH ONLINE", systemImage: "network")
                            }

                            Button(action: {
                                checkAlbumMetadata()
                            }) {
                                Label("CHECK METADATA", systemImage: "arrow.triangle.2.circlepath")
                            }

                            Divider()

                            Button(action: {
                                showingPlaylistPicker = true
                            }) {
                                Label("ADD TO PLAYLIST", systemImage: "plus.rectangle.on.folder")
                            }

                            if !libraryStore.playlists.isEmpty {
                                Menu {
                                    ForEach(libraryStore.playlists) { playlist in
                                        Button(action: {
                                            HapticFeedback.notificationSuccess()
                                            libraryStore.addTracks(album.tracks, toPlaylistID: playlist.id)
                                        }) {
                                            Text(playlist.name)
                                        }
                                    }
                                } label: {
                                    Label("QUICK ADD TO...", systemImage: "bolt.fill")
                                }
                            }
                        } label: {
                            Image(systemName: "music.note")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Tracklist Section (Album name removed next to artist, no track numbers written)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TRACKLIST (\(displayedTracks.count))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        if displayedTracks.isEmpty {
                            EmptyStateView(
                                title: "NO MATCHING TRACKS",
                                message: "No tracks in this album match '\(searchQuery)'."
                            )
                            .padding(.top, 16)
                        } else {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRowView(
                                        track: track,
                                        indexNumber: nil,
                                        isCurrentTrack: track.id == playerService.currentTrack?.id,
                                        isPlaying: playerService.playbackStatus.isPlaying && track.id == playerService.currentTrack?.id,
                                        isNextTrack: playerService.nextTrack?.id == track.id,
                                        isInPlayNext: playerService.playNextQueue.contains(where: { $0.id == track.id }),
                                        isTapToPlayNextEnabled: libraryStore.settings.tapToPlayNext,
                                        showAlbumSubtitle: false,
                                        onPlay: {
                                            // Original index
                                            let originalIndex = album.tracks.firstIndex(where: { $0.id == track.id }) ?? index
                                            playerService.play(track: track, inQueue: album.tracks, startIndex: originalIndex)
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
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 64)
            }
            .dismissKeyboardOnDrag()
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleSearch) {
                    Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        // Modal presentation sheet
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
        }
        // Modal presentation sheet
        .sheet(isPresented: $showingPlaylistPicker) {
            playlistPickerSheet(for: album.tracks)
        }
        // Modal presentation sheet
        .sheet(isPresented: $showingMetadataSheet) {
            AlbumMetadataReviewSheet(
                album: album,
                libraryStore: libraryStore,
                diffs: albumDiffs,
                isLoading: isCheckingMetadata,
                onRecheck: {
                    checkAlbumMetadata()
                }
            )
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(isPresented: $navigateToOnlineSearch) {
            GlobalSearchView(
                libraryStore: libraryStore,
                playerService: playerService,
                initialQuery: "\(album.artist) \(album.title)",
                initialOnlineMode: true
            )
        }
    }

    // Check album metadata
    private func checkAlbumMetadata() {
        isCheckingMetadata = true
        showingMetadataSheet = true
        Task {
            // Diffs
            let diffs = await libraryStore.checkMetadataForAlbum(album: album)
            await MainActor.run {
                self.albumDiffs = diffs
                self.isCheckingMetadata = false
            }
        }
    }


    // Playlist picker sheet
    private func playlistPickerSheet(for albumTracks: [Track]) -> some View {
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
                            HapticFeedback.notificationSuccess()
                            libraryStore.addTracks(albumTracks, toPlaylistID: playlist.id)
                            showingPlaylistPicker = false
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
                                Text("ADD ALL (\(albumTracks.count))")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.appSecondaryBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("CANCEL") {
                        showingPlaylistPicker = false
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // Toggle search
    private func toggleSearch() {
        if isSearching {
            isSearchFocused = false
            withAnimation(.easeOut(duration: 0.18)) {
                isSearching = false
                searchQuery = ""
            }
        } else {
            withAnimation(.easeIn(duration: 0.18)) {
                isSearching = true
            }
            isSearchFocused = true
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 16) {
            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 10
            )
            .frame(width: 124, height: 124)
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("ALBUM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(album.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                MultiArtistButtonsView(
                    rawArtist: album.artist,
                    joinedArtists: libraryStore.settings.joinedArtists,
                    font: .system(size: 14, weight: .medium),
                    foregroundColor: Color.primary,
                    separatorColor: .secondary,
                    lineLimit: nil,
                    onSelectArtist: { artistName in
                        if let artistObj = libraryStore.findArtist(name: artistName) {
                            selectedArtistForNavigation = artistObj
                        }
                    }
                )
                .contentShape(Rectangle())
                .contextMenu {
                    if ArtistParser.parseArtists(from: album.artist).count > 1 || libraryStore.isArtistJoined(rawArtist: album.artist) {
                        if libraryStore.isArtistJoined(rawArtist: album.artist) {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.unjoinArtists(for: album.artist)
                            }) {
                                Text("SEPARATE ARTISTS")
                            }
                        } else {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.joinArtists(for: album.artist)
                            }) {
                                Text("JOIN ARTISTS")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.formattedTrackCount)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(TimeFormatting.formatSummaryDuration(seconds: album.totalDuration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Dedicated side-by-side metadata review sheet for an entire album.
public struct AlbumMetadataReviewSheet: View {
    // Album title
    public let album: Album
    @Bindable var libraryStore: LibraryStore
    public let diffs: [MetadataDiff]
    // Flag indicating if loading
    public let isLoading: Bool
    // On recheck
    public let onRecheck: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @State private var preserveFeatures: Bool = true
    @State private var isEnrichingAll: Bool = false
    @State private var enrichProgress: Double = 0.0
    @State private var enrichStatusText: String = ""

    // Initialize with configured properties
    public init(
        album: Album,
        libraryStore: LibraryStore,
        diffs: [MetadataDiff],
        isLoading: Bool,
        onRecheck: @escaping () -> Void
    ) {
        self.album = album
        self.libraryStore = libraryStore
        self.diffs = diffs
        self.isLoading = isLoading
        self.onRecheck = onRecheck
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(Color.primary)
                        Text("CHECKING APPLE MUSIC METADATA FOR '\(album.title.uppercased())'...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
                } else if diffs.isEmpty {
                    VStack(spacing: 14) {
                        Text("NO ONLINE METADATA MATCHES")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)

                        Text("Could not find verified online album matches for '\(album.title)' by '\(album.artist)'.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        Button(action: onRecheck) {
                            Text("RETRY SCAN")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
                        .padding(.top, 6)
                    }
                    .padding(.vertical, 48)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 20) {
                            // Header Summary Card (Identical to Settings)
                            EnrichHeaderCardView(
                                diffsCount: diffs.count,
                                isBackgroundChecking: false,
                                backgroundStatus: "",
                                backgroundProgress: 0.0,
                                isEnriching: isEnrichingAll,
                                progress: enrichProgress,
                                statusText: enrichStatusText,
                                preserveFeatures: $preserveFeatures,
                                writeToFile: $libraryStore.settings.writeMetadataToAudioFiles,
                                onEnrichAll: {
                                    enrichAll()
                                }
                            )

                            // Swipeable Track Cards
                            ForEach(diffs) { diff in
                                SwipeableMetadataTrackCard(
                                    diff: diff,
                                    preserveFeatures: preserveFeatures,
                                    onApply: { lockedFields in
                                        applySingleWithLocks(diff: diff, lockedFields: lockedFields)
                                    },
                                    onKeepLocal: {
                                        withAnimation {
                                            libraryStore.dismissEnrichmentDiff(diffID: diff.id)
                                        }
                                        HapticFeedback.notificationSuccess()
                                    }
                                )

                                Divider()
                                    .overlay(appTheme.separatorColor.opacity(0.35))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ALBUM METADATA REVIEW")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
    }

    // Apply single with custom locks
    private func applySingleWithLocks(diff: MetadataDiff, lockedFields: Set<MetadataField>) {
        let local = diff.localTrack
        let online = diff.onlineMetadata

        let finalTitle = lockedFields.contains(.title) ? local.title : online.title
        let finalArtist = lockedFields.contains(.artist) ? local.artist : online.artist
        let finalAlbum = lockedFields.contains(.album) ? local.album : (online.album.isEmpty ? local.album : online.album)
        let finalYear = lockedFields.contains(.year) ? local.year : (online.releaseYear ?? local.year)
        let finalTrackNumber = lockedFields.contains(.trackNumber) ? local.trackNumber : (online.trackNumber ?? local.trackNumber)
        let finalGenre = lockedFields.contains(.genre) ? local.genre : (online.genre ?? local.genre)
        let finalArtworkURL = lockedFields.contains(.artwork) ? nil : online.artworkURL

        let customizedOnline = OnlineTrackMetadata(
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            releaseYear: finalYear,
            genre: finalGenre,
            trackNumber: finalTrackNumber,
            artworkURL: finalArtworkURL,
            isCompilation: online.isCompilation
        )

        Task {
            _ = await libraryStore.applyOnlineMetadata(
                trackID: local.id,
                onlineMetadata: customizedOnline,
                preserveLocalTitleAndArtist: false
            )
            HapticFeedback.notificationSuccess()
        }
    }

    // Enrich all
    private func enrichAll() {
        // Ensure preconditions are met before proceeding
        guard !diffs.isEmpty else { return }
        isEnrichingAll = true
        enrichProgress = 0.0
        enrichStatusText = "Pre-fetching artwork..."

        Task {
            _ = await libraryStore.applyBatchOnlineMetadata(
                diffs: diffs,
                preserveLocalTitleAndArtist: preserveFeatures,
                onProgress: { progress, text in
                    Task { @MainActor in
                        self.enrichProgress = progress
                        self.enrichStatusText = text
                    }
                }
            )
            isEnrichingAll = false
            HapticFeedback.notificationSuccess()
            dismiss()
        }
    }
}

