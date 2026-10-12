import SwiftUI
import AVFoundation
import Combine

struct HomeRow: Identifiable {
    /// What a row shows, to tell whether it changed: each title and its art.
    var contentKey: [String] { items.map { "\($0.id)|\($0.background ?? "")" } }

    let id: String
    let title: String
    let items: [MetaItem]
    /// A second caption line per title (destination rows: when a title was
    /// saved, how many catalogs a folder holds), by title id.
    var subtitles: [String: String] = [:]
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
    /// When the catalogs were last fetched (nil: not yet this launch) —
    /// Home refreshes when they're older than `refreshAge` (see `HomeView`).
    private(set) var loadedAt: Date?
    /// Catalogs are pulled (add-ons can't push): an hour covers lists that
    /// change daily or hourly, at a handful of requests a day.
    static let refreshAge: TimeInterval = 60 * 60
    var isStale: Bool { loadedAt.map { Date().timeIntervalSince($0) > Self.refreshAge } ?? false }

    /// The billboard's picks (see `BillboardPicks`), made once per catalog
    /// fetch — the same rhythm, so the billboard doesn't reshuffle between.
    @Published private(set) var billboardPicks: [BillboardPick] = []
    private var picksMadeFor: Date?

    /// Make the picks for the catalogs fetched at `loadedAt` (once: Home,
    /// Movies and Series share this model and all ask).
    func refreshPicks(history: BillboardPicks.History, addonManager: AddonManager, tmdb: Bool) async {
        guard let loadedAt, picksMadeFor != loadedAt else { return }
        picksMadeFor = loadedAt
        billboardPicks = await BillboardPicks.make(history: history, addonManager: addonManager,
                                                   tmdb: tmdb, fallback: highlights(max: 20))
    }

    /// The billboard for a tab: its picks (of that type on Movies / Series),
    /// filled with the rows' highlights while the picks aren't made yet.
    func billboard(type: String?, max: Int = BillboardPicks.count) -> [BillboardPick] {
        func fits(_ item: MetaItem) -> Bool {
            type.map { $0 == "series" ? item.isSeries : item.type == $0 } ?? true
        }
        let picks = billboardPicks.filter { fits($0.item) }
        return Array((picks.isEmpty ? highlights(max: max, type: type) : picks).prefix(max))
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
        // Hero source. The spotlight is derived during the load, so picking a
        // different catalog has to re-run it.
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
                    // shipped could still hold duplicate ids.
                    let staleItems = items.deduplicatedByID()
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
        loadedAt = Date()

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
        if !prefetchURLs.isEmpty {
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
        // The catalog's own name (or the one given it in Settings) — no
        // "- Movie" / "- Series" suffix: each title's facts line says it.
        settings.customTitle(for: key) ?? request.catalog.name ?? request.catalog.id.capitalized
    }


    /// Pull the billboard's backdrops into the image cache (art that is not
    /// on screen yet).
    private func warmSpotlightArt() {
        let art = highlights(max: 6).compactMap { $0.item.background ?? $0.item.poster }
        guard !art.isEmpty else { return }
        ImageCache.shared.warm(urls: art)
    }

    /// Highlights of Home: the top two titles of each of the first rows
    /// (no repeats, only titles with a backdrop — a billboard without one is
    /// a dead frame), in row order, up to `max`, the row's name as the
    /// reason. `type` filters for the Movies / Series tabs.
    func highlights(max: Int, type: String? = nil) -> [BillboardPick] {
        var seen = Set<String>()
        var picks: [BillboardPick] = []
        for entry in entries {
            guard case .catalog(let row) = entry else { continue }
            let fresh = row.items.filter { item in
                item.background != nil && !seen.contains(item.id)
                    && (type.map { $0 == "series" ? item.isSeries : item.type == $0 } ?? true)
            }
            for item in fresh.prefix(2) {
                seen.insert(item.id)
                picks.append(BillboardPick(item: item, reason: .row(title: row.title)))
                if picks.count == max { return picks }
            }
        }
        return picks
    }

}

struct HomeView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore

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
    @EnvironmentObject private var library: LibraryStore
    /// Movies / Series tabs: only this type ("movie" / "series"); nil: Home,
    /// everything. The same rows, filtered — see `filteredRows`.
    var typeFilter: String? = nil
    @Environment(\.scenePhase) private var scenePhase
    /// Its tab is in front (Home / Movies / Series stay alive when not).
    var active = true

    let onSelect: (MetaItem) -> Void
    /// The billboard's Select: Details takes over in place (no slide).
    var onSelectFeatured: ((MetaItem) -> Void)? = nil
    let onResume: (WatchProgress) -> Void
    /// Continue Watching's hold menu: Start Over, Choose Source.
    var onStartOver: (WatchProgress) -> Void = { _ in }
    var onChooseSource: (WatchProgress) -> Void = { _ in }
    /// A collection's folder, selected on its row.
    let onOpenFolder: (CueCollection, CueCollectionFolder) -> Void
    /// Fires when the first load attempt finishes (success or error), so the
    /// root can re-enable the sidebar only once content exists to hold focus.
    var onContentReady: () -> Void = {}

    /// Fetch the catalogs again when they're older than `refreshAge` — only
    /// for the tab in front, never while something plays (it competed with
    /// the stream for bandwidth).
    private func refreshIfStale() {
        guard active, viewModel.isStale, !NuvioSyncManager.playbackActive else { return }
        Task {
            await viewModel.load(
                addonManager: addonManager,
                collections: collections,
                settings: homeCatalogSettings,
                providers: collectionProviders
            )
        }
    }

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
        return (HomeRow(id: Spotlight.continueRowID,
                        title: "Continue Watching", items: items),
                progress)
    }
    
    /// Catalog rows plus collections, in the order Settings → Home rows gives
    /// them. Each collection is its own row: its folders as landscape tiles
    /// in one wide panel (see `FixedFocusRowCell`'s panel). Selecting a tile
    /// opens the folder — see `selectSpotlight`.
    private var spotlightRows: [HomeRow] {
        var rows: [HomeRow] = []
        for entry in viewModel.entries {
            switch entry {
            case .catalog(let row):
                if !row.items.isEmpty { rows.append(row) }
            case .collection(let collection):
                // On Movies / Series: the folders with that type.
                let items = collection.folders.filter { folder in typeFilter.map(folder.lists) ?? true }
                    .map { Self.spotlightItem(for: $0, in: collection, type: typeFilter) }
                guard !items.isEmpty else { continue }
                let key = HomeCatalogSettingsStore.collectionKey(collection.id)
                rows.append(HomeRow(id: Self.collectionItemPrefix + collection.id,
                                    title: homeCatalogSettings.customTitle(for: key) ?? collection.title,
                                    items: items,
                                    subtitles: Dictionary(items.map { ($0.id, $0.description ?? "") },
                                                          uniquingKeysWith: { first, _ in first })))
            }
        }
        return rows
    }

    /// The collection rows (their panels).
    static func isCollectionRow(_ id: String) -> Bool { id.hasPrefix(collectionItemPrefix) }

    /// The rows in order: the billboard, Continue Watching, the Watchlist,
    /// the catalogs — filtered on Movies / Series.
    private func homeRows(_ featured: [HomeRow], _ continueRow: HomeRow?) -> [HomeRow] {
        var rows = featured
        if let continueRow { rows.append(continueRow) }
        rows += libraryRow
        rows += spotlightRows
        return filteredRows(rows)
    }

    /// "Saved for Later": the library as a row, newest first (adding a title puts it
    /// at the front — the one order that matters).
    private var libraryRow: [HomeRow] {
        let saved = library.items.values.sorted { $0.addedAt > $1.addedAt }
        guard !saved.isEmpty else { return [] }
        return [HomeRow(id: Self.libraryRowID, title: "Saved for Later", items: saved.map(\.metaItem),
                        subtitles: Dictionary(saved.map { ($0.metaItem.id, Self.addedText($0.addedAt)) },
                                              uniquingKeysWith: { first, _ in first }))]
    }

    /// "Added today", "Added yesterday", "Added 3 days ago", then the date.
    static func addedText(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Added today"
        case 1: return "Added yesterday"
        case 2..<7: return "Added \(days) days ago"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return "Added " + date.formatted(sameYear ? .dateTime.day().month(.abbreviated)
                                                      : .dateTime.day().month(.abbreviated).year())
        }
    }
    static let libraryRowID = "spotlight.library"

    /// Movies / Series: every row filtered to the tab's type. A row left with
    /// only a few titles goes (unless it was that small to begin with);
    /// collection rows come already filtered (their folders of the type —
    /// see `spotlightRows`). The billboard, if its catalog
    /// has none of the type, is made from the tab's own rows.
    private func filteredRows(_ rows: [HomeRow]) -> [HomeRow] {
        guard let typeFilter else { return rows }
        func matches(_ item: MetaItem) -> Bool {
            typeFilter == "series" ? item.isSeries : item.type == typeFilter
        }
        var out: [HomeRow] = []
        for row in rows {
            if row.id.hasPrefix(Self.collectionItemPrefix) { out.append(row); continue }
            let items = row.items.filter(matches)
            let keep = row.id == Spotlight.featuredRowID || row.id == Spotlight.continueRowID
                || row.id == Self.libraryRowID || items.count >= min(4, row.items.count)
            if keep, !items.isEmpty {
                out.append(HomeRow(id: row.id, title: row.title, items: items, subtitles: row.subtitles))
            }
        }
        if !out.contains(where: { $0.id == Spotlight.featuredRowID }) {
            var seen = Set<String>()
            let picks = out.filter { $0.id != Spotlight.continueRowID && $0.id != Self.libraryRowID }
                .flatMap(\.items)
                .filter { $0.background != nil && seen.insert($0.id).inserted }
                .prefix(10)
            if !picks.isEmpty, Spotlight.showFeatured {
                out.insert(HomeRow(id: Spotlight.featuredRowID, title: "Featured", items: Array(picks)),
                           at: 0)
            }
        }
        return out
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

    /// A folder as a tile: its cover (the art carries its name); the facts
    /// line says how many catalogs it holds.
    /// `type` (Movies / Series): the count is of that kind's catalogs.
    private static func spotlightItem(for folder: CueCollectionFolder,
                                      in collection: CueCollection, type: String? = nil) -> MetaItem {
        let count = folder.effectiveSources.filter { source in
            type.map { source.kind == nil || source.kind == $0 } ?? true
        }.count
        return MetaItem(id: collectionItemPrefix + collection.id + "\u{1F}" + folder.id,
                        type: "collection", name: folder.title,
                        poster: folder.tileCoverImageUrl, background: folder.tileCoverImageUrl,
                        description: count == 1 ? "1 catalog" : "\(count) catalogs")
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
                onOpenFolder(collection, folder)
            }
            return
        }
    }
    var body: some View {
        Group {
            let cw = spotlightContinue
            // The billboard: Cue's picks (on Movies / Series, of that type).
            let picks = viewModel.billboard(type: typeFilter)
            let featured = picks.map(\.item)
            let featuredRow: [HomeRow] = featured.isEmpty || !Spotlight.showFeatured ? [] :
                [HomeRow(id: Spotlight.featuredRowID, title: "Featured", items: featured)]
            // Rows in UIKit (collection views), native focus, our own Core
            // Animation movement to the fixed box. Continue Watching, then
            // Saved for Later (the library), then the catalogs — on Movies /
            // Series, filtered to that type.
            HomeUIKitView(rows: homeRows(featuredRow, cw?.row),
                          featuredRowID: Spotlight.featuredRowID,
                          active: active,
                          continueRowID: Spotlight.continueRowID,
                          progress: cw?.progress ?? [:],
                          billboardReasons: Dictionary(picks.compactMap { pick in
                              pick.reason.map { (pick.id, $0) }
                          }, uniquingKeysWith: { first, _ in first }),
                          onSelect: selectSpotlight,
                          onSelectFeatured: onSelectFeatured,
                          onResume: onResume,
                          onStartOver: onStartOver,
                          onChooseSource: onChooseSource)
        }
        // The picks, once per catalog fetch.
        .task(id: viewModel.loadedAt) {
            await viewModel.refreshPicks(
                history: BillboardPicks.History(progress: progressStore, watched: watched, library: library),
                addonManager: addonManager, tmdb: tmdbSettings.isEnabled)
            // Their ratings in one request, before the billboard shows them.
            await MDBListService.prefetch(viewModel.billboardPicks.map(\.item), settings: mdblist.settings)
        }
        .onAppear {
            isVisible = true
            // The background queue (TitlePreloader): Home's stores.
            TitlePreloader.shared.context = .init(
                addonManager: addonManager, mdb: mdblist.settings, tmdb: tmdbSettings.settings,
                progress: progressStore, watched: watched)
        }
        .onDisappear {
            isVisible = false
            reloadDebounce?.cancel()
            contentReadyTask?.cancel()
        }
        .task {
            await reload()
        }
        // Catalogs are pulled — add-ons can't push — so Home asks again when
        // its lists are older than an hour: as it comes into view, and as
        // Cue comes back to the front. Not a timer: a handful of refreshes
        // a day. (The rows under your focus don't reshuffle: the row view
        // only takes count changes while you're in it.)
        .onChange(of: active) { _, isActive in if isActive { refreshIfStale() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshIfStale() } }
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
        return "\(watchedHash)#\(progressHash)#\(dismissedHash)#\(dayBucket)"
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
        // main-actor stores (cheap: a key set), then run it
        // detached; only the publish hops back. On an A8 this loop used to be
        // hundreds of milliseconds ON the main actor at every launch and
        // after every watched/progress mutation.
        let watchedKeys = Set(watched.items.keys)
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
                                                    watchedKeys: watchedKeys) else { continue }
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
                                                  watchedKeys: Set<String>) -> MetaVideo? {
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
        // Next up is the episode after the FURTHEST one watched: rewatching
        // an older episode doesn't send you back.
        if let furthestIndex = all.lastIndex(where: isWatched),
           furthestIndex + 1 < all.endIndex {
            return all[(furthestIndex + 1)...].first(where: \.isNextUpCandidate)
        }

        return all.first { !isWatched($0) && $0.isNextUpCandidate }
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

    /// Continue Watching card art: the episode's still (variety — the
    /// backdrops are everywhere else), else the show's backdrop/poster.
    private func continueImage(_ progress: WatchProgress) -> String? {
        if let thumb = progress.episodeThumbnail, !thumb.isEmpty { return thumb }
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
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var library: LibraryStore
    let rows: [HomeRow]
    /// The Featured row's id: the billboard (full screen, no posters).
    let featuredRowID: String
    /// Its tab is in front; kept alive but hidden otherwise.
    let active: Bool
    /// The Continue Watching row's id (landscape cards, Select resumes).
    let continueRowID: String
    let progress: [String: WatchProgress]
    /// Why each billboard title is there (see `BillboardPicks`).
    var billboardReasons: [String: BillboardReason] = [:]
    let onSelect: (MetaItem) -> Void
    /// Select on the billboard: Details takes over in place (no slide).
    let onSelectFeatured: ((MetaItem) -> Void)?
    let onResume: (WatchProgress) -> Void
    /// Continue Watching's hold menu: Start Over and Choose Source.
    var onStartOver: (WatchProgress) -> Void = { _ in }
    var onChooseSource: (WatchProgress) -> Void = { _ in }
    @EnvironmentObject private var watchedStore: WatchedStore
    @EnvironmentObject private var progressStore: ProgressStore

    /// The focused title (drives the background).
    @State private var focused: MetaItem?
    /// …and the picture its card shows: the colour comes from that (a
    /// portrait card's poster, not the backdrop it doesn't show).
    @State private var focusedArt: String?
    /// Its colour (the "Title colour" background only).
    @State private var tint: Color?
    /// Two colours mode: the title's second colour.
    @State private var tintSecond: Color?
    /// The billboard's scrim: the title's colour, very dark.
    @State private var tintDeep: Color?
    /// The "Artwork, blurred" background: the focused title's backdrop.
    @State private var picture: FixedFocusPicture?
    /// When the focus last moved and the colours last began to change
    /// (Render Lab → Tint: calm while scrolling fast).
    @State private var tintPace = TintPace()
    /// Focus is on the billboard: which of its titles (nil: in the rows).
    @State private var billboard: FixedFocusBillboardPosition?
    /// The billboard paging by itself: the next title, as a press would.
    @State private var billboardCommand: FixedFocusRowsCommand?
    @AppStorage(BillboardAutoPage.key) private var autoPage = true
    /// Arrivals on the billboard (each starts the paging clock over).
    @State private var autoPageVisit = 0
    /// The last title has been reached on this visit to Home: paging by
    /// itself is done (going back Left doesn't start it again). Reset when
    /// Home is opened again, the app comes back, or the titles change.
    @State private var autoPageDone = false
    @Environment(\.scenePhase) private var homeScenePhase
    /// How far below the billboard focus is (1: the first row below, whose
    /// strip of the billboard stays at the top).
    @State private var depth = 0
    /// The billboard's title (kept while it fades out on Down).
    @State private var billboardItem: MetaItem?
    /// Its MDBList ratings, per title (as on Details).
    @State private var billboardRatings: [String: MDBListRatings] = [:]
    /// Its season count from TMDB, per title.
    @State private var billboardInfo: [String: TMDBService.ShowSize] = [:]
    /// The colours shift through the scroll to or from the billboard.
    @State private var tintScroll = false
    /// Details (opened from the billboard) is taking / has taken over: the
    /// billboard's own cues (hint, dots) are out.
    /// Details is up over Home (the billboard doesn't page behind it).
    @ObservedObject private var detailsOpen = DetailsOpen.shared
    /// …and its picture has stepped closer (see `StagePictureView`).
    @EnvironmentObject private var theme: ThemeManager

    /// Below the billboard: the focused title's colours, or the app
    /// background (Settings → Appearance).
    @AppStorage(AppBackground.homeFollowsTitleKey) private var followsTitle = true

    /// The billboard's titles' taglines (TMDB), as they come.
    @State var billboardTaglines: [String: String] = [:]
    /// The dots' last state (so they fade out unchanged).
    @State private var lastBillboard: FixedFocusBillboardPosition?

    var body: some View {
        ZStack(alignment: .topLeading) {
            homeLayers
        }
    }

    /// A choice in Continue Watching's hold menu.
    private func act(_ action: ContinueMenuAction, on entry: WatchProgress) {
        switch action {
        case .details:
            let title = ContinueActions.title(entry)
            if let push = onSelectFeatured {
                DetailTransition.shared.open(title) { push(title) }
            } else {
                onSelect(title)
            }
        case .startOver: onStartOver(entry)
        case .chooseSource: onChooseSource(entry)
        case .markWatched: ContinueActions.markWatched(entry, watched: watchedStore, progressStore: progressStore)
        case .remove: ContinueActions.remove(entry, progressStore: progressStore)
        }
    }

    private var homeLayers: some View {
        ZStack(alignment: .topLeading) {
            if followsTitle {
                LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                background
            } else {
                ATVBackground()
            }
            FixedFocusRows(rows: rows, featuredRowID: featuredRowID, continueRowID: continueRowID,
                           active: active,
                           progress: progress,
                           panelRowIDs: Set(rows.map(\.id).filter(HomeView.isCollectionRow)),
                           // Collections, Continue Watching and Saved for
                           // Later: moving focus.
                           destinationRowIDs: Set(rows.map(\.id).filter {
                               HomeView.isCollectionRow($0) || $0 == HomeView.libraryRowID || $0 == continueRowID
                           }),
                           onSelect: onSelect,
                           onSelectFeatured: { openBillboardTitle($0) },
                           onResume: onResume,
                           // A title's card: into Details (`DetailTransition`).
                           onOpenDetails: onSelectFeatured.map { push in
                               { item in DetailTransition.shared.open(item) { push(item) } }
                           },
                           onContinueMenu: { act($0, on: $1) },
                           titleMenu: { item, rowID in
                               TitleMenu.shared.entries(for: item,
                                                        in: rowID == HomeView.libraryRowID ? .library : .standard)
                           },
                           onDepth: { depth = $0 },
                           onFocusArt: { focusedArt = $0 },
                           // The billboard paging by itself (Settings →
                           // Appearance → Billboard pages by itself).
                           command: billboardCommand,
                           // The billboard as Details': the first row peeks up
                           // the bottom edge (its name above its cards); the
                           // billboard goes up until its hard edge is at the
                           // top bar's middle — the usual peek, the dots in it.
                           rigidRest: Self.rigidRowRest,
                           rigidNameY: FixedFocusRowsLayout.nextNameY,
                           rigidPeek: Self.firstRowPeek,
                           rigidPeekShowsName: true,
                           billboardOverlay: billboardOverlay,
                           billboardOverlayBelowRows: true,
                           // The picture under the text: the controller's own,
                           // moved with the billboard's distance.
                           pinnedBillboardPicture: true,
                           rigidBillboardTravel: Self.rigidBillboardTravel) { item, position in
                // Between the billboard and the rows: the colours shift
                // gradually THROUGH the scroll (see `tintKey`'s task).
                if (position == nil) != (billboard == nil) { tintScroll = true }
                // Every arrival on the billboard (back from the top bar, on
                // the same title too) starts its paging clock over.
                if position != nil { autoPageVisit &+= 1 }
                // At the last title: done for this visit (see `autoPageDone`).
                if let position, position.index == position.count - 1 { autoPageDone = true }
                focused = item
                if let position {
                    // Left/Right on the billboard: the text crossfades (see
                    // `BillboardCrossfade`). The logo is decoded BEFORE the
                    // title swaps (a moment at most), so it fades in with the
                    // text instead of appearing a beat later.
                    Task { @MainActor in
                        if let logo = item.logo {
                            await withTaskGroup(of: Void.self) { group in
                                group.addTask { await ImageCache.shared.preload(logo, maxDimension: TitleBlock.logoWidth) }
                                group.addTask { try? await Task.sleep(for: .milliseconds(250)) }
                                await group.next()
                                group.cancelAll()
                            }
                        }
                        withAnimation(FixedFocusMotion.animation(duration: Motion.moveDuration)) { billboardItem = item }
                        warmNeighbourLogos(around: position.index)
                    }
                }
                billboard = position
            }
            .ignoresSafeArea()
            // The billboard's text, hint and dots (its picture is part of the
            // Featured row — `StagePictureView`).
            billboardLayer
        }
        .ignoresSafeArea()
        // Follows the focused title once you've paused on it.
        .task(id: tintKey) {
            guard followsTitle, let item = focused, let url = focusedArt ?? item.background ?? item.poster else { return }
            // Scrolling to or from the billboard: over the whole scroll.
            // Otherwise it moves with focus — no rest, the focus move's curve
            // and time.
            let scrolling = tintScroll
            tintScroll = false
            var follows = !scrolling
            var fade = scrolling ? FixedFocusMotion.billboardScroll : Motion.moveDuration
            // FAST SCROLLING: a press soon after the last is part of a burst. Then the colours
            // change at most every `tintBurstEvery` (the cards in between are
            // skipped — a new press cancels this wait), over a calm blend; once
            // no press has come for a moment, it has landed: the spring again.
            if follows {
                let now = Date()
                let gap = now.timeIntervalSince(tintPace.lastPress)
                tintPace.lastPress = now
                if gap < Self.tintBurstGap {
                    let quiet = 0.15
                    let due = min(tintPace.lastChange.addingTimeInterval(Self.tintBurstEvery),
                                  now.addingTimeInterval(quiet))
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    guard !Task.isCancelled else { return }
                    let landed = Date().timeIntervalSince(now) >= quiet - 0.01
                    if !landed {
                        follows = false
                        fade = Self.tintBurstBlend
                    }
                }
            }
            let animation: Animation = follows ? FixedFocusTint.focusAnimation : .easeInOut(duration: fade)
            // Picture's colour layout: the background is the picture's own
            // colours where they sit (`FixedFocusTint.layout`) — made while
            // the colours are found, not after.
            async let layoutImage = FixedFocusTint.layout(for: url)
            async let found = FixedFocusTint.colors(for: url)
            let (layout, colorsFound) = await (layoutImage, found)
            guard !Task.isCancelled, let colors = colorsFound else { return }
            tintPace.lastChange = Date()
            withAnimation(animation) {
                tint = colors.first
                tintSecond = colors.second
                tintDeep = colors.deep
            }
            if let layout {
                // Crossfaded by its own view (`LayoutPictureView`), from what
                // is on screen at that moment.
                picture = FixedFocusPicture(key: item.id, image: layout, fade: fade, follows: follows)
            }
        }
    }

    /// Presses closer together than this are fast scrolling: the tint
    /// calms down (changes now and then, over a blend).
    static let tintBurstGap: Double = 0.3
    /// …then the colours change at most this often, over this blend.
    static let tintBurstEvery: Double = 0.3
    static let tintBurstBlend: Double = 0.5

    /// What the tint follows: the focused title.
    private var tintKey: String { "\(focused?.id ?? "")|\(followsTitle)" }

    /// The background: the focused title's colour.
    @ViewBuilder
    private var background: some View {
        ZStack {
            TitleTintBackground(tint: tint, second: tintSecond, picture: picture)
        }
        .frame(width: 1920, height: 1080)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// THE CALM GROUND under rows of cards and text — Home's rows and the
/// Detail page's Episodes and More alike: the title's colour(s) (Render Lab
/// → Background, Tint …) over a near-black base and the subtle vignette.
/// A blurred backdrop shown as a background (see `BlurredBackdrop`).
/// The tint's pace (a reference: changing it redraws nothing).
final class TintPace {
    var lastPress = Date.distantPast
    var lastChange = Date.distantPast
}

struct FixedFocusPicture: Equatable {
    let key: String
    let image: UIImage
    /// Colour layout: how it crossfades in (`LayoutPictureView`).
    var fade: Double = 0
    var follows = false
}

/// The colour layout, crossfading in UIKit: a Core Animation fade always
/// starts from what is ON SCREEN, so a press mid-fade carries on from there
/// (no jump, no dip to the dark base).
struct LayoutPictureView: UIViewRepresentable {
    let picture: FixedFocusPicture

    final class Coordinator { var key: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleToFill
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        guard context.coordinator.key != picture.key else { return }
        let first = context.coordinator.key == nil
        context.coordinator.key = picture.key
        if !first, picture.fade > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = picture.fade
            fade.timingFunction = picture.follows ? FixedFocusTint.focusTiming
                : CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer.add(fade, forKey: "layout")
        }
        view.image = picture.image
    }
}

struct TitleTintBackground: View {
    /// The rows' vignette: corners and edges a little darker (also over
    /// Details' blurred picture — Render Lab → Details: vignette below).
    static var vignette: some View {
        EllipticalGradient(stops: [.init(color: .clear, location: 0.55),
                                   .init(color: .black.opacity(0.18), location: 0.8),
                                   .init(color: .black.opacity(0.45), location: 1)],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.72)
    }
    let tint: Color?
    var second: Color? = nil
    /// The picture's colour layout (Home); without it, the title's colour.
    var picture: FixedFocusPicture? = nil

    /// How strongly the colour covers the dark base.
    static let tintStrength: Double = 0.5

    var body: some View {
        ZStack {
            // Even from top to bottom: no darker lower half, no corners.
            Color(white: 0.06)
            if let picture {
                // The picture's colour layout, at the tint's strength.
                LayoutPictureView(picture: picture)
                    .frame(width: 1920, height: 1080)
                    .opacity(Self.tintStrength)
            } else if let tint {
                // The title's colour, evenly over the whole surface.
                Rectangle().fill(tint.opacity(Self.tintStrength))
                // Two colours: the second one comes in towards the bottom
                // left of the lit side (a fixed mask: only colours change,
                // so title changes fade like the single colour).
                if let second {
                    Rectangle().fill(second.opacity(Self.tintStrength))
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.15),
                                                     .init(color: .black, location: 0.95)],
                                             startPoint: UnitPoint(x: 0.95, y: 0),
                                             endPoint: UnitPoint(x: 0.5, y: 1)))
                }
            }
            // Corners and edges a little darker.
            Self.vignette
        }
        .allowsHitTesting(false)
    }
}

/// The background's colours from the title's artwork: the picture's colour
/// layout (`layout`), and its main colours (`colors` — where there is no
/// layout, the title's colour).
@MainActor
enum FixedFocusTint {
    static func colors(for url: String) async
        -> (first: Color, second: Color?, deep: Color)? {
        guard let palette = await SpotlightTint.areaPalette(for: url), let first = palette.first else { return nil }
        let second = palette.count > 1 ? palette[1] : nil
        return (shown(hue: first.hue, saturation: first.saturation),
                second.map { shown(hue: $0.hue, saturation: $0.saturation) },
                deep(hue: first.hue, saturation: first.saturation))
    }

    /// "Tint: move with focus": the focus move's own curve and time.
    @MainActor static var focusAnimation: Animation {
        FixedFocusMotion.animation(duration: Motion.moveDuration)
    }

