import Foundation
import os

/// Actor-isolated high-speed discovery service connecting concurrently to Apple Music / iTunes API, Deezer API, and Wikipedia REST API.
public actor OnlineDiscoveryService {
    public static let shared = OnlineDiscoveryService()

    // Url session
    private let urlSession: URLSession
    private var searchCache: [String: OnlineSearchResults] = [:]
    private var artistDetailCache: [String: OnlineArtistItem] = [:]
    private var albumDetailCache: [String: OnlineAlbumItem] = [:]
    private var wikipediaSummaryCache: [String: String] = [:]

    // Initialize with configured properties
    private init() {
        // Config
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        config.requestCachePolicy = .useProtocolCachePolicy
        self.urlSession = URLSession(configuration: config)
    }

    // Make request
    private func makeRequest(url: URL) -> URLRequest {
        // Request
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 4.0
        return request
    }


    // MARK: - Global Multi-Entity Search

    /// Searches for tracks, albums, and artists across iTunes and Deezer concurrently.
    public func search(query: String) async -> OnlineSearchResults {
        // Clean query
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !cleanQuery.isEmpty else { return OnlineSearchResults() }

        // In-memory cache for cache key
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
            // Norm d title
            let normDTitle = normalize(dTrack.title)
            // Norm d artist
            let normDArtist = normalize(dTrack.artistName)
            if !combinedTracks.contains(where: { normalize($0.title) == normDTitle && normalize($0.artistName) == normDArtist }) {
                combinedTracks.append(dTrack)
            }
        }

        // Merge & deduplicate albums
        var combinedAlbums = itunesAlbums
        for dAlbum in deezerAlbums {
            // Norm d title
            let normDTitle = normalize(dAlbum.title)
            // Norm d artist
            let normDArtist = normalize(dAlbum.artistName)
            if !combinedAlbums.contains(where: { normalize($0.title) == normDTitle && normalize($0.artistName) == normDArtist }) {
                combinedAlbums.append(dAlbum)
            }
        }

        // Merge & deduplicate artists
        var combinedArtists = itunesArtists
        for dArtist in deezerArtists {
            // Norm d name
            let normDName = normalize(dArtist.name)
            if let existingIndex = combinedArtists.firstIndex(where: { normalize($0.name) == normDName }) {
                // If existing iTunes artist lacks image, adopt Deezer image
                if combinedArtists[existingIndex].imageURL == nil, let img = dArtist.imageURL {
                    // Existing
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
                // Photo
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

        // Results
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

        // Detailed artist
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
            // Year a
            let yearA = a.releaseYear ?? (a.releaseDate.flatMap { Calendar.current.component(.year, from: $0) } ?? 0)
            // Year b
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
        // Sorted featured
        let sortedFeatured = searchAlbums.filter { item in
            // Norm artist
            let normArtist = normalize(item.artistName)
            // Norm current
            let normCurrent = normalize(artist.name)
            return normArtist != normCurrent && !ownAlbumTitles.contains(normalize(item.title))
        }.sorted { a, b in
            // Year a
            let yearA = a.releaseYear ?? 0
            // Year b
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

        // Detailed album
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
        // Detailed track
        var detailedTrack = track

        // Unique identifier for deezer id
        var deezerId: Int? = nil
        // Unique identifier for clean id
        let cleanId = track.id.replacingOccurrences(of: "dz_", with: "").replacingOccurrences(of: "itunes_", with: "")
        if !track.id.hasPrefix("itunes_") {
            deezerId = Int(cleanId)
        }

        if deezerId == nil {
            // Clean query
            let cleanQuery = "\(track.title) \(track.artistName)"
            if let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               // Local audio file URL
               let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=1") {
                // Request
                let request = makeRequest(url: url)
                if let (data, response) = try? await urlSession.data(for: request),
                   // Http
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   // Search resp
                   let searchResp = try? JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data),
                   // First
                   let first = searchResp.data.first {
                    deezerId = first.id
                }
            }
        }

        if let dzId = deezerId, let url = URL(string: "https://api.deezer.com/track/\(dzId)") {
            // Request
            let request = makeRequest(url: url)
            if let (data, response) = try? await urlSession.data(for: request),
               // Http
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               // Dz detail
               let dzDetail = try? JSONDecoder().decode(DeezerFullTrackDetailsResponse.self, from: data) {

                // Producers list
                var producersList: [String] = []
                // Composers list
                var composersList: [String] = []
                // Performers list
                var performersList: [String] = []

                if let contributors = dzDetail.contributors {
                    for c in contributors {
                        // Ensure preconditions are met before proceeding
                        guard let name = c.name, !name.isEmpty else { continue }
                        // Role
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

                // Final producers
                let finalProducers = !producersList.isEmpty ? producersList.joined(separator: ", ") : detailedTrack.producers
                // Final composers
                let finalComposers = !composersList.isEmpty ? composersList.joined(separator: ", ") : (dzDetail.composer ?? detailedTrack.composer)
                // Final performers
                let finalPerformers = !performersList.isEmpty ? performersList.joined(separator: ", ") : detailedTrack.performers
                // Final label
                let finalLabel = dzDetail.album?.label ?? detailedTrack.recordLabel
                // Final bpm
                let finalBpm = dzDetail.bpm ?? detailedTrack.bpm

                // R date
                var rDate: Date? = detailedTrack.releaseDate
                // R year
                var rYear: Int? = detailedTrack.releaseYear

                if let rStr = dzDetail.release_date ?? dzDetail.album?.release_date, !rStr.isEmpty {
                    rYear = Int(rStr.prefix(4))
                    // F
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

    // Fetch wikipedia summary
    private func fetchWikipediaSummary(query: String) async -> String? {
        // Clean
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure preconditions are met before proceeding
        guard !clean.isEmpty else { return nil }

        // In-memory cache for cache key
        let cacheKey = clean.lowercased()
        if let cached = wikipediaSummaryCache[cacheKey] {
            return cached
        }

        // Ensure preconditions are met before proceeding
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              // Local audio file URL
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }

        // Request
        let request = makeRequest(url: url)

        do {
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            // Wiki resp
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

    // Search i tunes tracks
    private func searchITunesTracks(term: String) async -> [OnlineTrackItem] {
        // Ensure preconditions are met before proceeding
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=15") else {
            return []
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            // Search
            let search = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

            return search.results.compactMap { item in
                // Ensure preconditions are met before proceeding
                guard let title = item.trackName, let artist = item.artistName else { return nil }

                // Artwork
                let artwork = item.artworkUrl100.flatMap {
                    URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                }
                // Release year
                let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                // Date
                let date = item.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) }
                // Duration in seconds
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

    // Search i tunes albums
    private func searchITunesAlbums(term: String) async -> [OnlineAlbumItem] {
        // Ensure preconditions are met before proceeding
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=album&limit=10") else {
            return []
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            // Search
            let search = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

            return search.results.compactMap { item in
                // Ensure preconditions are met before proceeding
                guard let title = item.collectionName, let artist = item.artistName, let collectionId = item.collectionId else { return nil }

                // Artwork
                let artwork = item.artworkUrl100.flatMap {
                    URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                }
                // Release year
                let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                // Date
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

    // Search i tunes artists
    private func searchITunesArtists(term: String) async -> [OnlineArtistItem] {
        // Ensure preconditions are met before proceeding
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=musicArtist&limit=8") else {
            return []
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            // Search
            let search = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

            return search.results.compactMap { item in
                // Ensure preconditions are met before proceeding
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

    // Search deezer tracks
    private func searchDeezerTracks(term: String) async -> [OnlineTrackItem] {
        // Ensure preconditions are met before proceeding
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=15") else {
            return []
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            // Deezer search
            let deezerSearch = try JSONDecoder().decode(DeezerTrackSearchResponse.self, from: data)

            return deezerSearch.data.compactMap { (item: DeezerTrackItemResult) -> OnlineTrackItem? in
                // Ensure preconditions are met before proceeding
                guard let title = item.title, let artist = item.artist?.name else { return nil }

                // Artwork
                let artwork = item.album?.cover_xl.flatMap { URL(string: $0) } ?? item.album?.cover_big.flatMap { URL(string: $0) }
                // Preview
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

    // Search deezer albums
    private func searchDeezerAlbums(term: String) async -> [OnlineAlbumItem] {
        // Ensure preconditions are met before proceeding
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=10") else {
            return []
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            // Deezer search
            let deezerSearch = try JSONDecoder().decode(DeezerAlbumSearchResponse.self, from: data)

            return deezerSearch.data.compactMap { (item: DeezerAlbumItemResult) -> OnlineAlbumItem? in
                // Ensure preconditions are met before proceeding
                guard let title = item.title, let artist = item.artist?.name else { return nil }

                // Artwork
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

    // Search deezer artists
    private func searchDeezerArtists(term: String) async -> [OnlineArtistItem] {
        // Ensure preconditions are met before proceeding
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=8") else {
            return []
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            // Deezer search
            let deezerSearch = try JSONDecoder().decode(DeezerArtistSearchResponse.self, from: data)

            return deezerSearch.data.compactMap { item in
                // Img
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

    // Lookup artist albums
    private func lookupArtistAlbums(artistId: String, artistName: String) async -> [OnlineAlbumItem] {
        if !artistId.hasPrefix("dz_"), let cleanId = Int(artistId) {
            // Ensure preconditions are met before proceeding
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(cleanId)&entity=album&limit=25") else { return [] }

            do {
                // Request
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                // Ensure preconditions are met before proceeding
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
                // Lookup
                let lookup = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

                // Albums
                let albums = lookup.results.compactMap { item -> OnlineAlbumItem? in
                    // Ensure preconditions are met before proceeding
                    guard item.wrapperType == "collection", let title = item.collectionName, let artist = item.artistName, let collectionId = item.collectionId else { return nil }

                    // Artwork
                    let artwork = item.artworkUrl100.flatMap {
                        URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                    }
                    // Release year
                    let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                    // Date
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

    // Lookup artist top tracks
    private func lookupArtistTopTracks(artistId: String, artistName: String) async -> [OnlineTrackItem] {
        if !artistId.hasPrefix("dz_"), let cleanId = Int(artistId) {
            // Ensure preconditions are met before proceeding
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(cleanId)&entity=song&limit=10") else { return [] }

            do {
                // Request
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                // Ensure preconditions are met before proceeding
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
                // Lookup
                let lookup = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

                // Tracks
                let tracks = lookup.results.compactMap { item -> OnlineTrackItem? in
                    // Ensure preconditions are met before proceeding
                    guard item.wrapperType == "track", let title = item.trackName, let artist = item.artistName else { return nil }

                    // Artwork
                    let artwork = item.artworkUrl100.flatMap {
                        URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                    }
                    // Release year
                    let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
                    // Duration in seconds
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

    // Lookup album tracks and metadata
    private func lookupAlbumTracksAndMetadata(album: OnlineAlbumItem) async -> (tracks: [OnlineTrackItem], copyright: String?, label: String?) {
        if !album.id.hasPrefix("dz_"), let cleanId = Int(album.id) {
            // Ensure preconditions are met before proceeding
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(cleanId)&entity=song") else {
                return ([], nil, nil)
            }

            do {
                // Request
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                // Ensure preconditions are met before proceeding
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return ([], nil, nil) }
                // Lookup
                let lookup = try JSONDecoder().decode(ITunesDiscoverySearchResponse.self, from: data)

                // Copyright
                var copyright: String? = nil
                // Label
                var label: String? = nil

                // Tracks
                let tracks: [OnlineTrackItem] = lookup.results.compactMap { item in
                    if item.wrapperType == "collection" {
                        copyright = item.copyright
                        label = item.collectionArtistName
                        return nil
                    }

                    // Ensure preconditions are met before proceeding
                    guard let title = item.trackName, let artist = item.artistName else { return nil }

                    // Artwork
                    let artwork = item.artworkUrl100.flatMap {
                        URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
                    }
                    // Duration in seconds
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
                // Request
                let request = makeRequest(url: url)
                let (data, response) = try await urlSession.data(for: request)
                // Ensure preconditions are met before proceeding
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return ([], nil, nil) }
                // Dz album
                let dzAlbum = try JSONDecoder().decode(DeezerAlbumDetailedResponse.self, from: data)

                // Tracks
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

    // Fetch deezer artist photo
    private func fetchDeezerArtistPhoto(artistName: String) async -> URL? {
        // Ensure preconditions are met before proceeding
        guard let encoded = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // Local audio file URL
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=1") else {
            return nil
        }

        do {
            // Request
            let request = makeRequest(url: url)
            let (data, response) = try await urlSession.data(for: request)
            // Ensure preconditions are met before proceeding
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            // Deezer search
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

    // Normalize
    private func normalize(_ str: String) -> String {
        str.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - Decodable Structures

// ITunesDiscoverySearchResponse representation
private struct ITunesDiscoverySearchResponse: Codable {
    // Result count
    let resultCount: Int
    // Results
    let results: [ITunesDiscoveryResult]
}

// ITunesDiscoveryResult representation
private struct ITunesDiscoveryResult: Codable {
    // Wrapper type
    let wrapperType: String?
    // Unique identifier for artist id
    let artistId: Int?
    // Unique identifier for collection id
    let collectionId: Int?
    // Unique identifier for track id
    let trackId: Int?
    // Artist name
    let artistName: String?
    // Collection name
    let collectionName: String?
    // Track name
    let trackName: String?
    // Collection artist name
    let collectionArtistName: String?
    // Primary genre name
    let primaryGenreName: String?
    // Release date
    let releaseDate: String?
    // Track count
    let trackCount: Int?
    // Track number
    let trackNumber: Int?
    // Disc number
    let discNumber: Int?
    // Track time millis
    let trackTimeMillis: Int?
    // Artwork url 100
    let artworkUrl100: String?
    // File system location for preview url
    let previewUrl: String?
    // Copyright
    let copyright: String?
    // File system location for artist link url
    let artistLinkUrl: String?
    // Track explicitness
    let trackExplicitness: String?
}

// WikipediaSummaryResponse representation
private struct WikipediaSummaryResponse: Codable {
    // Display title
    let title: String?
    // Extract
    let extract: String?
    // Description
    let description: String?
    // Type
    let type: String?
}

// DeezerTrackSearchResponse representation
private struct DeezerTrackSearchResponse: Codable {
    // Data
    let data: [DeezerTrackItemResult]
}

// DeezerTrackItemResult representation
private struct DeezerTrackItemResult: Codable {
    // Unique identifier
    let id: Int
    // Display title
    let title: String?
    // Duration in seconds
    let duration: Int?
    // Preview
    let preview: String?
    // Explicit lyrics
    let explicit_lyrics: Bool?
    // Primary artist name
    let artist: DeezerArtistItemResult?
    // Album title
    let album: DeezerAlbumItemResult?
}

// DeezerAlbumSearchResponse representation
private struct DeezerAlbumSearchResponse: Codable {
    // Data
    let data: [DeezerAlbumItemResult]
}

// DeezerAlbumItemResult representation
private struct DeezerAlbumItemResult: Codable {
    // Unique identifier
    let id: Int
    // Display title
    let title: String?
    // Cover big
    let cover_big: String?
    // Cover xl
    let cover_xl: String?
    // Nb tracks
    let nb_tracks: Int?
    // Genre id
    let genre_id: Int?
    // Primary artist name
    let artist: DeezerArtistItemResult?
}

// DeezerArtistSearchResponse representation
private struct DeezerArtistSearchResponse: Codable {
    // Data
    let data: [DeezerArtistItemResult]
}

// DeezerArtistItemResult representation
private struct DeezerArtistItemResult: Codable {
    // Unique identifier
    let id: Int
    // Name
    let name: String
    // Picture big
    let picture_big: String?
    // Picture xl
    let picture_xl: String?
}

// DeezerAlbumDetailedResponse representation
private struct DeezerAlbumDetailedResponse: Codable {
    // Unique identifier
    let id: Int
    // Display title
    let title: String?
    // Label
    let label: String?
    // Copyright
    let copyright: String?
    // Nb tracks
    let nb_tracks: Int?
    // Tracks
    let tracks: DeezerAlbumTracksDataResponse?
}

// DeezerAlbumTracksDataResponse representation
private struct DeezerAlbumTracksDataResponse: Codable {
    // Data
    let data: [DeezerAlbumTrackItemResult]
}

// DeezerAlbumTrackItemResult representation
private struct DeezerAlbumTrackItemResult: Codable {
    // Unique identifier
    let id: Int
    // Display title
    let title: String?
    // Duration in seconds
    let duration: Int?
    // Track position
    let track_position: Int?
    // Disk number
    let disk_number: Int?
    // Preview
    let preview: String?
    // Explicit lyrics
    let explicit_lyrics: Bool?
    // Primary artist name
    let artist: DeezerArtistItemResult?
}

// DeezerFullTrackDetailsResponse representation
private struct DeezerFullTrackDetailsResponse: Codable {
    // Unique identifier
    let id: Int
    // Display title
    let title: String?
    // Release date
    let release_date: String?
    // Duration in seconds
    let duration: Int?
    // Bpm
    let bpm: Int?
    // Track position
    let track_position: Int?
    // Disk number
    let disk_number: Int?
    // Preview
    let preview: String?
    // Explicit lyrics
    let explicit_lyrics: Bool?
    // Composer
    let composer: String?
    // Primary artist name
    let artist: DeezerArtistItemResult?
    // Album title
    let album: DeezerAlbumDetailedResult?
    // Contributors
    let contributors: [DeezerContributorItemResult]?
    // Genres
    let genres: DeezerGenresListResponse?
}

// DeezerAlbumDetailedResult representation
private struct DeezerAlbumDetailedResult: Codable {
    // Unique identifier
    let id: Int?
    // Display title
    let title: String?
    // Release date
    let release_date: String?
    // Cover xl
    let cover_xl: String?
    // Label
    let label: String?
    // Nb tracks
    let nb_tracks: Int?
}

// DeezerContributorItemResult representation
private struct DeezerContributorItemResult: Codable {
    // Unique identifier
    let id: Int?
    // Name
    let name: String?
    // Role
    let role: String?
}

// DeezerGenresListResponse representation
private struct DeezerGenresListResponse: Codable {
    // Data
    let data: [DeezerGenreItemResponse]?
}

// DeezerGenreItemResponse representation
private struct DeezerGenreItemResponse: Codable {
    // Unique identifier
    let id: Int?
    // Name
    let name: String?
}
