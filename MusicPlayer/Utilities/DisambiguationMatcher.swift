import Foundation

/// High-precision heuristic and disambiguation engine for evaluating online Apple Music catalog tracks
/// against local track signatures. Enforces audio length validation (±5s), version/remix consistency,
/// and string similarity thresholds to eliminate false positives.
public enum DisambiguationMatcher {

    /// Minimum confidence score required to accept an online match candidate (0.90 on 0..1 scale, 900 on 0..1000 scale).
    public static let minimumAcceptanceThreshold: Int = 900

    // MARK: - Match Evaluation

    /// Evaluates whether an online candidate matches the local track signature using precision weighted scoring.
    /// Returns a normalized confidence score in range 0..1000 (or nil if rejected by hard guardrails).
    public static func evaluateMatch(
        signature: TrackSignature,
        online: OnlineTrackMetadata
    ) -> Int? {
        // 0. Filter out low-quality junk, karaoke, tribute, and ringtone imitations
        let lowerOnlineTitle = online.title.lowercased()
        let lowerOnlineArtist = online.artist.lowercased()
        let lowerOnlineAlbum = online.album.lowercased()

        let junkKeywords = ["karaoke", "tribute to", "in the style of", "originally performed by", "soundtrack tribute", "ringtone", "cover version"]
        for kw in junkKeywords {
            if (lowerOnlineTitle.contains(kw) || lowerOnlineArtist.contains(kw) || lowerOnlineAlbum.contains(kw)) &&
               !signature.coreTitle.lowercased().contains(kw) {
                return nil
            }
        }

        // 1. Version Modifier & Remix Consistency Protection
        let isLocalRemix = (signature.versionModifier != nil && MetadataSanitizer.isRemixOrAlternateVersion(title: signature.versionModifier!)) || MetadataSanitizer.isRemixOrAlternateVersion(title: signature.coreTitle, album: signature.standardAlbum)
        let isOnlineRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: online.title, album: online.album)

        let onlineSignature = MetadataSanitizer.buildSignature(
            title: online.title,
            artist: online.artist,
            album: online.album,
            duration: online.duration ?? 0,
            trackNumber: online.trackNumber
        )

        // Strict remix isolation: standard track MUST NOT match remix; remix MUST match remix
        if isLocalRemix != isOnlineRemix {
            return nil
        }

        // If local track has a specific version modifier, verify match
        if let localModifier = signature.versionModifier {
            guard let onlineModifier = onlineSignature.versionModifier else {
                return nil
            }
            let normLocalMod = normalize(localModifier)
            let normOnlineMod = normalize(onlineModifier)
            let modSim = max(
                FuzzyMatcher.tokenSortLevenshteinSimilarity(normLocalMod, normOnlineMod),
                FuzzyMatcher.jaroWinklerSimilarity(normLocalMod, normOnlineMod)
            )
            if modSim < 0.60 && !normLocalMod.contains(normOnlineMod) && !normOnlineMod.contains(normLocalMod) {
                return nil
            }
        }

        // 2. Live Recording Consistency: strict isolation between studio cuts and live concert recordings
        let isLocalLive = signature.isLive || MetadataSanitizer.isLiveRecording(title: signature.coreTitle, album: signature.standardAlbum)
        let isOnlineLive = MetadataSanitizer.isLiveRecording(title: online.title, album: online.album)
        if isLocalLive != isOnlineLive {
            return nil
        }

        // 3. String Similarities (Token-Sort Levenshtein & Jaro-Winkler)
        let normLocalTitle = normalize(signature.coreTitle)
        let normOnlineTitle = normalize(onlineSignature.coreTitle)

        let titleSim = max(
            FuzzyMatcher.tokenSortLevenshteinSimilarity(normLocalTitle, normOnlineTitle),
            FuzzyMatcher.jaroWinklerSimilarity(normLocalTitle, normOnlineTitle)
        )

        // HARD GUARDRAIL 1: Reject immediately if Title Similarity < 0.85
        if titleSim < 0.85 {
            return nil
        }

        // Artist Similarity
        let isArtistKnown = !MetadataSanitizer.isUnknownArtist(signature.primaryArtist)

