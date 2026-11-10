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
    /// One catalog's fetch, at most: then its saved copy stands.
    static let catalogWait: Double = 8
    var isStale: Bool { loadedAt.map { Date().timeIntervalSince($0) > Self.refreshAge } ?? false }

    /// The billboard's picks (see `BillboardPicks`), made once per catalog
    /// fetch — the same rhythm, so the billboard doesn't reshuffle between.
    @Published private(set) var billboardPicks: [BillboardPick] = []
    /// The fetch whose picks are being made, and the one they're made for
    /// (only once they're in: the launch waits on that, so the billboard
    /// never shows the rows' highlights first).
    private var picksAskedFor: Date?
    private var picksMadeFor: Date?
    /// A later fetch's picks, waiting for the billboard to be out of view.
    private var nextPicks: [BillboardPick]?

    /// Make the picks for the catalogs fetched at `loadedAt` (once: Home,
    /// Movies and Series share this model and all ask). A refresh's new
    /// picks swap in out of view (`BillboardSight`): never under your eyes.
    func refreshPicks(history: BillboardPicks.History, addonManager: AddonManager, tmdb: Bool) async {
        guard let loadedAt, picksAskedFor != loadedAt else { return }
        picksAskedFor = loadedAt
        let made = await BillboardPicks.make(history: history, addonManager: addonManager,
                                             tmdb: tmdb, fallback: highlights(max: 20))
        guard picksAskedFor == loadedAt else { return }
        picksMadeFor = loadedAt
        if billboardPicks.isEmpty || LaunchPreloader.shared.curtain || !BillboardSight.shared.inView {
            nextPicks = nil
            billboardPicks = made
        } else {
            nextPicks = made
            BillboardSight.shared.onAway = { [weak self] in
                guard let self, let next = self.nextPicks else { return }
                self.nextPicks = nil
                self.billboardPicks = next
            }
        }
    }

    /// The picks are this fetch's (not still the one before — another
    /// profile's after a switch).
    var picksCurrent: Bool { loadedAt != nil && picksMadeFor == loadedAt }

    /// Another profile: its rows and picks, fetched again even where its
    /// add-ons and layout match (the picks follow its history).
    @Published private(set) var reloadRequest = 0
    func profileSwitched() {
        loadedFingerprint = []
        reloadRequest &+= 1
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
                        // At most `catalogWait`: past it the row keeps its
                        // saved copy (the launch waits for these).
                        items = try await withDeadline(Self.catalogWait) {
                            try await StremioAPI.catalog(addon: request.addon, catalog: request.catalog)
                        }
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
    /// Shows with every aired episode watched (of the shows Next Up looks
    /// at) — left out of the rows with Hide watched titles.
    @State private var finishedShows: Set<String> = []
    @AppStorage(HomeHideWatched.key) private var hideWatched = false
    @ObservedObject private var stills = ContinueStills.shared

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
        return withoutWatched(filteredRows(rows))
    }

    /// Hide watched titles: the catalog rows without watched films and
    /// finished shows; a row left empty goes.
    private func withoutWatched(_ rows: [HomeRow]) -> [HomeRow] {
        guard hideWatched else { return rows }
        return rows.compactMap { row in
            if row.id == Spotlight.featuredRowID || row.id == Spotlight.continueRowID
                || row.id == Self.libraryRowID || Self.isCollectionRow(row.id) { return row }
            let items = row.items.filter { item in
                item.isSeries ? !finishedShows.contains(item.id) : !watched.isWatched(contentID: item.id)
            }
            guard !items.isEmpty else { return nil }
            return items.count == row.items.count ? row
                : HomeRow(id: row.id, title: row.title, items: items, subtitles: row.subtitles)
        }
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
        // …and while it sits open: checked every 5 min, so a list an hour
        // old is fetched again without a press (the row under focus held).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard !Task.isCancelled else { return }
                refreshIfStale()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshIfStale() } }
        // Eight separate triggers, ONE debounced reload. Each of these used to
        // fire its own unthrottled `reload()`, and at launch they arrive in a
        // burst: the first load runs, then the collections library finishes
        // decoding, then profile scoping republishes four settings at once — so
        // a cold start ran the whole catalog sweep two to four times over.
        .onChange(of: addonManager.addons) { _, _ in scheduleReload() }
        .onChange(of: viewModel.reloadRequest) { _, _ in scheduleReload() }
        .onChange(of: collections.collections) { _, _ in scheduleReload() }
        // Collection rows render regardless, but a provider change still
        // reloads Home so anything downstream of the connections is fresh.
        .onChange(of: collectionProviders) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.orderKeys) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.disabledKeys) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.customTitles) { _, _ in scheduleReload() }
        .task(id: nextUpRefreshKey) { await refreshNextUpContinueItems() }
        .task(id: continueStillsKey) {
            await stills.load(mergedContinueItems(), useEpisodes: tmdbSettings.settings.useEpisodes)
        }
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
            return byRecency.filter(\.isStarted) + byRecency.filter { !$0.isStarted }
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
    /// A show gets a Next Up card only if an episode was watched this recently.
    private static let nextUpWindow: TimeInterval = 30 * 24 * 60 * 60

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

        // Only shows watched within `nextUpWindow`: old history, bulk marks
        // and imports aren't what you're watching (a removal here stays on
        // this device, so fewer cards is the fix, not a synced list).
        let windowStart = Date().addingTimeInterval(-Self.nextUpWindow)
        let watchedSeries = watched.items.values
            .filter { ($0.contentType == "series" || $0.contentType == "tv") && $0.season != nil && $0.episode != nil }
            .sorted { $0.watchedAt > $1.watchedAt }
            .deduplicatedByContentID()
            .filter { $0.watchedAt >= windowStart }
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
        let (rows, counts, finished) = await Task.detached(priority: .userInitiated) {
            var rows: [WatchProgress] = []
            var counts: [String: Int] = [:]
            var finished: Set<String> = []
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
                if entry.target.wantsCard,
                   Self.isFinished(entry.meta, contentID: contentID, watchedKeys: watchedKeys) {
                    finished.insert(contentID)
                }
                guard entry.target.wantsCard,
                      let next = Self.nextUpEpisode(in: entry.meta, contentID: contentID,
                                                    watchedKeys: watchedKeys) else { continue }
                rows.append(Self.nextUpProgress(meta: entry.meta, contentID: contentID, episode: next,
                                                lastWatchedAt: entry.target.lastWatchedAt,
                                                newEpisodeCount: count))
            }
            return (rows, counts, finished)
        }.value
        if !Task.isCancelled {
            nextUpContinueItems = rows
            newEpisodeCounts = counts
            if finished != finishedShows { finishedShows = finished }
        }
    }

    /// metaID → when this viewer first watched anything of that title.
    ///
    /// Derived rather than stored, from the two things that already sync
    /// everywhere: watch history and stored playback positions. That is what
    /// makes the badge agree across devices without a new synced field — and
    /// it means an imported history, which carries each episode's ORIGINAL watch time, gives the true start
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

    /// Every aired episode watched (specials left out); none known: not.
    private nonisolated static func isFinished(_ meta: MetaItem, contentID: String,
                                               watchedKeys: Set<String>) -> Bool {
        let now = Date()
        let aired = (meta.videos ?? []).filter { ($0.season ?? 0) > 0 && ($0.airedDate.map { $0 <= now } ?? true) }
        guard !aired.isEmpty else { return false }
        return aired.allSatisfy {
            watchedKeys.contains(WatchedItem.key(contentID: contentID, season: $0.season ?? 0, episode: $0.episode))
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

    /// Continue Watching card art: the episode's still, as Details shows it
    /// (TMDB's, else the add-on's), else the show's backdrop/poster.
    private func continueImage(_ progress: WatchProgress) -> String? {
        if let still = stills.still(for: progress) { return still }
        if let thumb = progress.episodeThumbnail, !thumb.isEmpty { return thumb }
        return progress.background ?? progress.poster ?? catalogMeta(for: progress.metaID)?.background ?? catalogMeta(for: progress.metaID)?.poster
    }

    /// The episodes on Continue Watching, to look their stills up again
    /// when they change.
    private var continueStillsKey: String {
        guard tmdbSettings.settings.useEpisodes else { return "" }
        return mergedContinueItems().compactMap(ContinueStills.key).joined(separator: ",")
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

/// TMDB's episode stills for Continue Watching, as Details' episodes show
/// them; the add-on's thumbnail only where TMDB has none (Cinemeta's are
/// often missing). Looked up under the launch curtain (`LaunchPreloader`),
/// then whenever the row's episodes change; TMDB's seasons are on disk.
@MainActor
final class ContinueStills: ObservableObject {
    static let shared = ContinueStills()
    @Published private(set) var stills: [String: String] = [:]

    nonisolated static func key(_ progress: WatchProgress) -> String? {
        guard let season = progress.season, let episode = progress.episode else { return nil }
        return "\(progress.metaID):\(season):\(episode)"
    }

    func still(for progress: WatchProgress) -> String? {
        Self.key(progress).flatMap { stills[$0] }
    }

    /// Looks up the episodes not yet known, a season at a time; returns
    /// the stills of `rows` (known or found).
    @discardableResult
    func load(_ rows: [WatchProgress], useEpisodes: Bool) async -> [String] {
        guard useEpisodes, TMDBService.hasAPIKey else { return [] }
        var seasons: [String: (metaID: String, type: String, season: Int, episodes: [Int: String])] = [:]
        for row in rows {
            guard let key = Self.key(row), stills[key] == nil,
                  let season = row.season, let episode = row.episode else { continue }
            seasons["\(row.metaID):\(season)", default: (row.metaID, row.type, season, [:])].episodes[episode] = key
        }
        if !seasons.isEmpty {
            let found = await withTaskGroup(of: [String: String].self) { group in
                for job in seasons.values {
                    group.addTask {
                        let extras = await TMDBService.seasonEpisodes(imdbID: job.metaID, type: job.type, season: job.season)
                        var out: [String: String] = [:]
                        for (episode, key) in job.episodes {
                            if let still = TMDBService.originalSize(extras[episode]?.still) { out[key] = still }
                        }
                        return out
                    }
                }
                return await group.reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
            }
            if !found.isEmpty { stills.merge(found) { _, new in new } }
        }
        return rows.compactMap(still(for:))
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
/// Back on Home, Movies or Series (the page's own `onExitCommand` asks):
/// the page in front first (`HomeUIKitView.backToBillboard`), else the top
/// bar. (One handler: a nested `onExitCommand` took every press, even
/// without an action.)
/// Whether a billboard is on screen — Home, Movies and Series each say for
/// their own; the picks (shared) swap only once none is (`onAway`).
@MainActor
final class BillboardSight {
    static let shared = BillboardSight()
    private var seen: Set<UUID> = []
    var inView: Bool { !seen.isEmpty }
    var onAway: (() -> Void)?

    func set(_ inView: Bool, for key: UUID) {
        if inView { seen.insert(key) } else { seen.remove(key) }
        guard !self.inView, let away = onAway else { return }
        onAway = nil
        away()
    }
}

@MainActor
final class HomeBack {
    static let shared = HomeBack()
    /// The page in front: how far below its billboard focus is (kept here:
    /// a closure reading the page's state saw an old value).
    var depth = 0
    var toBillboard: (() -> Void)?

    /// True: handled (focus goes up to the billboard).
    func handle() -> Bool {
        guard depth > 0, let toBillboard else { return false }
        toBillboard()
        return true
    }
}

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
    /// Focus is on the billboard: which of its titles (nil: in the rows).
    @State private var billboard: FixedFocusBillboardPosition?
    /// The billboard paging by itself: the next title, as a press would.
    @State private var billboardCommand: FixedFocusRowsCommand?
    @AppStorage(BillboardAutoPage.key) private var autoPage = true
    /// The billboard's trailer (Settings → Home & Details → Trailers).
    @StateObject private var trailer = StageTrailer()
    @EnvironmentObject private var homeSettings: HomeCatalogSettingsStore
    @ObservedObject private var trailerGate = TrailerGate.shared
    /// Into / out of Details in place: Home's parts become Details'.
    private var opening = BillboardOpening.shared
    /// Moves between the billboard's buttons (each fades the trailer out;
    /// resting again brings it back).
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
    /// Bumped when the billboard title's record changes (`TitleRecords`):
    /// its text reads the record.
    @State private var billboardRecord = 0
    /// The colours shift through the scroll to or from the billboard.
    @State private var tintScroll = false
    /// Details (opened from the billboard) is taking / has taken over: the
    /// billboard's own cues (hint, dots) are out.
    /// Details is up over Home (the billboard doesn't page behind it).
    @ObservedObject private var detailsOpen = DetailsOpen.shared
    /// This tab's say in `BillboardSight`.
    @State private var sightKey = UUID()
    /// …and its picture has stepped closer (see `StagePictureView`).

    /// Below the billboard: the focused title's colours, or the app
    /// background (Settings → Appearance).
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = true

    /// The dots' last state (so they fade out unchanged).
    @State private var lastBillboard: FixedFocusBillboardPosition?
    /// The billboard's buttons' focus.
    @State private var billboardBridge = FocusBridge<BillboardControl>()

    var body: some View {
        ZStack(alignment: .topLeading) {
            homeLayers
        }
        // Back: this page's first say while it's in front (`HomeBack`).
        .onAppear { if active { takeBack() } }
        .onChange(of: active) { _, now in
            if now { takeBack() }
            opening.trailerShown = now && trailerOut
        }
        // The top bar moves out with the peek while it plays.
        .onChange(of: trailerOut) { _, out in if active { opening.trailerShown = out } }
    }

    /// The trailer on the picture — or coming back on it from Details
    /// (handed over, taken on as Home shows): the peek, the dots and the
    /// top bar stay out (they came back, then went again).
    private var trailerOut: Bool { trailer.shown || opening.closing && StageTrailer.carrying }

    /// Back below the billboard: all the way up to it, in one move (its
    /// title as it is, the rows keeping their places). On it: not ours —
    /// the top bar's.
    private func takeBack() {
        HomeBack.shared.depth = depth
        HomeBack.shared.toBillboard = { billboardCommand = FixedFocusRowsCommand(action: .focusBillboard) }
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
            // Following the title: the app's one title background, which
            // this page sets while it's in front (see `TitleBackground`).
            ATVBackground(titles: true)
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
                           onDepth: {
                               depth = $0
                               if active { HomeBack.shared.depth = $0 }
                           },
                           onFocusArt: { focusedArt = $0 },
                           // The billboard's focus: its buttons (as Details').
                           externalBillboard: true,
                           // The billboard paging (its buttons, and by itself
                           // — Settings → Appearance → Billboard pages by itself).
                           command: billboardCommand,
                           // The billboard as Details': the first row peeks up
                           // the bottom edge (its name above its cards); the
                           // billboard goes up until its hard edge is at the
                           // top bar's middle — the usual peek, the dots in it.
                           rigidRest: Self.rigidRowRest,
                           rigidNameY: FixedFocusRowsLayout.nextNameY,
                           rigidPeek: Self.firstRowPeek,
                           rigidPeekShowsName: true,
                           // The trailer on the picture: the peek moves out
                           // the bottom (the dots too), back as it goes.
                           peekHidden: trailerOut,
                           openingLook: opening.opened,
                           onPeekBack: { trailer.letPeekBack() },
                           billboardOverlay: billboardOverlay,
                           billboardOverlayBelowRows: true,
                           billboardOverlayShift: Self.rigidDotsMid - Self.peekDotsMid,
                           billboardControls: billboardControls,
                           billboardControlsHeight: FixedFocusBillboardText.buttonsY + 130,
                           // Its text on its pictures: each title one card.
                           billboardPageText: { AnyView(BillboardPageText(item: $0, make: billboardText)) },
                           // Paging mid-slide: focus to the side it went —
                           // Next going right, Play going left.
                           onBillboardStep: { billboardBridge.request($0 > 0 ? .next : .details) },
                           billboardEdge: { [billboardBridge] in
                               switch billboardBridge.current {
                               case .next: 1
                               case .details: -1
                               default: 0
                               }
                           },
                           // The picture under the text: the controller's own,
                           // moved with the billboard's distance.
                           pinnedBillboardPicture: true,
                           billboardTrailer: trailer,
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
                    // Paging: the text comes in on its picture
                    // (`billboardPageText`; the neighbours' logos are
                    // decoded ahead).
                    billboardItem = item
                    warmNeighbourLogos(around: position.index)
                }
                billboard = position
            }
            .ignoresSafeArea()
            // The billboard's text, hint and dots (its picture is part of the
            // Featured row — `StagePictureView`).
            billboardLayer
        }
        .ignoresSafeArea()
        // A still background: the panels neutral.
        .onChange(of: followsTitle) { _, _ in TitleBackground.shared.refreshPanels() }
        // Follows the focused title — only while this tab is in front (the
        // billboard pages by itself behind other tabs; coming back puts
        // this tab's title back).
        .task(id: tintKey) {
            guard followsTitle, active, let item = focused,
                  let url = focusedArt ?? item.background ?? item.poster else { return }
            // Scrolling to or from the billboard: over the whole scroll.
            let scrolling = tintScroll
            tintScroll = false
            TitleBackground.shared.follow(url,
                                          over: scrolling ? FixedFocusMotion.billboardScroll : nil)
        }
    }

    /// What the tint follows: the focused title.
    private var tintKey: String { "\(focused?.id ?? "")|\(followsTitle)|\(active)" }
}

/// THE TITLE BACKGROUND (Background: Dynamic): Home, Movies and
/// Series (while in front) set it as focus moves, a folder to its cover,
/// and they show it (`ATVBackground(titles:)`); every other page shows
/// the Bands picture. Home's collection panels take its colour
/// (`addPanel`).
@MainActor
final class TitleBackground {
    static let shared = TitleBackground()

    private var tint: UIColor?
    private var second: UIColor?
    /// Its pictures as drawn (Home, Movies, Series, a folder).
    private let grounds = NSHashTable<TitleTintGroundView>.weakObjects()

    /// Presses closer together than this are fast scrolling: the colours
    /// calm down (change now and then, over a blend).
    static let burstGap: Double = 0.3
    /// …then they change at most this often, over this blend.
    static let burstEvery: Double = 0.45
    static let burstBlend: Double = 0.7

    private var url: String?
    private var task: Task<Void, Never>?
    private var lastPress = Date.distantPast
    private var lastChange = Date.distantPast
    private var panelColor: UIColor?
    private var panelFollows = true
    private let panels = NSHashTable<FixedFocusPanelView>.weakObjects()

    private init() {}

    /// Follows a picture. `over`: a fixed blend (the billboard's scroll);
    /// nil: with focus — the focus move's curve and time, calmed
    /// while scrolling fast. The same picture again: nothing.
    func follow(_ url: String, over: Double? = nil) {
        guard AppBackground.followsTitle, url != self.url else { return }
        self.url = url
        task?.cancel()
        task = Task { [weak self] in await self?.run(url, over: over) }
    }

    private func run(_ url: String, over: Double?) async {
        var follows = over == nil
        var fade = over ?? Motion.moveDuration
        // FAST SCROLLING: a press soon after the last is part of a burst.
        // Then the colours change at most every `burstEvery` (the cards in
        // between are skipped — a new press cancels this wait), over a calm
        // blend; once no press has come for a moment, it has landed: the
        // spring again.
        if follows {
            let now = Date()
            let gap = now.timeIntervalSince(lastPress)
            lastPress = now
            if gap < Self.burstGap {
                let quiet = 0.15
                let due = min(lastChange.addingTimeInterval(Self.burstEvery), now.addingTimeInterval(quiet))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(now) < quiet - 0.01 {
                    follows = false
                    fade = Self.burstBlend
                }
            }
        }
        // The picture's two main colours (`FixedFocusTint.colors`).
        guard let colors = await FixedFocusTint.colors(for: url), !Task.isCancelled else { return }
        lastChange = Date()
        tint = UIColor(colors.first)
        second = colors.second.map { UIColor($0) }
        for ground in grounds.allObjects { ground.show(tint, second, fade: fade, follows: follows) }
        panelColor = UIColor(colors.first)
        panelFollows = follows
        refreshPanels(fade: fade)
    }

    /// A new picture of it: the current colours, at once.
    func addGround(_ ground: TitleTintGroundView) {
        grounds.add(ground)
        ground.show(tint, second, fade: 0, follows: false)
    }

    // MARK: Collection panels

    /// A new panel: the current colour, at once.
    func addPanel(_ panel: FixedFocusPanelView) {
        panels.add(panel)
        panel.show(shownPanelColor, fade: 0, follows: panelFollows)
    }

    /// The panels again (the colour changed, or the setting): neutral on a
    /// still picture.
    func refreshPanels(fade: Double = Motion.fadeDuration) {
        for panel in panels.allObjects { panel.show(shownPanelColor, fade: fade, follows: panelFollows) }
    }

    private var shownPanelColor: UIColor? {
        AppBackground.followsTitle ? panelColor : nil
    }
}

/// The title background as drawn (`TitleBackground`): Home's ground.
/// Its colours change in Core Animation (`TitleTintGroundView`): in SwiftUI
/// the blend ran on the main thread with every focus move, beside the rows.
struct TitleBackgroundView: UIViewRepresentable {
    func makeUIView(context: Context) -> TitleTintGroundView {
        let view = TitleTintGroundView()
        TitleBackground.shared.addGround(view)
        return view
    }
    func updateUIView(_ view: TitleTintGroundView, context: Context) {}
}

/// `TitleTintBackground` in layers: the dark ground, the title's colour
/// over it, the second towards the bottom left (the same fixed mask); a
/// change blends from what's on screen, on the panels' curves.
final class TitleTintGroundView: UIView {
    private let first = CALayer()
    private let second = CALayer()
    private let secondMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        secondMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        secondMask.locations = [0.15, 0.95]
        secondMask.startPoint = CGPoint(x: 0.95, y: 0)
        secondMask.endPoint = CGPoint(x: 0.5, y: 1)
        second.mask = secondMask
        for sub in [first, second, secondMask] as [CALayer] { sub.actions = Self.still }
        layer.addSublayer(first)
        layer.addSublayer(second)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(),
                                                    "backgroundColor": NSNull()]

    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in [first, second, secondMask] as [CALayer] { sub.frame = bounds }
    }

    func show(_ tint: UIColor?, _ other: UIColor?, fade: Double, follows: Bool) {
        let strength = TitleTintBackground.tintStrength
        // No second colour: the first under the mask too, so it fades as one.
        let colors = [tint?.withAlphaComponent(strength),
                      (tint == nil ? nil : other ?? tint)?.withAlphaComponent(strength)]
        for (sub, color) in zip([first, second], colors) {
            let from = sub.presentation()?.backgroundColor ?? sub.backgroundColor
            sub.backgroundColor = (color ?? .clear).cgColor
            guard fade > 0, window != nil else { sub.removeAnimation(forKey: "tint"); continue }
            let change = CABasicAnimation(keyPath: "backgroundColor")
            change.fromValue = from
            change.duration = fade
            change.timingFunction = follows ? FixedFocusTint.focusTiming
                : CAMediaTimingFunction(name: .easeInEaseOut)
            sub.add(change, forKey: "tint")
        }
    }
}

