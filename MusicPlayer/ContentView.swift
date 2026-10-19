import SwiftUI

// MARK: - ContentView

/// Root multiplatform application coordinator.
/// Adapts cleanly to macOS with a desktop NavigationSplitView and bottom playback console,
/// while maintaining the fluid TabView and Expandable Player on iOS.
public struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryStore = LibraryStore()
    @State private var playerService = AudioPlayerService()

    // MARK: iOS State

    #if os(iOS)
    @State private var selectedTab: Int = 0
    @State private var isPlayerExpanded: Bool = false
    @State private var showingSettings: Bool = false
    @State private var homeNavigateToSearch: Bool = false
    @State private var selectedHomeAlbum: Album? = nil
    @State private var selectedHomePlaylist: Playlist? = nil
    @State private var isLibrarySearchFocused: Bool = false
    @State private var lastHomeTabTapTime: TimeInterval = 0

    /// Custom tab binding so re-tapping the active tab pops its navigation stack or triggers shortcuts
    private var tabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == 0 {
                    let now = Date().timeIntervalSince1970
                    guard now - lastHomeTabTapTime > 0.35 else { return }
                    lastHomeTabTapTime = now
                    HapticFeedback.selectionChanged()
                    if selectedTab == 0 {
                        // Already on the Home tab
                        if selectedHomeAlbum != nil || selectedHomePlaylist != nil {
                            // Currently in an album or playlist pushed from Home -> return to Home page
                            selectedHomeAlbum = nil
                            selectedHomePlaylist = nil
                            homeNavigateToSearch = false
                        } else if homeNavigateToSearch {
                            // Currently in Search Library -> tap Home to return to the Home page
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            homeNavigateToSearch = false
                        } else {
                            // Already on the Home page -> tap Home to go to the SEARCH LIBRARY page
                            homeNavigateToSearch = true
                        }
                    } else {
                        // Switching from Library tab to Home -> return to the Home page
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        selectedHomeAlbum = nil
                        selectedHomePlaylist = nil
                        homeNavigateToSearch = false
                        selectedTab = 0
                    }
                } else if newTab == 1 {
                    if selectedTab == 1 {
                        HapticFeedback.selectionChanged()
                        let defaultCat = libraryStore.settings.defaultLibraryCategory
                        if !libraryStore.searchQuery.isEmpty || libraryStore.selectedCategory != defaultCat {
                            libraryStore.searchQuery = ""
                            libraryStore.selectedCategory = defaultCat
                            isLibrarySearchFocused = false
                        } else {
                            isLibrarySearchFocused = true
                        }
                    } else {
                        // Switching from Home tab to Library: resign any active search keyboard cleanly
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    selectedTab = 1
                }
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
        .environment(libraryStore)
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
        .onChange(of: libraryStore.settings.playTrackInCurrentQueue) { _, playInQueue in
            playerService.playTrackInCurrentQueue = playInQueue
        }
        .onChange(of: libraryStore.settings.tapToPlayNext) { _, tapNext in
            playerService.tapToPlayNext = tapNext
        }
        .onChange(of: libraryStore.settings.smoothSkippingEnabled) { _, smooth in
            playerService.smoothSkippingEnabled = smooth
        }
        .onChange(of: libraryStore.settings.autoPlayNext) { _, autoPlay in
            playerService.autoPlayNext = autoPlay
        }
        .onChange(of: libraryStore.settings.rememberPlaybackPosition) { _, isRemember in
            playerService.rememberPlaybackPosition = isRemember
        }
        .onChange(of: libraryStore.settings.rememberPlaybackPositionMinMinutes) { _, minMinutes in
            playerService.rememberPlaybackPositionMinMinutes = minMinutes
        }
        .onChange(of: libraryStore.settings.downloadNextSongOnWiFi) { _, _ in
            playerService.downloadNextSongOnWiFi = true
        }
        .preferredColorScheme(.dark)
        #else
        ZStack(alignment: .bottom) {
            // Main Tab View (100% interactive - tabs and navigation are NEVER blocked)
            TabView(selection: tabBinding) {
                // Home Tab
                NavigationStack {
                    HomeView(
                        libraryStore: libraryStore,
                        playerService: playerService,
                        navigateToSearch: $homeNavigateToSearch,
                        selectedAlbumForNavigation: $selectedHomeAlbum,
                        selectedPlaylistForNavigation: $selectedHomePlaylist,
                        onOpenSettings: {
                            showingSettings = true
                        }
                    )
                    .enableInteractivePopGesture()
                }
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

                // Library Tab
                NavigationStack {
                    LibraryView(
                        libraryStore: libraryStore,
                        playerService: playerService,
                        isSearchFocused: $isLibrarySearchFocused,
                        onOpenSettings: {
                            showingSettings = true
                        }
                    )
                    .enableInteractivePopGesture()
                }
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
                .tag(1)
            }

            // Unified Fluid Expandable Player (Floating Miniplayer -> Full-Screen Player)
            // Only inserted into the hierarchy once a track is loaded to avoid layout overhead
            playerOverlay
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
        .onChange(of: libraryStore.settings.smoothSkippingEnabled) { _, smooth in
            playerService.smoothSkippingEnabled = smooth
        }
        .onChange(of: libraryStore.settings.autoPlayNext) { _, autoPlay in
            playerService.autoPlayNext = autoPlay
        }
        .onChange(of: libraryStore.settings.rememberPlaybackPosition) { _, isRemember in
            playerService.rememberPlaybackPosition = isRemember
        }
        .onChange(of: libraryStore.settings.rememberPlaybackPositionMinMinutes) { _, minMinutes in
            playerService.rememberPlaybackPositionMinMinutes = minMinutes
        }
        .onChange(of: libraryStore.settings.downloadNextSongOnWiFi) { _, _ in
            playerService.downloadNextSongOnWiFi = true
        }
        .onChange(of: libraryStore.settings.serverSources) { _, servers in
            playerService.serverSources = servers
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            playerService.refreshAudioSessionAndRoute()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                JellyfinDownloadManager.shared.flushIndex()
            } else if newPhase == .active {
                Task { await libraryStore.syncStaleServers() }
            }
        }
        .preferredColorScheme(.dark)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var playerOverlay: some View {
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
    #endif

    // MARK: Setup

    /// Seeds the player service with the current persisted settings and wires up
    /// the play-count callback. Called once on `.task` so it runs after the view mounts.
    private func setupPlayerSync() {
        playerService.refreshAudioSessionAndRoute()
        playerService.isCrossfadeEnabled = libraryStore.settings.isCrossfadeEnabled
        playerService.crossfadeDuration = libraryStore.settings.crossfadeDuration
        playerService.playTrackInCurrentQueue = libraryStore.settings.playTrackInCurrentQueue
        playerService.tapToPlayNext = libraryStore.settings.tapToPlayNext
        playerService.smoothSkippingEnabled = libraryStore.settings.smoothSkippingEnabled
        playerService.autoPlayNext = libraryStore.settings.autoPlayNext
        playerService.rememberPlaybackPosition = libraryStore.settings.rememberPlaybackPosition
        playerService.rememberPlaybackPositionMinMinutes = libraryStore.settings.rememberPlaybackPositionMinMinutes
        playerService.downloadNextSongOnWiFi = true
        playerService.serverSources = libraryStore.settings.serverSources
        playerService.autoDownloadOnPlay = false
        playerService.downloadOnCellular = true
        JellyfinDownloadManager.shared.allowsCellularAccess = true

        CloudDownloadCenter.shared.onTrackDownloaded = { [weak libraryStore] trackID, url in
            libraryStore?.upgradeTrackAfterDownload(trackID: trackID, fileURL: url)
        }

        playerService.onResolveTrack = { [weak libraryStore] trackID in
            libraryStore?.tracksByID[trackID]
        }

        // Weak capture prevents a retain cycle between the service and the store
        playerService.onTrackPlay = { [weak libraryStore] trackID in
            libraryStore?.incrementPlayCount(for: trackID)
            if let track = libraryStore?.tracks.first(where: { $0.id == trackID }) {
                libraryStore?.recordTrackPlayed(track)
            }
        }
        playerService.onSavePlaybackPosition = { [weak libraryStore] trackID, position in
            libraryStore?.setPlaybackPosition(position, for: trackID)
        }
        playerService.onGetPlaybackPosition = { [weak libraryStore] trackID in
            libraryStore?.playbackPosition(for: trackID)
        }
        playerService.onClearPlaybackPosition = { [weak libraryStore] trackID in
            libraryStore?.removePlaybackPosition(for: trackID)
        }
    }
}
