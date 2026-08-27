//
//  MacQueueInspectorView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI

/// Slide-out trailing queue inspector panel adhering to Apple HIG, strict typographic restraint,
/// and smooth lazy loading for extensive playback queues.
public struct MacQueueInspectorView: View {
    public let playerService: AudioPlayerService
    public let libraryStore: LibraryStore
    public let onClose: () -> Void

    @Environment(\.appTheme) private var appTheme

    public init(
        playerService: AudioPlayerService,
        libraryStore: LibraryStore,
        onClose: @escaping () -> Void
    ) {
        self.playerService = playerService
        self.libraryStore = libraryStore
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.25))

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Now Playing Card
                    if let track = playerService.currentTrack {
                        nowPlayingSection(track: track)
                    }

                    // Up Next Section
                    upNextSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 250, idealWidth: 270, maxWidth: 320)
        .background(appTheme.secondaryBackgroundColor.opacity(0.5))
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("PLAYBACK QUEUE")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(appTheme.primaryTextColor)

            Spacer()

            if !playerService.queue.isEmpty {
                Button(action: {
                    playerService.clearQueue()
                }) {
                    Text("CLEAR")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(appTheme.tertiaryBackgroundColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Text("CLOSE")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(appTheme.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func nowPlayingSection(track: Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOW PLAYING")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(appTheme.accentColor)

            HStack(spacing: 8) {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 4
                )
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(appTheme.primaryTextColor)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !track.technicalSummary.isEmpty {
                        Text(track.technicalSummary)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appTheme.secondaryBackgroundColor.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(appTheme.separatorColor.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("UP NEXT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Spacer()

                let totalQueueDuration = playerService.queue.reduce(0.0) { $0 + $1.duration }
                Text("\(playerService.queue.count) • \(TimeFormatting.formatTime(totalQueueDuration))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if playerService.queue.isEmpty {
                Text("Queue is empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(playerService.queue.enumerated()), id: \.element.id) { index, track in
                        MacQueueRowView(
                            index: index + 1,
                            track: track,
                            onPlay: { playerService.playTrackInQueue(at: index) },
                            onRemove: { playerService.removeFromQueue(at: index) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Isolated Queue Row View

private struct MacQueueRowView: View {
    let index: Int
    let track: Track
    let onPlay: () -> Void
    let onRemove: () -> Void

    @Environment(\.appTheme) private var appTheme
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .center)

            AlbumArtworkView(
                artworkKey: track.artworkKey,
                title: track.album,
                subtitle: track.artist,
                cornerRadius: 3
            )
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appTheme.primaryTextColor)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TimeFormatting.formatTime(track.duration))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Remove Button
            Button(action: onRemove) {
                Text("×")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(appTheme.tertiaryBackgroundColor.opacity(0.8))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? appTheme.tertiaryBackgroundColor.opacity(0.55) : Color.clear)
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
            Button("PLAY NOW") {
                onPlay()
            }
            Button("REMOVE FROM QUEUE") {
                onRemove()
            }
            Divider()
            Button("REVEAL IN FINDER") {
                FinderUtility.revealInFinder(url: track.fileURL)
            }
        }
    }
}
