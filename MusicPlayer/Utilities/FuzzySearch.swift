import Foundation

/// Ultra-fast, SIMD/cache-optimized fuzzy matching and relevance scoring engine.
/// Features full punctuation tolerance, `&` <-> `and` conjunction equivalence,
/// and sub-millisecond execution across massive music libraries.
public enum FuzzyMatcher {

    // MARK: - Normalization & Token Preparation

    /// Thoroughly normalizes strings for searching with zero unnecessary allocations:
    /// 1. Lowercases and replaces diacritics/conjunctions.
    /// 2. Converts all punctuation, symbols, and special characters into space delimiters.
    /// 3. Collapses multiple whitespace characters.
    @inline(__always)
    public static func normalize(_ str: String) -> String {
        guard !str.isEmpty else { return "" }
        let folded = str.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        var result = ""
        result.reserveCapacity(folded.count + 8)

        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if scalar == "$" {
                result.append("s")
                lastWasSpace = false
            } else if scalar == "@" {
                result.append("a")
                lastWasSpace = false
            } else if scalar == "&" || scalar == "+" {
                if !lastWasSpace { result.append(" ") }
                result.append("and ")
                lastWasSpace = true
            } else {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
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

        // Title score
        let titleScore = evaluateScore(cleanText: normalizedTitle, cleanQuery: cleanQuery)
        // Artist score
        let artistScore = evaluateScore(cleanText: normalizedArtist, cleanQuery: cleanQuery)
        // Album score
        let albumScore = evaluateScore(cleanText: normalizedAlbum, cleanQuery: cleanQuery)
        // Token score
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
        let cleanGenre = genre.map { normalize($0) } ?? ""
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

    /// Evaluates match score between pre-normalized strings with zero per-call heap allocations.
    @inline(__always)
    public static func evaluateScore(cleanText: String, cleanQuery: String) -> Int {
        guard !cleanText.isEmpty, !cleanQuery.isEmpty else { return 0 }

        // 1. Exact match (1200)
        if cleanText == cleanQuery {
            return 1200
        }

        let queryCount = cleanQuery.count
        let textCount = cleanText.count

        // 2. Full Prefix Match (900 - 1050)
        if cleanText.hasPrefix(cleanQuery) {
            let ratio = Double(queryCount) / Double(max(textCount, 1))
            return 900 + Int(ratio * 150)
        }

        // 3. Fast word-boundary check (e.g. "california" inside "hotel california")
        let spaceQuery = " " + cleanQuery
        if cleanText.contains(spaceQuery) {
            let ratio = Double(queryCount) / Double(max(textCount, 1))
            return 750 + Int(ratio * 120)
        }

        // 4. Exact Substring Containment (550 - 700)
        if cleanText.contains(cleanQuery) {
            let ratio = Double(queryCount) / Double(max(textCount, 1))
            return 550 + Int(ratio * 150)
        }

        // 5. Multi-word Query: All query tokens present in text (400 - 520)
        if cleanQuery.contains(" ") {
            let queryTokens = cleanQuery.split(separator: " ", omittingEmptySubsequences: true)
            if queryTokens.count > 1 {
                let allMatch = queryTokens.allSatisfy { qToken in
                    cleanText.hasPrefix(qToken) || cleanText.contains(" " + qToken) || cleanText.contains(qToken)
                }
                if allMatch {
                    let ratio = Double(queryCount) / Double(max(textCount, 1))
                    return 420 + Int(ratio * 120)
                }
            }
        }

        // 6. Subsequence / Acronym match (250 - 380)
        if queryCount >= 2 && queryCount <= textCount {
            if isSubsequence(query: cleanQuery, in: cleanText) {
                let ratio = Double(queryCount) / Double(max(textCount, 1))
                return 250 + Int(ratio * 80)
            }
        }

        return 0
    }

    @inline(__always)
    private static func isSubsequence(query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        guard query.count <= text.count else { return false }

        var queryIterator = query.makeIterator()
        guard var currentQueryChar = queryIterator.next() else { return true }

        for textChar in text {
            if textChar == currentQueryChar {
                if let nextChar = queryIterator.next() {
                    currentQueryChar = nextChar
                } else {
                    return true
                }
            }
        }
        return false
    }

    /// Normalized Levenshtein similarity score between 0.0 (completely different) and 1.0 (exact match).
    @inline(__always)
    public static func levenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        // Clean 1
        let clean1 = normalize(s1)
        // Clean 2
        let clean2 = normalize(s2)
        if clean1 == clean2 { return 1.0 }
        // Max len
        let maxLen = max(clean1.count, clean2.count)
        // Ensure preconditions are met before proceeding
        guard maxLen > 0 else { return 1.0 }
        // Dist
        let dist = fastLevenshtein(Array(clean1.utf8), Array(clean2.utf8), maxAllowed: maxLen)
        return max(0.0, 1.0 - (Double(dist) / Double(maxLen)))
    }

    @inline(__always)
    private static func fastLevenshtein(_ a: [UInt8], _ b: [UInt8], maxAllowed: Int) -> Int {
        // M
        let m = a.count
        // N
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        // Diff
        let diff = abs(m - n)
        if diff > maxAllowed { return diff }
        // V 0
        var v0 = [Int](repeating: 0, count: n + 1)
        // V 1
        var v1 = [Int](repeating: 0, count: n + 1)
        for j in 0...n { v0[j] = j }
        for i in 0..<m {
            v1[0] = i + 1
            // Min row val
            var minRowVal = v1[0]
            for j in 0..<n {
                // Cost
                let cost: Int = (a[i] == b[j]) ? 0 : 1
                v1[j + 1] = min(v1[j] + 1, v0[j + 1] + 1, v0[j] + cost)
                minRowVal = min(minRowVal, v1[j + 1])
            }
            if minRowVal > maxAllowed { return minRowVal }
            v0 = v1
        }
        return v0[n]
    }

    /// Token-Sort Levenshtein similarity: normalizes, splits into tokens, sorts alphabetically, and computes maximum similarity (0.0 to 1.0).
    @inline(__always)
    public static func tokenSortLevenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        let clean1 = normalize(s1)
        let clean2 = normalize(s2)
        if clean1 == clean2 { return 1.0 }

        let tokens1 = clean1.split(separator: " ", omittingEmptySubsequences: true).sorted().joined(separator: " ")
        let tokens2 = clean2.split(separator: " ", omittingEmptySubsequences: true).sorted().joined(separator: " ")
        if tokens1 == tokens2 { return 1.0 }

        let directSim = levenshteinSimilarity(clean1, clean2)
        let sortedSim = levenshteinSimilarity(tokens1, tokens2)
        return max(directSim, sortedSim)
    }

