import Foundation

/// Release-type metadata reported by a source (server or file tags). `nil` fields mean "not reported".
nonisolated public struct ReleaseTypeInfo: Codable, Sendable, Equatable, Hashable {
    public enum Primary: String, Codable, Sendable, Hashable {
        case album, single, ep, broadcast, other
    }

    public var primary: Primary?
    public var secondaries: [String]
    public var isCompilation: Bool?
    public var version: String?
    public var source: String
    public var rawValues: [String]

    public init(primary: Primary?, secondaries: [String], isCompilation: Bool?, version: String?, source: String, rawValues: [String]) {
        self.primary = primary
        self.secondaries = secondaries
        self.isCompilation = isCompilation
        self.version = version
        self.source = source
        self.rawValues = rawValues
    }

    private static let secondaryNames: Set<String> = [
        "compilation", "soundtrack", "spokenword", "interview", "audiobook", "audio drama",
        "live", "remix", "dj-mix", "mixtape/street", "demo", "field recording"
    ]

    /// Builds info from raw MusicBrainz-style type strings. Returns nil when nothing usable was reported.
    public static func from(rawTypes: [String], isCompilation: Bool?, version: String?, source: String) -> ReleaseTypeInfo? {
        let raw = rawTypes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionValue = (cleanVersion?.isEmpty ?? true) ? nil : cleanVersion
        guard !raw.isEmpty || versionValue != nil || isCompilation == true else { return nil }

        var primary: Primary?
        var secondaries: [String] = []
        for value in raw {
            var parts: [String] = []
            for piece in value.lowercased().split(whereSeparator: { $0 == ";" || $0 == "," }) {
                let trimmedPiece = piece.trimmingCharacters(in: .whitespaces)
                if trimmedPiece == "mixtape/street" { parts.append(trimmedPiece) } else {
                    parts.append(contentsOf: trimmedPiece.split(separator: "/").map { String($0) })
                }
            }
            for part in parts {
                let token = part.trimmingCharacters(in: .whitespaces)
                switch token {
                case "album", "lp": if primary == nil { primary = .album }
                case "single": if primary == nil { primary = .single }
                case "ep": if primary == nil { primary = .ep }
                case "broadcast": if primary == nil { primary = .broadcast }
                case "other": if primary == nil { primary = .other }
                case "dj mix", "djmix": secondaries.append("dj-mix")
                case "mixtape", "street", "mixtape/street": secondaries.append("mixtape/street")
                default:
                    if secondaryNames.contains(token) { secondaries.append(token) }
                }
            }
        }
        if isCompilation == true && !secondaries.contains("compilation") { secondaries.append("compilation") }
        return ReleaseTypeInfo(primary: primary, secondaries: secondaries, isCompilation: isCompilation, version: versionValue, source: source, rawValues: raw)
    }
}

/// Resolves release-type info for library albums from the stored server catalogs.
nonisolated public final class ReleaseTypeRegistry: @unchecked Sendable {
    public static let shared = ReleaseTypeRegistry()

    private let lock = NSLock()
    private var cachedRevision = -1
    private var infoByAlbumKey: [String: ReleaseTypeInfo] = [:]

    /// Changes whenever the underlying catalogs change (use it in cache keys).
    public var revision: Int { ServerCatalogStore.shared.revision &* 1_000_003 &+ LocalReleaseTagStore.shared.revision }

    /// Server catalog info (keyed by server album ID) first; otherwise the most common local file tag info across the album's tracks.
    public func info(for album: Album) -> ReleaseTypeInfo? {
        guard let key = album.tracks.lazy.compactMap({ $0.jellyfinAlbumId }).first(where: { !$0.isEmpty }) else {
            return LocalReleaseTagStore.shared.dominantInfo(for: album.tracks)
        }
        let current = ServerCatalogStore.shared.revision
        lock.lock(); defer { lock.unlock() }
        if current != cachedRevision {
            var merged: [String: ReleaseTypeInfo] = [:]
            for catalog in ServerCatalogStore.shared.snapshot().values {
                if let infos = catalog.albumReleaseInfo { merged.merge(infos) { a, _ in a } }
            }
            infoByAlbumKey = merged
            cachedRevision = current
        }
        return infoByAlbumKey[key]
    }
}

/// Artist-page discography sections, in display order.
nonisolated public enum DiscographySection: Int, Sendable, CaseIterable {
    case albums, singlesAndEPs, alternates, featuredOn
}

