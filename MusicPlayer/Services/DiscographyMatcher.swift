import Foundation

/// High-precision matching engine aligning local audio files against unified online discography releases.
/// Calculates weighted scores (duration, Jaro-Winkler title similarity, track/disc numbers),
/// evaluates album relocations, and classifies alternate cuts (live, remix, acoustic, demo).
public final class DiscographyMatcher: Sendable {
    public static let shared = DiscographyMatcher()

    public init() {}

    /// Performs complete discography matching for all local albums and tracks of an artist against online releases.
    public func match(
        artistName: String,
        localTracks: [Track],
        localAlbums: [Album],
        onlineReleases: [UnifiedReleaseCandidate]
    ) -> DiscographyScanResult {
        var albumMatches: [DiscographyAlbumMatch] = []
        var singleMatches: [DiscographyAlbumMatch] = []
        var alternateAlbumMatches: [DiscographyAlbumMatch] = []

        // If localAlbums is provided, use every localAlbum directly so all local albums are guaranteed to be evaluated
        let targetAlbums: [(title: String, artist: String, artworkKey: String?, albumObj: Album?, tracks: [Track])] = {
            if !localAlbums.isEmpty {
                return localAlbums.map { alb in
                    (title: alb.title, artist: alb.artist, artworkKey: alb.artworkKey, albumObj: Optional(alb), tracks: alb.tracks)
                }
            } else {
                let grouped = Dictionary(grouping: localTracks) { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) }
                return grouped.map { (title, tracks) in
                    (title: title, artist: tracks.first?.artist ?? artistName, artworkKey: tracks.first?.artworkKey, albumObj: nil, tracks: tracks)
                }
            }
        }()

        for target in targetAlbums {
            let localAlbumTitle = target.title
            let tracksInAlbum = target.tracks
            let matchedLocalAlbum = target.albumObj

            let bestRelease = findBestMatchingRelease(
                localAlbumTitle: localAlbumTitle,
                artistName: artistName,
                tracksInAlbum: tracksInAlbum,
                onlineReleases: onlineReleases
            )

            var standardMatches: [DiscographyTrackMatch] = []
            var albumAlternates: [DiscographyTrackMatch] = []

            for localTrack in tracksInAlbum {
                let (bestOnlineTrack, bestScore) = findBestOnlineTrack(
                    for: localTrack,
                    in: bestRelease.tracks
                )

                // Relocation rule: if local album match scores < 0.45, scan other candidate albums
                if bestScore < 0.45 {
                    if let relocation = checkRelocation(
                        localTrack: localTrack,
                        allReleases: onlineReleases,
                        currentReleaseId: bestRelease.id
                    ) {
                        let match = buildTrackMatch(
                            localTrack: localTrack,
                            onlineTrack: relocation.targetTrack,
                            targetAlbumTitle: relocation.targetRelease.title,
                            score: relocation.score,
                            isRelocated: true,
                            relocationTarget: relocation.targetRelease.title,
                            isAlternate: false,
                            alternateReason: "Relocated from \"\(localAlbumTitle)\""
                        )
                        standardMatches.append(match)
                        continue
                    }
                }

                // Alternates detection rule
                let isAlt = isAlternateCut(
                    localTrack: localTrack,
                    matchedOnlineTrack: bestOnlineTrack
                )

                let match = buildTrackMatch(
                    localTrack: localTrack,
                    onlineTrack: bestOnlineTrack,
                    targetAlbumTitle: bestRelease.title,
                    score: bestScore,
                    isRelocated: false,
                    relocationTarget: nil,
                    isAlternate: isAlt.isAlternate,
                    alternateReason: isAlt.reason
                )

                if isAlt.isAlternate {
                    albumAlternates.append(match)
                } else {
                    standardMatches.append(match)
                }
            }

            let group = DiscographyAlbumMatch(
                localAlbum: matchedLocalAlbum,
                localAlbumTitle: localAlbumTitle,
                localAlbumArtist: target.artist,
                localArtworkKey: target.artworkKey,
                onlineRelease: bestRelease,
                trackMatches: standardMatches,
                alternates: albumAlternates
            )

            let isInherentlyAlternate = matchedLocalAlbum?.isRemix == true || matchedLocalAlbum?.isLive == true
            let isSingle = matchedLocalAlbum?.isSingle == true || group.isSingleOrEP

            if isInherentlyAlternate {
                alternateAlbumMatches.append(group)
            } else if isSingle {
                singleMatches.append(group)
            } else {
                albumMatches.append(group)
            }
        }

