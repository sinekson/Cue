import SwiftUI
import AVFoundation
import Combine

struct HomeRow: Identifiable {
    /// Every picture these rows can show or open on (`ImageCache.protectHome`):
    /// each title's card picture, poster, backdrop (full size too, as the
    /// billboard and Details draw it) and logo.
    static func pictures(_ rows: [HomeRow]) -> Set<String> {
        var urls = Set<String>()
        for row in rows {
            for item in row.items {
                for url in [row.art[item.id], item.poster, item.background,
                            TMDBService.originalSize(item.background), item.logo] {
                    if let url { urls.insert(url) }
                }
            }
        }
        return urls
    }

    /// What a row shows, to tell whether it changed: each title and its art.
    var contentKey: [String] { items.map { "\($0.id)|\(art[$0.id] ?? $0.background ?? "")" } }

    let id: String
    let title: String
    private(set) var items: [MetaItem]

    /// The same row with fewer titles (a tab's or a filter's): its badges,
    /// pictures and tabs kept.
    func with(_ items: [MetaItem]) -> HomeRow {
        var row = self
        row.items = items
        return row
    }
    /// A second caption line per title (when a title was saved, an
    /// episode's name), by title id.
    var subtitles: [String: String] = [:]
    /// Cue's own rows (`CueRows`): the tabs it shows on ("home"); nil:
    /// every tab.
    var tabs: [String]? = nil
    /// Badges made with the row (`CueRows.Row.badges`), by title id.
    var badges: [String: CardBadge] = [:]
    /// A tall or ranked card's picture where it isn't the backdrop
    /// (`CueRows.Row`).
    var art: [String: String] = [:]
    /// Its cards (`CueRows.CardShape`): posters unless said.
    var shape: CueRows.CardShape = .poster
    /// An episode row's episode per show (`CueRows.EpisodeCard`).
    var episodes: [String: CueRows.EpisodeCard] = [:]
    /// The titles next in line (`CueRows.Row.spare`): Hide Watched refills
    /// from them.
    var spare: [MetaItem] = []

    /// The episode rows' state lines, as Continue Watching's: "S2:E5" and
    /// its day ("Today", "Yesterday", the weekday within a week, else the
    /// date); with Hide Spoilers, an episode not watched yet blurred, as
    /// Details'.
    @MainActor static func episodeStates(_ rows: [HomeRow], hideSpoilers: Bool = false,
                              watched: WatchedStore? = nil) -> [String: FixedFocusCardState] {
        var out: [String: FixedFocusCardState] = [:]
        for row in rows where row.shape == .episode {
            for (id, episode) in row.episodes where out[id] == nil {
                let seen = watched?.isWatched(contentID: id, season: episode.season, episode: episode.episode) ?? false
                out[id] = FixedFocusCardState(label: "S\(episode.season):E\(episode.episode)",
                                              right: episode.aired.map(day),
                                              blurred: hideSpoilers && !seen,
                                              rightSymbol: FixedFocusBadges.symbol(.returns))
            }
        }
        return out
    }

    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        return (days < 7 ? weekdayFormat : dateFormat).string(from: date)
    }
    /// Made once (a formatter per call loaded its locale's data each time).
    private static let weekdayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()
    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// The badges a card shows (`FixedFocusBadges`), at most two: the
    /// show's news, then the row's badge (For You's reason first), else the
    /// first fact that holds — each left out where the row already says it.
    @MainActor
    func badges(for item: MetaItem) -> [CardBadge] {
        guard !FixedFocusPlaceholder.isPlaceholder(item) else { return [] }
        let kind = id.hasPrefix("cue.") ? id.split(separator: ".").dropFirst(2).joined(separator: ".") : ""
        let records = TitleRecords.shared
        var out: [CardBadge] = []
        if !["ontheair", "airingtoday"].contains(kind), let news = records.news(item) { out.append(news) }
        let own = badges[item.id]
        let facts = records.facts(item).filter { !(kind == "toprated" && $0.kind == .acclaimed) }
        let second: CardBadge?
        switch own?.kind {
        case .person: second = facts.first { $0.kind == .finale } ?? own
        case .top10: second = facts.first ?? own
        default: second = own ?? facts.first
        }
        if let second { out.append(second) }
        return out
    }

    /// Shown on Home (rows saved before Movies and Series went say which).
    var onHome: Bool { tabs.map { $0.contains("home") } ?? true }

}

