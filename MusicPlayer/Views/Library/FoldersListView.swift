import SwiftUI

/// Unified List view displaying connected music sources (local folders and Jellyfin servers).
/// Supports independent source toggling, individual rescans, and sortable source listings.
public struct FoldersListView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.appTheme) private var appTheme

    @State private var folderSortOption: FolderSortOption = .name
    @State private var isSortReversed: Bool = false

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    public struct SourceItem: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let typeLabel: String
        public let trackCount: Int
        public let albumCount: Int
        public let isJellyfin: Bool
        public let linkedFolder: LinkedFolder?
        public let jellyfinServer: JellyfinServerLink?
    }

    private var allSources: [SourceItem] {
        var items: [SourceItem] = []

        for folder in libraryStore.settings.linkedFolders {
            let tCount = libraryStore.trackCount(for: folder)
            let aCount = libraryStore.albumCount(for: folder)
            items.append(SourceItem(
                id: folder.id,
                name: folder.name,
                typeLabel: "LOCAL FOLDER",
                trackCount: tCount,
                albumCount: aCount,
                isJellyfin: false,
                linkedFolder: folder,
                jellyfinServer: nil
            ))
        }

        for server in libraryStore.settings.jellyfinServers {
            let tCount = libraryStore.trackCount(for: server)
            let aCount = libraryStore.albumCount(for: server)
            items.append(SourceItem(
                id: server.id,
                name: server.serverName,
                typeLabel: "JELLYFIN SERVER",
                trackCount: tCount,
                albumCount: aCount,
                isJellyfin: true,
                linkedFolder: nil,
                jellyfinServer: server
            ))
        }

        if !libraryStore.searchQuery.isEmpty {
            let q = FuzzyMatcher.normalize(libraryStore.searchQuery)
            items = items.filter { FuzzyMatcher.normalize($0.name).contains(q) }
        }

        items.sort { a, b in
            if isSortReversed {
                return a.name.localizedStandardCompare(b.name) == .orderedDescending
            } else {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        return items
    }

    private var isSourcesPlural: Bool {
        (libraryStore.settings.linkedFolders.count + libraryStore.settings.jellyfinServers.count) > 1 || !libraryStore.settings.jellyfinServers.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Sort Selector Bar (NAME only) with hit target and reverse toggle
            SortSelectorBar(
                options: FolderSortOption.allCases,
                selectedOption: $folderSortOption,
                isReversed: $isSortReversed,
                labelForOption: { $0.label }
            )

            if allSources.isEmpty {
                EmptyStateView(
                    title: isSourcesPlural ? "NO SOURCES FOUND" : "NO FOLDERS FOUND",
                    message: libraryStore.searchQuery.isEmpty
                        ? "Link music folders or add a Jellyfin server in Settings to see them here."
                        : "No sources match '\(libraryStore.searchQuery)'."
                )
                .padding(.top, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(allSources) { source in
                        sourceRow(for: source)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.top, 4)
    }

    private func sourceRow(for source: SourceItem) -> some View {
        let isEnabled = libraryStore.isFolderEnabled(source.id)
        let isThisScanning = libraryStore.currentlyScanningFolderID == source.id

        return Button {
            HapticFeedback.selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) {
                libraryStore.toggleFolderEnabled(source.id)
            }
        } label: {
            HStack(spacing: 12) {
                // Source Icon
                Image(systemName: source.isJellyfin ? "server.rack" : "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        isEnabled
                            ? (source.isJellyfin ? Color.blue : appTheme.accentColor)
                            : Color.secondary.opacity(0.35)
                    )
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(source.name)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.35))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        if isThisScanning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: appTheme.accentColor))
                                .scaleEffect(0.65)
                                .frame(width: 12, height: 12)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(source.typeLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isEnabled ? appTheme.accentColor : Color.secondary.opacity(0.35))

                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.5))

                        Text("\(source.trackCount) TRACKS")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if source.albumCount > 0 {
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary.opacity(0.5))

                            Text("\(source.albumCount) ALBUMS")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Checkmark / State Indicator
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isEnabled ? appTheme.accentColor : Color.secondary.opacity(0.35))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                HapticFeedback.selectionChanged()
                if let folder = source.linkedFolder {
                    Task {
                        await libraryStore.rescanFolder(id: folder.id)
                    }
                } else if let server = source.jellyfinServer {
                    Task {
                        await libraryStore.syncJellyfinServer(server)
                    }
                }
            } label: {
                Text("RESCAN SOURCE")
            }
            .disabled(libraryStore.isScanning)

            Button {
                HapticFeedback.selectionChanged()
                libraryStore.toggleFolderEnabled(source.id)
            } label: {
                Text(isEnabled ? "DISABLE IN LIBRARY" : "ENABLE IN LIBRARY")
            }
        }
    }
}