        // Dedicated Alternates view: includes inherently alternate albums PLUS regular albums/singles that contain detected alternate cuts
        var allAlternatesList = alternateAlbumMatches
        for regular in (albumMatches + singleMatches) where !regular.alternates.isEmpty {
            allAlternatesList.append(regular)
        }

        return DiscographyScanResult(
            artistName: artistName,
            albums: albumMatches.map { $0.toReviewItem(category: .albums) }.sorted { $0.album.title.localizedCaseInsensitiveCompare($1.album.title) == .orderedAscending },
            singles: singleMatches.map { $0.toReviewItem(category: .singles) }.sorted { $0.album.title.localizedCaseInsensitiveCompare($1.album.title) == .orderedAscending },
            alternates: allAlternatesList.map { $0.toReviewItem(category: .alternates) }.sorted { $0.album.title.localizedCaseInsensitiveCompare($1.album.title) == .orderedAscending }
        )
    }

    // MARK: - Scoring Algorithm (Candidate Scoring 0.0 - 1.0)

    /// Calculates candidate match score:
    /// - Duration Match (weight 0.40): Absolute diff <= 3s = 1.0, linear drop to 0.0 at >15s.
    /// - Title Distance (weight 0.40): Normalized Jaro-Winkler similarity (clean punctuation, omit tags).
    /// - Track & Disc Number (weight 0.20): Matches existing tags.
    public func calculateScore(local: Track, online: UnifiedTrackCandidate) -> Double {
        // 1. Duration Score (0.40)
        let durationScore: Double
        if let onlineDur = online.duration, onlineDur > 0, local.duration > 0 {
            let diff = abs(local.duration - onlineDur)
            if diff <= 3.0 {
                durationScore = 1.0
            } else if diff > 15.0 {
                durationScore = 0.0
            } else {
                durationScore = max(0.0, 1.0 - ((diff - 3.0) / 12.0))
            }
        } else {
            durationScore = 0.5 // neutral when duration unavailable
        }

        // 2. Title Distance Score (0.40)
        let cleanLocal = sanitizeTitle(local.title)
        let cleanOnline = sanitizeTitle(online.title)
        let titleScore: Double
        if cleanLocal == cleanOnline {
            titleScore = 1.0
        } else {
            titleScore = FuzzyMatcher.jaroWinklerSimilarity(cleanLocal, cleanOnline)
        }

        // 3. Track & Disc Number Score (0.20)
        let numberScore: Double
        if let localNum = local.trackNumber, let onlineNum = online.trackNumber, localNum > 0 {
            if localNum == onlineNum {
                let localDisc = local.discNumber ?? 1
                let onlineDisc = online.discNumber ?? 1
                numberScore = (localDisc == onlineDisc) ? 1.0 : 0.8
            } else {
                numberScore = 0.0
            }
        } else {
            numberScore = 0.5 // neutral if untagged
        }

        return (0.40 * durationScore) + (0.40 * titleScore) + (0.20 * numberScore)
    }

    // MARK: - Disambiguation & Relocation Rules

    private struct RelocationResult {
        let targetRelease: UnifiedReleaseCandidate
        let targetTrack: UnifiedTrackCandidate
        let score: Double
    }

    private func checkRelocation(
        localTrack: Track,
        allReleases: [UnifiedReleaseCandidate],
        currentReleaseId: String
    ) -> RelocationResult? {
        var highestScore: Double = 0.0
        var bestRelocation: RelocationResult?

        for release in allReleases where release.id != currentReleaseId {
            for track in release.tracks {
                let score = calculateScore(local: localTrack, online: track)
                if score >= 0.85 && score > highestScore {
                    highestScore = score
                    bestRelocation = RelocationResult(
                        targetRelease: release,
                        targetTrack: track,
                        score: score
                    )
                }
            }
        }

        return bestRelocation
    }

    // MARK: - Alternates Detection

    private struct AlternateCheckResult {
        let isAlternate: Bool
        let reason: String?
    }

    private func isAlternateCut(
        localTrack: Track,
        matchedOnlineTrack: UnifiedTrackCandidate?
    ) -> AlternateCheckResult {
        let titleLower = localTrack.title.lowercased()

        // 1. Explicit keyword checks
        let alternateKeywords = ["live", "acoustic", "remix", "instrumental", "demo", "radio edit", "extended mix", "dub mix"]
        for kw in alternateKeywords {
            if titleLower.contains(kw) {
                return AlternateCheckResult(isAlternate: true, reason: "\(kw.capitalized) cut")
            }
        }

        // 2. High title similarity (>= 0.80) but duration difference > 10s
        if let online = matchedOnlineTrack, let onlineDur = online.duration, onlineDur > 0, localTrack.duration > 0 {
            let cleanLocal = sanitizeTitle(localTrack.title)
            let cleanOnline = sanitizeTitle(online.title)
            let sim = FuzzyMatcher.jaroWinklerSimilarity(cleanLocal, cleanOnline)

            if sim >= 0.80 {
                let diff = abs(localTrack.duration - onlineDur)
                if diff > 10.0 {
                    return AlternateCheckResult(isAlternate: true, reason: "Duration variance (\(Int(diff))s)")
                }
            }
        }

        return AlternateCheckResult(isAlternate: false, reason: nil)
    }

    // MARK: - Field Diffs Generator

    private func buildTrackMatch(
        localTrack: Track,
        onlineTrack: UnifiedTrackCandidate?,
        targetAlbumTitle: String,
        score: Double,
        isRelocated: Bool,
        relocationTarget: String?,
        isAlternate: Bool,
        alternateReason: String?
    ) -> DiscographyTrackMatch {
        var diffs: [DiscographyFieldDiff] = []

        // Title
        let onlineTitle = onlineTrack?.title ?? localTrack.title
        let titleChanged = FuzzyMatcher.normalize(localTrack.title) != FuzzyMatcher.normalize(onlineTitle)
        diffs.append(DiscographyFieldDiff(
            field: .title,
            localValue: localTrack.title,
            onlineValue: onlineTitle,
            hasChange: titleChanged
        ))

        // Track #
        let localTrackNumStr = localTrack.trackNumber.map { String($0) } ?? "—"
        let onlineTrackNumStr = onlineTrack?.trackNumber.map { String($0) } ?? "—"
        let trackNumChanged = (onlineTrack?.trackNumber != nil) && (localTrack.trackNumber != onlineTrack?.trackNumber)
        diffs.append(DiscographyFieldDiff(
            field: .trackNumber,
            localValue: localTrackNumStr,
            onlineValue: onlineTrackNumStr,
            hasChange: trackNumChanged
        ))

        // Disc #
        let localDiscStr = localTrack.discNumber.map { String($0) } ?? "1"
        let onlineDiscStr = onlineTrack?.discNumber.map { String($0) } ?? "1"
        let discChanged = (onlineTrack?.discNumber != nil) && (localTrack.discNumber != onlineTrack?.discNumber)
        diffs.append(DiscographyFieldDiff(
            field: .discNumber,
            localValue: localDiscStr,
            onlineValue: onlineDiscStr,
            hasChange: discChanged
        ))

        // Year
        let localYearStr = localTrack.year.map { String($0) } ?? "—"
        let onlineYearStr = onlineTrack?.releaseYear.map { String($0) } ?? "—"
        let yearChanged = (onlineTrack?.releaseYear != nil && onlineTrack!.releaseYear! > 0) && (localTrack.year != onlineTrack?.releaseYear)
        diffs.append(DiscographyFieldDiff(
            field: .year,
            localValue: localYearStr,
            onlineValue: onlineYearStr,
            hasChange: yearChanged
        ))

        // Artwork
        let localArtStr = (localTrack.artworkKey != nil && !localTrack.artworkKey!.isEmpty) ? "Local Art" : "Missing"
        let onlineArtStr = onlineTrack?.artworkURL != nil ? "High-Res Art" : "—"
        let artChanged = onlineTrack?.artworkURL != nil && localTrack.artworkKey == nil
        diffs.append(DiscographyFieldDiff(
            field: .artwork,
            localValue: localArtStr,
            onlineValue: onlineArtStr,
            hasChange: artChanged
        ))

        // ISRC
        let onlineIsrc = onlineTrack?.isrc ?? "—"
        let isrcChanged = onlineTrack?.isrc != nil && !onlineTrack!.isrc!.isEmpty
        diffs.append(DiscographyFieldDiff(
            field: .isrc,
            localValue: "—",
            onlineValue: onlineIsrc,
            hasChange: isrcChanged
        ))

        return DiscographyTrackMatch(
            localTrack: localTrack,
            matchedOnlineTrack: onlineTrack,
            targetAlbumTitle: targetAlbumTitle,
            isRelocated: isRelocated,
            relocationTarget: relocationTarget,
            isAlternate: isAlternate,
            alternateReason: alternateReason,
            score: score,
            isLocked: false,
            fieldDiffs: diffs
        )
    }

    // MARK: - Helpers & Sanitization

    private func findBestMatchingRelease(
        localAlbumTitle: String,
        artistName: String,
        tracksInAlbum: [Track],
        onlineReleases: [UnifiedReleaseCandidate]
    ) -> UnifiedReleaseCandidate {
        let cleanLocal = sanitizeTitle(DeluxeAlbumDetector.cleanToStandardAlbumName(localAlbumTitle))

        var bestRelease = onlineReleases.first ?? UnifiedReleaseCandidate(
            title: localAlbumTitle,
            artist: artistName,
            tracks: []
        )
        var highestScore: Double = -1.0

        for release in onlineReleases {
            let cleanOnline = sanitizeTitle(DeluxeAlbumDetector.cleanToStandardAlbumName(release.title))
            var albumScore = FuzzyMatcher.jaroWinklerSimilarity(cleanLocal, cleanOnline)

            // Bonus if track names match
            var trackMatchesCount = 0
            for t in tracksInAlbum.prefix(5) {
                let cleanT = sanitizeTitle(t.title)
                if release.tracks.contains(where: { sanitizeTitle($0.title) == cleanT }) {
                    trackMatchesCount += 1
                }
            }
            if !tracksInAlbum.isEmpty {
                albumScore += (Double(trackMatchesCount) / Double(min(5, tracksInAlbum.count))) * 0.3
            }

            if albumScore > highestScore {
                highestScore = albumScore
                bestRelease = release
            }
        }

        return bestRelease
    }

    private func findBestOnlineTrack(
        for local: Track,
        in onlineTracks: [UnifiedTrackCandidate]
    ) -> (UnifiedTrackCandidate?, Double) {
        var bestTrack: UnifiedTrackCandidate?
        var highestScore: Double = 0.0

        for online in onlineTracks {
            let score = calculateScore(local: local, online: online)
            if score > highestScore {
                highestScore = score
                bestTrack = online
            }
        }

        return (bestTrack, highestScore)
    }

    /// Strips punctuation, lowercases, and omits standard noise tags.
    public func sanitizeTitle(_ raw: String) -> String {
        var s = raw.lowercased()
        let patterns = [
            #"[\(\[\{]\s*(?:remastered|remaster|\d{4}\s+remaster|explicit|deluxe|bonus\s+track|single\s+version|album\s+version)[\)\]\}]"#,
            #"\s*-\s*(?:remastered|remaster|\d{4}\s+remaster|explicit|deluxe|bonus\s+track|single\s+version|album\s+version).*$"#,
            #"(?:feat\.|ft\.|featuring)\s+[^,\(\[\-]+"#
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return FuzzyMatcher.normalize(s)
    }
}
