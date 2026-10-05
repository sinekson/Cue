import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [MetaItem] = []
    /// How well known the titles of this search are (TMDB) — for the order.
    @Published var fame: [TMDBService.SearchFame] = []
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?

    func search(addonManager: AddonManager) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            fame = []
            isSearching = false
            return
        }
        isSearching = true
        let targets: [(InstalledAddon, ManifestCatalog)] = Self.searchTargets(addonManager)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            // TMDB's view of the same search, side by side with the add-ons'.
            async let fame = TMDBService.searchFame(trimmed)

            // Collect by target INDEX, not by completion. `for await` on a task
            // group yields in the order tasks finish, so the merged list was
            // ordered by whichever add-on answered fastest — a race. A slow
            // Cinemeta behind a fast torrent aggregator put junk on top, and
            // the same search could come back in a different order twice in a
            // row. Now the order is the one `searchTargets` decided.
            var byTarget = [Int: [MetaItem]](minimumCapacity: targets.count)
            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                for (index, target) in targets.enumerated() {
                    // Resolved out here: the class is @MainActor, so the
                    // task's body can't reach its static members.
                    let cap = Self.limit(for: target.0)
                    group.addTask {
                        let items = (try? await StremioAPI.catalog(
                            addon: target.0, catalog: target.1, search: trimmed)) ?? []
                        // Cap each catalog's contribution. One add-on
                        // returning hundreds of per-release rows buried every
                        // other add-on's real titles.
                        return (index, Array(items.prefix(cap)))
                    }
                }
                for await (index, items) in group { byTarget[index] = items }
            }
            guard !Task.isCancelled else { return }

            var merged: [MetaItem] = []
            var seen = Set<String>()
            for index in targets.indices {
                // Keyed on `id` alone: the grids' `ForEach` identify rows by
                // `MetaItem.id`, so "tt123" as `series` from one addon and
                // as `tv` from another must not both survive.
                for item in byTarget[index] ?? [] where !seen.contains(item.id) {
                    seen.insert(item.id)
                    merged.append(item)
                }
            }
            let known = await fame
            guard !Task.isCancelled else { return }
            self.fame = known
            results = merged
            isSearching = false
        }
    }

    /// Most results one catalog may contribute to a search.
    private static let perCatalogLimit = 40
    /// A much tighter cap for stream-only source add-ons. Ranking them last
    /// stops them leading the results but not from filling the tail: four
    /// searchable catalogs at the normal cap is still 160 per-release rows
    /// behind the real titles. They keep a foothold rather than a flood.
    private static let sourceAddonLimit = 8

    private static func limit(for addon: InstalledAddon) -> Int {
        searchRank(addon) == 2 ? sourceAddonLimit : perCatalogLimit
    }

    /// Every searchable catalog, metadata add-ons first.
    ///
    /// Search is for finding TITLES. An add-on that provides `meta` describes
    /// titles; one that only provides `stream` is a source aggregator whose
    /// catalog lists individual releases. When such an add-on sat above
    /// Cinemeta in the list, search filled up with single torrents for random
    /// episodes and users had to reorder their add-ons by hand to get it back.
    /// Ordering by capability rather than by install position is that
    /// workaround, done automatically.
    ///
    /// Source add-ons are still searched, just last — excluding them outright
    /// would silently drop results from a legitimately configured add-on.
    static func searchTargets(_ addonManager: AddonManager) -> [(InstalledAddon, ManifestCatalog)] {
        addonManager.catalogAddons
            .enumerated()
            // `sorted` is not documented as stable, so the install index is an
            // explicit tiebreaker — without it, add-ons of equal rank could
            // reshuffle between searches.
            .sorted { a, b in
                let (ra, rb) = (Self.searchRank(a.element), Self.searchRank(b.element))
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .flatMap { entry in
                (entry.element.manifest.catalogs ?? [])
                    .filter { $0.supportsSearch }
                    .map { (entry.element, $0) }
            }
    }

    /// Lower sorts first: metadata providers, then anything else, then
    /// stream-only source add-ons.
    private static func searchRank(_ addon: InstalledAddon) -> Int {
        if addon.manifest.providesMeta { return 0 }
        if addon.manifest.providesStreams { return 2 }
        return 1
    }
}

