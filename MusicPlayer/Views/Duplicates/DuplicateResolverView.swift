import SwiftUI

/// Comprehensive duplicate manager and cleaner view allowing side-by-side comparison of audio tracks,
/// technical spec evaluation, preferred primary selection, and safe disk file deletion with transparent progress.
public struct DuplicateResolverView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var trackToDelete: Track? = nil
    @State private var showingDeleteAllAlert: Bool = false
    @State private var isProcessingDeletion: Bool = false
    @State private var deletionStatusBanner: String? = nil
    @State private var deletionErrorAlertMessage: String? = nil

    // Initialize with configured properties
    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            Group {
                if libraryStore.duplicateGroups.isEmpty && !isProcessingDeletion {
                    EmptyDuplicatesStateView(statusBanner: deletionStatusBanner)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 20) {
                            // Transparent Deletion Status Banner
                            if let banner = deletionStatusBanner {
                                DeletionFeedbackBanner(message: banner) {
                                    withAnimation { deletionStatusBanner = nil }
                                }
                            }

                            // Processing Spinner
                            if isProcessingDeletion {
                                DeletionProcessingBanner()
                            }

                            // Summary & Global Action Header
                            DuplicateSummaryHeaderView(
                                groupsCount: libraryStore.duplicateGroups.count,
                                redundantCount: libraryStore.totalDuplicateTracksCount,
                                savingsBytes: libraryStore.totalDuplicateSavingsBytes,
                                isDeleting: isProcessingDeletion,
                                onAutoResolve: {
                                    HapticFeedback.notificationSuccess()
                                    libraryStore.autoResolveAllDuplicates()
                                },
                                onDeleteAll: {
                                    showingDeleteAllAlert = true
                                }
                            )

                            // Duplicate Clusters List
                            ForEach(libraryStore.duplicateGroups) { group in
                                DuplicateClusterCardView(
                                    group: group,
                                    isDeleting: isProcessingDeletion,
                                    onSelectPrimary: { candidateID in
                                        HapticFeedback.selectionChanged()
                                        libraryStore.resolveDuplicate(groupID: group.id, selectedPrimaryTrackID: candidateID)
                                    },
                                    onDeleteTrack: { track in
                                        trackToDelete = track
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("DUPLICATE MANAGER")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .alert("DELETE ALL DUPLICATES FROM DISK?", isPresented: $showingDeleteAllAlert) {
                Button("CANCEL", role: .cancel) {}
                Button("DELETE FILES", role: .destructive) {
                    deleteAllSecondaryDuplicates()
                }
            } message: {
                // Bytes
                let bytes = libraryStore.totalDuplicateSavingsBytes
                // Count
                let count = libraryStore.totalDuplicateTracksCount
                Text("This will permanently move \(count) redundant audio files (\(ByteFormatting.formatFileSize(bytes: bytes))) to Trash. Your selected primary versions will be safely retained in your library.")
            }
            .alert("DELETE FILE FROM DISK?", isPresented: Binding(
                get: { trackToDelete != nil },
                set: { if !$0 { trackToDelete = nil } }
            )) {
                Button("CANCEL", role: .cancel) { trackToDelete = nil }
                Button("DELETE FILE", role: .destructive) {
                    if let track = trackToDelete {
                        deleteSingleTrack(track)
                    }
                }
            } message: {
                if let track = trackToDelete {
                    Text("Permanently move '\(track.url.lastPathComponent)' (\(ByteFormatting.formatFileSize(bytes: track.fileInfo?.fileSizeBytes ?? 0))) to Trash?")
                }
            }
            .alert("DELETION RESULT", isPresented: Binding(
                get: { deletionErrorAlertMessage != nil },
                set: { if !$0 { deletionErrorAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { deletionErrorAlertMessage = nil }
            } message: {
                if let msg = deletionErrorAlertMessage {
                    Text(msg)
                }
            }
        }
    }

    // MARK: - Deletion Handlers

    // Delete all secondary duplicates
    private func deleteAllSecondaryDuplicates() {
        // Tracks to delete
        let tracksToDelete = libraryStore.duplicateGroups.flatMap { $0.duplicateCandidates.map { $0.track } }
        // Ensure preconditions are met before proceeding
        guard !tracksToDelete.isEmpty else { return }

        isProcessingDeletion = true
        deletionStatusBanner = nil

        Task {
            // Res
            let res = await libraryStore.deleteDuplicateTracks(tracksToDelete: tracksToDelete)
            await libraryStore.recalculateDuplicates()

            isProcessingDeletion = false
            HapticFeedback.notificationSuccess()

            // Remaining groups
            let remainingGroups = libraryStore.duplicateGroups.count
            // Remaining tracks
            let remainingTracks = libraryStore.totalDuplicateTracksCount

            if res.failedCount > 0 {
                deletionErrorAlertMessage = "Removed \(res.successCount) files. \(res.failedCount) files could not be deleted (check file permissions)."
            }

            if remainingGroups == 0 {
                deletionStatusBanner = "DELETION COMPLETE • REMOVED \(res.successCount) REDUNDANT FILES • 0 DUPLICATES REMAINING"
            } else {
                deletionStatusBanner = "REMOVED \(res.successCount) FILES • \(remainingGroups) GROUPS (\(remainingTracks) FILES) REMAINING"
            }
        }
    }

    // Delete single track
    private func deleteSingleTrack(_ track: Track) {
        trackToDelete = nil
        isProcessingDeletion = true
        deletionStatusBanner = nil

        Task {
            // Success
            let success = await libraryStore.deleteSingleTrackFile(track: track)
            await libraryStore.recalculateDuplicates()

            isProcessingDeletion = false
            HapticFeedback.notificationSuccess()

            // Remaining groups
            let remainingGroups = libraryStore.duplicateGroups.count
            if success {
                if remainingGroups == 0 {
                    deletionStatusBanner = "DELETED '\(track.title)' • 0 DUPLICATES REMAINING"
                } else {
                    deletionStatusBanner = "DELETED '\(track.title)' • \(remainingGroups) DUPLICATE GROUPS REMAINING"
                }
            } else {
                deletionErrorAlertMessage = "Failed to remove file '\(track.url.lastPathComponent)'. Check system file permissions."
            }
        }
    }
}

// MARK: - Dedicated Subviews

/// Interactive deletion status message banner.
private struct DeletionFeedbackBanner: View {
    // Message
    let message: String
    // On dismiss
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(message)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)

            Spacer()

            Button("DISMISS") {
                onDismiss()
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(appTheme.accentColor)
        }
        .padding(12)
        .background(appTheme.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(appTheme.accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Active progress indicator while trashing duplicate files.
private struct DeletionProcessingBanner: View {
    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.primary)

            Text("MOVING REDUNDANT FILES TO TRASH...")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(12)
        .background(appTheme.secondaryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Summary and global actions card at top of Duplicate Manager.
private struct DuplicateSummaryHeaderView: View {
    // Groups count
    let groupsCount: Int
    // Redundant count
    let redundantCount: Int
    // Savings bytes
    let savingsBytes: Int64
    // Flag indicating if deleting
    let isDeleting: Bool
    // On auto resolve
    let onAutoResolve: () -> Void
    // On delete all
    let onDeleteAll: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DUPLICATE CLUSTERS DETECTED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("\(groupsCount) GROUPS • \(redundantCount) REDUNDANT FILES")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("RECOVERABLE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(ByteFormatting.formatFileSize(bytes: savingsBytes))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                }
            }

            Divider()
                .overlay(appTheme.separatorColor)

            HStack(spacing: 10) {
                Button(action: onAutoResolve) {
                    Text("AUTO-RESOLVE BEST")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
                .disabled(isDeleting)

                Button(action: onDeleteAll) {
                    Text("DELETE ALL DUPLICATES")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TypographicButtonStyle(variant: .destructive, size: .small))
                .disabled(isDeleting || redundantCount == 0)
            }
        }
        .padding(14)
        .background(appTheme.secondaryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Duplicate cluster card containing horizontally scrollable side-by-side candidates with artwork and full metadata.
private struct DuplicateClusterCardView: View {
    // Group
    let group: DuplicateGroup
    // Flag indicating if deleting
    let isDeleting: Bool
    // On select primary
    let onSelectPrimary: (UUID) -> Void
    // On delete track
    let onDeleteTrack: (Track) -> Void

    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(group.displayArtist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if group.potentialSavedBytes > 0 {
                    Text("+\(ByteFormatting.formatFileSize(bytes: group.potentialSavedBytes)) RECOVERABLE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(appTheme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(appTheme.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            Divider()
                .overlay(appTheme.separatorColor.opacity(0.5))

            // Side-by-Side Candidates Comparison
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.candidates) { candidate in
                        CandidateComparisonCard(
                            candidate: candidate,
                            isPrimary: candidate.track.id == group.selectedPrimaryTrackID,
                            isDeleting: isDeleting,
                            onSelect: {
                                onSelectPrimary(candidate.track.id)
                            },
                            onDelete: {
                                onDeleteTrack(candidate.track)
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .background(appTheme.secondaryBackgroundColor.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(appTheme.separatorColor, lineWidth: 1)
        )
    }
}

/// An individual candidate card displaying centered album cover at top, followed by centered metadata and actions.
private struct CandidateComparisonCard: View {
    // Candidate
    let candidate: DuplicateCandidate
    // Flag indicating if primary
    let isPrimary: Bool
    // Flag indicating if deleting
    let isDeleting: Bool
    // On select
    let onSelect: () -> Void
    // On delete
    let onDelete: () -> Void

    @Environment(\.appTheme) private var appTheme

    // Body
    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            // Centered Album Artwork at top
            VStack(spacing: 6) {
                AlbumArtworkView(
                    artworkKey: candidate.track.artworkKey,
                    title: candidate.track.album,
                    subtitle: candidate.track.artist,
                    cornerRadius: 8
                )
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Sub-Artwork Status Label
                if isPrimary {
                    Text("KEEPING THIS VERSION")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                } else {
                    Text("REDUNDANT DUPLICATE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }
            }

            // Centered Metadata & Quality Summary
            VStack(alignment: .center, spacing: 5) {
                centeredRow(label: "TITLE", value: candidate.track.title)
                centeredRow(label: "ARTIST", value: candidate.track.artist)
                centeredRow(label: "ALBUM", value: candidate.track.album.isEmpty ? "—" : candidate.track.album)
                centeredRow(label: "FORMAT", value: candidate.formatBadge)
                centeredRow(label: "SAMPLE RATE", value: candidate.sampleRateString)

                if let size = candidate.track.fileInfo?.fileSizeBytes {
                    centeredRow(label: "SIZE", value: ByteFormatting.formatFileSize(bytes: size))
                }
            }
            .frame(width: 170)

            // Centered Selection & Deletion Actions
            VStack(spacing: 8) {
                if isPrimary {
                    Text("PRIMARY SELECTION")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                        .padding(.vertical, 4)
                } else {
                    Button(action: onSelect) {
                        Text("SELECT AS PRIMARY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)

                    Button(action: onDelete) {
                        Text("DELETE FROM DISK")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
    }

    private func centeredRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isPrimary ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
    }
}

/// Empty state when no duplicate files exist or after full deletion.
private struct EmptyDuplicatesStateView: View {
    // Status banner
    let statusBanner: String?

    // Body
    var body: some View {
        VStack(spacing: 16) {
            if let banner = statusBanner {
                Text(banner)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Text("NO DUPLICATES DETECTED")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)

            Text("All audio files in your linked directory are unique. The library is fully deduplicated and optimized.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
