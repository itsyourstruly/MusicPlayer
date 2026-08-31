import SwiftUI

/// Double-check sheet for tracks that were verified and determined to already match online records.
/// Displays centered swipeable cards comparing local metadata and the verified online match.
public struct VerifiedGoodTracksListView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var selectedTrackForCustomSearch: Track? = nil
    @State private var recheckingTrackID: UUID? = nil
    @State private var searchText: String = ""

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    private var filteredDiffs: [MetadataDiff] {
        let query = FuzzyMatcher.normalize(searchText)
        if query.isEmpty { return libraryStore.verifiedGoodDiffs }
        return libraryStore.verifiedGoodDiffs.filter { diff in
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
                if libraryStore.verifiedGoodDiffs.isEmpty {
                    emptyStateView
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 20) {
                            searchBar

                            headerCard

                            if !searchText.isEmpty {
                                HStack {
                                    Text("SHOWING \(filteredDiffs.count) OF \(libraryStore.verifiedGoodDiffs.count) TRACKS")
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
                                    Text("No verified track matches query '\(searchText)'.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 32)
                            } else {
                                ForEach(filteredDiffs) { diff in
                                    VerifiedGoodTrackCard(
                                        diff: diff,
                                        isRechecking: recheckingTrackID == diff.localTrack.id,
                                        onCustomSearch: {
                                            selectedTrackForCustomSearch = diff.localTrack
                                        },
                                        onRescan: {
                                            rescanSingleTrack(diff.localTrack)
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
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("VERIFIED TRACKS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .sheet(item: $selectedTrackForCustomSearch) { track in
                OnlineMetadataMatchSheet(track: track, libraryStore: libraryStore)
                    .tint(appTheme.accentColor)
                    .environment(\.appTheme, appTheme)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("SEARCH VERIFIED TRACKS...", text: $searchText)
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VERIFIED & COMPLETE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("\(libraryStore.verifiedGoodCount) TRACKS MATCH ONLINE")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }

                Spacer()

                Button("RESCAN ALL") {
                    HapticFeedback.notificationSuccess()
                    libraryStore.recheckAllVerifiedGoodTracks()
                    dismiss()
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.blue)
                .buttonStyle(.plain)
            }

            Text("YOUR LOCAL AUDIO TAGS MATCH OFFICIAL ONLINE RECORDS. YOU CAN REVIEW THE ONLINE MATCH, CUSTOM SEARCH, OR RESCAN.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("NO VERIFIED TRACKS")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("No tracks have been verified as matching online records yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func rescanSingleTrack(_ track: Track) {
        recheckingTrackID = track.id
        Task {
            _ = await libraryStore.recheckVerifiedGoodTrack(track)
            await MainActor.run {
                recheckingTrackID = nil
            }
            HapticFeedback.notificationSuccess()
        }
    }
}

/// Centered, swipeable card displaying local track vs verified online match with sub-artwork status label.
/// Defaults to displaying original local metadata.
private struct VerifiedGoodTrackCard: View {
    let diff: MetadataDiff
    let isRechecking: Bool
    let onCustomSearch: () -> Void
    let onRescan: () -> Void

    @State private var selectedPage: Int = 1 // Default to 1 (ORIGINAL LOCAL)
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(spacing: 14) {
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

                // Page 1: Original Local Metadata (Default)
                localPageView
                    .tag(1)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .frame(height: 380)

            // Action Buttons
            HStack(spacing: 24) {
                Spacer()

                Button(action: onCustomSearch) {
                    Text("CUSTOM SEARCH")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)

                Button(action: onRescan) {
                    Text(isRechecking ? "RESCANNING..." : "RESCAN")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isRechecking ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(isRechecking)

                Spacer()
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Online Page View
    private var onlinePageView: some View {
        VStack(alignment: .center, spacing: 10) {
            let isUsingLocalArtwork = !diff.artworkUpgraded

            // Album Artwork on Top
            VStack(spacing: 6) {
                if isUsingLocalArtwork {
                    AlbumArtworkView(
                        artworkKey: diff.localTrack.artworkKey,
                        title: diff.localTrack.album,
                        subtitle: diff.localTrack.artist,
                        cornerRadius: 8
                    )
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange, lineWidth: 1.5)
                    )
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.green, lineWidth: 1.5)
                    )
                }

                // Sub-Artwork Status Label
                if isUsingLocalArtwork {
                    Text("USING LOCAL ARTWORK")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                } else {
                    HStack(spacing: 4) {
                        Text("USING ONLINE ARTWORK")
                        Text("• \(diff.onlineMetadata.sourceAPI.uppercased())")
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
                }
            }

            // Centered Metadata Rows Below
            VStack(alignment: .center, spacing: 6) {
                centeredRow(label: "TITLE", value: diff.onlineMetadata.title, isGreen: diff.titleChanged)
                centeredRow(label: "ARTIST", value: diff.onlineMetadata.artist, isGreen: diff.artistChanged)
                centeredRow(label: "ALBUM", value: diff.onlineMetadata.album, isGreen: diff.albumChanged)

                if let y = diff.onlineMetadata.releaseYear, y > 0 {
                    centeredRow(label: "YEAR", value: String(y), isGreen: diff.yearChanged)
                }

                if let g = diff.onlineMetadata.genre, !g.isEmpty && g != "—" {
                    centeredRow(label: "GENRE", value: g, isGreen: diff.genreChanged)
                }

                if let t = diff.onlineMetadata.trackNumber, t > 0 {
                    let totalStr = diff.onlineMetadata.totalTracks.map { " of \($0)" } ?? ""
                    centeredRow(label: "TRACK #", value: "\(t)\(totalStr)", isGreen: diff.trackNumberChanged)
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
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange, lineWidth: 1.5)
                )

                // Sub-Artwork Status Label
                Text("ORIGINAL LOCAL METADATA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
            }

            // Centered Local Metadata Rows
            VStack(alignment: .center, spacing: 6) {
                centeredRow(label: "TITLE", value: diff.localTrack.title, isGreen: false)
                centeredRow(label: "ARTIST", value: diff.localTrack.artist, isGreen: false)
                centeredRow(label: "ALBUM", value: diff.localTrack.album.isEmpty ? "—" : diff.localTrack.album, isGreen: false)
                centeredRow(label: "YEAR", value: diff.localTrack.year.map { String($0) } ?? "—", isGreen: false)
                if let g = diff.localTrack.genre, !g.isEmpty && g != "—" {
                    centeredRow(label: "GENRE", value: g, isGreen: false)
                }
                if let lt = diff.localTrack.trackNumber, lt > 0 {
                    let totalStr = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                    centeredRow(label: "TRACK #", value: "\(lt)\(totalStr)", isGreen: false)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func centeredRow(label: String, value: String, isGreen: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isGreen ? Color.green.opacity(0.85) : Color.orange.opacity(0.85))

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(isGreen ? Color.green : Color.orange)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }
}
