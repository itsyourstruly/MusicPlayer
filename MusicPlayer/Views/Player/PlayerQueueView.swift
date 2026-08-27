import SwiftUI

/// Clean, minimal playback queue view featuring a unified scrollable list of
/// past history, currently playing track, and upcoming songs with tap-and-hold reorder and swipe-to-remove.
public struct PlayerQueueView: View {
    @Bindable var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    // Initialize with configured properties
    public init(playerService: AudioPlayerService) {
        self.playerService = playerService
    }

    private var currentIdx: Int {
        playerService.currentIndex ?? 0
    }

    private var pastTracks: [Track] {
        // Ensure preconditions are met before proceeding
        guard !playerService.queue.isEmpty, currentIdx > 0 else { return [] }
        // End
        let end = min(currentIdx, playerService.queue.count)
        return Array(playerService.queue[0..<end])
    }

    private var upcomingTracks: [(index: Int, track: Track)] {
        // Ensure preconditions are met before proceeding
        guard !playerService.queue.isEmpty else { return [] }
        // Start
        let start = min(currentIdx + 1, playerService.queue.count)
        // Ensure preconditions are met before proceeding
        guard start < playerService.queue.count else { return [] }
        return Array(playerService.queue[start..<playerService.queue.count].enumerated()).map {
            (index: start + $0.offset, track: $0.element)
        }
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                if playerService.queue.isEmpty && playerService.currentTrack == nil {
                    EmptyStateView(
                        title: "QUEUE IS EMPTY",
                        message: "Play tracks from your library to populate the queue."
                    )
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appTheme.backgroundColor.ignoresSafeArea())
                } else {
                    List {
                        // 1. PAST SONGS SECTION (Scroll up to view history)
                        if !pastTracks.isEmpty {
                            Section {
                                ForEach(Array(pastTracks.enumerated()), id: \.element.id) { idx, track in
                                    pastTrackRow(track: track, queueIndex: idx)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                            } header: {
                                Text("PAST SONGS (\(pastTracks.count))")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }

                        // 2. NOW PLAYING SECTION (Top of default visible queue)
                        if let current = playerService.currentTrack {
                            Section {
                                nowPlayingRow(track: current)
                                    .id("now_playing_item")
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            } header: {
                                Text("NOW PLAYING")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(appTheme.accentColor)
                                    .textCase(nil)
                            }
                        }

                        // 3. QUEUE (PLAY NEXT) SECTION (Dedicated sub-queue played before regular queue)
                        if !playerService.playNextQueue.isEmpty {
                            Section {
                                ForEach(Array(playerService.playNextQueue.enumerated()), id: \.element.id) { idx, track in
                                    playNextTrackRow(track: track, index: idx)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button {
                                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                    playerService.removePlayNextItem(at: idx)
                                                }
                                            } label: {
                                                Text("REMOVE")
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(Color.red)
                                            }
                                            .tint(Color.black.opacity(0.88))
                                        }
                                }
                                .onMove { source, destination in
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        playerService.movePlayNextItem(fromOffsets: source, toOffset: destination)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("QUEUE (\(playerService.playNextQueue.count))")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(appTheme.accentColor)
                                        .textCase(nil)

                                    Spacer()

                                    Button(action: {
                                        HapticFeedback.lightImpact()
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            playerService.clearPlayNextQueue()
                                        }
                                    }) {
                                        Text("CLEAR")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.red)
                                    }
                                }
                            }
                        }

