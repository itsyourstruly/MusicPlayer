import SwiftUI

/// Dedicated manager sheet for inspecting and re-checking tracks that had no exact online matches
/// and were marked as ignored during background analysis.
public struct UnmatchedTracksListView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var selectedTrackForManualSearch: Track? = nil
    @State private var checkingTrackIDs: Set<UUID> = []
    @State private var trackStatusMessages: [UUID: String] = [:]
    @State private var searchText: String = ""

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    private var filteredTracks: [Track] {
        let query = FuzzyMatcher.normalize(searchText)
        if query.isEmpty { return libraryStore.unmatchedTracks }
        return libraryStore.unmatchedTracks.filter { track in
            track.searchTokens.contains(query)
        }
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            Group {
                if libraryStore.unmatchedTracks.isEmpty {
                    emptyUnmatchedView
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 20) {
                            searchBar

                            UnmatchedHeaderCardView(
                                count: libraryStore.unmatchedTracks.count,
                                onRescanAll: {
                                    HapticFeedback.notificationSuccess()
                                    libraryStore.recheckAllUnmatchedTracks()
                                    dismiss()
                                }
                            )

                            if !searchText.isEmpty {
                                HStack {
                                    Text("SHOWING \(filteredTracks.count) OF \(libraryStore.unmatchedTracks.count) TRACKS")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 2)
                            }

                            if filteredTracks.isEmpty && !searchText.isEmpty {
                                VStack(spacing: 8) {
                                    Text("NO MATCHING TRACKS FOUND")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.primary)
                                    Text("No unmatched track matches query '\(searchText)'.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 32)
                            } else {
                                ForEach(filteredTracks) { track in
                                    UnmatchedTrackCardView(
                                        track: track,
                                        isChecking: checkingTrackIDs.contains(track.id),
                                        statusMessage: trackStatusMessages[track.id],
                                        onRecheck: {
                                            recheckTrack(track)
                                        },
                                        onManualSearch: {
                                            selectedTrackForManualSearch = track
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
            .navigationTitle("UNMATCHED TRACKS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .sheet(item: $selectedTrackForManualSearch) { track in
                OnlineMetadataMatchSheet(track: track, libraryStore: libraryStore)
                    .tint(appTheme.accentColor)
                    .environment(\.appTheme, appTheme)
            }
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

    // Recheck track safely in background
    private func recheckTrack(_ track: Track) {
        checkingTrackIDs.insert(track.id)
        trackStatusMessages[track.id] = "Checking online database..."

        Task {
            let matched = await libraryStore.recheckUnmatchedTrack(track)
            await MainActor.run {
                checkingTrackIDs.remove(track.id)
                if matched {
                    trackStatusMessages[track.id] = "Match found! Added to enrichment queue."
                    HapticFeedback.notificationSuccess()
                } else {
                    trackStatusMessages[track.id] = "No exact match found."
                }
            }
        }
    }

    private var emptyUnmatchedView: some View {
        VStack(spacing: 12) {
            Text("NO UNMATCHED TRACKS")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("All tracks in your music library were successfully recognized or verified.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Summary header card for Unmatched Tracks sheet with RESCAN ALL button.
private struct UnmatchedHeaderCardView: View {
    let count: Int
    let onRescanAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NO EXACT ONLINE MATCH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("\(count) TRACKS MARKED AS IGNORED")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }

                Spacer()

                Button("RESCAN ALL") {
                    onRescanAll()
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.blue)
                .buttonStyle(.plain)
            }

            Text("THESE TRACKS HAD NO EXACT MATCH IN ONLINE CATALOGS DURING BACKGROUND ANALYSIS. YOU CAN RUN CUSTOM SEARCH OR RESCAN.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

/// Centered card for an unmatched track with artwork on top, sub-artwork status, and centered metadata.
private struct UnmatchedTrackCardView: View {
    let track: Track
    let isChecking: Bool
    let statusMessage: String?
    let onRecheck: () -> Void
    let onManualSearch: () -> Void

    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            // Centered Album Artwork
            VStack(spacing: 6) {
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 8
                )
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Sub-Artwork Status Label
                Text("ORIGINAL LOCAL METADATA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }

            // Centered Metadata Rows
            VStack(alignment: .center, spacing: 6) {
                centeredRow(label: "TITLE", value: track.title)
                centeredRow(label: "ARTIST", value: track.artist)
                centeredRow(label: "ALBUM", value: track.album.isEmpty ? "—" : track.album)
                centeredRow(label: "YEAR", value: track.year.map { String($0) } ?? "—")

                if let g = track.genre, !g.isEmpty && g != "Unknown Genre" && g != "—" {
                    centeredRow(label: "GENRE", value: g)
                }

                if let info = track.fileInfo {
                    centeredRow(label: "CODEC", value: info.formatDescription)
                }
            }
            .frame(maxWidth: .infinity)

            if let msg = statusMessage {
                Text(msg.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.blue)
                    .padding(.vertical, 2)
            }

            // Centered Action Buttons matching Look Good sheet
            HStack(spacing: 24) {
                Spacer()

                Button(action: onManualSearch) {
                    Text("CUSTOM SEARCH")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)

                Button(action: onRecheck) {
                    Text(isChecking ? "RESCANNING..." : "RESCAN")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isChecking ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(isChecking)

                Spacer()
            }
        }
        .padding(.vertical, 8)
    }

    private func centeredRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }
}
