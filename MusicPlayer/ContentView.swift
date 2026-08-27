import SwiftUI

// MARK: - ContentView

/// Root multiplatform application coordinator.
/// Adapts cleanly to macOS with a desktop NavigationSplitView and bottom playback console,
/// while maintaining the fluid TabView and Expandable Player on iOS.
public struct ContentView: View {
    @State private var libraryStore = LibraryStore()
    @State private var playerService = AudioPlayerService()

    // MARK: iOS State

    #if os(iOS)
    @State private var selectedTab: Int = 0
    @State private var isPlayerExpanded: Bool = false
    @State private var showingSettings: Bool = false
    @State private var navigationPathHome = NavigationPath()
    @State private var navigationPathLibrary = NavigationPath()

    /// Custom tab binding so re-tapping the active tab pops its navigation stack
    /// rather than re-creating the view — mirrors the behaviour of the native Music app.
    private var tabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == 1 && selectedTab == 1 {
                    // Re-tap on Library: haptic feedback and reset to default category
                    HapticFeedback.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        if !navigationPathLibrary.isEmpty {
                            navigationPathLibrary.removeLast(navigationPathLibrary.count)
                        }
                        libraryStore.selectedCategory = libraryStore.settings.defaultLibraryCategory
                    }
                } else if newTab == 0 && selectedTab == 0 {
                    // Re-tap on Home: pop back to root without touching the category state
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

    // Initialize with configured properties
    public init() {}

    // MARK: Body

    // Main view layout structure
    public var body: some View {
        #if os(macOS)
        MacMainView(
            libraryStore: libraryStore,
            playerService: playerService
        )
        .tint(libraryStore.settings.appTheme.accentColor)
        .environment(\.appTheme, libraryStore.settings.appTheme)
        // Async lifecycle task
        .task {
            setupPlayerSync()
        }
        // Keep the player service in sync whenever the user changes crossfade settings
        .onChange(of: libraryStore.settings.isCrossfadeEnabled) { _, isEnabled in
            playerService.isCrossfadeEnabled = isEnabled
        }
        // React to state changes
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
            // Only inserted into the hierarchy once a track is loaded to avoid layout overhead
            if playerService.currentTrack != nil {
                ExpandablePlayerView(
                    playerService: playerService,
                    libraryStore: libraryStore,
                    isExpanded: $isPlayerExpanded
                )
                // High zIndex keeps the player above all tab content and navigation chrome
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
        // Modal presentation sheet
        .sheet(isPresented: $showingSettings) {
            SettingsView(libraryStore: libraryStore, playerService: playerService)
                .tint(libraryStore.settings.appTheme.accentColor)
                .environment(\.appTheme, libraryStore.settings.appTheme)
        }
        // Async lifecycle task
        .task {
            setupPlayerSync()
        }
        // Mirror each user-facing setting change into the player service immediately
        .onChange(of: libraryStore.settings.isCrossfadeEnabled) { _, isEnabled in
            playerService.isCrossfadeEnabled = isEnabled
        }
        // React to state changes
        .onChange(of: libraryStore.settings.crossfadeDuration) { _, duration in
            playerService.crossfadeDuration = duration
        }
        // React to state changes
        .onChange(of: libraryStore.settings.playTrackInCurrentQueue) { _, playInQueue in
            playerService.playTrackInCurrentQueue = playInQueue
        }
        // React to state changes
        .onChange(of: libraryStore.settings.tapToPlayNext) { _, tapNext in
            playerService.tapToPlayNext = tapNext
        }
        #endif
    }

    // MARK: Setup

    /// Seeds the player service with the current persisted settings and wires up
    /// the play-count callback. Called once on `.task` so it runs after the view mounts.
    private func setupPlayerSync() {
        playerService.isCrossfadeEnabled = libraryStore.settings.isCrossfadeEnabled
        playerService.crossfadeDuration = libraryStore.settings.crossfadeDuration
        playerService.playTrackInCurrentQueue = libraryStore.settings.playTrackInCurrentQueue
        playerService.tapToPlayNext = libraryStore.settings.tapToPlayNext
        // Weak capture prevents a retain cycle between the service and the store
        playerService.onTrackPlay = { [weak libraryStore] trackID in
            libraryStore?.incrementPlayCount(for: trackID)
        }
    }
}

#Preview {
    ContentView()
}
