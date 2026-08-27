import SwiftUI
import UniformTypeIdentifiers
import os

/// Settings view providing directory linking, library indexing, appearance themes, and cache management.
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

    // Initialize with configured properties
    public init(libraryStore: LibraryStore, playerService: AudioPlayerService? = nil) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            List {
                // MARK: - Directory & Indexing Section
                Section("MUSIC DIRECTORY") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LINKED FOLDER")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if let folderName = libraryStore.settings.linkedFolderName {
                            Text(folderName)
                                .font(.system(size: 15, weight: .bold))

                            if let lastScan = libraryStore.settings.lastScanDate {
                                Text("LAST SCANNED: \(lastScan.formatted(date: .abbreviated, time: .shortened)) • \(libraryStore.settings.totalScannedFiles) TRACKS")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No folder selected.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    // Rescan Progress Bar (when active)
                    if libraryStore.isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: libraryStore.scanProgress)
                                .tint(Color.primary)

                            Text(libraryStore.scanStatusText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }

                    // Directory Actions
                    HStack(spacing: 12) {
                        Button(action: { showingFolderPicker = true }) {
                            Text(libraryStore.settings.linkedFolderName == nil ? "LINK FOLDER" : "CHANGE FOLDER")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))

                        if libraryStore.settings.linkedFolderName != nil {
                            Button(action: {
                                Task {
                                    await libraryStore.rescanCurrentDirectory()
                                }
                            }) {
                                Text("RESCAN")
                            }
                            .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                            .disabled(libraryStore.isScanning)

                            Spacer()

                            Button(action: { showingUnlinkAlert = true }) {
                                Text("UNLINK")
                            }
                            .buttonStyle(TypographicButtonStyle(variant: .destructive, size: .small))
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Duplicate Tracks & Accuracy Section
                if libraryStore.settings.linkedFolderName != nil {
                    Section("DUPLICATE TRACKS & ACCURACY") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("DETECTED DUPLICATES")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)

                                    if libraryStore.duplicateGroups.isEmpty {
                                        Text("0 DUPLICATES DETECTED")
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.green)
                                    } else {
                                        Text("\(libraryStore.duplicateGroups.count) CLUSTERS (\(ByteFormatting.formatFileSize(bytes: libraryStore.totalDuplicateSavingsBytes)) SAVINGS)")
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.primary)
                                    }
                                }

                                Spacer()

                                if !libraryStore.duplicateGroups.isEmpty {
                                    Button(action: {
                                        showingDuplicateResolver = true
                                    }) {
                                        Text("REVIEW & DELETE")
                                    }
                                    .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
                                }
                            }

                            Toggle(isOn: $libraryStore.settings.autoHideDuplicates) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("AUTO-HIDE LOWER QUALITY DUPLICATES")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    Text("Only present the highest-fidelity, tag-complete version in library and search.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(Color.blue)
                            // React to state changes
                            .onChange(of: libraryStore.settings.autoHideDuplicates) { _, _ in
                                libraryStore.saveSettings()
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // MARK: - Track Info Section
                    TrackInfoSectionView(
                        libraryStore: libraryStore,
                        onShowEnrich: { showingMetadataComparison = true },
                        onShowVerifiedGood: { showingVerifiedGoodTracks = true },
                        onShowUnmatched: { showingUnmatchedTracks = true }
                    )
                }

                // MARK: - Appearance Settings Navigation
                Section("APPEARANCE") {
                    NavigationLink(destination: AppearanceSettingsView(libraryStore: libraryStore)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("APPEARANCE")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)

                                Text("Theme, default library page & player background")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(libraryStore.settings.appTheme.displayName)
                                .typographicBadge(isHighlighted: false)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - Playback Settings Navigation
                Section("PLAYBACK") {
                    NavigationLink(destination: PlaybackSettingsView(libraryStore: libraryStore, playerService: playerService ?? AudioPlayerService())) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PLAYBACK")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)

                                Text("Crossfade, auto-play & audio display preferences")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if libraryStore.settings.isCrossfadeEnabled {
                                Text(String(format: "%.1fS CROSSFADE", libraryStore.settings.crossfadeDuration))
                                    .typographicBadge(isHighlighted: true)
                            } else {
                                Text("STANDARD")
                                    .typographicBadge(isHighlighted: false)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - Home Trigger Preferences
                Section("HOME TRIGGER") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SHUFFLE BUTTON TARGET")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary)

                                Text("Currently set to \(libraryStore.settings.customShuffleTarget.isAll ? "All Tracks" : libraryStore.settings.customShuffleTarget.displayName).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(libraryStore.settings.customShuffleTarget.displayName)
                                .typographicBadge(isHighlighted: !libraryStore.settings.customShuffleTarget.isAll)
                        }

                        Button(action: {
                            HapticFeedback.notificationSuccess()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                libraryStore.settings.customShuffleTarget = .all
                                libraryStore.saveSettings()
                            }
                        }) {
                            Text("RESET HOME SHUFFLE TO ALL")
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Storage & Cache Management
                Section("STORAGE & CACHE") {
                    HStack {
                        Text("ARTWORK CACHE")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(ByteFormatting.formatFileSize(bytes: artworkCacheSizeBytes))
                            .font(.system(size: 12, design: .monospaced))
                    }

                    Button(action: clearArtworkCache) {
                        Text("CLEAR ARTWORK CACHE")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                }

                // MARK: - About & System Architecture
                Section("SYSTEM ARCHITECTURE") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OFFLINE MUSIC PLAYER")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text("Engineered with Swift 6 Concurrency, AVFoundation, and native Observation. Fully sandboxed and offline.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder, .audio, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    // File path location
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
                Text("This will remove indexed tracks and playlists from the app. Your audio files on disk will not be modified or deleted.")
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingDuplicateResolver) {
                DuplicateResolverView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingMetadataComparison) {
                MetadataComparisonListView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingVerifiedGoodTracks) {
                VerifiedGoodTracksListView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingUnmatchedTracks) {
                UnmatchedTracksListView(libraryStore: libraryStore)
                    .tint(libraryStore.settings.appTheme.accentColor)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            // Async lifecycle task
            .task {
                await refreshCacheSize()
            }
        }
    }

    // Refresh cache size
    private func refreshCacheSize() async {
        // Size
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

/// Isolated subview for the TRACK INFO section to prevent full-settings view invalidation during background operations.
private struct TrackInfoSectionView: View {
    // Library store
    let libraryStore: LibraryStore
    // On show enrich
    let onShowEnrich: () -> Void
    // On show verified good
    let onShowVerifiedGood: () -> Void
    // On show unmatched
    let onShowUnmatched: () -> Void

    // Body
    var body: some View {
        Section("TRACK INFO") {
            VStack(alignment: .leading, spacing: 12) {
                // Top: Real-Time Transparent Progress Bar
                if libraryStore.isBackgroundCheckingMetadata {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("SCANNING LIBRARY METADATA...")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(libraryStore.settings.appTheme.accentColor)

                            Spacer()

                            Button("CANCEL") {
                                libraryStore.cancelBackgroundMetadataScan()
                            }
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }

                        ProgressView(value: libraryStore.backgroundCheckProgress)
                            .tint(libraryStore.settings.appTheme.accentColor)

                        HStack {
                            Text(libraryStore.backgroundCheckStatusText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(Int(libraryStore.backgroundCheckProgress * 100))%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    Divider()
                        .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.5))
                }

                // Row 1: Ready to Enrich
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(libraryStore.enrichmentDiffs.count) TRACKS READY TO ENRICH")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Missing tags or high-res artwork found online.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onShowEnrich) {
                        Text("ENRICH")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
                    .disabled(libraryStore.enrichmentDiffs.isEmpty)
                }

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.5))

                // Row 2: Tracks Look Good (Double Check)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(libraryStore.verifiedGoodCount) TRACKS LOOK GOOD")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Your local track matches the online track.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onShowVerifiedGood) {
                        Text("DOUBLE CHECK")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                    .disabled(libraryStore.verifiedGoodCount == 0)
                }

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.5))

                // Row 3: Unmatched / Ignored Tracks
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(libraryStore.unmatchedTracksCount) TRACKS COULDN'T BE FOUND")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("No exact online match found; marked as ignored.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onShowUnmatched) {
                        Text("CHECK")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                }

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.5))

                // Row 4: Disk Writing Toggle
                Toggle(isOn: Binding(
                    get: { libraryStore.settings.writeMetadataToAudioFiles },
                    set: { newValue in
                        libraryStore.settings.writeMetadataToAudioFiles = newValue
                        libraryStore.saveSettings()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WRITE METADATA TO FILES ON DISK")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text("Embed ID3v2/M4A tags directly into audio files without re-encoding audio.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)

                Divider()
                    .overlay(libraryStore.settings.appTheme.separatorColor.opacity(0.5))

                // Row 5: Rescan All Option
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RESCAN ALL METADATA")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("Re-evaluates every song in your library from scratch in the background.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        libraryStore.rescanAllMetadata()
                        HapticFeedback.notificationSuccess()
                    }) {
                        Text("RESCAN")
                    }
                    .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                    .disabled(libraryStore.isBackgroundCheckingMetadata)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
