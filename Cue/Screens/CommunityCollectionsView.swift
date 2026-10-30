import SwiftUI
import UIKit

/// One ready-made, individually-installable category — a single stable TMDB
/// network/company/discover source. Picked independently ("Install" is
/// per-category, not per-group), but installs as a FOLDER inside its group's
/// shared collection (Streaming Services / Major Studios / Trending & Top
/// Rated) rather than its own standalone collection. That grouping matches
/// the real Cue Android app, which renders exactly one Home row per
/// collection with no way to merge several into one row — so a shared group
/// collection is what makes Home look the same (folder tabs within one row)
/// on both platforms, instead of a separate row per category on Android. No
/// search, no manifest URL, no setup: covers are the services'/studios' own
/// official TMDB logos, fetched live so they're always current.
struct CommunityCollectionPreset: Identifiable {
    /// Section this category is grouped under while browsing — AND the group
    /// collection it installs into (see `groupCollectionID`).
    enum Group: String, CaseIterable {
        case streaming = "Streaming Services"
        case studios = "Major Studios"
        case trending = "Trending & Top Rated"

        var subtitle: String {
            switch self {
            case .streaming: return "Pick exactly the services you use — each becomes a tab in one Streaming Services row"
            case .studios: return "Every film from the studio, direct from TMDB — pick the ones you care about"
            case .trending: return "What's popular, best-reviewed, and newest right now"
            }
        }
        var icon: String {
            switch self {
            case .streaming: return "sparkles.tv.fill"
            case .studios: return "film.stack.fill"
            case .trending: return "flame.fill"
            }
        }
    }
    /// What kind of source this is — drives both the marker chips and the
    /// fallback art (an emoji tint) when there's no TMDB brand logo to fetch.
    enum Kind {
        case network, studio, trending, topRated, newest

        var markerLabel: String {
            switch self {
            case .network: return "Streaming Network"
            case .studio: return "Studio"
            case .trending: return "Trending"
            case .topRated: return "Top Rated"
            case .newest: return "Newest"
            }
        }
        /// Fallback emoji cover for sources with no brand logo (DISCOVER-type).
        var emoji: String? {
            switch self {
            case .trending: return "🔥"
            case .topRated: return "⭐️"
            case .newest: return "✨"
            case .network, .studio: return nil   // these get a real fetched logo
            }
        }
    }

    let id: String
    let group: Group
    let kind: Kind
    let title: String
    /// Usually one source; a streaming service with a watch-provider override
    /// gets TWO (movie + tv) since that filter — unlike TMDB's network-only
    /// with_networks filter — works for both, so those categories can finally
    /// show movies too, not just shows.
    let sources: [CollectionSourceDTO]

    /// A single representative source for logo/id lookups — every source in
    /// a multi-source preset shares the same tmdbId/tmdbSourceType, they only
    /// differ in mediaType.
    var primarySource: CollectionSourceDTO { sources[0] }

    var mediaLabel: String {
        let hasMovie = sources.contains { ($0.mediaType ?? "movie").lowercased() != "tv" }
        let hasTV = sources.contains { ($0.mediaType ?? "movie").lowercased() == "tv" }
        if hasMovie && hasTV { return "Movies & Shows" }
        return hasTV ? "TV Shows" : "Movies"
    }
}

enum CommunityCollections {
    /// Stable id prefix so an installed community category can be recognized
    /// (and not duplicated) even after a rename.
    static let idPrefix = "community."

    /// Per-category cover style: "Dark" sits a logo on a tinted-dark tile
    /// (matches the app's near-black surfaces); "Bright" sits it on a
    /// near-white tile instead, which is how most streaming/studio logos are
    /// actually designed to be seen and reads much closer to their real
    /// brand color. Chosen independently per category (id → isBright), one
    /// shared UserDefaults key holding the whole map as JSON, so every view
    /// that renders a community folder — the browse picker AND the
    /// installed Home rows — reads the same live choice for that category.
    static let coverStyleKey = "cue.communitycoverstyle.v1"

    /// Memoized on the raw JSON string: every collection tile reads this map
    /// in its body, and the strips hold 100–200 folders — a fresh JSONDecoder
    /// per tile body was a per-scroll-frame allocation storm on the A8. The
    /// map only changes when someone flips a style in the community picker.
    private static let coverStyleLock = NSLock()
    private static var coverStyleMemo: (json: String, map: [String: Bool])?

