import Foundation

/// Unified abstraction for an online metadata source capable of resolving artist catalogs and tracks.
public protocol MetadataProvider: Sendable {
    var source: MetadataAPIOption { get }

    /// Finds candidate artist by name and returns canonical artist details.
    func searchArtist(name: String) async throws -> OnlineArtistCandidate?

    /// Fetches the complete release catalog (albums, singles, EPs) for an artist ID.
    func fetchDiscography(artistId: String, artistName: String) async throws -> [OnlineReleaseCandidate]

    /// Fetches all tracks for a specific release ID.
    func fetchReleaseTracks(releaseId: String) async throws -> [OnlineTrackCandidate]
}