/// Single source of truth for artist-discography classification (plan §3.8) and ordering.
nonisolated public enum DiscographyClassifier {
    public struct Sections {
        public var albums: [Album] = []
        public var singlesAndEPs: [Album] = []
        public var alternates: [Album] = []
        public var featuredOn: [Album] = []
    }

    private static let alternateSecondaries: Set<String> = ["remix", "live", "dj-mix", "demo"]
    private static let originalVersions: Set<String> = ["original", "standard", "album"]
    private static let qualifierWords: Set<String> = [
        "deluxe", "expanded", "anniversary", "remaster", "remastered", "edition", "complete",
        "platinum", "reloaded", "bonus", "extended", "alternate", "alternates", "instrumental",
        "instrumentals", "acapella", "acapellas", "remix", "remixes", "slowed", "unplugged", "live"
    ]
    private static let qualifierPhrases: [[String]] = [["chopped", "and", "screwed"], ["sped", "up"]]

    /// Section for an album on `artistName`'s page, or nil if it does not belong there.
    public static func section(for album: Album, artistName: String, joinedArtists: [String]) -> DiscographySection? {
        if album.isFeaturedAlbum(for: artistName, joinedArtists: joinedArtists) { return .featuredOn }
        guard album.isLeadOrCollaborativeAlbum(for: artistName, joinedArtists: joinedArtists) else { return nil }
        return releaseSection(for: album)
    }

    /// Rows 2–7 of the precedence table (the album is the artist's own release).
    public static func releaseSection(for album: Album) -> DiscographySection {
        releaseSection(for: album, info: ReleaseTypeRegistry.shared.info(for: album))
    }

    public static func releaseSection(for album: Album, info: ReleaseTypeInfo?) -> DiscographySection {
        // Row 2
        var primaryIsAlbum = false
        if let info {
            if info.secondaries.contains(where: { alternateSecondaries.contains($0) }) { return .alternates }
            switch info.primary {
            case .single?, .ep?: return .singlesAndEPs
            case .album?: primaryIsAlbum = true
            default: break
            }
            // Row 3
            if let version = info.version?.lowercased(), !version.isEmpty, !originalVersions.contains(version) {
                return .alternates
            }
        }
        // Row 4a
        if hasAlternateQualifier(album.title) { return .alternates }
        if primaryIsAlbum { return .albums }
        // Row 4b
        if hasSingleOrEPSuffix(album.title) { return .singlesAndEPs }
        // Row 5 (last resort): every track is a remix or live recording.
        if allTracksAlternate(album) { return .alternates }
        // Row 6 (only without a reported primary type)
        if info?.primary == nil {
            let count = album.tracks.count
            let duration = album.totalDuration
            if count >= 1 && count <= 3 && duration < 15 * 60 { return .singlesAndEPs }
            if count >= 4 && count <= 6 && duration < 30 * 60 { return .singlesAndEPs }
        }
        return .albums
    }

    /// True when the album has tracks and every one is a remix/alternate or live cut (explicit flag first, then title heuristics).
    public static func allTracksAlternate(_ album: Album) -> Bool {
        guard !album.tracks.isEmpty else { return false }
        return album.tracks.allSatisfy(isAlternateTrack)
    }

    /// Per-track alternate rule shared by row 5 and `Album`'s main/alternate track split.
    /// An explicit `isAlternate` flag wins; otherwise remix/alternate-version or live titles count.
    public static func isAlternateTrack(_ track: Track) -> Bool {
        if let flag = track.isAlternate { return flag }
        return MetadataSanitizer.isRemixOrAlternateVersion(title: track.title, album: track.album) ||
               MetadataSanitizer.isLiveRecording(title: track.title, album: track.album)
    }

    /// True when the title carries a bracketed or final " - " qualifier naming an alternate version.
    public static func hasAlternateQualifier(_ title: String) -> Bool {
        let parts = SearchNormalizer.splitTitle(title)
        for qualifier in parts.qualifiers {
            let tokens = SearchNormalizer.rawTokens(SearchNormalizer.fold(qualifier))
            if tokens.contains(where: { qualifierWords.contains($0) }) { return true }
            for phrase in qualifierPhrases where tokens.count >= phrase.count {
                for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<start + phrase.count]) == phrase {
                    return true
                }
            }
        }
        return false
    }

    public static func hasSingleOrEPSuffix(_ title: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return hasSingleSuffix(lower) || lower.hasSuffix(" - ep") || lower.hasSuffix("(ep)") || lower.hasSuffix("[ep]")
    }

    /// Single-only name rule (no EP), used for tag writing: " - Single", " (Single)", " [Single]" or exactly "Single".
    /// Requires a separator, so names such as "Not a Single" or "Greatest Singles" do not match.
    public static func hasSingleSuffix(_ title: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "single" || lower.hasSuffix(" - single") || lower.hasSuffix(" (single)") || lower.hasSuffix(" [single]")
    }

    /// Label used by album detail; always agrees with the section.
    public static func displayTitle(for album: Album) -> String {
        let info = ReleaseTypeRegistry.shared.info(for: album)
        switch releaseSection(for: album, info: info) {
        case .alternates: return "ALTERNATE"
        case .singlesAndEPs:
            let lower = album.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if info?.primary == .ep || lower.hasSuffix(" - ep") || lower.hasSuffix("(ep)") || lower.hasSuffix("[ep]") { return "EP" }
            if info?.primary == .single || lower.hasSuffix(" - single") { return "SINGLE" }
            return album.tracks.count >= 4 ? "EP" : "SINGLE"
        case .albums, .featuredOn: return "ALBUM"
        }
    }

    /// Classifies and orders an artist's albums into the four sections.
    public static func sections(for albums: [Album], artistName: String, joinedArtists: [String]) -> Sections {
        var result = Sections()
        for album in albums {
            switch section(for: album, artistName: artistName, joinedArtists: joinedArtists) {
            case .albums?: result.albums.append(album)
            case .singlesAndEPs?: result.singlesAndEPs.append(album)
            case .alternates?: result.alternates.append(album)
            case .featuredOn?: result.featuredOn.append(album)
            case nil: break
            }
        }
        result.albums = ordered(result.albums)
        result.singlesAndEPs = ordered(result.singlesAndEPs)
        result.alternates = ordered(result.alternates)
        result.featuredOn = ordered(result.featuredOn)
        return result
    }

    /// Newest first (resolvedYear ?? year), no-year last, then title, then id.
    public static func ordered(_ albums: [Album]) -> [Album] {
        albums.sorted { lhs, rhs in
            let yL = lhs.resolvedYear ?? lhs.year
            let yR = rhs.resolvedYear ?? rhs.year
            switch (yL, yR) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
