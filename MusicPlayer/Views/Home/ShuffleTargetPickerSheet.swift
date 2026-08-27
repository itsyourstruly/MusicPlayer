//
//  ShuffleTargetPickerSheet.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI

/// Sheet allowing the user to select an Artist, Album, or Playlist to customize the Home Shuffle button target.
/// Only shows results for Albums, Playlists, and Artists.
public struct ShuffleTargetPickerSheet: View {
    @Bindable var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var searchQuery: String = ""
    @State private var selectedTargetForConfirmation: ShuffleTarget? = nil
    @State private var showConfirmationAlert: Bool = false

    public init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    private var cleanQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredArtists: [Artist] {
        guard !cleanQuery.isEmpty else { return libraryStore.artists }
        return libraryStore.artists.filter {
            FuzzyMatcher.scoreArtist(normalizedName: $0.normalizedName, cleanQuery: cleanQuery) > 0
        }
    }

    private var filteredAlbums: [Album] {
        guard !cleanQuery.isEmpty else { return libraryStore.albums }
        return libraryStore.albums.filter {
            FuzzyMatcher.scoreAlbum(normalizedTitle: $0.normalizedTitle, normalizedArtist: $0.normalizedArtist, cleanQuery: cleanQuery) > 0
        }
    }

    private var filteredPlaylists: [Playlist] {
        guard !cleanQuery.isEmpty else { return libraryStore.playlists }
        return libraryStore.playlists.filter {
            FuzzyMatcher.evaluateScore(cleanText: $0.normalizedName, cleanQuery: cleanQuery) > 0
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    // Reset to All Option
                    Button(action: {
                        selectedTargetForConfirmation = .all
                        showConfirmationAlert = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(appTheme.accentColor)
                                .frame(width: 40, height: 40)
                                .background(appTheme.secondaryBackgroundColor)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("ALL TRACKS")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                Text("Entire library (\(libraryStore.tracks.count) tracks)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()

                    // Artists Section
                    if !filteredArtists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ARTISTS (\(filteredArtists.count))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            ForEach(filteredArtists.prefix(20)) { artist in
                                artistRow(artist: artist)
                            }
                        }
                    }

                    // Albums Section
                    if !filteredAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ALBUMS (\(filteredAlbums.count))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            ForEach(filteredAlbums.prefix(20)) { album in
                                albumRow(album: album)
                            }
                        }
                    }

                    // Playlists Section
                    if !filteredPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PLAYLISTS (\(filteredPlaylists.count))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            ForEach(filteredPlaylists) { playlist in
                                playlistRow(playlist: playlist)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .dismissKeyboardOnDrag()
            .background(appTheme.backgroundColor.ignoresSafeArea())
            .searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "SEARCH ARTISTS, ALBUMS, PLAYLISTS..."
            )
            .navigationTitle("SET SHUFFLE TARGET")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("CANCEL") {
                        dismiss()
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
            }
            .alert(
                "THIS WILL SWITCH THE SHUFFLE BUTTON TO THIS ARTIST/ALBUM/PLAYLIST. ARE YOU SURE?",
                isPresented: $showConfirmationAlert,
                presenting: selectedTargetForConfirmation
            ) { target in
                Button("CONFIRM") {
                    HapticFeedback.notificationSuccess()
                    libraryStore.settings.customShuffleTarget = target
                    libraryStore.saveSettings()
                    dismiss()
                }
                Button("CANCEL", role: .cancel) {}
            }
        }
    }

    private func artistRow(artist: Artist) -> some View {
        Button(action: {
            selectedTargetForConfirmation = .artist(name: artist.name)
            showConfirmationAlert = true
        }) {
            HStack(spacing: 12) {
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(appTheme.accentColor)
                    .frame(width: 40, height: 40)
                    .background(appTheme.secondaryBackgroundColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(artist.formattedTrackCount)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func albumRow(album: Album) -> some View {
        Button(action: {
            selectedTargetForConfirmation = .album(title: album.title, artist: album.artist)
            showConfirmationAlert = true
        }) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: album.artworkKey,
                    title: album.title,
                    subtitle: album.artist,
                    cornerRadius: 6
                )
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text("\(album.artist) • \(album.formattedTrackCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(playlist: Playlist) -> some View {
        Button(action: {
            selectedTargetForConfirmation = .playlist(id: playlist.id, name: playlist.name)
            showConfirmationAlert = true
        }) {
            HStack(spacing: 12) {
                AlbumArtworkView(
                    artworkKey: libraryStore.artworkKey(for: playlist),
                    title: playlist.name,
                    subtitle: "Playlist",
                    cornerRadius: 6
                )
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(playlist.formattedTrackCount)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
