import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Concurrency-safe macOS desktop utility for interacting with the Finder and file manager.
///
/// Confined to `@MainActor` because `NSWorkspace` must be called from the main thread.
@MainActor
public enum FinderUtility {

    // MARK: - Finder Reveal

    /// Reveals a specific file or directory in the macOS Finder.
    ///
    /// Falls back gracefully: tries the direct path first, then the parent folder,
    /// then the linked music root — so the user always ends up somewhere useful.
    public static func revealInFinder(url: URL) {
        #if os(macOS)
        // Resolve through the bookmark manager in case the path has a stale sandbox container UUID
        let resolved = SecurityScopedBookmark.shared.resolveAccessibleURL(for: url)
        // Fm
        let fm = FileManager.default

        if fm.fileExists(atPath: resolved.path) {
            NSWorkspace.shared.activateFileViewerSelecting([resolved])
            AppLogger.storage.info("Revealed file in Finder: \(resolved.path)")
        } else {
            // File was moved or deleted — open the containing folder instead
            let parent = resolved.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
                AppLogger.storage.info("Opened parent directory in Finder: \(parent.path)")
            } else if let root = SecurityScopedBookmark.shared.currentFolderURL {
                // Last resort: open the root music directory the user originally linked
                NSWorkspace.shared.open(root)
                AppLogger.storage.info("Opened root music directory in Finder: \(root.path)")
            } else {
                AppLogger.storage.warning("Cannot reveal path in Finder; file does not exist: \(url.path)")
            }
        }
        #endif
    }

    /// Opens a folder in Finder.
    public static func openFolderInFinder(url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}
