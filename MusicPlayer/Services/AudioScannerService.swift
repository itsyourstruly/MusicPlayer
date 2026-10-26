import Foundation
import AVFoundation
import CoreMedia
import os

/// Fast filesystem audio file stat record obtained during directory enumeration.
public struct AudioFileStat: Sendable {
    public let url: URL
    public let size: Int64
    public let modificationDate: Date?
    public let creationDate: Date?

    public init(url: URL, size: Int64, modificationDate: Date?, creationDate: Date?) {
        self.url = url
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
    }
}

/// Thread-safe artwork key deduplicator to prevent worker threads from queueing duplicate writes
public final class ArtworkKeyDeduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()

    public init() {}

    public func shouldStore(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(key).inserted
    }
}

/// High-throughput concurrency-safe audio scanner that traverses directories in parallel,
/// extracts rich ID3/QuickTime/Vorbis/FLAC metadata with single-shot AVURLAsset batch loading,
/// directory & filename heuristic fallbacks, and non-blocking background artwork caching.
public struct AudioScannerService: Sendable {
    public static let shared = AudioScannerService()

    // Supported extensions
    private let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "m4r", "mp4", "mpeg", "mpg", "mp2", "mpa",
        "aac", "flac", "wav", "wave", "aiff", "aif", "aifc", "caf", "alac",
        "ogg", "oga", "opus", "3gp", "wma"
    ]

    private static let commonArtworkFilenames: [String] = [
        "cover.jpg", "Cover.jpg", "COVER.JPG",
        "cover.png", "Cover.png", "COVER.PNG",
        "cover.jpeg", "Cover.jpeg", "COVER.JPEG",
        "folder.jpg", "Folder.jpg", "FOLDER.JPG",
        "folder.png", "Folder.png", "FOLDER.PNG",
        "folder.jpeg", "Folder.jpeg", "FOLDER.JPEG",
        "album.jpg", "Album.jpg", "ALBUM.JPG",
        "album.png", "Album.png", "ALBUM.PNG",
        "front.jpg", "Front.jpg", "FRONT.JPG",
        "front.png", "Front.png", "FRONT.PNG",
        "artwork.jpg", "Artwork.jpg", "ARTWORK.JPG",
        "artwork.png", "Artwork.png", "ARTWORK.PNG"
    ]
    private static let folderArtworkCache = NSCache<NSURL, NSData>()
    private static let discRegex = try? NSRegularExpression(pattern: #"^(?:cd|disc|disk)\s*(\d+)$"#, options: .caseInsensitive)

    /// Scans the folder containing the audio file (and grandparent if inside a CD/Disc subfolder) for cover images.
    private func findFolderArtwork(for fileURL: URL) -> Data? {
        let parentDir = fileURL.deletingLastPathComponent()
        if let cached = Self.folderArtworkCache.object(forKey: parentDir as NSURL) {
            return cached as Data
        }

        let fm = FileManager.default

        // Check parent directory
        for artName in Self.commonArtworkFilenames {
            let artURL = parentDir.appendingPathComponent(artName)
            if CloudFileAvailability.isLocal(url: artURL),
               fm.fileExists(atPath: artURL.path),
               let data = try? Data(contentsOf: artURL), !data.isEmpty {
                Self.folderArtworkCache.setObject(data as NSData, forKey: parentDir as NSURL)
                return data
            }
        }

        // If parent is a CD/Disc directory, check grandparent (the actual album directory)
        let parentName = parentDir.lastPathComponent
        if let regex = Self.discRegex,
           regex.firstMatch(in: parentName, options: [], range: NSRange(location: 0, length: parentName.utf16.count)) != nil {
            let grandParentDir = parentDir.deletingLastPathComponent()
            if let cached = Self.folderArtworkCache.object(forKey: grandParentDir as NSURL) {
                return cached as Data
            }

            for artName in Self.commonArtworkFilenames {
                let artURL = grandParentDir.appendingPathComponent(artName)
                if CloudFileAvailability.isLocal(url: artURL),
                   fm.fileExists(atPath: artURL.path),
                   let data = try? Data(contentsOf: artURL), !data.isEmpty {
                    Self.folderArtworkCache.setObject(data as NSData, forKey: parentDir as NSURL)
                    Self.folderArtworkCache.setObject(data as NSData, forKey: grandParentDir as NSURL)
                    return data
                }
            }
        }

        return nil
    }

    private func isAudioFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "icloud" {
            let filename = url.lastPathComponent
            let parts = filename.split(separator: ".")
            if parts.count >= 2 {
                let realExt = String(parts[parts.count - 2]).lowercased()
                return supportedExtensions.contains(realExt)
            }
            return false
        }
        return supportedExtensions.contains(ext)
    }

    private func isHiddenNonICloud(url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") {
            if name.hasSuffix(".icloud") {
                return false
            }
            return true
        }
        return false
    }

    // Initialize with configured properties
    public init() {}

    /// Scans a directory URL recursively in parallel with smart differential caching and returns parsed Track objects.
    public func scanDirectory(
        at folderURL: URL,
        folderID: UUID? = nil,
        existingTracks: [Track] = [],
        scanMethod: LibraryScanMethod = .id3Tags,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> [Track] {
        AppLogger.scanner.info("Starting high-speed audio scan at: \(folderURL.path) (with \(existingTracks.count) cached tracks)")

        // Ensure security-scoped root folder access is active
        _ = await SecurityScopedBookmark.shared.resolveAndAccessBookmark()

        // Build fast path-based lookup map for differential scan
        var existingTrackMap: [String: Track] = [:]
        existingTrackMap.reserveCapacity(existingTracks.count * 4)
        for track in existingTracks {
            let stdPath = track.url.standardizedFileURL.path
            existingTrackMap[stdPath] = track
            existingTrackMap[stdPath.lowercased()] = track
            let rawPath = track.url.path
            existingTrackMap[rawPath] = track
            existingTrackMap[rawPath.lowercased()] = track
        }

        let fileManager = FileManager.default
        var audioFiles: [AudioFileStat] = []
        audioFiles.reserveCapacity(min(existingTracks.count + 500, 50_000))
        var seenAudioFilePaths = Set<String>()
        var visitedDirectories = Set<String>()
        var isDir: ObjCBool = false

        let rootPath = folderURL.standardizedFileURL.path
        visitedDirectories.insert(rootPath)
        visitedDirectories.insert(folderURL.path)

        if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                // User linked a single audio file directly
                if isAudioFile(url: folderURL) {
                    let res = try? folderURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                    let size = Int64(res?.fileSize ?? 0)
                    audioFiles.append(AudioFileStat(
                        url: folderURL,
                        size: size,
                        modificationDate: res?.contentModificationDate,
                        creationDate: res?.creationDate
                    ))
                }
            } else {
                // Recursive directory enumeration with cycle & symlink loop protection
                if let enumerator = fileManager.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey
                    ],
                    options: [.skipsPackageDescendants]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        // Safety ceiling to prevent runaway allocations on corrupted filesystems
                        if audioFiles.count >= 200_000 {
                            AppLogger.scanner.warning("Reached safety limit of 200,000 files during scanning.")
                            break
                        }

                        if isHiddenNonICloud(url: fileURL) {
                            if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                                enumerator.skipDescendants()
                            }
                            continue
                        }

                        // Cycle detection for directories & symbolic links (only resolve symlinks if actually a symlink)
                        if let res = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                            if res.isSymbolicLink == true {
                                let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                                if visitedDirectories.contains(canonical) {
                                    enumerator.skipDescendants()
                                    continue
                                }
                                visitedDirectories.insert(canonical)
                            } else if res.isDirectory == true {
                                let dirPath = fileURL.standardizedFileURL.path
                                if visitedDirectories.contains(dirPath) {
                                    enumerator.skipDescendants()
                                    continue
                                }
                                visitedDirectories.insert(dirPath)
                            }
                        }

                        if isAudioFile(url: fileURL) {
                            let path = fileURL.standardizedFileURL.path
                            if seenAudioFilePaths.insert(path).inserted {
                                let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                                let size = Int64(res?.fileSize ?? 0)
                                audioFiles.append(AudioFileStat(
                                    url: fileURL,
                                    size: size,
                                    modificationDate: res?.contentModificationDate,
                                    creationDate: res?.creationDate
                                ))
                            }
                        }
                    }
                }

                // Fallback shallow directory scan if enumerator yielded no files
                if audioFiles.isEmpty {
                    if let directContents = try? fileManager.contentsOfDirectory(
                        at: folderURL,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for fileURL in directContents {
                            let ext = fileURL.pathExtension.lowercased()
                            if supportedExtensions.contains(ext) {
                                let path = fileURL.standardizedFileURL.path
                                if seenAudioFilePaths.insert(path).inserted {
                                    let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                                    let size = Int64(res?.fileSize ?? 0)
                                    audioFiles.append(AudioFileStat(
                                        url: fileURL,
                                        size: size,
                                        modificationDate: res?.contentModificationDate,
                                        creationDate: res?.creationDate
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        let totalFiles = audioFiles.count
        AppLogger.scanner.info("Found \(totalFiles) unique audio files to evaluate.")

        // MARK: - Smart Differential Partitioning
        var scannedTracks: [Track] = []
        scannedTracks.reserveCapacity(min(totalFiles, 50_000))
        var filesNeedingParsing: [AudioFileStat] = []
        filesNeedingParsing.reserveCapacity(min(totalFiles, 50_000))

        for fileStat in audioFiles {
            let stdPath = fileStat.url.standardizedFileURL.path
            let cachedTrack = existingTrackMap[stdPath] ?? existingTrackMap[stdPath.lowercased()] ?? existingTrackMap[fileStat.url.path]

            if !CloudFileAvailability.isLocal(url: fileStat.url) {
                // If cloud-only file is already in cache with real tags, keep it!
                if let cached = cachedTrack, cached.tagSnapshot != nil || cached.metadataSource == .embeddedTags {
                    scannedTracks.append(cached)
                    continue
                }
            } else if let cached = cachedTrack, !(cached.metadataSource == .folderStructure && cached.tagSnapshot != nil) {
                // (Legacy folder-scanned tracks stored folder values as their tag snapshot; re-parse them once.)
                let cachedSize = cached.fileInfo?.fileSizeBytes ?? 0
                let currentSize = fileStat.size

                if cachedSize > 0 && currentSize == cachedSize {
                    // Check modification dates if both exist
                    if let cachedMod = cached.fileInfo?.modificationDate, let curMod = fileStat.modificationDate {
                        if abs(cachedMod.timeIntervalSince(curMod)) < 2.0 {
                            scannedTracks.append(cached)
                            continue
                        }
                    } else {
                        // File size matches and is non-zero
                        scannedTracks.append(cached)
                        continue
                    }
                }
            }
            filesNeedingParsing.append(fileStat)
        }

        let reusedCount = scannedTracks.count
        let toParseCount = filesNeedingParsing.count
        AppLogger.scanner.info("[Differential Scan] Reused \(reusedCount) unmodified tracks instantly. Parsing \(toParseCount) new/modified files.")

        // Initial progress yield for reused files
        if totalFiles > 0 {
            onProgress?(reusedCount, totalFiles, "Indexed \(reusedCount) existing files...")
        }

        // MARK: - High-Throughput Streaming TaskGroup Worker Pool
        if !filesNeedingParsing.isEmpty {
            let maxConcurrentWorkers = 4
            let artworkDeduplicator = ArtworkKeyDeduplicator()
            var scannedNewTracks: [Track] = []
            scannedNewTracks.reserveCapacity(toParseCount)

            await withTaskGroup(of: Track?.self) { group in
                var nextIndex = 0
                let initialBatch = min(maxConcurrentWorkers * 2, toParseCount)

                // Seed initial workers
                while nextIndex < initialBatch {
                    let fileStat = filesNeedingParsing[nextIndex]
                    nextIndex += 1
                    group.addTask(priority: .userInitiated) {
                        if scanMethod == .folderHierarchy {
                            return await FolderHierarchyScanner.shared.parseAudioTrack(at: fileStat.url, rootFolderURL: folderURL, knownStat: fileStat, artworkDeduplicator: artworkDeduplicator)
                        } else {
                            return await self.parseAudioTrack(at: fileStat.url, folderID: folderID, rootFolderURL: folderURL, knownStat: fileStat, artworkDeduplicator: artworkDeduplicator)
                        }
                    }
                }

                var processedNewCount = 0
                var lastReportedTime = Date.distantPast

                for await track in group {
                    processedNewCount += 1
                    if let track = track {
                        scannedNewTracks.append(track)
                    }

                    // Feed next task immediately into the continuous pool
                    if nextIndex < toParseCount {
                        let fileStat = filesNeedingParsing[nextIndex]
                        nextIndex += 1
                        group.addTask(priority: .userInitiated) {
                            if scanMethod == .folderHierarchy {
                                return await FolderHierarchyScanner.shared.parseAudioTrack(at: fileStat.url, rootFolderURL: folderURL, knownStat: fileStat, artworkDeduplicator: artworkDeduplicator)
                            } else {
                                return await self.parseAudioTrack(at: fileStat.url, folderID: folderID, rootFolderURL: folderURL, knownStat: fileStat, artworkDeduplicator: artworkDeduplicator)
                            }
                        }
                    }

                    let totalProgress = reusedCount + processedNewCount
                    let now = Date()
                    if now.timeIntervalSince(lastReportedTime) >= 0.1 || totalProgress == totalFiles {
                        lastReportedTime = now
                        let currentName = track?.title ?? "Processing..."
                        onProgress?(totalProgress, totalFiles, currentName)
                    }
                }
            }

            scannedTracks.append(contentsOf: scannedNewTracks)
        }

        AppLogger.scanner.info("Completed scan. Total indexed: \(scannedTracks.count) tracks (\(reusedCount) reused, \(toParseCount) parsed).")
        return scannedTracks
    }

    /// Parses an audio file with pure-Swift binary extraction and lightweight fallback.
    public func parseAudioTrack(
        at url: URL,
        folderID: UUID? = nil,
        rootFolderURL: URL? = nil,
        knownStat: AudioFileStat? = nil,
        artworkDeduplicator: ArtworkKeyDeduplicator? = nil
    ) async -> Track? {
        let relativePath = TrackIdentity.computeRelativePath(fileURL: url, folderURL: rootFolderURL)
        let trackID = TrackIdentity.localTrackID(folderID: folderID, relativePath: relativePath)

        if !CloudFileAvailability.isLocal(url: url) {
            let cleanRelPath: String = {
                if url.pathExtension.lowercased() == "icloud" {
                    var c = relativePath
                    if c.hasSuffix(".icloud") { c = String(c.dropLast(7)) }
                    let comp = c.components(separatedBy: "/")
                    let last = comp.last ?? ""
                    var cleanLast = last
                    while cleanLast.hasPrefix("._") || cleanLast.hasPrefix(".") {
                        if cleanLast.hasPrefix("._") { cleanLast = String(cleanLast.dropFirst(2)) }
                        else if cleanLast.hasPrefix(".") { cleanLast = String(cleanLast.dropFirst(1)) }
                    }
                    var prefix = comp.dropLast().joined(separator: "/")
                    if !prefix.isEmpty { prefix += "/" }
                    return prefix + cleanLast
                }
                return relativePath
            }()
            let parsed = FolderPathMetadataParser.parse(relativePath: cleanRelPath)
            return Track(
                id: trackID,
                title: parsed.title,
                artist: parsed.artist,
                album: parsed.album,
                albumArtist: parsed.albumArtist,
                year: parsed.year,
                trackNumber: parsed.trackNumber,
                discNumber: parsed.discNumber,
                duration: 0,
                url: url,
                dateAdded: knownStat?.creationDate ?? Date(),
                folderID: folderID,
                relativePath: relativePath,
                metadataSource: .folderStructure,
                tagSnapshot: nil
            )
        }

        let isFileAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isFileAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Read file system attributes
        var fileSizeBytes: Int64 = knownStat?.size ?? 0
        var creationDate: Date? = knownStat?.creationDate
        var modificationDate: Date? = knownStat?.modificationDate

        if fileSizeBytes <= 0 {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                creationDate = attributes[.creationDate] as? Date
                modificationDate = attributes[.modificationDate] as? Date
            }
        }

        // MARK: - 1. Pure-Swift In-Process Direct Binary Metadata Extraction (<0.2ms per file)
        var parsedMeta = FastAudioMetadataReader.readMetadata(for: url, knownFileSize: fileSizeBytes > 0 ? fileSizeBytes : nil)

        // 2. Fallback to AVURLAsset ONLY if binary reader returned nil (unsupported container) or duration could not be determined
        if parsedMeta == nil || (parsedMeta?.duration ?? 0) <= 0 {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            var durationSeconds: TimeInterval = 0
            var allMetadata: [AVMetadataItem] = []

            if let (cmDuration, commonMeta, genericMeta) = try? await asset.load(.duration, .commonMetadata, .metadata) {
                let secs = CMTimeGetSeconds(cmDuration)
                if !secs.isNaN && !secs.isInfinite && secs > 0 { durationSeconds = secs }
                allMetadata.append(contentsOf: commonMeta)
                allMetadata.append(contentsOf: genericMeta)
            }

            var fallback = ParsedAudioMetadata()
            fallback.duration = durationSeconds > 0 ? durationSeconds : 1.0
            fallback.formatDescription = url.pathExtension.uppercased()

            for item in allMetadata {
                let commonKey = item.commonKey
                let keyLower = (item.keyString ?? (item.key as? String) ?? "").lowercased()
                let idLower = item.identifier?.rawValue.lowercased() ?? ""

                if fallback.title == nil && (commonKey == .commonKeyTitle || keyLower.contains("titl") || keyLower.contains("name") || idLower.contains("titl") || idLower.contains("name")) {
                    fallback.title = await extractString(from: item)
                }
                if fallback.artist == nil && (commonKey == .commonKeyArtist || commonKey == .commonKeyAuthor || keyLower.contains("art") || keyLower.contains("author") || keyLower.contains("auth") || idLower.contains("art") || idLower.contains("author") || idLower.contains("auth")) {
                    let str = await extractString(from: item)
                    if fallback.author == nil && (commonKey == .commonKeyAuthor || keyLower.contains("author") || keyLower.contains("auth") || idLower.contains("author") || idLower.contains("auth")) {
                        fallback.author = str
                    }
                    fallback.artist = str
                }
                if fallback.album == nil && (commonKey == .commonKeyAlbumName || keyLower.contains("alb") || idLower.contains("alb") || keyLower == "talb" || keyLower == "©alb") {
                    fallback.album = await extractString(from: item)
                }
                if fallback.albumArtist == nil && (keyLower.contains("aart") || keyLower.contains("albumartist") || keyLower.contains("album_artist") || keyLower.contains("band") || idLower.contains("aart") || idLower.contains("albumartist") || idLower.contains("band") || commonKey?.rawValue.lowercased().contains("albumartist") == true) {
                    fallback.albumArtist = await extractString(from: item)
                }
                if fallback.year == nil {
                    if let str = await extractString(from: item) {
                        let digits = str.filter { $0.isNumber }
                        if digits.count >= 4, let y = Int(digits.prefix(4)), y >= 1900, y <= 2099 {
                            fallback.year = y
                        }
                    }
                }
                if CloudFileAvailability.isLocal(url: url) && fallback.artworkData == nil && (commonKey == .commonKeyArtwork || keyLower.contains("art") || keyLower.contains("covr") || idLower.contains("art") || idLower.contains("covr") || keyLower.contains("apic")) {
                    fallback.artworkData = await extractArtwork(from: item)
                }
                if fallback.lyrics == nil {
                    if keyLower.contains("lyr") || keyLower.contains("uslt") || keyLower.contains("sylt") || idLower.contains("lyr") {
                        fallback.lyrics = await extractString(from: item)
                    } else if let str = await extractString(from: item), str.count > 50, (str.contains("\n") || str.contains("\r") || str.contains("[0")) {
                        fallback.lyrics = str
                    }
                }
            }

            if var existing = parsedMeta {
                if (existing.artist == nil || isGenericArtist(existing.artist ?? "")) && fallback.artist != nil {
                    existing.artist = fallback.artist
                }
                if (existing.author == nil || isGenericArtist(existing.author ?? "")) && fallback.author != nil {
                    existing.author = fallback.author
                }
                if (existing.title == nil || isGenericTitle(existing.title ?? "")) && fallback.title != nil {
                    existing.title = fallback.title
                }
                if (existing.album == nil || isGenericAlbum(existing.album ?? "")) && fallback.album != nil {
                    existing.album = fallback.album
                }
                if (existing.albumArtist == nil || isGenericArtist(existing.albumArtist ?? "")) && fallback.albumArtist != nil {
                    existing.albumArtist = fallback.albumArtist
                }
                if existing.artworkData == nil && fallback.artworkData != nil {
                    existing.artworkData = fallback.artworkData
                }
                if existing.duration <= 0 && fallback.duration > 0 {
                    existing.duration = fallback.duration
                }
                parsedMeta = existing
            } else {
                parsedMeta = fallback
            }
        }

        var meta = parsedMeta ?? ParsedAudioMetadata()
        if meta.duration <= 0 { meta.duration = 1.0 }

        // MARK: - Metadata Resolution (Strictly Attached File Metadata with Filename Fallback for Title)
        let isICloudDataless = url.pathExtension.lowercased() == "icloud"
        var cleanFileName = url.deletingPathExtension().lastPathComponent
        if isICloudDataless {
            while cleanFileName.hasPrefix("._") || cleanFileName.hasPrefix(".") {
                if cleanFileName.hasPrefix("._") {
                    cleanFileName = String(cleanFileName.dropFirst(2))
                } else if cleanFileName.hasPrefix(".") {
                    cleanFileName = String(cleanFileName.dropFirst(1))
                }
            }
            let innerURL = URL(fileURLWithPath: cleanFileName)
            let innerExt = innerURL.pathExtension.lowercased()
            if supportedExtensions.contains(innerExt) {
                cleanFileName = innerURL.deletingPathExtension().lastPathComponent
            }
        }
        let fileNameWithoutExtension = cleanFileName
        let fnMetadata = parseFilenameMetadata(filename: fileNameWithoutExtension)

        // Resolve Final Title: embedded tag -> filename parsed title -> raw filename
        let finalTitle: String = {
            if let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !isGenericTitle(t) {
                return t
            }
            if let t = fnMetadata.title, !t.isEmpty {
                return t
            }
            return fileNameWithoutExtension
        }()

        // Resolve Final Artist: embedded tag (artist/author/albumArtist) -> filename parsed artist/albumArtist -> Unknown Artist
        let finalArtist: String = {
            if let a = meta.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, !isGenericArtist(a) {
                return a
            }
            if let a = meta.author?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, !isGenericArtist(a) {
                return a
            }
            if let a = meta.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, !isGenericArtist(a) {
                return a
            }
            if let a = fnMetadata.artist, !a.isEmpty {
                return a
            }
            return "Unknown Artist"
        }()

        // Resolve Final Album: strictly from embedded metadata attached to the file
        let finalAlbum: String = {
            if let alb = meta.album?.trimmingCharacters(in: .whitespacesAndNewlines), !alb.isEmpty, !isGenericAlbum(alb) {
                return alb
            }
            return "Unknown Album"
        }()

        let finalTrackNumber = meta.trackNumber ?? fnMetadata.trackNumber

        // Attach embedded artwork or folder artwork and cache raw bytes deduplicated by album
        let isLocalAudio = CloudFileAvailability.isLocal(url: url)
        var artworkKey: String?
        var artworkData: Data? = isLocalAudio ? meta.artworkData : nil
        if isLocalAudio && (artworkData == nil || artworkData?.isEmpty == true) {
            artworkData = findFolderArtwork(for: url)
        }
        if let art = artworkData, !art.isEmpty {
            if finalArtist != "Unknown Artist" || finalAlbum != "Unknown Album" {
                artworkKey = ArtworkCacheService.albumArtworkKey(artist: finalArtist, album: finalAlbum)
            } else {
                let parentFolderName = url.deletingLastPathComponent().lastPathComponent.lowercased()
                artworkKey = "album_art_dir_\(parentFolderName)"
            }
            if let key = artworkKey {
                if artworkDeduplicator?.shouldStore(key) ?? true {
                    await ArtworkCacheService.shared.storeRawArtwork(data: art, key: key)
                }
            }
        }

        // Calculate bitrate
        var bitRate = meta.bitRate
        if bitRate <= 0 && meta.duration > 0 && fileSizeBytes > 0 {
            bitRate = Double(fileSizeBytes * 8) / meta.duration
        }

        // Audio file info
        let audioFileInfo = AudioFileInfo(
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension,
            fileSizeBytes: fileSizeBytes,
            sampleRate: meta.sampleRate,
            channelCount: meta.channelCount,
            bitRate: bitRate,
            formatDescription: meta.formatDescription.isEmpty ? url.pathExtension.uppercased() : meta.formatDescription,
            durationSeconds: meta.duration,
            creationDate: creationDate,
            modificationDate: modificationDate
        )

        // Release-type tags (plan §3.7) go to the classifier's local tag store.
        LocalReleaseTagStore.shared.record(trackID: trackID, info: meta.releaseTypeInfo)

        let tagSnap = TagSnapshot(
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            albumArtist: meta.albumArtist,
            year: meta.year,
            trackNumber: finalTrackNumber,
            discNumber: meta.discNumber
        )

        return Track(
            id: trackID,
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            albumArtist: meta.albumArtist,
            genre: meta.genre,
            year: meta.year,
            trackNumber: finalTrackNumber,
            totalTracks: meta.totalTracks,
            discNumber: meta.discNumber,
            duration: meta.duration,
            url: url,
            artworkKey: artworkKey,
            dateAdded: creationDate ?? Date(),
            fileInfo: audioFileInfo,
            lyrics: meta.lyrics,
            folderID: folderID,
            relativePath: relativePath,
            metadataSource: .embeddedTags,
            tagSnapshot: tagSnap
        )
    }

    // MARK: - Fast Synchronous Metadata Field Extractors

    // Extract string
    private func extractString(from item: AVMetadataItem) async -> String? {
        if let str = (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            return str
        }
        if let val = try? await item.load(.value) as? String {
            // Trimmed
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let data = try? await item.load(.dataValue),
           // Str
           let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) {
            // Trimmed
            let trimmed = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // Extract number
    private func extractNumber(from item: AVMetadataItem) async -> Int? {
        if let num = (try? await item.load(.numberValue))?.intValue, num > 0 {
            return num
        }
        if let val = (try? await item.load(.value)) as? NSNumber, val.intValue > 0 {
            return val.intValue
        }
        if let str = await extractString(from: item) {
            // Digits
            let digits = str.filter { $0.isNumber }
            if let n = Int(digits), n > 0 {
                return n
            }
        }
        return nil
    }

    // Extract artwork
    private func extractArtwork(from item: AVMetadataItem) async -> Data? {
        if let data = try? await item.load(.dataValue), !data.isEmpty {
            return data
        }
        if let val = try? await item.load(.value) {
            if let data = val as? Data, !data.isEmpty { return data }
            if let data = val as? NSData, data.length > 0 { return data as Data }
            if let dict = val as? [String: Any], let data = dict["data"] as? Data, !data.isEmpty { return data }
            if let dict = val as? NSDictionary, let data = dict["data"] as? NSData, data.length > 0 { return data as Data }
        }
        return nil
    }

    // MARK: - Filename Metadata Parsers

    /// Parses track number, artist, and title from standard file name patterns.
    private func parseFilenameMetadata(filename: String) -> (trackNumber: Int?, artist: String?, title: String?) {
        // Clean
        var clean = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        // Track number
        var trackNumber: Int?
        // Primary artist name
        var artist: String?
        // Display title
        var title: String?

        // Check leading digits (e.g. "01 - ", "01. ", "01 ", "1-01 ")
        let digitsPattern = #"^(\d{1,3})[\s\-\.\_]+"#
        if let regex = try? NSRegularExpression(pattern: digitsPattern),
           // Match
           let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)) {
            if let numRange = Range(match.range(at: 1), in: clean), let num = Int(clean[numRange]), num > 0 {
                trackNumber = num
                if let fullRange = Range(match.range, in: clean) {
                    clean = String(clean[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Split on standard delimiters (" - ", " — ", " – ")
        let delimiters = [" - ", " — ", " – "]
        for delim in delimiters {
            if clean.contains(delim) {
                // Parts
                let parts = clean.components(separatedBy: delim).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parts.count == 2 {
                    artist = parts[0]
                    title = parts[1]
                    return (trackNumber, artist, title)
                } else if parts.count >= 3 {
                    artist = parts[0]
                    title = parts[1...].joined(separator: " - ")
                    return (trackNumber, artist, title)
                }
            }
        }

        if !clean.isEmpty {
            title = clean
        }

        return (trackNumber, artist, title)
    }

    // Is generic title
    private func isGenericTitle(_ title: String) -> Bool {
        // Lower
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }
        if lower.hasPrefix("track") || lower.hasPrefix("audiotrack") || lower.hasPrefix("untitled") || lower == "unknown title" {
            return true
        }
        return false
    }

    // Is generic artist
    private func isGenericArtist(_ artist: String) -> Bool {
        // Lower
        let lower = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.isEmpty || lower == "unknown artist" || lower == "unknown"
    }

    // Is generic album
    private func isGenericAlbum(_ album: String) -> Bool {
        // Lower
        let lower = album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.isEmpty || lower == "unknown album" || lower == "unknown"
    }

    /// Converts a FourCharCode format ID to a human-readable audio format string.
    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        // Bytes
        let bytes: [CChar] = [
            CChar((code >> 24) & 0xff),
            CChar((code >> 16) & 0xff),
            CChar((code >> 8) & 0xff),
            CChar(code & 0xff),
            0
        ]
        // String
        let string = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        switch string {
        case "aac ", "aacf": return "AAC (MPEG-4)"
        case "alac": return "Apple Lossless (ALAC)"
        case "flac": return "Free Lossless Audio (FLAC)"
        case ".mp3", "LAME": return "MPEG Layer 3 (MP3)"
        case "lpcm": return "Linear PCM"
        case "opus": return "Opus"
        case "vorb": return "Ogg Vorbis"
        default: return string.isEmpty ? "Native Audio Stream" : string.uppercased()
        }
    }

    /// Lyrics for a track: on-disk copy (local file or downloaded server file) first, then the server's
    /// lyrics API for server tracks. A server track's `track.url` is an identity value and is never fetched.
    /// Views go through `LyricsCache.shared.lyrics(for:)`, which runs this at most once per song.
    public static func extractLyrics(for track: Track) async -> String? {
        if let downloaded = await MainActor.run(body: { JellyfinDownloadManager.shared.localFileURL(for: track.id) }),
           FileManager.default.fileExists(atPath: downloaded.path),
           let lyrics = await extractLyrics(from: downloaded) {
            return lyrics
        }
        if track.url.isFileURL {
            return await extractLyrics(from: track.url)
        }
        guard track.isJellyfinItem || track.metadataSource == .server,
              let provider = await MainActor.run(body: { AudioPlayerService.shared?.lyricsProvider(for: track) }) else {
            return nil
        }
        return await provider.fetchLyrics(for: track)
    }

    /// Deeply inspects an audio file and its sidecars to extract embedded or external lyrics.
    /// Non-file URLs are never opened: for a server track's identity URL the lookup goes through
    /// `extractLyrics(for:)` (server lyrics API), otherwise nil.
    public static func extractLyrics(from url: URL) async -> String? {
        guard url.isFileURL else {
            let track = await MainActor.run(body: { () -> Track? in
                guard let current = AudioPlayerService.shared?.currentTrack, current.url == url else { return nil }
                return current
            })
            guard let track else { return nil }
            return await extractLyrics(for: track)
        }
        // 1. High-speed binary tag reader first
        if let meta = FastAudioMetadataReader.readMetadata(for: url),
           let lyr = meta.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lyr.isEmpty {
            return lyr
        }

        // 2. Sidecar files: .lrc, .txt, .lyrics
        let base = url.deletingPathExtension()
        for ext in ["lrc", "LRC", "txt", "TXT", "lyrics", "LYRICS"] {
            let sidecar = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: sidecar.path),
               let content = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? (try? String(contentsOf: sidecar, encoding: .isoLatin1)),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 3. AVAsset deep metadata inspection (ID3, QuickTime, iTunes, Common)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let allMetadata = (try? await asset.load(.metadata)) ?? []
        for item in allMetadata {
            let keyLower = item.commonKey?.rawValue.lowercased() ?? ((item.key as? String)?.lowercased() ?? "")
            let idLower = item.identifier?.rawValue.lowercased() ?? ""

            if let stringVal = (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines), !stringVal.isEmpty {
                if keyLower.contains("lyr") || keyLower.contains("uslt") || keyLower.contains("sylt") || idLower.contains("lyr") {
                    return stringVal
                }
                // Large text tag with newlines or timestamp patterns
                if stringVal.count > 50 && (stringVal.contains("\n") || stringVal.contains("\r") || stringVal.contains("[0")) {
                    return stringVal
                }
            } else if let dataVal = try? await item.load(.dataValue) {
                if let str = (String(data: dataVal, encoding: .utf8) ?? String(data: dataVal, encoding: .isoLatin1))?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                    if keyLower.contains("lyr") || keyLower.contains("uslt") || keyLower.contains("sylt") || idLower.contains("lyr") {
                        return str
                    }
                    if str.count > 50 && (str.contains("\n") || str.contains("\r") || str.contains("[0")) {
                        return str
                    }
                }
            }
        }

        return nil
    }
}

public extension AVMetadataItem {
    nonisolated var keyString: String? {
        if let str = key as? String {
            return str
        } else if let num = key as? NSNumber {
            return num.stringValue
        }
        return nil
    }
}

// MARK: - Lyrics Cache

/// One lyrics lookup per song for this app session, shared by every player view.
/// Misses are cached too, and concurrent requests for the same song share one lookup.
/// Nothing here prefetches: a lookup only runs when the lyrics view asks for it.
actor LyricsCache {
    static let shared = LyricsCache()

    /// `nil` value = looked up, no lyrics.
    private var results: [UUID: String?] = [:]
    private var inFlight: [UUID: Task<String?, Never>] = [:]

    /// `.none` = never looked up; `.some(nil)` = looked up, no lyrics.
    func cachedResult(for trackID: UUID) -> String?? {
        results[trackID]
    }

    func lyrics(for track: Track) async -> String? {
        if let cached = results[track.id] { return cached }
        if let running = inFlight[track.id] { return await running.value }
        // Detached so file reads and the server request run off the main actor and finish
        // (and get cached) even if the view that asked goes away.
        let task = Task.detached(priority: .userInitiated) {
            await AudioScannerService.extractLyrics(for: track)
        }
        inFlight[track.id] = task
        let value = await task.value
        inFlight[track.id] = nil
        results[track.id] = .some(value)
        return value
    }
}