/// SEARCH: Apple's own search field and keyboard at the top (dictation with
/// the remote's mic); below it — recent searches while it's empty — in a fixed
/// area (nothing scrolls — the keyboard stays where it is), the results on
/// Home's rows:
/// - TOP RESULT first: a small billboard (logo, facts, chips, summary over
///   its backdrop — see `FixedFocusBannerCell`);
/// - then Movies and Series (the top result's kind first): posters at a
///   glance, name and year under each (Home's destination rows).
/// One row view: Up and Down between them are the rows' own moves.
struct SearchView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    // Owned by RootView so the query + results PERSIST across tab switches.
    @ObservedObject var viewModel: SearchViewModel
    /// Its tab is in front (the rows leave the focus engine otherwise).
    var active = true

    let onSelect: (MetaItem) -> Void
    /// Details, pushed without the system's slide (the Top Result's window
    /// has already brought it in).
    var onOpenInPlace: (MetaItem) -> Void = { _ in }

    /// Recent searches (newest first), shown while the field is empty.
    @AppStorage("cue.search.recent") private var recentStorage = ""
    private var recent: [String] { recentStorage.split(separator: "\n").map(String.init) }

    static let topRowID = "search.top"
    static let moviesRowID = "search.movies"
    static let seriesRowID = "search.series"

    /// The focused row's name, in the area below the keyboard.
    private static let rowsTop: CGFloat = 24
    /// Posters here: smaller than Home's — about half its space is the
    /// keyboard's — seven across.
    private static let posterHeight: CGFloat = 330
    /// The gap between a row (with its captions) and the next one's name.
    private static let rowGap: CGFloat = 48

    /// The top result's banner: at most the usual banner's height, less
    /// when the area is tight (the next row's name still shows).
    private static func topResultHeight(area: CGFloat) -> CGFloat {
        min(FixedFocusMetrics.bannerHeight, area - rowsTop - 2 * FixedFocusMetrics.titleHeight - rowGap - 40)
    }

    /// The next row starts right under the focused one (the taller of the
    /// banner and a poster row with its captions, then the gap): its name
    /// and the top of its posters show — no empty band.
    private static func belowVisible(area: CGFloat) -> CGFloat {
        let tallest = max(topResultHeight(area: area), posterHeight + FixedFocusMetrics.captionRoom)
        let nextTop = rowsTop + FixedFocusMetrics.titleHeight + tallest + rowGap
        return max(18, area - nextTop - FixedFocusMetrics.titleHeight)
    }

    /// The system's search field is sized for a whole screen of search;
    /// here it sits above results: a calmer size (the text it shows — the
    /// keyboard is the system's own).
    private static func styleSearchField() {
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).font =
            .systemFont(ofSize: 40, weight: .medium)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ATVBackground()
            // The full width and down to the bottom edge, as on Home: the
            // rows place themselves in screen coordinates.
            GeometryReader { geo in
                results(area: geo.size.height)
            }
            .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
        .searchable(text: $viewModel.query, prompt: "Movies and series")
        .onAppear(perform: Self.styleSearchField)
        .onChange(of: viewModel.query) { _, _ in
            viewModel.search(addonManager: addonManager)
        }
    }

    @ViewBuilder
    private func results(area: CGFloat) -> some View {
        let rows = Self.rows(Self.ranked(viewModel.results, for: viewModel.query, fame: viewModel.fame)
            .map(Self.withArt))
        if !rows.isEmpty {
            FixedFocusRows(rows: rows, featuredRowID: "", continueRowID: "", active: active,
                           billboardStepIn: false, progress: [:],
                           // Movies and Series: posters at a glance, Home's
                           // destination rows (Saved for Later's look).
                           destinationRowIDs: [Self.moviesRowID, Self.seriesRowID],
                           // The Top Result: a small billboard.
                           bannerRowIDs: [Self.topRowID],
                           bannerHeight: Self.topResultHeight(area: area),
                           destinationPosterHeight: Self.posterHeight,
                           rowTop: Self.rowsTop,
                           // Rows above: entirely out of the area, the name
                           // and facts under their cards too.
                           aboveVisible: -(FixedFocusMetrics.infoHeight + 24),
                           belowVisible: Self.belowVisible(area: area),
                           ringOnlyWithFocus: true,
                           startsOverOnChange: true,
                           onSelect: select, onSelectFeatured: select,
                           onResume: { _ in },
                           onOpenWindow: openThroughWindow,
                           titleMenu: { item, _ in TitleMenu.shared.entries(for: item) }) { _, _ in }
                .frame(width: 1920, height: area)
                // Nothing slides over the keyboard.
                .clipped()
        } else if viewModel.isSearching {
            CueLoadingView(label: "Searching").frame(maxWidth: .infinity).frame(height: 420)
        } else if viewModel.query.count >= 2 {
            CueEmptyState(icon: "magnifyingglass", title: "No results",
                          message: "Nothing matched “\(viewModel.query)”.")
                .frame(maxWidth: .infinity).frame(height: 420)
        } else if viewModel.query.isEmpty, !recent.isEmpty {
            recentSearches
        } else {
            Text("Search for a movie or a series — or hold the microphone button and say it.")
                .font(.system(size: FixedFocusMetrics.textSize))
                .foregroundStyle(AppGlass.textMuted)
                .padding(.leading, FixedFocusMetrics.titleInset)
                .padding(.top, 64)
        }
    }

    /// The field empty: the recent searches (newest first) as small pills —
    /// Select searches again — and Clear. Ours, not the system's
    /// suggestions (those can't be sized: they were huge above results).
    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Recent searches")
                .font(.system(size: FixedFocusMetrics.textSize, weight: .semibold))
                .foregroundStyle(AppGlass.textMuted)
            HStack(spacing: 16) {
                ForEach(recent, id: \.self) { search in
                    Button { viewModel.query = search } label: {
                        Label(search, systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(PillButtonStyle())
                }
                Button { recentStorage = "" } label: {
                    Label("Clear", systemImage: "xmark")
                }
                .buttonStyle(PillButtonStyle(quiet: true))
            }
        }
        .padding(.leading, FixedFocusMetrics.titleInset)
        .padding(.top, 48)
        .focusSection()
    }

    /// A result's Select: Details opens through a window from its card (see
    /// `DetailWindow`), and the query joins the recent ones.
    private func openThroughWindow(_ item: MetaItem, source: TitleMorphSource) {
        remember()
        DetailWindow.open(item, from: source, settings: mdblist.settings, push: onOpenInPlace)
    }

    /// The query joins the recent ones.
    private func remember() {
        let query = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        let list = [query] + recent.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        recentStorage = list.prefix(8).joined(separator: "\n")
    }

    /// Selecting a result: it opens, and the query joins the recent ones.
    private func select(_ item: MetaItem) {
        remember()
        onSelect(item)
    }

    /// Top Result, then Movies and Series — the top result's kind first.
    static func rows(_ ranked: [MetaItem]) -> [HomeRow] {
        guard let top = ranked.first else { return [] }
        let rest = ranked.dropFirst()
        // Under each poster: its year.
        let years = Dictionary(rest.compactMap { item in item.year.map { (item.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let movies = HomeRow(id: moviesRowID, title: "Movies", items: rest.filter { $0.type == "movie" },
                             subtitles: years)
        let series = HomeRow(id: seriesRowID, title: "Series", items: rest.filter { $0.type != "movie" },
                             subtitles: years)
        let kinds = top.type == "movie" ? [movies, series] : [series, movies]
        return [HomeRow(id: topRowID, title: "Top Result", items: [top])] + kinds.filter { !$0.items.isEmpty }
    }

    /// The order: how well the NAME matches what was typed (exactly, from
    /// its start, anywhere, not at all), then — within each — how well known
    /// the title is: TMDB's votes and popularity (`fame`, matched by name,
    /// year and kind); titles TMDB doesn't know after those, rated before
    /// unrated, by rating. The add-ons' own order only breaks ties: theirs is
    /// a text match, blind to fame.
    static func ranked(_ items: [MetaItem], for query: String,
                       fame: [TMDBService.SearchFame]) -> [MetaItem] {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// For matching names across sources: letters and digits only.
        func key(_ s: String) -> String { String(norm(s).unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
        func year(_ item: MetaItem) -> Int? {
            item.releaseInfo.flatMap { $0.firstMatch(of: /\d{4}/) }.flatMap { Int($0.output) }
        }
        var fameByName: [String: [TMDBService.SearchFame]] = [:]
        for entry in fame {
            for name in Set([entry.name, entry.originalName].compactMap { $0 }.map(key)) {
                fameByName[name, default: []].append(entry)
            }
        }
        func score(_ item: MetaItem) -> Double? {
            let isMovie = item.type == "movie"
            let itemYear = year(item)
            return fameByName[key(item.name)]?
                .filter { $0.isMovie == isMovie }
                .filter { entry in
                    guard let a = entry.year, let b = itemYear else { return true }
                    return abs(a - b) <= 1
                }
                .map(\.score).max()
        }
        let q = norm(query)
        let scored = items.enumerated().map { offset, item -> (item: MetaItem, tier: Int, fame: Double?,
                                                               rating: Double?, offset: Int) in
            let name = norm(item.name)
            let tier = name == q ? 0 : name.hasPrefix(q) ? 1 : name.contains(q) ? 2 : 3
            return (item, tier, score(item), item.imdbRating.flatMap(Double.init), offset)
        }
        return scored.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            switch (a.fame, b.fame) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch (a.rating, b.rating) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.item)
    }

    /// Search results often come without a backdrop or logo: MetaHub's for
    /// IMDb titles (a card without one shows the poster).
    private static func withArt(_ item: MetaItem) -> MetaItem {
        guard item.id.hasPrefix("tt"), item.background == nil || item.logo == nil else { return item }
        return MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster,
                        background: item.background
                            ?? "https://images.metahub.space/background/medium/\(item.id)/img",
                        logo: item.logo ?? "https://images.metahub.space/logo/medium/\(item.id)/img",
                        description: item.description, releaseInfo: item.releaseInfo,
                        imdbRating: item.imdbRating, runtime: item.runtime, genres: item.genres,
                        cast: item.cast, videos: item.videos)
    }
}
