import SwiftUI

/// Interactive review and confirmation sheet displaying matched discography candidates across
/// Albums, Singles & EPs, and Alternates. Follows the exact layout, typography, and styling
/// of AlbumMetadataSheet.
public struct DiscographyReviewSheet: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var scanResult: DiscographyScanResult
    @State private var category: DiscographyReviewCategory = .albums
    @State private var expandedAlbumIDs: Set<String> = []
    @State private var expandedAlternatesAlbumIDs: Set<String> = []
    @State private var expandedTrackIDs: Set<UUID> = []
    @State private var isApplyingChanges: Bool = false
    @State private var applyProgress: Double = 0.0
    @State private var applyStatusText: String = ""

    public init(scanResult: DiscographyScanResult, libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
        self._scanResult = State(initialValue: scanResult)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category Segmented Picker Header
                categoryHeaderView
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(appTheme.backgroundColor)

                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.35))

                // Scrollable Content
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 12) {
                        let displayedAlbums = currentDisplayedAlbums
                        if displayedAlbums.isEmpty {
                            emptyStateView
                                .padding(.top, 40)
                        } else {
                            ForEach(displayedAlbums) { albumItem in
                                albumRowCard(item: albumItem)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .padding(.bottom, 80)
                }

                // Bottom Persistent Action Bar
                bottomActionBar
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("DISCOGRAPHY REVIEW")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isApplyingChanges {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button(action: applyAllChanges) {
                            Text("APPLY")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Category Header

    private var categoryHeaderView: some View {
        Picker("Category", selection: $category) {
            Text("Albums (\(scanResult.albums.count))").tag(DiscographyReviewCategory.albums)
            Text("Singles (\(scanResult.singles.count))").tag(DiscographyReviewCategory.singles)
            Text("Alternates (\(scanResult.alternates.count))").tag(DiscographyReviewCategory.alternates)
        }
        .pickerStyle(.segmented)
    }

    private var currentDisplayedAlbums: [DiscographyAlbumReviewItem] {
        switch category {
        case .albums:
            return scanResult.albums
        case .singles:
            return scanResult.singles
        case .alternates:
            return scanResult.alternates
        }
    }

    // MARK: - Album Row Card (Expandable)

    private func albumRowCard(item: DiscographyAlbumReviewItem) -> some View {
        let isExpanded = expandedAlbumIDs.contains(item.id)

        return VStack(alignment: .leading, spacing: 0) {
            // Summary Header Button
            Button(action: {
                HapticFeedback.lightImpact()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedAlbumIDs.remove(item.id)
                    } else {
                        expandedAlbumIDs.insert(item.id)
                    }
                }
            }) {
                albumSummaryHeader(item: item, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            // Expanded Content (Tracklist Mapping Matrix & Unmatched Tracks)
            if isExpanded {
                Divider()
                    .overlay(appTheme.separatorColor.opacity(0.35))

                VStack(alignment: .leading, spacing: 14) {
                    // Side-by-Side Child Tracks Mapping Matrix
                    sideBySideTracksMatrix(item: item)

                    // Non-Album & Unmatched Tracks Routing Section (Alternates)
                    if !item.unmatchedTracks.isEmpty {
                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.35))

                        unmatchedTracksSection(item: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color.appSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isExpanded ? appTheme.accentColor.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Album Summary Header (Side-by-Side Comparison)

    private func albumSummaryHeader(item: DiscographyAlbumReviewItem, isExpanded: Bool) -> some View {
        let willOverwrite = item.willOverwrite

        return HStack(alignment: .center, spacing: 10) {
            // LEFT: Local Album Details
            HStack(spacing: 8) {
                AlbumArtworkView(
                    artworkKey: item.album.artworkKey,
                    title: item.album.title,
                    subtitle: item.album.artist,
                    cornerRadius: 6,
                    targetDimension: 52
                )
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text("LOCAL ALBUM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)

                    Text(item.album.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text(item.album.artist)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let year = item.album.resolvedYear ?? item.album.year {
                            Text(String(year))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("• \(item.album.tracks.count) TRACKS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // CENTER: Directional Arrow (.orange if keeping, .green if overwriting)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(willOverwrite ? Color.green : Color.orange)
                .padding(.horizontal, 2)

            // RIGHT: Online Matched Candidate Details
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    let sourceBadge: String = {
                        let s = item.selectedOnlineAlbum.sourceAPI.uppercased()
                        if s.contains("APPLE") || s.contains("ITUNES") { return "APPLE MUSIC" }
                        if s.contains("DEEZER") { return "DEEZER" }
                        if s.contains("SPOTIFY") { return "SPOTIFY" }
                        if s.contains("MUSICBRAINZ") { return "MUSICBRAINZ" }
                        return s
                    }()

                    Text(sourceBadge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.green)

                    Text(item.selectedOnlineAlbum.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(item.selectedOnlineAlbum.artistName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let y = item.selectedOnlineAlbum.releaseYear {
                            Text(String(y))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let count = item.selectedOnlineAlbum.trackCount ?? (item.onlineCuts.isEmpty ? nil : item.onlineCuts.count) {
                            Text("• \(count) TRACKS")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                if let artURL = item.selectedOnlineAlbum.artworkURL {
                    AsyncImage(url: artURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.gray.opacity(0.2))
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 52, height: 52)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Expand Chevron
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    // MARK: - Side-by-Side Child Tracks Matrix

    private func sideBySideTracksMatrix(item: DiscographyAlbumReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 8) {
                Text("LOCAL TRACKS (\(item.album.tracks.count))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)

                Text("ONLINE TRACKLIST (\(item.onlineCuts.count))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 0) {
                ForEach(Array(item.assignments.enumerated()), id: \.element.id) { index, assignment in
                    assignmentRow(index: index, assignment: assignment, inItem: item)
                }
            }
        }
    }

    // MARK: - Assignment Row Side-by-Side

    private func assignmentRow(
        index: Int,
        assignment: DisambiguationMatcher.AlbumCutAssignment,
        inItem item: DiscographyAlbumReviewItem
    ) -> some View {
        let cut = assignment.cut
        let localTrack = assignment.localTrack
        let isLocalInAlbum = localTrack != nil && item.album.tracks.contains(where: { $0.id == localTrack!.id })
        let isExternal = localTrack != nil && !isLocalInAlbum
        let isLocked = localTrack != nil && item.lockedTrackIDs.contains(localTrack!.id)

        let isAccepted: Bool = {
            guard let local = localTrack else { return false }
            if isLocked { return false }
            if isExternal {
                return item.acceptedTrackIDs.contains(local.id)
            } else {
                return !item.rejectedTrackIDs.contains(local.id)
            }
        }()

        let isExpanded = localTrack != nil && expandedTrackIDs.contains(localTrack!.id)
        let arrowColor: Color = isLocked ? Color.secondary : (isAccepted ? Color.green : Color.orange)
        let arrowSystemName: String = isAccepted ? "arrow.right" : "arrow.left"

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Left: Local Track
                HStack(spacing: 6) {
                    if let local = localTrack {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 18, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(local.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)

                                if isLocked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Color.orange)
                                }
                            }

                            Text(local.artist)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if isExternal {
                                Text(isAccepted ? "CONFIRMED • WILL IMPORT TO ALBUM" : "FROM LIBRARY • TAP TO LINK")
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
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let local = localTrack else { return }
                    HapticFeedback.selectionChanged()
                    toggleTrackAccepted(albumId: item.id, track: local, isExternal: isExternal)
                }
                .onLongPressGesture {
                    guard let local = localTrack else { return }
                    HapticFeedback.selectionChanged()
                    toggleTrackLock(albumId: item.id, trackId: local.id)
                }

                // Connector Arrow
                Image(systemName: arrowSystemName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(localTrack != nil ? arrowColor : Color.gray.opacity(0.4))
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let local = localTrack else { return }
                        HapticFeedback.selectionChanged()
                        toggleTrackAccepted(albumId: item.id, track: local, isExternal: isExternal)
                    }

                // Right: Online Cut
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

                        let cutArtist = cut.artist.isEmpty ? item.selectedOnlineAlbum.artistName : cut.artist
                        Text(cutArtist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    if localTrack != nil {
                        Button(action: {
                            if let local = localTrack {
                                HapticFeedback.selectionChanged()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    if isExpanded {
                                        expandedTrackIDs.remove(local.id)
                                    } else {
                                        expandedTrackIDs.insert(local.id)
                                    }
                                }
                            }
                        }) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)

            // Inline Field Diffs if expanded
            if isExpanded, let local = localTrack {
                inlineFieldDiffs(localTrack: local, cut: cut, onlineAlbum: item.selectedOnlineAlbum)
                    .padding(.leading, 24)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.35))
        }
    }

    // MARK: - Inline Field Diffs

    private func inlineFieldDiffs(localTrack: Track, cut: OnlineTrackMetadata, onlineAlbum: OnlineAlbumItem) -> some View {
        VStack(spacing: 3) {
            diffRow(label: "TITLE", local: localTrack.title, online: cut.title)
            diffRow(label: "TRACK #", local: localTrack.trackNumber != nil ? "\(localTrack.trackNumber!)" : "—", online: cut.trackNumber != nil ? "\(cut.trackNumber!)" : "—")
            diffRow(label: "DISC #", local: localTrack.discNumber != nil ? "\(localTrack.discNumber!)" : "—", online: cut.discNumber != nil ? "\(cut.discNumber!)" : "1")
            if let y = cut.releaseYear ?? onlineAlbum.releaseYear {
                diffRow(label: "YEAR", local: localTrack.year != nil ? "\(localTrack.year!)" : "—", online: "\(y)")
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func diffRow(label: String, local: String, online: String) -> some View {
        let hasDiff = local.lowercased() != online.lowercased()

        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(local)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(hasDiff ? Color.green : Color.gray.opacity(0.4))

            Text(online)
                .font(.system(size: 9, weight: hasDiff ? .bold : .regular, design: .monospaced))
                .foregroundStyle(hasDiff ? Color.green : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Unmatched Tracks Section

    private func unmatchedTracksSection(item: DiscographyAlbumReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("UNMATCHED TRACKS & ALTERNATES (\(item.unmatchedTracks.count))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                Spacer()
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 6) {
                ForEach(item.unmatchedTracks) { track in
                    unmatchedTrackRow(track: track, inItem: item)
                }
            }
        }
    }

    private func unmatchedTrackRow(track: Track, inItem item: DiscographyAlbumReviewItem) -> some View {
        let currentAction = item.unmatchedActions[track.id] ?? .moveToAlternates(reason: "Not on official tracklist")
        let otherAlbums = libraryStore.albums.filter { other in
            other.id != item.album.id && (
                FuzzyMatcher.normalize(other.artist) == FuzzyMatcher.normalize(item.album.artist)
            )
        }

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(currentAction.reasonText.uppercased())
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(actionTextColor(currentAction))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                Button(action: {
                    HapticFeedback.selectionChanged()
                    setAction(albumId: item.id, trackId: track.id, action: .moveToAlternates(reason: "Designated alternate cut"))
                }) {
                    Text(currentAction.isMoveToAlternates ? "MOVE TO ALTERNATES (SELECTED)" : "MOVE TO ALTERNATES")
                }

                if !otherAlbums.isEmpty {
                    Section("MOVE TO OTHER ALBUM") {
                        ForEach(otherAlbums) { targetAlbum in
                            Button(action: {
                                HapticFeedback.selectionChanged()
                                setAction(albumId: item.id, trackId: track.id, action: .moveToAlbum(
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
                                ))
                            }) {
                                Text(currentAction.targetAlbumTitle == targetAlbum.title ? "\(targetAlbum.title.uppercased()) (SELECTED)" : targetAlbum.title.uppercased())
                            }
                        }
                    }
                }

                Button(action: {
                    HapticFeedback.selectionChanged()
                    setAction(albumId: item.id, trackId: track.id, action: .keepInMain(reason: "User kept in tracklist"))
                }) {
                    Text(currentAction.isKeepInMain ? "KEEP IN MAIN TRACKLIST (SELECTED)" : "KEEP IN MAIN TRACKLIST")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentAction.displayTitle)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(actionTextColor(currentAction))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.appSecondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        VStack(spacing: 8) {
            if isApplyingChanges {
                VStack(spacing: 4) {
                    ProgressView(value: applyProgress)
                        .tint(appTheme.accentColor)
                    Text(applyStatusText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            } else {
                let overwritesCount = scanResult.totalOverwritesCount
                Button(action: applyAllChanges) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))

                        Text("APPLY METADATA CHANGES (\(overwritesCount) TRACKS)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(overwritesCount > 0 ? appTheme.accentColor : Color.gray.opacity(0.3))
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(overwritesCount == 0)
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Color.appSecondaryBackground)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("NO RELEASES FOUND")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("No releases matching the selected category filter.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State Mutations

    private func toggleTrackAccepted(albumId: String, track: Track, isExternal: Bool) {
        mutateItem(albumId: albumId) { item in
            if isExternal {
                if item.acceptedTrackIDs.contains(track.id) {
                    item.acceptedTrackIDs.remove(track.id)
                } else {
                    item.acceptedTrackIDs.insert(track.id)
                }
            } else {
                if item.rejectedTrackIDs.contains(track.id) {
                    item.rejectedTrackIDs.remove(track.id)
                } else {
                    item.rejectedTrackIDs.insert(track.id)
                }
            }
        }
    }

    private func toggleTrackLock(albumId: String, trackId: UUID) {
        mutateItem(albumId: albumId) { item in
            if item.lockedTrackIDs.contains(trackId) {
                item.lockedTrackIDs.remove(trackId)
            } else {
                item.lockedTrackIDs.insert(trackId)
            }
        }
    }

    private func setAction(albumId: String, trackId: UUID, action: UnmatchedTrackAction) {
        mutateItem(albumId: albumId) { item in
            item.unmatchedActions[trackId] = action
        }
    }

    private func mutateItem(albumId: String, mutation: (inout DiscographyAlbumReviewItem) -> Void) {
        for idx in scanResult.albums.indices where scanResult.albums[idx].id == albumId {
            mutation(&scanResult.albums[idx])
            return
        }
        for idx in scanResult.singles.indices where scanResult.singles[idx].id == albumId {
            mutation(&scanResult.singles[idx])
            return
        }
        for idx in scanResult.alternates.indices where scanResult.alternates[idx].id == albumId {
            mutation(&scanResult.alternates[idx])
            return
        }
    }

    // MARK: - Apply Changes Execution

    private func applyAllChanges() {
        guard !isApplyingChanges else { return }
        isApplyingChanges = true
        applyProgress = 0.0
        applyStatusText = "Applying discography metadata..."

        let result = self.scanResult
        Task(priority: .userInitiated) {
            await libraryStore.commitDiscographyScanResult(
                result,
                onProgress: { prog, status in
                    Task { @MainActor in
                        self.applyProgress = prog
                        self.applyStatusText = status
                    }
                }
            )

            Task { @MainActor in
                self.isApplyingChanges = false
                HapticFeedback.notificationSuccess()
                self.dismiss()
            }
        }
    }
}
