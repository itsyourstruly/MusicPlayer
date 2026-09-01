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
    @State private var showingUnlinkAlert: Bool = false
    @State private var duplicateScanStatusText: String? = nil
    @State private var duplicateBannerDismissTask: Task<Void, Never>? = nil
    @State private var showingMetadataComparison: Bool = false
    @State private var showingVerifiedGoodTracks: Bool = false
    @State private var showingUnmatchedTracks: Bool = false
    @State private var showingDuplicateResolver: Bool = false
    @State private var isScanningDuplicates: Bool = false
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

                // MARK: - 2. Track Enrichment Review Buttons (FOUND, GOOD, UNMATCHED, DUPLICATES)
                trackEnrichmentButtonsSection

                // MARK: - 3. Scan Library Metadata Online Button (Clean Text, No Background, No Icon)
                scanMetadataOnlineButtonSection

                // MARK: - 4. Disk Write Toggle
                diskWriteToggleSection

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.4))

                // MARK: - 5. Clean Library Scan Method Selector (METADATA vs FOLDER)
                scanMethodSelectorSection
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
                    Task {
                        await libraryStore.linkAndScanFolder(url: selectedURL)
                    }
                }
            case .failure(let error):
                AppLogger.library.error("Folder selection failed: \(error.localizedDescription)")
            }
        }
        .alert("UNLINK DIRECTORY?", isPresented: $showingUnlinkAlert) {
            Button("CANCEL", role: .cancel) {}
            Button("UNLINK", role: .destructive) {
                libraryStore.unlinkDirectory()
            }
        } message: {
            Text("THIS WILL REMOVE INDEXED TRACKS AND PLAYLISTS FROM THE APP. YOUR AUDIO FILES ON DISK WILL NOT BE MODIFIED OR DELETED.")
        }
        .sheet(isPresented: $showingMetadataComparison) {
            MetadataComparisonListView(libraryStore: libraryStore)
                .tint(appTheme.accentColor)
                .environment(\.appTheme, appTheme)
        }
        .sheet(isPresented: $showingVerifiedGoodTracks) {
            VerifiedGoodTracksListView(libraryStore: libraryStore)
                .tint(appTheme.accentColor)
                .environment(\.appTheme, appTheme)
        }
        .sheet(isPresented: $showingUnmatchedTracks) {
            UnmatchedTracksListView(libraryStore: libraryStore)
                .tint(appTheme.accentColor)
                .environment(\.appTheme, appTheme)
        }
        .sheet(isPresented: $showingDuplicateResolver) {
            DuplicateResolverView(libraryStore: libraryStore)
                .tint(appTheme.accentColor)
                .environment(\.appTheme, appTheme)
        }
        .sheet(item: $activeDetail) { detail in
            SettingOptionDetailSheet(detail: detail)
        }
        .onDisappear {
            duplicateBannerDismissTask?.cancel()
        }
    }

    // MARK: - 1. Linked Folder Header Section (Top of Sheet, No Background, Transient Status)
    private var linkedFolderHeaderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(libraryStore.settings.linkedFolderName != nil ? "LINKED TO \(libraryStore.settings.linkedFolderName!.uppercased())" : "LINKED TO MUSIC FOLDER")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                // Gear Icon with clean, all-caps, no-icon context menu
                Menu {
                    Button("CHANGE FOLDER") {
                        showingFolderPicker = true
                    }

                    Button("RESCAN LIBRARY") {
                        Task {
                            await libraryStore.rescanCurrentDirectory()
                        }
                    }
                    .disabled(libraryStore.isScanning || libraryStore.settings.linkedFolderName == nil)

                    Button(isScanningDuplicates ? "SCANNING DUPLICATES..." : "SCAN DUPLICATES") {
                        isScanningDuplicates = true
                        Task {
                            await libraryStore.recalculateDuplicates()
                            isScanningDuplicates = false
                            let count = libraryStore.duplicateGroups.count
                            if count == 0 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    duplicateScanStatusText = "NO DUPLICATES FOUND"
                                }
                            } else {
                                let wastedBytes = libraryStore.duplicateGroups.reduce(0) { $0 + $1.potentialSavedBytes }
                                let formattedSize = ByteFormatting.formatFileSize(bytes: wastedBytes).uppercased()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    duplicateScanStatusText = "FOUND \(count) DUPLICATE CLUSTER\(count == 1 ? "" : "S"). \(formattedSize) RECOVERABLE."
                                }
                            }
                            HapticFeedback.notificationSuccess()

                            duplicateBannerDismissTask?.cancel()
                            duplicateBannerDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                if !Task.isCancelled {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        duplicateScanStatusText = nil
                                    }
                                }
                            }
                        }
                    }
                    .disabled(isScanningDuplicates || libraryStore.tracks.isEmpty)

                    if libraryStore.settings.linkedFolderName != nil {
                        Divider()
                        Button(role: .destructive) {
                            showingUnlinkAlert = true
                        } label: {
                            Text("UNLINK FOLDER")
                        }
                    }
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }

            // Transient 5-Second Status Text for Duplicate Scan Results
            if let status = duplicateScanStatusText {
                Text(status)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.blue)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 2. Track Enrichment Buttons 2x2 Grid (FOUND, GOOD, UNMATCHED, DUPLICATES)
    private var trackEnrichmentButtonsSection: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            // 1. FOUND (Formerly Ready to Enrich)
            enrichmentCard(
                title: "FOUND",
                badge: "\(libraryStore.enrichmentDiffs.count) TRACKS",
                action: {
                    if !libraryStore.enrichmentDiffs.isEmpty {
                        showingMetadataComparison = true
                    }
                },
                detail: SettingOptionCatalog.enrichTracks,
                isDisabled: libraryStore.enrichmentDiffs.isEmpty
            )

            // 2. GOOD (Formerly Look Good)
            enrichmentCard(
                title: "GOOD",
                badge: "\(libraryStore.verifiedGoodCount) TRACKS",
                action: {
                    if libraryStore.verifiedGoodCount > 0 {
                        showingVerifiedGoodTracks = true
                    }
                },
                detail: SettingOptionCatalog.verifiedTracks,
                isDisabled: libraryStore.verifiedGoodCount == 0
            )

            // 3. UNMATCHED
            enrichmentCard(
                title: "UNMATCHED",
                badge: "\(libraryStore.unmatchedTracksCount) TRACKS",
                action: {
                    showingUnmatchedTracks = true
                },
                detail: SettingOptionCatalog.unmatchedTracks,
                isDisabled: false
            )

            // 4. DUPLICATES
            enrichmentCard(
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

    private func enrichmentCard(
        title: String,
        badge: String,
        action: @escaping () -> Void,
        detail: SettingOptionDetail,
        isDisabled: Bool
    ) -> some View {
        Button(action: {
            HapticFeedback.notificationSuccess()
            action()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(isDisabled ? Color.black.opacity(0.3) : Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(badge)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isDisabled ? Color.black.opacity(0.25) : Color.black.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu {
            Button("Option Info") {
                activeDetail = detail
            }
        }
    }

    // MARK: - 3. Scan Library Metadata Online Button (Clean Text, No Background, No Icon)
    private var scanMetadataOnlineButtonSection: some View {
        Button(action: {
            HapticFeedback.notificationSuccess()
            libraryStore.rescanAllMetadata()
        }) {
            Text(libraryStore.isBackgroundCheckingMetadata ? "SCANNING METADATA ONLINE..." : "SCAN LIBRARY METADATA ONLINE")
                .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                .foregroundStyle(libraryStore.isBackgroundCheckingMetadata ? Color.secondary : Color.blue)
        }
        .buttonStyle(.plain)
        .disabled(libraryStore.isBackgroundCheckingMetadata || libraryStore.tracks.isEmpty)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Option Info") {
                activeDetail = SettingOptionCatalog.rescanAllMetadata
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
}
