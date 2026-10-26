import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// Token / prefix index for library search (plan §3.2–§3.4).
// Everything here is pure, value-typed and thread-safe; it is built at .utility priority and queried off-main.

/// How a query word matched an index token.
nonisolated public enum SearchMatchClass: UInt8, Sendable {
    case exact = 0
    case collapsed = 1
    case prefix = 2
    case fuzzy1 = 3
    case fuzzy2 = 4

    /// Result bucket contribution: 3 exact/collapsed, 2 prefix, 1 fuzzy.
    var bucket: Int {
        switch self {
        case .exact, .collapsed: return 3
        case .prefix: return 2
        case .fuzzy1, .fuzzy2: return 1
        }
    }
}

/// One occurrence of a token inside an entity field.
nonisolated public struct SearchPosting: Sendable {
    public let entity: UInt32
    public let field: UInt8      // SearchFieldKind raw value
    public let ordinal: UInt8    // field instance within the entity
    public let position: UInt16  // token position inside the field
}

/// Per-kind postings (CSR layout over the shared vocabulary) plus per-entity ranking data.
nonisolated public struct SearchTokenKindIndex<ID: Hashable & Sendable>: Sendable {
    public let ids: [ID]
    public let indexByID: [ID: Int]
    let postingStarts: [UInt32]
    let postings: [SearchPosting]
    /// Token count of the main primary field.
    let primaryTokenCounts: [UInt8]
    /// Whole primary strings (primary, without article, collapsed) for whole-field bonuses.
    let wholeTexts: [[String]]
    /// Rank of the entity by normalized primary text, then insertion order (stable tie-break).
    let sortRanks: [UInt32]

    public var count: Int { ids.count }

    static var empty: SearchTokenKindIndex<ID> {
        SearchTokenKindIndex(ids: [], indexByID: [:], postingStarts: [0], postings: [], primaryTokenCounts: [], wholeTexts: [], sortRanks: [])
    }
}

/// Result of one kind: top-K ids with scores, plus the dense score of every matched entity.
nonisolated public struct SearchTokenKindResult<ID: Hashable & Sendable>: Sendable {
    public var ids: [ID] = []
    public var scores: [Int] = []
    /// True for entries whose whole primary field equals the query.
    public var wholeExact: [Bool] = []
    /// Score per entity index (0 = no match). Empty when nothing matched.
    public var dense: [Int32] = []
    public var matchedCount: Int = 0
}