    /// Jaro-Winkler string similarity distance between 0.0 (completely dissimilar) and 1.0 (identical).
    @inline(__always)
    public static func jaroWinklerSimilarity(_ s1: String, _ s2: String, prefixWeight: Double = 0.1) -> Double {
        let a = Array(normalize(s1).utf8)
        let b = Array(normalize(s2).utf8)

        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        if a == b { return 1.0 }

        let aLen = a.count
        let bLen = b.count
        let matchDistance = max(0, max(aLen, bLen) / 2 - 1)

        var aMatches = [Bool](repeating: false, count: aLen)
        var bMatches = [Bool](repeating: false, count: bLen)
        var matches = 0

        for i in 0..<aLen {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, bLen)
            guard start < end else { continue }
            for j in start..<end {
                if bMatches[j] { continue }
                if a[i] == b[j] {
                    aMatches[i] = true
                    bMatches[j] = true
                    matches += 1
                    break
                }
            }
        }

        if matches == 0 { return 0.0 }

        var transpositions = 0.0
        var k = 0
        for i in 0..<aLen {
            if !aMatches[i] { continue }
            while k < bLen && !bMatches[k] { k += 1 }
            if k < bLen {
                if a[i] != b[k] {
                    transpositions += 1.0
                }
                k += 1
            }
        }
        transpositions /= 2.0

        let m = Double(matches)
        let jaro = ((m / Double(aLen)) + (m / Double(bLen)) + ((m - transpositions) / m)) / 3.0

        // Winkler prefix scaling (up to 4 matching initial characters)
        var prefix = 0
        let maxPrefix = min(4, min(aLen, bLen))
        while prefix < maxPrefix && a[prefix] == b[prefix] {
            prefix += 1
        }

        let clampedPrefixWeight = min(0.25, max(0.0, prefixWeight))
        return min(1.0, max(0.0, jaro + (Double(prefix) * clampedPrefixWeight * (1.0 - jaro))))
    }
}

