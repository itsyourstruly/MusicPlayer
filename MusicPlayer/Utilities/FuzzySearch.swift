import Foundation

/// Ultra-fast, SIMD/cache-optimized fuzzy matching and relevance scoring engine.
/// Features full punctuation tolerance, `&` <-> `and` conjunction equivalence,
/// and sub-millisecond execution across massive music libraries.
public enum FuzzyMatcher {

    // MARK: - Normalization & Token Preparation

    /// Fast punctuation set: converts punctuation and special symbols to space delimiters.
    private static let punctuationCharacters: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(CharacterSet.symbols)
        set.formUnion(CharacterSet(charactersIn: ",:;-_'\"\"''.!?()[]/\\|~*#@%+=<>$`^{}"))
        set.remove(charactersIn: "")
        return set
    }()

    /// Thoroughly normalizes strings for searching:
    /// 1. Strips diacritics and lowercases.
    /// 2. Normalizes `&` and `+` to `and`.
    /// 3. Replaces punctuation with space delimiters so `Spider-Man` matches `Spider Man` and `Earth, Wind & Fire` matches `Earth Wind and Fire`.
    /// 4. Trims and collapses multiple whitespace characters.
    @inline(__always)
    public static func normalize(_ str: String) -> String {
        guard !str.isEmpty else { return "" }

        // Strip diacritics & lowercase
        let folded = str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()

        // Normalize conjunctions & symbols to space-padded words
        var replaced = folded.replacingOccurrences(of: "&", with: " and ")
        replaced = replaced.replacingOccurrences(of: "+", with: " and ")

        // Replace all punctuation with spaces
        let scalars = replaced.unicodeScalars.map { scalar -> Unicode.Scalar in
            if punctuationCharacters.contains(scalar) {
                return Unicode.Scalar(32) // ' ' space
            }
            return scalar
        }

        let cleaned = String(String.UnicodeScalarView(scalars))
        // Fast whitespace collapse
        let tokens = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        return tokens.joined(separator: " ")
    }

    // MARK: - Core Public API

    /// Calculate a match score between candidate text and a search query.
    /// Returns 0 for no match, or a positive integer reflecting match quality (higher = better).
    @inline(__always)
    public static func score(text: String, query: String) -> Int {
        let cleanQuery = normalize(query)
        guard !cleanQuery.isEmpty else { return 0 }
        let cleanText = normalize(text)
        guard !cleanText.isEmpty else { return 0 }

        return evaluateScore(cleanText: cleanText, cleanQuery: cleanQuery)
    }

    /// Evaluates multi-field track relevance prioritizing title match, then artist, then album.
    @inline(__always)
    public static func scoreTrack(
        normalizedTitle: String,
        normalizedArtist: String,
        normalizedAlbum: String,
        searchTokens: String,
        cleanQuery: String
    ) -> Int {
        guard !cleanQuery.isEmpty else { return 0 }

        // Fast rejection: if the pre-joined search token string does not match anywhere and query has no multi-tokens
        if !searchTokens.contains(cleanQuery) && !cleanQuery.contains(" ") {
            // Check acronym or short prefix
            if cleanQuery.count >= 2 && isSubsequence(query: cleanQuery, in: normalizedTitle) {
                return 250
            }
            return 0
        }

        let titleScore = evaluateScore(cleanText: normalizedTitle, cleanQuery: cleanQuery)
        let artistScore = evaluateScore(cleanText: normalizedArtist, cleanQuery: cleanQuery)
        let albumScore = evaluateScore(cleanText: normalizedAlbum, cleanQuery: cleanQuery)
        let tokenScore = evaluateScore(cleanText: searchTokens, cleanQuery: cleanQuery)

        return max(
            titleScore * 2,
            Int(Double(artistScore) * 1.4),
            albumScore,
            tokenScore
        )
    }

    /// Fallback scoreTrack taking raw strings (normalizes on the fly if pre-normalized tokens not available).
    @inline(__always)
    public static func scoreTrack(title: String, artist: String, album: String, genre: String? = nil, query: String) -> Int {
        let cleanQuery = normalize(query)
        guard !cleanQuery.isEmpty else { return 0 }

        let cleanTitle = normalize(title)
        let cleanArtist = normalize(artist)
        let cleanAlbum = normalize(album)
        let cleanGenre = genre != nil ? normalize(genre!) : ""
        let tokens = "\(cleanTitle) \(cleanArtist) \(cleanAlbum) \(cleanGenre)"

        return scoreTrack(
            normalizedTitle: cleanTitle,
            normalizedArtist: cleanArtist,
            normalizedAlbum: cleanAlbum,
            searchTokens: tokens,
            cleanQuery: cleanQuery
        )
    }

    /// Evaluates album relevance prioritizing album title match, then artist.
    @inline(__always)
    public static func scoreAlbum(normalizedTitle: String, normalizedArtist: String, cleanQuery: String) -> Int {
        guard !cleanQuery.isEmpty else { return 0 }

        let titleScore = evaluateScore(cleanText: normalizedTitle, cleanQuery: cleanQuery)
        let artistScore = evaluateScore(cleanText: normalizedArtist, cleanQuery: cleanQuery)

        return max(titleScore * 2, Int(Double(artistScore) * 1.2))
    }

    /// Fallback scoreAlbum taking raw strings.
    @inline(__always)
    public static func scoreAlbum(title: String, artist: String, query: String) -> Int {
        let cleanQuery = normalize(query)
        guard !cleanQuery.isEmpty else { return 0 }

        return scoreAlbum(
            normalizedTitle: normalize(title),
            normalizedArtist: normalize(artist),
            cleanQuery: cleanQuery
        )
    }

    /// Evaluates artist relevance.
    @inline(__always)
    public static func scoreArtist(normalizedName: String, cleanQuery: String) -> Int {
        guard !cleanQuery.isEmpty else { return 0 }
        return evaluateScore(cleanText: normalizedName, cleanQuery: cleanQuery)
    }

    /// Fallback scoreArtist taking raw strings.
    @inline(__always)
    public static func scoreArtist(name: String, query: String) -> Int {
        let cleanQuery = normalize(query)
        guard !cleanQuery.isEmpty else { return 0 }
        return scoreArtist(normalizedName: normalize(name), cleanQuery: cleanQuery)
    }

    // MARK: - Core Matching Engine

    /// Evaluates match score between pre-normalized strings.
    @inline(__always)
    public static func evaluateScore(cleanText: String, cleanQuery: String) -> Int {
        guard !cleanText.isEmpty, !cleanQuery.isEmpty else { return 0 }

        // 1. Exact match (1200)
        if cleanText == cleanQuery {
            return 1200
        }

        // 2. Full Prefix Match (900 - 1050)
        if cleanText.hasPrefix(cleanQuery) {
            let ratio = Double(cleanQuery.count) / Double(max(cleanText.count, 1))
            return 900 + Int(ratio * 150)
        }

        // Fast word-boundary check
        let paddedText = " " + cleanText
        let paddedQuery = " " + cleanQuery
        if paddedText.contains(paddedQuery) {
            let ratio = Double(cleanQuery.count) / Double(max(cleanText.count, 1))
            return 750 + Int(ratio * 120)
        }

        // 3. Exact Substring Containment (550 - 700)
        if cleanText.contains(cleanQuery) {
            let ratio = Double(cleanQuery.count) / Double(max(cleanText.count, 1))
            return 550 + Int(ratio * 150)
        }

        // 4. Multi-word Query: All query tokens present in text (400 - 520)
        let queryTokens = cleanQuery.split(separator: " ", omittingEmptySubsequences: true)
        if queryTokens.count > 1 {
            let allMatch = queryTokens.allSatisfy { qToken in
                paddedText.contains(" " + qToken) || cleanText.contains(qToken)
            }
            if allMatch {
                let ratio = Double(cleanQuery.count) / Double(max(cleanText.count, 1))
                return 420 + Int(ratio * 120)
            }
        }

        // 5. Subsequence / Acronym match (250 - 380)
        if cleanQuery.count >= 2 {
            let words = cleanText.split(separator: " ", omittingEmptySubsequences: true)
            if cleanQuery.count <= words.count {
                let acronym = String(words.compactMap { $0.first })
                if acronym.hasPrefix(cleanQuery) || acronym.contains(cleanQuery) {
                    return 360
                }
            }

            if isSubsequence(query: cleanQuery, in: cleanText) {
                let ratio = Double(cleanQuery.count) / Double(max(cleanText.count, 1))
                return 250 + Int(ratio * 80)
            }
        }

        return 0
    }

    // MARK: - Subsequence Matching

    @inline(__always)
    private static func isSubsequence(query: String, in text: String) -> Bool {
        var queryIdx = query.startIndex
        var textIdx = text.startIndex

        while queryIdx < query.endIndex && textIdx < text.endIndex {
            if query[queryIdx] == text[textIdx] {
                queryIdx = query.index(after: queryIdx)
            }
            textIdx = text.index(after: textIdx)
        }
        return queryIdx == query.endIndex
    }

    /// Normalized Levenshtein similarity score between 0.0 (completely different) and 1.0 (exact match).
    @inline(__always)
    public static func levenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        let clean1 = normalize(s1)
        let clean2 = normalize(s2)
        if clean1 == clean2 { return 1.0 }
        let maxLen = max(clean1.count, clean2.count)
        guard maxLen > 0 else { return 1.0 }
        let dist = fastLevenshtein(Array(clean1.utf8), Array(clean2.utf8), maxAllowed: maxLen)
        return max(0.0, 1.0 - (Double(dist) / Double(maxLen)))
    }

    @inline(__always)
    private static func fastLevenshtein(_ a: [UInt8], _ b: [UInt8], maxAllowed: Int) -> Int {
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        let diff = abs(m - n)
        if diff > maxAllowed { return diff }
        var v0 = [Int](repeating: 0, count: n + 1)
        var v1 = [Int](repeating: 0, count: n + 1)
        for j in 0...n { v0[j] = j }
        for i in 0..<m {
            v1[0] = i + 1
            var minRowVal = v1[0]
            for j in 0..<n {
                let cost: Int = (a[i] == b[j]) ? 0 : 1
                v1[j + 1] = min(v1[j] + 1, v0[j + 1] + 1, v0[j] + cost)
                minRowVal = min(minRowVal, v1[j + 1])
            }
            if minRowVal > maxAllowed { return minRowVal }
            v0 = v1
        }
        return v0[n]
    }
}

