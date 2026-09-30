import SwiftUI

/// List view displaying connected music folders with large folder names and a dedicated NAME sort row.
public struct FoldersListView: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.appTheme) private var appTheme

    @State private var folderSortOption: FolderSortOption = .name
    @State private var isSortReversed: Bool = false

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    private var sortedFolders: [LinkedFolder] {
        var folders = libraryStore.settings.linkedFolders
        if !libraryStore.searchQuery.isEmpty {
            let q = FuzzyMatcher.normalize(libraryStore.searchQuery)
            folders = folders.filter { FuzzyMatcher.normalize($0.name).contains(q) }
        }
        folders.sort { a, b in
            if isSortReversed {
                return a.name.localizedStandardCompare(b.name) == .orderedDescending
            } else {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return folders
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

            if sortedFolders.isEmpty {
                EmptyStateView(
                    title: "NO FOLDERS FOUND",
                    message: libraryStore.searchQuery.isEmpty
                        ? "Link music folders in Settings to see them here."
                        : "No folders match '\(libraryStore.searchQuery)'."
                )
                .padding(.top, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sortedFolders) { folder in
                        let isEnabled = libraryStore.isFolderEnabled(folder.id)
                        Button {
                            HapticFeedback.selectionChanged()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                libraryStore.toggleFolderEnabled(folder.id)
                            }
                        } label: {
                            HStack {
                                Text(folder.name)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.35))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.top, 4)
    }
}
