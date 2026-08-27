//
//  MacAllTracksView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI

/// Desktop multi-column table view for library tracks with column sorting, hover states, and context actions.
/// Highly optimized with LazyVStack and isolated row views for ultra-smooth 60/120 FPS scrolling across large libraries.
public struct MacAllTracksView: View {
    @Bindable var libraryStore: LibraryStore
    public let playerService: AudioPlayerService
    public let onSelectArtist: (Artist) -> Void
    public let onSelectAlbum: (Album) -> Void
    public let onShowTrackInfo: (Track) -> Void
    public let onAddToPlaylist: (Track) -> Void
    public let onMatchOnline: (Track) -> Void

    @Environment(\.appTheme) private var appTheme

    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        onSelectArtist: @escaping (Artist) -> Void,
        onSelectAlbum: @escaping (Album) -> Void,
        onShowTrackInfo: @escaping (Track) -> Void,
        onAddToPlaylist: @escaping (Track) -> Void,
        onMatchOnline: @escaping (Track) -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.onSelectArtist = onSelectArtist
        self.onSelectAlbum = onSelectAlbum
        self.onShowTrackInfo = onShowTrackInfo
        self.onAddToPlaylist = onAddToPlaylist
        self.onMatchOnline = onMatchOnline
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar: Search & Quick Shuffle
            topToolbarView

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.25))

            // Column Header Bar
            tableHeaderView

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.2))

            // Tracks Table List (Lazily Loaded)
            if libraryStore.filteredTracks.isEmpty {
                emptyStateView
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(libraryStore.filteredTracks) { track in
                            MacTrackTableRowView(
                                track: track,
                                isCurrent: playerService.currentTrack?.id == track.id,
                                isPlaying: playerService.playbackStatus.isPlaying,
                                playCount: libraryStore.playCount(for: track.id),
                                onPlay: {
                                    playerService.play(track: track, inQueue: libraryStore.filteredTracks)
                                },
                                onPlayNext: {
                                    playerService.playNext(track: track)
                                },
                                onEnqueue: {
                                    playerService.enqueue(track: track)
                                },
                                onSelectArtist: {
                                    if let artist = libraryStore.findArtist(name: track.artist) {
                                        onSelectArtist(artist)
                                    }
                                },
                                onSelectAlbum: {
                                    if let album = libraryStore.findAlbum(title: track.album, artist: track.artist) {
                                        onSelectAlbum(album)
                                    }
                                },
                                onShowTrackInfo: { onShowTrackInfo(track) },
                                onAddToPlaylist: { onAddToPlaylist(track) },
                                onMatchOnline: { onMatchOnline(track) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(appTheme.backgroundColor)
    }

    // MARK: - Subviews

    private var topToolbarView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ALL SONGS")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(appTheme.primaryTextColor)

                Text("\(libraryStore.filteredTracks.count) tracks")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Shuffle All Button
            Button(action: {
                var all = libraryStore.filteredTracks
                all.shuffle()
                if let first = all.first {
                    playerService.play(track: first, inQueue: all)
                }
            }) {
                Text("SHUFFLE ALL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.appInvertedBackground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appTheme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(libraryStore.filteredTracks.isEmpty)

            // Search Bar Filter
            HStack(spacing: 6) {
                TextField("Search songs...", text: $libraryStore.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !libraryStore.searchQuery.isEmpty {
                    Button(action: { libraryStore.searchQuery = "" }) {
                        Text("CLEAR")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 200)
            .background(appTheme.tertiaryBackgroundColor.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(appTheme.separatorColor.opacity(0.3), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var tableHeaderView: some View {
        HStack(spacing: 8) {
            // # Column
            Text("#")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            // Artwork spacer
            Color.clear
                .frame(width: 28, height: 1)

            // Title Column (Sortable)
            sortableColumnHeader(title: "TITLE", option: .title)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Artist Column (Sortable)
            sortableColumnHeader(title: "ARTIST", option: .artist)
                .frame(width: 160, alignment: .leading)

            // Album Column (Sortable)
            sortableColumnHeader(title: "ALBUM", option: .album)
                .frame(width: 160, alignment: .leading)

            // Duration Column (Sortable)
            sortableColumnHeader(title: "TIME", option: .duration)
                .frame(width: 52, alignment: .trailing)

            // Plays Column (Sortable)
            sortableColumnHeader(title: "PLAYS", option: .plays)
                .frame(width: 44, alignment: .trailing)

            // Technical Format
            Text("FORMAT")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(appTheme.secondaryBackgroundColor.opacity(0.35))
    }

    private func sortableColumnHeader(title: String, option: TrackSortOption) -> some View {
        let isSelected = libraryStore.trackSortOption == option

        return Button(action: {
            if libraryStore.trackSortOption == option {
                libraryStore.isTrackSortReversed.toggle()
            } else {
                libraryStore.trackSortOption = option
                libraryStore.isTrackSortReversed = false
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 9.5, weight: isSelected ? .heavy : .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? appTheme.accentColor : .secondary)

                if isSelected {
                    Text(libraryStore.isTrackSortReversed ? "▼" : "▲")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(appTheme.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("NO SONGS FOUND")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.primaryTextColor)

            if !libraryStore.searchQuery.isEmpty {
                Text("No tracks match '\(libraryStore.searchQuery)'. Try adjusting your search query.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button("CLEAR SEARCH") {
                    libraryStore.searchQuery = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(appTheme.tertiaryBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Text("Your linked music directory has no audio files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Isolated Row Component for Zero-Lag Scrolling

/// Dedicated lightweight table row view with isolated local hover state.
private struct MacTrackTableRowView: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let playCount: Int
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onEnqueue: () -> Void
    let onSelectArtist: () -> Void
    let onSelectAlbum: () -> Void
    let onShowTrackInfo: () -> Void
    let onAddToPlaylist: () -> Void
    let onMatchOnline: () -> Void

    @Environment(\.appTheme) private var appTheme
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Index or Playing Status
            Group {
                if isCurrent {
                    Text(isPlaying ? "▶" : "❚❚")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appTheme.accentColor)
                } else if let trackNumber = track.trackNumber, trackNumber > 0 {
                    Text("\(trackNumber)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("•")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 28, alignment: .center)

            // Album Artwork
            AlbumArtworkView(
                artworkKey: track.artworkKey,
                title: track.album,
                subtitle: track.artist,
                cornerRadius: 3
            )
            .frame(width: 28, height: 28)

            // Title
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? appTheme.accentColor : appTheme.primaryTextColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Artist
            Button(action: onSelectArtist) {
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(width: 160, alignment: .leading)

            // Album
            Button(action: onSelectAlbum) {
                Text(track.album)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(width: 160, alignment: .leading)

            // Duration
            Text(TimeFormatting.formatTime(track.duration))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            // Plays
            Text(playCount > 0 ? "\(playCount)" : "—")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(playCount > 0 ? appTheme.primaryTextColor : appTheme.secondaryTextColor.opacity(0.4))
                .frame(width: 44, alignment: .trailing)

            // Format Badge
            Text(track.audioFileInfo?.fileExtension.uppercased() ?? "AUDIO")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(appTheme.tertiaryBackgroundColor.opacity(0.8))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isCurrent
                        ? appTheme.accentColor.opacity(0.12)
                        : (isHovered ? appTheme.tertiaryBackgroundColor.opacity(0.5) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.08)) {
                isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            onPlay()
        }
        .contextMenu {
            Button("PLAY") { onPlay() }
            Button("PLAY NEXT") { onPlayNext() }
            Button("ADD TO QUEUE") { onEnqueue() }
            Divider()
            Button("ADD TO PLAYLIST...") { onAddToPlaylist() }
            Button("GET INFO") { onShowTrackInfo() }
            Button("MATCH ONLINE...") { onMatchOnline() }
            Divider()
            Button("REVEAL IN FINDER") {
                FinderUtility.revealInFinder(url: track.fileURL)
            }
        }
    }
}
