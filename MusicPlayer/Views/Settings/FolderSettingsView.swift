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
    @State private var serverToUnlink: JellyfinServerLink? = nil
    @State private var showingUnlinkServerAlert: Bool = false
    @State private var showingTagFinderSheet: Bool = false
    @State private var showingClearMetadataAlert: Bool = false
    @State private var showingClearArtworkAlert: Bool = false
    @State private var showingClearDownloadsAlert: Bool = false
    @State private var showingCloudWarningAlert: Bool = false
    @State private var cloudWarningMessage: String = ""
    @State private var artworkCacheSizeBytes: Int64 = 0
    @State private var activeDetail: SettingOptionDetail? = nil

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

                // MARK: - 2. Find Track Tags Button
                findTrackTagsButtonSection

                // MARK: - 3. Disk Write Toggle
                diskWriteToggleSection

                // MARK: - 3B. Downloads Section
                downloadsSection

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.4))

                // MARK: - 5. Clean Library Scan Method Selector (METADATA vs FOLDER)
                scanMethodSelectorSection

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
        .navigationTitle("FOLDER SETTINGS")
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
            Text("THIS WILL REMOVE ALL DOWNLOADED JELLYFIN TRACKS FROM DEVICE STORAGE. TRACKS WILL REMAIN IN YOUR LIBRARY AND CAN STILL BE STREAMED.")
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
                onJellyfinConnected: { serverLink in
                    handleJellyfinConnected(serverLink)
                }
            )
            .environment(\.appTheme, appTheme)
        }
        .alert("REMOVE JELLYFIN SERVER?", isPresented: $showingUnlinkServerAlert) {
            Button("CANCEL", role: .cancel) {
                serverToUnlink = nil
            }
            Button("REMOVE", role: .destructive) {
                if let server = serverToUnlink {
                    removeJellyfinServer(server)
                    serverToUnlink = nil
                }
            }
        } message: {
            Text("THIS WILL REMOVE TRACKS FROM THIS JELLYFIN SERVER FROM YOUR LIBRARY.")
        }
        .sheet(isPresented: $showingTagFinderSheet) {
            TrackTagFinderSheetView(libraryStore: libraryStore)
                .tint(appTheme.accentColor)
                .environment(\.appTheme, appTheme)
        }
        .sheet(item: $activeDetail) { detail in
            SettingOptionDetailSheet(detail: detail)
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
            let hasServers = !libraryStore.settings.jellyfinServers.isEmpty

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

                ForEach(libraryStore.settings.jellyfinServers) { server in
                    jellyfinServerRow(server: server)
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

    private func jellyfinServerRow(server: JellyfinServerLink) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("JELLYFIN: \(server.serverName.uppercased())")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button {
                    HapticFeedback.selectionChanged()
                    rescanJellyfinServer(server)
                } label: {
                    Text("RESCAN")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button(role: .destructive) {
                        serverToUnlink = server
                        showingUnlinkServerAlert = true
                    } label: {
                        Text("REMOVE SERVER")
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(appTheme.accentColor)
                        .padding(.leading, 8)
                        .contentShape(Rectangle())
                }
            }

            let serverTrackCount = libraryStore.trackCount(for: server)
            Text("USER: \(server.username.uppercased()) • \(serverTrackCount) TRACKS")
                .font(.system(size: 11, design: .monospaced))
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
        let isAnotherScanning = libraryStore.isScanning && !isThisScanning

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("LINKED TO \(folder.name.uppercased())")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button {
                    HapticFeedback.selectionChanged()
                    Task {
                        await libraryStore.rescanFolder(id: folder.id)
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isThisScanning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: libraryStore.settings.appTheme.accentColor))
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                            Text("SCANNING...")
                        } else {
                            Text("RESCAN")
                        }
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        isAnotherScanning
                            ? libraryStore.settings.appTheme.accentColor.opacity(0.35)
                            : libraryStore.settings.appTheme.accentColor
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.isScanning)
                .contextMenu {
                    Button {
                        activeDetail = SettingOptionCatalog.rescanFolder
                    } label: {
                        Text("OPTION INFO")
                    }
                }

                // Gear Icon with clean context menu
                Menu {
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
            Text("\(libraryStore.trackCount(for: folder)) TRACKS, \(libraryStore.albumCount(for: folder)) ALBUMS, \(libraryStore.artistCount(for: folder)) ARTISTS")
                .font(.system(size: 11, design: .monospaced))
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

    // MARK: - 3B. Downloads Section
    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DOWNLOADS & OFFLINE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            TypographicToggleRow(
                title: "DOWNLOAD NEXT SONG ON WI-FI",
                subtitle: "PRE-FETCHES UPCOMING QUEUE TRACKS SILENTLY WHEN CONNECTED TO WI-FI",
                isOn: Binding(
                    get: { libraryStore.settings.downloadNextSongOnWiFi },
                    set: {
                        libraryStore.settings.downloadNextSongOnWiFi = $0
                        libraryStore.saveSettings()
                    }
                )
            )

            TypographicToggleRow(
                title: "AUTO-DOWNLOAD ON PLAY",
                subtitle: "AUTOMATICALLY SAVES PLAYED JELLYFIN TRACKS TO DEVICE STORAGE",
                isOn: Binding(
                    get: { libraryStore.settings.autoDownloadOnPlay },
                    set: {
                        libraryStore.settings.autoDownloadOnPlay = $0
                        libraryStore.saveSettings()
                    }
                )
            )

            TypographicToggleRow(
                title: "DOWNLOAD OVER CELLULAR",
                subtitle: "ALLOW OFFLINE JELLYFIN DOWNLOADS WHEN NOT ON WI-FI",
                isOn: Binding(
                    get: { libraryStore.settings.downloadOnCellular },
                    set: {
                        libraryStore.settings.downloadOnCellular = $0
                        libraryStore.saveSettings()
                        JellyfinDownloadManager.shared.allowsCellularAccess = $0
                    }
                )
            )

            // Storage summary row & clear button
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("JELLYFIN OFFLINE STORAGE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    Text("\(JellyfinDownloadManager.shared.downloadRecords.count) TRACKS • \(JellyfinDownloadManager.shared.formattedTotalSize.uppercased())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !JellyfinDownloadManager.shared.downloadRecords.isEmpty {
                    Button(role: .destructive) {
                        HapticFeedback.notificationWarning()
                        showingClearDownloadsAlert = true
                    } label: {
                        Text("CLEAR ALL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 5. Clean Library Scan Method Selector (METADATA vs FOLDER)
    private var scanMethodSelectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LIBRARY SCAN METHOD")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            // Clean 2-Button Toggle (METADATA or FOLDER)
            HStack(spacing: 10) {
                // METADATA Button
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        libraryStore.setLibraryOrganization(.id3Tags)
                    }
                }) {
                    Text("METADATA")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.libraryScanMethod == .id3Tags ? Color.black : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            libraryStore.settings.libraryScanMethod == .id3Tags
                                ? Color.white
                                : appTheme.secondaryBackgroundColor
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                // FOLDER Button
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        libraryStore.setLibraryOrganization(.folderHierarchy)
                    }
                }) {
                    Text("FOLDER")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.libraryScanMethod == .folderHierarchy ? Color.black : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            libraryStore.settings.libraryScanMethod == .folderHierarchy
                                ? Color.white
                                : appTheme.secondaryBackgroundColor
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Description text displayed directly below the active selection
            Text(libraryStore.settings.libraryScanMethod.descriptionText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.top, 2)
                .padding(.horizontal, 2)
        }
    }

    private func handleJellyfinConnected(_ serverLink: JellyfinServerLink) {
        var linkToUse = serverLink
        if let existingIndex = libraryStore.settings.jellyfinServers.firstIndex(where: {
            $0.serverId == serverLink.serverId && $0.userId == serverLink.userId
        }) {
            let existing = libraryStore.settings.jellyfinServers[existingIndex]
            linkToUse = JellyfinServerLink(
                id: existing.id,
                serverId: serverLink.serverId,
                serverName: serverLink.serverName,
                userId: serverLink.userId,
                userName: serverLink.username,
                serverURL: serverLink.serverURL
            )
            libraryStore.settings.jellyfinServers[existingIndex] = linkToUse
            libraryStore.saveSettings()
        } else {
            libraryStore.settings.jellyfinServers.append(linkToUse)
            libraryStore.saveSettings()
        }
        rescanJellyfinServer(linkToUse)
    }

    private func rescanJellyfinServer(_ serverLink: JellyfinServerLink) {
        Task { @MainActor in
            await libraryStore.syncJellyfinServer(serverLink)
        }
    }

    private func removeJellyfinServer(_ serverLink: JellyfinServerLink) {
        libraryStore.removeJellyfinServer(id: serverLink.id)
        Task {
            await JellyfinClient.shared.logout(link: serverLink)
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
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)

                    Spacer()
                }
            }
        }
    }

    // MARK: - 6. Cache Management (CLEAR METADATA CACHE & CLEAR ARTWORK CACHE)
    private var cacheManagementSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CACHE MANAGEMENT")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            // Clear Metadata Cache
            HStack {
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    showingClearMetadataAlert = true
                }) {
                    Text("CLEAR METADATA CACHE")
                        .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(libraryStore.downloadedMetadataCache.totalRecordsCount) REC")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Clear Artwork Cache
            HStack {
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    showingClearArtworkAlert = true
                }) {
                    Text("CLEAR ARTWORK CACHE")
                        .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(ByteFormatting.formatFileSize(bytes: artworkCacheSizeBytes).uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
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
