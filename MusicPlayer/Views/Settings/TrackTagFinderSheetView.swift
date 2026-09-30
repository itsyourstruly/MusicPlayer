import SwiftUI

/// Tab categories for the unified Track Tag Finder sheet.
public enum TrackTagFinderTab: String, CaseIterable, Identifiable, Sendable {
    case lost = "LOST"
    case found = "FOUND"
    case good = "GOOD"
    case duplicates = "DUPLICATES"

    public var id: String { rawValue }
}

/// Unified Track Tag Finder sheet consolidating LOST, FOUND, GOOD, and DUPLICATES
/// with interactive scan progress, live track discovery, and batch enrichment.
public struct TrackTagFinderSheetView: View {
    var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    // Navigation & Tab State
    @State private var selectedTab: TrackTagFinderTab = .found
    @State private var searchText: String = ""

    // FOUND Tab States
    @State private var preserveFeatures: Bool = true
    @State private var isEnrichingAll: Bool = false
    @State private var enrichProcessedCount: Int = 0
    @State private var enrichTotalCount: Int = 0
    @State private var enrichProgress: Double = 0.0
    @State private var enrichStatusText: String = ""
    @State private var selectedTrackForCustomSearch: Track? = nil
    @State private var selectedSourceForCustomSearch: MetadataAPIOption = .all

    // GOOD & LOST Tab States
    @State private var recheckingTrackID: UUID? = nil
    @State private var trackStatusMessages: [UUID: String] = [:]

    // DUPLICATES Tab States
    @State private var trackToDelete: Track? = nil
    @State private var showingDeleteAllDuplicatesAlert: Bool = false
    @State private var isProcessingDeletion: Bool = false
    @State private var isScanningDuplicates: Bool = false

    // Cloud / Disk Write Alert State
    @State private var showingCloudDiskWriteAlert: Bool = false
    @State private var cloudDiskWriteAlertMessage: String = ""

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // MARK: - Computed Filtered Collections

