//
//  MetadataSanitizer.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation

/// High-performance metadata and filename sanitization engine.
/// Extracts clean core identity attributes and isolates contextual modifiers (remixes, features, live, remasters)
/// to produce stripped search query strings and structured matching signatures.
public enum MetadataSanitizer {

    // MARK: - Regular Expressions (Compiled Once)

    private static let fileExtensionRegex = try? NSRegularExpression(
        pattern: #"\.(?:mp3|m4a|flac|wav|aac|aiff|alac|ogg|wma|opus|m4p)$"#,
        options: [.caseInsensitive]
    )

    // Strictly matches track number prefixes: "01 - ", "1. ", "01 ", "Track 01 ", "1.01 ", "A1 - "
    // Will NEVER match standard numbers in song titles like "27 Club", "151 Rum", "30 Hours", "7 Rings", "1985"
    private static let trackNumberPrefixRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:(?:track\s*)?\d{1,3}\s*[\.\-_]\s*|(?:track\s+)\d{1,3}\s+|0\d\s+|[A-Z]\d{1,2}\s*[\.\-_]\s*|\d{1,2}\.\d{1,2}\s*[\.\-_]?\s*)"#,
        options: [.caseInsensitive]
    )

    // Matches features in brackets: "(feat. Drake)", "[ft. 21 Savage]", "(with Future)"
    // or trailing feature statements: "- feat. Drake", "feat. Drake"
    private static let bracketedFeatureRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*(?:feat\.?|ft\.?|featuring|with|vs\.?)\s+([^\)\]\}]+)[\)\]\}]"#,
        options: [.caseInsensitive]
    )

    private static let trailingFeatureRegex = try? NSRegularExpression(
        pattern: #"(?:\s+-\s*|\s+)(?:feat\.?|ft\.?|featuring)\s+(.+)$"#,
        options: [.caseInsensitive]
    )

    // Matches version modifiers strictly inside brackets "(Remix)", "[Club Mix]" or after a dash " - Radio Edit"
    private static let bracketedVersionRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*([^\(\)\[\]\{\}]+?(?:remix|club\s+mix|radio\s+edit|extended(?:\s+(?:mix|version))?|acoustic|instrumental|dub\s+mix|vip|mix|edit|version))\s*[\)\]\}]"#,
        options: [.caseInsensitive]
    )

    private static let trailingVersionRegex = try? NSRegularExpression(
        pattern: #"\s+-\s*([^\-\(\)\[\]\{\}]+?(?:remix|club\s+mix|radio\s+edit|extended(?:\s+(?:mix|version))?|acoustic|instrumental|dub\s+mix|vip|mix|edit|version))\s*$"#,
        options: [.caseInsensitive]
    )

    private static let liveRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*(?:live(?:\s+at|\s+from|\s+in|\s+session)?(?:[^\)\]\}]*))[\)\]\}]|\s+-\s*live(?:\s+at|\s+from|\s+in|\s+session)?.*$"#,
        options: [.caseInsensitive]
    )

    private static let remasterRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*(?:(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?)\s*[\)\]\}]|\s+-\s*(?:(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?)\s*$"#,
        options: [.caseInsensitive]
    )

    private static let generalNoiseRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*(?:official\s+audio|official\s+video|official|audio|video|lyrics|bonus\s+track|deluxe(?:\s+edition)?|320kbps|flac|lossless|hq|hd|mono|stereo)\s*[\)\]\}]|\s*-\s*(?:official|audio|video|lyrics).*$"#,
        options: [.caseInsensitive]
    )

    private static let producerAndHostRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*(?:(?:prd|prod|produced)\.?\s+by|hosted\s+by|lyrics\s+sync|snippet|leak).*?[\)\]\}]"#,
        options: [.caseInsensitive]
    )

    // MARK: - Public API

    /// Analyzes a Track entity and produces a stripped search query string and a structured `TrackSignature`.
    public static func sanitize(track: Track) -> TrackSignature {
        let rawTitle = track.title
        let rawArtist = track.artist
        let rawAlbum = track.album

        // If local metadata is generic or missing, attempt to extract from filename URL
        var parsedTitle = rawTitle
        var parsedArtist = rawArtist
        var parsedAlbum = rawAlbum

        if isGenericOrEmpty(rawTitle) || isGenericOrEmpty(rawArtist) {
            if let fromFilename = parseFilename(url: track.url) {
                if isGenericOrEmpty(parsedTitle) { parsedTitle = fromFilename.title }
                if isGenericOrEmpty(parsedArtist) { parsedArtist = fromFilename.artist }
            }
        }

        return buildSignature(
            title: parsedTitle,
            artist: parsedArtist,
            album: parsedAlbum,
            duration: track.duration,
            trackNumber: track.trackNumber
        )
    }

    /// Builds a structured signature from explicit title, artist, album, and duration.
    public static func buildSignature(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval = 0,
        trackNumber: Int? = nil
    ) -> TrackSignature {
        var cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip file extension if present in title
        if let extRegex = fileExtensionRegex {
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = extRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // 2. Strip track number prefix ("01 - ", "1.01 ", "A1 ")
        if let numRegex = trackNumberPrefixRegex {
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = numRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // 3. Extract and isolate features
        var featuredArtists: [String] = []
        if let bracketRegex = bracketedFeatureRegex {
            let nsTitle = cleanTitle as NSString
            let matches = bracketRegex.matches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length))
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let featStr = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let parsed = ArtistParser.parseArtists(from: featStr)
                    featuredArtists.append(contentsOf: parsed)
                }
            }
            cleanTitle = bracketRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        if let trailRegex = trailingFeatureRegex {
            let nsTitle = cleanTitle as NSString
            let matches = trailRegex.matches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length))
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let featStr = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let parsed = ArtistParser.parseArtists(from: featStr)
                    featuredArtists.append(contentsOf: parsed)
                }
            }
            cleanTitle = trailRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // Also extract features from the artist field if present
        let parsedArtists = ArtistParser.parseArtists(from: artist)
        let primaryArtist = parsedArtists.first ?? artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsedArtists.count > 1 {
            for guest in parsedArtists.dropFirst() {
                if !featuredArtists.contains(guest) {
                    featuredArtists.append(guest)
                }
            }
        }

        // 4. Extract version modifier (Remix, Club Mix, Acoustic, etc.)
        var versionModifier: String? = nil
        if let verRegex = bracketedVersionRegex {
            let nsTitle = cleanTitle as NSString
            if let match = verRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) {
                if match.numberOfRanges >= 2 && match.range(at: 1).location != NSNotFound {
                    versionModifier = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            cleanTitle = verRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        if versionModifier == nil, let trailVerRegex = trailingVersionRegex {
            let nsTitle = cleanTitle as NSString
            if let match = trailVerRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) {
                if match.numberOfRanges >= 2 && match.range(at: 1).location != NSNotFound {
                    versionModifier = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            cleanTitle = trailVerRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // 5. Detect Live Tag
        var isLive = false
        if let liveRegex = liveRegex {
            let nsTitle = cleanTitle as NSString
            if liveRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) != nil {
                isLive = true
            }
            cleanTitle = liveRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // 6. Detect Remaster Tag
        var isRemaster = false
        if let remRegex = remasterRegex {
            let nsTitle = cleanTitle as NSString
            if remRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) != nil {
                isRemaster = true
            }
            cleanTitle = remRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // 7. Strip general noise ("[Official Audio]", "320kbps", etc.)
        if let noiseRegex = generalNoiseRegex {
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = noiseRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // 7.5 Strip producer and hosting tags ("[Prd. by ...]", "[Hosted by ...]")
        if let prodRegex = producerAndHostRegex {
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = prodRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // Normalize spaces and cleanly balance surrounding punctuation
        cleanTitle = sanitizeBracketsAndPunctuation(cleanTitle)

        let standardAlbum = DeluxeAlbumDetector.cleanToStandardAlbumName(album).trimmingCharacters(in: .whitespacesAndNewlines)

        // 8. Build stripped minimal search query
        var queryParts: [String] = []
        let searchableTitle = cleanSearchTerm(cleanTitle)
        let searchableArtist = cleanSearchTerm(primaryArtist)
        if !searchableTitle.isEmpty { queryParts.append(searchableTitle) }
        if !searchableArtist.isEmpty && !isUnknownArtist(searchableArtist) { queryParts.append(searchableArtist) }
        let searchQuery = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        return TrackSignature(
            searchQuery: searchQuery,
            coreTitle: cleanTitle.isEmpty ? title : cleanTitle,
            primaryArtist: primaryArtist.isEmpty ? artist : primaryArtist,
            standardAlbum: standardAlbum.isEmpty ? album : standardAlbum,
            featuredArtists: featuredArtists,
            versionModifier: versionModifier,
            isLive: isLive,
            isRemaster: isRemaster,
            duration: duration,
            trackNumber: trackNumber
        )
    }

    // MARK: - Filename Parsing Fallback

    /// Parses artist and title from standard file naming conventions (e.g., "01 - Artist - Title.mp3", "Artist - Title.m4a").
    public static func parseFilename(url: URL) -> (title: String, artist: String)? {
        var rawName = url.deletingPathExtension().lastPathComponent

        // Strip track number prefixes
        if let numRegex = trackNumberPrefixRegex {
            let nsRange = NSRange(location: 0, length: (rawName as NSString).length)
            rawName = numRegex.stringByReplacingMatches(in: rawName, options: [], range: nsRange, withTemplate: "")
        }

        let parts = rawName.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty && !title.isEmpty {
                return (title: title, artist: artist)
            }
        }
        return nil
    }

    // MARK: - Completeness Pre-Check (Zero Network Cost)

    /// Evaluates if a track already has all core metadata fields and artwork populated.
    public static func isFullyTagged(track: Track) -> Bool {
        guard !isGenericOrEmpty(track.title) else { return false }
        guard !isUnknownArtist(track.artist) else { return false }
        guard !isUnknownAlbum(track.album) else { return false }
        guard let year = track.year, year > 1900 else { return false }
        guard let trackNum = track.trackNumber, trackNum > 0 else { return false }
        guard let artKey = track.artworkKey, !artKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Constructs a verified OnlineTrackMetadata model from an already complete local track.
    public static func synthesizeVerifiedMetadata(for track: Track) -> OnlineTrackMetadata {
        OnlineTrackMetadata(
            id: "local_verified_\(track.id.uuidString)",
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumArtist: track.albumArtist ?? track.artist,
            releaseDate: track.year.flatMap { Calendar.current.date(from: DateComponents(year: $0, month: 1, day: 1)) },
            releaseYear: track.year,
            genre: track.genre,
            trackNumber: track.trackNumber,
            totalTracks: track.totalTracks,
            discNumber: track.discNumber,
            duration: track.duration > 0 ? track.duration : nil,
            artworkURL: nil,
            previewURL: nil,
            sourceAPI: "Local Verification (Complete)",
            isCompilation: false
        )
    }

    public static func cleanSearchTerm(_ term: String) -> String {
        term.replacingOccurrences(of: #"[\(\)\[\]\{\}\"\'_#~]"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func isGenericOrEmpty(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("track") || trimmed.hasPrefix("audiotrack") || trimmed.hasPrefix("untitled") || trimmed == "unknown" || trimmed == "unknown artist" || trimmed == "unknown album" {
            return true
        }
        return false
    }

    public static func isUnknownArtist(_ artist: String) -> Bool {
        let lower = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.isEmpty || lower == "unknown artist" || lower == "unknown" || lower == "various artists"
    }

    public static func isUnknownAlbum(_ album: String) -> Bool {
        let lower = album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.isEmpty || lower == "unknown album" || lower == "unknown"
    }

    private static func sanitizeBracketsAndPunctuation(_ text: String) -> String {
        var str = text
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.,/\\"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Balance unclosed parentheses
        let openParen = str.filter { $0 == "(" }.count
        let closeParen = str.filter { $0 == ")" }.count
        if openParen > closeParen {
            if str.hasSuffix("(") {
                str.removeLast()
            } else {
                str.append(String(repeating: ")", count: openParen - closeParen))
            }
        } else if closeParen > openParen {
            if str.hasSuffix(")") {
                str.removeLast()
            }
        }

        // Balance unclosed square brackets
        let openBracket = str.filter { $0 == "[" }.count
        let closeBracket = str.filter { $0 == "]" }.count
        if openBracket > closeBracket {
            if str.hasSuffix("[") {
                str.removeLast()
            } else {
                str.append(String(repeating: "]", count: openBracket - closeBracket))
            }
        } else if closeBracket > openBracket {
            if str.hasSuffix("]") {
                str.removeLast()
            }
        }

        return str.trimmingCharacters(in: CharacterSet(charactersIn: " -_.,/\\"))
    }
}

