import SwiftUI

/// Lightweight folder tree of a linked local source, built from the library's tracks
/// (via `relativePath`), so it works for iCloud placeholders without touching the file system.
nonisolated struct FolderTreeIndex: Sendable {
    struct Entry: Sendable {
        let path: String
        let trackID: UUID
    }

    /// Track entries sorted by relative path.
    let entries: [Entry]
    /// Folder path ("" = source root) -> sorted child folder names.
    let subfolders: [String: [String]]
    /// Folder path -> number of tracks in that folder and all subfolders.
    let trackCounts: [String: Int]

    static let empty = FolderTreeIndex(entries: [], subfolders: [:], trackCounts: [:])

    static func build(tracks: [Track], folder: LinkedFolder) -> FolderTreeIndex {
        let rootPath = folder.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        var entries: [Entry] = []
        for track in tracks where track.folderID == folder.id && !track.isJellyfinItem {
            var rel = track.relativePath
            if rel == nil, let root = rootPath {
                let trackPath = track.url.standardizedFileURL.path
                if trackPath.hasPrefix(root + "/") {
                    rel = String(trackPath.dropFirst(root.count + 1))
                }
            }
            guard let relPath = rel?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !relPath.isEmpty else { continue }
            entries.append(Entry(path: relPath, trackID: track.id))
        }
        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var childSets: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for entry in entries {
            let folders = entry.path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
            var current = ""
            counts[current, default: 0] += 1
            for component in folders {
                let name = String(component)
                childSets[current, default: []].insert(name)
                current = current.isEmpty ? name : current + "/" + name
                counts[current, default: 0] += 1
            }
        }

        let subfolders = childSets.mapValues { names in
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return FolderTreeIndex(entries: entries, subfolders: subfolders, trackCounts: counts)
    }

    /// Track IDs in `folderPath` and all its subfolders, in path order.
    func trackIDs(under folderPath: String) -> [UUID] {
        if folderPath.isEmpty { return entries.map(\.trackID) }
        let prefix = folderPath + "/"
        return entries.filter { $0.path.hasPrefix(prefix) }.map(\.trackID)
    }
}

/// Sheet that browses a linked folder's tree and turns any folder into a playlist.
struct FolderPlaylistFinderSheet: View {
    var libraryStore: LibraryStore
    let folder: LinkedFolder

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var index: FolderTreeIndex = .empty
    @State private var isLoading: Bool = true

    var body: some View {
        NavigationStack {
            levelView(path: "")
                .navigationDestination(for: String.self) { path in
                    levelView(path: path)
                }
        }
        .task {
            let tracks = libraryStore.tracks
            let folder = self.folder
            let built = await Task.detached(priority: .userInitiated) {
                FolderTreeIndex.build(tracks: tracks, folder: folder)
            }.value
            index = built
            isLoading = false
        }
    }

    // MARK: - Folder Level

    private func levelView(path: String) -> some View {
        let children = index.subfolders[path] ?? []
        let total = index.trackCounts[path] ?? 0
        let title = path.isEmpty ? folder.name : (path.split(separator: "/").last.map(String.init) ?? path)

        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(isLoading ? "LOADING..." : "\(total) TRACKS • \(children.count) FOLDERS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)

                ForEach(children, id: \.self) { name in
                    let childPath = path.isEmpty ? name : path + "/" + name
                    NavigationLink(value: childPath) {
                        HStack(spacing: 12) {
                            Text(name.uppercased())
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 8)

                            Text("\(index.trackCounts[childPath] ?? 0)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .overlay(appTheme.separatorColor.opacity(0.35))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(appTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(title.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if path.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("CLOSE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                makePlaylist(folderPath: path, name: title)
            } label: {
                Text("MAKE PLAYLIST")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoading || total == 0)
            .opacity(isLoading || total == 0 ? 0.4 : 1.0)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(appTheme.backgroundColor.ignoresSafeArea(edges: .bottom))
        }
    }

    // MARK: - Playlist Creation

    private func makePlaylist(folderPath: String, name: String) {
        let ids = index.trackIDs(under: folderPath)
        guard !ids.isEmpty else { return }

        let tracksByID = Dictionary(libraryStore.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedTracks = ids.compactMap { tracksByID[$0] }
        guard !orderedTracks.isEmpty else { return }

        let baseName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Playlist" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingNames = Set(libraryStore.playlists.map { $0.name.lowercased() })
        var finalName = baseName
        var suffix = 2
        while existingNames.contains(finalName.lowercased()) {
            finalName = "\(baseName) \(suffix)"
            suffix += 1
        }

        let playlist = libraryStore.createPlaylist(name: finalName)
        libraryStore.addTracks(orderedTracks, toPlaylistID: playlist.id)
        HapticFeedback.notificationSuccess()
        dismiss()
    }
}