    /// The same for the colour layout's Core Animation fade (a fade takes a
    /// curve, not a spring: the no-bounce spring's shape, fast then a long
    /// settle).
    @MainActor static let focusTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.3, 1)

    /// The tint moves with focus: the colours (and layout) of the cards you
    /// may go to next, found beforehand — on the press there is nothing left
    /// to work out. (Both are cached per picture.)
    @MainActor static func prepare(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls {
                _ = await colors(for: url)
                _ = await self.layout(for: url)
            }
        }
    }

    @MainActor private static var layouts: [String: UIImage] = [:]

    /// "Picture's colour layout": the backdrop as a 4 × 3 grid of its own
    /// colours — each the average of its part of the picture (sky on top,
    /// the ground below, …) — every one at the tint's brightness and a
    /// little fuller (a calm, even, dark ground: no bright patches), blended
    /// smoothly across the screen. Made once per picture, a small still
    /// (it is all soft), stretched.
    @MainActor
    static func layout(for url: String) async -> UIImage? {
        if let hit = layouts[url] { return hit }
        // Four across, three down.
        let columns = 4, rows = 3
        guard let cells = await SpotlightTint.grid(for: url, columns: columns, rows: rows) else { return nil }
        // Every cell equally bright (the tint's brightness), a little fuller.
        let ceiling = min(0.9, Double(Spotlight.tintMaxSaturation + 0.05) / 1.1)
        // Each cell as the background shows a colour (`shown`).
        let shownCells: [[(Double, Double, Double)]] = cells.map { row in
            row.map { rgb in
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                let saturation = min(Double(s * Spotlight.tintSaturationBoost), ceiling)
                let ui = UIColor(shown(hue: h, saturation: CGFloat(saturation)))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                return (Double(r), Double(g), Double(b))
            }
        }
        let image = await Task.detached(priority: .userInitiated) { meshImage(shownCells) }.value
        if layouts.count > 60 { layouts.removeAll() }
        layouts[url] = image
        return image
    }

    /// The grid blended smoothly: each cell's colour at its centre, eased
    /// (smoothstep) between neighbours, flat beyond the outer centres.
    nonisolated private static func meshImage(_ cells: [[(Double, Double, Double)]]) -> UIImage {
        // Small: it is all soft gradients (stretched with smoothing).
        let w = 192, h = 108
        let rows = cells.count, columns = cells[0].count
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        for y in 0..<h {
            let gy = min(max((Double(y) + 0.5) / Double(h) * Double(rows) - 0.5, 0), Double(rows - 1))
            let y0 = min(Int(gy), rows - 2 < 0 ? 0 : rows - 2), ty = ease(gy - Double(y0))
            for x in 0..<w {
                let gx = min(max((Double(x) + 0.5) / Double(w) * Double(columns) - 0.5, 0), Double(columns - 1))
                let x0 = min(Int(gx), columns - 2 < 0 ? 0 : columns - 2), tx = ease(gx - Double(x0))
                let c00 = cells[y0][x0], c01 = cells[y0][x0 + 1], c10 = cells[y0 + 1][x0], c11 = cells[y0 + 1][x0 + 1]
                func mix(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> UInt8 {
                    let top = a + (b - a) * tx, bottom = c + (d - c) * tx
                    return UInt8(min(max((top + (bottom - top) * ty) * 255, 0), 255).rounded())
                }
                let i = (y * w + x) * 4
                pixels[i] = mix(c00.0, c01.0, c10.0, c11.0)
                pixels[i + 1] = mix(c00.1, c01.1, c10.1, c11.1)
                pixels[i + 2] = mix(c00.2, c01.2, c10.2, c11.2)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }

    /// The billboard's scrim: the title's main colour, nearly black — it
    /// darkens the artwork towards its own colour instead of grey.
    private static func deep(hue: CGFloat, saturation: CGFloat) -> Color {
        Color(hue: Double(hue), saturation: min(Double(saturation) * 1.2, 0.75), brightness: 0.1)
    }

    /// How bright the colour is before it is laid over the dark base.
    static let brightness: Double = 0.45

    /// The colour as the background shows it: at the tint's brightness.
    private static func shown(hue: CGFloat, saturation: CGFloat) -> Color {
        Color(hue: Double(hue), saturation: Double(saturation), brightness: brightness)
    }
}

/// The billboard's text (Home's and Details'): the logo (the name), then
/// the status badge and ratings, the facts and the tagline — no summary,
/// within the box's width less the text indent on both sides.
struct FixedFocusBillboardText: View {
    @EnvironmentObject private var theme: ThemeManager
    let item: MetaItem
    /// TMDB's season count, once loaded.
    let info: TMDBService.ShowSize?
    /// Why it's on the billboard (see `BillboardReason`), small above the
    /// logo; nil on Details.
    var reason: BillboardReason? = nil
    /// The ratings row (its room is kept either way).
    let ratings: AnyView?
    /// The tagline (none: the name).
    var tagline: String? = nil
    /// The logo to show instead of the item's (Details: the one Home
    /// showed — the record's is often another image).
    var logo: String? = nil

    static let width = FixedFocusMetrics.boxWidth - 2 * FixedFocusMetrics.textIndent
    static let logoToChips: CGFloat = 20
    /// The status badge, then the ratings (outlined boxes: `chipsGap` of
    /// extra room next to text).
    private var chips: some View {
        HStack(spacing: 10) {
            ForEach([FixedFocusShowInfo.status(item)].compactMap { $0 }, id: \.self) {
                TitleBadge(text: $0)
            }
            ratings
        }
        .frame(height: FixedFocusMetrics.factsHeight, alignment: .leading)
    }

    /// The logo's room (the reason above it).
    private var logoRoom: some View {
        Group {
            if let logo = logo ?? item.logo {
                // A logo that can't be loaded falls back to the name.
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading,
                            maxDimension: TitleBlock.logoWidth, showsPlaceholder: false,
                            fallback: AnyView(nameText))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .frame(width: TitleBlock.logoWidth)
            } else {
                nameText
            }
        }
        .frame(height: TitleBlock.logoHeight, alignment: .bottomLeading)
        // Above the logo's room, at the same spot for every title.
        .overlay(alignment: .topLeading) {
            if let reason {
                BillboardReasonLabel(reason: reason)
                    .frame(height: 30, alignment: .leading)
                    .offset(y: -Self.reasonRise)
            }
        }
    }

    /// Extra room above the chips (and the tagline after them): a plain
    /// line step left ~6 pt between the facts and the chips' boxes.
    static let chipsGap: CGFloat = 9
    /// The reason sits this far above the logo's room.
    static let reasonRise: CGFloat = 40
    /// How many rating sources show (the first ones, in Settings' order).
    static let ratingsShown = 3
    /// Where the Detail page's buttons start: below the chips line.
    static var buttonsY: CGFloat {
        FixedFocusMetrics.boxFrame.maxY + FixedFocusMetrics.infoHeight + 44
    }
    /// The chips line: the status badge, then the first ratings (nil: none).
    @MainActor
    static func ratingsChips(_ ratings: MDBListRatings?, settings: MDBListSettings, item: MetaItem) -> AnyView? {
        let entries = MDBListRatingsRow.entries(ratings, settings: settings, imdbFallback: item.imdbRating)
        return entries.isEmpty ? nil : AnyView(MDBListRatingsRow(
            entries: Array(entries.prefix(ratingsShown))))
    }
    private var nameText: some View {
        Text(item.name)
            .font(FusionType.heroTitle(theme.font))
            .foregroundStyle(theme.palette.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .frame(maxWidth: TitleBlock.logoWidth, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    /// The block's BOTTOM (the tagline) stands here — it grows up with
    /// what it has, as the Apple TV app's text sits on its buttons. (On
    /// Details: room for the buttons right below.)
    static var bottom: CGFloat { buttonsY - 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoRoom

            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.logoToChips)
                // The status badge and ratings, right under the logo.
                chips
                // THE FACTS — what it is: the relevant line, so the bright one.
                // (Without the rating: the chips carry it.)
                Text(FixedFocusShowInfo.factsLine(item, info: info))
                    .font(.system(size: FixedFocusMetrics.textSize, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                    .lineLimit(1)
                    .frame(height: FixedFocusMetrics.factsHeight, alignment: .leading)
                    .padding(.top, FixedFocusMetrics.factsOffset - 30 + Self.chipsGap)
                // The tagline — the mood, quiet and italic; no tagline: the
                // name (ALWAYS a line here: every title's block has the same
                // height, nothing moves).
                Text(tagline ?? item.name)
                    .font(.system(size: FixedFocusMetrics.textSize, weight: .regular).italic())
                    .foregroundStyle(Color.white.opacity(FixedFocusText.tagline))
                    .lineLimit(1)
                    .frame(height: 30, alignment: .leading)
                    .padding(.top, FixedFocusMetrics.factsOffset - 30)
            }
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        }
        .frame(width: Self.width, alignment: .leading)
    }
}

/// The billboard's reason: the kind of pick, muted, and its detail in white
/// ("NEW EPISODE · S3 E7 · YESTERDAY", "BECAUSE YOU WATCHED DARK"); trending
/// with its rank in a small white key — all on one line.
private struct BillboardReasonLabel: View {
    let reason: BillboardReason

    var body: some View {
        Group {
            if case .trending(let rank) = reason {
                // The rank in a small white key, the line's own height.
                HStack(spacing: 12) {
                    Text("\(rank)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(minWidth: 30)
                        .frame(height: 30)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(FixedFocusText.primary)))
                    caps(Text(reason.lead.uppercased()).foregroundStyle(Color.white.opacity(FixedFocusText.primary)))
                }
            } else {
                caps(Text(reason.lead.uppercased()).foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                     + Text(reason.detail.map { (separator + $0).uppercased() } ?? "")
                        .foregroundStyle(Color.white.opacity(FixedFocusText.primary)))
            }
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }

    /// "Because you watched" runs on into its title; the others get a dot.
    private var separator: String {
        if case .because = reason { return " " }
        return " · "
    }

    private func caps(_ text: Text) -> some View {
        text.font(.system(size: SectionHint.size, weight: SectionHint.weight))
            .tracking(SectionHint.tracking)
    }
}

/// Render Lab → Billboard scrim.
/// What Home's text needs from TMDB for a series: its season count (catalog
/// entries often carry no episode list) — one light request per title, kept
/// for the session.
@MainActor
enum FixedFocusShowInfo {
    private static var cache: [String: TMDBService.ShowSize] = [:]
    private static var statuses: [String: String] = [:]
    private static var loading: [String: Task<TMDBService.ShowSize?, Never>] = [:]

    static func known(_ item: MetaItem) -> TMDBService.ShowSize? { cache[item.id] }

    /// On disk for a day: a relaunch doesn't ask again. (v2: from the
    /// add-on's episode list — TMDB's counts, kept before, numbered some
    /// shows differently from the Episodes page.)
    private static let disk = DiskCache<TMDBService.ShowSize>(name: "show-sizes-v2")
    /// The status for half a day: AIRING follows the air dates.
    private static let statusDisk = DiskCache<String>(name: "series-status")
    private static let statusTTL: TimeInterval = 12 * 60 * 60

    /// A series' status chip: AIRING, RETURNING or "ENDED 2019" (see
    /// `status(for:facts:)`) — the catalog's years until it's known.
    static func status(_ item: MetaItem) -> String? {
        statuses[item.id] ?? TitleBlock.catalogStatus(item)
    }

    /// Seasons and episodes from the title's episode list (`SeriesEpisodes`
    /// — the Episodes page's), specials not counted — and the status.
    static func load(_ item: MetaItem) async -> TMDBService.ShowSize? {
        guard item.isSeries, let addonManager = AddonManager.shared else { return nil }
        if let hit = cache[item.id], statuses[item.id] != nil { return hit }
        if let stored = await disk.value(for: item.id, ttl: 24 * 60 * 60),
           let status = await statusDisk.value(for: item.id, ttl: statusTTL) {
            cache[item.id] = stored
            statuses[item.id] = status
            return stored
        }
        if let running = loading[item.id] { return await running.value }
        let task = Task { () -> TMDBService.ShowSize? in
            let meta = await SeriesEpisodes.fullMeta(for: item, addonManager: addonManager)
            if let status = status(for: meta, facts: await TMDBService.facts(for: item)) {
                statuses[item.id] = status
                await statusDisk.store(status, for: item.id)
            }
            return SeriesEpisodes.size(of: meta)
        }
        loading[item.id] = task
        let result = await task.value
        loading[item.id] = nil
        if let result {
            cache[item.id] = result
            await disk.store(result, for: item.id)
        }
        return result
    }

    /// How close "airing" is: an episode out within this, or due within it.
    static let airingWindow: TimeInterval = 10 * 24 * 60 * 60

    /// - AIRING: an episode aired in the last `airingWindow`, or the next is
    ///   due within it (the episode list's dates — the billboard's "New
    ///   episode" data).
    /// - ENDED + the year of its last episode: TMDB says ended or cancelled.
    /// - RETURNING: neither — between seasons (TMDB "Returning Series").
    /// Without TMDB, the catalog's years decide ENDED / RETURNING.
    private static func status(for meta: MetaItem, facts: TMDBService.TitleFacts?) -> String? {
        let now = Date()
        let dated = (meta.videos ?? []).filter { ($0.season ?? 0) > 0 }.compactMap(\.airedDate)
        let lastAired = dated.filter { $0 <= now }.max()
        let nextDue = dated.filter { $0 > now }.min()
        if let lastAired, now.timeIntervalSince(lastAired) <= airingWindow { return "AIRING" }
        if let nextDue, nextDue.timeIntervalSince(now) <= airingWindow { return "AIRING" }
        switch facts?.status {
        case "ENDED":
            let year = lastAired.map { String(Calendar.current.component(.year, from: $0)) }
                ?? TitleBlock.catalogYears(meta)?.end
            return year.map { "ENDED \($0)" } ?? "ENDED"
        case "ONGOING":
            return "RETURNING"
        default:
            return TitleBlock.catalogStatus(meta)
        }
    }

    /// Home's facts line (under the box, on the billboard): type, genre,
    /// the START year, size — no rating and no end year (the chips below
    /// carry those). The size from the catalog's episode list, else from
    /// `load` once it is known.
    static func factsLine(_ item: MetaItem, info: TMDBService.ShowSize? = nil) -> String {
        // A collection's folder: how many catalogs it holds.
        if item.type == "collection" { return item.description ?? "" }
        let info = info ?? cache[item.id]
        let size = item.regularSeasons.isEmpty && info != nil
            ? TitleBlock.seriesSizeText(item, seasons: info?.seasons, episodes: info?.episodes)
            : TitleBlock.seriesSizeText(item)
        return TitleBlock.metaSegments(for: item, seriesSize: size, includesRating: false,
                                       startYearOnly: true)
            .joined(separator: "  •  ")
    }
}

/// THE STAGE'S SHADE — what lies over a full-screen backdrop so text reads
/// on it: two fades (left, bottom). ONE definition for Home's billboard and the Detail page:
/// the same picture looks the same on both.
struct BillboardShade: View {
    /// What keeps the billboard's text readable: two fades, left and
    /// bottom (`twoFadesImage`).
    var body: some View {
        Image(uiImage: Self.twoFadesImage).resizable()
            .allowsHitTesting(false)
    }

    /// The billboard's dark fade over the left side (see
    /// `billboardLeftStops`). Not under the rows: their background is plain.
    var leftFade: some View {
        LinearGradient(stops: Self.billboardLeftStops, startPoint: .leading, endPoint: .trailing)
    }

    /// The billboard's left fade, built around ONE requirement: at the text
    /// column's right edge — as far as the summary's lines reach — the text
    /// must still be readable on a bright picture (75 % here; the
    /// calculated minimum is `scrimNeeded(textOpacity:)`, 61 % for the
    /// summary, plus reserve). From there it gets gradually darker to the
    /// left — a little by the column's middle, much at the screen's edge —
    /// and fades smoothly into the clear picture to the right. One smooth
    /// curve through these points; many stops: no bands.
    static let billboardLeftStops: [Gradient.Stop] = {
        let columnEnd = Double((FixedFocusMetrics.boxFrame.maxX - FixedFocusMetrics.textIndent) / 1920)
        let end = 0.7
        /// (share of the width, darkness)
        let points: [(x: Double, y: Double)] = [
            (0, 0.97),                                  // the screen's edge
            (0.1, 0.95),
            (columnEnd / 2, 0.9),                       // the column's middle
            (columnEnd, 0.75),                          // its right edge
            (columnEnd + (end - columnEnd) * 0.5, 0.33),
            (end, 0),
        ]
        return smoothStops(points, levelStart: false)
    }()

    /// Black stops along one smooth curve through `points` (share of the
    /// gradient, darkness) — monotone cubic interpolation (Fritsch–Carlson):
    /// smooth through every point, never overshooting; level at the ends
    /// (a soft landing; `levelStart` false: the first slope as it comes).
    static func smoothStops(_ points: [(x: Double, y: Double)], levelStart: Bool = true) -> [Gradient.Stop] {
        let darkness = smoothCurve(points, levelStart: levelStart)
        let start = points[0].x, end = points[points.count - 1].x
        let steps = 48
        return (0...steps).map { i in
            let x = start + (end - start) * Double(i) / Double(steps)
            return .init(color: .black.opacity(darkness(x)), location: x)
        }
    }

    /// The curve itself: darkness at any share (0 before the first point's
    /// value… held flat outside the points).
    static func smoothCurve(_ points: [(x: Double, y: Double)], levelStart: Bool = true) -> (Double) -> Double {
        let n = points.count
        let slopes = (0..<n - 1).map { (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x) }
        var tangents = (0..<n).map { i -> Double in
            if i == 0 { return levelStart ? 0 : slopes[0] }
            if i == n - 1 { return 0 }
            return slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<n - 1 where slopes[i] != 0 {
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[i] = scale * a * slopes[i]
                tangents[i + 1] = scale * b * slopes[i]
            }
        }
        let tangentsFixed = tangents
        return { x in
            if x <= points[0].x { return points[0].y }
            if x >= points[n - 1].x { return points[n - 1].y }
            let i = min((0..<n - 1).last { points[$0].x <= x } ?? 0, n - 2)
            let width = points[i + 1].x - points[i].x, t = (x - points[i].x) / width
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * points[i].y + (t3 - 2 * t2 + t) * width * tangentsFixed[i]
                + (-2 * t3 + 3 * t2) * points[i + 1].y + (t3 - t2) * width * tangentsFixed[i + 1]
            return min(max(y, 0), 1)
        }
    }

    /// "Two fades": the left and the bottom
    /// curve below, stacked — the darkening comes out of the bottom-left
    /// corner. (Tried: the darker of the two at every point.)
    /// No top band, no vignette. Made once (half size, stretched: all soft).
    static let twoFadesLeft: [(x: Double, y: Double)] = [
        (0, 0.8),                                      // the screen's edge
        (0.05, 0.75),
        (0.1, 0.70),
        (0.2, 0.66),                                    // the column's middle
        (0.36, 0.52),
        (0.48, 0.28),                                   // past the column
        (0.64, 0),
    ]
    static let twoFadesBottom: [(x: Double, y: Double)] = [
        (0.4, 0),
        (0.6, 0.25),
        (0.75, 0.47),                                   // the info block's foot
        (0.9, 0.65),
        (0.95, 0.74),
        (1, 0.8),                                      // the screen's edge
    ]
    /// A black shade from its alpha bytes (RGBA, premultiplied).
    static func blackImage(_ pixels: [UInt8], width w: Int, height h: Int) -> UIImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }

    static let twoFadesImage: UIImage = {
        let w = 960, h = 540
        let left = smoothCurve(twoFadesLeft, levelStart: false)
        let bottom = smoothCurve(twoFadesBottom)
        let across = (0..<w).map { left((Double($0) + 0.5) / Double(w)) }
        let down = (0..<h).map { bottom((Double($0) + 0.5) / Double(h)) }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // Black, premultiplied: only the alpha. STACKED (one over
                // the other): the darkening comes out of the corner.
                let dark = 1 - (1 - across[x]) * (1 - down[y])
                pixels[(y * w + x) * 4 + 3] = UInt8((dark * 255).rounded())
            }
        }
        return blackImage(pixels, width: w, height: h)
    }()

    /// How much black a WHITE picture needs over it for white text of
    /// `textOpacity` to reach `contrast` against it (WCAG's contrast ratio;
    /// 4.5 is its bar for body text). Any real picture is darker: more
    /// contrast than this.
    static func scrimNeeded(textOpacity: Double, contrast: Double = 4.5) -> Double {
        func luminance(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func reached(_ black: Double) -> Double {
            let ground = 1 - black
            let text = textOpacity + (1 - textOpacity) * ground
            return (luminance(text) + 0.05) / (luminance(ground) + 0.05)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if reached(mid) >= contrast { high = mid } else { low = mid }
        }
        return high
    }
}

/// Text levels: a hierarchy, mostly off-white.
enum FixedFocusText {
    /// THE BRIGHTEST any text gets: nothing in the UI is pure white (the
    /// logo, a picture, aside). The focused title, row names, the tagline.
    static let primary: CGFloat = 0.85
    static let heading: CGFloat = primary
    /// Facts and other secondary lines.
    static let secondary: CGFloat = 0.55
    /// The billboard's tagline: quieter than the facts.
    static let tagline: CGFloat = 0.58
}

/// The focus outline (Render Lab → Focus outline).
@MainActor
enum FixedFocusRing {
    static let width: CGFloat = 4
    static let color = UIColor.white.withAlphaComponent(0.85)
}

/// Where focus is on the billboard: title `index` of `count`.
struct FixedFocusBillboardPosition: Equatable {
    let index: Int
    let count: Int
}

extension HomeUIKitView {
    /// The billboard is paging by itself right now: the setting on, focus
    /// on it (not Details, a menu, or the app in the background).
    var autoPageRunning: Bool {
        guard let billboard, !autoPageDone else { return false }
        // It stops at the last title (no wrap back to the first).
        return autoPage && billboard.index < billboard.count - 1
            && homeScenePhase == .active && active && detailsOpen.depth == 0
    }
    static var rigidRowRest: CGFloat {
        1080 - FixedFocusRowsLayout.restingCardsOnScreen - FixedFocusMetrics.titleHeight
    }
    static var rigidBillboardTravel: CGFloat { 1080 - FixedFocusMetrics.aboveVisible }
    /// The first row's peek: how much of its cards shows.
    static let firstRowPeek: CGFloat = 60
    /// The dots' centre on the billboard: in the middle of its peek once
    /// it's up.
    static var rigidDotsMid: CGFloat { 1080 - FixedFocusMetrics.aboveVisible / 2 }
    /// Peeking: about the line of the first row's name, a little above it
    /// — clear of its cards.
    static var peekDotsMid: CGFloat {
        1080 - firstRowPeek - FixedFocusMetrics.titleHeight + FixedFocusMetrics.titleLine / 2 - peekDotsLift
    }
    static let peekDotsLift: CGFloat = 16
    /// (Peeking, only on the billboard: once it's up, where they always
    /// end — in the middle of its strip at the top.)
    private var dotsMid: CGFloat { depth == 0 ? Self.peekDotsMid : Self.rigidDotsMid }

    /// The billboard's text and dots for the rows to host — their own
    /// animations (a change made in a `withAnimation` here doesn't carry
    /// into the rows' host).
    var billboardOverlay: AnyView {
        AnyView(billboardContent
            .animation(FixedFocusMotion.animation(duration: Motion.moveDuration),
                       value: billboardItem?.id)
            .environmentObject(mdblist))
    }

    /// THE BILLBOARD (the Featured row in focus): the title's backdrop edge
    /// to edge under the shared scrim, the Detail page's title block in its
    /// place, and one dot per title. Left/Right crossfades in place; on Down
    /// it lifts away and the rows take the screen. (Focus itself is on the
    /// Featured row's invisible cells — see `FixedFocusRowsController`.)
    var billboardLayer: some View {
        // (Drawn by the rows — see `billboardOverlay`; only its upkeep
        // stays here.)
        Color.clear.frame(width: 0, height: 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: billboard) { _, now in
            if let now { lastBillboard = now }
        }
        // A page opened with focus still in the top bar (Movies / Series on
        // their first visit): the billboard is what's there, so show it all —
        // its text, hint and dots — not just its picture.
        .onAppear { primeBillboard(); autoPageDone = false }
        .onChange(of: homeScenePhase) { _, phase in if phase == .active { autoPageDone = false } }
        // THE BILLBOARD PAGING BY ITSELF: resting on it, the next title
        // after `BillboardAutoPage.interval` (the current segment fills over
        // it). Any press — a new title — starts it over; off the billboard,
        // in Details or a menu, it waits.
        .task(id: "\(billboard?.index ?? -1)|\(autoPageRunning)|\(autoPageVisit)") {
            guard autoPageRunning, let position = billboard, position.count > 1 else { return }
            try? await Task.sleep(for: .seconds(BillboardAutoPage.interval))
            guard !Task.isCancelled, autoPageRunning, billboard == position else { return }
            billboardCommand = FixedFocusRowsCommand(
                action: .select(rowID: featuredRowID, index: position.index + 1))
        }
        .onChange(of: rows.first(where: { $0.id == featuredRowID })?.items.map(\.id)) { _, _ in
            autoPageDone = false
            primeBillboard()
            refreshBillboardItem()
        }
    }

    /// The billboard's text, Details' buttons and hint for the swap, and
    /// the dots, laid out on the screen.
    var billboardContent: some View {
        ZStack(alignment: .topLeading) {
            if let item = billboardItem {
                BillboardCrossfade(item: item) { billboardText($0) }
                    // The ratings (cached by the service), as on Details.
                    .task(id: item.id) {
                        if billboardInfo[item.id] == nil, let info = await FixedFocusShowInfo.load(item) {
                            billboardInfo[item.id] = info
                        }
                    }
                    .task(id: item.id) {
                        guard billboardTaglines[item.id] == nil,
                              let tagline = await TMDBService.facts(for: item)?.tagline else { return }
                        billboardTaglines[item.id] = tagline
                    }
                    .task(id: item.id) {
                        guard billboardRatings[item.id] == nil,
                              let ratings = await MDBListService.ratings(for: item, settings: mdblist.settings)
                        else { return }
                        billboardRatings[item.id] = ratings
                    }
            }
            // The position, bottom centre (Left/Right): it stays in the strip
            // with the text.
            if let shown = billboard ?? lastBillboard {
                BillboardDots(count: shown.count, current: shown.index, focused: true,
                              timer: autoPageRunning ? BillboardAutoPage.interval : nil,
                              cycle: autoPageVisit)
                    .frame(height: SectionHint.size * 1.3)
                    .frame(width: 1920 - 2 * Spotlight.screenInset, alignment: .center)
                    .offset(x: Spotlight.screenInset,
                            y: dotsMid - SectionHint.size * 1.3 / 2)
                    .animation(FixedFocusMotion.animation(duration: FixedFocusMotion.billboardScroll),
                               value: depth == 0)
            }
        }
        // (Top-left: without the picture the layer is only as large as its
        // text — centred, it all moved down.)
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    /// Select on the billboard: into Details.
    func openBillboardTitle(_ item: MetaItem) {
        guard let onSelectFeatured else { onSelect(item); return }
        // As from any card (`DetailTransition.open`): Home dims, its picture
        // zooms to Details', Details comes in.
        DetailTransition.shared.open(item) { onSelectFeatured(item) }
    }

    /// Play's label as Details will first show it: where Continue Watching
    /// has the show, else the first episode.
    static func playTitle(_ item: MetaItem, progress entry: WatchProgress?) -> String {
        guard item.isSeries else { return "Play" }
        return "Play S\(entry?.season ?? 1):E\(entry?.episode ?? 1)"
    }

    /// The billboard's titles changed (its picks arrived): show the title now
    /// at its position.
    private func refreshBillboardItem() {
        guard let position = billboard,
              let row = rows.first(where: { $0.id == featuredRowID }), !row.items.isEmpty else { return }
        let index = min(position.index, row.items.count - 1)
        let item = row.items[index]
        guard item.id != billboardItem?.id else { return }
        billboard = FixedFocusBillboardPosition(index: index, count: row.items.count)
        focused = item
        withAnimation(FixedFocusMotion.animation(duration: Motion.moveDuration)) { billboardItem = item }
    }

    /// The logos either side of the billboard's title, decoded ahead so the
    /// next Left/Right swaps without waiting.
    private func warmNeighbourLogos(around index: Int) {
        guard let row = rows.first(where: { $0.id == featuredRowID }), !row.items.isEmpty else { return }
        let count = row.items.count
        for step in [1, -1, 2, -2] {
            guard let logo = row.items[((index + step) % count + count) % count].logo else { continue }
            Task.detached(priority: .userInitiated) {
                await ImageCache.shared.preload(logo, maxDimension: TitleBlock.logoWidth)
            }
        }
    }

    private func primeBillboard() {
        guard billboard == nil, billboardItem == nil,
              let row = rows.first(where: { $0.id == featuredRowID }), let first = row.items.first
        else { return }
        billboardItem = first
        billboard = FixedFocusBillboardPosition(index: 0, count: row.items.count)
        focused = first
    }


    /// The billboard's text for a title, at its place (standing on its
    /// bottom line — it grows up — the buttons below it).
    /// (The reason — Details has none — goes with the swap; the rest stays
    /// exactly: Details' text is the billboard's.)
    private func billboardText(_ item: MetaItem) -> some View {
        FixedFocusBillboardText(item: item, info: billboardInfo[item.id],
                                reason: billboardReasons[item.id],
                                ratings: billboardRatingsRow(item),
                                tagline: billboardTaglines[item.id])
            .frame(height: FixedFocusBillboardText.bottom, alignment: .bottomLeading)
            .padding(.leading, FixedFocusMetrics.titleInset)
    }



    /// The ratings chips (nil: none at all) — the catalog's IMDb score until
    /// MDBList's arrive, as on the Detail page.
    private func billboardRatingsRow(_ item: MetaItem) -> AnyView? {
        FixedFocusBillboardText.ratingsChips(billboardRatings[item.id], settings: mdblist.settings, item: item)
    }
}

/// The billboard's text changing title: a crossfade in place, in the
/// picture's time (only the picture drifts — the text drifting looked
/// restless). Started from INSIDE (the text lives in the rows' own host,
/// where a change animated from outside — the page's `withAnimation`, a
/// transition there — just swaps).
struct BillboardCrossfade<Page: View>: View {
    let item: MetaItem
    @ViewBuilder let page: (MetaItem) -> Page
    @State private var shown: MetaItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown {
                // (The same title: live — a rating, the tagline arriving.)
                page(shown.id == item.id ? item : shown)
                    .id(shown.id)
                    .transition(.opacity)
            }
        }
        .onAppear { if shown == nil { shown = item } }
        .onChange(of: item.id) { _, _ in
            withAnimation(FixedFocusMotion.animation(duration: Motion.moveDuration)) {
                shown = item
            }
        }
    }
}

/// The cards' light frame — a printed card's rim — and the soft shadow
/// under a lifted card: pre-rendered, stretchable images (drawn once, they
/// follow a card's size, also as it grows) — nothing drawn live on a moving
/// card.
enum FixedFocusCardEdge {
    /// The focus outline in the top bar's light (Render Lab → Focus outline)
    /// — off: a plain white line.
    /// (The top bar's light is no focus style any more: every focused card
    /// uses the same plain line — `FixedFocusRing`.)
    @MainActor static var focusLight: Bool { false }
    @MainActor static var focusImage: UIImage { art.focus }

    /// The rim over the card: an even 2 pt line inside the corner, there
    /// on dark artwork, quiet on light.
    @MainActor static var rim: UIImage { art.rim }

    /// How far the shadow reaches beyond the card.
    static let shadowPad: CGFloat = 70

    @MainActor static var shadowImage: UIImage { art.shadow }

    @MainActor private static let art = Art()

    @MainActor
    private struct Art {
        let rim: UIImage
        let focus: UIImage
        let shadow: UIImage

        init() {
            let radius = Spotlight.cornerRadius
            // Drawn at a small size and stretched: the corners stay, the
            // edges between them scale (so gradients along them scale too).
            let size = CGSize(width: 200, height: 200)
            let caps = UIEdgeInsets(top: radius + 4, left: radius + 4, bottom: radius + 4, right: radius + 4)
            func ring(_ inset: CGFloat, _ width: CGFloat, _ color: UIColor, in cg: CGContext) {
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset + width / 2, dy: inset + width / 2)
                cg.addPath(UIBezierPath(roundedRect: rect, cornerRadius: max(radius - inset - width / 2, 0)).cgPath)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(width)
                cg.strokePath()
            }
            func draw(_ body: (CGContext) -> Void) -> UIImage {
                UIGraphicsImageRenderer(size: size).image { body($0.cgContext) }
                    .resizableImage(withCapInsets: caps, resizingMode: .stretch)
            }
            rim = draw { ring(0, 2, UIColor.white.withAlphaComponent(0.3), in: $0) }
            // FOCUS: the top bar's light, clear — a full outline, brightest along
            // the top and the bottom, the sides still well visible. (A
            // see-through version that let the picture's colour in was too
            // faint for focus.)
            focus = draw { cg in
                let width: CGFloat = 4
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: width / 2, dy: width / 2)
                cg.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius - width / 2).cgPath)
                cg.setLineWidth(width)
                cg.replacePathWithStrokedPath()
                cg.clip()
                let colors = [1.0, 0.8, 0.55, 0.8, 0.95].map { UIColor(white: 1, alpha: $0).cgColor } as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                      locations: [0, 0.2, 0.5, 0.8, 1]) {
                    cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
            }
            // A soft shadow under the card, a little lower than it (only
            // outside the card's shape).
            let pad = FixedFocusCardEdge.shadowPad
            let shadowSize = CGSize(width: 200 + 2 * pad, height: 200 + 2 * pad)
            let card = CGRect(x: pad, y: pad, width: 200, height: 200)
            let shape = UIBezierPath(roundedRect: card, cornerRadius: radius)
            shadow = UIGraphicsImageRenderer(size: shadowSize).image { ctx in
                let outside = UIBezierPath(rect: CGRect(origin: .zero, size: shadowSize))
                outside.append(shape)
                outside.usesEvenOddFillRule = true
                outside.addClip()
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 14), blur: 40,
                                        color: UIColor.black.withAlphaComponent(0.6).cgColor)
                UIColor.black.setFill()
                shape.fill()
            }.resizableImage(withCapInsets: UIEdgeInsets(top: pad + radius + 20, left: pad + radius + 20,
                                                         bottom: pad + radius + 20, right: pad + radius + 20),
                             resizingMode: .stretch)
        }
    }
}

