import SwiftUI
import UniformTypeIdentifiers
import os

/// Information model describing what a setting does.
public struct SettingOptionDetail: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String

    public init(
        id: String,
        title: String,
        description: String
    ) {
        self.id = id
        self.title = title
        self.description = description
    }
}

/// Catalog of concise explanations for every setting option across the app.
public enum SettingOptionCatalog {
    public static let folderSettings = SettingOptionDetail(
        id: "folderSettings",
        title: "FOLDER SETTINGS & ORGANIZATION",
        description: "Manage your music directory linking, disk rescanning, and duplicate detection. Switch scan modes between ID3 tags and folder hierarchy."
    )

    public static let metadataEnrichment = SettingOptionDetail(
        id: "metadataEnrichment",
        title: "METADATA ENRICHMENT",
        description: "Enriches local tracks with verified online metadata, artwork, and lyrics."
    )

    public static let libraryScanMethod = SettingOptionDetail(
        id: "libraryScanMethod",
        title: "LIBRARY SCAN METHOD",
        description: "Choose between organizing by standard ID3 tags or your hard drive folder hierarchy."
    )

    public static let appearance = SettingOptionDetail(
        id: "appearance",
        title: "APPEARANCE",
        description: "Customize the app theme, accent colors, default library view, and player display styles."
    )

    public static let playback = SettingOptionDetail(
        id: "playback",
        title: "PLAYBACK",
        description: "Configure crossfading, skipping transitions, and queue behaviors."
    )

    public static let enrichTracks = SettingOptionDetail(
        id: "enrichTracks",
        title: "TRACKS FOUND",
        description: "Identifies local songs with missing tags or low-res artwork and matches them with official online records."
    )

    public static let verifiedTracks = SettingOptionDetail(
        id: "verifiedTracks",
        title: "TRACKS GOOD",
        description: "Lists songs whose local tags already match official online databases."
    )

    public static let unmatchedTracks = SettingOptionDetail(
        id: "unmatchedTracks",
        title: "UNMATCHED TRACKS",
        description: "Protects unique songs and live recordings from incorrect auto-tags until manually searched."
    )

    public static let duplicateTracks = SettingOptionDetail(
        id: "duplicateTracks",
        title: "DUPLICATE TRACKS",
        description: "Finds repetitive copies of the same song in your linked folder to free up storage space."
    )

    public static let autoHideDuplicates = SettingOptionDetail(
        id: "autoHideDuplicates",
        title: "AUTO-HIDE LOWER QUALITY DUPLICATES",
        description: "Keeps only the highest-quality version visible in search and lists without deleting files."
    )

    public static let writeMetadataToDisk = SettingOptionDetail(
        id: "writeMetadataToDisk",
        title: "WRITE METADATA TO FILES ON DISK",
        description: "Embeds enriched tags directly into your audio files on disk. If files are stored in iCloud, metadata is kept within the app."
    )

    public static let linkFolder = SettingOptionDetail(
        id: "linkFolder",
        title: "LINK FOLDER / CHANGE FOLDER",
        description: "Connects the app to your offline audio files on your device."
    )

    public static let rescanFolder = SettingOptionDetail(
        id: "rescanFolder",
        title: "RESCAN",
        description: "Rescan your local folder for new or modified tracks."
    )

    public static let findTrackTags = SettingOptionDetail(
        id: "findTrackTags",
        title: "FIND TRACK TAGS",
        description: "Opens a sheet which lets you perform an in-depth metadata scan on all the tracks in your library, it will take a while depending on library size."
    )

    public static let scanDuplicates = SettingOptionDetail(
        id: "scanDuplicates",
        title: "SCAN ALL FOR DUPLICATES",
        description: "Scans all songs in your library to detect identical tracks and calculate recoverable storage."
    )

    public static let unlinkFolder = SettingOptionDetail(
        id: "unlinkFolder",
        title: "UNLINK FOLDER",
        description: "Removes indexed tracks and resets your app library without modifying your files on disk."
    )

    public static let rescanAllMetadata = SettingOptionDetail(
        id: "rescanAllMetadata",
        title: "RESCAN ALL METADATA",
        description: "Queries Apple Music and Deezer for all your songs from scratch."
    )

    public static let resetHomeShuffle = SettingOptionDetail(
        id: "resetHomeShuffle",
        title: "RESET HOME SHUFFLE TO ALL",
        description: "Resets the quick-shuffle trigger on Home to play songs from your entire library."
    )

    public static let clearArtworkCache = SettingOptionDetail(
        id: "clearArtworkCache",
        title: "CLEAR ARTWORK CACHE",
        description: "Clears cached cover artwork from disk to reclaim local storage space."
    )

    public static let crossfadeTracks = SettingOptionDetail(
        id: "crossfadeTracks",
        title: "CROSSFADE",
        description: "At the end of a track, it will fade in the next track while fading out the current track across the set duration. Example: Track length is 1:00, if the crossfade is set to 5 seconds, it will begin crossfade at 0:55."
    )

    public static let crossfadeDuration = SettingOptionDetail(
        id: "crossfadeDuration",
        title: "CROSSFADE DURATION",
        description: "Sets how many seconds songs should overlap during crossfade (0.5s to 15s)."
    )

    public static let playTrackInQueue = SettingOptionDetail(
        id: "playTrackInQueue",
        title: "KEEP QUEUE WHEN PLAYING TRACK",
        description: "When your queue is empty, playing a track will fill your queue based on context. If you have any items in your Queue, or up next, playing a track via searching or your library will keep your queue in tact."
    )

    public static let tapToPlayNext = SettingOptionDetail(
        id: "tapToPlayNext",
        title: "TAP TO PLAY NEXT",
        description: "When toggled to on, tapping a song will not start playback. Instead, it will be added to the queue after the current track. While on, you can swipe right on a track to play now."
    )

