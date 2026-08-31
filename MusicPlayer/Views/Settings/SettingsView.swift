import SwiftUI
import UniformTypeIdentifiers
import os

/// Information model describing what a setting does and how to use it in simple terms.
public struct SettingOptionDetail: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let whatItDoes: String
    public let howToUseIt: String

    public init(
        id: String,
        title: String,
        whatItDoes: String,
        howToUseIt: String
    ) {
        self.id = id
        self.title = title
        self.whatItDoes = whatItDoes
        self.howToUseIt = howToUseIt
    }
}

/// Catalog of comprehensive, concise explanations for every setting option across the app.
public enum SettingOptionCatalog {
    public static let appearance = SettingOptionDetail(
        id: "appearance",
        title: "APPEARANCE",
        whatItDoes: "• CHANGES THE OVERALL VISUAL THEME AND ACCENT COLORS ACROSS THE APP.\n• LETS YOU PICK WHICH CATEGORY (ARTISTS, ALBUMS, PLAYLISTS) OPENS FIRST IN LIBRARY.\n• CUSTOMIZES HOW THE MINI AND FULLSCREEN PLAYERS RENDER BACKGROUNDS.",
        howToUseIt: "1. TAP TO OPEN THE APPEARANCE MENU.\n2. TAP ANY THEME OR PLAYER STYLE TO APPLY IT INSTANTLY."
    )

    public static let playback = SettingOptionDetail(
        id: "playback",
        title: "PLAYBACK",
        whatItDoes: "• CONTROLS SMOOTH CROSSFADING AND OVERLAPPING TRANSITIONS BETWEEN SONGS.\n• SETS HOW THE PLAYBACK QUEUE BEHAVES WHEN YOU TAP SONGS IN LISTS.\n• TOGGLES AUDIOPHILE TECHNICAL AUDIO SPEC BADGES IN THE PLAYER.",
        howToUseIt: "1. TAP TO OPEN PLAYBACK SETTINGS.\n2. TOGGLE CROSSFADE ON OR OFF, AND DRAG THE SLIDER TO SET FADE SECONDS.\n3. CHOOSE WHETHER TAPPING A SONG PLAYS IN YOUR QUEUE OR PLAYS NEXT."
    )

    public static let enrichTracks = SettingOptionDetail(
        id: "enrichTracks",
        title: "TRACKS READY TO ENRICH",
        whatItDoes: "• IDENTIFIES LOCAL SONGS WITH MISSING TAGS, LOW-RES ARTWORK, OR INCOMPLETE METADATA.\n• MATCHES THEM WITH OFFICIAL ONLINE RECORDS AND HIGHLIGHTS UPGRADES IN GREEN.\n• LETS YOU LOCK SPECIFIC LOCAL TAGS WITH [KEEP LOCAL] SO THEY ARE NOT OVERWRITTEN.",
        howToUseIt: "1. TAP TO OPEN THE ENRICHMENT MENU.\n2. SWIPE ON ANY TRACK TO COMPARE ONLINE DATA WITH YOUR ORIGINAL TAGS.\n3. TAP 'APPLY ONLINE METADATA' FOR A SINGLE TRACK, OR 'ENRICH ALL' TO BATCH UPDATE."
    )

    public static let verifiedTracks = SettingOptionDetail(
        id: "verifiedTracks",
        title: "TRACKS LOOK GOOD",
        whatItDoes: "• LISTS SONGS WHOSE LOCAL TAGS ALREADY MATCH OFFICIAL ONLINE DATABASES.\n• KEEPS TRACK OF COMPLETE ALBUMS AND EMBEDDED HIGH-RES COVER ART.\n• ALLOWS RE-EMBEDDING OFFICIAL TAGS OR RESCANNING AT ANY TIME.",
        howToUseIt: "1. TAP TO VIEW VERIFIED SONGS.\n2. SWIPE TO REVIEW THE ONLINE MATCH AGAINST YOUR ORIGINAL LOCAL TAGS.\n3. TAP 'RE-APPLY TAGS & ART' TO RE-DOWNLOAD ARTWORK, OR 'RESCAN' TO RE-CHECK."
    )