struct FixedFocusRows: UIViewControllerRepresentable {
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var theme: ThemeManager
    let rows: [HomeRow]
    let featuredRowID: String
    let continueRowID: String
    let active: Bool
    let progress: [String: WatchProgress]
    /// Rows of landscape cards besides Continue Watching (Search's).
    var landscapeRowIDs: Set<String> = []
    /// Collection rows: landscape tiles in a panel (see `FixedFocusPanelView`).
    var panelRowIDs: Set<String> = []
    /// Destination rows (see `FixedFocusMetrics.destinationPosterHeight`).
    var destinationRowIDs: Set<String> = []
    /// Rows of ONE wide banner (Search's Top Result: see
    /// `FixedFocusBannerCell`), and its height.
    var bannerRowIDs: Set<String> = []
    var bannerHeight: CGFloat = FixedFocusMetrics.bannerHeight
    /// Destination rows' posters' height (Search: smaller, under the keyboard).
    var destinationPosterHeight: CGFloat = FixedFocusMetrics.destinationPosterHeight
    /// Where the focused row's name sits (Home's spot by default)…
    var rowTop: CGFloat = FixedFocusMetrics.rowTop
    /// …and how much of the rows above and below shows.
    var aboveVisible: CGFloat = FixedFocusMetrics.aboveVisible
    var belowVisible: CGFloat = FixedFocusMetrics.belowVisible
    /// The focus outline only while focus is in the rows.
    var ringOnlyWithFocus = false
    /// New content starts over: the first row, each row's first title
    /// (Search: a new query). Home keeps its places.
    var startsOverOnChange = false
    let onSelect: (MetaItem) -> Void
    let onSelectFeatured: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    /// Select on a title's card (not the billboard, not Continue Watching,
    /// not a folder): the title and the card as the morph's start — Details
    /// opens through `DetailTransition`. nil: `onSelect`.
    var onOpenDetails: ((MetaItem) -> Void)? = nil
    /// A choice in a Continue Watching card's hold menu (the system context
    /// menu): the row and the card as a zoom's start. nil: no menu.
    var onContinueMenu: ((ContinueMenuAction, WatchProgress) -> Void)? = nil
    /// Select held on a title's card (not a billboard, not a folder): its
    /// menu's items (`TitleMenu`), given the title and its row's id. nil: no menu.
    var titleMenu: ((MetaItem, String) -> [MenuEntry])? = nil
    /// How far below the billboard the focused row is (0: on it or no
    /// billboard; 1: the first row below).
    var onDepth: (Int) -> Void = { _ in }
    /// The picture the focused card shows (the background colour follows it).
    var onFocusArt: (String?) -> Void = { _ in }
    /// Details: the billboard's focus is OUTSIDE the rows (its buttons) —
    /// its invisible cards take focus only on the way back up.
    var externalBillboard = false
    /// A card's state line on its picture (Details' episodes).
    var cardStates: [String: FixedFocusCardState] = [:]
    /// Select on a card, before anything else (true: handled) — Details plays
    /// its episodes.
    var onSelectInRow: ((MetaItem, String) -> Bool)? = nil
    /// Up out of these rows doesn't go to the row above: `onUpExit` gets
    /// the row's id (Details: its season pill takes focus).
    var upExitRowIDs: Set<String> = []
    var onUpExit: (String) -> Void = { _ in }
    /// Rows whose name doesn't show (something drawn in its place —
    /// Details' season control).
    var hiddenTitleRowIDs: Set<String> = []
    /// A one-off request from outside (a new id runs it once).
    var command: FixedFocusRowsCommand? = nil
    /// RIGID billboard (Details): under the billboard the first row waits
    /// with its name HERE (screen y) and its cards hidden right below it —
    /// the layout of the rows, just lower. Down / Up move everything one
    /// distance, nothing else (nil: Home's scroll, the name lifted onto the
    /// billboard).
    var rigidRest: CGFloat? = nil
    /// …and, lifted above its cards, where its NAME shows on the billboard
    /// (screen y of its line): the lift shrinks to nothing on Down, so the
    /// name and the cards meet (Home's `liftNextTitle`).
    var rigidNameY: CGFloat? = nil
    /// RIGID billboard: the next row PEEKS instead — its cards' top this far
    /// up the screen's bottom edge (dimmed, its name hidden); the row rests
    /// that much higher (nil: hidden, its name on the billboard).
    var rigidPeek: CGFloat? = nil
    /// …and its name stays above its cards (Home); off: hidden (Details).
    var rigidPeekShowsName = false
    /// The billboard's picture isn't drawn by the rows (Details draws its
    /// own, fixed, behind them).
    var hidesBillboardPicture = false
    /// SwiftUI on its own line under a row's name (or its header) — the
    /// row's cards lower by as much (`titleAccessoryHeight`, under a header
    /// `headerAccessoryHeight`); shown while the row has focus (Details'
    /// season progress).
    var rowTitleAccessories: [String: AnyView] = [:]
    /// Rows with glass buttons in their name's place while they have focus
    /// (Details' seasons): moving focus along them (Up from the cards),
    /// Up to the billboard, Down into the row. A button taking focus is
    /// reported to `onHeaderFocus` (row id, button index).
    var rowHeaders: [String: FixedFocusRowHeader] = [:]
    var onHeaderFocus: (String, Int) -> Void = { _, _ in }
    /// The billboard's own text and buttons (Details), hosted by the rows
    /// and moved (and dimmed) with them in the SAME animation — as a SwiftUI
    /// layer outside, it was animated by SwiftUI on the main thread and fell
    /// behind the rows (Core Animation) whenever the page was busy.
    var billboardOverlay: AnyView? = nil
    /// A page's header above the first row (a folder page), from the
    /// screen's top, `pageHeaderHeight` tall: moves up with that row.
    var pageHeader: AnyView? = nil
    var pageHeaderHeight: CGFloat = 0
    /// Its height from the top of the screen: no more than its content needs
    /// — over the rows it hides them from focus (tvOS skips what's covered).
    var billboardOverlayHeight: CGFloat = 1080
    /// The overlay UNDER the rows (Home: the billboard's focus is its own
    /// hidden cards — anything over them hides them from focus).
    var billboardOverlayBelowRows = false
    /// RIGID billboard (Home): its picture doesn't scroll with the rows — it
    /// stays, blurs and darkens on the way down, then gives way to the
    /// background's colours (`StagePictureView.blursBelow`).
    var pinnedBillboardPicture = false
    /// How far the billboard itself (picture, text) goes up for the first
    /// row, if not the rows' distance (Home: until its edge is at the top
    /// bar's middle — the rows' usual peek above).
    var rigidBillboardTravel: CGFloat? = nil
    /// Moving-focus rows whose focus stays in place: every step also scrolls
    /// the row, the focused card always at the first card's spot (Details'
    /// episodes). Others scroll only at the edge of the cards in view.
    var anchoredRowIDs: Set<String> = []
    /// Rows that are a SwiftUI view, not cards (Details' About): its own
    /// focusable parts; focus moving into it moves the rows as any row.
    var customRows: [String: FixedFocusCustomRow] = [:]
    /// Moving-focus rows of logos (Details' network & studios): small wide
    /// cards, each logo fitted on a light plate (logos are drawn for light
    /// ground).
    var logoRowIDs: Set<String> = []
    let onFocusItem: (MetaItem, FixedFocusBillboardPosition?) -> Void

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
        controller.onSelectFeatured = onSelectFeatured
        controller.onResume = onResume
        controller.onOpenDetails = onOpenDetails
        controller.onContinueMenu = onContinueMenu
        controller.titleMenu = titleMenu
        // SwiftUI inside the cells (the banner's chips) gets the app's stores.
        controller.environment = { [mdblist, theme] in
            AnyView($0.environmentObject(mdblist).environmentObject(theme))
        }
        controller.onFocusItem = onFocusItem
        controller.onDepth = onDepth
        controller.onFocusArt = onFocusArt
        controller.externalBillboard = externalBillboard
        controller.cardStates = cardStates
        controller.onSelectInRow = onSelectInRow
        controller.upExitRowIDs = upExitRowIDs
        controller.onUpExit = onUpExit
        controller.hiddenTitleRowIDs = hiddenTitleRowIDs
        controller.rigidRest = rigidRest
        controller.rigidPeek = rigidPeek
        controller.rigidPeekShowsName = rigidPeekShowsName
        controller.rigidNameY = rigidNameY
        controller.hidesBillboardPicture = hidesBillboardPicture
        controller.rowTitleAccessories = rowTitleAccessories
        controller.anchoredRowIDs = anchoredRowIDs
        controller.customRows = customRows
        controller.logoRowIDs = logoRowIDs
        controller.onHeaderFocus = onHeaderFocus
        controller.rowHeaders = rowHeaders
        controller.continueRowID = continueRowID
        controller.landscapeRowIDs = landscapeRowIDs
        controller.panelRowIDs = panelRowIDs
        controller.destinationRowIDs = destinationRowIDs
        controller.bannerRowIDs = bannerRowIDs
        controller.bannerHeight = bannerHeight
        controller.destinationPosterHeight = destinationPosterHeight
        controller.rowTop = rowTop
        controller.aboveVisible = aboveVisible
        controller.belowVisible = belowVisible
        controller.ringOnlyWithFocus = ringOnlyWithFocus
        controller.startsOverOnChange = startsOverOnChange
        controller.featuredRowID = featuredRowID
        // Hidden while another tab is in front: not in the focus engine's
        // way (a transparent SwiftUI layer alone doesn't guarantee that).
        if controller.isViewLoaded { controller.view.isHidden = !active }
        controller.progress = progress
        controller.update(rows)
        if let command { controller.run(command) }
        controller.billboardOverlayHeight = billboardOverlayHeight
        controller.billboardOverlayBelowRows = billboardOverlayBelowRows
        controller.rigidBillboardTravel = rigidBillboardTravel
        controller.pinnedBillboardPicture = pinnedBillboardPicture
        controller.setBillboardOverlay(billboardOverlay)
        controller.setPageHeader(pageHeader, height: pageHeaderHeight)
    }
}

/// Geometry shared by the controller and its cells (points, 1920 × 1080).
enum FixedFocusMetrics {
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
    /// A landscape card's width at a given height (the box's 16:9).
    static func landscapeWidth(height card: CGFloat) -> CGFloat { card * boxWidth / height }
    /// The row name (the original Home's size): its line, then a small gap
    /// to the row — it belongs to the row.
    static let titleLine: CGFloat = 48
    static let titleHeight: CGFloat = titleLine + 14
    /// The row below shows as much as on the original Home at the bottom
    /// edge (a little under half); the row above shows what's left of it.
    /// Rows further up / down than the neighbours: a whole row apart.
    static var rowPitch: CGFloat { titleHeight + height + 70 }
    /// The row above: its cards' lower part shows at the top, ending as far
    /// above the focused row's name as the next row's name is below the
    /// box's info (the same gap above and below; the same for every kind of
    /// row, the billboard too).
    static var aboveVisible: CGFloat { rowTop - peekGap }
    /// Between the focused row and the peeks: the next row's name this far
    /// below the box's info — and the same above.
    static var peekGap: CGFloat {
        1080 - belowVisible - titleHeight - (boxFrame.maxY + infoGap + infoHeight)
    }
    /// The row below: this much of its posters shows at the bottom (as on
    /// the original Home — a little under half).
    static var belowVisible: CGFloat { Spotlight.previewVisibleHeight }
    /// Rows other than the focused one (the preview below).
    static let dimmedAlpha: CGFloat = 0.45
    /// The posters left of the box in the focused row.
    static let previousAlpha: CGFloat = 0.45
    /// The focused row's name: exactly where the original Home had it.
    static var rowTop: CGFloat {
        Spotlight.catalogTitleY(screenHeight: 1080, topPadding: Spotlight.topPaddingUnderNav)
    }
    /// DESTINATION rows (Saved for Later, collections) — you go there for
    /// something you already know, not to be shown one title at a time:
    /// the system's own scrolling and lift, and a caption under every card.
    /// Saved for Later: posters at the rows' usual size…
    static let destinationPosterHeight: CGFloat = height
    /// …smaller posters, more in view: Search's titles, Details' people.
    static let compactPosterHeight: CGFloat = 330
    /// A short custom row in focus ends this far above the screen's bottom
    /// (see `FixedFocusCustomRow.contentHeight`).
    static let customBottomGap: CGFloat = 60
    /// A logo row's cards (Details' network & studios).
    static let logoCard = CGSize(width: 260, height: 140)
    /// …collections: landscape tiles (doors).
    static let destinationTileHeight: CGFloat = 300
    /// Continue Watching's cards: the landscape tiles' size (more of them
    /// on screen), whichever its focus style.
    static let continueHeight: CGFloat = destinationTileHeight
    /// The gap between moving-focus cards: wider than the fixed rows'
    /// (`gap`) — a lifted card grows into it.
    static let destinationGap: CGFloat = 40
    /// Between a row's cards: what the fixed rows keep beside their box
    /// (`gap`), around the LIFTED card — the gap at rest grows by as much
    /// as a card of that width grows on each side.
    /// How much a moving-focus card grows when focused.
    static let movingFocusLift: CGFloat = 0.05
    @MainActor static func destinationGap(cardWidth: CGFloat) -> CGFloat {
        (gap + cardWidth * movingFocusLift / 2).rounded()
    }
    /// The captions under moving-focus cards: a little smaller than the
    /// fixed box's text, so more of them fits; the second line this far
    /// below the first.
    static let captionSize: CGFloat = 22
    static let captionLineOffset: CGFloat = 33
    /// The fixed box while Select is pressed or held: a little smaller.
    /// (A moving-focus card instead loses its lift: back to its own size.)
    static let pressScale: CGFloat = 0.97
    /// …and while its hold menu is open: a little larger than focused.
    static let heldGrowth: CGFloat = 0.02
    /// The fixed box's own size: the portrait posters' height, its left edge
    /// on the row name's.
    static let boxScale: CGFloat = 1
    /// Their focus: tvOS's lift (tilt, sheen) — off: Cue's own outline, as
    /// on the other rows.
    static let destinationSystemLift = false
    /// The least of the cards before / after that shows once a row moves.
    static let destinationSliver: CGFloat = 24
    /// A banner row's card: the content's width, this tall (at most).
    static let bannerHeight: CGFloat = 380
    static var bannerWidth: CGFloat { 1920 - 2 * inset }
    /// Under each card: its name and a second line, with room for the lift.
    static let captionRoom: CGFloat = 86
    /// The panel around a collection row: how far it reaches beyond the
    /// row's name and cards (left of the box, above the name, under the
    /// info), and its corners.
    static let panelPad: CGFloat = 36
    static let panelRadius: CGFloat = 32
    /// How far a panel reaches beyond its row's name and cards: above the
    /// name, and below the cards (the info under the box, then its pad).
    static var panelReach: (above: CGFloat, below: CGFloat) { (panelPad, panelPad) }
    /// Under the box: the title's name, then its facts (meta) line.
    static let infoGap: CGFloat = 18
    static let factsOffset: CGFloat = 36
    static let factsHeight: CGFloat = 30
    /// Name, facts and the chips line.
    static let infoHeight: CGFloat = 104 + FixedFocusBillboardText.chipsGap
    /// ONE size for the text around the box and on the billboard: the
    /// title's name, its facts line and the summary (they differ only in
    /// brightness). Just above the smallest size that reads well on a TV.
    static let textSize: CGFloat = 24
    /// The facts line, on screen (the billboard's meta line sits here too).
    static var factsY: CGFloat { boxFrame.maxY + infoGap + factsOffset }
    /// One row below the billboard, none of it shows: Down scrolls one whole
    /// screen.
    static let billboardTopPeek: CGFloat = 0
    /// …and that row stands this much lower than usual, under the strip.
    static var billboardStripDrop: CGFloat { max(0, billboardTopPeek + 10 - rowTop) }
    /// How far the billboard lifts as it fades out on Down.
    static let billboardLift: CGFloat = 80
    /// The box, on screen.
    static var boxFrame: CGRect {
        CGRect(x: inset, y: rowTop + titleHeight, width: boxWidth, height: height)
    }
}