nonisolated public final class SearchTokenIndex: Sendable {
    let vocab: [String]
    let vocabBytes: [[UInt8]]
    let vocabScalarCounts: [UInt16]
    let tokenFreq: [UInt32]
    let tokenIDs: [String: UInt32]

    public let tracks: SearchTokenKindIndex<UUID>
    public let albums: SearchTokenKindIndex<String>
    public let artists: SearchTokenKindIndex<String>
    public let playlists: SearchTokenKindIndex<UUID>
    /// Trigram → vocabulary tokens (≥4 scalars, no CJK, not all digits), for bounded fuzzy candidates (§3.3).
    let trigrams: [UInt64: [UInt32]]

    public var vocabularySize: Int { vocab.count }

    init(vocab: [String], vocabBytes: [[UInt8]], vocabScalarCounts: [UInt16], tokenFreq: [UInt32], tokenIDs: [String: UInt32],
         tracks: SearchTokenKindIndex<UUID>, albums: SearchTokenKindIndex<String>,
         artists: SearchTokenKindIndex<String>, playlists: SearchTokenKindIndex<UUID>,
         trigrams: [UInt64: [UInt32]] = [:]) {
        self.trigrams = trigrams
        self.vocab = vocab
        self.vocabBytes = vocabBytes
        self.vocabScalarCounts = vocabScalarCounts
        self.tokenFreq = tokenFreq
        self.tokenIDs = tokenIDs
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    // MARK: - Build

    /// Index tokens for one field token: the token itself, plus CJK unigrams/bigrams, non-CJK segments
    /// of mixed tokens, and (where available) NLTokenizer words for CJK/Thai text.
    static func indexUnits(for token: String, wordTokenizer: (String) -> [String]) -> [String] {
        var units = [token]
        let hasCJK = SearchNormalizer.containsCJK(token)
        if hasCJK {
            units.append(contentsOf: SearchNormalizer.cjkIndexUnits(token))
            units.append(contentsOf: SearchNormalizer.nonCJKSegments(token))
        }
        if hasCJK || containsThai(token) {
            for w in wordTokenizer(token) where w != token { units.append(w) }
        }
        return units
    }

    static func containsThai(_ token: String) -> Bool {
        token.unicodeScalars.contains { $0.value >= 0x0E00 && $0.value <= 0x0E7F }
    }

    static func makeWordTokenizer() -> (String) -> [String] {
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .word)
        return { text in
            tokenizer.string = text
            var words: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let w = String(text[range])
                if !w.isEmpty { words.append(w) }
                return true
            }
            return words
        }
        #else
        return { _ in [] }
        #endif
    }

    @inline(__always)
    static func bytesLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }

    public static func build(
        tracks: [(id: UUID, fields: [SearchField])],
        albums: [(id: String, fields: [SearchField])],
        artists: [(id: String, fields: [SearchField])],
        playlists: [(id: UUID, fields: [SearchField])]
    ) -> SearchTokenIndex {
        let tokenizeWords = makeWordTokenizer()

        // Expand every entity's fields once: [entity][field] -> (kind, [[units at position]]).
        typealias Expanded = [(kind: SearchFieldKind, units: [[String]])]
        func expand<ID>(_ entities: [(id: ID, fields: [SearchField])]) -> [Expanded] {
            entities.map { entity in
                entity.fields.map { f in
                    (f.kind, f.tokens.map { indexUnits(for: $0, wordTokenizer: tokenizeWords) })
                }
            }
        }
        let tE = expand(tracks), alE = expand(albums), arE = expand(artists), pE = expand(playlists)

        var vocabSet = Set<String>()
        for group in [tE, alE, arE, pE] {
            for entity in group { for f in entity { for u in f.units { for s in u { vocabSet.insert(s) } } } }
        }
        var vocabPairs = vocabSet.map { (s: $0, b: Array($0.utf8)) }
        vocabPairs.sort { bytesLess($0.b, $1.b) }
        let vocab = vocabPairs.map { $0.s }
        let vocabBytes = vocabPairs.map { $0.b }
        var tokenIDs: [String: UInt32] = [:]
        tokenIDs.reserveCapacity(vocab.count)
        for (i, s) in vocab.enumerated() { tokenIDs[s] = UInt32(i) }
        let scalarCounts = vocab.map { UInt16(min($0.unicodeScalars.count, Int(UInt16.max))) }
        var freq = [UInt32](repeating: 0, count: vocab.count)

        func buildKind<ID: Hashable & Sendable>(_ entities: [(id: ID, fields: [SearchField])], _ expanded: [Expanded]) -> SearchTokenKindIndex<ID> {
            guard !entities.isEmpty else { return .empty }
            var counts = [UInt32](repeating: 0, count: vocab.count + 1)
            var pairs: [(UInt32, SearchPosting)] = []
            pairs.reserveCapacity(entities.count * 12)
            var primaryCounts: [UInt8] = []
            var wholeTexts: [[String]] = []
            var sortTexts: [String] = []
            primaryCounts.reserveCapacity(entities.count)
            for (ei, entity) in entities.enumerated() {
                var seenPrimary = false
                var pc: UInt8 = 0
                var wholes: [String] = []
                for (fi, f) in entity.fields.enumerated() {
                    if f.kind == .primary || f.kind == .primaryNoArticle || f.kind == .collapsed {
                        wholes.append(f.text)
                        if f.kind == .primary && !seenPrimary {
                            seenPrimary = true
                            pc = UInt8(min(f.tokens.count, 255))
                        }
                    }
                    guard fi < 255 else { continue }
                    let units = expanded[ei][fi].units
                    for (pos, tokUnits) in units.enumerated() {
                        let p16 = UInt16(min(pos, Int(UInt16.max)))
                        for u in tokUnits {
                            guard let tid = tokenIDs[u] else { continue }
                            counts[Int(tid)] += 1
                            freq[Int(tid)] += 1
                            pairs.append((tid, SearchPosting(entity: UInt32(ei), field: f.kind.rawValue, ordinal: UInt8(fi), position: p16)))
                        }
                    }
                }
                primaryCounts.append(max(pc, 1))
                wholeTexts.append(wholes)
                sortTexts.append(wholes.first ?? "")
            }
            // CSR offsets.
            var starts = [UInt32](repeating: 0, count: vocab.count + 1)
            var run: UInt32 = 0
            for i in 0..<vocab.count {
                starts[i] = run
                run += counts[i]
            }
            starts[vocab.count] = run
            var fill = starts
            var flat = [SearchPosting](repeating: SearchPosting(entity: 0, field: 0, ordinal: 0, position: 0), count: Int(run))
            for (tid, p) in pairs {
                flat[Int(fill[Int(tid)])] = p
                fill[Int(tid)] += 1
            }
            let order = sortTexts.indices.sorted { a, b in
                sortTexts[a] != sortTexts[b] ? sortTexts[a] < sortTexts[b] : a < b
            }
            var ranks = [UInt32](repeating: 0, count: entities.count)
            for (r, i) in order.enumerated() { ranks[i] = UInt32(r) }
            var byID: [ID: Int] = [:]
            byID.reserveCapacity(entities.count)
            for (i, e) in entities.enumerated() where byID[e.id] == nil { byID[e.id] = i }
            return SearchTokenKindIndex(ids: entities.map { $0.id }, indexByID: byID, postingStarts: starts, postings: flat,
                                        primaryTokenCounts: primaryCounts, wholeTexts: wholeTexts, sortRanks: ranks)
        }

        let tk = buildKind(tracks, tE)
        let alk = buildKind(albums, alE)
        let ark = buildKind(artists, arE)
        let pk = buildKind(playlists, pE)
        var tri: [UInt64: [UInt32]] = [:]
        for (i, word) in vocab.enumerated() {
            let sc = word.unicodeScalars.map { $0.value }
            guard SearchFuzzy.isFuzzyEligible(sc) else { continue }
            for g in Set(SearchFuzzy.trigrams(sc, partial: false)) { tri[g, default: []].append(UInt32(i)) }
        }
        return SearchTokenIndex(vocab: vocab, vocabBytes: vocabBytes, vocabScalarCounts: scalarCounts, tokenFreq: freq, tokenIDs: tokenIDs,
                                tracks: tk, albums: alk, artists: ark, playlists: pk, trigrams: tri)
    }

    // MARK: - Vocabulary lookups

    /// Token ids whose bytes start with `prefix` (excluding an exact match), capped to the most frequent `cap`.
    func prefixExpansions(_ prefix: [UInt8], cap: Int) -> [UInt32] {
        var lo = 0, hi = vocabBytes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.bytesLess(vocabBytes[mid], prefix) { lo = mid + 1 } else { hi = mid }
        }
        var out: [UInt32] = []
        var i = lo
        while i < vocabBytes.count {
            let b = vocabBytes[i]
            guard b.count >= prefix.count, b.starts(with: prefix) else { break }
            if b.count > prefix.count { out.append(UInt32(i)) }
            i += 1
        }
        if out.count > cap {
            out.sort { tokenFreq[Int($0)] > tokenFreq[Int($1)] }
            out.removeLast(out.count - cap)
        }
        return out
    }
}

