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
    public static let folderSettings = SettingOptionDetail(
        id: "folderSettings",
        title: "FOLDER SETTINGS & ORGANIZATION",
        whatItDoes: "• MANAGES YOUR MUSIC DIRECTORY LINKING, DISK RESCANNING, AND DUPLICATE DETECTION.\n• LETS YOU SWITCH SCAN MODES BETWEEN STANDARD ID3 TAGS AND SMART FOLDER HIERARCHY.",
        howToUseIt: "1. TAP THE FOLDER CARD TO OPEN DEDICATED FOLDER MANAGEMENT.\n2. CHANGE LINKED DIRECTORY, RESCAN FILES, RESOLVE DUPLICATES, OR UNLINK FOLDER."
    )

    public static let metadataEnrichment = SettingOptionDetail(
        id: "metadataEnrichment",
        title: "METADATA ENRICHMENT",
        whatItDoes: "• ENRICHES LOCAL TRACKS WITH VERIFIED ONLINE METADATA, ARTWORK, AND LYRICS.\n• EMBEDS TAGS DIRECTLY TO AUDIO FILES ON DISK IF ENABLED.\n• HOUSES READY TO ENRICH, LOOK GOOD, UNMATCHED, AND DUPLICATES SHEETS.",
        howToUseIt: "1. TAP TO OPEN THE METADATA ENRICHMENT HUB.\n2. REVIEW DETECTED DIFFERENCES, SWIPE TO APPLY UPGRADES, OR RESCAN ALL METADATA."
    )

    public static let libraryScanMethod = SettingOptionDetail(
        id: "libraryScanMethod",
        title: "LIBRARY SCAN METHOD",
        whatItDoes: "• METHOD 1 (STANDARD ID3 TAGS): GROUPS SONGS BASED ON EMBEDDED METADATA TAGS (ARTIST > ALBUM > TRACK).\n• METHOD 2 (FOLDER HIERARCHY): GROUPS SONGS BASED ON YOUR HARD DRIVE DIRECTORY NESTING (PARENT FOLDER = ARTIST, SUBFOLDER = ALBUM).",
        howToUseIt: "1. SELECT YOUR PREFERRED SCAN METHOD IN FOLDER SETTINGS.\n2. RESCAN LIBRARY TO RE-ORGANIZE YOUR SONGS."
    )

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
        title: "TRACKS FOUND",
        whatItDoes: "• IDENTIFIES LOCAL SONGS WITH MISSING TAGS, LOW-RES ARTWORK, OR INCOMPLETE METADATA.\n• MATCHES THEM WITH OFFICIAL ONLINE RECORDS AND HIGHLIGHTS UPGRADES IN GREEN.\n• LETS YOU LOCK SPECIFIC LOCAL TAGS WITH [KEEP LOCAL] SO THEY ARE NOT OVERWRITTEN.",
        howToUseIt: "1. TAP TO OPEN THE ENRICHMENT MENU.\n2. SWIPE ON ANY TRACK TO COMPARE ONLINE DATA WITH YOUR ORIGINAL TAGS.\n3. TAP 'APPLY ONLINE METADATA' FOR A SINGLE TRACK, OR 'ENRICH ALL' TO BATCH UPDATE."
    )

    public static let verifiedTracks = SettingOptionDetail(
        id: "verifiedTracks",
        title: "TRACKS GOOD",
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
        whatItDoes: "• MAINTAINS YOUR ACTIVE QUEUE CONTEXT WHEN YOU TAP A SONG IN SEARCH OR LISTS.\n• PREVENTS ACCIDENTAL CLEARING OF YOUR CURRENT PLAYLIST OR QUEUE.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED).\n2. WHEN ON, SELECTING A TRACK ADDS OR SWITCHES WITHIN YOUR CURRENT QUEUE."
    )

    public static let tapToPlayNext = SettingOptionDetail(
        id: "tapToPlayNext",
        title: "TAP TO PLAY NEXT",
        whatItDoes: "• AUTOMATICALLY INSERTS TAPPED SONGS RIGHT AFTER THE CURRENTLY PLAYING TRACK.\n• PERFECT FOR ON-THE-FLY QUEUE BUILDING.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED).\n2. TAPPING ANY SONG IMMEDIATELY QUEUES IT AS UP NEXT."
    )

    public static let autoPlayNext = SettingOptionDetail(
        id: "autoPlayNext",
        title: "AUTO-PLAY NEXT",
        whatItDoes: "• AUTOMATICALLY ADVANCES TO THE NEXT SONG IN THE QUEUE OR ALBUM WHEN A TRACK FINISHES.\n• KEEPS YOUR MUSIC FLOWING WITHOUT MANUAL INTERVENTION.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )

    public static let rememberPlaybackPosition = SettingOptionDetail(
        id: "rememberPlaybackPosition",
        title: "REMEMBER PLAYBACK POSITION",
        whatItDoes: "• REMEMBERS WHERE YOU LEFT OFF ON LONG AUDIO TRACKS, PODCASTS, DJ SETS, AND AUDIOBOOKS.\n• RESUMES FROM THE EXACT SECOND WHEN YOU PLAY THE TRACK AGAIN.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED).\n2. SET THE MINIMUM TRACK DURATION SLIDER BELOW (10 TO 60 MINUTES)."
    )

    public static let showAudioSpecs = SettingOptionDetail(
        id: "showAudioSpecs",
        title: "SHOW AUDIO SPECS",
        whatItDoes: "• DISPLAYS AUDIOPHILE TECHNICAL AUDIO METRICS (SAMPLE RATE, BIT DEPTH, BITRATE, CODEC) IN THE PLAYER BAR AND FULLSCREEN PLAYER.\n• LETS YOU VERIFY LOSSLESS OR HI-RES AUDIO FIDELITY AT A GLANCE.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
    )

    public static let smoothSkipping = SettingOptionDetail(
        id: "smoothSkipping",
        title: "SMOOTH SKIPPING",
        whatItDoes: "• APPLIES AN ULTRA-FAST MICRO-FADE WHEN SKIPPING BETWEEN TRACKS.\n• ELIMINATES HARD AUDIO POPS, CLICKS, AND DISCONTINUITIES.",
        howToUseIt: "1. TAP TO TOGGLE ON (BLUE) OR OFF (RED)."
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHAT IT DOES")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(detail.whatItDoes)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .lineSpacing(4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HOW TO USE IT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(detail.howToUseIt)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .lineSpacing(4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(detail.title)
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
        }
    }
}

