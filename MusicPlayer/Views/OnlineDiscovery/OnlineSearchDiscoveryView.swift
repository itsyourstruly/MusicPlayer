import SwiftUI

/// Dedicated online music search and exploration screen matching the app's clean typography and glassmorphic layout.
public struct OnlineSearchDiscoveryView: View {
    @State private var query: String = ""
    @State private var selectedCategory: OnlineDiscoveryItemType = .all
    @State private var results: OnlineSearchResults = OnlineSearchResults()
    @State private var isSearching: Bool = false
    @State private var previewManager = OnlineAudioPreviewManager.shared
    @State private var searchTask: Task<Void, Never>? = nil
    @Environment(\.appTheme) private var appTheme

    // Columns for 2-column album grids
    private let albumColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    // Initialize with configured properties
    public init() {}

    // Main view layout structure
    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            searchHeaderView

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.5))

            // Content Area
            if isSearching {
                loadingView
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptySearchPromptView
            } else if results.isEmpty {
                noResultsView
            } else {
                resultsContentView
            }
        }
        .dismissKeyboardOnDrag()
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("ONLINE DISCOVERY")
        .navigationBarTitleDisplayMode(.inline)
        // React to query changes
        .onChange(of: query) { _, newQuery in
            triggerSearch(query: newQuery, immediate: false)
        }
        // Triggered when view disappears
        .onDisappear {
            searchTask?.cancel()
            previewManager.stop()
        }
    }

    // MARK: - Search Header

    private var searchHeaderView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Search tracks, artists, or albums...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .onSubmit {
                            triggerSearch(query: query, immediate: true)
                        }

                    if !query.isEmpty {
                        Button(action: {
                            searchTask?.cancel()
                            query = ""
                            results = OnlineSearchResults()
                            isSearching = false
                            previewManager.stop()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(appTheme.secondaryBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(appTheme.separatorColor.opacity(0.4), lineWidth: 0.5)
                )

                if !query.isEmpty {
                    Button("SEARCH") {
                        triggerSearch(query: query, immediate: true)
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                }
            }

            // Category Filter Pills
            HStack(spacing: 8) {
                ForEach(OnlineDiscoveryItemType.allCases) { category in
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCategory = category
                        }
                    }) {
                        Text(category.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedCategory == category ? Color.primary : appTheme.secondaryBackgroundColor)
                            .foregroundStyle(selectedCategory == category ? Color.appInvertedBackground : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(appTheme.backgroundColor)
    }

    // Trigger search
    private func triggerSearch(query: String, immediate: Bool = false) {
        searchTask?.cancel()

        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            self.results = OnlineSearchResults()
            self.isSearching = false
            return
        }

        self.isSearching = true
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }

            let searchResults = await OnlineDiscoveryService.shared.search(query: clean)
            if !Task.isCancelled {
                self.results = searchResults
                self.isSearching = false
            }
        }
    }

    // MARK: - Redesigned Results View

    private var resultsContentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Artists Section
                if (selectedCategory == .all || selectedCategory == .artists) && !results.artists.isEmpty {
                    artistsSectionView
                }

                // Albums Section
                if (selectedCategory == .all || selectedCategory == .albums) && !results.albums.isEmpty {
                    albumsSectionView
                }

                // Tracks Section
                if (selectedCategory == .all || selectedCategory == .tracks) && !results.tracks.isEmpty {
                    tracksSectionView
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
    }

    // MARK: - Artists Section
    private var artistsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ARTISTS (\(results.artists.count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            if selectedCategory == .all {
                // Horizontal scrolling carousel in .all mode
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(results.artists) { artist in
                            NavigationLink(destination: OnlineArtistDetailView(artist: artist)) {
                                OnlineArtistCard(artist: artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                // Vertical list in .artists filtered mode
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(results.artists) { artist in
                        NavigationLink(destination: OnlineArtistDetailView(artist: artist)) {
                            OnlineArtistRow(artist: artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Albums Section
    private var albumsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALBUMS (\(results.albums.count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: albumColumns, spacing: 14) {
                ForEach(results.albums) { album in
                    NavigationLink(destination: OnlineAlbumDetailView(album: album)) {
                        OnlineAlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tracks Section
    private var tracksSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRACKS (\(results.tracks.count))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(results.tracks) { track in
                    NavigationLink(destination: OnlineTrackDetailView(track: track)) {
                        OnlineTrackRow(
                            track: track,
                            isPlayingPreview: previewManager.currentTrackID == track.id && previewManager.isPlaying,
                            onTogglePreview: {
                                previewManager.togglePreview(track: track)
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Loading & Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("SEARCHING ONLINE CATALOG...")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var emptySearchPromptView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 36))
                .foregroundStyle(appTheme.accentColor.opacity(0.8))

            Text("GLOBAL ONLINE SEARCH")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("Search any artist, album, or song to inspect detailed credits, biographies, tracklists, and 30-second audio previews.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .lineSpacing(3)
            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "slash.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.6))

            Text("NO MATCHES FOUND")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("No online tracks, albums, or artists found for '\(query)'.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Reusable Online Result Components

/// Horizontal card for artist results in general search
public struct OnlineArtistCard: View {
    public let artist: OnlineArtistItem
    @Environment(\.appTheme) private var appTheme

    public init(artist: OnlineArtistItem) {
        self.artist = artist
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 8) {
            if let img = artist.imageURL {
                AsyncImage(url: img) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(1.0, contentMode: .fill)
                    default:
                        Circle()
                            .fill(appTheme.secondaryBackgroundColor)
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(appTheme.secondaryBackgroundColor)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Text(String(artist.name.prefix(1)).uppercased())
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                    )
            }

            VStack(spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .frame(width: 90)

                Text(artist.genre?.uppercased() ?? "ARTIST")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Full-width row for artist results in dedicated filtered search
public struct OnlineArtistRow: View {
    public let artist: OnlineArtistItem
    @Environment(\.appTheme) private var appTheme

    public init(artist: OnlineArtistItem) {
        self.artist = artist
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let img = artist.imageURL {
                AsyncImage(url: img) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(1.0, contentMode: .fill)
                    default:
                        Circle().fill(appTheme.secondaryBackgroundColor)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(appTheme.secondaryBackgroundColor)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(String(artist.name.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(artist.genre?.uppercased() ?? "ARTIST")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
}

/// 2-Column Grid Card for Album results
public struct OnlineAlbumCard: View {
    public let album: OnlineAlbumItem
    @Environment(\.appTheme) private var appTheme

    public init(album: OnlineAlbumItem) {
        self.album = album
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: album.artworkURL) { phase in
                switch phase {
                case .success(let img):
                    img
                        .resizable()
                        .aspectRatio(1.0, contentMode: .fill)
                default:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appTheme.secondaryBackgroundColor)
                }
            }
            .aspectRatio(1.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(album.artistName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appTheme.accentColor)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(album.formattedReleaseDate)
                    if let count = album.trackCount, count > 0 {
                        Text("• \(count) TRACKS")
                    }
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
    }
}

/// Full-width typographic row for Track results (matches TrackRowView aesthetic)
public struct OnlineTrackRow: View {
    public let track: OnlineTrackItem
    public let isPlayingPreview: Bool
    public let onTogglePreview: () -> Void
    @Environment(\.appTheme) private var appTheme

    public init(
        track: OnlineTrackItem,
        isPlayingPreview: Bool,
        onTogglePreview: @escaping () -> Void
    ) {
        self.track = track
        self.isPlayingPreview = isPlayingPreview
        self.onTogglePreview = onTogglePreview
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Track artwork thumbnail with Play/Pause button overlay
            ZStack(alignment: .center) {
                AsyncImage(url: track.artworkURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(1.0, contentMode: .fill)
                    default:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(appTheme.secondaryBackgroundColor)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if track.previewURL != nil {
                    Button(action: onTogglePreview) {
                        Image(systemName: isPlayingPreview ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 26, height: 26)
                            .background(Color.black.opacity(0.75))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isPlayingPreview ? appTheme.accentColor : Color.primary)
                    .lineLimit(1)

                Text(track.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(appTheme.accentColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 30s Preview Button Pill
            if track.previewURL != nil {
                Button(action: onTogglePreview) {
                    Text(isPlayingPreview ? "PAUSE" : "PREVIEW")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(isPlayingPreview ? appTheme.accentColor : appTheme.accentColor.opacity(0.18))
                        .foregroundStyle(isPlayingPreview ? Color.appInvertedBackground : appTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text(TimeFormatting.formatTrackDuration(track.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isPlayingPreview
                ? appTheme.secondaryBackgroundColor.opacity(0.5)
                : appTheme.backgroundColor
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}
