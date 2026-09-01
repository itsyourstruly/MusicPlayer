import Foundation
import AVFoundation
import CoreMedia
import os

/// High-performance, isolated filesystem hierarchy parser that extracts Artist, Album, Disc Number,
/// Track Number, and Track Title directly from directory folder nesting and file naming conventions (Method 2).
public struct FolderHierarchyScanner: Sendable {
    public static let shared = FolderHierarchyScanner()

    // Common disc folder patterns (e.g., "CD 1", "CD1", "Disc 2", "Disk 1", "CD-01")
    private static let discRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(?:cd|disc|disk)[\s\-\_\.]*(\d{1,2})$"#, options: [.caseInsensitive])
    }()

    // Generic directory names to filter when analyzing deep folder structures
    private static let genericFolderNames: Set<String> = [
        "music", "my music", "audio", "audios", "flac", "flacs", "mp3", "mp3s",
        "lossless", "hires", "hi-res", "songs", "library", "downloads", "itunes",
        "itunes media", "apple music", "media", "tracks", "new folder", "unorganized",
        "albums", "discography", "complete"
    ]

    // Common artwork image filenames in album folders
    private static let commonArtworkFilenames: [String] = [
        "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.jpeg", "front.png", "album.jpg", "album.jpeg", "album.png",
        "artwork.jpg", "artwork.jpeg", "artwork.png", "Cover.jpg", "Cover.png", "Folder.jpg"
    ]

    public init() {}

    /// Parses an audio file using its filesystem hierarchy relative to the linked root directory.
    public func parseAudioTrack(at url: URL, rootFolderURL: URL?) async -> Track? {
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

        // Read filesystem attributes
        var fileSizeBytes: Int64 = 0
        var creationDate: Date?
        var modificationDate: Date?

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            creationDate = attributes[.creationDate] as? Date
            modificationDate = attributes[.modificationDate] as? Date
        }

        // 1. Read binary audio technical specs & embedded metadata baseline (<0.2ms)
        let binaryMeta = FastAudioMetadataReader.readMetadata(for: url)
        var durationSeconds = binaryMeta?.duration ?? 0
        if durationSeconds <= 0 {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            if let cmDuration = try? await asset.load(.duration) {
                let secs = CMTimeGetSeconds(cmDuration)
                if !secs.isNaN && !secs.isInfinite && secs > 0 { durationSeconds = secs }
            }
        }
        if durationSeconds <= 0 { durationSeconds = 1.0 }

        // 2. Extract hierarchy components from folder nesting
        let hierarchy = extractHierarchy(for: url, rootFolderURL: rootFolderURL)

        // 3. Filename track number and title extraction
        let filenameWithoutExt = url.deletingPathExtension().lastPathComponent
        let fnMeta = parseFilenameMetadata(filename: filenameWithoutExt)

        // 4. Resolve Title: filename title -> embedded tag title -> raw filename
        let finalTitle: String = {
            if let t = fnMeta.title, !t.isEmpty, !isGenericString(t) {
                return t
            }
            if let t = binaryMeta?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !isGenericString(t) {
                return t
            }
            return filenameWithoutExt
        }()

        // 5. Resolve Artist: folder artist -> filename artist -> embedded tag artist -> Unknown Artist
        let finalArtist: String = {
            if let a = hierarchy.artist, !a.isEmpty, !isGenericString(a) {
                return a
            }
            if let a = fnMeta.artist, !a.isEmpty, !isGenericString(a) {
                return a
            }
            if let a = binaryMeta?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, !isGenericString(a) {
                return a
            }
            return "Unknown Artist"
        }()

        // 6. Resolve Album: folder album -> embedded tag album -> "Singles" / "Unknown Album"
        let finalAlbum: String = {
            if let alb = hierarchy.album, !alb.isEmpty, !isGenericString(alb) {
                return alb
            }
            if let alb = binaryMeta?.album?.trimmingCharacters(in: .whitespacesAndNewlines), !alb.isEmpty, !isGenericString(alb) {
                return alb
            }
            if hierarchy.artist != nil {
                return "Singles"
            }
            return "Unknown Album"
        }()

        // 7. Resolve Disc Number: folder disc -> embedded tag disc
        let finalDiscNumber: Int? = hierarchy.discNumber ?? binaryMeta?.discNumber

        // 8. Resolve Track Number: filename track number -> embedded tag track number
        let finalTrackNumber: Int? = fnMeta.trackNumber ?? binaryMeta?.trackNumber

        // 9. Artwork Resolution: embedded artwork -> local folder artwork file
        var artworkKey: String?
        var artworkData: Data? = binaryMeta?.artworkData

        if artworkData == nil || artworkData?.isEmpty == true {
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
                await ArtworkCacheService.shared.storeRawArtwork(data: art, key: key)
            }
        }

        // Calculate bitrate
        var bitRate = binaryMeta?.bitRate ?? 0
        if bitRate <= 0 && durationSeconds > 0 && fileSizeBytes > 0 {
            bitRate = Double(fileSizeBytes * 8) / durationSeconds
        }

        let audioFileInfo = AudioFileInfo(
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension,
            fileSizeBytes: fileSizeBytes,
            sampleRate: binaryMeta?.sampleRate ?? 44100,
            channelCount: binaryMeta?.channelCount ?? 2,
            bitRate: bitRate,
            formatDescription: binaryMeta?.formatDescription.isEmpty == false ? (binaryMeta?.formatDescription ?? "") : url.pathExtension.uppercased(),
            durationSeconds: durationSeconds,
            creationDate: creationDate,
            modificationDate: modificationDate
        )

        let deterministicID = UUID.deterministic(from: url.standardizedFileURL.path.lowercased())
        return Track(
            id: deterministicID,
            title: finalTitle,
            artist: finalArtist,
            album: finalAlbum,
            albumArtist: hierarchy.artist ?? binaryMeta?.albumArtist,
            genre: binaryMeta?.genre,
            year: hierarchy.year ?? binaryMeta?.year,
            trackNumber: finalTrackNumber,
            totalTracks: binaryMeta?.totalTracks,
            discNumber: finalDiscNumber,
            duration: durationSeconds,
            url: url,
            artworkKey: artworkKey,
            dateAdded: creationDate ?? Date(),
            fileInfo: audioFileInfo,
            lyrics: binaryMeta?.lyrics
        )
    }

    // MARK: - Hierarchy Analysis

    public struct HierarchyResult: Sendable {
        public let artist: String?
        public let album: String?
        public let discNumber: Int?
        public let year: Int?
    }

    /// Deconstructs the directory hierarchy relative to the linked root directory.
    public func extractHierarchy(for url: URL, rootFolderURL: URL?) -> HierarchyResult {
        let stdFile = url.standardizedFileURL
        var folderComponents: [String] = []

        if let root = rootFolderURL?.standardizedFileURL,
           stdFile.path.hasPrefix(root.path) {
            let relativePath = String(stdFile.path.dropFirst(root.path.count))
            let parts = relativePath.components(separatedBy: "/").filter { !$0.isEmpty }
            // Drop the last component (the filename itself)
            folderComponents = Array(parts.dropLast())
        } else {
            // No root folder or file outside root: inspect parent directory path components
            let parentDir = stdFile.deletingLastPathComponent()
            let allParts = parentDir.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            // Take up to the last 4 components
            folderComponents = Array(allParts.suffix(4))
        }

        // Filter out initial generic folder names (e.g. "Music", "FLAC", "Lossless")
        while let first = folderComponents.first, Self.genericFolderNames.contains(first.lowercased()) && folderComponents.count > 1 {
            folderComponents.removeFirst()
        }

        guard !folderComponents.isEmpty else {
            return HierarchyResult(artist: nil, album: nil, discNumber: nil, year: nil)
        }

        var detectedDiscNumber: Int? = nil
        var remainingFolders = folderComponents

        // Check if the leaf folder is a Disc/CD subfolder (e.g., "CD 1", "Disc 2")
        if let lastFolder = remainingFolders.last,
           let regex = Self.discRegex,
           let match = regex.firstMatch(in: lastFolder, options: [], range: NSRange(location: 0, length: lastFolder.utf16.count)) {
            if let numRange = Range(match.range(at: 1), in: lastFolder), let discNum = Int(lastFolder[numRange]), discNum > 0 {
                detectedDiscNumber = discNum
                remainingFolders.removeLast()
            }
        }

        // Case 1: 2+ folders remaining -> [..., Artist, Album]
        if remainingFolders.count >= 2 {
            let rawAlbum = remainingFolders.last!
            let rawArtist = remainingFolders[remainingFolders.count - 2]

            let (cleanAlbum, year) = extractYearFromAlbumFolder(rawAlbum)
            return HierarchyResult(
                artist: rawArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                album: cleanAlbum.trimmingCharacters(in: .whitespacesAndNewlines),
                discNumber: detectedDiscNumber,
                year: year
            )
        }

        // Case 2: 1 folder remaining -> [Artist]
        if remainingFolders.count == 1 {
            let rawFolder = remainingFolders[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !Self.genericFolderNames.contains(rawFolder.lowercased()) {
                return HierarchyResult(
                    artist: rawFolder,
                    album: nil,
                    discNumber: detectedDiscNumber,
                    year: nil
                )
            }
        }

        return HierarchyResult(artist: nil, album: nil, discNumber: detectedDiscNumber, year: nil)
    }

    /// Extracts release year if prepended or appended to an album folder (e.g. "[1997] OK Computer" or "Kid A (2000)").
    private func extractYearFromAlbumFolder(_ folderName: String) -> (cleanTitle: String, year: Int?) {
        var clean = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        var year: Int?

        // Pattern 1: Leading year "[2001] Album Name" or "(2001) Album Name" or "2001 - Album Name"
        let leadingYearPattern = #"^[\(\[\{]?(\d{4})[\)\]\}]?\s*[\-\_\.]*\s*(.+)$"#
        if let regex = try? NSRegularExpression(pattern: leadingYearPattern),
           let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)) {
            if let yearRange = Range(match.range(at: 1), in: clean), let y = Int(clean[yearRange]), y >= 1900 && y <= 2099 {
                year = y
                if let titleRange = Range(match.range(at: 2), in: clean) {
                    clean = String(clean[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Pattern 2: Trailing year "Album Name (2001)" or "Album Name [2001]"
        let trailingYearPattern = #"^(.+?)\s*[\(\[\{](\d{4})[\)\]\}]$"#
        if year == nil,
           let regex = try? NSRegularExpression(pattern: trailingYearPattern),
           let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)) {
            if let yearRange = Range(match.range(at: 2), in: clean), let y = Int(clean[yearRange]), y >= 1900 && y <= 2099 {
                year = y
                if let titleRange = Range(match.range(at: 1), in: clean) {
                    clean = String(clean[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return (clean, year)
    }

    /// Scans the folder containing the audio file (and its parent if inside a CD subfolder) for cover images.
    private func findFolderArtwork(for fileURL: URL) -> Data? {
        let parentDir = fileURL.deletingLastPathComponent()
        let fm = FileManager.default

        // Check parent directory
        for artName in Self.commonArtworkFilenames {
            let artURL = parentDir.appendingPathComponent(artName)
            if fm.fileExists(atPath: artURL.path),
               let data = try? Data(contentsOf: artURL), !data.isEmpty {
                return data
            }
        }

        // If parent is a CD/Disc directory, check grandparent (the actual album directory)
        let parentName = parentDir.lastPathComponent
        if let regex = Self.discRegex,
           regex.firstMatch(in: parentName, options: [], range: NSRange(location: 0, length: parentName.utf16.count)) != nil {
            let grandParentDir = parentDir.deletingLastPathComponent()
            for artName in Self.commonArtworkFilenames {
                let artURL = grandParentDir.appendingPathComponent(artName)
                if fm.fileExists(atPath: artURL.path),
                   let data = try? Data(contentsOf: artURL), !data.isEmpty {
                    return data
                }
            }
        }

        return nil
    }

    // MARK: - Filename Metadata Parsing

    /// Parses track number, artist, and title from standard file name patterns.
    private func parseFilenameMetadata(filename: String) -> (trackNumber: Int?, artist: String?, title: String?) {
        var clean = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        var trackNumber: Int?
        var artist: String?
        var title: String?

        // Check leading digits (e.g. "01 - ", "01. ", "01 ", "1-01 ", "1.01 ")
        let digitsPattern = #"^(\d{1,3})[\s\-\.\_]+"#
        if let regex = try? NSRegularExpression(pattern: digitsPattern),
           let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)) {
            if let numRange = Range(match.range(at: 1), in: clean), let num = Int(clean[numRange]), num > 0 {
                trackNumber = num
                if let fullRange = Range(match.range, in: clean) {
                    clean = String(clean[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Multi-disc filename prefix check (e.g. "1-01 Song Title")
        let multiDiscPrefix = #"^(\d{1})\-(\d{1,2})[\s\-\.\_]+"#
        if trackNumber == nil,
           let regex = try? NSRegularExpression(pattern: multiDiscPrefix),
           let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)) {
            if let trackRange = Range(match.range(at: 2), in: clean), let num = Int(clean[trackRange]), num > 0 {
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

    private func isGenericString(_ str: String) -> Bool {
        let lower = str.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }
        if lower.hasPrefix("track") || lower.hasPrefix("audiotrack") || lower.hasPrefix("untitled") ||
           lower == "unknown title" || lower == "unknown artist" || lower == "unknown album" || lower == "unknown" {
            return true
        }
        return false
    }
}
