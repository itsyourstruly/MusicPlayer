import SwiftUI

/// Dedicated Album Metadata Sheet featuring a clean side-by-side comparison layout
/// between local album data (Orange) and verified online album data (Green).
public struct AlbumMetadataSheet: View {
    public let album: Album
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var searchQuery: String
    @State private var selectedSourceAPI: MetadataAPIOption = .all
    @State private var isSearching: Bool = false
    @State private var candidateAlbums: [OnlineAlbumItem] = []
    @State private var selectedOnlineAlbum: OnlineAlbumItem? = nil
    @State private var onlineAlbumTracks: [OnlineTrackMetadata] = []
    @State private var isLoadingTracks: Bool = false
    @State private var isApplying: Bool = false
    @State private var hasSearched: Bool = false
    @State private var acceptedTrackIDs: Set<UUID> = []
    @State private var rejectedTrackIDs: Set<UUID> = []
    @State private var unmatchedActions: [UUID: UnmatchedTrackAction] = [:]
    @State private var isAnalyzingUnmatched: Bool = false
    @State private var resolvedAssignments: [DisambiguationMatcher.AlbumCutAssignment] = []
    @State private var unmatchedLocalTracks: [Track] = []
    @State private var otherAlbumsByArtist: [Album] = []

    public init(
        album: Album,
        libraryStore: LibraryStore,
        preselectedOnlineAlbum: OnlineAlbumItem? = nil
    ) {
        self.album = album
        self.libraryStore = libraryStore
        let initialQuery = "\(album.artist) \(album.title)".trimmingCharacters(in: .whitespacesAndNewlines)
        self._searchQuery = State(initialValue: initialQuery)
        if let preselected = preselectedOnlineAlbum {
            self._selectedOnlineAlbum = State(initialValue: preselected)
            self._candidateAlbums = State(initialValue: [preselected])
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Search Bar & Source Selector
                topSearchBar

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.35))

                // Scrollable Main Content
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        // Candidate Matches Strip (when multiple online candidates exist)
                        if !candidateAlbums.isEmpty {
                            candidateAlbumsStrip
                        }

