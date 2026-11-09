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
    #if os(iOS)
    // Native search state: lets one tap on the close (X) button end search even while the keyboard is up
    @State private var isSearchPresented: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isScrollingContent: Bool = false
    @State private var lastScrollActivity: Date = .distantPast
    @State private var didJustSubmitSearch: Bool = false
    #endif
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var showingPlaylistPicker: Bool = false
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil
    @State private var showingAlbumMetadataSheet: Bool = false
    @State private var showingAlbumMergeSheet: Bool = false
    @State private var showingArtworkSelectionSheet: Bool = false
    @State private var mergeCandidateAlbums: [Album] = []
    @State private var showMergePill: Bool = false
    @State private var showMergedToastPill: Bool = false
    @State private var lastAutoMergedAlbums: [Album] = []
    @State private var mergedToastHideTask: Task<Void, Never>? = nil
    @State private var serverDescription: ServerDescription? = nil
    #if os(iOS)
    @State private var palette: ArtworkColorExtractor.ColorPalette = ArtworkColorExtractor.ColorPalette(
        primaryColor: Color.appSecondaryBackground,
        isDark: true
    )
    #endif
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool
    @Environment(LibrarySelectionStore.self) private var librarySelection: LibrarySelectionStore?

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

    /// iPhone album pages: number instead of art, clear row fill. Mac and other screens keep defaults.
    private var albumTrackRowShowsArtwork: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    private var albumTrackRowUsesClearBackground: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var currentAlbum: Album {
        if let direct = libraryStore.album(forID: album.id) {
            return direct
        }
        // Prefer punctuation-preserving identity (keeps "?") over FuzzyMatcher-normalized fallback.
        if let identityMatch = libraryStore.preferredAlbum(forIdentityKey: album.identityKey) {
            return libraryStore.album(forID: identityMatch.id) ?? identityMatch
        }
        if let normMatch = libraryStore.album(normalizedArtist: album.normalizedArtist, normalizedTitle: album.normalizedTitle) {
            return libraryStore.album(forID: normMatch.id) ?? normMatch
        }
        let validTracks = album.tracks.filter { libraryStore.tracksByID[$0.id] != nil }
        if validTracks.count != album.tracks.count {
            return album.withTracks(validTracks)
        }
        return album
    }

    private func displayedMainTracks(for activeAlbum: Album) -> [Track] {
        let list = activeAlbum.mainTracks
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        guard !cleanQuery.isEmpty else { return list }
        let scored: [(Track, Int)] = list.compactMap { track in
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

    private func displayedAlternateTracks(for activeAlbum: Album) -> [Track] {
        let mainTrackIDs = Set(displayedMainTracks(for: activeAlbum).map(\.id))
        let list = activeAlbum.alternateTracks.filter { !mainTrackIDs.contains($0.id) }
        guard !list.isEmpty else { return [] }
        if list.count == activeAlbum.tracks.count && !activeAlbum.tracks.contains(where: { $0.isAlternate == true }) {
            return []
        }
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        guard !cleanQuery.isEmpty else { return list }
        let scored: [(Track, Int)] = list.compactMap { track in
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
        let activeAlbum = currentAlbum
        let mainTracks = displayedMainTracks(for: activeAlbum)
        let altTracks = displayedAlternateTracks(for: activeAlbum)

        VStack(spacing: 0) {
            #if os(macOS)
            // Smooth Top Search Bar (Decoupled from ScrollView, zero layout jitter). iOS uses the native search field.
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
            #endif

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Header with Artwork & Album Info
                    headerView(for: activeAlbum)

                    // Play / Shuffle Actions with Music Note Button on the far right
                    HStack(spacing: 12) {
                        Button(action: {
                            if let first = activeAlbum.tracks.first {
                                playerService.play(track: first, inQueue: activeAlbum.tracks)
                            }
                        }) {
                            Text(AppCapitalization.format("PLAY ALBUM", enabled: isCaps))
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))

                        Button(action: {
                            // Shuffled
                            var shuffled = activeAlbum.tracks
                            shuffled.shuffle()
                            if let first = shuffled.first {
                                playerService.play(track: first, inQueue: shuffled)
                            }
                        }) {
                            Text(AppCapitalization.format("SHUFFLE", enabled: isCaps))
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .regular))

                        Spacer()


                        // Music note icon button with Album Metadata, Search Online & Playlist Actions
                        Menu {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                playerService.insertPlayNextFront(tracks: activeAlbum.tracks)
                            }) {
                                Text(AppCapitalization.format("PLAY NEXT", enabled: isCaps))
                            }

                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                playerService.appendToQueue(tracks: activeAlbum.tracks)
                            }) {
                                Text(AppCapitalization.format("QUEUE", enabled: isCaps))
                            }

                            Divider()

                            // Local-source albums only
                            let isLocalAlbum = activeAlbum.tracks.contains(where: { !OfflineMode.isServerTrack($0) })
                            if isLocalAlbum && activeAlbum.tracks.contains(where: { $0.supportsMetadataLookup }) {
                                Button(action: {
                                    showingAlbumMetadataSheet = true
                                }) {
                                    Text(AppCapitalization.format("ALBUM METADATA", enabled: isCaps))
                                }
                            }

                            // Local albums only; an album that is already collaborative can still be reverted.
                            if libraryStore.isCollaborativeAlbum(activeAlbum) || isLocalAlbum {
                                Button(action: {
                                    HapticFeedback.notificationSuccess()
                                    libraryStore.toggleCollaborativeAlbum(activeAlbum)
                                }) {
                                    Text(AppCapitalization.format(libraryStore.isCollaborativeAlbum(activeAlbum) ? "REVERT COLLABORATIVE ALBUM" : "MAKE COLLABORATIVE ALBUM", enabled: isCaps))
                                }
                            }

                            Divider()

                            Button(action: {
                                showingPlaylistPicker = true
                            }) {
                                Text(AppCapitalization.format("ADD TO PLAYLIST", enabled: isCaps))
                            }

                            QuickAddToPlaylistMenu(tracks: activeAlbum.tracks, libraryStore: libraryStore)

                            Divider()

                            // Server albums only
                            AlbumDownloadMenuItems(album: activeAlbum)

                            Button(action: {
                                HapticFeedback.lightImpact()
                                libraryStore.togglePinAlbum(activeAlbum)
                            }) {
                                Text(AppCapitalization.format(libraryStore.isAlbumPinned(activeAlbum) ? "UNPIN ALBUM" : "PIN ALBUM", enabled: isCaps))
                            }

                            #if os(iOS)
                            let candidatesToMerge = libraryStore.mergeCandidates(for: currentAlbum)
                            if !candidatesToMerge.isEmpty, !showMergePill {
                                Divider()
                                Button(action: {
                                    HapticFeedback.lightImpact()
                                    mergeCandidateAlbums = candidatesToMerge
                                    showingAlbumMergeSheet = true
                                }) {
                                    Text(AppCapitalization.format("MERGE", enabled: isCaps))
                                }
                            }
                            #endif
                            if libraryStore.hasUndoableAlbumMerge(activeAlbum) {
                                Divider()
                                Button(role: .destructive, action: {
                                    HapticFeedback.lightImpact()
                                    libraryStore.undoAlbumMerge(for: activeAlbum)
                                    #if os(iOS)
                                    refreshMergeSuggestion(for: currentAlbum)
                                    #endif
                                }) {
                                    Text(AppCapitalization.format("UNDO MERGE", enabled: isCaps))
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

                    // Tracklist Section (Main canonical tracks)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppCapitalization.format("TRACKLIST (\(mainTracks.count))", enabled: isCaps))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        if mainTracks.isEmpty && altTracks.isEmpty {
                            EmptyStateView(
                                title: "NO MATCHING TRACKS",
                                message: "No tracks in this album match '\(searchQuery)'."
                            )
                            .padding(.top, 16)
                        } else {
                            let currentTrackID = playerService.currentTrack?.id
                            let isCurrentPlaying = playerService.playbackStatus.isPlaying
                            let nextTrackID = playerService.queueBadges.nextTrackID
                            let playNextSet = playerService.queueBadges.playNextTrackIDs
                            let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                            LazyVStack(spacing: 4) {
                                ForEach(Array(mainTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRowView(
                                        track: track,
                                        indexNumber: index + 1,
                                        isCurrentTrack: track.id == currentTrackID,
                                        isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                        isNextTrack: track.id == nextTrackID,
                                        isInPlayNext: playNextSet.contains(track.id),
                                        isTapToPlayNextEnabled: isTapToPlayNext,
                                        showAlbumSubtitle: false,
                                        showsArtwork: albumTrackRowShowsArtwork,
                                        usesClearBackground: albumTrackRowUsesClearBackground,
                                        onPlay: {
                                            playerService.play(track: track, inQueue: mainTracks, startIndex: index)
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
                                        onSelectAlbum: nil,
                                        quickAddLibraryStore: libraryStore,
                                        isSelected: librarySelection?.contains(track.id) ?? false,
                                        isSelectMode: librarySelection?.isActive ?? false,
                                        onToggleSelect: librarySelection?.toggler(for: track)
                                    )
                                }
                            }
                        }
                    }

                    // Alternates Section (Instrumentals, Remixes, Acoustics, Live Versions, etc.)
                    if !altTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppCapitalization.format("ALTERNATES", enabled: isCaps))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            let currentTrackID = playerService.currentTrack?.id
                            let isCurrentPlaying = playerService.playbackStatus.isPlaying
                            let nextTrackID = playerService.queueBadges.nextTrackID
                            let playNextSet = playerService.queueBadges.playNextTrackIDs
                            let isTapToPlayNext = libraryStore.settings.tapToPlayNext

                            LazyVStack(spacing: 4) {
                                ForEach(Array(altTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRowView(
                                        track: track,
                                        indexNumber: index + 1,
                                        isCurrentTrack: track.id == currentTrackID,
                                        isPlaying: isCurrentPlaying && track.id == currentTrackID,
                                        isNextTrack: track.id == nextTrackID,
                                        isInPlayNext: playNextSet.contains(track.id),
                                        isTapToPlayNextEnabled: isTapToPlayNext,
                                        showAlbumSubtitle: false,
                                        showsArtwork: albumTrackRowShowsArtwork,
                                        usesClearBackground: albumTrackRowUsesClearBackground,
                                        onPlay: {
                                            playerService.play(track: track, inQueue: altTracks, startIndex: index)
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
                                        onSelectAlbum: nil,
                                        quickAddLibraryStore: libraryStore,
                                        isSelected: librarySelection?.contains(track.id) ?? false,
                                        isSelectMode: librarySelection?.isActive ?? false,
                                        onToggleSelect: librarySelection?.toggler(for: track)
                                    )
                                }
                            }
                        }
                        .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 64)
            }
            .dismissKeyboardOnDrag()
            #if os(iOS)
            // Track scrolling (including the drag that pulls the keyboard down) so hiding the keyboard keeps search open
            .onScrollPhaseChange { _, newPhase in
                isScrollingContent = newPhase.isScrolling
                lastScrollActivity = Date()
            }
            #endif
        }
        #if os(iOS)
        .background {
            PlayerBackgroundView(
                style: libraryStore.settings.albumPageBackgroundStyle,
                appTheme: libraryStore.settings.appTheme,
                primaryColor: palette.primaryColor,
                artworkKey: activeAlbum.artworkKey,
                overlayOpacity: 0.50
            )
            .ignoresSafeArea()
        }
        .task(id: activeAlbum.artworkKey) {
            let newPalette = await ArtworkColorExtractor.shared.extractPrimaryColor(
                for: activeAlbum.artworkKey,
                fallback: Color.appSecondaryBackground
            )
            withAnimation(.easeInOut(duration: 0.65)) {
                self.palette = newPalette
            }
        }
        #else
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        #endif
        .navigationTitle(activeAlbum.releaseTypeDisplayTitle)
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        // iOS 26 toolbar search: always-attached search button in the top bar that expands into a field
        // (no conditional modifier, so opening/closing search doesn't reset the scroll position)
        .searchable(text: $searchQuery, isPresented: $isSearchPresented, placement: .toolbar, prompt: Text("SEARCH TRACKS IN ALBUM"))
        .searchToolbarBehavior(.minimize)
        .searchFocused($isSearchFieldFocused)
        // Close search (and the keyboard) in one tap: when the field loses focus without a scroll, end search
        .onChange(of: isSearchFieldFocused) { _, focused in
            // The keyboard Search key also drops focus: skip that one so search stays open with results
            if !focused && didJustSubmitSearch {
                didJustSubmitSearch = false
                return
            }
            // Keyboard pulled down by a drag: focus drops as (or just after) the scroll ends, so allow a short grace window
            let recentlyScrolled = isScrollingContent || Date().timeIntervalSince(lastScrollActivity) < 0.6
            if !focused && isSearchPresented && !recentlyScrolled {
                isSearchPresented = false
            }
        }
        .onSubmit(of: .search) {
            didJustSubmitSearch = true
            // Safety reset in case focus doesn't change, so the next X tap still closes in one tap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { didJustSubmitSearch = false }
        }
        #endif
        .toolbar {
            #if os(iOS)
            DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                // Try to show the search button without the Liquid Glass background
                .sharedBackgroundVisibility(.hidden)
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
            #endif
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
        // Modal presentation sheet
        .sheet(isPresented: $showingPlaylistPicker) {
            playlistPickerSheet(for: activeAlbum.tracks)
        }
        // Dedicated Album Metadata Online Search & Apply Sheet
        .sheet(isPresented: $showingAlbumMetadataSheet) {
            AlbumMetadataSheet(album: activeAlbum, libraryStore: libraryStore)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        #if os(iOS)
        .sheet(isPresented: $showingAlbumMergeSheet) {
            albumMergeSheet(for: activeAlbum)
        }
        .sheet(isPresented: $showingArtworkSelectionSheet) {
            MergedAlbumArtworkPickerSheet(album: currentAlbum, libraryStore: libraryStore)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showMergePill || showMergedToastPill {
                HStack {
                    Spacer(minLength: 0)
                    if showMergedToastPill {
                        albumMergedToastPill
                    } else {
                        albumMergePill
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, playerService.currentTrack != nil ? 92 : 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: activeAlbum.id) {
            refreshMergeSuggestion(for: activeAlbum)
            if libraryStore.settings.hideServerAlbumDuplicates {
                libraryStore.hideVisibleServerDuplicateTracks(among: activeAlbum.tracks)
            }
        }
        .onChange(of: libraryStore.settings.hideServerAlbumDuplicates) { _, enabled in
            if enabled {
                libraryStore.hideVisibleServerDuplicateTracks(among: currentAlbum.tracks)
            }
        }
        .onChange(of: libraryStore.albums.count) { _, _ in
            refreshMergeSuggestion(for: currentAlbum)
        }
        #endif
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
        .enableInteractivePopGesture()
    }

    #if os(iOS)
    private func refreshMergeSuggestion(for active: Album) {
        let candidates = libraryStore.mergeCandidates(for: active)
        mergeCandidateAlbums = candidates
        if libraryStore.settings.albumMergeMode == .automatically {
            showMergePill = false
            let autoCandidates = libraryStore.autoMergeCandidates(for: active)
            guard !autoCandidates.isEmpty else { return }
            lastAutoMergedAlbums = autoCandidates
            libraryStore.mergeAlbums(into: active, otherIDs: autoCandidates.map(\.id))
            mergeCandidateAlbums = []
            presentMergedToastPill()
            return
        }
        showMergedToastPill = false
        showMergePill = libraryStore.shouldSuggestAlbumMerge(for: active)
    }

    private func presentMergedToastPill() {
        mergedToastHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showMergedToastPill = true }
        mergedToastHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showMergedToastPill = false }
        }
    }

    private var albumMergePill: some View {
        let theme = libraryStore.settings.appTheme
        return HStack(spacing: 4) {
            Button {
                HapticFeedback.lightImpact()
                showingAlbumMergeSheet = true
            } label: {
                Text("MERGE ALBUM?")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accentColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                HapticFeedback.lightImpact()
                libraryStore.dismissAlbumMergeSuggestion(for: currentAlbum)
                withAnimation(.easeOut(duration: 0.2)) {
                    showMergePill = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(theme.backgroundColor.opacity(0.96))
        )
        .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 2)
    }

    private var albumMergedToastPill: some View {
        let theme = libraryStore.settings.appTheme
        return Button {
            HapticFeedback.lightImpact()
            // Keep mergeCandidateAlbums empty so the sheet shows lastAutoMergedAlbums as a post-merge review.
            showingAlbumMergeSheet = true
        } label: {
            Text(AppCapitalization.format("MERGED", enabled: isCaps))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(theme.backgroundColor.opacity(0.96))
        )
        .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private func albumMergeSheet(for activeAlbum: Album) -> some View {
        let theme = libraryStore.settings.appTheme
        let sheetAlbums = mergeCandidateAlbums.isEmpty ? lastAutoMergedAlbums : mergeCandidateAlbums
        let isPostMergeReview = mergeCandidateAlbums.isEmpty && !lastAutoMergedAlbums.isEmpty
        VStack(spacing: 0) {
            Text(AppCapitalization.format(isPostMergeReview ? "MERGED ALBUMS" : "MERGE ALBUM", enabled: isCaps))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 16)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if sheetAlbums.isEmpty {
                        Text(AppCapitalization.format(isPostMergeReview ? "NO MERGED ALBUMS" : "NO ALBUMS TO MERGE", enabled: isCaps))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    } else {
                        ForEach(sheetAlbums) { candidate in
                            Button {
                                HapticFeedback.notificationSuccess()
                                if isPostMergeReview {
                                    let candidateID = candidate.id
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        lastAutoMergedAlbums.removeAll { $0.id == candidateID }
                                        if lastAutoMergedAlbums.isEmpty {
                                            showMergedToastPill = false
                                        }
                                    }
                                    Task { @MainActor in
                                        libraryStore.unmergeAlbum(id: candidateID, from: currentAlbum)
                                        refreshMergeSuggestion(for: currentAlbum)
                                    }
                                } else {
                                    libraryStore.mergeAlbums(into: currentAlbum, otherIDs: [candidate.id])
                                    withAnimation(.easeOut(duration: 0.2)) { showMergePill = false }
                                    refreshMergeSuggestion(for: currentAlbum)
                                    showingAlbumMergeSheet = false
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AlbumArtworkView(
                                        artworkKey: candidate.artworkKey,
                                        title: candidate.title,
                                        subtitle: candidate.artist,
                                        cornerRadius: 8,
                                        targetDimension: 52
                                    )
                                    .frame(width: 52, height: 52)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                        Text("\(candidate.artist) · \(candidate.formattedTrackCount)")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let year = candidate.displayYear {
                                            Text(year)
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Text(AppCapitalization.format(isPostMergeReview ? "UNMERGE" : "MERGE", enabled: isCaps))
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(isPostMergeReview ? Color.red.opacity(0.85) : theme.accentColor)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !isPostMergeReview && sheetAlbums.count > 1 {
                            Button {
                                HapticFeedback.notificationSuccess()
                                libraryStore.mergeAlbums(into: currentAlbum, otherIDs: sheetAlbums.map(\.id))
                                showingAlbumMergeSheet = false
                                withAnimation(.easeOut(duration: 0.2)) { showMergePill = false }
                                refreshMergeSuggestion(for: currentAlbum)
                            } label: {
                                Text(AppCapitalization.format("MERGE ALL INTO THIS ALBUM", enabled: isCaps))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(theme.accentColor)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }

                        if isPostMergeReview && sheetAlbums.count > 1 {
                            Button {
                                HapticFeedback.notificationSuccess()
                                let candidateIDs = sheetAlbums.map(\.id)
                                withAnimation(.easeOut(duration: 0.2)) {
                                    lastAutoMergedAlbums.removeAll()
                                    showMergedToastPill = false
                                }
                                Task { @MainActor in
                                    libraryStore.unmergeAlbums(ids: candidateIDs, from: currentAlbum)
                                    refreshMergeSuggestion(for: currentAlbum)
                                }
                            } label: {
                                Text(AppCapitalization.format("UNMERGE ALL", enabled: isCaps))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.red.opacity(0.85))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.backgroundColor)
        .tint(theme.accentColor)
        .environment(\.appTheme, theme)
    }
    #endif


    // Playlist picker sheet
    private func playlistPickerSheet(for albumTracks: [Track]) -> some View {
        PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: albumTracks.lazy.compactMap(\.artworkKey).first) { playlist in
            HapticFeedback.notificationSuccess()
            libraryStore.addTracks(albumTracks, toPlaylistID: playlist.id)
            showingPlaylistPicker = false
            selectedTrackForPlaylist = nil
        }
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

    @ViewBuilder
    private func headerView(for activeAlbum: Album) -> some View {
        HStack(alignment: .top, spacing: 16) {
            let isMerged = libraryStore.isMergedAlbum(activeAlbum)
            if isMerged {
                Button {
                    HapticFeedback.lightImpact()
                    showingArtworkSelectionSheet = true
                } label: {
                    AlbumArtworkView(
                        artworkKey: activeAlbum.artworkKey,
                        title: activeAlbum.title,
                        subtitle: activeAlbum.artist,
                        cornerRadius: 10,
                        targetDimension: 600
                    )
                    .frame(width: 124, height: 124)
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                AlbumArtworkView(
                    artworkKey: activeAlbum.artworkKey,
                    title: activeAlbum.title,
                    subtitle: activeAlbum.artist,
                    cornerRadius: 10,
                    targetDimension: 600
                )
                .frame(width: 124, height: 124)
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(activeAlbum.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                MultiArtistButtonsView(
                    rawArtist: activeAlbum.artist,
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
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .contextMenu {
                    if ArtistParser.parseArtists(from: activeAlbum.artist).count > 1 || libraryStore.isArtistJoined(rawArtist: activeAlbum.artist) {
                        if libraryStore.isArtistJoined(rawArtist: activeAlbum.artist) {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.unjoinArtists(for: activeAlbum.artist)
                            }) {
                                Text("SEPARATE ARTISTS")
                            }
                        } else {
                            Button(action: {
                                HapticFeedback.notificationSuccess()
                                libraryStore.joinArtists(for: activeAlbum.artist)
                            }) {
                                Text("JOIN ARTISTS")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(TimeFormatting.formatSummaryDuration(seconds: activeAlbum.totalDuration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let year = activeAlbum.displayYear {
                        Text(year)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let serverDescription {
                        ServerDescriptionButton(description: serverDescription, title: activeAlbum.title)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .loadsServerDescription(ServerDescriptionTarget.album(activeAlbum, sources: libraryStore.settings.serverSources),
                                sources: libraryStore.settings.serverSources, into: $serverDescription)
    }
}

#if os(iOS)
private struct MergedAlbumArtworkPickerSheet: View {
    let album: Album
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        let releases = libraryStore.mergedReleases(for: album)
        let preferredYear = libraryStore.preferredYear(for: album)
        VStack(spacing: 0) {
            Text(AppCapitalization.format("SELECT ARTWORK", enabled: isCaps))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 16)

            ScrollView {
                if releases.isEmpty {
                    Text(AppCapitalization.format("NO ARTWORKS AVAILABLE", enabled: isCaps))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 32)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(releases) { release in
                            let isSelected = (release.artworkKey == album.artworkKey)
                            let releaseYear = release.year
                            let isYearSelected = (releaseYear != nil && releaseYear == preferredYear)

                            Button {
                                HapticFeedback.notificationSuccess()
                                libraryStore.setMergedAlbumArtwork(key: release.artworkKey ?? "", for: album)
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        AlbumArtworkView(
                                            artworkKey: release.artworkKey,
                                            title: album.title,
                                            subtitle: album.artist,
                                            cornerRadius: 10,
                                            targetDimension: 400
                                        )
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(isSelected ? appTheme.accentColor : Color.clear, lineWidth: 3)
                                        )
                                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)

                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(appTheme.accentColor)
                                                .background(Circle().fill(appTheme.backgroundColor))
                                                .padding(8)
                                        }
                                    }

                                    if let year = releaseYear, year > 0 {
                                        Text(String(year))
                                            .font(.system(size: 12, weight: isYearSelected ? .bold : .semibold, design: .monospaced))
                                            .foregroundStyle(isYearSelected ? appTheme.accentColor : Color.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let year = releaseYear, year > 0 {
                                    Button {
                                        HapticFeedback.lightImpact()
                                        libraryStore.toggleMergedAlbumYear(year: year, for: album)
                                    } label: {
                                        if isYearSelected {
                                            Label(AppCapitalization.format("USE RELEASE YEAR", enabled: isCaps), systemImage: "checkmark")
                                        } else {
                                            Text(AppCapitalization.format("USE RELEASE YEAR", enabled: isCaps))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appTheme.backgroundColor)
        .tint(appTheme.accentColor)
    }
}
#endif

