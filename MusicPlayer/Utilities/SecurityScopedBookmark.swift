//
//  SecurityScopedBookmark.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/24/26.
//

import Foundation
import os

/// Concurrency-safe manager for creating, resolving, and retaining access to security-scoped URLs on iOS & macOS.
public final class SecurityScopedBookmark: @unchecked Sendable {
    private let userDefaultsKey: String = "linkedMusicDirectoryBookmark"
    private var activeSecurityScopedURL: URL?
    private let lock = NSLock()

    public static let shared = SecurityScopedBookmark()

    private init() {}

    /// Returns the currently active linked directory URL, if any.
    public var currentFolderURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return activeSecurityScopedURL
    }

    /// Saves security-scoped bookmark data for a chosen folder URL.
    public func saveBookmark(for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveBookmarkLocked(for: url)
    }

    private func saveBookmarkLocked(for url: URL) -> Bool {
        // Ensure we stop accessing any previous directory
        stopAccessingActiveURLLocked()

        let startedAccessing = url.startAccessingSecurityScopedResource()

        do {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            let options: URL.BookmarkCreationOptions = []
            #endif

            let bookmarkData = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            UserDefaults.standard.set(bookmarkData, forKey: userDefaultsKey)
            self.activeSecurityScopedURL = url
            AppLogger.storage.info("Successfully persisted security-scoped bookmark for \(url.lastPathComponent)")
            return true
        } catch {
            AppLogger.storage.error("Error creating bookmark data: \(error.localizedDescription)")
            if startedAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            return false
        }
    }

    /// Resolves the persisted bookmark data and starts accessing the directory if not already active.
    public func resolveAndAccessBookmark() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        // If we already have an active URL that exists on disk, reuse it without leaking startAccessing tokens
        if let active = activeSecurityScopedURL {
            if FileManager.default.fileExists(atPath: active.path) {
                return active
            } else {
                active.stopAccessingSecurityScopedResource()
                self.activeSecurityScopedURL = nil
            }
        }

        guard let bookmarkData = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }

        var isStale = false
        do {
            #if os(macOS)
            let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let resolutionOptions: URL.BookmarkResolutionOptions = .withoutUI
            #endif

            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                AppLogger.storage.warning("Security-scoped bookmark is stale. Re-saving bookmark.")
                _ = saveBookmarkLocked(for: resolvedURL)
            }

            _ = resolvedURL.startAccessingSecurityScopedResource()
            self.activeSecurityScopedURL = resolvedURL
            AppLogger.storage.info("Resolved & accessed security-scoped folder: \(resolvedURL.path)")
            return resolvedURL
        } catch {
            AppLogger.storage.error("Failed to resolve bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Dynamically resolves a track's file URL into a valid, reachable URL on the current file system.
    /// Handles sandbox container UUID shifts and relocated linked folders across launches.
    public func resolveAccessibleURL(for fileURL: URL) -> URL {
        let fm = FileManager.default

        // 1. Ensure security-scoped root directory is actively accessed
        let rootFolderURL = resolveAndAccessBookmark()

        // 2. Direct path check
        if fm.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        // 3. Resolve against active security-scoped root directory
        guard let folderURL = rootFolderURL else {
            return fileURL
        }

        let fileName = fileURL.lastPathComponent

        // Case A: Direct child of folder
        let directCandidate = folderURL.appendingPathComponent(fileName)
        if fm.fileExists(atPath: directCandidate.path) {
            return directCandidate
        }

        // Case B: Subpath relative to folder name using path components
        let folderComponents = folderURL.pathComponents
        let fileComponents = fileURL.pathComponents

        if let folderName = folderComponents.last,
           let indexInFile = fileComponents.firstIndex(of: folderName),
           indexInFile + 1 < fileComponents.count {
            let subComponents = fileComponents[(indexInFile + 1)...]
            var candidate = folderURL
            for comp in subComponents {
                candidate.appendPathComponent(comp)
            }
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Case C: Subpath matching original string pattern
        let folderName = folderURL.lastPathComponent
        let originalPath = fileURL.path
        if let range = originalPath.range(of: "/\(folderName)/") {
            let relativeSubpath = String(originalPath[range.upperBound...])
            let candidate = folderURL.appendingPathComponent(relativeSubpath)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Case D: Shallow search in immediate subdirectories of the linked folder
        if let subdirs = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in subdirs {
                let candidate = dir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                // Check 1 level deeper (e.g. Artist/Album/Song.mp3)
                if let deepDirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for deepDir in deepDirs {
                        let deepCandidate = deepDir.appendingPathComponent(fileName)
                        if fm.fileExists(atPath: deepCandidate.path) {
                            return deepCandidate
                        }
                    }
                }
            }
        }

        return fileURL
    }

    /// Executes a synchronous operation with guaranteed security-scoped resource access, properly closing access on exit.
    public func withSecurityScopedAccess<T>(_ operation: () throws -> T) rethrows -> T {
        let rootURL = resolveAndAccessBookmark()
        let didStart = rootURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStart, let root = rootURL {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    /// Executes an asynchronous operation with guaranteed security-scoped resource access, properly closing access on exit.
    public func withSecurityScopedAccessAsync<T>(_ operation: () async throws -> T) async rethrows -> T {
        let rootURL = resolveAndAccessBookmark()
        let didStart = rootURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStart, let root = rootURL {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    /// Releases security scoped access if currently active.
    public func stopAccessingActiveURL() {
        lock.lock()
        defer { lock.unlock() }
        stopAccessingActiveURLLocked()
    }

    private func stopAccessingActiveURLLocked() {
        if let active = activeSecurityScopedURL {
            active.stopAccessingSecurityScopedResource()
            activeSecurityScopedURL = nil
            AppLogger.storage.info("Stopped accessing active security-scoped resource.")
        }
    }

    /// Clears the saved bookmark from UserDefaults.
    public func clearSavedBookmark() {
        lock.lock()
        defer { lock.unlock() }

        stopAccessingActiveURLLocked()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        AppLogger.storage.info("Cleared security-scoped bookmark.")
    }
}
