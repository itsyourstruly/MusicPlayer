import SwiftUI

/// Minimal, transparent playback configuration view for configuring track crossfade duration,
/// auto-playback transitions, queue behaviors, and audio display preferences with typographic state toggles
/// and long-press explanation sheets.
public struct PlaybackSettingsView: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    @State private var activeDetail: SettingOptionDetail? = nil

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Crossfade
                crossfadeSection

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // Track Selection
                trackSelectionSection

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                // General Playback
                generalPlaybackSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .padding(.bottom, 60)
        }
        .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("PLAYBACK")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            playerService.playTrackInCurrentQueue = libraryStore.settings.playTrackInCurrentQueue
            playerService.tapToPlayNext = libraryStore.settings.tapToPlayNext
            playerService.smoothSkippingEnabled = libraryStore.settings.smoothSkippingEnabled
            playerService.rememberPlaybackPosition = libraryStore.settings.rememberPlaybackPosition
            playerService.rememberPlaybackPositionMinMinutes = libraryStore.settings.rememberPlaybackPositionMinMinutes
        }
        .sheet(item: $activeDetail) { detail in
            SettingOptionDetailSheet(detail: detail)
        }
    }

    // MARK: - Crossfade Section
    private var crossfadeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            TypographicToggleRow(
                title: "CROSSFADE TRACKS",
                isOn: $libraryStore.settings.isCrossfadeEnabled,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.crossfadeTracks }
            )

            if libraryStore.settings.isCrossfadeEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DURATION")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(String(format: "%.1FS", libraryStore.settings.crossfadeDuration))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                    }

                    Slider(
                        value: $libraryStore.settings.crossfadeDuration,
                        in: 0.0...15.0,
                        step: 0.5
                    )
                    .tint(Color.blue)
                    .onChange(of: libraryStore.settings.crossfadeDuration) { _, _ in
                        libraryStore.saveSettings()
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Track Selection Section
    private var trackSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            TypographicToggleRow(
                title: "PLAY TRACKS IN QUEUE",
                isOn: $libraryStore.settings.playTrackInCurrentQueue,
                onToggle: {
                    if libraryStore.settings.playTrackInCurrentQueue {
                        libraryStore.settings.tapToPlayNext = false
                        playerService.tapToPlayNext = false
                    }
                    libraryStore.saveSettings()
                    playerService.playTrackInCurrentQueue = libraryStore.settings.playTrackInCurrentQueue
                },
                onLongPress: { activeDetail = SettingOptionCatalog.playTrackInQueue }
            )

            TypographicToggleRow(
                title: "TAP TO PLAY NEXT",
                isOn: $libraryStore.settings.tapToPlayNext,
                onToggle: {
                    if libraryStore.settings.tapToPlayNext {
                        libraryStore.settings.playTrackInCurrentQueue = false
                        playerService.playTrackInCurrentQueue = false
                    }
                    libraryStore.saveSettings()
                    playerService.tapToPlayNext = libraryStore.settings.tapToPlayNext
                },
                onLongPress: { activeDetail = SettingOptionCatalog.tapToPlayNext }
            )
        }
    }

    // MARK: - General Playback Section
    private var generalPlaybackSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            TypographicToggleRow(
                title: "AUTO-PLAY NEXT",
                isOn: $libraryStore.settings.autoPlayNext,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.autoPlayNext }
            )

            VStack(alignment: .leading, spacing: 12) {
                TypographicToggleRow(
                    title: "REMEMBER PLAYBACK POSITION",
                    isOn: $libraryStore.settings.rememberPlaybackPosition,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            libraryStore.saveSettings()
                            playerService.rememberPlaybackPosition = libraryStore.settings.rememberPlaybackPosition
                        }
                    },
                    onLongPress: { activeDetail = SettingOptionCatalog.rememberPlaybackPosition }
                )

                if libraryStore.settings.rememberPlaybackPosition {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("MIN TRACK LENGTH")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(Int(libraryStore.settings.rememberPlaybackPositionMinMinutes)) MIN")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.blue)
                        }

                        Slider(
                            value: $libraryStore.settings.rememberPlaybackPositionMinMinutes,
                            in: 10.0...60.0,
                            step: 1.0
                        )
                        .tint(Color.blue)
                        .onChange(of: libraryStore.settings.rememberPlaybackPositionMinMinutes) { _, _ in
                            libraryStore.saveSettings()
                            playerService.rememberPlaybackPositionMinMinutes = libraryStore.settings.rememberPlaybackPositionMinMinutes
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }

            TypographicToggleRow(
                title: "SHOW AUDIO SPECS",
                isOn: $libraryStore.settings.showAudioSpecsInPlayer,
                onToggle: { libraryStore.saveSettings() },
                onLongPress: { activeDetail = SettingOptionCatalog.showAudioSpecs }
            )

            TypographicToggleRow(
                title: "SMOOTH SKIPPING",
                isOn: $libraryStore.settings.smoothSkippingEnabled,
                onToggle: {
                    libraryStore.saveSettings()
                    playerService.smoothSkippingEnabled = libraryStore.settings.smoothSkippingEnabled
                },
                onLongPress: { activeDetail = SettingOptionCatalog.smoothSkipping }
            )
        }
    }
}