    static func decodeCoverStyles(_ json: String) -> [String: Bool] {
        coverStyleLock.lock()
        if let memo = coverStyleMemo, memo.json == json {
            defer { coverStyleLock.unlock() }
            return memo.map
        }
        coverStyleLock.unlock()
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        coverStyleLock.lock()
        coverStyleMemo = (json, dict)
        coverStyleLock.unlock()
        return dict
    }

    static func encodeCoverStyles(_ styles: [String: Bool]) -> String {
        guard let data = try? JSONEncoder().encode(styles),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// `watchProviderID` (verified live against TMDB) switches the query from
    /// TMDB's `with_networks` (originals only, TV-only) to `with_watch_providers`
    /// (the platform's REAL streaming catalog including licensed content, and
    /// works for movies too) — checked per-service since it isn't always
    /// better (Apple TV+/FX/BBC's watch-provider data undercounts vs. their
    /// network data, so those stay network-only with no override).
    /// `traktNetwork` is the name Trakt's `networks=` filter knows the service
    /// by (verified live against `shows/popular`); nil for a service Trakt
    /// has no network for. It gives the category a Trakt side, so a viewer
    /// signed in to Trakt with no TMDB key still gets the shows — the
    /// resolver keeps preferring TMDB whenever it is connected.
    private static func network(_ slug: String, _ title: String, _ tmdbId: Int,
                                 watchProviderID: Int? = nil,
                                 traktNetwork: String? = nil) -> CommunityCollectionPreset {
        var filters: TmdbFiltersDTO?
        if let wpid = watchProviderID {
            filters = TmdbFiltersDTO(watchRegion: "US", withWatchProviders: String(wpid))
        }
        func makeSource(mediaType: String) -> CollectionSourceDTO {
            var s = CollectionSourceDTO(tmdbSourceType: "NETWORK", title: title, tmdbId: tmdbId, mediaType: mediaType)
            s.filters = filters
            return s
        }
        // A watch-provider override serves movies AND shows; network-only
        // (TMDB's with_networks) is TV-only, full stop — so those categories
        // only ever get the tv source, same as before.
        var sources = filters != nil ? [makeSource(mediaType: "movie"), makeSource(mediaType: "tv")]
                                     : [makeSource(mediaType: "tv")]
        if let traktNetwork {
            sources.append(CollectionSourceDTO(
                traktEndpoint: "shows/popular", traktQuery: "networks=" + traktQueryValue(traktNetwork),
                title: title, mediaType: "tv"
            ))
        }
        return CommunityCollectionPreset(
            id: idPrefix + "streaming." + slug, group: .streaming, kind: .network, title: title, sources: sources
        )
    }

    /// Percent-encode a filter value for a Trakt query ("Apple TV+" →
    /// "Apple%20TV%2B" — a bare "+" would read as a space).
    private static func traktQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    /// `extraCompanyIDs` combines several TMDB company records into one
    /// OR-matched query (verified live against TMDB) for franchises legally
    /// fragmented across multiple company entities — a single id badly
    /// undercounts those. Plain single-studio collections leave this empty.
    private static func studio(_ slug: String, _ title: String, _ tmdbId: Int,
                                extraCompanyIDs: [Int] = []) -> CommunityCollectionPreset {
        var source = CollectionSourceDTO(tmdbSourceType: "COMPANY", title: title, tmdbId: tmdbId, mediaType: "movie")
        if !extraCompanyIDs.isEmpty {
            let combined = ([tmdbId] + extraCompanyIDs).map(String.init).joined(separator: "|")
            source.filters = TmdbFiltersDTO(withCompanies: combined)
        }
        return CommunityCollectionPreset(
            id: idPrefix + "studio." + slug, group: .studios, kind: .studio, title: title, sources: [source]
        )
    }
    /// `minVoteCount` matters specifically for `sort_by=vote_average.desc`:
    /// verified live that without it, "Top Rated" is pure noise — obscure
    /// titles with a single 10/10 vote outrank The Shawshank Redemption.
    /// `recentDaysWindow` is for "Newest": plain release-date sorting
    /// surfaces unreleased 2029-2099 placeholder entries with zero votes, so
    /// this instead restricts to a rolling recent window (computed fresh at
    /// query time) and sorts by popularity within it. Trending needs neither.
    /// `traktEndpoint`/`traktQuery` give the category its Trakt side (see
    /// `network`): trending → `movies/trending`, top rated → `movies/popular`
    /// (Trakt's popular is rating-and-votes), newest → popular within the
    /// current year.
    private static func discover(_ slug: String, _ title: String, kind: CommunityCollectionPreset.Kind,
                                  mediaType: String, sortBy: String,
                                  minVoteCount: Int? = nil, recentDaysWindow: Int? = nil,
                                  traktEndpoint: String? = nil, traktQuery: String? = nil) -> CommunityCollectionPreset {
        var source = CollectionSourceDTO(tmdbSourceType: "DISCOVER", title: title, tmdbId: nil,
                                          mediaType: mediaType, sortBy: sortBy)
        if minVoteCount != nil || recentDaysWindow != nil {
            source.filters = TmdbFiltersDTO(voteCountGte: minVoteCount, recentDays: recentDaysWindow)
        }
        var sources = [source]
        if let traktEndpoint {
            sources.append(CollectionSourceDTO(traktEndpoint: traktEndpoint, traktQuery: traktQuery,
                                               title: title, mediaType: mediaType))
        }
        return CommunityCollectionPreset(
            id: idPrefix + "trending." + slug, group: .trending, kind: kind, title: title, sources: sources
        )
    }

    static let presets: [CommunityCollectionPreset] = [
        // MARK: Streaming Services — each its own installable category.
        // Every id below verified live against TMDB. `watchProviderID` set =
        // that service's watch-provider data is a meaningfully bigger, still-
        // accurate catalog than its network data (adds movies too, since
        // watch-provider isn't TV-only); left unset = the network id already
        // wins (Apple TV+ 238>221, FX 97>14, BBC 2644>9 — their watch-provider
        // data is oddly sparse and would make those categories WORSE).
        network("netflix", "Netflix", 213, watchProviderID: 8, traktNetwork: "Netflix"),              // 2798 -> 3426
        network("disneyplus", "Disney+", 2739, watchProviderID: 337, traktNetwork: "Disney+"),        //  472 ->  931
        network("max", "Max", 49, watchProviderID: 1899, traktNetwork: "Max"),                        //  378 -> 1798 (HBO Max)
        network("primevideo", "Prime Video", 1024, watchProviderID: 9, traktNetwork: "Prime Video"),  // 1455 -> 4907
        network("appletvplus", "Apple TV+", 2552, traktNetwork: "Apple TV+"),                        // network wins, no override
        network("hulu", "Hulu", 453, watchProviderID: 15, traktNetwork: "Hulu"),                      //  362 -> 1914
        network("paramountplus", "Paramount+", 4330, watchProviderID: 2303, traktNetwork: "Paramount+"), //  151 ->  712 (Premium tier)
        network("peacock", "Peacock", 3353, watchProviderID: 386, traktNetwork: "Peacock"),           //  206 -> 1079 (Premium tier)
        network("fx", "FX", 88, traktNetwork: "FX"),                                                 // network wins, no override
        network("amc", "AMC", 174, watchProviderID: 526, traktNetwork: "AMC"),                        //   80 ->  263 (AMC+ bundle)
        network("bbc", "BBC", 4, traktNetwork: "BBC One"),                                           // network wins, no override
        // Crunchyroll's network id is its ORIGINALS only (RWBY, ...) — TMDB
        // credits Crunchyroll's vast licensed anime catalog (One Piece,
        // Naruto, Jujutsu Kaisen, ...) to their original Japanese broadcast
        // networks, not to Crunchyroll. Watch-provider data (what's actually
        // streamable on Crunchyroll) is the only correct source here.
        network("crunchyroll", "Crunchyroll", 1112, watchProviderID: 283),   //   19 -> 1825

        // MARK: Major Studios — each its own installable category.
        // Marvel Studios (420) alone is MCU-only (~100 titles) and misses
        // classic/crossover Marvel films still legally credited elsewhere
        // (2002 Spider-Man, Into/Across the Spider-Verse, Logan, …). Combined
        // with its other TMDB company records: ~142 titles, verified live.
        studio("marvel", "Marvel Studios", 420, extraCompanyIDs: [19551, 7505, 108634, 160251]),
        studio("disney", "Walt Disney Pictures", 2),
        studio("pixar", "Pixar", 3),
        studio("lucasfilm", "Lucasfilm", 1),
        studio("warnerbros", "Warner Bros.", 174),
        studio("universal", "Universal Pictures", 33),
        studio("paramount", "Paramount Pictures", 4),
        studio("sony", "Sony Pictures", 34),
        studio("a24", "A24", 41077),
        // "DC Films" (128064) alone is only ~17 titles — a narrow, recent
        // production label. Combined with DC Entertainment (9993), the real
        // DC catalog (Batman, Joker, Aquaman, Justice League, Wonder Woman,
        // Shazam, Teen Titans, animated DC movies, …): ~69 titles, verified
        // live. (Adding Atlas Entertainment — co-produced several DC films —
        // was tried and rejected: it also makes many unrelated films, e.g.
        // Oppenheimer, Uncharted, so it pollutes rather than completes this.)
        studio("dcfilms", "DC Films", 128064, extraCompanyIDs: [9993]),
        studio("ghibli", "Studio Ghibli", 10342),
        studio("blumhouse", "Blumhouse", 3172),

        // MARK: Trending & Top Rated — each its own installable category.
        discover("moviesnow", "Trending Movies", kind: .trending, mediaType: "movie", sortBy: "popularity.desc",
                 traktEndpoint: "movies/trending"),
        discover("showsnow", "Trending Shows", kind: .trending, mediaType: "tv", sortBy: "popularity.desc",
                 traktEndpoint: "shows/trending"),
        // Verified live: sorting by vote_average with no vote-count floor is
        // pure noise (obscure titles with a single 10/10 vote outrank The
        // Shawshank Redemption). 1000 for movies / 800 for shows: clean,
        // recognizable results (Shawshank, Godfather, Schindler's List /
        // Breaking Bad, Arcane, Chernobyl) while still ~4900 / ~700 titles.
        discover("moviestop", "Top Rated Movies", kind: .topRated, mediaType: "movie",
                 sortBy: "vote_average.desc", minVoteCount: 1000, traktEndpoint: "movies/popular"),
        discover("showstop", "Top Rated Shows", kind: .topRated, mediaType: "tv",
                 sortBy: "vote_average.desc", minVoteCount: 800, traktEndpoint: "shows/popular"),
        // Verified live: plain primary_release_date.desc surfaced unreleased
        // 2029-2099 placeholder entries with zero votes (e.g. "Avatar 5",
        // "100 Years"), not watchable new releases. recentDaysWindow instead
        // restricts to the last 120 days (computed fresh at query time,
        // excludes anything not yet released) sorted by popularity within
        // that window — Toy Story 5, Supergirl, The Devil Wears Prada 2, etc.
        discover("newest", "Newest Releases", kind: .newest, mediaType: "movie",
                 sortBy: "popularity.desc", recentDaysWindow: 120,
                 traktEndpoint: "movies/popular", traktQuery: "years=$YEAR"),
    ]

    static func presets(in group: CommunityCollectionPreset.Group) -> [CommunityCollectionPreset] {
        presets.filter { $0.group == group }
    }

    static func groupCollectionID(for group: CommunityCollectionPreset.Group) -> String {
        switch group {
        case .streaming: return "community.streaming"
        case .studios: return "community.studios"
        case .trending: return "community.trending"
        }
    }

    /// Insert/replace a category's folder in its group's collection, creating
    /// that group collection on first use.
    @MainActor
    static func addFolder(_ folder: CueCollectionFolder, to group: CommunityCollectionPreset.Group,
                           collections: CollectionsStore) {
        let groupID = groupCollectionID(for: group)
        // The LIBRARY, not the visible subset: a group switched off (or with
        // every category hidden) is absent from the visible list, and the
        // install then appended a second copy of the group instead of adding
        // the category to it — which is why an install "didn't take".
        if var existing = collections.library.first(where: { $0.id == groupID }) {
            if let idx = existing.folders.firstIndex(where: { $0.id == folder.id }) {
                existing.folders[idx] = folder
            } else {
                existing.folders.append(folder)
            }
            collections.update(existing)
        } else {
            var newCollection = CueCollection(id: groupID, title: group.rawValue, folders: [folder])
            newCollection.focusGlowEnabled = true
            collections.add(newCollection)
        }
    }

    /// Declares the tileShape that actually matches a logo's real proportions.
    /// tvOS renders a folder cover with `.fill` (crop-to-cover); the real
    /// Cue Android app renders it with `ContentScale.FillBounds` (stretch to
    /// EXACTLY fill the declared shape's aspect ratio, no crop) — so a logo
    /// whose real aspect ratio doesn't match the declared shape gets visibly
    /// warped on Android and cropped on tvOS.
    static func measuredTileShape(for urlString: String) async -> String {
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data), image.size.height > 0 else { return "SQUARE" }
        let ratio = image.size.width / image.size.height
        return ratio >= 1.5 ? "LANDSCAPE" : "SQUARE"
    }

