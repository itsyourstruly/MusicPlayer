import SwiftUI

/// The one "ADD TO PLAYLIST" sheet used across the app. Small sheet on the theme background,
/// dismissed by swiping down; each row is name, track count and "ADD" with a separator under it.
/// The caller's `onAdd` keeps each screen's existing add behavior (and dismisses the sheet).
struct PlaylistPickerSheet: View {
    @Bindable var libraryStore: LibraryStore
    let onAdd: (Playlist) -> Void

    var body: some View {
        let theme = libraryStore.settings.appTheme
        VStack(spacing: 0) {
            Text("ADD TO PLAYLIST")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
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
    }
}