// MARK: - Query

nonisolated public struct SearchQueryTerm: Sendable {
    /// Alternative forms; each alternative is a conjunction of words. alternatives[0][0] is the typed word.
    public var alternatives: [[String]]
    /// The typed word may prefix-match (last token still being typed).
    public var isPrefix: Bool
    /// CJK n-gram unit: exact match only.
    public var isCJKUnit: Bool
}

nonisolated public struct SearchParsedQuery: Sendable {
    public var terms: [SearchQueryTerm]
    /// Space-joined canonical query (for whole-field bonuses).
    public var wholeText: String
    /// Query with spaces removed, when it has ≥2 words and no CJK.
    public var collapsed: String?
    public var lastIsPartial: Bool

    private static let unitWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let tensWords = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    public static func parse(_ query: String) -> SearchParsedQuery {
        let partial = SearchNormalizer.lastTokenIsPartial(query)
        let toks = SearchNormalizer.canonicalTokens(query, lastIsPartial: partial)
        var terms: [SearchQueryTerm] = []
        var hasCJK = false
        var i = 0
        while i < toks.count {
            let tok = toks[i]
            let isLast = (i == toks.count - 1)
            // "twenty one" ↔ 21
            if i + 1 < toks.count, let t = tensWords.firstIndex(of: tok), let u = unitWords.firstIndex(of: toks[i + 1]) {
                terms.append(SearchQueryTerm(alternatives: [[tok, toks[i + 1]], [String((t + 2) * 10 + u + 1)]], isPrefix: false, isCJKUnit: false))
                i += 2
                continue
            }
            if SearchNormalizer.containsCJK(tok) {
                hasCJK = true
                for u in SearchNormalizer.cjkQueryUnits(tok) {
                    terms.append(SearchQueryTerm(alternatives: [[u]], isPrefix: false, isCJKUnit: true))
                }
                let segs = SearchNormalizer.nonCJKSegments(tok)
                for (si, seg) in segs.enumerated() {
                    let prefix = isLast && partial && si == segs.count - 1 && tok.hasSuffix(seg)
                    terms.append(SearchQueryTerm(alternatives: [[seg]], isPrefix: prefix, isCJKUnit: false))
                }
                i += 1
                continue
            }
            var alts: [[String]] = [[tok]]
            let variants = SearchNormalizer.numberVariants(tok, isLast: isLast)
            if !variants.isEmpty {
                alts.append(contentsOf: variants.map { [$0] })
            } else if let n = Int(tok), n > 20, n < 100, n % 10 != 0 {
                alts.append([tensWords[n / 10 - 2], unitWords[n % 10 - 1]])
            }
            terms.append(SearchQueryTerm(alternatives: alts, isPrefix: isLast && partial, isCJKUnit: false))
            i += 1
        }
        let collapsed = (!hasCJK && toks.count >= 2) ? toks.joined() : nil
        return SearchParsedQuery(terms: terms, wholeText: toks.joined(separator: " "), collapsed: collapsed, lastIsPartial: partial)
    }
}

// MARK: - Evaluation