final class FixedFocusRowsController: UIViewController, UICollectionViewDataSource,
                                      UICollectionViewDelegateFlowLayout {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onResume: (WatchProgress) -> Void = { _ in }
    /// The focused title (for the background tint) — and, on the billboard,
    /// which of its titles.
    var onFocusItem: (MetaItem, FixedFocusBillboardPosition?) -> Void = { _, _ in }
    var onDepth: (Int) -> Void = { _ in }
    /// The picture the focused card shows (the background colour follows it).
    var onFocusArt: (String?) -> Void = { _ in }

    /// The first row below the billboard stands lower while it is in focus
    /// (see `FixedFocusMetrics.billboardStripDrop`).
    var rowDrop: CGFloat {
        guard let featured = rows.firstIndex(where: { $0.id == featuredRowID }),
              focusedRow == featured + 1 else { return 0 }
        if rigidRest != nil { return 0 }
        return FixedFocusMetrics.billboardStripDrop
    }

    private func depth(of rowIndex: Int) -> Int {
        rows.firstIndex(where: { $0.id == featuredRowID }).map { max(rowIndex - $0, 0) } ?? 0
    }
    /// The Featured row: THE BILLBOARD. Its cells are invisible focus
    /// targets (native Left/Right between its titles, Down to the rows);
    /// what you see is drawn full screen by `HomeUIKitView.billboardLayer`.
    var featuredRowID = ""

    func isFeatured(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && rows[rowIndex].id == featuredRowID
    }
    /// Continue Watching: landscape cards (no growing, no fixed box — the
    /// focused card itself sits at the spot), Select resumes.
    var continueRowID = ""
    var progress: [String: WatchProgress] = [:]

    func isContinue(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && rows[rowIndex].id == continueRowID
    }
    /// Landscape cards: Continue Watching's look, for other rows too.
    var landscapeRowIDs: Set<String> = []

    func isLandscape(_ rowIndex: Int) -> Bool {
        isContinue(rowIndex) || isPanel(rowIndex)
            || (rows.indices.contains(rowIndex) && landscapeRowIDs.contains(rows[rowIndex].id))
    }
    /// Collection rows: their tiles in a panel.
    var panelRowIDs: Set<String> = []

    func isPanel(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && panelRowIDs.contains(rows[rowIndex].id)
    }
    /// Destination rows: native scrolling, the system's lift, captions.
    /// A change (Render Lab: Continue Watching's focus) rebuilds the rows
    /// at once — half-switched, a row showed both kinds of cards.
    var destinationRowIDs: Set<String> = [] {
        didSet {
            guard destinationRowIDs != oldValue, isViewLoaded else { return }
            if isDestination(focusedRow) { box.alpha = 0 }
            outer.reloadData()
            outer.collectionViewLayout.invalidateLayout()
            applyDimming()
        }
    }

    func isDestination(_ rowIndex: Int) -> Bool {
        isBanner(rowIndex) || (rows.indices.contains(rowIndex) && destinationRowIDs.contains(rows[rowIndex].id))
    }

    /// Banner rows: one wide card, drawn like a small billboard. They move
    /// and focus as destination rows do.
    var bannerRowIDs: Set<String> = []
    var bannerHeight = FixedFocusMetrics.bannerHeight
    var destinationPosterHeight = FixedFocusMetrics.destinationPosterHeight

    func isBanner(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && bannerRowIDs.contains(rows[rowIndex].id)
    }

    /// A destination row's card (picture only — the caption is below it).
    func destinationCard(_ rowIndex: Int) -> CGSize {
        if isBanner(rowIndex) { return CGSize(width: FixedFocusMetrics.bannerWidth, height: bannerHeight) }
        if isLogo(rowIndex) { return FixedFocusMetrics.logoCard }
        // Continue Watching (moving focus): its cards at their own size —
        // the fixed box's.
        if isContinue(rowIndex) {
            return CGSize(width: FixedFocusMetrics.landscapeWidth(height: FixedFocusMetrics.continueHeight),
                          height: FixedFocusMetrics.continueHeight)
        }
        return isLandscape(rowIndex)
            ? CGSize(width: FixedFocusMetrics.landscapeWidth(height: FixedFocusMetrics.destinationTileHeight),
                     height: FixedFocusMetrics.destinationTileHeight)
            : CGSize(width: destinationPosterHeight * 2 / 3, height: destinationPosterHeight)
    }
    /// The focused row's name, on screen (the box below it).
    var rowTop: CGFloat = FixedFocusMetrics.rowTop {
        didSet { if rowTop != oldValue, isViewLoaded { view.setNeedsLayout() } }
    }
    /// How much of the rows above and below the focused one shows.
    var aboveVisible: CGFloat = FixedFocusMetrics.aboveVisible
    var belowVisible: CGFloat = FixedFocusMetrics.belowVisible
    /// The focus outline only while focus is in the rows (Search; Home
    /// keeps it while you're up in the top bar).
    var ringOnlyWithFocus = false
    /// The row's cards' height.
    func cardHeight(_ rowIndex: Int) -> CGFloat {
        if let custom = custom(rowIndex) { return custom.height }
        return isBanner(rowIndex) ? bannerHeight
            : isDestination(rowIndex) ? destinationCard(rowIndex).height + FixedFocusMetrics.captionRoom
            : FixedFocusMetrics.height
    }

    /// The box, on screen, for the focused row's card size (under its name:
    /// lower for a collection, whose panel's top is the row's anchor).
    private var boxFrame: CGRect {
        let height = cardHeight(focusedRow)
        let anchorOffset = isPanel(focusedRow) ? FixedFocusMetrics.panelReach.above : 0
        let width = FixedFocusMetrics.landscapeWidth(height: height)
        return CGRect(x: FixedFocusMetrics.inset, y: rowTop + rowDrop + anchorOffset + FixedFocusMetrics.titleHeight,
                      width: width, height: height)
    }
    private(set) var rows: [HomeRow] = []
    /// Each row's title at the spot.
    private(set) var selected: [String: Int] = [:]
    /// The row focus is in (only it has a grown cell).
    private(set) var focusedRow = 0 {
        didSet {
            belowGuide.isEnabled = isFeatured(focusedRow)
        }
    }
    private var outer: UICollectionView!
    /// Reuse identifiers registered so far (one per catalog).
    private var registeredRows = Set<String>()
    /// THE FIXED BOX: on Left/Right it never moves — only its content
    /// changes; the posters slide in behind it.
    private let box = FixedFocusBoxView()
    private var hasFocus = false
    /// See `FixedFocusRows.externalBillboard`. (Focus is "in" the billboard
    /// from the start: Down from its buttons is the billboard's scroll.)
    var externalBillboard = false {
        didSet { if externalBillboard, !oldValue { hasFocus = true } }
    }
    /// The billboard has the focus outside (its buttons): its cards don't
    /// take focus.
    var billboardFocusOutside: Bool { externalBillboard && isFeatured(focusedRow) }
    var cardStates: [String: FixedFocusCardState] = [:]
    var onSelectInRow: ((MetaItem, String) -> Bool)?

    var startsOverOnChange = false

    func update(_ rows: [HomeRow]) {
        // The titles and their art compared, not just the counts — a new
        // search brings as many results; a setting changes the art — except
        // while focus may be in the rows: a background refresh of Home must
        // not reload them under your focus (count changes only, then).
        let strict = startsOverOnChange || (isViewLoaded && view.isHidden)
        let changed = rows.map(\.id) != self.rows.map(\.id)
            || zip(rows, self.rows).contains {
                strict ? $0.contentKey != $1.contentKey : $0.items.count != $1.items.count
            }
        // The billboard's titles (its picks arrive just after Home paints)
        // change in place: only its own row is refreshed.
        let featured = rows.firstIndex { $0.id == featuredRowID }
        let featuredChanged = featured.map { index in
            self.rows.indices.contains(index) && rows[index].contentKey != self.rows[index].contentKey
        } ?? false
        self.rows = rows
        // A row's new name (Details: the season scrolled into): in place.
        if !changed, isViewLoaded {
            for case let cell as FixedFocusRowCell in outer.visibleCells where rows.indices.contains(cell.rowIndex) {
                cell.showTitle(rows[cell.rowIndex].title)
            }
        }
        if !changed, featuredChanged, let featured, isViewLoaded {
            (outer.cellForItem(at: IndexPath(item: featured, section: 0)) as? FixedFocusRowCell)?
                .configure(rowIndex: featured, controller: self)
            return
        }
        guard changed else { return }
        if startsOverOnChange {
            selected = [:]
            focusedRow = 0
        }
        if focusedRow >= rows.count { focusedRow = max(rows.count - 1, 0) }
        guard isViewLoaded else { return }
        outer.reloadData()
        outer.collectionViewLayout.invalidateLayout()
        applyDimming()
        revealNextNameIfNew()
        startOnCollectionIfAsked()
        // The box shows the focused row's title as it is now.
        if box.alpha > 0, rows.indices.contains(focusedRow) {
            let row = rows[focusedRow]
            let index = selected[row.id] ?? 0
            if row.items.indices.contains(index) {
                let item = row.items[index]
                box.show(item, animated: false)
            }
        }
    }

    /// Dev (`-homeFocusCollection`): start on the first collection row —
    /// the simulator can't send arrow keys.
    private var pendingFocusRow: Int?
    private var startedOnCollection = false

    private func startOnCollectionIfAsked() {
        // (`-homeFocusRow N`: start on row N.)
        let args = ProcessInfo.processInfo.arguments
        let asked = args.firstIndex(of: "-homeFocusRow").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        guard !startedOnCollection,
              let index = asked.flatMap({ rows.indices.contains($0) ? $0 : nil })
                ?? (args.contains("-homeFocusCollection") ? rows.indices.first(where: isPanel) : nil)
        else { return }
        startedOnCollection = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            focusedRow = index
            onDepth(depth(of: index))
            applyDimming()
            outer.collectionViewLayout.invalidateLayout()
            outer.layoutIfNeeded()
            place(box, boxFrame)
            pendingFocusRow = index
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let cell = pendingFocusCell {
            pendingFocusCell = nil
            return [cell]
        }
        // On the billboard, its focus is the overlay's (Details' Play).
        if pendingFocusRow == nil, billboardFocusOutside, let overlayHost { return [overlayHost] }
        if let index = pendingFocusRow {
            pendingFocusRow = nil
            if let rowCell = outer.cellForItem(at: IndexPath(item: index, section: 0)) as? FixedFocusRowCell,
               let cell = rowCell.posterCell(at: selected[rows[index].id] ?? 0) {
                return [cell]
            }
        }
        return super.preferredFocusEnvironments
    }

    override func loadView() {
        let root = UIView()
        let layout = FixedFocusRowsLayout()
        layout.focusedRow = { [weak self] in self?.focusedRow ?? 0 }
        layout.rowTop = { [weak self] in (self?.rowTop ?? FixedFocusMetrics.rowTop) + (self?.rowDrop ?? 0) }
        layout.rowDrop = { [weak self] in self?.rowDrop ?? 0 }
        layout.rigidRest = { [weak self] in self?.rigidRest }
        layout.billboardUp = { [weak self] in self?.rigidBillboardTravel == nil ? nil : self?.billboardUp(depth: $0) }
        layout.cardHeight = { [weak self] in self?.cardHeight($0) ?? FixedFocusMetrics.height }
        layout.titleExtra = { [weak self] in self?.titleExtra($0) ?? 0 }
        layout.peeks = { [weak self] in
            (self?.aboveVisible ?? FixedFocusMetrics.aboveVisible, self?.belowVisible ?? FixedFocusMetrics.belowVisible)
        }
        layout.belowCards = { [weak self] in
            // (Not a collection's: its panel is its edge — placed by that.)
            self?.isDestination($0) == true && self?.isBanner($0) == false && self?.isPanel($0) == false
                ? FixedFocusMetrics.captionRoom : 0
        }
        layout.reach = { [weak self] in
            self?.isPanel($0) == true ? FixedFocusMetrics.panelReach : (0, 0)
        }
        layout.customContent = { [weak self] in
            guard let self, let content = self.custom($0)?.contentHeight else { return nil }
            return FixedFocusMetrics.titleHeight + self.titleExtra($0) + content
        }
        layout.drawnHeight = { [weak self] in
            let usual = FixedFocusMetrics.titleHeight + FixedFocusMetrics.height
                + FixedFocusMetrics.infoGap + FixedFocusMetrics.infoHeight
            guard let self else { return usual }
            let named = FixedFocusMetrics.titleHeight + self.titleExtra($0) + self.cardHeight($0)
            // A collection: its panel is its edge.
            if self.isPanel($0) {
                let reach = FixedFocusMetrics.panelReach
                return reach.above + named + reach.below
            }
            // A custom row or a moving-focus row: its height (captions in).
            if self.custom($0) != nil || self.isDestination($0) { return named }
            // A fixed-box row: the box's info under its cards.
            return named + FixedFocusMetrics.infoGap + FixedFocusMetrics.infoHeight
        }
        layout.featuredRow = { [weak self] in
            guard let self else { return nil }
            return self.rows.firstIndex { $0.id == self.featuredRowID }
        }
        layout.belowAway = { [weak self] in self?.belowAway ?? false }
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
        place(box, FixedFocusMetrics.boxFrame)
        box.alpha = 0
        box.isUserInteractionEnabled = false
        root.addSubview(box)
        // Along the bottom edge, below the billboard's (invisible) cells.
        root.addLayoutGuide(belowGuide)
        observeHeldSteps()
        NSLayoutConstraint.activate([
            belowGuide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            belowGuide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            belowGuide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            belowGuide.heightAnchor.constraint(equalToConstant: 1),
        ])
        belowGuide.isEnabled = isFeatured(focusedRow)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Taller than the screen: rows sliding out of (or into) the screen
        // stay inside the list's visible area, so UIKit keeps their cells
        // and they SLIDE — outside it, it drops them and fades them in place.
        outer.frame = view.bounds.insetBy(dx: 0, dy: -FixedFocusRowsLayout.overscan)
        if let stage = pinnedStage {
            stage.bounds = CGRect(origin: .zero, size: StagePictureView.pictureSize)
            stage.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        }
        layoutOverlay()
        if let host = pageHeaderHost {
            host.view.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: pageHeaderHeight)
            host.view.center = CGPoint(x: view.bounds.midX, y: pageHeaderHeight / 2)
            UIView.performWithoutAnimation { applyPageHeaderPosition() }
        }
        place(box, boxFrame)
        if !boxPressed, !boxHeld {
            UIView.performWithoutAnimation { box.applyScale(FixedFocusMetrics.boxScale, base: FixedFocusMetrics.boxScale) }
        }
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
        cell.contentView.alpha = rowAlpha(indexPath.item)
        cell.concealed = rowConcealed(indexPath.item)
        cell.titleAlpha = titleAlpha(indexPath.item)
        cell.titleLift = 0
        cell.titleScale = 1
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: 1920, height: FixedFocusMetrics.titleHeight + titleExtra(indexPath.item) + cardHeight(indexPath.item))
    }

    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { false }

    /// A row coming into view mid-animation gets its dimming too.
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        cell.contentView.alpha = rowAlpha(indexPath.item)
        (cell as? FixedFocusRowCell)?.concealed = rowConcealed(indexPath.item)
        (cell as? FixedFocusRowCell)?.titleAlpha = titleAlpha(indexPath.item)
    }

    /// Focus moved (natively). Left/Right: the box stays, its content
    /// changes, the row slides behind it. Up/Down ("opening a book"): the
    /// box steps aside, the new row's title grows into the box as the rows
    /// move up; at the end the box takes over again, in the same place.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Focus into a hold menu and back: the card is still the focused one
        // (see `HoldMenu`) — nothing changes.
        if HoldMenu.shared.isOpen { return }
        if let next = context.nextFocusedView, !next.isDescendant(of: outer) {
            // (Into a hold menu: the card keeps its look.)
            if ringOnlyWithFocus, !HoldMenu.shared.isOpen { box.ringHidden = true }
            return
        }
        box.ringHidden = false
        if let button = context.nextFocusedView as? FixedFocusHeaderButton, let rowCell = button.rowCell,
           rows.indices.contains(rowCell.rowIndex) {
            onHeaderFocus(rows[rowCell.rowIndex].id, button.index)
            return
        }
        // Into a custom row's view (or within it): the row comes to the spot.
        if let next = context.nextFocusedView, let rowCell = Self.rowCell(containing: next),
           custom(rowCell.rowIndex) != nil {
            enterRow(rowCell.rowIndex)
            return
        }
        if let tile = context.nextFocusedView as? FixedFocusDestinationItem, let rowCell = tile.rowCell,
           rows.indices.contains(rowCell.rowIndex) {
            focusDestination(tile.itemIndex, in: rowCell)
            return
        }
        guard let cell = context.nextFocusedView as? FixedFocusPosterCell,
              let rowCell = cell.rowCell, rows.indices.contains(rowCell.rowIndex) else { return }
        let rowIndex = rowCell.rowIndex
        let row = rows[rowIndex]
        guard row.items.indices.contains(cell.itemIndex) else { return }
        let item = row.items[cell.itemIndex]
        let featured = isFeatured(rowIndex)
        onFocusArt(item.background ?? item.poster)
        onFocusItem(item, featured ? FixedFocusBillboardPosition(index: cell.itemIndex, count: row.items.count) : nil)
        TitlePreloader.shared.focused(rows: rows, row: rowIndex, index: cell.itemIndex)
        // The next cards' colours, ready before you get there.
        FixedFocusTint.prepare([cell.itemIndex + 1, cell.itemIndex - 1, cell.itemIndex + 2]
            .filter { row.items.indices.contains($0) }
            .compactMap { row.items[$0].background ?? row.items[$0].poster })
        onDepth(depth(of: rowIndex))
        // Back on the SAME card from outside the rows (a menu closing, down
        // from the top bar, back from a page): nothing moved — no move to
        // play (it replayed the box's slide, and the next press waited on it).
        let fromOutside = context.previouslyFocusedView.map { !$0.isDescendant(of: outer) } ?? true
        if fromOutside, hasFocus, rowIndex == focusedRow, cell.itemIndex == selected[row.id],
           box.alpha == 1 || featured {
            return
        }
        let rowChanged = rowIndex != focusedRow || !hasFocus
        // An opening into a fixed-box row: Left/Right waits for it to land.
        if rowChanged, !featured, !isDestination(rowIndex) { openingRow = rowIndex }
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
            // Commit that look NOW: the, animation below continues from what's
            // on screen (beginFromCurrentState), and without this it started
            // from the plain poster — the old box was instantly small.
            CATransaction.flush()
        }
        // Between the billboard and the rows: ONE SCROLL — the picture goes
        // up a whole screen while the rows rise from just below the screen,
        // where they wait under the billboard (no jump first).
        let billboardScroll = rowChanged && hasFocus && (featured != isFeatured(focusedRow))
        if featured {
            // The billboard's picture: the title's, drifting on Left/Right.
            rowCell.showStage(item, direction: direction, animated: !rowChanged)
        }
        if billboardScroll, !featured, rigidRest == nil { sendRowsBelowAway() }
        // Up: the rows sink a whole scroll, with the picture.
        if billboardScroll, featured, rigidRest == nil { belowAway = true }
        // A collection's panel takes the focused folder's colour.
        rowCell.tintPanel(item, animated: true)
        selected[row.id] = cell.itemIndex
        focusedRow = rowIndex
        // The row's card size (a change of row hands the box over to the
        // cells first, so it never visibly resizes).
        if rowChanged {
            UIView.performWithoutAnimation { place(box, boxFrame); box.layoutIfNeeded() }
        }

        if featured, externalBillboard, rowChanged {
            // Up into a billboard whose focus is outside (Details' buttons):
            // its cards stop taking focus now (`billboardCardsOff`), so focus
            // settles again — on the outside's own default (Play; see
            // `preferredFocusEnvironments`).
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.view.window,
                      let system = UIFocusSystem.focusSystem(for: window) else { return }
                system.requestFocusUpdate(to: window)
                system.updateFocusIfNeeded()
            }
        }
        if featured {
            // The billboard has no box (coming up from a catalog, that row's
            // cell already took over its look above and shrinks back).
            box.alpha = 0
        } else if rowChanged, !verticalDrift {
            // The opening: the grown cell shows its own content.
            box.alpha = 0
            rowCell.contentHidden = false
        } else if box.alpha < 1 {
            // Left/Right while an opening is still running: the CELLS carry
            // it — the old one shrinks, the next grows, in this step's move,
            // riding the row's rise. (The box taking over at once sat in its
            // final place, full grown, while the row still rose under it: the
            // card seemed to grow at once and slide in diagonally.) The box
            // takes over once every move has settled (see `handOverToBox`).
            rowCell.contentHidden = false
        } else {
            // The box stays; its content drifts (sideways on Left/Right, up
            // or down on Up/Down) while the row(s) move underneath.
            rowCell.contentHidden = true
            oldRowCell?.contentHidden = true
            box.show(item, animated: true, direction: direction,
                     vertical: rowChanged)
        }
        // Up/Down moves much more than a step: its own, longer spring.
        let duration = billboardScroll ? FixedFocusMotion.billboardScroll
            : rowChanged ? Motion.verticalDuration : Motion.moveDuration
        // For the cells' Up/Down details: the image drift's direction and
        // the outlines' own, gradual crossfade (see `setGrown`).
        // Down from the billboard: the rows show at once (the move is the
        // scroll, not a fade); Up hides them as they sink back.
        // (Now: focus is taken right after, and a held move runs later.)
        let hadFocus = hasFocus
        let move = {
            FixedFocusPosterCell.vertical = rowChanged && hadFocus
                ? (direction: direction, duration: duration) : nil
            defer { FixedFocusPosterCell.vertical = nil }
            FixedFocusMotion.run(duration: duration) {
                self.applyDimming()
                oldRowCell?.relayout()
                rowCell.focus(index: cell.itemIndex)
                // The row list doesn't scroll: its layout places every row
                // around the focused one, and the rows glide to their places.
                self.outer.collectionViewLayout.invalidateLayout()
                self.outer.layoutIfNeeded()
                self.applyPageHeaderPosition()
            } completion: { _ in
                if billboardScroll, featured, self.focusedRow == rowIndex {
                    // Back on the billboard: the rows (off the screen) return to
                    // wait, hidden, at the bottom edge.
                    self.belowAway = false
                    UIView.performWithoutAnimation {
                        self.applyDimming(settled: true)
                        self.outer.collectionViewLayout.invalidateLayout()
                        self.outer.layoutIfNeeded()
                    }
                }
                if self.hurriedMoves > 0 { self.hurriedMoves -= 1; return }
                self.movesInFlight -= 1
                if !rowChanged, self.movesInFlight == 0 { self.runPendingStep() }
                guard !featured, self.focusedRow == rowIndex else { return }
                self.handOverToBox(rowCell, row: row, rowIndex: rowIndex)
            }
            self.movesInFlight += 1
            if billboardScroll { self.liftNextTitle(down: !featured) }
        }
        move()
        hasFocus = true
        loadShowInfo(for: item, in: row, at: cell.itemIndex)
    }

    /// Moves (Up/Down, Left/Right) still running in the rows.
    private var movesInFlight = 0
    /// A fixed-box row opening (Up/Down into it), until the box has it.
    private var openingRow: Int?
    /// Left/Right presses held during an opening (+ right, − left).
    private var pendingSteps = 0
    private var hurried = false
    /// The opening's rest in this much time, from where it is now.
    static let hurryDuration: Double = 0.10

    /// A held press (its move failed: `shouldUpdateFocus` said no) counts
    /// once — as a step to run after the opening.
    private var heldStepToken: NSObjectProtocol?
    private func observeHeldSteps() {
        guard heldStepToken == nil else { return }
        heldStepToken = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            else { return }
            MainActor.assumeIsolated {
                guard let self, let opening = self.openingRow,
                      let from = ctx.previouslyFocusedItem as? FixedFocusPosterCell,
                      from.rowCell?.rowIndex == opening, from.isDescendant(of: self.outer) else { return }
                if ctx.focusHeading.contains(.left) { self.pendingSteps -= 1 }
                if ctx.focusHeading.contains(.right) { self.pendingSteps += 1 }
                self.hurryOpening(opening)
            }
        }
    }

    /// Finish the running opening quickly, from where it is (once per
    /// opening): every animation running in the rows is replaced by a short
    /// one from what's on screen to its end (re-animating to the same target
    /// doesn't retarget a spring), and the opening counts as done at once.
    private func hurryOpening(_ rowIndex: Int) {
        guard !hurried, openingRow == rowIndex,
              let rowCell = outer.cellForItem(at: IndexPath(item: rowIndex, section: 0)) as? FixedFocusRowCell
        else { return }
        hurried = true
        let duration = Self.hurryDuration
        let ease = CAMediaTimingFunction(name: .easeOut)
        func hurry(_ layer: CALayer) {
            if let keys = layer.animationKeys(), !keys.isEmpty, let shown = layer.presentation() {
                let now: [(String, Any?)] = [
                    ("position", NSValue(cgPoint: shown.position)),
                    ("bounds", NSValue(cgRect: shown.bounds)),
                    ("transform", NSValue(caTransform3D: shown.transform)),
                    ("opacity", shown.opacity),
                ]
                layer.removeAllAnimations()
                for (key, from) in now {
                    let to = layer.value(forKeyPath: key)
                    guard let from, let to, !(from as AnyObject).isEqual(to) else { continue }
                    let move = CABasicAnimation(keyPath: key)
                    move.fromValue = from
                    move.toValue = to
                    move.duration = duration
                    move.timingFunction = ease
                    layer.add(move, forKey: "hurry.\(key)")
                }
            }
            layer.sublayers?.forEach(hurry)
        }
        // The opening's own completion is void now (`hurriedMoves`) — set
        // first: removing its animations calls it.
        hurriedMoves = movesInFlight
        movesInFlight = 0
        hurry(view.layer)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard self.focusedRow == rowIndex, self.openingRow == rowIndex else { return }
            self.handOverToBox(rowCell, row: self.rows[rowIndex], rowIndex: rowIndex)
        }
    }
    /// Completions of moves cut short by a hurry, still to come (ignored).
    private var hurriedMoves = 0

    /// One held Left/Right, as a normal step (the box has the row now).
    private func runPendingStep() {
        guard openingRow == nil, movesInFlight == 0, pendingSteps != 0,
              rows.indices.contains(focusedRow),
              let rowCell = outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell
        else { return }
        let step = pendingSteps > 0 ? 1 : -1
        pendingSteps -= step
        let target = (selected[rows[focusedRow].id] ?? 0) + step
        guard rows[focusedRow].items.indices.contains(target), let cell = rowCell.posterCell(at: target),
              let system = UIFocusSystem.focusSystem(for: view) else { pendingSteps = 0; return }
        // (Through this controller's preferred focus: a request straight to
        // a card in a strip is ignored.)
        pendingFocusCell = cell
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
    }
    private var pendingFocusCell: UIView?

    /// After an opening, once NOTHING moves any more (a Left/Right during it
    /// keeps the cells carrying it): the box takes over — identical look,
    /// same place, no jump — on the title focused now.
    private func handOverToBox(_ rowCell: FixedFocusRowCell, row: HomeRow, rowIndex: Int) {
        guard movesInFlight == 0 else { return }
        if box.alpha < 1, let current = selected[row.id], row.items.indices.contains(current) {
            let now = row.items[current]
            box.show(now, animated: false)
            box.alpha = 1
            rowCell.contentHidden = true
        }
        openingRow = nil
        hurried = false
        // Held presses: now, one step at a time.
        DispatchQueue.main.async { self.runPendingStep() }
    }

    /// Focus in a destination row: the system scrolls it and lifts the card;
    /// here only the rest — the background and panel colour, and on arriving
    /// from another row, the rows moving so this one is at the spot (the box
    /// steps aside: it's not used here).
    private func focusDestination(_ index: Int, in rowCell: FixedFocusRowCell) {
        let rowIndex = rowCell.rowIndex
        let row = rows[rowIndex]
        guard row.items.indices.contains(index) else { return }
        let item = row.items[index]
        // (As the card shows it: landscape the backdrop, a poster card its poster.)
        let card = destinationCard(rowIndex)
        onFocusArt(card.width > card.height ? item.background ?? item.poster : item.poster ?? item.background)
        onFocusItem(item, nil)
        TitlePreloader.shared.focused(rows: rows, row: rowIndex, index: index)
        FixedFocusTint.prepare([index + 1, index - 1, index + 2]
            .filter { row.items.indices.contains($0) }
            .compactMap { card.width > card.height ? row.items[$0].background ?? row.items[$0].poster
                : row.items[$0].poster ?? row.items[$0].background })
        onDepth(depth(of: rowIndex))
        rowCell.tintPanel(item, animated: true)
        selected[row.id] = index
        enterRow(rowIndex)
    }

    /// The row a view is in (nil: none).
    private static func rowCell(containing view: UIView) -> FixedFocusRowCell? {
        var current: UIView? = view
        while let v = current {
            if let cell = v as? FixedFocusRowCell { return cell }
            current = v.superview
        }
        return nil
    }

    /// Focus came into a row that moves the rows itself (moving focus, a
    /// custom row): from another row, the rows move so it's at the spot.
    private func enterRow(_ rowIndex: Int) {
        if custom(rowIndex) != nil { onDepth(depth(of: rowIndex)) }
        let rowChanged = rowIndex != focusedRow || !hasFocus
        let fromBillboard = rowChanged && hasFocus && isFeatured(focusedRow)
        hasFocus = true
        guard rowChanged else { return }
        let oldRowCell = outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell
        if box.alpha == 1 {
            // The old row's grown cell takes the box's look, then shrinks.
            oldRowCell?.contentHidden = false
            CATransaction.flush()
        }
        box.alpha = 0
        if fromBillboard, rigidRest == nil { sendRowsBelowAway() }
        focusedRow = rowIndex
        let duration = fromBillboard ? FixedFocusMotion.billboardScroll : Motion.verticalDuration
        let move = {
            FixedFocusMotion.run(duration: duration) {
                self.applyDimming()
                oldRowCell?.relayout()
                self.outer.collectionViewLayout.invalidateLayout()
                self.outer.layoutIfNeeded()
                self.applyPageHeaderPosition()
            } completion: { _ in }
            if fromBillboard { self.liftNextTitle(down: true) }
        }
        move()
    }


    /// The season count for the title you rest on (and the next two, so
    /// stepping right finds them ready) — then the box's text takes it.
    private var infoLoading: Task<Void, Never>?

    private func loadShowInfo(for item: MetaItem, in row: HomeRow, at index: Int) {
        infoLoading?.cancel()
        infoLoading = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if FixedFocusShowInfo.known(item) == nil, await FixedFocusShowInfo.load(item) != nil,
               !Task.isCancelled {
                self?.box.refreshInfo(for: item)
            }
            for next in row.items.dropFirst(index + 1).prefix(2) {
                guard !Task.isCancelled else { return }
                _ = await FixedFocusShowInfo.load(next)
            }
        }
    }

    var onSelectFeatured: (MetaItem) -> Void = { _ in }

    var onOpenDetails: ((MetaItem) -> Void)?
    var onContinueMenu: ((ContinueMenuAction, WatchProgress) -> Void)?
    var titleMenu: ((MetaItem, String) -> [MenuEntry])?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HoldMenu.shared.install()
    }

    private func menuEntries(rowIndex: Int, itemIndex: Int) -> (String, [MenuEntry])? {
        guard rows.indices.contains(rowIndex), rows[rowIndex].items.indices.contains(itemIndex) else { return nil }
        let row = rows[rowIndex]
        let item = row.items[itemIndex]
        if isContinue(rowIndex) {
            guard let onContinueMenu, let entry = progress[item.id] else { return nil }
            return (entry.name, ContinueMenuAction.allCases.map { action in
                MenuEntry(title: action.title, icon: action.icon, destructive: action == .remove) {
                    onContinueMenu(action, entry)
                }
            })
        }
        // Not the billboards (Home's, Search's Top Result) or folders.
        guard let titleMenu, !isFeatured(rowIndex), !isBanner(rowIndex), !isPanel(rowIndex),
              item.type != "collection" else { return nil }
        return (item.name, titleMenu(item, row.id))
    }

    /// What the context menu lifts: a COPY of the fixed box (it covers the
    /// cell), in the box's place. Handed the box itself, the system takes it
    /// off the screen while the menu is up — its info under it too — and
    /// only puts it back once its closing animation has fully run.
    private var boxPressed = false

    /// The box's place, by bounds and centre: a frame set while it is scaled
    /// (pressed) silently enlarged it — it grew after the press.
    private func place(_ view: UIView, _ rect: CGRect) {
        view.bounds = CGRect(origin: .zero, size: rect.size)
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Select pressed or held on a fixed row's card: the box sinks a little
    /// (as Apple TV's cards do), back on release or when the menu closes.
    func setBoxPressed(_ pressed: Bool) {
        // One state, one move: repeats (began twice, end after cancel) change nothing.
        guard pressed != boxPressed else { return }
        boxPressed = pressed
        applyBoxScale(duration: pressed ? 0.12 : 0.2)
    }

    /// The box's hold menu open (see `HoldMenuRequest.onHeld`): 102 %.
    private func setBoxHeld(_ held: Bool) {
        guard held != boxHeld else { return }
        boxHeld = held
        applyBoxScale(duration: 0.28)
    }
    private var boxHeld = false

    /// 97 % pressed, 102 % with its menu open, else 100 %. Smaller, the card
    /// under it is out of sight (its edges showed around the box).
    private func applyBoxScale(duration: Double) {
        let base = FixedFocusMetrics.boxScale
        let scale = boxHeld ? base + FixedFocusMetrics.heldGrowth
            : boxPressed ? base - (1 - FixedFocusMetrics.pressScale) : base
        let covered = currentCard(row: focusedRow).first as? FixedFocusPosterCell
        // (Below its own size the card under it — as large — shows.)
        if scale < base { covered?.setUnderPressedBox(true) }
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.box.applyScale(scale, base: base)
        } completion: { _ in
            if !self.boxPressed { covered?.setUnderPressedBox(false) }
        }
    }

    /// Gives SwiftUI hosted in a cell the app's stores.
    var environment: (AnyView) -> AnyView = { $0 }

    /// Where a row's first card sits on the screen (window points) while the
    /// row is at the spot.
    func restingCardOrigin(_ rowIndex: Int) -> CGPoint? {
        guard isViewLoaded, view.window != nil else { return nil }
        let anchor = isPanel(rowIndex) ? FixedFocusMetrics.panelReach.above : 0
        return view.convert(CGPoint(x: FixedFocusMetrics.inset,
                                    y: rowTop + (rowIndex == focusedRow ? rowDrop : 0) + anchor
                                        + FixedFocusMetrics.titleHeight), to: nil)
    }

    /// Handing over to Details: Home holds still; a Down waits for Details.
    var upExitRowIDs: Set<String> = []
    var onUpExit: (String) -> Void = { _ in }
    var hiddenTitleRowIDs: Set<String> = [] {
        didSet { if hiddenTitleRowIDs != oldValue, isViewLoaded { applyDimming() } }
    }
    private var lastCommand: UUID?

    /// See `FixedFocusRows.rigidRest` — or, peeking (`rigidPeek`), where
    /// the next row rests so its cards' top is the peek up the bottom edge.
    var rigidRest: CGFloat? {
        get {
            guard let rest = rigidRestSetting else { return nil }
            guard let peek = rigidPeek, let featured = featuredIndex, rows.indices.contains(featured + 1)
            else { return rest }
            return 1080 - peek - FixedFocusMetrics.titleHeight - titleExtra(featured + 1)
        }
        set { rigidRestSetting = newValue }
    }
    private var rigidRestSetting: CGFloat?
    var rigidPeek: CGFloat?
    var rigidPeekShowsName = false
    var rigidNameY: CGFloat?
    var hidesBillboardPicture = false
    /// The line under the name (gap, map) — the cards that much lower.
    static let titleAccessoryHeight: CGFloat = 40
    /// Under a header: the accessory's line, with the same gap above it
    /// (to the buttons) as below it (to the cards).
    static let headerAccessoryGap: CGFloat = 28
    static let headerAccessoryHeight: CGFloat = 26

    var rowTitleAccessories: [String: AnyView] = [:] {
        didSet {
            guard isViewLoaded else { return }
            // (A row gaining / losing one changes its height.)
            if Set(rowTitleAccessories.keys) != Set(oldValue.keys) {
                outer.collectionViewLayout.invalidateLayout()
            }
            for case let cell as FixedFocusRowCell in outer.visibleCells { cell.showAccessory() }
        }
    }


    var rowHeaders: [String: FixedFocusRowHeader] = [:] {
        didSet {
            guard rowHeaders != oldValue, isViewLoaded else { return }
            // (A row gaining / losing one changes its height.)
            if Set(rowHeaders.keys) != Set(oldValue.keys) {
                outer.collectionViewLayout.invalidateLayout()
            }
            for case let cell as FixedFocusRowCell in outer.visibleCells { cell.showHeader() }
        }
    }
    var onHeaderFocus: (String, Int) -> Void = { _, _ in }

    /// How much lower than usual a row's cards are under its name: the
    /// header's buttons and their gap take more room than a name; the line
    /// under the name (or the header).
    func titleExtra(_ rowIndex: Int) -> CGFloat {
        guard rows.indices.contains(rowIndex) else { return 0 }
        let id = rows[rowIndex].id
        let accessory = rowTitleAccessories[id] != nil
        guard rowHeaders[id] != nil else { return accessory ? Self.titleAccessoryHeight : 0 }
        let below = accessory ? 2 * Self.headerAccessoryGap + Self.headerAccessoryHeight
            : FixedFocusHeaderButton.gapBelow
        return FixedFocusHeaderButton.height + below - FixedFocusMetrics.titleHeight
    }


    /// The billboard's overlay (see `FixedFocusRows.billboardOverlay`).
    private var overlayHost: UIHostingController<AnyView>?
    var billboardOverlayHeight: CGFloat = 1080
    var billboardOverlayBelowRows = false
    var rigidBillboardTravel: CGFloat?
    var anchoredRowIDs: Set<String> = []
    var customRows: [String: FixedFocusCustomRow] = [:] {
        didSet {
            guard isViewLoaded else { return }
            for case let cell as FixedFocusRowCell in outer.visibleCells { cell.showCustom() }
            // (A content height measured: where the rows rest may change.)
            if customRows.mapValues(\.contentHeight) != oldValue.mapValues(\.contentHeight) {
                outer.collectionViewLayout.invalidateLayout()
            }
        }
    }

    var logoRowIDs: Set<String> = []
    func isLogo(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && logoRowIDs.contains(rows[rowIndex].id)
    }

    func custom(_ rowIndex: Int) -> FixedFocusCustomRow? {
        rows.indices.contains(rowIndex) ? customRows[rows[rowIndex].id] : nil
    }

    /// How far the billboard is up with focus `depth` rows below it.
    func billboardUp(depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        if let travel = rigidBillboardTravel { return travel + CGFloat(depth - 1) * FixedFocusMetrics.rowPitch }
        return rigidRest.map {
            FixedFocusRowsLayout.billboardScroll(depth: depth, rigidRest: $0, rowTop: rowTop + rowDrop)
        } ?? FixedFocusRowsLayout.billboardScroll(depth: depth)
    }

    var pinnedBillboardPicture = false {
        didSet {
            guard pinnedBillboardPicture != oldValue else { return }
            if pinnedBillboardPicture { loadViewIfNeeded(); makePinnedStage() } else {
                pinnedStage?.removeFromSuperview()
                pinnedStage = nil
            }
            if isViewLoaded { outer.reloadData() }
        }
    }
    /// The pinned billboard picture (see `FixedFocusRows.pinnedBillboardPicture`).
    private(set) var pinnedStage: StagePictureView?

    private func makePinnedStage() {
        guard pinnedStage == nil else { return }
        let stage = StagePictureView()
        stage.blursBelow = rigidBillboardTravel == nil
        view.insertSubview(stage, at: 0)
        stage.bounds = CGRect(origin: .zero, size: StagePictureView.pictureSize)
        stage.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        pinnedStage = stage
    }

    /// The pinned picture at a depth: blurred and darker below the
    /// billboard (in the move's animation), and — once the rows are up — out,
    /// to the background's colours; back at once on the way up.
    private func applyPinnedStage(depth: Int) {
        guard let stage = pinnedStage else { return }
        // Home: the picture travels the billboard's own distance (its hard
        // edge ends at the top bar's middle) — under the text, which is
        // under the rows.
        if rigidBillboardTravel != nil {
            stage.transform = CGAffineTransform(translationX: 0, y: -billboardUp(depth: depth))
            return
        }
        stage.setBelow(depth > 0)
        let alpha: CGFloat = depth > 0 ? 0 : 1
        guard stage.alpha != alpha else { return }
        let move = FixedFocusMotion.billboardScroll
        UIView.animate(withDuration: depth > 0 ? move * 0.8 : move * 0.4,
                       delay: depth > 0 ? move * 0.3 : 0,
                       options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
            stage.alpha = alpha
        }
    }

    // MARK: Page header (a folder page)

    /// Above the first row, from the screen's top, this tall: moves with the
    /// first row, in the rows' own animation (a SwiftUI layer outside would
    /// move on the main thread, behind them — or only fade).
    private var pageHeaderHost: UIHostingController<AnyView>?
    private var pageHeaderHeight: CGFloat = 0
    /// The first row's top with it in focus: the header's rest.
    private var pageHeaderRest: CGFloat?

    func setPageHeader(_ content: AnyView?, height: CGFloat) {
        pageHeaderHeight = height
        guard let content else {
            pageHeaderHost?.willMove(toParent: nil)
            pageHeaderHost?.view.removeFromSuperview()
            pageHeaderHost?.removeFromParent()
            pageHeaderHost = nil
            return
        }
        if let pageHeaderHost {
            pageHeaderHost.rootView = environment(content)
            return
        }
        loadViewIfNeeded()
        let host = UIHostingController(rootView: environment(content))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.isUserInteractionEnabled = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        pageHeaderHost = host
        view.setNeedsLayout()
    }

    /// The header as far up as the first row has gone.
    private func applyPageHeaderPosition() {
        guard let host = pageHeaderHost,
              let top = outer.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY else { return }
        if focusedRow == 0 { pageHeaderRest = top }
        guard let rest = pageHeaderRest else { return }
        host.view.transform = CGAffineTransform(translationX: 0, y: top - rest)
    }

    func setBillboardOverlay(_ content: AnyView?) {
        guard content != nil || overlayHost != nil else { return }
        // (In from the first frame: Details takes over from Home's billboard
        // looking exactly like it.)
        loadViewIfNeeded()
        guard let content else {
            overlayHost?.willMove(toParent: nil)
            overlayHost?.view.removeFromSuperview()
            overlayHost?.removeFromParent()
            overlayHost = nil
            return
        }
        if let overlayHost {
            overlayHost.rootView = environment(content)
            return
        }
        let host = UIHostingController(rootView: environment(content))
        host.view.backgroundColor = .clear
        // (Its own safe area off: it's laid out in screen points, as the rows.)
        host.safeAreaRegions = []
        // Details' info block: hidden until it rises in (`DetailTransition`).
        DetailTransition.shared.textHostCreated(host.view)
        addChild(host)
        // Over the rows (their names on the billboard stay under the text) —
        // or under them (see `billboardOverlayBelowRows`).
        if billboardOverlayBelowRows {
            view.insertSubview(host.view, belowSubview: outer)
            host.view.isUserInteractionEnabled = false
        } else {
            view.addSubview(host.view)
        }
        host.didMove(toParent: self)
        overlayHost = host
        layoutOverlay()
        UIView.performWithoutAnimation { applyOverlayPosition() }
    }

    /// From the top of the screen, its height; moved by a transform (see
    /// `applyOverlayPosition`).
    private func layoutOverlay() {
        let height = min(billboardOverlayHeight, view.bounds.height)
        if let host = overlayHost {
            host.view.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
            host.view.center = CGPoint(x: view.bounds.midX, y: height / 2)
        }
    }

    /// The overlay where the billboard is: scrolled up with it, and above
    /// the rows dimmed like the row above. Inside a move: on its animation.
    private func applyOverlayPosition() {
        guard let featured = featuredIndex else { return }
        let depth = max(focusedRow - featured, 0)
        applyPinnedStage(depth: depth)
        let scroll = billboardUp(depth: depth)
        if let host = overlayHost {
            host.view.transform = CGAffineTransform(translationX: 0, y: -scroll)
            host.view.alpha = depth == 0 ? 1 : FixedFocusMetrics.dimmedAlpha
        }
    }

    /// The row under a rigid billboard whose name has come in.
    private var revealedNextRowID: String?

    /// A rigid billboard's next row arriving (Details: its episodes land a
    /// beat after the swap): its name on the billboard comes down into place
    /// (`ModeSwap.lift`) on the swap's arriving curve — not a pop.
    private func revealNextNameIfNew() {
        guard rigidRest != nil, isFeatured(focusedRow), let featured = featuredIndex,
              rows.indices.contains(featured + 1), rows[featured + 1].id != revealedNextRowID else { return }
        revealedNextRowID = rows[featured + 1].id
        outer.layoutIfNeeded()
        nextRowCell?.revealTitle()
    }

    func header(_ rowIndex: Int) -> FixedFocusRowHeader? {
        rows.indices.contains(rowIndex) ? rowHeaders[rows[rowIndex].id] : nil
    }

    /// A row's header shows (and takes focus) while its row has focus.
    /// Never from the billboard: Down lands on the cards.
    func headerShown(_ rowIndex: Int) -> Bool {
        header(rowIndex) != nil && rowIndex == focusedRow && hasFocus
    }

    func run(_ command: FixedFocusRowsCommand) {
        guard command.id != lastCommand, isViewLoaded else { return }
        lastCommand = command.id
        switch command.action {
        case let .aim(rowID, index):
            guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }),
                  rows[rowIndex].items.indices.contains(index) else { return }
            selected[rowID] = index
            (outer.cellForItem(at: IndexPath(item: rowIndex, section: 0)) as? FixedFocusRowCell)?.aim(index)
        case let .focusRow(rowID):
            guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }) else { return }
            requestFocus(row: rowIndex)
        case .focusBillboard:
            guard let featured = featuredIndex else { return }
            requestFocus(row: featured)
        case let .select(rowID, index):
            guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }),
                  rows[rowIndex].items.indices.contains(index), focusedRow == rowIndex,
                  let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
                  focused.isDescendant(of: outer), !HoldMenu.shared.isOpen else { return }
            selected[rowID] = index
            let cell = outer.cellForItem(at: IndexPath(item: rowIndex, section: 0)) as? FixedFocusRowCell
            if cell?.isDestination == true { cell?.aim(index) } else { cell?.jump(to: index) }
            DispatchQueue.main.async { self.requestFocus(row: rowIndex) }


        }
    }

    /// Focus to one view in the rows, through this controller's preferred
    /// focus (a request straight to it is ignored).
    private func requestFocus(view target: UIView) {
        guard let system = UIFocusSystem.focusSystem(for: view) else { return }
        pendingFocusCell = target
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
    }

    /// Focus to a row's current card, from wherever focus is now.
    private func requestFocus(row: Int) {
        pendingFocusRow = row
        if let system = UIFocusSystem.focusSystem(for: view) {
            system.requestFocusUpdate(to: self)
            system.updateFocusIfNeeded()
        }
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // (The rows, not this view: the billboard's overlay is in it too.)
        let previousInside = context.previouslyFocusedView?.isDescendant(of: outer) == true
        // Down from the billboard's own focus (Details' buttons) that doesn't
        // reach the rows — the first row's current card isn't under the
        // button (an episode further along) and the search settled back on
        // the button: to that card.
        if context.focusHeading.contains(.down), billboardFocusOutside, !previousInside,
           (context.nextFocusedView?.isDescendant(of: outer) ?? false) == false,
           let featured = featuredIndex, rows.indices.contains(featured + 1) {
            DispatchQueue.main.async { self.requestFocus(row: featured + 1) }
            return false
        }
        // Up from a row with a header: its selected button (the engine kept
        // the move in the row's focus group — another of its cards).
        if context.focusHeading.contains(.up), previousInside,
           let from = context.previouslyFocusedView, !(from is FixedFocusHeaderButton),
           let rowCell = (from as? FixedFocusDestinationItem)?.rowCell ?? (from as? FixedFocusPosterCell)?.rowCell,
           let target = rowCell.headerFocusTarget, context.nextFocusedView !== target {
            DispatchQueue.main.async { self.requestFocus(view: target) }
            return false
        }
        // A header (Details' seasons): along it natively; Up goes to the
        // billboard, Down to the row's card.
        if let button = context.previouslyFocusedView as? FixedFocusHeaderButton,
           let rowCell = button.rowCell, rows.indices.contains(rowCell.rowIndex),
           !(context.nextFocusedView is FixedFocusHeaderButton) {
            if context.focusHeading.contains(.up), let featured = featuredIndex, rowCell.rowIndex == featured + 1 {
                DispatchQueue.main.async { self.requestFocus(row: featured) }
                return false
            }
            if context.focusHeading.contains(.down) {
                let row = rowCell.rowIndex
                DispatchQueue.main.async { self.requestFocus(row: row) }
                return false
            }
        }
        // Up out of a row with its own way out (Details' episodes → seasons).
        if context.focusHeading.contains(.up), previousInside,
           let from = context.previouslyFocusedView as? FixedFocusDestinationItem, let fromRow = from.rowCell,
           rows.indices.contains(fromRow.rowIndex), upExitRowIDs.contains(rows[fromRow.rowIndex].id),
           (context.nextFocusedView as? FixedFocusDestinationItem)?.rowCell !== fromRow {
            let id = rows[fromRow.rowIndex].id
            DispatchQueue.main.async { self.onUpExit(id) }
            return false
        }
        // LEFT/RIGHT DURING AN OPENING: held — first land, then step. The
        // opening is hurried to its end (`hurryOpening`); the press runs as
        // a normal step after it (`runPendingStep`). The card beside never
        // takes focus mid-move (it grew in both ways while still moving).
        if let opening = openingRow, previousInside,
           context.focusHeading.contains(.left) || context.focusHeading.contains(.right),
           let from = context.previouslyFocusedView as? FixedFocusPosterCell, from.rowCell?.rowIndex == opening {
            // (Counted once per press, when the move fails — see
            // `observeHeldSteps`: tvOS asks this several times per press.)
            DispatchQueue.main.async { self.hurryOpening(opening) }
            return false
        }
        // Into a moving-focus row from outside: its CURRENT card, not the
        // one nearest by position (it may be aimed — Details' episodes).
        if !previousInside, !ModeSwap.shared.handingOver,
           let to = context.nextFocusedView as? FixedFocusDestinationItem, let toRow = to.rowCell,
           rows.indices.contains(toRow.rowIndex),
           let current = selected[rows[toRow.rowIndex].id], current != to.itemIndex {
            let rowIndex = toRow.rowIndex
            DispatchQueue.main.async { self.requestFocus(row: rowIndex) }
            return false
        }
        guard ModeSwap.shared.handingOver else { return super.shouldUpdateFocus(in: context) }
        if context.focusHeading.contains(.down) { ModeSwap.shared.heldPress = .down }
        return false
    }

    func select(_ item: MetaItem, rowIndex: Int) {
        if let onSelectInRow, rows.indices.contains(rowIndex), onSelectInRow(item, rows[rowIndex].id) { return }
        // Handing over to Details: this Select is Play there.
        if ModeSwap.shared.handingOver {
            ModeSwap.shared.heldPress = .play
            return
        }
        if !isFeatured(rowIndex), !isContinue(rowIndex), item.type != "collection", let onOpenDetails {
            onOpenDetails(item)
        } else if isFeatured(rowIndex) {
            onSelectFeatured(item)
        } else if isContinue(rowIndex), let entry = progress[item.id] {
            onResume(entry)
        } else {
            onSelect(item)
        }
    }

    /// The focused row full, every other row dimmed. `settled`: a move to
    /// the billboard has ended (rigid: only now the rows below hide).
    private func applyDimming(settled: Bool = false) {
        applyOverlayPosition()
        for case let cell as FixedFocusRowCell in outer.visibleCells {
            cell.contentView.alpha = rowAlpha(cell.rowIndex)
            cell.applyCaptions()
            cell.applyCardDim()
            // (Rigid: by a line fixed on the screen, moved in the scroll —
            // see `concealTravel`.)
            if let rest = rigidRest {
                let travel = FixedFocusRowsLayout.billboardScroll(depth: 1, rigidRest: rest, rowTop: rowTop)
                if cell.concealTravel != travel { UIView.performWithoutAnimation { cell.concealTravel = travel } }
            }
            cell.concealed = rowConcealed(cell.rowIndex)
            cell.titleAlpha = titleAlpha(cell.rowIndex)
            // (Never animated here: Down/Up give it its own move.)
            UIView.performWithoutAnimation { cell.titleLift = 0; cell.titleScale = 1 }
            cell.applyAccessory()
            cell.applyHeader()
        }
    }

    /// Under the billboard the rows wait at the bottom edge, hidden (see
    /// `rowConcealed`), at full brightness: the scroll is a move, not a fade.
    private func rowAlpha(_ rowIndex: Int) -> CGFloat {
        // (A custom row — Details' About, the page's end — is never dimmed.)
        if custom(rowIndex) != nil { return 1 }
        // (The billboard's picture is never dimmed: it scrolls away whole.)
        // (Under the billboard the rows are full: the scroll is a move.)
        if isFeatured(focusedRow) {
            // Rigid: the row waiting under it is a row out of focus — the
            // peeking one (`rigidPeek`) only lightly dimmed: its cards
            // darkened, the row itself opaque (`cardDim`); other kinds of
            // rows through their brightness.
            if rigidPeek != nil, isNext(rowIndex) { return cardsDarkened(rowIndex) ? 1 : Self.peekAlpha }
            return rigidRest != nil && !isFeatured(rowIndex) ? FixedFocusMetrics.dimmedAlpha : 1
        }
        return rowIndex == focusedRow || isFeatured(rowIndex) ? 1 : FixedFocusMetrics.dimmedAlpha
    }

    /// Waiting under the billboard (at the bottom edge) the rows are hidden:
    /// their names and their cards' contents — the cards stay on the screen,
    /// so tvOS can focus them. (Not through the row's own alpha: the focus
    /// engine skips everything inside a fully transparent view.) Away (off
    /// the screen, scrolling) they show.
    private func rowConcealed(_ rowIndex: Int) -> Bool {
        // (Peeking: the next row's cards show.)
        isFeatured(focusedRow) && !isFeatured(rowIndex) && !belowAway && !(rigidPeek != nil && isNext(rowIndex))
    }

    /// THE NEXT ROW'S NAME ON THE BILLBOARD is that row's own name, lifted
    /// above its (hidden) cards — `titleLift` — up to its spot on the
    /// billboard (bottom left, in line with the dots), dimmed like a row
    /// out of focus. The other waiting rows' names are hidden; that one too
    /// while the billboard steps into Details.
    private func titleAlpha(_ rowIndex: Int) -> CGFloat {
        if rows.indices.contains(rowIndex), hiddenTitleRowIDs.contains(rows[rowIndex].id) { return 0 }
        guard isFeatured(focusedRow) else { return 1 }
        // (Rigid: the row's own brightness dims it. Peeking: no name.)
        if isNext(rowIndex) {
            if rigidPeek != nil { return rigidPeekShowsName && cardsDarkened(rowIndex) ? Self.peekAlpha : 0 }
            return rigidRest != nil ? 1 : FixedFocusMetrics.dimmedAlpha
        }
        return belowAway ? 1 : 0
    }

    /// A header row's name, going up with the billboard (`liftNextTitle`):
    /// smaller.
    static let nextNameScale: CGFloat = 0.75
    /// The peeking row's brightness under the billboard (see `rigidPeek`).
    static let peekAlpha: CGFloat = 0.45

    /// How dark a row's cards are drawn (0: as they are) — the peeking
    /// row's: darkened, not see-through (the billboard's picture behind).
    func cardDim(_ rowIndex: Int) -> CGFloat {
        rigidPeek != nil && isFeatured(focusedRow) && isNext(rowIndex) && cardsDarkened(rowIndex)
            ? 1 - Self.peekAlpha : 0
    }

    /// Rows whose cards can be darkened one by one (posters, moving-focus
    /// cards) — a collection's panel or a banner dims as a whole.
    private func cardsDarkened(_ rowIndex: Int) -> Bool { !isPanel(rowIndex) && !isBanner(rowIndex) }
    /// A header row's name (Details' "Episodes") stays at least this far
    /// below the billboard's buttons while they're on the screen.
    static let nameButtonsMargin: CGFloat = 32

    private func isNext(_ rowIndex: Int) -> Bool {
        featuredIndex.map { rowIndex == $0 + 1 } ?? false
    }

    private var nextRowCell: FixedFocusRowCell? {
        featuredIndex.flatMap { outer.cellForItem(at: IndexPath(item: $0 + 1, section: 0)) as? FixedFocusRowCell }
    }

    /// Down / Up between the billboard and the rows — right after the rows'
    /// move was set off: a header row's name and header (Details' seasons)
    /// on the row's own move. (Other rows' names come with their row.)
    private func liftNextTitle(down: Bool) {
        guard let cell = nextRowCell else { return }
        let end = cell.convert(CGPoint.zero, to: view).y
        let start = end + (cell.layer.presentation()?.frame.minY ?? cell.frame.minY) - cell.frame.minY
        let distance = end - start
        guard abs(distance) > 1 else { return }
        let rowMove = cell.layer.animationKeys()?
            .compactMap { cell.layer.animation(forKey: $0) as? CABasicAnimation }
            .first { $0.keyPath == "position" }
        let timing = rowMove?.timingFunction ?? CAMediaTimingFunction(name: .easeInEaseOut)
        let duration = rowMove?.duration ?? FixedFocusMotion.billboardScroll
        let spot = rigidRest != nil ? rigidNameY ?? FixedFocusRowsLayout.nextNameY : FixedFocusRowsLayout.nextNameY
        guard header(cell.rowIndex) != nil else { return }
        // A row with a header (Details' seasons): its name goes up from its
        // spot on the billboard and out past the screen's top (Down) / comes
        // back down from there (Up) — no fade, its brightness kept against
        // the row's own brightening (the row is dimmed on the billboard).
        // It follows the billboard's buttons, never touching them: the gap
        // to them closes only as they leave the screen. The header (with
        // the line under it) comes up with the row, fading in / goes down
        // with it, fading out.
        let away = -FixedFocusMetrics.titleLine - 20
        let travel = billboardUp(depth: 1)
        // The buttons' lower edge (focused, a little grown) at rest.
        let buttons = FixedFocusBillboardText.buttonsY + TitleBlock.buttonHeight + Self.nameButtonsMargin
        let gap = spot - buttons
        // Past the buttons' own end, if that isn't out of the screen yet.
        let extra = max(buttons - travel - away, 0)
        // Along the move's progress p: the name's place on screen, the
        // row's brightness; lift = the row's place minus the name's.
        func name(_ p: CGFloat) -> CGFloat {
            let up = down ? p : 1 - p   // how far the billboard is up
            return buttons - travel * up + gap * (1 - up) * (1 - up) - extra * up * up
        }
        let spring = rowMove as? CASpringAnimation
        let progress = spring.map { Self.springProgress($0) }
        let samples = progress?.values ?? (0...40).map { CGFloat($0) / 40 }
        cell.moveHeader(fade: samples.map { down ? $0 : 1 - $0 },
                        lift: samples.map { start + (end - start) * $0 - name($0) },
                        titleOpacity: samples.map { _ in 0 },
                        scale: Self.nextNameScale,
                        timing: spring == nil ? timing : nil,
                        duration: progress?.duration ?? duration, entering: down)
    }

    /// A spring's progress (0…1, overshoot included) at even steps across
    /// its settling time — as Core Animation runs it (mass, stiffness,
    /// damping, from rest).
    private static func springProgress(_ spring: CASpringAnimation, steps: Int = 90)
        -> (values: [CGFloat], duration: Double, map: ((CGFloat) -> CGFloat) -> [CGFloat]) {
        let duration = spring.settlingDuration
        let m = Double(spring.mass), k = Double(spring.stiffness), c = Double(spring.damping)
        var x = 0.0, v = Double(spring.initialVelocity)
        let substeps = 8, dt = duration / Double(steps * substeps)
        var values: [CGFloat] = [0]
        for _ in 0..<steps {
            for _ in 0..<substeps {
                // Toward 1: semi-implicit Euler.
                v += (-k * (x - 1) - c * v) / m * dt
                x += v * dt
            }
            values.append(CGFloat(x))
        }
        values[values.count - 1] = 1
        return (values, duration, { f in values.map(f) })
    }

    /// Scrolling to or from the rows (see `FixedFocusRowsLayout.belowAway`).
    private var belowAway = false

    /// Down from the billboard: the waiting rows first go — unseen, off the
    /// screen — a whole scroll below their places and show; then they rise
    /// with the picture, the same distance: one page, a constant gap.
    private func sendRowsBelowAway() {
        belowAway = true
        UIView.performWithoutAnimation {
            applyDimming()
            outer.collectionViewLayout.invalidateLayout()
            outer.layoutIfNeeded()
            // The next row's name stays at its spot on the billboard.
            if let cell = nextRowCell {
                cell.titleLift = cell.convert(CGPoint.zero, to: view).y - FixedFocusRowsLayout.nextNameY
            }
        }
        // (Committed now: the move starts from there, not from the edge.)
        CATransaction.flush()
    }

    /// Down from the billboard: the rows wait at the bottom edge, so the
    /// focus engine isn't left to pick a card by position — a guide along
    /// the bottom edge (on only while the billboard has focus) hands Down to
    /// the row's current title. (Up needs none: with the billboard scrolled
    /// away its card list takes focus and hands it to its remembered title.)
    private lazy var belowGuide = FixedFocusRedirectGuide { [weak self] in
        guard let self, let featured = self.featuredIndex else { return [] }
        return self.currentCard(row: featured + 1)
    }

    private var featuredIndex: Int? { rows.firstIndex(where: { $0.id == featuredRowID }) }

    private func currentCard(row: Int) -> [UIFocusEnvironment] {
        guard rows.indices.contains(row),
              let rowCell = outer.cellForItem(at: IndexPath(item: row, section: 0)) as? FixedFocusRowCell
        else { return [] }
        return [rowCell.posterCell(at: selected[rows[row].id] ?? 0) ?? rowCell]
    }

}