/// THE CALM GROUND under rows of cards and text: the title's colour(s)
/// over a near-black base — flat, no vignette.
struct TitleTintBackground: View {
    let tint: Color?
    var second: Color? = nil

    /// Under it (Home, a folder): dark, a little lighter at the top.
    static var base: some View {
        LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    /// How strongly the colour covers the dark base.
    static let tintStrength: Double = 0.5

    var body: some View {
        ZStack {
            // Even from top to bottom: no darker lower half, no corners.
            Color(white: 0.06)
            if let tint {
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
        }
        .allowsHitTesting(false)
    }
}

/// The background's colours from the title's artwork: its two main colours
/// (`colors`).
@MainActor
enum FixedFocusTint {
    static func colors(for url: String) async
        -> (first: Color, second: Color?)? {
        guard let palette = await SpotlightTint.areaPalette(for: url) else { return nil }
        return colors(from: palette)
    }

    private static func colors(from palette: [SpotlightTint.Swatch])
        -> (first: Color, second: Color?)? {
        guard let first = palette.first else { return nil }
        let second = palette.count > 1 ? palette[1] : nil
        return (shown(hue: first.hue, saturation: first.saturation),
                second.map { shown(hue: $0.hue, saturation: $0.saturation) })
    }

    /// The colours' Core Animation fade with focus (the background, the
    /// collection panels; a fade takes a
    /// curve, not a spring: the no-bounce spring's shape, fast then a long
    /// settle).
    @MainActor static let focusTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.3, 1)

    /// The tint moves with focus: the colours of the cards you may go to
    /// next, found beforehand — on the press there is nothing left to work
    /// out. (Cached per picture.)
    @MainActor static func prepare(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls {
                _ = await colors(for: url)
            }
        }
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
    /// Details' line in the reason's place (`DetailTrailerHint`).
    var lead: AnyView? = nil

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

    /// The logo (else the name), sized by area (`logoArea`, within
    /// `logoMaxSize`), the view as large as it's
    /// drawn — so the reason sits on it.
    private var logoView: some View {
        Group {
            if let logo = logo ?? item.logo {
                // A logo that can't be loaded falls back to the name.
                RemoteImage(url: logo, maxDimension: Self.logoMaxSize.width, showsPlaceholder: false,
                            fallback: AnyView(nameText),
                            logoFit: LogoFit(area: Self.logoArea, maxSize: Self.logoMaxSize))
            } else {
                nameText
            }
        }
    }

    /// Extra room above the chips (and the tagline after them): a plain
    /// line step left ~6 pt between the facts and the chips' boxes.
    static let chipsGap: CGFloat = 9
    /// THE BLOCK'S GAPS, as seen (between what's drawn, not the lines'
    /// frames): one gap between its parts, a little more around the chips.
    static let gap: CGFloat = 19
    static let chipsSpace: CGFloat = 26
    /// Every logo covers about this much (pt²): e.g. 420 × 110 wide,
    /// 260 × 160 (its height cap) near square.
    static let logoArea: CGFloat = 46_000
    static let logoMaxSize = CGSize(width: TitleBlock.logoWidth, height: TitleBlock.logoHeight)
    /// The reason ⇄ Details' line (into Details in place).
    static let leadSwap = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                                   removal: .opacity.combined(with: .offset(y: -6)))
    /// The reason's line frame (30 pt) holds this much below its baseline.
    static let reasonInset: CGFloat = 6.5
    /// THE BLOCK'S TEXT (facts, tagline): one size, a little above the
    /// base; its line's frame and what that holds above its capitals /
    /// below its baseline.
    static let textSize: CGFloat = 26
    static let lineHeight: CGFloat = 32
    static let lineInset: CGFloat = 7
    /// How many rating sources show (the first ones, in Settings' order).
    static let ratingsShown = 3
    /// The description under the tagline (`VibrantSummary`): three lines'
    /// room, narrower than the block so it stays on the shade's dark side.
    static let summaryWidth: CGFloat = 600
    static let summaryLines = 3
    static let summarySpacing: CGFloat = 4
    static var summaryHeight: CGFloat {
        let line = UIFont.systemFont(ofSize: FixedFocusMetrics.textSize).lineHeight
        return (line * CGFloat(summaryLines) + summarySpacing * CGFloat(summaryLines - 1)).rounded(.up)
    }
    /// Where the Detail page's buttons start: below the chips line.
    static var buttonsY: CGFloat {
        FixedFocusMetrics.boxFrame.maxY + FixedFocusMetrics.infoHeight + 44
    }
    /// The chips line: the status badge, then the first ratings (nil: none).
    @MainActor
    static func ratingsChips(_ ratings: MDBListRatings?, settings: MDBListSettings, item: MetaItem,
                             onDetails: Bool = false) -> AnyView? {
        let entries = MDBListRatingsRow.entries(ratings, settings: settings, imdbFallback: item.imdbRating,
                                                onDetails: onDetails)
        return entries.isEmpty ? nil : AnyView(MDBListRatingsRow(
            entries: Array(entries.prefix(ratingsShown))))
    }
    private var nameText: some View {
        Text(item.name)
            .font(FusionType.heroTitle)
            .foregroundStyle(CuePalette.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .frame(maxWidth: TitleBlock.logoWidth, alignment: .bottomLeading)
    }

    /// The block's BOTTOM (the tagline) stands here — it grows up with
    /// what it has, as the Apple TV app's text sits on its buttons. (On
    /// Details: room for the buttons right below.)
    static var bottom: CGFloat { buttonsY - 30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            block
                // ONE shadow for the block (reason, logo, chips, facts,
                // tagline): small and tight, the shade does the rest.
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            // The description, as the Apple TV app's: vibrant (blended
            // with the picture behind it, not painted over it), so it
            // reads on bright pictures and trailers too; no shadow (it
            // would flatten the effect). Up to three lines from the top of
            // a fixed room (every title's block the same height).
            VibrantSummary(text: FixedFocusMetrics.descriptionText(item) ?? "")
                .frame(width: Self.summaryWidth, height: Self.summaryHeight, alignment: .topLeading)
                .padding(.top, Self.gap - Self.lineInset)
        }
        .frame(width: Self.width, alignment: .leading)
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One place, the reason or Details' line: swapped, the old one
            // rising out as it fades, the new one coming up into it.
            ZStack(alignment: .leading) {
                if let reason {
                    BillboardReasonLabel(reason: reason)
                        .transition(Self.leadSwap)
                } else if let lead {
                    lead
                        .transition(Self.leadSwap)
                }
            }
            .frame(height: 30, alignment: .leading)
            .padding(.bottom, Self.gap - Self.reasonInset)
            logoView

            VStack(alignment: .leading, spacing: 0) {
                // The status badge and ratings (boxes: no inset).
                chips
                    .padding(.top, Self.chipsSpace)
                // THE FACTS — what it is, quieter than the logo and the
                // chips. (Without the rating: the chips carry it.)
                Text(FixedFocusShowInfo.factsLine(item, info: info))
                    .font(.system(size: Self.textSize, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.body))
                    .lineLimit(1)
                    .frame(height: Self.lineHeight, alignment: .leading)
                    .padding(.top, Self.chipsSpace - Self.lineInset)
                // The tagline — the mood, quiet and italic; no tagline: the
                // name (ALWAYS a line here: every title's block has the same
                // height, nothing moves).
                Text(tagline ?? item.name)
                    .font(.system(size: Self.textSize, weight: .regular).italic())
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                    .lineLimit(1)
                    .frame(height: Self.lineHeight, alignment: .leading)
                    .padding(.top, Self.gap - 2 * Self.lineInset)
            }
        }
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

/// What Home's text needs for a series beyond the catalog — its size and
/// status — read from its record (`TitleRecords`).
@MainActor
enum FixedFocusShowInfo {
    static func known(_ item: MetaItem) -> TMDBService.ShowSize? { TitleRecords.shared.size(item) }

