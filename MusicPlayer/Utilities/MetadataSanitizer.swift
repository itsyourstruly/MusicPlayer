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
        // Raw title
        let rawTitle = track.title
        // Raw artist
        let rawArtist = track.artist
        // Raw album
        let rawAlbum = track.album

        // If local metadata is generic or missing, attempt to extract from filename URL
        var parsedTitle = rawTitle
        // Parsed artist
        var parsedArtist = rawArtist
        // Parsed album
        let parsedAlbum = rawAlbum

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
        // Clean title
        var cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip file extension if present in title
        if let extRegex = fileExtensionRegex {
            // Ns range
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = extRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // 2. Strip track number prefix ("01 - ", "1.01 ", "A1 ")
        if let numRegex = trackNumberPrefixRegex {
            // Ns range
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = numRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // 3. Extract and isolate features
        var featuredArtists: [String] = []
        if let bracketRegex = bracketedFeatureRegex {
            // Ns title
            let nsTitle = cleanTitle as NSString
            // Matches
            let matches = bracketRegex.matches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length))
            for match in matches {
                if match.numberOfRanges >= 2 {
                    // Feat str
                    let featStr = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Parsed
                    let parsed = ArtistParser.parseArtists(from: featStr)
                    featuredArtists.append(contentsOf: parsed)
                }
            }
            cleanTitle = bracketRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        if let trailRegex = trailingFeatureRegex {
            // Ns title
            let nsTitle = cleanTitle as NSString
            // Matches
            let matches = trailRegex.matches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length))
            for match in matches {
                if match.numberOfRanges >= 2 {
                    // Feat str
                    let featStr = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Parsed
                    let parsed = ArtistParser.parseArtists(from: featStr)
                    featuredArtists.append(contentsOf: parsed)
                }
            }
            cleanTitle = trailRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // Also extract features from the artist field if present
        let parsedArtists = ArtistParser.parseArtists(from: artist)
        // Primary artist
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
            // Ns title
            let nsTitle = cleanTitle as NSString
            if let match = verRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) {
                if match.numberOfRanges >= 2 && match.range(at: 1).location != NSNotFound {
                    versionModifier = nsTitle.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            cleanTitle = verRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        if versionModifier == nil, let trailVerRegex = trailingVersionRegex {
            // Ns title
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
            // Ns title
            let nsTitle = cleanTitle as NSString
            if liveRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) != nil {
                isLive = true
            }
            cleanTitle = liveRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // 6. Detect Remaster Tag
        var isRemaster = false
        if let remRegex = remasterRegex {
            // Ns title
            let nsTitle = cleanTitle as NSString
            if remRegex.firstMatch(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length)) != nil {
                isRemaster = true
            }
            cleanTitle = remRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: NSRange(location: 0, length: nsTitle.length), withTemplate: "")
        }

        // 7. Strip general noise ("[Official Audio]", "320kbps", etc.)
        if let noiseRegex = generalNoiseRegex {
            // Ns range
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = noiseRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // 7.5 Strip producer and hosting tags ("[Prd. by ...]", "[Hosted by ...]")
        if let prodRegex = producerAndHostRegex {
            // Ns range
            let nsRange = NSRange(location: 0, length: (cleanTitle as NSString).length)
            cleanTitle = prodRegex.stringByReplacingMatches(in: cleanTitle, options: [], range: nsRange, withTemplate: "")
        }

        // Normalize spaces and cleanly balance surrounding punctuation
        cleanTitle = sanitizeBracketsAndPunctuation(cleanTitle)

        // Standard album
        let standardAlbum = DeluxeAlbumDetector.cleanToStandardAlbumName(album).trimmingCharacters(in: .whitespacesAndNewlines)

        // 8. Build stripped minimal search query
        var queryParts: [String] = []
        // Searchable title
        let searchableTitle = cleanSearchTerm(cleanTitle)
        // Searchable artist
        let searchableArtist = cleanSearchTerm(primaryArtist)
        if !searchableTitle.isEmpty { queryParts.append(searchableTitle) }
        if !searchableArtist.isEmpty && !isUnknownArtist(searchableArtist) { queryParts.append(searchableArtist) }
        // Search query
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
        // Raw name
        var rawName = url.deletingPathExtension().lastPathComponent

        // Strip track number prefixes
        if let numRegex = trackNumberPrefixRegex {
            // Ns range
            let nsRange = NSRange(location: 0, length: (rawName as NSString).length)
            rawName = numRegex.stringByReplacingMatches(in: rawName, options: [], range: nsRange, withTemplate: "")
        }

        // Parts
        let parts = rawName.components(separatedBy: " - ")
        if parts.count >= 2 {
            // Primary artist name
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            // Display title
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty && !title.isEmpty {
                return (title: title, artist: artist)
            }
        }
        return nil
    }

    // MARK: - Completeness Pre-Check (Zero Network Cost)

    /// Evaluates if a track has all essential metadata spots filled (Title, Artist, Album, Year, and Artwork).
    public static func hasAllSpotsFilled(track: Track) -> Bool {
        guard !isGenericOrEmpty(track.title) else { return false }
        guard !isUnknownArtist(track.artist) else { return false }
        guard !isUnknownAlbum(track.album) else { return false }
        guard let year = track.year, (1900...2099).contains(year) else { return false }
        guard let artKey = track.artworkKey, !artKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Evaluates if a track already has all core metadata fields and artwork populated.
    public static func isFullyTagged(track: Track) -> Bool {
        hasAllSpotsFilled(track: track)
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

    // Clean search term
    public static func cleanSearchTerm(_ term: String) -> String {
        term.replacingOccurrences(of: #"[\(\)\[\]\{\}\"\'_#~]"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Preserves exact artist name strings for catalog queries, stripping only outer wrapping quotes or brackets.
    public static func cleanArtistSearchTerm(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = trimmed
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) ||
           (cleaned.hasPrefix("(") && cleaned.hasSuffix(")")) ||
           (cleaned.hasPrefix("[") && cleaned.hasSuffix("]")) {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    // Is generic or empty
    public static func isGenericOrEmpty(_ string: String) -> Bool {
        // Trimmed
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("track") || trimmed.hasPrefix("audiotrack") || trimmed.hasPrefix("untitled") || trimmed == "unknown" || trimmed == "unknown artist" || trimmed == "unknown album" {
            return true
        }
        return false
    }

    // Is unknown artist
    public static func isUnknownArtist(_ artist: String) -> Bool {
        // Lower
        let lower = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.isEmpty || lower == "unknown artist" || lower == "unknown" || lower == "various artists"
    }

    // Is unknown album
    public static func isUnknownAlbum(_ album: String) -> Bool {
        // Lower
        let lower = album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.isEmpty || lower == "unknown album" || lower == "unknown"
    }

    // MARK: - Remix, Alternate Version & Live Detection & Album Routing

    public static func isFreestyleOrBonusTrack(title: String, album: String = "") -> Bool {
        let titleLower = title.lowercased()
        let albumLower = album.lowercased()
        let keywords = ["freestyle", "bonus track", "bonus cut", "bonus song", "bonus"]
        return keywords.contains { titleLower.contains($0) || albumLower.contains($0) }
    }

    private static let alternateVersionRegex = try? NSRegularExpression(
        pattern: #"[\(\[\{]\s*(?:clear\s+channel|heineken|red\s+star|session|sessions|live\s+session|bbc|live\s+lounge|tiny\s*desk|spotify\s+session|apple\s+music\s+session|itunes\s+session|aol\s+session|stripped|unplugged|mtv|exclusive|performance|snippet|demo|unreleased|alternate|alternative|alt\.?\s+take|take\s+\d+|rough\s+mix|work\s+in\s+progress|wip|early\s+version|outtake|b-side|clean\s+version|explicit\s+version|instrumental|acapella|a\s+cappella|orchestral|acoustic|dub|vip|re-?mix|club\s+mix|extended|radio\s+edit|radio\s+version|dance\s+mix|slowed|reverb|sped\s+up|speed\s+up|chopped\s+(?:and|&)\s+screwed|mash-?up|re-?work|re-?edit|bootleg|nightcore|daycore|intro\s+version|outro\s+version|single\s+version|album\s+version|re-?recorded|flip|mix|edit|version).*?[\)\]\}]|\s+-\s*(?:clear\s+channel|heineken|red\s+star|session|sessions|live\s+session|bbc|live\s+lounge|tiny\s*desk|stripped|unplugged|mtv|exclusive|performance|snippet|demo|unreleased|alternate|alternative|rough\s+mix|outtake|b-side|clean\s+version|instrumental|acapella|acoustic|dub|vip|re-?mix|extended|radio\s+edit|radio\s+version|slowed|sped\s+up|mash-?up|re-?work|re-?edit|bootleg|nightcore|re-?recorded|flip|mix|edit|version).*$"#,
        options: [.caseInsensitive]
    )

    private static let remixKeywords: [String] = [
        "remix", "re-mix", "club mix", "dub mix", "vip mix", "vip", "extended mix",
        "extended version", "acoustic version", "acoustic", "instrumental",
        "sped up", "speed up", "slowed + reverb", "slowed & reverb", "slowed down",
        "chopped and screwed", "chopped & screwed", "radio edit", "dance mix",
        "bootleg", "nightcore", "daycore", "flip", "acapella", "a cappella", "orchestral",
        "stripped", "demo", "unreleased", "alternate", "alternative",
        "session", "sessions", "clear channel", "heineken", "red star", "bbc",
        "live lounge", "tinydesk", "tiny desk", "mtv", "unplugged", "exclusive",
        "outtake", "b-side", "rough mix", "re-recorded", "rerecorded",
        "snippet", "clean version", "explicit version", "radio version", "re-edit",
        "re-work", "rework", "mashup", "mash-up", "intro version", "outro version"
    ]

    private static let liveKeywords: [String] = [
        "live at", "live in", "live from", "(live)", "[live]", "- live",
        "live recording", "recorded live", "in concert", "live session", "unplugged",
        "live festival", "tour live"
    ]

    /// Determines if a track title or album title indicates a remix or alternate version.
    public static func isRemixOrAlternateVersion(title: String, album: String = "") -> Bool {
        // Freestyles and bonus tracks stay in singles, not alternates/remixes
        if isFreestyleOrBonusTrack(title: title, album: album) {
            return false
        }

        let titleLower = title.lowercased()
        let albumLower = album.lowercased()

        // 1. Regex evaluation for bracketed or trailing descriptors (e.g. "Jesus Walks (Clear Channel...)")
        if let regex = alternateVersionRegex {
            let nsTitle = title as NSString
            if regex.firstMatch(in: title, options: [], range: NSRange(location: 0, length: nsTitle.length)) != nil {
                return true
            }
            let nsAlbum = album as NSString
            if regex.firstMatch(in: album, options: [], range: NSRange(location: 0, length: nsAlbum.length)) != nil {
                return true
            }
        }

        // 2. Keyword check
        for kw in remixKeywords {
            if titleLower.contains(kw) || albumLower.contains(kw) {
                return true
            }
        }
        return false
    }

    /// Determines if a track title or album title indicates a live concert recording.
    public static func isLiveRecording(title: String, album: String = "") -> Bool {
        let titleLower = title.lowercased()
        let albumLower = album.lowercased()
        for kw in liveKeywords {
            if titleLower.contains(kw) || albumLower.contains(kw) {
                return true
            }
        }
        return false
    }

    /// Generates clean album title for alternates without appending "(Alternates)".
    public static func remixAlbumName(forStandardAlbum rawAlbum: String) -> String {
        var clean = DeluxeAlbumDetector.cleanToStandardAlbumName(rawAlbum).trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean.lowercased() == "unknown album" || clean.lowercased() == "unknown" {
            return rawAlbum.isEmpty ? "Unknown Album" : rawAlbum
        }
        if clean.hasSuffix(" (Alternates)") {
            clean = String(clean.dropLast(" (Alternates)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasSuffix("(Alternates)") {
            clean = String(clean.dropLast("(Alternates)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean.isEmpty ? rawAlbum : clean
    }

    /// Generates clean Live album title (e.g. "Graduation (Live)").
    public static func liveAlbumName(forStandardAlbum rawAlbum: String) -> String {
        let clean = DeluxeAlbumDetector.cleanToStandardAlbumName(rawAlbum).trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean.lowercased() == "unknown album" || clean.lowercased() == "unknown" {
            return "Live"
        }
        if clean.hasSuffix("(Live)") {
            return clean
        }
        return "\(clean) (Live)"
    }

    // MARK: - 4-Digit Release Year Extractor

    private static let fourDigitYearRegex = try? NSRegularExpression(
        pattern: #"\b(19\d{2}|20\d{2})\b"#,
        options: []
    )

    /// Extracts a 4-digit release year (1900..2099) from any date, timestamp, or freeform metadata string.
    public static func extract4DigitYear(from text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let nsText = text as NSString
        if let match = fourDigitYearRegex?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            if let yearInt = Int(nsText.substring(with: match.range)), (1900...2099).contains(yearInt) {
                return yearInt
            }
        }
        let digits = text.filter { $0.isNumber }
        if digits.count >= 4, let y = Int(digits.prefix(4)), (1900...2099).contains(y) {
            return y
        }
        return nil
    }

    // Sanitize brackets and punctuation
    private static func sanitizeBracketsAndPunctuation(_ text: String) -> String {
        // Str
        var str = text
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.,/\\"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Balance unclosed parentheses
        let openParen = str.filter { $0 == "(" }.count
        // Close paren
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
        // Close bracket
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

    // MARK: - String Normalization & Canonical Genre Taxonomy

    /// Strips diacritics, accents, and decomposes unicode characters for uniform matching.
    public static func stripDiacriticsAndAccents(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Normalizes raw scraped genres to canonical standard taxonomies (ID3/Apple/Deezer standards).
    public static func normalizeGenre(_ rawGenre: String?) -> String? {
        guard let raw = rawGenre?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = stripDiacriticsAndAccents(raw).lowercased()

        if lower == "unknown genre" || lower == "unknown" || lower == "other" || lower == "—" || lower == "-" || lower == "none" {
            return nil
        }

        // Canonical mapping table
        if lower.contains("hip hop") || lower.contains("hip-hop") || lower.contains("rap") || lower.contains("trap") || lower.contains("drill") {
            return "Hip-Hop/Rap"
        }
        if lower.contains("r&b") || lower.contains("rnb") || lower.contains("soul") || lower.contains("neo-soul") || lower.contains("motown") {
            return "R&B/Soul"
        }
        if lower.contains("alt") || lower.contains("indie") || lower.contains("grunge") || lower.contains("shoegaze") {
            return "Alternative"
        }
        if lower.contains("metal") || lower.contains("deathcore") || lower.contains("metalcore") || lower.contains("thrash") {
            return "Metal"
        }
        if lower.contains("hard rock") || lower.contains("classic rock") || lower.contains("punk") || lower.contains("rock") {
            return "Rock"
        }
        if lower.contains("synthpop") || lower.contains("synth-pop") || lower.contains("electropop") || lower.contains("dance pop") || lower.contains("pop") || lower.contains("k-pop") || lower.contains("j-pop") {
            return "Pop"
        }
        if lower.contains("electronic") || lower.contains("edm") || lower.contains("house") || lower.contains("techno") || lower.contains("trance") || lower.contains("dubstep") || lower.contains("dance") || lower.contains("ambient") || lower.contains("drum and bass") || lower.contains("dnb") {
            return "Electronic"
        }
        if lower.contains("jazz") || lower.contains("bebop") || lower.contains("swing") || lower.contains("bossa nova") {
            return "Jazz"
        }
        if lower.contains("classical") || lower.contains("baroque") || lower.contains("orchestral") || lower.contains("symphony") || lower.contains("opera") {
            return "Classical"
        }
        if lower.contains("country") || lower.contains("bluegrass") || lower.contains("americana") {
            return "Country"
        }
        if lower.contains("reggae") || lower.contains("dancehall") || lower.contains("dub") || lower.contains("ska") {
            return "Reggae"
        }
        if lower.contains("latin") || lower.contains("reggaeton") || lower.contains("salsa") || lower.contains("bachata") || lower.contains("cumbia") {
            return "Latin"
        }
        if lower.contains("soundtrack") || lower.contains("score") || lower.contains("ost") || lower.contains("film") || lower.contains("video game") {
            return "Soundtrack"
        }
        if lower.contains("folk") || lower.contains("acoustic") || lower.contains("singer-songwriter") {
            return "Folk"
        }
        if lower.contains("blues") {
            return "Blues"
        }

        // Return title-cased trimmed original if not in mapping table
        return raw.capitalized
    }
}


