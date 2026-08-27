import SwiftUI

/// Detailed playback configuration view for configuring track crossfade duration,
/// auto-playback transitions, and audio player specification badges.
public struct PlaybackSettingsView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        List {
            // MARK: - Crossfade Section
            Section {
                Toggle(isOn: $libraryStore.settings.isCrossfadeEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CROSSFADE TRACKS")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)

                        Text("Smoothly blend songs as one ends and the next begins.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.isCrossfadeEnabled) { _, _ in
                    HapticFeedback.selectionChanged()
                    libraryStore.saveSettings()
                }

                if libraryStore.settings.isCrossfadeEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("CROSSFADE DURATION")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(String(format: "%.1f SECONDS", libraryStore.settings.crossfadeDuration))
                                .typographicBadge(isHighlighted: true)
                        }

                        Slider(
                            value: $libraryStore.settings.crossfadeDuration,
                            in: 0.0...15.0,
                            step: 0.5
                        ) {
                            Text("Crossfade Duration")
                        } minimumValueLabel: {
                            Text("0s")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("15s")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .tint(Color.blue)
                        // React to state changes
                        .onChange(of: libraryStore.settings.crossfadeDuration) { _, _ in
                            libraryStore.saveSettings()
                        }
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } header: {
                Text("CROSSFADE")
            } footer: {
                Text(libraryStore.settings.isCrossfadeEnabled
                     ? "Transitions will begin \(String(format: "%.1f", libraryStore.settings.crossfadeDuration)) seconds before the current track concludes."
                     : "Crossfade is disabled. Tracks will transition immediately.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // MARK: - Track Selection Section
            Section {
                Toggle(isOn: $libraryStore.settings.playTrackInCurrentQueue) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PLAY TRACKS IN QUEUE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Play tracks within active queue.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.playTrackInCurrentQueue) { _, newValue in
                    HapticFeedback.selectionChanged()
                    if newValue {
                        libraryStore.settings.tapToPlayNext = false
                        playerService.tapToPlayNext = false
                    }
                    libraryStore.saveSettings()
                    playerService.playTrackInCurrentQueue = newValue
                }

                Toggle(isOn: $libraryStore.settings.tapToPlayNext) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TAP TO PLAY NEXT")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Tapping any track will play it next.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.tapToPlayNext) { _, newValue in
                    HapticFeedback.selectionChanged()
                    if newValue {
                        libraryStore.settings.playTrackInCurrentQueue = false
                        playerService.playTrackInCurrentQueue = false
                    }
                    libraryStore.saveSettings()
                    playerService.tapToPlayNext = newValue
                }
            } header: {
                Text("TRACK SELECTION")
            } footer: {
                Text("Configure how you interact with Tracks.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // MARK: - Playback Preferences Section
            Section {
                Toggle(isOn: $libraryStore.settings.autoPlayNext) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AUTO-PLAY NEXT")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Automatically transition to the next queued track.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.autoPlayNext) { _, _ in
                    HapticFeedback.selectionChanged()
                    libraryStore.saveSettings()
                }

                Toggle(isOn: $libraryStore.settings.rememberPlaybackPosition) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("REMEMBER PLAYBACK POSITION")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Save and restore playback timestamps across tracks.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.rememberPlaybackPosition) { _, _ in
                    HapticFeedback.selectionChanged()
                    libraryStore.saveSettings()
                }

                Toggle(isOn: $libraryStore.settings.showAudioSpecsInPlayer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SHOW AUDIO SPECS")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Display codec, sample rate, and bitrate tags in player.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.showAudioSpecsInPlayer) { _, _ in
                    HapticFeedback.selectionChanged()
                    libraryStore.saveSettings()
                }

                Toggle(isOn: $libraryStore.settings.smoothSkippingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SMOOTH SKIPPING")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Fade out the current track and fade in the next when skipping.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)
                // React to state changes
                .onChange(of: libraryStore.settings.smoothSkippingEnabled) { _, newValue in
                    HapticFeedback.selectionChanged()
                    libraryStore.saveSettings()
                    playerService.smoothSkippingEnabled = newValue
                }
            } header: {
                Text("GENERAL PLAYBACK")
            } footer: {
                Text("Configure continuous playback and audio specification tag visibility.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        // Smooth UI transition animation
        .animation(.smooth(duration: 0.25), value: libraryStore.settings.isCrossfadeEnabled)
        .navigationTitle("PLAYBACK")
        .navigationBarTitleDisplayMode(.inline)
        // Triggered when view appears
        .onAppear {
            playerService.playTrackInCurrentQueue = libraryStore.settings.playTrackInCurrentQueue
            playerService.tapToPlayNext = libraryStore.settings.tapToPlayNext
            playerService.smoothSkippingEnabled = libraryStore.settings.smoothSkippingEnabled
        }
    }
}