    /// A series' status chip: AIRING, RETURNING or "ENDED 2019" (see
    /// `TitleRecords.status`) — the catalog's years until it's known.
    static func status(_ item: MetaItem) -> String? { TitleRecords.shared.status(item) }

    /// Seasons and episodes, specials not counted — once its record has
    /// them (looked up if missing or a day old).
    static func load(_ item: MetaItem) async -> TMDBService.ShowSize? {
        guard item.isSeries else { return nil }
        await TitleRecords.shared.refresh(item, [.show, .facts])
        return TitleRecords.shared.size(item)
    }

    /// How close "airing" is: an episode out within this, or due within it.
    static let airingWindow: TimeInterval = 10 * 24 * 60 * 60

    /// Home's facts line (under the box, on the billboard): type, genre,
    /// the START year, size — no rating and no end year (the chips below
    /// carry those). The size from the catalog's episode list, else from
    /// `load` once it is known.
    static func factsLine(_ item: MetaItem, info: TMDBService.ShowSize? = nil) -> String {
        // A collection's folder: how many catalogs it holds.
        if item.type == "collection" { return item.description ?? "" }
        let info = info ?? TitleRecords.shared.size(item)
        let size = item.regularSeasons.isEmpty && info != nil
            ? TitleBlock.seriesSizeText(item, seasons: info?.seasons, episodes: info?.episodes)
            : TitleBlock.seriesSizeText(item)
        return TitleBlock.metaSegments(for: item, seriesSize: size, includesRating: false,
                                       startYearOnly: true)
            .joined(separator: "  •  ")
    }
}

/// THE STAGE'S SHADE — what lies over a full-screen backdrop so text reads
/// on it: one fade from the left. ONE definition for Home's billboard and
/// the Detail page: the same picture looks the same on both.
struct BillboardShade: View {
    var body: some View {
        Image(uiImage: Self.image).resizable()
            .allowsHitTesting(false)
    }

