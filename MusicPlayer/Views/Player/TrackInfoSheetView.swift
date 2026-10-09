import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Clean, transparent technical audio file inspector sheet displaying container, codec, stream, tag metadata, and file system specifications.
public struct TrackInfoSheetView: View {
    // Track
    public let track: Track
    // Injected library store dependency
    public var libraryStore: LibraryStore?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @State private var currentTrack: Track
    @State private var copiedPathToast: Bool = false
    @State private var showingOnlineMetadataSheet: Bool = false

    // Manual Tag Editing State
    @State private var isEditingTags: Bool = false
    @State private var isSavingTags: Bool = false
    @State private var showingSaveErrorAlert: Bool = false
    @State private var saveErrorMessage: String = ""
    @State private var showingRemoveConfirmation: Bool = false
    @State private var showingDeleteConfirmation: Bool = false
    @State private var isProcessingAction: Bool = false

    // 12 editable tag properties (even if empty)
    @State private var editTitle: String = ""
    @State private var editArtist: String = ""
    @State private var editAlbum: String = ""
    @State private var editAlbumArtist: String = ""
    @State private var editComposer: String = ""
    @State private var editPerformer: String = ""
    @State private var editGenre: String = ""
    @State private var editDiscNumber: String = ""
    @State private var editDiscTotal: String = ""
    @State private var editTrackNumber: String = ""
    @State private var editTrackTotal: String = ""
    @State private var editYear: String = ""

    // Initialize with configured properties
    public init(track: Track, libraryStore: LibraryStore? = nil) {
        self.track = track
        self.libraryStore = libraryStore
        self._currentTrack = State(initialValue: track)
    }

