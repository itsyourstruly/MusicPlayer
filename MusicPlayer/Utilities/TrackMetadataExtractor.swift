import Foundation

/// Structured metadata extracted from audio track titles, file names, and folder hierarchies.
public struct ExtractedTitleMetadata: Sendable, Equatable {
    /// The sanitized, clean song title (free of track numbers, redundant artist prefixes, and download noise).
    public let cleanTitle: String
    /// The extracted or confirmed primary artist name, if identified.
    public let artist: String?
    /// The extracted track number, if detected.
    public let trackNumber: Int?
    /// The extracted disc number, if detected (e.g. from "1-04" or "CD2-03").
    public let discNumber: Int?
    /// Individual featured artists extracted from the title or artist token.
    public let featuredArtists: [String]
    /// Release year extracted from title tags (e.g. "(1999)"), if missing from tags.
    public let year: Int?

    public init(
        cleanTitle: String,
        artist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        featuredArtists: [String] = [],
        year: Int? = nil
    ) {
        self.cleanTitle = cleanTitle
        self.artist = artist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.featuredArtists = featuredArtists
        self.year = year
    }
}

/// Intelligent, zero-false-positive extraction engine for local audio track titles and file names.
///
/// Designed to parse formats such as:
/// - `"(track #). (artist) - (title)"` (e.g. `01. Drake - Hotline Bling`)
/// - `"[02] Kendrick Lamar - HUMBLE. (Official Audio)"`
/// - `"1-04. Queen - Bohemian Rhapsody (2011 Remaster)"`
/// - `"Dua Lipa - 07 - Levitating"`
/// - `"[Travis Scott] SICKO MODE"`
/// - `"06 The Weeknd - Starboy"`
///
/// Strict rules ensure genuine song titles with numbers or hyphens
/// (e.g. *"1985"*, *"1999"*, *"24K Magic"*, *"30 Hours"*, *"151 Rum"*, *"7 Rings"*, *"Jay-Z"*, *"Blink-182"*)
/// are never falsely stripped.
public enum TrackMetadataExtractor: Sendable {

    // MARK: - Precompiled Regular Expressions

