import SwiftUI
import UniformTypeIdentifiers
import os

/// Dedicated folder and library indexing settings page housing linked directory operations,
/// track enrichment review sheets, and clean dual-mode scan selection.
public struct FolderSettingsView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

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
    @State private var showingCloudWarningAlert: Bool = false
    @State private var cloudWarningMessage: String = ""
    @State private var artworkCacheSizeBytes: Int64 = 0
    @State private var activeDetail: SettingOptionDetail? = nil
    // Pending (unsaved) local organization selection; nil = use saved settings
    @State private var pendingMethod: LibraryScanMethod? = nil
    @State private var pendingLayout: FolderHierarchyLayout? = nil
    @State private var isSavingOrganization: Bool = false
    @State private var storageTarget: StorageClearTarget = .metadata

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - 1. Linked To Folder Header with Gear Menu & Transient Scan Status
                linkedFolderHeaderSection

                // MARK: - Live Scanning Status Logs
                scanningStatusLogsView

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.4))

                // MARK: - 2. Find Track Tags Button (local sources only)
                if !libraryStore.settings.linkedFolders.isEmpty {
                    findTrackTagsButtonSection
                }

                // MARK: - 5. Library Scan Method (local sources only)
                if !libraryStore.settings.linkedFolders.isEmpty {
                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.4))

                    scanMethodSelectorSection
                }

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.4))

                // MARK: - 6. Cache Management (CLEAR METADATA CACHE & CLEAR ARTWORK CACHE)
                cacheManagementSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .padding(.bottom, 60)
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle("SOURCES")
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
        .alert("UNLINK DIRECTORY?", isPresented: $showingUnlinkAlert) {
            Button("CANCEL", role: .cancel) {
                folderToUnlink = nil
            }
            Button("UNLINK", role: .destructive) {
                if let folder = folderToUnlink {
                    libraryStore.unlinkFolder(id: folder.id)
                    folderToUnlink = nil
                } else {
                    libraryStore.unlinkDirectory()
                }
            }
        } message: {
            Text("THIS WILL REMOVE INDEXED TRACKS AND PLAYLISTS FROM THE APP. YOUR AUDIO FILES ON DISK WILL NOT BE MODIFIED OR DELETED.")
        }
        .alert("CLEAR METADATA CACHE?", isPresented: $showingClearMetadataAlert) {
            Button("CANCEL", role: .cancel) {}
            Button("CLEAR", role: .destructive) {
                libraryStore.clearDownloadedMetadataCache()
            }
        } message: {
            Text("THIS WILL REMOVE ALL LOCALLY CACHED ONLINE METADATA MATCHES AND RESET ENRICHMENT QUEUES.")
        }
        .alert("CLEAR ARTWORK CACHE?", isPresented: $showingClearArtworkAlert) {
            Button("CANCEL", role: .cancel) {}
            Button("CLEAR", role: .destructive) {
                libraryStore.clearArtworkCache()
                Task {
                    await refreshArtworkCacheSize()
                }
            }
        } message: {
            Text("THIS WILL REMOVE ALL CACHED COVER ARTWORKS FROM DISK. ARTWORKS WILL BE RE-EXTRACTED AS NEEDED.")
        }
        .alert("CLEAR ALL DOWNLOADS?", isPresented: $showingClearDownloadsAlert) {
            Button("CANCEL", role: .cancel) {}
            Button("CLEAR", role: .destructive) {
                JellyfinDownloadManager.shared.deleteAllDownloads()
            }
        } message: {
            Text("THIS WILL REMOVE ALL DOWNLOADED SERVER TRACKS FROM DEVICE STORAGE. TRACKS WILL REMAIN IN YOUR LIBRARY AND CAN STILL BE STREAMED.")
        }
        .alert("CLEAR EVERYTHING?", isPresented: $showingClearEverythingAlert) {
            Button("CANCEL", role: .cancel) {}
            Button("CLEAR EVERYTHING", role: .destructive) {
                libraryStore.clearEverything()
                Task {
                    await refreshArtworkCacheSize()
                }
            }
        } message: {
            Text("THIS WILL PERMANENTLY REMOVE ALL SOURCES, TRACKS, ALBUMS, PLAYLISTS, ARTWORKS, AND ALL DATA SAVED IN THE APP. THIS ACTION CANNOT BE UNDONE.")
        }
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
    }

    // MARK: - 1. Linked Folder & Server Sources Header Section (Top of Sheet, No Background)
    private var linkedFolderHeaderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            let hasFolders = !libraryStore.settings.linkedFolders.isEmpty
            let hasServers = !libraryStore.settings.serverSources.isEmpty

            if !hasFolders && !hasServers {
                HStack(alignment: .center) {
                    Button(action: {
                        showingAddSourceSheet = true
                    }) {
                        Text("ADD SOURCE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            } else {
                ForEach(libraryStore.settings.linkedFolders) { folder in
                    linkedFolderRow(folder: folder)
                }

                ForEach(libraryStore.settings.serverSources) { server in
                    serverRow(server: server)
                }

                Button(action: {
                    showingAddSourceSheet = true
                }) {
                    Text("ADD ANOTHER SOURCE")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func serverRow(server: ServerSourceLink) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("\(server.displayLabel) - \(server.username.uppercased())")
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
                        Text("RESCAN")
                    }
                    .disabled(libraryStore.isScanning)

                    Divider()
                    Button(role: .destructive) {
                        serverToUnlink = server
                        showingUnlinkServerAlert = true
                    } label: {
                        Text("REMOVE SERVER")
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
                 : "\(serverTrackCount) TRACKS, \(libraryStore.albumCount(for: server)) ALBUMS, \(libraryStore.artistCount(for: server)) ARTISTS")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            if let error = libraryStore.jellyfinServerErrors[server.id] {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)

                    if error.contains("LOCAL NETWORK ACCESS IS OFF") {
                        #if os(iOS)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString),
                               UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text("OPEN SETTINGS")
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
                Text(folder.name.uppercased())
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
                        Text(isThisScanning ? "SCANNING..." : "RESCAN")
                    }
                    .disabled(libraryStore.isScanning)

                    Button {
                        HapticFeedback.selectionChanged()
                        folderForPlaylistFinder = folder
                    } label: {
                        Text("FIND PLAYLIST")
                    }

                    Button(action: {
                        folderToChange = folder
                        showingFolderPicker = true
                    }) {
                        Text("CHANGE FOLDER")
                    }

                    Button {
                        libraryStore.toggleTagEnrichmentExclusion(for: folder.id)
                    } label: {
                        Text(folder.isExcludedFromTagEnrichment ? "EXCLUDE FROM TAG ENRICHMENT (SELECTED)" : "EXCLUDE FROM TAG ENRICHMENT")
                    }

                    Divider()
                    Button(role: .destructive) {
                        folderToUnlink = folder
                        showingUnlinkAlert = true
                    } label: {
                        Text("UNLINK FOLDER")
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
                 : "\(libraryStore.trackCount(for: folder)) TRACKS, \(libraryStore.albumCount(for: folder)) ALBUMS, \(libraryStore.artistCount(for: folder)) ARTISTS")
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
                    Text("FIND TRACK TAGS")
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
                        Text("\(libraryStore.visibleEnrichmentDiffs.count) FOUND • \(libraryStore.visibleVerifiedGoodCount) GOOD • \(libraryStore.unmatchedTracksCount) LOST • \(libraryStore.visibleDuplicateGroups.count) DUPES")
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
                Text("OPTION INFO")
            }
        }
    }

    // MARK: - 4. Disk Write Toggle
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
    private var hasPendingOrganizationChange: Bool {
        let saved = libraryStore.settings
        if effectiveMethod != saved.libraryScanMethod { return true }
        // Layout only matters (and only shows) in FOLDER mode
        return effectiveMethod == .folderHierarchy && effectiveLayout != saved.folderHierarchyLayout
    }

    private var scanMethodSelectorSection: some View {
        let isFolder = effectiveMethod == .folderHierarchy

        return VStack(alignment: .leading, spacing: 12) {
            Text("LOCAL FOLDER ORGANIZATION")
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
                        if !isFolder { Label("METADATA", systemImage: "checkmark") } else { Text("METADATA") }
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
                                    Label(layout.displayName, systemImage: "checkmark")
                                } else {
                                    Text(layout.displayName)
                                }
                            }
                        }
                    } label: {
                        if isFolder { Label("FOLDER", systemImage: "checkmark") } else { Text("FOLDER") }
                    }
                } label: {
                    Text(isFolder ? "FOLDER" : "METADATA")
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
                        Text(isSavingOrganization ? "SAVING..." : "SAVE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingOrganization)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasPendingOrganizationChange || isSavingOrganization)
    }

    private func saveOrganization() {
        guard !isSavingOrganization else { return }
        let method = effectiveMethod
        let layout = effectiveLayout
        isSavingOrganization = true
        Task { @MainActor in
            await libraryStore.applyLocalOrganization(method: method, layout: layout)
            HapticFeedback.notificationSuccess()
            withAnimation(.easeInOut(duration: 0.2)) {
                pendingMethod = nil
                pendingLayout = nil
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
        let status = libraryStore.scanStatusText.uppercased()
        return status.isEmpty ? "INDEXING..." : status
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
                Text(libraryStore.scanStatusText.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text("INDEXING: \(Int(libraryStore.scanProgress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)

                    Spacer()
                }
            }
        }
    }

    // MARK: - 6. Cache Management (CLEAR METADATA CACHE & CLEAR ARTWORK CACHE)
    private enum StorageClearTarget: String, CaseIterable, Identifiable {
        case metadata = "LOCAL TRACKS METADATA CACHE"
        case artwork = "ARTWORK CACHE"
        case jellyfinOffline = "SERVER OFFLINE STORAGE"
        case everything = "EVERYTHING"
        var id: String { rawValue }
    }

    private var storageTargetDetail: String {
        switch storageTarget {
        case .metadata:
            return "\(libraryStore.downloadedMetadataCache.totalRecordsCount) RECORDS"
        case .artwork:
            return ByteFormatting.formatFileSize(bytes: artworkCacheSizeBytes).uppercased()
        case .jellyfinOffline:
            return "\(JellyfinDownloadManager.shared.downloadRecords.count) TRACKS • \(JellyfinDownloadManager.shared.formattedTotalSize.uppercased())"
        case .everything:
            let sourceCount = libraryStore.settings.linkedFolders.count + libraryStore.settings.serverSources.count
            return "\(sourceCount) SOURCES • \(libraryStore.tracks.count) TRACKS • \(libraryStore.albums.count) ALBUMS"
        }
    }

    private var cacheManagementSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APP STORAGE MANAGEMENT")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.storageManagementSection
                }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("CLEAR")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)

                Menu {
                    ForEach(StorageClearTarget.allCases) { target in
                        Button {
                            HapticFeedback.selectionChanged()
                            storageTarget = target
                        } label: {
                            if storageTarget == target {
                                Label(target.rawValue, systemImage: "checkmark")
                            } else {
                                Text(target.rawValue)
                            }
                        }
                    }
                } label: {
                    Text(storageTarget.rawValue)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
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
                    case .everything: showingClearEverythingAlert = true
                    }
                } label: {
                    Text("CLEAR")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
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
