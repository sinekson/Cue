import SwiftUI
import AVFoundation

struct HomeRow: Identifiable {
    let id: String
    let title: String
    let items: [MetaItem]
    /// Source catalog, so the row can navigate to a paginated "See All".
    var addon: InstalledAddon?
    var catalog: ManifestCatalog?

    /// This row's key in `HomeCatalogSettingsStore` terms, so a setting that
    /// NAMES a catalog can be matched back to the row it produced.
    ///
    /// Not `id`: that is built from `addon.id`, which is the manifest URL,
    /// while the settings keys use `manifest.id`. Two different strings for
    /// the same addon — matching one against the other would never hit.
    var catalogKey: String? {
        guard let addon, let catalog else { return nil }
        return HomeCatalogSettingsStore.catalogKey(
            addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
    }
}

private extension Sequence where Element == WatchedItem {
    func deduplicatedByContentID() -> [WatchedItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.contentID).inserted }
    }
}

/// A home screen row: either a catalog of posters or a collection of folders.
enum HomeEntry: Identifiable {
    case catalog(HomeRow)
    case collection(CueCollection)

    var id: String {
        switch self {
        case .catalog(let row): return row.id
        case .collection(let collection): return "collection|\(collection.id)"
        }
    }
}

/// Persists the last-rendered Home catalog rows (their items) to disk, keyed by
/// catalog key, so the screen paints instantly on a cold start and then
/// refreshes in the background (stale-while-revalidate).
enum HomeCatalogCache {
    private static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("cue-home-catalogs.json")
    }()

    static func load() -> [String: [MetaItem]] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [MetaItem]].self, from: data) else { return [:] }
        return decoded
    }

    static func save(_ rows: [String: [MetaItem]]) {
        // Encode + write OFF the main thread. This is called from the @MainActor
        // Home load right after a refresh; encoding ~15 rows × 30 MetaItems and
        // writing the file synchronously there is a visible hitch on the A8 the
        // moment Home finishes loading. It's fire-and-forget persistence, so a
        // utility-queue hop costs the UI nothing.
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var entries: [HomeEntry] = [] {
        didSet { rebuildItemIndex() }
    }
    @Published var isLoading = false
    /// Current phase label for the first-run stepped loading backdrop
    /// (nil when not doing a cold, cache-less load).
    @Published var loadingStep: String?
    @Published var loadError: String?
    /// The default billboard title (first catalog item with art), computed on
    /// load. The LIVE hero — which changes as focus moves — lives in a separate
    /// `HeroFocus` object so its frequent animated updates only re-render the
    /// billboard, NOT the poster rows. That full re-render was cancelling the
    /// first long-press on a card right after moving to it.
    /// Settings → Layout → Hero source, captured at the start of each `load`.
    ///
    /// Stored rather than read live because every derivation below runs inside
    /// `load` or straight off `entries`, and the key is in the load fingerprint
    /// — so changing the setting reloads Home, which re-reads it here. That
    /// keeps the spotlight and the Featured bar deciding from one value
    /// instead of reads that could disagree mid-load.
    private var heroCatalogKey: String = ""

    /// The row the hero draws from: the chosen catalog, or the first row when
    /// nothing is chosen.
    ///
    /// Falls back for a chosen key that isn't on screen, which is a real case
    /// and not a corner one — the row can be switched off in the list right
    /// below this setting, or ranked past `maxHomeRows`, or come from an addon
    /// that has since been removed. A hero that silently went blank in any of
    /// those would look like a bug in the hero rather than a stale preference.
    private var heroCatalogRow: HomeRow? {
        Self.heroCatalogRow(entries, heroKey: heroCatalogKey)
    }

    static func heroCatalogRow(_ entries: [HomeEntry], heroKey: String) -> HomeRow? {
        let catalogs = entries.compactMap { entry -> HomeRow? in
            if case .catalog(let row) = entry { return row }
            return nil
        }
        if !heroKey.isEmpty, let chosen = catalogs.first(where: { $0.catalogKey == heroKey }) {
            return chosen
        }
        return catalogs.first
    }

    private var loadedFingerprint: [String] = []
    /// Bumped by every `load`. Loads overlap constantly on launch —
    /// `.task` fires one, then the account sync lands and collections,
    /// order keys and add-ons each trip their own `.onChange` — and each
    /// run holds its OWN `orderedKeys`, captured before its awaits. With
    /// no generation check the run that finishes last wins, which is
    /// routinely the OLDEST one: it republishes a row list assembled
    /// before the collections existed, so the collection rows vanish and
    /// stay gone (the fingerprint already says "loaded"). That is the
    /// intermittent "my categories didn't show up" — a race, which is
    /// why a relaunch usually 'fixes' it.
    private var loadGeneration = 0

    // MARK: - Shared home assembly

    /// Every catalog item by id, rebuilt only when `entries` changes. The
    /// per-theme copies re-derived this inside a loop over Continue Watching
    /// items — 45 rows x 30 items scanned per card, on every body pass.
    private(set) var itemIndex: [String: MetaItem] = [:]

    /// Every catalog item, de-duplicated, in HOME ORDER. Order matters — the
    /// Max and Hulu spotlights take the first few with backdrop art, so this
    /// cannot be served from `itemIndex.values`, which is unordered.
    private(set) var orderedItems: [MetaItem] = []

    private func rebuildItemIndex() {
        var index: [String: MetaItem] = [:]
        var ordered: [MetaItem] = []
        for case .catalog(let row) in entries {
            for item in row.items where index[item.id] == nil {
                index[item.id] = item
                ordered.append(item)
            }
        }
        itemIndex = index
        orderedItems = ordered
    }



    /// Collections that share ONE combined "Collections" row (viewMode other
    /// than ROWS); Home shows them at the first one's slot.
    var sharedCollections: [CueCollection] {
        entries.compactMap {
            if case .collection(let c) = $0, c.viewMode != "ROWS" { return c } else { return nil }
        }
    }


    /// One folder presented as its own single-folder collection — what every
    /// theme opens when a folder tile is selected.
    nonisolated static func folderCollection(
        _ folder: CueCollectionFolder, in collection: CueCollection
    ) -> CueCollection {
        CueCollection(id: "folder:\(collection.id):\(folder.id)",
                        title: folder.title, folders: [folder])
    }

    func loadIfNeeded(
        addonManager: AddonManager,
        collections: CollectionsStore,
        settings: HomeCatalogSettingsStore,
        providers: CollectionProviders
    ) async {
        // Fingerprint includes catalog counts (so rows refresh when the live
        // manifests replace the bundled seed) plus the layout customization
        // state and collection list, so edits re-render immediately. viewMode +
        // pinToTop are included so changing a collection's Home layout or its
        // pin re-renders without a relaunch.
        var fingerprint = addonManager.catalogAddons.map {
            "\($0.id)#\(($0.manifest.catalogs ?? []).count)"
        }
        fingerprint.append(settings.orderKeys.joined(separator: ","))
        fingerprint.append(settings.disabledKeys.sorted().joined(separator: ","))
        fingerprint.append(settings.customTitles.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
        fingerprint.append("hideUnreleased=\(settings.hideUnreleasedContent)")
        // "Poster banners" swaps the artwork as catalogs are fetched, so the
        // rows must be fetched again for a flip of it to show.
        fingerprint.append("posterBanners=\(settings.showPosterBanners)")
        // Row titles are baked in at load time by rowTitle(), so the two
        // switches that change them belong in the fingerprint. Without these,
        // toggling "Show add-on name" or the type suffix left every row header
        // stale until some unrelated refresh happened to rebuild Home.
        fingerprint.append("addonName=\(settings.catalogAddonNameEnabled)")
        fingerprint.append("typeSuffix=\(settings.catalogTypeSuffixEnabled)")
        // Hero source. The spotlight is derived during the load, so picking a
        // different catalog has to re-run it.
        fingerprint.append("heroCatalog=\(settings.heroCatalogKey)")
        fingerprint.append(collections.collections.map {
            "\($0.id)#\($0.folders.count)#\($0.title)#\($0.viewMode)#\($0.pinToTop)"
        }.joined(separator: ","))
        // Collection rows no longer come and go with TMDB / Trakt, but keep
        // the connections in the fingerprint anyway — cheap, and any future
        // provider-dependent rendering rebuilds without a relaunch.
        fingerprint.append("providers=\(providers.tmdb)/\(providers.trakt)")
        guard entries.isEmpty || fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint
        await load(addonManager: addonManager, collections: collections,
                   settings: settings, providers: providers)
    }

    func load(
        addonManager: AddonManager,
        collections: CollectionsStore,
        settings: HomeCatalogSettingsStore,
        /// TMDB / Trakt. Collections ALWAYS show on Home, whatever is
        /// connected — a collection opened with nothing connected explains
        /// inside (per folder) that TMDB or Trakt needs setting up. Hiding
        /// them here just made the feature look broken with no pointer to why.
        providers: CollectionProviders
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        /// False once a newer load has started; a superseded run stops
        /// publishing instead of overwriting the newer one's rows.
        func isCurrent() -> Bool { loadGeneration == generation }

        isLoading = entries.isEmpty
        loadError = nil
        // Read ONCE per load: everything derived below (the spotlight, the
        // Featured bar) must agree about which catalog the hero is on, and
        // `loadIfNeeded` re-runs this whenever it changes.
        heroCatalogKey = settings.heroCatalogKey

        // Assemble the available rows keyed the same way the sync payload is,
        // then let the layout settings decide order and visibility.
        var catalogByKey: [String: (addon: InstalledAddon, catalog: ManifestCatalog)] = [:]
        var catalogKeys: [String] = []
        // Enumerate EVERY catalog the addon declares — the same rule
        // Settings → Layout uses. These two lists must agree: a per-addon
        // `.prefix(6)` here meant an addon declaring 10 catalogs showed all 10
        // in the Layout editor (with live toggles and reorder arrows) while
        // Home silently never fetched 7-10, and no amount of reordering could
        // rescue them because the cut was taken in MANIFEST order, before the
        // user's order was merged in. `maxHomeRows` below is the real ceiling,
        // and it cuts in the user's own order.
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id
                )
                guard catalogByKey[key] == nil else { continue }
                catalogKeys.append(key)
                catalogByKey[key] = (addon, catalog)
            }
        }
        var collectionByKey: [String: CueCollection] = [:]
        var collectionKeys: [String] = []
        for collection in collections.collections {
            let key = HomeCatalogSettingsStore.collectionKey(collection.id)
            collectionKeys.append(key)
            collectionByKey[key] = collection
        }
        NSLog("[CueHome] load: %d catalogs, %d collections (%d pinned), %d order keys",
              catalogKeys.count, collectionKeys.count,
              collections.collections.filter(\.pinToTop).count,
              settings.orderKeys.count)
        AppProbe.data("home load: \(catalogKeys.count) catalogs,"
                      + " \(collectionKeys.count) collections"
                      + " (\(collections.collections.filter(\.pinToTop).count) pinned),"
                      + " \(settings.orderKeys.count) order keys")

        let mergedKeys = settings
            .mergedOrder(catalogKeys: catalogKeys, collectionKeys: collectionKeys)
            .filter { settings.isEnabled(key: $0) }
        // Pin to top: a collection flagged pinToTop jumps to the front of the
        // Home order (keeping relative order among pins), so it renders above
        // the catalogs instead of wherever the merged order placed it.
        let pinnedKeys = Set(collections.collections.filter(\.pinToTop)
            .map { HomeCatalogSettingsStore.collectionKey($0.id) })
        let prioritized = pinnedKeys.isEmpty ? mergedKeys
            : mergedKeys.filter { pinnedKeys.contains($0) } + mergedKeys.filter { !pinnedKeys.contains($0) }

        // Cap the number of CATALOG rows Home will build. Row layouts render
        // their rows eagerly (see rowsContent), so an account carrying 40+
        // addons — each declaring up to 6 catalogs — would materialize hundreds
        // of rows and fetch every one of them on a single load. That is the
        // "app dies after signing in with lots of addons" case: it isn't the
        // login, it's the Home load that follows it. Collections are exempt:
        // they're markers with no fetch, and the user explicitly created them.
        // The order is the user's own (Settings → Layout), so the cut is always
        // "the rows you ranked lowest", and everything remains reachable from
        // Discover.
        var catalogRowBudget = AddonSweepLimits.maxHomeRows
        let orderedKeys = prioritized.filter { key in
            guard catalogByKey[key] != nil else { return true }   // collections: always keep
            guard catalogRowBudget > 0 else { return false }
            catalogRowBudget -= 1
            return true
        }

        // Rows painted from the on-disk cache, by key. These are REAL content
        // already on screen, so every republish below composes against them:
        // a row that hasn't come back from the network yet keeps showing its
        // cached items rather than disappearing.
        var staleByKey: [String: HomeEntry] = [:]

        /// The published row list: fresh where we have it, cached where we
        /// don't, collections always.
        ///
        /// Everything that assigns `entries` during a refresh goes through
        /// this. The old code assigned raw partial results instead — first the
        /// collection markers alone (wiping every cached row the moment a
        /// refresh started), then each progressive batch (a screen of cached
        /// rows collapsing to the one or two that had answered so far). That
        /// is the "categories flash for a split second and vanish" on a cold
        /// start: the rows were never lost, they were being republished a few
        /// at a time over a full screen that had already painted.
        func compose(fresh: [String: HomeEntry]) -> [HomeEntry] {
            orderedKeys.compactMap { key in
                if let collection = collectionByKey[key] { return .collection(collection) }
                return fresh[key] ?? staleByKey[key]
            }
        }

        // A refresh over an already-populated Home (coming back to the tab, a
        // settings change, a manual refresh) has to be protected the same way
        // — seed the fallback from what is currently on screen, or the
        // progressive republish blanks those rows exactly like a cold start.
        if !entries.isEmpty {
            var keyByRowID: [String: String] = [:]
            for key in orderedKeys {
                if let request = catalogByKey[key] { keyByRowID[Self.rowID(request)] = key }
            }
            for entry in entries {
                if case .catalog(let row) = entry, let key = keyByRowID[row.id] {
                    staleByKey[key] = entry
                }
            }
        }

        // STALE: on a cold start, paint the last-saved catalog items instantly
        // (paired with the live addon/catalog so "See All" still works), then
        // refresh below.
        if entries.isEmpty {
            // Read + JSON-decode the on-disk cache OFF the main thread — on the
            // A8 this blocked the very first frame (the loading backdrop) until
            // the file was parsed. Awaiting a detached read lets the backdrop
            // paint immediately, then the stale rows swap in when it returns.
            let cached = await Task.detached(priority: .userInitiated) {
                HomeCatalogCache.load()
            }.value
            var stale: [HomeEntry] = []
            for key in orderedKeys {
                if let collection = collectionByKey[key] {
                    // Collections are pure markers (buttons/tiles, no content
                    // fetch) in every view mode, so all paint instantly.
                    stale.append(.collection(collection))
                } else if let request = catalogByKey[key], let items = cached[key], !items.isEmpty {
                    // Dedup: a cache written before the source-side dedup
                    // shipped could still hold duplicate ids. Unreleased items
                    // are dropped here too — the cache may predate the setting
                    // (or the title's release date may have passed since).
                    var staleItems = items.deduplicatedByID()
                    if settings.hideUnreleasedContent {
                        staleItems = staleItems.filter { !$0.isUnreleased }
                    }
                    guard !staleItems.isEmpty else { continue }
                    let staleRow = HomeEntry.catalog(HomeRow(
                        id: Self.rowID(request),
                        title: Self.rowTitle(key: key, request: request, settings: settings),
                        items: staleItems, addon: request.addon, catalog: request.catalog
                    ))
                    // Remembered by key so the refresh below can fall back to
                    // it PER ROW instead of blanking the screen.
                    staleByKey[key] = staleRow
                    stale.append(staleRow)
                }
            }
            if !isCurrent() { return }
            if !stale.isEmpty {
                entries = stale
                // As early as the rows exist, before the network revalidation
                // even starts. Backdrops are the one image class nothing warms:
                // the poster prefetch below only takes `\.poster` from rows 3+,
                // so every spotlight title used to hit the network at the
                // moment it rotated in — a full-screen download while you are
                // looking at the frame it belongs in.
                warmSpotlightArt()
            }
        }

        // The stepped backdrop only shows when there's genuinely nothing on
        // screen (true first run). Warm starts render from cache instantly.
        isLoading = entries.isEmpty
        if isLoading {
            // No artificial pause — go straight to fetching so the first-run
            // load is as fast as the network allows.
            loadingStep = "Loading catalogs…"
        }

        // REVALIDATE: fetch the catalogs, a bounded number at a time.
        // Collections are just markers here — Home shows them as buttons/tiles;
        // their catalog content is resolved on demand when the user opens a
        // folder/collection's discover page, so Home never eagerly fetches
        // collection content.
        var fetched: [(index: Int, key: String?, entry: HomeEntry)] = []
        /// Fresh rows by key, for `compose`.
        var freshByKey: [String: HomeEntry] = [:]
        // The catalog rows still to fetch, paired with their slot in
        // orderedKeys. Titles and row ids are resolved HERE, on the main actor,
        // so the fetch loop below needs no isolated state of its own.
        var pending: [(index: Int, key: String, title: String, rowID: String,
                       request: (addon: InstalledAddon, catalog: ManifestCatalog))] = []
        for (index, key) in orderedKeys.enumerated() {
            if let collection = collectionByKey[key] {
                fetched.append((index, nil, .collection(collection)))
            } else if let request = catalogByKey[key] {
                pending.append((
                    index, key,
                    Self.rowTitle(key: key, request: request, settings: settings),
                    Self.rowID(request),
                    request
                ))
            }
        }
        // Collections resolve instantly; publish them WITH the cached rows
        // still in place (compose keeps them) rather than in place of them.
        if !fetched.isEmpty, isCurrent() { entries = compose(fresh: [:]) }

        await withTaskGroup(of: (Int, String, HomeEntry?).self) { group in
            // Keep at most `catalogs` requests outstanding. Unbounded, a large
            // install fired one request per row simultaneously and held every
            // decoded response at once — the peak that killed the app.
            let window = max(1, min(AddonSweepLimits.catalogs, pending.count))
            var next = 0
            // Read once here, not inside the task: `settings` is main-actor state.
            let hideUnreleased = settings.hideUnreleasedContent
            func startNext() {
                guard next < pending.count else { return }
                let (index, key, title, rowID, request) = pending[next]
                next += 1
                group.addTask {
                    // A row that yields nothing is dropped silently — it just
                    // isn't on Home, while Settings → Layout still lists it.
                    // That is indistinguishable from "the addon is down" unless
                    // we say which happened, so log the reason.
                    var items: [MetaItem]
                    do {
                        items = try await StremioAPI.catalog(addon: request.addon, catalog: request.catalog)
                    } catch {
                        NSLog("[CueHome] row dropped — fetch failed: %@ (%@): %@",
                              title, key, error.localizedDescription)
                        // An empty Home is nearly always a pile of these. Each
                        // one names the row that will simply not be there.
                        AppProbe.warn("home row", "\(title) [\(key)] — \(error.localizedDescription)")
                        return (index, key, nil)
                    }
                    let fetched = items.count
                    // "Hide unreleased content" (Settings → Layout). Filtered
                    // BEFORE the 30-item trim so a row full of upcoming titles
                    // still fills up with things you can actually watch.
                    if hideUnreleased { items = items.filter { !$0.isUnreleased } }
                    guard !items.isEmpty else {
                        NSLog("[CueHome] row dropped — %@: %@ (%@)",
                              fetched == 0 ? "addon returned no items"
                                           : "all \(fetched) items hidden by Hide unreleased content",
                              title, key)
                        AppProbe.data("home row dropped — \(title) [\(key)]: "
                                      + (fetched == 0 ? "add-on returned no items"
                                         : "all \(fetched) hidden by Hide unreleased content"))
                        return (index, key, nil)
                    }
                    let row = HomeRow(
                        id: rowID,
                        title: title,
                        // Dedupe by id, exactly as the cache-paint path above
                        // does: a repeated MetaItem.id inside a tvOS ForEach
                        // crashes the focus engine, and aggregator catalogs do
                        // return the same title twice.
                        items: Array(items.deduplicatedByID().prefix(30)),
                        addon: request.addon,
                        catalog: request.catalog
                    )
                    return (index, key, .catalog(row))
                }
            }
            for _ in 0..<window { startNext() }

            // Reveal rows AS SOURCES RESPOND so a slow aggregator doesn't hold
            // up the whole screen — but coalesce the republishes. Re-sorting and
            // reassigning `entries` on every single completion made SwiftUI
            // rebuild the entire (eagerly-built) row stack once per row; with
            // many rows that is quadratic work on the main actor. Same throttle
            // the Sources sweep uses.
            var lastFlush = Date.distantPast
            for await (index, key, entry) in group {
                // Stop the whole sweep once superseded, rather than only muting
                // its results. The generation check below prevented a stale
                // publish, but the abandoned run carried on issuing and decoding
                // every remaining catalog page — so the duplicated work and the
                // memory peak both survived it.
                guard isCurrent() else { group.cancelAll(); break }
                startNext()
                guard let entry else { continue }
                fetched.append((index: index, key: String?.some(key), entry: entry))
                freshByKey[key] = entry
                if Date().timeIntervalSince(lastFlush) > 0.4, isCurrent() {
                    entries = compose(fresh: freshByKey)
                    lastFlush = Date()
                }
            }
            if isCurrent() { entries = compose(fresh: freshByKey) }
        }

        // Superseded mid-flight: a newer load owns the screen now. Bail before
        // republishing this run's (older) row list over it.
        guard isCurrent() else { return }

        if isLoading { loadingStep = "Loading artwork…" }

        let ordered = fetched.sorted { $0.index < $1.index }
        // Per-row fallback, so one dead catalog can't blank its row and an
        // offline refresh can't blank the screen.
        entries = compose(fresh: freshByKey)

        // Persist fresh catalog items for the next cold start. Only real
        // add-on catalog rows (whose key maps back to a live catalog) are
        // cached; collection-derived rows re-resolve on next launch.
        var toCache: [String: [MetaItem]] = [:]
        for row in ordered {
            if let key = row.key, catalogByKey[key] != nil, case .catalog(let r) = row.entry {
                toCache[key] = r.items
            }
        }
        // A row that didn't answer this run is still on screen from cache —
        // carry its items forward, or saving here would drop it and the next
        // cold start would have nothing to paint for it.
        for (key, entry) in staleByKey where toCache[key] == nil {
            if catalogByKey[key] != nil, case .catalog(let r) = entry { toCache[key] = r.items }
        }
        if !toCache.isEmpty { HomeCatalogCache.save(toCache) }

        // Again with the live rows: the fresh top titles may differ from the
        // cached ones, and an already-cached URL costs a `fileExists` here.
        warmSpotlightArt()
        if entries.isEmpty {
            loadError = "No catalogs available. Check your addons and network connection."
        }
        isLoading = false
        loadingStep = nil

        // Warm the poster cache for the below-the-fold rows so scrolling down
        // hits disk, not the network. First rows render on their own.
        let prefetchURLs = entries.dropFirst(2).flatMap { entry -> [String] in
            guard case .catalog(let row) = entry else { return [] }
            return row.items.prefix(12).compactMap(\.poster)
        }
        if !prefetchURLs.isEmpty, PerformanceSettingsStore.shared.settings.artworkPrefetch {
            ImageCache.shared.prefetch(urls: Array(prefetchURLs))
        }
    }

    // MARK: Row builders (shared between the cache-paint and live-fetch paths)

    static func rowID(_ request: (addon: InstalledAddon, catalog: ManifestCatalog)) -> String {
        "\(request.addon.id)|\(request.catalog.type)|\(request.catalog.id)"
    }

    static func rowTitle(
        key: String,
        request: (addon: InstalledAddon, catalog: ManifestCatalog),
        settings: HomeCatalogSettingsStore
    ) -> String {
        // APK row header format: "{Catalog Name} - {Type}" (e.g. "Trending Movies - Movie").
        let typeLabel: String
        switch request.catalog.type {
        case "series", "tv": typeLabel = "Series"
        case "movie": typeLabel = "Movie"
        default: typeLabel = request.catalog.type.capitalized
        }
        let baseName = request.catalog.name ?? request.catalog.id.capitalized
        if let custom = settings.customTitle(for: key) { return custom }
        var title = baseName
        if settings.catalogAddonNameEnabled { title += " · \(request.addon.manifest.name)" }
        if settings.catalogTypeSuffixEnabled { title += " - \(typeLabel)" }
        return title
    }


    /// Pull the spotlight's backdrops into the image cache. Gated on the same
    /// switch as the poster prefetch — this is art that is not on screen yet.
    private func warmSpotlightArt() {
        guard PerformanceSettingsStore.shared.settings.artworkPrefetch else { return }
        let art = spotlightItems(max: 6).compactMap { $0.background ?? $0.poster }
        guard !art.isEmpty else { return }
        ImageCache.shared.warm(urls: art)
    }

    /// The top titles for the Apple TV hero's spotlight rotation: the hero
    /// catalog's items that actually have backdrop art (a hero with no
    /// backdrop is a dead frame), capped at `max`.
    func spotlightItems(max: Int) -> [MetaItem] {
        let items = (heroCatalogRow?.items ?? []).filter { $0.background != nil }
        return Array(items.prefix(max))
    }

}