        var artistSim: Double = 1.0
        if isArtistKnown {
            let (isCompat, compatScore) = isArtistCompatible(
                localArtist: signature.primaryArtist,
                localTitle: signature.coreTitle,
                cutArtist: onlineSignature.primaryArtist,
                cutTitle: onlineSignature.coreTitle,
                cutAlbumArtist: online.albumArtist,
                albumArtist: online.albumArtist
            )

            if isCompat {
                artistSim = max(0.90, compatScore)
            } else {
                artistSim = compatScore
            }

            // HARD GUARDRAIL 2: Reject immediately if local Artist exists and Artist Similarity < 0.80
            if artistSim < 0.80 && !isCompat {
                return nil
            }
        }

        // Album Similarity & Single Detection
        let isAlbumKnown = !MetadataSanitizer.isUnknownAlbum(signature.standardAlbum) && !signature.standardAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isOnlineSingle = online.isSingle || online.album.lowercased().hasSuffix("single") || normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(online.album)) == normOnlineTitle
        let isLocalSingle = !isAlbumKnown || signature.standardAlbum.lowercased().hasSuffix("single") || normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(signature.standardAlbum)) == normLocalTitle

        var albumSim: Double = 1.0
        if isAlbumKnown && !isLocalSingle {
            let cleanLocalAlbum = DeluxeAlbumDetector.cleanToStandardAlbumName(signature.standardAlbum)
            let cleanOnlineAlbum = DeluxeAlbumDetector.cleanToStandardAlbumName(onlineSignature.standardAlbum)
            let normCleanLocal = normalize(cleanLocalAlbum)
            let normCleanOnline = normalize(cleanOnlineAlbum)

            // Reject if local track belongs to a studio album and candidate is a compilation
            if online.isCompilation || (isOnlineSingle && normCleanLocal != normCleanOnline) {
                return nil
            }

            if normCleanLocal == normCleanOnline {
                albumSim = 1.0
            } else {
                albumSim = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(normCleanLocal, normCleanOnline),
                    FuzzyMatcher.jaroWinklerSimilarity(normCleanLocal, normCleanOnline)
                )
                // Strict studio album rejection if similarity is below 0.75
                if albumSim < 0.75 && !normCleanLocal.contains(normCleanOnline) && !normCleanOnline.contains(normCleanLocal) {
                    return nil
                }
            }
        } else if isLocalSingle {
            if isOnlineSingle {
                albumSim = 1.0
            } else if !online.isCompilation {
                albumSim = 0.90
            } else {
                albumSim = 0.50
            }
        }

        // Duration Similarity & Proximity Penalty
        var durationSim: Double = 1.0
        var durationPenalty: Double = 0.0

        if signature.duration > 0, let onlineDuration = online.duration, onlineDuration > 0 {
            let delta = abs(signature.duration - onlineDuration)
            if delta <= 5.0 {
                durationSim = 1.0
            } else if delta <= 15.0 {
                durationSim = max(0.0, 1.0 - ((delta - 5.0) / 10.0) * 0.5)
            } else {
                // HARD GUARDRAIL 3: Apply -0.30 penalty if duration delta > 15s
                durationSim = 0.0
                if !signature.isLive && signature.versionModifier == nil {
                    durationPenalty = 0.30
                }
            }
        }

        // 4. Dynamic Weight Redistribution
        let wTitle: Double
        let wArtist: Double
        let wAlbum: Double
        let wDuration: Double = 0.10

        if isLocalSingle {
            // Redistribute Album weight (0.15) to Title (+0.08) and Artist (+0.07)
            wTitle = 0.48
            wArtist = 0.42
            wAlbum = 0.00
        } else {
            wTitle = 0.40
            wArtist = 0.35
            wAlbum = 0.15
        }

        // 5. Calculate Weighted Composite Confidence Score (0.0 to 1.0)
        var compositeScore = (wTitle * titleSim) + (wArtist * artistSim) + (wAlbum * albumSim) + (wDuration * durationSim)
        compositeScore -= durationPenalty

        let finalScore = Int(compositeScore * 1000.0)

        // HARD GUARDRAIL 4: Require Final Confidence Score >= 0.85 (850 / 1000)
        guard finalScore >= 850 else {
            return nil
        }

        return finalScore
    }

    /// Finds the best matching candidate from an array of online metadata candidates for a given track signature.
    public static func bestMatch(
        for signature: TrackSignature,
        in candidates: [OnlineTrackMetadata]
    ) -> OnlineTrackMetadata? {
        let ranked = rankCandidates(for: signature, in: candidates)
        return ranked.first
    }

    /// Ranks candidates by match accuracy score and metadata richness (most accurate and enriched first).
    public static func rankCandidates(
        for signature: TrackSignature,
        in candidates: [OnlineTrackMetadata]
    ) -> [OnlineTrackMetadata] {
        return candidates.sorted { a, b in
            let scoreA = evaluateMatch(signature: signature, online: a) ?? -1
            let scoreB = evaluateMatch(signature: signature, online: b) ?? -1

            if scoreA != scoreB {
                return scoreA > scoreB
            }

            // Tie-break with metadata richness score
            let richnessA = metadataRichnessScore(for: a)
            let richnessB = metadataRichnessScore(for: b)
            return richnessA > richnessB
        }
    }

    /// Scores the completeness / richness of an online metadata record.
    public static func metadataRichnessScore(for metadata: OnlineTrackMetadata) -> Int {
        var score = 0
        if !metadata.title.isEmpty { score += 10 }
        if !metadata.artist.isEmpty && !MetadataSanitizer.isUnknownArtist(metadata.artist) { score += 10 }
        if !metadata.album.isEmpty && !MetadataSanitizer.isUnknownAlbum(metadata.album) { score += 10 }
        if metadata.releaseYear != nil && (metadata.releaseYear ?? 0) > 0 { score += 8 }
        if metadata.trackNumber != nil && (metadata.trackNumber ?? 0) > 0 { score += 5 }
        if metadata.totalTracks != nil && (metadata.totalTracks ?? 0) > 0 { score += 3 }
        if metadata.genre != nil && !(metadata.genre?.isEmpty ?? true) { score += 5 }
        if metadata.artworkURL != nil { score += 12 }
        if metadata.duration != nil && (metadata.duration ?? 0) > 0 { score += 5 }
        if metadata.sourceAPI.contains("Apple Music") || metadata.sourceAPI.contains("iTunes") { score += 2 }
        return score
    }

    // MARK: - Multi-Artist Compatibility Check

    /// Checks if a local track has the right artist, or one of the right artists (primary artist, album artist, featured artist, or collaboration token).
    public static func isArtistCompatible(
        localArtist: String,
        localTitle: String = "",
        localAlbumArtist: String? = nil,
        cutArtist: String,
        cutTitle: String = "",
        cutAlbumArtist: String? = nil,
        albumArtist: String? = nil
    ) -> (isCompatible: Bool, similarityScore: Double) {
        let isLocalUnknown = MetadataSanitizer.isUnknownArtist(localArtist) || localArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isLocalUnknown {
            return (true, 0.90) // Unknown artist falls back to title and duration verification
        }

        let localTokens = ArtistParser.allArtists(forTitle: localTitle, artist: localArtist, albumArtist: localAlbumArtist)
            .map { normalize($0) }
            .filter { !$0.isEmpty }

        var onlineTokens = ArtistParser.allArtists(forTitle: cutTitle, artist: cutArtist, albumArtist: cutAlbumArtist)
            .map { normalize($0) }
            .filter { !$0.isEmpty }

        if let albArt = albumArtist, !albArt.isEmpty {
            let parsedAlb = ArtistParser.parseArtists(from: albArt).map { normalize($0) }.filter { !$0.isEmpty }
            onlineTokens.append(contentsOf: parsedAlb)
        }

        let normLocalFull = normalize(localArtist)
        let normCutFull = normalize(cutArtist)

        if normLocalFull == normCutFull {
            return (true, 1.0)
        }

        // Direct token overlap
        for l in localTokens {
            for o in onlineTokens {
                if l == o || l.contains(o) || o.contains(l) {
                    return (true, 1.0)
                }
            }
        }

        // Fuzzy token similarity
        var maxSim: Double = 0.0
        for l in localTokens {
            for o in onlineTokens {
                let sim = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(l, o),
                    FuzzyMatcher.jaroWinklerSimilarity(l, o)
                )
                if sim > maxSim {
                    maxSim = sim
                }
            }
        }

        if maxSim >= 0.85 {
            return (true, maxSim)
        }

        // Full string fuzzy comparison
        let fullSim = max(
            FuzzyMatcher.tokenSortLevenshteinSimilarity(normLocalFull, normCutFull),
            FuzzyMatcher.jaroWinklerSimilarity(normLocalFull, normCutFull)
        )
        if fullSim >= 0.85 {
            return (true, fullSim)
        }

        return (false, max(maxSim, fullSim))
    }

    // MARK: - Album Tracklist Alignment & Mislabeling Resolution

    /// Represents the resolved assignment of a local track to an official online album cut.
    public struct AlbumCutAssignment: Identifiable, Sendable {
        public var id: String { cut.id }
        public let cut: OnlineTrackMetadata
        public let localTrack: Track?
        public let confidenceScore: Int
        public let isMislabeled: Bool
        public let mislabelReason: String?

        public init(
            cut: OnlineTrackMetadata,
            localTrack: Track?,
            confidenceScore: Int = 0,
            isMislabeled: Bool = false,
            mislabelReason: String? = nil
        ) {
            self.cut = cut
            self.localTrack = localTrack
            self.confidenceScore = confidenceScore
            self.isMislabeled = isMislabeled
            self.mislabelReason = mislabelReason
        }
    }

    /// Performs optimal global 1-to-1 bipartite matching between an album's official online tracklist
    /// and candidate local tracks from across the library (including incorrectly labeled files).
    public static func matchAlbumTracklistToCandidates(
        onlineTracks: [OnlineTrackMetadata],
        albumTitle: String,
        albumArtist: String,
        candidateTracks: [Track]
    ) -> (assignments: [AlbumCutAssignment], unassignedLocalTracks: [Track]) {
        guard !onlineTracks.isEmpty else {
            return ([], candidateTracks)
        }

        // Precompute signatures for candidate tracks
        let candidatesWithSignatures = candidateTracks.map { track -> (track: Track, sig: TrackSignature, filenameTitle: String) in
            let sig = MetadataSanitizer.sanitize(track: track)
            let fnTitle = MetadataSanitizer.parseFilename(url: track.url)?.title ?? track.url.deletingPathExtension().lastPathComponent
            return (track, sig, fnTitle)
        }

        struct MatchPair {
            let cutIndex: Int
            let trackIndex: Int
            let score: Int
            let isExactTrackNum: Bool
            let durationDelta: Double
        }

        var candidatePairs: [MatchPair] = []

        for (cutIdx, cut) in onlineTracks.enumerated() {
            let normCutTitle = normalize(cut.title)
            let cutDuration = cut.duration ?? 0
            let cutTrackNum = cut.trackNumber ?? (cutIdx + 1)
            let isCutRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: cut.title, album: cut.album)
            let isCutLive = MetadataSanitizer.isLiveRecording(title: cut.title, album: cut.album)

            for (trackIdx, candidate) in candidatesWithSignatures.enumerated() {
                let track = candidate.track
                let sig = candidate.sig

                // 1. Remix & Live Consistency
                let isTrackRemix = (sig.versionModifier != nil && MetadataSanitizer.isRemixOrAlternateVersion(title: sig.versionModifier!)) || MetadataSanitizer.isRemixOrAlternateVersion(title: sig.coreTitle, album: track.album)
                let isTrackLive = sig.isLive || MetadataSanitizer.isLiveRecording(title: sig.coreTitle, album: track.album)

                if isTrackRemix != isCutRemix || isTrackLive != isCutLive {
                    continue
                }

                // 2. Title Similarity (Check tag title + filename title)
                let normTrackTitle = normalize(sig.coreTitle)
                let normFnTitle = normalize(candidate.filenameTitle)

                let titleSim1 = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(normTrackTitle, normCutTitle),
                    FuzzyMatcher.jaroWinklerSimilarity(normTrackTitle, normCutTitle)
                )
                let titleSim2 = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(normFnTitle, normCutTitle),
                    FuzzyMatcher.jaroWinklerSimilarity(normFnTitle, normCutTitle)
                )
                let titleSim = max(titleSim1, titleSim2)

                let isExactTitle = normTrackTitle == normCutTitle || normFnTitle == normCutTitle
                let isTrackNumMatch = (track.trackNumber != nil && track.trackNumber! > 0 && track.trackNumber! == cutTrackNum)

                if !isExactTitle && titleSim < 0.65 && !isTrackNumMatch {
                    continue
                }
                if !isExactTitle && titleSim < 0.50 {
                    continue
                }

                // 3. Artist Compatibility ("Right artist, or one of the right artists")
                let (isArtistCompat, artistSim) = isArtistCompatible(
                    localArtist: track.artist,
                    localTitle: track.title,
                    localAlbumArtist: track.albumArtist,
                    cutArtist: cut.artist,
                    cutTitle: cut.title,
                    cutAlbumArtist: cut.albumArtist,
                    albumArtist: albumArtist
                )

                // If not artist compatible, allow if exact title matches (last-case scenario for multi-artist / miscategorized tracks)
                if !isArtistCompat && artistSim < 0.70 && !MetadataSanitizer.isUnknownArtist(track.artist) && !isExactTitle {
                    continue
                }

                // 4. Duration Proximity
                var durationSim: Double = 1.0
                var durDelta: Double = 0.0
                if track.duration > 0 && cutDuration > 0 {
                    durDelta = abs(track.duration - cutDuration)
                    if durDelta <= 4.0 {
                        durationSim = 1.0
                    } else if durDelta <= 15.0 {
                        durationSim = max(0.0, 1.0 - ((durDelta - 4.0) / 11.0) * 0.4)
                    } else if durDelta <= 25.0 {
                        durationSim = 0.50
                    } else if !isTrackLive && !isExactTitle {
                        continue // Reject severe duration mismatch for studio tracks unless exact title
                    }
                }

                // 5. Composite Score Calculation
                let wTitle = 0.45
                let wArtist = 0.30
                let wDuration = 0.15
                let wNum = 0.10

                let numScore = isTrackNumMatch ? 1.0 : 0.0
                let effectiveArtistScore = isArtistCompat ? max(0.85, artistSim) : (isExactTitle ? max(0.50, artistSim) : artistSim)
                var rawScore = (wTitle * titleSim) + (wArtist * effectiveArtistScore) + (wDuration * durationSim) + (wNum * numScore)
                
                // Priority tier 1: track already in local target album
                if track.album.localizedCaseInsensitiveCompare(albumTitle) == .orderedSame {
                    rawScore += 0.10
                }

                if isExactTitle {
                    // Guaranteed base score for title match to enable last-case matching
                    rawScore = max(rawScore, 0.65)
                }

                let finalConfidence = Int(min(1.0, rawScore) * 1000.0)
                if finalConfidence >= 600 {
                    candidatePairs.append(
                        MatchPair(
                            cutIndex: cutIdx,
                            trackIndex: trackIdx,
                            score: finalConfidence,
                            isExactTrackNum: isTrackNumMatch,
                            durationDelta: durDelta
                        )
                    )
                }
            }
        }

        // Sort candidate pairs descending by score, tie-breaking by track number match, then lowest duration delta
        candidatePairs.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            if a.isExactTrackNum != b.isExactTrackNum {
                return a.isExactTrackNum && !b.isExactTrackNum
            }
            return a.durationDelta < b.durationDelta
        }

        // Bipartite Greedy Assignment
        var assignedCutIndices = Set<Int>()
        var assignedTrackIndices = Set<Int>()
        var cutToTrackMap: [Int: (trackIndex: Int, score: Int)] = [:]

        for pair in candidatePairs {
            if !assignedCutIndices.contains(pair.cutIndex) && !assignedTrackIndices.contains(pair.trackIndex) {
                assignedCutIndices.insert(pair.cutIndex)
                assignedTrackIndices.insert(pair.trackIndex)
                cutToTrackMap[pair.cutIndex] = (pair.trackIndex, pair.score)
            }
        }

        var assignments: [AlbumCutAssignment] = []
        assignments.reserveCapacity(onlineTracks.count)

        for (cutIdx, cut) in onlineTracks.enumerated() {
            if let mapping = cutToTrackMap[cutIdx] {
                let local = candidateTracks[mapping.trackIndex]
                let normLocalAlbum = normalize(local.album)
                let normTargetAlbum = normalize(albumTitle)
                let isAlbumDifferent = normLocalAlbum != normTargetAlbum
                let normLocalArtist = normalize(local.artist)
                let normCutArtist = normalize(cut.artist)
                let isArtistDifferent = normLocalArtist != normCutArtist && !normLocalArtist.contains(normCutArtist) && !normCutArtist.contains(normLocalArtist)

                let hasValidLocalTrackNum = (local.trackNumber ?? 0) > 0
                let isTrackNumDifferent = hasValidLocalTrackNum && local.trackNumber != (cut.trackNumber ?? (cutIdx + 1))

                let isMislabeled = isAlbumDifferent || isArtistDifferent || isTrackNumDifferent || MetadataSanitizer.isUnknownAlbum(local.album)

                let mislabelReason: String? = {
                    if MetadataSanitizer.isUnknownAlbum(local.album) || local.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "From Unknown Album"
                    } else if isArtistDifferent && isAlbumDifferent {
                        return "Reassign from \(local.artist) - \"\(local.album)\""
                    } else if isAlbumDifferent {
                        return "Reassign from \"\(local.album)\""
                    } else if isArtistDifferent {
                        return "Reassign from artist \"\(local.artist)\""
                    } else if isTrackNumDifferent {
                        return "Correct Track #\(local.trackNumber!) → #\(cut.trackNumber ?? (cutIdx + 1))"
                    }
                    return nil
                }()

                assignments.append(
                    AlbumCutAssignment(
                        cut: cut,
                        localTrack: local,
                        confidenceScore: mapping.score,
                        isMislabeled: isMislabeled,
                        mislabelReason: mislabelReason
                    )
                )
            } else {
                assignments.append(
                    AlbumCutAssignment(
                        cut: cut,
                        localTrack: nil,
                        confidenceScore: 0,
                        isMislabeled: false,
                        mislabelReason: nil
                    )
                )
            }
        }

        let unassigned = candidateTracks.enumerated().filter { !assignedTrackIndices.contains($0.offset) }.map { $0.element }
        return (assignments, unassigned)
    }

    // MARK: - Album Cut Identification

    /// High-precision matching of a local track to an official cut within its verified online album tracklist.
    /// Since the album and artist are already verified, this matches by track number, title similarity, and duration.
    /// Enforces uniqueness per album so multiple local tracks never get assigned to the same online cut.
    public static func findTrackCutInAlbum(
        for track: Track,
        signature: TrackSignature,
        in albumCuts: [OnlineTrackMetadata],
        excludedCutIDs: Set<String> = []
    ) -> OnlineTrackMetadata? {
        let availableCuts = albumCuts.filter { !excludedCutIDs.contains($0.id) }
        guard !availableCuts.isEmpty else { return nil }

        let normLocalTitle = normalize(signature.coreTitle)

        // 1. Direct Track Number Match if local track number is valid (>0)
        if let localNum = track.trackNumber, localNum > 0 {
            if let numMatch = availableCuts.first(where: { $0.trackNumber == localNum }) {
                let normCutTitle = normalize(numMatch.title)
                let titleSim = max(
                    FuzzyMatcher.tokenSortLevenshteinSimilarity(normLocalTitle, normCutTitle),
                    FuzzyMatcher.jaroWinklerSimilarity(normLocalTitle, normCutTitle)
                )

                let durationOk: Bool = {
                    guard track.duration > 0, let cutDur = numMatch.duration, cutDur > 0 else { return true }
                    return abs(track.duration - cutDur) <= 20.0 || signature.isLive
                }()

                let remixMatch: Bool = {
                    let isLocalRemix = (signature.versionModifier != nil && MetadataSanitizer.isRemixOrAlternateVersion(title: signature.versionModifier!)) || MetadataSanitizer.isRemixOrAlternateVersion(title: signature.coreTitle)
                    let isCutRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: numMatch.title)
                    return isLocalRemix == isCutRemix
                }()

                let liveMatch: Bool = {
                    let isLocalLive = signature.isLive || MetadataSanitizer.isLiveRecording(title: signature.coreTitle, album: track.album)
                    let isCutLive = MetadataSanitizer.isLiveRecording(title: numMatch.title, album: numMatch.album)
                    return isLocalLive == isCutLive
                }()

                if (titleSim >= 0.70 || normLocalTitle == normCutTitle) && durationOk && remixMatch && liveMatch {
                    return numMatch
                }
            }
        }

        // 2. High Title Similarity Match across available album cuts
        var bestCut: OnlineTrackMetadata?
        var bestCutSim: Double = 0.0

        for cut in availableCuts {
            let normCutTitle = normalize(cut.title)
            if normLocalTitle == normCutTitle {
                // Exact title match: verify duration, remix & live
                let durationOk: Bool = {
                    guard track.duration > 0, let cutDur = cut.duration, cutDur > 0 else { return true }
                    return abs(track.duration - cutDur) <= 20.0 || signature.isLive
                }()
                let remixMatch: Bool = {
                    let isLocalRemix = (signature.versionModifier != nil && MetadataSanitizer.isRemixOrAlternateVersion(title: signature.versionModifier!)) || MetadataSanitizer.isRemixOrAlternateVersion(title: signature.coreTitle)
                    let isCutRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: cut.title)
                    return isLocalRemix == isCutRemix
                }()
                let liveMatch: Bool = {
                    let isLocalLive = signature.isLive || MetadataSanitizer.isLiveRecording(title: signature.coreTitle, album: track.album)
                    let isCutLive = MetadataSanitizer.isLiveRecording(title: cut.title, album: cut.album)
                    return isLocalLive == isCutLive
                }()
                if durationOk && remixMatch && liveMatch {
                    return cut
                }
            }

            let sim = max(
                FuzzyMatcher.tokenSortLevenshteinSimilarity(normLocalTitle, normCutTitle),
                FuzzyMatcher.jaroWinklerSimilarity(normLocalTitle, normCutTitle)
            )

            if sim > bestCutSim {
                bestCutSim = sim
                bestCut = cut
            }
        }

        if bestCutSim >= 0.75, let cut = bestCut {
            let durationOk: Bool = {
                guard track.duration > 0, let cutDur = cut.duration, cutDur > 0 else { return true }
                return abs(track.duration - cutDur) <= 20.0 || signature.isLive
            }()
            let remixMatch: Bool = {
                let isLocalRemix = (signature.versionModifier != nil && MetadataSanitizer.isRemixOrAlternateVersion(title: signature.versionModifier!)) || MetadataSanitizer.isRemixOrAlternateVersion(title: signature.coreTitle)
                let isCutRemix = MetadataSanitizer.isRemixOrAlternateVersion(title: cut.title)
                return isLocalRemix == isCutRemix
            }()
            let liveMatch: Bool = {
                let isLocalLive = signature.isLive || MetadataSanitizer.isLiveRecording(title: signature.coreTitle, album: track.album)
                let isCutLive = MetadataSanitizer.isLiveRecording(title: cut.title, album: cut.album)
                return isLocalLive == isCutLive
            }()
            if durationOk && remixMatch && liveMatch {
                return cut
            }
        }

        // 3. Filtered bestMatch fallback ONLY if similarity threshold is met
        if let match = bestMatch(for: signature, in: availableCuts) {
            let normMatchTitle = normalize(match.title)
            let sim = max(
                FuzzyMatcher.tokenSortLevenshteinSimilarity(normLocalTitle, normMatchTitle),
                FuzzyMatcher.jaroWinklerSimilarity(normLocalTitle, normMatchTitle)
            )
            if sim >= 0.75 {
                return match
            }
        }

        return nil
    }

    // MARK: - Helpers

    public static func normalize(_ str: String) -> String {
        str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