    private var filteredEnrichmentDiffs: [MetadataDiff] {
        let query = FuzzyMatcher.normalize(searchText)
        let list = libraryStore.visibleEnrichmentDiffs
        if query.isEmpty { return list }
        return list.filter { diff in
            diff.localTrack.searchTokens.contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.title).contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.artist).contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.album).contains(query)
        }
    }

    private var filteredVerifiedGoodDiffs: [MetadataDiff] {
        let query = FuzzyMatcher.normalize(searchText)
        let list = libraryStore.visibleVerifiedGoodDiffs
        if query.isEmpty { return list }
        return list.filter { diff in
            diff.localTrack.searchTokens.contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.title).contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.artist).contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.album).contains(query)
        }
    }

    private var filteredUnmatchedTracks: [Track] {
        let query = FuzzyMatcher.normalize(searchText)
        let list = libraryStore.unmatchedTracks
        if query.isEmpty { return list }
        return list.filter { track in
            track.searchTokens.contains(query)
        }
    }

    private var filteredDuplicateGroups: [DuplicateGroup] {
        let query = FuzzyMatcher.normalize(searchText)
        let list = libraryStore.visibleDuplicateGroups
        if query.isEmpty { return list }
        return list.filter { group in
            FuzzyMatcher.normalize(group.displayTitle).contains(query) ||
            FuzzyMatcher.normalize(group.displayArtist).contains(query) ||
            group.normalizedTitle.contains(query) ||
            group.normalizedArtist.contains(query)
        }
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Search Bar (Always visible)
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                // Scrollable Content
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 4 Text Tab Buttons (LOST, FOUND, GOOD, DUPLICATES)
                        tabButtonsSection

                        // Counter Text & Music Services Attribution
                        headerSummarySection

                        // Tab-Specific Option Controls
                        tabOptionsSection

                        // Action Buttons: "ENRICH ALL" and "SCAN ALL TRACKS ONLINE"
                        actionButtonsSection

                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.35))
                            .padding(.vertical, 4)

                        // Results List for Selected Tab
                        tabResultsListSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .padding(.bottom, 40)
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("FIND TRACK TAGS")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedTrackForCustomSearch) { track in
                OnlineMetadataMatchSheet(track: track, libraryStore: libraryStore, initialSource: selectedSourceForCustomSearch)
                    .tint(appTheme.accentColor)
                    .environment(\.appTheme, appTheme)
            }
            .onAppear {
                libraryStore.indexCompleteTracksIntoVerifiedGood()
            }
            .alert("DELETE DUPLICATES FROM DISK?", isPresented: $showingDeleteAllDuplicatesAlert) {
                Button("CANCEL", role: .cancel) {}
                Button("DELETE FILES", role: .destructive) {
                    deleteAllSecondaryDuplicates()
                }
            } message: {
                let bytes = libraryStore.totalDuplicateSavingsBytes
                let count = libraryStore.totalDuplicateTracksCount
                Text("This will permanently delete \(count) redundant duplicate audio files (\(ByteFormatting.formatFileSize(bytes: bytes))) from disk. Your primary versions will be safely preserved.")
            }
            .alert("DELETE FILE FROM DISK?", isPresented: Binding(
                get: { trackToDelete != nil },
                set: { if !$0 { trackToDelete = nil } }
            )) {
                Button("CANCEL", role: .cancel) {}
                Button("DELETE", role: .destructive) {
                    if let track = trackToDelete {
                        deleteSingleTrack(track)
                    }
                }
            } message: {
                if let track = trackToDelete {
                    Text("Are you sure you want to permanently delete \"\(track.title)\" from disk? This cannot be undone.")
                }
            }
            .alert("ICLOUD STORAGE DETECTED", isPresented: $showingCloudDiskWriteAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cloudDiskWriteAlertMessage)
            }
        }
    }

    // MARK: - 1. Top Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)

            TextField("SEARCH TRACK, ALBUM, OR ARTIST...", text: $searchText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .textFieldStyle(.plain)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button("CLEAR") {
                    searchText = ""
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(appTheme.separatorColor.opacity(0.6)),
            alignment: .bottom
        )
    }

    // MARK: - 2. Four Text Tab Buttons (LOST, FOUND, GOOD, DUPLICATES)

    private var tabButtonsSection: some View {
        HStack(spacing: 26) {
            ForEach(TrackTagFinderTab.allCases) { tab in
                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(selectedTab == tab ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }

    // MARK: - 3. Header Counter & Dynamic Provider Text

    private var headerSummarySection: some View {
        HStack(alignment: .firstTextBaseline) {
            // Counter Text
            Group {
                switch selectedTab {
                case .lost:
                    Text("\(libraryStore.unmatchedTracksCount) LOST")
                case .found:
                    Text("\(libraryStore.visibleEnrichmentDiffs.count) FOUND")
                case .good:
                    Text("\(libraryStore.visibleVerifiedGoodCount) GOOD")
                case .duplicates:
                    Text("FOUND \(libraryStore.totalDuplicateTracksCount) DUPLICATES")
                }
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.primary)

            Spacer()
        }
    }

    // MARK: - 4. Tab-Specific Options Section

    @ViewBuilder
    private var tabOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch selectedTab {
            case .found:
                TypographicToggleRow(
                    title: "PRESERVE LOCAL TITLES & FEATURES",
                    subtitle: "RETAINS GUEST ARTISTS & CUSTOM TITLES",
                    isOn: $preserveFeatures
                )

                TypographicToggleRow(
                    title: "WRITE TAGS TO FILES ON DISK",
                    subtitle: "EMBEDS ID3V2/M4A/FLAC TAGS DIRECTLY INTO AUDIO FILES",
                    isOn: Binding(
                        get: { libraryStore.settings.writeMetadataToAudioFiles },
                        set: { newValue in
                            libraryStore.settings.writeMetadataToAudioFiles = newValue
                            libraryStore.saveSettings()
                            if newValue {
                                let rootURL = SecurityScopedBookmark.shared.currentFolderURL ?? SecurityScopedBookmark.shared.resolveAndAccessBookmark()
                                if let root = rootURL, AudioFileMetadataWriter.isCloudStorageURL(root) {
                                    cloudDiskWriteAlertMessage = "Your music files are stored in iCloud Drive / cloud storage. Files in cloud storage cannot be modified directly on disk. Enriched metadata will be kept safely within the app."
                                    showingCloudDiskWriteAlert = true
                                }
                            }
                        }
                    )
                )

            case .good:
                Text("LOCAL AUDIO TAGS MATCH OFFICIAL ONLINE RECORDS. YOU CAN REVIEW MATCHES, CUSTOM SEARCH, OR RESCAN.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

            case .lost:
                Text("TRACKS WITHOUT AUTOMATIC EXACT ONLINE MATCHES. YOU CAN RUN TARGETED SEARCHES OR RECHECK INDIVIDUALLY.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

            case .duplicates:
                HStack {
                    Text("\(libraryStore.visibleDuplicateGroups.count) CLUSTERS • \(ByteFormatting.formatFileSize(bytes: libraryStore.totalDuplicateSavingsBytes)) SAVINGS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 5. Action Buttons

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            // White Button: "ENRICH ALL [amount] TRACKS" (Only shown when FOUND tab has results, or while actively enriching)
            if selectedTab == .found && (!libraryStore.visibleEnrichmentDiffs.isEmpty || isEnrichingAll || libraryStore.isEnrichingMetadata) {
                let isBusy = isEnrichingAll || libraryStore.isEnrichingMetadata
                Button(action: {
                    enrichAllDiffs()
                }) {
                    let current = enrichProcessedCount > 0 ? enrichProcessedCount : libraryStore.enrichProcessedCount
                    let total = enrichTotalCount > 0 ? enrichTotalCount : (libraryStore.enrichTotalCount > 0 ? libraryStore.enrichTotalCount : libraryStore.visibleEnrichmentDiffs.count)
                    Text(isBusy ? "\(current)/\(total)" : "ENRICH ALL \(libraryStore.visibleEnrichmentDiffs.count) TRACKS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy || libraryStore.visibleEnrichmentDiffs.isEmpty)
            }

            if selectedTab == .duplicates {
                // Duplicates Tab Action Deck: Scan Library for Duplicates + Auto-Resolve & Delete Duplicates Side-by-Side
                duplicatesActionSection
            } else {
                // Interactive "SCAN ALL TRACKS ONLINE" Button with Progress, Pause/Play, and Cancel
                scanAllTracksButton

                Text("LAC WILL COMPARE YOUR LOCAL TRACK METADATA INCLUDING TRACK TITLE, ARTIST, AND ALBUM TO FIND THE MOST ACCURATE MATCH ACROSS APPLE MUSIC, DEEZER, AND MUSICBRAINZ. RESULTS WILL NOT BE PERFECT. I HIGHLY RECOMMEND YOU DOUBLE CHECK BEFORE ENRICHING. FOR BETTER RESULTS, SEARCH ALBUMS OR TRACKS INDIVIDUALLY.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .lineSpacing(3)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Duplicates Tab Actions

    private var duplicatesActionSection: some View {
        VStack(spacing: 10) {
            // Primary "SCAN LIBRARY FOR DUPLICATES" Button
            Button(action: {
                HapticFeedback.notificationSuccess()
                isScanningDuplicates = true
                Task {
                    await libraryStore.recalculateDuplicates()
                    isScanningDuplicates = false
                }
            }) {
                HStack(spacing: 8) {
                    if isScanningDuplicates {
                        ProgressView()
                            .tint(Color.black)
                            .scaleEffect(0.85)
                        Text("SCANNING LIBRARY FOR DUPLICATES...")
                    } else {
                        Text("SCAN LIBRARY FOR DUPLICATES")
                    }
                }
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isScanningDuplicates || libraryStore.tracks.isEmpty)

            // Side-by-Side Action Buttons: "AUTO-RESOLVE" and "DELETE DUPLICATES"
            HStack(spacing: 10) {
                // AUTO-RESOLVE Button
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    libraryStore.autoResolveAllDuplicates()
                }) {
                    Text("AUTO-RESOLVE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.visibleDuplicateGroups.isEmpty || isScanningDuplicates || isProcessingDeletion)
                .opacity(libraryStore.visibleDuplicateGroups.isEmpty ? 0.4 : 1.0)

                // DELETE DUPLICATES Button
                Button(action: {
                    showingDeleteAllDuplicatesAlert = true
                }) {
                    HStack(spacing: 6) {
                        if isProcessingDeletion {
                            ProgressView()
                                .tint(Color.red)
                                .scaleEffect(0.8)
                            Text("DELETING...")
                        } else {
                            Text("DELETE DUPLICATES")
                        }
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.visibleDuplicateGroups.isEmpty || libraryStore.totalDuplicateTracksCount == 0 || isScanningDuplicates || isProcessingDeletion)
                .opacity((libraryStore.visibleDuplicateGroups.isEmpty || libraryStore.totalDuplicateTracksCount == 0) ? 0.4 : 1.0)
            }
        }
    }

    // MARK: - Interactive Scan All Tracks Online Button

    private var scanAllTracksButton: some View {
        Group {
            if !libraryStore.isBackgroundCheckingMetadata {
                // Idle State: Clean white button with black text
                Button(action: {
                    HapticFeedback.notificationSuccess()
                    libraryStore.rescanAllMetadata()
                }) {
                    Text("SCAN ALL TRACKS ONLINE")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.tracks.isEmpty)
            } else {
                // Active Scanning or Paused State: White card with progress tracker and controls
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        Text("\(libraryStore.backgroundCheckScannedCount)/\(libraryStore.backgroundCheckTotalCount)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.black)

                        Spacer()

                        Button(action: {
                            HapticFeedback.selectionChanged()
                            if libraryStore.isBackgroundCheckingMetadataPaused {
                                libraryStore.resumeBackgroundMetadataScan()
                            } else {
                                libraryStore.pauseBackgroundMetadataScan()
                            }
                        }) {
                            Text(libraryStore.isBackgroundCheckingMetadataPaused ? "PLAY" : "PAUSE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(libraryStore.isBackgroundCheckingMetadataPaused ? libraryStore.settings.appTheme.accentColor : Color.gray)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, libraryStore.isBackgroundCheckingMetadataPaused ? 8 : 12)

                    // When paused, display large red CANCEL button
                    if libraryStore.isBackgroundCheckingMetadataPaused {
                        Divider()
                            .overlay(Color.black.opacity(0.12))
                            .padding(.horizontal, 10)

                        Button(action: {
                            HapticFeedback.notificationWarning()
                            libraryStore.cancelBackgroundMetadataScan()
                        }) {
                            Text("CANCEL")
                                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: - 6. Tab Results List Section

    @ViewBuilder
    private var tabResultsListSection: some View {
        switch selectedTab {
        case .lost:
            lostTracksList
        case .found:
            foundTracksList
        case .good:
            goodTracksList
        case .duplicates:
            duplicatesList
        }
    }

    // MARK: - LOST Tab List

    private var lostTracksList: some View {
        LazyVStack(spacing: 16) {
            if filteredUnmatchedTracks.isEmpty {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "NO UNMATCHED TRACKS" : "NO MATCHING TRACKS FOUND")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text(searchText.isEmpty ? "All tracks in your library have either been matched or verified." : "No unmatched track matches '\(searchText)'.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 32)
            } else {
                ForEach(filteredUnmatchedTracks) { track in
                    UnmatchedTrackCardView(
                        track: track,
                        isChecking: recheckingTrackID == track.id,
                        statusMessage: trackStatusMessages[track.id],
                        onRecheck: {
                            recheckSingleUnmatchedTrack(track)
                        },
                        onManualSearch: {
                            selectedSourceForCustomSearch = .all
                            selectedTrackForCustomSearch = track
                        }
                    )

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.35))
                }
            }
        }
    }

    // MARK: - FOUND Tab List

    private var foundTracksList: some View {
        LazyVStack(spacing: 16) {
            if filteredEnrichmentDiffs.isEmpty {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "NO PENDING ENRICHMENTS" : "NO MATCHING TRACKS FOUND")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text(searchText.isEmpty ? "Scan all tracks online to search for tag improvements and high-res artwork." : "No pending track matches '\(searchText)'.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 32)
            } else {
                ForEach(filteredEnrichmentDiffs) { diff in
                    SwipeableMetadataTrackCard(
                        diff: diff,
                        preserveFeatures: preserveFeatures,
                        isRecheckingAPI: recheckingTrackID == diff.localTrack.id,
                        onApply: { lockedFields in
                            applyDiffWithCustomLocks(diff: diff, lockedFields: lockedFields)
                        },
                        onKeepLocal: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                libraryStore.dismissEnrichmentDiff(diffID: diff.id)
                            }
                        },
                        onCustomSearch: {
                            selectedSourceForCustomSearch = .all
                            selectedTrackForCustomSearch = diff.localTrack
                        },
                        onSelectAPI: { source in
                            recheckTrackWithSource(track: diff.localTrack, source: source)
                        }
                    )

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.35))
                }
            }
        }
    }

    // MARK: - GOOD Tab List

    private var goodTracksList: some View {
        LazyVStack(spacing: 16) {
            if filteredVerifiedGoodDiffs.isEmpty {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "NO VERIFIED TRACKS" : "NO MATCHING TRACKS FOUND")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text(searchText.isEmpty ? "Tracks that already match online records will appear here." : "No verified track matches '\(searchText)'.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 32)
            } else {
                ForEach(filteredVerifiedGoodDiffs) { diff in
                    VerifiedGoodTrackCard(
                        diff: diff,
                        isRechecking: recheckingTrackID == diff.localTrack.id,
                        onCustomSearch: {
                            selectedSourceForCustomSearch = .all
                            selectedTrackForCustomSearch = diff.localTrack
                        },
                        onRescan: {
                            recheckSingleVerifiedTrack(diff.localTrack)
                        },
                        onSelectAPI: { source in
                            recheckTrackWithSource(track: diff.localTrack, source: source)
                        }
                    )

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.35))
                }
            }
        }
    }

    // MARK: - DUPLICATES Tab List

    private var duplicatesList: some View {
        LazyVStack(spacing: 16) {
            if filteredDuplicateGroups.isEmpty {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "NO DUPLICATE TRACKS FOUND" : "NO MATCHING DUPLICATES")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text(searchText.isEmpty ? "Your library has no detected duplicate tracks." : "No duplicate cluster matches '\(searchText)'.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 32)
            } else {
                ForEach(filteredDuplicateGroups) { group in
                    DuplicateClusterCardView(
                        group: group,
                        isDeleting: isProcessingDeletion,
                        onSelectPrimary: { candidateID in
                            HapticFeedback.selectionChanged()
                            libraryStore.resolveDuplicate(groupID: group.id, selectedPrimaryTrackID: candidateID)
                        },
                        onDeleteTrack: { track in
                            trackToDelete = track
                        }
                    )

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.35))
                }
            }
        }
    }

    // MARK: - Action Helpers

    private func applyDiffWithCustomLocks(diff: MetadataDiff, lockedFields: Set<MetadataField>) {
        let local = diff.localTrack
        let online = diff.onlineMetadata

        let shouldPreserveTitle = preserveFeatures || lockedFields.contains(.title)
        let shouldPreserveArtist = preserveFeatures || lockedFields.contains(.artist)

        let hasLocalFeatureInTitle = local.title.lowercased().contains("feat") || local.title.lowercased().contains("ft.")
        let hasOnlineFeatureInTitle = online.title.lowercased().contains("feat") || online.title.lowercased().contains("ft.")
        let finalTitle: String
        if shouldPreserveTitle || (hasLocalFeatureInTitle && !hasOnlineFeatureInTitle) {
            finalTitle = local.title
        } else {
            finalTitle = online.title
        }

        let isLocalMultiArtist = ArtistParser.parseArtists(from: local.artist).count > 1 ||
                                 local.artist.lowercased().contains(" & ") ||
                                 local.artist.lowercased().contains(", ") ||
                                 local.artist.lowercased().contains(" feat") ||
                                 local.artist.lowercased().contains(" ft.")
        let isOnlineMultiArtist = ArtistParser.parseArtists(from: online.artist).count > 1
        let finalArtist: String
        if shouldPreserveArtist || (isLocalMultiArtist && !isOnlineMultiArtist) {
            finalArtist = local.artist
        } else {
            finalArtist = online.artist
        }

        let finalAlbum = lockedFields.contains(.album) ? local.album : (online.album.isEmpty ? local.album : online.album)
        let finalYear = lockedFields.contains(.year) ? local.year : (online.releaseYear ?? local.year)
        let finalTrackNumber = lockedFields.contains(.trackNumber) ? local.trackNumber : (online.trackNumber ?? local.trackNumber)
        let finalGenre = lockedFields.contains(.genre) ? local.genre : (online.genre ?? local.genre)
        let finalArtworkURL = lockedFields.contains(.artwork) ? nil : online.artworkURL

        let customizedOnline = OnlineTrackMetadata(
            id: online.id,
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            albumArtist: online.albumArtist,
            releaseDate: online.releaseDate,
            releaseYear: finalYear,
            genre: finalGenre,
            trackNumber: finalTrackNumber,
            totalTracks: online.totalTracks,
            discNumber: online.discNumber,
            duration: online.duration,
            artworkURL: finalArtworkURL,
            previewURL: online.previewURL,
            sourceAPI: online.sourceAPI,
            isCompilation: online.isCompilation,
            isShazamMatch: online.isShazamMatch
        )

        if libraryStore.settings.writeMetadataToAudioFiles && AudioFileMetadataWriter.isCloudStorageURL(local.url) {
            cloudDiskWriteAlertMessage = "\"\(local.title)\" is located in iCloud Drive. Direct file writing to disk cannot be performed on cloud-synced files. All metadata has been saved within the app."
            showingCloudDiskWriteAlert = true
        }

        Task {
            _ = await libraryStore.applyOnlineMetadata(
                trackID: local.id,
                onlineMetadata: customizedOnline,
                preserveLocalTitleAndArtist: preserveFeatures || shouldPreserveTitle || shouldPreserveArtist
            )
            HapticFeedback.notificationSuccess()
        }
    }

    private func enrichAllDiffs() {
        let diffsToEnrich = libraryStore.visibleEnrichmentDiffs
        guard !diffsToEnrich.isEmpty else { return }

        if libraryStore.settings.writeMetadataToAudioFiles {
            let hasCloudTracks = diffsToEnrich.contains { AudioFileMetadataWriter.isCloudStorageURL($0.localTrack.url) }
            if hasCloudTracks {
                cloudDiskWriteAlertMessage = "Some or all tracks are located in iCloud Drive. Direct file writing to disk cannot be performed on cloud-synced files. All metadata will be preserved safely within the app."
                showingCloudDiskWriteAlert = true
            }
        }

        isEnrichingAll = true
        enrichTotalCount = diffsToEnrich.count
        enrichProcessedCount = 0
        enrichProgress = 0.0
        enrichStatusText = "Preparing batch enrichment for \(diffsToEnrich.count) tracks..."

        Task {
            _ = await libraryStore.applyBatchOnlineMetadata(
                diffs: diffsToEnrich,
                preserveLocalTitleAndArtist: preserveFeatures,
                onProgress: { progress, text in
                    Task { @MainActor in
                        self.enrichProgress = progress
                        self.enrichStatusText = text
                    }
                },
                onCountProgress: { current, total in
                    Task { @MainActor in
                        self.enrichProcessedCount = current
                        self.enrichTotalCount = total
                    }
                }
            )

            await MainActor.run {
                self.isEnrichingAll = false
                self.enrichProcessedCount = 0
                self.enrichTotalCount = 0
            }
            HapticFeedback.notificationSuccess()
        }
    }

    private func recheckSingleVerifiedTrack(_ track: Track) {
        recheckingTrackID = track.id
        Task {
            _ = await libraryStore.recheckVerifiedGoodTrack(track)
            recheckingTrackID = nil
            HapticFeedback.notificationSuccess()
        }
    }

    private func recheckSingleUnmatchedTrack(_ track: Track) {
        recheckingTrackID = track.id
        trackStatusMessages[track.id] = "Checking online..."
        Task {
            _ = await libraryStore.recheckUnmatchedTrack(track)
            recheckingTrackID = nil
            trackStatusMessages[track.id] = nil
            HapticFeedback.notificationSuccess()
        }
    }

    private func recheckTrackWithSource(track: Track, source: MetadataAPIOption) {
        recheckingTrackID = track.id
        Task {
            let match = await libraryStore.recheckTrackWithSpecificAPI(track: track, source: source)
            await MainActor.run {
                recheckingTrackID = nil
                if match != nil {
                    HapticFeedback.notificationSuccess()
                } else {
                    selectedSourceForCustomSearch = source
                    selectedTrackForCustomSearch = track
                    HapticFeedback.notificationWarning()
                }
            }
        }
    }

    private func deleteSingleTrack(_ track: Track) {
        isProcessingDeletion = true
        Task {
            let success = await libraryStore.deleteSingleTrackFile(track: track)
            await libraryStore.recalculateDuplicates()
            isProcessingDeletion = false
            trackToDelete = nil
            if success {
                HapticFeedback.notificationSuccess()
            } else {
                HapticFeedback.notificationError()
            }
        }
    }

    private func deleteAllSecondaryDuplicates() {
        let tracksToDelete = libraryStore.visibleDuplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track } }
        guard !tracksToDelete.isEmpty else { return }

        isProcessingDeletion = true
        Task {
            let res = await libraryStore.deleteDuplicateTracks(tracksToDelete: tracksToDelete)
            await libraryStore.recalculateDuplicates()
            isProcessingDeletion = false
            if res.successCount > 0 {
                HapticFeedback.notificationSuccess()
            } else if res.failedCount > 0 {
                HapticFeedback.notificationError()
            }
        }
    }
}