struct HomeView: View {
    @ObservedObject private var probe = RenderProbe.shared
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore

    /// The services collections can resolve from right now (see
    /// `CollectionProviders`). Collection rows always render; this only tells
    /// the loader what a collection opened from them will be able to fill.
    private var collectionProviders: CollectionProviders {
        CollectionProviders(tmdb: tmdbSettings.isEnabled, trakt: TraktService.isConfigured)
    }
    // Owned by RootView so it PERSISTS across tab switches. If it were a local
    // @StateObject, switching away and back would rebuild HomeView with a fresh
    // (empty) model → a "Loading catalogs" spinner with no focusable element →
    // focus falls back to the sidebar, which reopened the panel.
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject private var perf = PerformanceSettingsStore.shared

    let onSelect: (MetaItem) -> Void
    /// The billboard's Select (see `HomeSpotlightView.onSelectFeatured`).
    var onSelectFeatured: ((MetaItem) -> Void)? = nil
    let onResume: (WatchProgress) -> Void
    var onResumeFromStart: (WatchProgress) -> Void = { _ in }
    /// Opens the source list (StreamsView) so the user picks a stream manually.
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    /// Same, from a Continue Watching card's hold menu — takes the STORED row
    /// so the root can run the identity repair a resume gets (tmdb: → tt,
    /// "tv"-typed rows, dropped season/episode) before opening the picker.
    var onPlayManuallyProgress: (WatchProgress) -> Void = { _ in }
    let onOpenCollection: (CueCollection) -> Void
    var onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void = { _, _, _ in }
    /// Fires when the first load attempt finishes (success or error), so the
    /// root can re-enable the sidebar only once content exists to hold focus.
    var onContentReady: () -> Void = {}
    /// Called when Back is pressed at the START of a row (or on the hero/other
    /// non-row content): opens the sidebar (Classic) or focuses the tab bar
    /// (Fusion). Passed from RootView.
    var onHomeBack: () -> Void = {}

    /// Coalesces the launch burst of store publishes into one reload.
    @State private var reloadDebounce: Task<Void, Never>?
    /// The deferred `onContentReady` nudge from `reload()`. Held so a repeat
    /// reload or a teardown can cancel it instead of firing into a gone view.
    @State private var contentReadyTask: Task<Void, Never>?
    @State private var nextUpContinueItems: [WatchProgress] = []
    /// Coarse wall-clock tick. Air dates are day-granular, so a newly aired
    /// episode only becomes eligible when the DAY changes — nothing else in the
    /// stores moves at midnight. Bumping this on the hour is enough to notice
    /// the rollover and re-run the Next Up refresh (see `nextUpRefreshKey`).
    @State private var clockTick = Date()
    /// Continue Watching rows the viewer has moved past (see
    /// `supersededContinueRows`), by `continueRowStamp`. Their show gets a
    /// Next Up card instead.
    @State private var supersededContinueRows: Set<String> = []
    /// metaID → how many episodes have aired since the viewer started that
    /// show and are still unwatched. Drives the green "+N" badge. Covers shows
    /// with a real progress row too, not just the synthesised Next Up cards.
    @State private var newEpisodeCounts: [String: Int] = [:]