nonisolated public struct SearchTokenLimits: Sendable {
    public var tracks: Int
    public var albums: Int
    public var artists: Int
    public var playlists: Int
    public init(tracks: Int, albums: Int, artists: Int, playlists: Int) {
        self.tracks = tracks; self.albums = albums; self.artists = artists; self.playlists = playlists
    }
}

nonisolated public struct SearchTokenResults: Sendable {
    public var tracks = SearchTokenKindResult<UUID>()
    public var albums = SearchTokenKindResult<String>()
    public var artists = SearchTokenKindResult<String>()
    public var playlists = SearchTokenKindResult<UUID>()
    public var usedFuzzy = false
    public var cancelled = false
}

/// One vocabulary token a query word expands to.
nonisolated struct SearchExpansion {
    let token: UInt32
    let cls: SearchMatchClass
    let edits: Int
    let firstDiffers: Bool
    let queryLength: Int
}

/// Best hit of one query term per entity (dense, indexed by entity).
nonisolated struct SearchTermHits {
    var score: [Float]
    var cls: [UInt8]
    var field: [UInt8]
    var ordinal: [UInt8]
    var position: [UInt16]
    var touched: [UInt32]

    init(count: Int) {
        score = [Float](repeating: -1, count: count)
        cls = [UInt8](repeating: 0, count: count)
        field = [UInt8](repeating: 0, count: count)
        ordinal = [UInt8](repeating: 0, count: count)
        position = [UInt16](repeating: 0, count: count)
        touched = []
    }

    @inline(__always) func has(_ e: Int) -> Bool { score[e] >= 0 }
}

nonisolated enum SearchScoring {
    // Plan §2: all kind priors are 0; ties are decided by the §3 rules in SearchEngine.
    static let kindPriorArtist: Double = 0.0
    static let kindPriorAlbum: Double = 0.0
    static let kindPriorPlaylist: Double = 0.0
    static let kindPriorTrack: Double = 0.0

    static func fieldWeight(_ raw: UInt8) -> Float {
        switch SearchFieldKind(rawValue: raw) ?? .tertiary {
        case .primary, .primaryNoArticle, .collapsed: return 1.0
        case .artist: return 0.70
        case .featured: return 0.50
        case .album: return 0.55
        case .qualifier: return 0.20
        case .tertiary: return 0.15
        }
    }

    static func classWeight(_ cls: SearchMatchClass, queryLength: Int, tokenLength: Int) -> Float {
        switch cls {
        case .exact: return 1.0
        case .collapsed: return 0.90
        case .prefix: return 0.80 * Float((Double(queryLength) / Double(max(tokenLength, 1))).squareRoot())
        case .fuzzy1: return 0.60
        case .fuzzy2: return 0.40
        }
    }

    static func isPrimaryField(_ raw: UInt8) -> Bool {
        raw <= SearchFieldKind.collapsed.rawValue
    }
}

