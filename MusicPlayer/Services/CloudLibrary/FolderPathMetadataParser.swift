import Foundation

/// Parsed metadata extracted purely from filesystem folder hierarchy and filename strings.
public struct ParsedPathMetadata: Sendable, Equatable {
    public let artist: String
    public let albumArtist: String?
    public let album: String
    public let year: Int?
    public let discNumber: Int?
    public let trackNumber: Int?
    public let title: String
    public let isCompilation: Bool
    public let albumDirectory: String

    public init(
        artist: String,
        albumArtist: String? = nil,
        album: String,
        year: Int? = nil,
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        title: String,
        isCompilation: Bool = false,
        albumDirectory: String
    ) {
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.title = title
        self.isCompilation = isCompilation
        self.albumDirectory = albumDirectory
    }

    public var track: Int? { trackNumber }
    public var disc: Int? { discNumber }
}

/// Pure filesystem path metadata parser for cloud and folder-based music libraries.
/// Zero file I/O operations.
public enum FolderPathMetadataParser: Sendable {

    // MARK: - Precompiled Regular Expressions

    private static let discFolderRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(?:cd|disc|disk)\s*(\d+)(?:\s*[-–—:]\s*.*)?$"#, options: [.caseInsensitive])
    }()

    private static let qualityTagRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\s*[\(\[](?:flac|alac|mp3|web|cd|vinyl|sacd|dvd|audio\s*rip|remaster(?:ed)?|deluxe|hi-res|lossless|24[- ]?bit|24[-/ ]96|24[-/ ]192|16[-/ ]44(?:\.1)?|320k?|v0|v2)[\)\]]$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let trailingYearRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s*[\(\[](\d{4})[\)\]]$"#, options: [])
    }()

    private static let leadingYearRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(\d{4})\s*[-–—]\s*"#, options: [])
    }()

    private static let discTrackRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(\d+)[.-](\d{1,3})(?:\s*[-–—_.]\s*|\s+)"#, options: [])
    }()

    private static let standardTrackRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(\d{1,3})(?:\s*[-–—_.]\s*|\.\s+|\)\s*)"#, options: [])
    }()

    private static let bareTrackRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(\d{1,3})\s+"#, options: [])
    }()

    private static let genericFolderNames: Set<String> = [
        "music", "flac", "mp3", "lossless", "library", "itunes", "itunes music", "apple music",
        "media", "albums", "artists", "collection", "audio", "my music", "songs", "tracks"
    ]

    private static let compilationFolderNames: Set<String> = [
        "various artists", "va", "compilations", "soundtrack", "soundtracks", "ost"
    ]

    // MARK: - Main Parser Method

    public static func parse(relativePath: String) -> ParsedPathMetadata {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        var parts = normalized.components(separatedBy: "/").filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            return ParsedPathMetadata(artist: "Unknown Artist", album: "Unknown Album", title: "Unknown Title", albumDirectory: "")
        }

        var rawFilename = parts.removeLast()
        // Legacy iCloud stubs: .Name.ext.icloud -> Name.ext
        if rawFilename.hasPrefix(".") && rawFilename.hasSuffix(".icloud") {
            let dropLeading = String(rawFilename.dropFirst())
            let dropTrailing = String(dropLeading.dropLast(".icloud".count))
            rawFilename = dropTrailing
        } else if rawFilename.hasSuffix(".icloud") {
            rawFilename = String(rawFilename.dropLast(".icloud".count))
        }

        // Drop leading generic folders while more than one folder remains
        while parts.count > 1, let first = parts.first, genericFolderNames.contains(first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            parts.removeFirst()
        }

        var discNumber: Int? = nil
        // Check if last folder is a disc folder
        if let lastFolder = parts.last {
            let trimmedLast = lastFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(location: 0, length: trimmedLast.utf16.count)
            if let match = discFolderRegex.firstMatch(in: trimmedLast, options: [], range: range) {
                if let discRange = Range(match.range(at: 1), in: trimmedLast), let d = Int(trimmedLast[discRange]) {
                    discNumber = d
                    parts.removeLast()
                }
            }
        }

        var rawArtist: String = ""
        var rawAlbum: String = ""

        if parts.isEmpty {
            rawArtist = "Unknown Artist"
            rawAlbum = "Unknown Album"
        } else if parts.count == 1 {
            let single = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if single.contains(" - ") {
                let split = single.components(separatedBy: " - ")
                rawArtist = split[0].trimmingCharacters(in: .whitespacesAndNewlines)
                rawAlbum = split.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawArtist = single
                rawAlbum = single
            }
        } else {
            rawAlbum = parts.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
            rawArtist = parts.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Album directory key (artist and album folders joined, disc folders excluded)
        let albumDirectory: String
        if !rawArtist.isEmpty && !rawAlbum.isEmpty {
            albumDirectory = "\(rawArtist)/\(rawAlbum)"
        } else {
            albumDirectory = rawAlbum.isEmpty ? rawArtist : rawAlbum
        }

        // Album cleanup
        var cleanAlbum = rawAlbum
        var albumYear: Int? = nil

        var changed = true
        while changed {
            changed = false
            // Strip trailing bracketed quality tags
            let qRange = NSRange(location: 0, length: cleanAlbum.utf16.count)
            if let match = qualityTagRegex.firstMatch(in: cleanAlbum, options: [], range: qRange) {
                if let replaceRange = Range(match.range, in: cleanAlbum) {
                    cleanAlbum.removeSubrange(replaceRange)
                    cleanAlbum = cleanAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }

            // Trailing year (YYYY) / [YYYY]
            let yRange = NSRange(location: 0, length: cleanAlbum.utf16.count)
            if let match = trailingYearRegex.firstMatch(in: cleanAlbum, options: [], range: yRange) {
                if let yearNumRange = Range(match.range(at: 1), in: cleanAlbum), let y = Int(cleanAlbum[yearNumRange]) {
                    albumYear = y
                }
                if let replaceRange = Range(match.range, in: cleanAlbum) {
                    cleanAlbum.removeSubrange(replaceRange)
                    cleanAlbum = cleanAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }

        // Leading "YYYY - " sets the year
        let leadRange = NSRange(location: 0, length: cleanAlbum.utf16.count)
        if let match = leadingYearRegex.firstMatch(in: cleanAlbum, options: [], range: leadRange) {
            if let yearNumRange = Range(match.range(at: 1), in: cleanAlbum), let y = Int(cleanAlbum[yearNumRange]) {
                if albumYear == nil { albumYear = y }
            }
            if let replaceRange = Range(match.range, in: cleanAlbum) {
                cleanAlbum.removeSubrange(replaceRange)
                cleanAlbum = cleanAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Remove redundant "Artist - " prefix on album
        let redundantPrefix = "\(rawArtist) - "
        if cleanAlbum.hasPrefix(redundantPrefix) {
            cleanAlbum = String(cleanAlbum.dropFirst(redundantPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Compilation detection
        let lowerArtist = rawArtist.lowercased()
        let isCompilation = compilationFolderNames.contains(lowerArtist)
        let albumArtist = isCompilation ? "Various Artists" : (rawArtist.isEmpty ? nil : rawArtist)

        // Filename parsing
        var filenameNoExt = rawFilename
        if let dotIndex = filenameNoExt.lastIndex(of: ".") {
            filenameNoExt = String(filenameNoExt[..<dotIndex])
        }
        filenameNoExt = filenameNoExt.trimmingCharacters(in: .whitespacesAndNewlines)

        var trackNumber: Int? = nil
        var remainingTitle = filenameNoExt

        // Check "D-NN" or "D.NN"
        let dtRange = NSRange(location: 0, length: remainingTitle.utf16.count)
        if let match = discTrackRegex.firstMatch(in: remainingTitle, options: [], range: dtRange) {
            if let dRange = Range(match.range(at: 1), in: remainingTitle), let d = Int(remainingTitle[dRange]) {
                if discNumber == nil { discNumber = d }
            }
            if let tRange = Range(match.range(at: 2), in: remainingTitle), let t = Int(remainingTitle[tRange]) {
                trackNumber = t
            }
            if let fullMatch = Range(match.range, in: remainingTitle) {
                remainingTitle.removeSubrange(fullMatch)
                remainingTitle = remainingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let match = standardTrackRegex.firstMatch(in: remainingTitle, options: [], range: dtRange) {
            // "NN - ", "NN.", "NN)", "NN_"
            if let tRange = Range(match.range(at: 1), in: remainingTitle), let t = Int(remainingTitle[tRange]) {
                trackNumber = t
            }
            if let fullMatch = Range(match.range, in: remainingTitle) {
                remainingTitle.removeSubrange(fullMatch)
                remainingTitle = remainingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let match = bareTrackRegex.firstMatch(in: remainingTitle, options: [], range: dtRange) {
            // Bare "NN " prefix counts only with leading zero or value <= 50
            if let tRange = Range(match.range(at: 1), in: remainingTitle) {
                let trackStr = String(remainingTitle[tRange])
                if let t = Int(trackStr) {
                    let hasLeadingZero = trackStr.count > 1 && trackStr.hasPrefix("0")
                    if hasLeadingZero || t <= 50 {
                        trackNumber = t
                        if let fullMatch = Range(match.range, in: remainingTitle) {
                            remainingTitle.removeSubrange(fullMatch)
                            remainingTitle = remainingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
        }

        var finalTrackArtist = rawArtist
        var finalTitle = remainingTitle

        // Split remaining on " - " into artist and title
        if remainingTitle.contains(" - ") {
            let split = remainingTitle.components(separatedBy: " - ")
            let firstPart = split[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = split.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)

            if isCompilation {
                finalTrackArtist = firstPart
                finalTitle = rest
            } else if firstPart.caseInsensitiveCompare(rawArtist) == .orderedSame {
                finalTitle = rest
            } else if trackNumber != nil && split.count >= 3 {
                finalTrackArtist = firstPart
                finalTitle = rest
            }
        }

        return ParsedPathMetadata(
            artist: finalTrackArtist.isEmpty ? "Unknown Artist" : finalTrackArtist,
            albumArtist: albumArtist,
            album: cleanAlbum.isEmpty ? "Unknown Album" : cleanAlbum,
            year: albumYear,
            discNumber: discNumber,
            trackNumber: trackNumber,
            title: finalTitle.isEmpty ? filenameNoExt : finalTitle,
            isCompilation: isCompilation,
            albumDirectory: albumDirectory
        )
    }
}