    /// False while Home is covered (player fullScreenCover, pushed screen,
    /// other tab). Home stays mounted in those states, so without this gate the
    /// spotlight kept rotating unseen — decoding a full-screen backdrop every
    /// 9s DURING playback, real decode/memory contention on the 2–3 GB boxes.
    @State private var isVisible = true

    /// Continue Watching as a spotlight row, plus the progress entry behind
    /// each of its titles (so Select can resume exactly where you stopped).
    private var spotlightContinue: (row: HomeRow, progress: [String: WatchProgress])? {
        let entries = mergedContinueItems()
        guard !entries.isEmpty else { return nil }
        var progress: [String: WatchProgress] = [:]
        var items: [MetaItem] = []
        for entry in entries where progress[entry.metaID] == nil {
            progress[entry.metaID] = entry
            // Full catalog data when the title is loaded elsewhere on Home.
            let base = heroItem(from: entry)
            items.append(MetaItem(
                id: entry.metaID, type: base.type, name: base.name,
                poster: base.poster ?? entry.poster,
                // Episode still (when enabled), else the show backdrop.
                background: continueImage(entry) ?? base.background,
                logo: base.logo ?? entry.logo,
                description: base.description, releaseInfo: base.releaseInfo,
                imdbRating: base.imdbRating, runtime: base.runtime,
                genres: base.genres, cast: base.cast, videos: base.videos
            ))
        }
        return (HomeRow(id: HomeSpotlightView.continueRowID,
                        title: "Continue Watching", items: items),
                progress)
    }
    
    /// Catalog rows plus collections, in the order Settings → Layout gives
    /// them. Collections are a first cut: plain rows whose cards stand for
    /// folders (a ROWS collection gets its own row of folders) or for whole
    /// collections (every other collection shares one "Collections" row, at
    /// the first one's slot). Selecting a card opens the folder or collection
    /// browser — see `selectSpotlight`.
    private var spotlightRows: [HomeRow] {
        var rows: [HomeRow] = []
        var sharedRowAdded = false
        for entry in viewModel.entries {
            switch entry {
            case .catalog(let row):
                if !row.items.isEmpty { rows.append(row) }
            case .collection(let collection):
                if collection.viewMode == "ROWS" {
                    let items = collection.folders.map { Self.spotlightItem(for: $0, in: collection) }
                    guard !items.isEmpty else { continue }
                    let key = HomeCatalogSettingsStore.collectionKey(collection.id)
                    rows.append(HomeRow(id: Self.collectionItemPrefix + collection.id,
                                        title: homeCatalogSettings.customTitle(for: key) ?? collection.title,
                                        items: items))
                } else if !sharedRowAdded {
                    sharedRowAdded = true
                    rows.append(HomeRow(id: Self.collectionItemPrefix + "shared",
                                        title: "Collections",
                                        items: viewModel.sharedCollections.map(Self.spotlightItem(for:))))
                }
            }
        }
        return rows
    }

    /// Marks a spotlight card that stands for a collection or folder, not a
    /// title. The rest of the id is looked up again in `selectSpotlight`.
    private static let collectionItemPrefix = "cue-collection:"

    private static func spotlightItem(for collection: CueCollection) -> MetaItem {
        let cover = collection.folders.first?.tileCoverImageUrl
        let backdrop = collection.backdropImageUrl?.isEmpty == false ? collection.backdropImageUrl : cover
        return MetaItem(id: collectionItemPrefix + collection.id, type: "collection",
                        name: collection.title, poster: cover, background: backdrop)
    }

    private static func spotlightItem(for folder: CueCollectionFolder,
                                      in collection: CueCollection) -> MetaItem {
        let backdrop = folder.heroBackdropUrl?.isEmpty == false ? folder.heroBackdropUrl
            : (collection.backdropImageUrl?.isEmpty == false ? collection.backdropImageUrl
               : folder.tileCoverImageUrl)
        return MetaItem(id: collectionItemPrefix + collection.id + "\u{1F}" + folder.id,
                        type: "collection", name: folder.title,
                        poster: folder.tileCoverImageUrl, background: backdrop,
                        logo: folder.titleLogoUrl)
    }

