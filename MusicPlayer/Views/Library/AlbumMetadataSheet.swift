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
    @State private var preserveFeatures: Bool = true
    @State private var isApplying: Bool = false
    @State private var hasSearched: Bool = false
    @State private var acceptedTrackIDs: Set<UUID> = []
    @State private var rejectedTrackIDs: Set<UUID> = []

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                }
            }
            .task {
                if let preselected = selectedOnlineAlbum, onlineAlbumTracks.isEmpty {
                    isLoadingTracks = true
                    let cuts = await MusicMetadataService.shared.fetchOnlineAlbumCuts(albumItem: preselected)
                    self.onlineAlbumTracks = cuts
                    self.isLoadingTracks = false
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
                HStack(spacing: 10) {
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
                                            .aspectRatio(contentMode: .fill)
                                    default:
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.gray.opacity(0.2))
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(Color.primary.opacity(0.15), lineWidth: 1.0)
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.primary)
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
                                            .foregroundStyle(appTheme.accentColor)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(isSelected ? appTheme.accentColor.opacity(0.18) : Color.appSecondaryBackground.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSelected ? appTheme.accentColor : Color.clear, lineWidth: 1.5)
                            )
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

    private var candidateTracksForAlbum: [Track] {
        var localTracks = album.tracks
        let localIDs = Set(album.tracks.map { $0.id })

        let cutTitles = Set(onlineAlbumTracks.map { FuzzyMatcher.normalize($0.title) })
        let cleanArtist = FuzzyMatcher.normalize(album.artist)

        var tier2Candidates: [Track] = []
        var tier3Candidates: [Track] = []
        var seenIDs = localIDs

        for track in libraryStore.tracks {
            guard !seenIDs.contains(track.id) else { continue }
            let tTitle = FuzzyMatcher.normalize(track.title)
            guard cutTitles.contains(tTitle) else { continue }

            let tArtist = FuzzyMatcher.normalize(track.artist)
            let isArtistMatch = tArtist == cleanArtist || tArtist.contains(cleanArtist) || cleanArtist.contains(tArtist)

            if isArtistMatch {
                tier2Candidates.append(track)
                seenIDs.insert(track.id)
            } else {
                tier3Candidates.append(track)
                seenIDs.insert(track.id)
            }
        }

        localTracks.append(contentsOf: tier2Candidates)
        localTracks.append(contentsOf: tier3Candidates)
        return localTracks
    }

    private var resolvedAssignments: [DisambiguationMatcher.AlbumCutAssignment] {
        guard !onlineAlbumTracks.isEmpty else { return [] }
        let (assignments, _) = DisambiguationMatcher.matchAlbumTracklistToCandidates(
            onlineTracks: onlineAlbumTracks,
            albumTitle: selectedOnlineAlbum?.title ?? album.title,
            albumArtist: selectedOnlineAlbum?.artistName ?? album.artist,
            candidateTracks: candidateTracksForAlbum
        )
        return assignments
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
                LazyVStack(spacing: 6) {
                    ForEach(Array(resolvedAssignments.enumerated()), id: \.element.id) { index, assignment in
                        assignmentRowSideBySide(index: index, assignment: assignment)
                    }
                }
            } else {
                LazyVStack(spacing: 6) {
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

        let statusColor: Color = isAccepted ? Color.green : Color.orange

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
                }
            }
        }) {
            HStack(spacing: 6) {
                // Left: Local Track
                HStack(spacing: 6) {
                    if let local = localTrack {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(statusColor)
                            .frame(width: 18, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(local.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(statusColor)
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
                                    .foregroundStyle(statusColor)
                                    .lineLimit(1)
                            } else if assignment.isMislabeled, let reason = assignment.mislabelReason {
                                Text(reason.uppercased())
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(statusColor)
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
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(localTrack != nil ? statusColor.opacity(0.08) : Color.appSecondaryBackground.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(localTrack != nil ? statusColor.opacity(0.25) : Color.clear, lineWidth: 1.0)
                )

                // Connector
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(localTrack != nil ? statusColor.opacity(0.8) : Color.gray.opacity(0.5))

                // Right: Online Cut
                HStack(spacing: 6) {
                    let cutNum = cut.trackNumber ?? (index + 1)
                    Text("\(cutNum)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .frame(width: 18, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(cut.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)

                        let cutArtist = cut.artist.isEmpty ? (selectedOnlineAlbum?.artistName ?? album.artist) : cut.artist
                        Text(cutArtist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(localTrack != nil ? statusColor.opacity(0.08) : Color.appSecondaryBackground.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(localTrack != nil ? statusColor.opacity(0.25) : Color.clear, lineWidth: 1.0)
                )
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

        return HStack(spacing: 6) {
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
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSecondaryBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Connector
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)

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
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSecondaryBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: - Options & Apply Section
    private var optionsAndApplySection: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $preserveFeatures) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PRESERVE LOCAL TITLE & FEATURES")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                    Text("Retains original song titles and (feat. XYZ) artist credits.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.orange)
            .padding(.vertical, 2)

            Toggle(isOn: $libraryStore.settings.writeMetadataToAudioFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WRITE TAGS TO AUDIO FILES ON DISK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                    Text("Atomically embed updated ID3v2/M4A album tags and cover art.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.blue)
            .padding(.vertical, 2)

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
            }
        }
    }

    private func selectOnlineAlbum(_ item: OnlineAlbumItem) {
        HapticFeedback.selectionChanged()
        withAnimation(.easeInOut(duration: 0.2)) {
            self.selectedOnlineAlbum = item
            self.isLoadingTracks = true
        }

        Task {
            let cuts = await MusicMetadataService.shared.fetchOnlineAlbumCuts(albumItem: item)
            await MainActor.run {
                self.onlineAlbumTracks = cuts
                self.isLoadingTracks = false
            }
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
                preserveLocalTitleAndArtist: preserveFeatures,
                specificTracksToApply: tracksToApply
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