    public static let unmatchedTracks = SettingOptionDetail(
        id: "unmatchedTracks",
        title: "UNMATCHED TRACKS",
        whatItDoes: "• PROTECTS UNIQUE SONGS, LIVE RECORDINGS, AND BOOTLEGS FROM WRONG AUTO-TAGS.\n• KEEPS UNMATCHED AUDIO FILES ISOLATED UNTIL YOU MANUALLY SEARCH OR RE-CHECK.\n• LETS YOU SEARCH ONLINE CATALOGS MANUALLY TO FIND EXACT RELEASES.",
        howToUseIt: "1. TAP TO VIEW UNMATCHED TRACKS.\n2. TAP 'RE-CHECK' TO SEARCH ONLINE DATABASES AGAIN.\n3. TAP 'CUSTOM SEARCH' TO SEARCH BY A SPECIFIC SONG OR ALBUM NAME."
    )

    public static let duplicateTracks = SettingOptionDetail(
        id: "duplicateTracks",
        title: "DUPLICATE TRACKS",
        whatItDoes: "• FINDS REPETITIVE COPIES OF THE SAME SONG IN YOUR LINKED FOLDER.\n• COMPARES BITRATE, SAMPLE RATE, AND FILE SIZE TO HIGHLIGHT THE BEST QUALITY VERSION.\n• FREES UP STORAGE SPACE BY SAFELY MOVING REDUNDANT FILES TO TRASH.",
        howToUseIt: "1. TAP TO OPEN THE DUPLICATE MANAGER.\n2. REVIEW DETECTED DUPLICATE GROUPS SIDE-BY-SIDE.\n3. PICK YOUR PREFERRED HIGH-QUALITY VERSION TO KEEP, OR TAP 'DELETE FROM DISK' ON REDUNDANT COPIES."
    )

    public static let autoHideDuplicates = SettingOptionDetail(
        id: "autoHideDuplicates",
        title: "AUTO-HIDE LOWER QUALITY DUPLICATES",
        whatItDoes: "• CLEANS UP YOUR LIBRARY BY HIDING REDUNDANT COPIES OF SONGS AUTOMATICALLY.\n• KEEPS ONLY THE HIGHEST-QUALITY VERSION VISIBLE IN SEARCH AND LISTS.\n• DOES NOT DELETE ANY FILES FROM YOUR DISK.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED).\n2. WHEN ON, DUPLICATE CLUTTER IS HIDDEN AUTOMATICALLY."
    )

    public static let writeMetadataToDisk = SettingOptionDetail(
        id: "writeMetadataToDisk",
        title: "WRITE METADATA TO FILES ON DISK",
        whatItDoes: "• EMBEDS ENRICHED TAGS (TITLE, ARTIST, ALBUM, ARTWORK) DIRECTLY INTO YOUR AUDIO FILES.\n• ALLOWS OTHER MUSIC PLAYERS AND APPS TO READ YOUR UPGRADED TAGS AND ARTWORK.\n• DOES NOT RE-ENCODE AUDIO SO QUALITY REMAINS 100% LOSSLESS.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) BEFORE ENRICHING TRACKS.\n2. WHEN YOU APPLY ONLINE METADATA, TAGS ARE PERMANENTLY SAVED TO YOUR AUDIO FILES ON DISK."
    )

    public static let linkFolder = SettingOptionDetail(
        id: "linkFolder",
        title: "LINK FOLDER / CHANGE FOLDER",
        whatItDoes: "• CONNECTS THE APP TO YOUR OFFLINE AUDIO FILES (MP3, FLAC, AAC, WAV, ALAC).\n• BUILDS YOUR LOCAL MUSIC LIBRARY WITH ZERO CLOUD SUBSCRIPTION REQUIRED.\n• REMEMBERS ACCESS PERMISSIONS SAFELY AND PRIVATELY ON YOUR DEVICE.",
        howToUseIt: "1. TAP 'LINK FOLDER' (OR 'CHANGE FOLDER').\n2. SELECT THE FOLDER ON YOUR DEVICE OR ICLOUD WHERE YOUR MUSIC IS STORED.\n3. THE APP WILL IMMEDIATELY SCAN AND ORGANIZE YOUR SONGS."
    )