    // Main view layout structure
    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // MARK: - 1. Track Identity Section
                    tagMetadataSection

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.4))

                    // MARK: - 2. Technical Audio Stream Section
                    audioSpecsSection

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.4))

                    // MARK: - 3. File System & Storage Section
                    storageSection

                    // MARK: - 4. Lyrics (If present)
                    if let lyrics = track.lyrics, !lyrics.isEmpty {
                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        lyricsSection(lyrics: lyrics)
                    }

                    // MARK: - 5. Track Library Removal & Disk Deletion
                    if libraryStore != nil {
                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        trackActionsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .padding(.bottom, 40)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("FILE INFO")
            .navigationBarTitleDisplayMode(.inline)
            // Modal presentation sheet
            .sheet(isPresented: $showingOnlineMetadataSheet) {
                if let libraryStore = libraryStore {
                    OnlineMetadataMatchSheet(track: currentTrack, libraryStore: libraryStore)
                        .tint(libraryStore.settings.appTheme.accentColor)
                        .environment(\.appTheme, libraryStore.settings.appTheme)
                }
            }
            .alert(saveErrorMessage, isPresented: $showingSaveErrorAlert) {
                Button("OK", role: .cancel) {}
            }
            .alert(
                currentTrack.isJellyfinItem || currentTrack.metadataSource == .server ? "HIDE TRACK?" : "REMOVE FROM LIBRARY?",
                isPresented: $showingRemoveConfirmation
            ) {
                Button("CANCEL", role: .cancel) {}
                Button("HIDE", role: .destructive) {
                    performRemoveFromLibrary()
                }
            } message: {
                Text("This track will be hidden from your library and will not appear in the app. The audio file itself will remain intact.")
            }
            .alert(
                currentTrack.isJellyfinItem || currentTrack.metadataSource == .server ? "DELETE FROM JELLYFIN?" : "DELETE TRACK PERMANENTLY?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("CANCEL", role: .cancel) {}
                Button("DELETE", role: .destructive) {
                    performDeleteTrack()
                }
            } message: {
                if currentTrack.isJellyfinItem || currentTrack.metadataSource == .server {
                    Text("Are you sure you want to permanently delete \"\(currentTrack.title)\" from your Jellyfin server? This will delete the file on the server.")
                } else {
                    Text("Are you sure you want to permanently delete \"\(currentTrack.title)\" from your device? This will delete the audio file itself and cannot be undone.")
                }
            }
        }
    }

    // MARK: - Tag Metadata Section

    private var tagMetadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isEditingTags ? "EDIT TAG METADATA" : "TAG METADATA")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)

                Spacer()

                if libraryStore != nil {
                    if isEditingTags {
                        Button("CANCEL") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isEditingTags = false
                            }
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)

                        Button(isSavingTags ? "SAVING..." : "SAVE") {
                            Task {
                                await saveTags()
                            }
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                        .buttonStyle(.plain)
                        .disabled(isSavingTags)
                    } else {
                        HStack(spacing: 12) {
                            if let store = libraryStore, store.hasOverride(for: currentTrack.id) {
                                Button("RESET EDITS") {
                                    store.resetEdits(for: currentTrack.id)
                                    if let updated = store.tracks.first(where: { $0.id == currentTrack.id }) {
                                        currentTrack = updated
                                    }
                                    HapticFeedback.notificationSuccess()
                                }
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.red)
                                .buttonStyle(.plain)
                            }

                            Button("EDIT") {
                                populateEditFields()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isEditingTags = true
                                }
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if isEditingTags {
                VStack(spacing: 10) {
                    editFieldRow(label: "TRACK TITLE", text: $editTitle)
                    editFieldRow(label: "ARTIST", text: $editArtist)
                    editFieldRow(label: "ALBUM", text: $editAlbum)
                    editFieldRow(label: "ALBUM ARTIST", text: $editAlbumArtist)
                    editFieldRow(label: "COMPOSER", text: $editComposer)
                    editFieldRow(label: "PERFORMER", text: $editPerformer)
                    editFieldRow(label: "GENRE", text: $editGenre)

                    HStack(spacing: 12) {
                        editFieldRow(label: "DISC NUMBER", text: $editDiscNumber)
                        editFieldRow(label: "DISC TOTAL", text: $editDiscTotal)
                    }

                    HStack(spacing: 12) {
                        editFieldRow(label: "TRACK NUMBER", text: $editTrackNumber)
                        editFieldRow(label: "TRACK TOTAL", text: $editTrackTotal)
                    }

                    editFieldRow(label: "YEAR", text: $editYear)
                }
            } else {
                VStack(spacing: 8) {
                    infoRow(label: "TITLE", value: currentTrack.title)
                    infoRow(label: "ARTIST", value: currentTrack.artist)
                    infoRow(label: "ALBUM", value: currentTrack.album)

                    if let year = currentTrack.year, year > 0 {
                        infoRow(label: "RELEASE DATE", value: String(year))
                    }

                    if let albumArtist = currentTrack.albumArtist, !albumArtist.isEmpty {
                        infoRow(label: "ALBUM ARTIST", value: albumArtist)
                    }

                    if let composer = currentTrack.composer, !composer.isEmpty {
                        infoRow(label: "COMPOSER", value: composer)
                    }

                    if let performer = currentTrack.performer, !performer.isEmpty {
                        infoRow(label: "PERFORMER", value: performer)
                    }

                    if let genre = currentTrack.genre, !genre.isEmpty {
                        infoRow(label: "GENRE", value: genre)
                    }

                    if let disc = currentTrack.discNumber, disc > 0 {
                        if let total = currentTrack.discTotal, total > 0 {
                            infoRow(label: "DISC NUMBER", value: "\(disc) of \(total)")
                        } else {
                            infoRow(label: "DISC NUMBER", value: String(disc))
                        }
                    }

                    if let trackNum = currentTrack.trackNumber, trackNum > 0 {
                        if let total = currentTrack.totalTracks, total > 0 {
                            infoRow(label: "TRACK NUMBER", value: "\(trackNum) of \(total)")
                        } else {
                            infoRow(label: "TRACK NUMBER", value: String(trackNum))
                        }
                    }

                    infoRow(label: "ARTWORK", value: currentTrack.artworkKey != nil ? "EMBEDDED (CACHED)" : "NONE / DEFAULT")
                }

                if libraryStore != nil {
                    Button(action: { showingOnlineMetadataSheet = true }) {
                        HStack {
                            Text("FETCH ONLINE METADATA")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                            Spacer()
                            Text("→")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(appTheme.accentColor)
                        }
                        .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Audio Specs Section

    private var audioSpecsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO SPECIFICATIONS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            VStack(spacing: 8) {
                if let info = currentTrack.fileInfo {
                    infoRow(label: "CODEC / FORMAT", value: info.formatDescription)
                    infoRow(label: "CONTAINER", value: ".\(info.fileExtension)")
                    infoRow(label: "SAMPLE RATE", value: ByteFormatting.formatSampleRate(hz: info.sampleRate))
                    infoRow(label: "CHANNELS", value: info.channelDescription)
                    infoRow(label: "BITRATE", value: ByteFormatting.formatBitrate(bps: info.bitRate))
                    infoRow(label: "EXACT DURATION", value: String(format: "%.3f sec (%@)", info.durationSeconds, TimeFormatting.format(seconds: info.durationSeconds)))
                } else {
                    infoRow(label: "DURATION", value: TimeFormatting.format(seconds: currentTrack.duration))
                    infoRow(label: "FORMAT", value: currentTrack.url.pathExtension.uppercased())
                }
            }
        }
    }

    // MARK: - Storage & File Section

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STORAGE & FILE SYSTEM")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            VStack(spacing: 8) {
                if let info = currentTrack.fileInfo {
                    infoRow(label: "FILE SIZE", value: "\(ByteFormatting.formatFileSize(bytes: info.fileSizeBytes)) (\(info.fileSizeBytes.formatted()) bytes)")
                    infoRow(label: "FILE NAME", value: info.fileName)
                } else {
                    infoRow(label: "FILE NAME", value: currentTrack.url.lastPathComponent)
                }

                if currentTrack.isCloudItem {
                    infoRow(label: "STORAGE TYPE", value: currentTrack.isCloudDownloaded ? "ICLOUD (DOWNLOADED)" : "ICLOUD (ON-DEMAND)")
                } else if currentTrack.isJellyfinItem {
                    infoRow(label: "STORAGE TYPE", value: "JELLYFIN REMOTE")
                } else {
                    infoRow(label: "STORAGE TYPE", value: "LOCAL STORAGE")
                }

                if let relPath = currentTrack.relativePath {
                    infoRow(label: "RELATIVE PATH", value: relPath)
                }

                if let info = currentTrack.fileInfo {
                    if let created = info.creationDate {
                        infoRow(label: "CREATED", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let modified = info.modificationDate {
                        infoRow(label: "MODIFIED", value: modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("FILE PATH")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(currentTrack.url.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)

                Button(action: copyFilePath) {
                    HStack(spacing: 6) {
                        Image(systemName: copiedPathToast ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                        Text(copiedPathToast ? "COPIED TO CLIPBOARD" : "COPY PATH")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(copiedPathToast ? Color.green : appTheme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Lyrics Section

    private func lyricsSection(lyrics: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LYRICS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            Text(lyrics)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helper Views & Functions

    private func editFieldRow(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func populateEditFields() {
        editTitle = currentTrack.title
        editArtist = currentTrack.artist
        editAlbum = currentTrack.album
        editAlbumArtist = currentTrack.albumArtist ?? ""
        editComposer = currentTrack.composer ?? ""
        editPerformer = currentTrack.performer ?? ""
        editGenre = currentTrack.genre ?? ""
        editDiscNumber = currentTrack.discNumber.map { String($0) } ?? ""
        editDiscTotal = currentTrack.discTotal.map { String($0) } ?? ""
        editTrackNumber = currentTrack.trackNumber.map { String($0) } ?? ""
        editTrackTotal = currentTrack.totalTracks.map { String($0) } ?? ""
        editYear = currentTrack.year.map { String($0) } ?? ""
    }

    private func saveTags() async {
        guard let libraryStore = libraryStore else { return }
        isSavingTags = true

        let trackNum = Int(editTrackNumber.trimmingCharacters(in: .whitespacesAndNewlines))
        let trackTot = Int(editTrackTotal.trimmingCharacters(in: .whitespacesAndNewlines))
        let discNum = Int(editDiscNumber.trimmingCharacters(in: .whitespacesAndNewlines))
        let discTot = Int(editDiscTotal.trimmingCharacters(in: .whitespacesAndNewlines))
        let yearNum = Int(editYear.trimmingCharacters(in: .whitespacesAndNewlines))

        let newTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist = editArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAlbum = editAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAlbumArtist = editAlbumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let newComposer = editComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPerformer = editPerformer.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGenre = editGenre.trimmingCharacters(in: .whitespacesAndNewlines)

        let success = await libraryStore.updateTrackMetadata(
            for: currentTrack.id,
            title: newTitle.isEmpty ? currentTrack.title : newTitle,
            artist: newArtist.isEmpty ? currentTrack.artist : newArtist,
            album: newAlbum.isEmpty ? currentTrack.album : newAlbum,
            albumArtist: newAlbumArtist.isEmpty ? nil : newAlbumArtist,
            composer: newComposer.isEmpty ? nil : newComposer,
            performer: newPerformer.isEmpty ? nil : newPerformer,
            genre: newGenre.isEmpty ? nil : newGenre,
            year: yearNum,
            trackNumber: trackNum,
            totalTracks: trackTot,
            discNumber: discNum,
            discTotal: discTot
        )

        isSavingTags = false
        if success {
            if let updated = libraryStore.tracks.first(where: { $0.id == currentTrack.id }) {
                self.currentTrack = updated
            }
            HapticFeedback.notificationSuccess()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isEditingTags = false
            }
        } else {
            HapticFeedback.notificationError()
            saveErrorMessage = "COULD NOT WRITE METADATA TO AUDIO FILE ON DISK."
            showingSaveErrorAlert = true
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 1)
    }

    private func copyFilePath() {
        #if canImport(UIKit)
        UIPasteboard.general.string = currentTrack.url.path
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentTrack.url.path, forType: .string)
        #endif
        copiedPathToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedPathToast = false
        }
    }

    // MARK: - Remove & Delete Track Actions

    private var trackActionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: {
                showingRemoveConfirmation = true
            }) {
                Text(currentTrack.isJellyfinItem || currentTrack.metadataSource == .server ? "HIDE TRACK" : "REMOVE FROM LIBRARY")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
            .disabled(isProcessingAction)

            Button(action: {
                showingDeleteConfirmation = true
            }) {
                Text("DELETE TRACK")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
            .disabled(isProcessingAction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func performRemoveFromLibrary() {
        guard let libraryStore = libraryStore else { return }
        isProcessingAction = true
        HapticFeedback.notificationSuccess()
        if let player = AudioPlayerService.shared, player.currentTrack?.id == currentTrack.id {
            player.next()
        }
        libraryStore.hideTrack(currentTrack)
        dismiss()
    }

    private func performDeleteTrack() {
        guard let libraryStore = libraryStore else { return }
        isProcessingAction = true
        HapticFeedback.notificationSuccess()
        Task {
            if let player = AudioPlayerService.shared, player.currentTrack?.id == currentTrack.id {
                player.next()
            }
            if currentTrack.isJellyfinItem || currentTrack.metadataSource == .server {
                do {
                    try await libraryStore.deleteJellyfinTrack(currentTrack)
                } catch {
                    AppLogger.library.error("Failed to delete Jellyfin track: \(error.localizedDescription)")
                }
            } else {
                _ = await libraryStore.deleteSingleTrackFile(track: currentTrack)
            }
            await MainActor.run {
                dismiss()
            }
        }
    }
}
