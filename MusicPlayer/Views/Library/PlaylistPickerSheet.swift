import SwiftUI

/// The one "ADD TO PLAYLIST" sheet used across the app. Small sheet on the theme background,
/// dismissed by swiping down; each row is name, track count and "ADD" with a separator under it.
/// The caller's `onAdd` keeps each screen's existing add behavior (and dismisses the sheet).
/// NEW (top right) opens the NEW PLAYLIST sheet; its SAVE creates the playlist and hands it to `onAdd`.
struct PlaylistPickerSheet: View {
    @Bindable var libraryStore: LibraryStore
    // Artwork of the first song being added, shown in the NEW PLAYLIST preview
    let previewArtworkKey: String?
    let onAdd: (Playlist) -> Void
    @State private var showingNewPlaylist: Bool = false

    init(libraryStore: LibraryStore, previewArtworkKey: String? = nil, onAdd: @escaping (Playlist) -> Void) {
        self.libraryStore = libraryStore
        self.previewArtworkKey = previewArtworkKey
        self.onAdd = onAdd
    }

    var body: some View {
        let theme = libraryStore.settings.appTheme
        VStack(spacing: 0) {
            ZStack {
                Text("ADD TO PLAYLIST")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)

                HStack {
                    Spacer()
                    Button(action: { showingNewPlaylist = true }) {
                        Text("NEW")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.accentColor)
                    }
                    // Opens a sheet, so it gets the system Liquid Glass background (like the toolbar gear)
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)

            if libraryStore.playlists.isEmpty {
                Text("NO PLAYLISTS YET")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(libraryStore.playlists) { playlist in
                            Button {
                                onAdd(playlist)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                        Text(playlist.formattedTrackCount)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text("ADD")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.primary)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.backgroundColor)
        .tint(theme.accentColor)
        .environment(\.appTheme, theme)
        .sheet(isPresented: $showingNewPlaylist) {
            EditPlaylistModalView(newPlaylistWith: libraryStore, previewArtworkKey: previewArtworkKey) { created in
                onAdd(created)
            }
        }
    }
}

/// Shared "QUICK ADD TO..." submenu listing playlists; adds the given tracks directly (duplicates are skipped).
/// A separate view so the playlist list is only observed when the menu content renders, not by the host row.
public struct QuickAddToPlaylistMenu: View {
    private let resolveTracks: () -> [Track]
    public let libraryStore: LibraryStore
    public let excludedPlaylistID: UUID?
    private let onAdded: (() -> Void)?

    public init(tracks: [Track], libraryStore: LibraryStore, excludedPlaylistID: UUID? = nil) {
        self.resolveTracks = { tracks }
        self.libraryStore = libraryStore
        self.excludedPlaylistID = excludedPlaylistID
        self.onAdded = nil
    }

    /// Tracks resolved only when a playlist is picked; `onAdded` runs after a non-empty add.
    public init(libraryStore: LibraryStore, onAdded: @escaping () -> Void, resolveTracks: @escaping () -> [Track]) {
        self.resolveTracks = resolveTracks
        self.libraryStore = libraryStore
        self.excludedPlaylistID = nil
        self.onAdded = onAdded
    }

    public var body: some View {
        let playlists = libraryStore.playlists.filter { $0.id != excludedPlaylistID }
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button(action: {
                        let tracks = resolveTracks()
                        guard !tracks.isEmpty else { return }
                        HapticFeedback.notificationSuccess()
                        libraryStore.addTracks(tracks, toPlaylistID: playlist.id)
                        onAdded?()
                    }) {
                        Text(playlist.name)
                    }
                }
            } label: {
                Text("QUICK ADD TO...")
            }
        }
    }
}
