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
    @State private var folderToChange: LinkedFolder? = nil
    @State private var folderToUnlink: LinkedFolder? = nil
    @State private var showingUnlinkAlert: Bool = false
    @State private var showingTagFinderSheet: Bool = false
    @State private var showingClearMetadataAlert: Bool = false
    @State private var showingClearArtworkAlert: Bool = false
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
            allowedContentTypes: [.folder, .audio, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let selectedURL = urls.first {
                    if let folder = folderToChange {
                        Task {
                            await libraryStore.changeFolder(id: folder.id, newURL: selectedURL)
                        }
                    } else {
                        Task {
                            await libraryStore.addAndScanFolder(url: selectedURL)
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
        .alert("ICLOUD STORAGE DETECTED", isPresented: $showingCloudWarningAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloudWarningMessage)
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
            await refreshArtworkCacheSize()
        }
    }

    // MARK: - 1. Linked Folder Header Section (Top of Sheet, No Background)
    private var linkedFolderHeaderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if libraryStore.settings.linkedFolders.isEmpty {
                HStack(alignment: .center) {
                    Button(action: {
                        folderToChange = nil
                        showingFolderPicker = true
                    }) {
                        Text("LINK FOLDER")
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

                Button(action: {
                    folderToChange = nil
                    showingFolderPicker = true
                }) {
                    Text("ADD ANOTHER FOLDER")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(libraryStore.settings.appTheme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func linkedFolderRow(folder: LinkedFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("LINKED TO \(folder.name.uppercased())")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text("RESCAN")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        libraryStore.isScanning
                            ? libraryStore.settings.appTheme.accentColor.opacity(0.4)
                            : libraryStore.settings.appTheme.accentColor
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        libraryStore.isScanning
                            ? nil
                            : LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    HapticFeedback.notificationSuccess()
                                    activeDetail = SettingOptionCatalog.rescanFolder
                                }
                                .exclusively(before: TapGesture().onEnded {
                                    Task {
                                        await libraryStore.rescanFolder(id: folder.id)
                                    }
                                })
                    )

                // Gear Icon with clean context menu
                Menu {
                    Button("CHANGE FOLDER") {
                        folderToChange = folder
                        showingFolderPicker = true
                    }

                    Button {
                        libraryStore.toggleTagEnrichmentExclusion(for: folder.id)
                    } label: {
                        if folder.isExcludedFromTagEnrichment {
                            Label("EXCLUDE FROM TAG ENRICHMENT", systemImage: "checkmark")
                        } else {
                            Text("EXCLUDE FROM TAG ENRICHMENT")
                        }
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
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    HapticFeedback.notificationSuccess()
                    activeDetail = SettingOptionCatalog.findTrackTags
                }
                .exclusively(before: TapGesture().onEnded {
                    HapticFeedback.notificationSuccess()
                    showingTagFinderSheet = true
                })
        )
        .contextMenu {
            Button("Option Info") {
                activeDetail = SettingOptionCatalog.findTrackTags
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
                        libraryStore.settings.libraryScanMethod = .id3Tags
                        libraryStore.saveSettings()
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
                        libraryStore.settings.libraryScanMethod = .folderHierarchy
                        libraryStore.saveSettings()
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