    private static let fileExtensionRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\.(?:mp3|m4a|flac|wav|aac|aiff|alac|ogg|wma|opus|m4p)$"#,
            options: [.caseInsensitive]
        )
    }()

    // Matches multi-disc prefixes: "1-01. ", "CD2-04 - ", "Disc 1 - 05. ", "1.04 "
    private static let discTrackPrefixRegex: NSRegularExpression? = {
        let pattern = #"^(?:(?:cd|disc)\s*([1-9])[\s\.\-_]+)?([1-9])[\.\-](0\d|\d{2,3})[\s\.\-_]+"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Matches vinyl side prefixes: "A1 - ", "B02. "
    private static let vinylSidePrefixRegex: NSRegularExpression? = {
        let pattern = #"^([A-Da-d])(\d{1,2})[\s\.\-_]+"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Matches bracketed track numbers: "[01] ", "(02) - ", "[3]. "
    private static let bracketedTrackPrefixRegex: NSRegularExpression? = {
        let pattern = #"^[\[\(](\d{1,3})[\]\)][\s\.\-_]*"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Matches explicit track word prefixes: "Track 01 - ", "Trk. 02 ", "Track 3. "
    private static let wordTrackPrefixRegex: NSRegularExpression? = {
        let pattern = #"^(?:track|trk)[\s\.\-_]*(\d{1,3})[\s\.\-_]+"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Matches standard track numbers followed by delimiter: "01. ", "1. ", "01 - ", "1 - ", "01_ "
    private static let standardDelimiterTrackRegex: NSRegularExpression? = {
        let pattern = #"^(\d{1,3})\s*[\.\-_]\s+"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Matches strictly two-digit numbers with leading zero followed by space: "01 Song Title"
    // Will NEVER match numbers like "1985", "24K Magic", "30 Hours", "151 Rum", "7 Rings"
    private static let leadingZeroTwoDigitTrackRegex: NSRegularExpression? = {
        let pattern = #"^(0[1-9])\s+"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Matches bracketed artist prefix: "[Travis Scott] SICKO MODE" or "[Daft Punk] - One More Time"
    private static let bracketedArtistRegex: NSRegularExpression? = {
        let pattern = #"^\[([^\]]+)\]\s*[-–—]?\s*(.+)$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Matches parenthesized artist prefix: "(Drake) - Hotline Bling"
    private static let parenthesizedArtistRegex: NSRegularExpression? = {
        let pattern = #"^\(([^)]+)\)\s*[-–—]\s*(.+)$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Matches YouTube and rip noise brackets
    private static let generalNoiseRegex: NSRegularExpression? = {
        let pattern = #"[\(\[\{]\s*(?:official\s+(?:audio|music\s+video|lyric\s+video|video)|lyric\s+video|visualizer|color\s+coded\s+lyrics|320kbps|lossless|flac|hq|hd|bonus\s+track)\s*[\)\]\}]|\s*-\s*(?:official\s+(?:audio|music\s+video|lyric\s+video|video)|visualizer)\s*$"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Matches year inside parentheses/brackets: "(1999)", "[2004]", "(2011 Remaster)"
    private static let bracketedYearRegex: NSRegularExpression? = {
        let pattern = #"[\(\[][^\)\]]*?\b(19\d{2}|20\d{2})\b[^\)\]]*[\)\]]"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    // Common artist-title delimiters
    private static let delimiters: [String] = [" - ", " — ", " – ", " _ ", " ~ "]

    // Known noise tokens that should never be treated as artist names
    private static let noiseTokens: Set<String> = [
        "official audio", "official video", "official music video",
        "official lyric video", "lyric video", "visualizer",
        "audio", "video", "lyrics", "hq", "hd", "320kbps", "flac"
    ]

    // MARK: - Public Extraction API

    /// Extracts clean title, artist, track number, disc number, features, and year from raw track title / filename.
    ///
    /// - Parameters:
    ///   - rawTitle: The initial title candidate (e.g. from ID3 tag or filename).
    ///   - existingArtist: Existing tagged artist if present.
    ///   - existingAlbum: Existing tagged album if present.
    ///   - existingAlbumArtist: Existing tagged album artist if present.
    ///   - existingTrackNumber: Existing tagged track number if present.
    ///   - existingDiscNumber: Existing tagged disc number if present.
    ///   - existingYear: Existing tagged release year if present.
    ///   - fallbackFilename: The raw audio file name (without path) used for fallback when rawTitle is generic.
    /// - Returns: An `ExtractedTitleMetadata` struct with cleaned components.
    public static func extract(
        rawTitle: String?,
        existingArtist: String? = nil,
        existingAlbum: String? = nil,
        existingAlbumArtist: String? = nil,
        existingTrackNumber: Int? = nil,
        existingDiscNumber: Int? = nil,
        existingYear: Int? = nil,
        fallbackFilename: String? = nil
    ) -> ExtractedTitleMetadata {
        let cleanFallback = fallbackFilename.flatMap { stripExtension($0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Decide which string to parse primarily
        let candidateString: String
        if let initial = initialTitle, !initial.isEmpty, !isGenericTitle(initial) {
            candidateString = stripExtension(initial)
        } else if let fb = cleanFallback, !fb.isEmpty {
            candidateString = fb
        } else {
            return ExtractedTitleMetadata(
                cleanTitle: "Unknown Title",
                artist: existingArtist,
                trackNumber: existingTrackNumber,
                discNumber: existingDiscNumber,
                featuredArtists: [],
                year: existingYear
            )
        }

        // Run extraction on the primary candidate string
        var parsed = parseString(
            candidateString,
            knownArtist: existingArtist,
            knownAlbumArtist: existingAlbumArtist
        )

        // If candidateString was title-only and didn't have artist/track info, but fallbackFilename is available,
        // attempt extracting missing components from filename
        if (parsed.artist == nil || parsed.trackNumber == nil),
           let fb = cleanFallback,
           fb != candidateString {
            let fbParsed = parseString(
                fb,
                knownArtist: existingArtist,
                knownAlbumArtist: existingAlbumArtist
            )

            let resolvedArtist = parsed.artist ?? fbParsed.artist
            let resolvedTrack = parsed.trackNumber ?? fbParsed.trackNumber
            let resolvedDisc = parsed.discNumber ?? fbParsed.discNumber
            let resolvedYear = parsed.year ?? fbParsed.year
            var combinedFeatures = parsed.featuredArtists
            for f in fbParsed.featuredArtists {
                if !combinedFeatures.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) {
                    combinedFeatures.append(f)
                }
            }

            parsed = ExtractedTitleMetadata(
                cleanTitle: parsed.cleanTitle,
                artist: resolvedArtist,
                trackNumber: resolvedTrack,
                discNumber: resolvedDisc,
                featuredArtists: combinedFeatures,
                year: resolvedYear
            )
        }

        // Corroborate and merge with existing metadata
        let finalTrackNumber = (existingTrackNumber != nil && existingTrackNumber! > 0)
            ? existingTrackNumber
            : parsed.trackNumber

        let finalDiscNumber = (existingDiscNumber != nil && existingDiscNumber! > 0)
            ? existingDiscNumber
            : parsed.discNumber

        let finalYear = (existingYear != nil && existingYear! > 0)
            ? existingYear
            : parsed.year

        // Determine authoritative artist:
        // If existingArtist is present and not generic, keep it unless extracted artist matches it (which we already know)
        var finalArtist = existingArtist
        if finalArtist == nil || isGenericArtist(finalArtist!) {
            if let extArt = parsed.artist, !extArt.isEmpty, !isGenericArtist(extArt) {
                finalArtist = extArt
            } else if let albArt = existingAlbumArtist, !albArt.isEmpty, !isGenericArtist(albArt) {
                finalArtist = albArt
            }
        }

        return ExtractedTitleMetadata(
            cleanTitle: parsed.cleanTitle.isEmpty ? "Unknown Title" : parsed.cleanTitle,
            artist: finalArtist,
            trackNumber: finalTrackNumber,
            discNumber: finalDiscNumber,
            featuredArtists: parsed.featuredArtists,
            year: finalYear
        )
    }

    // MARK: - Core Parsing Pipeline

    private static func parseString(
        _ raw: String,
        knownArtist: String?,
        knownAlbumArtist: String?
    ) -> ExtractedTitleMetadata {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else {
            return ExtractedTitleMetadata(cleanTitle: "Unknown Title")
        }

        var detectedDiscNumber: Int?
        var detectedTrackNumber: Int?
        var detectedArtist: String?
        var detectedYear: Int?

        // 1. Multi-disc + track prefix: e.g. "1-04. ", "CD1-05 - ", "2.03 "
        if let discRegex = discTrackPrefixRegex {
            let nsStr = working as NSString
            if let match = discRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                // Group 1: disc number from CD/Disc prefix (if any)
                // Group 2: disc number from X-YY
                // Group 3: track number
                var disc: Int?
                if match.range(at: 1).location != NSNotFound {
                    disc = Int(nsStr.substring(with: match.range(at: 1)))
                } else if match.range(at: 2).location != NSNotFound {
                    disc = Int(nsStr.substring(with: match.range(at: 2)))
                }
                var track: Int?
                if match.range(at: 3).location != NSNotFound {
                    track = Int(nsStr.substring(with: match.range(at: 3)))
                }

                if let t = track, t > 0 {
                    detectedTrackNumber = t
                    detectedDiscNumber = disc
                    let remainder = nsStr.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        working = remainder
                    }
                }
            }
        }

        // 2. Vinyl side prefix: e.g. "A1 - ", "B02. "
        if detectedTrackNumber == nil, let vinylRegex = vinylSidePrefixRegex {
            let nsStr = working as NSString
            if let match = vinylRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let sideChar = nsStr.substring(with: match.range(at: 1)).uppercased()
                let trackNum = Int(nsStr.substring(with: match.range(at: 2)))
                if let t = trackNum, t > 0 {
                    detectedTrackNumber = t
                    switch sideChar {
                    case "A": detectedDiscNumber = 1
                    case "B": detectedDiscNumber = 2
                    case "C": detectedDiscNumber = 3
                    case "D": detectedDiscNumber = 4
                    default: break
                    }
                    let remainder = nsStr.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        working = remainder
                    }
                }
            }
        }

        // 3. Bracketed track number: "[01] ", "(02) - "
        if detectedTrackNumber == nil, let bracketRegex = bracketedTrackPrefixRegex {
            let nsStr = working as NSString
            if let match = bracketRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let trackStr = nsStr.substring(with: match.range(at: 1))
                if let t = Int(trackStr), t > 0 {
                    detectedTrackNumber = t
                    let remainder = nsStr.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        working = remainder
                    }
                }
            }
        }

        // 4. Word track prefix: "Track 01 - ", "Trk. 02 "
        if detectedTrackNumber == nil, let wordRegex = wordTrackPrefixRegex {
            let nsStr = working as NSString
            if let match = wordRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let trackStr = nsStr.substring(with: match.range(at: 1))
                if let t = Int(trackStr), t > 0 {
                    detectedTrackNumber = t
                    let remainder = nsStr.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        working = remainder
                    }
                }
            }
        }

        // 5. Standard track number delimiter prefix: "01. ", "1 - ", "02_ "
        if detectedTrackNumber == nil, let stdRegex = standardDelimiterTrackRegex {
            let nsStr = working as NSString
            if let match = stdRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let trackStr = nsStr.substring(with: match.range(at: 1))
                if let t = Int(trackStr), t > 0 {
                    detectedTrackNumber = t
                    let remainder = nsStr.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        working = remainder
                    }
                }
            }
        }

        // 6. Two-digit leading-zero space prefix: "01 Song Title"
        if detectedTrackNumber == nil, let zeroRegex = leadingZeroTwoDigitTrackRegex {
            let nsStr = working as NSString
            if let match = zeroRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let trackStr = nsStr.substring(with: match.range(at: 1))
                if let t = Int(trackStr), t > 0 {
                    detectedTrackNumber = t
                    let remainder = nsStr.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        working = remainder
                    }
                }
            }
        }

        // 7. Bracketed artist prefix: "[Travis Scott] SICKO MODE"
        if let bktArtRegex = bracketedArtistRegex {
            let nsStr = working as NSString
            if let match = bktArtRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let artCandidate = nsStr.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let titleCandidate = nsStr.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidArtistToken(artCandidate) && !titleCandidate.isEmpty {
                    detectedArtist = artCandidate
                    working = titleCandidate
                }
            }
        }

        // 8. Parenthesized artist prefix: "(Drake) - Hotline Bling"
        if detectedArtist == nil, let parenArtRegex = parenthesizedArtistRegex {
            let nsStr = working as NSString
            if let match = parenArtRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let artCandidate = nsStr.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let titleCandidate = nsStr.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidArtistToken(artCandidate) && !titleCandidate.isEmpty {
                    detectedArtist = artCandidate
                    working = titleCandidate
                }
            }
        }

        // 9. Delimiter splitting: "Artist - Title", "Artist - 01 - Title", "Artist - Title - Subtitle"
        if detectedArtist == nil {
            for delim in delimiters {
                if working.contains(delim) {
                    let parts = working.components(separatedBy: delim)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    guard parts.count >= 2 else { continue }

                    // Pattern: "Artist - 01 - Title"
                    if parts.count >= 3, let middleTrack = Int(parts[1]), middleTrack > 0 {
                        detectedArtist = parts[0]
                        if detectedTrackNumber == nil {
                            detectedTrackNumber = middleTrack
                        }
                        working = parts[2...].joined(separator: " - ")
                        break
                    }

                    // Multi-part evaluation with known artist corroboration
                    let effectiveKnown = (knownArtist != nil && !isGenericArtist(knownArtist!))
                        ? knownArtist
                        : ((knownAlbumArtist != nil && !isGenericArtist(knownAlbumArtist!)) ? knownAlbumArtist : nil)

                    if let known = effectiveKnown {
                        let canonKnown = ArtistParser.canonicalArtistKey(known)
                        let canonPart0 = ArtistParser.canonicalArtistKey(parts[0])
                        let canonLast = ArtistParser.canonicalArtistKey(parts.last!)

                        if canonPart0 == canonKnown || parts[0].caseInsensitiveCompare(known) == .orderedSame {
                            detectedArtist = parts[0]
                            working = parts[1...].joined(separator: " - ")
                            break
                        } else if canonLast == canonKnown || parts.last!.caseInsensitiveCompare(known) == .orderedSame {
                            // Reverse order: "Title - Artist"
                            detectedArtist = parts.last!
                            working = parts.dropLast().joined(separator: " - ")
                            break
                        } else {
                            // Neither part matches known artist.
                            // The string is likely a title with a dash (e.g. "Song Name - Acoustic Version").
                            // Do not falsely extract parts[0] as artist.
                            break
                        }
                    } else {
                        // No known artist tag available: adopt parts[0] as artist if valid
                        if isValidArtistToken(parts[0]) {
                            detectedArtist = parts[0]
                            working = parts[1...].joined(separator: " - ")
                            break
                        }
                    }
                }
            }
        }

        // 10. Extract year if present in brackets (e.g. "(1999)", "[2004]", or "(2011 Remaster)")
        if let yearRegex = bracketedYearRegex {
            let nsStr = working as NSString
            if let match = yearRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: nsStr.length)) {
                let yrStr = nsStr.substring(with: match.range(at: 1))
                if let yr = Int(yrStr), (1900...2099).contains(yr) {
                    detectedYear = yr
                    let matchedSub = nsStr.substring(with: match.range).lowercased()
                    // Strip the bracket only if it's purely a year bracket (not version info like Remaster, Live, Deluxe, Mix)
                    let isPureYear = matchedSub.trimmingCharacters(in: CharacterSet(charactersIn: "()[] ")).count == 4
                    if isPureYear {
                        working = (working as NSString).replacingCharacters(in: match.range, with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }

        // 11. Remove YouTube / rip noise brackets
        if let noiseRegex = generalNoiseRegex {
            let nsRange = NSRange(location: 0, length: (working as NSString).length)
            working = noiseRegex.stringByReplacingMatches(in: working, options: [], range: nsRange, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 12. Featured artist extraction and normalization
        let featureCredit = ArtistParser.parseTitleFeaturedCredit(working)
        var featuredArtists = featureCredit.featuredArtists

        var cleanTitle = featureCredit.baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the title had unbracketed trailing "feat. X", restore standard "(feat. X)" formatting
        if featureCredit.hasFeaturedCredit && !working.contains("(") && !working.contains("[") {
            let featString = featuredArtists.joined(separator: ", ")
            cleanTitle = "\(cleanTitle) (feat. \(featString))"
        } else if featureCredit.hasFeaturedCredit && !cleanTitle.isEmpty {
            // Keep the clean base title plus the original bracketed feature if it was properly enclosed
            if working.contains("(") || working.contains("[") {
                cleanTitle = working
            }
        }

        // Clean up any double spaces, empty brackets, or trailing delimiters
        cleanTitle = sanitizePunctuation(cleanTitle.isEmpty ? working : cleanTitle)

        return ExtractedTitleMetadata(
            cleanTitle: cleanTitle.isEmpty ? raw : cleanTitle,
            artist: detectedArtist,
            trackNumber: detectedTrackNumber,
            discNumber: detectedDiscNumber,
            featuredArtists: featuredArtists,
            year: detectedYear
        )
    }

    // MARK: - Validation & Helpers

    private static func isValidArtistToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 100 else { return false }
        if Int(trimmed) != nil { return false }
        let lower = trimmed.lowercased()
        if noiseTokens.contains(lower) { return false }
        if ArtistParser.isGenericArtistName(trimmed) { return false }
        return true
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }
        if lower.hasPrefix("track") || lower.hasPrefix("audiotrack") || lower.hasPrefix("untitled") || lower == "unknown title" {
            return true
        }
        return false
    }

    private static func isGenericArtist(_ artist: String) -> Bool {
        ArtistParser.isGenericArtistName(artist)
    }

    private static func stripExtension(_ filename: String) -> String {
        guard let regex = fileExtensionRegex else { return filename }
        let nsRange = NSRange(location: 0, length: (filename as NSString).length)
        return regex.stringByReplacingMatches(in: filename, options: [], range: nsRange, withTemplate: "")
    }

    private static func sanitizePunctuation(_ text: String) -> String {
        var clean = text
        // Remove empty brackets: (), [], {}
        clean = clean.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\[\s*\]"#, with: "", options: .regularExpression)
        // Trim leading/trailing dashes and spaces
        clean = clean.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—_ ")))
        // Collapse multiple spaces
        clean = clean.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
