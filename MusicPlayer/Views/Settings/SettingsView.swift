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
    // MARK: - Section Info (Appearance)
    public static let themeSection = SettingOptionDetail(
        id: "themeSection",
        title: "THEME",
        description: "Sets the global theme for the app. This changes the background color, and accents."
    )

    public static let capitalization = SettingOptionDetail(
        id: "capitalization",
        title: "CAPITALIZATION",
        description: "When enabled, app-owned UI labels appear in ALL CAPS. When disabled, labels appear in Title Case while preserving acronyms."
    )

    public static let homePageSection = SettingOptionDetail(
        id: "homePageSection",
        title: "HOME PAGE",
        description: "Choose which sections appear on Home and drag to reorder them. New library carousels start off. Empty sections still show their header when enabled."
    )

    public static let defaultLibraryPageSection = SettingOptionDetail(
        id: "defaultLibraryPageSection",
        title: "DEFAULT LIBRARY PAGE",
        description: "Set the default tab for the Library page. While on a different library tab, tapping the Library page goes back to the Default tab. While on the default tab, tapping the Library page again focuses the search bar."
    )

    public static let fullscreenPlayerSection = SettingOptionDetail(
        id: "fullscreenPlayerSection",
        title: "FULLSCREEN PLAYER",
        description: "Sets the background theme of the Fullscreen Player. Solid matches your theme."
    )

    public static let albumPageSection = SettingOptionDetail(
        id: "albumPageSection",
        title: "ALBUM PAGE",
        description: "Sets the background of album pages. The backdrop stays fixed behind the page and does not scroll. Solid matches your theme."
    )

    // MARK: - Section Info (Sources)
    public static let localOrganizationSection = SettingOptionDetail(
        id: "localOrganizationSection",
        title: "LOCAL FOLDER ORGANIZATION",
        description: "This option only affects sources that are available locally on the device and will not affect server sources. Metadata ignores folder heirarchy, instead it scans individual tracks and builds a library based on the metadata available on each track including its Album, and Artist. Folder will use your existing folder heirarchy, whether you store your library by Artist/Album/Track or another method. Option must be saved to apply."
    )

    public static let artistSeparators = SettingOptionDetail(
        id: "artistSeparators",
        title: "ARTIST SEPARATORS",
        description: "Custom literal characters or phrases (such as //) used to separate multiple artists in local tracks. Built-in delimiters and compound artist names are still respected within each chunk."
    )

    public static let storageManagementSection = SettingOptionDetail(
        id: "storageManagementSection",
        title: "APP STORAGE MANAGEMENT",
        description: "Select a Target, check how much its storing, and choose to clear it. "
    )

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
        description: "Choose between organizing by standard ID3 tags or your local folder hierarchy."
    )

    public static let appearance = SettingOptionDetail(
        id: "appearance",
        title: "APPEARANCE",
        description: "Customize the accent colors, default library view, and player display."
    )

    public static let playback = SettingOptionDetail(
        id: "playback",
        title: "PLAYBACK",
        description: "Configure crossfading, queue behavior, and saving playback position."
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

    public static let hideDuplicates = SettingOptionDetail(
        id: "hideDuplicates",
        title: "HIDE DUPLICATES",
        description: "When navigating into an Album, duplicate tracks will automatically be hidden. The highest quality track will remain. These hidden tracks will show up under 'Hidden' under the Sources settings."
    )

    public static let mergeAlbums = SettingOptionDetail(
        id: "mergeAlbums",
        title: "MERGE ALBUMS",
        description: "Album tracks may be split into separated albums under the same name depending on organization. While set to 'Automatically,' when an album is opened, if there is a matching album, it will merge them and combine the tracklist. While set to 'Manually,' opening a duplicated album will display 'Merge Album?' at the bottom to merge. If the 'Merge Album?' pill is dismissed, you can still merge albums by selecting the Music icon and 'Merge'"
    )

    public static let writeMetadataToDisk = SettingOptionDetail(
        id: "writeMetadataToDisk",
        title: "WRITE METADATA TO FILES ON DISK",
        description: "Embeds enriched tags directly into your audio files on disk. If files are stored in iCloud, metadata is kept within the app."
    )

    public static let cacheInAdvance = SettingOptionDetail(
        id: "cacheInAdvance",
        title: "CACHE IN ADVANCE",
        description: "During playback, automatically save the set amount of queued songs to cache. Past songs are offloaded. This will use your cellular connection when not connected to Wi-Fi, regardless of the 'DOWNLOAD OVER CELLULAR' toggle. Caching uses your devices memory, be wary of set amount depending on your file sizes."
    )

    public static let autoDownloadOnPlay = SettingOptionDetail(
        id: "autoDownloadOnPlay",
        title: "AUTO-DOWNLOAD ON PLAY",
        description: "Automatically download songs to your device when they're played."
    )

    public static let downloadOverCellular = SettingOptionDetail(
        id: "downloadOverCellular",
        title: "DOWNLOAD OVER CELLULAR",
        description: "Enables downloading songs using Cellular data. Applies to 'AUTO-DOWNLOAD ON PLAY' and manual downloads."
    )

    public static let linkFolder = SettingOptionDetail(
        id: "linkFolder",
        title: "LINK FOLDER / CHANGE FOLDER",
        description: "Connect the app to the directory containing the local audio files on your device."
    )

    public static let rescanFolder = SettingOptionDetail(
        id: "rescanFolder",
        title: "RESCAN",
        description: "Rescan your local folder for new or modified tracks."
    )

    public static let findTrackTags = SettingOptionDetail(
        id: "findTrackTags",
        title: "FIND TRACK TAGS",
        description: "Lets you perform an in-depth metadata scan on all local tracks in your library, comparing across Apple Music, Deezer, and MusicBrainz. Each found track will be listed, along with its online counterpart, giving you the option to overwrite or add tags such as: Release Year, Artist, Album, Track Number, and Artwork. This will take a while depending on library size."
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
        description: "Replaces the waveform scrubber with a classic progress bar."
    )

    public static let roundedArtwork = SettingOptionDetail(
        id: "roundedArtwork",
        title: "ROUNDED ARTWORK",
        description: "Toggles rounded corners on album artwork across the app."
    )

    public static let playerIcons = SettingOptionDetail(
        id: "playerIcons",
        title: "ICONS",
        description: "Shows icons instead of text for the controls in the full screen player."
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

    public static let offline = SettingOptionDetail(
        id: "offline",
        title: "OFFLINE",
        description: "Only tracks on your device will be shown. While enabled, LAP won't send any requests or play counts to your connected servers."
    )
}

/// Setting option detailed sheet overlay
public struct SettingOptionDetailSheet: View {
    public let detail: SettingOptionDetail
    /// Long texts (ABOUT descriptions) open at medium and can be dragged to full screen.
    public let expandsToFullScreen: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    public init(detail: SettingOptionDetail, expandsToFullScreen: Bool = false) {
        self.detail = detail
        self.expandsToFullScreen = expandsToFullScreen
    }

    public var body: some View {
        // Scrolls only when the text is taller than the sheet (long artist or album descriptions).
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text(AppCapitalization.format(detail.title, enabled: isCaps))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)

                Text(detail.description)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .presentationBackground(appTheme.backgroundColor)
        .presentationDetents(expandsToFullScreen ? [.medium, .large] : [.height(200), .medium])
        .presentationContentInteraction(expandsToFullScreen ? .resizes : .automatic)
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
        let isCaps = libraryStore.settings.isCapitalizationEnabled
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
            .navigationTitle(AppCapitalization.format("SETTINGS", enabled: isCaps))
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.isCapitalizationEnabled, isCaps)
            .sheet(item: $activeDetail) { detail in
                SettingOptionDetailSheet(detail: detail)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
                    .environment(\.isCapitalizationEnabled, isCaps)
            }
            .sheet(isPresented: $showingLogsSheet) {
                SessionLogsSheetView()
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
                    .environment(\.isCapitalizationEnabled, isCaps)
                    .presentationBackground(libraryStore.settings.appTheme.backgroundColor)
            }
        }
    }

    // MARK: - Top Page Navigation Buttons Group
    private var topPageButtonsGroup: some View {
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        return VStack(spacing: 10) {
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
                        title: AppCapitalization.format("APPEARANCE", enabled: isCaps),
                        badge: AppCapitalization.format(libraryStore.settings.appTheme.displayName, enabled: isCaps)
                    )
                }
                .buttonStyle(.plain)

                // Playback Subpage
                NavigationLink(destination: PlaybackSettingsView(libraryStore: libraryStore, playerService: playerService ?? AudioPlayerService())) {
                    topButtonContent(
                        title: AppCapitalization.format("PLAYBACK", enabled: isCaps),
                        badge: AppCapitalization.format(
                            libraryStore.settings.isCrossfadeEnabled
                                ? String(format: "%.1FS FADE", libraryStore.settings.crossfadeDuration)
                                : "STANDARD",
                            enabled: isCaps
                        )
                    )
                }
                .buttonStyle(.plain)
            }

            // 2. Primary Consolidated Folder Card (Below Appearance & Playback)
            NavigationLink(destination: FolderSettingsView(libraryStore: libraryStore)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(AppCapitalization.format("SOURCES", enabled: isCaps))
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.black)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.6))
                    }

                    Text({
                        let names = libraryStore.settings.linkedFolders.map { $0.name }
                            + libraryStore.settings.serverSources.map { $0.serverName }
                        return names.isEmpty ? AppCapitalization.format("NO SOURCES", enabled: isCaps) : names.joined(separator: " - ")
                    }())
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
        let isCaps = libraryStore.settings.isCapitalizationEnabled
        return VStack(alignment: .leading, spacing: 18) {
            // HAPTICS Toggle
            TypographicToggleRow(
                title: AppCapitalization.format("HAPTICS", enabled: isCaps),
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

            // OFFLINE Toggle (only meaningful with a connected server)
            if !libraryStore.settings.serverSources.isEmpty {
                TypographicToggleRow(
                    title: AppCapitalization.format("OFFLINE", enabled: isCaps),
                    isOn: Binding(
                        get: { libraryStore.settings.isOfflineModeEnabled },
                        set: { newValue in
                            libraryStore.settings.isOfflineModeEnabled = newValue
                            libraryStore.saveSettings()
                        }
                    ),
                    onLongPress: {
                        activeDetail = SettingOptionCatalog.offline
                    }
                )
            }

            // Action: Reset Home Shuffle
            if !libraryStore.settings.customShuffleTarget.isAll {
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        libraryStore.settings.customShuffleTarget = .all
                        libraryStore.saveSettings()
                    }
                }) {
                    Text(AppCapitalization.format("RESET HOME SHUFFLE TO ALL", enabled: isCaps))
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        activeDetail = SettingOptionCatalog.resetHomeShuffle
                    } label: {
                        Text(AppCapitalization.format("OPTION INFO", enabled: isCaps))
                    }
                }
            }

            // Info text explaining long press
            HStack {
                Spacer()
                Text(AppCapitalization.format("LONG PRESS OPTIONS FOR MORE INFO", enabled: isCaps))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            showingLogsSheet = true
                        } label: {
                            Text(AppCapitalization.format("SHOW LOGS", enabled: isCaps))
                        }
                    }
                Spacer()
            }
            .padding(.top, 8)
        }
    }
}