nonisolated extension SearchTokenIndex {
    static let prefixCap = 2000

    /// Exact and prefix expansions of one word.
    func exactPrefixExpansions(word: String, allowPrefix: Bool) -> [SearchExpansion] {
        var out: [SearchExpansion] = []
        let qLen = word.unicodeScalars.count
        if let id = tokenIDs[word] {
            out.append(SearchExpansion(token: id, cls: .exact, edits: 0, firstDiffers: false, queryLength: qLen))
        }
        if allowPrefix {
            for id in prefixExpansions(Array(word.utf8), cap: Self.prefixCap) {
                out.append(SearchExpansion(token: id, cls: .prefix, edits: 0, firstDiffers: false, queryLength: qLen))
            }
        }
        return out
    }

    /// Dense best-hit table of one word's expansions inside a kind.
    func hits<ID>(_ kind: SearchTokenKindIndex<ID>, expansions: [SearchExpansion], budget: inout Int, cancelled: inout Bool) -> SearchTermHits {
        var h = SearchTermHits(count: kind.count)
        guard kind.count > 0 else { return h }
        kind.postings.withUnsafeBufferPointer { post in
            for e in expansions {
                if cancelled { return }
                let s = Int(kind.postingStarts[Int(e.token)]), end = Int(kind.postingStarts[Int(e.token) + 1])
                guard s < end else { continue }
                let tokLen = Int(vocabScalarCounts[Int(e.token)])
                let penalty: Float = Float(e.edits) * 0.1 + (e.firstDiffers ? 0.05 : 0)
                for pi in s..<end {
                    budget += 1
                    if (budget & 4095) == 0 && Task.isCancelled { cancelled = true; return }
                    let p = post[pi]
                    var cls = e.cls
                    if cls == .exact && p.field == SearchFieldKind.collapsed.rawValue { cls = .collapsed }
                    let sc = max(SearchScoring.classWeight(cls, queryLength: e.queryLength, tokenLength: tokLen) * SearchScoring.fieldWeight(p.field) - penalty, 0.001)
                    let ent = Int(p.entity)
                    if h.score[ent] < 0 { h.touched.append(p.entity) }
                    if sc > h.score[ent] {
                        h.score[ent] = sc
                        h.cls[ent] = cls.rawValue
                        h.field[ent] = p.field
                        h.ordinal[ent] = p.ordinal
                        h.position[ent] = p.position
                    }
                }
            }
        }
        return h
    }

    /// Hits of a full term: every alternative (a conjunction of words), best alternative per entity.
    func termHits<ID>(_ kind: SearchTokenKindIndex<ID>, term: SearchQueryTerm, extra: [SearchExpansion],
                      budget: inout Int, cancelled: inout Bool) -> SearchTermHits {
        var merged: SearchTermHits? = nil
        for (ai, alt) in term.alternatives.enumerated() {
            var altHits: SearchTermHits? = nil
            for (wi, word) in alt.enumerated() {
                let allowPrefix = (ai == 0 && alt.count == 1 && term.isPrefix)
                var exps = exactPrefixExpansions(word: word, allowPrefix: allowPrefix)
                if ai == 0 && wi == 0 && alt.count == 1 { exps.append(contentsOf: extra) }
                let h = hits(kind, expansions: exps, budget: &budget, cancelled: &cancelled)
                if cancelled { return h }
                if var acc = altHits {
                    // Conjunction: keep entities present in both, with the weaker score.
                    var kept: [UInt32] = []
                    for e in acc.touched {
                        let ei = Int(e)
                        if h.has(ei) {
                            acc.score[ei] = min(acc.score[ei], h.score[ei])
                            kept.append(e)
                        } else {
                            acc.score[ei] = -1
                        }
                    }
                    acc.touched = kept
                    altHits = acc
                } else {
                    altHits = h
                }
            }
            guard let a = altHits else { continue }
            if var m = merged {
                for e in a.touched {
                    let ei = Int(e)
                    if !m.has(ei) { m.touched.append(e) }
                    if a.score[ei] > m.score[ei] {
                        m.score[ei] = a.score[ei]; m.cls[ei] = a.cls[ei]; m.field[ei] = a.field[ei]
                        m.ordinal[ei] = a.ordinal[ei]; m.position[ei] = a.position[ei]
                    }
                }
                merged = m
            } else {
                merged = a
            }
        }
        return merged ?? SearchTermHits(count: kind.count)
    }
}

// MARK: - Kind evaluation and scoring