    /// A spotlight card was selected: a collection/folder card opens its
    /// browser, anything else is a title.
    private func selectSpotlight(_ item: MetaItem) {
        guard item.id.hasPrefix(Self.collectionItemPrefix) else { onSelect(item); return }
        let parts = item.id.dropFirst(Self.collectionItemPrefix.count)
            .split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        for entry in viewModel.entries {
            guard case .collection(let collection) = entry, collection.id == parts.first else { continue }
            if parts.count == 2, let folder = collection.folders.first(where: { $0.id == parts[1] }) {
                onOpenCollection(HomeViewModel.folderCollection(folder, in: collection))
            } else {
                onOpenCollection(collection)
            }
            return
        }
    }
    var body: some View {
        Group {
            let cw = spotlightContinue
            // Featured: the same titles the original hero rotates through
            // (the hero catalog from Settings → Layout, backdrops only).
            let featured = viewModel.spotlightItems(max: 10)
            let featuredRow = featured.isEmpty || !Spotlight.showFeatured ? [] :
                [HomeRow(id: HomeSpotlightView.featuredRowID, title: "Featured", items: featured)]
            if probe.flags.uikitHome {
                // The new Home: rows in UIKit (collection views), native
                // focus, our own Core Animation movement to the fixed box.
                // (Catalogs only for now.)
                HomeUIKitView(rows: (cw.map { [$0.row] } ?? []) + spotlightRows,
                              continueRowID: HomeSpotlightView.continueRowID,
                              progress: cw?.progress ?? [:],
                              onSelect: selectSpotlight,
                              onResume: onResume)
            } else {
                // The previous Home, kept for reference (Render Lab → UIKit
                // Home off).
            HomeSpotlightView(
                rows: featuredRow + (cw.map { [$0.row] } ?? []) + spotlightRows,
                onSelect: selectSpotlight,
                onSelectFeatured: onSelectFeatured,
                onBack: onHomeBack,
                continueProgress: cw?.progress ?? [:],
                onResume: onResume,
                onResumeFromStart: onResumeFromStart,
                onPlayManually: onPlayManuallyProgress
            )
            }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
            reloadDebounce?.cancel()
            contentReadyTask?.cancel()
        }
        .task {
            await reload()
        }
        // Periodic catalog auto-refresh (Settings → Content & Discovery).
        // Restarts whenever the cadence changes; 0 = off. Uses the FORCED
        // load (not loadIfNeeded — the fingerprint wouldn't have changed) so
        // new releases appear without relaunching.
        .task(id: homeCatalogSettings.autoRefreshMinutes) {
            let minutes = homeCatalogSettings.autoRefreshMinutes
            guard minutes > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
                guard !Task.isCancelled else { return }
                // Same gate the account-sync loops use: never fire a full
                // multi-addon catalog sweep (plus its poster prefetch) while
                // the home is covered or a stream is playing — that competed
                // with the movie for bandwidth mid-film.
                guard isVisible, !NuvioSyncManager.playbackActive else { continue }
                await viewModel.load(
                    addonManager: addonManager,
                    collections: collections,
                    settings: homeCatalogSettings,
                    providers: collectionProviders
                )
            }
        }
        // Eight separate triggers, ONE debounced reload. Each of these used to
        // fire its own unthrottled `reload()`, and at launch they arrive in a
        // burst: the first load runs, then the collections library finishes
        // decoding, then profile scoping republishes four settings at once — so
        // a cold start ran the whole catalog sweep two to four times over.
        .onChange(of: addonManager.addons) { _, _ in scheduleReload() }
        .onChange(of: collections.collections) { _, _ in scheduleReload() }
        // Collection rows render regardless, but a provider change still
        // reloads Home so anything downstream of the connections is fresh.
        .onChange(of: collectionProviders) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.orderKeys) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.disabledKeys) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.customTitles) { _, _ in scheduleReload() }
        // Same reason as the three above: these three change what the loader
        // produces, and nothing else asked Home to rebuild when they flipped —
        // the row titles (and the unreleased filter) stayed stale.
        .onChange(of: homeCatalogSettings.catalogAddonNameEnabled) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.catalogTypeSuffixEnabled) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.hideUnreleasedContent) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.showPosterBanners) { _, _ in scheduleReload() }
        .task(id: nextUpRefreshKey) { await refreshNextUpContinueItems() }
        // Hourly clock nudge so the day bucket in `nextUpRefreshKey` notices a
        // midnight rollover while Home is left open. The key only changes once
        // per day, so this does NOT re-run the Next Up fetch every hour.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                guard !Task.isCancelled else { return }
                clockTick = Date()
            }
        }
    }

    /// Coalesce a burst of store publishes into one reload. `loadIfNeeded` is
    /// fingerprint-guarded, so a redundant call is cheap — but only after it has
    /// already re-derived the whole request list, and at launch these arrive
    /// several at a time.
    private func scheduleReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        // Let the root enable focus/sidebar input after the first frame instead
        // of waiting for every Home catalog request to finish. Slow or broken
        // add-ons should leave Home loading, not make the whole app feel frozen.
        contentReadyTask?.cancel()
        contentReadyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            onContentReady()
        }

        let done = AppProbe.begin("data", "Home reload")
        await viewModel.loadIfNeeded(
            addonManager: addonManager,
            collections: collections,
            settings: homeCatalogSettings,
            providers: collectionProviders
        )
        done("\(viewModel.entries.count) rows")
        onContentReady()
    }

    private var nextUpRefreshKey: String {
        // CHEAP. This is a `.task(id:)` key recomputed on every Home body
        // pass; it used to sort-and-join the full watch history (a ~100KB
        // string after a Trakt import) plus a full Continue Watching sort,
        // twice over per invalidation. An order-insensitive hash of the same
        // inputs changes exactly when they do, for a few microseconds.
        var watchedHash = 0, progressHash = 0, dismissedHash = 0
        for key in watched.items.keys { watchedHash ^= key.hashValue }
        for item in progressStore.continueWatching(sortMode: .recentlyWatched) {
            progressHash ^= item.id.hashValue &+ Int(item.positionSeconds)
        }
        for show in progressStore.dismissedNextUpShows { dismissedHash ^= show.hashValue }
        // Day bucket: an episode "becomes available" on its air DATE, which is
        // invisible to every store. Without this the row only recomputed when
        // something else changed, so a new episode that aired while the app sat
        // open (or overnight) stayed absent until the next launch.
        let dayBucket = Int(clockTick.timeIntervalSince1970 / 86_400)
        return "\(watchedHash)#\(progressHash)#\(homeCatalogSettings.showUnairedNextUp)"
            + "#\(dismissedHash)#\(dayBucket)"
    }

    private func mergedContinueItems() -> [WatchProgress] {
        let sortMode = homeCatalogSettings.continueWatchingSortMode
        // By stamp, not by show: a row saved AFTER the judgement (the viewer
        // went back to that episode) is shown at once, without waiting for the
        // refresh to re-judge it.
        let active = progressStore.continueWatching(sortMode: sortMode)
            .filter { !supersededContinueRows.contains(Self.continueRowStamp($0)) }
        let activeMetaIDs = Set(active.map(\.metaID))
        // Also filtered here, not only in the async refresh: `removeShow` on a
        // synthesised card has no progress rows to delete, so the card would sit
        // on screen until the refresh re-ran — and that does up to twenty
        // sequential metadata fetches first.
        let additions = nextUpContinueItems.filter {
            !activeMetaIDs.contains($0.metaID)
                && !progressStore.dismissedNextUpShows.contains($0.metaID)
        }
        // Synthesised Next Up rows already carry their count; stamp the ones
        // with a real progress row here. Doing it on the row (rather than
        // passing the map down) keeps `ContinueWatchingCell`'s Equatable
        // comparison honest — the card re-renders when the number changes.
        let stamped = active.map { row -> WatchProgress in
            guard let count = newEpisodeCounts[row.metaID] else { return row }
            var copy = row
            copy.newEpisodeCount = count
            return copy
        }
        // Next Up cards take their place by recency — each is dated by the
        // show's last watched episode — instead of queueing behind every
        // in-progress row. Appended, a show whose episode had just been
        // finished sat after the show watched the day before, so leaving the
        // player put the PREVIOUS show at the front. The reference Nuvio client
        // sorts the two kinds together the same way.
        return Self.continueOrder(stamped + additions, sortMode: sortMode)
    }

    /// `ProgressStore.continueWatching(sortMode:)`'s ordering, applied to the
    /// row once Next Up cards have joined it: newest first on (timestamp, id),
    /// and for Streaming style the mid-episode titles ahead of the rest.
    private nonisolated static func continueOrder(
        _ rows: [WatchProgress], sortMode: ContinueWatchingSortMode
    ) -> [WatchProgress] {
        let byRecency = rows.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        switch sortMode {
        case .recentlyWatched:
            return byRecency
        case .streamingStyle:
            return byRecency.filter { $0.fraction >= 0.02 } + byRecency.filter { $0.fraction < 0.02 }
        }
    }

    /// Identifies one version of a row: its key and when it was written.
    private nonisolated static func continueRowStamp(_ row: WatchProgress) -> String {
        "\(row.id)|\(row.updatedAt.timeIntervalSinceReferenceDate)"
    }

    /// The Continue Watching rows the viewer has moved PAST: an episode at or
    /// after the row's own was marked watched after the row was last written.
    ///
    /// The row keeps one card per show — its newest unfinished episode — and a
    /// finished episode's row is retired. So finishing S2E2 handed the card to
    /// whatever older row the show still had, S2E1 at twenty seconds or S1E3
    /// half-watched weeks ago, and Continue Watching went BACK instead of on to
    /// S2E3; the furthest-episode rule never ran, because a show with any
    /// unfinished row gets no Next Up card. A row newer than every such mark is
    /// the viewer going back to it on purpose, and stays.
    private nonisolated static func supersededContinueRows(
        _ rows: [WatchProgress], watched: [WatchedItem]
    ) -> Set<String> {
        let episodic = rows.filter { $0.season != nil && $0.episode != nil }
        guard !episodic.isEmpty else { return [] }
        let shows = Set(episodic.map(\.metaID))
        var marks: [String: [(season: Int, episode: Int, at: Date)]] = [:]
        for item in watched where shows.contains(item.contentID) {
            guard let season = item.season, let episode = item.episode else { continue }
            marks[item.contentID, default: []].append((season, episode, item.watchedAt))
        }
        var superseded: Set<String> = []
        for row in episodic {
            guard let season = row.season, let episode = row.episode,
                  let showMarks = marks[row.metaID] else { continue }
            if showMarks.contains(where: { ($0.season, $0.episode) >= (season, episode) && $0.at > row.updatedAt }) {
                superseded.insert(continueRowStamp(row))
            }
        }
        return superseded
    }

    /// One show this pass needs metadata for.
    ///
    /// Two kinds, fetched together in a single bounded pass: shows that are
    /// ALREADY in Continue Watching (metadata is needed only to count their
    /// new episodes) and shows the viewer has watched but has no progress row
    /// for (which additionally get a synthesised Next Up card).
    private struct NextUpTarget {
        let contentID: String
        let contentType: String
        let lastWatchedAt: Date
        let wantsCard: Bool
    }

    private func refreshNextUpContinueItems() async {
        let allActiveRows = progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
        let superseded = Self.supersededContinueRows(allActiveRows, watched: Array(watched.items.values))
        // Published before any fetch below. A stale row that stayed up while
        // up to twenty shows' metadata loaded WAS the wrong-episode card; for
        // that moment the show simply has no card until its Next Up is ready.
        if superseded != supersededContinueRows { supersededContinueRows = superseded }
        // A superseded show counts as having no progress row, so it gets a
        // synthesised Next Up card like any other watched show.
        let activeRows = allActiveRows.filter { !superseded.contains(Self.continueRowStamp($0)) }
        let activeMetaIDs = Set(activeRows.map(\.metaID))
        // Series already on the row. No card is synthesised for these — they
        // have a real progress row — but they still need their episode list so
        // the "+N new episodes" badge can be computed for them.
        let activeSeries = activeRows
            .filter { $0.season != nil && ($0.type == "series" || $0.type == "tv") }
            .prefix(20)
            .map { NextUpTarget(contentID: $0.metaID, contentType: $0.type,
                                lastWatchedAt: $0.updatedAt, wantsCard: false) }

        let watchedSeries = watched.items.values
            .filter { ($0.contentType == "series" || $0.contentType == "tv") && $0.season != nil && $0.episode != nil }
            .sorted { $0.watchedAt > $1.watchedAt }
            .deduplicatedByContentID()
            .filter { !activeMetaIDs.contains($0.contentID) }
            // Removed from Continue Watching means removed, including the
            // synthesised suggestion that would otherwise replace the card.
            .filter { !progressStore.dismissedNextUpShows.contains($0.contentID) }
            .prefix(20)
            .map { NextUpTarget(contentID: $0.contentID, contentType: $0.contentType,
                                lastWatchedAt: $0.watchedAt, wantsCard: true) }

        let targets = activeSeries + watchedSeries
        // When the viewer first STARTED each show, and how far they have got.
        // Built once, off the per-show loop, from data that already syncs
        // everywhere (see `startedWatchingByShow`).
        let startedAt = startedWatchingByShow()
        let reached = reachedEpisodesByShow()

        // Bounded-concurrent, not serial. These are full-series metadata
        // responses — among the largest payloads in the app — and fetching up to
        // twenty of them one after another meant ten to twenty seconds on a cold
        // cache before a single Next Up card appeared. `boundedConcurrentMap`
        // preserves order, and the result is re-sorted below anyway.
        let fetched = await boundedConcurrentMap(
            targets, limit: AddonSweepLimits.catalogs
        ) { target -> (meta: MetaItem, target: NextUpTarget)? in
            guard let addon = addonManager.metaAddon(for: target.contentType, id: target.contentID),
                  let meta = try? await StremioAPI.meta(
                      addon: addon, type: target.contentType, id: target.contentID
                  )
            else { return nil }
            return (meta, target)
        }
        // The episode walking below is pure computation over the fetched
        // metas — up to 40 FULL series' episode lists, each walked several
        // times with per-episode date parses. Snapshot what it needs from the
        // main-actor stores (cheap: a key set and two bools), then run it
        // detached; only the publish hops back. On an A8 this loop used to be
        // hundreds of milliseconds ON the main actor at every launch and
        // after every watched/progress mutation.
        let watchedKeys = Set(watched.items.keys)
        let showUnaired = homeCatalogSettings.showUnairedNextUp
        let fromFurthest = homeCatalogSettings.nextUpFromFurthestEpisode
        let entries = fetched.compactMap { $0 }
        let (rows, counts) = await Task.detached(priority: .userInitiated) {
            var rows: [WatchProgress] = []
            var counts: [String: Int] = [:]
            for entry in entries {
                // Keyed by the CANONICAL id the watch/progress stores use, not
                // the id the meta addon echoed back — a fallback meta addon can
                // answer with its own scheme (tvdb:, anidb:…), and rows/badges
                // keyed by that never matched the stores (badge missing) and
                // resumed into a sources page no stream addon claims.
                let contentID = entry.target.contentID
                let count = Self.newEpisodeCount(in: entry.meta,
                                                 startedAt: startedAt[contentID],
                                                 reached: reached[contentID] ?? [])
                if count > 0 { counts[contentID] = count }
                guard entry.target.wantsCard,
                      let next = Self.nextUpEpisode(in: entry.meta, contentID: contentID,
                                                    watchedKeys: watchedKeys,
                                                    showUnaired: showUnaired,
                                                    fromFurthest: fromFurthest) else { continue }
                rows.append(Self.nextUpProgress(meta: entry.meta, contentID: contentID, episode: next,
                                                lastWatchedAt: entry.target.lastWatchedAt,
                                                newEpisodeCount: count))
            }
            return (rows, counts)
        }.value
        if !Task.isCancelled {
            nextUpContinueItems = rows
            newEpisodeCounts = counts
        }
    }

    /// metaID → when this viewer first watched anything of that title.
    ///
    /// Derived rather than stored, from the two things that already sync
    /// everywhere: watch history (account, Trakt, SIMKL, Stremio) and stored
    /// playback positions. That is what makes the badge agree across devices
    /// without a new synced field — and it means an imported Trakt history,
    /// which carries each episode's ORIGINAL watch time, gives the true start
    /// date rather than the import date.
    private func startedWatchingByShow() -> [String: Date] {
        var out: [String: Date] = [:]
        for item in watched.items.values {
            if let existing = out[item.contentID], existing <= item.watchedAt { continue }
            out[item.contentID] = item.watchedAt
        }
        for row in progressStore.items.values {
            if let existing = out[row.metaID], existing <= row.updatedAt { continue }
            out[row.metaID] = row.updatedAt
        }
        return out
    }

    /// metaID → every episode the viewer has reached, watched or merely
    /// started. "Reached" deliberately includes a part-watched episode: the
    /// one you are in the middle of is not something you are behind on.
    ///
    /// A SET rather than a single furthest point, because the furthest point
    /// has to be resolved against AIR DATES, which only the metadata knows —
    /// see `newEpisodeCount`.
    private func reachedEpisodesByShow() -> [String: Set<SeasonEpisode>] {
        var out: [String: Set<SeasonEpisode>] = [:]
        func offer(_ id: String, _ season: Int?, _ episode: Int?) {
            guard let season, let episode else { return }
            out[id, default: []].insert(SeasonEpisode(season: season, episode: episode))
        }
        for item in watched.items.values { offer(item.contentID, item.season, item.episode) }
        for row in progressStore.items.values { offer(row.metaID, row.season, row.episode) }
        return out
    }

    /// How many episodes are waiting AHEAD of the viewer that aired after they
    /// started the show.
    ///
    /// Two conditions, and both are load-bearing:
    ///
    /// * **After the furthest episode they have reached.** Counting every
    ///   unwatched episode would include the one they are 60% of the way
    ///   through, so a show you are actively keeping up with would claim you
    ///   were behind on it.
    /// * **Aired after they started the show.** Working through a back
    ///   catalogue is not being behind, and without this a series that
    ///   finished years ago would sit at a permanent "+49" from the moment
    ///   someone started episode one.
    ///
    /// An episode with no known air date is skipped rather than assumed new.
    private nonisolated static func newEpisodeCount(in meta: MetaItem, startedAt: Date?,
                                                    reached: Set<SeasonEpisode>) -> Int {
        guard let startedAt, !reached.isEmpty else { return 0 }
        let all = meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return 0 }
        let now = Date()

        // The furthest episode reached that has ACTUALLY AIRED. Unaired
        // episodes are excluded from this even when they carry a watched row:
        // an episode that has not been broadcast cannot have been watched, and
        // "Mark Season Watched" used to stamp every episode a season lists,
        // including next month's finale. Taking those at face value pinned the
        // furthest point at the end of the season, so the show could never
        // report a new episode again.
        var furthest: SeasonEpisode?
        for episode in all {
            guard let season = episode.season, let number = episode.episode else { continue }
            guard let aired = episode.airedDate, aired <= now else { continue }
            let point = SeasonEpisode(season: season, episode: number)
            guard reached.contains(point) else { continue }
            if furthest == nil || point > furthest! { furthest = point }
        }
        guard let furthest else { return 0 }

        return all.reduce(into: 0) { total, episode in
            guard let season = episode.season, let number = episode.episode else { return }
            guard SeasonEpisode(season: season, episode: number) > furthest else { return }
            guard let aired = episode.airedDate, aired > startedAt, aired <= now else { return }
            total += 1
        }
    }

    private nonisolated static func nextUpEpisode(in meta: MetaItem, contentID: String,
                                                  watchedKeys: Set<String>,
                                                  showUnaired: Bool,
                                                  fromFurthest: Bool) -> MetaVideo? {
        let all = meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return nil }

        func isWatched(_ episode: MetaVideo) -> Bool {
            // The canonical store id, not `meta.id` — a fallback meta addon
            // can echo its own id scheme, and history is not keyed by that.
            // (`watchedKeys` is a snapshot of the watched store's keys, taken
            // on the main actor by the caller.)
            watchedKeys.contains(WatchedItem.key(contentID: contentID,
                                                 season: episode.season ?? 0,
                                                 episode: episode.episode))
        }
        // "Show unaired Next Up" was in this row's refresh key but never in the
        // selection, so Home offered an episode airing next week — with no
        // streams behind it — while Detail's Play button, which does honour the
        // setting, offered something watchable for the very same show.
        func isEligible(_ episode: MetaVideo) -> Bool {
            showUnaired || episode.hasAired
        }

        if fromFurthest,
           let furthestIndex = all.lastIndex(where: isWatched),
           furthestIndex + 1 < all.endIndex {
            return all[(furthestIndex + 1)...].first(where: isEligible)
        }

        return all.first { !isWatched($0) && isEligible($0) }
    }

    private nonisolated static func nextUpProgress(meta: MetaItem, contentID: String, episode: MetaVideo,
                                                   lastWatchedAt: Date, newEpisodeCount: Int) -> WatchProgress {
        // The canonical show id + a canonical episode key under it. Using the
        // addon-echoed `meta.id`/`episode.id` made the synthesised row an
        // identity no other store row (or stream addon) matched. Only tt ids
        // take the `show:season:episode` form — exotic schemes (kitsu: …)
        // shape their episode ids differently, so keep theirs.
        var episodeID = episode.id
        if contentID.hasPrefix("tt"), let s = episode.season, let e = episode.episode {
            episodeID = "\(contentID):\(s):\(e)"
        }
        // A Next Up episode that has AIRED since the viewer last watched the
        // show is newly available and belongs near the top; one that had
        // already aired before their last watch is just the next back-catalogue
        // episode and keeps the show's own recency. Stamping with the air date
        // (stable across refreshes, unlike `Date()`) floats the new episode up
        // through `continueOrder`'s recency sort without reordering everything
        // on every pass.
        let lastWatched = lastWatchedAt
        var availableAt = lastWatched
        if let aired = episode.airedDate, aired > lastWatched, aired <= Date() {
            availableAt = aired
        }
        return WatchProgress(
            id: episodeID,
            metaID: contentID,
            type: "series",
            name: meta.name,
            poster: meta.poster,
            background: meta.background,
            logo: meta.logo,
            season: episode.season,
            episode: episode.episode,
            episodeTitle: episode.title,
            episodeThumbnail: episode.thumbnail,
            positionSeconds: 0,
            durationSeconds: 1,
            streamURL: nil,
            updatedAt: availableAt,
            newEpisodeCount: newEpisodeCount,
            // Not aired yet (with "Show unaired Next Up" on): when it airs,
            // for the card's state line.
            airsAt: episode.hasAired ? nil : (episode.airedDate ?? .distantFuture)
        )
    }

    // MARK: Rows

    /// Continue Watching card art: the episode still when enabled and present,
    /// otherwise the show backdrop/poster.
    private func continueImage(_ progress: WatchProgress) -> String? {
        if homeCatalogSettings.useEpisodeThumbnailsInCw, let thumb = progress.episodeThumbnail, !thumb.isEmpty {
            return thumb
        }
        return progress.background ?? progress.poster ?? catalogMeta(for: progress.metaID)?.background ?? catalogMeta(for: progress.metaID)?.poster
    }

    /// A hero-bar item for a Continue Watching entry. Progress rows only carry
    /// name/art, so prefer the full MetaItem when the title is also in a
    /// loaded catalog row (description, genres, rating…).
    private func heroItem(from progress: WatchProgress) -> MetaItem {
        if let match = catalogMeta(for: progress.metaID) { return match }
        return MetaItem(
            id: progress.metaID, type: progress.type, name: progress.name,
            poster: progress.poster, background: progress.background, logo: progress.logo
        )
    }

    /// The loaded catalog item for an id, via the view model's O(1) index.
    private func catalogMeta(for id: String) -> MetaItem? {
        viewModel.itemIndex[id]
    }
}

