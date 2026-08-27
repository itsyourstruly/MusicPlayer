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
    // Covers the widest variety of real-world artist delimiter conventions found in music tags
    private static let delimiterPattern = #"(?:\s*,\s*|\s*&\s*|\s+(?:feat\.?|ft\.?|featuring|with|vs\.?|x)\s+|\s*;\s*|\s*/\s*|\s*\|\s*)"#

    // Compiled once at startup — NSRegularExpression is thread-safe after initialization
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: delimiterPattern, options: [.caseInsensitive])
    }()

    // Broad cleanup set used to strip punctuation artifacts left after splitting
    private static let unwantedChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "&,;/-_()[]*#\"'"))

    // MARK: - Parsing

    /// Parses a raw artist string into discrete, individually selectable `ArtistSegment` tokens.
    public static func parse(rawArtist: String) -> [ArtistSegment] {
        // Trimmed
        let trimmed = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !trimmed.isEmpty else {
            return [ArtistSegment(name: "Unknown Artist")]
        }

        // Ensure preconditions are met before proceeding
        guard let regex = regex else {
            // Regex compilation failed at startup — fall back to treating the whole string as one artist
            return [ArtistSegment(name: trimmed)]
        }

        // Ns string
        let nsString = trimmed as NSString
        // Matches
        let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

        // Ensure preconditions are met before proceeding
        guard !matches.isEmpty else {
            return [ArtistSegment(name: trimmed)]
        }

        // Segments
        var segments: [ArtistSegment] = []
        // Current index
        var currentIndex = 0

        for match in matches {
            // Match range
            let matchRange = match.range
            // Artist range
            let artistRange = NSRange(location: currentIndex, length: matchRange.location - currentIndex)
            // Artist name
            let artistName = nsString.substring(with: artistRange).trimmingCharacters(in: unwantedChars)
            // Delimiter
            let delimiter = nsString.substring(with: matchRange)

            if !artistName.isEmpty {
                segments.append(ArtistSegment(name: artistName, separatorAfter: delimiter))
            }
            currentIndex = matchRange.location + matchRange.length
        }

        // Capture the final artist token that appears after the last delimiter
        if currentIndex < nsString.length {
            // Remainder range
            let remainderRange = NSRange(location: currentIndex, length: nsString.length - currentIndex)
            // Artist name
            let artistName = nsString.substring(with: remainderRange).trimmingCharacters(in: unwantedChars)
            if !artistName.isEmpty {
                segments.append(ArtistSegment(name: artistName, separatorAfter: nil))
            }
        }

        // Guard against pathological cases where every segment was empty after trimming
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

    // MARK: - Combined Artist Collection

    /// Returns all distinct artists associated with a track (primary artists from artist/albumArtist, plus featured artists from the title).
    public static func allArtists(forTitle title: String, artist: String, albumArtist: String? = nil) -> [String] {
        // Results
        var results: [String] = []

        // Primary artists from the artist tag
        let direct = parseArtists(from: artist)
        for a in direct {
            // Clean
            let clean = a.trimmingCharacters(in: unwantedChars)
            if !clean.isEmpty && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                results.append(clean)
            }
        }

        // Album artist may introduce additional names not in the artist tag (e.g. "Various Artists" vs actual performers)
        if let albArt = albumArtist, !albArt.isEmpty {
            // Alb artists
            let albArtists = parseArtists(from: albArt)
            for a in albArtists {
                // Clean
                let clean = a.trimmingCharacters(in: unwantedChars)
                if !clean.isEmpty && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                    results.append(clean)
                }
            }
        }

        // Features embedded in the title string supplement the artist tag
        let featuredInTitle = extractFeaturedArtists(fromTitle: title)
        for a in featuredInTitle {
            // Clean
            let clean = a.trimmingCharacters(in: unwantedChars)
            if !clean.isEmpty && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                results.append(clean)
            }
        }

        return results.isEmpty ? ["Unknown Artist"] : results
    }

    /// Checks if a specific artist name is featured in a track title (e.g. `(feat. Artist)`).
    public static func isArtistFeatured(name: String, inTitle title: String) -> Bool {
        // Clean name
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !cleanName.isEmpty else { return false }
        // Featured
        let featured = extractFeaturedArtists(fromTitle: title)
        return featured.contains { $0.caseInsensitiveCompare(cleanName) == .orderedSame }
    }
}