private extension Sequence where Element == WatchedItem {
    func deduplicatedByContentID() -> [WatchedItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.contentID).inserted }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var entries: [HomeRow] = [] {
        didSet { rebuildItemIndex() }
    }
    /// When the rows were last loaded (nil: not yet this launch). Published:
    /// the billboard's picks are made for it (`.task(id:)`), and a load with
    /// no new rows changes nothing else.
    @Published private(set) var loadedAt: Date?
    /// The titles the rows were last loaded for (`CueRows.seeds`).
    private var loadedSeeds: [String]?
    /// New rows may be due (`CueRows.due`): a new day since the last load,
    /// other recent titles (you watched something), or a retry's time.
    /// Cheap: no disk, no network.
    var mightBeDue: Bool {
        guard let loadedAt else { return false }
        if let retryAt, Date() >= retryAt { return true }
        if CueRows.rebuildRequested { return true }
        return CueRows.dayKey(loadedAt) != CueRows.dayKey(Date())
            || loadedSeeds != CueRows.seeds(cueHistory?())
    }
    /// Cue's rows came back degraded (`CueRows.Saved.degraded`): made again
    /// from this time (`cueRetry` on).
    @Published private(set) var retryAt: Date?
    /// Cue's rows being made (`loadCueRows`).
    private var cueBuild: (seeds: [String], task: Task<CueRows.Saved, Never>)?
    static let cueRetry: TimeInterval = 5 * 60

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
        loadedOnce = false
        cueBuild = nil   // (the last profile's: not taken over)
        reloadRequest &+= 1
    }

    /// The billboard: its picks, filled with the rows' highlights while the
    /// picks aren't made yet.
    func billboard(max: Int = BillboardPicks.count) -> [BillboardPick] {
        // Today's Pick has its own card below: not on the billboard too.
        let spotlight = Set(entries.compactMap { row -> String? in
            row.shape == .spotlight ? row.items.first?.id : nil
        })
        func fits(_ item: MetaItem) -> Bool {
            !spotlight.contains(item.id)
        }
        let picks = billboardPicks.filter { fits($0.item) }
        return Array((picks.isEmpty ? highlights(max: max).filter { fits($0.item) } : picks).prefix(max))
    }

    /// Loaded for this profile (a profile switch loads again).
    private var loadedOnce = false
    /// Bumped by every load: a superseded run stops publishing.
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

    /// What "Because you watched" is made from (Home's stores; set by
    /// `HomeView`).
    var cueHistory: (@MainActor () -> BillboardPicks.History)?

    private static func entries(_ rows: [CueRows.Row]) -> [HomeRow] {
        rows.map { row in
            // An episode row: the episode's still as the card's picture, its
            // title under the show's name.
            let episodes = row.episodes ?? [:]
            var art = row.art ?? [:]
            var subtitles = row.subtitles ?? [:]
            for (id, episode) in episodes {
                if let still = episode.still { art[id] = still }
                if let name = episode.name, !name.isEmpty { subtitles[id] = name }
            }
            return HomeRow(id: row.id, title: row.title, items: row.items, subtitles: subtitles,
                           tabs: row.tabs, badges: row.badges ?? [:], art: art,
                           shape: row.shape ?? .poster, episodes: episodes, spare: row.spare ?? [])
        }
    }

    /// Cue's own rows (`CueRows`): the saved ones at once, new ones when
    /// they're due.
    private func loadCueRows() async {
        loadedOnce = true
        loadGeneration &+= 1
        let generation = loadGeneration
        let saved = await CueRows.saved()
        guard loadGeneration == generation else { return }
        if let saved, entries.isEmpty {
            entries = Self.entries(saved.rows)
        }
        // The launch's first: the saved rows shown, whether new ones are due
        // waits for the history (`LaunchPreloader.historySettled`).
        if loadedAt == nil {
            await LaunchPreloader.shared.historySettled()
            guard loadGeneration == generation else { return }
        }
        let history = cueHistory?()
        let seeds = CueRows.seeds(history)
        loadedSeeds = seeds
        CueRows.modelSource = {
            await CueRows.model(watches: history?.watches ?? [], standings: await CueRows.standings(history),
                                ratings: TitleRatings.shared.snapshot())
        }
        if CueRows.due(saved, seeds: seeds) {
            // A load arriving mid-build from the same titles takes its rows
            // (two at launch doubled every request to TMDB).
            let build = cueBuild.flatMap { $0.seeds == seeds ? $0.task : nil } ?? Task {
                let done = AppProbe.begin("data", "cue rows")
                let standings = await CueRows.standings(history)
                let built = await CueRows.build(watches: history?.watches ?? [], standings: standings,
                                                seeds: seeds, last: saved,
                                                passes: CueRows.Memory.shared.snapshot(),
                                                ratings: TitleRatings.shared.snapshot())
                done("\(built.rows.count) rows, taste from \(built.titles) titles, \(built.health ?? "")"
                     + (built.degraded == true ? " — degraded" : ""))
                return built
            }
            cueBuild = (seeds, build)
            let built = await build.value
            if cueBuild?.task == build { cueBuild = nil }
            guard loadGeneration == generation else { return }
            // Degraded (TMDB failed too many lists): whole rows saved before
            // stay, on screen and on disk; with none, these show. Either way
            // made again soon (`retryAt`), not kept for the day.
            retryAt = built.degraded == true ? Date().addingTimeInterval(Self.cueRetry) : nil
            let keepSaved = built.degraded == true && saved != nil && saved?.degraded != true
            if !built.rows.isEmpty, !keepSaved {
                entries = Self.entries(built.rows)
                CueRows.save(built)
            }
        }
        loadedAt = Date()
        warmSpotlightArt()
    }

    private func rebuildItemIndex() {
        var index: [String: MetaItem] = [:]
        var ordered: [MetaItem] = []
        for row in entries {
            for item in row.items where index[item.id] == nil {
                index[item.id] = item
                ordered.append(item)
            }
        }
        itemIndex = index
        orderedItems = ordered
    }

    /// Home's rows: Cue's own (`CueRows`), the saved ones at once, new ones
    /// when they're due (a load whose rows aren't due is cheap).
    func load() async {
        retryAt = nil
        await loadCueRows()
    }

    /// Once per profile; later loads come from `refreshIfDue`.
    func loadIfNeeded() async {
        guard entries.isEmpty || !loadedOnce else { return }
        await load()
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
    /// a dead frame), in row order, up to `max`, the row's own reason for
    /// it (its card's: who's in it, your taste, what's new) as the reason,
    /// else the row's name. Not a fact (Hidden gem, Acclaimed…): the line
    /// under the logo says those, on Details too. `type` filters for the
    /// Movies / Series tabs.
    private static let reasonKinds: Set<CardBadge.Kind> = [.person, .taste, .news, .returns]

    func highlights(max: Int) -> [BillboardPick] {
        var seen = Set<String>()
        var picks: [BillboardPick] = []
        for row in entries {
            let fresh = row.items.filter { item in
                item.background != nil && !seen.contains(item.id)
            }
            for item in fresh.prefix(2) {
                seen.insert(item.id)
                let own = row.badges[item.id].flatMap { Self.reasonKinds.contains($0.kind) ? $0 : nil }
                picks.append(BillboardPick(item: item, reason: own.map { .card($0) } ?? .row(title: row.title)))
                if picks.count == max { return picks }
            }
        }
        return picks
    }

}