    public static let autoPlayNext = SettingOptionDetail(
        id: "autoPlayNext",
        title: "AUTO-PLAY NEXT",
        description: "Automatically advances to the next song in the queue or album when a track finishes."
    )

    public static let rememberPlaybackPosition = SettingOptionDetail(
        id: "rememberPlaybackPosition",
        title: "SAVE PLAYBACK POSITION (LONG TRACKS)",
        description: "Save your playback position of tracks longer than or equal to your set duration. Any track shorter than the set duration will be played normally."
    )

    public static let showAudioSpecs = SettingOptionDetail(
        id: "showAudioSpecs",
        title: "SHOW AUDIO SPECS",
        description: "Displays sample rate, bit depth, bitrate, and codec badges in the player."
    )

    public static let useProgressBar = SettingOptionDetail(
        id: "useProgressBar",
        title: "USE PROGRESS BAR",
        description: "Replaces the circular scrubber with a continuous progress bar in the fullscreen player."
    )

    public static let roundedArtwork = SettingOptionDetail(
        id: "roundedArtwork",
        title: "ROUNDED ARTWORK",
        description: "Toggles rounded corners on album artwork in the player. When disabled, artwork is displayed as a sharp square."
    )

    public static let smoothSkipping = SettingOptionDetail(
        id: "smoothSkipping",
        title: "TRANSITION TRACKS WHEN SKIPPING",
        description: "Separate from crossfade, this will transition tracks smoothly when skipping by first fading in the next track, then fading out the current track. It will also toggle audio fading in/out when playing/pausing."
    )

    public static let haptics = SettingOptionDetail(
        id: "haptics",
        title: "HAPTICS",
        description: "Enables haptic feedback on actions throughout the app."
    )
}

/// Setting option detailed sheet overlay
public struct SettingOptionDetailSheet: View {
    public let detail: SettingOptionDetail
    @Environment(\.dismiss) private var dismiss

    public init(detail: SettingOptionDetail) {
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(detail.title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text(detail.description)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground.ignoresSafeArea())
        .presentationDetents([.height(200), .medium])
        .presentationDragIndicator(.visible)
    }
}

/// Settings and preferences control panel.
public struct SettingsView: View {
    @Bindable var libraryStore: LibraryStore
    public var playerService: AudioPlayerService?

    @Environment(\.dismiss) private var dismiss
    @State private var activeDetail: SettingOptionDetail? = nil
    @State private var showingLogsSheet: Bool = false

    public init(libraryStore: LibraryStore, playerService: AudioPlayerService? = nil) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // MARK: - Consolidated Top Group (Primary Folder Card & Subpages)
                    topPageButtonsGroup

                    Divider()
                        .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

                    // MARK: - Main Inline Controls
                    inlineControlsGroup
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .padding(.bottom, 60)
            }
            .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $activeDetail) { detail in
                SettingOptionDetailSheet(detail: detail)
            }
            .sheet(isPresented: $showingLogsSheet) {
                SessionLogsSheetView()
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
        }
    }

    // MARK: - Top Page Navigation Buttons Group
    private var topPageButtonsGroup: some View {
        VStack(spacing: 10) {
            // 1. Navigation Subpages Grid (Appearance & Playback)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                // Appearance Subpage
                NavigationLink(destination: AppearanceSettingsView(libraryStore: libraryStore)) {
                    topButtonContent(
                        title: "APPEARANCE",
                        badge: libraryStore.settings.appTheme.displayName
                    )
                }
                .buttonStyle(.plain)

                // Playback Subpage
                NavigationLink(destination: PlaybackSettingsView(libraryStore: libraryStore, playerService: playerService ?? AudioPlayerService())) {
                    topButtonContent(
                        title: "PLAYBACK",
                        badge: libraryStore.settings.isCrossfadeEnabled
                            ? String(format: "%.1FS FADE", libraryStore.settings.crossfadeDuration)
                            : "STANDARD"
                    )
                }
                .buttonStyle(.plain)
            }

            // 2. Primary Consolidated Folder Card (Below Appearance & Playback)
            NavigationLink(destination: FolderSettingsView(libraryStore: libraryStore)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("FOLDER")
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.black)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.6))
                    }

                    Text(libraryStore.settings.linkedFolderName ?? "NO FOLDER LINKED")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func topButtonContent(title: String, badge: String? = nil, isMuted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(isMuted ? Color.black.opacity(0.3) : Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let badge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isMuted ? Color.black.opacity(0.25) : Color.black.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Inline Controls Group
    private var inlineControlsGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            // HAPTICS Toggle
            TypographicToggleRow(
                title: "HAPTICS",
                isOn: Binding(
                    get: { libraryStore.settings.isHapticsEnabled },
                    set: { newValue in
                        libraryStore.settings.isHapticsEnabled = newValue
                        HapticManager.shared.isEnabled = newValue
                        if newValue {
                            HapticFeedback.toggle(isOn: true)
                        }
                        libraryStore.saveSettings()
                    }
                ),
                onLongPress: {
                    activeDetail = SettingOptionCatalog.haptics
                }
            )

            // Action: Reset Home Shuffle
            if !libraryStore.settings.customShuffleTarget.isAll {
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        libraryStore.settings.customShuffleTarget = .all
                        libraryStore.saveSettings()
                    }
                }) {
                    Text("RESET HOME SHUFFLE TO ALL")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.resetHomeShuffle
                    }
                }
            }

            // Info text explaining long press
            HStack {
                Spacer()
                Text("Long press options for more info")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            showingLogsSheet = true
                        } label: {
                            Text("show logs. for debugging use.")
                        }
                    }
                Spacer()
            }
            .padding(.top, 8)
        }
    }
}
