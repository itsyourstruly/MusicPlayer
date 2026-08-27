import Foundation

/// Represents an individual artist token in a multi-artist collaboration string along with its trailing separator.
public struct ArtistSegment: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let separatorAfter: String?

    public init(name: String, separatorAfter: String? = nil) {
        self.name = name
        self.separatorAfter = separatorAfter
    }
}

/// Robust parser for multi-artist metadata strings (supporting commas, ampersands, feat./ft., slashes, etc.)
public enum ArtistParser {
    private static let delimiterPattern = #"(?:\s*,\s*|\s*&\s*|\s+(?:feat\.?|ft\.?|featuring|with|vs\.?|x)\s+|\s*;\s*|\s*/\s*|\s*\|\s*)"#

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: delimiterPattern, options: [.caseInsensitive])
    }()

    private static let unwantedChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "&,;/-_()[]*#\"'"))

    /// Parses a raw artist string into discrete, individually selectable `ArtistSegment` tokens.
    public static func parse(rawArtist: String) -> [ArtistSegment] {
        let trimmed = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [ArtistSegment(name: "Unknown Artist")]
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

        // Remainder after the last delimiter
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

    private static let titleFeatureRegex: NSRegularExpression? = {
        let pattern = #"(?:\((?:feat\.?|ft\.?|featuring|with)\s+([^)]+)\)|\[(?:feat\.?|ft\.?|featuring|with)\s+([^\]]+)\]|(?:\s+-\s+|\s+)(?:feat\.?|ft\.?|featuring|with)\s+(.+)$)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Extracts all featured artist names mentioned in a track title (e.g. `(feat. Drake & Future)` -> `["Drake", "Future"]`).
    public static func extractFeaturedArtists(fromTitle title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let regex = titleFeatureRegex else { return [] }

        let nsString = trimmed as NSString
        let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

        var featuredArtists: [String] = []
        for match in matches {
            // Check capture groups 1, 2, or 3
            for groupIndex in 1...3 {
                let range = match.range(at: groupIndex)
                if range.location != NSNotFound && range.length > 0 {
                    let featureString = nsString.substring(with: range)
                    let artists = parseArtists(from: featureString)
                    for a in artists {
                        let clean = a.trimmingCharacters(in: unwantedChars)
                        if !clean.isEmpty && !featuredArtists.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                            featuredArtists.append(clean)
                        }
                    }
                }
            }
        }
        return featuredArtists
    }

    /// Returns all distinct artists associated with a track (primary artists from artist/albumArtist, plus featured artists from the title).
    public static func allArtists(forTitle title: String, artist: String, albumArtist: String? = nil) -> [String] {
        var results: [String] = []

        let direct = parseArtists(from: artist)
        for a in direct {
            let clean = a.trimmingCharacters(in: unwantedChars)
            if !clean.isEmpty && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                results.append(clean)
            }
        }

        if let albArt = albumArtist, !albArt.isEmpty {
            let albArtists = parseArtists(from: albArt)
            for a in albArtists {
                let clean = a.trimmingCharacters(in: unwantedChars)
                if !clean.isEmpty && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                    results.append(clean)
                }
            }
        }

        let featuredInTitle = extractFeaturedArtists(fromTitle: title)
        for a in featuredInTitle {
            let clean = a.trimmingCharacters(in: unwantedChars)
            if !clean.isEmpty && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                results.append(clean)
            }
        }

        return results.isEmpty ? ["Unknown Artist"] : results
    }

    /// Checks if a specific artist name is featured in a track title (e.g. `(feat. Artist)`).
    public static func isArtistFeatured(name: String, inTitle title: String) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        let featured = extractFeaturedArtists(fromTitle: title)
        return featured.contains { $0.caseInsensitiveCompare(cleanName) == .orderedSame }
    }
}
