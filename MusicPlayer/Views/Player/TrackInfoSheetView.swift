import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Comprehensive technical audio file inspector sheet displaying container, codec, stream, tag metadata, and file system specifications.
public struct TrackInfoSheetView: View {
    // Track
    public let track: Track
    // Injected library store dependency
    public var libraryStore: LibraryStore?
    @Environment(\.dismiss) private var dismiss
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
            List {
                // MARK: - Track Identity Section
                Section("TAG METADATA") {
                    infoRow(label: "TITLE", value: track.title)
                    infoRow(label: "ARTIST", value: track.artist)
                    infoRow(label: "ALBUM", value: track.album)

                    // Release year
                    if let year = track.year, year > 0 {
                        infoRow(label: "RELEASE DATE", value: String(year))
                    }

                    // Album-level artist credit for compilations
                    if let albumArtist = track.albumArtist, !albumArtist.isEmpty {
                        infoRow(label: "ALBUM ARTIST", value: albumArtist)
                    }

                    // Musical genre classification
                    if let genre = track.genre, !genre.isEmpty {
                        infoRow(label: "GENRE", value: genre)
                    }

                    if let disc = track.discNumber, disc > 0 {
                        infoRow(label: "DISC NUMBER", value: String(disc))
                    }

                    // Injected library store dependency
                    if let libraryStore = libraryStore {
                        Button(action: { showingOnlineMetadataSheet = true }) {
                            Text("FETCH ONLINE METADATA & ARTWORK")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .primary, size: .small))
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Technical Audio Stream Section
                Section("AUDIO SPECIFICATIONS") {
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

                // MARK: - Extended Embedded File Tags (If present)
                if !dynamicTags.isEmpty {
                    Section("EMBEDDED FILE TAGS") {
                        ForEach(dynamicTags, id: \.key) { tag in
                            infoRow(label: tag.key, value: tag.value)
                        }
                    }
                }

                // MARK: - File System & Storage Section
                Section("STORAGE & FILE SYSTEM") {
                    if let info = track.fileInfo {
                        infoRow(label: "FILE SIZE", value: "\(ByteFormatting.formatFileSize(bytes: info.fileSizeBytes)) (\(info.fileSizeBytes.formatted()) bytes)")
                        infoRow(label: "FILE NAME", value: info.fileName)
                    } else {
                        infoRow(label: "FILE NAME", value: track.url.lastPathComponent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("FILE PATH")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(track.url.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .textSelection(.enabled)
                            .lineLimit(4)

                        Button(action: copyFilePath) {
                            Text(copiedPathToast ? "COPIED TO CLIPBOARD" : "COPY PATH")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .buttonStyle(TypographicButtonStyle(variant: .subtle, size: .mini))
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)

                    if let info = track.fileInfo {
                        if let created = info.creationDate {
                            infoRow(label: "CREATED", value: created.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let modified = info.modificationDate {
                            infoRow(label: "MODIFIED", value: modified.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }

                // MARK: - Embedded Artwork & Extras
                Section("ASSETS & LYRICS") {
                    infoRow(label: "ARTWORK", value: track.artworkKey != nil ? "EMBEDDED (CACHED)" : "NONE / SYSTEM PLACEHOLDER")

                    // Synchronized or plain text lyrics if available
                    if let lyrics = track.lyrics, !lyrics.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LYRICS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text(lyrics)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.primary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("AUDIO FILE INFO")
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
            .sheet(isPresented: $showingOnlineMetadataSheet) {
                // Injected library store dependency
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

    // Load dynamic tags
    private func loadDynamicTags() async {
        // Asset
        let asset = AVURLAsset(url: track.url)
        // Ensure preconditions are met before proceeding
        guard let metadata = try? await asset.load(.metadata) else { return }

        // List
        var list: [(key: String, value: String)] = []
        for item in metadata {
            // Raw key
            let rawKey = item.commonKey?.rawValue ?? item.keyString ?? (item.key as? String) ?? (item.key as? NSNumber)?.stringValue ?? ""
            // Ensure preconditions are met before proceeding
            guard !rawKey.isEmpty else { continue }

            // Skip keys already prominently displayed in primary sections
            let cleanKey = rawKey.replacingOccurrences(of: "com.apple.quicktime.", with: "")
                .replacingOccurrences(of: "org.id3.", with: "")
                .replacingOccurrences(of: "©", with: "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            // Upper
            let upper = cleanKey.uppercased()
            if ["TITLE", "ARTIST", "ALBUM", "GENRE", "CREATIONDATE", "DATE", "YEAR", "ARTWORK"].contains(upper) {
                continue
            }

            if let val = try? await item.load(.stringValue) {
                // Trimmed val
                let trimmedVal = val.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !trimmedVal.isEmpty && !list.contains(where: { $0.key == upper }) {
                    list.append((key: upper, value: trimmedVal))
                }
            }
        }

        self.dynamicTags = list.sorted { $0.key < $1.key }
    }

    // Info row
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }

    // Copy file path
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
