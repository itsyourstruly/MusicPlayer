//
//  OnlineDiscoveryService.swift
//  MusicPlayer
//
//  Created by Principal Apple Software Engineer on 8/25/26.
//

import Foundation
import os

/// Actor-isolated high-speed discovery service connecting concurrently to Apple Music / iTunes API, Deezer API, and Wikipedia REST API.
public actor OnlineDiscoveryService {
    public static let shared = OnlineDiscoveryService()

    private let urlSession: URLSession
    private var searchCache: [String: OnlineSearchResults] = [:]
    private var artistDetailCache: [String: OnlineArtistItem] = [:]
    private var albumDetailCache: [String: OnlineAlbumItem] = [:]
    private var wikipediaSummaryCache: [String: String] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        config.requestCachePolicy = .useProtocolCachePolicy
        self.urlSession = URLSession(configuration: config)
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 4.0
        return request
    }


    // MARK: - Global Multi-Entity Search

    /// Searches for tracks, albums, and artists across iTunes and Deezer concurrently.
    public func search(query: String) async -> OnlineSearchResults {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return OnlineSearchResults() }

        let cacheKey = cleanQuery.lowercased()
        if let cached = searchCache[cacheKey] {
            return cached
        }

        // Concurrently query iTunes and Deezer for tracks, albums, and artists
        async let itunesTracksTask = searchITunesTracks(term: cleanQuery)
        async let deezerTracksTask = searchDeezerTracks(term: cleanQuery)

        async let itunesAlbumsTask = searchITunesAlbums(term: cleanQuery)
        async let deezerAlbumsTask = searchDeezerAlbums(term: cleanQuery)

        async let itunesArtistsTask = searchITunesArtists(term: cleanQuery)
        async let deezerArtistsTask = searchDeezerArtists(term: cleanQuery)

        let (itunesTracks, deezerTracks) = await (itunesTracksTask, deezerTracksTask)
        let (itunesAlbums, deezerAlbums) = await (itunesAlbumsTask, deezerAlbumsTask)
        let (itunesArtists, deezerArtists) = await (itunesArtistsTask, deezerArtistsTask)

        // Merge & deduplicate tracks
        var combinedTracks = itunesTracks
        for dTrack in deezerTracks {
            let normDTitle = normalize(dTrack.title)
            let normDArtist = normalize(dTrack.artistName)
            if !combinedTracks.contains(where: { normalize($0.title) == normDTitle && normalize($0.artistName) == normDArtist }) {
                combinedTracks.append(dTrack)
            }
        }

        // Merge & deduplicate albums
        var combinedAlbums = itunesAlbums
        for dAlbum in deezerAlbums {
            let normDTitle = normalize(dAlbum.title)
            let normDArtist = normalize(dAlbum.artistName)
            if !combinedAlbums.contains(where: { normalize($0.title) == normDTitle && normalize($0.artistName) == normDArtist }) {
                combinedAlbums.append(dAlbum)
            }
        }

        // Merge & deduplicate artists
        var combinedArtists = itunesArtists
        for dArtist in deezerArtists {
            let normDName = normalize(dArtist.name)
            if let existingIndex = combinedArtists.firstIndex(where: { normalize($0.name) == normDName }) {
                // If existing iTunes artist lacks image, adopt Deezer image
                if combinedArtists[existingIndex].imageURL == nil, let img = dArtist.imageURL {
                    let existing = combinedArtists[existingIndex]
                    combinedArtists[existingIndex] = OnlineArtistItem(
                        id: existing.id,
                        name: existing.name,
                        genre: existing.genre ?? dArtist.genre,
                        imageURL: img,
                        appleMusicURL: existing.appleMusicURL,
                        biography: existing.biography,
                        topTracks: existing.topTracks,
                        albums: existing.albums
                    )
                }
            } else {
                combinedArtists.append(dArtist)
            }
        }

        // Ensure all artists have photos populated
        var finalArtists: [OnlineArtistItem] = []
        for artist in combinedArtists {
            if artist.imageURL != nil {
                finalArtists.append(artist)
            } else {
                let photo = await fetchDeezerArtistPhoto(artistName: artist.name)
                finalArtists.append(OnlineArtistItem(
                    id: artist.id,
                    name: artist.name,
                    genre: artist.genre,
                    imageURL: photo,
                    appleMusicURL: artist.appleMusicURL,
                    biography: artist.biography,
                    topTracks: artist.topTracks,
                    albums: artist.albums
                ))
            }
        }

        let results = OnlineSearchResults(
            artists: finalArtists,
            albums: combinedAlbums,
            tracks: combinedTracks
        )

        searchCache[cacheKey] = results
        return results
    }

    // MARK: - Deep Artist Details

    /// Fetches deep biographical information, full discography (sorted chronologically), and featured albums for an artist.
    public func fetchArtistDetails(artist: OnlineArtistItem) async -> OnlineArtistItem {
        if let cached = artistDetailCache[artist.id] {
            return cached
        }

        var detailedArtist = artist

        // 1. Fetch Biography from Wikipedia REST API
        async let bioTask = fetchWikipediaSummary(query: artist.name)

        // 2. Fetch Discography & Top Tracks from iTunes Lookup / Deezer
        async let itunesAlbumsTask = lookupArtistAlbums(artistId: artist.id, artistName: artist.name)
        async let itunesTracksTask = lookupArtistTopTracks(artistId: artist.id, artistName: artist.name)

        // 3. Fetch Featured Albums where artist appears as guest / collaborator
        async let searchAlbumsTask = searchITunesAlbums(term: artist.name)

        // 4. Fetch High-Res Artist Image from Deezer
        async let deezerImageTask = fetchDeezerArtistPhoto(artistName: artist.name)

        let (bio, albums, tracks, searchAlbums, deezerImage) = await (bioTask, itunesAlbumsTask, itunesTracksTask, searchAlbumsTask, deezerImageTask)

        // Sort discography albums chronologically (descending by release date/year)
        let sortedAlbums = albums.sorted { a, b in
            let yearA = a.releaseYear ?? (a.releaseDate.flatMap { Calendar.current.component(.year, from: $0) } ?? 0)
            let yearB = b.releaseYear ?? (b.releaseDate.flatMap { Calendar.current.component(.year, from: $0) } ?? 0)
            if yearA != yearB {
                return yearA > yearB
            }
            if let dateA = a.releaseDate, let dateB = b.releaseDate {
                return dateA > dateB
            }
            return a.title < b.title
        }

        // Filter featured albums (albums not by this primary artist)
        let ownAlbumTitles = Set(sortedAlbums.map { normalize($0.title) })
        let sortedFeatured = searchAlbums.filter { item in
            let normArtist = normalize(item.artistName)
            let normCurrent = normalize(artist.name)
            return normArtist != normCurrent && !ownAlbumTitles.contains(normalize(item.title))
        }.sorted { a, b in
            let yearA = a.releaseYear ?? 0
            let yearB = b.releaseYear ?? 0
            if yearA != yearB { return yearA > yearB }
            return a.title < b.title
        }

        detailedArtist.biography = bio
        detailedArtist.albums = sortedAlbums
        detailedArtist.featuredAlbums = sortedFeatured
        detailedArtist.topTracks = tracks
        if detailedArtist.imageURL == nil, let dImage = deezerImage {
            detailedArtist = OnlineArtistItem(
                id: detailedArtist.id,
                name: detailedArtist.name,
                genre: detailedArtist.genre,
                imageURL: dImage,
                appleMusicURL: detailedArtist.appleMusicURL,
                biography: bio,
                topTracks: tracks,
                albums: sortedAlbums,
                featuredAlbums: sortedFeatured
            )
        }

        artistDetailCache[artist.id] = detailedArtist
        return detailedArtist
    }

    // MARK: - Deep Album Details

    /// Fetches full official tracklist with audio previews, record label, copyright, and Wikipedia overview.
    public func fetchAlbumDetails(album: OnlineAlbumItem) async -> OnlineAlbumItem {
        if let cached = albumDetailCache[album.id] {
            return cached
        }

        var detailedAlbum = album

        // 1. Fetch Official Tracklist & Copyright from iTunes Lookup or Deezer
        async let tracklistTask = lookupAlbumTracksAndMetadata(album: album)

        // 2. Fetch Album Overview Description from Wikipedia
        let wikiQuery = "\(album.title) (\(album.artistName) album)"
        async let descTask = fetchWikipediaSummary(query: wikiQuery)
        async let fallbackDescTask = fetchWikipediaSummary(query: "\(album.title) album")

        let ((tracklist, copyright, label), desc1, desc2) = await (tracklistTask, descTask, fallbackDescTask)

        detailedAlbum.tracklist = tracklist
        detailedAlbum.description = desc1 ?? desc2

        detailedAlbum = OnlineAlbumItem(
            id: detailedAlbum.id,
            title: detailedAlbum.title,
            artistName: detailedAlbum.artistName,
            artistId: detailedAlbum.artistId,
            releaseDate: detailedAlbum.releaseDate,
            releaseYear: detailedAlbum.releaseYear,
            recordLabel: label ?? detailedAlbum.recordLabel,
            copyright: copyright ?? detailedAlbum.copyright,
            genre: detailedAlbum.genre,
            trackCount: detailedAlbum.trackCount ?? tracklist.count,
            discCount: detailedAlbum.discCount,
            artworkURL: detailedAlbum.artworkURL,
            description: desc1 ?? desc2,
            tracklist: tracklist
        )

        albumDetailCache[album.id] = detailedAlbum
        return detailedAlbum
    }

    // MARK: - Deep Track Details

    /// Fetches full production credits (producers, composers, performers, audio specs) for a track.
    public func fetchTrackDetails(track: OnlineTrackItem) async -> OnlineTrackItem {
        var detailedTrack = track

        var deezerId: Int? = nil
        let cleanId = track.id.replacingOccurrences(of: "dz_", with: "").replacingOccurrences(of: "itunes_", with: "")
        if !track.id.hasPrefix("itunes_") {
            deezerId = Int(cleanId)
        }

        if deezerId == nil {
            let cleanQuery = "\(track.title) \(track.artistName)"
            if let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=1") {
                let request = makeRequest(url: url)
                if let (data, response) = try? await urlSession.data(for: request),
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let searchResp = try? JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data),
                   let first = searchResp.data.first {
                    deezerId = first.id
                }
            }
        }

        if let dzId = deezerId, let url = URL(string: "https://api.deezer.com/track/\(dzId)") {
            let request = makeRequest(url: url)
            if let (data, response) = try? await urlSession.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let dzDetail = try? JSONDecoder().decode(DeezerFullTrackDetailsResponse.self, from: data) {

                var producersList: [String] = []
                var composersList: [String] = []
                var performersList: [String] = []

                if let contributors = dzDetail.contributors {
                    for c in contributors {
                        guard let name = c.name, !name.isEmpty else { continue }
                        let role = (c.role ?? "").lowercased()
                        if role.contains("producer") {
                            if !producersList.contains(name) { producersList.append(name) }
                        } else if role.contains("composer") || role.contains("author") || role.contains("writer") {
                            if !composersList.contains(name) { composersList.append(name) }
                        } else if role.contains("main") || role.contains("featured") || role.contains("artist") {
                            if !performersList.contains(name) { performersList.append(name) }
                        }
                    }
                }

                let finalProducers = !producersList.isEmpty ? producersList.joined(separator: ", ") : detailedTrack.producers
                let finalComposers = !composersList.isEmpty ? composersList.joined(separator: ", ") : (dzDetail.composer ?? detailedTrack.composer)
                let finalPerformers = !performersList.isEmpty ? performersList.joined(separator: ", ") : detailedTrack.performers
                let finalLabel = dzDetail.album?.label ?? detailedTrack.recordLabel
                let finalBpm = dzDetail.bpm ?? detailedTrack.bpm

                var rDate: Date? = detailedTrack.releaseDate
                var rYear: Int? = detailedTrack.releaseYear

                if let rStr = dzDetail.release_date ?? dzDetail.album?.release_date, !rStr.isEmpty {
                    rYear = Int(rStr.prefix(4))
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    rDate = f.date(from: rStr)
                }

                detailedTrack = OnlineTrackItem(
                    id: detailedTrack.id,
                    title: detailedTrack.title,
                    artistName: detailedTrack.artistName,
                    albumTitle: detailedTrack.albumTitle,
                    albumId: detailedTrack.albumId,
                    releaseDate: rDate,
                    releaseYear: rYear,
                    genre: detailedTrack.genre ?? dzDetail.genres?.data?.first?.name,
                    trackNumber: detailedTrack.trackNumber ?? dzDetail.track_position,
                    totalTracks: detailedTrack.totalTracks ?? dzDetail.album?.nb_tracks,
                    discNumber: detailedTrack.discNumber ?? dzDetail.disk_number,
                    duration: detailedTrack.duration > 0 ? detailedTrack.duration : Double(dzDetail.duration ?? 0),
                    previewURL: detailedTrack.previewURL ?? dzDetail.preview.flatMap { URL(string: $0) },
                    artworkURL: detailedTrack.artworkURL ?? dzDetail.album?.cover_xl.flatMap { URL(string: $0) },
                    recordLabel: finalLabel,
                    isExplicit: detailedTrack.isExplicit || (dzDetail.explicit_lyrics ?? false),
                    composer: finalComposers,
                    performers: finalPerformers,
                    producers: finalProducers,
                    bpm: finalBpm
                )
            }
        }

        return detailedTrack
    }

    // MARK: - Wikipedia Summary API

    private func fetchWikipediaSummary(query: String) async -> String? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let cacheKey = clean.lowercased()
        if let cached = wikipediaSummaryCache[cacheKey] {
            return cached
        }

        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }

        let request = makeRequest(url: url)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let wikiResp = try JSONDecoder().decode(WikipediaSummaryResponse.self, from: data)

            if let extract = wikiResp.extract, !extract.isEmpty, wikiResp.type != "disambiguation" {
                wikipediaSummaryCache[cacheKey] = extract
                return extract
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - iTunes Search Endpoints

    private func searchITunesTracks(term: String) async -> [OnlineTrackItem] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=15") else {
            return []
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let search = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

            return search.results.compactMap { item in
                guard let title = item.trackName, let artist = item.artistName else { return nil }

                let artwork = item.artworkUrl100.flatMap {
                    URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                }
                let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                let date = item.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }
                let duration = item.trackTimeMillis.map { Double($0) / 1000.0 } ?? 0

                return OnlineTrackItem(
                    id: "\(item.trackId ?? Int.random(in: 100000...999999))",
                    title: title,
                    artistName: artist,
                    albumTitle: item.collectionName ?? "Single",
                    albumId: item.collectionId.map { "\($0)" },
                    releaseDate: date,
                    releaseYear: year,
                    genre: item.primaryGenreName,
                    trackNumber: item.trackNumber,
                    totalTracks: item.trackCount,
                    discNumber: item.discNumber,
                    duration: duration,
                    previewURL: item.previewUrl.flatMap { URL(string: $0) },
                    artworkURL: artwork,
                    recordLabel: item.collectionArtistName,
                    isExplicit: item.trackExplicitness == "explicit"
                )
            }
        } catch {
            return []
        }
    }

    private func searchITunesAlbums(term: String) async -> [OnlineAlbumItem] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=album&limit=10") else {
            return []
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let search = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

            return search.results.compactMap { item in
                guard let title = item.collectionName, let artist = item.artistName, let collectionId = item.collectionId else { return nil }

                let artwork = item.artworkUrl100.flatMap {
                    URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                }
                let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                let date = item.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }

                return OnlineAlbumItem(
                    id: "\(collectionId)",
                    title: title,
                    artistName: artist,
                    artistId: item.artistId.map { "\($0)" },
                    releaseDate: date,
                    releaseYear: year,
                    copyright: item.copyright,
                    genre: item.primaryGenreName,
                    trackCount: item.trackCount,
                    artworkURL: artwork
                )
            }
        } catch {
            return []
        }
    }

    private func searchITunesArtists(term: String) async -> [OnlineArtistItem] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=musicArtist&limit=8") else {
            return []
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let search = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

            return search.results.compactMap { item in
                guard let artistName = item.artistName, let artistId = item.artistId else { return nil }
                return OnlineArtistItem(
                    id: "\(artistId)",
                    name: artistName,
                    genre: item.primaryGenreName,
                    appleMusicURL: item.artistLinkUrl.flatMap { URL(string: $0) }
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Deezer Search Endpoints

    private func searchDeezerTracks(term: String) async -> [OnlineTrackItem] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=15") else {
            return []
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let deezerSearch = try JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data)

            return deezerSearch.data.compactMap { (item: DeezerTrackItemResult) -> OnlineTrackItem? in
                guard let title = item.title, let artist = item.artist?.name else { return nil }

                let artwork = item.album?.cover_xl.flatMap { URL(string: $0) } ?? item.album?.cover_big.flatMap { URL(string: $0) }
                let preview = item.preview.flatMap { URL(string: $0) }

                return OnlineTrackItem(
                    id: "dz_\(item.id)",
                    title: title,
                    artistName: artist,
                    albumTitle: item.album?.title ?? "Single",
                    albumId: item.album.map { "dz_\($0.id)" },
                    releaseDate: nil,
                    releaseYear: nil,
                    genre: nil,
                    trackNumber: nil,
                    totalTracks: nil,
                    discNumber: nil,
                    duration: Double(item.duration ?? 0),
                    previewURL: preview,
                    artworkURL: artwork,
                    recordLabel: nil,
                    isExplicit: item.explicit_lyrics ?? false
                )
            }
        } catch {
            return []
        }
    }

    private func searchDeezerAlbums(term: String) async -> [OnlineAlbumItem] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=10") else {
            return []
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let deezerSearch = try JSONDecoder().decode(DeezerAlbumSearchResponse.self, from: data)

            return deezerSearch.data.compactMap { (item: DeezerAlbumItemResult) -> OnlineAlbumItem? in
                guard let title = item.title, let artist = item.artist?.name else { return nil }

                let artwork = item.cover_xl.flatMap { URL(string: $0) } ?? item.cover_big.flatMap { URL(string: $0) }

                return OnlineAlbumItem(
                    id: "dz_\(item.id)",
                    title: title,
                    artistName: artist,
                    artistId: item.artist.map { "dz_\($0.id)" },
                    releaseDate: nil,
                    releaseYear: nil,
                    recordLabel: nil,
                    copyright: nil,
                    genre: item.genre_id.map { "\($0)" },
                    trackCount: item.nb_tracks,
                    artworkURL: artwork
                )
            }
        } catch {
            return []
        }
    }

    private func searchDeezerArtists(term: String) async -> [OnlineArtistItem] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=8") else {
            return []
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let deezerSearch = try JSONDecoder().decode(DeezerArtistSearchResponse.self, from: data)

            return deezerSearch.data.compactMap { item in
                let img = item.picture_xl.flatMap { URL(string: $0) } ?? item.picture_big.flatMap { URL(string: $0) }
                return OnlineArtistItem(
                    id: "dz_\(item.id)",
                    name: item.name,
                    genre: nil,
                    imageURL: img
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Lookup Endpoints

    private func lookupArtistAlbums(artistId: String, artistName: String) async -> [OnlineAlbumItem] {
        if !artistId.hasPrefix("dz_"), let cleanId = Int(artistId) {
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(cleanId)&entity=album&limit=25") else { return [] }

            do {
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
                let lookup = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

                let albums = lookup.results.compactMap { item -> OnlineAlbumItem? in
                    guard item.wrapperType == "collection", let title = item.collectionName, let artist = item.artistName, let collectionId = item.collectionId else { return nil }

                    let artwork = item.artworkUrl100.flatMap {
                        URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                    }
                    let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                    let date = item.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }

                    return OnlineAlbumItem(
                        id: "\(collectionId)",
                        title: title,
                        artistName: artist,
                        artistId: artistId,
                        releaseDate: date,
                        releaseYear: year,
                        copyright: item.copyright,
                        genre: item.primaryGenreName,
                        trackCount: item.trackCount,
                        artworkURL: artwork
                    )
                }

                if !albums.isEmpty { return albums }
            } catch {}
        }

        // Fallback: Deezer album search for artist
        return await searchDeezerAlbums(term: artistName)
    }

    private func lookupArtistTopTracks(artistId: String, artistName: String) async -> [OnlineTrackItem] {
        if !artistId.hasPrefix("dz_"), let cleanId = Int(artistId) {
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(cleanId)&entity=song&limit=10") else { return [] }

            do {
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
                let lookup = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

                let tracks = lookup.results.compactMap { item -> OnlineTrackItem? in
                    guard item.wrapperType == "track", let title = item.trackName, let artist = item.artistName else { return nil }

                    let artwork = item.artworkUrl100.flatMap {
                        URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                    }
                    let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                    let duration = item.trackTimeMillis.map { Double($0) / 1000.0 } ?? 0

                    return OnlineTrackItem(
                        id: "\(item.trackId ?? Int.random(in: 100000...999999))",
                        title: title,
                        artistName: artist,
                        albumTitle: item.collectionName ?? "Single",
                        albumId: item.collectionId.map { "\($0)" },
                        releaseDate: nil,
                        releaseYear: year,
                        genre: item.primaryGenreName,
                        trackNumber: item.trackNumber,
                        totalTracks: item.trackCount,
                        discNumber: item.discNumber,
                        duration: duration,
                        previewURL: item.previewUrl.flatMap { URL(string: $0) },
                        artworkURL: artwork,
                        isExplicit: item.trackExplicitness == "explicit"
                    )
                }

                if !tracks.isEmpty { return tracks }
            } catch {}
        }

        // Fallback: Deezer tracks for artist
        return await searchDeezerTracks(term: artistName)
    }

    private func lookupAlbumTracksAndMetadata(album: OnlineAlbumItem) async -> (tracks: [OnlineTrackItem], copyright: String?, label: String?) {
        if !album.id.hasPrefix("dz_"), let cleanId = Int(album.id) {
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(cleanId)&entity=song") else {
                return ([], nil, nil)
            }

            do {
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return ([], nil, nil) }
                let lookup = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

                var copyright: String? = nil
                var label: String? = nil

                let tracks: [OnlineTrackItem] = lookup.results.compactMap { item in
                    if item.wrapperType == "collection" {
                        copyright = item.copyright
                        label = item.collectionArtistName
                        return nil
                    }

                    guard let title = item.trackName, let artist = item.artistName else { return nil }

                    let artwork = item.artworkUrl100.flatMap {
                        URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                    }
                    let duration = item.trackTimeMillis.map { Double($0) / 1000.0 } ?? 0

                    return OnlineTrackItem(
                        id: "\(item.trackId ?? Int.random(in: 100000...999999))",
                        title: title,
                        artistName: artist,
                        albumTitle: item.collectionName ?? album.title,
                        albumId: album.id,
                        releaseDate: nil,
                        releaseYear: item.releaseDate.flatMap { Int($0.prefix(4)) },
                        genre: item.primaryGenreName,
                        trackNumber: item.trackNumber,
                        totalTracks: item.trackCount,
                        discNumber: item.discNumber,
                        duration: duration,
                        previewURL: item.previewUrl.flatMap { URL(string: $0) },
                        artworkURL: artwork,
                        recordLabel: label,
                        isExplicit: item.trackExplicitness == "explicit"
                    )
                }

                if !tracks.isEmpty {
                    return (tracks, copyright, label)
                }
            } catch {}
        }

        // Deezer Album Tracks Lookup Fallback
        let deezerAlbumId = album.id.replacingOccurrences(of: "dz_", with: "")
        if let dzId = Int(deezerAlbumId), let url = URL(string: "https://api.deezer.com/album/\(dzId)") {
            do {
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return ([], nil, nil) }
                let dzAlbum = try JSONDecoder().decode(DeezerAlbumDetailedResponse.self, from: data)

                let tracks = (dzAlbum.tracks?.data ?? []).map { item in
                    OnlineTrackItem(
                        id: "dz_\(item.id)",
                        title: item.title ?? "Track",
                        artistName: item.artist?.name ?? album.artistName,
                        albumTitle: album.title,
                        albumId: album.id,
                        releaseDate: nil,
                        releaseYear: album.releaseYear,
                        genre: album.genre,
                        trackNumber: item.track_position,
                        totalTracks: dzAlbum.nb_tracks,
                        discNumber: item.disk_number,
                        duration: Double(item.duration ?? 0),
                        previewURL: item.preview.flatMap { URL(string: $0) },
                        artworkURL: album.artworkURL,
                        recordLabel: dzAlbum.label,
                        isExplicit: item.explicit_lyrics ?? false
                    )
                }
                return (tracks, dzAlbum.copyright, dzAlbum.label)
            } catch {}
        }

        return ([], nil, nil)
    }

    private func fetchDeezerArtistPhoto(artistName: String) async -> URL? {
        guard let encoded = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=1") else {
            return nil
        }

        do {
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let deezerSearch = try JSONDecoder().decode(DeezerArtistSearchResponse.self, from: data)

            if let first = deezerSearch.data.first {
                if let xl = first.picture_xl, let u = URL(string: xl) { return u }
                if let big = first.picture_big, let u = URL(string: big) { return u }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func normalize(_ str: String) -> String {
        str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - Decodable Structures

private struct ITunesDiscoverySearchResponse: Codable {
    let resultCount: Int
    let results: [ITunesDiscoveryResult]
}

private struct ITunesDiscoveryResult: Codable {
    let wrapperType: String?
    let artistId: Int?
    let collectionId: Int?
    let trackId: Int?
    let artistName: String?
    let collectionName: String?
    let trackName: String?
    let collectionArtistName: String?
    let primaryGenreName: String?
    let releaseDate: String?
    let trackCount: Int?
    let trackNumber: Int?
    let discNumber: Int?
    let trackTimeMillis: Int?
    let artworkUrl100: String?
    let previewUrl: String?
    let copyright: String?
    let artistLinkUrl: String?
    let trackExplicitness: String?
}

private struct WikipediaSummaryResponse: Codable {
    let title: String?
    let extract: String?
    let description: String?
    let type: String?
}

private struct DeezerTrackSearchResponse: Codable {
    let data: [DeezerTrackItemResult]
}

private struct DeezerTrackItemResult: Codable {
    let id: Int
    let title: String?
    let duration: Int?
    let preview: String?
    let explicit_lyrics: Bool?
    let artist: DeezerArtistItemResult?
    let album: DeezerAlbumItemResult?
}

private struct DeezerAlbumSearchResponse: Codable {
    let data: [DeezerAlbumItemResult]
}

private struct DeezerAlbumItemResult: Codable {
    let id: Int
    let title: String?
    let cover_big: String?
    let cover_xl: String?
    let nb_tracks: Int?
    let genre_id: Int?
    let artist: DeezerArtistItemResult?
}

private struct DeezerArtistSearchResponse: Codable {
    let data: [DeezerArtistItemResult]
}

private struct DeezerArtistItemResult: Codable {
    let id: Int
    let name: String
    let picture_big: String?
    let picture_xl: String?
}

private struct DeezerAlbumDetailedResponse: Codable {
    let id: Int
    let title: String?
    let label: String?
    let copyright: String?
    let nb_tracks: Int?
    let tracks: DeezerAlbumTracksDataResponse?
}

private struct DeezerAlbumTracksDataResponse: Codable {
    let data: [DeezerAlbumTrackItemResult]
}

private struct DeezerAlbumTrackItemResult: Codable {
    let id: Int
    let title: String?
    let duration: Int?
    let track_position: Int?
    let disk_number: Int?
    let preview: String?
    let explicit_lyrics: Bool?
    let artist: DeezerArtistItemResult?
}

private struct DeezerFullTrackDetailsResponse: Codable {
    let id: Int
    let title: String?
    let release_date: String?
    let duration: Int?
    let bpm: Int?
    let track_position: Int?
    let disk_number: Int?
    let preview: String?
    let explicit_lyrics: Bool?
    let composer: String?
    let artist: DeezerArtistItemResult?
    let album: DeezerAlbumDetailedResult?
    let contributors: [DeezerContributorItemResult]?
    let genres: DeezerGenresListResponse?
}

private struct DeezerAlbumDetailedResult: Codable {
    let id: Int?
    let title: String?
    let release_date: String?
    let cover_xl: String?
    let label: String?
    let nb_tracks: Int?
}

private struct DeezerContributorItemResult: Codable {
    let id: Int?
    let name: String?
    let role: String?
}

private struct DeezerGenresListResponse: Codable {
    let data: [DeezerGenreItemResponse]?
}

private struct DeezerGenreItemResponse: Codable {
    let id: Int?
    let name: String?
}
