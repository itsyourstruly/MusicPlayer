import SwiftUI

/// Interactive sheet for searching verified online metadata and high-res artwork,
/// previewing differences, and applying updates directly to the track and file on disk.
public struct OnlineMetadataMatchSheet: View {
    // Track
    public let track: Track
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var searchResults: [OnlineTrackMetadata] = []
    @State private var selectedMatch: OnlineTrackMetadata?
    @State private var downloadedArtwork: Data?
    @State private var preserveFeatures: Bool = true
    @State private var isSearching: Bool = false
    @State private var isApplying: Bool = false
    @State private var searchQuery: String = ""

    // Initialize with configured properties
    public init(track: Track, libraryStore: LibraryStore) {
        self.track = track
        self.libraryStore = libraryStore
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Top Custom Search Bar
                    customSearchBar

                    if isSearching {
                        loadingView
                    } else if let match = selectedMatch {
                        // Diff Comparison View for Selected Match
                        selectedMatchDiffView(match: match)
                    } else if searchResults.isEmpty {
                        noResultsView
                    } else {
                        // Results candidate picker
                        resultsPickerList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ONLINE METADATA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectedMatch != nil && searchResults.count > 1 {
                        Button("RESULTS") {
                            withAnimation {
                                selectedMatch = nil
                                downloadedArtwork = nil
                            }
                        }
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            // Async lifecycle task
            .task {
                searchQuery = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
                await performAutoSearch()
            }
        }
    }

    // MARK: - Search Bar Component

    private var customSearchBar: some View {
        HStack(spacing: 8) {
            TextField("CUSTOM SEARCH QUERY...", text: $searchQuery)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit {
                    Task {
                        await performCustomSearch()
                    }
                }

            if !searchQuery.isEmpty {
                Button("CLEAR") {
                    searchQuery = ""
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Button(action: {
                Task {
                    await performCustomSearch()
                }
            }) {
                Text("SEARCH")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .mini))
            .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // MARK: - Loading & Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.primary)
            Text("SEARCHING APPLE MUSIC & DEEZER...")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var noResultsView: some View {
        VStack(spacing: 14) {
            Text("NO ONLINE MATCHES FOUND")
                .font(.system(size: 14, weight: .bold, design: .monospaced))

            Text("We couldn't find matches for '\(searchQuery)'. Try refining your search query above.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 36)
    }

    // MARK: - Results Picker List

    private var resultsPickerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FOUND \(searchResults.count) MATCHES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("SELECT A TRACK TO REVIEW")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ForEach(searchResults) { match in
                Button(action: {
                    selectMatch(match)
                }) {
                    HStack(spacing: 12) {
                        AsyncImage(url: match.artworkURL) { phase in
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
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            Text("\(match.artist) — \(match.album)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                // Release year
                                if let year = match.releaseYear {
                                    Text("\(year)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                // Musical genre classification
                                if let genre = match.genre {
                                    Text("• \(genre)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text("• \(match.sourceAPI)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.8))
                            }
                        }

                        Spacer()

                        Text("VIEW")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(appTheme.accentColor)
                    }
                    .padding(10)
                    .background(appTheme.secondaryBackgroundColor.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Selected Match Diff View

    // Selected match diff view
    private func selectedMatchDiffView(match: OnlineTrackMetadata) -> some View {
        VStack(spacing: 16) {
            // High-Res Artwork & Identity Header
            HStack(spacing: 14) {
                if let art = downloadedArtwork, let img = PlatformImage(data: art) {
                    #if canImport(UIKit)
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    #elseif canImport(AppKit)
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    #endif
                } else {
                    AsyncImage(url: match.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(appTheme.secondaryBackgroundColor)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("VERIFIED ONLINE RECORD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)

                    Text(match.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(match.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("Source: \(match.sourceAPI)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                }

                Spacer()
            }
            .padding(12)
            .background(appTheme.secondaryBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Side-by-side diff table
            VStack(alignment: .leading, spacing: 10) {
                Text("METADATA COMPARISON")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                diffRow(label: "TITLE", current: track.title, online: match.title)
                diffRow(label: "ARTIST", current: track.artist, online: match.artist)
                diffRow(label: "ALBUM", current: track.album, online: match.album)

                if let onlineYear = match.releaseYear {
                    diffRow(
                        label: "YEAR",
                        current: track.year.map { String($0) } ?? "—",
                        online: String(onlineYear)
                    )
                }

                if let g = track.genre, !g.isEmpty && g != "Unknown Genre" && g != "—" {
                    diffRow(
                        label: "GENRE",
                        current: g,
                        online: g
                    )
                }

                if let onlineTrackNum = match.trackNumber {
                    diffRow(
                        label: "TRACK #",
                        current: track.trackNumber.map { String($0) } ?? "—",
                        online: String(onlineTrackNum)
                    )
                }

                diffRow(
                    label: "ARTWORK",
                    current: track.artworkKey != nil ? "Local" : "None",
                    online: match.artworkURL != nil ? "High-Res (1400px)" : "None"
                )
            }
            .padding(12)
            .background(appTheme.secondaryBackgroundColor.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Feature Preservation Toggle
            Toggle(isOn: $preserveFeatures) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PRESERVE LOCAL TITLE & FEATURES")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text("Retains (feat. XYZ) guest artist credits and original track title.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.blue)
            .padding(12)
            .background(appTheme.secondaryBackgroundColor.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Direct File Writing Option Toggle
            Toggle(isOn: $libraryStore.settings.writeMetadataToAudioFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WRITE TAGS TO AUDIO FILE ON DISK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text("Atomically embed ID3v2/M4A tags directly into the file.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.blue)
            .padding(12)
            .background(appTheme.secondaryBackgroundColor.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Apply Button
            Button(action: {
                applyMatch(match)
            }) {
                HStack(spacing: 6) {
                    if isApplying {
                        ProgressView()
                            .tint(Color.appInvertedBackground)
                    }
                    Text(isApplying ? "APPLYING & WRITING..." : "APPLY METADATA & ARTWORK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
            .disabled(isApplying)
        }
    }

    // Diff row
    private func diffRow(label: String, current: String, online: String) -> some View {
        // Flag indicating if different
        let isDifferent = current.trimmingCharacters(in: .whitespacesAndNewlines) != online.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(current)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .strikethrough(isDifferent, color: .red.opacity(0.7))

                if isDifferent {
                    Text(online)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Handlers

    // Perform auto search
    private func performAutoSearch() async {
        isSearching = true
        // Candidates
        let candidates = await MusicMetadataService.shared.searchOnline(for: track)
        self.searchResults = candidates
        self.isSearching = false
        // Signature
        let signature = MetadataSanitizer.sanitize(track: track)
        if let best = DisambiguationMatcher.bestMatch(for: signature, in: candidates) ?? candidates.first {
            selectMatch(best)
        }
    }

    // Perform custom search
    private func performCustomSearch() async {
        // Query
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !query.isEmpty else { return }

        isSearching = true
        selectedMatch = nil
        downloadedArtwork = nil

        // Candidates
        let candidates = await MusicMetadataService.shared.searchOnline(query: query)
        self.searchResults = candidates
        self.isSearching = false
        if let first = candidates.first {
            selectMatch(first)
        }
    }

    // Select match
    private func selectMatch(_ match: OnlineTrackMetadata) {
        self.selectedMatch = match
        Task {
            // File path location
            if let artURL = match.artworkURL {
                // Data
                let data = await MusicMetadataService.shared.downloadArtworkData(from: artURL)
                await MainActor.run {
                    self.downloadedArtwork = data
                }
            }
        }
    }

    // Apply match
    private func applyMatch(_ match: OnlineTrackMetadata) {
        isApplying = true
        Task {
            _ = await libraryStore.applyOnlineMetadata(
                trackID: track.id,
                onlineMetadata: match,
                artworkData: downloadedArtwork,
                preserveLocalTitleAndArtist: preserveFeatures
            )
            isApplying = false
            HapticFeedback.notificationSuccess()
            dismiss()
        }
    }
}
