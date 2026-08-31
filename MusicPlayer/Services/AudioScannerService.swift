import Foundation
import AVFoundation
import CoreMedia
import os

/// High-throughput concurrency-safe audio scanner that traverses directories in parallel,
/// extracts rich ID3/QuickTime/Vorbis/FLAC metadata with single-shot AVURLAsset batch loading,
/// directory & filename heuristic fallbacks, and non-blocking background artwork caching.
public struct AudioScannerService: Sendable {
    public static let shared = AudioScannerService()

    // Supported extensions
    private let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "m4r", "mp4", "mpeg", "mpg", "mp2", "mpa",
        "aac", "flac", "wav", "wave", "aiff", "aif", "aifc", "caf", "alac",
        "ogg", "oga", "opus", "wma", "webm", "3gp", "dsf", "dff"
    ]

    // Initialize with configured properties
    public init() {}

    /// Scans a directory URL recursively in parallel with smart differential caching and returns parsed Track objects.
    public func scanDirectory(
        at folderURL: URL,
        existingTracks: [Track] = [],
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> [Track] {
        AppLogger.scanner.info("Starting high-speed audio scan at: \(folderURL.path) (with \(existingTracks.count) cached tracks)")

        // Ensure security-scoped root folder access is active
        _ = SecurityScopedBookmark.shared.resolveAndAccessBookmark()
        _ = folderURL.startAccessingSecurityScopedResource()

        // Build fast path-based lookup map for differential scan
        var existingTrackMap: [String: Track] = [:]
        existingTrackMap.reserveCapacity(existingTracks.count)
        for track in existingTracks {
            existingTrackMap[track.url.standardizedFileURL.path] = track
        }

        let fileManager = FileManager.default
        var audioFileURLs: [URL] = []
        var seenAudioFilePaths = Set<String>()
        var visitedDirectories = Set<String>()
        var isDir: ObjCBool = false

        let rootCanonicalPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        visitedDirectories.insert(rootCanonicalPath)

        if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                // User linked a single audio file directly
                let ext = folderURL.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    audioFileURLs.append(folderURL)
                }
            } else {
                // Recursive directory enumeration with cycle & symlink loop protection
                if let enumerator = fileManager.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let fileURL as URL in enumerator {
                        // Safety ceiling to prevent runaway allocations on corrupted filesystems
                        if audioFileURLs.count >= 200_000 {
                            AppLogger.scanner.warning("Reached safety limit of 200,000 files during scanning.")
                            break
                        }

                        // Cycle detection for directories & symbolic links
                        if let res = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                            if res.isDirectory == true || res.isSymbolicLink == true {
                                let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                                if visitedDirectories.contains(canonical) {
                                    enumerator.skipDescendants()
                                    continue
                                }
                                visitedDirectories.insert(canonical)
                            }
                        }

                        let ext = fileURL.pathExtension.lowercased()
                        if supportedExtensions.contains(ext) {
                            let path = fileURL.standardizedFileURL.path
                            if seenAudioFilePaths.insert(path).inserted {
                                audioFileURLs.append(fileURL)
                            }
                        }
                    }
                }

                // Fallback shallow directory scan if enumerator yielded no files
                if audioFileURLs.isEmpty {
                    if let directContents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for fileURL in directContents {
                            let ext = fileURL.pathExtension.lowercased()
                            if supportedExtensions.contains(ext) {
                                let path = fileURL.standardizedFileURL.path
                                if seenAudioFilePaths.insert(path).inserted {
                                    audioFileURLs.append(fileURL)
                                }
                            }
                        }
                    }
                }
            }
        }

        let totalFiles = audioFileURLs.count
        AppLogger.scanner.info("Found \(totalFiles) unique audio files to evaluate.")

        // MARK: - Smart Differential Partitioning
        var scannedTracks: [Track] = []
        scannedTracks.reserveCapacity(min(totalFiles, 50_000))
        var filesNeedingParsing: [URL] = []
        filesNeedingParsing.reserveCapacity(min(totalFiles, 50_000))

        for fileURL in audioFileURLs {
            let standardizedPath = fileURL.standardizedFileURL.path
            if let cachedTrack = existingTrackMap[standardizedPath] {
                // Fast size check to verify file hasn't been modified on disk
                if let cachedSize = cachedTrack.fileInfo?.fileSizeBytes, cachedSize > 0,
                   let artKey = cachedTrack.artworkKey, !artKey.isEmpty {
                    if let attr = try? fileManager.attributesOfItem(atPath: fileURL.path),
                       let currentSize = (attr[.size] as? NSNumber)?.int64Value,
                       currentSize == cachedSize {
                        // Only reuse if artwork is confirmed available
                        if await ArtworkCacheService.shared.hasArtwork(key: artKey) {
                            scannedTracks.append(cachedTrack)
                            continue
                        }
                    }
                }
            }
            filesNeedingParsing.append(fileURL)
        }

        let reusedCount = scannedTracks.count
        let toParseCount = filesNeedingParsing.count
        AppLogger.scanner.info("[Differential Scan] Reused \(reusedCount) unmodified tracks instantly. Parsing \(toParseCount) new/modified files.")

        // Initial progress yield for reused files
        if totalFiles > 0 {
            onProgress?(reusedCount, totalFiles, "Indexed \(reusedCount) existing files...")
        }

        // MARK: - Scaled TaskGroup Execution for New/Modified Files
        if !filesNeedingParsing.isEmpty {
            let maxConcurrentWorkers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
            let chunkSize = maxConcurrentWorkers * 4

            var processedNewCount = 0
            var lastReportedTime = Date.distantPast

            for chunkStart in stride(from: 0, to: toParseCount, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, toParseCount)
                let currentChunk = Array(filesNeedingParsing[chunkStart..<chunkEnd])

                var chunkResults: [Track] = []
                await withTaskGroup(of: Track?.self) { group in
                    for fileURL in currentChunk {
                        group.addTask(priority: .utility) {
                            await self.parseAudioTrack(at: fileURL, rootFolderURL: folderURL)
                        }
                    }

                    for await track in group {
                        processedNewCount += 1
                        if let track = track {
                            chunkResults.append(track)
                        }

                        let totalProgress = reusedCount + processedNewCount
                        let now = Date()
                        if now.timeIntervalSince(lastReportedTime) >= 0.25 || totalProgress == totalFiles {
                            lastReportedTime = now
                            let currentName = track?.title ?? "Processing..."
                            onProgress?(totalProgress, totalFiles, currentName)
                        }
                    }
                }

                scannedTracks.append(contentsOf: chunkResults)
            }
        }

        AppLogger.scanner.info("Completed scan. Total indexed: \(scannedTracks.count) tracks (\(reusedCount) reused, \(toParseCount) parsed).")
        return scannedTracks
    }

    /// Parses an audio file with pure-Swift binary extraction and lightweight fallback.
    public func parseAudioTrack(at url: URL, rootFolderURL: URL? = nil) async -> Track? {
        let isFileAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isFileAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Trigger background download if file is an undownloaded iCloud ubiquitous item
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        // Read file system attributes
        var fileSizeBytes: Int64 = 0
        var creationDate: Date?
        var modificationDate: Date?

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            creationDate = attributes[.creationDate] as? Date
            modificationDate = attributes[.modificationDate] as? Date
        }

        // MARK: - 1. Pure-Swift In-Process Direct Binary Metadata Extraction (<0.2ms per file)
        var parsedMeta = FastAudioMetadataReader.readMetadata(for: url)

        // 2. Lightweight Fallback ONLY if binary reader was unable to parse the file
        if parsedMeta == nil {
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
                    fallback.title = extractString(from: item)
                }
                if fallback.artist == nil && (commonKey == .commonKeyArtist || keyLower.contains("art") || keyLower.contains("author") || idLower.contains("art")) {
                    fallback.artist = extractString(from: item)
                }
                if fallback.album == nil && (commonKey == .commonKeyAlbumName || keyLower.contains("alb") || idLower.contains("alb") || keyLower == "talb" || keyLower == "©alb") {
                    fallback.album = extractString(from: item)
                }
                if fallback.albumArtist == nil && (keyLower.contains("aart") || keyLower.contains("albumartist") || idLower.contains("aart")) {
                    fallback.albumArtist = extractString(from: item)
                }
                if fallback.year == nil {
                    if let str = extractString(from: item) {
                        let digits = str.filter { $0.isNumber }
                        if digits.count >= 4, let y = Int(digits.prefix(4)), y >= 1900, y <= 2099 {
                            fallback.year = y
                        }
                    }
                }
                if fallback.artworkData == nil && (commonKey == .commonKeyArtwork || keyLower.contains("art") || keyLower.contains("covr") || idLower.contains("art") || idLower.contains("covr") || keyLower.contains("apic")) {
                    fallback.artworkData = extractArtwork(from: item)
                }
                if fallback.lyrics == nil {
                    if keyLower.contains("lyr") || keyLower.contains("uslt") || keyLower.contains("sylt") || idLower.contains("lyr") {
                        fallback.lyrics = extractString(from: item)
                    } else if let str = extractString(from: item), str.count > 50, (str.contains("\n") || str.contains("\r") || str.contains("[0")) {
                        fallback.lyrics = str
                    }
                }
            }
            parsedMeta = fallback
        }

        var meta = parsedMeta ?? ParsedAudioMetadata()
        if meta.duration <= 0 { meta.duration = 1.0 }

        // MARK: - Metadata Resolution (Strictly Attached File Metadata with Filename Fallback for Title)
        let fileNameWithoutExtension = url.deletingPathExtension().lastPathComponent
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

        // Resolve Final Artist: embedded tag -> filename parsed artist -> Unknown Artist
        let finalArtist: String = {
            if let a = meta.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, !isGenericArtist(a) {
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

        // Attach embedded artwork and cache raw bytes deduplicated by album
        var artworkKey: String?
        if let art = meta.artworkData, !art.isEmpty {
            if finalArtist != "Unknown Artist" || finalAlbum != "Unknown Album" {
                artworkKey = ArtworkCacheService.albumArtworkKey(artist: finalArtist, album: finalAlbum)
            } else {
                let parentFolderName = url.deletingLastPathComponent().lastPathComponent.lowercased()
                artworkKey = "album_art_dir_\(parentFolderName)"
            }
            if let key = artworkKey {
                await ArtworkCacheService.shared.storeRawArtwork(data: art, key: key)
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

        let deterministicID = UUID.deterministic(from: url.standardizedFileURL.path.lowercased())
        return Track(
            id: deterministicID,
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
            lyrics: meta.lyrics
        )
    }

    // MARK: - Fast Synchronous Metadata Field Extractors

    // Extract string
    private func extractString(from item: AVMetadataItem) -> String? {
        if let str = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            return str
        }
        if let val = item.value as? String {
            // Trimmed
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let data = item.dataValue,
           // Str
           let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) {
            // Trimmed
            let trimmed = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // Extract number
    private func extractNumber(from item: AVMetadataItem) -> Int? {
        if let num = item.numberValue?.intValue, num > 0 {
            return num
        }
        if let val = item.value as? NSNumber, val.intValue > 0 {
            return val.intValue
        }
        if let str = extractString(from: item) {
            // Digits
            let digits = str.filter { $0.isNumber }
            if let n = Int(digits), n > 0 {
                return n
            }
        }
        return nil
    }

    // Extract artwork
    private func extractArtwork(from item: AVMetadataItem) -> Data? {
        if let data = item.dataValue, !data.isEmpty {
            return data
        }
        if let val = item.value {
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

    /// Deeply inspects an audio file and its sidecars to extract embedded or external lyrics.
    public static func extractLyrics(from url: URL) async -> String? {
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
