//
//  OnlineSearchDiscoveryView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import SwiftUI

/// Dedicated online music search and deep exploration screen matching the Library 2-column layout.
public struct OnlineSearchDiscoveryView: View {
    @State private var query: String = ""
    @State private var selectedCategory: OnlineDiscoveryItemType = .all
    @State private var results: OnlineSearchResults = OnlineSearchResults()
    @State private var isSearching: Bool = false
    @State private var previewManager = OnlineAudioPreviewManager.shared
    @State private var searchTask: Task<Void, Never>? = nil
    @Environment(\.appTheme) private var appTheme

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public init() {}

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
                resultsGridView
            }
        }
        .dismissKeyboardOnDrag()
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("ONLINE DISCOVERY")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, newQuery in
            triggerSearch(query: newQuery, immediate: false)
        }
        .onDisappear {
            searchTask?.cancel()
            previewManager.stop()
        }
    }

    // MARK: - Search Header

    private var searchHeaderView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search tracks, artists, or albums...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(appTheme.separatorColor.opacity(0.4), lineWidth: 0.5)
                    )
                    .onSubmit {
                        triggerSearch(query: query, immediate: true)
                    }

                if !query.isEmpty {
                    Button("SEARCH") {
                        triggerSearch(query: query, immediate: true)
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)

                    Button("CLEAR") {
                        searchTask?.cancel()
                        query = ""
                        results = OnlineSearchResults()
                        isSearching = false
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }

            // Category Filter Pills
            HStack(spacing: 8) {
                ForEach(OnlineDiscoveryItemType.allCases) { category in
                    Button(action: {
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
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { return }

            let searchResults = await OnlineDiscoveryService.shared.search(query: clean)
            if !Task.isCancelled {
                self.results = searchResults
                self.isSearching = false
            }
        }
    }

    // MARK: - 2-Column Results Grid

    private var resultsGridView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Artists Section
                if (selectedCategory == .all || selectedCategory == .artists) && !results.artists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ARTISTS (\(results.artists.count))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(results.artists) { artist in
                                OnlineArtistGridCard(artist: artist)
                            }
                        }
                    }
                }

                // Albums Section
                if (selectedCategory == .all || selectedCategory == .albums) && !results.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ALBUMS (\(results.albums.count))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(results.albums) { album in
                                OnlineAlbumGridCard(album: album)
                            }
                        }
                    }
                }

                // Tracks Section
                if (selectedCategory == .all || selectedCategory == .tracks) && !results.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TRACKS (\(results.tracks.count))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(results.tracks) { track in
                                OnlineTrackGridCard(track: track)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
    }

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
        VStack(spacing: 12) {
            Spacer()
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

// MARK: - 2-Column Grid Cards (Library Aesthetic)

public struct OnlineArtistGridCard: View {
    public let artist: OnlineArtistItem
    @Environment(\.appTheme) private var appTheme

    public init(artist: OnlineArtistItem) {
        self.artist = artist
    }

    public var body: some View {
        NavigationLink(destination: OnlineArtistDetailView(artist: artist)) {
            VStack(alignment: .leading, spacing: 8) {
                // Artist Photo with 8pt corner radius matching library
                if let img = artist.imageURL {
                    AsyncImage(url: img) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(1.0, contentMode: .fill)
                        default:
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(appTheme.secondaryBackgroundColor)
                        }
                    }
                    .aspectRatio(1.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appTheme.secondaryBackgroundColor)
                        .aspectRatio(1.0, contentMode: .fit)
                        .overlay(
                            Text(String(artist.name.prefix(1)).uppercased())
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    if let g = artist.genre {
                        Text(g.uppercased())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("ARTIST")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

public struct OnlineAlbumGridCard: View {
    public let album: OnlineAlbumItem
    @Environment(\.appTheme) private var appTheme

    public init(album: OnlineAlbumItem) {
        self.album = album
    }

    public var body: some View {
        NavigationLink(destination: OnlineAlbumDetailView(album: album)) {
            VStack(alignment: .leading, spacing: 8) {
                // 1.0 Aspect Ratio Square Artwork
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(album.formattedReleaseDate)
                        if let count = album.trackCount, count > 0 {
                            Text("• \(count) TRACKS")
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

public struct OnlineTrackGridCard: View {
    public let track: OnlineTrackItem
    @State private var previewManager = OnlineAudioPreviewManager.shared
    @Environment(\.appTheme) private var appTheme

    public init(track: OnlineTrackItem) {
        self.track = track
    }

    public var body: some View {
        NavigationLink(destination: OnlineTrackDetailView(track: track)) {
            VStack(alignment: .leading, spacing: 8) {
                // Square Artwork with Play/Pause Trigger Badge
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: track.artworkURL) { phase in
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

                    if track.previewURL != nil {
                        Button(action: {
                            previewManager.togglePreview(track: track)
                        }) {
                            Text(previewManager.currentTrackID == track.id && previewManager.isPlaying ? "PAUSE" : "PLAY")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.85))
                                .foregroundStyle(appTheme.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(track.artistName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(appTheme.accentColor)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(TimeFormatting.formatTrackDuration(track.duration))
                        if let y = track.releaseYear, y > 0 {
                            Text("• \(y)")
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}