/// Focus-styled "Try Again" pill shared by network-failure empty states.
struct RetryLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: CueSpacing.sm) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 20, weight: .semibold))
            Text("Try Again")
                .font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(isFocused ? theme.palette.onSecondary : theme.palette.textPrimary)
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .background(Capsule().fill(isFocused ? theme.palette.secondary : Color.primary.opacity(0.1)))
        .overlay(Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
        .focusLift(CueFocus.card, isFocused)
        .animation(PerformanceSettingsStore.shared.buttonMotion(FusionMotion.focusEntry),
                   value: isFocused)
    }
}

extension View {
    /// Small helper because `.onFocusChange` reads better at call sites than
    /// the focusable/onChange dance.
    func onFocusChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(FocusChangeModifier(action: action))
    }
}

private struct FocusChangeModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused) { _, newValue in
                action(newValue)
            }
            // onChange misses the INITIAL value: a lazy cell created by a fast
            // scroll (or at launch) can be born already-focused with no change
            // event.
            .onAppear {
                if isFocused { action(true) }
            }
            // …and the mirror: a cell that leaves the tree (a lazy row
            // unloading it, a reload remounting the row) never gets the
            // false, so its caption stayed "lowered" — a card that read as
            // focused while the card actually under focus only moved its
            // name and date. Reset on the way out; `onAppear` re-seeds a
            // card that comes back already focused.
            .onDisappear {
                action(false)
            }
    }
}




// MARK: - Home rows (UIKit)

/// The rows in UIKit. Focus moves natively over real poster cells; the
/// system never scrolls (scrolling is off). On every focus change WE move
/// the row — and the rows — to the fixed spot with a UIKit animation, which
/// runs in Core Animation (off the main thread, cleanly re-aimable), and
/// the focused cell grows to box width in the same animation.
struct HomeUIKitView: View {
    @ObservedObject private var probe = RenderProbe.shared
    let rows: [HomeRow]
    /// The Continue Watching row's id (landscape cards, Select resumes).
    let continueRowID: String
    let progress: [String: WatchProgress]
    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    /// The focused title (drives the background).
    @State private var focused: MetaItem?
    /// Its colour (the "Title colour" background only).
    @State private var tint: Color?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if probe.flags.backgroundTint { background }
            FixedFocusRows(rows: rows, continueRowID: continueRowID, progress: progress,
                           onSelect: onSelect, onResume: onResume) { item in
                focused = item
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        // Title colour style only: follows the focused title once you've
        // paused on it.
        .task(id: focused?.id) {
            guard FixedFocusBackground.current == .titleColor,
                  let item = focused, let url = item.background ?? item.poster else { return }
            // A brief rest on the title first (Render Lab → Tint delay): long
            // enough that fast scrolling doesn't flicker, short enough to
            // feel immediate.
            try? await Task.sleep(for: .seconds(probe.flags.tintDelay))
            guard !Task.isCancelled, let color = await SpotlightTint.color(for: url),
                  !Task.isCancelled else { return }
            // The extracted colour is tuned dark; lifted a little so the
            // background stays recognisably the image's colour.
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let lifted = Color(hue: h, saturation: s, brightness: max(b, 0.55))
            withAnimation(.easeInOut(duration: probe.flags.tintFade)) { tint = lifted }
        }
    }

    /// The background (Render Lab → Background): one fixed, designed colour —
    /// a deep gradient with a soft glow — or (for comparison) the focused
    /// title's colour. A black fade over the left third keeps text readable.
    @ViewBuilder
    private var background: some View {
        let style = FixedFocusBackground.current
        ZStack {
            // Even from top to bottom: no darker lower half, no corners.
            Color(white: 0.06)
            if let palette = style.palette {
                palette.top
                // Optional (Render Lab → Background glow). Large enough to
                // reach the right edge and corners evenly.
                if probe.flags.backgroundGlow {
                RadialGradient(colors: [palette.glow.opacity(0.55), palette.glow.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.62, y: 0.45), startRadius: 0, endRadius: 1900)
                }
            } else if let tint {
                // The title's colour, evenly over the whole surface.
                Rectangle().fill(tint.opacity(0.5))
            }
            // Dark (not black) at the edge, easing out across the first
            // quarter, clear by ~48 %.
            LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0),
                                   .init(color: .black.opacity(0.55), location: 0.24),
                                   .init(color: .black.opacity(0.25), location: 0.36),
                                   .init(color: .clear, location: 0.48)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .frame(width: 1920, height: 1080)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The new Home's background choices.
enum FixedFocusBackground: String, CaseIterable {
    case midnight, charcoal, teal, titleColor

    @MainActor static var current: FixedFocusBackground {
        FixedFocusBackground(rawValue: RenderProbe.shared.flags.backgroundStyle) ?? .midnight
    }

    var displayName: String {
        switch self {
        case .midnight: return "Midnight (blue-violet)"
        case .charcoal: return "Charcoal (warm grey)"
        case .teal: return "Deep teal"
        case .titleColor: return "Title colour (changes)"
        }
    }

    /// Fixed palettes: a dark top-to-bottom base and the glow's colour.
    var palette: (top: Color, bottom: Color, glow: Color)? {
        switch self {
        case .midnight: return (Color(red: 0.07, green: 0.05, blue: 0.14),
                                Color(red: 0.02, green: 0.02, blue: 0.05),
                                Color(red: 0.32, green: 0.16, blue: 0.62))
        case .charcoal: return (Color(red: 0.11, green: 0.10, blue: 0.09),
                                Color(red: 0.04, green: 0.04, blue: 0.035),
                                Color(red: 0.38, green: 0.32, blue: 0.26))
        case .teal: return (Color(red: 0.03, green: 0.09, blue: 0.10),
                            Color(red: 0.01, green: 0.03, blue: 0.04),
                            Color(red: 0.08, green: 0.40, blue: 0.42))
        case .titleColor: return nil
        }
    }
}

private struct FixedFocusRows: UIViewControllerRepresentable {
    let rows: [HomeRow]
    let continueRowID: String
    let progress: [String: WatchProgress]
    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onFocusItem: (MetaItem) -> Void

    func makeUIViewController(context: Context) -> FixedFocusRowsController {
        let controller = FixedFocusRowsController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: FixedFocusRowsController, context: Context) {
        apply(to: controller)
    }

    private func apply(to controller: FixedFocusRowsController) {
        controller.onSelect = onSelect
        controller.onResume = onResume
        controller.onFocusItem = onFocusItem
        controller.continueRowID = continueRowID
        controller.progress = progress
        controller.update(rows)
    }
}

/// Geometry shared by the controller and its cells (points, 1920 × 1080).
private enum FixedFocusMetrics {
    /// The original Home's gap.
    static let gap: CGFloat = Spotlight.spacing
    /// The original margin: the box lines up with the row names; a strip
    /// of the previous poster peeks in left of it.
    static let inset: CGFloat = Spotlight.screenInset
    /// Text next to the rounded box is indented a little (optical
    /// alignment: the corner makes the edge look further in than it is).
    static let textIndent: CGFloat = 5
    static var titleInset: CGFloat { inset + textIndent }
    /// The original Home's sizes exactly (box 16:9 and posters 2:3, both
    /// 420 pt tall) — about 3½ posters right of the box.
    static let height: CGFloat = Spotlight.rowHeight
    static let posterWidth: CGFloat = Spotlight.posterWidth
    static let boxWidth: CGFloat = Spotlight.boxWidth
    static var pitch: CGFloat { posterWidth + gap }
    /// The row name (the original Home's size): its line, then a small gap
    /// to the row — it belongs to the row.
    static let titleLine: CGFloat = 48
    static let titleHeight: CGFloat = titleLine + 14
    /// The row below shows as much as on the original Home at the bottom
    /// edge (a little under half); the row above shows what's left of it.
    /// Rows further up / down than the neighbours: a whole row apart.
    static var rowPitch: CGFloat { titleHeight + height + 70 }
    /// The row above: its posters' lower fifth shows at the top.
    static var aboveVisible: CGFloat { height / 5 }
    /// The row below: this much of its posters shows at the bottom (as on
    /// the original Home — a little under half).
    static var belowVisible: CGFloat { Spotlight.previewVisibleHeight }
    /// Rows other than the focused one (the preview below).
    static let dimmedAlpha: CGFloat = 0.45
    /// The focused row's name: exactly where the original Home had it.
    static var rowTop: CGFloat {
        Spotlight.catalogTitleY(screenHeight: 1080, topPadding: Spotlight.topPaddingUnderNav)
    }
    /// The box, on screen.
    static var boxFrame: CGRect {
        CGRect(x: inset, y: rowTop + titleHeight, width: boxWidth, height: height)
    }
}

final class FixedFocusRowsController: UIViewController, UICollectionViewDataSource,
                                      UICollectionViewDelegateFlowLayout {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onResume: (WatchProgress) -> Void = { _ in }
    /// The focused title (for the background tint).
    var onFocusItem: (MetaItem) -> Void = { _ in }
    /// Continue Watching: landscape cards (no growing, no fixed box — the
    /// focused card itself sits at the spot), Select resumes.
    var continueRowID = ""
    var progress: [String: WatchProgress] = [:]

    func isContinue(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && rows[rowIndex].id == continueRowID
    }
    private(set) var rows: [HomeRow] = []
    /// Each row's title at the spot.
    private(set) var selected: [String: Int] = [:]
    /// The row focus is in (only it has a grown cell).
    private(set) var focusedRow = 0
    private var outer: UICollectionView!
    /// Reuse identifiers registered so far (one per catalog).
    private var registeredRows = Set<String>()
    /// THE FIXED BOX: on Left/Right it never moves — only its content
    /// changes; the posters slide in behind it.
    private let box = FixedFocusBoxView()
    private var hasFocus = false

    func update(_ rows: [HomeRow]) {
        let changed = rows.map(\.id) != self.rows.map(\.id)
            || zip(rows, self.rows).contains { $0.items.count != $1.items.count }
        self.rows = rows
        if changed, isViewLoaded { outer.reloadData() }
    }

    override func loadView() {
        let root = UIView()
        let layout = FixedFocusRowsLayout()
        layout.focusedRow = { [weak self] in self?.focusedRow ?? 0 }
        outer = UICollectionView(frame: .zero, collectionViewLayout: layout)
        outer.backgroundColor = .clear
        outer.clipsToBounds = false
        // The system never scrolls: only our animation moves the rows.
        outer.isScrollEnabled = false
        outer.showsVerticalScrollIndicator = false
        outer.contentInsetAdjustmentBehavior = .never
        outer.dataSource = self
        outer.delegate = self
        root.addSubview(outer)
        box.frame = FixedFocusMetrics.boxFrame
        box.alpha = 0
        box.isUserInteractionEnabled = false
        root.addSubview(box)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Taller than the screen: rows sliding out of (or into) the screen
        // stay inside the list's visible area, so UIKit keeps their cells
        // and they SLIDE — outside it, it drops them and fades them in place.
        outer.frame = view.bounds.insetBy(dx: 0, dy: -FixedFocusRowsLayout.overscan)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        // One reuse identifier PER CATALOG: UIKit only ever hands a row cell
        // back to its own catalog — with its poster row's native focus
        // memory (`remembersLastFocusedIndexPath`) and scroll position
        // intact. (One shared identifier recycled a row's cell, memory and
        // all, for a different catalog: rows "forgot" their title.)
        let reuseID = "row-" + rows[indexPath.item].id
        if registeredRows.insert(reuseID).inserted {
            cv.register(FixedFocusRowCell.self, forCellWithReuseIdentifier: reuseID)
        }
        let cell = cv.dequeueReusableCell(withReuseIdentifier: reuseID, for: indexPath) as! FixedFocusRowCell
        cell.configure(rowIndex: indexPath.item, controller: self)
        // (contentView, not the cell: the collection view resets a cell's
        // own alpha from its layout attributes.)
        cell.contentView.alpha = indexPath.item == focusedRow ? 1 : FixedFocusMetrics.dimmedAlpha
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: 1920, height: FixedFocusMetrics.titleHeight + FixedFocusMetrics.height)
    }

    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { false }

    /// A row coming into view mid-animation gets its dimming too.
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        cell.contentView.alpha = indexPath.item == focusedRow ? 1 : FixedFocusMetrics.dimmedAlpha
    }

    /// Focus moved (natively). Left/Right: the box stays, its content
    /// changes, the row slides behind it. Up/Down ("opening a book"): the
    /// box steps aside, the new row's title grows into the box as the rows
    /// move up; at the end the box takes over again, in the same place.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let cell = context.nextFocusedView as? FixedFocusPosterCell,
              let rowCell = cell.rowCell, rows.indices.contains(rowCell.rowIndex) else { return }
        let rowIndex = rowCell.rowIndex
        let row = rows[rowIndex]
        guard row.items.indices.contains(cell.itemIndex) else { return }
        let item = row.items[cell.itemIndex]
        onFocusItem(item)
        let rowChanged = rowIndex != focusedRow || !hasFocus
        let continueRow = isContinue(rowIndex)
        let entry = continueRow ? progress[item.id] : nil
        // Up/Down is the "opening": the box steps aside, the new row's title
        // grows into it, the old one shrinks back to a poster.
        let verticalDrift = false
        let direction: CGFloat = rowChanged
            ? (rowIndex > focusedRow ? 1 : -1)
            : (cell.itemIndex >= (selected[row.id] ?? 0) ? 1 : -1)
        let oldRowCell = rowChanged
            ? outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell : nil
        if rowChanged, !verticalDrift, box.alpha == 1 {
            // Opening: the old row's cell first takes on the box's exact
            // look (still the focused row here) — the box can step aside
            // without anything changing — and then shrinks, animated.
            oldRowCell?.contentHidden = false
            // Commit that look NOW: the animation below continues from what's
            // on screen (beginFromCurrentState), and without this it started
            // from the plain poster — the old box was instantly small.
            CATransaction.flush()
        }
        selected[row.id] = cell.itemIndex
        focusedRow = rowIndex

