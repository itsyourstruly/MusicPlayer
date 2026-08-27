//
//  MacMainView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// Root macOS navigation coordinator utilizing NavigationSplitView, persistent bottom playback bar,
/// slide-out queue inspector, and drag-and-drop file import.
public struct MacMainView: View {
    public let libraryStore: LibraryStore
    public let playerService: AudioPlayerService

    @State private var selectedNavItem: MacNavigationItem? = .home
    @State private var isQueuePresented: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingCreatePlaylist: Bool = false
    @State private var selectedTrackForInfo: Track? = nil
    @State private var selectedTrackForPlaylist: Track? = nil
    @State private var selectedTrackForMatch: Track? = nil
    @State private var selectedArtistForNav: Artist? = nil
    @State private var selectedAlbumForNav: Album? = nil
    @State private var isDropTargeted: Bool = false

    @Environment(\.appTheme) private var appTheme

    public init(libraryStore: LibraryStore, playerService: AudioPlayerService) {
        self.libraryStore = libraryStore
        self.playerService = playerService
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Main Desktop 2-Pane Navigation with Trailing Inspector
            NavigationSplitView {
                MacSidebarView(
                    libraryStore: libraryStore,
                    playerService: playerService,
                    selectedItem: $selectedNavItem,
                    onOpenSettings: { showingSettings = true },
                    onCreatePlaylist: { showingCreatePlaylist = true }
                )
            } detail: {
                detailContentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .inspector(isPresented: $isQueuePresented) {
                MacQueueInspectorView(
                    playerService: playerService,
                    libraryStore: libraryStore,
                    onClose: { isQueuePresented = false }
                )
            }

            // Bottom-Anchored Persistent Desktop Playback Console
            MacPlaybackBarView(
                playerService: playerService,
                libraryStore: libraryStore,
                isQueuePresented: $isQueuePresented,
                onOpenTrackInfo: {
                    if let current = playerService.currentTrack {
                        selectedTrackForInfo = current
                    }
                },
                onSelectArtist: { artistName in
                    if let artistObj = libraryStore.findArtist(name: artistName) {
                        selectedArtistForNav = artistObj
                    }
                },
                onSelectAlbum: { albumTitle, artistName in
                    if let albumObj = libraryStore.findAlbum(title: albumTitle, artist: artistName) {
                        selectedAlbumForNav = albumObj
                    }
                }
            )
        }
        .background(appTheme.backgroundColor)
        .tint(libraryStore.settings.appTheme.accentColor)
        .environment(\.appTheme, libraryStore.settings.appTheme)
        .sheet(isPresented: $showingSettings) {
            SettingsView(libraryStore: libraryStore, playerService: playerService)
                .frame(minWidth: 580, idealWidth: 640, minHeight: 480, idealHeight: 560)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(isPresented: $showingCreatePlaylist) {
            CreatePlaylistSheet(libraryStore: libraryStore)
                .frame(minWidth: 380, minHeight: 220)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForInfo) { track in
            TrackInfoSheetView(track: track, libraryStore: libraryStore)
                .frame(minWidth: 460, minHeight: 440)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            playlistPickerSheet(for: track)
                .frame(minWidth: 380, minHeight: 320)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedTrackForMatch) { track in
            OnlineMetadataMatchSheet(track: track, libraryStore: libraryStore)
                .frame(minWidth: 580, minHeight: 520)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedArtistForNav) { artist in
            NavigationStack {
                ArtistDetailView(
                    artist: artist,
                    libraryStore: libraryStore,
                    playerService: playerService
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("CLOSE") { selectedArtistForNav = nil }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
            }
            .frame(minWidth: 620, minHeight: 520)
            .tint(libraryStore.settings.appTheme.accentColor)
            .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .sheet(item: $selectedAlbumForNav) { album in
            NavigationStack {
                AlbumDetailView(
                    album: album,
                    libraryStore: libraryStore,
                    playerService: playerService
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("CLOSE") { selectedAlbumForNav = nil }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
            }
            .frame(minWidth: 620, minHeight: 520)
            .tint(libraryStore.settings.appTheme.accentColor)
            .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            Group {
                if isDropTargeted {
                    ZStack {
                        Color.black.opacity(0.6)
                        VStack(spacing: 8) {
                            Text("DROP MUSIC FOLDER OR AUDIO FILES")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                            Text("Will link directory and index audio files automatically")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.8))
                        }
                        .padding(24)
                        .background(appTheme.secondaryBackgroundColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .ignoresSafeArea()
                }
            }
        )
    }

    // MARK: - Detail Content Switcher

    @ViewBuilder
    private var detailContentArea: some View {
        switch selectedNavItem {
        case .home, .none:
            MacHomeView(
                libraryStore: libraryStore,
                playerService: playerService,
                onNavigateToPlaylist: { playlist in
                    selectedNavItem = .playlist(playlist.id)
                },
                onNavigateToAlbum: { album in
                    selectedAlbumForNav = album
                },
                onNavigateToSearch: {
                    selectedNavItem = .search
                },
                onNavigateToDiscovery: {
                    selectedNavItem = .discovery
                },
                onOpenSettings: {
                    showingSettings = true
                }
            )

        case .search:
            NavigationStack {
                GlobalSearchView(
                    libraryStore: libraryStore,
                    playerService: playerService
                )
            }

        case .discovery:
            NavigationStack {
                OnlineSearchDiscoveryView()
            }

        case .allTracks:
            MacAllTracksView(
                libraryStore: libraryStore,
                playerService: playerService,
                onSelectArtist: { artist in
                    selectedArtistForNav = artist
                },
                onSelectAlbum: { album in
                    selectedAlbumForNav = album
                },
                onShowTrackInfo: { track in
                    selectedTrackForInfo = track
                },
                onAddToPlaylist: { track in
                    selectedTrackForPlaylist = track
                },
                onMatchOnline: { track in
                    selectedTrackForMatch = track
                }
            )

        case .albums:
            NavigationStack {
                ScrollView(.vertical, showsIndicators: true) {
                    AlbumsListView(
                        libraryStore: libraryStore,
                        playerService: playerService
                    )
                    .padding(.vertical, 16)
                }
                .background(appTheme.backgroundColor)
                .navigationTitle("ALBUMS")
            }

        case .artists:
            NavigationStack {
                ScrollView(.vertical, showsIndicators: true) {
                    ArtistsListView(
                        libraryStore: libraryStore,
                        playerService: playerService
                    )
                    .padding(.vertical, 16)
                }
                .background(appTheme.backgroundColor)
                .navigationTitle("ARTISTS")
            }

        case .duplicates:
            NavigationStack {
                DuplicateResolverView(libraryStore: libraryStore)
            }

        case .metadataAccuracy:
            NavigationStack {
                MetadataComparisonListView(libraryStore: libraryStore)
            }

        case .playlist(let playlistID):
            NavigationStack {
                PlaylistDetailView(
                    playlistID: playlistID,
                    libraryStore: libraryStore,
                    playerService: playerService
                )
            }
        }
    }

    // MARK: - Helper Modals & Drag-and-Drop

    private func playlistPickerSheet(for track: Track) -> some View {
        NavigationStack {
            List {
                if libraryStore.playlists.isEmpty {
                    Text("NO PLAYLISTS CREATED")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryStore.playlists) { playlist in
                        Button(action: {
                            libraryStore.addTrack(track, toPlaylistID: playlist.id)
                            selectedTrackForPlaylist = nil
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 13, weight: .bold))
                                    Text(playlist.formattedTrackCount)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("ADD")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(appTheme.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("ADD TO PLAYLIST")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("DONE") {
                        selectedTrackForPlaylist = nil
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            await libraryStore.linkAndScanFolder(url: url)
                        } else {
                            let parent = url.deletingLastPathComponent()
                            await libraryStore.linkAndScanFolder(url: parent)
                        }
                    }
                }
            }
        }
        return true
    }
}
