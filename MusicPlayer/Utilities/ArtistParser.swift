import Foundation

/// Represents an individual artist token in a multi-artist collaboration string along with its trailing separator.
public struct ArtistSegment: Identifiable, Hashable, Sendable {
    // Unique track identifier
    public var id: String { name }
    // Name
    public let name: String
    // The original separator text (e.g. " & ", " feat. ") preserved for round-trip display
    public let separatorAfter: String?

    // Initialize with configured properties
    public init(name: String, separatorAfter: String? = nil) {
        self.name = name
        self.separatorAfter = separatorAfter
    }
}

/// Robust parser for multi-artist metadata strings (supporting commas, ampersands, feat./ft., slashes, etc.)
public enum ArtistParser {
    // Known individual artists / bands with internal commas, ampersands, or slashes that should NOT be split into multiple artists
    private static let singleArtistExceptions: Set<String> = [
        "tyler, the creator",
        "earth, wind & fire",
        "crosby, stills, nash & young",
        "crosby, stills & nash",
        "blood, sweat & tears",
        "emerson, lake & palmer",
        "simon & garfunkel",
        "hall & oates",
        "kool & the gang",
        "kc & the sunshine band",
        "huey lewis & the news",
        "frankie lymon & the teenagers",
        "gladys knight & the pips",
        "joan jett & the blackhearts",
        "tom petty and the heartbreakers",
        "bob marley & the wailers",
        "ziggy marley & the melody makers",
        "sly & the family stone",
        "captain & tennille",
        "peaches & herb",
        "ashford & simpson",
        "sam & dave",
        "ike & tina turner",
        "brooks & dunn",
        "dan + shay",
        "florida georgia line",
        "above & beyond",
        "ac/dc"
    ]

    /// Checks whether an artist string is a protected single entity.
    public static func isSingleArtistException(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return singleArtistExceptions.contains(clean)
    }

    // Covers multi-artist delimiter conventions: &, and, feat., ft., featuring, with, vs., x, comma, semicolon, pipe, slash
    private static let delimiterPattern = #"(?:\s*;\s*|\s*\|\s*|\s+/\s+|\s*,\s*|\s+&\s+|\s+x\s+|\s+(?:feat\.?|ft\.?|featuring|with|vs\.?)\s+)"#