        if rowChanged, !verticalDrift {
            // The opening: the grown cell shows its own content.
            box.alpha = 0
            rowCell.contentHidden = false
        } else if box.alpha < 1 {
            // Left/Right while an opening is still running: the box takes
            // over (instead of the new cell growing in visibly) — a quick
            // fade over the moving cell, then the cell steps back.
            box.show(item, progress: entry, animated: false)
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
                self.box.alpha = 1
            } completion: { _ in
                if self.box.alpha == 1 { rowCell.contentHidden = true }
            }
        } else {
            // The box stays; its content drifts (sideways on Left/Right, up
            // or down on Up/Down) while the row(s) move underneath.
            rowCell.contentHidden = true
            oldRowCell?.contentHidden = true
            box.show(item, progress: entry, animated: true, direction: direction,
                     vertical: rowChanged)
        }
        // Up/Down moves much more than a step: its own, longer spring.
        // Continue Watching's cards are box-wide: a step travels 2.5× as far
        // as a poster step — its own, slightly longer duration.
        let duration = rowChanged ? Motion.durations.vertical
            : continueRow ? Motion.durations.continueMove : Motion.durations.move
        let damping = rowChanged ? Motion.durations.verticalDamping : 1
        // For the cells' Up/Down details: the image drift's direction and
        // the outlines' own, gradual crossfade (see `setGrown`).
        FixedFocusPosterCell.vertical = rowChanged && hasFocus
            ? (direction: direction, duration: duration) : nil
        defer { FixedFocusPosterCell.vertical = nil }
        FixedFocusMotion.run(vertical: rowChanged, duration: duration, damping: damping) {
            self.applyDimming()
            oldRowCell?.relayout()
            rowCell.focus(index: cell.itemIndex)
            // The row list doesn't scroll: its layout places every row
            // around the focused one, and the rows glide to their places.
            self.outer.collectionViewLayout.invalidateLayout()
            self.outer.layoutIfNeeded()
        } completion: { _ in
            guard rowChanged, self.box.alpha < 1, self.focusedRow == rowIndex,
                  let current = self.selected[row.id], row.items.indices.contains(current) else { return }
            // Hand over to the box: identical look, same place — no jump.
            // (The title focused NOW — a Left/Right may have followed.)
            let now = row.items[current]
            self.box.show(now, progress: self.isContinue(rowIndex) ? self.progress[now.id] : nil,
                          animated: false)
            self.box.alpha = 1
            rowCell.contentHidden = true
        }
        hasFocus = true
    }

    func select(_ item: MetaItem, rowIndex: Int) {
        if isContinue(rowIndex), let entry = progress[item.id] {
            onResume(entry)
        } else {
            onSelect(item)
        }
    }

    /// The focused row full, every other row dimmed.
    private func applyDimming() {
        for case let cell as FixedFocusRowCell in outer.visibleCells {
            cell.contentView.alpha = cell.rowIndex == focusedRow ? 1 : FixedFocusMetrics.dimmedAlpha
        }
    }
}

/// The fixed box: backdrop, shade, logo, focus outline. Content changes
/// crossfade; the box itself never moves.
final class FixedFocusBoxView: UIView {
    /// One "page" of the box: backdrop, shade, logo. A change either slides
    /// a new page in (the old one out) or crossfades on the current page.
    private final class Page: UIView {
        let backdrop = UIImageView()
        let shade = CAGradientLayer()
        let logo = UIImageView()
        /// Continue Watching: the state line (no logo).
        let state = FixedFocusProgressView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backdrop.contentMode = .scaleAspectFill
            backdrop.clipsToBounds = true
            addSubview(backdrop)
            shade.colors = [UIColor.clear.cgColor,
                            UIColor.black.withAlphaComponent(Spotlight.logoScrimOpacity).cgColor]
            shade.startPoint = CGPoint(x: 0.5, y: 0.5)
            shade.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(shade)
            logo.contentMode = .scaleAspectFit
            addSubview(logo)
            state.alpha = 0
            addSubview(state)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            backdrop.frame = bounds
            shade.frame = bounds
            layer.insertSublayer(shade, above: backdrop.layer)
            logo.frame = CGRect(x: Spotlight.logoInset,
                                y: bounds.height - Spotlight.logoInset - bounds.height * 0.28,
                                width: bounds.width * 0.55, height: bounds.height * 0.28)
            state.frame = CGRect(x: 24, y: bounds.height - 22 - 34, width: bounds.width - 48, height: 34)
        }

        func show(_ item: MetaItem, progress: WatchProgress?) {
            if let progress {
                // Continue Watching: its card's look — the still, the state
                // line, no logo.
                FixedFocusImages.load(progress.episodeThumbnail ?? item.background ?? item.poster,
                                      into: backdrop, maxDimension: FixedFocusMetrics.boxWidth)
                FixedFocusImages.load(nil, into: logo, maxDimension: 0)
                state.show(progress)
                state.alpha = 1
                return
            }
            state.alpha = 0
            FixedFocusImages.load(item.background ?? item.poster, into: backdrop,
                                  maxDimension: FixedFocusMetrics.boxWidth)
            FixedFocusImages.load(item.logo, into: logo,
                                  maxDimension: FixedFocusMetrics.boxWidth * 0.55)
        }
    }

    /// The box's info (name, facts) under it — part of the box: it stays
    /// put and drifts with it.
    private final class InfoPage: UIView {
        let name = UILabel()
        let facts = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            name.font = .systemFont(ofSize: 23, weight: .regular)
            name.textColor = .white
            facts.font = .systemFont(ofSize: 20, weight: .medium)
            facts.textColor = UIColor.white.withAlphaComponent(0.62)
            addSubview(name)
            addSubview(facts)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            name.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 30)
            facts.frame = CGRect(x: 0, y: 36, width: bounds.width, height: 28)
        }

        func show(_ item: MetaItem, progress: WatchProgress?) {
            name.text = item.name
            facts.text = progress?.episodeTitle
                ?? TitleBlock.metaSegments(for: item, seriesSize: TitleBlock.seriesSizeText(item))
                    .joined(separator: "  •  ")
        }
    }

    /// Clips the pages to the box's rounded shape (the box itself doesn't
    /// clip: its info sits below it).
    private let clip = UIView()
    private var page = Page()
    private var infoPage = InfoPage()
    private var shownID: String?
    /// The box's outline in the title's colour (Render Lab → Box outline:
    /// title colour); off: white.
    private let rim = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = Spotlight.cornerRadius
        clip.layer.cornerCurve = .continuous
        clip.backgroundColor = UIColor(white: 0.12, alpha: 1)
        addSubview(clip)
        clip.addSubview(page)
        addSubview(infoPage)
        rim.image = FixedFocusRim.image(.box, lineWidth: 4)
        addSubview(rim)
        // (A layer's border is drawn above its sublayers: above the pages.)
        layer.cornerRadius = Spotlight.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.cgColor
        applyOutlineStyle()
    }

    /// White border, or the rim (title colour / light / vivid).
    private func applyOutlineStyle() {
        let colored = RenderProbe.shared.flags.boxRimColored
        layer.borderWidth = colored ? 0 : 4
        rim.isHidden = !colored
        let style = FixedFocusRim.style
        FixedFocusRim.apply(style, to: rim.layer)
        rim.image = FixedFocusRim.image(.box, lineWidth: 4)
        if style != .titleColor { rim.tintColor = .white }
    }

    private func tintRim(for item: MetaItem, progress: WatchProgress?) {
        applyOutlineStyle()
        // (The poster's colour — the same the cells use, so the handover
        // between cell and box is seamless.)
        guard RenderProbe.shared.flags.boxRimColored, FixedFocusRim.style == .titleColor,
              let url = item.poster ?? item.background else { return }
        let id = item.id
        FixedFocusColors.color(for: url) { [weak self] color in
            guard let self, self.shownID == id else { return }
            UIView.animate(withDuration: Motion.durations.move) { self.rim.tintColor = color }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where the info sits: as under the cells (18 pt below, optically
    /// indented).
    private var infoFrame: CGRect {
        CGRect(x: FixedFocusMetrics.textIndent, y: bounds.height + 18, width: bounds.width, height: 70)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        rim.frame = bounds
        if page.layer.animationKeys()?.isEmpty ?? true { page.frame = bounds }
        if infoPage.layer.animationKeys()?.isEmpty ?? true { infoPage.frame = infoFrame }
    }

    /// `direction`: +1 moving right (new content comes from the right),
    /// −1 moving left. Render Lab → Box change: slide or crossfade.
    func show(_ item: MetaItem, progress: WatchProgress? = nil, animated: Bool,
              direction: CGFloat = 1, vertical: Bool = false) {
        guard item.id != shownID else { return }
        shownID = item.id
        tintRim(for: item, progress: progress)
        guard animated else {
            page.show(item, progress: progress)
            infoPage.show(item, progress: progress)
            return
        }
        if RenderProbe.shared.flags.boxDrift {
            // DRIFT: a crossfade with a hint of direction — the new image
            // fades in while shifting a little in the direction of travel,
            // the old one fades out shifting on. No seam, little movement.
            // (Up/Down: the same, vertically — from below on Down.)
            let shift: CGFloat = 30
            let dx = vertical ? 0 : direction * shift
            let dy = vertical ? direction * shift : 0
            let incoming = Page(frame: bounds.offsetBy(dx: dx, dy: dy))
            incoming.show(item, progress: progress)
            incoming.alpha = 0
            clip.addSubview(incoming)
            let outgoing = page
            page = incoming
            // The info drifts the same way, in sync.
            let infoIn = InfoPage(frame: infoFrame.offsetBy(dx: dx, dy: dy))
            infoIn.show(item, progress: progress)
            infoIn.alpha = 0
            addSubview(infoIn)
            let infoOut = infoPage
            infoPage = infoIn
            let infoTarget = infoFrame
            FixedFocusMotion.run(vertical: vertical,
                                 duration: vertical ? Motion.durations.vertical : Motion.durations.move,
                                 damping: 1) {
                incoming.frame = self.bounds
                incoming.alpha = 1
                outgoing.frame = self.bounds.offsetBy(dx: -dx, dy: -dy)
                outgoing.alpha = 0
                infoIn.frame = infoTarget
                infoIn.alpha = 1
                infoOut.frame = infoTarget.offsetBy(dx: -dx, dy: -dy)
                infoOut.alpha = 0
            } completion: { _ in
                if outgoing !== self.page { outgoing.removeFromSuperview() }
                if infoOut !== self.infoPage { infoOut.removeFromSuperview() }
            }
        } else {
            UIView.transition(with: page, duration: Motion.durations.fade,
                              options: [.transitionCrossDissolve, .beginFromCurrentState,
                                        .allowUserInteraction],
                              animations: { self.page.show(item, progress: progress) })
            UIView.transition(with: infoPage, duration: Motion.durations.fade,
                              options: [.transitionCrossDissolve, .beginFromCurrentState,
                                        .allowUserInteraction],
                              animations: { self.infoPage.show(item, progress: progress) })
        }
    }
}

/// Image loading for the UIKit cells: memory cache, then disk, then network
/// (decoded off the main thread); stale results are dropped.
@MainActor
enum FixedFocusImages {
    private static var requested: [ObjectIdentifier: String] = [:]

    static func load(_ url: String?, into view: UIImageView, maxDimension: CGFloat) {
        let slot = ObjectIdentifier(view)
        requested[slot] = url
        guard let url else { view.image = nil; return }
        let memoryKey = RemoteImage.memoryKey(url, maxDimension: maxDimension, maxPixels: nil)
        if let hit = ImageCache.shared.image(for: memoryKey) { view.image = hit; return }
        view.image = nil
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil)
        Task { @MainActor [weak view] in
            var image = await ImageCache.shared.diskImage(for: url, budget: budget, memoryKey: memoryKey)
            if image == nil, let remote = URL(string: url),
               let data = try? await ImageCache.shared.download(remote) {
                ImageCache.shared.insertData(data, for: url)
                image = ImageCache.decodeDownsampled(data, budget: budget)
            }
            guard let view, requested[slot] == url else { return }
            view.image = image
        }
    }
}

/// One row: its name and a horizontal collection view of posters.
final class FixedFocusRowCell: UICollectionViewCell, UICollectionViewDataSource,
                               UICollectionViewDelegateFlowLayout {
    private(set) var rowIndex = 0
    private weak var controller: FixedFocusRowsController?
    private let title = UILabel()
    private let strip: UICollectionView
    private var row: HomeRow? {
        guard let controller, controller.rows.indices.contains(rowIndex) else { return nil }
        return controller.rows[rowIndex]
    }
    private var selectedIndex: Int { row.flatMap { controller?.selected[$0.id] } ?? 0 }
    /// Only the focused row has a grown cell; the others are all posters.
    private var isFocusRow: Bool { controller?.focusedRow == rowIndex }
    /// Continue Watching: landscape cards.
    var isContinue: Bool { controller?.isContinue(rowIndex) == true }
    /// The grown cell's own content hidden (the fixed box shows it).
    var contentHidden = true {
        didSet { applyGrown() }
    }

    private let layout = FixedFocusStripLayout()

    override init(frame: CGRect) {
        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        layout.wideIndex = { [weak self] in
            guard let self, self.isFocusRow, !self.isContinue else { return nil }
            return self.selectedIndex
        }
        layout.cardWidth = { [weak self] in
            self?.isContinue == true ? FixedFocusMetrics.boxWidth : FixedFocusMetrics.posterWidth
        }
        clipsToBounds = false
        contentView.clipsToBounds = false
        title.font = .systemFont(ofSize: Spotlight.headerTitleSize, weight: .semibold)
        title.textColor = .white
        contentView.addSubview(title)
        strip.backgroundColor = .clear
        strip.clipsToBounds = false
        strip.isScrollEnabled = false
        strip.showsHorizontalScrollIndicator = false
        strip.contentInsetAdjustmentBehavior = .never
        strip.remembersLastFocusedIndexPath = true
        strip.dataSource = self
        strip.delegate = self
        strip.register(FixedFocusPosterCell.self, forCellWithReuseIdentifier: "poster")
        contentView.addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: FixedFocusMetrics.titleInset, y: 0, width: 1200,
                             height: FixedFocusMetrics.titleLine)
        // Wider than the screen on both sides: posters sliding in or out at
        // the edges keep their cells and SLIDE (outside the visible area
        // UIKit creates / drops them with a fade, in place).
        let over = FixedFocusStripLayout.overscan
        strip.frame = CGRect(x: -over, y: FixedFocusMetrics.titleHeight,
                             width: 1920 + 2 * over, height: FixedFocusMetrics.height)
    }

    /// The catalog (and its size) this cell last showed.
    private var shownRow: (id: String, count: Int)?

    func configure(rowIndex: Int, controller: FixedFocusRowsController) {
        self.rowIndex = rowIndex
        self.controller = controller
        title.text = row?.title
        // The same catalog coming back (it keeps its own cell): leave its
        // posters, scroll position and focus memory as they are — a reload
        // would erase exactly that. Only new content reloads.
        if let row, let shown = shownRow, shown.id == row.id, shown.count == row.items.count {
            return
        }
        shownRow = row.map { ($0.id, $0.items.count) }
        contentHidden = true
        strip.reloadData()
        strip.layoutIfNeeded()
        strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0)
    }

    /// Inside the controller's animation: grow the new, shrink the old,
    /// move the row so the new one sits at the spot.
    func focus(index: Int) {
        relayout()
        strip.contentOffset = CGPoint(x: offset(for: index), y: 0)
    }

    /// Re-lay out (grown cell or not) and restyle the visible cells.
    func relayout() {
        strip.collectionViewLayout.invalidateLayout()
        strip.layoutIfNeeded()
        applyGrown()
        if !isFocusRow { strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0) }
    }

    private func applyGrown() {
        for cell in strip.visibleCells {
            guard let poster = cell as? FixedFocusPosterCell else { continue }
            poster.setGrown(isFocusRow && poster.itemIndex == selectedIndex,
                            contentHidden: contentHidden)
        }
    }

    /// The row offset that puts title `index` at the spot. Exact: every
    /// title before it is card-wide (`FixedFocusStripLayout`).
    private func offset(for index: Int) -> CGFloat {
        let card = isContinue ? FixedFocusMetrics.boxWidth : FixedFocusMetrics.posterWidth
        return CGFloat(index) * (card + FixedFocusMetrics.gap)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        row?.items.count ?? 0
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath) as! FixedFocusPosterCell
        if let row {
            let item = row.items[indexPath.item]
            cell.configure(item, index: indexPath.item, rowCell: self,
                           progress: isContinue ? controller?.progress[item.id] : nil,
                           landscape: isContinue)
            cell.setGrown(isFocusRow && indexPath.item == selectedIndex, contentHidden: contentHidden)
        }
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: isFocusRow && indexPath.item == selectedIndex ? FixedFocusMetrics.boxWidth
                                                                     : FixedFocusMetrics.posterWidth,
               height: FixedFocusMetrics.height)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row, row.items.indices.contains(indexPath.item) else { return }
        controller?.select(row.items[indexPath.item], rowIndex: rowIndex)
    }
}

