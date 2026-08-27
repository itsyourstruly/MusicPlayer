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
        // Query
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
                        LazyVStack(spacing: 16) {
                            // Pinned Search Bar at the Top
                            searchBar

                            // Header Summary & Global Re-check
                            UnmatchedHeaderCardView(
                                count: libraryStore.unmatchedTracks.count,
                                isScanning: libraryStore.isBackgroundCheckingMetadata,
                                onRecheckAll: {
                                    HapticFeedback.notificationSuccess()
                                    libraryStore.recheckAllUnmatchedTracks()
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
                                // Unmatched Track Cards
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
            // Modal presentation sheet
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

    // MARK: - Handlers

    // Recheck track
    private func recheckTrack(_ track: Track) {
        checkingTrackIDs.insert(track.id)
        trackStatusMessages[track.id] = "Checking online database..."

        Task {
            // Matched
            let matched = await libraryStore.recheckUnmatchedTrack(track)
            checkingTrackIDs.remove(track.id)
            if matched {
                trackStatusMessages[track.id] = "Match found! Added to enrichment queue."
                HapticFeedback.notificationSuccess()
            } else {
                trackStatusMessages[track.id] = "No exact match found."
            }
        }
    }

    private var emptyUnmatchedView: some View {
        VStack(spacing: 12) {
            Text("NO UNMATCHED TRACKS")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("All tracks in your linked directory have verified matches or complete metadata.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Subviews

/// Summary header card for unmatched / ignored tracks.
private struct UnmatchedHeaderCardView: View {
    // Count
    let count: Int
    // Flag indicating if scanning
    let isScanning: Bool
    // On recheck all
    let onRecheckAll: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Text("STRICT FILTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(appTheme.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }

            Text("These tracks had no exact match in the Apple Music catalog during background analysis and were ignored to prevent incorrect tag assignments.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()
                .overlay(appTheme.separatorColor)

            Button(action: onRecheckAll) {
                Text(isScanning ? "CHECKING DATABASE..." : "RE-CHECK ALL (\(count) TRACKS)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TypographicButtonStyle(variant: .primary, size: .regular))
            .disabled(isScanning)
        }
        .padding(14)
        .background(appTheme.secondaryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// An individual card for an unmatched track with artwork preview, metadata, and re-check actions.
private struct UnmatchedTrackCardView: View {
    // Track
    let track: Track
    // Flag indicating if checking
    let isChecking: Bool
    // Status message
    let statusMessage: String?
    // On recheck
    let onRecheck: () -> Void
    // On manual search
    let onManualSearch: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Album artwork thumbnail
                AlbumArtworkView(
                    artworkKey: track.artworkKey,
                    title: track.album,
                    subtitle: track.artist,
                    cornerRadius: 6
                )
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Metadata specs
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(track.album)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let info = track.fileInfo {
                            Text("• .\(info.fileExtension)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Text("IGNORED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(appTheme.backgroundColor.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                    .padding(.vertical, 2)
            }

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.5))

            // Action Buttons
            HStack(spacing: 10) {
                Button(action: onRecheck) {
                    Text(isChecking ? "CHECKING..." : "RE-CHECK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                .disabled(isChecking)

                Button(action: onManualSearch) {
                    Text("CUSTOM SEARCH")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .subtle, size: .small))
            }
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