    // Compiled once at startup — NSRegularExpression is thread-safe after initialization
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: delimiterPattern, options: [.caseInsensitive])
    }()

    // Delimiter cleanup set
    private static let unwantedChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|/,()[]\""))

    // MARK: - Parsing

    /// Parses a raw artist string into discrete, individually selectable `ArtistSegment` tokens.
    public static func parse(rawArtist: String) -> [ArtistSegment] {
        let trimmed = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [ArtistSegment(name: "Unknown Artist")]
        }

        // If it's a known single-artist compound name (e.g. "Tyler, The Creator"), preserve intact
        if isSingleArtistException(trimmed) {
            return [ArtistSegment(name: trimmed)]
        }

        guard let regex = regex else {
            return [ArtistSegment(name: trimmed)]
        }

        let nsString = trimmed as NSString
        let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

        guard !matches.isEmpty else {
            return [ArtistSegment(name: trimmed)]
        }

        var segments: [ArtistSegment] = []
        var currentIndex = 0

        for match in matches {
            let matchRange = match.range
            let artistRange = NSRange(location: currentIndex, length: matchRange.location - currentIndex)
            let artistName = nsString.substring(with: artistRange).trimmingCharacters(in: unwantedChars)
            let delimiter = nsString.substring(with: matchRange)

            if !artistName.isEmpty {
                segments.append(ArtistSegment(name: artistName, separatorAfter: delimiter))
            }
            currentIndex = matchRange.location + matchRange.length
        }

        if currentIndex < nsString.length {
            let remainderRange = NSRange(location: currentIndex, length: nsString.length - currentIndex)
            let artistName = nsString.substring(with: remainderRange).trimmingCharacters(in: unwantedChars)
            if !artistName.isEmpty {
                segments.append(ArtistSegment(name: artistName, separatorAfter: nil))
            }
        }

        return segments.isEmpty ? [ArtistSegment(name: trimmed)] : segments
    }

    /// Parses a raw artist string into an array of clean artist name strings.
    public static func parseArtists(from rawArtist: String) -> [String] {
        parse(rawArtist: rawArtist).map { $0.name }
    }

    // MARK: - Featured Artist Extraction

    // Matches "(feat. X)", "[ft. X]", and trailing "feat. X" patterns across all common bracket styles
    private static let titleFeatureRegex: NSRegularExpression? = {
        // Pattern
        let pattern = #"(?:\((?:feat\.?|ft\.?|featuring|with)\s+([^)]+)\)|\[(?:feat\.?|ft\.?|featuring|with)\s+([^\]]+)\]|(?:\s+-\s+|\s+)(?:feat\.?|ft\.?|featuring|with)\s+(.+)$)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Extracts all featured artist names mentioned in a track title (e.g. `(feat. Drake & Future)` -> `["Drake", "Future"]`).
    public static func extractFeaturedArtists(fromTitle title: String) -> [String] {
        // Trimmed
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !trimmed.isEmpty, let regex = titleFeatureRegex else { return [] }

        // Ns string
        let nsString = trimmed as NSString
        // Matches
        let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

        // Featured artists
        var featuredArtists: [String] = []
        for match in matches {
            // Groups 1, 2, 3 correspond to parentheses, brackets, and trailing forms respectively
            for groupIndex in 1...3 {
                // Range
                let range = match.range(at: groupIndex)
                if range.location != NSNotFound && range.length > 0 {
                    // Feature string
                    let featureString = nsString.substring(with: range)
                    // Artists
                    let artists = parseArtists(from: featureString)
                    for a in artists {
                        // Clean
                        let clean = a.trimmingCharacters(in: unwantedChars)
                        // Deduplicate case-insensitively to avoid "Drake" and "drake" both appearing
                        if !clean.isEmpty && !featuredArtists.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                            featuredArtists.append(clean)
                        }
                    }
                }
            }
        }
        return featuredArtists
    }

    /// Checks whether an artist name is a generic compilation placeholder that should not be indexed as a real artist.
    public static func isGenericArtistName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty ||
               lower == "various artists" ||
               lower == "various artist" ||
               lower == "various" ||
               lower == "v.a." ||
               lower == "va" ||
               lower == "v/a" ||
               lower == "soundtrack" ||
               lower == "original soundtrack" ||
               lower == "ost" ||
               lower == "unknown artist" ||
               lower == "unknown"
    }

    /// Returns all distinct real artists associated with a track (primary artists from artist/albumArtist, plus featured artists from the title).
    public static func allArtists(forTitle title: String, artist: String, albumArtist: String? = nil) -> [String] {
        var results: [String] = []

        let cleanDirect = artist.trimmingCharacters(in: unwantedChars)
        if isSingleArtistException(cleanDirect) {
            if !cleanDirect.isEmpty && !isGenericArtistName(cleanDirect) {
                results.append(cleanDirect)
            }
        } else {
            let direct = parseArtists(from: artist)
            for a in direct {
                let clean = a.trimmingCharacters(in: unwantedChars)
                if !clean.isEmpty && !isGenericArtistName(clean) && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                    results.append(clean)
                }
            }
        }

        // 2. Album artist if present
        if let albArt = albumArtist, !albArt.isEmpty {
            let cleanAlb = albArt.trimmingCharacters(in: unwantedChars)
            if isSingleArtistException(cleanAlb) {
                if !cleanAlb.isEmpty && !isGenericArtistName(cleanAlb) && !results.contains(where: { $0.caseInsensitiveCompare(cleanAlb) == .orderedSame }) {
                    results.append(cleanAlb)
                }
            } else {
                let albArtists = parseArtists(from: albArt)
                for a in albArtists {
                    let clean = a.trimmingCharacters(in: unwantedChars)
                    if !clean.isEmpty && !isGenericArtistName(clean) && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                        results.append(clean)
                    }
                }
            }
        }

        // 3. Features embedded in the title string
        let featuredInTitle = extractFeaturedArtists(fromTitle: title)
        for a in featuredInTitle {
            let clean = a.trimmingCharacters(in: unwantedChars)
            if !clean.isEmpty && !isGenericArtistName(clean) && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                results.append(clean)
            }
        }

        if results.isEmpty {
            return cleanDirect.isEmpty ? ["Unknown Artist"] : [cleanDirect]
        }
        return results
    }

    /// Generates a canonical, punctuation and diacritic-tolerant artist key for clustering aliases (e.g. "JAŸ-Z", "JAY-Z", "Jay Z" -> "jay z", "J Cole" and "J. Cole" -> "j cole", "A$AP Rocky" and "ASAP Rocky" -> "asap rocky").
    public static func canonicalArtistKey(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var result = ""
        result.reserveCapacity(folded.count + 4)
        for char in folded {
            if char.isLetter || char.isNumber {
                result.append(char)
            } else if char == "$" {
                result.append("s")
            } else if char == "&" || char == "+" {
                result.append(" and ")
            } else {
                result.append(" ")
            }
        }
        let tokens = result.split(separator: " ", omittingEmptySubsequences: true)
        return tokens.joined(separator: " ")
    }

    /// Selects the authoritative display name between two aliases (e.g. prefers "J. Cole" over "J Cole", "Jay-Z" over "Jay Z").
    public static func preferredArtistDisplayName(_ name1: String, _ name2: String) -> String {
        guard name1 != name2 else { return name1 }
        let punctChars = CharacterSet(charactersIn: ".-,!'$")
        let count1 = name1.unicodeScalars.filter { punctChars.contains($0) }.count
        let count2 = name2.unicodeScalars.filter { punctChars.contains($0) }.count
        if count1 != count2 {
            return count1 > count2 ? name1 : name2
        }
        // Prefer Title-Cased over all-lowercase
        let isLower1 = name1 == name1.lowercased()
        let isLower2 = name2 == name2.lowercased()
        if !isLower1 && isLower2 { return name1 }
        if isLower1 && !isLower2 { return name2 }
        return name1
    }

    /// Checks if a specific artist name is featured in a track title (e.g. `(feat. Artist)`), tolerating missing punctuation.
    public static func isArtistFeatured(name: String, inTitle title: String) -> Bool {
        // Clean name
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        let canonicalTarget = canonicalArtistKey(cleanName)
        let featured = extractFeaturedArtists(fromTitle: title)
        return featured.contains {
            $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
            canonicalArtistKey($0) == canonicalTarget
        }
    }
}