    /// One-time migration: an earlier build installed each category as its OWN
    /// standalone collection (its own Home row per category, and its own
    /// folder id — a random UUID). Fold any of those still around into their
    /// group's collection, normalizing the folder id to the stable preset id.
    @MainActor
    static func consolidateIndividualCollections(collections: CollectionsStore) {
        for preset in presets {
            guard let standalone = collections.library.first(where: { $0.id == preset.id }),
                  var folder = standalone.folders.first else { continue }
            collections.remove(id: preset.id)
            folder.id = preset.id
            addFolder(folder, to: preset.group, collections: collections)
        }
    }

    /// One-time fix for categories installed BEFORE a preset's TMDB source was
    /// corrected (e.g. Marvel/DC's single-company id was too narrow, or Top
    /// Rated/Newest had no quality filter). Already-installed folders keep
    /// whatever source they were given at install time, so without this
    /// they'd stay stuck on the old query even after the app fixes it.
    /// One-shot per REVISION: community folders are editable in Settings, and
    /// an unconditional per-launch rewrite silently reverted any source or
    /// filter the user had added to one. Bump the key when the presets change
    /// and every install picks the new sources up exactly once.
    private static let sourceResyncKey = "cue.community.sourceResync.v3-trakt"

    @MainActor
    static func resyncPresetSources(collections: CollectionsStore) {
        guard !UserDefaults.standard.bool(forKey: sourceResyncKey) else { return }
        UserDefaults.standard.set(true, forKey: sourceResyncKey)
        for preset in presets {
            for collection in collections.library where collection.id.hasPrefix(idPrefix) {
                guard let idx = collection.folders.firstIndex(where: { $0.id == preset.id }),
                      collection.folders[idx].sources != preset.sources else { continue }
                var updated = collection
                updated.folders[idx].sources = preset.sources
                collections.update(updated)
            }
        }
    }

