//
//  MacPlaybackBarView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI
import AVKit

/// Sleek, minimalist desktop playback console adhering to Apple HIG and strict typographic restraint.
public struct MacPlaybackBarView: View {
    public let playerService: AudioPlayerService
    public let libraryStore: LibraryStore
    @Binding var isQueuePresented: Bool
    public let onOpenTrackInfo: () -> Void
    public let onSelectArtist: (String) -> Void
    public let onSelectAlbum: (String, String) -> Void

    @Environment(\.appTheme) private var appTheme
    @State private var isHoveringScrubber: Bool = false
    @State private var isDraggingScrubber: Bool = false
    @State private var dragScrubPosition: Double = 0.0

    public init(
        playerService: AudioPlayerService,
        libraryStore: LibraryStore,
        isQueuePresented: Binding<Bool>,
        onOpenTrackInfo: @escaping () -> Void,
        onSelectArtist: @escaping (String) -> Void,
        onSelectAlbum: @escaping (String, String) -> Void
    ) {
        self.playerService = playerService
        self.libraryStore = libraryStore
        self._isQueuePresented = isQueuePresented
        self.onOpenTrackInfo = onOpenTrackInfo
        self.onSelectArtist = onSelectArtist
        self.onSelectAlbum = onSelectAlbum
    }

