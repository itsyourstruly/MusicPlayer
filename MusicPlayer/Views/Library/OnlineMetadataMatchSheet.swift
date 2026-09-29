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
    @State private var selectedCandidateIndex: Int = 0
    @State private var downloadedArtwork: Data?
    @State private var lockedLocalFields: Set<MetadataField> = [] // Empty by default: ALL fields overwrite with online metadata!
    @State private var isSearching: Bool = false
    @State private var isApplying: Bool = false
    @State private var searchQuery: String = ""
    @State private var selectedSourceAPI: MetadataAPIOption = .all

    // Initialize with configured properties
    public init(track: Track, libraryStore: LibraryStore, initialSource: MetadataAPIOption = .all) {
        self.track = track
        self.libraryStore = libraryStore
        self._selectedSourceAPI = State(initialValue: initialSource)
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Top Custom Search Bar (Always fixed at top)
                    customSearchBar

                    // API Provider Selector (Always fixed at top)
                    sourceSelectorBar

                    // Content Area (Maintains stable full-height frame)
                    ZStack {
                        if isSearching {
                            loadingView
                                .transition(.opacity)
                        } else if searchResults.isEmpty {
                            noResultsView
                                .transition(.opacity)
                        } else {
                            resultsContent
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 480, alignment: .top)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ONLINE METADATA")
            .navigationBarTitleDisplayMode(.inline)
            // Async lifecycle task
            .task {
                let sig = MetadataSanitizer.sanitize(track: track)
                if !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) && !sig.primaryArtist.isEmpty {
                    searchQuery = "\(sig.coreTitle) \(sig.primaryArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    searchQuery = sig.coreTitle
                }
                await performSearchWithCurrentSource()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Candidate Results & Comparison View

    private var resultsContent: some View {
        VStack(spacing: 16) {
            // Horizontal scroll strip matching AlbumMetadataSheet
            candidateMatchesStrip

            // Selected Match Header & Overwrite Options
            if let currentMatch = selectedMatch ?? searchResults.first {
                selectedMatchDiffView(match: currentMatch)
            }
        }
    }

    // MARK: - Candidate Matches Horizontal Strip
    private var candidateMatchesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ONLINE MATCHES (\(searchResults.count))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if isSearching {
                    ProgressView()
                        .tint(Color.primary)
                        .scaleEffect(0.7)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, item in
                        let isSelected = (selectedMatch?.id == item.id) || (selectedMatch == nil && index == 0)

                        Button(action: {
                            HapticFeedback.selectionChanged()
                            selectedCandidateIndex = index
                            selectMatch(item)
                        }) {
                            HStack(spacing: 8) {
                                AsyncImage(url: item.artworkURL) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    default:
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.gray.opacity(0.2))
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                        .lineLimit(1)

                                    Text(item.artist)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: 4) {
                                        if let year = item.releaseYear, year > 0 {
                                            Text(String(year))
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text("• \(item.sourceAPI.uppercased())")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(isSelected ? Color.green : appTheme.accentColor)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - API Source Selector Bar

    private var sourceSelectorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(MetadataAPIOption.allCases) { source in
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        selectedSourceAPI = source
                        Task {
                            await performSearchWithCurrentSource()
                        }
                    }) {
                        Text(source.displayName)
                            .font(.system(size: 11, weight: selectedSourceAPI == source ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(selectedSourceAPI == source ? Color.white : Color.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Search Bar Component

    private var customSearchBar: some View {
        HStack(spacing: 8) {
            TextField("CUSTOM SEARCH QUERY...", text: $searchQuery)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.white)
                .submitLabel(.search)
                .onSubmit {
                    Task {
                        await performSearchWithCurrentSource()
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
                    await performSearchWithCurrentSource()
                }
            }) {
                Text("SEARCH")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(appTheme.separatorColor.opacity(0.6)),
            alignment: .bottom
        )
    }

    // MARK: - Loading & Empty States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.primary)
                .scaleEffect(1.15)
            Text("SEARCHING \(selectedSourceAPI.displayName)...")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private var noResultsView: some View {
        VStack(spacing: 14) {
            Text("NO ONLINE MATCHES FOUND")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)

            Text("We couldn't find matches via \(selectedSourceAPI.displayName) for '\(searchQuery)'. Try searching by song title alone or switching API sources.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Selected Match Diff View

    private func selectedMatchDiffView(match: OnlineTrackMetadata) -> some View {
        VStack(spacing: 14) {
            // High-Res Artwork & Identity Header
            HStack(spacing: 14) {
                let isUsingLocalArtwork = lockedLocalFields.contains(.artwork)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if lockedLocalFields.contains(.artwork) {
                            lockedLocalFields.remove(.artwork)
                        } else {
                            lockedLocalFields.insert(.artwork)
                        }
                    }
                }) {
                    Group {
                        if isUsingLocalArtwork {
                            AlbumArtworkView(
                                artworkKey: track.artworkKey,
                                title: track.title,
                                subtitle: track.artist,
                                cornerRadius: 8
                            )
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else if let art = downloadedArtwork, let img = PlatformImage(data: art) {
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
                                    AlbumArtworkView(
                                        artworkKey: track.artworkKey,
                                        title: track.title,
                                        subtitle: track.artist,
                                        cornerRadius: 8
                                    )
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isUsingLocalArtwork ? Color.orange : Color.green, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text("VERIFIED ONLINE RECORD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.green)

                    Text(match.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text(match.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("API:")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(match.sourceAPI.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.green)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.35))

            // Overwrite Controls (Clean text buttons)
            HStack(spacing: 20) {
                let isOverwriteAll = lockedLocalFields.isEmpty
                let isKeepAll = lockedLocalFields.count == MetadataField.allCases.count

                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        lockedLocalFields.removeAll() // Overwrite ALL with online
                    }
                }) {
                    Text("OVERWRITE ALL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isOverwriteAll ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)

                Button(action: {
                    HapticFeedback.selectionChanged()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        lockedLocalFields = Set(MetadataField.allCases) // Keep ALL local
                    }
                }) {
                    Text("KEEP ALL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isKeepAll ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.vertical, 2)

            // Interactive Per-Tag Toggle Table
            VStack(spacing: 0) {
                interactiveTagRow(
                    field: .title,
                    currentVal: track.title,
                    onlineVal: match.title
                )

                interactiveTagRow(
                    field: .artist,
                    currentVal: track.artist,
                    onlineVal: match.artist
                )

                interactiveTagRow(
                    field: .album,
                    currentVal: track.album.isEmpty ? "—" : track.album,
                    onlineVal: match.album
                )

                if let year = match.releaseYear, year > 0 {
                    interactiveTagRow(
                        field: .year,
                        currentVal: track.year.map { String($0) } ?? "—",
                        onlineVal: String(year)
                    )
                }

                if let g = match.genre, !g.isEmpty {
                    interactiveTagRow(
                        field: .genre,
                        currentVal: track.genre ?? "—",
                        onlineVal: g
                    )
                }

                if let num = match.trackNumber, num > 0 {
                    interactiveTagRow(
                        field: .trackNumber,
                        currentVal: track.trackNumber.map { String($0) } ?? "—",
                        onlineVal: String(num)
                    )
                }

                interactiveTagRow(
                    field: .artwork,
                    currentVal: track.artworkKey != nil ? "Embedded Art" : "None",
                    onlineVal: match.artworkURL != nil ? "High-Res Art" : "None"
                )
            }

            // Direct File Writing Option Toggle (Clean ON/OFF text)
            TypographicToggleRow(
                title: "WRITE TAGS TO AUDIO FILE ON DISK",
                subtitle: "Atomically embed updated ID3v2/M4A tags directly into the file.",
                isOn: Binding(
                    get: { libraryStore.settings.writeMetadataToAudioFiles },
                    set: { newValue in
                        libraryStore.settings.writeMetadataToAudioFiles = newValue
                        libraryStore.saveSettings()
                    }
                )
            )
            .padding(.top, 4)

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

    // MARK: - Interactive Tag Row
    private func interactiveTagRow(
        field: MetadataField,
        currentVal: String,
        onlineVal: String
    ) -> some View {
        let isUsingLocal = lockedLocalFields.contains(field)
        let displayVal = isUsingLocal ? currentVal : onlineVal
        let textColor = isUsingLocal ? Color.orange : Color.green

        return Button(action: {
            HapticFeedback.selectionChanged()
            withAnimation(.easeInOut(duration: 0.15)) {
                if lockedLocalFields.contains(field) {
                    lockedLocalFields.remove(field)
                } else {
                    lockedLocalFields.insert(field)
                }
            }
        }) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(field.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(textColor)
                        .frame(width: 80, alignment: .leading)

                    Text(displayVal)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(textColor)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Handlers

    private func performSearchWithCurrentSource() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        selectedMatch = nil
        selectedCandidateIndex = 0
        downloadedArtwork = nil

        let defaultQuery: String = {
            let sig = MetadataSanitizer.sanitize(track: track)
            if !MetadataSanitizer.isUnknownArtist(sig.primaryArtist) && !sig.primaryArtist.isEmpty {
                return "\(sig.coreTitle) \(sig.primaryArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return sig.coreTitle
        }()

        let candidates: [OnlineTrackMetadata]
        if query.isEmpty || query.localizedCaseInsensitiveCompare(defaultQuery) == .orderedSame {
            candidates = await MusicMetadataService.shared.searchOnline(for: track, source: selectedSourceAPI)
        } else {
            let results = await MusicMetadataService.shared.searchOnline(query: query, source: selectedSourceAPI)
            let sig = MetadataSanitizer.sanitize(track: track)
            candidates = DisambiguationMatcher.rankCandidates(for: sig, in: results)
        }
        self.searchResults = candidates
        self.isSearching = false
        self.selectedCandidateIndex = 0
        if let best = candidates.first {
            selectMatch(best)
        }
    }

    private func selectMatch(_ match: OnlineTrackMetadata) {
        self.selectedMatch = match
        Task {
            if let artURL = match.artworkURL {
                let data = await MusicMetadataService.shared.downloadArtworkData(from: artURL)
                await MainActor.run {
                    self.downloadedArtwork = data
                }
            }
        }
    }

    private func applyMatch(_ match: OnlineTrackMetadata) {
        isApplying = true
        Task {
            _ = await libraryStore.applyCustomizedMetadata(
                trackID: track.id,
                onlineMetadata: match,
                lockedFields: lockedLocalFields,
                artworkData: downloadedArtwork
            )
            isApplying = false
            HapticFeedback.notificationSuccess()
            dismiss()
        }
    }
}
