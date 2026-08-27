//
//  MacCommands.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI

/// Concurrency-safe macOS Menu Bar commands and keyboard shortcuts.
public struct MacPlaybackCommands: Commands {
    public let playerService: AudioPlayerService
    public let libraryStore: LibraryStore
    public let onNewPlaylist: () -> Void
    public let onOpenSettings: () -> Void

    public init(
        playerService: AudioPlayerService,
        libraryStore: LibraryStore,
        onNewPlaylist: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.playerService = playerService
        self.libraryStore = libraryStore
        self.onNewPlaylist = onNewPlaylist
        self.onOpenSettings = onOpenSettings
    }

    public var body: some Commands {
        // MARK: - Playback Menu
        CommandMenu("Playback") {
            Button(playerService.playbackStatus.isPlaying ? "Pause" : "Play") {
                playerService.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Next Track") {
                playerService.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!playerService.hasNextTrack)

            Button("Previous Track") {
                playerService.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!playerService.hasPreviousTrack)

            Divider()

            Button("Volume Up") {
                playerService.increaseVolume()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Volume Down") {
                playerService.decreaseVolume()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button(playerService.isMuted ? "Unmute" : "Mute") {
                playerService.toggleMute()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Button("Toggle Shuffle") {
                playerService.toggleShuffle()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Cycle Repeat Mode") {
                playerService.cycleRepeatMode()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        // MARK: - Library & File Commands
        CommandGroup(replacing: .newItem) {
            Button("New Playlist...") {
                onNewPlaylist()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Library") {
            Button("Rescan Library") {
                Task {
                    await libraryStore.rescanCurrentDirectory()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(libraryStore.isScanning)

            Divider()

            Button("Reveal Current Track in Finder") {
                if let track = playerService.currentTrack {
                    FinderUtility.revealInFinder(url: track.fileURL)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(playerService.currentTrack == nil)
        }
    }
}
