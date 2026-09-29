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

/// Robust, intelligent parser for multi-artist metadata strings (supporting commas, ampersands, feat./ft., slashes, etc.)
/// with placeholder masking for compound artist names (e.g. "Tyler, The Creator", "Earth, Wind & Fire", "Simon & Garfunkel").
public enum ArtistParser {
    // Known compound artist / band names that contain internal commas, ampersands, pluses, or slashes
    // Sorted longest first so longer multi-word names match before shorter substrings
    private static let protectedArtists: [String] = [
        "Tyler, The Creator",
        "Earth, Wind & Fire",
        "Earth, Wind and Fire",
        "Crosby, Stills, Nash & Young",
        "Crosby, Stills & Nash",
        "Blood, Sweat & Tears",
        "Emerson, Lake & Palmer",
        "Simon & Garfunkel",
        "Simon and Garfunkel",
        "Daryl Hall & John Oates",
        "Hall & Oates",
        "Hall and Oates",
        "Kool & The Gang",
        "Kool and the Gang",
        "KC & The Sunshine Band",
        "KC and the Sunshine Band",
        "Huey Lewis & The News",
        "Huey Lewis and the News",
        "Frankie Lymon & The Teenagers",
        "Gladys Knight & The Pips",
        "Joan Jett & The Blackhearts",
        "Tom Petty and the Heartbreakers",
        "Tom Petty & The Heartbreakers",
        "Bob Marley & The Wailers",
        "Bob Marley and the Wailers",
        "Ziggy Marley & The Melody Makers",
        "Sly & The Family Stone",
        "Sly and the Family Stone",
        "Captain & Tennille",
        "Captain and Tennille",
        "Peaches & Herb",
        "Peaches and Herb",
        "Ashford & Simpson",
        "Ashford and Simpson",
        "Sam & Dave",
        "Sam and Dave",
        "Ike & Tina Turner",
        "Ike and Tina Turner",
        "Brooks & Dunn",
        "Brooks and Dunn",
        "Dan + Shay",
        "Dan and Shay",
        "Florida Georgia Line",
        "Above & Beyond",
        "AC/DC",
        "Marina & The Diamonds",
        "Marina and the Diamonds",
        "Florence + The Machine",
        "Florence and the Machine",
        "Fitz and the Tantrums",
        "Fitz & The Tantrums",
        "Edward Sharpe & The Magnetic Zeros",
        "Echo & The Bunnymen",
        "King Gizzard & The Lizard Wizard",
        "Me First and the Gimme Gimmes",
        "Siouxsie and the Banshees",
        "Toots & The Maytals",
        "Arms and Sleepers",
        "Birds and Batteries",
        "The Mamas & The Papas",
        "The Mamas and the Papas",
        "The Birds and the Bees",
        "Portugal. The Man"
    ].sorted { $0.count > $1.count }

    private static let singleArtistExceptions: Set<String> = Set(protectedArtists.map { $0.lowercased() })

    private struct PrecompiledProtectedArtist: Sendable {
        let name: String
        let lowercaseName: String
        let regex: NSRegularExpression
    }

    private static let precompiledProtectedArtists: [PrecompiledProtectedArtist] = {
        return protectedArtists.compactMap { protected in
            let escaped = NSRegularExpression.escapedPattern(for: protected)
            let pattern = "(?i)(?:^|(?<=[\\s,;&|/]))" + escaped + "(?=[\\s,;&|/]|$)"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
            return PrecompiledProtectedArtist(name: protected, lowercaseName: protected.lowercased(), regex: rx)
        }
    }()

