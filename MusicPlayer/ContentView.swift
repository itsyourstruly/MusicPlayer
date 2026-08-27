//
//  ContentView.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import SwiftUI

/// Root multiplatform application coordinator.
/// Adapts cleanly to macOS with a desktop NavigationSplitView and bottom playback console,
/// while maintaining the fluid TabView and Expandable Player on iOS.
public struct ContentView: View {
    @State private var libraryStore = LibraryStore()
    @State private var playerService = AudioPlayerService()

    #if os(iOS)
    @State private var selectedTab: Int = 0
    @State private var isPlayerExpanded: Bool = false
    @State private var showingSettings: Bool = false
    @State private var navigationPathHome = NavigationPath()
    @State private var navigationPathLibrary = NavigationPath()
    private var tabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == 1 && selectedTab == 1 {
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        if !navigationPathLibrary.isEmpty {
                            navigationPathLibrary.removeLast(navigationPathLibrary.count)
                        }
                        libraryStore.selectedCategory = libraryStore.settings.defaultLibraryCategory
                    }
                } else if newTab == 0 && selectedTab == 0 {
                    if !navigationPathHome.isEmpty {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            navigationPathHome.removeLast(navigationPathHome.count)
                        }
                    }
                }
                selectedTab = newTab
            }
        )
    }
    #endif

    public init() {}

    public var body: some View {
        #if os(macOS)
        MacMainView(
            libraryStore: libraryStore,
            playerService: playerService
        )
        .tint(libraryStore.settings.appTheme.accentColor)
        .environment(\.appTheme, libraryStore.settings.appTheme)
        .task {
            setupPlayerSync()
        }
        .onChange(of: libraryStore.settings.isCrossfadeEnabled) { _, isEnabled in
            playerService.isCrossfadeEnabled = isEnabled
        }
        .onChange(of: libraryStore.settings.crossfadeDuration) { _, duration in
            playerService.crossfadeDuration = duration
        }
        #else
        ZStack(alignment: .bottom) {
            // Main Tab View (100% interactive - tabs and navigation are NEVER blocked)
            TabView(selection: tabBinding) {
                // Home Tab
                NavigationStack(path: $navigationPathHome) {
                    HomeView(
                        libraryStore: libraryStore,
                        playerService: playerService,
                        onNavigateToPlaylist: { playlist in
                            navigationPathHome.append(playlist.id)
                        },
                        onOpenSettings: {
                            showingSettings = true
                        }
                    )
                    .navigationDestination(for: UUID.self) { playlistID in
                        PlaylistDetailView(
                            playlistID: playlistID,
                            libraryStore: libraryStore,
                            playerService: playerService
                        )
                    }
                }
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

                // Library Tab
                NavigationStack(path: $navigationPathLibrary) {
                    LibraryView(
                        libraryStore: libraryStore,
                        playerService: playerService,
                        onOpenSettings: {
                            showingSettings = true
                        }
                    )
                }
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
                .tag(1)
            }

            // Unified Fluid Expandable Player (Floating Miniplayer -> Full-Screen Player)
            if playerService.currentTrack != nil {
                ExpandablePlayerView(
                    playerService: playerService,
                    libraryStore: libraryStore,
                    isExpanded: $isPlayerExpanded
                )
                .zIndex(100)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            }
        }
        .tint(libraryStore.settings.appTheme.accentColor)
        .environment(\.appTheme, libraryStore.settings.appTheme)
        .environment(libraryStore)
        .sheet(isPresented: $showingSettings) {
            SettingsView(libraryStore: libraryStore, playerService: playerService)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        .task {
            setupPlayerSync()
        }
        .onChange(of: libraryStore.settings.isCrossfadeEnabled) { _, isEnabled in
            playerService.isCrossfadeEnabled = isEnabled
        }
        .onChange(of: libraryStore.settings.crossfadeDuration) { _, duration in
            playerService.crossfadeDuration = duration
        }
        .onChange(of: libraryStore.settings.playTrackInCurrentQueue) { _, playInQueue in
            playerService.playTrackInCurrentQueue = playInQueue
        }
        .onChange(of: libraryStore.settings.tapToPlayNext) { _, tapNext in
            playerService.tapToPlayNext = tapNext
        }
        #endif
    }

    private func setupPlayerSync() {
        playerService.isCrossfadeEnabled = libraryStore.settings.isCrossfadeEnabled
        playerService.crossfadeDuration = libraryStore.settings.crossfadeDuration
        playerService.playTrackInCurrentQueue = libraryStore.settings.playTrackInCurrentQueue
        playerService.tapToPlayNext = libraryStore.settings.tapToPlayNext
        playerService.onTrackPlay = { [weak libraryStore] trackID in
            libraryStore?.incrementPlayCount(for: trackID)
        }
    }
}

#Preview {
    ContentView()
}
