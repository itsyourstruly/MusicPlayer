import SwiftUI
import UniformTypeIdentifiers
import os

/// Dedicated folder and library indexing settings page housing linked directory operations,
/// track enrichment review sheets, and clean dual-mode scan selection.
public struct FolderSettingsView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    @State private var showingFolderPicker: Bool = false
    @State private var pendingOpenFolderPicker: Bool = false
    @State private var folderToChange: LinkedFolder? = nil
    @State private var folderToUnlink: LinkedFolder? = nil
    @State private var showingUnlinkAlert: Bool = false
    @State private var showingAddSourceSheet: Bool = false
    @State private var serverToUnlink: ServerSourceLink? = nil
    @State private var showingUnlinkServerAlert: Bool = false
    @State private var showingTagFinderSheet: Bool = false
    @State private var folderForPlaylistFinder: LinkedFolder? = nil
    @State private var showingClearMetadataAlert: Bool = false
    @State private var showingClearArtworkAlert: Bool = false
    @State private var showingClearDownloadsAlert: Bool = false
    @State private var showingClearEverythingAlert: Bool = false
    @State private var showingClearMergesAlert: Bool = false
    @State private var showingCloudWarningAlert: Bool = false
    @State private var cloudWarningMessage: String = ""
    @State private var artworkCacheSizeBytes: Int64 = 0
    @State private var activeDetail: SettingOptionDetail? = nil
    // Pending (unsaved) local organization selection; nil = use saved settings
    @State private var pendingMethod: LibraryScanMethod? = nil
    @State private var pendingLayout: FolderHierarchyLayout? = nil
    @State private var pendingSeparators: [String]? = nil
    @State private var isArtistSeparatorsExpanded: Bool = false
    @State private var newSeparatorInput: String = ""
    @State private var isSavingOrganization: Bool = false
    @State private var storageTarget: StorageClearTarget = .metadata
    @State private var isHiddenExpanded: Bool = false

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    public var body: some View {
        sourcesScrollContent
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle(AppCapitalization.format("SOURCES", enabled: isCaps))
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let selectedURL = urls.first {
                        _ = selectedURL.startAccessingSecurityScopedResource()
                        if let folder = folderToChange {
                            Task {
                                await libraryStore.changeFolder(id: folder.id, newURL: selectedURL)
                                selectedURL.stopAccessingSecurityScopedResource()
                            }
                        } else {
                            Task {
                                await libraryStore.addAndScanFolder(url: selectedURL)
                                selectedURL.stopAccessingSecurityScopedResource()
                            }
                        }
                    }
                    folderToChange = nil
                case .failure(let error):
                    folderToChange = nil
                    AppLogger.library.error("Folder selection failed: \(error.localizedDescription)")
                }
            }
            .alert(AppCapitalization.format("UNLINK DIRECTORY?", enabled: isCaps), isPresented: $showingUnlinkAlert) {
                Button(AppCapitalization.format("CANCEL", enabled: isCaps), role: .cancel) {
                    folderToUnlink = nil
                }
                Button(AppCapitalization.format("UNLINK", enabled: isCaps), role: .destructive) {
                    if let folder = folderToUnlink {
                        libraryStore.unlinkFolder(id: folder.id)
                        folderToUnlink = nil
                    } else {
                        libraryStore.unlinkDirectory()
                    }
                }
            } message: {
                Text(AppCapitalization.format("THIS WILL REMOVE INDEXED TRACKS AND PLAYLISTS FROM THE APP. YOUR AUDIO FILES ON DISK WILL NOT BE MODIFIED OR DELETED.", enabled: isCaps))
            }
            .modifier(FolderSettingsStorageClearAlerts(
                libraryStore: libraryStore,
                showingClearMetadataAlert: $showingClearMetadataAlert,
                showingClearArtworkAlert: $showingClearArtworkAlert,
                showingClearDownloadsAlert: $showingClearDownloadsAlert,
                showingClearMergesAlert: $showingClearMergesAlert,
                showingClearEverythingAlert: $showingClearEverythingAlert,
                refreshArtworkCacheSize: { await refreshArtworkCacheSize() },
                onClearedMerges: { reconcileStorageClearTargetSelection() }
            ))
            .alert("ICLOUD STORAGE DETECTED", isPresented: $showingCloudWarningAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cloudWarningMessage)
            }
            .sheet(isPresented: $showingAddSourceSheet, onDismiss: {
                if pendingOpenFolderPicker {
                    pendingOpenFolderPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        folderToChange = nil
                        showingFolderPicker = true
                    }
                }
            }) {
                AddLibrarySourceSheet(
                    onSelectLocalFolder: {
                        pendingOpenFolderPicker = true
                    },
                    onServerConnected: { serverLink in
                        handleServerConnected(serverLink)
                    }
                )
                .environment(\.appTheme, appTheme)
            }
            .alert("REMOVE SERVER?", isPresented: $showingUnlinkServerAlert) {
                Button("CANCEL", role: .cancel) {
                    serverToUnlink = nil
                }
                Button("REMOVE", role: .destructive) {
                    if let server = serverToUnlink {
                        removeServer(server)
                        serverToUnlink = nil
                    }
                }
            } message: {
                Text("THIS WILL REMOVE THIS SERVER'S TRACKS, DOWNLOADS AND ARTWORK FROM YOUR LIBRARY.")
            }
            .sheet(isPresented: $showingTagFinderSheet) {
                TrackTagFinderSheetView(libraryStore: libraryStore)
                    .tint(appTheme.accentColor)
                    .environment(\.appTheme, appTheme)
            }
            .sheet(item: $activeDetail) { detail in
                SettingOptionDetailSheet(detail: detail)
                    .environment(\.appTheme, libraryStore.settings.appTheme)
            }
            .sheet(item: $folderForPlaylistFinder) { folder in
                FolderPlaylistFinderSheet(libraryStore: libraryStore, folder: folder)
                    .tint(appTheme.accentColor)
                    .environment(\.appTheme, appTheme)
            }
            .task {
                if artworkCacheSizeBytes == 0 {
                    await refreshArtworkCacheSize()
                }
            }
            .task {
                // Lists items hidden before the HIDDEN list existed (tags read off the main thread, once per session)
                libraryStore.resolveLegacyHiddenTracksIfNeeded()
            }
            .onChange(of: libraryStore.hiddenItems.isEmpty) { _, isEmpty in
                if isEmpty { isHiddenExpanded = false }
            }
            .onChange(of: availableStorageClearTargets.map(\.rawValue).joined(separator: "|")) { _, _ in
                reconcileStorageClearTargetSelection()
            }
    }

    private var sourcesScrollContent: some View {
        let hasServers = !libraryStore.settings.serverSources.isEmpty
        let hasFolders = !libraryStore.settings.linkedFolders.isEmpty
        let hasAnySources = hasServers || hasFolders

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - 1. Online Sources (Top) & Add Button
                onlineSourcesSection

                // MARK: - Live Scanning Status Logs
                scanningStatusLogsView

                if hasAnySources {
                    // MARK: - 2. Online Sources Options
                    if hasServers {
                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        serverDownloadTogglesSection
                    }

                    // MARK: - 3. Local Sources & Options
                    if hasFolders {
                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        localSourcesSection

                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        findTrackTagsButtonSection

                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        scanMethodSelectorSection
                    }

                    // MARK: - 4. App Storage Management
                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.4))

                    cacheManagementSection
                }

                // MARK: - 5. Hidden Items (only when something is hidden)
                if !libraryStore.hiddenItems.isEmpty {
                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.4))

                    hiddenItemsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Online Sources Section (Top of Sheet)
    private var onlineSourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(libraryStore.settings.serverSources) { server in
                serverRow(server: server)
            }

            let hasAnySources = !libraryStore.settings.serverSources.isEmpty || !libraryStore.settings.linkedFolders.isEmpty
            Button(action: {
                showingAddSourceSheet = true
            }) {
                Text(AppCapitalization.format(hasAnySources ? "ADD ANOTHER SOURCE" : "ADD SOURCE", enabled: isCaps))
                    .font(.system(size: hasAnySources ? 13 : 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(libraryStore.settings.appTheme.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, hasAnySources && !libraryStore.settings.serverSources.isEmpty ? 2 : 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Local Sources Section
    private var localSourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(libraryStore.settings.linkedFolders) { folder in
                linkedFolderRow(folder: folder)
            }
        }
        .padding(.vertical, 4)
    }

    private func serverRow(server: ServerSourceLink) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("\(AppCapitalization.format(server.displayLabel, enabled: isCaps)) - \(AppCapitalization.format(server.username, enabled: isCaps))")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Menu {
                    Button {
                        HapticFeedback.selectionChanged()
                        rescanServer(server)
                    } label: {
                        Text(AppCapitalization.format("RESCAN", enabled: isCaps))
                    }
                    .disabled(libraryStore.isScanning)

                    if libraryStore.jellyfinServerErrors[server.id] != nil {
                        Button {
                            HapticFeedback.selectionChanged()
                            Task { @MainActor in await libraryStore.syncServer(server) }
                        } label: {
                            Text(AppCapitalization.format("RETRY", enabled: isCaps))
                        }
                        .disabled(libraryStore.isScanning)
                    }

                    Divider()
                    Button(role: .destructive) {
                        serverToUnlink = server
                        showingUnlinkServerAlert = true
                    } label: {
                        Text(AppCapitalization.format("REMOVE SERVER", enabled: isCaps))
                    }
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }

            let serverTrackCount = libraryStore.trackCount(for: server)
            Text(libraryStore.isScanning && libraryStore.currentlyScanningFolderID == server.id
                 ? scanProgressLine
                 : "\(serverTrackCount) \(AppCapitalization.format("TRACKS", enabled: isCaps)), \(libraryStore.albumCount(for: server)) \(AppCapitalization.format("ALBUMS", enabled: isCaps)), \(libraryStore.artistCount(for: server)) \(AppCapitalization.format("ARTISTS", enabled: isCaps))")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            if libraryStore.serverRescanRecommended.contains(server.id) && !libraryStore.isScanning {
                Text(AppCapitalization.format("RESCAN RECOMMENDED: SONG CREDITS ARE FROM AN OLDER VERSION", enabled: isCaps))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let error = libraryStore.jellyfinServerErrors[server.id] {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)

                    if error == JellyfinClientError.localNetworkDenied.localizedDescription {
                        #if os(iOS)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString),
                               UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text(AppCapitalization.format("OPEN SETTINGS", enabled: isCaps))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func linkedFolderRow(folder: LinkedFolder) -> some View {
        let isThisScanning = libraryStore.currentlyScanningFolderID == folder.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(AppCapitalization.format(folder.name, enabled: isCaps))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                // Gear Icon with clean context menu
                Menu {
                    Button {
                        HapticFeedback.selectionChanged()
                        Task { await libraryStore.rescanFolder(id: folder.id) }
                    } label: {
                        Text(AppCapitalization.format(isThisScanning ? "SCANNING..." : "RESCAN", enabled: isCaps))
                    }
                    .disabled(libraryStore.isScanning)

                    Button {
                        HapticFeedback.selectionChanged()
                        folderForPlaylistFinder = folder
                    } label: {
                        Text(AppCapitalization.format("FIND PLAYLIST", enabled: isCaps))
                    }

                    Button(action: {
                        folderToChange = folder
                        showingFolderPicker = true
                    }) {
                        Text(AppCapitalization.format("CHANGE FOLDER", enabled: isCaps))
                    }

                    Button {
                        libraryStore.toggleTagEnrichmentExclusion(for: folder.id)
                    } label: {
                        Text(AppCapitalization.format(folder.isExcludedFromTagEnrichment ? "EXCLUDE FROM TAG ENRICHMENT (SELECTED)" : "EXCLUDE FROM TAG ENRICHMENT", enabled: isCaps))
                    }

                    Divider()
                    Button(role: .destructive) {
                        folderToUnlink = folder
                        showingUnlinkAlert = true
                    } label: {
                        Text(AppCapitalization.format("UNLINK FOLDER", enabled: isCaps))
                    }
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }

            // Plain text, slightly gray summary of tracks, albums, and artists
            Text(isThisScanning && libraryStore.isScanning
                 ? scanProgressLine
                 : "\(libraryStore.trackCount(for: folder)) \(AppCapitalization.format("TRACKS", enabled: isCaps)), \(libraryStore.albumCount(for: folder)) \(AppCapitalization.format("ALBUMS", enabled: isCaps)), \(libraryStore.artistCount(for: folder)) \(AppCapitalization.format("ARTISTS", enabled: isCaps))")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 2. Find Track Tags Button (Opens Unified Tag Finder Sheet)
    private var findTrackTagsButtonSection: some View {
        Button {
            HapticFeedback.notificationSuccess()
            showingTagFinderSheet = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppCapitalization.format("FIND TRACK TAGS", enabled: isCaps))
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.black)

                    if libraryStore.isBackgroundCheckingMetadata {
                        let total = libraryStore.backgroundCheckTotalCount > 0 ? libraryStore.backgroundCheckTotalCount : max(libraryStore.tracks.count, 1)
                        Text("\(libraryStore.backgroundCheckScannedCount)/\(total)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.65))
                    } else if libraryStore.isEnrichingMetadata {
                        let total = libraryStore.enrichTotalCount > 0 ? libraryStore.enrichTotalCount : max(libraryStore.enrichmentDiffs.count, 1)
                        Text("\(libraryStore.enrichProcessedCount)/\(total)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.65))
                    } else {
                        Text("\(libraryStore.visibleEnrichmentDiffs.count) \(AppCapitalization.format("FOUND", enabled: isCaps)) • \(libraryStore.visibleVerifiedGoodCount) \(AppCapitalization.format("GOOD", enabled: isCaps)) • \(libraryStore.unmatchedTracksCount) \(AppCapitalization.format("LOST", enabled: isCaps)) • \(libraryStore.visibleDuplicateGroups.count) \(AppCapitalization.format("DUPES", enabled: isCaps))")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.65))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                activeDetail = SettingOptionCatalog.findTrackTags
            } label: {
                Text(AppCapitalization.format("OPTION INFO", enabled: isCaps))
            }
        }
    }

    // MARK: - 4. Disk Write Toggle
    private var serverDownloadTogglesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TypographicToggleRow(
                title: "AUTO-DOWNLOAD ON PLAY",
                isOn: Binding(
                    get: { libraryStore.settings.autoDownloadOnPlay },
                    set: { newValue in
                        libraryStore.settings.autoDownloadOnPlay = newValue
                        libraryStore.saveSettings()
                    }
                ),
                onLongPress: { activeDetail = SettingOptionCatalog.autoDownloadOnPlay }
            )
            TypographicToggleRow(
                title: "CACHE IN ADVANCE",
                isOn: Binding(
                    get: { libraryStore.settings.cacheInAdvanceEnabled },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            libraryStore.settings.cacheInAdvanceEnabled = newValue
                        }
                        libraryStore.saveSettings()
                    }
                ),
                onLongPress: { activeDetail = SettingOptionCatalog.cacheInAdvance }
            )
            if libraryStore.settings.cacheInAdvanceEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(AppCapitalization.format("SONGS TO CACHE", enabled: isCaps))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("\(libraryStore.settings.cacheInAdvanceCount)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(libraryStore.settings.cacheInAdvanceCount) },
                            set: { newValue in
                                let count = Int(newValue.rounded())
                                guard count != libraryStore.settings.cacheInAdvanceCount else { return }
                                libraryStore.settings.cacheInAdvanceCount = count
                                libraryStore.saveSettings()
                            }
                        ),
                        in: 0.0...25.0,
                        step: 1.0
                    )
                    .tint(libraryStore.settings.appTheme.accentColor)
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
            TypographicToggleRow(
                title: "DOWNLOAD OVER CELLULAR",
                isOn: Binding(
                    get: { libraryStore.settings.downloadOverCellular },
                    set: { newValue in
                        libraryStore.settings.downloadOverCellular = newValue
                        libraryStore.saveSettings()
                    }
                ),
                onLongPress: { activeDetail = SettingOptionCatalog.downloadOverCellular }
            )
            TypographicToggleRow(
                title: "HIDE DUPLICATES",
                isOn: Binding(
                    get: { libraryStore.settings.hideServerAlbumDuplicates },
                    set: { newValue in
                        libraryStore.setHideServerAlbumDuplicates(newValue)
                    }
                ),
                onLongPress: { activeDetail = SettingOptionCatalog.hideDuplicates }
            )
            albumMergeModeSection
        }
    }

    private var diskWriteToggleSection: some View {
        TypographicToggleRow(
            title: "WRITE METADATA TO FILES ON DISK",
            subtitle: "EMBEDS ID3V2 / M4A / FLAC TAGS DIRECTLY INTO AUDIO FILES",
            isOn: Binding(
                get: { libraryStore.settings.writeMetadataToAudioFiles },
                set: { newValue in
                    libraryStore.settings.writeMetadataToAudioFiles = newValue
                    libraryStore.saveSettings()
                    if newValue {
                        let rootURL = SecurityScopedBookmark.shared.currentFolderURL ?? SecurityScopedBookmark.shared.resolveAndAccessBookmark()
                        if let root = rootURL, AudioFileMetadataWriter.isCloudStorageURL(root) {
                            cloudWarningMessage = "Your music folder is located in iCloud Drive. Files in cloud storage cannot be modified directly on disk. Enriched metadata will be kept safely within the app."
                            showingCloudWarningAlert = true
                        }
                    }
                }
            ),
            onLongPress: { activeDetail = SettingOptionCatalog.writeMetadataToDisk }
        )
    }

    // MARK: - 5. Library Organization Option Box (METADATA / FOLDER + folder layouts), local folders only
    private var effectiveMethod: LibraryScanMethod { pendingMethod ?? libraryStore.settings.libraryScanMethod }
    private var effectiveLayout: FolderHierarchyLayout { pendingLayout ?? libraryStore.settings.folderHierarchyLayout }
    private var effectiveSeparators: [String] {
        pendingSeparators ?? libraryStore.settings.customArtistSeparators
    }
    private var hasPendingSeparatorsChange: Bool {
        if let pending = pendingSeparators {
            return pending != libraryStore.settings.customArtistSeparators
        }
        return false
    }
    private var hasPendingOrganizationChange: Bool {
        let saved = libraryStore.settings
        if effectiveMethod != saved.libraryScanMethod { return true }
        if effectiveMethod == .folderHierarchy && effectiveLayout != saved.folderHierarchyLayout { return true }
        return hasPendingSeparatorsChange
    }

    private var scanMethodSelectorSection: some View {
        let isFolder = effectiveMethod == .folderHierarchy

        return VStack(alignment: .leading, spacing: 12) {
            Text(AppCapitalization.format("LOCAL FOLDER ORGANIZATION", enabled: isCaps))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.localOrganizationSection
                }

            HStack(alignment: .firstTextBaseline) {
                Menu {
                    Button {
                        HapticFeedback.selectionChanged()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            pendingMethod = .id3Tags
                        }
                    } label: {
                        if !isFolder { Label(AppCapitalization.format("METADATA", enabled: isCaps), systemImage: "checkmark") } else { Text(AppCapitalization.format("METADATA", enabled: isCaps)) }
                    }

                    Menu {
                        ForEach(FolderHierarchyLayout.allCases) { layout in
                            Button {
                                HapticFeedback.selectionChanged()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    pendingLayout = layout
                                    pendingMethod = .folderHierarchy
                                }
                            } label: {
                                if isFolder && effectiveLayout == layout {
                                    Label(AppCapitalization.format(layout.displayName, enabled: isCaps), systemImage: "checkmark")
                                } else {
                                    Text(AppCapitalization.format(layout.displayName, enabled: isCaps))
                                }
                            }
                        }
                    } label: {
                        if isFolder { Label(AppCapitalization.format("FOLDER", enabled: isCaps), systemImage: "checkmark") } else { Text(AppCapitalization.format("FOLDER", enabled: isCaps)) }
                    }
                } label: {
                    Text(AppCapitalization.format(isFolder ? "FOLDER" : "METADATA", enabled: isCaps))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(isSavingOrganization)

                if hasPendingOrganizationChange || isSavingOrganization {
                    Button {
                        saveOrganization()
                    } label: {
                        Text(AppCapitalization.format(isSavingOrganization ? "SAVING..." : "SAVE", enabled: isCaps))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingOrganization)
                    .transition(.opacity)
                }
            }

            // Collapsible ARTIST SEPARATORS section under LOCAL FOLDER ORGANIZATION
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        isArtistSeparatorsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(AppCapitalization.format("ARTIST SEPARATORS", enabled: isCaps))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !effectiveSeparators.isEmpty {
                            Text("(\(effectiveSeparators.count))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isArtistSeparatorsExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        activeDetail = SettingOptionCatalog.artistSeparators
                    } label: {
                        Text(AppCapitalization.format("OPTION INFO", enabled: isCaps))
                    }
                }

                if isArtistSeparatorsExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(effectiveSeparators.enumerated()), id: \.offset) { index, separator in
                            HStack {
                                Text("\"\(separator)\"")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                                Spacer()

                                Button {
                                    HapticFeedback.selectionChanged()
                                    var current = effectiveSeparators
                                    current.remove(at: index)
                                    pendingSeparators = current
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }

                        HStack(spacing: 8) {
                            TextField(AppCapitalization.format("ADD SEPARATOR (E.G. //)", enabled: isCaps), text: $newSeparatorInput)
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif

                            Button {
                                let trimmed = newSeparatorInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                guard !effectiveSeparators.contains(newSeparatorInput) else {
                                    newSeparatorInput = ""
                                    return
                                }
                                HapticFeedback.selectionChanged()
                                var current = effectiveSeparators
                                current.append(newSeparatorInput)
                                pendingSeparators = current
                                newSeparatorInput = ""
                            } label: {
                                Text(AppCapitalization.format("ADD", enabled: isCaps))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(appTheme.accentColor)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .disabled(newSeparatorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 6)
        }
        .animation(.easeInOut(duration: 0.2), value: hasPendingOrganizationChange || isSavingOrganization)
    }

    private func saveOrganization() {
        guard !isSavingOrganization else { return }
        let method = effectiveMethod
        let layout = effectiveLayout
        let seps = effectiveSeparators
        isSavingOrganization = true
        Task { @MainActor in
            await libraryStore.applyLocalOrganization(method: method, layout: layout, customSeparators: seps)
            HapticFeedback.notificationSuccess()
            withAnimation(.easeInOut(duration: 0.2)) {
                pendingMethod = nil
                pendingLayout = nil
                pendingSeparators = nil
                newSeparatorInput = ""
                isSavingOrganization = false
            }
        }
    }

    private var optionDivider: some View {
        Divider()
            .overlay(appTheme.separatorColor.opacity(0.4))
    }

    private func handleServerConnected(_ serverLink: ServerSourceLink) {
        var linkToUse = serverLink
        if let existingIndex = libraryStore.settings.serverSources.firstIndex(where: {
            $0.kind == serverLink.kind && $0.serverId == serverLink.serverId && $0.userId == serverLink.userId
        }) {
            let existing = libraryStore.settings.serverSources[existingIndex]
            // Re-sign-in to an already linked server keeps the original source ID (and therefore all track IDs);
            // move the freshly saved credentials onto it.
            ServerCredentialStore.moveCredentials(from: serverLink.id, to: existing.id)
            if serverLink.kind == .plex {
                PlexConnectionStore.save(PlexConnectionStore.connections(for: serverLink.id), for: existing.id)
                PlexConnectionStore.remove(for: serverLink.id)
            }
            linkToUse = ServerSourceLink(
                id: existing.id,
                kind: existing.kind,
                serverId: serverLink.serverId,
                serverName: serverLink.serverName,
                userId: serverLink.userId,
                userName: serverLink.username,
                serverURL: serverLink.serverURL,
                dateAdded: existing.dateAdded,
                productName: serverLink.productName ?? existing.productName
            )
            ServerSessionCache.shared.removeSession(for: existing.id)
            libraryStore.settings.serverSources[existingIndex] = linkToUse
            libraryStore.saveSettings()
        } else {
            libraryStore.settings.serverSources.append(linkToUse)
            libraryStore.saveSettings()
        }
        rescanServer(linkToUse)
    }

    private func rescanServer(_ serverLink: ServerSourceLink) {
        Task { @MainActor in
            await libraryStore.syncServer(serverLink, force: true)
        }
    }

    private func removeServer(_ serverLink: ServerSourceLink) {
        libraryStore.removeServerSource(id: serverLink.id)
    }

    private var scanProgressLine: String {
        let status = libraryStore.scanStatusText
        return status.isEmpty ? AppCapitalization.format("INDEXING...", enabled: isCaps) : AppCapitalization.format(status, enabled: isCaps)
    }

    private var scanBelongsToListedRow: Bool {
        guard let id = libraryStore.currentlyScanningFolderID else { return false }
        return libraryStore.settings.serverSources.contains { $0.id == id }
            || libraryStore.settings.linkedFolders.contains { $0.id == id }
    }

    // MARK: - Scanning Status Logs View
    @ViewBuilder
    private var scanningStatusLogsView: some View {
        // Only shown when the scan doesn't belong to a listed row (progress otherwise replaces that row's stats line)
        if libraryStore.isScanning && !scanBelongsToListedRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppCapitalization.format(libraryStore.scanStatusText, enabled: isCaps))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text(AppCapitalization.format("INDEXING: \(Int(libraryStore.scanProgress * 100))%", enabled: isCaps))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)

                    Spacer()
                }
            }
        }
    }

    // MARK: - 6. Cache Management (CLEAR METADATA CACHE & CLEAR ARTWORK CACHE)
    private enum StorageClearTarget: String, CaseIterable, Identifiable, Hashable {
        case metadata = "LOCAL TRACKS METADATA CACHE"
        case artwork = "ARTWORK CACHE"
        case jellyfinOffline = "SERVER OFFLINE STORAGE"
        case merges = "MERGES"
        case everything = "EVERYTHING"
        var id: String { rawValue }
    }

    private func storageClearTargetHasContent(_ target: StorageClearTarget) -> Bool {
        switch target {
        case .metadata:
            return libraryStore.downloadedMetadataCache.totalRecordsCount > 0
        case .artwork:
            return artworkCacheSizeBytes > 0
        case .jellyfinOffline:
            return !JellyfinDownloadManager.shared.downloadRecords.isEmpty
        case .merges:
            return !libraryStore.settings.albumMergeGroups.isEmpty
        case .everything:
            return StorageClearTarget.allCases.contains {
                $0 != .everything && storageClearTargetHasContent($0)
            }
        }
    }

    private var availableStorageClearTargets: [StorageClearTarget] {
        StorageClearTarget.allCases.filter(storageClearTargetHasContent)
    }

    private func reconcileStorageClearTargetSelection() {
        let available = availableStorageClearTargets
        if available.isEmpty {
            storageTarget = .metadata
            return
        }
        if !available.contains(storageTarget) {
            storageTarget = available[0]
        }
    }

    private var storageTargetDetail: String {
        switch storageTarget {
        case .metadata:
            return "\(libraryStore.downloadedMetadataCache.totalRecordsCount) \(AppCapitalization.format("RECORDS", enabled: isCaps))"
        case .artwork:
            return AppCapitalization.format(ByteFormatting.formatFileSize(bytes: artworkCacheSizeBytes), enabled: isCaps)
        case .jellyfinOffline:
            return "\(JellyfinDownloadManager.shared.downloadRecords.count) \(AppCapitalization.format("TRACKS", enabled: isCaps)) • \(AppCapitalization.format(JellyfinDownloadManager.shared.formattedTotalSize, enabled: isCaps))"
        case .merges:
            let groups = libraryStore.settings.albumMergeGroups
            let original = Set(groups.flatMap(\.memberIDs)).count
            let merged = groups.count
            return "\(original) \(AppCapitalization.format("ALBUMS MERGED INTO", enabled: isCaps)) \(merged)"
        case .everything:
            let sourceCount = libraryStore.settings.linkedFolders.count + libraryStore.settings.serverSources.count
            return "\(sourceCount) \(AppCapitalization.format("SOURCES", enabled: isCaps)) • \(libraryStore.tracks.count) \(AppCapitalization.format("TRACKS", enabled: isCaps)) • \(libraryStore.albums.count) \(AppCapitalization.format("ALBUMS", enabled: isCaps))"
        }
    }

    private var albumMergeModeSection: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(AppCapitalization.format("MERGE ALBUMS", enabled: isCaps))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Spacer(minLength: 8)

            Picker(selection: Binding(
                get: { libraryStore.settings.albumMergeMode },
                set: { newValue in
                    libraryStore.settings.albumMergeMode = newValue
                    libraryStore.saveSettings()
                    HapticFeedback.selectionChanged()
                }
            )) {
                ForEach(AlbumMergeMode.allCases) { mode in
                    Text(AppCapitalization.format(mode.rawValue, enabled: isCaps))
                        .lineLimit(1)
                        .tag(mode)
                }
            } label: {
                Text(AppCapitalization.format("MERGE ALBUMS", enabled: isCaps))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .tint(appTheme.accentColor)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.45) {
            HapticFeedback.softImpact(intensity: 0.50)
            activeDetail = SettingOptionCatalog.mergeAlbums
        }
        .contextMenu {
            Button {
                activeDetail = SettingOptionCatalog.mergeAlbums
            } label: {
                Text(AppCapitalization.format("OPTION INFO", enabled: isCaps))
            }
        }
    }

    private var cacheManagementSection: some View {
        let available = availableStorageClearTargets
        return VStack(alignment: .leading, spacing: 14) {
            Text(AppCapitalization.format("APP STORAGE MANAGEMENT", enabled: isCaps))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.storageManagementSection
                }

            if available.isEmpty {
                EmptyView()
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(AppCapitalization.format("CLEAR", enabled: isCaps))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    Spacer(minLength: 8)

                    // Same native menu-picker control as Appearance settings (shows up/down chevrons).
                    Picker(selection: $storageTarget) {
                        ForEach(available) { target in
                            Text(AppCapitalization.format(target.rawValue, enabled: isCaps))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .tag(target)
                        }
                    } label: {
                        Text(AppCapitalization.format("CLEAR", enabled: isCaps))
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .tint(appTheme.accentColor)
                    .onChange(of: storageTarget) { _, _ in
                        HapticFeedback.selectionChanged()
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(storageTargetDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(role: .destructive) {
                        HapticFeedback.notificationWarning()
                        switch storageTarget {
                        case .metadata: showingClearMetadataAlert = true
                        case .artwork: showingClearArtworkAlert = true
                        case .jellyfinOffline: showingClearDownloadsAlert = true
                        case .merges: showingClearMergesAlert = true
                        case .everything: showingClearEverythingAlert = true
                        }
                    } label: {
                        Text(AppCapitalization.format("CLEAR", enabled: isCaps))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { reconcileStorageClearTargetSelection() }
    }

    // MARK: - 7. Hidden Items Section
    private var hiddenItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                HapticFeedback.selectionChanged()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isHiddenExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(AppCapitalization.format("HIDDEN (\(libraryStore.hiddenItems.count))", enabled: isCaps))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(isHiddenExpanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHiddenExpanded {
                let manual = libraryStore.hiddenItems.filter { $0.kind != .autoDuplicate }
                let automatic = libraryStore.hiddenItems.filter { $0.kind == .autoDuplicate }
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !manual.isEmpty {
                        Text(AppCapitalization.format("MANUALLY HIDDEN", enabled: isCaps))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ForEach(manual) { item in
                            HiddenItemRow(item: item) {
                                HapticFeedback.notificationSuccess()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    libraryStore.returnHiddenItem(item)
                                }
                            }
                        }
                    }
                    if !automatic.isEmpty {
                        Text(AppCapitalization.format("AUTOMATICALLY HIDDEN", enabled: isCaps))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, manual.isEmpty ? 0 : 6)
                        ForEach(automatic) { item in
                            HiddenItemRow(item: item) {
                                HapticFeedback.notificationSuccess()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    libraryStore.returnHiddenItem(item)
                                }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshArtworkCacheSize() async {
        let size = await Task.detached(priority: .utility) {
            await ArtworkCacheService.shared.calculateDiskSize()
        }.value
        await MainActor.run {
            self.artworkCacheSizeBytes = size
        }
    }
}

// MARK: - Hidden Item Row (styled like TrackRowView)
private struct HiddenItemRow: View {
    let item: HiddenLibraryItem
    let onReturn: () -> Void
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    private var subtitle: String {
        if item.kind == .album || item.kind == .autoDuplicate {
            let count = item.records.count
            return "\(item.subtitle) • \(count) \(count == 1 ? AppCapitalization.format("TRACK", enabled: isCaps) : AppCapitalization.format("TRACKS", enabled: isCaps))"
        }
        return item.subtitle
    }

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtworkView(
                artworkKey: item.artworkKey,
                title: (item.kind == .album || item.kind == .autoDuplicate) ? item.title : (item.records.first?.track.album ?? item.title),
                subtitle: item.subtitle,
                cornerRadius: 6
            )
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onReturn) {
                Text(AppCapitalization.format("RETURN", enabled: isCaps))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(appTheme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}


// MARK: - Storage clear alerts (split out so Sources body type-checks)

private struct FolderSettingsStorageClearAlerts: ViewModifier {
    @Bindable var libraryStore: LibraryStore
    @Binding var showingClearMetadataAlert: Bool
    @Binding var showingClearArtworkAlert: Bool
    @Binding var showingClearDownloadsAlert: Bool
    @Binding var showingClearMergesAlert: Bool
    @Binding var showingClearEverythingAlert: Bool
    let refreshArtworkCacheSize: () async -> Void
    let onClearedMerges: () -> Void
    @Environment(\.isCapitalizationEnabled) private var isCaps: Bool

    func body(content: Content) -> some View {
        content
            .alert(AppCapitalization.format("CLEAR METADATA CACHE?", enabled: isCaps), isPresented: $showingClearMetadataAlert) {
                Button(AppCapitalization.format("CANCEL", enabled: isCaps), role: .cancel) {}
                Button(AppCapitalization.format("CLEAR", enabled: isCaps), role: .destructive) {
                    libraryStore.clearDownloadedMetadataCache()
                }
            } message: {
                Text(AppCapitalization.format("THIS WILL REMOVE ALL LOCALLY CACHED ONLINE METADATA MATCHES AND RESET ENRICHMENT QUEUES.", enabled: isCaps))
            }
            .alert(AppCapitalization.format("CLEAR ARTWORK CACHE?", enabled: isCaps), isPresented: $showingClearArtworkAlert) {
                Button(AppCapitalization.format("CANCEL", enabled: isCaps), role: .cancel) {}
                Button(AppCapitalization.format("CLEAR", enabled: isCaps), role: .destructive) {
                    libraryStore.clearArtworkCache()
                    Task { await refreshArtworkCacheSize() }
                }
            } message: {
                Text(AppCapitalization.format("THIS WILL REMOVE ALL CACHED COVER ARTWORKS FROM DISK. ARTWORKS WILL BE RE-EXTRACTED AS NEEDED.", enabled: isCaps))
            }
            .alert(AppCapitalization.format("CLEAR ALL DOWNLOADS?", enabled: isCaps), isPresented: $showingClearDownloadsAlert) {
                Button(AppCapitalization.format("CANCEL", enabled: isCaps), role: .cancel) {}
                Button(AppCapitalization.format("CLEAR", enabled: isCaps), role: .destructive) {
                    JellyfinDownloadManager.shared.deleteAllDownloads()
                }
            } message: {
                Text(AppCapitalization.format("THIS WILL REMOVE ALL DOWNLOADED SERVER TRACKS FROM DEVICE STORAGE. TRACKS WILL REMAIN IN YOUR LIBRARY AND CAN STILL BE STREAMED.", enabled: isCaps))
            }
            .alert(AppCapitalization.format("CLEAR MERGES?", enabled: isCaps), isPresented: $showingClearMergesAlert) {
                Button(AppCapitalization.format("CANCEL", enabled: isCaps), role: .cancel) {}
                Button(AppCapitalization.format("CLEAR", enabled: isCaps), role: .destructive) {
                    libraryStore.clearAllAlbumMerges()
                    onClearedMerges()
                }
            } message: {
                Text(AppCapitalization.format("THIS WILL UNMERGE ALL MANUALLY MERGED ALBUMS AND SHOW MERGE SUGGESTIONS AGAIN WHERE CANDIDATES EXIST.", enabled: isCaps))
            }
            .alert(AppCapitalization.format("CLEAR EVERYTHING?", enabled: isCaps), isPresented: $showingClearEverythingAlert) {
                Button(AppCapitalization.format("CANCEL", enabled: isCaps), role: .cancel) {}
                Button(AppCapitalization.format("CLEAR EVERYTHING", enabled: isCaps), role: .destructive) {
                    libraryStore.clearEverything()
                    Task { await refreshArtworkCacheSize() }
                }
            } message: {
                Text(AppCapitalization.format("THIS WILL PERMANENTLY REMOVE ALL SOURCES, TRACKS, ALBUMS, PLAYLISTS, ARTWORKS, AND ALL DATA SAVED IN THE APP. THIS ACTION CANNOT BE UNDONE.", enabled: isCaps))
            }
    }
}