    public var body: some View {
        HStack(spacing: 16) {
            // Left: Current Track Info
            leftTrackIdentityView
                .frame(width: 260, alignment: .leading)

            Spacer(minLength: 12)

            // Center: Transport & Scrubber
            centerTransportAndScrubberView
                .frame(maxWidth: 540)

            Spacer(minLength: 12)

            // Right: Volume & Queue
            rightVolumeAndQueueView
                .frame(width: 260, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background(appTheme.secondaryBackgroundColor.opacity(0.95))
        .overlay(
            Rectangle()
                .fill(appTheme.separatorColor.opacity(0.3))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Left Section (Now Playing Details)

    @ViewBuilder
    private var leftTrackIdentityView: some View {
        if let track = playerService.currentTrack {
            HStack(spacing: 10) {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 5
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appTheme.primaryTextColor)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Button(action: { onSelectArtist(track.artist) }) {
                            Text(track.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)

                        if !track.album.isEmpty {
                            Text("•")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)

                            Button(action: { onSelectAlbum(track.album, track.artist) }) {
                                Text(track.album)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 5) {
                        if !track.technicalSummary.isEmpty {
                            Text(track.technicalSummary)
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }

                        Button(action: onOpenTrackInfo) {
                            Text("INFO")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(appTheme.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(appTheme.tertiaryBackgroundColor)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Select a song to start listening")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Center Section (Transport & Progress)

    private var centerTransportAndScrubberView: some View {
        VStack(spacing: 5) {
            // Row 1: Transport Controls
            HStack(spacing: 18) {
                // Shuffle Button
                Button(action: {
                    playerService.toggleShuffle()
                }) {
                    Text("SHUF")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.shuffleMode == .on
                                ? appTheme.accentColor
                                : .secondary
                        )
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            playerService.shuffleMode == .on
                                ? appTheme.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)

                // Previous Button
                Button(action: {
                    playerService.previous()
                }) {
                    Text("PREV")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.hasPreviousTrack
                                ? appTheme.primaryTextColor
                                : .secondary.opacity(0.4)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!playerService.hasPreviousTrack)

                // Play / Pause Button (Clean filled pill)
                Button(action: {
                    playerService.togglePlayPause()
                }) {
                    Text(playerService.playbackStatus.isPlaying ? "PAUSE" : "PLAY")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.appInvertedBackground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(appTheme.accentColor)
                        .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                // Next Button
                Button(action: {
                    playerService.next()
                }) {
                    Text("NEXT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.hasNextTrack
                                ? appTheme.primaryTextColor
                                : .secondary.opacity(0.4)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!playerService.hasNextTrack)

                // Repeat Button
                Button(action: {
                    playerService.cycleRepeatMode()
                }) {
                    Text(repeatButtonLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            playerService.repeatMode != .off
                                ? appTheme.accentColor
                                : .secondary
                        )
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            playerService.repeatMode != .off
                                ? appTheme.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Row 2: Progress Scrubber
            HStack(spacing: 8) {
                // Elapsed Time
                let currentTime = isDraggingScrubber ? dragScrubPosition : playerService.currentTime
                Text(TimeFormatting.formatTime(currentTime))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                // Interactive Progress Slider Bar
                GeometryReader { geometry in
                    let totalDuration = max(playerService.duration, 0.01)
                    let currentProgress = min(max(currentTime / totalDuration, 0.0), 1.0)

                    ZStack(alignment: .leading) {
                        // Track Background
                        Capsule()
                            .fill(appTheme.tertiaryBackgroundColor)
                            .frame(height: isHoveringScrubber || isDraggingScrubber ? 5 : 3)

                        // Played Progress
                        Capsule()
                            .fill(appTheme.accentColor)
                            .frame(
                                width: geometry.size.width * CGFloat(currentProgress),
                                height: isHoveringScrubber || isDraggingScrubber ? 5 : 3
                            )
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHoveringScrubber = hovering
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingScrubber = true
                                let clampedX = min(max(0, value.location.x), geometry.size.width)
                                let progress = Double(clampedX / max(geometry.size.width, 1))
                                dragScrubPosition = progress * totalDuration
                            }
                            .onEnded { value in
                                let clampedX = min(max(0, value.location.x), geometry.size.width)
                                let progress = Double(clampedX / max(geometry.size.width, 1))
                                let targetTime = progress * totalDuration
                                playerService.seek(to: targetTime)
                                isDraggingScrubber = false
                            }
                    )
                }
                .frame(height: 12)

                // Remaining Time
                let remainingTime = max(playerService.duration - currentTime, 0)
                Text("-" + TimeFormatting.formatTime(remainingTime))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .leading)
            }
        }
    }

    private var repeatButtonLabel: String {
        switch playerService.repeatMode {
        case .off: return "REP"
        case .all: return "REP ALL"
        case .one: return "REP 1"
        }
    }

    // MARK: - Right Section (Volume, AirPlay & Queue)

    private var rightVolumeAndQueueView: some View {
        HStack(spacing: 12) {
            // Mute / Volume Button
            Button(action: {
                playerService.toggleMute()
            }) {
                Text(playerService.isMuted ? "MUTED" : "VOL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(playerService.isMuted ? Color.orange : .secondary)
            }
            .buttonStyle(.plain)

            // Minimal Volume Slider
            Slider(
                value: Binding(
                    get: { Double(playerService.volume) },
                    set: { playerService.volume = Float($0) }
                ),
                in: 0...1
            )
            .frame(width: 80)
            .tint(appTheme.accentColor)

            // Native AirPlay Route Picker
            #if os(macOS)
            MacAirPlayRoutePicker()
                .frame(width: 22, height: 22)
            #endif

            // Queue Drawer Toggle Button
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isQueuePresented.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Text("QUEUE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))

                    if !playerService.queue.isEmpty {
                        Text("\(playerService.queue.count)")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                isQueuePresented
                                    ? Color.appInvertedBackground
                                    : appTheme.accentColor
                            )
                            .foregroundStyle(
                                isQueuePresented
                                    ? appTheme.accentColor
                                    : Color.appInvertedBackground
                            )
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(
                    isQueuePresented
                        ? Color.appInvertedBackground
                        : appTheme.primaryTextColor
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isQueuePresented
                        ? appTheme.accentColor
                        : appTheme.tertiaryBackgroundColor
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

#if os(macOS)
/// Native AppKit AVRoutePickerView wrapper for macOS.
struct MacAirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
