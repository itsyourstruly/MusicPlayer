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

    /// Scans a directory URL recursively in parallel and returns parsed Track objects.
    public func scanDirectory(
        at folderURL: URL,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> [Track] {
        AppLogger.scanner.info("Starting high-speed audio scan at: \(folderURL.path)")

        // Ensure security-scoped access is active for scanning
        let isAccessing = folderURL.startAccessingSecurityScopedResource()
        // Cleanup upon exiting scope
        defer {
            if isAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        // File manager
        let fileManager = FileManager.default
        // Audio file ur ls
        var audioFileURLs: [URL] = []
        // Flag indicating if dir
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                // User linked a single audio file directly
                let ext = folderURL.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    audioFileURLs.append(folderURL)
                }
            } else {
                // Recursive directory enumeration
                if let enumerator = fileManager.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    // File path location
                    for case let fileURL as URL in enumerator {
                        // Ext
                        let ext = fileURL.pathExtension.lowercased()
                        if supportedExtensions.contains(ext) {
                            audioFileURLs.append(fileURL)
                        }
                    }
                }

                // Fallback shallow directory scan if enumerator yielded no files
                if audioFileURLs.isEmpty {
                    if let directContents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for fileURL in directContents {
                            // Ext
                            let ext = fileURL.pathExtension.lowercased()
                            if supportedExtensions.contains(ext) {
                                audioFileURLs.append(fileURL)
                            }
                        }
                    }
                }
            }
        }

        // Total files
        let totalFiles = audioFileURLs.count
        AppLogger.scanner.info("Found \(totalFiles) audio files to process.")

        // MARK: - Scaled TaskGroup Execution
        #if os(macOS)
        // Max concurrent workers
        let maxConcurrentWorkers = min(16, max(4, ProcessInfo.processInfo.activeProcessorCount))
        // Chunk size
        let chunkSize = maxConcurrentWorkers * 8
        #else
        // Max concurrent workers
        let maxConcurrentWorkers = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        // Chunk size
        let chunkSize = maxConcurrentWorkers * 4
        #endif
        // Scanned tracks
        var scannedTracks: [Track] = []
        scannedTracks.reserveCapacity(totalFiles)

        // Processed count
        var processedCount = 0
        // Last reported time
        var lastReportedTime = Date.distantPast

        for chunkStart in stride(from: 0, to: totalFiles, by: chunkSize) {
            // Chunk end
            let chunkEnd = min(chunkStart + chunkSize, totalFiles)
            // Current chunk
            let currentChunk = Array(audioFileURLs[chunkStart..<chunkEnd])

            // Chunk results
            var chunkResults: [Track] = []
            await withTaskGroup(of: Track?.self) { group in
                for fileURL in currentChunk {
                    group.addTask {
                        await self.parseAudioTrack(at: fileURL, rootFolderURL: folderURL)
                    }
                }

                for await track in group {
                    processedCount += 1
                    if let track = track {
                        chunkResults.append(track)
                    }

                    // Now
                    let now = Date()
                    if now.timeIntervalSince(lastReportedTime) >= 0.25 || processedCount == totalFiles || (processedCount % 25 == 0) {
                        lastReportedTime = now
                        // Current name
                        let currentName = track?.title ?? "Processing..."
                        onProgress?(processedCount, totalFiles, currentName)
                    }
                }
            }

            scannedTracks.append(contentsOf: chunkResults)
        }

        AppLogger.scanner.info("Completed scan. Successfully parsed \(scannedTracks.count) of \(totalFiles) tracks.")
        return scannedTracks
    }

    /// Parses an audio file with lightweight AVURLAsset property loading and fast synchronous tag decoding.
    public func parseAudioTrack(at url: URL, rootFolderURL: URL? = nil) async -> Track? {
        // Flag indicating if file accessing
        let isFileAccessing = url.startAccessingSecurityScopedResource()
        // Cleanup upon exiting scope
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
        // Creation date
        var creationDate: Date?
        // Modification date
        var modificationDate: Date?

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            creationDate = attributes[.creationDate] as? Date
            modificationDate = attributes[.modificationDate] as? Date
        }

        // MARK: - 1. Pure-Swift In-Process Direct Binary Metadata Extraction (<0.2ms per file)
        var parsedMeta = FastAudioMetadataReader.readMetadata(for: url)

        // 2. Fallback to AVURLAsset ONLY for rare niche formats unsupported by binary parser
        if parsedMeta == nil {
            // Asset
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            // Duration seconds
            var durationSeconds: TimeInterval = 0
            // All metadata
            var allMetadata: [AVMetadataItem] = []

            if let (cmDuration, commonMeta, genericMeta) = try? await asset.load(.duration, .commonMetadata, .metadata) {
                // Secs
                let secs = CMTimeGetSeconds(cmDuration)
                if !secs.isNaN && !secs.isInfinite && secs > 0 { durationSeconds = secs }
                allMetadata.append(contentsOf: commonMeta)
                allMetadata.append(contentsOf: genericMeta)
            }

            // Fallback
            var fallback = ParsedAudioMetadata()
            fallback.duration = durationSeconds > 0 ? durationSeconds : 1.0
            fallback.formatDescription = url.pathExtension.uppercased()

            for item in allMetadata {
                // Common key
                let commonKey = item.commonKey
                // Key lower
                let keyLower = (item.keyString ?? (item.key as? String) ?? "").lowercased()
                // Id lower
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
                        // Digits
                        let digits = str.filter { $0.isNumber }
                        if digits.count >= 4, let y = Int(digits.prefix(4)), y >= 1900, y <= 2099 {
                            fallback.year = y
                        }
                    }
                }
                if fallback.artworkData == nil && (commonKey == .commonKeyArtwork || keyLower.contains("art") || keyLower.contains("covr") || idLower.contains("art") || idLower.contains("covr")) {
                    fallback.artworkData = extractArtwork(from: item)
                }
            }
            parsedMeta = fallback
        }

        // Meta
        var meta = parsedMeta ?? ParsedAudioMetadata()
        if meta.duration <= 0 { meta.duration = 1.0 }

        // MARK: - Metadata Resolution (Strictly Attached File Metadata with Filename Fallback for Title)
        let fileNameWithoutExtension = url.deletingPathExtension().lastPathComponent
        // Fn metadata
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

        // Final track number
        let finalTrackNumber = meta.trackNumber ?? fnMetadata.trackNumber

        // Attach embedded artwork and cache
        var artworkKey: String?
        if let art = meta.artworkData, !art.isEmpty {
            if finalArtist != "Unknown Artist" || finalAlbum != "Unknown Album" {
                artworkKey = "\(finalArtist)_\(finalAlbum)".lowercased()
            } else {
                artworkKey = "art_\(fileNameWithoutExtension.lowercased())"
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
            lyrics: nil
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
                // Full range
                let fullRange = Range(match.range, in: clean)!
                clean = String(clean[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
