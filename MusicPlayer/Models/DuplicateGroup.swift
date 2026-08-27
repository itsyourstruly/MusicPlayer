//
//  DuplicateGroup.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation

/// Represents an individual audio track candidate within a duplicate group,
/// evaluated for metadata completeness and technical audio quality.
public struct DuplicateCandidate: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID { track.id }
    public let track: Track
    public let qualityScore: Int
    public let scoreBreakdown: [String: Int]
    public let isRecommended: Bool

    public init(
        track: Track,
        qualityScore: Int,
        scoreBreakdown: [String: Int] = [:],
        isRecommended: Bool = false
    ) {
        self.track = track
        self.qualityScore = qualityScore
        self.scoreBreakdown = scoreBreakdown
        self.isRecommended = isRecommended
    }

    /// Formatted summary badge of audio codec and bitrate (e.g. `FLAC 1411k` or `AAC 256k`).
    public var formatBadge: String {
        let ext = track.fileInfo?.fileExtension ?? track.url.pathExtension.uppercased()
        if let kbps = track.fileInfo?.bitRate, kbps > 0 {
            let k = Int(round(kbps / 1000.0))
            return "\(ext) \(k)kbps"
        }
        return ext
    }

    /// Audio sample rate formatted string (e.g. `96.0 kHz` or `44.1 kHz`).
    public var sampleRateString: String {
        guard let sr = track.fileInfo?.sampleRate, sr > 0 else { return "44.1 kHz" }
        if sr >= 1000 {
            return String(format: "%.1f kHz", sr / 1000.0)
        }
        return "\(Int(sr)) Hz"
    }

    /// Indicates whether embedded artwork is available.
    public var hasArtwork: Bool {
        track.artworkKey != nil && !track.artworkKey!.isEmpty
    }
}

/// A cluster of audio tracks identified as duplicates of the same musical piece.
public struct DuplicateGroup: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let normalizedTitle: String
    public let normalizedArtist: String
    public var candidates: [DuplicateCandidate]
    public var selectedPrimaryTrackID: UUID

    public init(
        id: String,
        normalizedTitle: String,
        normalizedArtist: String,
        candidates: [DuplicateCandidate],
        selectedPrimaryTrackID: UUID? = nil
    ) {
        self.id = id
        self.normalizedTitle = normalizedTitle
        self.normalizedArtist = normalizedArtist
        self.candidates = candidates
        // Default to the recommended (highest scoring) candidate or the first candidate
        if let explicitID = selectedPrimaryTrackID {
            self.selectedPrimaryTrackID = explicitID
        } else if let rec = candidates.first(where: { $0.isRecommended }) {
            self.selectedPrimaryTrackID = rec.track.id
        } else {
            self.selectedPrimaryTrackID = candidates.first?.track.id ?? UUID()
        }
    }

    /// Currently selected primary track.
    public var primaryCandidate: DuplicateCandidate? {
        candidates.first(where: { $0.track.id == selectedPrimaryTrackID }) ?? candidates.first
    }

    /// All alternative duplicate candidates excluding the primary track.
    public var duplicateCandidates: [DuplicateCandidate] {
        candidates.filter { $0.track.id != selectedPrimaryTrackID }
    }

    /// Total wasted disk space in bytes consumed by the secondary duplicates in this group.
    public var potentialSavedBytes: Int64 {
        duplicateCandidates.reduce(0) { $0 + ($1.track.fileInfo?.fileSizeBytes ?? 0) }
    }

    /// Display title for the duplicate group.
    public var displayTitle: String {
        candidates.first?.track.title ?? normalizedTitle
    }

    /// Display artist for the duplicate group.
    public var displayArtist: String {
        candidates.first?.track.artist ?? normalizedArtist
    }
}
