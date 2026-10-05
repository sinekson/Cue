import Foundation

/// Resolves a collection folder's TMDB / Trakt sources into `MetaItem`s. Shared
/// by the collection BROWSE page (full depth) and HOME rows (first TMDB page
/// only, via `maxTmdbPages`, so rendering a Rows/Combined collection doesn't
/// fire hundreds of TMDB requests per folder on every load).
///
/// Categories are a TMDB/Trakt feature. Add-on catalog sources are NOT resolved
/// in a folder that has any TMDB or Trakt source: a folder pointing at an
/// installed add-on's catalog used to fill itself with no TMDB key at all,
/// which made "categories" look like they worked while every TMDB-backed folder
/// sat empty. Those folders' addon rows are left in storage untouched (so a
/// folder authored on the phone round-trips unchanged) and resolve to nothing.
///
/// The one exception is a folder with NO TMDB or Trakt source at all, which
/// resolves its add-on catalogs through the installed add-on that serves them.
/// A pack built elsewhere out of an add-on's own catalogs is made entirely of
/// such folders — an Xperience export, for one, is nothing but
/// `catalogSources` naming the Xperience add-on — and every one of them opened
/// on "add TMDB or Trakt sources" however TMDB was set up. There is no TMDB
/// source in them for an add-on catalog to hide, and
/// `blocker(for:providers:addons:)` still says when the add-on is missing.
/// The services a collection can draw on right now.
///
/// Apart from those add-on-only folders, collections are built out of TMDB and
/// Trakt sources, so with neither connected there is nothing for one to
/// resolve — every folder would open empty. `any` is the switch the whole
/// feature hangs off.
struct CollectionProviders: Equatable {
    /// TMDB has the viewer's API key and is switched on.
    let tmdb: Bool
    /// The viewer is signed in to Trakt.
    let trakt: Bool

    var any: Bool { tmdb || trakt }

    /// TMDB is the one to recommend and the one to prefer when both are live:
    /// it resolves every source type collections can hold (lists, collections,
    /// companies, networks, people, discover queries), and it returns artwork,
    /// descriptions and ids directly. A Trakt list carries titles and ids only
    /// — its posters have to be borrowed from a meta add-on, one lookup per
    /// title, for the first thirty entries and no further.
    var preferredName: String? { tmdb ? "TMDB" : (trakt ? "Trakt" : nil) }

    static let none = CollectionProviders(tmdb: false, trakt: false)
}

enum CollectionResolver {

    /// Why a folder can't fill itself, if it can't.
    ///
    /// This is asked per FOLDER and only when the folder has nothing that can
    /// resolve. A folder holding both a TMDB source and a Trakt list is NOT
    /// blocked when only TMDB is connected — it just quietly uses TMDB, which
    /// is the whole point of favouring TMDB. Reporting "sign in to Trakt"
    /// there (or worse, across the whole collection because one folder
    /// somewhere had a Trakt list) was noise about a source the folder didn't
    /// need.
    enum FolderBlocker: Equatable {
        /// Something in this folder can resolve.
        case none
        case needsTMDB
        case needsTrakt
        /// Has both kinds, and neither service is connected.
        case needsEither
        /// Add-on catalogs only, and none of their add-ons is installed and
        /// switched on on this profile.
        case needsAddon
        /// No TMDB, Trakt or add-on source this app can resolve.
        case unsupportedSources
        /// The folder has no sources at all.
        case empty
    }

    static func blocker(for folder: CueCollectionFolder,
                        providers: CollectionProviders,
                        addons: [InstalledAddon]) -> FolderBlocker {
        let sources = folder.effectiveSources
        guard !sources.isEmpty else { return .empty }
        let tmdb = sources.contains(where: \.isTMDBSource)
        let trakt = sources.contains(where: \.isUsableTraktSource)
        // Anything at all that can run right now means the folder is fine.
        if (tmdb && providers.tmdb) || (trakt && providers.trakt) { return .none }
        if tmdb && trakt { return .needsEither }
        if tmdb { return .needsTMDB }
        if trakt { return .needsTrakt }
        // No TMDB or Trakt source at all: an add-on-only folder, which fills
        // itself from whichever of its catalogs an installed add-on serves.
        if folder.addonSources.contains(where: { addonCatalog(for: $0, addons: addons) != nil }) {
            return .none
        }
        if !folder.addonSources.isEmpty { return .needsAddon }
        return .unsupportedSources
    }

