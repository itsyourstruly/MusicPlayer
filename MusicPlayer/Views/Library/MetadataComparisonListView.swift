import SwiftUI

/// Metadata field enum for interactive locking of individual attributes.
public enum MetadataField: String, CaseIterable, Hashable, Sendable {
    case title = "TITLE"
    case artist = "ARTIST"
    case album = "ALBUM"
    case year = "YEAR"
    case genre = "GENRE"
    case trackNumber = "TRACK #"
    case artwork = "ARTWORK"
}

/// High-performance metadata review sheet presenting swipeable track cards
/// to compare online and local metadata, with interactive [KEEP LOCAL] locking.
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

    // Custom diffs
    private let customDiffs: [MetadataDiff]?

    // Initialize with configured properties
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

    // Main view layout structure
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

    // MARK: - Active Batch Progress View

    private var enrichingProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Text("ENRICHING METADATA")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.blue)

                Text("APPLYING VERIFIED TAGS, DOWNLOADING ARTWORK, AND UPDATING AUDIO FILES.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(enrichStatusText.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text("PROGRESS: \(Int(enrichProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)

                    Spacer()
                }
            }
            .padding(.horizontal, 24)

            Text("PLEASE KEEP THE APPLICATION OPEN UNTIL ENRICHMENT IS COMPLETE.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Diff List Scroll View

    private var diffListScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 20) {
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
                        SwipeableMetadataTrackCard(
                            diff: diff,
                            preserveFeatures: preserveFeatures,
                            onApply: { lockedFields in
                                applyDiffWithCustomLocks(diff: diff, lockedFields: lockedFields)
                            },
                            onKeepLocal: {
                                keepLocalDiff(diff)
                            }
                        )

                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.35))
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

    // MARK: - Actions

    private func applyDiffWithCustomLocks(diff: MetadataDiff, lockedFields: Set<MetadataField>) {
        let local = diff.localTrack
        let online = diff.onlineMetadata

        let finalTitle = lockedFields.contains(.title) ? local.title : online.title
        let finalArtist = lockedFields.contains(.artist) ? local.artist : online.artist
        let finalAlbum = lockedFields.contains(.album) ? local.album : (online.album.isEmpty ? local.album : online.album)
        let finalYear = lockedFields.contains(.year) ? local.year : (online.releaseYear ?? local.year)
        let finalTrackNumber = lockedFields.contains(.trackNumber) ? local.trackNumber : (online.trackNumber ?? local.trackNumber)
        let finalGenre = lockedFields.contains(.genre) ? local.genre : (online.genre ?? local.genre)
        let finalArtworkURL = lockedFields.contains(.artwork) ? nil : online.artworkURL

        let customizedOnline = OnlineTrackMetadata(
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            releaseYear: finalYear,
            genre: finalGenre,
            trackNumber: finalTrackNumber,
            artworkURL: finalArtworkURL,
            isCompilation: online.isCompilation
        )

        Task {
            _ = await libraryStore.applyOnlineMetadata(
                trackID: local.id,
                onlineMetadata: customizedOnline,
                preserveLocalTitleAndArtist: false
            )
            HapticFeedback.notificationSuccess()
        }
    }

    private func keepLocalDiff(_ diff: MetadataDiff) {
        withAnimation(.easeInOut(duration: 0.2)) {
            libraryStore.dismissEnrichmentDiff(diffID: diff.id)
        }
        HapticFeedback.notificationSuccess()
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

// MARK: - Header Summary View

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
        VStack(alignment: .leading, spacing: 14) {
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

                Text("APPLE MUSIC / DEEZER")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if isBackgroundChecking {
                VStack(alignment: .leading, spacing: 3) {
                    Text(backgroundStatus.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("METADATA CHECK: \(Int(backgroundProgress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
                .padding(.vertical, 2)
            }

            if isEnriching {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusText.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("ENRICHING: \(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                }
                .padding(.vertical, 2)
            }

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.5))

            // Settings & Controls
            TypographicToggleRow(
                title: "PRESERVE LOCAL TITLES & FEATURES",
                subtitle: "RETAINS GUEST ARTISTS & CUSTOM TITLES",
                isOn: $preserveFeatures
            )

            TypographicToggleRow(
                title: "WRITE TAGS TO FILES ON DISK",
                subtitle: "EMBEDS ID3V2/M4A TAGS DIRECTLY INTO AUDIO FILES",
                isOn: $writeToFile
            )

            Button(action: onEnrichAll) {
                Text(isEnriching ? "ENRICHING IN PROGRESS..." : "ENRICH ALL (\(diffsCount) TRACKS)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(isEnriching || diffsCount == 0 ? Color.secondary : Color.blue)
            }
            .buttonStyle(.plain)
            .disabled(isEnriching || diffsCount == 0)
            .padding(.top, 2)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Swipeable Metadata Track Card

/// Swipeable, backgroundless track card showing Online Metadata by default,
/// allowing horizontal swipe to Original Local Metadata, and tap-to-lock `[KEEP LOCAL]` fields.
public struct SwipeableMetadataTrackCard: View {
    public let diff: MetadataDiff
    public let preserveFeatures: Bool
    public let onApply: (Set<MetadataField>) -> Void
    public let onKeepLocal: () -> Void

    @State private var selectedPage: Int = 0 // 0 = Online, 1 = Local
    @State private var lockedFields: Set<MetadataField> = []
    @Environment(\.appTheme) private var appTheme

    public init(
        diff: MetadataDiff,
        preserveFeatures: Bool,
        onApply: @escaping (Set<MetadataField>) -> Void,
        onKeepLocal: @escaping () -> Void
    ) {
        self.diff = diff
        self.preserveFeatures = preserveFeatures
        self.onApply = onApply
        self.onKeepLocal = onKeepLocal
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Page Indicator Tabs
            HStack(spacing: 12) {
                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedPage = 0 }
                }) {
                    Text("ONLINE METADATA")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(selectedPage == 0 ? Color.blue : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                Text("•")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.3))

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedPage = 1 }
                }) {
                    Text("ORIGINAL LOCAL")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(selectedPage == 1 ? Color.orange : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // Swipeable Card Pages
            TabView(selection: $selectedPage) {
                // Page 0: Online Found Metadata
                onlinePageView
                    .tag(0)

                // Page 1: Original Local Metadata
                localPageView
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 410)

            // Dynamic Action Button
            HStack {
                Spacer()
                if selectedPage == 0 {
                    Button(action: {
                        onApply(lockedFields)
                    }) {
                        Text("APPLY ONLINE METADATA")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        onKeepLocal()
                    }) {
                        Text("KEEP LOCAL METADATA")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.orange)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            if preserveFeatures && diff.hasLocalFeatureCredit {
                lockedFields.insert(.title)
                lockedFields.insert(.artist)
            }
        }
    }

    // MARK: - Online Page View
    private var onlinePageView: some View {
        VStack(alignment: .center, spacing: 10) {
            // Album Artwork on Top
            Button(action: {
                toggleFieldLock(.artwork)
            }) {
                VStack(spacing: 6) {
                    if lockedFields.contains(.artwork) {
                        AlbumArtworkView(
                            artworkKey: diff.localTrack.artworkKey,
                            title: diff.localTrack.album,
                            subtitle: diff.localTrack.artist,
                            cornerRadius: 8
                        )
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        AsyncImage(url: diff.onlineMetadata.artworkURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                AlbumArtworkView(
                                    artworkKey: diff.localTrack.artworkKey,
                                    title: diff.localTrack.album,
                                    subtitle: diff.localTrack.artist,
                                    cornerRadius: 8
                                )
                            }
                        }
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Sub-Artwork Status Label
                    if lockedFields.contains(.artwork) {
                        Text("KEEPING LOCAL ARTWORK [KEEP LOCAL]")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("USING ONLINE METADATA")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                    }
                }
            }
            .buttonStyle(.plain)

            // Centered Metadata Rows Below
            VStack(alignment: .center, spacing: 6) {
                centeredMetadataRow(
                    field: .title,
                    onlineValue: diff.onlineMetadata.title,
                    localValue: diff.localTrack.title,
                    isChanged: diff.titleChanged
                )

                centeredMetadataRow(
                    field: .artist,
                    onlineValue: diff.onlineMetadata.artist,
                    localValue: diff.localTrack.artist,
                    isChanged: diff.artistChanged
                )

                centeredMetadataRow(
                    field: .album,
                    onlineValue: diff.effectiveOnlineAlbum.isEmpty ? diff.localTrack.album : diff.effectiveOnlineAlbum,
                    localValue: diff.localTrack.album,
                    isChanged: diff.albumChanged
                )

                if let y = diff.onlineMetadata.releaseYear, y > 0 {
                    centeredMetadataRow(
                        field: .year,
                        onlineValue: String(y),
                        localValue: diff.localTrack.year.map { String($0) } ?? "—",
                        isChanged: diff.yearChanged
                    )
                } else if let ly = diff.localTrack.year, ly > 0 {
                    centeredMetadataRow(
                        field: .year,
                        onlineValue: String(ly),
                        localValue: String(ly),
                        isChanged: false
                    )
                }

                if let g = diff.onlineMetadata.genre ?? diff.localTrack.genre, !g.isEmpty && g != "—" {
                    centeredMetadataRow(
                        field: .genre,
                        onlineValue: g,
                        localValue: diff.localTrack.genre ?? "—",
                        isChanged: diff.genreChanged
                    )
                }

                let onlineTrackNum: String = {
                    if let t = diff.onlineMetadata.trackNumber, t > 0 {
                        let total = diff.onlineMetadata.totalTracks.map { " of \($0)" } ?? ""
                        return "\(t)\(total)"
                    } else if let lt = diff.localTrack.trackNumber, lt > 0 {
                        let total = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                        return "\(lt)\(total)"
                    }
                    return "—"
                }()

                let localTrackNum: String = {
                    if let lt = diff.localTrack.trackNumber, lt > 0 {
                        let total = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                        return "\(lt)\(total)"
                    }
                    return "—"
                }()

                if onlineTrackNum != "—" || localTrackNum != "—" {
                    centeredMetadataRow(
                        field: .trackNumber,
                        onlineValue: onlineTrackNum,
                        localValue: localTrackNum,
                        isChanged: diff.trackNumberChanged
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Local Page View
    private var localPageView: some View {
        VStack(alignment: .center, spacing: 10) {
            // Album Artwork on Top
            VStack(spacing: 6) {
                AlbumArtworkView(
                    artworkKey: diff.localTrack.artworkKey,
                    title: diff.localTrack.album,
                    subtitle: diff.localTrack.artist,
                    cornerRadius: 8
                )
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Sub-Artwork Status Label
                Text("ORIGINAL LOCAL METADATA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }

            // Centered Local Metadata Rows
            VStack(alignment: .center, spacing: 6) {
                centeredLocalRow(field: .title, value: diff.localTrack.title)
                centeredLocalRow(field: .artist, value: diff.localTrack.artist)
                centeredLocalRow(field: .album, value: diff.localTrack.album.isEmpty ? "—" : diff.localTrack.album)
                centeredLocalRow(field: .year, value: diff.localTrack.year.map { String($0) } ?? "—")
                if let g = diff.localTrack.genre, !g.isEmpty && g != "—" {
                    centeredLocalRow(field: .genre, value: g)
                }
                let localTrackNum: String = {
                    if let lt = diff.localTrack.trackNumber, lt > 0 {
                        let total = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                        return "\(lt)\(total)"
                    }
                    return "—"
                }()
                if localTrackNum != "—" {
                    centeredLocalRow(field: .trackNumber, value: localTrackNum)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // Toggle field lock
    private func toggleFieldLock(_ field: MetadataField) {
        HapticFeedback.selectionChanged()
        withAnimation(.easeInOut(duration: 0.15)) {
            if lockedFields.contains(field) {
                lockedFields.remove(field)
            } else {
                lockedFields.insert(field)
            }
        }
    }

    // Centered Metadata Row with interactive lock toggle and Green for overwritten/new metadata
    private func centeredMetadataRow(
        field: MetadataField,
        onlineValue: String,
        localValue: String,
        isChanged: Bool
    ) -> some View {
        let isLocked = lockedFields.contains(field)
        let displayValue = isLocked ? localValue : onlineValue
        let textColor: Color = isLocked ? Color.orange : (isChanged ? Color.green : Color.primary)

        return Button(action: {
            toggleFieldLock(field)
        }) {
            HStack(spacing: 6) {
                Text(field.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(displayValue)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                if isLocked {
                    Text("[KEEP LOCAL]")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func centeredLocalRow(field: MetadataField, value: String) -> some View {
        let isLocked = lockedFields.contains(field)
        return Button(action: {
            toggleFieldLock(field)
        }) {
            HStack(spacing: 6) {
                Text(field.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(isLocked ? Color.orange : Color.primary)
                    .lineLimit(1)

                if isLocked {
                    Text("[KEEP LOCAL]")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
