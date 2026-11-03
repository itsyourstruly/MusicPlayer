import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// AppThemeEnvironmentKey representation
private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppTheme = .dark
}

public extension EnvironmentValues {
    // App theme
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }

    /// Indicates whether the full-screen player is actively being dragged, swiped down to dismiss,
    /// or in the process of collapsing, allowing descendant buttons to suppress accidental triggers.
    var isPlayerDraggingOrDismissing: Bool {
        get { self[PlayerDraggingOrDismissingKey.self] }
        set { self[PlayerDraggingOrDismissingKey.self] = newValue }
    }
}

// PlayerDraggingOrDismissingKey representation
private struct PlayerDraggingOrDismissingKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

/// Semantic surface card modifier for standard dark/light mode responsive panels.
public struct SemanticCardModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    public var cornerRadius: CGFloat = 12
    public var padding: CGFloat = 16

    // Body
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(appTheme.secondaryBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(appTheme.separatorColor.opacity(0.55), lineWidth: 0.5)
            )
    }
}

/// Subtle badge modifier for tags, categories, counts, and status indicators.
public struct TypographicBadgeModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    public var isHighlighted: Bool = false

    // Body
    public func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isHighlighted
                    ? appTheme.accentColor
                    : appTheme.tertiaryBackgroundColor
            )
            .foregroundStyle(
                isHighlighted
                    ? Color.appInvertedBackground
                    : appTheme.primaryTextColor
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Desktop-tailored row hover modifier for macOS lists and tables.
public struct MacRowHoverModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    @State private var isHovered: Bool = false
    public var isSelected: Bool = false
    public var cornerRadius: CGFloat = 6

    // Body
    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? appTheme.accentColor.opacity(0.16)
                            : (isHovered ? appTheme.tertiaryBackgroundColor.opacity(0.55) : Color.clear)
                    )
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}