nonisolated extension SearchTokenIndex {
    /// Whole-field bonus (§3.4): ×1.6 when the query equals an entire primary field
    /// (primary, article-stripped or collapsed form), ×1.3 when a primary field starts with the full query.
    @inline(__always)
    func wholeFieldBonus<ID>(_ e: Int, kind: SearchTokenKindIndex<ID>, text: String) -> (factor: Double, exact: Bool) {
        guard !text.isEmpty, e < kind.wholeTexts.count else { return (1, false) }
        var prefix = false
        for w in kind.wholeTexts[e] {
            if w == text { return (1.6, true) }
            if !prefix && w.hasPrefix(text) { prefix = true }
        }
        return (prefix ? 1.3 : 1, false)
    }

    /// Scores one entity from its per-term hits. `missing` is the index of the one term allowed to be absent.
    @inline(__always)
    func scoreEntity<ID>(_ e: Int, terms: [SearchTermHits], missing: Int?, kind: SearchTokenKindIndex<ID>,
                         query: SearchParsedQuery, kindPrior: Double) -> (score: Int32, wholeExact: Bool) {
        let n = terms.count
        var sum: Float = 0
        var bucket = 3
        var matchedPrimary = 0
        var hasCJK = false
        for (ti, t) in terms.enumerated() where ti != missing {
            sum += t.score[e]
            bucket = min(bucket, (SearchMatchClass(rawValue: t.cls[e]) ?? .fuzzy2).bucket)
            if SearchScoring.isPrimaryField(t.field[e]) { matchedPrimary += 1 }
            if query.terms[ti].isCJKUnit { hasCJK = true }
        }
        var final = Double(sum) / Double(max(n, 1))

        // Whole field exact / prefix.
        let whole = missing == nil ? wholeFieldBonus(e, kind: kind, text: query.wholeText) : (factor: 1.0, exact: false)
        final *= whole.factor

        // Phrase in order: every term's best hit in one field, at consecutive positions.
        if missing == nil && n >= 2 && !hasCJK {
            var inOrder = true
            let ord = terms[0].ordinal[e]
            for ti in 1..<n where terms[ti].ordinal[e] != ord || Int(terms[ti].position[e]) != Int(terms[ti - 1].position[e]) + 1 {
                inOrder = false
                break
            }
            if inOrder { final *= 1.15 }
        }

        // Primary coverage (plan §2): query terms matched in the primary field / n.
        final *= 0.6 + 0.4 * min(Double(matchedPrimary) / Double(max(n, 1)), 1)

        if missing != nil {
            bucket = 0
            final *= 0.55
        }
        final += kindPrior
        return (Self.packScore(bucket: bucket, final: final), whole.exact && bucket == 3)
    }

    /// Score of an entity matched through the collapsed (space-free) query.
    @inline(__always)
    func scoreCollapsed<ID>(_ e: Int, hits: SearchTermHits, kind: SearchTokenKindIndex<ID>,
                            query: SearchParsedQuery, kindPrior: Double) -> (score: Int32, wholeExact: Bool) {
        let bucket = (SearchMatchClass(rawValue: hits.cls[e]) ?? .fuzzy2).bucket
        var final = Double(hits.score[e])
        let whole = wholeFieldBonus(e, kind: kind, text: query.collapsed ?? "")
        final *= whole.factor
        // A collapsed hit in a primary field covers the whole collapsed name.
        let primary = SearchScoring.isPrimaryField(hits.field[e])
        final *= primary ? 1 : 0.85
        final += kindPrior
        return (Self.packScore(bucket: bucket, final: final), whole.exact && bucket == 3)
    }

    @inline(__always)
    static func packScore(bucket: Int, final: Double) -> Int32 {
        Int32(bucket * 10_000_000 + Int(min(max(final, 0), 9.99) * 1_000_000))
    }

    func evaluateKind<ID>(
        _ kind: SearchTokenKindIndex<ID>,
        query: SearchParsedQuery,
        extras: [[SearchExpansion]],
        limit: Int,
        kindPrior: Double,
        allowMissing: Bool,
        budget: inout Int,
        cancelled: inout Bool
    ) -> SearchTokenKindResult<ID> {
        var result = SearchTokenKindResult<ID>()
        guard kind.count > 0, limit > 0, !query.terms.isEmpty else { return result }

        var termHits: [SearchTermHits] = []
        termHits.reserveCapacity(query.terms.count)
        for (ti, term) in query.terms.enumerated() {
            let h = self.termHits(kind, term: term, extra: ti < extras.count ? extras[ti] : [], budget: &budget, cancelled: &cancelled)
            if cancelled { return result }
            termHits.append(h)
        }

        var dense = [Int32](repeating: 0, count: kind.count)
        var whole = [Bool](repeating: false, count: kind.count)
        var matched: [UInt32] = []

        // Any-order AND, smallest posting set first.
        let order = termHits.indices.sorted { termHits[$0].touched.count < termHits[$1].touched.count }
        let first = order[0]
        candidateLoop: for e in termHits[first].touched {
            let ei = Int(e)
            for ti in order.dropFirst() where !termHits[ti].has(ei) { continue candidateLoop }
            let s = scoreEntity(ei, terms: termHits, missing: nil, kind: kind, query: query, kindPrior: kindPrior)
            dense[ei] = s.score
            whole[ei] = s.wholeExact
            matched.append(e)
        }

        // Collapsed query ("jay z" → "jayz").
        if let c = query.collapsed {
            let exps = exactPrefixExpansions(word: c, allowPrefix: query.lastIsPartial).map {
                SearchExpansion(token: $0.token, cls: $0.cls == .exact ? .collapsed : $0.cls, edits: 0, firstDiffers: false, queryLength: $0.queryLength)
            }
            if !exps.isEmpty {
                let h = hits(kind, expansions: exps, budget: &budget, cancelled: &cancelled)
                if cancelled { return result }
                for e in h.touched {
                    let ei = Int(e)
                    let s = scoreCollapsed(ei, hits: h, kind: kind, query: query, kindPrior: kindPrior)
                    if dense[ei] == 0 { matched.append(e) }
                    if s.score > dense[ei] { dense[ei] = s.score; whole[ei] = s.wholeExact }
                }
            }
        }

        let fullCount = matched.count
        // Fewer than 5 results: allow one missing non-last term.
        if allowMissing && termHits.count >= 2 && fullCount < 5 {
            let lastIdx = termHits.count - 1
            var counts = [UInt8](repeating: 0, count: kind.count)
            for t in termHits { for e in t.touched { counts[Int(e)] &+= 1 } }
            let need = UInt8(termHits.count - 1)
            for e in termHits[lastIdx].touched {
                let ei = Int(e)
                guard dense[ei] == 0, counts[ei] == need else { continue }
                guard let miss = (0..<lastIdx).first(where: { !termHits[$0].has(ei) }) else { continue }
                let s = scoreEntity(ei, terms: termHits, missing: miss, kind: kind, query: query, kindPrior: kindPrior)
                dense[ei] = max(s.score, 1)
                matched.append(e)
            }
        }

        guard !matched.isEmpty else { return result }
        let ranks = kind.sortRanks
        matched.sort { a, b in
            let sa = dense[Int(a)], sb = dense[Int(b)]
            return sa != sb ? sa > sb : ranks[Int(a)] < ranks[Int(b)]
        }
        for e in matched.prefix(limit) {
            let ei = Int(e)
            result.ids.append(kind.ids[ei])
            result.scores.append(Int(dense[ei]))
            result.wholeExact.append(whole[ei])
        }
        result.dense = dense
        result.matchedCount = fullCount
        return result
    }

    /// Runs the query over every kind (§3.3). Returns empty results when the query is too short (Q7).
    public func search(_ raw: String, limits: SearchTokenLimits) -> SearchTokenResults {
        var out = SearchTokenResults()
        guard SearchNormalizer.meetsMinimumLength(raw) else { return out }
        let query = SearchParsedQuery.parse(raw)
        guard !query.terms.isEmpty else { return out }
        var budget = 0
        var cancelled = false
        let noExtras: [[SearchExpansion]] = []

        // Pass 1: exact / collapsed / prefix only.
        out.artists = evaluateKind(artists, query: query, extras: noExtras, limit: limits.artists, kindPrior: SearchScoring.kindPriorArtist, allowMissing: true, budget: &budget, cancelled: &cancelled)
        if cancelled || Task.isCancelled { out.cancelled = true; return out }
        out.albums = evaluateKind(albums, query: query, extras: noExtras, limit: limits.albums, kindPrior: SearchScoring.kindPriorAlbum, allowMissing: true, budget: &budget, cancelled: &cancelled)
        if cancelled || Task.isCancelled { out.cancelled = true; return out }
        out.tracks = evaluateKind(tracks, query: query, extras: noExtras, limit: limits.tracks, kindPrior: SearchScoring.kindPriorTrack, allowMissing: true, budget: &budget, cancelled: &cancelled)
        if cancelled || Task.isCancelled { out.cancelled = true; return out }
        out.playlists = evaluateKind(playlists, query: query, extras: noExtras, limit: limits.playlists, kindPrior: SearchScoring.kindPriorPlaylist, allowMissing: true, budget: &budget, cancelled: &cancelled)
        if cancelled || Task.isCancelled { out.cancelled = true; return out }

        // Pass 2: fuzzy, only for kinds whose top-K is not already full.
        let needArtists = limits.artists > 0 && out.artists.matchedCount < limits.artists
        let needAlbums = limits.albums > 0 && out.albums.matchedCount < limits.albums
        let needTracks = limits.tracks > 0 && out.tracks.matchedCount < limits.tracks
        let needPlaylists = limits.playlists > 0 && out.playlists.matchedCount < limits.playlists
        guard needArtists || needAlbums || needTracks || needPlaylists else { return out }
        let extras = fuzzyExtras(query, budget: &budget, cancelled: &cancelled)
        if cancelled || Task.isCancelled { out.cancelled = true; return out }
        guard extras.contains(where: { !$0.isEmpty }) else { return out }
        out.usedFuzzy = true
        if needArtists {
            out.artists = evaluateKind(artists, query: query, extras: extras, limit: limits.artists, kindPrior: SearchScoring.kindPriorArtist, allowMissing: true, budget: &budget, cancelled: &cancelled)
            if cancelled || Task.isCancelled { out.cancelled = true; return out }
        }
        if needAlbums {
            out.albums = evaluateKind(albums, query: query, extras: extras, limit: limits.albums, kindPrior: SearchScoring.kindPriorAlbum, allowMissing: true, budget: &budget, cancelled: &cancelled)
            if cancelled || Task.isCancelled { out.cancelled = true; return out }
        }
        if needTracks {
            out.tracks = evaluateKind(tracks, query: query, extras: extras, limit: limits.tracks, kindPrior: SearchScoring.kindPriorTrack, allowMissing: true, budget: &budget, cancelled: &cancelled)
            if cancelled || Task.isCancelled { out.cancelled = true; return out }
        }
        if needPlaylists {
            out.playlists = evaluateKind(playlists, query: query, extras: extras, limit: limits.playlists, kindPrior: SearchScoring.kindPriorPlaylist, allowMissing: true, budget: &budget, cancelled: &cancelled)
            if cancelled || Task.isCancelled { out.cancelled = true }
        }
        return out
    }
}