                        // Side-by-Side Album Header Cards
                        sideBySideAlbumHeaders

                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.35))

                        // Side-by-Side Child Tracks Mapping Matrix
                        sideBySideTracksMatrix

                        // Non-Album & Unmatched Tracks Routing Section
                        if !unmatchedLocalTracks.isEmpty {
                            Divider()
                                .overlay(appTheme.separatorColor.opacity(0.35))

                            unmatchedTracksSection
                        }

                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.35))

                        // Toggles & Apply Action
                        optionsAndApplySection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ALBUM METADATA")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                recalculateOtherAlbums()
                if let preselected = selectedOnlineAlbum, onlineAlbumTracks.isEmpty {
                    isLoadingTracks = true
                    let cuts = await MusicMetadataService.shared.fetchOnlineAlbumCuts(albumItem: preselected)
                    self.onlineAlbumTracks = cuts
                    self.isLoadingTracks = false
                    await computeTrackAssignmentsAsync()
                }
                if !hasSearched {
                    await performSearch()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Top Search Bar
    private var topSearchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("SEARCH ARTIST & ALBUM ONLINE", text: $searchQuery)
                    .font(.system(size: 13, weight: .medium))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onSubmit {
                        Task {
                            await performSearch()
                        }
                    }

                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    Task {
                        await performSearch()
                    }
                }) {
                    Text("SEARCH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSecondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Source Selector Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(MetadataAPIOption.allCases) { source in
                        Button(action: {
                            HapticFeedback.selectionChanged()
                            selectedSourceAPI = source
                            Task {
                                await performSearch()
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
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(appTheme.backgroundColor)
    }

    // MARK: - Candidate Albums Horizontal Strip
    private var candidateAlbumsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ONLINE MATCHES (\(candidateAlbums.count))")
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
                    ForEach(candidateAlbums) { item in
                        let isSelected = selectedOnlineAlbum?.id == item.id

                        Button(action: {
                            selectOnlineAlbum(item)
                        }) {
                            HStack(spacing: 8) {
                                AsyncImage(url: item.artworkURL) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img
                                            .resizable()
                                            .interpolation(.high)
                                            .antialiased(true)
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

                                    Text(item.artistName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: 4) {
                                        if let year = item.releaseYear {
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

    // MARK: - Side-by-Side Album Headers
    private var sideBySideAlbumHeaders: some View {
        HStack(alignment: .top, spacing: 16) {
            // LEFT: Local Album
            localAlbumHeaderCard
                .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT: Online Album
            onlineAlbumHeaderCard
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Left Card: Local Album
    private var localAlbumHeaderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOCAL ALBUM")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.orange)

            AlbumArtworkView(
                artworkKey: album.artworkKey,
                title: album.title,
                subtitle: album.artist,
                cornerRadius: 8
            )
            .frame(width: 86, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                Text(album.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let year = album.tracks.compactMap({ $0.year }).first(where: { $0 > 0 }) {
                        Text(String(year))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("• \(album.tracks.count) TRACKS")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Right Card: Online Match
    private var onlineAlbumHeaderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let online = selectedOnlineAlbum {
                let sourceName: String = {
                    let s = online.sourceAPI.uppercased()
                    if s.contains("APPLE") || s.contains("ITUNES") { return "APPLE MUSIC" }
                    if s.contains("DEEZER") { return "DEEZER" }
                    if s.contains("SPOTIFY") { return "SPOTIFY" }
                    if s.contains("MUSICBRAINZ") { return "MUSICBRAINZ" }
                    return s
                }()

                Text(sourceName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)

                AsyncImage(url: online.artworkURL) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .aspectRatio(contentMode: .fill)
                    default:
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(online.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)

                    Text(online.artistName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let year = online.releaseYear {
                            Text(String(year))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let tc = online.trackCount {
                            Text("• \(tc) TRACKS")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if isSearching {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(Color.primary)
                    Text("SEARCHING...")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 6) {
                    Text("NO MATCH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Search or switch source.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    // MARK: - Candidates and Bipartite Matching for Local Album

    private func computeTrackAssignmentsAsync() async {
        guard !onlineAlbumTracks.isEmpty else {
            await MainActor.run {
                self.resolvedAssignments = []
                self.unmatchedLocalTracks = []
            }
            return
        }

        let currentAlbum = self.album
        let cuts = self.onlineAlbumTracks
        let selectedOnline = self.selectedOnlineAlbum
        let allTracks = self.libraryStore.tracks

        let (assignments, _) = await Task.detached(priority: .userInitiated) { () -> ([DisambiguationMatcher.AlbumCutAssignment], [Track]) in
            let localIDs = Set(currentAlbum.tracks.map { $0.id })
            var cutTitles = Set<String>()
            for cut in cuts {
                cutTitles.insert(FuzzyMatcher.normalize(cut.title))
                let sig = MetadataSanitizer.buildSignature(title: cut.title, artist: cut.artist, album: cut.album)
                cutTitles.insert(FuzzyMatcher.normalize(sig.coreTitle))
            }

            let cleanAlbumArtist = FuzzyMatcher.normalize(currentAlbum.artist)
            let cleanOnlineArtist = FuzzyMatcher.normalize(selectedOnline?.artistName ?? "")

            var candidateTracks = currentAlbum.tracks
            var seenIDs = localIDs

            for track in allTracks {
                guard !seenIDs.contains(track.id) else { continue }
                let tTitle = FuzzyMatcher.normalize(track.title)
                let sig = MetadataSanitizer.sanitize(track: track)
                let tCoreTitle = FuzzyMatcher.normalize(sig.coreTitle)
                guard cutTitles.contains(tTitle) || cutTitles.contains(tCoreTitle) else { continue }

                let tArtist = FuzzyMatcher.normalize(track.artist)
                let isArtistMatch = (!cleanAlbumArtist.isEmpty && (tArtist == cleanAlbumArtist || tArtist.contains(cleanAlbumArtist) || cleanAlbumArtist.contains(tArtist))) ||
                                    (!cleanOnlineArtist.isEmpty && (tArtist == cleanOnlineArtist || tArtist.contains(cleanOnlineArtist) || cleanOnlineArtist.contains(tArtist)))

                if isArtistMatch {
                    candidateTracks.append(track)
                    seenIDs.insert(track.id)
                }
            }

            let (matched, _) = DisambiguationMatcher.matchAlbumTracklistToCandidates(
                onlineTracks: cuts,
                albumTitle: selectedOnline?.title ?? currentAlbum.title,
                albumArtist: selectedOnline?.artistName ?? currentAlbum.artist,
                candidateTracks: candidateTracks
            )

            var matchedInAlbum: Set<UUID> = []
            for a in matched {
                guard let local = a.localTrack else { continue }
                if currentAlbum.tracks.contains(where: { $0.id == local.id }) {
                    matchedInAlbum.insert(local.id)
                }
            }
            let unmatched = currentAlbum.tracks.filter { !matchedInAlbum.contains($0.id) }
            return (matched, unmatched)
        }.value

        await MainActor.run {
            self.resolvedAssignments = assignments
            self.updateUnmatchedLocalTracks()
        }
    }

    /// Instantaneous O(N) local filtering (< 0.01ms) for 120fps fluid track toggling without re-running global matching.
    private func updateUnmatchedLocalTracks() {
        var matchedInAlbum: Set<UUID> = []
        for assignment in resolvedAssignments {
            guard let local = assignment.localTrack else { continue }
            let isLocalInAlbum = album.tracks.contains(where: { $0.id == local.id })
            if isLocalInAlbum {
                if !rejectedTrackIDs.contains(local.id) {
                    matchedInAlbum.insert(local.id)
                }
            }
        }
        self.unmatchedLocalTracks = album.tracks.filter { !matchedInAlbum.contains($0.id) }
    }

    private func recalculateOtherAlbums() {
        let currentNormTitle = FuzzyMatcher.normalize(album.title)
        let artistNorm = FuzzyMatcher.normalize(album.artist)
        let onlineArtistNorm = FuzzyMatcher.normalize(selectedOnlineAlbum?.artistName ?? "")
        self.otherAlbumsByArtist = libraryStore.albums.filter { other in
            let otherNormTitle = FuzzyMatcher.normalize(other.title)
            guard otherNormTitle != currentNormTitle else { return false }
            let otherArtistNorm = FuzzyMatcher.normalize(other.artist)
            let isLocalMatch = !artistNorm.isEmpty && (otherArtistNorm == artistNorm || otherArtistNorm.contains(artistNorm) || artistNorm.contains(otherArtistNorm))
            let isOnlineMatch = !onlineArtistNorm.isEmpty && (otherArtistNorm == onlineArtistNorm || otherArtistNorm.contains(onlineArtistNorm) || onlineArtistNorm.contains(otherArtistNorm))
            return isLocalMatch || isOnlineMatch
        }
    }

    private var sortedUnmatchedLocalTracks: [Track] {
        unmatchedLocalTracks.sorted { lhs, rhs in
            let actionLhs = unmatchedActions[lhs.id] ?? .moveToAlternates(reason: "")
            let actionRhs = unmatchedActions[rhs.id] ?? .moveToAlternates(reason: "")

            let rankLhs: Int
            switch actionLhs {
            case .moveToAlbum: rankLhs = 0
            case .keepInMain: rankLhs = 1
            case .moveToAlternates: rankLhs = 2
            }

            let rankRhs: Int
            switch actionRhs {
            case .moveToAlbum: rankRhs = 0
            case .keepInMain: rankRhs = 1
            case .moveToAlternates: rankRhs = 2
            }

            if rankLhs != rankRhs {
                return rankLhs < rankRhs
            }

            let trackNumL = lhs.trackNumber ?? 999
            let trackNumR = rhs.trackNumber ?? 999
            if trackNumL != trackNumR {
                return trackNumL < trackNumR
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: - Side-by-Side Child Tracks Matrix
    private var sideBySideTracksMatrix: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Matrix Header
            HStack(spacing: 8) {
                Text("LOCAL TRACKS (\(album.tracks.count))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)

                Text("ONLINE TRACKLIST (\(onlineAlbumTracks.count))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)

            if !resolvedAssignments.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(Array(resolvedAssignments.enumerated()), id: \.element.id) { index, assignment in
                        assignmentRowSideBySide(index: index, assignment: assignment)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, localTrack in
                        childTrackRowSideBySide(index: index, localTrack: localTrack)
                    }
                }
            }
        }
    }

    // MARK: - Assignment Row Side-by-Side
    private func assignmentRowSideBySide(index: Int, assignment: DisambiguationMatcher.AlbumCutAssignment) -> some View {
        let cut = assignment.cut
        let localTrack = assignment.localTrack
        let isLocalInCurrentAlbum = localTrack != nil && album.tracks.contains(where: { $0.id == localTrack!.id })
        let isExternalCandidate = localTrack != nil && !isLocalInCurrentAlbum

        let isAccepted: Bool = {
            guard let local = localTrack else { return false }
            if isExternalCandidate {
                return acceptedTrackIDs.contains(local.id)
            } else {
                return !rejectedTrackIDs.contains(local.id)
            }
        }()

        let arrowColor: Color = isAccepted ? Color.green : Color.orange
        let arrowSystemName: String = isAccepted ? "arrow.right" : "arrow.left"

        return Button(action: {
            guard let local = localTrack else { return }
            HapticFeedback.selectionChanged()
            if isExternalCandidate {
                if acceptedTrackIDs.contains(local.id) {
                    acceptedTrackIDs.remove(local.id)
                } else {
                    acceptedTrackIDs.insert(local.id)
                }
            } else {
                if rejectedTrackIDs.contains(local.id) {
                    rejectedTrackIDs.remove(local.id)
                } else {
                    rejectedTrackIDs.insert(local.id)
                    if unmatchedActions[local.id] == nil {
                        let fastAction = AlbumOrganizationService.shared.fastLocalResolveUnmatchedTrack(
                            track: local,
                            currentAlbum: album,
                            onlineCuts: onlineAlbumTracks,
                            otherAlbums: otherAlbumsByArtist
                        )
                        self.unmatchedActions[local.id] = fastAction
                    }
                }
            }
            updateUnmatchedLocalTracks()
        }) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    // Left: Local Track (no background, clean text)
                    HStack(spacing: 6) {
                        if let local = localTrack {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 18, alignment: .leading)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(local.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)

                                Text(local.artist)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if isExternalCandidate {
                                    let originText = local.artist.localizedCaseInsensitiveCompare(album.artist) == .orderedSame
                                        ? "FOUND IN LIBRARY • TAP TO IMPORT"
                                        : "FROM ARTIST \"\(local.artist)\" • TAP TO LINK"
                                    Text(isAccepted ? "CONFIRMED • WILL IMPORT TO ALBUM" : originText)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(arrowColor)
                                        .lineLimit(1)
                                } else if assignment.isMislabeled, let reason = assignment.mislabelReason {
                                    Text(reason.uppercased())
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(arrowColor)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 2)
                        } else {
                            Text("—")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .leading)

                            Text("MISSING FROM ALBUM")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)

                            Spacer(minLength: 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Connector Arrow: Colored; flips to orange left arrow when track is tapped
                    Image(systemName: arrowSystemName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(localTrack != nil ? arrowColor : Color.gray.opacity(0.4))
                        .frame(width: 20)

                    // Right: Online Cut (no background, clean text)
                    HStack(spacing: 6) {
                        let cutNum = cut.trackNumber ?? (index + 1)
                        Text("\(cutNum)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 18, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(cut.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            let cutArtist = cut.artist.isEmpty ? (selectedOnlineAlbum?.artistName ?? album.artist) : cut.artist
                            Text(cutArtist)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())

                // Small separator line between tracks
                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fallback Side-by-Side Row
    private func childTrackRowSideBySide(index: Int, localTrack: Track) -> some View {
        let signature = MetadataSanitizer.sanitize(track: localTrack)
        let matchedCut = DisambiguationMatcher.findTrackCutInAlbum(
            for: localTrack,
            signature: signature,
            in: onlineAlbumTracks
        )

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Left: Local Track
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(localTrack.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)

                        Text(localTrack.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Connector
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.green)
                    .frame(width: 20)

                // Right: Online Cut
                HStack(spacing: 6) {
                    if let cut = matchedCut {
                        let cutNum = cut.trackNumber ?? (index + 1)
                        Text("\(cutNum)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(cut.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            let cutArtist = cut.artist.isEmpty ? (selectedOnlineAlbum?.artistName ?? album.artist) : cut.artist
                            Text(cutArtist)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 2)
                    } else {
                        Text("PRESERVE LOCAL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)

            // Small separator line between tracks
            Divider()
                .overlay(appTheme.separatorColor.opacity(0.35))
        }
    }

    // MARK: - Non-Album & Unmatched Tracks Routing Section
    private var unmatchedTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("UNMATCHED TRACKS (\(sortedUnmatchedLocalTracks.count))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.orange)

                        Button(action: triggerUnmatchedScan) {
                            HStack(spacing: 4) {
                                if isAnalyzingUnmatched {
                                    ProgressView()
                                        .tint(Color.white)
                                        .scaleEffect(0.6)
                                    Text("SCANNING...")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.white)
                                } else {
                                    Text("SCAN")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.white)
                                }
                            }
                        }
                        .disabled(isAnalyzingUnmatched || selectedOnlineAlbum == nil)
                    }

                    Text("Tracks in local album not on official tracklist. Tap badge to re-route.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 6) {
                ForEach(sortedUnmatchedLocalTracks) { track in
                    unmatchedTrackRow(track: track)
                }
            }
        }
    }

    private func unmatchedTrackRow(track: Track) -> some View {
        let currentAction = unmatchedActions[track.id] ?? .moveToAlternates(reason: "Not on official tracklist")

        return HStack(spacing: 8) {
            // Track title and artist
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(currentAction.reasonText.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(actionTextColor(currentAction))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Interactive routing menu (clean text only, no background)
            Menu {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    unmatchedActions[track.id] = .moveToAlternates(reason: "Designated alternate cut")
                }) {
                    HStack {
                        Text("Move to Alternates")
                        if currentAction.isMoveToAlternates {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                if !otherAlbumsByArtist.isEmpty {
                    Section("MOVE TO OTHER ALBUM") {
                        ForEach(otherAlbumsByArtist) { targetAlbum in
                            Button(action: {
                                HapticFeedback.selectionChanged()
                                unmatchedActions[track.id] = .moveToAlbum(
                                    albumTitle: targetAlbum.title,
                                    artistName: targetAlbum.artist,
                                    year: targetAlbum.year,
                                    genre: targetAlbum.genre,
                                    artworkKey: targetAlbum.artworkKey,
                                    artworkURL: nil,
                                    trackNumber: nil,
                                    totalTracks: targetAlbum.tracks.count,
                                    discNumber: nil,
                                    reason: "Manual move to \"\(targetAlbum.title)\""
                                )
                            }) {
                                HStack {
                                    Text(targetAlbum.title)
                                    if currentAction.targetAlbumTitle == targetAlbum.title {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                Button(action: {
                    HapticFeedback.selectionChanged()
                    unmatchedActions[track.id] = .keepInMain(reason: "User kept in tracklist")
                }) {
                    HStack {
                        Text("Keep in Main Tracklist")
                        if currentAction.isKeepInMain {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentAction.displayTitle)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(actionTextColor(currentAction))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.appSecondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func actionTextColor(_ action: UnmatchedTrackAction) -> Color {
        switch action {
        case .moveToAlternates:
            return Color.orange
        case .moveToAlbum:
            return Color.blue
        case .keepInMain:
            return Color.secondary
        }
    }

    // MARK: - Options & Apply Section
    private var optionsAndApplySection: some View {
        VStack(spacing: 12) {
            TypographicToggleRow(
                title: "WRITE TAGS TO AUDIO FILES ON DISK",
                subtitle: "Atomically embed updated ID3v2/M4A album tags and cover art.",
                isOn: Binding(
                    get: { libraryStore.settings.writeMetadataToAudioFiles },
                    set: { newValue in
                        libraryStore.settings.writeMetadataToAudioFiles = newValue
                        libraryStore.saveSettings()
                    }
                )
            )

            // Apply Button
            if let selectedAlbum = selectedOnlineAlbum {
                Button(action: {
                    applyAlbumToChildren(selectedAlbum: selectedAlbum)
                }) {
                    HStack(spacing: 6) {
                        if isApplying {
                            ProgressView()
                                .tint(Color.appInvertedBackground)
                        }
                        Text(isApplying ? "APPLYING TO ALL TRACKS..." : "APPLY ALBUM TO ALL TRACKS")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
                .disabled(isApplying)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Actions

    private func performSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        hasSearched = true
        let results = await MusicMetadataService.shared.searchOnlineAlbums(query: q, source: selectedSourceAPI)
        await MainActor.run {
            self.candidateAlbums = results
            self.isSearching = false
            if selectedOnlineAlbum == nil, let first = results.first {
                self.selectOnlineAlbum(first)
            } else if selectedOnlineAlbum == nil {
                self.onlineAlbumTracks = []
                self.resolvedAssignments = []
                self.unmatchedLocalTracks = []
            }
        }
    }

    private func selectOnlineAlbum(_ item: OnlineAlbumItem) {
        HapticFeedback.selectionChanged()
        withAnimation(.easeInOut(duration: 0.2)) {
            self.selectedOnlineAlbum = item
            self.isLoadingTracks = true
        }
        recalculateOtherAlbums()

        Task {
            let cuts = await MusicMetadataService.shared.fetchOnlineAlbumCuts(albumItem: item)
            await MainActor.run {
                self.onlineAlbumTracks = cuts
                self.isLoadingTracks = false
            }
            await self.computeTrackAssignmentsAsync()
        }
    }

    private func triggerUnmatchedScan() {
        guard !isAnalyzingUnmatched, let selected = selectedOnlineAlbum else { return }
        HapticFeedback.lightImpact()
        Task {
            var cuts = self.onlineAlbumTracks
            if cuts.isEmpty {
                cuts = await MusicMetadataService.shared.fetchOnlineAlbumCuts(albumItem: selected)
                await MainActor.run {
                    self.onlineAlbumTracks = cuts
                }
                await self.computeTrackAssignmentsAsync()
            }
            await analyzeUnmatchedTracks(onlineAlbum: selected, cuts: cuts)
        }
    }

    private func analyzeUnmatchedTracks(onlineAlbum: OnlineAlbumItem, cuts: [OnlineTrackMetadata]) async {
        await MainActor.run {
            self.isAnalyzingUnmatched = true
        }
        let currentUnmatched = self.unmatchedLocalTracks
        guard !currentUnmatched.isEmpty else {
            await MainActor.run {
                self.isAnalyzingUnmatched = false
            }
            return
        }

        let actions = await AlbumOrganizationService.shared.resolveAllUnmatchedTracks(
            tracks: currentUnmatched,
            currentAlbum: album,
            onlineAlbum: onlineAlbum,
            onlineCuts: cuts,
            libraryAlbums: libraryStore.albums
        )

        await MainActor.run {
            for (trackID, action) in actions {
                self.unmatchedActions[trackID] = action
            }
            self.isAnalyzingUnmatched = false
        }
    }

    private func applyAlbumToChildren(selectedAlbum: OnlineAlbumItem) {
        guard !isApplying else { return }
        isApplying = true

        var activeAssignments: [DisambiguationMatcher.AlbumCutAssignment] = []
        for assignment in resolvedAssignments {
            guard let local = assignment.localTrack else { continue }
            let isLocalInAlbum = album.tracks.contains(where: { $0.id == local.id })
            if isLocalInAlbum {
                if !rejectedTrackIDs.contains(local.id) {
                    activeAssignments.append(assignment)
                }
            } else {
                if acceptedTrackIDs.contains(local.id) {
                    activeAssignments.append(assignment)
                }
            }
        }

        let targetTracks = activeAssignments.compactMap { $0.localTrack }
        let tracksToApply = targetTracks.isEmpty ? album.tracks : targetTracks

        Task {
            let success = await libraryStore.applyOnlineAlbumToAlbum(
                album: album,
                onlineAlbum: selectedAlbum,
                onlineTracks: onlineAlbumTracks,
                preserveLocalTitleAndArtist: false,
                specificTracksToApply: tracksToApply,
                specificAssignments: activeAssignments,
                unmatchedActions: unmatchedActions
            )

            await MainActor.run {
                self.isApplying = false
                if success {
                    HapticFeedback.notificationSuccess()
                    dismiss()
                } else {
                    HapticFeedback.notificationError()
                }
            }
        }
    }
}