/// A row that is a SwiftUI view (see `FixedFocusRows.customRows`): its
/// height (where the cards would be) and the view.
struct FixedFocusCustomRow {
    var height: CGFloat
    var view: AnyView
    /// How tall its content actually is (nil: its height). Focused, the
    /// rows go up only so far that this ends `customBottomGap` above the
    /// screen's bottom — never higher than the usual spot.
    var contentHeight: CGFloat? = nil
}

/// A row's header (see `FixedFocusRows.rowHeaders`): its buttons' names
/// and which one the row is at.
struct FixedFocusRowHeader: Equatable {
    var labels: [String]
    var selected: Int
}

/// A header's button: Details' button look (glass at rest, the bright
/// highlight focused, a touch larger) — moving focus along the header.
/// Select: down into the row.
final class FixedFocusHeaderButton: UIView {
    weak var rowCell: FixedFocusRowCell?
    let label: String
    let index: Int
    static let height: CGFloat = 64
    static let spacing: CGFloat = 16
    /// Between the buttons and the cards.
    static let gapBelow: CGFloat = 36

    var selected = false {
        didSet { if selected != oldValue { render() } }
    }
    private var lit = false
    private var pressed = false
    private let host: UIHostingController<FixedFocusHeaderPill>

    init(label: String, index: Int) {
        self.label = label
        self.index = index
        host = UIHostingController(rootView: FixedFocusHeaderPill(label: label, lit: false, selected: false))
        super.init(frame: .zero)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { rowCell?.headerFocusable(self) == true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: host.sizeThatFits(in: CGSize(width: 600, height: Self.height)).width, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }

    private func render() {
        host.rootView = FixedFocusHeaderPill(label: label, lit: lit, selected: selected)
        let scale = lit ? FixedFocusHeaderPill.focusScale - (pressed ? 1 - FixedFocusMetrics.pressScale : 0) : 1
        UIView.animate(withDuration: Motion.focusDuration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self { lit = true; render() }
        else if context.previouslyFocusedView === self { lit = false; pressed = false; render() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
        pressed = true
        render()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        pressed = false
        render()
        // Select: into the row, on the season's episode.
        rowCell?.focusCards()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressed = false
        render()
        super.pressesCancelled(presses, with: event)
    }
}

/// A header button's face (see `FixedFocusHeaderButton`).
struct FixedFocusHeaderPill: View {
    let label: String
    let lit: Bool
    let selected: Bool
    /// A dropdown's button: a chevron after the label.
    var chevron = false
    /// A symbol before the label (the sort button's).
    var icon: String? = nil
    static let focusScale: CGFloat = 1.07

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: GlassPill.textSize * 0.8, weight: .semibold))
            }
            Text(label)
                .font(.system(size: GlassPill.textSize, weight: .semibold))
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: GlassPill.textSize * 0.7, weight: .bold))
            }
        }
            .fixedSize()
            .padding(.horizontal, 24)
            .frame(height: FixedFocusHeaderButton.height)
            .foregroundStyle(lit ? FlatControl.contentOnFocus : selected ? FlatControl.content : FlatControl.contentMuted)
            .background {
                ZStack {
                    Color.clear.liquidGlass(in: Capsule())
                    // The row's season: lighter glass; focused: the highlight.
                    Capsule().fill(FlatControl.selected).opacity(selected && !lit ? 1 : 0)
                    Capsule().fill(AppGlass.focusTint).opacity(lit ? 1 : 0)
                }
            }
            .animation(Motion.focus, value: lit)
            .animation(Motion.focus, value: selected)
    }
}

/// A card's state line on its picture (`FixedFocusProgressView`): an
/// episode's "S1:E3", its progress, and "20m left" / "Watched" / "Airs Fri".
struct FixedFocusCardState: Equatable {
    var label: String?
    /// In progress: how far (0…1) — the bar.
    var fraction: Double?
    var right: String?
}

/// A row's list of cards. Doesn't take focus itself while `selfFocus` says
/// no (the billboard's, its focus outside — see `externalBillboard`).
final class FixedFocusStripView: UICollectionView {
    var selfFocus: () -> Bool = { true }
    override var canBecomeFocused: Bool { selfFocus() && super.canBecomeFocused }
}

/// A focus guide whose destination is worked out when focus arrives.
/// Something asked of the rows from outside (`FixedFocusRows.command`).
struct FixedFocusRowsCommand: Equatable {
    enum Action: Equatable {
        /// The row's current card becomes `index` and the row moves to show
        /// it (first in view) — no focus change; the next way in lands there.
        case aim(rowID: String, index: Int)
        /// Focus to the row's current card (from outside the rows).
        case focusRow(rowID: String)
        /// Back to the billboard (Details: on to its buttons).
        case focusBillboard
        /// The row's card `index` takes focus — as a press there would, the
        /// row first aimed at it (the billboard paging by itself, wrapping
        /// from the last title to the first). Only while focus is in that
        /// row: never pulled from elsewhere.
        case select(rowID: String, index: Int)

    }
    let action: Action
    let id = UUID()
}

final class FixedFocusRedirectGuide: UIFocusGuide {
    private let targets: () -> [UIFocusEnvironment]
    init(targets: @escaping () -> [UIFocusEnvironment]) {
        self.targets = targets
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var preferredFocusEnvironments: [UIFocusEnvironment]! {
        get { targets() }
        set {}
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
        }

        func show(_ item: MetaItem) {
            // A folder's cover is its own picture, name and all: no shade.
            shade.isHidden = item.type == "collection"
            // (At the box's size — larger for a side-info row.)
            let width = max(bounds.width, FixedFocusMetrics.boxWidth)
            FixedFocusImages.load(item.background ?? item.poster, into: backdrop, maxDimension: width)
            FixedFocusImages.load(item.logo, into: logo, maxDimension: width * 0.55)
        }
    }