    /// The fade, darkest at the screen's left edge, clear past the text
    /// column, then a little dark again towards the right edge (bright
    /// pictures). No bottom fade, no top band, no vignette.
    static let points: [(x: Double, y: Double)] = [
        (0, 0.8),                                      // the screen's edge
        (0.05, 0.75),
        (0.1, 0.70),
        (0.2, 0.66),                                    // the column's middle
        (0.36, 0.52),
        (0.48, 0.28),                                   // past the column
        (0.64, 0.28),
        (0.82, 0.28),
        (1, 0.28),                                       // the right edge
    ]

    /// The darkness at any share of the width: one smooth curve through
    /// `points` — monotone cubic interpolation (Fritsch–Carlson): smooth
    /// through every point, never overshooting; level where it ends.
    static func curve(_ points: [(x: Double, y: Double)]) -> (Double) -> Double {
        let n = points.count
        let slopes = (0..<n - 1).map { (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x) }
        var tangents = (0..<n).map { i -> Double in
            if i == 0 { return slopes[0] }
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

    /// Made once: one line of pixels (black, only the alpha — RGBA,
    /// premultiplied), stretched to the screen.
    static let image: UIImage = {
        let w = 960
        let dark = curve(points)
        var pixels = [UInt8](repeating: 0, count: w * 4)
        for x in 0..<w {
            pixels[x * 4 + 3] = UInt8((dark((Double(x) + 0.5) / Double(w)) * 255).rounded())
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: w, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }()
}

/// Text levels: a hierarchy, mostly off-white.
enum FixedFocusText {
    /// The app's four text levels, used everywhere (nothing brighter: the
    /// logo, a picture aside, nothing in the UI is pure white). Names and
    /// titles — row and page names, panels' names, a focused card's name.
    static let primary: CGFloat = 0.82
    /// Text to read: summaries, a bio, About's facts, the billboard's facts.
    static let body: CGFloat = 0.72
    /// Supporting lines: a focused card's second line, facts lines,
    /// subtitles, the tagline, Settings' values and descriptions.
    static let secondary: CGFloat = 0.62
    /// Small labels (kind labels, "SUMMARY", section labels), what's off.
    static let tertiary: CGFloat = 0.5
    /// (Out of focus, a card's caption steps down one level: its name
    /// secondary, its second line tertiary. Tried: row and page names at
    /// tvOS's heading grey, 55 %, under captions and About's text at 70 % —
    /// the names dimmer than what they named; nine levels in all; 85 /
    /// 75 / 60 / 45 — bright; 75 / 65 / 55 / 45 — too muted.)

    /// A title and its info line (under the box, under a card): the name
    /// medium, the line under it regular, one size — weight and level
    /// tell them apart. Focused: the name primary, the line body; out of
    /// focus each two levels down (secondary, tertiary). (Tried: semibold; both
    /// regular, the line secondary — they read as one.)
    static func titleFont(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .medium) }
    static func infoFont(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .regular) }
    static func titleLevel(focused: Bool) -> CGFloat { focused ? primary : secondary }
    static func infoLevel(focused: Bool) -> CGFloat { focused ? body : tertiary }
}

/// The focused card's look: the unfocused cards' edge, bright (no ring
/// around the card), a soft shadow under it and, where cards grow, a 6 %
/// lift (`FixedFocusMetrics.movingFocusLift`).
@MainActor
enum FixedFocusRing {
    /// Settings → Appearance → Card outlines, by how much they show: high —
    /// every card's thin rim and the bright edge on the one in focus; low —
    /// the rim only (focus is the shadow and the grow); off — neither.
    enum Outlines: String, CaseIterable {
        case high, low, off
        var label: String {
            switch self {
            case .high: "Edges and Focus"
            case .low: "Edges Only"
            case .off: "Off"
            }
        }
    }
    static let outlinesKey = "cue.appearance.cardOutlines"
    /// Set: every card follows at once (`refreshAll`) — set from the
    /// options page, the Appearance page's own `onChange` wasn't there to
    /// see it: only cards laid out anyway (the fixed rows, on every move)
    /// followed; Continue Watching, Saved for Later much later.
    static var outlines: Outlines {
        get {
            if let raw = UserDefaults.standard.string(forKey: outlinesKey), let chosen = Outlines(rawValue: raw) {
                return chosen
            }
            // The old Focus outline switch, off: the rim only.
            return UserDefaults.standard.object(forKey: "cue.appearance.focusEdge") as? Bool == false ? .low : .high
        }
        set {
            guard newValue != outlines || UserDefaults.standard.string(forKey: outlinesKey) == nil else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: outlinesKey)
            refreshAll()
        }
    }
    /// The focus edge: the rim's own width, bright.
    static var width: CGFloat { outlines == .high ? 2 : 0 }
    static let color = UIColor.white.withAlphaComponent(0.75)

