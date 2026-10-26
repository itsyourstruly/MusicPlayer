#if DEBUG
import Foundation
import os

/// DEBUG-only launch self-check (plan §6): classifier precedence rows, normalizer idempotence, and index/query token parity.
/// Logs results with os.Logger (category "SelfCheck"). Not compiled into Release builds.
nonisolated enum SearchSelfCheck {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicPlayer", category: "SelfCheck")

    static func run() {
        var failures: [String] = []
        var checks = 0
        func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
            checks += 1
            if !ok { failures.append(what()) }
        }

        // MARK: Classifier rows
        let url = URL(fileURLWithPath: "/dev/null")
        func album(_ title: String, _ titles: [String], seconds: TimeInterval = 240) -> Album {
            Album(title: title, artist: "Self Check", tracks: titles.map {
                Track(title: $0, artist: "Self Check", album: title, duration: seconds, url: url)
            })
        }
        let tenTracks = (1...10).map { "Song \($0)" }
        func info(_ types: [String], version: String? = nil) -> ReleaseTypeInfo? {
            ReleaseTypeInfo.from(rawTypes: types, isCompilation: nil, version: version, source: "selfcheck")
        }
        let cases: [(String, Album, ReleaseTypeInfo?, DiscographySection)] = [
            ("row2 single type", album("Hit", tenTracks), info(["Single"]), .singlesAndEPs),
            ("row2 ep type", album("Short", tenTracks), info(["EP"]), .singlesAndEPs),
            ("row2 live secondary", album("Tour", tenTracks), info(["Album/Live"]), .alternates),
            ("row2 remix secondary", album("Mixes", tenTracks), info(["album", "remix"]), .alternates),
            ("row3 version", album("Record", tenTracks), info(["Album"], version: "Deluxe"), .alternates),
            ("row3 original version", album("Record", tenTracks), info(["Album"], version: "Original"), .albums),
            ("row2 album beats size", album("Tiny", ["A", "B"]), info(["Album"]), .albums),
            ("row2 album beats all-remix", album("Club", tenTracks.map { "\($0) (Remix)" }), info(["Album"]), .albums),
            ("row4a deluxe title", album("Record (Deluxe Edition)", tenTracks), nil, .alternates),
            ("row4a live title", album("Record [Live]", tenTracks), nil, .alternates),
            ("row4a bare word is not a qualifier", album("Live", tenTracks), nil, .albums),
            ("row4b single suffix", album("Hit - Single", tenTracks), nil, .singlesAndEPs),
            ("row4b ep suffix", album("Short - EP", tenTracks), nil, .singlesAndEPs),
            ("row5 all remix", album("Club", tenTracks.map { "\($0) (Remix)" }), nil, .alternates),
            ("row5 needs every track", album("Club", ["A (Remix)", "B"] + tenTracks), nil, .albums),
            ("row6 1-3 short", album("Drop", ["A", "B"], seconds: 200), nil, .singlesAndEPs),
            ("row6 4-6 short", album("Drop", ["A", "B", "C", "D"], seconds: 200), nil, .singlesAndEPs),
            ("row6 long stays album", album("Epic", ["A", "B", "C"], seconds: 600), nil, .albums),
            ("default album", album("Record", tenTracks), nil, .albums),
        ]
        for (name, a, i, want) in cases {
            let got = DiscographyClassifier.releaseSection(for: a, info: i)
            expect(got == want, "classifier \(name): got \(got) want \(want)")
        }

        // MARK: Name suffix helpers
        for t in ["Hit - Single", "Hit (Single)", "Hit [single]", "single", "Short - EP"] {
            expect(DiscographyClassifier.hasSingleOrEPSuffix(t), "hasSingleOrEPSuffix should match \(t)")
        }
        for t in ["Not a Single", "Lonesingle", "Epic", "Greatest Singles"] {
            expect(!DiscographyClassifier.hasSingleOrEPSuffix(t), "hasSingleOrEPSuffix should not match \(t)")
        }
        expect(DiscographyClassifier.hasSingleSuffix("Hit - Single"), "hasSingleSuffix should match Hit - Single")
        expect(!DiscographyClassifier.hasSingleSuffix("Short - EP"), "hasSingleSuffix must not match EPs")
        expect(DiscographyClassifier.releaseSection(for: album("Hit (Single)", tenTracks), info: nil) == .singlesAndEPs, "row4b (single) suffix")

        // MARK: Per-track alternate rule and Album partitions
        func track(_ title: String, alt: Bool? = nil) -> Track {
            Track(title: title, artist: "Self Check", album: "Mix", duration: 240, url: url, isAlternate: alt)
        }
        expect(DiscographyClassifier.isAlternateTrack(track("A (Remix)")), "isAlternateTrack remix")
        expect(DiscographyClassifier.isAlternateTrack(track("A (Live)")), "isAlternateTrack live")
        expect(!DiscographyClassifier.isAlternateTrack(track("A")), "isAlternateTrack plain")
        expect(!DiscographyClassifier.isAlternateTrack(track("A (Remix)", alt: false)), "isAlternateTrack explicit false wins")
        let mixed = album("Record", tenTracks + ["Song 1 (Remix)", "Song 2 (Remix)"])
        expect(mixed.mainTracks.count == 10 && mixed.alternateTracks.count == 2, "partition 10+2: got \(mixed.mainTracks.count)/\(mixed.alternateTracks.count)")
        let allRemix = album("Club", ["A (Remix)", "B (Remix)", "C (Remix)"])
        expect(allRemix.mainTracks.count == 3 && allRemix.alternateTracks.isEmpty, "partition all-remix stays unsplit")

        // MARK: Tag-writing single rule (single suffixes only, never EP)
        func online(_ album: String, title: String = "Song", total: Int? = nil) -> OnlineTrackMetadata {
            OnlineTrackMetadata(title: title, artist: "Self Check", album: album, totalTracks: total, sourceAPI: "selfcheck")
        }
        expect(MetadataDiff.isSingleRelease(online: online("Song - Single"), localAlbum: "Record", title: "Song"), "isSingleRelease online single suffix")
        expect(!MetadataDiff.isSingleRelease(online: online("Album", total: 12), localAlbum: "Record", title: "Song"), "isSingleRelease 12-track album")
        expect(MetadataDiff.isSingleRelease(online: online("Album", total: 2), localAlbum: "Record", title: "Song"), "isSingleRelease 2 tracks")
        expect(MetadataDiff.isSingleRelease(online: online("Album", total: 12), localAlbum: "Thing (single)", title: "Song"), "isSingleRelease local (single)")
        expect(!MetadataDiff.isSingleRelease(online: online("Short - EP", total: 5), localAlbum: "Record", title: "Song"), "isSingleRelease ignores EP")

        // MARK: Normalizer idempotence and index/query token parity
        let samples = [
            "Beyoncé", "AC/DC", "Jay-Z", "Guns N' Roses", "$uicideboy$", "R&B", "  Multiple   Spaces ",
            "ＦＵＬＬ　ＷＩＤＴＨ", "宇多田ヒカル", "Sigur Rós", "twenty one pilots", "21 Savage", "Ke$ha", "P!nk",
            "Mötley Crüe", "Love (Deluxe Edition) [Remastered]", "ภาษาไทย", "방탄소년단 노래", "Ольга", "Ελληνικά",
            "Florence + the Machine", "Rock n Roll", "Don’t Stop", "Café del Mar", "ゆず", "N.W.A",
        ]
        let noWords: (String) -> [String] = { _ in [] }
        for text in samples {
            let once = SearchNormalizer.normalize(text)
            expect(SearchNormalizer.normalize(once) == once, "normalize not idempotent: \(text) -> \(once) -> \(SearchNormalizer.normalize(once))")
            let folded = SearchNormalizer.fold(text)
            expect(SearchNormalizer.fold(folded) == folded, "fold not idempotent: \(text)")

            var units = Set<String>()
            for token in SearchNormalizer.canonicalTokens(text) {
                units.formUnion(SearchTokenIndex.indexUnits(for: token, wordTokenizer: noWords))
            }
            // Completed query (trailing space): every term's typed form must be an exact index unit.
            let parsed = SearchParsedQuery.parse(text + " ")
            for term in parsed.terms {
                let typed = term.alternatives.first ?? []
                let ok = term.alternatives.contains { alt in alt.allSatisfy { units.contains($0) } }
                expect(ok, "token parity: \(text) query term \(typed) not in index units \(units.sorted())")
            }
        }

        // MARK: Search ranking (plan §6, D1–D10)
        let U = SearchRanking.unit
        func key(_ id: String, section: DiscographySection = .albums, year: Int? = 2020, tracks: Int = 10,
                 named: Bool = false, bucket: Int = 3, final: Int = 1_000_000, alt: Bool = false) -> SearchReleaseKey {
            SearchReleaseKey(versionNamed: named, bucket: bucket, final: final, alternateTrack: alt,
                             section: section.rawValue, year: year, trackCount: tracks, albumID: id)
        }
        func order(_ keys: [SearchReleaseKey]) -> [String] { keys.sorted(by: SearchRanking.releaseOrder).map(\.albumID) }
        // 1. D3/D5: studio > single > EP-in-singles > alternates > featured; remix/live cuts after plain cuts.
        let t1 = order([
            key("Live", section: .alternates, alt: true), key("Collab", section: .featuredOn),
            key("Deluxe", section: .alternates), key("EP", section: .singlesAndEPs, year: 2021, tracks: 4),
            key("Remix", section: .singlesAndEPs, alt: true), key("Single", section: .singlesAndEPs, tracks: 1),
            key("Views")])
        expect(t1 == ["Views", "Single", "EP", "Deluxe", "Collab", "Remix", "Live"], "t1 D3 order: \(t1)")
        // 2. Typed version word wins.
        expect(order([key("Views"), key("Live", section: .alternates, named: true)]).first == "Live", "t2 version named wins")
        // 3. Better bucket beats section.
        expect(order([key("Views", bucket: 1), key("Single", section: .singlesAndEPs)]).first == "Single", "t3 bucket first")
        // 4. Final within 1% is a tie → section decides; beyond 1% → final decides.
        expect(order([key("S", section: .singlesAndEPs, final: 1_000_000), key("A", final: 995_000)]).first == "A", "t4 1% tie")
        expect(order([key("S", section: .singlesAndEPs, final: 1_000_000), key("A", final: 900_000)]).first == "S", "t4b beyond 1%")
        // 5. Earliest year, then fewest tracks, then ID.
        expect(order([key("B", year: 2019), key("A", year: 2015)]) == ["A", "B"], "t5 earliest year")
        expect(order([key("B", tracks: 12), key("A", tracks: 8)]) == ["A", "B"], "t5b fewer tracks")
        expect(order([key("B"), key("A")]) == ["A", "B"], "t5c album ID")
        // 6. D10: no-year (nil or 0) albums sort after dated ones.
        expect(order([key("N", year: nil), key("Z", year: 0), key("D", year: 2024)]) == ["D", "N", "Z"], "t6 D10 no-year last")
        // 7. D4: whole exact artist wins top hit.
        let h7 = [SearchRanking.HitCandidate(kind: .track, score: 3 * U + 999_000),
                  SearchRanking.HitCandidate(kind: .artist, score: 3 * U + 900_000, wholeExactArtist: true)]
        expect(SearchRanking.pickTopHit(h7) == 1, "t7 D4 exact artist")
        // 8. Partial artist never wins over a song/album.
        let h8 = [SearchRanking.HitCandidate(kind: .artist, score: 3 * U + 999_000),
                  SearchRanking.HitCandidate(kind: .album, score: 2 * U + 500_000)]
        expect(SearchRanking.pickTopHit(h8) == 1, "t8 partial artist loses")
        // 9. Artists only → best artist.
        expect(SearchRanking.pickTopHit([SearchRanking.HitCandidate(kind: .artist, score: 2 * U)]) == 0, "t9 artists only")
        // 10. Tie within 1% in same bucket → track > album.
        let h10 = [SearchRanking.HitCandidate(kind: .album, score: 3 * U + 1_000_000),
                   SearchRanking.HitCandidate(kind: .track, score: 3 * U + 995_000)]
        expect(SearchRanking.pickTopHit(h10) == 1, "t10 track wins tie")
        expect(SearchRanking.pickTopHit([]) == nil, "t10b empty")
        // 11. Artist + song detection (leading and trailing).
        expect(SearchRanking.artistSongRest(queryTokens: ["drake", "hotline"], artistTokens: ["drake"]) == ["hotline"], "t11 leading")
        expect(SearchRanking.artistSongRest(queryTokens: ["hotline", "drake"], artistTokens: ["drake"]) == ["hotline"], "t11b trailing")
        expect(SearchRanking.artistSongRest(queryTokens: ["drake"], artistTokens: ["drake"]) == nil, "t11c no rest")
        // 12. Title coverage with prefixes.
        expect(SearchRanking.titleCovers(["hot", "bl"], title: "Hotline Bling"), "t12 covers")
        expect(!SearchRanking.titleCovers(["views"], title: "Hotline Bling"), "t12b not covered")
        // 13. Near-tie rule only in fuzzy buckets.
        expect(SearchRanking.isNearTie(top: 1 * U + 500_000, runner: 1 * U + 450_000), "t13 fuzzy near tie")
        expect(!SearchRanking.isNearTie(top: 3 * U + 500_000, runner: 3 * U + 450_000), "t13b exact not tie")
        expect(!SearchRanking.isNearTie(top: 1 * U + 500_000, runner: nil), "t13c no runner")
        // 14. Version words in query.
        expect(SearchRanking.queryVersionWords("views live") == ["live"], "t14 version words")
        expect(SearchRanking.namesVersion(["live"], album: album("Views (Live)", ["A"]), track: nil), "t14b names version")
        // 15–16. 2-character minimum kept.
        expect(SearchNormalizer.meetsMinimumLength("ho"), "t15 two chars ok")
        expect(!SearchNormalizer.meetsMinimumLength("h"), "t16 one char blocked")
        // 17–20. §6b auto-expansion.
        typealias M = GlobalSearchModel
        let hA = SearchExpansionHint(artistID: "ar", albumID: "a1", suppress: false)
        let s17 = M.nextExpansion(prev: .init(), hint: hA, user: .init())
        expect(s17.expandedArtistIDs == ["ar"] && s17.expandedAlbumIDs == ["a1"], "t17 auto expands hint")
        expect(M.nextExpansion(prev: s17, hint: hA, user: .init()) == s17, "t18 same key no change")
        let hB = SearchExpansionHint(artistID: "ar", albumID: "a2", suppress: false)
        let s19 = M.nextExpansion(prev: s17, hint: hB, user: .init(expandedAlbumIDs: ["a1"]))
        expect(s19.expandedAlbumIDs == ["a1", "a2"], "t19 user-opened album kept: \(s19.expandedAlbumIDs)")
        let s19b = M.nextExpansion(prev: s17, hint: hB, user: .init())
        expect(s19b.expandedAlbumIDs == ["a2"], "t19b old auto album closed")
        let s20 = M.nextExpansion(prev: .init(), hint: hA, user: .init(collapsedAlbumIDs: ["a1"]))
        expect(s20.expandedAlbumIDs.isEmpty, "t20 user-collapsed not reopened")
        let s20b = M.nextExpansion(prev: s17, hint: SearchExpansionHint(artistID: "x", albumID: "y", suppress: true), user: .init())
        expect(s20b == s17, "t20b suppress keeps state")
        // 21. D9: a guest's track on another lead's album counts as Featured On for the guest.
        let feat = Album(title: "Lead Record", artist: "Lead", tracks: [
            Track(title: "Song (feat. Guest)", artist: "Lead", album: "Lead Record", duration: 200, url: url)])
        expect(feat.isFeaturedAlbum(for: "Guest") && !feat.isFeaturedAlbum(for: "Lead"), "t21 D9 featured album")

        // 22–24. D11 section headers.
        let L = SearchSectionLayout.self
        let one = L.layout([("ALBUMS", [String]()), ("SINGLES & EPS", ["s2", "s1"]), ("ALTERNATES", []), ("FEATURED ON", [])],
                           topAlbumID: "s2", id: { $0 })
        expect(one.count == 1 && one[0].0 == nil, "t22 single section has no header")
        expect(one.first?.1 == ["s2", "s1"], "t23 ranked order kept in plain list")
        let groups = [("ALBUMS", ["a1"]), ("SINGLES & EPS", ["s1", "s2"]), ("ALTERNATES", ["x1"]), ("FEATURED ON", ["f1"])]
        let artistView = L.layout(groups, topAlbumID: nil, id: { $0 })
        expect(artistView.map(\.0) == ["ALBUMS", "SINGLES & EPS", "ALTERNATES", "FEATURED ON"], "t24 mixed: headers, standard order")
        expect(artistView[1].1 == ["s1", "s2"], "t24b ranked order within section")
        // 25–27. D12 top-match section first.
        expect(L.topMatchSectionFirst, "t25 D12 default on")
        let songView = L.layout(groups, topAlbumID: "x1", id: { $0 })
        expect(songView.map(\.0) == ["ALTERNATES", "ALBUMS", "SINGLES & EPS", "FEATURED ON"], "t26 top section first, rest standard")
        let off = L.layout(groups, topAlbumID: "x1", id: { $0 }, topMatchFirst: false)
        expect(off.map(\.0) == ["ALBUMS", "SINGLES & EPS", "ALTERNATES", "FEATURED ON"], "t27 switch off = standard order")
        expect(SearchExpansionHint(artistID: "a", albumID: "b", suppress: false).isSongOrAlbumHit == false, "t27b artist hint keeps standard order")

        // 28. 'LV Bag' bug: a single whose title equals the track, credited "Lead & Guest", by an artist with many
        // albums, must resolve to the lead (so the song top hit builds the matched-only view), and rank first.
        let lvTrack = Track(title: "Hit Song", artist: "Lead Star & Guest", album: "Hit Song", duration: 200, url: url)
        let lvSingle = Album(title: "Hit Song", artist: "Lead Star", tracks: [lvTrack])
        let catalog = (1...6).map { album("Record \($0)", tenTracks) } + [lvSingle]
        let lead = Artist(name: "Lead Star", albums: catalog)
        let index = [ArtistParser.canonicalArtistKey("Lead Star"): lead]
        let resolved = SearchEngine.resolveCreditedArtist(
            credit: lvTrack.artist, title: lvTrack.title,
            holds: { $0.albums.contains { $0.tracks.contains { $0.id == lvTrack.id } } },
            artistLookupIndex: index, lookup: SearchAlbumLookup(generation: 0))
        expect(resolved?.name == "Lead Star", "t28 combined credit resolves to library artist")
        let lvOrder = order([key("R1", year: 2018), key(lvSingle.id, section: .singlesAndEPs, tracks: 1, bucket: 3, final: 1_000_000),
                             key("R2", bucket: 1, final: 300_000)])
        expect(lvOrder.first == lvSingle.id, "t28b matched single ranks above unmatched albums")
        let one28 = L.layout([("ALBUMS", [String]()), ("SINGLES & EPS", [lvSingle.id])], topAlbumID: lvSingle.id, id: { $0 })
        expect(one28.count == 1 && one28[0].0 == nil, "t28c single match = one plain list (D11)")

        // 29–33. D13: matches nest under their artist; bottom list only for unresolvable songs.
        func tn(_ t: Track) -> SearchTreeTrackNode { SearchTreeTrackNode(id: t.id.uuidString, track: t, isDirectlyMatched: true, relevanceScore: 1) }
        let otherTrack = Track(title: "Hit Song", artist: "Other Band feat. Someone", album: "Deep Cut", duration: 180, url: url)
        let other = Artist(name: "Other Band", albums: [Album(title: "Deep Cut", artist: "Other Band", tracks: [otherTrack])])
        let index2 = index.merging([ArtistParser.canonicalArtistKey("Other Band"): other]) { a, _ in a }
        let lk = SearchAlbumLookup(generation: 0)
        expect(SearchEngine.unresolvedTracks([tn(lvTrack), tn(otherTrack)], artistLookupIndex: index2, lookup: lk).isEmpty,
               "t29 other-artist matches nest under their artist / t31 no bottom list when all resolve")
        expect(SearchEngine.expandScope(matchedAlbums: 0, matchedTracks: 1) == .matchedOnly
               && SearchEngine.expandScope(matchedAlbums: 1, matchedTracks: 0) == .matchedOnly, "t30 non-top expand = matches only")
        let orphan = Track(title: "Hit Song", artist: "Nobody Known", album: "Loose", duration: 100, url: url)
        let loose = SearchEngine.unresolvedTracks([tn(lvTrack), tn(orphan)], artistLookupIndex: index2, lookup: lk)
        expect(loose.map(\.track.id) == [orphan.id], "t32 bottom list holds only unresolvable songs")
        let ranked = (0..<60).map { Artist(name: "Artist \($0)") }
        let tree = SearchEngine.treeArtists(ranked, cap: 50, trackOwnerIDs: [ranked[55].id])
        expect(tree.count == 51 && tree.last?.id == ranked[55].id, "t33 song past the 50 cap nests under its artist")

        if failures.isEmpty {
            log.debug("Self-check passed (\(checks) checks).")
        } else {
            for f in failures { log.error("Self-check FAILED: \(f, privacy: .public)") }
            log.error("Self-check: \(failures.count)/\(checks) checks failed.")
        }
    }
}
#endif
