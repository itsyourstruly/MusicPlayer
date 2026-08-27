//
//  MetadataComparisonListView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import SwiftUI

/// High-performance metadata review sheet presenting side-by-side comparisons of local tracks
/// and verified Apple Music online metadata, supporting single and batch enrichment with direct file tag writing
/// and automatic feature preservation.
public struct MetadataComparisonListView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var preserveFeatures: Bool = true
    @State private var isEnrichingAll: Bool = false
    @State private var isCompleted: Bool = false
    @State private var completedCount: Int = 0
    @State private var enrichProgress: Double = 0.0
    @State private var enrichStatusText: String = ""
    @State private var searchText: String = ""

    private let customDiffs: [MetadataDiff]?

    public init(libraryStore: LibraryStore, customDiffs: [MetadataDiff]? = nil) {
        self.libraryStore = libraryStore
        self.customDiffs = customDiffs
    }

    private var activeDiffs: [MetadataDiff] {
        customDiffs ?? libraryStore.enrichmentDiffs
    }

    private var filteredDiffs: [MetadataDiff] {
        let list = activeDiffs
        let query = FuzzyMatcher.normalize(searchText)
        if query.isEmpty { return list }
        return list.filter { diff in
            diff.localTrack.searchTokens.contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.title).contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.artist).contains(query) ||
            FuzzyMatcher.normalize(diff.onlineMetadata.album).contains(query)
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isCompleted {
                    completionView
                } else if isEnrichingAll {
                    enrichingProgressView
                } else if activeDiffs.isEmpty && !libraryStore.isBackgroundCheckingMetadata {
                    ComparisonEmptyStateView()
                } else {
                    diffListScrollView
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("METADATA ENRICHMENT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !isEnrichingAll {
                        Button("DONE") {
                            dismiss()
                        }
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Completion View

    private var completionView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("ENRICHMENT COMPLETE")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.green)

            Text("Successfully enriched \(completedCount) tracks in your library with verified online metadata, high-resolution artwork, and disk tags.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: {
                dismiss()
            }) {
                Text("DONE")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(maxWidth: 200)
            }
            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
            .padding(.top, 12)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Active Batch Progress View (Remains visible throughout entire enrichment process)

    private var enrichingProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Text("ENRICHING METADATA")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)

                Text("Applying verified tags, downloading artwork, and updating audio files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ProgressView(value: enrichProgress)
                    .tint(appTheme.accentColor)

                HStack {
                    Text(enrichStatusText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(enrichProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
            }
            .padding(16)
            .background(appTheme.secondaryBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(appTheme.separatorColor.opacity(0.6), lineWidth: 1)
            )
            .padding(.horizontal, 24)

            Text("Please keep the application open until enrichment is complete.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Diff List Scroll View

    private var diffListScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 16) {
                searchBar

                EnrichHeaderCardView(
                    diffsCount: activeDiffs.count,
                    isBackgroundChecking: libraryStore.isBackgroundCheckingMetadata,
                    backgroundStatus: libraryStore.backgroundCheckStatusText,
                    backgroundProgress: libraryStore.backgroundCheckProgress,
                    isEnriching: isEnrichingAll,
                    progress: enrichProgress,
                    statusText: enrichStatusText,
                    preserveFeatures: $preserveFeatures,
                    writeToFile: $libraryStore.settings.writeMetadataToAudioFiles,
                    onEnrichAll: {
                        enrichAllDiffs()
                    }
                )

                if !searchText.isEmpty {
                    HStack {
                        Text("SHOWING \(filteredDiffs.count) OF \(activeDiffs.count) TRACKS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 2)
                }

                if filteredDiffs.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 8) {
                        Text("NO MATCHING TRACKS FOUND")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                        Text("No pending enrichment matches query '\(searchText)'.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 32)
                } else {
                    ForEach(filteredDiffs) { diff in
                        MetadataSideBySideDiffCard(
                            diff: diff,
                            preserveFeatures: preserveFeatures,
                            onApply: {
                                applySingleDiff(diff)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(appTheme.secondaryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(appTheme.separatorColor.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func applySingleDiff(_ diff: MetadataDiff) {
        Task {
            _ = await libraryStore.applyOnlineMetadata(
                trackID: diff.localTrack.id,
                onlineMetadata: diff.onlineMetadata,
                preserveLocalTitleAndArtist: preserveFeatures
            )
            HapticFeedback.notificationSuccess()
        }
    }

    private func enrichAllDiffs() {
        let diffsToEnrich = activeDiffs
        guard !diffsToEnrich.isEmpty else { return }

        isEnrichingAll = true
        isCompleted = false
        enrichProgress = 0.0
        enrichStatusText = "Preparing batch enrichment for \(diffsToEnrich.count) tracks..."

        Task {
            let count = await libraryStore.applyBatchOnlineMetadata(
                diffs: diffsToEnrich,
                preserveLocalTitleAndArtist: preserveFeatures,
                onProgress: { progress, text in
                    Task { @MainActor in
                        self.enrichProgress = progress
                        self.enrichStatusText = text
                    }
                }
            )

            await MainActor.run {
                self.completedCount = count
                self.isEnrichingAll = false
                self.isCompleted = true
            }
            HapticFeedback.notificationSuccess()
        }
    }
}

// MARK: - Subviews

/// Header summary card with batch action, feature preservation toggle, and direct disk file writing toggle.
public struct EnrichHeaderCardView: View {
    public let diffsCount: Int
    public let isBackgroundChecking: Bool
    public let backgroundStatus: String
    public let backgroundProgress: Double
    public let isEnriching: Bool
    public let progress: Double
    public let statusText: String
    @Binding public var preserveFeatures: Bool
    @Binding public var writeToFile: Bool
    public let onEnrichAll: () -> Void

    @Environment(\.appTheme) private var appTheme

    public init(
        diffsCount: Int,
        isBackgroundChecking: Bool = false,
        backgroundStatus: String = "",
        backgroundProgress: Double = 0.0,
        isEnriching: Bool,
        progress: Double,
        statusText: String,
        preserveFeatures: Binding<Bool>,
        writeToFile: Binding<Bool>,
        onEnrichAll: @escaping () -> Void
    ) {
        self.diffsCount = diffsCount
        self.isBackgroundChecking = isBackgroundChecking
        self.backgroundStatus = backgroundStatus
        self.backgroundProgress = backgroundProgress
        self.isEnriching = isEnriching
        self.progress = progress
        self.statusText = statusText
        self._preserveFeatures = preserveFeatures
        self._writeToFile = writeToFile
        self.onEnrichAll = onEnrichAll
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VERIFIED ONLINE MATCHES")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("\(diffsCount) TRACKS READY TO ENRICH")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }

                Spacer()

                Text("Apple Music / Deezer")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if isBackgroundChecking {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: backgroundProgress)
                        .tint(Color.primary)
                    Text(backgroundStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if isEnriching {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                    }
                    ProgressView(value: progress)
                        .tint(appTheme.accentColor)
                }
                .padding(10)
                .background(appTheme.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Divider()
                .overlay(appTheme.separatorColor)

            // Settings & Controls
            Toggle(isOn: $preserveFeatures) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PRESERVE LOCAL TITLES & FEATURES")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("Retains guest artists & custom titles while upgrading artwork, album & date.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.blue)

            Toggle(isOn: $writeToFile) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WRITE TAGS TO FILES ON DISK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("Embeds ID3v2/M4A tags directly into audio files.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.blue)

            Button(action: onEnrichAll) {
                Text(isEnriching ? "ENRICHING IN PROGRESS..." : "ENRICH ALL (\(diffsCount) TRACKS)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
            .disabled(isEnriching || diffsCount == 0)
        }
        .padding(14)
        .background(appTheme.secondaryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Side-by-side comparison card displaying Local Track on Left and Online Track on Right.
public struct MetadataSideBySideDiffCard: View {
    public let diff: MetadataDiff
    public let preserveFeatures: Bool
    public let onApply: () -> Void

    @Environment(\.appTheme) private var appTheme

    public init(diff: MetadataDiff, preserveFeatures: Bool, onApply: @escaping () -> Void) {
        self.diff = diff
        self.preserveFeatures = preserveFeatures
        self.onApply = onApply
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Track Identity Header
            HStack {
                Text(diff.localTrack.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Spacer()

                if diff.isExactAlbumMatch {
                    Text("ALBUM MATCH")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }

                if diff.hasLocalFeatureCredit && preserveFeatures {
                    Text("FEAT. PRESERVED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.4))

            // Side-by-Side Comparison Container
            HStack(alignment: .top, spacing: 10) {
                // Left: Original Local Track
                LocalTrackComparisonColumn(diff: diff, preserveFeatures: preserveFeatures)

                // Right: Online Verified Track
                OnlineTrackComparisonColumn(diff: diff, preserveFeatures: preserveFeatures)
            }

            // Apply Button for this track
            Button(action: onApply) {
                Text("APPLY ONLINE METADATA")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
            .padding(.top, 4)
        }
        .padding(12)
        .background(appTheme.secondaryBackgroundColor.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(appTheme.separatorColor, lineWidth: 1)
        )
    }
}

/// Left Column: Original Local Track with full metadata list and transfer indicators.
public struct LocalTrackComparisonColumn: View {
    public let diff: MetadataDiff
    public let preserveFeatures: Bool
    @Environment(\.appTheme) private var appTheme

    public init(diff: MetadataDiff, preserveFeatures: Bool = true) {
        self.diff = diff
        self.preserveFeatures = preserveFeatures
    }

    public init(track: Track) {
        self.diff = MetadataDiff(localTrack: track, onlineMetadata: OnlineTrackMetadata(title: track.title, artist: track.artist, album: track.album), preserveLocalTitleAndArtist: true)
        self.preserveFeatures = true
    }

    private var track: Track { diff.localTrack }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ORIGINAL METADATA")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            // Local Artwork Preview
            VStack(alignment: .leading, spacing: 4) {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 6
                )
                .frame(width: 140, height: 140)

                Text(track.artworkKey != nil ? "EMBEDDED ART" : "NO ARTWORK")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Comprehensive Local Metadata List
            VStack(alignment: .leading, spacing: 4) {
                localMetaRow(
                    label: "TITLE",
                    value: track.title,
                    isWillUseLocal: preserveFeatures
                )

                localMetaRow(
                    label: "ARTIST",
                    value: track.artist,
                    isWillUseLocal: preserveFeatures
                )

                localMetaRow(
                    label: "ALBUM",
                    value: track.album.isEmpty ? "—" : track.album,
                    isWillUseLocal: diff.onlineMetadata.album.isEmpty || (!diff.albumChanged)
                )

                localMetaRow(
                    label: "YEAR",
                    value: track.year.map { String($0) } ?? "—",
                    isWillUseLocal: diff.onlineMetadata.releaseYear == nil || diff.onlineMetadata.releaseYear == 0 || diff.isYearTransferredFromLocal
                )

                if let g = track.genre, !g.isEmpty && g != "Unknown Genre" && g != "—" {
                    localMetaRow(
                        label: "GENRE",
                        value: g,
                        isWillUseLocal: true
                    )
                }

                let trackNumStr: String = {
                    if let t = track.trackNumber, t > 0 {
                        let totalStr = track.totalTracks.map { " of \($0)" } ?? ""
                        return "\(t)\(totalStr)"
                    }
                    return "—"
                }()
                localMetaRow(
                    label: "TRACK #",
                    value: trackNumStr,
                    isWillUseLocal: diff.onlineMetadata.trackNumber == nil || diff.onlineMetadata.trackNumber == 0 || diff.isTrackNumberTransferredFromLocal
                )

                if let disc = track.discNumber, disc > 0 {
                    localMetaRow(label: "DISC #", value: String(disc), isWillUseLocal: true)
                }

                if let info = track.fileInfo {
                    localMetaRow(label: "CODEC", value: info.formatDescription, isWillUseLocal: true)
                }
            }
            .padding(6)
            .background(appTheme.backgroundColor.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localMetaRow(label: String, value: String, isWillUseLocal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if isWillUseLocal && value != "—" {
                    Text("→")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                }
            }

            Text(value)
                .font(.system(size: 10, weight: value == "—" ? .regular : .semibold, design: .monospaced))
                .foregroundStyle(value == "—" ? .secondary : Color.primary)
                .lineLimit(1)
        }
    }
}

/// Right Column: Online Verified Track (Green for online upgrades, Orange for using local metadata).
public struct OnlineTrackComparisonColumn: View {
    public let diff: MetadataDiff
    public let preserveFeatures: Bool
    @Environment(\.appTheme) private var appTheme

    public init(diff: MetadataDiff, preserveFeatures: Bool) {
        self.diff = diff
        self.preserveFeatures = preserveFeatures
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ONLINE METADATA")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            // Online Artwork Preview
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: diff.onlineMetadata.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(appTheme.secondaryBackgroundColor)
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 4) {
                    if diff.artworkUpgraded {
                        Text("HIGH-RES (ONLINE)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.green)
                    } else {
                        Text("KEEP LOCAL ART")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.orange)
                    }
                }
            }

            // Online Metadata Rows
            VStack(alignment: .leading, spacing: 4) {
                if preserveFeatures {
                    onlineMetaRow(
                        label: "TITLE",
                        value: diff.localTrack.title,
                        isOnlineUpgrade: false
                    )
                } else {
                    onlineMetaRow(
                        label: "TITLE",
                        value: diff.onlineMetadata.title,
                        isOnlineUpgrade: diff.titleChanged
                    )
                }

                if preserveFeatures {
                    onlineMetaRow(
                        label: "ARTIST",
                        value: diff.localTrack.artist,
                        isOnlineUpgrade: false
                    )
                } else {
                    onlineMetaRow(
                        label: "ARTIST",
                        value: diff.onlineMetadata.artist,
                        isOnlineUpgrade: diff.artistChanged
                    )
                }

                let isAlbumOnline = !diff.effectiveOnlineAlbum.isEmpty && diff.albumChanged
                onlineMetaRow(
                    label: "ALBUM",
                    value: isAlbumOnline ? diff.effectiveOnlineAlbum : diff.localTrack.album,
                    isOnlineUpgrade: isAlbumOnline
                )

                if let y = diff.onlineMetadata.releaseYear, y > 0 && diff.yearChanged {
                    onlineMetaRow(
                        label: "YEAR",
                        value: String(y),
                        isOnlineUpgrade: true
                    )
                } else if let localY = diff.localTrack.year, localY > 0 {
                    onlineMetaRow(
                        label: "YEAR",
                        value: String(localY),
                        isOnlineUpgrade: false
                    )
                } else {
                    onlineMetaRow(
                        label: "YEAR",
                        value: "—",
                        isOnlineUpgrade: false
                    )
                }

                if let localG = diff.localTrack.genre, !localG.isEmpty && localG != "Unknown Genre" && localG != "—" {
                    onlineMetaRow(
                        label: "GENRE",
                        value: localG,
                        isOnlineUpgrade: false
                    )
                }

                if let t = diff.onlineMetadata.trackNumber, t > 0 && diff.trackNumberChanged {
                    let totalStr = diff.onlineMetadata.totalTracks.map { " of \($0)" } ?? ""
                    onlineMetaRow(
                        label: "TRACK #",
                        value: "\(t)\(totalStr)",
                        isOnlineUpgrade: true
                    )
                } else if let localT = diff.localTrack.trackNumber, localT > 0 {
                    let totalStr = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                    onlineMetaRow(
                        label: "TRACK #",
                        value: "\(localT)\(totalStr)",
                        isOnlineUpgrade: false
                    )
                } else {
                    onlineMetaRow(
                        label: "TRACK #",
                        value: "—",
                        isOnlineUpgrade: false
                    )
                }
            }
            .padding(6)
            .background(appTheme.backgroundColor.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onlineMetaRow(
        label: String,
        value: String,
        isOnlineUpgrade: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(isOnlineUpgrade ? Color.green : Color.orange)

                Text(isOnlineUpgrade ? "[ONLINE UPGRADE]" : "[USE LOCAL]")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(isOnlineUpgrade ? Color.green : Color.orange)
            }

            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOnlineUpgrade ? Color.green : Color.orange)
                .lineLimit(1)
        }
    }
}

/// Empty state view when all tracks have complete metadata.
private struct ComparisonEmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("NO PENDING ENRICHMENTS")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("All tracks in your library with verified online records are up to date.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