    public static let rescanFolder = SettingOptionDetail(
        id: "rescanFolder",
        title: "RESCAN FOLDER",
        whatItDoes: "• CHECKS YOUR MUSIC FOLDER FOR NEWLY ADDED SONGS, MODIFIED TAGS, OR DELETED FILES.\n• REFRESHES YOUR ARTISTS, ALBUMS, AND PLAYLISTS IN SECONDS.",
        howToUseIt: "1. TAP 'RESCAN' WHENEVER YOU ADD NEW MUSIC FILES TO YOUR LINKED FOLDER.\n2. WATCH THE LIVE INDEXING LOG SHOW SCAN PROGRESS UNTIL FINISHED."
    )

    public static let scanDuplicates = SettingOptionDetail(
        id: "scanDuplicates",
        title: "SCAN ALL FOR DUPLICATES",
        whatItDoes: "• SCANS ALL SONGS IN YOUR LIBRARY TO DETECT IDENTICAL TRACKS.\n• CALCULATES RECOVERABLE DISK STORAGE IN MEGABYTES/GIGABYTES.",
        howToUseIt: "1. TAP 'SCAN ALL FOR DUPLICATES'.\n2. THE APP WILL ANALYZE ALL TRACKS IN YOUR LIBRARY.\n3. WHEN DUPLICATES ARE FOUND, A 'DUPLICATES' BUTTON APPEARS AT THE TOP."
    )

    public static let unlinkFolder = SettingOptionDetail(
        id: "unlinkFolder",
        title: "UNLINK FOLDER",
        whatItDoes: "• REMOVES INDEXED TRACKS AND RESETS YOUR APP LIBRARY.\n• YOUR ACTUAL AUDIO FILES ON DISK ARE NEVER DELETED OR MODIFIED.",
        howToUseIt: "1. TAP 'UNLINK' IN RED.\n2. CONFIRM THE PROMPT TO SAFELY DISCONNECT THE FOLDER."
    )

    public static let rescanAllMetadata = SettingOptionDetail(
        id: "rescanAllMetadata",
        title: "RESCAN ALL METADATA",
        whatItDoes: "• QUERIES APPLE MUSIC AND DEEZER FOR ALL YOUR SONGS FROM SCRATCH.\n• FINDS NEW HIGH-RES ALBUM COVERS AND MISSING SONG DETAILS.",
        howToUseIt: "1. TAP 'RESCAN ALL METADATA'.\n2. THE APP WILL CHECK ONLINE CATALOGS FOR EVERY TRACK IN THE BACKGROUND.\n3. TAP 'CANCEL' ANYTIME TO STOP THE SCAN."
    )

    public static let resetHomeShuffle = SettingOptionDetail(
        id: "resetHomeShuffle",
        title: "RESET HOME SHUFFLE TO ALL",
        whatItDoes: "• RESETS THE ONE-TAP SHUFFLE TRIGGER ON HOME TO PLAY SONGS FROM YOUR ENTIRE LIBRARY INSTEAD OF A PINNED ITEM.",
        howToUseIt: "1. TAP TO RESET YOUR HOME SCREEN QUICK-SHUFFLE BUTTON BACK TO FULL-LIBRARY SHUFFLE."
    )

    public static let clearArtworkCache = SettingOptionDetail(
        id: "clearArtworkCache",
        title: "CLEAR METADATA & ARTWORK CACHE",
        whatItDoes: "• CLEARS DOWNLOADED ONLINE METADATA AND HIGH-RESOLUTION CACHED ARTWORK.\n• RECLAIMS LOCAL DISK STORAGE SPACE.\n• NEVER DELETES YOUR AUDIO FILES ON DISK.",
        howToUseIt: "1. TAP 'CLEAR METADATA & ARTWORK CACHE' IN RED.\n2. CONFIRM THE PROMPT TO REMOVE CACHED METADATA AND COVER ART."
    )

    public static let systemArchitecture = SettingOptionDetail(
        id: "systemArchitecture",
        title: "SYSTEM ARCHITECTURE",
        whatItDoes: "• RUNS 100% OFFLINE AND ON-DEVICE USING SWIFT 6 CONCURRENCY AND AVFOUNDATION.\n• ZERO TELEMETRY, ZERO ANALYTICS, ZERO CLOUD TRACKING.",
        howToUseIt: "1. LONG-PRESS OR TAP TO VIEW TECHNICAL OFFLINE ENGINE DETAILS."
    )