    /// The setting changed: every card lays itself out again (each applies
    /// the edge there) — at once, in every tab and page, no restart. The
    /// cards (`follow`) too when off screen: a tab not shown (Home, behind
    /// Settings) or a recycled cell kept the old look until laid out again.
    static func refreshAll() {
        func relayout(_ view: UIView) {
            view.setNeedsLayout()
            view.subviews.forEach(relayout)
        }
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach(relayout)
        }
        cards.allObjects.forEach(relayout)
    }
    /// A card with outlines: laid out again when Card outlines changes.
    static func follow(_ card: UIView) { cards.add(card) }
    private static let cards = NSHashTable<UIView>.weakObjects()

    /// The shadow under a focus outline `view` (its card's rect): the
    /// cards' shadow picture (`FixedFocusCardEdge.shadowImage`, only outside
    /// the card), sized by autoresizing — so it follows the card's grow
    /// animation (a layer's shadow path snapped to each new size: flicker).
    static func attachShadow(to view: UIView) {
        let pad = FixedFocusCardEdge.shadowPad
        let shadow = UIImageView(image: FixedFocusCardEdge.shadowImage)
        shadow.isUserInteractionEnabled = false
        shadow.frame = view.bounds.insetBy(dx: -pad, dy: -pad)
        shadow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(shadow, at: 0)
    }
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
        // (A trailer playing: it moves on at its end.)
        autoPagePossible && !autoPageDone && !trailer.playing
    }
    /// The setting on, a title to go to, nothing over the billboard.
    /// A trailer's end needs no more: it pages on after moves along the
    /// buttons too (`autoPageDone`).
    var autoPagePossible: Bool {
        guard let billboard else { return false }
        // It stops at the last title (no wrap back to the first).
        return autoPage && billboard.index < billboard.count - 1
            && homeScenePhase == .active && active && detailsOpen.depth == 0
    }
    /// A new episode's or season's pick: that season's trailer (TMDB's
    /// season airing then).
    private func trailerSeason(_ item: MetaItem) -> (season: Int?, aired: Date?) {
        switch billboardReasons[item.id] {
        case .newEpisode(let season, _, let aired), .newSeason(let season, let aired): return (season, aired)
        default: return (nil, nil)
        }
    }
    /// Resting on the billboard: its title's trailer may play.
    var trailerTitle: MetaItem? {
        guard billboard != nil, homeSettings.heroTrailersEnabled, homeScenePhase == .active, active,
              detailsOpen.depth == 0, !trailerGate.playerUp, !trailerGate.coverUp else { return nil }
        return billboardTitle
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

    /// The billboard's text and dots for the rows to host (a change of
    /// title: on the pictures — `billboardPageText`).
    var billboardOverlay: AnyView {
        AnyView(billboardContent.environmentObject(mdblist))
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
        // Whether this tab's billboard is on screen (or under Details): new
        // picks wait until it isn't.
        .onChange(of: active && (billboard != nil || detailsOpen.depth > 0), initial: true) { _, seen in
            BillboardSight.shared.set(seen, for: sightKey)
        }
        .onDisappear { BillboardSight.shared.set(false, for: sightKey) }
        // THE BILLBOARD PAGING BY ITSELF: resting on it, the next title
        // after `BillboardAutoPage.interval` (the current segment fills over
        // it). Any press — a new title — starts it over; off the billboard,
        // in Details or a menu, it waits.
        .task(id: "\(billboard?.index ?? -1)|\(autoPageRunning)|\(autoPageVisit)") {
            guard autoPageRunning, let position = billboard, position.count > 1 else { return }
            try? await Task.sleep(for: .seconds(BillboardAutoPage.interval))
            guard !Task.isCancelled, autoPageRunning, billboard == position else { return }
            billboardCommand = FixedFocusRowsCommand(
                action: .page(rowID: featuredRowID, index: position.index + 1))
        }
        // THE TRAILER: resting on a title, it plays over its picture;
        // another title, or off the buttons, fades it out. At its end, the billboard moves on (as by
        // itself — `autoPageRunning`).
        .onChange(of: "\(trailerTitle?.id ?? "")|\(homeSettings.heroTrailerSound)", initial: true) { _, _ in
            // Back from Details: its trailer playing on.
            if let trailerTitle { trailer.adopt(trailerTitle) }
            let about = trailerTitle.map(trailerSeason)
            trailer.rest(on: trailerTitle, season: about?.season, aired: about?.aired,
                         sound: homeSettings.heroTrailerSound)
        }
        // The billboard's first titles' trailers resolved ahead, from launch
        // (under the curtain), in its order — the rest as they're rested on.
        // Kept on disk: later launches find them.
        .task(id: "\(homeSettings.heroTrailersEnabled)|\(rows.first(where: { $0.id == featuredRowID })?.items.map(\.id) ?? [])") {
            guard homeSettings.heroTrailersEnabled,
                  let items = rows.first(where: { $0.id == featuredRowID })?.items else { return }
            await TrailerResolver.warm(items.prefix(TrailerResolver.warmCount).map { item in
                let about = trailerSeason(item)
                return (item, about.season, about.aired)
            })
        }
        .onAppear {
            trailer.reset()
        }
        .onChange(of: trailer.endings) { _, _ in
            guard autoPagePossible, let position = billboard else { return }
            billboardCommand = FixedFocusRowsCommand(
                action: .page(rowID: featuredRowID, index: position.index + 1))
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
                // (The text itself is on the picture — `billboardPageText`;
                // its data loads here.)
                Color.clear.frame(width: 0, height: 0)
                    // Its record (size, status, tagline, ratings), brought
                    // up to date if a day old.
                    .task(id: item.id) {
                        if await TitleRecords.shared.refresh(item, [.show, .facts, .ratings]) {
                            billboardRecord += 1
                        }
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
                    // In the peek; once the billboard is up, in its strip's
                    // middle — moved there by the rows with their scroll
                    // (`billboardOverlayShift`: on SwiftUI's clock it ran
                    // apart from them), and with the peek (`movePeek`).
                    .offset(x: Spotlight.screenInset, y: Self.peekDotsMid - SectionHint.size * 1.3 / 2)
            }
        }
        // (Top-left: without the picture the layer is only as large as its
        // text — centred, it all moved down.)
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    /// THE BILLBOARD'S BUTTONS (Details' look): Details, Library, Next.
    /// Left from Details: the title before; Right from Next (or Select
    /// on it): the next one — focus stays where it is, so Right again
    /// browses on. Down: the first row.
    var billboardControls: AnyView {
        AnyView(BillboardControls(
            item: billboardTitle,
            bridge: billboardBridge,
            onPage: pageBillboard,
            onDetails: { if let item = billboardTitle { openBillboardTitle(item) } },
            // Moving between the buttons: the paging by itself stops (the
            // title would change under the button you're about to press);
            // the trailer plays on.
            onMove: { autoPageDone = true })
            .environmentObject(library)
            .frame(height: DetailActionButton.height)
            .padding(.leading, FixedFocusMetrics.titleInset)
            .padding(.top, FixedFocusBillboardText.buttonsY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    /// The billboard's title now (its text may still be crossfading to it).
    private var billboardTitle: MetaItem? {
        guard let position = billboard ?? lastBillboard,
              let row = rows.first(where: { $0.id == featuredRowID }),
              row.items.indices.contains(position.index) else { return billboardItem }
        return row.items[position.index]
    }

    /// One title along (−1: back), focus staying on the button.
    private func pageBillboard(_ step: Int) {
        billboardCommand = FixedFocusRowsCommand(action: .step(rowID: featuredRowID, by: step))
    }

    /// Details' button: into Details — in place (`DetailTransition.openInPlace`):
    /// Home's billboard becomes Details'.
    /// A trailer playing goes on into Details (`StageTrailer.handOver`).
    func openBillboardTitle(_ item: MetaItem) {
        guard let onSelectFeatured else { onSelect(item); return }
        DetailTransition.shared.openInPlace(item, trailer: trailer.handOver()) { onSelectFeatured(item) }
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
                await ImageCache.shared.preload(logo, maxDimension: PictureSize.logo)
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
    /// Into Details in place (`opened`): the reason goes (Details' hint
    /// comes in with Details).
    private func billboardText(_ item: MetaItem, opened: Bool) -> some View {
        // (What's in memory already — loaded ahead, `TitleExtras` — draws
        // with the text, not a moment after it.)
        let _ = billboardRecord
        let records = TitleRecords.shared
        return FixedFocusBillboardText(item: item, info: records.size(item),
                                reason: opened ? nil : billboardReasons[item.id],
                                ratings: billboardRatingsRow(item),
                                tagline: records.tagline(item))
            .frame(height: FixedFocusBillboardText.bottom, alignment: .bottomLeading)
            .padding(.leading, FixedFocusMetrics.titleInset)
    }

    /// The ratings chips (nil: none at all) — the catalog's IMDb score until
    /// MDBList's arrive, as on the Detail page.
    private func billboardRatingsRow(_ item: MetaItem) -> AnyView? {
        FixedFocusBillboardText.ratingsChips(TitleRecords.shared.ratings(item) ?? nil,
                                             settings: mdblist.settings, item: item)
    }
}

enum BillboardControl: Hashable { case details, library, next }

/// A billboard card's text, following `BillboardOpening` (each card's own
/// host: a new root view wouldn't animate).
struct BillboardPageText<Content: View>: View {
    private var opening = BillboardOpening.shared
    let item: MetaItem
    let make: (MetaItem, Bool) -> Content
    /// `opened` as this card shows it, changed in the card's own
    /// transaction: the reason out and back on the move (Back, the change
    /// came with its host's new root view, unanimated — the reason was
    /// there at once, ahead of the parts moving in).
    @State private var shown = BillboardOpening.shared.opened
    init(item: MetaItem, make: @escaping (MetaItem, Bool) -> Content) {
        self.item = item
        self.make = make
    }
    var body: some View {
        make(item, shown)
            .onChange(of: opening.opened) { _, opened in
                guard opened != shown else { return }
                if opening.running {
                    withAnimation(Motion.move) { shown = opened }
                } else {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { shown = opened }
                }
            }
    }
}

/// Home's billboard buttons — Details' look (`DetailActionButton`):
/// Details (labelled, first — playing is a heavy step, it's behind
/// Details), Library, Next. ONE view
/// for every title: focus stays put as the billboard pages.
struct BillboardControls: View {
    let item: MetaItem?
    let bridge: FocusBridge<BillboardControl>
    let onPage: (Int) -> Void
    let onDetails: () -> Void
    let onMove: () -> Void
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        // (Into Details in place they stay as they are: Details' own
        // buttons wear them, becoming Play / About as Details arrives; on
        // Back these wear Details', becoming Home's with its parts —
        // `DetailActionButton.other`.)
        FocusBridgeHost(bridge: bridge, defaultValue: .details, onChange: { old, new in
            if old != nil, let new, new != .next { onMove() }
        }) { focus in
            HStack(spacing: CueSpacing.md) {
                DetailActionButton(
                    icon: "info.circle", title: "Details", isPrimary: true, lit: false,
                    billboard: true, action: onDetails,
                    other: .init(title: "Play", icon: "play.fill"))
                    .focused(focus, equals: .details)
                    .onMoveCommand { if $0 == .left { onPage(-1) } }
                // (One focus section, as on Details: a move into the row
                // resolves against them as a unit.)
                HStack(spacing: CueSpacing.md) {
                    let saved = item.map(library.contains) ?? false
                    DetailActionButton(
                        icon: saved ? "checkmark" : "plus", title: saved ? "In Library" : "Library",
                        isPrimary: false, lit: false, bare: true, billboard: true,
                        action: { if let item { library.toggle(item) } })
                        .focused(focus, equals: .library)
                    DetailActionButton(icon: "chevron.right", title: "Next", isPrimary: false, lit: false,
                                       bare: true, plain: true, billboard: true, action: { onPage(1) },
                                       other: .init(title: "About", icon: "text.alignleft"))
                        .focused(focus, equals: .next)
                        .onMoveCommand { if $0 == .right { onPage(1) } }
                }
                .focusSection()
            }
        }
    }
}

/// The cards' light frame — a printed card's rim — and the soft shadow
/// under a lifted card: pre-rendered, stretchable images (drawn once, they
/// follow a card's size, also as it grows) — nothing drawn live on a moving
/// card.
enum FixedFocusCardEdge {
    /// The focus outline in the top bar's light
    /// — off: a plain white line.
    /// (The top bar's light is no focus style any more: every focused card
    /// uses the same plain line — `FixedFocusRing`.)
    @MainActor static var focusLight: Bool { false }
    @MainActor static var focusImage: UIImage { art.focus }

    /// The rim over the card: an even 2 pt line inside the corner, there
    /// on dark artwork, quiet on light.
    /// None with Card outlines off.
    @MainActor static var rim: UIImage? { FixedFocusRing.outlines == .off ? nil : art.rim }

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

/// The billboard's description, as the Apple TV app's: tvOS's vibrancy
/// (a dark blur's) — the words blended with what's behind them,
/// so they keep their contrast over bright pictures and trailers, where a
/// fixed grey washes out. A UIKit effect view: it samples the window
/// behind it, the picture under SwiftUI's host included.
struct VibrantSummary: UIViewRepresentable {
    let text: String
    /// Plain white over the vibrant words: a little brighter than tvOS's
    /// vibrancy alone, still blended where it counts.
    static let lift: CGFloat = 0.3

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let effect = UIVisualEffectView(effect: UIVibrancyEffect(blurEffect: UIBlurEffect(style: .dark)))
        effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effect.frame = view.bounds
        view.addSubview(effect)
        let lift = TopAlignedLabel()
        lift.textColor = UIColor.white.withAlphaComponent(Self.lift)
        for (label, parent) in [(TopAlignedLabel(), effect.contentView), (lift, view)] {
            label.numberOfLines = FixedFocusBillboardText.summaryLines
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.frame = parent.bounds
            parent.addSubview(label)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = FixedFocusBillboardText.summarySpacing
        style.lineBreakMode = .byTruncatingTail
        let effect = view.subviews.first as? UIVisualEffectView
        for case let label as UILabel in (effect?.contentView.subviews ?? []) + view.subviews {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: FixedFocusMetrics.textSize), .paragraphStyle: style]
            if label.superview === view { attributes[.foregroundColor] = UIColor.white.withAlphaComponent(Self.lift) }
            label.attributedText = NSAttributedString(string: text, attributes: attributes)
        }
    }
}