    /// One add-on catalog a folder can fetch: the add-on that serves it, that
    /// add-on's manifest entry for it, and the source's genre filter.
    struct AddonCatalog {
        let addon: InstalledAddon
        let catalog: ManifestCatalog
        let genre: String?
    }

    /// The catalog an add-on source names, if an installed, switched-on add-on
    /// on this profile serves it — the add-on matched by manifest id, the
    /// catalog by type and id within that manifest.
    ///
    /// Deliberately NOT filtered on `requiresExtra`, which only decides what
    /// can stand as a plain Home row: Xperience marks every one of its catalogs'
    /// genre as required (which keeps them off Stremio boards) and still
    /// answers the bare catalog URL with the full list.
    ///
    /// A catalog the manifest doesn't list is asked for all the same: a
    /// configurable add-on's manifest lists only the catalogs picked as Home
    /// rows (Xperience: 19 of its hundreds), yet it serves every one of them
    /// — and a collection pack names those. Nuvio's apps ask the same way.
    static func addonCatalog(for source: CollectionSourceDTO,
                             addons: [InstalledAddon]) -> AddonCatalog? {
        guard source.isAddonSource,
              let addonID = source.addonId,
              let type = source.type,
              let catalogID = source.catalogId,
              let addon = addons.first(where: { $0.enabled && $0.manifest.id == addonID })
        else { return nil }
        let catalog = (addon.manifest.catalogs ?? []).first(where: { $0.type == type && $0.id == catalogID })
            ?? ManifestCatalog(type: type, id: catalogID, name: source.title, extra: nil,
                               extraRequired: nil, extraSupported: nil)
        return AddonCatalog(addon: addon, catalog: catalog, genre: source.genre)
    }

    /// Resolve ONE folder's items, de-duplicated by id (TMDB, then Trakt, then
    /// add-on catalogs). Returns empty when the folder has nothing resolvable.
    static func resolveFolder(
        _ folder: CueCollectionFolder,
        addonManager: AddonManager,
        /// The installed add-ons an add-on-only folder resolves through.
        addons: [InstalledAddon],
        providers: CollectionProviders,
        tmdbLanguage: String,
        maxTmdbPages: Int = Int.max,
        /// First TMDB page of this window (see TMDBService.resolve). >1 means
        /// "continue a streaming load", so addon/Trakt sources — which aren't
        /// paged — are skipped to avoid re-returning what earlier windows
        /// already delivered.
        tmdbStartPage: Int = 1
    ) async -> [MetaItem] {
        // Only a CONNECTED service resolves, and TMDB wins OUTRIGHT: when TMDB
        // can serve this folder, its Trakt sources aren't consulted at all —
        // TMDB returns artwork, descriptions and resolved ids directly, while
        // a Trakt list needs a per-title meta lookup just to get posters.
        // Trakt resolves only when it is the folder's sole workable service
        // (TMDB disconnected, or a Trakt-only folder).
        let resolvableTmdb = providers.tmdb ? folder.effectiveSources.filter(\.isTMDBSource) : []
        let traktSources = (providers.trakt && resolvableTmdb.isEmpty)
            ? folder.effectiveSources.filter(\.isUsableTraktSource) : []
        // Add-on catalogs only ever fill a folder with no TMDB or Trakt source
        // at all (see the note at the top of this file), so every folder TMDB
        // or Trakt could resolve before resolves exactly as it did.
        let isAddonOnly = !folder.effectiveSources.contains(where: \.isTMDBSource)
            && !folder.effectiveSources.contains(where: \.isUsableTraktSource)
        let addonCatalogs = isAddonOnly
            ? folder.addonSources.compactMap { addonCatalog(for: $0, addons: addons) } : []
        guard !resolvableTmdb.isEmpty || !traktSources.isEmpty || !addonCatalogs.isEmpty else { return [] }

        let isContinuation = tmdbStartPage > 1

        // Every source in the folder is fetched CONCURRENTLY. They used to run
        // one after another — each TMDB source, then each Trakt list, every one
        // a full network round-trip — so a folder built from four sources took
        // four round-trips end to end even though none of them depends on the
        // others. Folders were already parallel; the wait was inside each one.
        //
        // Order is preserved by INDEX, not by arrival: the merge below still
        // goes TMDB → Trakt → add-on, in each group's own source order, so the
        // de-duplication keeps giving the same winner it always did (first
        // source to claim an id owns it). Concurrency changes when things
        // arrive, never what the folder resolves to.
        func gather(_ count: Int,
                    _ body: @escaping @Sendable (Int) async -> [MetaItem]) async -> [[MetaItem]] {
            guard count > 0 else { return [] }
            var out = [[MetaItem]](repeating: [], count: count)
            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                for i in 0..<count { group.addTask { (i, await body(i)) } }
                for await (i, items) in group { out[i] = items }
            }
            return out
        }

