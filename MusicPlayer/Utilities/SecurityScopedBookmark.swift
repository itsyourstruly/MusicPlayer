import Foundation
import os

/// Concurrency-safe manager for creating, resolving, and retaining access to security-scoped URLs on iOS & macOS.
public final class SecurityScopedBookmark: @unchecked Sendable {
    // User defaults key
    private let userDefaultsKey: String = "linkedMusicDirectoryBookmark"
    // File path location
    private var activeSecurityScopedURL: URL?
    private let lock = NSLock()

    public static let shared = SecurityScopedBookmark()

    // Initialize with configured properties
    private init() {}

    /// Returns the currently active linked directory URL, if any.
    public var currentFolderURL: URL? {
        lock.lock()
        // Cleanup upon exiting scope
        defer { lock.unlock() }
        return activeSecurityScopedURL
    }

    /// Saves security-scoped bookmark data for a chosen folder URL.
    public func saveBookmark(for url: URL) -> Bool {
        lock.lock()
        // Cleanup upon exiting scope
        defer { lock.unlock() }
        return saveBookmarkLocked(for: url)
    }

    // Save bookmark locked
    private func saveBookmarkLocked(for url: URL) -> Bool {
        // Ensure we stop accessing any previous directory
        stopAccessingActiveURLLocked()

        // Started accessing
        let startedAccessing = url.startAccessingSecurityScopedResource()

        do {
            #if os(macOS)
            // Options
            let options: URL.BookmarkCreationOptions = .withSecurityScope
            #else
            // Options
            let options: URL.BookmarkCreationOptions = []
            #endif

            // Bookmark data
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
        // Cleanup upon exiting scope
        defer { lock.unlock() }

        // If we already have an active URL, ensure active access and check disk existence
        if let active = activeSecurityScopedURL {
            _ = active.startAccessingSecurityScopedResource()
            if FileManager.default.fileExists(atPath: active.path) {
                return active
            } else {
                active.stopAccessingSecurityScopedResource()
                self.activeSecurityScopedURL = nil
            }
        }

        // Ensure preconditions are met before proceeding
        guard let bookmarkData = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }

        // Flag indicating if stale
        var isStale = false
        do {
            #if os(macOS)
            // Resolution options
            let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            // Resolution options
            let resolutionOptions: URL.BookmarkResolutionOptions = .withoutUI
            #endif

            // File system location for resolved url
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
        // Fm
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

        // File name
        let fileName = fileURL.lastPathComponent

        // Case A: Direct child of folder
        let directCandidate = folderURL.appendingPathComponent(fileName)
        if fm.fileExists(atPath: directCandidate.path) {
            return directCandidate
        }

        // Case B: Subpath relative to folder name using path components
        let folderComponents = folderURL.pathComponents
        // File components
        let fileComponents = fileURL.pathComponents

        if let folderName = folderComponents.last,
           // Index in file
           let indexInFile = fileComponents.firstIndex(of: folderName),
           indexInFile + 1 < fileComponents.count {
            // Sub components
            let subComponents = fileComponents[(indexInFile + 1)...]
            // Candidate
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
        // File system location for original path
        let originalPath = fileURL.path
        if let range = originalPath.range(of: "/\(folderName)/") {
            // Relative subpath
            let relativeSubpath = String(originalPath[range.upperBound...])
            // Candidate
            let candidate = folderURL.appendingPathComponent(relativeSubpath)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Case D: Shallow search in immediate subdirectories of the linked folder
        if let subdirs = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in subdirs {
                // Candidate
                let candidate = dir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                // Check 1 level deeper (e.g. Artist/Album/Song.mp3)
                if let deepDirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for deepDir in deepDirs {
                        // Deep candidate
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
        // File system location for root url
        let rootURL = resolveAndAccessBookmark()
        // Did start
        let didStart = rootURL?.startAccessingSecurityScopedResource() ?? false
        // Cleanup upon exiting scope
        defer {
            if didStart, let root = rootURL {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    /// Executes an asynchronous operation with guaranteed security-scoped resource access, properly closing access on exit.
    public func withSecurityScopedAccessAsync<T>(_ operation: () async throws -> T) async rethrows -> T {
        // File system location for root url
        let rootURL = resolveAndAccessBookmark()
        // Did start
        let didStart = rootURL?.startAccessingSecurityScopedResource() ?? false
        // Cleanup upon exiting scope
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
        // Cleanup upon exiting scope
        defer { lock.unlock() }
        stopAccessingActiveURLLocked()
    }

    // Stop accessing active url locked
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
        // Cleanup upon exiting scope
        defer { lock.unlock() }

        stopAccessingActiveURLLocked()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        AppLogger.storage.info("Cleared security-scoped bookmark.")
    }
}