    public static let crossfadeTracks = SettingOptionDetail(
        id: "crossfadeTracks",
        title: "CROSSFADE TRACKS",
        whatItDoes: "• SMOOTHLY FADES OUT THE CURRENT SONG WHILE FADING IN THE NEXT SONG.\n• REMOVES AWKWARD SILENCE BETWEEN TRACKS FOR CONTINUOUS MUSIC FLOW.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED).\n2. USE THE DURATION SLIDER BELOW TO CHOOSE FADE SECONDS (0.5S TO 15.0S)."
    )

    public static let crossfadeDuration = SettingOptionDetail(
        id: "crossfadeDuration",
        title: "CROSSFADE DURATION",
        whatItDoes: "• DETERMINES THE EXACT TIMING AND VOLUME CURVE FOR SMOOTH SONG TRANSITIONS.",
        howToUseIt: "1. DRAG THE SLIDER TO SET HOW MANY SECONDS SONGS SHOULD OVERLAP (0.5S TO 15S)."
    )

    public static let playTrackInQueue = SettingOptionDetail(
        id: "playTrackInQueue",
        title: "PLAY TRACKS IN QUEUE",
        whatItDoes: "• WHEN ON: TAPPING A SONG PLAYS IT WITHIN YOUR CURRENT QUEUE WITHOUT CLEARING YOUR QUEUE LIST.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )

    public static let tapToPlayNext = SettingOptionDetail(
        id: "tapToPlayNext",
        title: "TAP TO PLAY NEXT",
        whatItDoes: "• WHEN ON: TAPPING ANY SONG ADDS IT RIGHT AFTER THE CURRENTLY PLAYING TRACK INSTEAD OF INTERRUPTING PLAYBACK.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )

    public static let autoPlayNext = SettingOptionDetail(
        id: "autoPlayNext",
        title: "AUTO-PLAY NEXT",
        whatItDoes: "• WHEN ON: AUTOMATICALLY ADVANCES TO THE NEXT SONG WHEN THE CURRENT TRACK FINISHES.\n• WHEN OFF: PAUSES AT THE END OF EACH TRACK.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )

    public static let rememberPlaybackPosition = SettingOptionDetail(
        id: "rememberPlaybackPosition",
        title: "REMEMBER PLAYBACK POSITION",
        whatItDoes: "• REMEMBERS EXACTLY WHERE YOU STOPPED IN LONG TRACKS, PODCASTS, OR DJ SETS.\n• EXPANDS TO LET YOU SET THE MINIMUM TRACK DURATION (10 TO 60 MINUTES) TO REMEMBER.\n• RESUMES FROM YOUR LAST POSITION ANYTIME YOU RETURN TO A TRACK.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED).\n2. DRAG THE SLIDER TO SET THE MINIMUM TRACK LENGTH (10 TO 60 MIN)."
    )

    public static let showAudioSpecs = SettingOptionDetail(
        id: "showAudioSpecs",
        title: "SHOW AUDIO SPECS",
        whatItDoes: "• SHOWS AUDIOPHILE BADGES (FLAC 24-BIT 96KHZ, MP3 320KBPS, ETC.) DIRECTLY IN THE PLAYER INTERFACE.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )

    public static let smoothSkipping = SettingOptionDetail(
        id: "smoothSkipping",
        title: "SMOOTH SKIPPING",
        whatItDoes: "• APPLIES A QUICK MICRO-FADE (60MS) WHEN SKIPPING SONGS TO PREVENT LOUD AUDIO CLICKS OR POPS.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )
}

/// Minimal, clean modal sheet displaying simple, broken-down explanations of how to use a setting
/// followed by what it does.
public struct SettingOptionDetailSheet: View {
    public let detail: SettingOptionDetail
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    public init(detail: SettingOptionDetail) {
        self.detail = detail
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Title Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("SETTING INFO")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)

                    Text(detail.title)
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .padding(.top, 8)

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.4))

                // Section 1: HOW TO USE IT (Placed on top!)
                explanationSection(
                    title: "HOW TO USE IT",
                    content: detail.howToUseIt
                )

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.3))

                // Section 2: WHAT IT DOES (Placed below!)
                explanationSection(
                    title: "WHAT IT DOES",
                    content: detail.whatItDoes
                )
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .padding(.bottom, 30)
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func explanationSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.blue)
                .tracking(1.0)

