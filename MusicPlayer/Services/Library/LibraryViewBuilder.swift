import Foundation

/// Inputs for one Library view computation (captured on the main actor, consumed off it).
nonisolated struct LibraryViewInput: Sendable {
    let tracks: [Track]
    let albums: [Album]
    let artists: [Artist]
    /// Every configured source (local folders first, then servers in settings order).
    let sourceOrder: [UUID]
    let disabledSourceIDs: Set<UUID>
    /// Local folder paths, used only for legacy local tracks stored without a folder ID.
    let localFolderPaths: [(id: UUID, path: String)]
    /// Server tracks downloaded for offline playback (rank like local copies).
    let downloadedTrackIDs: Set<UUID>
    let joinedArtists: [String]
    /// Offline: only tracks on this device (local tracks and downloaded server tracks) are shown.
    var offlineOnly: Bool = false
}

/// What the Library tabs and Library search show for the current source selection:
/// only enabled sources, and — when two or more sources are enabled — only the best copy of
/// each duplicate track. The persisted library (pins, recents, playlists, playback) is never filtered.
nonisolated struct LibraryViewSnapshot: Sendable {
    let tracks: [Track]
    let albums: [Album]
    let artists: [Artist]
    let albumsByID: [String: Album]
    let artistsByID: [String: Artist]
    /// Nil when every track is visible (nothing disabled, nothing hidden).
    let visibleTrackIDs: Set<UUID>?
    /// Duplicate copies hidden because a better copy from another enabled source is shown.
    let hiddenDuplicateIDs: Set<UUID>

    func isVisible(_ id: UUID) -> Bool {
        visibleTrackIDs?.contains(id) ?? true
    }
}