                        // 4. UP NEXT SECTION (Tap & hold to reorder, swipe to remove)
                        if !upcomingTracks.isEmpty {
                            Section {
                                ForEach(upcomingTracks, id: \.track.id) { item in
                                    upcomingTrackRow(track: item.track, queueIndex: item.index)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button {
                                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                    playerService.removeQueueItem(at: item.index)
                                                }
                                            } label: {
                                                Text("REMOVE")
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(Color.red)
                                            }
                                            .tint(Color.black.opacity(0.88))
                                        }
                                }
                                .onMove { source, destination in
                                    handleMoveUpcoming(source: source, destination: destination)
                                }
                            } header: {
                                HStack {
                                    Text("UP NEXT (\(upcomingTracks.count))")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)

                                    Spacer()

                                    Button(action: {
                                        HapticFeedback.lightImpact()
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            clearUpcoming()
                                        }
                                    }) {
                                        Text("CLEAR")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.red)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(appTheme.backgroundColor.ignoresSafeArea())
                    // Triggered when view appears
                    .onAppear {
                        // Scroll to Now Playing on appearance so it starts at the top
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("now_playing_item", anchor: .top)
                            }
                        }
                    }
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("QUEUE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Text("DONE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // Now playing row
    private func nowPlayingRow(track: Track) -> some View {
        Button(action: {
            playerService.togglePlayPause()
        }) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: track.artworkKey,
                        title: track.album,
                        subtitle: track.artist,
                        cornerRadius: 6
                    )
                    .frame(width: 44, height: 44)

                    Text(playerService.playbackStatus.isPlaying ? "PLAYING" : "PAUSED")
                        .font(.system(size: 6.5, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1.5)
                        .background(appTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        .offset(x: 2, y: 2)
                        .contentTransition(.opacity)
                        // Smooth UI transition animation
                        .animation(.easeInOut(duration: 0.22), value: playerService.playbackStatus.isPlaying)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(appTheme.accentColor)
                        .lineLimit(1)

                    Text(track.artistAlbumSubtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(appTheme.secondaryBackgroundColor.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // Past track row
    private func pastTrackRow(track: Track, queueIndex: Int) -> some View {
        Button(action: {
            playerService.play(track: track, inQueue: playerService.queue, startIndex: queueIndex)
        }) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 6
                )
                .frame(width: 38, height: 38)
                .opacity(0.55)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Play next track row
    private func playNextTrackRow(track: Track, index: Int) -> some View {
        Button(action: {
            playerService.playFromPlayNext(at: index)
        }) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: track.artworkKey,
                        title: track.album,
                        subtitle: track.artist,
                        cornerRadius: 6
                    )
                    .frame(width: 40, height: 40)

                    if index == 0 {
                        Text("NEXT")
                            .font(.system(size: 6.5, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                            .offset(x: 2, y: 2)
                            .contentTransition(.opacity)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Upcoming track row
    private func upcomingTrackRow(track: Track, queueIndex: Int) -> some View {
        Button(action: {
            playerService.play(track: track, inQueue: playerService.queue, startIndex: queueIndex)
        }) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtworkView(
                        artworkKey: track.artworkKey,
                        title: track.album,
                        subtitle: track.artist,
                        cornerRadius: 6
                    )
                    .frame(width: 40, height: 40)

                    if playerService.playNextQueue.isEmpty && queueIndex == currentIdx + 1 {
                        Text("NEXT")
                            .font(.system(size: 6.5, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                            .offset(x: 2, y: 2)
                            .contentTransition(.opacity)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(TimeFormatting.format(seconds: track.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Handle move upcoming
    private func handleMoveUpcoming(source: IndexSet, destination: Int) {
        // Start
        let start = (playerService.currentIndex ?? 0) + 1
        // Adjusted source
        var adjustedSource = IndexSet()
        for idx in source {
            adjustedSource.insert(start + idx)
        }
        // Adjusted destination
        let adjustedDestination = start + destination
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            playerService.moveQueueItem(fromOffsets: adjustedSource, toOffset: adjustedDestination)
        }
    }

    // Clear upcoming
    private func clearUpcoming() {
        // Ensure preconditions are met before proceeding
        guard !playerService.queue.isEmpty, let current = playerService.currentTrack else { return }
        // Current idx
        let currentIdx = playerService.currentIndex ?? 0
        // Preserved
        let preserved = Array(playerService.queue[0...min(currentIdx, playerService.queue.count - 1)])
        playerService.play(track: current, inQueue: preserved, startIndex: currentIdx)
    }
}