    private static let tylerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "(?i)(?:^|(?<=[\\s,;&|/]))tyler,?\\s+the creator(?=[\\s,;&|/]|$)")
    }()

    /// Checks whether an artist string is a protected single entity.
    public static func isSingleArtistException(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if singleArtistExceptions.contains(clean) { return true }
        if clean.contains("tyler, the creator") || clean.contains("tyler the creator") {
            return true
        }
        return false
    }

    // Covers multi-artist delimiter conventions: &, and, feat., ft., featuring, with, vs., x, comma, semicolon, pipe, slash
    private static let delimiterPattern = #"(?:\s*;\s*|\s*\|\s*|\s+/\s+|\s*,\s*|\s+&\s+|\s+and\s+|\s+x\s+|\s+(?:feat\.?|ft\.?|featuring|with|vs\.?)\s+)"#

    // Compiled once at startup — NSRegularExpression is thread-safe after initialization
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: delimiterPattern, options: [.caseInsensitive])
    }()

    // Delimiter and punctuation cleanup set
    private static let unwantedChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|/,()[]\"'&+"))

    // MARK: - Parsing

    /// Parses a raw artist string into discrete, individually selectable `ArtistSegment` tokens with intelligent compound name protection.
    public static func parse(rawArtist: String) -> [ArtistSegment] {
        let trimmed = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [ArtistSegment(name: "Unknown Artist")]
        }

        // 1. Direct match for protected entity
        if isSingleArtistException(trimmed) {
            if let canonical = protectedArtists.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return [ArtistSegment(name: canonical)]
            }
            if trimmed.lowercased().contains("tyler") && trimmed.lowercased().contains("creator") {
                return [ArtistSegment(name: "Tyler, The Creator")]
            }
            return [ArtistSegment(name: trimmed)]
        }

        // 2. Placeholder masking: preserve protected compound names prior to delimiter splitting
        var workingText = trimmed
        var placeholders: [String: String] = [:]
        var placeholderIndex = 0
        let lowerWorking = workingText.lowercased()

        for item in precompiledProtectedArtists {
            guard lowerWorking.contains(item.lowercaseName) else { continue }
            let nsWorking = workingText as NSString
            let matches = item.regex.matches(in: workingText, options: [], range: NSRange(location: 0, length: nsWorking.length))
            if !matches.isEmpty {
                let key = "___PROT_ARTIST_\(placeholderIndex)___"
                placeholders[key] = item.name
                placeholderIndex += 1
                workingText = item.regex.stringByReplacingMatches(
                    in: workingText,
                    options: [],
                    range: NSRange(location: 0, length: (workingText as NSString).length),
                    withTemplate: key
                )
            }
        }

        // Smart protection for Tyler, The Creator variations
        if lowerWorking.contains("tyler") && lowerWorking.contains("creator"), let tylerRegex = tylerRegex {
            let nsWorking = workingText as NSString
            let matches = tylerRegex.matches(in: workingText, options: [], range: NSRange(location: 0, length: nsWorking.length))
            if !matches.isEmpty {
                let key = "___PROT_ARTIST_\(placeholderIndex)___"
                placeholders[key] = "Tyler, The Creator"
                placeholderIndex += 1
                workingText = tylerRegex.stringByReplacingMatches(
                    in: workingText,
                    options: [],
                    range: NSRange(location: 0, length: (workingText as NSString).length),
                    withTemplate: key
                )
            }
        }

        guard let regex = regex else {
            let restored = restorePlaceholders(in: workingText, placeholders: placeholders)
            return [ArtistSegment(name: cleanArtistToken(restored))]
        }

        let nsString = workingText as NSString
        let matches = regex.matches(in: workingText, options: [], range: NSRange(location: 0, length: nsString.length))

        guard !matches.isEmpty else {
            let restored = restorePlaceholders(in: workingText, placeholders: placeholders)
            let clean = cleanArtistToken(restored)
            return [ArtistSegment(name: clean.isEmpty ? trimmed : clean)]
        }

        var segments: [ArtistSegment] = []
        var currentIndex = 0

        for match in matches {
            let matchRange = match.range
            let artistRange = NSRange(location: currentIndex, length: matchRange.location - currentIndex)
            let rawSegment = nsString.substring(with: artistRange)
            let delimiter = nsString.substring(with: matchRange)

            let restoredName = restorePlaceholders(in: rawSegment, placeholders: placeholders)
            let clean = cleanArtistToken(restoredName)

            if !clean.isEmpty && !isGenericArtistName(clean) {
                segments.append(ArtistSegment(name: clean, separatorAfter: delimiter))
            }
            currentIndex = matchRange.location + matchRange.length
        }

        if currentIndex < nsString.length {
            let remainderRange = NSRange(location: currentIndex, length: nsString.length - currentIndex)
            let rawSegment = nsString.substring(with: remainderRange)
            let restoredName = restorePlaceholders(in: rawSegment, placeholders: placeholders)
            let clean = cleanArtistToken(restoredName)

            if !clean.isEmpty && !isGenericArtistName(clean) {
                segments.append(ArtistSegment(name: clean, separatorAfter: nil))
            }
        }

        return segments.isEmpty ? [ArtistSegment(name: trimmed)] : segments
    }

    private static func restorePlaceholders(in text: String, placeholders: [String: String]) -> String {
        var result = text
        for (key, val) in placeholders {
            result = result.replacingOccurrences(of: key, with: val)
        }
        return result
    }

    private static func cleanArtistToken(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: unwantedChars)
        // Check if quotes wrap the token
        if (clean.hasPrefix("\"") && clean.hasSuffix("\"")) || (clean.hasPrefix("'") && clean.hasSuffix("'")) {
            clean = String(clean.dropFirst().dropLast()).trimmingCharacters(in: unwantedChars)
        }
        // Normalize Tyler The Creator if missing comma
        if clean.lowercased() == "tyler the creator" {
            clean = "Tyler, The Creator"
        }
        return clean
    }

    /// Parses a raw artist string into an array of clean individual artist name strings.
    public static func parseArtists(from rawArtist: String) -> [String] {
        parse(rawArtist: rawArtist).map { $0.name }
    }

    // MARK: - Featured Artist Extraction

    // Matches "(feat. X)", "[ft. X]", and trailing "feat. X" patterns across all common bracket styles
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
            for groupIndex in 1...3 {
                let range = match.range(at: groupIndex)
                if range.location != NSNotFound && range.length > 0 {
                    let featureString = nsString.substring(with: range)
                    let artists = parseArtists(from: featureString)
                    for a in artists {
                        let clean = cleanArtistToken(a)
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

        let cleanDirect = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSingleArtistException(cleanDirect) {
            let parsedDirect = parse(rawArtist: cleanDirect)
            for seg in parsedDirect {
                if !seg.name.isEmpty && !isGenericArtistName(seg.name) {
                    results.append(seg.name)
                }
            }
        } else {
            let direct = parseArtists(from: artist)
            for a in direct {
                let clean = cleanArtistToken(a)
                if !clean.isEmpty && !isGenericArtistName(clean) && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                    results.append(clean)
                }
            }
        }

        // 2. Album artist if present
        if let albArt = albumArtist, !albArt.isEmpty {
            let cleanAlb = albArt.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSingleArtistException(cleanAlb) {
                let parsedAlb = parse(rawArtist: cleanAlb)
                for seg in parsedAlb {
                    if !seg.name.isEmpty && !isGenericArtistName(seg.name) && !results.contains(where: { $0.caseInsensitiveCompare(seg.name) == .orderedSame }) {
                        results.append(seg.name)
                    }
                }
            } else {
                let albArtists = parseArtists(from: albArt)
                for a in albArtists {
                    let clean = cleanArtistToken(a)
                    if !clean.isEmpty && !isGenericArtistName(clean) && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                        results.append(clean)
                    }
                }
            }
        }

        // 3. Features embedded in the title string
        let featuredInTitle = extractFeaturedArtists(fromTitle: title)
        for a in featuredInTitle {
            let clean = cleanArtistToken(a)
            if !clean.isEmpty && !isGenericArtistName(clean) && !results.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                results.append(clean)
            }
        }

        if results.isEmpty {
            return cleanDirect.isEmpty ? ["Unknown Artist"] : [cleanDirect]
        }
        return results
    }

    /// Generates a canonical, punctuation and diacritic-tolerant artist key for clustering aliases.
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

    /// Selects the authoritative display name between two aliases.
    public static func preferredArtistDisplayName(_ name1: String, _ name2: String) -> String {
        guard name1 != name2 else { return name1 }
        // Prefer known canonical casing from protected exceptions if available
        if let canon1 = protectedArtists.first(where: { $0.caseInsensitiveCompare(name1) == .orderedSame }) {
            return canon1
        }
        if let canon2 = protectedArtists.first(where: { $0.caseInsensitiveCompare(name2) == .orderedSame }) {
            return canon2
        }

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
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        let canonicalTarget = canonicalArtistKey(cleanName)
        let featured = extractFeaturedArtists(fromTitle: title)
        return featured.contains {
            $0.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
            canonicalArtistKey($0) == canonicalTarget
        }
    }

    // MARK: - Collaborative Album Artist Resolution

    /// Formats an array of artist names into an intuitive display string (e.g. "Artist A & Artist B" or "A, B & C").
    public static func formatDisplayArtist(_ artists: [String]) -> String {
        guard !artists.isEmpty else { return "Unknown Artist" }
        if artists.count == 1 {
            return artists[0]
        } else if artists.count == 2 {
            return "\(artists[0]) & \(artists[1])"
        } else {
            let prefix = artists.dropLast().joined(separator: ", ")
            return "\(prefix) & \(artists.last!)"
        }
    }

    /// Determines the definitive artist(s) for an album based on track-level presence, collaborative thresholds,
    /// and explicit tags. Returns multiple artists for genuine collaborative projects, while preventing
    /// 1-2 track guest features from polluting the album's primary artist attribution.
    public static func resolveAlbumArtists(
        for tracks: [Track],
        explicitAlbumArtist: String? = nil,
        joinedArtists: [String] = []
    ) -> [String] {
        let cleanExplicit = explicitAlbumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitCanonical = canonicalArtistKey(cleanExplicit)

        // 1. Check if explicit album artist matches a joined artist rule
        if !cleanExplicit.isEmpty {
            for joined in joinedArtists {
                let joinedCanonical = canonicalArtistKey(joined)
                if explicitCanonical == joinedCanonical {
                    return [joined]
                }
                let joinedParts = parseArtists(from: joined).map { canonicalArtistKey($0) }
                if joinedParts.count > 1 {
                    let explicitParts = parseArtists(from: cleanExplicit).map { canonicalArtistKey($0) }
                    if Set(joinedParts).isSubset(of: Set(explicitParts)) {
                        return [joined]
                    }
                }
            }
        }

        // 2. If explicitAlbumArtist has multiple parsed artists (e.g. "Drake & 21 Savage")
        if !cleanExplicit.isEmpty && !isGenericArtistName(cleanExplicit) {
            let explicitParsed = parseArtists(from: cleanExplicit).filter { !isGenericArtistName($0) }
            if explicitParsed.count > 1 {
                return explicitParsed
            }
        }

        guard !tracks.isEmpty else {
            if !cleanExplicit.isEmpty && !isGenericArtistName(cleanExplicit) {
                return [cleanExplicit]
            }
            return ["Unknown Artist"]
        }

        let n = tracks.count

        // 3. For 1-track release (Single)
        if n == 1 {
            let track = tracks[0]
            if !cleanExplicit.isEmpty && !isGenericArtistName(cleanExplicit) {
                let parsed = parseArtists(from: cleanExplicit).filter { !isGenericArtistName($0) }
                if !parsed.isEmpty { return parsed }
            }
            let trackArtists = parseArtists(from: track.artist).filter { !isGenericArtistName($0) }
            if !trackArtists.isEmpty { return trackArtists }
            return [track.artist.isEmpty ? "Unknown Artist" : track.artist]
        }

        // 4. For 2-track releases
        if n == 2 {
            var seen = Set<String>()
            var result: [String] = []
            if !cleanExplicit.isEmpty && !isGenericArtistName(cleanExplicit) {
                for a in parseArtists(from: cleanExplicit) where !isGenericArtistName(a) && seen.insert(canonicalArtistKey(a)).inserted {
                    result.append(a)
                }
            }
            for track in tracks {
                for a in parseArtists(from: track.artist) where !isGenericArtistName(a) && seen.insert(canonicalArtistKey(a)).inserted {
                    result.append(a)
                }
            }
            return result.isEmpty ? (cleanExplicit.isEmpty ? ["Unknown Artist"] : [cleanExplicit]) : result
        }

        // 5. For 3+ track albums / EPs: tally artist presences
        struct ArtistStats {
            var primaryCount: Int = 0
            var totalCount: Int = 0
            var firstSeenIndex: Int = Int.max
            var variantCounts: [String: Int] = [:]
        }

        var statsByCanonical: [String: ArtistStats] = [:]

        for (idx, track) in tracks.enumerated() {
            let primaryParsed = parseArtists(from: track.artist).filter { !isGenericArtistName($0) }
            let allOnTrack = allArtists(forTitle: track.title, artist: track.artist, albumArtist: track.albumArtist).filter { !isGenericArtistName($0) }

            for a in primaryParsed {
                let k = canonicalArtistKey(a)
                guard !k.isEmpty else { continue }
                var s = statsByCanonical[k, default: ArtistStats()]
                s.primaryCount += 1
                s.firstSeenIndex = min(s.firstSeenIndex, idx)
                s.variantCounts[a, default: 0] += 1
                statsByCanonical[k] = s
            }

            for a in allOnTrack {
                let k = canonicalArtistKey(a)
                guard !k.isEmpty else { continue }
                var s = statsByCanonical[k, default: ArtistStats()]
                s.totalCount += 1
                s.firstSeenIndex = min(s.firstSeenIndex, idx)
                s.variantCounts[a, default: 0] += 1
                statsByCanonical[k] = s
            }
        }

        func bestName(for canonical: String) -> String {
            guard let stats = statsByCanonical[canonical] else { return canonical }
            return stats.variantCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return preferredArtistDisplayName(lhs.key, rhs.key) == lhs.key
            }.first?.key ?? canonical
        }

        // Identify candidate co-lead artists
        var qualifiedCanonicals = Set<String>()

        // Always include explicit album artist if present and non-generic
        if !cleanExplicit.isEmpty && !isGenericArtistName(cleanExplicit) {
            for a in parseArtists(from: cleanExplicit) where !isGenericArtistName(a) {
                let k = canonicalArtistKey(a)
                if !k.isEmpty {
                    qualifiedCanonicals.insert(k)
                }
            }
        }

        // Find primary artist with the most primary tracks
        let maxPrimary = statsByCanonical.values.map { $0.primaryCount }.max() ?? 0
        let maxTotal = statsByCanonical.values.map { $0.totalCount }.max() ?? 0

        // If no explicit artist was provided, always include the lead artist with max primary count
        if qualifiedCanonicals.isEmpty {
            if let lead = statsByCanonical.first(where: { $0.value.primaryCount == maxPrimary && maxPrimary > 0 }) {
                qualifiedCanonicals.insert(lead.key)
            } else if let lead = statsByCanonical.first(where: { $0.value.totalCount == maxTotal && maxTotal > 0 }) {
                qualifiedCanonicals.insert(lead.key)
            }
        }

        // Evaluate all other artists for collaborative co-lead status.
        // Must appear on every single track in the album to qualify as a collaborative album.
        for (canonical, stats) in statsByCanonical {
            if qualifiedCanonicals.contains(canonical) { continue }

            if stats.totalCount == n {
                qualifiedCanonicals.insert(canonical)
            }
        }

        // If no artist reached collaborative threshold (e.g. compilation of 10 tracks by 10 different artists)
        if qualifiedCanonicals.isEmpty {
            if !cleanExplicit.isEmpty {
                return [cleanExplicit]
            }
            if n >= 4 && maxTotal <= 2 {
                return ["Various Artists"]
            }
            if let top = statsByCanonical.max(by: { $0.value.totalCount < $1.value.totalCount }) {
                return [bestName(for: top.key)]
            }
            return ["Unknown Artist"]
        }

        // Sort qualified artists:
        // 1. Explicit album artist first
        // 2. Higher primaryCount
        // 3. Higher totalCount
        // 4. Earlier track appearance order
        let sortedCanonicals = qualifiedCanonicals.sorted { k1, k2 in
            let isK1Explicit = k1 == explicitCanonical
            let isK2Explicit = k2 == explicitCanonical
            if isK1Explicit != isK2Explicit { return isK1Explicit }

            let s1 = statsByCanonical[k1] ?? ArtistStats()
            let s2 = statsByCanonical[k2] ?? ArtistStats()
            if s1.primaryCount != s2.primaryCount { return s1.primaryCount > s2.primaryCount }
            if s1.totalCount != s2.totalCount { return s1.totalCount > s2.totalCount }
            return s1.firstSeenIndex < s2.firstSeenIndex
        }

        let resolvedNames = sortedCanonicals.map { bestName(for: $0) }
        return resolvedNames.isEmpty ? ["Unknown Artist"] : resolvedNames
    }
}