// MARK: - Bounded fuzzy matching (§3.3)

nonisolated enum SearchFuzzy {
    static let candidateCap = 200
    private static let padStart: UInt32 = 1
    private static let padEnd: UInt32 = 2

    /// Fuzzy targets and queries: at least 4 scalars, no CJK, not all digits.
    static func isFuzzyEligible(_ sc: [UInt32]) -> Bool {
        guard sc.count >= 4 else { return false }
        var allDigits = true
        for v in sc {
            if SearchNormalizer.isCJKScalar(v) { return false }
            if !(v >= 0x30 && v <= 0x39) { allDigits = false }
        }
        return !allDigits
    }

    static func maxEdits(_ length: Int) -> Int { length >= 8 ? 2 : (length >= 4 ? 1 : 0) }

    @inline(__always)
    static func pack(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt64 {
        (UInt64(a) << 42) | (UInt64(b) << 21) | UInt64(c)
    }

    /// Padded trigrams: "^^word$" for whole tokens, "^^word" (front only) for a partial last token.
    static func trigrams(_ sc: [UInt32], partial: Bool) -> [UInt64] {
        var p: [UInt32] = [padStart, padStart]
        p.append(contentsOf: sc)
        if !partial { p.append(padEnd) }
        guard p.count >= 3 else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(p.count - 2)
        for i in 0..<(p.count - 2) { out.append(pack(p[i], p[i + 1], p[i + 2])) }
        return out
    }

    /// Optimal-string-alignment distance, or k+1 once it is known to exceed k.
    static func osa(_ a: [UInt32], _ b: ArraySlice<UInt32>, k: Int) -> Int {
        let b = Array(b)
        let n = a.count, m = b.count
        if abs(n - m) > k { return k + 1 }
        if n == 0 { return m }
        if m == 0 { return n }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    v = min(v, prev2[j - 2] + 1)
                }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > k { return k + 1 }
            swap(&prev2, &prev)
            swap(&prev, &cur)
        }
        return prev[m]
    }
}

