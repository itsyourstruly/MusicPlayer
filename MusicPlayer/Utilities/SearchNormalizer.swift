import Foundation

/// Field identifiers for search indexing (weights live in the ranking code).
nonisolated public enum SearchFieldKind: UInt8, Sendable {
    /// Core title / name (feat. and qualifiers stripped).
    case primary = 0
    /// Name without a leading article ("Beatles" for "The Beatles").
    case primaryNoArticle = 1
    /// Primary field with spaces removed ("jayz", "acdc").
    case collapsed = 2
    /// Artist on a track, album artist on an album.
    case artist = 3
    /// Featured artists split out of a title.
    case featured = 4
    /// Album core title on a track.
    case album = 5
    /// Bracketed or " - " qualifier ("remastered 2011", "live").
    case qualifier = 6
    /// Genre (tracks) or year (albums).
    case tertiary = 7
}

/// One normalized field of an entity: its kind and its tokens.
nonisolated public struct SearchField: Sendable {
    public let kind: SearchFieldKind
    public let tokens: [String]
    public init(kind: SearchFieldKind, tokens: [String]) {
        self.kind = kind
        self.tokens = tokens
    }
    public var text: String { tokens.joined(separator: " ") }
}

/// The single normalization pipeline shared by index time and query time (plan §3.1).
/// Pure and thread-safe; never touches the device locale.
nonisolated public enum SearchNormalizer {

    // MARK: - Unicode fold (§3.1 step 1)

    /// NFKC → lowercase (no locale) → Latin/Greek/Cyrillic-only diacritic fold → katakana→hiragana → special letters.
    /// Idempotent: fold(fold(x)) == fold(x).
    public static func fold(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if text.utf8.allSatisfy({ $0 < 128 }) {
            return text.lowercased()
        }
        let lowered = text.precomposedStringWithCompatibilityMapping.lowercased()
        var out = String.UnicodeScalarView()
        var lastBaseIsFoldable = false
        for scalar in lowered.decomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if v >= 0x0300 && v <= 0x036F {
                // Combining diacritic: drop only when attached to a Latin, Greek or Cyrillic base.
                if lastBaseIsFoldable { continue }
                out.append(scalar)
                continue
            }
            if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .spacingMark {
                // Other marks (dakuten, Indic matras/virama, Thai vowels/tones) carry meaning: keep.
                out.append(scalar)
                continue
            }
            lastBaseIsFoldable = isLatinGreekCyrillic(v)
            if v >= 0x30A1 && v <= 0x30F6, let hira = Unicode.Scalar(v - 0x60) {
                out.append(hira)
                continue
            }
            switch v {
            case 0x00DF: out.append(contentsOf: "ss".unicodeScalars)      // ß
            case 0x00E6: out.append(contentsOf: "ae".unicodeScalars)      // æ
            case 0x0153: out.append(contentsOf: "oe".unicodeScalars)      // œ
            case 0x00F8: out.append("o")                                  // ø
            case 0x0142: out.append("l")                                  // ł
            case 0x0111, 0x00F0: out.append("d")                          // đ ð
            case 0x00FE: out.append(contentsOf: "th".unicodeScalars)      // þ
            case 0x0131: out.append("i")                                  // ı
            default: out.append(scalar)
            }
        }
        return String(out).precomposedStringWithCanonicalMapping
    }

    @inline(__always)
    private static func isLatinGreekCyrillic(_ v: UInt32) -> Bool {
        (v >= 0x41 && v <= 0x24F) || (v >= 0x1E00 && v <= 0x1EFF) ||
        (v >= 0x370 && v <= 0x3FF) || (v >= 0x1F00 && v <= 0x1FFF) ||
        (v >= 0x400 && v <= 0x52F)
    }

    // MARK: - Tokenization (§3.1 steps 2–4)

    /// Folds and splits text into word tokens. `&`/`+` become "and"; `$`→s, `@`→a;
    /// `! * . '` (and curly quotes) are removed inside words; everything else non-alphanumeric separates.
    /// Standalone "n" is kept as-is here; see `canonicalTokens`.
    public static func rawTokens(_ text: String) -> [String] {
        let folded = fold(text)
        guard !folded.isEmpty else { return [] }
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        for scalar in folded.unicodeScalars {
            let v = scalar.value
            if v < 128 {
                switch scalar {
                case "a"..."z", "0"..."9":
                    current.append(scalar)
                case "$":
                    current.append("s")
                case "@":
                    current.append("a")
                case "!", "*", ".", "'", "`":
                    continue
                case "&", "+":
                    flush()
                    tokens.append("and")
                default:
                    flush()
                }
                continue
            }
            if v == 0x2019 || v == 0x2018 || v == 0x02BC { continue } // ’ ‘ ʼ
            if v == 0x30FC { current.append(scalar); continue }        // ー prolonged sound mark stays in the word
            let props = scalar.properties
            if props.isAlphabetic || props.numericType != nil ||
               props.generalCategory == .nonspacingMark || props.generalCategory == .spacingMark ||
               props.generalCategory == .enclosingMark {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Tokens with the standalone-"n" rule applied: a completed word "n" means "and".
    /// When `lastIsPartial` is true (query still being typed), the last token is never rewritten.
    public static func canonicalTokens(_ text: String, lastIsPartial: Bool = false) -> [String] {
        var tokens = rawTokens(text)
        for i in tokens.indices where tokens[i] == "n" {
            if lastIsPartial && i == tokens.count - 1 { continue }
            tokens[i] = "and"
        }
        return tokens
    }

    /// Space-joined canonical normalized form (used for whole-field comparisons and legacy keys).
    public static func normalize(_ text: String) -> String {
        canonicalTokens(text).joined(separator: " ")
    }

    // MARK: - Query rules (§3.3, Q7)

    /// Number of grapheme clusters in the normalized query with separators removed.
    public static func normalizedLength(_ query: String) -> Int {
        rawTokens(query).reduce(0) { $0 + $1.count }
    }

    /// Q7: fewer than 2 normalized grapheme clusters → no search at all.
    public static func meetsMinimumLength(_ query: String) -> Bool {
        normalizedLength(query) >= 2
    }

    /// True when the user is still typing the last word (no trailing separator).
    public static func lastTokenIsPartial(_ query: String) -> Bool {
        guard let last = query.unicodeScalars.last else { return false }
        return !(CharacterSet.whitespacesAndNewlines.contains(last))
    }

    // MARK: - Title structure (§3.1 steps 5–6)

    public struct TitleParts: Sendable {
        public let core: String
        public let featured: [String]
        public let qualifiers: [String]
    }

    private static let featPrefixes = ["featuring ", "feat. ", "feat ", "ft. ", "ft ", "with "]

    /// Splits "Title (feat. X) [Remastered 2011] - Live" into core / featured / qualifiers.
    public static func splitTitle(_ raw: String) -> TitleParts {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TitleParts(core: "", featured: [], qualifiers: []) }
        var featured: [String] = []
        var qualifiers: [String] = []
        var core = ""
        var depth = 0
        var group = ""
        var closer: Character = ")"
        for ch in trimmed {
            if depth == 0, ch == "(" || ch == "[" || ch == "{" {
                depth = 1
                closer = ch == "(" ? ")" : (ch == "[" ? "]" : "}")
                group = ""
                continue
            }
            if depth > 0 {
                if ch == closer {
                    depth = 0
                    classifyGroup(group, featured: &featured, qualifiers: &qualifiers)
                    core.append(" ")
                } else {
                    group.append(ch)
                }
                continue
            }
            core.append(ch)
        }
        if depth > 0 { core.append(contentsOf: group) } // unbalanced: keep text
        // Unbracketed " feat. X" / " ft. X" / " featuring X"
        let lowerCore = core.lowercased()
        for marker in [" featuring ", " feat. ", " feat ", " ft. "] {
            if let r = lowerCore.range(of: marker) {
                let offset = lowerCore.distance(from: lowerCore.startIndex, to: r.lowerBound)
                let markerLen = lowerCore.distance(from: r.lowerBound, to: r.upperBound)
                let start = core.index(core.startIndex, offsetBy: offset)
                let after = core.index(start, offsetBy: markerLen)
                let names = String(core[after...]).trimmingCharacters(in: .whitespaces)
                if !names.isEmpty { featured.append(names) }
                core = String(core[..<start])
                break
            }
        }
        // Final " - " qualifier
        if let r = core.range(of: " - ", options: .backwards) {
            let head = String(core[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(core[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty && !tail.isEmpty {
                qualifiers.append(tail)
                core = head
            }
        }
        var cleanCore = core.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTokens(cleanCore).isEmpty {
            cleanCore = trimmed
            qualifiers = []
        }
        return TitleParts(core: cleanCore, featured: featured, qualifiers: qualifiers)
    }

    private static func classifyGroup(_ group: String, featured: inout [String], qualifiers: inout [String]) {
        let g = group.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return }
        let lower = g.lowercased()
        for p in featPrefixes where lower.hasPrefix(p) {
            let name = String(g.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { featured.append(name) }
            return
        }
        qualifiers.append(g)
    }

    // MARK: - Articles (§3.1 step 7)

    private static let articles: Set<String> = ["the", "a", "an", "el", "la", "los", "las", "le", "les", "il", "lo", "gli", "die", "der", "das"]

    /// Tokens without a leading article, or nil when there is none (or nothing would remain).
    public static func stripArticle(_ tokens: [String]) -> [String]? {
        guard tokens.count > 1, let first = tokens.first, articles.contains(first) else { return nil }
        return Array(tokens.dropFirst())
    }

    // MARK: - Number synonyms (§3.1 step 8, query side)

    private static let numberWords: [String] = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                                "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
    private static let tensWords: [Int: String] = [30: "thirty", 40: "forty", 50: "fifty", 60: "sixty", 70: "seventy", 80: "eighty", 90: "ninety", 100: "hundred"]
    private static let romans: [String] = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
                                           "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx"]

    /// Alternatives for one completed query token (at most 2 extra variants).
    public static func numberVariants(_ token: String, isLast: Bool) -> [String] {
        var out: [String] = []
        if let n = Int(token) {
            if n >= 0 && n <= 20 { out.append(numberWords[n]) }
            else if let w = tensWords[n] { out.append(w) }
        } else if let idx = numberWords.firstIndex(of: token) {
            out.append(String(idx))
        } else if let entry = tensWords.first(where: { $0.value == token }) {
            out.append(String(entry.key))
        }
        if isLast, token.count >= 2, let r = romans.firstIndex(of: token) {
            out.append(String(r + 1))
        }
        if isLast, let n = Int(token), n >= 1, n <= 20 {
            out.append(romans[n - 1])
        }
        return Array(out.prefix(2))
    }

    // MARK: - CJK units (§3.1 step 9)

    @inline(__always)
    public static func isCJKScalar(_ v: UInt32) -> Bool {
        (v >= 0x3040 && v <= 0x30FF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0x9FFF) ||
        (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0x1100 && v <= 0x11FF) || (v >= 0x3130 && v <= 0x318F) ||
        (v >= 0xF900 && v <= 0xFAFF) || (v >= 0x20000 && v <= 0x2FA1F)
    }

    /// True when the token contains any Han/kana/Hangul character.
    public static func containsCJK(_ token: String) -> Bool {
        token.unicodeScalars.contains { isCJKScalar($0.value) }
    }

    /// Bigrams and unigrams of every CJK run in a token (index side), after the kana fold.
    public static func cjkIndexUnits(_ token: String) -> [String] {
        var units: [String] = []
        for run in cjkRuns(token) {
            let chars = Array(run)
            for c in chars { units.append(String(c)) }
            if chars.count >= 2 {
                for i in 0..<(chars.count - 1) { units.append(String(chars[i]) + String(chars[i + 1])) }
            }
        }
        return units
    }

    /// Query side: a CJK run of length ≥2 becomes its bigrams; a run of 1 becomes a unigram.
    public static func cjkQueryUnits(_ token: String) -> [String] {
        var units: [String] = []
        for run in cjkRuns(token) {
            let chars = Array(run)
            if chars.count == 1 {
                units.append(String(chars[0]))
            } else {
                for i in 0..<(chars.count - 1) { units.append(String(chars[i]) + String(chars[i + 1])) }
            }
        }
        return units
    }

    /// Non-CJK remainder segments of a mixed token (e.g. "abc" in "abc愛").
    public static func nonCJKSegments(_ token: String) -> [String] {
        var segs: [String] = []
        var cur = ""
        for ch in token {
            if ch.unicodeScalars.contains(where: { isCJKScalar($0.value) }) {
                if !cur.isEmpty { segs.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { segs.append(cur) }
        return segs
    }

    private static func cjkRuns(_ token: String) -> [String] {
        var runs: [String] = []
        var cur = ""
        for ch in token {
            if ch.unicodeScalars.contains(where: { isCJKScalar($0.value) }) {
                cur.append(ch)
            } else if !cur.isEmpty {
                runs.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { runs.append(cur) }
        return runs
    }

    // MARK: - Entity field sets (§3.2)

    /// Adds the original ("n") form when the canonical form rewrote it, so both match.
    private static func withOriginal(_ text: String) -> (canonical: [String], original: [String]?) {
        let raw = rawTokens(text)
        var canon = raw
        var changed = false
        for i in canon.indices where canon[i] == "n" { canon[i] = "and"; changed = true }
        return (canon, changed ? raw : nil)
    }

    private static func appendPrimary(_ text: String, into fields: inout [SearchField], allowArticle: Bool) {
        let (canon, original) = withOriginal(text)
        guard !canon.isEmpty else { return }
        fields.append(SearchField(kind: .primary, tokens: canon))
        if let original { fields.append(SearchField(kind: .primaryNoArticle, tokens: original)) }
        if allowArticle, let stripped = stripArticle(canon) {
            fields.append(SearchField(kind: .primaryNoArticle, tokens: stripped))
        }
        if canon.count > 1 {
            fields.append(SearchField(kind: .collapsed, tokens: [canon.joined()]))
            if let original { fields.append(SearchField(kind: .collapsed, tokens: [original.joined()])) }
            if let stripped = allowArticle ? stripArticle(canon) : nil, stripped.count > 1 {
                fields.append(SearchField(kind: .collapsed, tokens: [stripped.joined()]))
            }
        }
    }

    private static func appendField(_ kind: SearchFieldKind, _ text: String, into fields: inout [SearchField]) {
        let (canon, original) = withOriginal(text)
        guard !canon.isEmpty else { return }
        fields.append(SearchField(kind: kind, tokens: canon))
        if let original { fields.append(SearchField(kind: kind, tokens: original)) }
    }

    public static func artistFields(name: String) -> [SearchField] {
        var fields: [SearchField] = []
        appendPrimary(name, into: &fields, allowArticle: true)
        return fields
    }

    public static func playlistFields(name: String) -> [SearchField] {
        var fields: [SearchField] = []
        appendPrimary(name, into: &fields, allowArticle: false)
        return fields
    }

    public static func albumFields(title: String, artist: String, year: Int?) -> [SearchField] {
        let parts = splitTitle(title)
        var fields: [SearchField] = []
        appendPrimary(parts.core, into: &fields, allowArticle: true)
        appendField(.artist, artist, into: &fields)
        if let stripped = stripArticle(rawTokens(artist)) {
            fields.append(SearchField(kind: .artist, tokens: stripped))
        }
        let artistTokens = rawTokens(artist)
        if artistTokens.count > 1 { fields.append(SearchField(kind: .artist, tokens: [artistTokens.joined()])) }
        for f in parts.featured { appendField(.featured, f, into: &fields) }
        for q in parts.qualifiers { appendField(.qualifier, q, into: &fields) }
        if let year, year > 0 { fields.append(SearchField(kind: .tertiary, tokens: [String(year)])) }
        return fields
    }

    public static func trackFields(title: String, artist: String, album: String, genre: String?) -> [SearchField] {
        let parts = splitTitle(title)
        var fields: [SearchField] = []
        appendPrimary(parts.core, into: &fields, allowArticle: false)
        appendField(.artist, artist, into: &fields)
        let artistTokens = rawTokens(artist)
        if artistTokens.count > 1 { fields.append(SearchField(kind: .artist, tokens: [artistTokens.joined()])) }
        for f in parts.featured { appendField(.featured, f, into: &fields) }
        let albumParts = splitTitle(album)
        appendField(.album, albumParts.core, into: &fields)
        for q in parts.qualifiers { appendField(.qualifier, q, into: &fields) }
        if let genre { appendField(.tertiary, genre, into: &fields) }
        return fields
    }

    /// Legacy substring-engine key: primary text first (its UTF-8 length is the primary length), then every other field.
    public static func legacyKey(for fields: [SearchField]) -> (key: String, primaryLength: Int32) {
        guard let primary = fields.first(where: { $0.kind == .primary }) else { return ("", 0) }
        let primaryText = primary.text
        var parts: [String] = [primaryText]
        for f in fields where !(f.kind == .primary && f.tokens == primary.tokens) {
            parts.append(f.text)
        }
        return (parts.joined(separator: " "), Int32(primaryText.utf8.count))
    }
}