    /// The box's info (name, facts) under it — part of the box: it stays
    /// put and drifts with it.
    private final class InfoPage: UIView {
        let name = UILabel()
        let facts = UILabel()
        let chips = FixedFocusChipsView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(chips)
            name.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .regular)
            name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
            facts.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .regular)
            facts.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
            addSubview(name)
            addSubview(facts)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            name.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 30)
            facts.frame = CGRect(x: 0, y: 36, width: bounds.width, height: FixedFocusMetrics.factsHeight)
            chips.frame = CGRect(x: 0, y: FixedFocusChipsView.y, width: bounds.width,
                                 height: FixedFocusMetrics.factsHeight)
        }

        func show(_ item: MetaItem) {
            chips.show(item)
            name.text = item.name
            facts.text = FixedFocusShowInfo.factsLine(item)
        }
    }

    /// Clips the pages to the box's rounded shape (the box itself doesn't
    /// clip: its info sits below it).
    private let clip = UIView()
    private var page = Page()
    private var infoPage = InfoPage()
    /// Holds the info pages.
    private let infoHost = UIView()
    private var shownID: String?
    /// The cards' rim (see `FixedFocusCardEdge`), and the focus outline in
    /// the top bar's light.
    private let edge = UIImageView()
    private let focusRing = UIImageView()

    /// The season count arrived for the title shown: its text takes it,
    /// with a short fade.
    func refreshInfo(for item: MetaItem) {
        guard shownID == item.id else { return }
        UIView.transition(with: infoPage, duration: Motion.fadeDuration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: { self.infoPage.show(item) })
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = Spotlight.cornerRadius
        clip.layer.cornerCurve = .continuous
        clip.backgroundColor = UIColor(white: 0.12, alpha: 1)
        addSubview(clip)
        clip.addSubview(page)
        infoHost.isUserInteractionEnabled = false
        addSubview(infoHost)
        infoHost.addSubview(infoPage)
        edge.isUserInteractionEnabled = false
        addSubview(edge)
        focusRing.isUserInteractionEnabled = false
        addSubview(focusRing)
        // (A layer's border is drawn above its sublayers: above the pages.)
        layer.cornerRadius = Spotlight.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.cgColor
        applyOutlineStyle()
    }

    /// The focus outline: the top bar's light or a white line.
    /// Focus is elsewhere (Search: on the keyboard or the top result): the
    /// box keeps showing its title, without the focus outline.
    var ringHidden = false {
        didSet { if ringHidden != oldValue { applyOutlineStyle() } }
    }
    private func applyOutlineStyle() {
        // The focus outline: the top bar's light, clearer (Render Lab →
        // Focus outline), or a plain white line.
        let lit = FixedFocusCardEdge.focusLight
        let hidden = ringHidden
        focusRing.image = lit && !hidden ? FixedFocusCardEdge.focusImage : nil
        layer.borderWidth = lit || hidden ? 0 : FixedFocusRing.width
        layer.borderColor = FixedFocusRing.color.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where the info sits: as under the cells (18 pt below, optically
    /// indented).
    private var infoFrame: CGRect {
        CGRect(x: FixedFocusMetrics.textIndent, y: bounds.height + 18,
               width: max(bounds.width, FixedFocusMetrics.boxWidth),
               height: FixedFocusMetrics.infoHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        // The cards' rim.
        edge.image = FixedFocusCardEdge.rim
        edge.frame = bounds
        focusRing.frame = bounds
        infoHost.bounds = CGRect(origin: .zero, size: bounds.size)
        infoHost.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if page.layer.animationKeys()?.isEmpty ?? true { page.frame = bounds }
        if infoPage.layer.animationKeys()?.isEmpty ?? true { infoPage.frame = infoFrame }
    }

    /// The box at `scale` (lifted, pressed, held). The info under it keeps
    /// its size and sits as far below the box as its `base` (lifted) size
    /// overhangs — pressing or holding doesn't move it.
    func applyScale(_ scale: CGFloat, base: CGFloat) {
        transform = CGAffineTransform(scaleX: scale, y: scale)
        let overhang = bounds.height * (base - 1) / 2
        infoHost.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).translatedBy(x: 0, y: overhang)
    }

    /// `direction`: +1 moving right (new content comes from the right),
    /// −1 moving left. Render Lab → Box change: slide or crossfade.
    func show(_ item: MetaItem, animated: Bool,
              direction: CGFloat = 1, vertical: Bool = false) {
        guard item.id != shownID else { return }
        shownID = item.id
        applyOutlineStyle()
        guard animated else {
            page.show(item)
            infoPage.show(item)
            return
        }
        // DRIFT: a crossfade with a hint of direction — the new image
        // fades in while shifting a little in the direction of travel,
        // the old one fades out shifting on. No seam, little movement.
        // (Up/Down: the same, vertically — from below on Down.)
        let shift: CGFloat = 30
        let dx = vertical ? 0 : direction * shift
        let dy = vertical ? direction * shift : 0
        let incoming = Page(frame: bounds.offsetBy(dx: dx, dy: dy))
        incoming.show(item)
        incoming.alpha = 0
        clip.addSubview(incoming)
        let outgoing = page
        page = incoming
        // The info drifts the same way, in sync.
        let infoIn = InfoPage(frame: infoFrame.offsetBy(dx: dx, dy: dy))
        infoIn.show(item)
        infoIn.alpha = 0
        infoHost.addSubview(infoIn)
        let infoOut = infoPage
        infoPage = infoIn
        let infoTarget = infoFrame
        FixedFocusMotion.run(duration: vertical ? Motion.verticalDuration : Motion.moveDuration) {
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
                image = ImageCache.decodeDownsampled(data, budget: budget)
                // In memory too (under the same key a SwiftUI RemoteImage of
                // this size uses): the Detail page opened from the billboard
                // shows the very same picture from its first frame.
                if let image {
                    ImageCache.shared.insert(image, for: url, data: data, memoryKey: memoryKey)
                } else {
                    ImageCache.shared.insertData(data, for: url)
                }
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

    /// A moving-focus row's captions only while it has focus — as the fixed
    /// box's info: rows above and below show only their cards (the same
    /// preview strip as any row).
    func applyCaptions() {
        guard let strip = destinationStrip else { return }
        for case let card as FixedFocusDestinationCell in strip.visibleCells { card.setCaptionShown(isFocusRow) }
    }

    /// The cards darkened as the row's state says (see the controller's
    /// `cardDim`).
    func applyCardDim() {
        guard let controller else { return }
        let dim = controller.cardDim(rowIndex)
        for case let card as FixedFocusDestinationCell in destinationStrip?.visibleCells ?? [] { card.dim = dim }
        for case let card as FixedFocusPosterCell in strip.visibleCells { card.dim = dim }
    }
    var cardDim: CGFloat { controller?.cardDim(rowIndex) ?? 0 }

    /// Continue Watching: landscape cards (its progress, Select resumes).
    var isContinue: Bool { controller?.isContinue(rowIndex) == true }
    /// Landscape cards (Continue Watching's, Search's rows).
    var isLandscape: Bool { controller?.isLandscape(rowIndex) == true }
    /// A collection: its name and tiles in a panel.
    var isPanel: Bool { controller?.isPanel(rowIndex) == true }
    /// Its box at the posters' size (no wide card).
    /// A destination row: its own strip (native scrolling, system lift).
    var isDestination: Bool { controller?.isDestination(rowIndex) == true }
    private var destinationStrip: UICollectionView?
    /// The cards' size.
    var cardHeight: CGFloat { controller?.cardHeight(rowIndex) ?? FixedFocusMetrics.height }
    var cardWidth: CGFloat {
        isLandscape ? FixedFocusMetrics.landscapeWidth(height: cardHeight) : FixedFocusMetrics.posterWidth
    }
    /// The billboard: no name, invisible cells (focus targets only).
    var isFeatured: Bool { controller?.isFeatured(rowIndex) == true }
    /// A header button takes focus while the row has it: from the cards
    /// only the selected one (Up lands on the row's season), along the
    /// header any.
    func headerFocusable(_ button: FixedFocusHeaderButton) -> Bool {
        guard controller?.headerShown(rowIndex) == true else { return false }
        if button.selected { return true }
        let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem
        return (focused as? FixedFocusHeaderButton)?.rowCell === self
    }

    /// The header's selected button (nil: no header showing).
    var headerFocusTarget: UIView? {
        guard controller?.headerShown(rowIndex) == true, let header = controller?.header(rowIndex),
              headerButtons.indices.contains(header.selected) else { return nil }
        return headerButtons[header.selected]
    }
    /// The cards' top: under the name (and its line, if any).
    var cardsTop: CGFloat { FixedFocusMetrics.titleHeight + (controller?.titleExtra(rowIndex) ?? 0) }
    /// A row's name.
    static let titleFont = UIFont.systemFont(ofSize: Spotlight.headerTitleSize, weight: .semibold)
    /// Waiting under the billboard: the row's cards don't show (they stay
    /// focusable).
    var concealed = false {
        didSet {
            let byLine = concealTravel != nil
            for case let poster as FixedFocusPosterCell in strip.visibleCells {
                poster.setConcealed(concealed && !byLine)
            }
            // (A destination row's list through a mask, not its alpha: the
            // focus engine skips everything in a fully transparent view, and
            // Down from the billboard went past the row.)
            applyConcealMask()
        }
    }
    /// RIGID billboard (Details): concealed, the cards are cut off by a LINE
    /// at their top instead of hidden whole; shown, the line is this much
    /// lower (past them). Changed inside the scroll it moves with the row's
    /// curve against the row's own move — so it stays put on the screen and
    /// the cards rise out from under it (no fade, no pop).
    var concealTravel: CGFloat? {
        didSet { if concealTravel != oldValue { applyConcealMask() } }
    }

    private func applyConcealMask() {
        let over = FixedFocusStripLayout.overscan
        let base = stripHost.bounds.insetBy(dx: -2 * over, dy: -200)
        guard let travel = concealTravel else {
            concealMask.alpha = concealed ? 0 : 1
            concealMask.frame = base
            return
        }
        concealMask.alpha = 1
        // (Stretched to the cards' top, or past them by the travel.)
        let line = cardsTop - stripHost.frame.minY + (concealed ? 0 : travel)
        concealMask.frame = CGRect(x: base.minX, y: base.minY, width: base.width, height: line - base.minY)
    }
    /// Hides a destination row's list while it waits under the billboard.
    private let concealMask = UIView()
    /// The name's brightness (see the controller's `titleAlpha`).
    var titleAlpha: CGFloat = 1 {
        didSet { applyHeader() }
    }
    /// How far the name sits above its usual place over the cards (the next
    /// row's, waiting under the billboard: up on the billboard).
    var titleLift: CGFloat = 0 {
        didSet {
            // (Unchanged: a move under way stays — a Left/Right mid-scroll.)
            guard titleLift != oldValue else { return }
            titleHolder.layer.removeAnimation(forKey: "lift")
            titleHolder.transform = CGAffineTransform(translationX: 0, y: -titleLift)
        }
    }
    private let titleHolder = UIView()

    /// The row's name accessory (see `FixedFocusRows.rowTitleAccessories`):
    /// on its own line under the name, shown while the row has focus.
    private var accessory: UIHostingController<AnyView>?

    func showAccessory() {
        guard let controller, let row else { return }
        guard let view = controller.rowTitleAccessories[row.id] else {
            accessory?.view.isHidden = true
            return
        }
        if let accessory {
            accessory.rootView = view
            accessory.view.isHidden = false
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.safeAreaRegions = []
            accessory = host
        }
        // (Under a header: in its block — they move as one.)
        if let host = accessory?.view {
            let parent = controller.header(rowIndex) != nil ? headerBlock : contentView
            if host.superview !== parent { parent.addSubview(host) }
        }
        setNeedsLayout()
        placeAccessory()
        applyAccessory()
    }

    func applyAccessory() { accessory?.view.alpha = isFocusRow ? 1 : 0 }


    private func placeAccessory() {
        if let host = accessory?.view {
            // Its own line: under the name, centred in the extra room (above
            // the usual gap to the cards) — or under the header, in its room.
            let size = host.sizeThatFits(CGSize(width: 1920, height: 200))
            let y: CGFloat
            if controller?.header(rowIndex) != nil {
                let room = FixedFocusRowsController.headerAccessoryHeight
                y = FixedFocusHeaderButton.height + FixedFocusRowsController.headerAccessoryGap + (room - size.height) / 2
            } else {
                let room = FixedFocusRowsController.titleAccessoryHeight
                y = FixedFocusMetrics.titleLine + (room - size.height) / 2 + 4
            }
            host.frame = CGRect(x: FixedFocusMetrics.titleInset, y: y, width: size.width, height: size.height)
        }
    }

    /// A custom row's view (see `FixedFocusRows.customRows`), where the
    /// cards would be — over them, so its focusable parts aren't covered.
    private var customHost: UIHostingController<AnyView>?

    func showCustom() {
        guard let controller else { return }
        guard let custom = controller.custom(rowIndex) else {
            customHost?.view.isHidden = true
            return
        }
        let view = controller.environment(custom.view)
        if let customHost {
            customHost.rootView = view
            customHost.view.isHidden = false
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            // (A child of the rows: focus and the environment reach it. Under
            // the row's name: what it draws may reach up behind it.)
            controller.addChild(host)
            contentView.insertSubview(host.view, belowSubview: titleHolder)
            host.didMove(toParent: controller)
            customHost = host
        }
        setNeedsLayout()
    }

    /// The row's header (see `FixedFocusRows.rowHeaders`): glass buttons in
    /// the name's place while the row has focus — the name gives way.
    private var headerButtons: [FixedFocusHeaderButton] = []
    private let headerStack = UIStackView()
    /// The header scrolls along: tvOS keeps the focused button in view; from
    /// the cards, the row's season is brought in (`revealSelected`).
    private let headerScroll = UIScrollView()
    /// The header and the line under it (the row's accessory), shown and
    /// hidden as one (see `moveHeader`).
    private let headerBlock = UIView()
    private var revealedSelection: Int?

    /// Focus back to the row's current card (Select on the header).
    func focusCards() {
        controller?.run(FixedFocusRowsCommand(action: .focusRow(rowID: row?.id ?? "")))
    }

    func showHeader() {
        guard let controller else { return }
        let labels = controller.header(rowIndex)?.labels ?? []
        if headerButtons.map(\.label) != labels {
            headerButtons.forEach { $0.removeFromSuperview() }
            headerButtons = labels.enumerated().map { index, label in
                let button = FixedFocusHeaderButton(label: label, index: index)
                button.rowCell = self
                headerStack.addArrangedSubview(button)
                return button
            }
        }
        applyHeader(animated: false)
        // (The line under it moves into / out of its block.)
        showAccessory()
    }

    /// The header or the name, whichever the row's state says; the selected
    /// button marked.
    func applyHeader(animated: Bool = true) {
        let header = controller?.header(rowIndex)
        let shown = controller?.headerShown(rowIndex) == true
        for button in headerButtons { button.selected = button.index == header?.selected }
        if let selected = header?.selected, selected != revealedSelection {
            revealedSelection = selected
            revealSelected(animated: animated && shown)
        }
        let apply = {
            self.headerStack.alpha = shown ? 1 : 0
            // (Never a fade: the name and the header trade places in the
            // billboard's move — `moveHeader`.)
            UIView.performWithoutAnimation { self.title.alpha = shown ? 0 : self.titleAlpha }
        }
        if animated, headerStack.alpha != (shown ? 1 : 0) {
            UIView.animate(withDuration: Motion.fadeDuration, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    /// Down from the billboard (`entering`) / Up to it, on the row's move
    /// (its timing over even steps of its progress, or — `timing` nil — a
    /// spring's sampled progress): the header's offset below its place
    /// along `fade`; the name's lift and opacity along `lift` and
    /// `titleOpacity` at `scale` (its ⌄ with it); then the end state.
    func moveHeader(fade: [CGFloat], lift: [CGFloat], titleOpacity: [CGFloat], scale: CGFloat,
                    timing: CAMediaTimingFunction?, duration: Double, entering: Bool) {
        let times = fade.indices.map { NSNumber(value: Double($0) / Double(max(fade.count - 1, 1))) }
        func keyframes(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values.map { NSNumber(value: Double($0)) }
            animation.keyTimes = times
            animation.calculationMode = .linear
            animation.timingFunction = timing
            animation.duration = duration
            return animation
        }
        UIView.performWithoutAnimation {
            accessory?.view.alpha = entering ? 1 : 0
            headerStack.alpha = entering ? 1 : 0
            title.alpha = entering ? 0 : titleAlpha
            titleLift = lift.last ?? 0
            titleScale = scale
        }
        let ones = [CGFloat](repeating: 1, count: fade.count)
        // (The block fades; inside it both are shown throughout.)
        headerBlock.layer.add(keyframes("opacity", fade), forKey: "opacity")
        accessory?.view.layer.add(keyframes("opacity", ones), forKey: "opacity")
        headerStack.layer.add(keyframes("opacity", ones), forKey: "opacity")
        titleHolder.layer.add(keyframes("transform.translation.y", lift.map { -$0 }), forKey: "lift")
        title.layer.add(keyframes("opacity", titleOpacity), forKey: "opacity")
    }

    /// The row's season in view (a step across a season seam, opening on
    /// a later season) — not while focus is on the header: tvOS scrolls it.
    private func revealSelected(animated: Bool) {
        guard let index = revealedSelection, headerButtons.indices.contains(index),
              !headerButtons.contains(where: \.isFocused) else { return }
        layoutIfNeeded()
        let frame = headerButtons[index].frame.offsetBy(dx: headerStack.frame.minX, dy: 0)
        let inset = FixedFocusMetrics.inset
        let width = headerScroll.bounds.width
        let maxX = max(headerScroll.contentSize.width - width, 0)
        var x = headerScroll.contentOffset.x
        if frame.maxX + inset > x + width { x = frame.maxX + inset - width }
        if frame.minX - inset < x { x = frame.minX - inset }
        x = min(max(x, 0), maxX)
        guard x != headerScroll.contentOffset.x else { return }
        let move = { self.headerScroll.contentOffset.x = x }
        if animated {
            UIView.animate(withDuration: Motion.moveDuration, delay: 0,
                           usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: move)
        } else {
            move()
        }
    }


    /// The name's size (the next row's, on the billboard: smaller).
    var titleScale: CGFloat = 1 {
        didSet {
            guard titleScale != oldValue else { return }
            title.layer.removeAnimation(forKey: "scale")
            title.transform = CGAffineTransform(scaleX: titleScale, y: titleScale)
        }
    }
    /// The grown cell's own content hidden (the fixed box shows it).
    var contentHidden = true {
        didSet { applyGrown() }
    }

    private let layout = FixedFocusStripLayout()

    override init(frame: CGRect) {
        strip = FixedFocusStripView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        // The billboard's invisible cards: not while its focus is outside
        // (Details' buttons) — neither they nor the list in their place.
        (strip as? FixedFocusStripView)?.selfFocus = { [weak self] in !(self?.billboardCardsOff ?? false) }
        layout.wideIndex = { [weak self] in
            guard let self, self.isFocusRow, !self.isLandscape, !self.isFeatured else { return nil }
            return self.selectedIndex
        }
        layout.cardWidth = { [weak self] in self?.cardWidth ?? FixedFocusMetrics.posterWidth }
        layout.cardHeight = { [weak self] in self?.cardHeight ?? FixedFocusMetrics.height }
        clipsToBounds = false
        contentView.clipsToBounds = false
        title.font = Self.titleFont
        title.textColor = UIColor.white.withAlphaComponent(FixedFocusText.heading)
        // The name in a holder: the holder lifts (`titleLift`), the name in
        // it scales from its left edge (`titleScale`).
        title.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        titleHolder.addSubview(title)
        contentView.addSubview(titleHolder)
        headerStack.axis = .horizontal
        headerStack.spacing = FixedFocusHeaderButton.spacing
        headerStack.alpha = 0
        headerScroll.clipsToBounds = false
        headerScroll.showsHorizontalScrollIndicator = false
        headerScroll.contentInsetAdjustmentBehavior = .never
        headerScroll.addSubview(headerStack)
        headerBlock.addSubview(headerScroll)
        contentView.addSubview(headerBlock)
        strip.backgroundColor = .clear
        strip.clipsToBounds = false
        strip.isScrollEnabled = false
        strip.showsHorizontalScrollIndicator = false
        strip.contentInsetAdjustmentBehavior = .never
        strip.remembersLastFocusedIndexPath = true
        strip.dataSource = self
        strip.delegate = self
        strip.register(FixedFocusPosterCell.self, forCellWithReuseIdentifier: "poster")
        stripHost.layer.cornerRadius = FixedFocusMetrics.panelRadius
        stripHost.layer.cornerCurve = .continuous
        stripHost.addSubview(strip)
        contentView.addSubview(stripHost)
        // The header over the cards' host (it spans the cell): it must not
        // be covered, or tvOS won't focus it.
        // (The name too: as a control it must not be covered either.)
        contentView.bringSubviewToFront(titleHolder)
        contentView.bringSubviewToFront(headerBlock)


    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // (Last: once the strip has its size.)
        defer { applyPendingAim() }
        // (Bounds and centre: the name may be lifted — a transform.)
        // (Wide: as a control, Up from any card finds it.)
        titleHolder.bounds = CGRect(x: 0, y: 0, width: 1700, height: FixedFocusMetrics.titleLine)
        titleHolder.center = CGPoint(x: FixedFocusMetrics.titleInset + 850, y: FixedFocusMetrics.titleLine / 2)
        title.bounds = CGRect(x: 0, y: 0, width: 1200, height: FixedFocusMetrics.titleLine)
        title.center = CGPoint(x: 0, y: FixedFocusMetrics.titleLine / 2)
        placeAccessory()
        customHost?.view.frame = CGRect(x: 0, y: cardsTop, width: bounds.width, height: cardHeight)
        let headerSize = headerStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        headerBlock.frame = CGRect(x: 0, y: 0, width: bounds.width, height: cardsTop)
        headerScroll.bounds.size = CGSize(width: bounds.width, height: FixedFocusHeaderButton.height)
        headerScroll.center = CGPoint(x: bounds.width / 2, y: FixedFocusHeaderButton.height / 2)
        headerStack.frame = CGRect(x: FixedFocusMetrics.inset, y: 0,
                                   width: headerSize.width, height: FixedFocusHeaderButton.height)
        headerScroll.contentSize = CGSize(width: headerSize.width + 2 * FixedFocusMetrics.inset,
                                          height: FixedFocusHeaderButton.height)
        // Wider than the screen on both sides: posters sliding in or out at
        // the edges keep their cells and SLIDE (outside the visible area
        // UIKit creates / drops them with a fade, in place).
        let over = FixedFocusStripLayout.overscan
        strip.frame = CGRect(x: -over, y: cardsTop,
                             width: 1920 + 2 * over, height: cardHeight)
        // The billboard's picture: the whole screen while this row is at the
        // focus spot (its edge below).
        stage?.frame = CGRect(x: 0, y: -FixedFocusMetrics.rowTop, width: 1920,
                              height: StagePictureView.pictureSize.height)
        panel?.frame = FixedFocusPanelView.frame(cardHeight: cardHeight)
        // A collection's tiles stay inside its panel: they slide under its
        // edges (the strip's host clips to it).
        let stripFrame = strip.frame
        if let panel, isPanel {
            stripHost.frame = panel.frame
            stripHost.clipsToBounds = true
        } else {
            stripHost.frame = bounds
            stripHost.clipsToBounds = false
        }
        strip.frame = stripFrame.offsetBy(dx: -stripHost.frame.minX, dy: -stripHost.frame.minY)
        // A destination strip: the screen plus the overscan on both sides.
        destinationStrip?.frame = CGRect(x: -over, y: cardsTop,
                                         width: 1920 + 2 * over, height: cardHeight)
            .offsetBy(dx: -stripHost.frame.minX, dy: -stripHost.frame.minY)
        // Covers the list wherever its cards (and their lift) reach.
        UIView.performWithoutAnimation { applyConcealMask() }
    }

    /// Holds the strip; a panel row's clips to the panel.
    private let stripHost = UIView()

    /// The Featured row: the billboard's picture (see `StagePictureView`).
    private var stage: StagePictureView?
    /// A collection row's panel (see `FixedFocusPanelView`).
    private var panel: FixedFocusPanelView?

    func tintPanel(_ item: MetaItem, animated: Bool) {
        guard let panel, isPanel else { return }
        panel.tint(for: item.background ?? item.poster, animated: animated)
    }



    func showStage(_ item: MetaItem, direction: CGFloat, animated: Bool) {
        // Full screen: TMDB's ORIGINAL file, whatever size the pick came
        // with (a saved pick or cached catalog may still carry a smaller
        // rendition — soft on a 4K TV).
        placeStage(TMDBService.originalSize(item.background) ?? item.poster,
                   direction: direction, animated: animated)
    }

    private func placeStage(_ url: String?, direction: CGFloat, animated: Bool) {
        guard isFeatured, controller?.hidesBillboardPicture != true else { return }
        // Pinned: the controller's, not part of this row.
        if let pinned = controller?.pinnedStage {
            stage?.removeFromSuperview()
            stage = nil
            pinned.show(url, direction: direction, animated: animated)
            return
        }
        if stage == nil {
            let view = StagePictureView()
            contentView.insertSubview(view, at: 0)
            stage = view
            setNeedsLayout()
            layoutIfNeeded()
        }
        stage?.show(url, direction: direction, animated: animated)
    }

    /// The catalog (and its titles and art) this cell last showed.
    private var shownRow: (id: String, content: [String])?

    /// The name coming down into place (see the controller's
    /// `revealNextNameIfNew`).
    func revealTitle() {
        let alpha = title.alpha
        title.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.title.alpha = alpha
        }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -ModeSwap.lift
        drop.toValue = 0
        drop.isAdditive = true
        drop.duration = 0.45
        drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.85, 0.25, 1)
        title.layer.add(drop, forKey: "reveal")
    }

    /// A new name, crossfaded (the row itself unchanged).
    func showTitle(_ text: String) {
        guard title.text != text else { return }
        UIView.transition(with: title, duration: Motion.fadeDuration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: { self.title.text = text })
        setNeedsLayout()
    }

    func configure(rowIndex: Int, controller: FixedFocusRowsController) {
        self.rowIndex = rowIndex
        self.controller = controller
        title.text = row?.title
        title.isHidden = isFeatured
        setNeedsLayout()
        showAccessory()
        showHeader()
        showCustom()
        if isPanel {
            if panel == nil {
                let view = FixedFocusPanelView()
                contentView.insertSubview(view, at: 0)
                panel = view
                setNeedsLayout()
            }
            if let row, row.items.indices.contains(selectedIndex) {
                tintPanel(row.items[selectedIndex], animated: false)
            }
        }
        panel?.isHidden = !isPanel
        if isFeatured, let row, row.items.indices.contains(selectedIndex) {
            showStage(row.items[selectedIndex], direction: 1, animated: false)
        }
        strip.isHidden = isDestination
        if isDestination, destinationStrip == nil { makeDestinationStrip() }
        destinationStrip?.isHidden = !isDestination
        // The same catalog coming back (it keeps its own cell): leave its
        // posters, scroll position and focus memory as they are — a reload
        // would erase exactly that. Only new content reloads.
        if let row, let shown = shownRow, shown.id == row.id, shown.content == row.contentKey {
            return
        }
        shownRow = row.map { ($0.id, $0.contentKey) }
        if isDestination {
            // Scrolled by their own rule (see `windowOffset`).
            destinationStrip?.isScrollEnabled = false
            windowStart = 0
            destinationStrip?.reloadData()
            destinationStrip?.contentOffset = .zero
            // (Aimed before its cell was made: there at once — and again once
            // the strip has its size: a page built in one go (Details with
            // its data) made this cell before layout, the offset set then
            // was lost, and the row sat at its first card while the engine
            // took it to be at the aimed one — Down then found nothing.)
            if selectedIndex > 0 {
                destinationStrip?.layoutIfNeeded()
                aim(selectedIndex, animated: false)
                pendingAim = selectedIndex
                setNeedsLayout()
            }
            return
        }
        contentHidden = true
        strip.reloadData()
        strip.layoutIfNeeded()
        strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0)
    }

    /// Select pressed on a fixed row's card (the box shows it).
    func setBoxPressed(_ pressed: Bool) { controller?.setBoxPressed(pressed) }

    /// This row's first card on screen, at rest (see the controller).
    func restingCardOrigin() -> CGPoint? { controller?.restingCardOrigin(rowIndex) }
    /// SwiftUI for a card, with the app's stores.
    func hosted(_ view: some View) -> AnyView { controller?.environment(AnyView(view)) ?? AnyView(view) }

    func posterCell(at index: Int) -> UIView? {
        let shown = destinationStrip.flatMap { isDestination ? $0 : nil } ?? strip
        shown.layoutIfNeeded()
        return shown.cellForItem(at: IndexPath(item: index, section: 0))
    }

    /// A destination row's strip: the system's horizontal scrolling — focus
    /// moves along, the row follows only near its edge.
    private func makeDestinationStrip() {
        let flow = UICollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = FixedFocusMetrics.destinationGap
        // Wider than the screen by the strips' overscan (positions shifted
        // by it): cards scrolling out keep their cells and SLIDE away —
        // outside its bounds UIKit drops them at once.
        let over = FixedFocusStripLayout.overscan
        flow.sectionInset = UIEdgeInsets(top: 0, left: over + FixedFocusMetrics.inset, bottom: 0,
                                         right: over + FixedFocusMetrics.inset)
        let view = UICollectionView(frame: .zero, collectionViewLayout: flow)
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        // No memory: the way in is always the row's current card (see
        // `indexPathForPreferredFocusedView`). A remembered card that's no
        // longer current (aimed elsewhere — Details' seasons) can't take
        // focus, and the strip itself took it instead: a dead end.
        view.remembersLastFocusedIndexPath = false
        view.dataSource = self
        view.delegate = self
        view.register(FixedFocusDestinationCell.self, forCellWithReuseIdentifier: "destination")
        view.register(FixedFocusBannerCell.self, forCellWithReuseIdentifier: "banner")
        stripHost.addSubview(view)
        destinationStrip = view
        concealMask.backgroundColor = .black
        concealMask.alpha = concealed ? 0 : 1
        stripHost.mask = concealMask
        setNeedsLayout()
    }

    /// Inside the controller's animation: grow the new, shrink the old,
    /// move the row so the new one sits at the spot.
    func focus(index: Int) {
        guard !isDestination else { return }
        relayout()
        strip.contentOffset = CGPoint(x: offset(for: index), y: 0)
    }

    /// Re-lay out (grown cell or not) and restyle the visible cells.
    func relayout() {
        guard !isDestination else { return }
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
            poster.setPast(isPast(poster.itemIndex))
        }
    }

    /// Left of the box in the focused row: where you came from — dimmed.
    private func isPast(_ index: Int) -> Bool { isFocusRow && index < selectedIndex }

    /// The row offset that puts title `index` at the spot. Exact: every
    /// title before it is card-wide (`FixedFocusStripLayout`).
    private func offset(for index: Int) -> CGFloat {
        CGFloat(index) * (cardWidth + FixedFocusMetrics.gap)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        row?.items.count ?? 0
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if cv === destinationStrip, controller?.isBanner(rowIndex) == true {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "banner", for: indexPath) as! FixedFocusBannerCell
            if let row, row.items.indices.contains(indexPath.item) {
                cell.configure(row.items[indexPath.item], index: indexPath.item, rowCell: self)
            }
            return cell
        }
        if cv === destinationStrip {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "destination", for: indexPath)
                as! FixedFocusDestinationCell
            if let row, let controller, row.items.indices.contains(indexPath.item) {
                let item = row.items[indexPath.item]
                cell.configure(item, subtitle: row.subtitles[item.id], index: indexPath.item, rowCell: self,
                               card: controller.destinationCard(rowIndex),
                               progress: controller.isContinue(rowIndex) ? controller.progress[item.id] : nil,
                               cardState: controller.cardStates[item.id],
                               isLogo: controller.isLogo(rowIndex))
                cell.setCaptionShown(isFocusRow)
                UIView.performWithoutAnimation { cell.dim = cardDim }
            }
            return cell
        }
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath) as! FixedFocusPosterCell
        if let row {
            let item = row.items[indexPath.item]
            cell.configure(item, index: indexPath.item, rowCell: self,
                           progress: isContinue ? controller?.progress[item.id] : nil,
                           landscape: isLandscape, invisible: isFeatured,
                           cardHeight: cardHeight)
            cell.setGrown(isFocusRow && indexPath.item == selectedIndex, contentHidden: contentHidden)
            cell.setPast(isPast(indexPath.item))
            cell.setConcealed(concealed)
            UIView.performWithoutAnimation { cell.dim = cardDim }
        }
        return cell
    }

    private var billboardCardsOff: Bool { isFeatured && controller?.billboardFocusOutside == true }

    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if cv === strip && billboardCardsOff { return false }
        // Into a moving-focus row from outside: only its current card. The
        // nearest by position is often the sliver of the one before (an
        // aimed row — Details' episodes), and redirecting from there fails
        // when focus comes from outside the rows (SwiftUI's Play, the
        // season name).
        // (SwiftUI's focused item isn't always a UIView: anything but a
        // view inside this row counts as outside.)
        if cv === destinationStrip,
           (UIFocusSystem.focusSystem(for: cv)?.focusedItem as? UIView)?.isDescendant(of: cv) != true {
            return indexPath.item == selectedIndex
        }
        // A fixed row, from outside the rows altogether (Details' Play down
        // into a row last left further along): its current card too, not
        // the sliver of the one before. (Between rows the box's own move
        // decides.)
        if cv === strip, !isFeatured, let rows = superview,
           (UIFocusSystem.focusSystem(for: cv)?.focusedItem as? UIView)?.isDescendant(of: rows) != true {
            return indexPath.item == selectedIndex
        }
        return true
    }

    func indexPathForPreferredFocusedView(in cv: UICollectionView) -> IndexPath? {
        guard cv === destinationStrip, let row, row.items.indices.contains(selectedIndex) else { return nil }
        return IndexPath(item: selectedIndex, section: 0)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if cv === destinationStrip, let controller {
            return CGSize(width: controller.destinationCard(rowIndex).width, height: cardHeight)
        }
        return CGSize(width: isFocusRow && !isLandscape && indexPath.item == selectedIndex
                        ? FixedFocusMetrics.boxWidth : cardWidth,
                      height: cardHeight)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        guard let controller else { return FixedFocusMetrics.destinationGap }
        return FixedFocusMetrics.destinationGap(cardWidth: controller.destinationCard(rowIndex).width)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row, row.items.indices.contains(indexPath.item) else { return }
        controller?.select(row.items[indexPath.item], rowIndex: rowIndex)
    }

    /// A destination row: moves to its window for the focused card, on
    /// Home's curve and timing.
    func collectionView(_ cv: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard cv === destinationStrip, let index = context.nextFocusedIndexPath?.item,
              let controller, let row else { return }
        let card = controller.destinationCard(rowIndex)
        let offset = windowOffset(focusing: index, card: card.width, count: row.items.count)
        guard offset != cv.contentOffset.x else { return }
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            cv.contentOffset = CGPoint(x: offset, y: 0)
        } completion: { _ in }
    }

    /// The first card a destination row shows in full.
    private var windowStart = 0
    /// An aim's scroll: very fast, and at most this far (a longer way starts
    /// this far short of it).
    static let aimDuration: Double = 0.3
    static let aimLead: CGFloat = 1100
    /// An aim made before the strip had its size (see `configure`).
    private var pendingAim: Int?

    private func applyPendingAim() {
        guard let index = pendingAim, let cv = destinationStrip, cv.bounds.width > 0 else { return }
        pendingAim = nil
        guard index == selectedIndex else { return }
        cv.layoutIfNeeded()
        aim(index, animated: false)
    }

    /// Shows `index` first in view (aimed from outside — see
    /// `FixedFocusRowsCommand.aim`): a very fast scroll (Details' season
    /// buttons). A long way: from just short of it — the cards between
    /// were never drawn.
    /// A fixed-focus row (the billboard's) straight at `index` — its card
    /// there, for focus to land on (the billboard paging by itself, the
    /// last title to the first). Destination rows: `aim`.
    func jump(to index: Int) {
        guard !isDestination, let row, row.items.indices.contains(index) else { return }
        strip.contentOffset = CGPoint(x: offset(for: index), y: 0)
        strip.layoutIfNeeded()
    }

    func aim(_ index: Int, animated: Bool = true) {
        guard isDestination, let cv = destinationStrip, let controller, let row,
              row.items.indices.contains(index) else { return }
        let card = controller.destinationCard(rowIndex)
        windowStart = index
        let offset = windowOffset(focusing: index, card: card.width, count: row.items.count)
        let distance = abs(offset - cv.contentOffset.x)
        guard distance > 0.5 else { return }
        guard animated else {
            cv.contentOffset = CGPoint(x: offset, y: 0)
            return
        }
        if distance > Self.aimLead {
            let lead = offset > cv.contentOffset.x ? Self.aimLead : -Self.aimLead
            UIView.performWithoutAnimation {
                cv.contentOffset = CGPoint(x: offset - lead, y: 0)
                cv.layoutIfNeeded()
            }
        }
        UIView.animate(withDuration: Self.aimDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            cv.contentOffset = CGPoint(x: offset, y: 0)
        }
    }

    /// Destination rows scroll by a rule, not the system's: as many cards in
    /// full as their space holds (a collection's panel; the screen) with, once
    /// the row has moved, a sliver of the one before and the one after split
    /// evenly — always a hint when there's more. At the start: the cards from
    /// the usual inset, the next one's sliver at the right.
    private func windowOffset(focusing index: Int, card: CGFloat, count: Int) -> CGFloat {
        let gap = FixedFocusMetrics.destinationGap(cardWidth: card)
        let pitch = card + gap
        // Focus stays in place (`FixedFocusRows.anchoredRowIDs`): the
        // focused card always at the first card's spot — to the last one,
        // the row's end left open.
        if let row, controller?.anchoredRowIDs.contains(row.id) == true {
            windowStart = index
            return CGFloat(index) * pitch
        }
        let space = isPanel ? FixedFocusPanelView.frame(cardHeight: cardHeight)
                            : CGRect(x: 0, y: 0, width: 1920, height: 0)
        // Room for the slivers (and their gaps) on both sides.
        let room = space.width - 2 * (gap + FixedFocusMetrics.destinationSliver)
        let shown = max(1, Int((room + gap) / pitch))
        if index < windowStart { windowStart = index }
        if index > windowStart + shown - 1 { windowStart = index - shown + 1 }
        guard windowStart > 0 else { return 0 }
        let edge = (space.width - CGFloat(shown) * card - CGFloat(shown - 1) * gap) / 2
        let content = 2 * FixedFocusMetrics.inset + CGFloat(count) * pitch - gap
        let end = max(0, content - 1920)
        return min(FixedFocusMetrics.inset + CGFloat(windowStart) * pitch - (space.minX + edge), end)
    }
}

extension UIView {
    /// This view on screen (window points, its transform included).
    @MainActor
    var onScreen: CGRect { convert(bounds, to: nil) }

    /// A picture of this view as it looks now.
    @MainActor
    func picture() -> UIImage? {
        guard window != nil else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}



/// THE way into Details, from everywhere (billboard, cards, Search, folders,
/// More Like This). Nothing shown before it's final; every move is Core
/// Animation (played by the render server — the main thread can't make it
/// jump), and nothing heavy runs while something moves. STRICT PHASES:
/// A. Move 1 — the page dims; Details' picture comes forward over it: in at
///    Home's framing, zooming once into Details' as it fades in. Starts
///    once the picture is decoded (usually at the press).
/// B. Still — everything else is loaded (`DetailPreparer`), Details is pushed
///    and built under the still picture, until the main thread has been
///    quiet for a few frames.
/// C. Move 2 — the picture hands over to Details (its rows' name) and the
///    info block fades in, in place. Focus is on Play from its first frame.
/// Back: the mirror. Every phase's main-thread hitches go to the LAN log
/// ("details") — `FrameWatch`.
@MainActor
final class DetailTransition {
    static let shared = DetailTransition()

    // The look — tune here (the real durations; no multiplier).
    /// A: the page going (it only dims — scaled too, it fought the
    /// picture's zoom: in, out, in).
    static let pageDim: CGFloat = 0.85
    static let pageTime: Double = 0.3
    /// A: the picture, from exactly Home's framing (the billboard's — Details
    /// frames it `ModeSwap.depthScale` larger) zooming ONCE into Details'.
    static let pictureDelay: Double = 0.05
    static let pictureFade: Double = 0.38
    static let pictureSettle: Double = 0.55
    /// Fade: the zoomed backdrop alone this long before the info block
    /// comes in. (Tried: the info block landing WITH the zoom's end, and
    /// 0.1 s before it — not it; a 0.25 s pause — too slow.)
    static let picturePause: Double = 0.0
    /// …the info block starting at this much of the zoom's time (its tail
    /// barely moves; 1: at its very end).
    static let revealAt: Double = 0.85
    /// The picture's zoom: the original curve — quick off the mark, a long
    /// settle — a little slower (0.7 s; was 0.5, then 0.6). (Tried: linear —
    /// too abrupt; gentle starts (0.45, 0, 0.15, 1), (0.3, 0.25, 0.15, 1);
    /// ease in-out (0.35, 0, 0.25, 1).)
    static let zoomInCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
    /// B: quiet frames before C (and at most this long).
    static let quietFrames = 2
    static let quietLimit: Double = 1.0
    /// C: the hand-over and the rise.
    static let reveal: Double = 0.28