        async let tmdbResults: [[MetaItem]] = gather(resolvableTmdb.count) { i in
            await TMDBService.resolve(source: resolvableTmdb[i], language: tmdbLanguage,
                                      maxPages: maxTmdbPages, startPage: tmdbStartPage)
        }
        async let traktResults: [[MetaItem]] = isContinuation ? [] : gather(traktSources.count) { i in
            await resolveTrakt(source: traktSources[i], addonManager: addonManager)
        }
        async let addonResults: [[MetaItem]] = isContinuation ? [] : gather(addonCatalogs.count) { i in
            let source = addonCatalogs[i]
            return (try? await StremioAPI.catalog(addon: source.addon, catalog: source.catalog,
                                                  genre: source.genre)) ?? []
        }

        var items: [MetaItem] = []
        var seen = Set<String>()
        for batch in await tmdbResults + traktResults + addonResults {
            for item in batch where seen.insert(item.id).inserted { items.append(item) }
        }
        return items
    }

    /// One of a folder's catalogs, resolved: its name and titles.
    struct FolderCatalog: Identifiable, Sendable {
        let id: String
        let title: String
        let items: [MetaItem]
    }

    /// A folder's catalogs EACH ON ITS OWN, in the folder's order — what
    /// the folder page shows as rows or tabs (`resolveFolder` merges them).
    /// The same rules for which sources resolve; empty ones are left out.
    static func catalogs(
        of folder: CueCollectionFolder,
        addonManager: AddonManager,
        addons: [InstalledAddon],
        providers: CollectionProviders,
        tmdbLanguage: String,
        maxTmdbPages: Int = 2
    ) async -> [FolderCatalog] {
        let tmdbSources = providers.tmdb ? folder.effectiveSources.filter(\.isTMDBSource) : []
        let traktSources = (providers.trakt && tmdbSources.isEmpty)
            ? folder.effectiveSources.filter(\.isUsableTraktSource) : []
        let isAddonOnly = !folder.effectiveSources.contains(where: \.isTMDBSource)
            && !folder.effectiveSources.contains(where: \.isUsableTraktSource)
        let addonCatalogs = isAddonOnly
            ? folder.addonSources.compactMap { addonCatalog(for: $0, addons: addons) } : []

        /// A catalog's name: the source's own title, else the add-on's name
        /// for it, else its id made readable.
        func name(_ title: String?, fallback: String) -> String {
            if let title, !title.isEmpty { return title }
            return fallback.replacingOccurrences(of: "_", with: " ").capitalized
        }
        var jobs: [(String, @Sendable () async -> [MetaItem])] = []
        /// Packs often name every catalog of a folder after the folder
        /// ("Netflix", "Netflix", …): those get a name from the catalog's
        /// id instead (`streaming_netflix_top10_movies` → "Top 10 Movies").
        var ids: [String?] = []
        for source in tmdbSources {
            ids.append(nil)
            jobs.append((name(source.title, fallback: source.tmdbSourceType ?? "TMDB"), {
                await TMDBService.resolve(source: source, language: tmdbLanguage, maxPages: maxTmdbPages)
            }))
        }
        for source in traktSources {
            ids.append(nil)
            jobs.append((name(source.title, fallback: "Trakt"), {
                await resolveTrakt(source: source, addonManager: addonManager)
            }))
        }
        for entry in addonCatalogs {
            ids.append(entry.catalog.id)
            jobs.append((name(entry.catalog.name, fallback: entry.catalog.id), {
                (try? await StremioAPI.catalog(addon: entry.addon, catalog: entry.catalog, genre: entry.genre)) ?? []
            }))
        }
        // Side by side; kept in the folder's order.
        var results = [[MetaItem]](repeating: [], count: jobs.count)
        await withTaskGroup(of: (Int, [MetaItem]).self) { group in
            for (index, job) in jobs.enumerated() { group.addTask { (index, await job.1()) } }
            for await (index, items) in group { results[index] = items }
        }
        let names = jobs.map(\.0)
        func title(_ index: Int) -> String {
            let own = names[index]
            let unclear = own.caseInsensitiveCompare(folder.title) == .orderedSame
                || names.filter { $0.caseInsensitiveCompare(own) == .orderedSame }.count > 1
            guard unclear, let id = ids[index], let derived = readableName(id, folder: folder.title) else { return own }
            return derived
        }
        return jobs.indices.compactMap { index in
            results[index].isEmpty ? nil
                : FolderCatalog(id: "\(folder.id)#\(index)", title: title(index), items: results[index])
        }
    }

    /// A catalog id as a name: its words, without the pack's prefixes and
    /// the folder's own name ("snoak_latest_netflix_series" in Netflix →
    /// "Latest Series").
    static func readableName(_ id: String, folder: String) -> String? {
        let skip: Set<String> = ["streaming", "snoak", "fp", "studio", "genre", "themed", "collection", "discover"]
        let folderWords = Set(folder.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let words: [String: String] = ["top10": "Top 10", "toprated": "Top Rated", "tv": "TV", "mcu": "MCU",
                                       "dc": "DC", "dceu": "DCEU", "dcu": "DCU", "scifi": "Sci-Fi"]
        let parts = id.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).map(String.init)
            .filter { !skip.contains($0) && !folderWords.contains($0) }
        guard !parts.isEmpty else { return nil }
        return parts.map { words[$0] ?? $0.capitalized }.joined(separator: " ")
    }

    /// Trakt list items arrive with no artwork — enrich the first N via the
    /// installed meta add-on (Cinemeta) so the grid still has posters; the rest
    /// still display (title only) rather than being dropped.
    static func resolveTrakt(source: CollectionSourceDTO, addonManager: AddonManager) async -> [MetaItem] {
        let type = (source.mediaType ?? "movie").lowercased() == "tv" ? "show" : "movie"
        let raw: [TraktService.PublicListItem]
        if let endpoint = source.traktEndpoint {
            // A browse endpoint (the community categories' Trakt side).
            raw = await TraktService.endpointItems(path: endpoint, query: source.traktQuery, type: type)
        } else {
            guard let traktListId = source.traktListId else { return [] }
            let sortBy = source.sortBy ?? "rank"
            let sortHow = source.sortHow ?? "asc"
            raw = await TraktService.publicListItems(
                traktListId: traktListId, type: type, sortBy: sortBy, sortHow: sortHow
            )
        }
        // Flatten first: every entry gets its placeholder, and the first 30 get
        // upgraded in place if their meta lookup lands.
        struct Entry { let id: String; let type: String; let placeholder: MetaItem }
        let entries: [Entry] = raw.compactMap { item in
            let metaType = item.isMovie ? "movie" : "series"
            guard let id = item.imdb ?? item.tmdb.map({ "tmdb:\($0)" }) else { return nil }
            return Entry(id: id, type: metaType, placeholder: MetaItem(
                id: id, type: metaType, name: item.title,
                releaseInfo: item.year.map(String.init)
            ))
        }
        guard !entries.isEmpty else { return [] }

        // Resolve the meta add-on ONCE per type rather than per item. It is a
        // main-actor lookup, so doing it inside the loop cost thirty hops onto
        // the main thread — while the main thread is drawing the grid.
        var addonByType: [String: InstalledAddon] = [:]
        for type in Set(entries.prefix(30).map(\.type)) {
            if let first = entries.first(where: { $0.type == type }),
               let addon = await addonManager.metaAddon(for: type, id: first.id) {
                addonByType[type] = addon
            }
        }

        // The enrichment is what made a Trakt list slow: thirty meta fetches,
        // strictly one after another, before a single poster appeared. They are
        // independent lookups — run them together, bounded so a list doesn't
        // open thirty sockets at once.
        let enrichCount = min(entries.count, 30)
        var upgraded = [MetaItem?](repeating: nil, count: enrichCount)
        await withTaskGroup(of: (Int, MetaItem?).self) { group in
            let window = min(8, enrichCount)
            var next = 0
            func start() {
                guard next < enrichCount else { return }
                let i = next
                next += 1
                let entry = entries[i]
                let addon = addonByType[entry.type]
                group.addTask {
                    guard let addon else { return (i, nil) }
                    return (i, try? await StremioAPI.meta(addon: addon, type: entry.type, id: entry.id))
                }
            }
            for _ in 0..<window { start() }
            for await (i, meta) in group {
                start()
                upgraded[i] = meta
            }
        }

        return entries.enumerated().map { index, entry in
            (index < enrichCount ? upgraded[index] : nil) ?? entry.placeholder
        }
    }
}
