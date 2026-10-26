import Foundation

/// Builds media-server albums and artists exactly as each server organizes them (server album identity,
/// server album-artist credits, server "appears on" credits) and merges them with the local library:
/// the same artist across sources becomes one artist, the same album (same album artists + title) one album.
/// Nothing is hidden here; duplicate-copy hiding happens in `LibraryViewBuilder` for the current source selection.
nonisolated enum ServerLibraryGrouper {

    struct Output {
        let albums: [Album]
        let artists: [Artist]
        let lookup: [String: Artist]
    }

    /// One album as one server presents it.
    private struct Unit {
        let sourceKey: String
        let serverAlbumID: String
        let title: String
        let displayArtist: String
        var artistKeys: [String] = []
        var artistNames: [String: String] = [:]
        var entityCandidates: [String: String] = [:]
        /// Album-artist name key -> source-scoped server artist id ("source:id"), when the server sent one.
        var artistIDs: [String: String] = [:]
        /// Track-artist entity name key -> source-scoped server artist id.
        var entityIDs: [String: String] = [:]
        var tracks: [Track] = []
    }

    /// Albums that share a merge key (one optional local album plus server units from distinct sources).
    private struct Group {
        let mergeKey: String
        var local: Album?
        var localKeys: [String] = []
        var localNames: [String: String] = [:]
        var units: [Unit] = []
        var sources: Set<String> = []
    }

    private struct ArtistAccumulator {
        var name: String
        /// True once the name comes from a server artist entity (server spelling wins over local variants).
        var hasServerName = false
        var base: Artist?
        var albums: [Album]
        var albumIndexByID: [String: Int]
        var tracks: [Track]
        var trackIDs: Set<UUID>?
        var changed: Bool

        init(base: Artist) {
            name = base.name
            self.base = base
            albums = base.albums
            albumIndexByID = Dictionary(base.albums.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            tracks = base.tracks
            trackIDs = nil
            changed = false
        }

        init(name: String) {
            self.name = name
            base = nil
            albums = []
            albumIndexByID = [:]
            tracks = []
            trackIDs = []
            changed = true
        }

        mutating func add(album: Album) {
            if let idx = albumIndexByID[album.id] {
                albums[idx] = album
            } else {
                albumIndexByID[album.id] = albums.count
                albums.append(album)
            }
            changed = true
        }

        mutating func add(tracks newTracks: [Track]) {
            if trackIDs == nil { trackIDs = Set(tracks.map(\.id)) }
            for track in newTracks where trackIDs!.insert(track.id).inserted {
                tracks.append(track)
                changed = true
            }
        }
    }

    static func sourceKey(of track: Track) -> String {
        track.folderID?.uuidString ?? "local"
    }

    /// Server artist ids are only unique within one server, so they are scoped by source.
    private static func scopedArtistID(_ id: String?, source: String) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return source + ":" + id
    }

    private static func mergeKey(artistKeys: [String], title: String) -> String {
        artistKeys.sorted().joined(separator: "\u{1F}") + "||" + ServerCredits.nameKey(title)
    }

    static func merge(
        localAlbums: [Album],
        localArtists: [Artist],
        localLookup: [String: Artist],
        serverTracks: [Track],
        serverOrder: [UUID],
        joinedArtists: [String]
    ) -> Output {
        guard !serverTracks.isEmpty else {
            return Output(albums: localAlbums, artists: localArtists, lookup: localLookup)
        }
        let catalogs = ServerCatalogStore.shared.snapshot()
        let orderedCatalogs: [ServerCatalog] = serverOrder.compactMap { catalogs[$0] }
            + catalogs.filter { !serverOrder.contains($0.key) }.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value)
        let orderIndex = Dictionary(serverOrder.enumerated().map { ($1.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Server album units: the server's album identity (album id), split only where the user edited album/album artist.
        var unitIndexByKey: [String: Int] = [:]
        var units: [Unit] = []
        for track in serverTracks {
            let source = sourceKey(of: track)
            let titleKey = ServerCredits.nameKey(track.album)
            let albumArtistNames = track.serverAlbumArtistNames
            var albumKey: String
            if let albumID = track.jellyfinAlbumId, !albumID.isEmpty {
                albumKey = albumID
                if let snapshot = track.tagSnapshot, ServerCredits.nameKey(snapshot.album) != titleKey {
                    albumKey += "|t:" + titleKey
                }
                if track.hasEditedServerAlbumArtist {
                    albumKey += "|a:" + albumArtistNames.map(ServerCredits.nameKey).joined(separator: ",")
                }
            } else {
                albumKey = "t:" + titleKey + "|a:" + albumArtistNames.map(ServerCredits.nameKey).joined(separator: ",")
            }
            let key = source + "#" + albumKey

            let index: Int
            if let existing = unitIndexByKey[key] {
                index = existing
            } else {
                let trimmedTitle = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
                let explicitAlbumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let display = !explicitAlbumArtist.isEmpty
                    ? explicitAlbumArtist
                    : (albumArtistNames.isEmpty ? track.artist : albumArtistNames.joined(separator: ", "))
                index = units.count
                unitIndexByKey[key] = index
                units.append(Unit(
                    sourceKey: source,
                    serverAlbumID: albumKey,
                    title: trimmedTitle.isEmpty ? "Unknown Album" : trimmedTitle,
                    displayArtist: display.isEmpty ? "Unknown Artist" : display
                ))
            }
            for ref in track.serverAlbumArtistRefs {
                let k = ServerCredits.nameKey(ref.name)
                guard !k.isEmpty else { continue }
                if units[index].artistIDs[k] == nil, let id = scopedArtistID(ref.id, source: source) {
                    units[index].artistIDs[k] = id
                }
                guard units[index].artistNames[k] == nil else { continue }
                units[index].artistNames[k] = ref.name
                units[index].artistKeys.append(k)
            }
            for ref in track.serverArtistEntityRefs {
                let k = ServerCredits.nameKey(ref.name)
                guard !k.isEmpty else { continue }
                if units[index].entityCandidates[k] == nil { units[index].entityCandidates[k] = ref.name }
                if units[index].entityIDs[k] == nil, let id = scopedArtistID(ref.id, source: source) {
                    units[index].entityIDs[k] = id
                }
            }
            units[index].tracks.append(track)
        }
        units.sort { lhs, rhs in
            let lo = orderIndex[lhs.sourceKey] ?? Int.max
            let ro = orderIndex[rhs.sourceKey] ?? Int.max
            if lo != ro { return lo < ro }
            if lhs.sourceKey != rhs.sourceKey { return lhs.sourceKey < rhs.sourceKey }
            return lhs.serverAlbumID < rhs.serverAlbumID
        }

        // 2. Local albums register first so a matching server album joins the existing local album (keeps its ID).
        var groups: [Group] = []
        groups.reserveCapacity(localAlbums.count + units.count)
        var groupIndexByKey: [String: Int] = [:]
        for album in localAlbums {
            var keys: [String] = []
            var names: [String: String] = [:]
            for part in ArtistParser.parseArtists(from: album.artist) {
                let k = ServerCredits.nameKey(part)
                guard !k.isEmpty, names[k] == nil else { continue }
                names[k] = part
                keys.append(k)
            }
            let key = mergeKey(artistKeys: keys, title: album.title)
            var group = Group(mergeKey: key, local: album, localKeys: keys, localNames: names)
            group.sources = Set(album.tracks.map(sourceKey(of:)))
            if groupIndexByKey[key] == nil { groupIndexByKey[key] = groups.count }
            groups.append(group)
        }

        // 3. Server units join a group from a different source; same-source collisions stay separate albums.
        for unit in units {
            let base = mergeKey(artistKeys: unit.artistKeys, title: unit.title)
            let year = unit.tracks.compactMap(\.year).first(where: { $0 > 0 }).map { "|y\($0)" } ?? "|y?"
            let candidates = [base, base + year, base + "|" + unit.sourceKey + "|" + unit.serverAlbumID]
            for candidate in candidates {
                if let gi = groupIndexByKey[candidate] {
                    guard !groups[gi].sources.contains(unit.sourceKey) else { continue }
                    groups[gi].units.append(unit)
                    groups[gi].sources.insert(unit.sourceKey)
                } else {
                    groupIndexByKey[candidate] = groups.count
                    var group = Group(mergeKey: candidate)
                    group.units = [unit]
                    group.sources = [unit.sourceKey]
                    groups.append(group)
                }
                break
            }
        }

        // 4. Build final albums.
        var finalAlbums: [Album] = []
        finalAlbums.reserveCapacity(groups.count)
        var replacedLocalAlbums: [String: Album] = [:]
        var serverAlbumEntries: [(album: Album, keys: [String], names: [String: String], ids: [String: String], units: [Unit])] = []
        for group in groups {
            guard !group.units.isEmpty else {
                if let local = group.local { finalAlbums.append(local) }
                continue
            }
            var keys = group.localKeys
            var names = group.localNames
            var entityNames: [String: String] = [:]
            var ids: [String: String] = [:]
            var albumArtistIDSet = Set<String>()
            for unit in group.units {
                for k in unit.artistKeys where names[k] == nil {
                    names[k] = unit.artistNames[k]
                    keys.append(k)
                }
                for (k, id) in unit.artistIDs where ids[k] == nil { ids[k] = id }
                albumArtistIDSet.formUnion(unit.artistIDs.values)
                for (k, name) in unit.entityCandidates where entityNames[k] == nil { entityNames[k] = name }
            }
            let keySet = Set(keys)
            // Featured = track-artist entities that are not album artists (compared by server id, then by name).
            var featured = Set<String>()
            for unit in group.units {
                for k in unit.entityCandidates.keys where !keySet.contains(k) {
                    if let id = unit.entityIDs[k], albumArtistIDSet.contains(id) { continue }
                    featured.insert(k)
                }
            }
            let unitTracks = group.units.flatMap(\.tracks)
            let first = group.units[0]
            let sortName = orderedCatalogs.lazy.compactMap { $0.albumSortNames[first.serverAlbumID.components(separatedBy: "|").first ?? ""] }.first

            let album: Album
            if let local = group.local {
                for track in local.tracks {
                    for name in ArtistParser.allArtists(forTitle: track.title, artist: track.artist, albumArtist: track.albumArtist) {
                        let k = ServerCredits.nameKey(name)
                        if !k.isEmpty, !keySet.contains(k) { featured.insert(k) }
                    }
                }
                album = Album(
                    title: local.title,
                    artist: local.artist,
                    year: local.year,
                    genre: local.genre ?? unitTracks.first?.genre,
                    artworkKey: local.artworkKey,
                    tracks: local.tracks + unitTracks,
                    groupKey: local.groupKey,
                    albumArtistKeys: keys,
                    featuredArtistKeys: featured.sorted(),
                    sortName: local.sortName ?? sortName
                )
                replacedLocalAlbums[local.id] = album
            } else {
                album = Album(
                    title: first.title,
                    artist: first.displayArtist,
                    year: unitTracks.compactMap(\.year).first(where: { $0 > 0 }),
                    genre: unitTracks.first?.genre,
                    artworkKey: first.tracks.compactMap(\.artworkKey).first(where: { !$0.isEmpty }),
                    tracks: unitTracks,
                    groupKey: "srv_" + group.mergeKey,
                    albumArtistKeys: keys,
                    featuredArtistKeys: featured.sorted(),
                    sortName: sortName
                )
            }
            finalAlbums.append(album)
            serverAlbumEntries.append((album, keys, names, ids, group.units))
        }

        // 5. Artists: local artists keep their instances unless they gain server content; server album artists are the entities.
        var accumulators: [ArtistAccumulator] = []
        accumulators.reserveCapacity(localArtists.count + serverAlbumEntries.count)
        var accIndexByKey: [String: Int] = [:]
        // Server artists are keyed by their server id; local and other-source spellings join through the canonical key.
        var accIndexByServerID: [String: Int] = [:]
        var accIndexByCanonical: [String: Int] = [:]
        func accumulatorIndex(key k: String, name: String, serverID: String?) -> Int? {
            if let serverID, let idx = accIndexByServerID[serverID] { return idx }
            if let idx = accIndexByKey[k] { return idx }
            return accIndexByCanonical[ArtistParser.canonicalArtistKey(name)]
        }
        for artist in localArtists {
            let k = ServerCredits.nameKey(artist.name)
            let canonical = ArtistParser.canonicalArtistKey(artist.name)
            if accIndexByCanonical[canonical] == nil, let idx = accIndexByKey[k] { accIndexByCanonical[canonical] = idx }
            if let idx = accIndexByKey[k] {
                for album in artist.albums { accumulators[idx].add(album: album) }
                accumulators[idx].add(tracks: artist.tracks)
            } else {
                accIndexByKey[k] = accumulators.count
                if accIndexByCanonical[canonical] == nil { accIndexByCanonical[canonical] = accumulators.count }
                var acc = ArtistAccumulator(base: artist)
                for album in artist.albums {
                    if let replaced = replacedLocalAlbums[album.id] { acc.add(album: replaced) }
                }
                accumulators.append(acc)
            }
        }
        for entry in serverAlbumEntries {
            let serverTracksOfAlbum = entry.units.flatMap(\.tracks)
            for k in entry.keys {
                let name = entry.names[k] ?? k
                let serverID = entry.ids[k]
                let idx: Int
                if let existing = accumulatorIndex(key: k, name: name, serverID: serverID) {
                    idx = existing
                    // The server's spelling of its artist entity names the merged artist (first server wins).
                    if serverID != nil, !accumulators[idx].hasServerName {
                        accumulators[idx].hasServerName = true
                        if accumulators[idx].name != name {
                            accumulators[idx].name = name
                            accumulators[idx].changed = true
                        }
                    }
                } else {
                    idx = accumulators.count
                    accumulators.append(ArtistAccumulator(name: name))
                    accumulators[idx].hasServerName = serverID != nil
                }
                if accIndexByKey[k] == nil { accIndexByKey[k] = idx }
                if let serverID, accIndexByServerID[serverID] == nil { accIndexByServerID[serverID] = idx }
                let canonical = ArtistParser.canonicalArtistKey(name)
                if accIndexByCanonical[canonical] == nil { accIndexByCanonical[canonical] = idx }
                accumulators[idx].add(album: entry.album)
                accumulators[idx].add(tracks: serverTracksOfAlbum)
            }
        }
        // "Appears on": only server track-artist entities that are already artists in the library.
        for entry in serverAlbumEntries {
            let keySet = Set(entry.keys)
            let albumArtistIDSet = Set(entry.ids.values)
            var albumArtistIndexes = Set<Int>()
            for k in entry.keys {
                if let idx = accumulatorIndex(key: k, name: entry.names[k] ?? k, serverID: entry.ids[k]) { albumArtistIndexes.insert(idx) }
            }
            var creditedTracks: [Int: [Track]] = [:]
            var creditedOrder: [Int] = []
            for unit in entry.units {
                for track in unit.tracks {
                    for ref in track.serverArtistEntityRefs {
                        let k = ServerCredits.nameKey(ref.name)
                        let serverID = scopedArtistID(ref.id, source: unit.sourceKey)
                        guard !k.isEmpty, !keySet.contains(k) else { continue }
                        if let serverID, albumArtistIDSet.contains(serverID) { continue }
                        guard let idx = accumulatorIndex(key: k, name: ref.name, serverID: serverID),
                              !albumArtistIndexes.contains(idx) else { continue }
                        if creditedTracks[idx] == nil { creditedOrder.append(idx) }
                        creditedTracks[idx, default: []].append(track)
                    }
                }
            }
            for idx in creditedOrder {
                accumulators[idx].add(album: entry.album)
                accumulators[idx].add(tracks: creditedTracks[idx] ?? [])
            }
        }

        var builtArtists: [Artist] = []
        builtArtists.reserveCapacity(accumulators.count)
        var changedIDs = Set<String>()
        for acc in accumulators {
            let k = ServerCredits.nameKey(acc.name)
            let sortName = acc.base?.sortName ?? orderedCatalogs.lazy.compactMap { $0.artistSortNames[k] }.first
            if let base = acc.base, !acc.changed, base.sortName == sortName {
                builtArtists.append(base)
            } else {
                let artist = Artist(name: acc.name, albums: acc.albums, tracks: acc.tracks, joinedArtists: joinedArtists, sortName: sortName)
                builtArtists.append(artist)
                changedIDs.insert(artist.id)
            }
        }

        // Two names that differ only by punctuation share an Artist.id; keep one entity so ID lookups stay unique.
        var finalArtists: [Artist] = []
        finalArtists.reserveCapacity(builtArtists.count)
        var artistIndexByID: [String: Int] = [:]
        for artist in builtArtists {
            if let existing = artistIndexByID[artist.id] {
                let kept = finalArtists[existing]
                var seenAlbums = Set(kept.albums.map(\.id))
                var seenTracks = Set(kept.tracks.map(\.id))
                let albums = kept.albums + artist.albums.filter { seenAlbums.insert($0.id).inserted }
                let tracks = kept.tracks + artist.tracks.filter { seenTracks.insert($0.id).inserted }
                finalArtists[existing] = kept.withContent(albums: albums, tracks: tracks, joinedArtists: joinedArtists)
                changedIDs.insert(artist.id)
            } else {
                artistIndexByID[artist.id] = finalArtists.count
                finalArtists.append(artist)
            }
        }
        finalArtists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        finalAlbums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // 6. Lookup index: keep local name-variant aliases, repointed at the final instances.
        var finalByID: [String: Artist] = [:]
        finalByID.reserveCapacity(finalArtists.count)
        for artist in finalArtists { finalByID[artist.id] = artist }
        var lookup = localLookup
        if !changedIDs.isEmpty {
            for (alias, artist) in lookup where changedIDs.contains(artist.id) {
                lookup[alias] = finalByID[artist.id] ?? artist
            }
        }
        for artist in finalArtists {
            lookup[artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = artist
            lookup[ArtistParser.canonicalArtistKey(artist.name)] = artist
            lookup[artist.id] = artist
        }

        return Output(albums: finalAlbums, artists: finalArtists, lookup: lookup)
    }
}
