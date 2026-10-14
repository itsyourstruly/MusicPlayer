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
                EmptyStateView(title: "EMPTY", message: "")
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

        return Button {
            HapticFeedback.selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) {
                libraryStore.toggleFolderEnabled(source.id)
            }
        } label: {
            HStack {
                Text(source.name)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
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