/// A poster cell: a WINDOW onto two fixed-size images — the portrait
/// poster and the box-sized backdrop (with logo). Growing opens the window;
/// nothing is stretched. Backdrop and logo load only once it grows.
final class FixedFocusPosterCell: UICollectionViewCell {
    /// Set by the controller while it starts an Up/Down movement.
    static var vertical: (direction: CGFloat, duration: Double)?

    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private let poster = UIImageView()
    private let backdrop = UIImageView()
    private let shade = CAGradientLayer()
    private let logo = UIImageView()
    /// The grown cell's own outline — fades in as it opens (Up/Down), while
    /// the fixed box is away.
    private let outline = UIView()
    /// The title's info (name, facts) — BELOW the cell, so it travels with
    /// its title: in with it, away with it.
    private let info = UIView()
    private let name = UILabel()
    private let facts = UILabel()
    private var item: MetaItem?
    private var backdropFor: String?
    /// The poster's own-coloured rim (pre-rendered, tinted — see
    /// `FixedFocusRim`). Sits with the poster; the box covers it.
    private let rim = UIImageView()
    /// The opening's outline in the title's colour (matches the box's).
    private let outlineRim = UIImageView()
    private var rimColor: UIColor?
    /// Continue Watching: a landscape card (backdrop always), with its state.
    private var landscape = false
    private let state = FixedFocusProgressView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = Spotlight.cornerRadius
        contentView.layer.cornerCurve = .continuous
        for view in [backdrop, poster] {
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            contentView.addSubview(view)
        }
        shade.colors = [UIColor.clear.cgColor,
                        UIColor.black.withAlphaComponent(Spotlight.logoScrimOpacity).cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        backdrop.layer.addSublayer(shade)
        logo.contentMode = .scaleAspectFit
        backdrop.addSubview(logo)
        state.alpha = 0
        backdrop.addSubview(state)
        rim.isUserInteractionEnabled = false
        rim.alpha = 0
        contentView.addSubview(rim)
        outlineRim.isUserInteractionEnabled = false
        outlineRim.image = FixedFocusRim.image(.box, lineWidth: 4)
        outlineRim.alpha = 0
        addSubview(outlineRim)
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = UIColor.white.cgColor
        outline.layer.borderWidth = 4
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        addSubview(outline)
        name.font = .systemFont(ofSize: 23, weight: .regular)
        name.textColor = .white
        facts.font = .systemFont(ofSize: 20, weight: .medium)
        facts.textColor = UIColor.white.withAlphaComponent(0.62)
        info.addSubview(name)
        info.addSubview(facts)
        info.alpha = 0
        info.isUserInteractionEnabled = false
        addSubview(info)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Fixed sizes, anchored left: the cell's width only reveals.
        poster.frame = CGRect(x: 0, y: 0, width: FixedFocusMetrics.posterWidth, height: FixedFocusMetrics.height)
        backdrop.frame = CGRect(x: 0, y: 0, width: FixedFocusMetrics.boxWidth, height: FixedFocusMetrics.height)
        shade.frame = backdrop.bounds
        logo.frame = CGRect(x: Spotlight.logoInset,
                            y: FixedFocusMetrics.height - Spotlight.logoInset - FixedFocusMetrics.height * 0.28,
                            width: FixedFocusMetrics.boxWidth * 0.55, height: FixedFocusMetrics.height * 0.28)
        outline.frame = bounds
        outlineRim.frame = CGRect(x: 0, y: 0, width: FixedFocusMetrics.boxWidth, height: FixedFocusMetrics.height)
        let rimSize = landscape
            ? CGSize(width: FixedFocusMetrics.boxWidth, height: FixedFocusMetrics.height)
            : CGSize(width: FixedFocusMetrics.posterWidth, height: FixedFocusMetrics.height)
        rim.frame = CGRect(origin: .zero, size: rimSize)
        state.frame = CGRect(x: 24, y: FixedFocusMetrics.height - 22 - 34,
                             width: FixedFocusMetrics.boxWidth - 48, height: 34)
        info.frame = CGRect(x: FixedFocusMetrics.textIndent, y: FixedFocusMetrics.height + 18,
                            width: FixedFocusMetrics.boxWidth, height: 70)
        name.frame = CGRect(x: 0, y: 0, width: info.bounds.width, height: 30)
        facts.frame = CGRect(x: 0, y: 36, width: info.bounds.width, height: 28)
    }

    func configure(_ item: MetaItem, index: Int, rowCell: FixedFocusRowCell,
                   progress: WatchProgress?, landscape: Bool) {
        itemIndex = index
        self.rowCell = rowCell
        self.item = item
        self.landscape = landscape
        backdropFor = nil
        // The rim, in the poster's own colour (subtle).
        let rimOn = RenderProbe.shared.flags.posterRims
        rim.image = rimOn ? FixedFocusRim.image(landscape ? .box : .poster, lineWidth: 2) : nil
        rim.alpha = 0
        rimColor = nil
        let style = FixedFocusRim.style
        FixedFocusRim.apply(style, to: rim.layer)
        FixedFocusRim.apply(style, to: outlineRim.layer)
        outlineRim.image = FixedFocusRim.image(.box, lineWidth: 4)
        if style == .titleColor {
            if let url = item.poster ?? item.background {
                let id = item.id
                FixedFocusColors.color(for: url) { [weak self] color in
                    guard let self, self.item?.id == id else { return }
                    self.rimColor = color
                    self.rim.tintColor = color
                    self.outlineRim.tintColor = color
                    if rimOn { self.rim.alpha = self.backdrop.alpha > 0.5 ? 0 : FixedFocusRim.posterAlpha }
                }
            }
        } else {
            // Light / vivid: white — over the poster's own edge it reads as
            // a lighter version of exactly that colour (glass-like).
            rimColor = .white
            rim.tintColor = .white
            outlineRim.tintColor = .white
            if rimOn { rim.alpha = FixedFocusRim.posterAlpha }
        }
        setNeedsLayout()
        if landscape {
            // Continue Watching: the landscape art right away — no logo, the
            // state line is the card's only text.
            backdropFor = item.id
            FixedFocusImages.load(progress?.episodeThumbnail ?? item.background ?? item.poster,
                                  into: backdrop, maxDimension: FixedFocusMetrics.boxWidth)
            FixedFocusImages.load(nil, into: logo, maxDimension: 0)
            FixedFocusImages.load(nil, into: poster, maxDimension: 0)
            state.show(progress)
            state.alpha = progress == nil ? 0 : 1
            name.text = item.name
            facts.text = progress?.episodeTitle
                ?? TitleBlock.metaSegments(for: item, seriesSize: TitleBlock.seriesSizeText(item))
                    .joined(separator: "  •  ")
            return
        }
        state.alpha = 0
        FixedFocusImages.load(item.poster ?? item.background, into: poster,
                              maxDimension: FixedFocusMetrics.height)
        FixedFocusImages.load(nil, into: backdrop, maxDimension: 0)
        FixedFocusImages.load(nil, into: logo, maxDimension: 0)
        name.text = item.name
        facts.text = TitleBlock.metaSegments(for: item, seriesSize: TitleBlock.seriesSizeText(item))
            .joined(separator: "  •  ")
    }

    /// The cell's outline: white, or the rim in the title's colour (as the
    /// box's — Render Lab → Box outline: title colour).
    private func setOutline(_ on: Bool) {
        let colored = RenderProbe.shared.flags.boxRimColored
        outline.alpha = on && !colored ? 1 : 0
        outlineRim.alpha = on && colored ? 1 : 0
    }

    /// Grown: the backdrop shows — unless the fixed box shows it
    /// (`contentHidden`), then the cell is just a box-wide gap. The info
    /// shows under every grown cell (it travels with its title).
    func setGrown(_ grown: Bool, contentHidden: Bool) {
        if landscape {
            // Continue Watching: always the landscape card; the outline only
            // while it shows itself (under the fixed box: none).
            poster.alpha = 0
            backdrop.alpha = 1
            setOutline(grown && !contentHidden)
            info.alpha = grown && !contentHidden ? 1 : 0
            return
        }
        if grown, let item, backdropFor != item.id {
            backdropFor = item.id
            FixedFocusImages.load(item.background ?? item.poster, into: backdrop,
                                  maxDimension: FixedFocusMetrics.boxWidth)
            FixedFocusImages.load(item.logo, into: logo, maxDimension: FixedFocusMetrics.boxWidth * 0.55)
        }
        // Under the fixed box (contentHidden) the poster simply stays: the
        // box covers it — no fade, only movement. It only gives way to the
        // backdrop while the cell itself shows the box (Up/Down opening).
        let shows = grown && !contentHidden
        poster.alpha = shows ? 0 : 1
        backdrop.alpha = shows ? 1 : 0
        // The info too only while the cell shows itself (Up/Down); under the
        // box, the box's own info drifts in place.
        info.alpha = shows ? 1 : 0
        if let vertical = Self.vertical {
            // Up/Down: the outlines hand over gradually: the old one fades out over
            // the first 70 %, the new one in over the last 70 %, linearly.
            let span = vertical.duration * 0.7
            UIView.animate(withDuration: span, delay: shows ? vertical.duration - span : 0,
                           options: [.curveLinear, .overrideInheritedDuration,
                                     .overrideInheritedCurve, .beginFromCurrentState]) {
                self.setOutline(shows)
            }
        } else {
            setOutline(shows)
        }
        // The poster's own rim steps back while the cell shows the box.
        if RenderProbe.shared.flags.posterRims, rimColor != nil {
            rim.alpha = shows ? 0 : FixedFocusRim.posterAlpha
        }
    }
}


/// The poster row's layout: every position computed exactly — title i at
/// `inset + i × pitch`, everything after the wide (focused) title shifted
/// by its extra width. (UIKit's flow layout spread the posters out as soon
/// as one cell was wider than the rest.)
final class FixedFocusStripLayout: UICollectionViewLayout {
    /// The row extends this far beyond the screen on both sides; positions
    /// are shifted by it (so on screen nothing moves).
    static let overscan: CGFloat = 1200
    /// The grown title's index (nil: all posters).
    var wideIndex: () -> Int? = { nil }
    /// The cards' width (posters; Continue Watching: box-wide).
    var cardWidth: () -> CGFloat = { FixedFocusMetrics.posterWidth }
    private var frames: [CGRect] = []
    private var contentWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let wide = wideIndex()
        let card = cardWidth()
        let pitch = card + FixedFocusMetrics.gap
        let extra = FixedFocusMetrics.boxWidth - card
        frames = (0..<count).map { i in
            var x = Self.overscan + FixedFocusMetrics.inset + CGFloat(i) * pitch
            if let wide, i > wide { x += extra }
            let width = i == wide ? FixedFocusMetrics.boxWidth : card
            return CGRect(x: x, y: 0, width: width, height: FixedFocusMetrics.height)
        }
        // Room after the last title so it too can reach the spot.
        contentWidth = (frames.last?.maxX ?? 0) + 1920 + 2 * Self.overscan
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: FixedFocusMetrics.height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.compactMap { i in
            frames[i].intersects(rect) ? attributes(i) : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    private func attributes(_ i: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
        a.frame = frames[i]
        return a
    }
}


/// The row list's layout: no scrolling — every row placed around the
/// focused one. The focused row at the fixed spot; the row above so its
/// posters' lower third shows at the top; the row below so the original
/// preview height shows at the bottom; the rest off screen, a row apart.
/// On Up/Down the layout is recomputed and the rows glide to their places.
final class FixedFocusRowsLayout: UICollectionViewLayout {
    var focusedRow: () -> Int = { 0 }
    /// The list extends this far beyond the screen, above and below (see
    /// the controller's `viewDidLayoutSubviews`); rows are placed in screen
    /// coordinates shifted by it.
    static let overscan: CGFloat = 1100
    private var frames: [CGRect] = []

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let f = focusedRow()
        let rowHeight = FixedFocusMetrics.titleHeight + FixedFocusMetrics.height
        let pitch = FixedFocusMetrics.rowPitch
        let focusY = FixedFocusMetrics.rowTop
        let aboveY = FixedFocusMetrics.aboveVisible - rowHeight
        let belowY = 1080 - FixedFocusMetrics.belowVisible - FixedFocusMetrics.titleHeight
        frames = (0..<count).map { r in
            let y: CGFloat
            switch r - f {
            case 0: y = focusY
            case ..<0: y = aboveY - CGFloat(f - r - 1) * pitch
            default: y = belowY + CGFloat(r - f - 1) * pitch
            }
            return CGRect(x: 0, y: y + Self.overscan, width: 1920, height: rowHeight)
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: 1920, height: 1080 + 2 * Self.overscan)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.compactMap { frames[$0].intersects(rect) ? attributes($0) : nil }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    private func attributes(_ r: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: r, section: 0))
        a.frame = frames[r]
        return a
    }
}