/// Extension for convenient view modifier application.
public extension View {
    // Semantic card
    func semanticCard(cornerRadius: CGFloat = 12, padding: CGFloat = 16) -> some View {
        modifier(SemanticCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    // Typographic badge
    func typographicBadge(isHighlighted: Bool = false) -> some View {
        modifier(TypographicBadgeModifier(isHighlighted: isHighlighted))
    }

    // Mac row hover
    func macRowHover(isSelected: Bool = false, cornerRadius: CGFloat = 6) -> some View {
        modifier(MacRowHoverModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }

    // Album context menu. GO TO ARTIST shows only when `onGoToArtist` is provided; `hidingArtistNamed` drops the artist already on screen.
    func albumContextMenu(album: Album, libraryStore: LibraryStore, playerService: AudioPlayerService, onGoToArtist: ((Artist) -> Void)? = nil, hidingArtistNamed: String? = nil) -> some View {
        modifier(AlbumContextMenuModifier(album: album, libraryStore: libraryStore, playerService: playerService, onGoToArtist: onGoToArtist, hidingArtistNamed: hidingArtistNamed))
    }

    // Library select mode: tapping an album shows SELECT / OPEN (a fully selected album is deselected directly)
    func albumSelectModeTap(album: Album, onOpen: @escaping () -> Void) -> some View {
        modifier(AlbumSelectModeTapModifier(album: album, onOpen: onOpen))
    }

    // Playlist context menu
    func playlistContextMenu(playlist: Playlist, libraryStore: LibraryStore, playerService: AudioPlayerService) -> some View {
        modifier(PlaylistContextMenuModifier(playlist: playlist, libraryStore: libraryStore, playerService: playerService))
    }
}

/// Universal long-press menu for albums: SHUFFLE, PLAY NEXT, QUEUE, GO TO ARTIST, ADD TO PLAYLIST, QUICK ADD TO..., downloads (server only), PIN, HIDE.
public struct AlbumContextMenuModifier: ViewModifier {
    // Album title
    public let album: Album
    // Library store
    public let libraryStore: LibraryStore
    // Player service
    public let playerService: AudioPlayerService
    // Navigation to an artist; nil hides GO TO ARTIST
    public var onGoToArtist: ((Artist) -> Void)? = nil
    // Artist already on screen, left out of GO TO ARTIST
    public var hidingArtistNamed: String? = nil
    @State private var showingPlaylistPicker: Bool = false
    @Environment(LibrarySelectionStore.self) private var librarySelection: LibrarySelectionStore?

    // Body
    public func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: {
                    if !album.tracks.isEmpty {
                        // Shuffled
                        var shuffled = album.tracks.shuffled()
                        // First
                        let first = shuffled.removeFirst()
                        shuffled.insert(first, at: 0)
                        playerService.play(track: first, inQueue: shuffled)
                    }
                }) {
                    Text("SHUFFLE")
                }

                Button(action: {
                    HapticFeedback.notificationSuccess()
                    playerService.insertPlayNextFront(tracks: album.tracks)
                }) {
                    Text("PLAY NEXT")
                }

                Button(action: {
                    HapticFeedback.notificationSuccess()
                    playerService.appendToQueue(tracks: album.tracks)
                }) {
                    Text("QUEUE")
                }

                if let onGoToArtist {
                    let artistNames = ArtistParser.parse(rawArtist: album.artist).map { $0.name }.filter { name in
                        guard let hidden = hidingArtistNamed else { return true }
                        return name.caseInsensitiveCompare(hidden) != .orderedSame
                    }
                    if artistNames.count == 1, let name = artistNames.first {
                        Button(action: {
                            if let artist = libraryStore.findArtist(name: name) { onGoToArtist(artist) }
                        }) {
                            Text("GO TO ARTIST")
                        }
                    } else if artistNames.count > 1 {
                        Menu {
                            ForEach(artistNames, id: \.self) { name in
                                Button(action: {
                                    if let artist = libraryStore.findArtist(name: name) { onGoToArtist(artist) }
                                }) {
                                    Text(name)
                                }
                            }
                        } label: {
                            Text("GO TO ARTIST")
                        }
                    }
                }

                Button(action: {
                    showingPlaylistPicker = true
                }) {
                    Text("ADD TO PLAYLIST")
                }

                QuickAddToPlaylistMenu(tracks: album.tracks, libraryStore: libraryStore)

                AlbumDownloadMenuItems(album: album, removeDownloadsAtBottom: true)

                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        libraryStore.togglePinAlbum(album)
                    }
                }) {
                    Text(libraryStore.isAlbumPinned(album) ? "UNPIN" : "PIN")
                }

                if let librarySelection {
                    AlbumSelectMenuItem(album: album, selection: librarySelection)
                }

                AlbumMenuBottomItem(album: album) {
                    HapticFeedback.notificationWarning()
                    libraryStore.hideAlbum(album)
                }
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                PlaylistPickerSheet(libraryStore: libraryStore, previewArtworkKey: album.tracks.lazy.compactMap(\.artworkKey).first) { playlist in
                    HapticFeedback.notificationSuccess()
                    libraryStore.addTracks(album.tracks, toPlaylistID: playlist.id)
                    showingPlaylistPicker = false
                }
            }
    }
}

/// SELECT / DESELECT for an album in the long-press menu; a separate view so only the open menu reads the selection.
private struct AlbumSelectMenuItem: View {
    let album: Album
    let selection: LibrarySelectionStore

    var body: some View {
        Button(action: {
            HapticFeedback.selectionChanged()
            selection.toggle(album: album)
        }) {
            Text(selection.isAlbumSelected(album) ? "DESELECT" : "SELECT")
        }
    }
}

/// In Library select mode, covers an album cell so a tap shows SELECT / OPEN instead of opening it,
/// or deselects the album directly when all its tracks are already selected. Inactive outside select mode.
private struct AlbumSelectModeTapModifier: ViewModifier {
    let album: Album
    let onOpen: () -> Void
    @Environment(LibrarySelectionStore.self) private var librarySelection: LibrarySelectionStore?

