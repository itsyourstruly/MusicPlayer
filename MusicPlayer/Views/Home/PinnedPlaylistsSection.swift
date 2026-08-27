import SwiftUI
import UniformTypeIdentifiers

/// Section displaying user-pinned albums and playlists on the Home view with long-press drag reordering.
public struct PinnedSection: View {
    @Bindable var libraryStore: LibraryStore
    @Bindable var playerService: AudioPlayerService
    public let onSelectPlaylist: (Playlist) -> Void
    // On select album
    public let onSelectAlbum: (Album) -> Void

    @State private var draggedItem: PinnedItem? = nil

    // Columns
    private let columns = [
        GridItem(.adaptive(minimum: 140), spacing: 14)
    ]

    // Initialize with configured properties
    public init(
        libraryStore: LibraryStore,
        playerService: AudioPlayerService,
        onSelectPlaylist: @escaping (Playlist) -> Void,
        onSelectAlbum: @escaping (Album) -> Void
    ) {
        self.libraryStore = libraryStore
        self.playerService = playerService
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectAlbum = onSelectAlbum
    }

    // Main view layout structure
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PINS")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(libraryStore.pinnedItems.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if libraryStore.pinnedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NO PINS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text("Pin albums or playlists from the Library tab to access them quickly from Home.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .semanticCard(cornerRadius: 10, padding: 14)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(libraryStore.pinnedItems) { item in
                        pinnedCard(for: item)
                            .onDrag {
                                self.draggedItem = item
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: PinnedItemsDropDelegate(
                                    item: item,
                                    draggedItem: $draggedItem,
                                    libraryStore: libraryStore
                                )
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pinnedCard(for item: PinnedItem) -> some View {
        switch item {
        case .playlist(let playlist):
            Button(action: {
                onSelectPlaylist(playlist)
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        AlbumArtworkView(
                            artworkKey: libraryStore.artworkKey(for: playlist),
                            title: playlist.name,
                            subtitle: "Playlist",
                            cornerRadius: 8
                        )
                        .aspectRatio(1.0, contentMode: .fit)

                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.appInvertedBackground)
                            .padding(4)
                            .background(Color.primary.opacity(0.85))
                            .clipShape(Circle())
                            .padding(5)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)

                        Text("Playlist • \(playlist.formattedTrackCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        libraryStore.togglePinPlaylist(id: playlist.id)
                    }
                }) {
                    Label("UNPIN", systemImage: "pin.slash")
                }

                Divider()

                Button(action: {
                    // Tracks
                    let tracks = libraryStore.tracks(for: playlist)
                    if let first = tracks.first {
                        playerService.play(track: first, inQueue: tracks)
                    }
                }) {
                    Label("PLAY", systemImage: "play.fill")
                }

                Button(action: {
                    // Tracks
                    let tracks = libraryStore.tracks(for: playlist)
                    playerService.playNext(tracks: tracks)
                }) {
                    Label("PLAY NEXT", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button(action: {
                    // Tracks
                    let tracks = libraryStore.tracks(for: playlist)
                    playerService.appendToQueue(tracks: tracks)
                }) {
                    Label("ADD TO QUEUE", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }

        // Album or release title
        case .album(let album):
            Button(action: {
                onSelectAlbum(album)
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        AlbumArtworkView(
                            artworkKey: album.artworkKey,
                            title: album.title,
                            subtitle: album.artist,
                            cornerRadius: 8
                        )
                        .aspectRatio(1.0, contentMode: .fit)

                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.appInvertedBackground)
                            .padding(4)
                            .background(Color.primary.opacity(0.85))
                            .clipShape(Circle())
                            .padding(5)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)

                        Text(album.artist)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
            .albumContextMenu(album: album, libraryStore: libraryStore, playerService: playerService)
        }
    }
}

/// Drop delegate providing native long-press drag-and-drop reordering for pinned items on Home.
struct PinnedItemsDropDelegate: DropDelegate {
    // Item
    let item: PinnedItem
    @Binding var draggedItem: PinnedItem?
    let libraryStore: LibraryStore

    // Drop entered
    func dropEntered(info: DropInfo) {
        // Ensure preconditions are met before proceeding
        guard let draggedItem = draggedItem,
              draggedItem.id != item.id else { return }

        HapticFeedback.lightImpact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            libraryStore.movePin(sourceID: draggedItem.id, targetID: item.id)
        }
    }

    // Drop updated
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    // Perform drop
    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

/// Compatibility alias for PinnedPlaylistsSection.
public typealias PinnedPlaylistsSection = PinnedSection
