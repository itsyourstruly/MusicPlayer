//
//  FinderUtility.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/26/26.
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Concurrency-safe macOS desktop utility for interacting with the Finder and file manager.
@MainActor
public enum FinderUtility {
    /// Reveals a specific file or directory in the macOS Finder.
    /// If the file does not exist directly, resolves through security-scoped root or parent folder.
    public static func revealInFinder(url: URL) {
        #if os(macOS)
        let resolved = SecurityScopedBookmark.shared.resolveAccessibleURL(for: url)
        let fm = FileManager.default

        if fm.fileExists(atPath: resolved.path) {
            NSWorkspace.shared.activateFileViewerSelecting([resolved])
            AppLogger.storage.info("Revealed file in Finder: \(resolved.path)")
        } else {
            let parent = resolved.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
                AppLogger.storage.info("Opened parent directory in Finder: \(parent.path)")
            } else if let root = SecurityScopedBookmark.shared.currentFolderURL {
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