nonisolated extension SearchTokenIndex {
    /// Fuzzy expansions of one query word (empty when the word is not eligible or is guarded).
    func fuzzyExpansions(word: String, partial: Bool, budget: inout Int, cancelled: inout Bool) -> [SearchExpansion] {
        let q = word.unicodeScalars.map { $0.value }
        guard SearchFuzzy.isFuzzyEligible(q) else { return [] }
        let L = q.count
        // Dictionary guard: a 4–5 character word that is itself in the vocabulary is never fuzzed.
        if L <= 5 && tokenIDs[word] != nil { return [] }
        let k = SearchFuzzy.maxEdits(L)
        let grams = Array(Set(SearchFuzzy.trigrams(q, partial: partial)))
        // Plan: ≥ trigrams − 3k shared. Tuned with the harness to 4k: one OSA transposition
        // in the middle of a word ("rhianna"/"rihanna") breaks up to four padded trigrams.
        let minShared = max(1, grams.count - 4 * k)
        let first = q[0], second = q[1]

        var counts: [UInt32: UInt16] = [:]
        for g in grams {
            guard let list = trigrams[g] else { continue }
            for t in list {
                budget += 1
                if (budget & 4095) == 0 && Task.isCancelled { cancelled = true; return [] }
                counts[t, default: 0] &+= 1
            }
        }
        var candidates: [(token: UInt32, shared: UInt16)] = []
        for (t, c) in counts where Int(c) >= minShared {
            guard let f = vocab[Int(t)].unicodeScalars.first?.value, f == first || f == second else { continue }
            candidates.append((t, c))
        }
        candidates.sort { $0.shared != $1.shared ? $0.shared > $1.shared : tokenFreq[Int($0.token)] > tokenFreq[Int($1.token)] }
        if candidates.count > SearchFuzzy.candidateCap { candidates.removeLast(candidates.count - SearchFuzzy.candidateCap) }

        var out: [SearchExpansion] = []
        for c in candidates {
            let t = vocab[Int(c.token)].unicodeScalars.map { $0.value }
            guard t.count >= 4 else { continue }
            // The second-character exception exists only for a first-position transposition
            // ("ekndrick" → "kendrick"), so such a target must start with q[1] q[0].
            if t[0] != first && !(t[0] == second && t[1] == first) { continue }
            var d = k + 1
            if partial && t.count > L {
                // Last token still being typed: compare with the target's prefixes of length |q|±k.
                // (A target no longer than the query is compared whole, so "nasa" cannot reach "asap" via "asa".)
                for len in max(1, L - k)...(L + k) where len <= t.count {
                    d = min(d, SearchFuzzy.osa(q, t[0..<len], k: k))
                    if d == 0 { break }
                }
            } else {
                d = SearchFuzzy.osa(q, t[...], k: k)
            }
            guard d >= 1, d <= k else { continue }
            out.append(SearchExpansion(token: c.token, cls: d == 1 ? .fuzzy1 : .fuzzy2, edits: d,
                                       firstDiffers: t[0] != first, queryLength: L))
        }
        return out
    }

    /// Per-term fuzzy extras (only single-word, non-CJK first alternatives are fuzzed).
    func fuzzyExtras(_ query: SearchParsedQuery, budget: inout Int, cancelled: inout Bool) -> [[SearchExpansion]] {
        var extras: [[SearchExpansion]] = []
        for (ti, term) in query.terms.enumerated() {
            guard !term.isCJKUnit, let alt = term.alternatives.first, alt.count == 1 else { extras.append([]); continue }
            let partial = term.isPrefix && ti == query.terms.count - 1
            extras.append(fuzzyExpansions(word: alt[0], partial: partial, budget: &budget, cancelled: &cancelled))
            if cancelled { return extras }
        }
        return extras
    }
}
