import Foundation
import os

/// Concurrency-safe manager for creating, resolving, and retaining access to security-scoped URLs on iOS & macOS.
public final class SecurityScopedBookmark: @unchecked Sendable {
    // User defaults key
    private let userDefaultsKey: String = "linkedMusicDirectoryBookmark"
    private let multiBookmarksKey: String = "linkedMusicDirectoryBookmarksMap"

    // File path location
    private var activeSecurityScopedURL: URL?
    private var isAccessActive: Bool = false
    private var activeFolders: [UUID: (url: URL, isAccessActive: Bool)] = [:]
    private var resolvedURLCache: [URL: URL] = [:]
    private let lock = NSLock()

    public static let shared = SecurityScopedBookmark()

    // Initialize with configured properties
    private init() {}

    /// Returns the currently active linked directory URL, if any.
    public var currentFolderURL: URL? {
        lock.lock()
        // Cleanup upon exiting scope
        defer { lock.unlock() }
        return activeSecurityScopedURL ?? activeFolders.values.first?.url
    }

    /// Returns all currently active folder URLs.
    public var allActiveFolderURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        var urls: [URL] = []
        if let primary = activeSecurityScopedURL {
            urls.append(primary)
        }
        for (_, entry) in activeFolders {
            if !urls.contains(where: { $0.path == entry.url.path }) {
                urls.append(entry.url)
            }
        }
        return urls
    }

    /// Returns active URL for a specific folder ID.
    public func url(for folderID: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return activeFolders[folderID]?.url
    }

    /// Saves security-scoped bookmark data for a chosen folder URL (legacy single folder).
    public func saveBookmark(for url: URL) -> Bool {
        lock.lock()
        // Cleanup upon exiting scope
        defer { lock.unlock() }
        return saveBookmarkLocked(for: url)
    }

    /// Saves security-scoped bookmark data for a specific folder entity and returns the created bookmark data.
    public func saveBookmark(for url: URL, folderID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        // Stop accessing any previous resource for this folderID
        if let existing = activeFolders[folderID], existing.isAccessActive {
            existing.url.stopAccessingSecurityScopedResource()
        }

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

            activeFolders[folderID] = (url: url, isAccessActive: startedAccessing)
            self.activeSecurityScopedURL = url
            self.isAccessActive = startedAccessing

            // Save in map and primary key
            var map = UserDefaults.standard.dictionary(forKey: multiBookmarksKey) as? [String: Data] ?? [:]
            map[folderID.uuidString] = bookmarkData
            UserDefaults.standard.set(map, forKey: multiBookmarksKey)
            UserDefaults.standard.set(bookmarkData, forKey: userDefaultsKey)

            AppLogger.storage.info("Successfully persisted security-scoped bookmark for folder \(folderID) (\(url.lastPathComponent))")
            return bookmarkData
        } catch {
            AppLogger.storage.error("Error creating bookmark data for folder \(folderID): \(error.localizedDescription)")
            if startedAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            return nil
        }
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
            self.isAccessActive = startedAccessing
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

    /// Resolves bookmark data for a specific folder and begins security access.
    public func resolveAndAccessBookmark(folderID: UUID, bookmarkData: Data?) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = activeFolders[folderID], existing.isAccessActive {
            return existing.url
        }

        let map = UserDefaults.standard.dictionary(forKey: multiBookmarksKey) as? [String: Data]
        guard let data = bookmarkData ?? map?[folderID.uuidString] ?? UserDefaults.standard.data(forKey: userDefaultsKey) else {
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
                resolvingBookmarkData: data,
                options: resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            let didAccess = resolvedURL.startAccessingSecurityScopedResource()
            activeFolders[folderID] = (url: resolvedURL, isAccessActive: didAccess)
            if self.activeSecurityScopedURL == nil {
                self.activeSecurityScopedURL = resolvedURL
                self.isAccessActive = didAccess
            }
            AppLogger.storage.info("Resolved & accessed security-scoped folder [\(folderID)]: \(resolvedURL.path)")
            return resolvedURL
        } catch {
            AppLogger.storage.error("Failed to resolve bookmark for folder [\(folderID)]: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves and accesses all bookmarks for the provided linked folders.
    public func resolveAndAccessAllBookmarks(folders: [LinkedFolder]) {
        for folder in folders {
            _ = resolveAndAccessBookmark(folderID: folder.id, bookmarkData: folder.bookmarkData)
        }
    }

    /// Stops accessing and removes tracking for a specific folder.
    public func stopAccessing(folderID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if let entry = activeFolders.removeValue(forKey: folderID) {
            if entry.isAccessActive {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
        var map = UserDefaults.standard.dictionary(forKey: multiBookmarksKey) as? [String: Data] ?? [:]
        map.removeValue(forKey: folderID.uuidString)
        UserDefaults.standard.set(map, forKey: multiBookmarksKey)

        if activeSecurityScopedURL?.path == activeFolders[folderID]?.url.path {
            activeSecurityScopedURL = activeFolders.values.first?.url
        }
    }

    /// Resolves the persisted bookmark data and starts accessing the directory if not already active.
    public func resolveAndAccessBookmark() -> URL? {
        lock.lock()
        // Cleanup upon exiting scope
        defer { lock.unlock() }

        // Fast-path: return immediately if we already hold an active retained security access
        if let active = activeSecurityScopedURL, isAccessActive {
            return active
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

            let didAccess = resolvedURL.startAccessingSecurityScopedResource()
            self.activeSecurityScopedURL = resolvedURL
            self.isAccessActive = didAccess
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
        // Fast-path: Check in-memory cache first (zero disk I/O)
        lock.lock()
        if let cached = resolvedURLCache[fileURL] {
            lock.unlock()
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
        } else {
            lock.unlock()
        }

        let fm = FileManager.default

        // 1. Direct path check first
        if fm.fileExists(atPath: fileURL.path) {
            lock.lock()
            resolvedURLCache[fileURL] = fileURL
            lock.unlock()
            return fileURL
        }

        // 2. Ensure security-scoped root directories are actively accessed
        var candidateRoots = allActiveFolderURLs
        if candidateRoots.isEmpty, let root = currentFolderURL ?? resolveAndAccessBookmark() {
            candidateRoots.append(root)
        }

        guard !candidateRoots.isEmpty else {
            return fileURL
        }

        let fileName = fileURL.lastPathComponent
        let fileComponents = fileURL.pathComponents
        let originalPath = fileURL.path

        for folderURL in candidateRoots {
            // Case A: Direct child of folder
            let directCandidate = folderURL.appendingPathComponent(fileName)
            if fm.fileExists(atPath: directCandidate.path) {
                lock.lock()
                resolvedURLCache[fileURL] = directCandidate
                lock.unlock()
                return directCandidate
            }

            // Case B: Subpath relative to folder name using path components
            let folderComponents = folderURL.pathComponents
            if let folderName = folderComponents.last,
               let indexInFile = fileComponents.firstIndex(of: folderName),
               indexInFile + 1 < fileComponents.count {
                let subComponents = fileComponents[(indexInFile + 1)...]
                var candidate = folderURL
                for comp in subComponents {
                    candidate.appendPathComponent(comp)
                }
                if fm.fileExists(atPath: candidate.path) {
                    lock.lock()
                    resolvedURLCache[fileURL] = candidate
                    lock.unlock()
                    return candidate
                }
            }

            // Case C: Subpath matching original string pattern
            let folderName = folderURL.lastPathComponent
            if let range = originalPath.range(of: "/\(folderName)/") {
                let relativeSubpath = String(originalPath[range.upperBound...])
                let candidate = folderURL.appendingPathComponent(relativeSubpath)
                if fm.fileExists(atPath: candidate.path) {
                    lock.lock()
                    resolvedURLCache[fileURL] = candidate
                    lock.unlock()
                    return candidate
                }
            }

            // Case D: Shallow search in immediate subdirectories of the linked folder
            if let subdirs = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for dir in subdirs {
                    let candidate = dir.appendingPathComponent(fileName)
                    if fm.fileExists(atPath: candidate.path) {
                        lock.lock()
                        resolvedURLCache[fileURL] = candidate
                        lock.unlock()
                        return candidate
                    }
                    if let deepDirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        for deepDir in deepDirs {
                            let deepCandidate = deepDir.appendingPathComponent(fileName)
                            if fm.fileExists(atPath: deepCandidate.path) {
                                lock.lock()
                                resolvedURLCache[fileURL] = deepCandidate
                                lock.unlock()
                                return deepCandidate
                            }
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
        resolvedURLCache.removeAll()
        if let active = activeSecurityScopedURL {
            if isAccessActive {
                active.stopAccessingSecurityScopedResource()
            }
            activeSecurityScopedURL = nil
            isAccessActive = false
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
