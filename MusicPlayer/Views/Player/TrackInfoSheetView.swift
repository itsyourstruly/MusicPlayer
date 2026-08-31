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
    @State private var copiedPathToast: Bool = false
    @State private var showingOnlineMetadataSheet: Bool = false
    @State private var dynamicTags: [(key: String, value: String)] = []

    // Initialize with configured properties
    public init(track: Track, libraryStore: LibraryStore? = nil) {
        self.track = track
        self.libraryStore = libraryStore
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

                    // MARK: - 5. Extended Embedded File Tags (If present)
                    if !dynamicTags.isEmpty {
                        Divider()
                            .overlay(appTheme.separatorColor.opacity(0.4))

                        embeddedTagsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .padding(.bottom, 40)
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("FILE INFO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                }
            }
            // Modal presentation sheet
            .sheet(isPresented: $showingOnlineMetadataSheet) {
                if let libraryStore = libraryStore {
                    OnlineMetadataMatchSheet(track: track, libraryStore: libraryStore)
                        .tint(libraryStore.settings.appTheme.accentColor)
                        .environment(\.appTheme, libraryStore.settings.appTheme)
                }
            }
            // Async lifecycle task
            .task {
                await loadDynamicTags()
            }
        }
    }

    // MARK: - Tag Metadata Section

    private var tagMetadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TAG METADATA")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            VStack(spacing: 8) {
                infoRow(label: "TITLE", value: track.title)
                infoRow(label: "ARTIST", value: track.artist)
                infoRow(label: "ALBUM", value: track.album)

                if let year = track.year, year > 0 {
                    infoRow(label: "RELEASE DATE", value: String(year))
                }

                if let albumArtist = track.albumArtist, !albumArtist.isEmpty {
                    infoRow(label: "ALBUM ARTIST", value: albumArtist)
                }

                if let genre = track.genre, !genre.isEmpty {
                    infoRow(label: "GENRE", value: genre)
                }

                if let trackNum = track.trackNumber, trackNum > 0 {
                    if let total = track.totalTracks, total > 0 {
                        infoRow(label: "TRACK NUMBER", value: "\(trackNum) of \(total)")
                    } else {
                        infoRow(label: "TRACK NUMBER", value: String(trackNum))
                    }
                }

                if let disc = track.discNumber, disc > 0 {
                    infoRow(label: "DISC NUMBER", value: String(disc))
                }

                infoRow(label: "ARTWORK", value: track.artworkKey != nil ? "EMBEDDED (CACHED)" : "NONE / DEFAULT")
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

    // MARK: - Audio Specs Section

    private var audioSpecsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO SPECIFICATIONS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            VStack(spacing: 8) {
                if let info = track.fileInfo {
                    infoRow(label: "CODEC / FORMAT", value: info.formatDescription)
                    infoRow(label: "CONTAINER", value: ".\(info.fileExtension)")
                    infoRow(label: "SAMPLE RATE", value: ByteFormatting.formatSampleRate(hz: info.sampleRate))
                    infoRow(label: "CHANNELS", value: info.channelDescription)
                    infoRow(label: "BITRATE", value: ByteFormatting.formatBitrate(bps: info.bitRate))
                    infoRow(label: "EXACT DURATION", value: String(format: "%.3f sec (%@)", info.durationSeconds, TimeFormatting.format(seconds: info.durationSeconds)))
                } else {
                    infoRow(label: "DURATION", value: TimeFormatting.format(seconds: track.duration))
                    infoRow(label: "FORMAT", value: track.url.pathExtension.uppercased())
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
                if let info = track.fileInfo {
                    infoRow(label: "FILE SIZE", value: "\(ByteFormatting.formatFileSize(bytes: info.fileSizeBytes)) (\(info.fileSizeBytes.formatted()) bytes)")
                    infoRow(label: "FILE NAME", value: info.fileName)
                } else {
                    infoRow(label: "FILE NAME", value: track.url.lastPathComponent)
                }

                if let info = track.fileInfo {
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

                Text(track.url.path)
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

    // MARK: - Embedded Tags Section

    private var embeddedTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EMBEDDED FILE TAGS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(appTheme.accentColor)

            VStack(spacing: 8) {
                ForEach(dynamicTags, id: \.key) { tag in
                    infoRow(label: tag.key, value: tag.value)
                }
            }
        }
    }

    // MARK: - Helper Views & Functions

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

    private func loadDynamicTags() async {
        let asset = AVURLAsset(url: track.url)
        guard let metadata = try? await asset.load(.metadata) else { return }

        var list: [(key: String, value: String)] = []
        for item in metadata {
            let rawKey = item.commonKey?.rawValue ?? item.keyString ?? (item.key as? String) ?? (item.key as? NSNumber)?.stringValue ?? ""
            guard !rawKey.isEmpty else { continue }

            let cleanKey = rawKey.replacingOccurrences(of: "com.apple.quicktime.", with: "")
                .replacingOccurrences(of: "org.id3.", with: "")
                .replacingOccurrences(of: "©", with: "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            let upper = cleanKey.uppercased()
            if ["TITLE", "ARTIST", "ALBUM", "GENRE", "CREATIONDATE", "DATE", "YEAR", "ARTWORK"].contains(upper) {
                continue
            }

            if let val = try? await item.load(.stringValue) {
                let trimmedVal = val.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !trimmedVal.isEmpty && !list.contains(where: { $0.key == upper }) {
                    list.append((key: upper, value: trimmedVal))
                }
            }
        }

        self.dynamicTags = list.sorted { $0.key < $1.key }
    }

    private func copyFilePath() {
        #if canImport(UIKit)
        UIPasteboard.general.string = track.url.path
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(track.url.path, forType: .string)
        #endif
        copiedPathToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedPathToast = false
        }
    }
}
