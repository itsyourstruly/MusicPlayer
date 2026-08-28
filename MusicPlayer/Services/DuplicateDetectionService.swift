import Foundation

/// High-performance actor responsible for detecting duplicate audio tracks,
/// clustering them into groups, and calculating technical fidelity & metadata completeness scores.
///
/// Detection Pipeline:
/// 1. Hash-bucketed grouping by normalized title (avoids O(n²) brute-force)
/// 2. Multi-signal pairwise verification within each bucket
/// 3. Union-find transitive closure for proper multi-way group merging
/// 4. Quality scoring and DuplicateGroup construction
public actor DuplicateDetectionService {
    public static let shared = DuplicateDetectionService()

    // Initialize with configured properties
    private init() {}

    // MARK: - Main Analysis Entry Point

    /// Analyzes a collection of tracks and returns detected duplicate clusters.
    public func analyzeDuplicates(in tracks: [Track]) -> [DuplicateGroup] {
        // Ensure preconditions are met before proceeding
        guard tracks.count > 1 else { return [] }

        // Phase 1: Hash-bucketed grouping by normalized title
        var buckets: [String: [Int]] = [:]
        buckets.reserveCapacity(tracks.count)

        for i in 0..<tracks.count {
            let key = normalizeTitle(tracks[i].title).groupingKey
            buckets[key, default: []].append(i)
        }

        // Phase 2 & 3: Pairwise verification within each bucket using union-find
        let uf = UnionFind(count: tracks.count)

        for (_, indices) in buckets where indices.count > 1 {
            for i in 0..<indices.count {
                for j in (i + 1)..<indices.count {
                    let idxA = indices[i]
                    let idxB = indices[j]
                    // Skip if already in the same group
                    if uf.find(idxA) == uf.find(idxB) { continue }

                    if isDuplicate(tracks[idxA], tracks[idxB]) {
                        uf.union(idxA, idxB)
                    }
                }
            }
        }

        // Phase 4: Collect groups from union-find
        var groupMap: [Int: [Int]] = [:]
        for i in 0..<tracks.count {
            let root = uf.find(i)
            groupMap[root, default: []].append(i)
        }

        // Convert clusters into DuplicateGroups with scoring
        var duplicateGroups: [DuplicateGroup] = []
        duplicateGroups.reserveCapacity(groupMap.count)

        for (_, memberIndices) in groupMap where memberIndices.count > 1 {
            let cluster = memberIndices.map { tracks[$0] }

            // Score each candidate
            let candidates: [DuplicateCandidate] = cluster.map { track in
                let (score, breakdown) = calculateQualityScore(for: track)
                return DuplicateCandidate(track: track, qualityScore: score, scoreBreakdown: breakdown, isRecommended: false)
            }

            // Find highest score candidate
            let maxScore = candidates.map { $0.qualityScore }.max() ?? 0
            // Mark the highest-scoring candidate(s) as recommended
            let evaluatedCandidates = candidates.map { cand in
                DuplicateCandidate(
                    track: cand.track,
                    qualityScore: cand.qualityScore,
                    scoreBreakdown: cand.scoreBreakdown,
                    isRecommended: cand.qualityScore == maxScore
                )
            }

            // Build group identity from the first track
            let first = cluster[0]
            let normTitle = normalizeTitle(first.title).normalized
            let normArtist = normalizeArtist(first.artist)
            let groupID = "\(normArtist)_\(normTitle)".lowercased()

            let recommendedID = evaluatedCandidates.first(where: { $0.isRecommended })?.track.id ?? first.id

            let group = DuplicateGroup(
                id: groupID,
                normalizedTitle: normTitle,
                normalizedArtist: normArtist,
                candidates: evaluatedCandidates,
                selectedPrimaryTrackID: recommendedID
            )
            duplicateGroups.append(group)
        }

        // Sort groups by potential disk savings (largest first)
        return duplicateGroups.sorted { $0.potentialSavedBytes > $1.potentialSavedBytes }
    }

    // MARK: - Multi-Signal Duplicate Verification

    /// Evaluates whether two tracks are duplicates using a multi-signal scoring approach.
    /// Returns true when the composite confidence score meets the threshold.
    public func isDuplicate(_ a: Track, _ b: Track) -> Bool {
        // Fast exact file path check
        if a.url == b.url { return true }

        // Extract normalized titles with version modifiers
        let titleInfoA = normalizeTitle(a.title)
        let titleInfoB = normalizeTitle(b.title)

        // Signal 1: Title match (required gate)
        let titleScore = scoreTitleMatch(titleInfoA.normalized, titleInfoB.normalized)
        guard titleScore > 0 else { return false }

        // Signal 5: Version/remix guard (apply early to reject quickly)
        let versionPenalty = scoreVersionGuard(titleInfoA.versionModifier, titleInfoB.versionModifier)
        if versionPenalty < 0 { return false }

        // Signal 2: Artist match
        let normArtistA = normalizeArtist(a.artist)
        let normArtistB = normalizeArtist(b.artist)
        let artistScore = scoreArtistMatch(normArtistA, normArtistB)

        // Signal 3: Duration proximity
        let durationScore = scoreDurationProximity(a.duration, b.duration)

        // Signal 4: Album match bonus
        let normAlbumA = normalizeAlbum(a.album)
        let normAlbumB = normalizeAlbum(b.album)
        let albumScore = scoreAlbumMatch(normAlbumA, normAlbumB)

        // Composite score
        let totalScore = titleScore + artistScore + durationScore + albumScore + versionPenalty
        return totalScore >= 55
    }

    // MARK: - Individual Signal Scoring

    /// Scores title similarity. Returns 0 (reject) or 35-40 points.
    private func scoreTitleMatch(_ normA: String, _ normB: String) -> Int {
        // Exact normalized match
        if normA == normB { return 40 }

        // Levenshtein similarity for near-matches (typos, minor differences)
        let similarity = levenshteinSimilarityPreNormalized(normA, normB)
        if similarity >= 0.92 { return 35 }

        return 0
    }

    /// Scores artist similarity. Returns 0-25 points.
    private func scoreArtistMatch(_ normA: String, _ normB: String) -> Int {
        // Exact match
        if normA == normB { return 25 }

        // Both unknown
        if normA == "unknown artist" && normB == "unknown artist" { return 10 }

        // One unknown — give benefit of the doubt
        if normA == "unknown artist" || normB == "unknown artist" { return 15 }

        // Substring containment: only if the contained string has meaningful length
        // This prevents "dj" matching "dj khaled" matching "dj snake"
        let tokensA = normA.split(separator: " ")
        let tokensB = normB.split(separator: " ")

        if normA.contains(normB) && tokensB.count >= 2 { return 20 }
        if normB.contains(normA) && tokensA.count >= 2 { return 20 }

        // Levenshtein for minor differences
        let similarity = levenshteinSimilarityPreNormalized(normA, normB)
        if similarity >= 0.85 { return 18 }

        return 0
    }

    /// Scores duration proximity. Returns 0-20 points.
    private func scoreDurationProximity(_ durA: TimeInterval, _ durB: TimeInterval) -> Int {
        let diff = abs(durA - durB)
        if diff <= 1.0 { return 20 }
        if diff <= 3.0 { return 15 }
        if diff <= 5.0 { return 8 }
        if diff <= 10.0 { return 3 }
        return 0
    }

    /// Scores album match. Returns 0-10 points.
    private func scoreAlbumMatch(_ normA: String, _ normB: String) -> Int {
        if normA == normB { return 10 }
        if normA == "unknown album" || normB == "unknown album" { return 5 }
        return 0
    }

    /// Version/remix guard. Returns 0 (OK) or -100 (REJECT).
    /// If one track has a version modifier that the other doesn't, they are different creative works.
    private func scoreVersionGuard(_ modA: String?, _ modB: String?) -> Int {
        // Neither has a modifier — fine
        if modA == nil && modB == nil { return 0 }
        // Both have the same modifier — fine
        if let a = modA, let b = modB, a == b { return 0 }
        // Both have modifiers but they're different (e.g., "remix" vs "acoustic") — reject
        if modA != nil && modB != nil { return -100 }
        // One has a modifier and the other doesn't — reject
        return -100
    }

    // MARK: - Quality Scoring (unchanged logic, preserved for DuplicateCandidate)

    /// Computes a comprehensive quality and accuracy score for a track.
    public func calculateQualityScore(for track: Track) -> (score: Int, breakdown: [String: Int]) {
        // Score
        var score = 0
        // Breakdown
        var breakdown: [String: Int] = [:]

        // 1. Tag Metadata Completeness
        if !track.title.isEmpty && track.title.lowercased() != "unknown title" {
            score += 10
            breakdown["Title"] = 10
        }
        if !track.artist.isEmpty && track.artist.lowercased() != "unknown artist" {
            score += 10
            breakdown["Artist"] = 10
        }
        if !track.album.isEmpty && track.album.lowercased() != "unknown album" {
            score += 10
            breakdown["Album"] = 10
        }
        // Release year
        if let year = track.year, year > 1900 {
            score += 10
            breakdown["Year"] = 10
        }
        // Musical genre classification
        if let genre = track.genre, !genre.isEmpty {
            score += 5
            breakdown["Genre"] = 5
        }
        if let trackNum = track.trackNumber, trackNum > 0 {
            score += 5
            breakdown["Track #"] = 5
        }
        // Synchronized or plain text lyrics if available
        if let lyrics = track.lyrics, !lyrics.isEmpty {
            score += 10
            breakdown["Lyrics"] = 10
        }
        if track.artworkKey != nil {
            score += 25
            breakdown["Artwork"] = 25
        }

        // 2. Audio Format & Codec Fidelity
        let ext = (track.fileInfo?.fileExtension ?? track.url.pathExtension).lowercased()
        // Format score
        var formatScore = 0
        switch ext {
        case "flac", "alac":
            formatScore = 40
        case "wav", "aiff", "aif", "caf":
            formatScore = 35
        case "m4a", "aac", "mp4":
            if let bitRate = track.fileInfo?.bitRate, bitRate >= 250000 {
                formatScore = 25
            } else {
                formatScore = 18
            }
        case "mp3":
            if let bitRate = track.fileInfo?.bitRate, bitRate >= 310000 {
                formatScore = 22
            } else if let bitRate = track.fileInfo?.bitRate, bitRate >= 250000 {
                formatScore = 16
            } else if let bitRate = track.fileInfo?.bitRate, bitRate >= 190000 {
                formatScore = 12
            } else {
                formatScore = 6
            }
        default:
            formatScore = 10
        }
        score += formatScore
        breakdown["Format (\(ext.uppercased()))"] = formatScore

        // 3. Audio Specifications (Sample Rate & Channels & Bitrate)
        if let info = track.fileInfo {
            // Spec score
            var specScore = 0
            if info.sampleRate >= 96000 {
                specScore += 15
            } else if info.sampleRate >= 48000 {
                specScore += 8
            } else if info.sampleRate >= 44100 {
                specScore += 5
            }

            if info.channelCount >= 2 {
                specScore += 10
            } else if info.channelCount == 1 {
                specScore += 2
            }

            // Bitrate bonus
            let bitrateBonus = min(15, Int(info.bitRate / 64000.0))
            specScore += bitrateBonus

            score += specScore
            breakdown["Audio Specs"] = specScore
        }

        return (score, breakdown)
    }

    // MARK: - String Normalization Helpers

    /// Result of title normalization containing both the cleaned title and any extracted version modifier.
    private struct NormalizedTitleInfo {
        /// The cleaned, normalized title string for comparison.
        let normalized: String
        /// A grouping key that strips even more aggressively (used for hash bucketing).
        let groupingKey: String
        /// Extracted version modifier (e.g., "remix", "acoustic", "live"), or nil if none found.
        let versionModifier: String?
    }

    /// Version modifiers that indicate distinct creative works.
    /// When one track has a modifier and the other doesn't, they should NOT be grouped.
    private static let versionModifiers: [String] = [
        "remix", "acoustic", "instrumental", "live", "radio edit", "extended",
        "extended mix", "club mix", "sped up", "slowed", "slowed and reverb",
        "slowed reverb", "chopped and screwed", "demo", "stripped",
        "unplugged", "a cappella", "acapella", "mashup", "bootleg",
        "vip mix", "dub mix", "interlude"
    ]

    /// Pattern to match version modifier tags in parentheses/brackets.
    private static let versionModifierRegex: NSRegularExpression? = {
        let modifiers = versionModifiers.joined(separator: "|")
        // Match (modifier...) or [modifier...] including optional surrounding text like year
        let pattern = #"[\(\[\{]\s*(?:"# + modifiers + #")(?:\s+[\w\d]+)*\s*[\)\]\}]"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Pattern to match feat./ft./featuring tags in titles.
    private static let featRegex: NSRegularExpression? = {
        let pattern = #"[\(\[\{]?\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]\}]+[\)\]\}]?"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Pattern to strip noise tags (remastered, explicit, clean, etc.) from titles.
    private static let noiseRegex: NSRegularExpression? = {
        let pattern = #"(?:\s*[\(\[\{](?:remastered|remaster|explicit|clean|official\s+audio|official\s+video|official|audio|video|lyrics|bonus\s+track|deluxe(?:\s+edition)?|320kbps|flac|hq|hd)(?:\s+[\w\d]+)*[\)\]\}]|\s*-\s*(?:remastered|official|audio|video).*$)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Pattern to strip track number prefixes like "01 - ", "1. ", "02_".
    private static let trackNumberPrefixRegex: NSRegularExpression? = {
        let pattern = #"^\s*\d+[\s\-\.\_]+"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Pattern to match "Title - Artist" filename-derived titles.
    private static let titleArtistSplitRegex: NSRegularExpression? = {
        let pattern = #"^(.+?)\s+-\s+.+$"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Strips noise, remaster tags, version modifiers, feat. tags, and track number prefixes from track titles.
    /// Returns both the normalized title and any extracted version modifier.
    private func normalizeTitle(_ rawTitle: String) -> NormalizedTitleInfo {
        var str = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove track number prefixes like "01 - ", "1. ", "02_"
        if let reg = Self.trackNumberPrefixRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Extract version modifier BEFORE stripping it
        var extractedModifier: String? = nil
        let lowered = str.lowercased()
        for modifier in Self.versionModifiers {
            if lowered.contains(modifier) {
                extractedModifier = modifier
                break
            }
        }

        // Remove version modifier tags
        if let reg = Self.versionModifierRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Remove feat./ft./featuring tags from title
        if let reg = Self.featRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Remove noise tags like (Remastered 2021), (Explicit), etc.
        if let reg = Self.noiseRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Remove non-alphanumeric noise, fold diacritics, lowercase
        let cleaned = str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        let normalized = cleaned.isEmpty ? rawTitle.lowercased() : cleaned

        return NormalizedTitleInfo(
            normalized: normalized,
            groupingKey: normalized,
            versionModifier: extractedModifier
        )
    }

    /// Normalizes artist strings for comparison.
    /// Strips feat./ft./featuring suffixes and leading "The".
    private func normalizeArtist(_ rawArtist: String) -> String {
        var str = rawArtist

        // Strip feat./ft./featuring from artist field
        if let reg = Self.featRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Fold diacritics, strip punctuation, lowercase
        let cleaned = str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        guard !cleaned.isEmpty else { return "unknown artist" }

        // Strip leading "the" (e.g., "the beatles" → "beatles")
        if cleaned.hasPrefix("the ") && cleaned.count > 4 {
            return String(cleaned.dropFirst(4))
        }

        return cleaned
    }

    /// Normalizes album strings for comparison.
    /// Strips deluxe/special edition noise and normalizes.
    private func normalizeAlbum(_ rawAlbum: String) -> String {
        var str = rawAlbum

        // Remove noise tags
        if let reg = Self.noiseRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        let cleaned = str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        return cleaned.isEmpty ? "unknown album" : cleaned
    }

    // MARK: - Levenshtein on Pre-Normalized Strings

    /// Computes Levenshtein similarity (0.0–1.0) on already-normalized strings.
    /// Unlike `FuzzyMatcher.levenshteinSimilarity`, this skips redundant re-normalization.
    private func levenshteinSimilarityPreNormalized(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 1.0 }
        let dist = fastLevenshtein(Array(s1.utf8), Array(s2.utf8), maxAllowed: maxLen)
        return max(0.0, 1.0 - (Double(dist) / Double(maxLen)))
    }

    @inline(__always)
    private func fastLevenshtein(_ a: [UInt8], _ b: [UInt8], maxAllowed: Int) -> Int {
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

// MARK: - Union-Find (Disjoint Set)

/// Lightweight union-find data structure for efficient transitive closure
/// when merging duplicate clusters. Ensures that if A≈B and B≈C,
/// then {A, B, C} all end up in the same group even if A and C
/// were never directly compared.
private final class UnionFind: @unchecked Sendable {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x]) // Path compression
        }
        return parent[x]
    }

    func union(_ x: Int, _ y: Int) {
        let rootX = find(x)
        let rootY = find(y)
        guard rootX != rootY else { return }

        // Union by rank
        if rank[rootX] < rank[rootY] {
            parent[rootX] = rootY
        } else if rank[rootX] > rank[rootY] {
            parent[rootY] = rootX
        } else {
            parent[rootY] = rootX
            rank[rootX] += 1
        }
    }
}