    static let textTime: Double = 0.28
    /// Back.
    /// Back (the simple exit): Details fades and steps back to this size.
    static let exitTime: Double = 0.25
    static let exitScale: CGFloat = 0.98
    static let ringAfter: Double = 1.5
    static let giveUp: Double = 8

    static let settleCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
    static let inOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let out = CAMediaTimingFunction(name: .easeOut)

    private var busy = false
    private var appeared: String?
    /// The picture each opened page shows (Back brings it over it again).
    private var pictures: [String: String] = [:]
    /// Details' info block (its host view in the rows engine): hidden from
    /// its first frame while `hidesNextText`, then risen in.
    var hidesNextText = false
    private(set) weak var textView: UIView?
    private var textViews: [String: UIView] = [:]
    private let overlay = DetailTransitionOverlay()

    /// The rows engine made a billboard text host.
    func textHostCreated(_ view: UIView) {
        guard hidesNextText else { return }
        hidesNextText = false
        view.alpha = 0
        textView = view
    }

    func pageAppeared(_ id: String) { appeared = id }

    /// Where an opening started (Back returns there): the picture at
    /// Home's framing.
    struct Opening {
        var picture: CGRect
    }
    private var openings: [String: Opening] = [:]

    static var screen: CGRect { CGRect(origin: .zero, size: StagePictureView.pictureSize) }
    /// Details' picture on screen: a little wider than it (the drift),
    /// stepped closer (`ModeSwap.depthScale`).
    static func detailsPicture(scale: CGFloat? = nil) -> CGRect {
        let scale = scale ?? ModeSwap.depthScale(1)
        let size = CGSize(width: (1920 + 2 * StagePictureView.drift) * scale, height: 1080 * scale)
        return CGRect(x: 960 - size.width / 2, y: 540 - size.height / 2, width: size.width, height: size.height)
    }

    /// The opening's start: Home's framing of the picture (the billboard's,
    /// as large as it is at the press).
    private static func opening(startScale: CGFloat) -> Opening {
        Opening(picture: detailsPicture(scale: startScale))
    }

    func open(_ item: MetaItem, push: @escaping () -> Void) {
        guard !busy, let window = Self.window else { return }
        let opening = Self.opening(startScale: 1)
        busy = true
        ModeSwap.shared.handingOver = true
        DetailOpenProbe.pressed()
        DetailPreparer.shared.start(item)
        // The screen as it is, in the overlay: what dims and what the picture
        // comes over — so Details can be pushed and BUILT under it at once,
        // during move 1 (the moves are the render server's; the main thread
        // building doesn't touch them).
        overlay.install(in: window, page: window.snapshotView(afterScreenUpdates: false))
        let watch = FrameWatch()
        let k = Self.length
        Task { @MainActor in
            let start = CACurrentMediaTime()
            let ring = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.ringAfter * Self.length))
                if !Task.isCancelled { self.overlay.ring(true) }
            }
            // A. Move 1: the page dims at once; the picture as soon as it's
            // decoded. (Not awaited: Details is built meanwhile.)
            watch.begin("move 1")
            var moves: [Task<Void, Never>] = []
            moves.append(Task { await Self.run {
                Self.animate(self.overlay.dim, "opacity", from: 0, to: Self.pageDim, Self.pageTime * k, Self.inOut)
            } })
            let url = await DetailPreparer.shared.picture(for: item, within: Self.giveUp)
            let image = url.flatMap(Self.decoded)
            let wait = Self.pictureDelay * k - (CACurrentMediaTime() - start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            var zoomEnd: CFTimeInterval?
            if let url, let image {
                pictures[item.id] = url
                openings[item.id] = opening
                overlay.picture.image = image
                // The billboard's own shade (Details uses the same).
                overlay.place(opening, shade: StageArt.shade)
                zoomEnd = CACurrentMediaTime() + Self.pictureSettle * k
                moves.append(Task {
                    await Self.run {
                        Self.animate(self.overlay.pictureFrame.layer, "opacity", from: 0, to: 1, Self.pictureFade * k, Self.out)
                        self.overlay.open(from: opening, Self.pictureSettle * k, Self.zoomInCurve)
                    }
                })
            }
            // A frame for the moves to be handed over before the main thread
            // gets busy (Details is built during them).
            try? await Task.sleep(for: .milliseconds(20))
            // Under it: the rest of the data, then Details, pushed and built.
            await DetailPreparer.shared.ready(item, within: Self.giveUp)
            ModeSwap.shared.billboardItemID = item.id
            ModeSwap.shared.billboardRatings = nil
            ModeSwap.shared.billboardFacts = nil
            ModeSwap.shared.billboardSeriesSize = nil
            ModeSwap.shared.billboardTint = (nil, nil)
            appeared = nil
            hidesNextText = true
            DetailOpenProbe.note("push")
            DetailsOpen.shared.depth += 1
            push()
            ModeSwap.shared.handingOver = false
            let built = CACurrentMediaTime()
            while appeared != item.id, CACurrentMediaTime() - built < 1 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let drawnAt = CACurrentMediaTime()
            // The rest once the picture looks landed — `revealAt` of its zoom
            // (its last bit hardly moves and runs out under the fade) — and
            // Details is ready.
            if let zoomEnd {
                await moves.first?.value
                let at = zoomEnd - Self.pictureSettle * k * (1 - Self.revealAt) - CACurrentMediaTime()
                if at > 0 { try? await Task.sleep(for: .seconds(at)) }
                if Self.picturePause > 0 { try? await Task.sleep(for: .seconds(Self.picturePause * k)) }
            } else {
                for move in moves { await move.value }
            }
            // B. Only if Details was drawn just now: its first frames.
            watch.begin("still")
            if CACurrentMediaTime() - drawnAt < 0.15 {
                await watch.quiet(frames: Self.quietFrames, within: Self.quietLimit)
            }
            hidesNextText = false
            ring.cancel()
            overlay.ring(false)
            if let text = textView { textViews[item.id] = text }
            let covered = image != nil
            // The page (the snapshot) gone under the picture.
            if covered {
                Self.set(overlay.dim, "opacity", 0)
                overlay.dropPage()
            }
            // (Dev: `-detailsHold` keeps the cover up a while — to compare it
            // with Details on screenshots.)
            if ProcessInfo.processInfo.arguments.contains("-detailsHold") {
                try? await Task.sleep(for: .seconds(3))
            }
            // C. Hand-over and rise.
            watch.begin("move 2")
            DetailOpenProbe.note("reveal")
            let text = textView
            Self.refocus()
            await Self.run {
                if !covered {
                    Self.animate(self.overlay.dim, "opacity", from: Self.pageDim, to: 0, Self.reveal * k, Self.inOut)
                    self.overlay.fadePage(Self.reveal * k)
                }
                Self.animate(self.overlay.pictureFrame.layer, "opacity", from: covered ? 1 : 0, to: 0, Self.reveal * k, Self.inOut)
                // The info block: a plain fade, in place.
                if let text {
                    text.alpha = 1
                    Self.animate(text.layer, "opacity", from: 0, to: 1, Self.textTime * k, Self.inOut)
                }
            }
            watch.end()
            overlay.remove()
            busy = false
        }
    }


    /// 1 — or 4 with the dev slow motion.
    static var length: Double { slowMotion ? 4 : 1 }
    /// Dev: `-transitionSlowMo` — every move 4× longer (to watch / screenshot).
    static let slowMotion = ProcessInfo.processInfo.arguments.contains("-transitionSlowMo")

    /// Back from Details: the info block drops away, the picture is over it
    /// again, the page goes; the page below comes back to its size.
    func close(itemID: String?, pop: @escaping () -> Void) {
        guard !busy, let window = Self.window else { pop(); return }
        // THE EXIT (from anywhere, the billboard too): Details steps back — it
        // fades and shrinks a touch — and the page below is simply there
        // (Back is about leaving: quick, no picture brought forward).
        busy = true
        let k = Self.length
        let watch = FrameWatch()
        watch.begin("back")
        let shot = window.rootViewController?.view.snapshotView(afterScreenUpdates: false)
        overlay.install(in: window, page: shot)
        if let itemID {
            textViews[itemID] = nil
            pictures[itemID] = nil
            openings[itemID] = nil
        }
        pop()
        DetailsOpen.shared.depth = max(0, DetailsOpen.shared.depth - 1)
        Task { @MainActor in
            if let shot {
                await Self.run {
                    // (A frame for the page below to be drawn.)
                    Self.animate(shot.layer, "opacity", from: 1, to: 0, Self.exitTime * k, Self.inOut, delay: 1.0 / 30)
                    Self.animate(shot.layer, "transform.scale", from: 1, to: Self.exitScale, Self.exitTime * k,
                                 Self.inOut, delay: 1.0 / 30)
                }
            }
            watch.end()
            overlay.remove()
            busy = false
        }
    }

    // MARK: Core Animation

    /// The animations added in `body`, until Core Animation says they're
    /// ALL done (a fixed wait cut them short when they began late).
    /// …or until their longest one has ended by the clock, whichever comes
    /// first (a late report never holds the next phase back).
    private static func run(_ body: () -> Void) async {
        collecting = 0
        var resumed = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            func finish() {
                guard !resumed else { return }
                resumed = true
                done.resume()
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            body()
            CATransaction.commit()
            // To the render server NOW: otherwise only when the main thread
            // next returns to its run loop — after building Details, the
            // moves began ~0.25 s late.
            CATransaction.flush()
            let longest = collecting ?? 0
            collecting = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(longest + 1.0 / 60))
                finish()
            }
        }
    }
    /// The longest animation added inside a `run` so far.
    private static var collecting: Double?
    private static func note(_ duration: Double) {
        if let longest = collecting { collecting = max(longest, duration) }
    }

    /// From → to, the model value set to the end (it stays there).
    static func animate(_ layer: CALayer, _ path: String, from: CGFloat, to: CGFloat,
                        _ duration: Double, _ curve: CAMediaTimingFunction, delay: Double = 0) {
        let animation = CABasicAnimation(keyPath: path)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = curve
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        note(duration + delay)
        set(layer, path, to)
        layer.add(animation, forKey: path)
    }

    /// A layer from one frame (in its superlayer) to another: its size and
    /// place (Core Animation scales a picture's contents with it).
    static func move(_ layer: CALayer, from: CGRect, to: CGRect, _ duration: Double, _ curve: CAMediaTimingFunction) {
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = CGRect(origin: .zero, size: from.size)
        bounds.toValue = CGRect(origin: .zero, size: to.size)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = CGPoint(x: from.midX, y: from.midY)
        position.toValue = CGPoint(x: to.midX, y: to.midY)
        for animation in [bounds, position] {
            animation.duration = duration
            animation.timingFunction = curve
        }
        note(duration)
        place(layer, to)
        layer.add(bounds, forKey: "bounds")
        layer.add(position, forKey: "position")
    }

    static func place(_ layer: CALayer, _ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()
    }

    static func set(_ layer: CALayer, _ path: String, _ value: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: path)
        layer.setValue(value, forKeyPath: path)
        CATransaction.commit()
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The picture as Details decodes it (same size: same memory entry).
    private static func decoded(_ url: String) -> UIImage? {
        ImageCache.shared.image(for: RemoteImage.memoryKey(url, maxDimension: StagePictureView.pictureSize.width,
                                                           maxPixels: nil))
    }

    /// Focus onto the page that's now up.
    private static func refocus() {
        window?.rootViewController?.setNeedsFocusUpdate()
        window?.rootViewController?.updateFocusIfNeeded()
    }
}

typealias DetailTransitionOpening = DetailTransition.Opening

/// Over everything (on the window, above the app): the page's dimming,
/// Details' picture exactly where Details draws it (without its shade), a
/// ring for a long wait.
@MainActor
final class DetailTransitionOverlay {
    let root = UIView()
    let dim = CALayer()
    /// The screen, clipped: the cover picture's frame — it fades.
    let pictureFrame = UIView()
    let picture = UIImageView()
    /// Details' shade over the picture (the cover is Details without its
    /// text — the reveal only adds things).
    let shade = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)

    init() {
        root.isUserInteractionEnabled = false
        root.frame = DetailTransition.screen
        dim.backgroundColor = UIColor.black.cgColor
        dim.frame = root.bounds
        dim.opacity = 0
        root.layer.addSublayer(dim)
        pictureFrame.frame = root.bounds
        pictureFrame.clipsToBounds = true
        pictureFrame.backgroundColor = .black
        pictureFrame.layer.opacity = 0
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        pictureFrame.addSubview(picture)
        shade.contentMode = .scaleToFill
        shade.frame = root.bounds
        pictureFrame.addSubview(shade)
        placeOpen()
        root.addSubview(pictureFrame)
        spinner.color = .white
        spinner.center = CGPoint(x: 960, y: 540)
        spinner.hidesWhenStopped = true
        root.addSubview(spinner)
    }

    /// The screen as it was at the press (dimmed; Details is built under it).
    private var page: UIView?

    func install(in window: UIWindow, page snapshot: UIView? = nil) {
        if root.superview !== window { window.addSubview(root) }
        window.bringSubviewToFront(root)
        if let snapshot {
            page?.removeFromSuperview()
            snapshot.frame = root.bounds
            snapshot.isUserInteractionEnabled = false
            root.insertSubview(snapshot, at: 0)
            page = snapshot
        }
    }

    func dropPage() {
        page?.layer.mask = nil
        page?.removeFromSuperview()
        page = nil
    }

    /// Without a picture: the page fades into Details.
    func fadePage(_ duration: Double) {
        guard let page else { return }
        DetailTransition.animate(page.layer, "opacity", from: 1, to: 0, duration, DetailTransition.inOut)
    }

    func ring(_ on: Bool) { on ? spinner.startAnimating() : spinner.stopAnimating() }

    /// The picture at the opening's start, Home's framing (no animation).
    func place(_ opening: DetailTransitionOpening, shade image: UIImage?) {
        shade.image = image
        DetailTransition.place(picture.layer, opening.picture)
    }

    /// The picture at Details' framing (no animation).
    func placeOpen() {
        DetailTransition.place(picture.layer, DetailTransition.detailsPicture())
    }

    /// The zoom in: Home's framing → Details'.
    func open(from opening: DetailTransitionOpening, _ duration: Double, _ curve: CAMediaTimingFunction) {
        DetailTransition.move(picture.layer, from: opening.picture, to: DetailTransition.detailsPicture(), duration, curve)
    }

    /// Back: Details' framing → Home's.
    func close(to opening: DetailTransitionOpening, _ duration: Double, _ curve: CAMediaTimingFunction) {
        DetailTransition.move(picture.layer, from: DetailTransition.detailsPicture(), to: opening.picture, duration, curve)
    }

    func remove() {
        dropPage()
        root.removeFromSuperview()
        dim.removeAllAnimations()
        dim.opacity = 0
        for layer in [pictureFrame.layer, picture.layer] { layer.removeAllAnimations() }
        pictureFrame.layer.mask = nil
        pictureFrame.layer.opacity = 0
        placeOpen()
        picture.image = nil
        spinner.stopAnimating()
    }
}

/// Main-thread hitches per phase of a transition (LAN log, "details"): a
/// display link counts frames that came later than one refresh. The moves
/// themselves are Core Animation — this shows what the main thread did
/// meanwhile (and B waits on it: `quiet`).
@MainActor
final class FrameWatch {
    private var link: CADisplayLink?
    private var phase: String?
    private var phaseStart: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0, late = 0
    private var worst: CFTimeInterval = 0
    private var quietRun = 0
    private final class Target: NSObject {
        weak var watch: FrameWatch?
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { watch?.tick(link) } }
    }
    private let target = Target()

    init() {
        target.watch = self
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let refresh = max(link.duration, 1.0 / 120)
        if last > 0 {
            let gap = now - last
            frames += 1
            if gap > refresh * 1.5 { late += 1; quietRun = 0 } else { quietRun += 1 }
            worst = max(worst, gap)
        }
        last = now
    }

    func begin(_ name: String) {
        report()
        phase = name
        phaseStart = CACurrentMediaTime()
        frames = 0; late = 0; worst = 0
    }

    /// Until `frames` frames in a row came on time (or `within` passed).
    func quiet(frames count: Int, within: Double) async {
        quietRun = 0
        let deadline = CACurrentMediaTime() + within
        while quietRun < count, CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    func end() {
        report()
        link?.invalidate()
        link = nil
    }

    private func report() {
        guard let phase else { return }
        PlayerProbe.event("details", String(format: "frames %@: %.0f ms · %d frames · %d late · worst %.0f ms",
                                            phase, (CACurrentMediaTime() - phaseStart) * 1000, frames, late, worst * 1000))
    }
}

/// How many Details pages are up (opened through `DetailTransition`). Its
/// own object: it changes only at a push / pop, not with the animation.
@MainActor
final class DetailsOpen: ObservableObject {
    static let shared = DetailsOpen()
    @Published var depth = 0
}

/// A card in a destination row, as the controller sees it: its row and
/// its place in it.
@MainActor
/// Holding Select on a card (see `HoldMenu`): Continue Watching's menu, or
/// the title's — beside the fixed box, or the moving-focus card itself.
extension FixedFocusRowsController: HoldMenuProviding {
    func holdMenu(for focused: UIView) -> HoldMenuRequest? {
        let rowIndex: Int, itemIndex: Int
        if let poster = focused as? FixedFocusPosterCell, let rowCell = poster.rowCell {
            (rowIndex, itemIndex) = (rowCell.rowIndex, poster.itemIndex)
        } else if let tile = focused as? FixedFocusDestinationItem, let rowCell = tile.rowCell {
            (rowIndex, itemIndex) = (rowCell.rowIndex, tile.itemIndex)
        } else {
            return nil
        }
        guard let (_, entries) = menuEntries(rowIndex: rowIndex, itemIndex: itemIndex), !entries.isEmpty
        else { return nil }
        // The card at its held size (the menu lines up with its top).
        func held(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
            rect.insetBy(dx: -rect.width * (scale - 1) / 2, dy: -rect.height * (scale - 1) / 2)
        }
        if isDestination(rowIndex) {
            // The card, without its caption.
            let card = CGRect(origin: .zero, size: CGSize(width: focused.bounds.width,
                                                          height: destinationCard(rowIndex).height))
            let lift = FixedFocusMetrics.movingFocusLift
            let cell = focused as? FixedFocusDestinationCell
            let rest = focused.convert(card, to: nil)
            return HoldMenuRequest(entries: entries,
                                   anchor: held(rest, 1 + lift + FixedFocusMetrics.heldGrowth),
                                   onHeld: { [weak cell] in cell?.setHeld($0) },
                                   row: (rest, FixedFocusMetrics.destinationGap(cardWidth: card.width)))
        }
        guard box.alpha == 1 else {
            return HoldMenuRequest(entries: entries, anchor: focused.convert(focused.bounds, to: nil))
        }
        // (`frame`: the box's own transform — pressed — left out.)
        let boxRect = view.convert(CGRect(x: box.center.x - box.bounds.width / 2,
                                          y: box.center.y - box.bounds.height / 2,
                                          width: box.bounds.width, height: box.bounds.height), to: nil)
        return HoldMenuRequest(entries: entries,
                               anchor: held(boxRect, FixedFocusMetrics.boxScale + FixedFocusMetrics.heldGrowth),
                               onHeld: { [weak self] in self?.setBoxHeld($0) },
                               row: (boxRect, FixedFocusMetrics.gap))
    }
}

protocol FixedFocusDestinationItem: UIView {
    var itemIndex: Int { get }
    var rowCell: FixedFocusRowCell? { get }
}

/// A banner row's card — Search's Top Result — drawn as a small billboard:
/// the backdrop filling it, the billboard's left fade, and over it the
/// billboard's text as Home's billboard has it — the logo (or the name), the
/// chips, the facts and the tagline — at its sizes, only the logo shorter.
/// Focused: Cue's outline and a shadow.
final class FixedFocusBannerCell: UICollectionViewCell, FixedFocusDestinationItem {
    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private let card = UIView()
    private let backdrop = UIImageView()
    private let fade = CAGradientLayer()
    private let logo = LeftAlignedImageView()
    /// The title in big type, where there's no logo.
    private let name = UILabel()
    private let facts = UILabel()
    /// The tagline (TMDB) — no tagline: the name, so the block keeps its
    /// height.
    private let tagline = UILabel()
    /// The chips line (status, the first three ratings) — the billboard's
    /// own SwiftUI chips, hosted.
    private let chips = UIHostingController(rootView: AnyView(EmptyView()))
    /// Loads the facts' season count and the tagline for the shown title.
    private var extras: Task<Void, Never>?
    private let outline = UIView()
    private let shadow = UIImageView()
    /// The cards' edge (Render Lab → Card edge), as on every card.
    private let edge = UIImageView()
    private var item: MetaItem?
    private var focusedNow = false

    /// The text column: from the card's left, this wide.
    private static let textInset: CGFloat = 56
    private static let textWidth: CGFloat = 760
    private static let logoHeight: CGFloat = 96

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.image = FixedFocusCardEdge.shadowImage
        shadow.alpha = 0
        contentView.addSubview(shadow)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        contentView.addSubview(card)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        card.addSubview(backdrop)
        // The billboard's left fade: dark under the text, gone by mid-card.
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [0.92, 0.85, 0.55, 0].map { UIColor.black.withAlphaComponent($0).cgColor }
        fade.locations = [0, 0.3, 0.5, 0.75]
        card.layer.addSublayer(fade)
        name.font = .systemFont(ofSize: 52, weight: .bold)
        name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        name.numberOfLines = 2
        // As on the billboard: the facts bright, the tagline quiet and italic.
        facts.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .medium)
        facts.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        tagline.font = UIFont(descriptor: UIFont.systemFont(ofSize: FixedFocusMetrics.textSize)
            .fontDescriptor.withSymbolicTraits(.traitItalic) ?? UIFont.systemFont(ofSize: FixedFocusMetrics.textSize).fontDescriptor,
                              size: FixedFocusMetrics.textSize)
        tagline.textColor = UIColor.white.withAlphaComponent(FixedFocusText.tagline)
        chips.view.backgroundColor = .clear
        chips.safeAreaRegions = []
        for view: UIView in [logo, name, chips.view, facts, tagline] { card.addSubview(view) }
        edge.isUserInteractionEnabled = false
        card.addSubview(edge)
        // A logo arriving replaces the name: the column is laid out again.
        logo.imageView.onImage = { [weak self] in self?.setNeedsLayout() }
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outline.layer.borderWidth = FixedFocusRing.width
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        contentView.addSubview(outline)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: MetaItem, index: Int, rowCell: FixedFocusRowCell) {
        itemIndex = index
        self.rowCell = rowCell
        if self.item?.id != item.id {
            FixedFocusImages.load(item.background ?? item.poster, into: backdrop,
                                  maxDimension: StagePictureView.pictureSize.width)
            logo.image = nil
            FixedFocusImages.load(item.logo, into: logo.imageView, maxDimension: 600)
        }
        let changed = self.item?.id != item.id
        self.item = item
        name.text = item.name
        chips.rootView = rowCell.hosted(TitleChipsLine(item: item))
        if changed {
            facts.text = FixedFocusShowInfo.factsLine(item)
            tagline.text = TMDBService.knownFacts(for: item)?.tagline ?? item.name
            extras?.cancel()
            extras = Task { @MainActor [weak self] in
                async let info = FixedFocusShowInfo.load(item)
                async let facts = TMDBService.facts(for: item)
                let (size, titleFacts) = await (info, facts)
                guard let self, !Task.isCancelled, self.item?.id == item.id else { return }
                self.facts.text = FixedFocusShowInfo.factsLine(item, info: size)
                if let line = titleFacts?.tagline { self.tagline.text = line }
            }
        }
        applyFocus(isFocused)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre: they may be grown (transformed).
        for view in [card, outline] {
            view.bounds = CGRect(origin: .zero, size: bounds.size)
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        shadow.bounds = CGRect(origin: .zero, size: bounds.insetBy(dx: -FixedFocusCardEdge.shadowPad,
                                                                    dy: -FixedFocusCardEdge.shadowPad).size)
        shadow.center = CGPoint(x: bounds.midX, y: bounds.midY)
        edge.image = FixedFocusCardEdge.rim
        edge.frame = card.bounds
        // A WINDOW onto the full-screen picture: the backdrop at the size and
        // place Details (and Home's billboard) give it, seen through the
        // card — the very same picture.
        let origin = rowCell?.restingCardOrigin() ?? .zero
        let drift = StagePictureView.drift
        backdrop.frame = CGRect(x: -drift - origin.x, y: -origin.y,
                                width: StagePictureView.pictureSize.width + 2 * drift,
                                height: StagePictureView.pictureSize.height)
        fade.frame = card.bounds
        // The text column, centred on the card's height, in the billboard's
        // order and rhythm: the logo (or the name), the chips, the facts,
        // the tagline.
        let x = Self.textInset, width = Self.textWidth
        let hasLogo = logo.image != nil
        name.isHidden = hasLogo
        logo.isHidden = !hasLogo
        let titleHeight = hasLogo ? Self.logoHeight
            : name.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let line = FixedFocusMetrics.factsHeight
        let gap = FixedFocusMetrics.factsOffset - 30   // the billboard's line step
        let chipsGap = gap + FixedFocusBillboardText.chipsGap
        let total = titleHeight + FixedFocusBillboardText.logoToChips + line + chipsGap + line + gap + 30
        var y = max(24, (bounds.height - total) / 2)
        logo.frame = CGRect(x: x, y: y, width: width * 0.7, height: Self.logoHeight)
        name.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + FixedFocusBillboardText.logoToChips
        chips.view.frame = CGRect(x: x, y: y, width: width, height: line)
        y += line + chipsGap
        facts.frame = CGRect(x: x, y: y, width: width, height: line)
        y += line + gap
        tagline.frame = CGRect(x: x, y: y, width: width, height: 30)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.applyFocus(focused)
        } completion: { _ in }
    }

    /// (No lift: the window stays exactly where the picture is.)
    private func applyFocus(_ focused: Bool) {
        focusedNow = focused
        outline.alpha = focused ? 1 : 0
        shadow.alpha = focused ? 1 : 0
    }
}

/// The chips line on its own — the status badge (optional), then the first
/// ratings — loading the ratings itself: the Top Result's banner, and the
/// window opening from it into Details.
struct TitleChipsLine: View {
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let item: MetaItem
    var includesStatus = true
    @State private var ratings: MDBListRatings?

    var body: some View {
        HStack(spacing: 10) {
            if includesStatus, let status = FixedFocusShowInfo.status(item) {
                TitleBadge(text: status)
            }
            FixedFocusBillboardText.ratingsChips(ratings, settings: mdblist.settings, item: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.id) {
            ratings = await MDBListService.ratings(for: item, settings: mdblist.settings)
        }
    }
}

/// Holding Select on a Continue Watching card: the system's context menu
/// (lifting the card, blurring the rest, in Liquid Glass), with these.
enum ContinueMenuAction: CaseIterable {
    case details, startOver, chooseSource, markWatched, remove

    var title: String {
        switch self {
        case .details: return "Go to Details"
        case .startOver: return "Start Over"
        case .chooseSource: return "Choose Source"
        case .markWatched: return "Mark as Watched"
        case .remove: return "Remove from Continue Watching"
        }
    }

    var icon: String {
        switch self {
        case .details: return "info.circle"
        case .startOver: return "gobackward"
        case .chooseSource: return "list.and.film"
        case .markWatched: return "checkmark.circle"
        case .remove: return "xmark"
        }
    }
}

private extension View {
    /// Into a rect of the screen (top-left origin).
    func place(_ rect: CGRect, alignment: Alignment = .center) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// An image view that draws its picture aspect-fit to its LEFT edge (a
/// logo in a text column), not centred. Load into `imageView`.
final class LeftAlignedImageView: UIView {
    /// Tells its holder whenever a picture arrives (`onImage`).
    final class Picture: UIImageView {
        var onImage: () -> Void = {}
        override var image: UIImage? {
            didSet { superview?.setNeedsLayout(); onImage() }
        }
    }
    let imageView = Picture()
    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            imageView.frame = .zero
            return
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        // Left, and down to the bottom (it sits on the facts line).
        imageView.frame = CGRect(x: 0, y: bounds.height - fitted.height, width: fitted.width, height: fitted.height)
    }
}

/// A destination row's card: its picture with Cue's focus outline (or
/// tvOS's lift — `FixedFocusMetrics.destinationSystemLift`); under it the
/// name and a second line (when it was saved, how many catalogs).
final class FixedFocusDestinationCell: UICollectionViewCell, FixedFocusDestinationItem {
    private(set) var itemIndex = 0
    private(set) weak var rowCell: FixedFocusRowCell?
    private let picture = UIImageView()
    /// The card's edge (Render Lab → Card edge) and the focus outline, as on
    /// the other rows' cards.
    private let edge = UIImageView()
    private let outline = UIView()
    private let outlineLight = UIImageView()
    /// The lift's scale the outline is sized to (see `setFocused`).
    private var outlineScale: CGFloat = 1
    private let name = UILabel()
    private let detail = UILabel()
    /// A logo row's logo: fitted inside the picture's light plate.
    private let logo = UIImageView()
    static let logoInset = CGSize(width: 34, height: 30)

    /// Darkened (0…1 black over the picture — not see-through).
    var dim: CGFloat = 0 {
        didSet { if dim != oldValue { dimCover.alpha = dim } }
    }
    private let dimCover = UIView()

    /// The name and second line under the card (its row focused).
    func setCaptionShown(_ shown: Bool) {
        name.alpha = shown ? 1 : 0
        detail.alpha = shown ? 1 : 0
    }

    /// Continue Watching's state (episode, progress, time left), if it is one,
    /// over the picture's lower half darkened (as the fixed-focus card).
    private let state = FixedFocusProgressView()
    private let stateShade = CAGradientLayer()
    /// The captions' gap below the card (larger while it's grown).
    private var captionGap: NSLayoutConstraint!
    private var cardHeight: CGFloat = 0
    private var shown: String?
    private static var lift: Bool { FixedFocusMetrics.destinationSystemLift }

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.adjustsImageWhenAncestorFocused = Self.lift
        picture.contentMode = .scaleAspectFill
        if !Self.lift {
            picture.clipsToBounds = true
            picture.layer.cornerRadius = Spotlight.cornerRadius
            picture.layer.cornerCurve = .continuous
        }
        contentView.addSubview(picture)
        edge.isUserInteractionEnabled = false
        picture.addSubview(edge)
        stateShade.colors = [UIColor.clear.cgColor,
                             UIColor.black.withAlphaComponent(Spotlight.logoScrimOpacity).cgColor]
        stateShade.startPoint = CGPoint(x: 0.5, y: 0.5)
        stateShade.endPoint = CGPoint(x: 0.5, y: 1)
        stateShade.isHidden = true
        picture.layer.insertSublayer(stateShade, at: 0)
        state.alpha = 0
        state.isUserInteractionEnabled = false
        picture.addSubview(state)
        logo.contentMode = .scaleAspectFit
        logo.isHidden = true
        picture.addSubview(logo)
        dimCover.backgroundColor = .black
        dimCover.alpha = 0
        dimCover.isUserInteractionEnabled = false
        picture.addSubview(dimCover)
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = UIColor.white.cgColor
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.addSubview(outlineLight)
        outline.alpha = 0
        contentView.addSubview(outline)
        // Like the fixed box's text (see its `InfoPage`), a little smaller: one size
        // for both lines, the second dimmer.
        name.font = .systemFont(ofSize: FixedFocusMetrics.captionSize, weight: .regular)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: FixedFocusMetrics.captionSize, weight: .regular)
        detail.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        for label in [name, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        // Below the picture's FOCUSED frame: a lift pushes them down.
        captionGap = name.topAnchor.constraint(equalTo: picture.focusedFrameGuide.bottomAnchor,
                                               constant: FixedFocusMetrics.infoGap)
        NSLayoutConstraint.activate([
            captionGap,
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FixedFocusMetrics.textIndent),
            name.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            name.heightAnchor.constraint(equalToConstant: 30),
            detail.topAnchor.constraint(equalTo: name.topAnchor, constant: FixedFocusMetrics.captionLineOffset),
            detail.heightAnchor.constraint(equalToConstant: FixedFocusMetrics.factsHeight),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
        ])
        applyFocus(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frames: they may be grown (transformed).
        let card = CGRect(x: 0, y: 0, width: bounds.width, height: cardHeight)
        for view in [picture, outline] {
            view.bounds = CGRect(origin: .zero, size: card.size)
            view.center = CGPoint(x: card.midX, y: card.midY)
        }
        outline.bounds = CGRect(origin: .zero, size: CGSize(width: card.width * outlineScale,
                                                            height: card.height * outlineScale))
        edge.image = Self.lift ? nil : FixedFocusCardEdge.rim
        edge.frame = picture.bounds
        dimCover.frame = picture.bounds
        logo.frame = picture.bounds.insetBy(dx: Self.logoInset.width, dy: Self.logoInset.height)
        // (As on Continue Watching's fixed-focus cards.)
        state.frame = CGRect(x: 24, y: card.height - 22 - 34, width: card.width - 48, height: 34)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stateShade.frame = picture.bounds
        CATransaction.commit()
        let lit = FixedFocusCardEdge.focusLight
        outline.layer.borderWidth = lit ? 0 : FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outlineLight.image = lit ? FixedFocusCardEdge.focusImage : nil
        outlineLight.frame = outline.bounds
    }

