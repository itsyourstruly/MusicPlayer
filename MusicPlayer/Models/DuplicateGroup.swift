import Foundation

// MARK: - DuplicateCandidate

/// Represents an individual audio track candidate within a duplicate group,
/// evaluated for metadata completeness and technical audio quality.
public struct DuplicateCandidate: Identifiable, Codable, Sendable, Hashable {
    // Unique track identifier
    public var id: UUID { track.id }
    // Track
    public let track: Track
    /// Composite score across bitrate, sample rate, metadata completeness, and artwork presence.
    public let qualityScore: Int
    /// Per-dimension breakdown for display in the duplicate resolution UI.
    public let scoreBreakdown: [String: Int]
    /// True for the highest-scoring candidate — the one the engine suggests keeping.
    public let isRecommended: Bool

    // Initialize with configured properties
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

    /// Formatted summary badge of audio codec and bitrate (e.g. `FLAC 1411kbps` or `AAC 256kbps`).
    public var formatBadge: String {
        // Ext
        let ext = track.fileInfo?.fileExtension ?? track.url.pathExtension.uppercased()
        if let kbps = track.fileInfo?.bitRate, kbps > 0 {
            // K
            let k = Int(round(kbps / 1000.0))
            return "\(ext) \(k)kbps"
        }
        return ext
    }

    /// Audio sample rate formatted string (e.g. `96.0 kHz` or `44.1 kHz`).
    public var sampleRateString: String {
        // Ensure preconditions are met before proceeding
        guard let sr = track.fileInfo?.sampleRate, sr > 0 else { return "44.1 kHz" }
        if sr >= 1000 {
            return String(format: "%.1f kHz", sr / 1000.0)
        }
        // Unlikely sub-1 kHz value — show raw Hz to avoid confusing the user.
        return "\(Int(sr)) Hz"
    }

    /// Indicates whether embedded artwork is available.
    public var hasArtwork: Bool {
        track.artworkKey?.isEmpty == false
    }
}

// MARK: - DuplicateGroup

/// A cluster of audio tracks identified as duplicates of the same musical piece.
public struct DuplicateGroup: Identifiable, Codable, Sendable, Hashable {
    /// Stable ID derived from the normalised title + artist key used during duplicate detection.
    public let id: String
    // Normalized title
    public let normalizedTitle: String
    // Normalized artist
    public let normalizedArtist: String
    public var candidates: [DuplicateCandidate]
    /// The track the user (or engine) has designated as the one to keep.
    public var selectedPrimaryTrackID: UUID

    // Initialize with configured properties
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

    // MARK: - Computed Properties

    /// Currently selected primary track.
    public var primaryCandidate: DuplicateCandidate? {
        // Falls back to first candidate in case the selectedID is stale after a library rescan.
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
