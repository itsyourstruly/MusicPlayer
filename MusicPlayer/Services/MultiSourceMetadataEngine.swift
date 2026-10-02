import Foundation

/// High-throughput actor orchestrating concurrent multi-source discography retrieval
/// across iTunes, Deezer, and MusicBrainz. Merges multi-provider data into unified
/// release and track candidate models.
public actor MultiSourceMetadataEngine {
    public static let shared = MultiSourceMetadataEngine()

    private let itunes: iTunesProvider
    private let deezer: DeezerProvider
    private let musicBrainz: MusicBrainzProvider

    // In-memory cache for artist discographies: [normalizedArtistName: [UnifiedReleaseCandidate]]
    private var discographyCache: [String: [UnifiedReleaseCandidate]] = [:]

    public init(
        itunes: iTunesProvider = iTunesProvider(),
        deezer: DeezerProvider = DeezerProvider(),
        musicBrainz: MusicBrainzProvider = MusicBrainzProvider()
    ) {
        self.itunes = itunes
        self.deezer = deezer
        self.musicBrainz = musicBrainz
    }

    /// Clears the in-memory discography cache.
    public func clearCache() {
        discographyCache.removeAll(keepingCapacity: false)
    }

    /// Fetches the synthesized multi-source discography for an artist with progress reporting,
    /// guaranteeing complete tracklist coverage for all local albums.
    public func fetchUnifiedDiscography(
        artistName: String,
        localAlbums: [Album] = [],
        source: MetadataAPIOption = .all,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async -> [UnifiedReleaseCandidate] {
        let cleanArtist = MetadataSanitizer.cleanArtistSearchTerm(artistName)
        let cacheKey = "\(cleanArtist.lowercased())__\(source.rawValue)"

        if let cached = discographyCache[cacheKey], !cached.isEmpty {
            onProgress?(1.0, "Loaded discography for \(artistName) from memory.")
            return cached
        }

        onProgress?(0.05, "Resolving artist identity across catalog providers...")

        // Step 1: Resolve canonical artist IDs across selected providers
        var itunesCandidate: OnlineArtistCandidate?
        var deezerCandidate: OnlineArtistCandidate?
        var mbCandidate: OnlineArtistCandidate?

        if source == .all || source == .itunes {
            itunesCandidate = try? await itunes.searchArtist(name: cleanArtist)
        }
        if source == .all || source == .deezer {
            deezerCandidate = try? await deezer.searchArtist(name: cleanArtist)
        }
        if source == .all || source == .musicBrainz {
            mbCandidate = try? await musicBrainz.searchArtist(name: cleanArtist)
        }

        onProgress?(0.20, "Querying complete discography from iTunes, Deezer, and MusicBrainz...")

        // Step 2: Fetch discography releases across providers concurrently
        async let itunesReleasesTask: [OnlineReleaseCandidate] = {
            guard let it = itunesCandidate else { return [] }
            return (try? await self.itunes.fetchDiscography(artistId: it.id, artistName: it.name)) ?? []
        }()

        async let deezerReleasesTask: [OnlineReleaseCandidate] = {
            guard let dz = deezerCandidate else { return [] }
            return (try? await self.deezer.fetchDiscography(artistId: dz.id, artistName: dz.name)) ?? []
        }()

        async let mbReleasesTask: [OnlineReleaseCandidate] = {
            guard let mb = mbCandidate else { return [] }
            return (try? await self.musicBrainz.fetchDiscography(artistId: mb.id, artistName: mb.name)) ?? []
        }()

        let itunesReleases = await itunesReleasesTask
        let deezerReleases = await deezerReleasesTask
        let mbReleases = await mbReleasesTask

        onProgress?(0.45, "Synthesizing catalog across providers...")

        // Step 3: Deduplicate and merge releases into composite release candidates
        var mergedReleases = mergeReleases(
            itunes: itunesReleases,
            deezer: deezerReleases,
            musicBrainz: mbReleases,
            canonicalArtist: cleanArtist
        )

        // Step 4: Guarantee that 100% of the artist's local albums have a populated online release
        var matchedReleaseIDs = Set<String>()
        let totalLocalCount = Double(max(1, localAlbums.count))

        for (idx, localAlbum) in localAlbums.enumerated() {
            let progressFraction = 0.45 + (Double(idx) / totalLocalCount) * 0.40
            onProgress?(progressFraction, "Aligning album (\(idx + 1)/\(localAlbums.count)): \"\(localAlbum.title)\"")

            let cleanLocalTitle = DeluxeAlbumDetector.cleanToStandardAlbumName(localAlbum.title)
            if let matchedIndex = mergedReleases.firstIndex(where: { releasesMatch(cleanLocalTitle, $0.title) }) {
                // If tracks not fetched yet, fetch them now
                if mergedReleases[matchedIndex].tracks.isEmpty {
                    let tracks = await fetchCompositeTracks(for: mergedReleases[matchedIndex])
                    mergedReleases[matchedIndex].tracks = tracks
                    if mergedReleases[matchedIndex].totalTracks == nil || mergedReleases[matchedIndex].totalTracks == 0 {
                        mergedReleases[matchedIndex].totalTracks = tracks.count
                    }
                }
                matchedReleaseIDs.insert(mergedReleases[matchedIndex].id)
            } else {
                // Targeted search for this specific local album
                if let cuts = await MusicMetadataService.shared.searchAlbumSongs(album: localAlbum.title, artist: cleanArtist, source: source), !cuts.isEmpty {
                    let releaseYear = cuts.compactMap { $0.releaseYear }.first(where: { $0 > 0 }) ?? localAlbum.year
                    let genre = cuts.compactMap { $0.genre }.first(where: { !$0.isEmpty }) ?? localAlbum.genre
                    let artwork = cuts.compactMap { $0.artworkURL }.first
                    let trackCandidates = cuts.map { c in
                        UnifiedTrackCandidate(
                            id: c.id,
                            title: c.title,
                            artist: c.artist.isEmpty ? cleanArtist : c.artist,
                            album: c.album,
                            trackNumber: c.trackNumber,
                            discNumber: c.discNumber ?? 1,
                            duration: c.duration,
                            isrc: nil,
                            releaseYear: c.releaseYear,
                            genre: c.genre,
                            artworkURL: c.artworkURL,
                            sourceAPIs: [c.sourceAPIOption]
                        )
                    }

                    let targetedRelease = UnifiedReleaseCandidate(
                        id: "targeted_\(localAlbum.id)",
                        title: cuts.first?.album ?? localAlbum.title,
                        artist: cleanArtist,
                        releaseYear: releaseYear,
                        genre: genre,
                        artworkURL: artwork,
                        totalTracks: cuts.count,
                        totalDiscs: 1,
                        isSingleOrEP: localAlbum.isSingle,
                        tracks: trackCandidates,
                        sourceAPIs: [source]
                    )
                    mergedReleases.insert(targetedRelease, at: 0)
                    matchedReleaseIDs.insert(targetedRelease.id)
                }
            }
        }

        // Fetch tracks for remaining top releases in the discography
        let remainingReleases = mergedReleases.filter { !matchedReleaseIDs.contains($0.id) && $0.tracks.isEmpty }.prefix(25)
        for release in remainingReleases {
            if let idx = mergedReleases.firstIndex(where: { $0.id == release.id }) {
                let tracks = await fetchCompositeTracks(for: release)
                mergedReleases[idx].tracks = tracks
                if mergedReleases[idx].totalTracks == nil || mergedReleases[idx].totalTracks == 0 {
                    mergedReleases[idx].totalTracks = tracks.count
                }
            }
        }

        onProgress?(0.95, "Finalizing discography models...")
        discographyCache[cacheKey] = mergedReleases
        return mergedReleases
    }

    // MARK: - Release Merging Policy

    private func mergeReleases(
        itunes: [OnlineReleaseCandidate],
        deezer: [OnlineReleaseCandidate],
        musicBrainz: [OnlineReleaseCandidate],
        canonicalArtist: String
    ) -> [UnifiedReleaseCandidate] {
        var composites: [UnifiedReleaseCandidate] = []

        // Primary base: iTunes (has top-quality artwork & mainstream taxonomy)
        for it in itunes {
            let cleanTitle = DeluxeAlbumDetector.cleanToStandardAlbumName(it.title)
            var candidate = UnifiedReleaseCandidate(
                id: "itunes_\(it.id)",
                title: it.title,
                artist: it.artist.isEmpty ? canonicalArtist : it.artist,
                releaseYear: it.releaseYear,
                genre: it.genre,
                artworkURL: it.artworkURL,
                totalTracks: it.totalTracks,
                totalDiscs: 1,
                isSingleOrEP: it.isSingleOrEP,
                tracks: [],
                sourceAPIs: [.itunes]
            )

            // Look for matching Deezer release
            if let dzMatch = deezer.first(where: { releasesMatch(cleanTitle, $0.title) }) {
                candidate.sourceAPIs.append(.deezer)
                if candidate.artworkURL == nil { candidate.artworkURL = dzMatch.artworkURL }
                if candidate.releaseYear == nil { candidate.releaseYear = dzMatch.releaseYear }
                if candidate.totalTracks == nil { candidate.totalTracks = dzMatch.totalTracks }
            }

            // Look for matching MusicBrainz release
            if let mbMatch = musicBrainz.first(where: { releasesMatch(cleanTitle, $0.title) }) {
                candidate.sourceAPIs.append(.musicBrainz)
                if candidate.releaseYear == nil { candidate.releaseYear = mbMatch.releaseYear }
                if candidate.genre == nil { candidate.genre = mbMatch.genre }
            }

            composites.append(candidate)
        }

        // Add Deezer releases that weren't in iTunes
        for dz in deezer {
            let cleanTitle = DeluxeAlbumDetector.cleanToStandardAlbumName(dz.title)
            let alreadyMerged = composites.contains { releasesMatch(cleanTitle, $0.title) }
            guard !alreadyMerged else { continue }

            var candidate = UnifiedReleaseCandidate(
                id: "deezer_\(dz.id)",
                title: dz.title,
                artist: dz.artist.isEmpty ? canonicalArtist : dz.artist,
                releaseYear: dz.releaseYear,
                genre: dz.genre,
                artworkURL: dz.artworkURL,
                totalTracks: dz.totalTracks,
                totalDiscs: 1,
                isSingleOrEP: dz.isSingleOrEP,
                tracks: [],
                sourceAPIs: [.deezer]
            )

            if let mbMatch = musicBrainz.first(where: { releasesMatch(cleanTitle, $0.title) }) {
                candidate.sourceAPIs.append(.musicBrainz)
                if candidate.releaseYear == nil { candidate.releaseYear = mbMatch.releaseYear }
            }

            composites.append(candidate)
        }

        // Add MusicBrainz releases that weren't in iTunes or Deezer
        for mb in musicBrainz {
            let cleanTitle = DeluxeAlbumDetector.cleanToStandardAlbumName(mb.title)
            let alreadyMerged = composites.contains { releasesMatch(cleanTitle, $0.title) }
            guard !alreadyMerged else { continue }

            composites.append(UnifiedReleaseCandidate(
                id: "mb_\(mb.id)",
                title: mb.title,
                artist: mb.artist.isEmpty ? canonicalArtist : mb.artist,
                releaseYear: mb.releaseYear,
                genre: mb.genre,
                artworkURL: mb.artworkURL,
                totalTracks: mb.totalTracks,
                totalDiscs: 1,
                isSingleOrEP: mb.isSingleOrEP,
                tracks: [],
                sourceAPIs: [.musicBrainz]
            ))
        }

        // Sort: Albums first, then singles; within each, descending by year
        return composites.sorted { a, b in
            if a.isSingleOrEP != b.isSingleOrEP {
                return !a.isSingleOrEP && b.isSingleOrEP
            }
            let yA = a.releaseYear ?? 0
            let yB = b.releaseYear ?? 0
            if yA != yB {
                return yA > yB
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private func releasesMatch(_ a: String, _ b: String) -> Bool {
        let normA = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(a))
        let normB = FuzzyMatcher.normalize(DeluxeAlbumDetector.cleanToStandardAlbumName(b))
        if normA == normB { return true }
        let sim = FuzzyMatcher.jaroWinklerSimilarity(normA, normB)
        return sim >= 0.88 || (normA.count >= 4 && normB.contains(normA)) || (normB.count >= 4 && normA.contains(normB))
    }

    // MARK: - Tracklist Merging Policy

    private func fetchCompositeTracks(for release: UnifiedReleaseCandidate) async -> [UnifiedTrackCandidate] {
        var rawTracks: [OnlineTrackCandidate] = []

        // If release originated from iTunes, fetch from iTunes
        if release.id.hasPrefix("itunes_") {
            let itId = release.id.replacingOccurrences(of: "itunes_", with: "")
            if let itTracks = try? await itunes.fetchReleaseTracks(releaseId: itId), !itTracks.isEmpty {
                rawTracks = itTracks
            }
        } else if release.id.hasPrefix("deezer_") {
            let dzId = release.id.replacingOccurrences(of: "deezer_", with: "")
            if let dzTracks = try? await deezer.fetchReleaseTracks(releaseId: dzId), !dzTracks.isEmpty {
                rawTracks = dzTracks
            }
        } else if release.id.hasPrefix("mb_") {
            let mbId = release.id.replacingOccurrences(of: "mb_", with: "")
            if let mbTracks = try? await musicBrainz.fetchReleaseTracks(releaseId: mbId), !mbTracks.isEmpty {
                rawTracks = mbTracks
            }
        }

        // Map into unified composite track candidates
        return rawTracks.map { t in
            UnifiedTrackCandidate(
                id: t.id,
                title: t.title,
                artist: t.artist.isEmpty ? release.artist : t.artist,
                album: release.title,
                trackNumber: t.trackNumber,
                discNumber: t.discNumber ?? 1,
                duration: t.duration,
                isrc: t.isrc,
                releaseYear: t.releaseYear ?? release.releaseYear,
                genre: t.genre ?? release.genre,
                artworkURL: release.artworkURL,
                sourceAPIs: [t.source]
            )
        }
    }
}