    /// The card itself, without its caption (in the cell).
    var cardFrame: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: cardHeight) }


    func configure(_ item: MetaItem, subtitle: String?, index: Int, rowCell: FixedFocusRowCell?, card: CGSize,
                   progress: WatchProgress? = nil, cardState: FixedFocusCardState? = nil, isLogo: Bool = false) {
        itemIndex = index
        self.rowCell = rowCell
        cardHeight = card.height
        // (A reused cell: its last focus look gone.)
        applyFocus(isFocused)
        name.text = item.name
        // Continue Watching (moving focus): the episode's title under it, and
        // the episode, bar and time left on the darkened picture.
        detail.text = progress?.episodeTitle ?? subtitle
        // (Or a state line given as such — Details' episodes.)
        if let cardState { state.show(cardState) } else { state.show(progress) }
        let hasState = progress != nil || cardState != nil
        state.alpha = hasState ? 1 : 0
        stateShade.isHidden = !hasState
        setNeedsLayout()
        let art = card.width > card.height ? (item.background ?? item.poster) : (item.poster ?? item.background)
        let key = "\(item.id)|\(art ?? "")|\(Int(card.width))"
        guard key != shown else { return }
        shown = key
        // A logo: on a light plate, fitted with room around it.
        logo.isHidden = !isLogo
        picture.backgroundColor = isLogo ? UIColor(white: 0.9, alpha: 1) : nil
        if isLogo {
            picture.image = nil
            logo.image = nil
            if let art { FixedFocusImages.load(art, into: logo, maxDimension: max(card.width, card.height)) }
            return
        }
        // (No picture: the title's name — a person's initials.)
        let placeholder = item.type == "person"
            ? item.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            : item.name
        picture.image = TileArt.placeholder(size: card, text: art == nil ? placeholder : nil)
        guard let art else { return }
        if Self.lift {
            // The system's effect needs the corners in the picture itself.
            TileArt.load(art, size: card, contain: false) { [weak self] image in
                guard let self, self.shown == key, let image else { return }
                self.picture.image = image
            }
        } else {
            FixedFocusImages.load(art, into: picture, maxDimension: max(card.width, card.height))
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // Focus into a hold menu (`HoldMenu`): the card stays lifted.
        let focused = isFocused || (HoldMenu.shared.isOpen && context.previouslyFocusedView === self)
        guard !Self.lift else {
            coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
            return
        }
        // On Home's curve and timing, with the row's scroll.
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.applyFocus(focused)
            self.layoutIfNeeded()
        } completion: { _ in }
    }

    /// Select pressed / held: the card sinks a little (back on release, or
    /// when the menu closes).
    private var pressed = false
    private var focusedNow = false
    /// Its hold menu open: a little larger than lifted.
    private var held = false
    func setHeld(_ held: Bool) {
        guard held != self.held else { return }
        self.held = held
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.applyFocus(self.focusedNow)
        }
    }
    func setPressed(_ pressed: Bool) {
        guard pressed != self.pressed else { return }
        self.pressed = pressed
        UIView.animate(withDuration: pressed ? 0.12 : 0.2, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.applyFocus(self.focusedNow)
        }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(true) }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesCancelled(presses, with: event)
    }

    private func applyFocus(_ focused: Bool) {
        focusedNow = focused
        name.textColor = UIColor.white.withAlphaComponent(focused ? FixedFocusText.primary : 0.7)
        guard !Self.lift else { return }
        // Grown and outlined — the captions step down with it.
        let lift = FixedFocusMetrics.movingFocusLift
        let grows = lift > 0
        // Pressed: a little less lifted (as the fixed box sinks, `pressScale`).
        let scale = focused && grows
            ? 1 + lift - (pressed ? 1 - FixedFocusMetrics.pressScale : 0) + (held ? FixedFocusMetrics.heldGrowth : 0)
            : 1
        let grown = CGAffineTransform(scaleX: scale, y: scale)
        picture.transform = grown
        // The outline SIZED with the card, not scaled: its line stays the
        // fixed box's width (scaled, it grew thicker with the lift).
        outlineScale = scale
        outline.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width * scale, height: cardHeight * scale))
        outline.layer.cornerRadius = Spotlight.cornerRadius * scale
        outline.alpha = focused ? 1 : 0
        // The caption keeps its distance to the card at its FOCUSED size:
        // pressing or holding (brief, the card's own feedback) doesn't move it.
        let focusedScale = focused && grows ? 1 + lift : 1
        captionGap.constant = FixedFocusMetrics.infoGap + cardHeight * (focusedScale - 1) / 2
        if focused { superview?.bringSubviewToFront(self) }
    }

}

/// A poster cell: a WINDOW onto two fixed-size images — the portrait
/// poster and the box-sized backdrop (with logo). Growing opens the window;
/// nothing is stretched. Backdrop and logo load only once it grows.
final class FixedFocusPosterCell: UICollectionViewCell {
    /// Set by the controller while it starts an Up/Down movement.
    static var vertical: (direction: CGFloat, duration: Double)?

    // Select pressed / held: the box (which shows this card) sinks a little.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { rowCell?.setBoxPressed(true) }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { rowCell?.setBoxPressed(false) }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { rowCell?.setBoxPressed(false) }
        super.pressesCancelled(presses, with: event)
    }

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
    /// Continue Watching: a landscape card (backdrop always), with its state.
    private var landscape = false
    private let state = FixedFocusProgressView()

    /// Darkened (0…1 black over the card — not see-through).
    var dim: CGFloat = 0 {
        didSet { if dim != oldValue { dimCover.alpha = dim } }
    }
    private let dimCover = UIView()

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
        // The card's edge (on top of its pictures) and its shadow (under
        // the card, outside it) — Render Lab → Card edge.
        edge.isUserInteractionEnabled = false
        contentView.addSubview(edge)
        dimCover.backgroundColor = .black
        dimCover.alpha = 0
        dimCover.isUserInteractionEnabled = false
        contentView.addSubview(dimCover)
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outline.layer.borderWidth = FixedFocusRing.width
        // (The top bar's light — as on the box: see `FixedFocusCardEdge`.)
        outline.addSubview(outlineLight)
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        addSubview(outline)
        name.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .regular)
        name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        facts.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .regular)
        facts.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        info.addSubview(name)
        info.addSubview(facts)
        info.addSubview(chips)
        info.alpha = 0
        info.isUserInteractionEnabled = false
        addSubview(info)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimCover.frame = contentView.bounds
        // Fixed sizes, anchored left: the cell's width only reveals.
        poster.frame = CGRect(x: 0, y: 0, width: FixedFocusMetrics.posterWidth, height: cardHeight)
        backdrop.frame = CGRect(x: 0, y: 0, width: landscapeWidth, height: cardHeight)
        shade.frame = backdrop.bounds
        logo.frame = CGRect(x: Spotlight.logoInset,
                            y: cardHeight - Spotlight.logoInset - cardHeight * 0.28,
                            width: landscapeWidth * 0.55, height: cardHeight * 0.28)
        outline.frame = bounds
        let lit = FixedFocusCardEdge.focusLight
        outline.layer.borderWidth = lit ? 0 : FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outlineLight.image = lit ? FixedFocusCardEdge.focusImage : nil
        outlineLight.frame = outline.bounds
        edge.image = FixedFocusCardEdge.rim
        // Around what the card shows: the poster — not the box-wide gap a
        // grown cell under the fixed box is (its hairline trailed into the
        // box while sliding there) — or, showing the box itself, all of it.
        let card = landscape || showsBox ? contentView.bounds : poster.frame
        edge.frame = card
        contentView.bringSubviewToFront(edge)
        state.frame = CGRect(x: 24, y: cardHeight - 22 - 34,
                             width: landscapeWidth - 48, height: 34)
        // (Bounds and centre: it may be counter-scaled — see `apply`.)
        let infoRect = CGRect(x: FixedFocusMetrics.textIndent, y: cardHeight + FixedFocusMetrics.infoGap,
                              width: landscapeWidth, height: FixedFocusMetrics.infoHeight)
        info.bounds = CGRect(origin: .zero, size: infoRect.size)
        info.center = CGPoint(x: infoRect.midX, y: infoRect.midY)
        applyInfoCounterScale()
        chips.frame = CGRect(x: 0, y: FixedFocusChipsView.y, width: info.bounds.width,
                             height: FixedFocusMetrics.factsHeight)
        name.frame = CGRect(x: 0, y: 0, width: info.bounds.width, height: 30)
        facts.frame = CGRect(x: 0, y: 36, width: info.bounds.width, height: FixedFocusMetrics.factsHeight)
    }

    func configure(_ item: MetaItem, index: Int, rowCell: FixedFocusRowCell,
                   progress: WatchProgress?, landscape: Bool, invisible: Bool = false,
                   cardHeight: CGFloat = FixedFocusMetrics.height) {
        itemIndex = index
        self.cardHeight = cardHeight
        self.rowCell = rowCell
        self.item = item
        self.landscape = landscape
        self.invisible = invisible
        contentView.isHidden = invisible
        backdropFor = nil
        if invisible {
            // The billboard's focus target: nothing to show or load.
            for view in [poster, backdrop, logo] { FixedFocusImages.load(nil, into: view, maxDimension: 0) }
            setOutline(false)
            info.alpha = 0
            return
        }
        setNeedsLayout()
        if landscape {
            // Landscape: the art right away. Continue Watching: its art is
            // the still or the backdrop (Settings → Episode thumbnails,
            // already applied to the item), no logo, the state line is the
            // card's only text; other rows: the logo.
            backdropFor = item.id
            shade.isHidden = item.type == "collection"
            FixedFocusImages.load(item.background ?? item.poster,
                                  into: backdrop, maxDimension: landscapeWidth)
            FixedFocusImages.load(progress == nil ? item.logo : nil, into: logo,
                                  maxDimension: landscapeWidth * 0.55)
            FixedFocusImages.load(nil, into: poster, maxDimension: 0)
            state.show(progress)
            state.alpha = progress == nil ? 0 : 1
            name.text = item.name
            facts.text = progress?.episodeTitle
                ?? FixedFocusShowInfo.factsLine(item)
            return
        }
        state.alpha = 0
        shade.isHidden = false
        FixedFocusImages.load(item.poster ?? item.background, into: poster,
                              maxDimension: FixedFocusMetrics.height)
        FixedFocusImages.load(nil, into: backdrop, maxDimension: 0)
        FixedFocusImages.load(nil, into: logo, maxDimension: 0)
        name.text = item.name
        facts.text = FixedFocusShowInfo.factsLine(item)
    }

    /// The cell's outline.
    private func setOutline(_ on: Bool) {
        outline.alpha = on ? 1 : 0
    }

    /// The billboard's cells: focus targets only, nothing drawn.
    private var invisible = false
    /// The card's height (the landscape picture's width follows).
    private var cardHeight = FixedFocusMetrics.height
    private var landscapeWidth: CGFloat { FixedFocusMetrics.landscapeWidth(height: cardHeight) }
    /// The third line under the grown cell (as under the box).
    private let chips = FixedFocusChipsView()

    /// Left of the box: dimmed (Render Lab → Previous poster).
    func setPast(_ past: Bool) {
        self.past = past
        applyAlpha()
    }

    /// Waiting under the billboard: not shown (still focusable — it's the
    /// cell's content that is transparent, not the cell).
    func setConcealed(_ concealed: Bool) {
        self.concealed = concealed
        applyAlpha()
    }

    private var past = false
    private var concealed = false

    private func applyAlpha() {
        contentView.alpha = concealed || underPressedBox ? 0 : past ? FixedFocusMetrics.previousAlpha : 1
    }

    /// Showing the box itself (grown, not under the fixed box).
    private var showsBox = false

    /// The layout's scale for this card (the grown title at the lifted box's
    /// size). Its info keeps its size and sits where the box's does — the
    /// card's own scale undone, moved down by the overhang — or at the
    /// handover to the box it jumped back.
    private var layoutScale: CGFloat = 1
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        layoutScale = layoutAttributes.transform.a == 0 ? 1 : layoutAttributes.transform.a
        applyInfoCounterScale(size: layoutAttributes.size)
    }

    private func applyInfoCounterScale(size: CGSize? = nil) {
        let s = layoutScale
        guard s != 1 else { info.transform = .identity; return }
        let size = size ?? bounds.size
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let overhang = cardHeight * (s - 1) / 2
        // Net for the info: moved down by `overhang`, unscaled.
        let tx = -(s - 1) * (info.center.x - centre.x) / s
        let ty = (overhang - (s - 1) * (info.center.y - centre.y)) / s
        info.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: 1 / s, y: 1 / s)
    }
    /// Under the pressed fixed box (it shrinks a little): hidden, or its
    /// edges showed around the box.
    func setUnderPressedBox(_ under: Bool) {
        underPressedBox = under
        applyAlpha()
    }
    private var underPressedBox = false

    /// The card's rim (see `FixedFocusCardEdge`).
    private let edge = UIImageView()
    private let outlineLight = UIImageView()

    /// Grown: the backdrop shows — unless the fixed box shows it
    /// (`contentHidden`), then the cell is just a box-wide gap. The info
    /// shows under every grown cell (it travels with its title).
    func setGrown(_ grown: Bool, contentHidden: Bool) {
        if invisible { return }
        if grown, let item { chips.show(item) }
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
        if shows != showsBox { showsBox = shows; setNeedsLayout() }
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
    /// The cards' width (posters; landscape: box-wide) and height.
    var cardWidth: () -> CGFloat = { FixedFocusMetrics.posterWidth }
    var cardHeight: () -> CGFloat = { FixedFocusMetrics.height }
    private var frames: [CGRect] = []
    private var contentWidth: CGFloat = 0
    private var height = FixedFocusMetrics.height

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let wide = wideIndex()
        let card = cardWidth()
        height = cardHeight()
        let pitch = card + FixedFocusMetrics.gap
        let extra = FixedFocusMetrics.boxWidth - card
        // A lifted box (Render Lab) overhangs its spot: its neighbours step
        // aside by as much, keeping the usual gap.
        let overhang = FixedFocusMetrics.boxWidth * (FixedFocusMetrics.boxScale - 1) / 2
        frames = (0..<count).map { i in
            var x = Self.overscan + FixedFocusMetrics.inset + CGFloat(i) * pitch
            if let wide, i > wide { x += extra + overhang }
            if let wide, i < wide { x -= overhang }
            let width = i == wide ? FixedFocusMetrics.boxWidth : card
            return CGRect(x: x, y: 0, width: width, height: height)
        }
        // Room after the last title so it too can reach the spot.
        contentWidth = (frames.last?.maxX ?? 0) + 1920 + 2 * Self.overscan
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: height)
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
        // The grown title at the box's size (lifted, Render Lab): with its
        // size and place, so opening into the box and growing are one move.
        if i == wideIndex() {
            let scale = FixedFocusMetrics.boxScale
            if scale != 1 {
                a.transform = CGAffineTransform(scaleX: scale, y: scale)
                a.zIndex = 1
            }
        }
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
    /// The focused row's name, on screen.
    var rowTop: () -> CGFloat = { FixedFocusMetrics.rowTop }
    /// How much lower than usual the focused row stands (the row under the
    /// billboard): `rowTop()` includes it.
    var rowDrop: () -> CGFloat = { 0 }
    /// See `FixedFocusRows.rigidRest`.
    var rigidRest: () -> CGFloat? = { nil }
    /// The billboard's own distance up at a depth, if it has one.
    var billboardUp: (Int) -> CGFloat? = { _ in nil }
    /// A row's cards' height (one size, but for a side-info row).
    var cardHeight: (Int) -> CGFloat = { _ in FixedFocusMetrics.height }
    /// A row's cards this much lower under its name (a line under it).
    var titleExtra: (Int) -> CGFloat = { _ in 0 }
    /// How much of the rows above and below shows.
    var peeks: () -> (above: CGFloat, below: CGFloat) = {
        (FixedFocusMetrics.aboveVisible, FixedFocusMetrics.belowVisible)
    }
    /// How far a row's drawing reaches beyond its name and cards (a
    /// collection's panel): rows keep that much more room between them.
    var reach: (Int) -> (above: CGFloat, below: CGFloat) = { _ in (0, 0) }
    /// How much of a row's height is below its cards (a destination row's
    /// captions): the row above shows its CARDS' lower part, as any row.
    var belowCards: (Int) -> CGFloat = { _ in 0 }
    /// How far a focused row draws, from its anchor (its name; a panel's
    /// top) to the end of what shows under its cards (the fixed box's info,
    /// captions, a panel's edge): the next row's name the peek gap below it.
    var drawnHeight: (Int) -> CGFloat = { _ in
        FixedFocusMetrics.titleHeight + FixedFocusMetrics.height + FixedFocusMetrics.infoGap + FixedFocusMetrics.infoHeight
    }
    /// The row below always shows at least this much of its cards (a tall
    /// focused row pushes it down only so far).
    static let minimumPeek: CGFloat = 70
    /// A custom row's content height from its anchor (nil: not one, or not
    /// measured — see `FixedFocusCustomRow.contentHeight`). Coming into it,
    /// the rows only scroll as far as needed to show it all.
    var customContent: (Int) -> CGFloat? = { _ in nil }
    /// The Featured row (the billboard), if any.
    var featuredRow: () -> Int? = { nil }
    /// Billboard in focus, scrolling to or from the rows: the rows below are
    /// AWAY — at their places with the next row in focus, a whole scroll
    /// lower (off the screen), so they move exactly as far as the picture.
    /// At rest under the billboard they wait at the bottom edge instead.
    var belowAway: () -> Bool = { false }
    /// How far everything scrolls between the billboard and the rows: the
    /// picture, all the way off the screen.
    static let billboardTravel: CGFloat = StagePictureView.pictureSize.height
    /// Under the billboard the next row waits with its (hidden) cards just
    /// on the screen at the bottom edge: enough for tvOS to focus them.
    static let restingCardsOnScreen: CGFloat = 2
    /// The next row's name on the billboard sits here (bottom left, in line
    /// with the dots) — see the controller's `titleLift`.
    static var nextNameY: CGFloat {
        let dotsMid = TitleBlock.hintY(screenHeight: 1080) + SectionHint.size * 1.3 / 2
        return (dotsMid - FixedFocusMetrics.titleLine / 2).rounded()
    }
    /// One row below the billboard its lower edge still shows this far down
    /// (never below the focused row's name, so the rows' entry stays off
    /// the screen).
    static func topPeek(focusY: CGFloat) -> CGFloat { FixedFocusMetrics.billboardTopPeek }
    /// How far everything moves between the billboard and the rows: the
    /// picture, the rows and the billboard's text alike.
    static func scrollDistance(focusY: CGFloat) -> CGFloat { billboardTravel - topPeek(focusY: focusY) }
    /// How far the billboard has gone up with focus `depth` rows below it:
    /// ONE formula for its picture (the Featured row) and its text and dots
    /// (SwiftUI, above the rows), so they move as one.
    static func billboardScroll(depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        return scrollDistance(focusY: FixedFocusMetrics.rowTop)
            + (depth > 1 ? FixedFocusMetrics.billboardStripDrop + CGFloat(depth - 1) * FixedFocusMetrics.rowPitch : 0)
    }
    /// A RIGID billboard's (see `FixedFocusRows.rigidRest`): the first row
    /// from its rest up to the spot, then a row at a time.
    static func billboardScroll(depth: Int, rigidRest rest: CGFloat, rowTop: CGFloat = FixedFocusMetrics.rowTop) -> CGFloat {
        guard depth > 0 else { return 0 }
        return rest - rowTop + CGFloat(depth - 1) * FixedFocusMetrics.rowPitch
    }
    /// The list extends this far beyond the screen, above and below (see
    /// the controller's `viewDidLayoutSubviews`); rows are placed in screen
    /// coordinates shifted by it.
    static let overscan: CGFloat = 1100
    private var frames: [CGRect] = []

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let f = focusedRow()
        let heights = (0..<count).map { FixedFocusMetrics.titleHeight + titleExtra($0) + cardHeight($0) }
        let focusY = rowTop()
        // (The list's own height: the whole screen on Home.)
        let screen = (collectionView?.bounds.height).map { $0 - 2 * Self.overscan } ?? 1080
        let peek = peeks()
        let reaches = (0..<count).map(reach)
        /// The lowest the row below the focused one may start: its name and
        /// the minimum peek of its cards still on the screen.
        let lowestBelow = screen - FixedFocusMetrics.titleHeight - Self.minimumPeek
        /// Every row's top with row `f` focused: the focused one at the spot;
        /// the next the same gap below the end of what the focused one draws
        /// (whatever its height — so the peek varies, the gap doesn't), but
        /// never lower than its minimum peek; the ones after it the same gap
        /// apart; the one before peeking down from the top, the rest a row
        /// apart above it — each row's reach (a panel's) included, so no
        /// drawing overlaps the next. A row's ANCHOR
        /// is the top of what it draws (its name; a collection's panel).
        func tops(_ f: Int) -> [CGFloat] {
            var y = [CGFloat](repeating: 0, count: count)
            guard count > 0 else { return y }
            let f = min(max(f, 0), count - 1)
            y[f] = focusY + reaches[f].above
            if f + 1 < count {
                let after = focusY + drawnHeight(f) + FixedFocusMetrics.peekGap
                y[f + 1] = min(after, lowestBelow) + reaches[f + 1].above
            }
            // Further down: the same gap below each row (its height, captions
            // in) — a row coming up to be next doesn't move again.
            if f + 2 < count {
                for r in (f + 2)..<count {
                    y[r] = y[r - 1] + heights[r - 1] + reaches[r - 1].below + FixedFocusMetrics.peekGap
                        + reaches[r].above
                }
            }
            if f > 0 { y[f - 1] = peek.above - heights[f - 1] - reaches[f - 1].below + belowCards(f - 1) }
            // Further up: the same gap above each row, below the cards of the
            // one over it (out of focus, its captions don't show).
            if f > 1 {
                for r in stride(from: f - 2, through: 0, by: -1) {
                    y[r] = y[r + 1] - reaches[r + 1].above - FixedFocusMetrics.peekGap - reaches[r].below
                        - heights[r] + belowCards(r)
                }
            }
            return y
        }
        let focusedTops = tops(f)
        func normal(_ r: Int, _ f: Int) -> CGFloat {
            f == self.focusedRow() ? focusedTops[r] : tops(f)[r]
        }
        let featured = featuredRow()
        /// Focus in a custom row (Details' About), from a row above that
        /// isn't the billboard: the rows as with that row in focus, all moved
        /// up by one distance — just enough that its content ends
        /// `customBottomGap` above the screen's bottom (never past the usual
        /// spot; not at all if it already shows).
        let customScroll: (tops: [CGFloat], by: CGFloat)? = {
            guard count > 0, f > 0, f < count, featured != f - 1, let content = customContent(f) else { return nil }
            let before = tops(f - 1)
            let target = screen - FixedFocusMetrics.customBottomGap - content
            let top = min(before[f], max(focusY, target))
            return (before, before[f] - top)
        }()
        frames = (0..<count).map { r in
            let y: CGFloat
            if let featured, f == featured, r != featured {
                // Under the billboard, as with the next row in focus: AWAY a
                // whole scroll lower (the picture's distance: one page), or
                // at rest with the next row's hidden cards just touching the
                // bottom edge (see the controller's `rowConcealed`).
                let next = featured + 1
                if let rest = rigidRest() {
                    // Rigid: the rows as with the next one in focus, lower
                    // by exactly the scroll.
                    y = normal(r, next) + rest - focusY
                } else if belowAway() {
                    y = normal(r, next) + Self.billboardScroll(depth: 1)
                } else {
                    let cardsTop = screen - Self.restingCardsOnScreen
                    y = normal(r, next) + cardsTop - FixedFocusMetrics.titleHeight - reaches[next].above - focusY
                }
            } else if let featured, r == featured, f > featured {
                // Scrolled away above: the picture and its edge off the top
                // — one row down, its lower edge still shows (as the row
                // above does).
                // (From the usual spot, not the dropped one: the picture's
                // frame is laid out from it.)
                y = focusY - rowDrop() - (billboardUp(f - featured) ?? rigidRest().map {
                    Self.billboardScroll(depth: f - featured, rigidRest: $0, rowTop: focusY)
                } ?? Self.billboardScroll(depth: f - featured))
            } else if let scroll = customScroll {
                // Into a custom row: the rows as they were, scrolled up just
                // far enough to show it all.
                y = scroll.tops[r] - scroll.by
            } else {
                y = normal(r, f)
            }
            return CGRect(x: 0, y: y + Self.overscan, width: 1920, height: heights[r])
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
        // The billboard's picture lies under the rows scrolling over it.
        if r == featuredRow() { a.zIndex = -1 }
        return a
    }
}




/// A collection row's panel: one wide rounded plate behind its name and
/// tiles, in the focused folder's colour (deep, with a lighter edge) — the
/// row reads as a place to go into, not a feed. The tiles slide under its
/// edges (the row cell clips them to it).
final class FixedFocusPanelView: UIView {
    /// In the row cell: around the name, the tiles and the info under the
    /// box, from a little left of the box almost to the right edge.
    static func frame(cardHeight: CGFloat) -> CGRect {
        let reach = FixedFocusMetrics.panelReach
        let x = FixedFocusMetrics.inset - FixedFocusMetrics.panelPad
        return CGRect(x: x, y: -reach.above, width: 1920 - 2 * x,
                      height: reach.above + FixedFocusMetrics.titleHeight + cardHeight + reach.below)
    }

    private var tintedFor: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = FixedFocusMetrics.panelRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        apply(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The colour of the folder in front (its art's); neutral until known.
    func tint(for url: String?, animated: Bool) {
        guard let url, url != tintedFor else { return }
        tintedFor = url
        FixedFocusColors.color(for: url) { [weak self] color in
            guard let self, self.tintedFor == url else { return }
            if animated {
                UIView.animate(withDuration: 0.45, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.apply(color)
                }
            } else {
                self.apply(color)
            }
        }
    }

    private func apply(_ color: UIColor?) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let color, color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            backgroundColor = UIColor(white: 1, alpha: 0.06)
            layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
            return
        }
        backgroundColor = UIColor(hue: h, saturation: min(s, 0.75), brightness: 0.26, alpha: 0.92)
        layer.borderColor = UIColor(hue: h, saturation: min(s, 0.6), brightness: 0.62, alpha: 0.7).cgColor
    }
}

/// The third line under the box — where the billboard has its badge and
/// ratings: the series' status (AIRING / RETURNING / ENDED + year — see
/// `FixedFocusShowInfo.status`) and ONE rating (IMDb's, from the catalog).
/// Chips in the badge's shape (`TitleBadge`, `MDBListRatingsRow`'s chips).
final class FixedFocusChipsView: UIView {
    /// Below the facts line, one line step down — and the billboard's extra
    /// room above its chips (`chipsGap`): a plain step left them crowded.
    static let y: CGFloat = 36 + FixedFocusMetrics.factsOffset + FixedFocusBillboardText.chipsGap

    private final class Chip: UIView {
        let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 7
            layer.cornerCurve = .continuous
            layer.borderWidth = 1.25
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        func set(_ text: NSAttributedString, border: UIColor) {
            label.attributedText = text
            layer.borderColor = border.cgColor
            label.sizeToFit()
            // The badge's box: 10 pt at the sides, 21 + 2 × 4 pt tall.
            bounds.size = CGSize(width: label.bounds.width + 20, height: 29)
            label.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private let status = Chip()
    private let rating = Chip()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(status)
        addSubview(rating)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func text(_ parts: [(String, UIColor)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, color) in parts {
            result.append(NSAttributedString(string: string, attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold), .kern: 0.5, .foregroundColor: color,
            ]))
        }
        return result
    }

    func show(_ item: MetaItem) {
        let white = UIColor.white.withAlphaComponent(0.85)
        if let known = FixedFocusShowInfo.status(item) {
            status.set(Self.text([(known, white)]), border: UIColor.white.withAlphaComponent(0.4))
            status.isHidden = false
        } else {
            status.isHidden = true
        }
        if let score = item.imdbRating, !score.isEmpty {
            let imdb = UIColor(CuePrimitives.imdb)
            rating.set(Self.text([("IMDb ", imdb), (score, white)]), border: imdb.withAlphaComponent(0.7))
            rating.isHidden = false
        } else {
            rating.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for chip in [status, rating] where !chip.isHidden {
            chip.frame.origin = CGPoint(x: x, y: (bounds.height - chip.bounds.height) / 2)
            x = chip.frame.maxX + 10
        }
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
            label.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
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

    /// A state given as such (Details' episodes): the label left, a bar (in
    /// progress) or nothing, the text right.
    func show(_ state: FixedFocusCardState) {
        episode.text = state.label
        remaining.text = state.right
        fraction = CGFloat(state.fraction ?? 0)
        track.isHidden = state.fraction == nil
        setNeedsLayout()
    }

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
    /// A focus movement (Left/Right and Up/Down alike) on UIKit's own
    /// spring (duration + bounce 0): a new press during the move carries
    /// its speed on instead of starting from rest. (Always UIView.animate:
    /// collection views only animate their cells' size changes inside it —
    /// under a property animator they jumped.)
    static func run(duration: Double,
                    animations: @escaping () -> Void,
                    completion: @escaping (Bool) -> Void) {
        UIView.animate(springDuration: duration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: animations, completion: completion)
    }

    /// Between the billboard and the rows: a little longer than a row step
    /// (it moves further).
    static let billboardScroll: Double = 0.6

    /// `run`'s move for SwiftUI views moving with it (the billboard's text
    /// and dots): SwiftUI's spring is UIKit's system spring.
    static func animation(duration: Double) -> Animation {
        .spring(duration: duration, bounce: 0)
    }

    /// Left/Right, for things moving with the row (the box's drift).
    static func horizontal(_ animations: @escaping () -> Void, completion: @escaping () -> Void) {
        run(duration: Motion.moveDuration, animations: animations, completion: { _ in completion() })
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
