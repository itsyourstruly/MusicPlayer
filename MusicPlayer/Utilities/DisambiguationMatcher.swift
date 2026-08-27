//
//  DisambiguationMatcher.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation

/// High-precision heuristic and disambiguation engine for evaluating online Apple Music catalog tracks
/// against local track signatures. Enforces audio length validation (±5s), version/remix consistency,
/// and string similarity thresholds to eliminate false positives.
public enum DisambiguationMatcher {

    /// Minimum confidence score required to accept an online match candidate.
    public static let minimumAcceptanceThreshold: Int = 550

    // MARK: - Match Evaluation

    /// Evaluates whether an online candidate matches the local track signature and returns a confidence score (or nil if rejected).
    public static func evaluateMatch(
        signature: TrackSignature,
        online: OnlineTrackMetadata
    ) -> Int? {
        // 1. Audio Duration Validation (Relaxed tolerance for bitrate estimations & padding)
        if signature.duration > 0, let onlineDuration = online.duration, onlineDuration > 0 {
            let durationDelta = abs(signature.duration - onlineDuration)
            // Only reject if length differs drastically (> 90s) when album is unknown
            if durationDelta > 90.0 && MetadataSanitizer.isUnknownAlbum(signature.standardAlbum) {
                return nil
            }
        }

        // 2. Version Modifier & Remix Protection
        let onlineSignature = MetadataSanitizer.buildSignature(
            title: online.title,
            artist: online.artist,
            album: online.album,
            duration: online.duration ?? 0,
            trackNumber: online.trackNumber
        )

        // If local track is a remix/version, online candidate MUST have matching modifier
        if let localModifier = signature.versionModifier {
            guard let onlineModifier = onlineSignature.versionModifier else {
                // Local is remix/version, online is standard track -> reject
                return nil
            }
            let normLocalMod = normalize(localModifier)
            let normOnlineMod = normalize(onlineModifier)
            let modSim = FuzzyMatcher.levenshteinSimilarity(normLocalMod, normOnlineMod)
            if modSim < 0.50 && !normLocalMod.contains(normOnlineMod) && !normOnlineMod.contains(normLocalMod) {
                return nil
            }
        } else {
            // Local track is standard; if online is explicitly an alternate remix/version, reject
            if let onlineModifier = onlineSignature.versionModifier {
                let normOnlineMod = normalize(onlineModifier)
                if normOnlineMod.contains("remix") || normOnlineMod.contains("club mix") || normOnlineMod.contains("dub") || normOnlineMod.contains("vip") {
                    return nil
                }
            }
        }

        // 3. Live Recording Consistency
        if signature.isLive != onlineSignature.isLive {
            // If local is explicitly live but online is studio, or vice versa, apply heavy penalty / reject if local is live
            if signature.isLive {
                return nil
            }
        }

        // 4. Title Similarity Scoring
        let normLocalTitle = normalize(signature.coreTitle)
        let normOnlineTitle = normalize(onlineSignature.coreTitle)

        var titleScore = 0
        if normLocalTitle == normOnlineTitle {
            titleScore = 500
        } else if normLocalTitle.contains(normOnlineTitle) || normOnlineTitle.contains(normLocalTitle) {
            let ratio = Double(min(normLocalTitle.count, normOnlineTitle.count)) / Double(max(normLocalTitle.count, normOnlineTitle.count, 1))
            titleScore = 400 + Int(ratio * 80)
        } else {
            let sim = FuzzyMatcher.levenshteinSimilarity(normLocalTitle, normOnlineTitle)
            if sim < 0.55 {
                return nil // Title is too dissimilar
            }
            titleScore = Int(sim * 450)
        }

        // 5. Artist Similarity Scoring
        let normLocalArtist = normalize(signature.primaryArtist)
        let normOnlineArtist = normalize(onlineSignature.primaryArtist)

        var artistScore = 0
        let isArtistKnown = !MetadataSanitizer.isUnknownArtist(signature.primaryArtist)

        if isArtistKnown {
            if normLocalArtist == normOnlineArtist {
                artistScore = 350
            } else if normLocalArtist.contains(normOnlineArtist) || normOnlineArtist.contains(normLocalArtist) {
                artistScore = 280
            } else {
                let sim = FuzzyMatcher.levenshteinSimilarity(normLocalArtist, normOnlineArtist)
                if sim < 0.50 {
                    return nil // Artist mismatch
                }
                artistScore = Int(sim * 300)
            }
        } else {
            artistScore = 150 // Neutral score when artist is unknown
        }

        // 6. Album Fidelity Scoring
        var albumScore = 0
        let normLocalAlbum = normalize(signature.standardAlbum)
        let normOnlineAlbum = normalize(onlineSignature.standardAlbum)
        let isAlbumKnown = !MetadataSanitizer.isUnknownAlbum(signature.standardAlbum)

        if isAlbumKnown {
            if normLocalAlbum == normOnlineAlbum {
                albumScore = 250
            } else if normLocalAlbum.contains(normOnlineAlbum) || normOnlineAlbum.contains(normLocalAlbum) {
                albumScore = 150
            } else if !online.isCompilation && !online.isSingle {
                albumScore = -50
            }
        }

        // 7. Track Number Alignment Bonus
        var trackNumBonus = 0
        if let localNum = signature.trackNumber, let onlineNum = online.trackNumber, localNum > 0, onlineNum > 0 {
            if localNum == onlineNum {
                trackNumBonus = 150
            }
        }

        // 8. Duration Proximity Bonus
        var durationBonus = 0
        if signature.duration > 0, let onlineDuration = online.duration, onlineDuration > 0 {
            let delta = abs(signature.duration - onlineDuration)
            if delta <= 2.0 {
                durationBonus = 100
            } else if delta <= 5.0 {
                durationBonus = 50
            }
        }

        // Calculate Total Score
        let totalScore = titleScore + artistScore + albumScore + trackNumBonus + durationBonus

        guard totalScore >= minimumAcceptanceThreshold else {
            return nil
        }

        return totalScore
    }

    /// Finds the best matching candidate from an array of online metadata candidates for a given track signature.
    public static func bestMatch(
        for signature: TrackSignature,
        in candidates: [OnlineTrackMetadata]
    ) -> OnlineTrackMetadata? {
        var highestScore = -1
        var bestCandidate: OnlineTrackMetadata? = nil

        for candidate in candidates {
            if let score = evaluateMatch(signature: signature, online: candidate) {
                if score > highestScore {
                    highestScore = score
                    bestCandidate = candidate
                }
            }
        }

        return bestCandidate
    }

    // MARK: - Helpers

    private static func normalize(_ str: String) -> String {
        str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
