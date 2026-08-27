import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Concurrency-safe tactile feedback utility.
@MainActor
public enum HapticFeedback {
    /// Generates light impact feedback for taps and state transitions.
    public static func lightImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Generates medium impact feedback for snap-to-expand / snap-to-minimize gestures.
    public static func mediumImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Generates rigid impact feedback for mode toggles.
    public static func rigidImpact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }

    /// Generates selection change feedback for track skipping or scrubbing.
    public static func selectionChanged() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Generates success notification feedback.
    public static func notificationSuccess() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Generates warning notification feedback.
    public static func notificationWarning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}

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

    // Album context menu
    func albumContextMenu(album: Album, libraryStore: LibraryStore, playerService: AudioPlayerService) -> some View {
        modifier(AlbumContextMenuModifier(album: album, libraryStore: libraryStore, playerService: playerService))
    }
}

/// Universal context menu for albums across the application (PIN, PLAY, SHUFFLE, PLAY NEXT, QUEUE NEXT without icons).
public struct AlbumContextMenuModifier: ViewModifier {
    // Album title
    public let album: Album
    // Library store
    public let libraryStore: LibraryStore
    // Player service
    public let playerService: AudioPlayerService

    // Body
    public func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: {
                    HapticFeedback.lightImpact()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        libraryStore.togglePinAlbum(album)
                    }
                }) {
                    Text(libraryStore.isAlbumPinned(album) ? "UNPIN" : "PIN")
                }

                Button(action: {
                    if let first = album.tracks.first {
                        playerService.play(track: first, inQueue: album.tracks)
                    }
                }) {
                    Text("PLAY")
                }

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
                    playerService.insertPlayNextFront(tracks: album.tracks)
                }) {
                    Text("PLAY NEXT")
                }

                Button(action: {
                    playerService.playNext(tracks: album.tracks)
                }) {
                    Text("QUEUE NEXT")
                }
            }
    }
}

// MARK: - Universal Keyboard Drag-to-Dismiss Helper

public extension View {
    /// Allows dragging down anywhere on the view or dragging the scroll content to dismiss the software keyboard.
    func dismissKeyboardOnDrag() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            #if canImport(UIKit)
            // Interactive drag and touch gesture handling
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .local)
                    .onChanged { value in
                        if value.translation.height > 20 {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
            )
            #endif
    }
}

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