    /// One-time fix for categories installed BEFORE tileShape was measured:
    /// every logo-covered folder was hardcoded "LANDSCAPE" regardless of its
    /// real proportions. Re-measures each already-installed community
    /// folder's actual logo and corrects its declared shape — and when a
    /// brand's installed logo is squarish (Warner Bros' shield), upgrades it
    /// to the brand's WIDE logo variant when TMDB hosts one, so the tile
    /// matches the rest of the landscape row.
    /// One-shot guard: the remeasure downloads EVERY installed community logo
    /// (to read its pixel size) and hits TMDB's images endpoint for each
    /// square one — repeating that on every launch forever is pure waste,
    /// especially for brands with no wide variant (Paramount, DC) that can
    /// never converge. Fresh installs pick the wide logo up front, so once
    /// this pass has run, launches skip it. Bump the key to re-run everywhere.
    private static let logoMigrationKey = "cue.community.logoMigration.v2"

    @MainActor
    static func remeasureInstalledLogos(collections: CollectionsStore) async {
        guard !UserDefaults.standard.bool(forKey: logoMigrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: logoMigrationKey) }
        // The LIBRARY, not the visible subset: a community pack switched off
        // account-wide is still installed and still needs its tiles re-measured,
        // and `update` writes the library copy anyway.
        for collection in collections.library where collection.id.hasPrefix(idPrefix) {
            var changed = false
            var updated = collection
            for i in updated.folders.indices {
                let folder = updated.folders[i]
                guard let cover = folder.coverImageUrl, !cover.isEmpty else { continue }
                var shape = await measuredTileShape(for: cover)
                if shape != "LANDSCAPE",
                   let preset = presets.first(where: { $0.id == folder.id }),
                   let tmdbId = preset.primarySource.tmdbId,
                   let wide = await TMDBService.brandWideLogo(
                       id: tmdbId,
                       isNetwork: preset.primarySource.tmdbSourceType?.uppercased() == "NETWORK"
                   ), wide != cover {
                    updated.folders[i].coverImageUrl = wide
                    shape = "LANDSCAPE"
                    changed = true
                }
                if updated.folders[i].tileShape != shape {
                    updated.folders[i].tileShape = shape
                    changed = true
                }
            }
            if changed { collections.update(updated) }
        }
    }

    /// Runs only local, cheap fixes that are safe to execute near launch.
    @MainActor
    static func runLaunchMigrations(collections: CollectionsStore) {
        consolidateIndividualCollections(collections: collections)
        resyncPresetSources(collections: collections)
    }

    /// Runs every one-time consolidation/fix pass. The logo pass can download
    /// every installed community logo and query TMDB, so keep it off the app
    /// launch path and run it only when this screen is opened.
    @MainActor
    static func runStartupMigrations(collections: CollectionsStore) async {
        runLaunchMigrations(collections: collections)
        await remeasureInstalledLogos(collections: collections)
    }
}

