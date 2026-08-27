//
//  DuplicateDetectionService.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation
import os

/// High-performance actor responsible for detecting duplicate audio tracks,
/// clustering them into groups, and calculating technical fidelity & metadata completeness scores.
public actor DuplicateDetectionService {
    public static let shared = DuplicateDetectionService()

    private init() {}

    /// Analyzes a collection of tracks and returns detected duplicate clusters.
    public func analyzeDuplicates(in tracks: [Track]) -> [DuplicateGroup] {
        guard tracks.count > 1 else { return [] }

        var clusters: [[Track]] = []
        var processedTrackIDs = Set<UUID>()

        for i in 0..<tracks.count {
            let trackA = tracks[i]
            if processedTrackIDs.contains(trackA.id) { continue }

            var currentCluster = [trackA]

            for j in (i + 1)..<tracks.count {
                let trackB = tracks[j]
                if processedTrackIDs.contains(trackB.id) { continue }

                if isDuplicate(trackA, trackB) {
                    currentCluster.append(trackB)
                    processedTrackIDs.insert(trackB.id)
                }
            }

            if currentCluster.count > 1 {
                processedTrackIDs.insert(trackA.id)
                clusters.append(currentCluster)
            }
        }

        // Convert clusters into DuplicateGroups with scoring
        var duplicateGroups: [DuplicateGroup] = []
        duplicateGroups.reserveCapacity(clusters.count)

        for cluster in clusters {
            let candidates: [DuplicateCandidate] = cluster.map { track in
                let (score, breakdown) = calculateQualityScore(for: track)
                return DuplicateCandidate(track: track, qualityScore: score, scoreBreakdown: breakdown, isRecommended: false)
            }

            // Find highest score candidate
            let maxScore = candidates.map { $0.qualityScore }.max() ?? 0
            let evaluatedCandidates = candidates.map { cand in
                DuplicateCandidate(
                    track: cand.track,
                    qualityScore: cand.qualityScore,
                    scoreBreakdown: cand.scoreBreakdown,
                    isRecommended: cand.qualityScore == maxScore
                )
            }

            let first = cluster[0]
            let normTitle = normalizeTitle(first.title)
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

    /// Evaluates whether two tracks are duplicates using normalized tags and duration similarity.
    public func isDuplicate(_ a: Track, _ b: Track) -> Bool {
        // Fast exact file path check
        if a.url == b.url { return true }

        let normTitleA = normalizeTitle(a.title)
        let normTitleB = normalizeTitle(b.title)

        // Exact normalized title match
        let titlesMatch = (normTitleA == normTitleB) ||
            FuzzyMatcher.evaluateScore(cleanText: normTitleA, cleanQuery: normTitleB) >= 800

        guard titlesMatch else { return false }

        let normArtistA = normalizeArtist(a.artist)
        let normArtistB = normalizeArtist(b.artist)

        let artistsMatch = (normArtistA == normArtistB) ||
            normArtistA.contains(normArtistB) || normArtistB.contains(normArtistA) ||
            normArtistA == "unknown artist" || normArtistB == "unknown artist"

        let durationDiff = abs(a.duration - b.duration)

        // Strict duration match (within 3.0 seconds) if artist matches, or within 1.0s if artist is uncertain
        if artistsMatch && durationDiff <= 3.5 {
            return true
        }

        if normTitleA == normTitleB && durationDiff <= 1.2 {
            return true
        }

        return false
    }

    /// Computes a comprehensive quality and accuracy score for a track.
    public func calculateQualityScore(for track: Track) -> (score: Int, breakdown: [String: Int]) {
        var score = 0
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
        if let year = track.year, year > 1900 {
            score += 10
            breakdown["Year"] = 10
        }
        if let genre = track.genre, !genre.isEmpty {
            score += 5
            breakdown["Genre"] = 5
        }
        if let trackNum = track.trackNumber, trackNum > 0 {
            score += 5
            breakdown["Track #"] = 5
        }
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

            let bitrateBonus = min(15, Int(info.bitRate / 64000.0))
            specScore += bitrateBonus

            score += specScore
            breakdown["Audio Specs"] = specScore
        }

        return (score, breakdown)
    }

    // MARK: - String Normalization Helpers

    private static let noiseRegex: NSRegularExpression? = {
        let pattern = #"(?:\s*[\(\[\{](?:remastered|remaster|explicit|clean|official\s+audio|official\s+video|official|audio|video|lyrics|bonus\s+track|deluxe(?:\s+edition)?|instrumental|320kbps|flac|hq|hd)[\)\]\}]|\s*-\s*(?:remastered|official|audio|video).*$)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let trackNumberPrefixRegex: NSRegularExpression? = {
        let pattern = #"^\s*\d+[\s\-\.\_]+"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Strips noise, remaster tags, and track number prefixes from track titles.
    public func normalizeTitle(_ rawTitle: String) -> String {
        var str = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove track number prefixes like "01 - ", "1. ", "02_"
        if let reg = Self.trackNumberPrefixRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Remove noise tags like (Remastered 2021)
        if let reg = Self.noiseRegex {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = reg.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
        }

        // Remove non-alphanumeric noise
        let cleaned = str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        return cleaned.isEmpty ? rawTitle.lowercased() : cleaned
    }

    /// Normalizes artist strings for comparison.
    public func normalizeArtist(_ rawArtist: String) -> String {
        let cleaned = rawArtist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        return cleaned.isEmpty ? "unknown artist" : cleaned
    }
}