            Text(content)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineSpacing(4)
        }
    }
}

/// Redesigned minimal settings view featuring top white navigation buttons for page/sheet options,
/// clean inline toggles and actions without section headers or subtitles, and long-press explanation sheets.
public struct SettingsView: View {
    @Bindable var libraryStore: LibraryStore
    var playerService: AudioPlayerService?
    @Environment(\.dismiss) private var dismiss

    @State private var showingFolderPicker: Bool = false
    @State private var showingUnlinkAlert: Bool = false
    @State private var showingDuplicateResolver: Bool = false
    @State private var showingMetadataComparison: Bool = false
    @State private var showingVerifiedGoodTracks: Bool = false
    @State private var showingUnmatchedTracks: Bool = false
    @State private var artworkCacheSizeBytes: Int64 = 0
    @State private var activeDetail: SettingOptionDetail? = nil
    @State private var isScanningDuplicates: Bool = false
    @State private var showingClearCacheAlert: Bool = false

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService? = nil) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // MARK: - Top Page & Sheet Navigation Buttons (White Background, Black Text)
                    topPageButtonsGroup

                    if libraryStore.isBackgroundCheckingMetadata {
                        HStack {
                            Spacer()
                            Text("\(libraryStore.backgroundCheckScannedCount) of \(libraryStore.backgroundCheckTotalCount)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.blue)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .transition(.opacity)
                    }

                    Divider()
                        .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))
                        .padding(.vertical, 6)

                    // MARK: - Inline Toggles & Actions
                    inlineControlsGroup
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .padding(.bottom, 60)
            }
            .background(libraryStore.settings.appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder, .audio, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let selectedURL = urls.first {
                        Task {
                            await libraryStore.linkAndScanFolder(url: selectedURL)
                            await refreshCacheSize()
                        }
                    }
                case .failure(let error):
                    AppLogger.library.error("Folder selection failed: \(error.localizedDescription)")
                }
            }
            .alert("UNLINK DIRECTORY", isPresented: $showingUnlinkAlert) {
                Button("CANCEL", role: .cancel) {}
                Button("UNLINK", role: .destructive) {
                    libraryStore.unlinkDirectory()
                    Task {
                        await refreshCacheSize()
                    }
                }
            } message: {
                Text("THIS WILL REMOVE INDEXED TRACKS AND PLAYLISTS FROM THE APP. YOUR AUDIO FILES ON DISK WILL NOT BE MODIFIED OR DELETED.")
            }
            .alert("CLEAR METADATA & ARTWORK CACHE?", isPresented: $showingClearCacheAlert) {
                Button("CANCEL", role: .cancel) {}
                Button("CLEAR CACHE", role: .destructive) {
                    libraryStore.clearDownloadedMetadataCache()
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await refreshCacheSize()
                    }
                }
            } message: {
                Text("THIS WILL REMOVE \(libraryStore.downloadedMetadataCache.totalRecordsCount) DOWNLOADED METADATA RECORDS AND PURGE CACHED COVER ARTWORK (\(ByteFormatting.formatFileSize(bytes: artworkCacheSizeBytes))). YOUR LOCAL AUDIO FILES ON DISK WILL NOT BE MODIFIED.")
            }
            .sheet(isPresented: $showingDuplicateResolver) {
                DuplicateResolverView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(isPresented: $showingMetadataComparison) {
                MetadataComparisonListView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(isPresented: $showingVerifiedGoodTracks) {
                VerifiedGoodTracksListView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(isPresented: $showingUnmatchedTracks) {
                UnmatchedTracksListView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(item: $activeDetail) { detail in
                SettingOptionDetailSheet(detail: detail)
            }
            .task {
                await refreshCacheSize()
            }
        }
    }

    // MARK: - Top Page & Sheet Buttons (Grouped with Spacing)
    private var topPageButtonsGroup: some View {
        VStack(spacing: 12) {
            // Group 1: Navigation Subpages (Appearance & Playback)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                // 1. Appearance Page
                NavigationLink(destination: AppearanceSettingsView(libraryStore: libraryStore)) {
                    topButtonContent(
                        title: "APPEARANCE",
                        badge: libraryStore.settings.appTheme.displayName
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.appearance
                    }
                }

                // 2. Playback Page
                NavigationLink(destination: PlaybackSettingsView(libraryStore: libraryStore, playerService: playerService ?? AudioPlayerService())) {
                    topButtonContent(
                        title: "PLAYBACK",
                        badge: libraryStore.settings.isCrossfadeEnabled
                            ? String(format: "%.1FS FADE", libraryStore.settings.crossfadeDuration)
                            : "STANDARD"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.playback
                    }
                }
            }

            // Group 2: Metadata & Duplicates Review Sheets
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                // 3. Tracks Ready to Enrich (Sheet)
                topActionButton(
                    title: "READY TO ENRICH",
                    badge: "\(libraryStore.enrichmentDiffs.count) TRACKS",
                    action: {
                        if !libraryStore.enrichmentDiffs.isEmpty {
                            showingMetadataComparison = true
                        }
                    },
                    detail: SettingOptionCatalog.enrichTracks,
                    isDisabled: libraryStore.enrichmentDiffs.isEmpty
                )

                // 4. Tracks Look Good (Sheet)
                topActionButton(
                    title: "LOOK GOOD",
                    badge: "\(libraryStore.verifiedGoodCount) TRACKS",
                    action: {
                        if libraryStore.verifiedGoodCount > 0 {
                            showingVerifiedGoodTracks = true
                        }
                    },
                    detail: SettingOptionCatalog.verifiedTracks,
                    isDisabled: libraryStore.verifiedGoodCount == 0
                )

                // 5. Unmatched Tracks (Sheet)
                topActionButton(
                    title: "UNMATCHED",
                    badge: "\(libraryStore.unmatchedTracksCount) TRACKS",
                    action: {
                        showingUnmatchedTracks = true
                    },
                    detail: SettingOptionCatalog.unmatchedTracks,
                    isDisabled: false
                )

                // 6. Duplicate Tracks (Sheet)
                topActionButton(
                    title: "DUPLICATES",
                    badge: "\(libraryStore.duplicateGroups.count) CLUSTERS",
                    action: {
                        showingDuplicateResolver = true
                    },
                    detail: SettingOptionCatalog.duplicateTracks,
                    isDisabled: libraryStore.duplicateGroups.isEmpty
                )
            }
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

    private func topActionButton(
        title: String,
        badge: String? = nil,
        action: @escaping () -> Void,
        detail: SettingOptionDetail,
        isDisabled: Bool = false
    ) -> some View {
        Button(action: {
            HapticFeedback.notificationSuccess()
            action()
        }) {
            topButtonContent(title: title, badge: badge, isMuted: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu {
            Button("Option Info") {
                activeDetail = detail
            }
        }
    }

    // MARK: - Inline Controls Group
    private var inlineControlsGroup: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Folder Section Info & Actions
            folderControlsView

            // Live Background Scanning Status Logs
            scanningStatusLogsView

            Divider()
                .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.4))

            // Write Metadata to Disk
            TypographicToggleRow(
                title: "WRITE METADATA TO FILES ON DISK",
                isOn: Binding(
                    get: { libraryStore.settings.writeMetadataToAudioFiles },
                    set: { newValue in
                        libraryStore.settings.writeMetadataToAudioFiles = newValue
                        libraryStore.saveSettings()
                    }
                ),
                onLongPress: { activeDetail = SettingOptionCatalog.writeMetadataToDisk }
            )

            // Action: Rescan All Metadata
            Button(action: {
                HapticFeedback.notificationSuccess()
                libraryStore.rescanAllMetadata()
            }) {
                Text(libraryStore.isBackgroundCheckingMetadata ? "SCANNING METADATA..." : "RESCAN ALL METADATA")
                    .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(libraryStore.isBackgroundCheckingMetadata ? Color.secondary : Color.blue)
            }
            .buttonStyle(.plain)
            .disabled(libraryStore.isBackgroundCheckingMetadata)
            .contextMenu {
                Button("Option Info") {
                    activeDetail = SettingOptionCatalog.rescanAllMetadata
                }
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
                    Text("RESET HOME SHUFFLE TO ALL")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.resetHomeShuffle
                    }
                }
            }

            // Action: Clear Metadata & Artwork Cache
            HStack {
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    showingClearCacheAlert = true
                }) {
                    Text("CLEAR METADATA & ARTWORK CACHE")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(libraryStore.downloadedMetadataCache.totalRecordsCount) REC • \(ByteFormatting.formatFileSize(bytes: artworkCacheSizeBytes).uppercased())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Option Info") {
                    activeDetail = SettingOptionCatalog.clearArtworkCache
                }
            }

            // System Architecture Info Action
            Button(action: {
                HapticFeedback.notificationSuccess()
                activeDetail = SettingOptionCatalog.systemArchitecture
            }) {
                HStack {
                    Text("SYSTEM ARCHITECTURE")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("INFO")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Folder Controls View
    private var folderControlsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let folderName = libraryStore.settings.linkedFolderName {
                HStack {
                    Text("FOLDER: \(folderName.uppercased())")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.linkFolder
                }

                HStack(spacing: 18) {
                    Button(action: {
                        HapticFeedback.notificationSuccess()
                        showingFolderPicker = true
                    }) {
                        Text("CHANGE FOLDER")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Option Info") {
                            activeDetail = SettingOptionCatalog.linkFolder
                        }
                    }

                    Button(action: {
                        HapticFeedback.notificationSuccess()
                        Task {
                            await libraryStore.rescanCurrentDirectory()
                        }
                    }) {
                        Text(libraryStore.isScanning ? "SCANNING..." : "RESCAN")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(libraryStore.isScanning ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(libraryStore.isScanning)
                    .contextMenu {
                        Button("Option Info") {
                            activeDetail = SettingOptionCatalog.rescanFolder
                        }
                    }

                    Spacer()

                    Button(action: {
                        HapticFeedback.notificationSuccess()
                        showingUnlinkAlert = true
                    }) {
                        Text("UNLINK")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Option Info") {
                            activeDetail = SettingOptionCatalog.unlinkFolder
                        }
                    }
                }

                // SCAN ALL FOR DUPLICATES BUTTON
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    isScanningDuplicates = true
                    Task {
                        await libraryStore.recalculateDuplicates()
                        isScanningDuplicates = false
                        HapticFeedback.notificationSuccess()
                    }
                }) {
                    Text(isScanningDuplicates ? "SCANNING FOR DUPLICATES..." : "SCAN ALL FOR DUPLICATES")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(isScanningDuplicates ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(isScanningDuplicates)
                .padding(.top, 2)
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.scanDuplicates
                    }
                }
            } else {
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    showingFolderPicker = true
                }) {
                    Text("LINK FOLDER")
                        .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Scanning Status Logs View
    @ViewBuilder
    private var scanningStatusLogsView: some View {
        if libraryStore.isScanning {
            VStack(alignment: .leading, spacing: 4) {
                Text(libraryStore.scanStatusText.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text("INDEXING: \(Int(libraryStore.scanProgress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)

                    Spacer()
                }
            }
            .padding(.vertical, 2)
        }

        if libraryStore.isBackgroundCheckingMetadata {
            VStack(alignment: .leading, spacing: 4) {
                Text(libraryStore.backgroundCheckStatusText.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text("METADATA CHECK: \(Int(libraryStore.backgroundCheckProgress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)

                    Spacer()

                    Button("CANCEL") {
                        libraryStore.cancelBackgroundMetadataScan()
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // Refresh cache size
    private func refreshCacheSize() async {
        let size = await ArtworkCacheService.shared.calculateDiskSize()
        self.artworkCacheSizeBytes = size
    }

    // Clear artwork cache
    private func clearArtworkCache() {
        Task {
            await ArtworkCacheService.shared.clearCache()
            await refreshCacheSize()
        }
    }
}