    func body(content: Content) -> some View {
        content.overlay {
            if let selection = librarySelection, selection.isActive {
                if selection.isAlbumSelected(album) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticFeedback.selectionChanged()
                            selection.toggle(album: album)
                        }
                } else {
                    Menu {
                        Button(action: {
                            HapticFeedback.selectionChanged()
                            selection.toggle(album: album)
                        }) {
                            Text("SELECT")
                        }
                        Button(action: onOpen) {
                            Text("OPEN")
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Album download menu items for server albums only (nothing for local albums).
/// A separate view so the download summary is computed only when the menu content renders, not for every grid cell.
public struct AlbumDownloadMenuItems: View {
    public let album: Album
    /// When true, REMOVE ALBUM DOWNLOADS is left out here because the menu shows it at the bottom (AlbumMenuBottomItem).
    public let removeDownloadsAtBottom: Bool

    public init(album: Album, removeDownloadsAtBottom: Bool = false) {
        self.album = album
        self.removeDownloadsAtBottom = removeDownloadsAtBottom
    }

    public var body: some View {
        let summary = JellyfinDownloadManager.shared.albumSummary(for: album)
        if summary.total > 0 {
            let jellyfinTracks = album.tracks.filter { $0.isJellyfinItem || $0.metadataSource == .server }
            if summary.isAllDownloaded {
                if !removeDownloadsAtBottom {
                    Button(role: .destructive) {
                        removeAlbumDownloads(album)
                    } label: {
                        Text("REMOVE ALBUM DOWNLOADS")
                    }
                }
            } else if summary.isAnyDownloading {
                if JellyfinDownloadManager.shared.isWaitingForWiFi {
                    Button {} label: {
                        Text("WAITING FOR WI-FI")
                    }
                    .disabled(true)
                }
                Button {
                    HapticFeedback.selectionChanged()
                    for track in jellyfinTracks {
                        JellyfinDownloadManager.shared.cancelDownload(trackId: track.id)
                    }
                } label: {
                    Text("CANCEL DOWNLOADS")
                }
            } else {
                Button {
                    HapticFeedback.selectionChanged()
                    JellyfinDownloadManager.shared.download(tracks: jellyfinTracks)
                } label: {
                    Text(summary.failed > 0 ? "DOWNLOAD FAILED, TAP TO RETRY" : "DOWNLOAD ALBUM")
                }
            }
        }
    }
}

/// Deletes the downloads of every server track in an album.
@MainActor public func removeAlbumDownloads(_ album: Album) {
    HapticFeedback.selectionChanged()
    for track in album.tracks where track.isJellyfinItem || track.metadataSource == .server {
        JellyfinDownloadManager.shared.deleteDownload(trackId: track.id)
    }
}

/// Bottom item of an album's long-press menu: REMOVE ALBUM DOWNLOADS when fully downloaded, otherwise HIDE.
public struct AlbumMenuBottomItem: View {
    public let album: Album
    public let onHide: () -> Void

    public init(album: Album, onHide: @escaping () -> Void) {
        self.album = album
        self.onHide = onHide
    }

    public var body: some View {
        let summary = JellyfinDownloadManager.shared.albumSummary(for: album)
        if summary.total > 0 && summary.isAllDownloaded {
            Button(role: .destructive) {
                removeAlbumDownloads(album)
            } label: {
                Text("REMOVE ALBUM DOWNLOADS")
            }
        } else {
            Button(role: .destructive, action: onHide) {
                Text("HIDE")
            }
        }
    }
}

/// Universal long-press menu for playlists: SHUFFLE, PLAY NEXT, QUEUE, PIN, DELETE (with confirmation).
public struct PlaylistContextMenuModifier: ViewModifier {
    public let playlist: Playlist
    public let libraryStore: LibraryStore
    public let playerService: AudioPlayerService
    @State private var showingDeleteAlert: Bool = false

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: {
                    let tracks = libraryStore.tracks(for: playlist).shuffled()
                    if let first = tracks.first {
                        playerService.play(track: first, inQueue: tracks)
                    }
                }) {
                    Text("SHUFFLE")
                }

                Button(action: {
                    HapticFeedback.notificationSuccess()
                    playerService.insertPlayNextFront(tracks: libraryStore.tracks(for: playlist))
                }) {
                    Text("PLAY NEXT")
                }

                Button(action: {
                    HapticFeedback.notificationSuccess()
                    playerService.appendToQueue(tracks: libraryStore.tracks(for: playlist))
                }) {
                    Text("QUEUE")
                }

                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        libraryStore.togglePinPlaylist(id: playlist.id)
                    }
                }) {
                    Text(playlist.isPinned ? "UNPIN" : "PIN")
                }

                Button(role: .destructive, action: {
                    showingDeleteAlert = true
                }) {
                    Text("DELETE")
                }
            }
            .alert("DELETE PLAYLIST", isPresented: $showingDeleteAlert) {
                Button("CANCEL", role: .cancel) {}
                Button("DELETE", role: .destructive) {
                    libraryStore.deletePlaylist(id: playlist.id)
                }
            } message: {
                Text("Are you sure you want to delete '\(playlist.name)'? Audio files on disk will not be affected.")
            }
    }
}