/// Settings and preferences control panel.
public struct SettingsView: View {
    @Bindable var libraryStore: LibraryStore
    public var playerService: AudioPlayerService?

    @Environment(\.dismiss) private var dismiss
    @State private var showingClearCacheAlert: Bool = false
    @State private var activeDetail: SettingOptionDetail? = nil
    @State private var artworkCacheSizeBytes: Int64 = 0

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

                    // MARK: - Main Inline Controls & Cache Maintenance
                    inlineControlsGroup
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
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
            .sheet(item: $activeDetail) { detail in
                SettingOptionDetailSheet(detail: detail)
            }
            .task {
                await refreshCacheSize()
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
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.appearance
                    }
                }

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
                .contextMenu {
                    Button("Option Info") {
                        activeDetail = SettingOptionCatalog.playback
                    }
                }
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
            .contextMenu {
                Button("Option Info") {
                    activeDetail = SettingOptionCatalog.folderSettings
                }
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

    // MARK: - Inline Controls Group
    private var inlineControlsGroup: some View {
        VStack(alignment: .leading, spacing: 22) {
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

    private func refreshCacheSize() async {
        let size = await ArtworkCacheService.shared.calculateDiskSize()
        await MainActor.run {
            self.artworkCacheSizeBytes = size
        }
    }
}
