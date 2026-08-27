//
//  VerifiedGoodTracksListView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import SwiftUI

/// Double-check sheet for tracks that were verified and determined to already match online records.
/// Displays side-by-side comparisons of local metadata and the verified online match, allowing
/// the user to review, re-apply online tags & artwork, or rescan.
public struct VerifiedGoodTracksListView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var recheckingTrackID: UUID? = nil
    @State private var searchText: String = ""

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

    public var body: some View {
        NavigationStack {
            Group {
                if libraryStore.verifiedGoodDiffs.isEmpty {
                    emptyStateView
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 16) {
                            // Pinned Search Bar at the Top
                            searchBar

                            // Summary Header Card
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
                                // Verified Good Track Cards
                                ForEach(filteredDiffs) { diff in
                                    VerifiedGoodTrackCard(
                                        diff: diff,
                                        isRechecking: recheckingTrackID == diff.localTrack.id,
                                        onApplyOnline: {
                                            applyOnlineTags(diff)
                                        },
                                        onRescan: {
                                            rescanSingleTrack(diff.localTrack)
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

    // MARK: - Subviews

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
                    libraryStore.recheckAllVerifiedGoodTracks()
                    HapticFeedback.notificationSuccess()
                }
                .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
            }

            Text("Your local audio tags match official online records. You can review the online match, re-embed high-resolution artwork, or rescan.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(appTheme.secondaryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func applyOnlineTags(_ diff: MetadataDiff) {
        Task {
            _ = await libraryStore.applyOnlineMetadata(
                trackID: diff.localTrack.id,
                onlineMetadata: diff.onlineMetadata,
                preserveLocalTitleAndArtist: true
            )
            HapticFeedback.notificationSuccess()
        }
    }

    private func rescanSingleTrack(_ track: Track) {
        recheckingTrackID = track.id
        Task {
            _ = await libraryStore.recheckVerifiedGoodTrack(track)
            recheckingTrackID = nil
            HapticFeedback.notificationSuccess()
        }
    }
}

/// Side-by-side card displaying local track vs verified online match with confirm badge.
private struct VerifiedGoodTrackCard: View {
    let diff: MetadataDiff
    let isRechecking: Bool
    let onApplyOnline: () -> Void
    let onRescan: () -> Void

    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(diff.localTrack.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Spacer()

                Text("MATCH CONFIRMED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.4))

            // Side-by-Side Content
            HStack(alignment: .top, spacing: 10) {
                // Left: Local Track
                VStack(alignment: .leading, spacing: 6) {
                    Text("LOCAL TRACK")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // Local Artwork
                    VStack(alignment: .leading, spacing: 4) {
                        AlbumArtworkView(
                            artworkKey: diff.localTrack.artworkKey,
                            title: diff.localTrack.album,
                            subtitle: diff.localTrack.artist,
                            cornerRadius: 6
                        )
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Text(diff.localTrack.artworkKey != nil ? "LOCAL ARTWORK" : "NO ARTWORK")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        metaItem(label: "TITLE", value: diff.localTrack.title)
                        metaItem(label: "ARTIST", value: diff.localTrack.artist)
                        metaItem(label: "ALBUM", value: diff.localTrack.album)

                        if let y = diff.localTrack.year, y > 0 {
                            metaItem(label: "YEAR", value: String(y))
                        } else {
                            metaItem(label: "YEAR", value: "MISSING", isMissing: true)
                        }

                        if let g = diff.localTrack.genre, !g.isEmpty && g != "Unknown Genre" && g != "—" {
                            metaItem(label: "GENRE", value: g)
                        }

                        if let t = diff.localTrack.trackNumber, t > 0 {
                            let totalStr = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                            metaItem(label: "TRACK #", value: "\(t)\(totalStr)")
                        } else {
                            metaItem(label: "TRACK #", value: "—", isMissing: true)
                        }
                    }
                    .padding(6)
                    .background(appTheme.backgroundColor.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: Online Match
                VStack(alignment: .leading, spacing: 6) {
                    Text("ONLINE VERIFIED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)

                    // Online Artwork
                    VStack(alignment: .leading, spacing: 4) {
                        AsyncImage(url: diff.onlineMetadata.artworkURL) { phase in
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
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        HStack(spacing: 4) {
                            Text(diff.onlineMetadata.artworkURL != nil ? "HIGH-RES (1400x1400)" : "NO ONLINE ART")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)

                            Text("→ MATCH")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.green)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        onlineMetaItem(label: "TITLE", value: diff.localTrack.title, arrowBadge: "→ KEEP LOCAL", isTransferred: true)
                        onlineMetaItem(label: "ARTIST", value: diff.localTrack.artist, arrowBadge: "→ KEEP LOCAL", isTransferred: true)
                        onlineMetaItem(label: "ALBUM", value: diff.effectiveOnlineAlbum, arrowBadge: "→ MATCH")

                        // Year
                        if let y = diff.onlineMetadata.releaseYear, y > 0 {
                            let isEnriched = diff.localTrack.year == nil || diff.localTrack.year == 0
                            onlineMetaItem(label: "YEAR", value: String(y), arrowBadge: isEnriched ? "→ ENRICH" : "→ MATCH")
                        } else if diff.isYearTransferredFromLocal, let localY = diff.localTrack.year {
                            onlineMetaItem(label: "YEAR", value: String(localY), arrowBadge: "→ KEEP LOCAL", isTransferred: true)
                        } else {
                            onlineMetaItem(label: "YEAR", value: "—")
                        }

                        // Genre
                        if let localG = diff.localTrack.genre, !localG.isEmpty && localG != "Unknown Genre" && localG != "—" {
                            onlineMetaItem(label: "GENRE", value: localG, arrowBadge: "→ KEEP LOCAL", isTransferred: true)
                        }

                        // Track Number
                        if let t = diff.onlineMetadata.trackNumber, t > 0 {
                            let totalStr = diff.onlineMetadata.totalTracks.map { " of \($0)" } ?? ""
                            onlineMetaItem(label: "TRACK #", value: "\(t)\(totalStr)", arrowBadge: "→ MATCH")
                        } else if diff.isTrackNumberTransferredFromLocal, let localT = diff.localTrack.trackNumber {
                            let totalStr = diff.localTrack.totalTracks.map { " of \($0)" } ?? ""
                            onlineMetaItem(label: "TRACK #", value: "\(localT)\(totalStr)", arrowBadge: "→ KEEP LOCAL", isTransferred: true)
                        } else {
                            onlineMetaItem(label: "TRACK #", value: "—")
                        }
                    }
                    .padding(6)
                    .background(appTheme.backgroundColor.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Action Buttons
            HStack(spacing: 8) {
                Button(action: onApplyOnline) {
                    Text("RE-APPLY TAGS & ART")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))

                Button(action: onRescan) {
                    Text(isRechecking ? "RESCANNING..." : "RESCAN")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .secondary, size: .small))
                .disabled(isRechecking)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(appTheme.secondaryBackgroundColor.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(appTheme.separatorColor, lineWidth: 1)
        )
    }

    private func metaItem(label: String, value: String, isMissing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: isMissing ? .regular : .bold, design: .monospaced))
                .foregroundStyle(isMissing ? .secondary : Color.primary)
                .lineLimit(1)
        }
    }

    private func onlineMetaItem(
        label: String,
        value: String,
        arrowBadge: String? = nil,
        isTransferred: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let badge = arrowBadge {
                    Text(badge)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(isTransferred ? Color.secondary : Color.green)
                }
            }

            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
    }
}
