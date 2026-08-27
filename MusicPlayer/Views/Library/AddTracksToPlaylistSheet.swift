import SwiftUI

/// Modal sheet for searching all library tracks and quickly adding/removing them from a playlist.
public struct AddTracksToPlaylistSheet: View {
    public let playlistID: UUID
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var searchQuery: String = ""

    public init(playlistID: UUID, libraryStore: LibraryStore) {
        self.playlistID = playlistID
        self.libraryStore = libraryStore
    }

    private var currentPlaylist: Playlist? {
        libraryStore.playlists.first(where: { $0.id == playlistID })
    }

    private var filteredTracks: [Track] {
        let cleanQuery = FuzzyMatcher.normalize(searchQuery)
        guard !cleanQuery.isEmpty else { return libraryStore.tracks }

        let scored: [(Track, Int)] = libraryStore.tracks.compactMap { track in
            let score = FuzzyMatcher.scoreTrack(
                normalizedTitle: track.normalizedTitle,
                normalizedArtist: track.normalizedArtist,
                normalizedAlbum: track.normalizedAlbum,
                searchTokens: track.searchTokens,
                cleanQuery: cleanQuery
            )
            return score > 0 ? (track, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Input Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("SEARCH ALL TRACKS", text: $searchQuery)
                        .font(.system(size: 13, weight: .medium))
                        .textFieldStyle(.plain)

                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if filteredTracks.isEmpty {
                    EmptyStateView(
                        title: searchQuery.isEmpty ? "NO TRACKS IN LIBRARY" : "NO TRACKS FOUND",
                        message: searchQuery.isEmpty
                            ? "Scan a directory in Settings to add tracks to your library."
                            : "No tracks match '\(searchQuery)'."
                    )
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredTracks) { track in
                            let isAdded = currentPlaylist?.trackIDs.contains(track.id) ?? false
                            HStack(spacing: 12) {
                                AlbumArtworkView(
                                    artworkKey: track.artworkKey,
                                    title: track.album,
                                    subtitle: track.artist,
                                    cornerRadius: 6
                                )
                                .frame(width: 42, height: 42)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)

                                    Text(track.artistAlbumSubtitle)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Button(action: {
                                    HapticFeedback.lightImpact()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        if isAdded {
                                            libraryStore.removeTrack(trackID: track.id, fromPlaylistID: playlistID)
                                        } else {
                                            libraryStore.addTrack(track, toPlaylistID: playlistID)
                                        }
                                    }
                                }) {
                                    if isAdded {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                            Text("ADDED")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        }
                                        .foregroundStyle(appTheme.accentColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(appTheme.accentColor.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    } else {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 10, weight: .bold))
                                            Text("ADD")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        }
                                        .foregroundStyle(Color.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.appSecondaryBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Color.appSeparator.opacity(0.5), lineWidth: 0.5)
                                        )
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("ADD TO PLAYLIST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