struct HomeView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    /// Continue Watching's order.
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore

    // Owned by RootView so it PERSISTS across tab switches. If it were a local
    // @StateObject, switching away and back would rebuild HomeView with a fresh
    // (empty) model → a "Loading catalogs" spinner with no focusable element →
    // focus falls back to the sidebar, which reopened the panel.
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var library: LibraryStore
    /// Discover's sentences put on Home.
    @ObservedObject private var pins = DiscoverPins.shared
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
    /// Fires when the first load attempt finishes (success or error), so the
    /// root can re-enable the sidebar only once content exists to hold focus.
    var onContentReady: () -> Void = {}

    /// New rows when they're due (a new day, or you watched something) —
    /// only for the tab in front, never while something plays (it competed
    /// with the stream for bandwidth).
    private func refreshIfDue() {
        guard active, viewModel.mightBeDue, !NuvioSyncManager.playbackActive else { return }
        Task { await viewModel.load() }
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
    
    /// Cue's rows that go on Home.
    private var spotlightRows: [HomeRow] {
        viewModel.entries.filter { !$0.items.isEmpty && $0.onHome }
    }

    /// The rows in order: the billboard, Continue Watching, the Watchlist,
    /// the catalogs — filtered on Movies / Series.
    private func homeRows(_ featured: [HomeRow], _ continueRow: HomeRow?) -> [HomeRow] {
        var rows = featured
        if let continueRow { rows.append(continueRow) }
        rows += libraryRow
        rows += Self.placing(pins.rows, in: spotlightRows)
        return withoutWatched(rows)
    }

    /// Your rows (Discover's pins) in Cue's: from the second large-row slot
    /// on, in your order (the first stays Because You Watched), the
    /// catalogue's large rows moving down into the slots after them, so large
    /// rows still take turns with the fixed ones.
    private static func placing(_ pinned: [HomeRow], in rows: [HomeRow]) -> [HomeRow] {
        guard !pinned.isEmpty else { return rows }
        let slots = rows.indices.filter { rows[$0].tabs != nil && rows[$0].shape == .poster }
        guard !slots.isEmpty else { return pinned + rows }
        var large = slots.map { rows[$0] }
        large.insert(contentsOf: pinned, at: 1)
        var out = rows
        for (slot, row) in zip(slots, large) { out[slot] = row }
        return out
    }

    /// Hide watched titles: the catalog rows without watched films and
    /// finished shows, refilled from the titles next in line (`spare`) so
    /// a row keeps its slot; one left empty goes.
    private func withoutWatched(_ rows: [HomeRow]) -> [HomeRow] {
        guard hideWatched else { return rows }
        return rows.compactMap { row in
            // A ranked list keeps its ten: left out, the ranks would skip.
            if row.id == Spotlight.featuredRowID || row.id == Spotlight.continueRowID
                || row.id == Self.libraryRowID
                || row.shape == .ranked { return row }
            let unwatched = { (item: MetaItem) -> Bool in
                item.isSeries ? !finishedShows.contains(item.id) : !watched.isWatched(contentID: item.id)
            }
            var items = row.items.filter(unwatched)
            if items.count < row.items.count {
                items += row.spare.filter(unwatched).prefix(row.items.count - items.count)
            }
            guard !items.isEmpty else { return nil }
            return items.count == row.items.count ? row : row.with(items)
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

    var body: some View {
        Group {
            let cw = spotlightContinue
            // The billboard: Cue's picks (on Movies / Series, of that type).
            let picks = viewModel.billboard()
            let featured = picks.map(\.item)
            let featuredRow: [HomeRow] = featured.isEmpty || !Spotlight.showFeatured ? [] :
                [HomeRow(id: Spotlight.featuredRowID, title: "Featured", items: featured)]
            // Rows in UIKit (collection views), native focus, our own Core
            // Animation movement to the fixed box. Continue Watching, then
            // Saved for Later (the library), then the catalogs — on Movies /
            // Series, filtered to that type.
            let shownRows = homeRows(featuredRow, cw?.row)
            // Their pictures kept on disk over everything else.
            let _ = ImageCache.shared.protectHome(HomeRow.pictures(shownRows))
            HomeUIKitView(rows: shownRows,
                          featuredRowID: Spotlight.featuredRowID,
                          active: active,
                          continueRowID: Spotlight.continueRowID,
                          progress: cw?.progress ?? [:],
                          billboardReasons: Dictionary(picks.compactMap { pick in
                              pick.reason.map { (pick.id, $0) }
                          }, uniquingKeysWith: { first, _ in first }),
                          onSelect: onSelect,
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
            viewModel.cueHistory = { [progressStore, watched, library] in
                BillboardPicks.History(progress: progressStore, watched: watched, library: library)
            }
            // The background queue (TitlePreloader): Home's stores.
            TitlePreloader.shared.context = .init(
                addonManager: addonManager, mdb: mdblist.settings,
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
        // Discover's sentences put on Home: their titles.
        .task { await pins.refresh() }
        // New rows only as Home comes into view (back from the player, a
        // page or another tab) and as Cue comes back to the front, and only
        // when due: a new day, or you watched something. Never while it sits
        // open (an hourly check rebuilt them as you browsed, every 6 hours).
        .onChange(of: active) { _, isActive in if isActive { refreshIfDue() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshIfDue() } }
        // Degraded rows: made again at their retry time, once.
        .task(id: viewModel.retryAt) {
            guard let retryAt = viewModel.retryAt else { return }
            try? await Task.sleep(for: .seconds(max(1, retryAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            refreshIfDue()
        }
        // Another profile: its rows.
        .onChange(of: viewModel.reloadRequest) { _, _ in scheduleReload() }
        .task(id: nextUpRefreshKey) { await refreshNextUpContinueItems() }
        .task(id: continueStillsKey) {
            await stills.load(mergedContinueItems())
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
        await viewModel.loadIfNeeded()
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
        // Looked up and none of its own loads: the backdrop, not a dead link.
        if !stills.hasNone(progress), let thumb = progress.episodeThumbnail, !thumb.isEmpty { return thumb }
        return progress.background ?? progress.poster ?? catalogMeta(for: progress.metaID)?.background ?? catalogMeta(for: progress.metaID)?.poster
    }

    /// The episodes on Continue Watching, to look their stills up again
    /// when they change.
    private var continueStillsKey: String {
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

/// Continue Watching's episode pictures (Home's cards and the Top Shelf):
/// TMDB's still, as Details' episodes show it; where TMDB numbers the show
/// otherwise (Frieren's second season is TMDB's season 1 from episode 29:
/// S2:E3 is its S1:E31), the add-on's original numbering, else the TMDB
/// episode that aired the same day in an earlier season; else the add-on
/// thumbnails that really load (metahub's 404 for that episode left the card
/// empty for weeks, the Top Shelf on the show's backdrop); none: the caller's
/// backdrop. Looked up under the launch curtain (`LaunchPreloader`), then
/// whenever the row's episodes change; TMDB's seasons are on disk.
@MainActor
final class ContinueStills: ObservableObject {
    static let shared = ContinueStills()
    /// By episode: its picture, "" when it has none (the backdrop then).
    @Published private(set) var stills: [String: String] = [:]
    private var running: [String: Task<String?, Never>] = [:]

    nonisolated static func key(_ progress: WatchProgress) -> String? {
        guard let season = progress.season, let episode = progress.episode else { return nil }
        return "\(progress.metaID):\(season):\(episode)"
    }

    func still(for progress: WatchProgress) -> String? {
        Self.key(progress).flatMap { stills[$0] }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Looked up and found to have no picture of its own: not the stored
    /// thumbnail either (the backdrop instead).
    func hasNone(_ progress: WatchProgress) -> Bool {
        Self.key(progress).flatMap { stills[$0] } == ""
    }

    /// Looks up the episodes not yet known; returns the pictures of `rows`.
    @discardableResult
    func load(_ rows: [WatchProgress]) async -> [String] {
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                guard let season = row.season, let episode = row.episode else { continue }
                group.addTask { @MainActor in
                    _ = await self.picture(metaID: row.metaID, type: row.type, season: season, episode: episode,
                                           thumbnail: row.episodeThumbnail)
                }
            }
        }
        return rows.compactMap(still(for:))
    }

    /// One episode's picture (nil: none — the backdrop), once per launch;
    /// a lookup that failed on the network is tried again next time.
    func picture(metaID: String, type: String, season: Int, episode: Int, thumbnail: String?) async -> String? {
        let key = "\(metaID):\(season):\(episode)"
        if let known = stills[key] { return known.isEmpty ? nil : known }
        if let task = running[key] { return await task.value }
        let task = Task { @MainActor () -> String? in
            let (found, definite) = await Self.find(metaID: metaID, type: type, season: season,
                                                    episode: episode, thumbnail: thumbnail)
            if found != nil || definite { self.stills[key] = found ?? "" }
            return found
        }
        running[key] = task
        let found = await task.value
        running[key] = nil
        return found
    }

    /// The picture, and whether a nil is the answer (not a network failure).
    private static func find(metaID: String, type: String, season: Int, episode: Int,
                             thumbnail: String?) async -> (String?, Bool) {
        func tmdb(_ season: Int, _ episode: Int) async -> String? {
            guard TMDBService.hasAPIKey else { return nil }
            let extras = await TMDBService.seasonEpisodes(imdbID: metaID, type: type, season: season)
            return TMDBService.originalSize(extras[episode]?.still)
        }
        if let still = await tmdb(season, episode) { return (still, true) }
        // The add-on's episode: its original numbering, air date, thumbnail.
        var video: MetaVideo?
        // Without the add-ons (Home not set up yet): asked again later.
        var failed = TitlePreloader.shared.context == nil
        if let addons = TitlePreloader.shared.context?.addonManager {
            let meta = await SeriesEpisodes.fullMeta(for: MetaItem(id: metaID, type: type, name: ""),
                                                     addonManager: addons)
            video = meta.videos?.first { $0.season == season && $0.episode == episode }
        }
        if let s = video?.originalSeason, let e = video?.originalEpisode, (s, e) != (season, episode),
           let still = await tmdb(s, e) { return (still, true) }
        if TMDBService.hasAPIKey, let video, season > 1 {
            let extras = await TMDBService.seasonEpisodes(imdbID: metaID, type: type, season: season, videos: [video])
            if let still = TMDBService.originalSize(extras[episode]?.still) { return (still, true) }
        }
        for url in [video?.thumbnail, thumbnail].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            switch await ImageCache.shared.fetchPicture(url) {
            case .some(true): return (url, true)
            case .some(false): continue
            case .none: failed = true
            }
        }
        return (nil, !failed)
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

    /// The page in front: up to its billboard, focus not stopping there.
    var passUp: ((@escaping () -> Void) -> Void)?

    /// Back: below the billboard the page goes up to it first; `then`
    /// once it's on the way (focus to the top bar).
    func handle(then: @escaping () -> Void) {
        guard depth > 0, let passUp else { return then() }
        passUp(then)
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

    /// Focus is on the billboard: which of its titles (nil: in the rows).
    @State private var billboard: FixedFocusBillboardPosition?
    /// The billboard paging by itself: the next title, as a press would.
    @State private var billboardCommand: FixedFocusRowsCommand?
    @AppStorage(BillboardAutoPage.key) private var autoPage = true
    @AppStorage(DetailHideSpoilers.key) private var hideSpoilers = false
    /// The billboard's trailer (Settings → Home & Details → Trailers).
    @StateObject private var trailer = StageTrailer()
    @EnvironmentObject private var homeSettings: HomeCatalogSettingsStore
    @ObservedObject private var trailerGate = TrailerGate.shared
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
    /// Details (opened from the billboard) is taking / has taken over: the
    /// billboard's own cues (hint, dots) are out.
    /// Details is up over Home (the billboard doesn't page behind it).
    @ObservedObject private var detailsOpen = DetailsOpen.shared
    /// This tab's say in `BillboardSight`.
    @State private var sightKey = UUID()
    /// …and its picture has stepped closer (see `StagePictureView`).

    /// The dots' last state (so they fade out unchanged).
    @State private var lastBillboard: FixedFocusBillboardPosition?
    /// The billboard's buttons' focus.

    var body: some View {
        ZStack(alignment: .topLeading) {
            homeLayers
        }
        // Back: this page's first say while it's in front (`HomeBack`).
        .onAppear { if active { takeBack() } }
        .onChange(of: active) { _, now in if now { takeBack() } }
    }

    /// Back below the billboard: all the way up to it, in one move (its
    /// title as it is, the rows keeping their places). On it: not ours —
    /// the top bar's.
    private func takeBack() {
        HomeBack.shared.depth = depth
        HomeBack.shared.toBillboard = { billboardCommand = FixedFocusRowsCommand(action: .focusBillboard) }
        HomeBack.shared.passUp = { then in billboardCommand = FixedFocusRowsCommand(action: .passUp, then: then) }
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
            ATVBackground()
            FixedFocusRows(rows: rows, featuredRowID: featuredRowID, continueRowID: continueRowID,
                           active: active,
                           progress: progress,
                           // Episode rows: Continue Watching's cards.
                           landscapeRowIDs: Set(rows.filter { $0.shape == .episode }.map(\.id)),
                           // Every row: moving focus, its cards by its
                           // shape (`CueRows.CardShape`; posters unless said).
                           destinationRowIDs: Set(rows.map(\.id).filter { $0 != featuredRowID }),
                           // Top 10: each card's place beside it.
                           rankedRowIDs: Set(rows.filter { $0.shape == .ranked }.map(\.id)),
                           showcaseRowIDs: Set(rows.filter { $0.shape == .tall || $0.shape == .spotlight }.map(\.id)),
                           showcaseTrailers: (homeSettings.heroTrailersEnabled, homeSettings.heroTrailerSound),
                           spotlightRowIDs: Set(rows.filter { $0.shape == .spotlight }.map(\.id)),
                           featureRows: true, captions: false, centred: true,
                           onSelect: onSelect,
                           onSelectFeatured: { openBillboardTitle($0) },
                           onResume: onResume,
                           // A title's card: into Details (`DetailTransition`).
                           onOpenDetails: onSelectFeatured.map { push in
                               { item in DetailTransition.shared.open(item) { push(item) } }
                           },
                           onContinueMenu: { act($0, on: $1) },
                           titleMenu: { item, rowID in
                               TitleMenu.shared.entries(for: item)
                           },
                           onDepth: {
                               depth = $0
                               if active { HomeBack.shared.depth = $0 }
                           },
                           // The billboard's focus: the card itself (its
                           // hidden cards: Left/Right page, Select opens,
                           // hold: the card's menu). (Its buttons, as
                           // Details', were before.)
                           externalBillboard: false,
                           cardStates: HomeRow.episodeStates(rows, hideSpoilers: hideSpoilers, watched: watchedStore),
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
                           billboardOverlay: billboardOverlay,
                           billboardOverlayBelowRows: true,
                           // Its text on its pictures: each title one card.
                           billboardPageText: { AnyView(billboardText($0)) },
                           // The picture under the text: the controller's own,
                           // moved with the billboard's distance.
                           pinnedBillboardPicture: true,
                           billboardTrailer: trailer,
                           rigidBillboardTravel: Self.rigidBillboardTravel,
                           billboardCard: StagePictureView.homeCard,
                           billboardCardFocus: true) { item, position in
                // Every arrival on the billboard (back from the top bar, on
                // the same title too) starts its paging clock over.
                if position != nil { autoPageVisit &+= 1 }
                // At the last title: done for this visit (see `autoPageDone`).
                if let position, position.index == position.count - 1 { autoPageDone = true }
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
    /// The reason, status, fact and ratings on plates in the top corners
    /// (`BillboardCorners`: Home's card, Details): only logo, facts and
    /// tagline (Details' line still over the logo).
    var corners = false

    static let width = FixedFocusMetrics.boxWidth - 2 * FixedFocusMetrics.textIndent
    static let logoToChips: CGFloat = 20
    /// The status, one badge of the cards' (the first fact that holds:
    /// finale, Hidden gem, Acclaimed, Miniseries; the news is the reason's),
    /// then the ratings.
    private var chips: some View {
        HStack(spacing: RatingChip.spacing) {
            ForEach([FixedFocusShowInfo.status(item)].compactMap { $0 }, id: \.self) {
                TitleBadge(text: $0)
            }
            if let fact = TitleRecords.shared.facts(item).first {
                BadgeLabel(badge: .init(symbol: FixedFocusBadges.symbol(fact.kind), text: fact.text))
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

    /// THE BLOCK'S GAPS, as seen (between what's drawn, not the lines'
    /// frames): `space` between its parts (reason, logo, the lines under
    /// it, the buttons), `gap` between those lines (chips, facts,
    /// tagline). (The chips were boxes once, with more room round them;
    /// 19 above the logo read as part of its art.)
    static let space: CGFloat = 34
    static let gap: CGFloat = 19
    /// Every logo covers about this much (pt²): e.g. 420 × 110 wide,
    /// 260 × 160 (its height cap) near square.
    static let logoArea: CGFloat = 46_000
    static let logoMaxSize = CGSize(width: TitleBlock.logoWidth, height: TitleBlock.logoHeight)
    /// The reason ⇄ Details' line (into Details in place).
    static let leadSwap = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                                   removal: .opacity.combined(with: .offset(y: -6)))
    /// The reason's and chips' line frames (30 pt) hold this much above
    /// their capitals and below their baseline.
    static let labelInset: CGFloat = 6.5
    /// THE BLOCK'S TEXT (facts, tagline): one size, a little above the
    /// base; its line's frame and what that holds above its capitals /
    /// below its baseline.
    static let textSize: CGFloat = 26
    static let lineHeight: CGFloat = 32
    static let lineInset: CGFloat = 7
    /// How many rating sources show (the first ones, in Settings' order).
    static let ratingsShown = 3
    /// The description under the tagline (`VibrantSummary`): five lines'
    /// room, narrower than the block so it stays on the shade's dark side.
    /// Hidden for now (billboard and Details), the billboard being
    /// reworked; `VibrantSummary` kept for text on pictures elsewhere.
    static let showsSummary = false
    static let summaryWidth: CGFloat = 600
    static let summaryLines = 5
    static let summarySpacing: CGFloat = 4
    static var summaryHeight: CGFloat {
        let line = UIFont.systemFont(ofSize: FixedFocusMetrics.textSize).lineHeight
        return (line * CGFloat(summaryLines) + summarySpacing * CGFloat(summaryLines - 1)).rounded(.up)
    }
    /// The chips line: the status badge, then the first ratings (nil: none).
    @MainActor
    static func ratingsChips(_ ratings: MDBListRatings?, settings: MDBListSettings, item: MetaItem,
                             onDetails: Bool = false) -> AnyView? {
        let entries = MDBListRatingsRow.entries(ratings, settings: settings, onDetails: onDetails)
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
            if Self.showsSummary {
                VibrantSummary(text: FixedFocusMetrics.descriptionText(item) ?? "")
                    .frame(width: Self.summaryWidth, height: Self.summaryHeight, alignment: .topLeading)
                    .padding(.top, Self.gap - Self.lineInset)
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One place, the reason or Details' line: swapped, the old one
            // rising out as it fades, the new one coming up into it.
            if !corners || lead != nil {
            ZStack(alignment: .leading) {
                if let reason, !corners {
                    BillboardReasonLabel(reason: reason)
                        .transition(Self.leadSwap)
                } else if let lead {
                    lead
                        .transition(Self.leadSwap)
                }
            }
            .frame(height: 30, alignment: .leading)
            .padding(.bottom, Self.space - Self.labelInset)
            }
            logoView

            VStack(alignment: .leading, spacing: 0) {
                // The status badge, a fact and the ratings.
                if !corners {
                    chips
                        .padding(.top, Self.space - Self.labelInset)
                }
                // THE FACTS — what it is, quieter than the logo and the
                // chips. (Without the rating: the chips carry it.)
                Text(FixedFocusShowInfo.factsLine(item, info: info))
                    .font(.system(size: Self.textSize, weight: .medium))
                    .foregroundStyle(CueInk.body)
                    .lineLimit(1)
                    .frame(height: Self.lineHeight, alignment: .leading)
                    .padding(.top, corners ? Self.space - Self.lineInset
                                           : Self.gap - Self.labelInset - Self.lineInset)
                // The tagline — the mood, quiet and italic; no tagline: the
                // name (ALWAYS a line here: every title's block has the same
                // height, nothing moves).
                Text(tagline ?? item.name)
                    .font(.system(size: Self.textSize, weight: .regular).italic())
                    .foregroundStyle(CueInk.secondary)
                    .lineLimit(1)
                    .frame(height: Self.lineHeight, alignment: .leading)
                    .padding(.top, Self.gap - 2 * Self.lineInset)
            }
        }
    }
}

/// The billboard's reason, as the cards' top badge: its symbol and words in
/// sentence case on the shade, the detail a level down ("🔔 New episode ·
/// S3 E7 · Yesterday", "♥ Because you watched Dark", "📈 Trending today";
/// spaced capitals with the rank in a white key were the look before).
private struct BillboardReasonLabel: View {
    let reason: BillboardReason

    var symbol: FixedFocusBadges.Symbol? {
        switch reason {
        case .newEpisode, .newSeason: return FixedFocusBadges.symbol(.news)
        case .because: return FixedFocusBadges.symbol(.taste)
        case .trending: return FixedFocusBadges.symbol(.top10)
        case .card(let badge): return FixedFocusBadges.symbol(badge.kind)
        case .row: return nil
        }
    }

    var detail: String? {
        if case .trending(let rank) = reason { return "No. \(rank)" }
        return reason.detail
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                let colours = symbol.colours.map { Color(uiColor: $0) }
                Image(systemName: symbol.name)
                    .font(.system(size: FixedFocusMetrics.textSize - 2, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(colours[0], colours.count > 1 ? colours[1] : colours[0])
            }
            (Text(reason.lead).foregroundStyle(CueInk.primary)
             + Text(detail.map { separator + $0 } ?? "")
                .foregroundStyle(CueInk.body))
                .font(Font(FixedFocusText.infoFont(FixedFocusMetrics.textSize)))
        }
        .lineLimit(1)
    }

    /// "Because you watched" runs on into its title; the others get a dot.
    var separator: String {
        if case .because = reason { return " " }
        return " · "
    }
}

/// TRYING: Home's billboard card in the cards' layout — top left the
/// reason, the status and one fact, each on the cards' plate
/// (`FixedFocusBadges`: a deep shade of the picture's colour, its ink);
/// top right the ratings (the first three sources) on one plate.
/// The billboard's badges on the cards' plates in its top corners: the
/// reason, status and one fact top left, the ratings top right (Home's
/// card: the first three; Details: all, as Details shows them).
struct BillboardCorners: View {
    let item: MetaItem
    let reason: BillboardReason?
    var details = false
    /// Changed when the title's records were read again (redraws it).
    var revision = 0
    @State private var tint: UIColor?

    private var url: String? { TMDBService.originalSize(item.background) ?? item.poster }

    private func ink(_ level: CGFloat) -> Color {
        Color(uiColor: tint.map { SourceTint.ink($0, level) } ?? UIColor.white.withAlphaComponent(level))
    }

    var body: some View {
        HStack(alignment: .top, spacing: FixedFocusBadges.gap) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FixedFocusBadges.gap) { reasonPlate; badgePlates }
                VStack(alignment: .leading, spacing: FixedFocusBadges.gap) {
                    reasonPlate
                    HStack(spacing: FixedFocusBadges.gap) { badgePlates }
                }
            }
            Spacer(minLength: 0)
            ratingsPlate
        }
        .task(id: url) {
            guard let url else { tint = nil; return }
            if let known = SourceTint.cached(for: url) { tint = known; return }
            tint = nil
            let sampled = await SourceTint.tint(for: url)
            withAnimation(.easeInOut(duration: Motion.fadeDuration)) { tint = sampled }
        }
    }

    @ViewBuilder private var reasonPlate: some View {
        if let reason {
            let label = BillboardReasonLabel(reason: reason)
            plate(symbol: label.symbol) {
                Text(reason.lead).foregroundStyle(ink(FixedFocusText.primary))
                + Text(label.detail.map { label.separator + $0 } ?? "")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(ink(FixedFocusText.body))
            }
        }
    }

    @ViewBuilder private var badgePlates: some View {
        if let status = FixedFocusShowInfo.status(item) {
            let badge = FixedFocusBadges.status(status)
            plate(symbol: badge.symbol) { Text(badge.text).foregroundStyle(ink(FixedFocusText.primary)) }
        }
        if let fact = TitleRecords.shared.facts(item).first {
            plate(symbol: FixedFocusBadges.symbol(fact.kind)) {
                Text(fact.text).foregroundStyle(ink(FixedFocusText.primary))
            }
        }
    }

    private var ratings: [MDBListRatingEntry] {
        let settings = MDBListSettingsStore.current
        guard settings.showsRatings(onDetails: details) else { return [] }
        let known = TitleRecords.shared.ratings(item) ?? nil
        let all = MDBListRatingsRow.entries(known, settings: settings, onDetails: details)
        return details ? all : Array(all.prefix(FixedFocusBillboardText.ratingsShown))
    }

    @ViewBuilder private var ratingsPlate: some View {
        let all = ratings
        if !all.isEmpty {
            HStack(spacing: 20) {
                ForEach(all) { entry in
                    HStack(spacing: 9) {
                        if let mark = FixedFocusBadges.mark(entry.provider) { Image(uiImage: mark) }
                        Text(entry.text).foregroundStyle(ink(FixedFocusText.primary))
                    }
                }
            }
            .font(Font(FixedFocusBadges.font))
            .modifier(Plate(colour: FixedFocusBadges.plate(tint)))
        }
    }

    private func plate(symbol: FixedFocusBadges.Symbol?, @ViewBuilder words: () -> Text) -> some View {
        HStack(spacing: 9) {
            if let symbol {
                let colours = symbol.colours.map {
                    $0 == FixedFocusBadges.symbolGrey ? ink(FixedFocusText.body) : Color(uiColor: $0)
                }
                Image(systemName: symbol.name)
                    .font(.system(size: 21, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(colours[0], colours.count > 1 ? colours[1] : colours[0])
            }
            words()
                .endFade()
        }
        .font(Font(FixedFocusBadges.font))
        .lineLimit(1)
        .modifier(Plate(colour: FixedFocusBadges.plate(tint)))
    }

    private struct Plate: ViewModifier {
        let colour: UIColor
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, FixedFocusBadges.padding)
                .frame(height: FixedFocusBadges.height)
                .background(Color(uiColor: colour),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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
        return TitleBlock.metaSegments(for: item, seriesSize: size, startYearOnly: true)
            .joined(separator: "  •  ")
    }
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

/// The text's colour at a level (`FixedFocusText`), in tvOS's appearance:
/// dark, white at the level; light, near-black (tvOS's own light grey
/// text) at 85, 70, 55, 42 % for the four levels. What sits on a picture
/// (Details, the billboard, a card's art, the player, glass) is kept dark
/// (`overrideUserInterfaceStyle`, `colorScheme`), so it stays white there.
enum CueInk {
    static func ui(_ level: CGFloat) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .light
                ? UIColor.black.withAlphaComponent(onLight(level))
                : UIColor.white.withAlphaComponent(level)
        }
    }

    static func color(_ level: CGFloat) -> Color { Color(uiColor: ui(level)) }

    static let primary = color(FixedFocusText.primary)
    static let body = color(FixedFocusText.body)
    static let secondary = color(FixedFocusText.secondary)
    static let tertiary = color(FixedFocusText.tertiary)

    /// A level on light: tvOS's text grey (~58 % black: 0.32 on its 0.75)
    /// for primary, the rest a step dimmer each; between them in
    /// step (dimmer on dark is dimmer on light too).
    static func onLight(_ level: CGFloat) -> CGFloat {
        let dark: [CGFloat] = [FixedFocusText.tertiary, FixedFocusText.secondary, FixedFocusText.body, FixedFocusText.primary]
        let light: [CGFloat] = [0.40, 0.46, 0.52, 0.58]
        if level <= dark[0] { return light[0] * level / dark[0] }
        for i in 1..<dark.count where level <= dark[i] {
            let t = (level - dark[i - 1]) / (dark[i] - dark[i - 1])
            return light[i - 1] + t * (light[i] - light[i - 1])
        }
        // (Past primary, to black: the controls' words, as tvOS's rows.)
        return min(1, light[3] + (level - dark[3]) / (1 - dark[3]) * (1 - light[3]))
    }

    /// A fill in the page (flat controls at rest, rows): white at `dark` on
    /// dark; on light, white at `light` (tvOS's light rows are lighter than
    /// the grey, not darker).
    static func fill(dark: CGFloat, light: CGFloat) -> Color {
        Color(uiColor: uiFill(dark: dark, light: light))
    }
    static func uiFill(dark: CGFloat, light: CGFloat) -> UIColor {
        UIColor { $0.userInterfaceStyle == .light
            ? UIColor.white.withAlphaComponent(light) : UIColor.white.withAlphaComponent(dark) }
    }
}

/// The focused card's look: the unfocused cards' edge, bright (no ring
/// around the card), a soft shadow under it and, where cards grow, the
/// same growth on every card's longer side (`FixedFocusMetrics.focusGrowth`).
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
    /// buttons too (`autoPageDone`). Never while Details is up, or opening
    /// (from the press: it's counted open only once pushed) — Back must
    /// find the title it left.
    var autoPagePossible: Bool {
        guard let billboard else { return false }
        // It stops at the last title (no wrap back to the first).
        return autoPage && billboard.index < billboard.count - 1
            && homeScenePhase == .active && active && detailsOpen.depth == 0
            && !DetailTransition.shared.busy
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
            // The position, under the buttons at the card's foot, right
            // (`StagePictureView.dotsY`); up with the card.
            if let shown = billboard ?? lastBillboard {
                let card = StagePictureView.homeCard
                BillboardDots(count: shown.count, current: shown.index, focused: true,
                              timer: autoPageRunning ? BillboardAutoPage.interval : nil,
                              cycle: autoPageVisit)
                    .frame(width: card.width - 2 * StagePictureView.cardMargin,
                           height: BillboardDots.dot, alignment: .trailing)
                    .offset(x: card.minX + StagePictureView.cardMargin, y: StagePictureView.dotsY)
            }
        }
        // (Top-left: without the picture the layer is only as large as its
        // text — centred, it all moved down.)
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    /// The billboard's title now (its text may still be crossfading to it).
    private var billboardTitle: MetaItem? {
        guard let position = billboard ?? lastBillboard,
              let row = rows.first(where: { $0.id == featuredRowID }),
              row.items.indices.contains(position.index) else { return billboardItem }
        return row.items[position.index]
    }

    /// Select on the billboard card: into Details, a window growing out of
    /// the card (it shows Details' picture: `DetailTransition.Window`).
    /// A trailer playing goes on into Details (`StageTrailer.handOver`).
    func openBillboardTitle(_ item: MetaItem) {
        guard let onSelectFeatured else { onSelect(item); return }
        DetailTransition.shared.open(item, keepsPicture: true, trailer: trailer.handOver(),
                                     from: StagePictureView.homeCardShown?.openingWindow()) { onSelectFeatured(item) }
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
    }

    /// The billboard's text for a title, at its place (standing on its
    /// bottom line — it grows up — the buttons below it).
    /// (The reason — Details has none — goes with the swap; the rest stays
    /// exactly: Details' text is the billboard's.)
    private func billboardText(_ item: MetaItem) -> some View {
        // (What's in memory already — loaded ahead, `TitleExtras` — draws
        // with the text, not a moment after it.)
        let _ = billboardRecord
        let records = TitleRecords.shared
        let card = StagePictureView.homeCard
        let margin = StagePictureView.cardMargin
        // TRYING: the cards' layout — the reason, status and fact on plates
        // top left, the ratings on one top right; logo, facts and tagline
        // at the foot.
        return ZStack(alignment: .topLeading) {
            FixedFocusBillboardText(item: item, info: records.size(item),
                                    reason: nil,
                                    ratings: billboardRatingsRow(item),
                                    tagline: records.tagline(item),
                                    corners: true)
                .frame(height: StagePictureView.textBottom(card), alignment: .bottomLeading)
                .padding(.leading, FixedFocusMetrics.titleInset + StagePictureView.textIn(card))
            // The plates' contents on the text's edges (the reason's symbol
            // over the logo's left, the last score over the dots' right
            // end), the plates past them; as far from the top as from the
            // side, as on the cards.
            let inset = margin - FixedFocusBadges.padding
            BillboardCorners(item: item, reason: billboardReasons[item.id])
                .frame(width: card.width - 2 * inset, alignment: .topLeading)
                .offset(x: card.minX + inset, y: card.minY + inset)
        }
    }

    /// The ratings chips (nil: none at all) — the catalog's IMDb score until
    /// MDBList's arrive, as on the Detail page.
    private func billboardRatingsRow(_ item: MetaItem) -> AnyView? {
        FixedFocusBillboardText.ratingsChips(TitleRecords.shared.ratings(item) ?? nil,
                                             settings: mdblist.settings, item: item)
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