nonisolated enum LibraryViewBuilder {

    static func build(_ input: LibraryViewInput) -> LibraryViewSnapshot {
        let order = Dictionary(input.sourceOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let singleLocalFolder: UUID? = input.localFolderPaths.count == 1 && input.sourceOrder.count == 1 ? input.localFolderPaths.first?.id : nil

        func source(of track: Track) -> UUID? {
            if let id = track.folderID { return id }
            if let single = singleLocalFolder { return single }
            let path = track.url.path
            return input.localFolderPaths.first(where: { !$0.path.isEmpty && path.hasPrefix($0.path) })?.id
        }
        func isEnabled(_ track: Track) -> Bool {
            if input.offlineOnly, !OfflineMode.isOnDevice(track, downloadedTrackIDs: input.downloadedTrackIDs) {
                return false
            }
            guard !input.disabledSourceIDs.isEmpty, let src = source(of: track) else { return true }
            return !input.disabledSourceIDs.contains(src)
        }

        // Duplicates are only hidden among two or more enabled sources.
        let enabledSourceCount = input.sourceOrder.filter { !input.disabledSourceIDs.contains($0) }.count
        var hidden = Set<UUID>()
        if enabledSourceCount >= 2 {
            for album in input.albums {
                hideDuplicates(in: album, source: source(of:), isEnabled: isEnabled, order: order,
                               downloaded: input.downloadedTrackIDs, hidden: &hidden)
            }
        }

        if input.disabledSourceIDs.isEmpty && hidden.isEmpty && !input.offlineOnly {
            var artistsByID: [String: Artist] = [:]
            artistsByID.reserveCapacity(input.artists.count)
            for artist in input.artists { artistsByID[artist.id] = artist }
            var albumsByID: [String: Album] = [:]
            albumsByID.reserveCapacity(input.albums.count)
            for album in input.albums { albumsByID[album.id] = album }
            return LibraryViewSnapshot(tracks: input.tracks, albums: input.albums, artists: input.artists,
                                       albumsByID: albumsByID, artistsByID: artistsByID,
                                       visibleTrackIDs: nil, hiddenDuplicateIDs: [])
        }

        var visibleIDs = Set<UUID>()
        visibleIDs.reserveCapacity(input.tracks.count)
        var tracks: [Track] = []
        tracks.reserveCapacity(input.tracks.count)
        for track in input.tracks where !hidden.contains(track.id) && isEnabled(track) {
            visibleIDs.insert(track.id)
            tracks.append(track)
        }

        // Albums: unchanged instances when fully visible; trimmed copies keep identity (groupKey) and attribution.
        var albums: [Album] = []
        albums.reserveCapacity(input.albums.count)
        var albumsByID: [String: Album] = [:]
        albumsByID.reserveCapacity(input.albums.count)
        for album in input.albums {
            let kept = album.tracks.filter { visibleIDs.contains($0.id) }
            guard !kept.isEmpty else { continue }
            let viewAlbum = kept.count == album.tracks.count ? album : album.withTracks(kept)
            albums.append(viewAlbum)
            albumsByID[viewAlbum.id] = viewAlbum
        }

        var artists: [Artist] = []
        artists.reserveCapacity(input.artists.count)
        var artistsByID: [String: Artist] = [:]
        artistsByID.reserveCapacity(input.artists.count)
        for artist in input.artists {
            let keptTracks = artist.tracks.filter { visibleIDs.contains($0.id) }
            guard !keptTracks.isEmpty else { continue }
            var albumsChanged = false
            let keptAlbums: [Album] = artist.albums.compactMap { album in
                guard let viewAlbum = albumsByID[album.id] else { albumsChanged = true; return nil }
                if viewAlbum.tracks.count != album.tracks.count { albumsChanged = true }
                return viewAlbum
            }
            let viewArtist = (!albumsChanged && keptTracks.count == artist.tracks.count)
                ? artist
                : artist.withContent(albums: keptAlbums, tracks: keptTracks, joinedArtists: input.joinedArtists)
            artists.append(viewArtist)
            artistsByID[viewArtist.id] = viewArtist
        }

        return LibraryViewSnapshot(tracks: tracks, albums: albums, artists: artists,
                                   albumsByID: albumsByID, artistsByID: artistsByID,
                                   visibleTrackIDs: visibleIDs, hiddenDuplicateIDs: hidden)
    }

    // MARK: - Duplicates

    /// Within one (merged) album: same disc + track number + title (case/diacritics/whitespace folded),
    /// durations within 2 s. Only groups spanning two or more enabled sources count; the best copy stays visible.
    private static func hideDuplicates(
        in album: Album,
        source: (Track) -> UUID?,
        isEnabled: (Track) -> Bool,
        order: [UUID: Int],
        downloaded: Set<UUID>,
        hidden: inout Set<UUID>
    ) {
        guard album.tracks.count >= 2 else { return }
        var firstSource: UUID??
        var multiSource = false
        for track in album.tracks where isEnabled(track) {
            let src = source(track)
            if let seen = firstSource {
                if seen != src { multiSource = true; break }
            } else {
                firstSource = .some(src)
            }
        }
        guard multiSource else { return }

        var buckets: [String: [Track]] = [:]
        for track in album.tracks where isEnabled(track) {
            let key = "\(track.discNumber ?? 1)|\(track.trackNumber ?? 0)|\(ServerCredits.nameKey(track.title))"
            buckets[key, default: []].append(track)
        }
        for (_, candidates) in buckets where candidates.count >= 2 {
            let sorted = candidates.sorted { $0.duration < $1.duration }
            var cluster: [Track] = [sorted[0]]
            for track in sorted.dropFirst() {
                if track.duration - cluster[cluster.count - 1].duration <= 2 {
                    cluster.append(track)
                } else {
                    resolve(cluster, source: source, order: order, downloaded: downloaded, hidden: &hidden)
                    cluster = [track]
                }
            }
            resolve(cluster, source: source, order: order, downloaded: downloaded, hidden: &hidden)
        }
    }

    private static func resolve(
        _ cluster: [Track],
        source: (Track) -> UUID?,
        order: [UUID: Int],
        downloaded: Set<UUID>,
        hidden: inout Set<UUID>
    ) {
        guard cluster.count >= 2 else { return }
        let sources = Set(cluster.map { source($0) })
        guard sources.count >= 2 else { return }
        let winner = cluster.max { lhs, rhs in
            qualityRank(lhs, source: source, order: order, downloaded: downloaded)
                < qualityRank(rhs, source: source, order: order, downloaded: downloaded)
        }!
        let winnerSource = source(winner)
        // Copies from the winner's own source stay (a source's own duplicates are not this feature's concern).
        for track in cluster where source(track) != winnerSource {
            hidden.insert(track.id)
        }
    }

    /// Lossless first, then bit depth, sample rate, bitrate; ties prefer local/downloaded copies, then source order.
    private static func qualityRank(_ track: Track, source: (Track) -> UUID?, order: [UUID: Int], downloaded: Set<UUID>) -> QualityRank {
        let info = track.fileInfo
        return QualityRank(
            lossless: isLossless(info) ? 1 : 0,
            bitDepth: track.serverCredits?.bitDepth ?? 0,
            sampleRate: info?.sampleRate ?? 0,
            bitRate: info?.bitRate ?? 0,
            offline: (!track.isJellyfinItem || downloaded.contains(track.id)) ? 1 : 0,
            sourcePreference: -(source(track).flatMap { order[$0] } ?? Int.max / 2)
        )
    }

    private struct QualityRank: Comparable {
        let lossless: Int
        let bitDepth: Int
        let sampleRate: Double
        let bitRate: Double
        let offline: Int
        let sourcePreference: Int

        static func < (lhs: QualityRank, rhs: QualityRank) -> Bool {
            if lhs.lossless != rhs.lossless { return lhs.lossless < rhs.lossless }
            if lhs.bitDepth != rhs.bitDepth { return lhs.bitDepth < rhs.bitDepth }
            if lhs.sampleRate != rhs.sampleRate { return lhs.sampleRate < rhs.sampleRate }
            if lhs.bitRate != rhs.bitRate { return lhs.bitRate < rhs.bitRate }
            if lhs.offline != rhs.offline { return lhs.offline < rhs.offline }
            return lhs.sourcePreference < rhs.sourcePreference
        }
    }

    private static let losslessExtensions: Set<String> = ["FLAC", "ALAC", "WAV", "AIFF", "AIF", "APE", "WV", "DSF", "DFF"]

    private static func isLossless(_ info: AudioFileInfo?) -> Bool {
        guard let info else { return false }
        if losslessExtensions.contains(info.fileExtension.uppercased()) { return true }
        let format = info.formatDescription.uppercased()
        return format.contains("ALAC") || format.contains("FLAC") || format.contains("PCM") || format.contains("LOSSLESS")
    }
}