// MARK: - Universal Keyboard Drag-to-Dismiss Helper

public extension View {
    /// Allows dragging on the scroll content to dismiss the software keyboard interactively without cancelling in-flight scroll gestures.
    func dismissKeyboardOnDrag() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Native Search Field (iOS 26 Liquid Glass, same as the Library page)

public extension View {
    /// iOS: the system search field under the navigation bar, always visible (like the Library page).
    /// macOS: no change (Mac views keep their own search fields).
    @ViewBuilder
    func nativeSearchField(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        #else
        self
        #endif
    }
}

// MARK: - Interactive Swipe-to-Go-Back Navigation Enabler

#if os(iOS)
/// Attaches to UINavigationController to ensure interactive swipe-to-go-back
/// takes precedence over child scroll views and drag gestures when initiated from the left screen edge.
public struct InteractivePopGestureEnablerModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(InteractivePopGestureHelperView())
    }
}

private struct InteractivePopGestureHelperView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InteractivePopGestureController {
        InteractivePopGestureController()
    }

    func updateUIViewController(_ uiViewController: InteractivePopGestureController, context: Context) {
        uiViewController.configureNavigationController()
    }

    static func dismantleUIViewController(_ uiViewController: InteractivePopGestureController, coordinator: ()) {
        uiViewController.tearDownNavigationController()
    }
}

private final class InteractivePopGestureController: UIViewController, UIGestureRecognizerDelegate {
    private weak var configuredNavController: UINavigationController?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationController()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureNavigationController()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        configureNavigationController()
    }

    func configureNavigationController() {
        guard let nav = navigationController else { return }
        if configuredNavController !== nav {
            configuredNavController = nav
        }
        nav.interactivePopGestureRecognizer?.isEnabled = true
        nav.interactivePopGestureRecognizer?.delegate = self
    }

    func tearDownNavigationController() {
        if let nav = configuredNavController, nav.interactivePopGestureRecognizer?.delegate === self {
            nav.interactivePopGestureRecognizer?.delegate = nil
        }
        configuredNavController = nil
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = configuredNavController ?? navigationController else { return false }
        let shouldBegin = nav.viewControllers.count > 1
        if shouldBegin {
            // Let the page being swiped away close any active search before the pop animation starts.
            NotificationCenter.default.post(name: .interactivePopWillBegin, object: nil)
        }
        return shouldBegin
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = configuredNavController ?? navigationController else { return false }
        return gestureRecognizer == nav.interactivePopGestureRecognizer && nav.viewControllers.count > 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
}

public extension Notification.Name {
    /// Posted when the edge-swipe back gesture is about to begin.
    static let interactivePopWillBegin = Notification.Name("InteractivePopWillBegin")
}

public extension View {
    /// Ensures that swiping right from the left screen edge reliably triggers interactive pop navigation,
    /// preventing child scroll views and gestures from hijacking edge swipes.
    func enableInteractivePopGesture() -> some View {
        modifier(InteractivePopGestureEnablerModifier())
    }
}
#else
public extension View {
    func enableInteractivePopGesture() -> some View {
        self
    }
}
#endif

// MARK: - Cross-Platform Compatibility Shims for macOS

#if !os(iOS)
// NavigationBarTitleDisplayModePlaceholder representation
public struct NavigationBarTitleDisplayModePlaceholder: Sendable, Equatable {
    public static let automatic = NavigationBarTitleDisplayModePlaceholder()
    public static let inline = NavigationBarTitleDisplayModePlaceholder()
    public static let large = NavigationBarTitleDisplayModePlaceholder()
}

public extension View {
    @inlinable
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayModePlaceholder) -> some View {
        self
    }
}

public extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement {
        .navigation
    }

    static var topBarTrailing: ToolbarItemPlacement {
        .primaryAction
    }
}

public extension SearchFieldPlacement {
    // NavigationBarDrawerModePlaceholder representation
    struct NavigationBarDrawerModePlaceholder: Sendable, Equatable {
        public static let always = NavigationBarDrawerModePlaceholder()
        public static let automatic = NavigationBarDrawerModePlaceholder()
    }

    // Navigation bar drawer
    static func navigationBarDrawer(displayMode: NavigationBarDrawerModePlaceholder = .automatic) -> SearchFieldPlacement {
        .automatic
    }
}
#endif
