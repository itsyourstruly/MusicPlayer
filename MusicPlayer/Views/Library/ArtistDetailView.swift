//
//  ArtistDetailView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI

/// Detailed discography and track view for a specific artist.
public struct ArtistDetailView: View {
    public let artist: Artist
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    @State private var selectedAlbumForNavigation: Album? = nil
    @State private var selectedArtistForNavigation: Artist? = nil
    @State private var selectedTrackForInfo: Track? = nil
    @State private var showingFavorites: Bool = false

    public init(
        artist: Artist,
        libraryStore: LibraryStore,
        playerService: AudioPlayerService
    ) {
        self.artist = artist
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    public var body: some View {
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

                // 1. Studio Albums Section (Lead Artist, Not Singles)
                if !ownAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "ALBUMS",
                            artistName: artist.name,
                            albums: ownAlbums,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("ALBUMS (\(ownAlbums.count))")
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
                            HStack(spacing: 12) {
                                ForEach(ownAlbums) { album in
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
                if !ownSingles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "SINGLES",
                            artistName: artist.name,
                            albums: ownSingles,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("SINGLES (\(ownSingles.count))")
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
                            HStack(spacing: 12) {
                                ForEach(ownSingles) { single in
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

                // 3. Featured On Section (Guest appearances on other artists' albums)
                if !featuredAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(destination: ArtistSectionFullListView(
                            title: "FEATURED ON",
                            artistName: artist.name,
                            albums: featuredAlbums,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )) {
                            HStack {
                                Text("FEATURED ON (\(featuredAlbums.count))")
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
                            HStack(spacing: 12) {
                                ForEach(featuredAlbums) { featAlbum in
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
                        Text(showingFavorites ? "YOUR FAVORITES (\(displayedArtistTracks.count))" : "ALL TRACKS (\(artist.tracks.count))")
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

                    LazyVStack(spacing: 4) {
                        ForEach(Array(displayedArtistTracks.enumerated()), id: \.element.id) { index, track in
                            let count = libraryStore.playCount(for: track.id)
                            let trailingLabel = showingFavorites ? (count == 1 ? "1 PLAY" : "\(count) PLAYS") : nil

                            TrackRowView(
                                track: track,
                                indexNumber: index + 1,
                                isCurrentTrack: track.id == playerService.currentTrack?.id,
                                isPlaying: playerService.playbackStatus.isPlaying && track.id == playerService.currentTrack?.id,
                                isNextTrack: playerService.nextTrack?.id == track.id,
                                isInPlayNext: playerService.playNextQueue.contains(where: { $0.id == track.id }),
                                isTapToPlayNextEnabled: libraryStore.settings.tapToPlayNext,
                                trailingText: trailingLabel,
                                onPlay: {
                                    playerService.play(track: track, inQueue: displayedArtistTracks, startIndex: index)
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
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
        }
        .navigationDestination(item: $selectedAlbumForNavigation) { album in
            AlbumDetailView(album: album, libraryStore: libraryStore, playerService: playerService)
        }
        .navigationDestination(item: $selectedArtistForNavigation) { artist in
            ArtistDetailView(artist: artist, libraryStore: libraryStore, playerService: playerService)
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ARTIST")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(artist.name)
                .font(.system(size: 24, weight: .bold))

            Text("\(artist.discographySummary) · \(TimeFormatting.formatSummaryDuration(seconds: artist.totalDuration))")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filtered & Sorted Discography Rows

    private var displayedArtistTracks: [Track] {
        if showingFavorites {
            return artist.tracks.sorted { lhs, rhs in
                let pL = libraryStore.playCount(for: lhs.id)
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

    private var ownAlbums: [Album] {
        let joined = libraryStore.settings.joinedArtists
        let list = libraryStore.albums.filter {
            $0.isLeadOrCollaborativeAlbum(for: artist.name, joinedArtists: joined) && !$0.isSingle
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
        let list = libraryStore.albums.filter {
            $0.isLeadOrCollaborativeAlbum(for: artist.name, joinedArtists: joined) && $0.isSingle
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
        let list = libraryStore.albums.filter {
            $0.isFeaturedAlbum(for: artist.name, joinedArtists: joined)
        }
        return list.sorted { lhs, rhs in
            let yL = lhs.resolvedYear ?? 0
            let yR = rhs.resolvedYear ?? 0
            if yL != yR { return yL > yR }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

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