/// Continue Watching's state line on a card, as on the original Home:
/// "S1:E5" · progress bar · "20 min left" — or, not started, "Up Next".
final class FixedFocusProgressView: UIView {
    private let episode = UILabel()
    private let remaining = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [episode, remaining] {
            label.font = .systemFont(ofSize: Spotlight.continueStateSize, weight: .semibold)
            label.textColor = .white
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.6
            label.layer.shadowRadius = 6
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(label)
        }
        track.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        track.layer.cornerRadius = Spotlight.continueProgressBarHeight / 2
        fill.backgroundColor = .white
        fill.layer.cornerRadius = Spotlight.continueProgressBarHeight / 2
        track.addSubview(fill)
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ entry: WatchProgress?) {
        guard let entry else { return }
        episode.text = entry.season.flatMap { s in entry.episode.map { "S\(s):E\($0)" } }
        let started = entry.fraction > 0.02
        remaining.text = started ? (entry.remainingTimeText.map { "\($0) left" } ?? "In progress") : "Up Next"
        fraction = started ? CGFloat(entry.fraction) : 0
        track.isHidden = !started
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = Spotlight.continueStateGap
        episode.sizeToFit()
        remaining.sizeToFit()
        let h = bounds.height
        episode.frame = CGRect(x: 0, y: (h - episode.bounds.height) / 2,
                               width: episode.text == nil ? 0 : episode.bounds.width,
                               height: episode.bounds.height)
        remaining.frame = CGRect(x: bounds.width - remaining.bounds.width,
                                 y: (h - remaining.bounds.height) / 2,
                                 width: remaining.bounds.width, height: remaining.bounds.height)
        let barX = episode.frame.maxX + (episode.text == nil ? 0 : gap)
        let barWidth = max(remaining.frame.minX - gap - barX, 0)
        let barH = Spotlight.continueProgressBarHeight
        track.frame = CGRect(x: barX, y: (h - barH) / 2, width: barWidth, height: barH)
        fill.frame = CGRect(x: 0, y: 0, width: max(barWidth * fraction, barH), height: barH)
    }
}


/// The Left/Right and Up/Down curves (Render Lab → Motion). All through
/// `UIView.animate` — the only animation collection views follow for their
/// cells' size changes.
@MainActor
enum FixedFocusMotion {
    enum Curve: String, CaseIterable {
        case spring, easeOut, easeInOut
        var displayName: String {
            switch self {
            case .spring: return "Spring (no bounce)"
            case .easeOut: return "Ease-out"
            case .easeInOut: return "Ease-in-out"
            }
        }
    }

    static var curve: Curve { Curve(rawValue: RenderProbe.shared.flags.horizontalCurve) ?? .easeInOut }
    static var verticalCurve: Curve { Curve(rawValue: RenderProbe.shared.flags.verticalCurve) ?? .easeInOut }

    /// A focus movement on its curve (Left/Right or Up/Down, each chosen in
    /// Render Lab). Ease-in-out gives the movement weight: it has to get
    /// going and it brakes — snappier curves made the UI feel light.
    static func run(vertical: Bool, duration: Double, damping: Double,
                    animations: @escaping () -> Void,
                    completion: @escaping (Bool) -> Void) {
        let chosen = vertical ? verticalCurve : curve
        // Always UIView.animate: collection views only animate their cells'
        // size changes inside it (under a property animator they jumped).
        if chosen == .spring {
            UIView.animate(withDuration: duration, delay: 0,
                           usingSpringWithDamping: vertical ? damping : 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: animations, completion: completion)
            return
        }
        let curveOption: UIView.AnimationOptions = chosen == .easeOut ? .curveEaseOut : .curveEaseInOut
        UIView.animate(withDuration: duration, delay: 0,
                       options: [curveOption, .beginFromCurrentState, .allowUserInteraction],
                       animations: animations, completion: completion)
    }

    /// Left/Right, for things moving with the row (the box's drift).
    static func horizontal(_ animations: @escaping () -> Void, completion: @escaping () -> Void) {
        run(vertical: false, duration: Motion.durations.move, damping: 1,
            animations: animations, completion: { _ in completion() })
    }
}


/// The rim, drawn ONCE per size as a white gradient ring (bright at the
/// top-right, fading around, gone at the bottom-left) and used as a
/// template image — each poster tints it with its own colour. A picture that
/// moves with its poster: no per-frame drawing (a live gradient stroke on
/// moving cards is what cost the old Home its frames).
@MainActor
enum FixedFocusRim {
    enum Size { case poster, box }

    /// Render Lab → Rim: the title's colour, or glass-like — white over the
    /// poster's own edge (light: plain blend; vivid: overlay blend, which
    /// brightens the edge colours without washing them out).
    enum Style: String, CaseIterable {
        case titleColor, light, vivid, glass
        var displayName: String {
            switch self {
            case .titleColor: return "Title colour"
            case .light: return "Light (glass)"
            case .vivid: return "Vivid (glass)"
            case .glass: return "Vivid glass (depth)"
            }
        }
    }

    static var style: Style { Style(rawValue: RenderProbe.shared.flags.rimStyle) ?? .light }

    /// The posters' rim strength (the box's is full).
    static var posterAlpha: CGFloat {
        switch style {
        case .titleColor: return 0.8
        case .light: return 0.45
        case .vivid: return 0.9
        case .glass: return 0.95
        }
    }

    /// Vivid / vivid glass: the rim is blended with what's beneath
    /// (overlay) — it brightens the edge's own colours (and the glass's dark
    /// counter-edge deepens them). Same cost for both.
    static func apply(_ style: Style, to layer: CALayer) {
        layer.compositingFilter = style == .vivid || style == .glass ? "overlayBlendMode" : nil
    }
    private static var cache: [String: UIImage] = [:]

    static func image(_ size: Size, lineWidth: CGFloat) -> UIImage {
        if style == .glass { return glassImage(size, lineWidth: lineWidth) }
        let w = size == .box ? FixedFocusMetrics.boxWidth : FixedFocusMetrics.posterWidth
        let h = FixedFocusMetrics.height
        let key = "\(size)-\(lineWidth)"
        if let hit = cache[key] { return hit }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let image = UIGraphicsImageRenderer(size: rect.size).image { ctx in
            let cg = ctx.cgContext
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = UIBezierPath(roundedRect: inset,
                                    cornerRadius: max(Spotlight.cornerRadius - lineWidth / 2, 0))
            cg.addPath(path.cgPath)
            cg.setLineWidth(lineWidth)
            cg.replacePathWithStrokedPath()
            cg.clip()
            // Pure directional light from the TOP RIGHT (the dark fade on the
            // left reads as shadow, so the scene is lit from the right):
            // peak there, fading steadily around the frame, gone at the
            // bottom-left.
            let colors = [1.0, 0.45, 0.12, 0.0].map { UIColor(white: 1, alpha: $0).cgColor } as CFArray
            let locations: [CGFloat] = [0, 0.3, 0.6, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: locations) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: w, y: 0), end: CGPoint(x: 0, y: h), options: [])
            }
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }
}

extension FixedFocusRim {
    /// GLASS (depth): an edge that looks physical, all baked into one image
    /// per size (so it costs the same as the flat rim):
    /// - a soft specular sheen INSIDE the lit (top-right) corner, over the art;
    /// - a fine dark counter-edge on the shadow side (bottom-left);
    /// - a fine light line all around, fading from the lit corner;
    /// - the edge THICKER where the light hits, thinning out around it.
    /// Not a template: its light and shadow are baked in.
    static func glassImage(_ size: Size, lineWidth: CGFloat) -> UIImage {
        let w = size == .box ? FixedFocusMetrics.boxWidth : FixedFocusMetrics.posterWidth
        let h = FixedFocusMetrics.height
        let key = "glass-\(size)-\(lineWidth)"
        if let hit = cache[key] { return hit }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let radius = Spotlight.cornerRadius
        let space = CGColorSpaceCreateDeviceRGB()
        let light = CGPoint(x: w, y: 0)
        let reach = max(w, h)

        func ring(_ cg: CGContext, width: CGFloat) {
            let inset = rect.insetBy(dx: width / 2, dy: width / 2)
            cg.addPath(UIBezierPath(roundedRect: inset, cornerRadius: max(radius - width / 2, 0)).cgPath)
            cg.setLineWidth(width)
            cg.replacePathWithStrokedPath()
            cg.clip()
        }
        func gradient(_ colors: [UIColor], _ locations: [CGFloat]) -> CGGradient? {
            CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations)
        }

        // Soft INNER edge: the light is brightest right at the edge and
        // fades into the image over `feather` points (a hard inner boundary
        // read as a line painted on top). Wider on the box.
        let feather: CGFloat = size == .box ? 12 : 6
        let outer = UIBezierPath(roundedRect: rect, cornerRadius: radius)

        /// Masks must cover the WHOLE image: a gradient only paints between
        /// its ends, and `.destinationIn` leaves unpainted pixels untouched —
        /// the glow stayed at full strength beyond the mask's radius (a hard
        /// cut-off on the box's top and bottom edges).
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        /// An inner glow (or shadow) of `color`, feathered inward, masked by
        /// `mask` (the directional falloff).
        func innerGlow(_ cg: CGContext, color: UIColor, blur: CGFloat, passes: Int = 1,
                       mask: () -> Void) {
            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.addPath(outer.cgPath)
            cg.clip()
            // Fill everything OUTSIDE the shape with a shadow: only the
            // shadow falls inside — soft, from the edge inward.
            let frame = UIBezierPath(rect: rect.insetBy(dx: -blur * 4, dy: -blur * 4))
            frame.append(outer)
            frame.usesEvenOddFillRule = true
            // (A soft shadow is only about half as strong right at the edge:
            // drawn several times to bring the edge up to full light.)
            cg.setShadow(offset: .zero, blur: blur, color: color.cgColor)
            cg.setFillColor(color.cgColor)
            for _ in 0..<passes {
                cg.addPath(frame.cgPath)
                cg.fillPath(using: .evenOdd)
            }
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            // Keep it only where the light (or shadow) falls.
            cg.setBlendMode(.destinationIn)
            mask()
            cg.endTransparencyLayer()
            cg.restoreGState()
        }

        let image = UIGraphicsImageRenderer(size: rect.size).image { ctx in
            let cg = ctx.cgContext
            // Sheen inside the lit corner.
            cg.saveGState()
            cg.addPath(outer.cgPath)
            cg.clip()
            if let g = gradient([UIColor(white: 1, alpha: 0.06), UIColor(white: 1, alpha: 0)], [0, 1]) {
                cg.drawRadialGradient(g, startCenter: light, startRadius: 0,
                                      endCenter: light, endRadius: reach * 0.55, options: [])
            }
            cg.restoreGState()
            // Shadow side: a soft dark inner edge, strongest at the bottom-left.
            innerGlow(cg, color: UIColor(white: 0, alpha: 0.5), blur: feather * 0.7, passes: 2) {
                if let g = gradient([UIColor(white: 0, alpha: 0), UIColor(white: 0, alpha: 0),
                                     UIColor(white: 0, alpha: 1)], [0, 0.5, 1]) {
                    cg.drawLinearGradient(g, start: light, end: CGPoint(x: 0, y: h), options: extend)
                }
            }
            // Light side: a soft light inner edge — widest and brightest at the
            // top-right corner, fading around the frame.
            innerGlow(cg, color: UIColor(white: 1, alpha: 1), blur: feather,
                      passes: size == .box ? 4 : 3) {
                if let g = gradient([UIColor(white: 1, alpha: 1), UIColor(white: 1, alpha: 0.4),
                                     UIColor(white: 1, alpha: 0)], [0, 0.35, 1]) {
                    cg.drawRadialGradient(g, startCenter: light, startRadius: 0,
                                          endCenter: light, endRadius: reach * 0.75, options: extend)
                }
            }
            // The very edge: a fine crisp catch-light, fading from the corner.
            cg.saveGState()
            ring(cg, width: size == .box ? 2 : 1)
            if let g = gradient([UIColor(white: 1, alpha: 0.9), UIColor(white: 1, alpha: 0.3),
                                 UIColor(white: 1, alpha: 0)], [0, 0.45, 0.75]) {
                cg.drawLinearGradient(g, start: light, end: CGPoint(x: 0, y: h), options: [])
            }
            cg.restoreGState()
        }
        cache[key] = image
        return image
    }
}

/// Each title's colour (from `SpotlightTint`, cached), lifted so it reads as
/// light on the dark background rather than muddy.
@MainActor
enum FixedFocusColors {
    private static var cache: [String: UIColor] = [:]

    static func color(for url: String, _ done: @escaping (UIColor) -> Void) {
        if let hit = cache[url] { done(hit); return }
        Task { @MainActor in
            guard let base = await SpotlightTint.color(for: url) else { return }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(base).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let lifted = UIColor(hue: h, saturation: min(max(s * 1.15, 0.35), 0.9),
                                 brightness: max(b, 0.9), alpha: 1)
            cache[url] = lifted
            done(lifted)
        }
    }
}
