import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [MetaItem] = []
    /// How well known the titles of this search are (TMDB) — for the order.
    @Published var fame: [TMDBService.SearchFame] = []
    @Published var isSearching = false
    /// The scope chosen in the search bar: Top Result, Movies or Series
    /// (back to Top Result with each new search).
    @Published var scope: SearchScope = .top

    private var searchTask: Task<Void, Never>?

    func search(addonManager: AddonManager) {
        searchTask?.cancel()
        scope = .top
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
/// - TOP RESULT first: the best match as one big card, the
///   billboard's text in it (`SearchTopResultCell`);
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

    /// Recent searches (or what the page says) this far under the
    /// keyboard's line.
    private static let statusTop: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ATVBackground()
            // (Read here, not by this view: a change of the keyboard's height
            // needn't re-run this body — that re-applies the suggestions and
            // the system reloads them.)
            SearchKeyboardReader(metrics: keyboard) { keyboardHeight in
            if hasRows {
                // The whole page, under the keyboard too: it scrolls with
                // the grid.
                // Up to the screen's top, under the bar (the page starts
                // below it).
                GeometryReader { geo in
                    let above = geo.frame(in: .global).minY
                    grid(height: geo.size.height + above, keyboardHeight: keyboardHeight + above)
                        .padding(.top, -above)
                }
                .ignoresSafeArea()
                // The scope bar on the page, not in the grid's scroll view
                // (from the keyboard, Down never found it there); it scrolls
                // with the grid all the same (`SearchKeyboardScroll`).
                GeometryReader { _ in
                    SearchScopeBarHost(viewModel: viewModel, mover: barMover)
                        .frame(height: SearchScopeBar.pillHeight)
                        .padding(.top, max(0, keyboardHeight + SearchScopeBar.top))
                }
                .ignoresSafeArea()
            } else {
                // In the grid's place: from the screen's edges (as the grid),
                // just under the keyboard's line.
                GeometryReader { _ in
                    status
                        .padding(.leading, FixedFocusMetrics.inset)
                        .padding(.top, keyboardHeight + Self.statusTop)
                }
                .ignoresSafeArea()
            }
            }
            SearchKeyboardScroll(enabled: hasRows, hidesLine: hasRows, mover: barMover) { height in
                if keyboard.height != height { keyboard.height = height }
            }
            .frame(width: 1, height: 1)
        }
        // Only a real change (the field writes its text back as the system
        // re-applies the suggestions; the same text needn't rebuild the page).
        .searchable(text: Binding(get: { viewModel.query },
                                  set: { if $0 != viewModel.query { viewModel.query = $0 } }),
                    prompt: "Movies and series")
        // As in the Apple TV app, between the keys and the line: the field
        // empty, the recent searches (newest first); with text, what you may
        // mean — the best matches' names. Select searches. (Only
        // completions: a Button among them — Clear — sent tvOS into an
        // endless focus/reload loop that froze Search.)
        .searchSuggestions {
            if shownSuggestions.recent {
                ForEach(shownSuggestions.items, id: \.self) { search in
                    Label(search, systemImage: "clock.arrow.circlepath").searchCompletion(search)
                }
            } else {
                ForEach(shownSuggestions.items, id: \.self) { name in
                    Text(name).searchCompletion(name)
                }
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.search(addonManager: addonManager)
            refreshSuggestions()
        }
        .onChange(of: viewModel.results.map(\.id)) { _, _ in refreshSuggestions() }
        .onChange(of: recentStorage) { _, _ in refreshSuggestions(force: true) }
        .onAppear { refreshSuggestions(force: true) }
    }

    /// The system's field and keyboard, above the results (`SearchKeyboardScroll`).
    @State private var keyboard = SearchKeyboardMetrics()
    /// The scope bar's view, moved with the grid's scroll.
    @State private var barMover = SearchBarMover()

    private var hasRows: Bool { !viewModel.results.isEmpty }

    /// The suggestions: the best matches' names (lowercased), each once,
    /// without what's typed itself.
    /// The suggestions on show — kept while the field shows one of them:
    /// focusing a suggestion puts its text in the field (tvOS); a row
    /// rebuilt for that text would take the focused one away.
    @State private var shownSuggestions: (recent: Bool, items: [String]) = (true, [])

    private func refreshSuggestions(force: Bool = false) {
        let query = viewModel.query
        if !force, shownSuggestions.items.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
            return
        }
        shownSuggestions = query.isEmpty ? (true, recent) : (false, suggestions)
    }

    private var suggestions: [String] {
        guard !viewModel.query.isEmpty else { return [] }
        let typed = viewModel.query.lowercased().trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        return Self.ranked(viewModel.results, for: viewModel.query, fame: viewModel.fame)
            .map { $0.name.lowercased() }
            .filter { $0 != typed && seen.insert($0).inserted }
            .prefix(8).map { $0 }
    }

    /// The results as the browse pages' grid: the best match as one big
    /// card (Top Result), or one type's posters, best match first.
    private func grid(height: CGFloat, keyboardHeight: CGFloat) -> some View {
        // Under the scope bar (on the line under the keyboard).
        let topSpace = max(0, keyboardHeight + SearchScopeBar.top + SearchScopeBar.height
                              - FolderGridController.headerTopMargin)
        // The Top Result reaches down to the screen's bottom, the side
        // margin from it.
        let resultsTop = topSpace + FolderGridController.headerTopMargin + FolderGridController.firstLineGap
        let ranked = Self.ranked(viewModel.results, for: viewModel.query, fame: viewModel.fame)
        let scope = viewModel.scope
        let items = scope == .top ? [] : ranked.filter { ($0.type == "movie") == (scope == .movies) }
        return FolderPosterGrid(
            header: nil,
            headerHeight: 0,
            items: items, subtitles: Self.years(items),
            onSelect: select, onOpenDetails: openDetails,
            topSpace: topSpace,
            focusesFirstTitle: false,
            topResults: scope == .top ? ranked.prefix(1).map(Self.withArt) : [],
            topResultHeight: max(300, height - resultsTop - FixedFocusMetrics.inset))
    }

    /// Under each poster: its year.
    private static func years(_ items: [MetaItem]) -> [String: String] {
        Dictionary(items.compactMap { item in item.year.map { (item.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// No results to show: searching, nothing found, the recent searches or
    /// what to do.
    @ViewBuilder
    private var status: some View {
        if viewModel.isSearching {
            CueLoadingView(label: "Searching").frame(maxWidth: .infinity).frame(height: 420)
        } else if viewModel.query.count >= 2 {
            CueEmptyState(icon: "magnifyingglass", title: "No results",
                          message: "Nothing matched “\(viewModel.query)”.")
                .frame(maxWidth: .infinity).frame(height: 420)
        } else if viewModel.query.isEmpty, !recent.isEmpty {
            // (The recent searches are the suggestions, under the keys.)
            EmptyView()
        } else {
            Text("Search for a movie or a series — or hold the microphone button and say it.")
                .font(.system(size: FixedFocusMetrics.textSize))
                .foregroundStyle(AppGlass.textMuted)
        }
    }

    /// A result's Select: into Details (`DetailTransition`), and the query
    /// joins the recent ones.
    private func openDetails(_ item: MetaItem) {
        remember()
        DetailTransition.shared.open(item) { onOpenInPlace(item) }
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

/// Search's scopes.
enum SearchScope: Hashable, CaseIterable {
    case top, movies, series

    var label: String {
        switch self {
        case .top: return "Top Result"
        case .movies: return "Movies"
        case .series: return "Series"
        }
    }
}

/// The keyboard's height (the page's scroll), observed only by what's laid
/// out under it (`SearchKeyboardReader`).
final class SearchKeyboardMetrics: ObservableObject {
    @Published var height: CGFloat = 0
}

private struct SearchKeyboardReader<Content: View>: View {
    @ObservedObject var metrics: SearchKeyboardMetrics
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View { content(metrics.height) }
}

/// The scope bar's UIKit view, for `SearchKeyboardScroll` to move.
final class SearchBarMover {
    weak var view: UIView?
}

/// The scope bar in its own hosting view, so it can be moved with the
/// grid's scroll point for point without a SwiftUI update per frame. (In a
/// container: SwiftUI places the container and resets its transform; the
/// bar inside is ours to move.)
private struct SearchScopeBarHost: UIViewControllerRepresentable {
    @ObservedObject var viewModel: SearchViewModel
    let mover: SearchBarMover

    final class Container: UIViewController {
        let host: UIHostingController<SearchScopeBar>
        init(_ bar: SearchScopeBar) {
            host = UIHostingController(rootView: bar)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    func makeUIViewController(context: Context) -> Container {
        let container = Container(SearchScopeBar(viewModel: viewModel))
        container.loadViewIfNeeded()
        mover.view = container.host.view
        return container
    }

    func updateUIViewController(_ container: Container, context: Context) {
        container.host.rootView = SearchScopeBar(viewModel: viewModel)
    }
}

/// THE SCOPE BAR, as in the Apple TV app: Top Result | Movies | Series in
/// the top bar's glass pill (`glassPill` — its size, type and highlight),
/// set into the line under the keyboard (the system's own line is hidden
/// meanwhile — `SearchKeyboardScroll.hidesLine`). Moving focus along it
/// switches the scope, as along the top bar.
struct SearchScopeBar: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var focus: SearchScope?
    @Namespace private var highlight

    static let pillHeight = GlassPill.itemHeight + 2 * GlassPill.inset
    /// Its top, from the keyboard's bottom: the line 12 pt under the
    /// keyboard (where the Apple TV app's moves to).
    static let top: CGFloat = 12 - pillHeight / 2
    /// The pill, then the gap to the results.
    static let height = pillHeight + 24
    /// The line's gap around the pill.
    private static let lineGap: CGFloat = 40

    var body: some View { scopeRow }

    private var scopeRow: some View {
        let focused = focus != nil
        let lit = focus ?? viewModel.scope
        return HStack(spacing: Self.lineGap) {
            line
            HStack(spacing: 0) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Button { viewModel.scope = scope } label: {
                        Text(scope.label)
                            .font(.system(size: GlassPill.textSize, weight: .semibold))
                            .padding(.horizontal, GlassPill.textPadding)
                            .foregroundStyle(GlassPill.contentColor(current: lit == scope,
                                                                    onFocusHighlight: focused && lit == scope))
                            .frame(height: GlassPill.itemHeight)
                            .animation(.easeOut(duration: 0.18), value: lit)
                            .glassPillItem(scope, in: highlight)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused($focus, equals: scope)
                }
            }
            .glassPill(highlight: lit, in: highlight, focused: focused)
            .defaultFocus($focus, viewModel.scope)
            // Focused, it grows a little (as the top bar).
            .scaleEffect(focused ? GlassSidebar.focusedScale : 1)
            .animation(.smooth(duration: 0.3), value: focused)
            line
        }
        .focusSection()
        .frame(height: Self.pillHeight)
        .padding(.horizontal, FixedFocusMetrics.inset)
        .onChange(of: focus) { old, now in
            guard let now else { return }
            if old == nil {
                // Coming in (Down from the keyboard, Up from the results):
                // onto the current scope, not the nearest one.
                if now != viewModel.scope {
                    let scope = viewModel.scope
                    DispatchQueue.main.async { focus = scope }
                }
            } else if now != viewModel.scope {
                // Along the pill: the scope follows.
                viewModel.scope = now
            }
        }
    }

    /// The line's halves: as the system's (tertiary label colour, 1 pt).
    private var line: some View {
        Rectangle().fill(Color(uiColor: .tertiaryLabel)).frame(height: 1)
    }
}

/// The system's search field and keyboard scroll with the results' grid,
/// point for point — the page scrolls, as in the Apple TV app (at the
/// grid's top — the first line — the keyboard shows: Up reaches it, the
/// engine never finds it once it's out). The results controller's content
/// scroll view is a hidden one we move — the system scrolls its keyboard
/// with it. Placed at the top of the results area (where the keyboard
/// ends).
/// Back on Search (the page's `onExitCommand` asks): in the results, up to
/// the keyboard (`SearchKeyboardScroll.Anchor.backToKeyboard`).
@MainActor
final class SearchBack {
    static let shared = SearchBack()
    weak var anchor: SearchKeyboardScroll.Anchor?
}

struct SearchKeyboardScroll: UIViewRepresentable {
    /// Results showing: only then does the keyboard make way.
    var enabled: Bool
    /// The system's line under the keyboard hidden (the scope bar draws its
    /// own, lower).
    var hidesLine = false
    /// The scope bar, moved with the grid as the keyboard is.
    var mover: SearchBarMover?
    /// The keyboard's height (the page's scroll), once known.
    var onHeight: (CGFloat) -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.onHeight = onHeight
        anchor.enabled = enabled
        anchor.hidesLine = hidesLine
        anchor.mover = mover
        // The grid comes in this same update: once it's there.
        DispatchQueue.main.async { anchor.followGrid() }
    }

    final class Anchor: UIView {
        var onHeight: (CGFloat) -> Void = { _ in }
        var enabled = false
        var mover: SearchBarMover?
        var hidesLine = false {
            didSet { if hidesLine != oldValue { applyLine() } }
        }
        /// The grid's page, followed.
        private var gridObservation: NSKeyValueObservation?
        private weak var followedGrid: UIScrollView?
        private let tracker = UIScrollView()
        private weak var search: UISearchController?
        /// The results' hosting view (the grid is in it).
        private weak var page: UIView?
        private var height: CGFloat = 0
        /// From the system's line to where the results start (as without
        /// suggestions).
        private static let lineToResults: CGFloat = 31

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            tracker.isHidden = true
            tracker.isUserInteractionEnabled = false
            tracker.contentInsetAdjustmentBehavior = .never
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, search == nil else { return }
            var responder: UIResponder? = self
            while let next = responder, !(next is UISearchController) { responder = next.next }
            guard let search = responder as? UISearchController,
                  let results = search.searchResultsController else { return }
            var view: UIView? = self
            while let current = view, current.superview !== results.view { view = current.superview }
            self.search = search
            page = view
            SearchBack.shared.anchor = self
            results.view.insertSubview(tracker, at: 0)
            results.setContentScrollView(tracker, for: .top)
            // The grid reaches up under the top bar, past the page's top
            // (the page sits under the bar — the system's field ignores the
            // safe area): the system's containers mustn't cut it off there.
            var ancestor = page?.superview
            while let view = ancestor, !(view is UIWindow) {
                view.clipsToBounds = false
                ancestor = view.superview
            }
            measure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        private func measure() {
            guard let page else { return }
            // Where the results start: the keyboard's bottom — lower with
            // the system's suggestions under the keys (they lie over the
            // results; the system's line, hidden or not, goes down under
            // them). As the keyboard scrolls away, its offset is added back.
            var top = convert(CGPoint.zero, to: page).y - page.bounds.minY
            if let root = search?.view, let line = lines(root).first {
                let lineY = line.convert(line.bounds, to: page).maxY - page.bounds.minY + tracker.contentOffset.y
                top = max(top, lineY + Self.lineToResults)
            }
            tracker.frame = CGRect(origin: .zero, size: page.bounds.size)
            tracker.contentSize = CGSize(width: page.bounds.width, height: page.bounds.height + top)
            if top != height, top > 0 {
                height = top
                onHeight(top)
            }
        }

        /// The system's line under the keyboard: a 1 pt view across it.
        private func lines(_ view: UIView) -> [UIView] {
            let hairline = view.bounds.height <= 1.5 && view.bounds.width > 1000
                && view.backgroundColor == .tertiaryLabel
            return (hairline ? [view] : []) + view.subviews.flatMap(lines)
        }

        private func applyLine() {
            guard let root = search?.view else { return }
            for line in lines(root) { line.isHidden = hidesLine }
        }

        /// Back with focus in the results (the scope bar, the grid): the
        /// page back to its top — the keyboard with it — and focus onto the
        /// keyboard. False: focus isn't in the results.
        func backToKeyboard() -> Bool {
            guard let page, let search, let window,
                  let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView,
                  focused.isDescendant(of: page) else { return false }
            // (A request straight into the keyboard is ignored: the results
            // step out of focus's way for a moment, and the search screen's
            // own choice — its keyboard — takes it.)
            let toKeyboard = { [weak page] in
                guard let page, let system = UIFocusSystem.focusSystem(for: window) else { return }
                page.isUserInteractionEnabled = false
                system.requestFocusUpdate(to: search)
                system.updateFocusIfNeeded()
                page.isUserInteractionEnabled = true
            }
            if let grid = followedGrid, grid.contentOffset.y > -grid.contentInset.top + 1 {
                grid.setContentOffset(CGPoint(x: 0, y: -grid.contentInset.top), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: toKeyboard)
            } else {
                toKeyboard()
            }
            return true
        }

        /// The grid's page: the keyboard scrolls with it.
        func followGrid() {
            applyLine()
            measure()
            func find(_ view: UIView) -> UIScrollView? {
                (view.next as? FolderGridController)?.scrollView ?? view.subviews.lazy.compactMap(find).first
            }
            let grid = enabled ? page.flatMap(find) : nil
            guard grid !== followedGrid || grid == nil && gridObservation != nil else { return }
            followedGrid = grid
            gridObservation = grid?.observe(\.contentOffset, options: [.initial, .new]) { [weak self] grid, _ in
                MainActor.assumeIsolated {
                    let offset = max(0, grid.contentOffset.y + grid.contentInset.top)
                    guard let self else { return }
                    self.tracker.contentOffset.y = offset
                    self.mover?.view?.transform = CGAffineTransform(translationX: 0, y: -offset)
                }
            }
            if grid == nil {
                tracker.contentOffset.y = 0
                mover?.view?.transform = .identity
            }
        }
    }
}
