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
                            candidateSwipeCarousel
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
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

    // MARK: - Candidate Swipe Carousel

    private var candidateSwipeCarousel: some View {
        VStack(spacing: 14) {
            // Source pager selector bar if multiple matches
            if searchResults.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(searchResults.enumerated()), id: \.offset) { index, match in
                            Button(action: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    selectedCandidateIndex = index
                                    selectMatch(match)
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Text("\(index + 1). \(match.sourceAPI.uppercased())")
                                        .font(.system(size: 11, weight: selectedCandidateIndex == index ? .bold : .medium, design: .monospaced))
                                    if index == 0 {
                                        Text("★ BEST")
                                            .font(.system(size: 9, weight: .black, design: .monospaced))
                                            .foregroundStyle(Color.green)
                                    }
                                }
                                .foregroundStyle(selectedCandidateIndex == index ? Color.white : Color.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                HStack {
                    Text("← SWIPE LEFT / RIGHT TO SWITCH OPTIONS (\(selectedCandidateIndex + 1)/\(searchResults.count)) →")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // Swipeable Current Match Diff Card
            if let currentMatch = searchResults.indices.contains(selectedCandidateIndex) ? searchResults[selectedCandidateIndex] : searchResults.first {
                selectedMatchDiffView(match: currentMatch)
                    .id(currentMatch.id)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 25)
                            .onEnded { value in
                                if value.translation.width < -40 {
                                    // Swipe Left -> Next source
                                    if selectedCandidateIndex < searchResults.count - 1 {
                                        HapticFeedback.selectionChanged()
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            selectedCandidateIndex += 1
                                            selectMatch(searchResults[selectedCandidateIndex])
                                        }
                                    }
                                } else if value.translation.width > 40 {
                                    // Swipe Right -> Previous source
                                    if selectedCandidateIndex > 0 {
                                        HapticFeedback.selectionChanged()
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            selectedCandidateIndex -= 1
                                            selectMatch(searchResults[selectedCandidateIndex])
                                        }
                                    }
                                }
                            }
                    )
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
                let hasOnlineArtwork = downloadedArtwork != nil || match.artworkURL != nil

                Group {
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
                                    .fill(Color.gray.opacity(0.2))
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hasOnlineArtwork ? Color.green : Color.orange, lineWidth: 1.5)
                )

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

            // Master Overwrite Controls Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TAG OVERWRITE OPTIONS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                        Text("Tap any tag below to toggle between Online (Green) & Local (Orange)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    Button(action: {
                        HapticFeedback.selectionChanged()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            lockedLocalFields.removeAll() // Overwrite ALL with online
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("OVERWRITE ALL (ONLINE)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(lockedLocalFields.isEmpty ? Color.green.opacity(0.25) : Color.appSecondaryBackground)
                        .foregroundStyle(lockedLocalFields.isEmpty ? Color.green : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(lockedLocalFields.isEmpty ? Color.green : Color.clear, lineWidth: 1.0)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        HapticFeedback.selectionChanged()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            lockedLocalFields = Set(MetadataField.allCases) // Keep ALL local
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                            Text("KEEP ALL LOCAL")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(lockedLocalFields.count == MetadataField.allCases.count ? Color.orange.opacity(0.25) : Color.appSecondaryBackground)
                        .foregroundStyle(lockedLocalFields.count == MetadataField.allCases.count ? Color.orange : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(lockedLocalFields.count == MetadataField.allCases.count ? Color.orange : Color.clear, lineWidth: 1.0)
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .padding(10)
            .background(Color.appSecondaryBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Interactive Per-Tag Toggle Table
            VStack(spacing: 6) {
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

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.35))

            // Direct File Writing Option Toggle
            Toggle(isOn: $libraryStore.settings.writeMetadataToAudioFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WRITE TAGS TO AUDIO FILE ON DISK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                    Text("Atomically embed updated ID3v2/M4A tags directly into the file.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.blue)
            .padding(.vertical, 4)

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
        let isDifferent = currentVal.trimmingCharacters(in: .whitespacesAndNewlines) != onlineVal.trimmingCharacters(in: .whitespacesAndNewlines)

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
            HStack(spacing: 10) {
                Text(field.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isUsingLocal ? Color.orange : Color.green)
                    .frame(width: 65, alignment: .leading)

                tagValueDisplay(isUsingLocal: isUsingLocal, isDifferent: isDifferent, currentVal: currentVal, onlineVal: onlineVal)

                Spacer()

                tagStatePill(isUsingLocal: isUsingLocal)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isUsingLocal ? Color.orange.opacity(0.06) : Color.green.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isUsingLocal ? Color.orange.opacity(0.2) : Color.green.opacity(0.2), lineWidth: 1.0)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tagValueDisplay(isUsingLocal: Bool, isDifferent: Bool, currentVal: String, onlineVal: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if isUsingLocal {
                Text(currentVal)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            } else {
                if isDifferent {
                    Text(currentVal)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                        .strikethrough(true, color: Color.red.opacity(0.6))
                        .lineLimit(1)
                }

                Text(onlineVal)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func tagStatePill(isUsingLocal: Bool) -> some View {
        HStack(spacing: 4) {
            if isUsingLocal {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text("LOCAL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .bold))
                Text("ONLINE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isUsingLocal ? Color.orange.opacity(0.18) : Color.green.opacity(0.18))
        .foregroundStyle(isUsingLocal ? Color.orange : Color.green)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isUsingLocal ? Color.orange.opacity(0.4) : Color.green.opacity(0.4), lineWidth: 0.8)
        )
    }

    // MARK: - Handlers

    private func performSearchWithCurrentSource() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        selectedMatch = nil
        selectedCandidateIndex = 0
        downloadedArtwork = nil

        let candidates: [OnlineTrackMetadata]
        if query.isEmpty {
            candidates = await MusicMetadataService.shared.searchOnline(for: track, source: selectedSourceAPI)
        } else {
            candidates = await MusicMetadataService.shared.searchOnline(query: query, source: selectedSourceAPI)
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
