import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    /// What the last search found — every kind, published at once.
    @Published private(set) var found = SearchFound()
    @Published var isSearching = false
    /// The scope chosen in the line: Top Results, Movies, Series, People or
    /// Studios (back to Top Results with each new search).
    @Published var scope: SearchScope = .top
    /// What you may mean, as you type: TMDB's names (`suggest`).
    @Published private(set) var suggestions: [String] = []
    /// The titles last opened from Search (newest first): the row while the
    /// field is empty.
    @Published private(set) var recentTitles: [MetaItem] = SearchViewModel.loadRecentTitles()

    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    /// TMDB's answers by query (lowercased): the suggestions', the results'
    /// and their order's — one search for all three.
    private var hitCache: [String: [TMDBService.SearchHit]] = [:]

    /// TMDB's films and series for a query, asked once.
    private func hits(for query: String) async -> [TMDBService.SearchHit] {
        let key = query.lowercased()
        if let known = hitCache[key] { return known }
        let found = await TMDBService.search(query)
        hitCache[key] = found
        return found
    }

    /// The suggestions for what's typed: at once from what an earlier,
    /// shorter query brought (filtered here), then TMDB's own answer a
    /// moment later (120 ms after the last key, older lookups dropped).
    /// (Focusing a suggestion only previews its text in the field; the
    /// query changes once it's chosen.)
    func suggest() {
        suggestTask?.cancel()
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { setSuggestions([]); return }
        if let base = (1...typed.count).reversed().lazy
            .map({ String(typed.prefix($0)) }).first(where: { self.hitCache[$0] != nil }) {
            setSuggestions(Self.names((hitCache[base] ?? []).map(\.fame), for: typed))
        }
        guard hitCache[typed] == nil else { return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let found = await hits(for: typed)
            guard !Task.isCancelled else { return }
            setSuggestions(Self.names(found.map(\.fame), for: typed))
        }
    }

    /// Only a real change (each one re-applies the system's row).
    private func setSuggestions(_ names: [String]) {
        if names != suggestions { suggestions = names }
    }

    /// The names that go on with what's typed (lowercased, as the Apple TV
    /// app's): their start or a word's (`matchBonus`), the best known first
    /// with its bonus; each once.
    private static func names(_ fame: [TMDBService.SearchFame], for typed: String) -> [String] {
        let q = matchForm(typed)
        var seen = Set<String>()
        return fame.compactMap { entry -> (name: String, score: Double)? in
            matchBonus(matchForm(entry.name), q).map { (entry.name.lowercased(), entry.score + $0) }
        }
        .sorted { $0.score > $1.score }
        .map(\.name)
        .filter { seen.insert($0).inserted }
        .prefix(8).map { $0 }
    }

    // MARK: Recent titles

    private static let recentTitlesKey = "cue.search.recentTitles"
    private static let recentTitlesLimit = 12

    private static func loadRecentTitles() -> [MetaItem] {
        guard let data = UserDefaults.standard.data(forKey: recentTitlesKey) else { return [] }
        return (try? JSONDecoder().decode([MetaItem].self, from: data)) ?? []
    }

    /// A title opened from Search: first among the recent ones.
    func opened(_ item: MetaItem) {
        let list = [item] + recentTitles.filter { $0.id != item.id }
        recentTitles = Array(list.prefix(Self.recentTitlesLimit))
        if let data = try? JSONEncoder().encode(recentTitles) {
            UserDefaults.standard.set(data, forKey: Self.recentTitlesKey)
        }
    }

    /// The results: TMDB's films and series for the query (the same search
    /// as the suggestions'), playable by their IMDb ids — what the stream
    /// add-ons take, wherever a title was found (`TMDBService.playable`).
    func search() {
        searchTask?.cancel()
        scope = .top
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            found = SearchFound()
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            // All kinds at once: switching the scope shows them at once.
            async let foundTop = TMDBService.searchMulti(trimmed)
            async let foundPeople = TMDBService.searchPeople(trimmed)
            async let foundStudios = TMDBService.searchCompanies(trimmed)
            let hits = await hits(for: trimmed)
            let items = await TMDBService.playable(hits)
            let (combined, persons, companies) = await (foundTop, foundPeople, foundStudios)
            guard !Task.isCancelled else { return }
            var next = SearchFound()
            next.query = trimmed
            next.top = combined
            next.results = items
            next.fame = hits.map(\.fame)
            // Only people with a photo, as titles with a picture and
            // studios with a logo (the rest: namesakes nobody means, and
            // thousands of small production firms).
            let pictured = persons.filter { $0.profileURL != nil }
            next.people = pictured.map {
                MetaItem(id: "person:\($0.id)", type: "person", name: $0.name, poster: $0.profileURL,
                         background: nil, releaseInfo: $0.knownFor)
            }
            next.personFame = Dictionary(pictured.map { ("person:\($0.id)", Self.fame(of: $0)) },
                                         uniquingKeysWith: { first, _ in first })
            next.studios = companies.filter { $0.logoURL != nil }.map {
                MetaItem(id: "company:\($0.id)", type: "company", name: $0.name, poster: $0.logoURL,
                         background: nil)
            }
            // A person or studio leading Top Results (in either order):
            // their best-known titles, fetched before anything shows — the
            // page swaps in whole.
            let leads = Set([true, false].compactMap { next.lead(own: $0) })
            next.related = await withTaskGroup(of: (String, [MetaItem]).self) { group in
                for lead in leads {
                    group.addTask { (lead.id, await Self.bestKnown(of: lead)) }
                }
                var related: [String: [MetaItem]] = [:]
                for await (id, titles) in group { related[id] = titles }
                return related
            }
            guard !Task.isCancelled else { return }
            found = next
            isSearching = false
        }
    }

    /// A leading person's or studio's best-known titles (Top Results).
    private nonisolated static func bestKnown(of lead: MetaItem) async -> [MetaItem] {
        guard let id = tmdbID(lead) else { return [] }
        if lead.type == "person" {
            return await TMDBService.bestKnown(TMDBService.personCredits(id: id), limit: SearchFound.topCount)
        }
        return await TMDBService.studioBestKnown(id: id, limit: SearchFound.topCount)
    }

    /// A person's fame on the titles' scale: their popularity (counted
    /// double — people have no votes) plus half their best-known title's
    /// votes (log scale). Christopher Nolan above the documentaries named
    /// after him; a minor actor of a famous film not above the film.
    private static func fame(of person: TMDBService.PersonSearchResult) -> Double {
        2 * log1p(person.popularity) + 0.5 * log1p(Double(person.knownForVotes))
    }

    /// A person's or studio's TMDB id (`person:<id>`, `company:<id>`).
    nonisolated static func tmdbID(_ item: MetaItem) -> Int? {
        item.id.split(separator: ":").last.flatMap { Int($0) }
    }

    /// A name as it's matched: lowercased, accents gone, words apart (any
    /// punctuation a space) — "Dune: Part Two" → "dune part two".
    nonisolated static func matchForm(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// How a name goes on with what's typed (both in `matchForm`) — the
    /// suggestions' rule: nil, it doesn't — neither its start nor one of its
    /// words starts with it; else the bonus on its fame: the name itself +3,
    /// its start +1, a word 0.
    nonisolated static func matchBonus(_ name: String, _ typed: String) -> Double? {
        guard !typed.isEmpty else { return nil }
        if name == typed { return 3 }
        if name.hasPrefix(typed) { return 1 }
        return name.contains(" " + typed) ? 0 : nil
    }

}

/// What one search found — every kind, in TMDB's order — and both orders
/// over it (Render Lab → Search: Cue's order).
struct SearchFound {
    var query = ""
    /// TMDB's combined search (films, series, people): Top Results in its
    /// order.
    var top: [MetaItem] = []
    /// Films and series (TMDB's film and series searches), with their fame
    /// for Cue's order.
    var results: [MetaItem] = []
    var fame: [TMDBService.SearchFame] = []
    /// People (`person:<id>`) and their fame on the titles' scale.
    var people: [MetaItem] = []
    var personFame: [String: Double] = [:]
    /// Studios (`company:<id>`).
    var studios: [MetaItem] = []
    /// A leading person's or studio's best-known titles, by its id.
    var related: [String: [MetaItem]] = [:]

    /// Top Results: as many as fit across, no scrolling.
    static let topCount = 6

    private typealias Model = SearchViewModel

    /// Top Results: the order's list, a studio taken in when it's what you
    /// typed (`withStudio`); led by a person or studio, the rest of the
    /// places their best-known titles.
    func topResults(own: Bool) -> [MetaItem] {
        let base = withStudio(own ? rankedTop() : top, count: Self.topCount)
        guard let lead = base.first, let more = related[lead.id], !more.isEmpty else { return base }
        var seen: Set<String> = [lead.id]
        return [lead] + more.filter { seen.insert($0.id).inserted }.prefix(Self.topCount - 1)
    }

    /// The person or studio leading Top Results in that order, if one does.
    func lead(own: Bool) -> MetaItem? {
        withStudio(own ? rankedTop() : top, count: 1).first.flatMap { ["person", "company"].contains($0.type) ? $0 : nil }
    }

    // MARK: Cue's own order

    /// THE ORDER: only names whose start — or a word's — starts with what
    /// was typed ("di" → Die Hard, The Diplomat, Digimon; TMDB's fuzzier
    /// finds left out; none match, a typo: all), the best known first —
    /// fame plus a bonus for the name itself or its start (`matchBonus`):
    /// enough to lift an exact match among names about as known, not a
    /// minor one over a famous one.
    private func ranked(_ items: [MetaItem], fame: (MetaItem) -> Double) -> [(item: MetaItem, score: Double)] {
        let typed = Model.matchForm(query)
        var scored = items.enumerated().map { offset, item in
            (item: item, bonus: Model.matchBonus(Model.matchForm(item.name), typed), fame: fame(item), offset: offset)
        }
        if scored.contains(where: { $0.bonus != nil }) { scored.removeAll { $0.bonus == nil } }
        return scored
            .sorted { a, b in
                let (x, y) = (a.fame + (a.bonus ?? 0), b.fame + (b.bonus ?? 0))
                return x != y ? x > y : a.offset < b.offset
            }
            .map { ($0.item, $0.fame + ($0.bonus ?? 0)) }
    }

    /// The titles in Cue's order, by the fame of their own TMDB entry (the
    /// same name, kind and year — else one a year off: a release date told
    /// differently).
    func rankedTitles() -> [(item: MetaItem, score: Double)] {
        func key(_ s: String) -> String { Model.matchForm(s).replacingOccurrences(of: " ", with: "") }
        var byName: [String: [TMDBService.SearchFame]] = [:]
        for entry in fame {
            for name in Set([entry.name, entry.originalName].compactMap { $0 }.map(key)) {
                byName[name, default: []].append(entry)
            }
        }
        return ranked(results) { item in
            let same = (byName[key(item.name)] ?? []).filter { $0.isMovie == (item.type == "movie") }
            let year = item.year.flatMap(Int.init)
            let entry = year.flatMap { y in same.first { $0.year == y } ?? same.first { ($0.year.map { abs($0 - y) <= 1 }) ?? true } }
                ?? (year == nil ? same.max { $0.score < $1.score } : nil)
            return entry?.score ?? 0
        }
    }

    func rankedPeople() -> [(item: MetaItem, score: Double)] {
        ranked(people) { personFame[$0.id] ?? 0 }
    }

    /// Studios: only those whose name — or a word — starts with what was
    /// typed (none: all), the name itself first, else TMDB's order.
    func rankedStudios() -> [MetaItem] {
        ranked(studios) { _ in 0 }.map(\.item)
    }

    /// Top Results in Cue's order: titles and people together, by score.
    func rankedTop() -> [MetaItem] {
        (rankedTitles() + rankedPeople()).sorted { $0.score > $1.score }.map(\.item)
    }

    /// One studio into Top Results (both orders), when it's what you
    /// typed: the name itself → first; its name or a word starting with it
    /// (3 letters on) → second, after the first hit. At most one — the
    /// list keeps its length. None while a title or person has that very
    /// name ("dune": the films, not a studio called Dune).
    func withStudio(_ list: [MetaItem], count: Int) -> [MetaItem] {
        let typed = Model.matchForm(query)
        let bonuses = studios.map { Model.matchBonus(Model.matchForm($0.name), typed) }
        let named = (results + people).contains { Model.matchForm($0.name) == typed }
        let pick: (item: MetaItem, place: Int)?
        if named {
            pick = nil
        } else if let exact = studios.indices.first(where: { bonuses[$0] == 3 }) {
            pick = (studios[exact], 0)
        } else if typed.count >= 3, let start = studios.indices.first(where: { bonuses[$0] != nil }) {
            pick = (studios[start], 1)
        } else {
            pick = nil
        }
        var out = Array(list.prefix(count))
        if let pick {
            out.insert(pick.item, at: min(pick.place, out.count))
            out = Array(out.prefix(count))
        }
        return out
    }
}

/// SEARCH: Apple's own search field and keyboard at the top (dictation with
/// the remote's mic), its suggestions under the keys — the recent searches
/// while the field is empty, else what you may mean. Under them the line
/// with the scopes (Top Results | Movies | Series) and one row of posters:
/// the results, or the titles last opened from Search. Nothing scrolls but
/// the row, sideways; the line and the row sit where the system puts its
/// page: up while no suggestions show, down when they do, at once (as in
/// the Apple TV app — `SearchKeyboardLine`).
struct SearchView: View {
    // Owned by RootView so the query + results PERSIST across tab switches.
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject private var probe = RenderProbe.shared
    /// Its tab is in front (the row leaves the focus engine otherwise).
    var active = true

    /// Details, pushed without the system's slide (`DetailTransition` has
    /// already brought it in).
    var onOpenInPlace: (MetaItem) -> Void = { _ in }
    /// A person's / a studio's page (TMDB id, name).
    var onOpenPerson: (Int, String) -> Void = { _, _ in }
    var onOpenStudio: (Int, String) -> Void = { _, _ in }

    /// Recent searches (newest first), the suggestions while the field is empty.
    @AppStorage("cue.search.recent") private var recentStorage = ""
    private var recent: [String] { recentStorage.split(separator: "\n").map(String.init) }

    /// The page's top at its lowest — suggestions on show (window points),
    /// once known: the posters' size, the same in both places.
    @State private var lowestTop: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ATVBackground()
            if let lowestTop {
                GeometryReader { geo in
                    let above = geo.frame(in: .global).minY
                    page(rowHeight: Self.rowHeight(screenHeight: geo.size.height + above, lowestTop: lowestTop))
                }
                .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
            SearchKeyboardLine { if lowestTop != $0 { lowestTop = $0 } }
                .frame(width: 1, height: 1)
        }
        // Only a real change (the field writes its text back as the system
        // re-applies the suggestions; the same text needn't rebuild the page).
        .searchable(text: Binding(get: { viewModel.query },
                                  set: { if $0 != viewModel.query { viewModel.query = $0 } }),
                    prompt: "Movies and series")
        // As in the Apple TV app, between the keys and the line (tvOS draws
        // no icons on them — a `UISearchSuggestionItem`'s neither): the field empty, the recent searches (newest first);
        // with text, what you may mean (`SearchViewModel.suggest`). Select
        // searches. (Only completions: a Button among them — Clear — sent
        // tvOS into an endless focus/reload loop that froze Search.)
        .searchSuggestions {
            if viewModel.query.isEmpty {
                ForEach(recent, id: \.self) { search in Text(search).searchCompletion(search) }
            } else {
                ForEach(viewModel.suggestions, id: \.self) { name in Text(name).searchCompletion(name) }
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.search()
            viewModel.suggest()
        }
    }

    /// The row's room with the page at its lowest.
    private static func rowHeight(screenHeight: CGFloat, lowestTop: CGFloat) -> CGFloat {
        max(200, screenHeight - lowestTop + pillRaise - SearchScopeBar.pillHeight - gap - bottomGap)
    }

    /// The line with the scopes, then the row (or what the page says).
    private func page(rowHeight: CGFloat) -> some View {
        let typed = !viewModel.query.isEmpty
        let items = typed ? scoped : viewModel.recentTitles
        // The same gap under the pill as over it, to the cards at rest (the
        // row keeps room above them for a focused card's growth).
        let growthRoom = SearchRowController.growthRoom(rowHeight: rowHeight)
        return VStack(alignment: .leading, spacing: Self.gap - growthRoom) {
            SearchScopeBar(viewModel: viewModel, showsPill: typed)
            ZStack(alignment: .topLeading) {
                SearchResultsRow(items: items, subtitles: Self.subtitles(items), height: rowHeight,
                                 onSelect: open)
                    // Hidden by its contents' absence, never transparent
                    // (tvOS skips transparent views).
                if items.isEmpty { status.padding(.leading, FixedFocusMetrics.inset) }
            }
            .frame(height: rowHeight)
        }
        .padding(.top, -Self.pillRaise)
    }

    /// Over and under the pill (from the suggestions, to the cards), and
    /// under the captions.
    private static let gap: CGFloat = 40
    private static let bottomGap: CGFloat = 50
    /// The pill above the page's top: the system starts the page 71 pt
    /// under its suggestions (tvOS 27); the pill `gap` under them. (Partly
    /// outside the page, it still takes focus.)
    private static let pillRaise: CGFloat = 31

    /// The cards of the scope chosen — in Cue's own order or TMDB's
    /// (Render Lab → Search: Cue's order).
    private var scoped: [MetaItem] {
        let own = probe.flags.searchOwnOrder
        let found = viewModel.found
        switch viewModel.scope {
        case .top: return found.topResults(own: own)
        case .movies:
            return (own ? found.rankedTitles().map(\.item) : found.results).filter { $0.type == "movie" }
        case .series:
            return (own ? found.rankedTitles().map(\.item) : found.results).filter { $0.type != "movie" }
        case .people: return own ? found.rankedPeople().map(\.item) : found.people
        case .studios: return own ? found.rankedStudios() : found.studios
        }
    }

    /// Under each card: a title's year, a person's line of work (TMDB's
    /// "Acting", "Directing"…), nothing for a studio.
    private static func subtitles(_ items: [MetaItem]) -> [String: String] {
        Dictionary(items.compactMap { item in
            (item.type == "person" ? item.releaseInfo : item.type == "company" ? nil : item.year).map { (item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// No posters to show: searching, nothing found, or what to do.
    @ViewBuilder
    private var status: some View {
        if viewModel.isSearching {
            CueLoadingView(label: "Searching").frame(maxWidth: .infinity).frame(height: 300)
        } else if viewModel.query.count >= 2 {
            CueEmptyState(icon: "magnifyingglass", title: "No results",
                          message: "Nothing matched “\(viewModel.query)”.")
                .frame(maxWidth: .infinity).frame(height: 300)
        } else if viewModel.query.isEmpty {
            Text("Search for a movie or a series — or hold the microphone button and say it.")
                .font(.system(size: FixedFocusMetrics.textSize))
                .foregroundStyle(AppGlass.textMuted)
        }
    }

    /// A card's Select: a title into Details (`DetailTransition`) — it
    /// joins the recent titles; a person's or studio's page. The query
    /// joins the recent searches.
    private func open(_ item: MetaItem) {
        remember()
        switch item.type {
        case "person":
            if let id = SearchViewModel.tmdbID(item) { onOpenPerson(id, item.name) }
        case "company":
            if let id = SearchViewModel.tmdbID(item) { onOpenStudio(id, item.name) }
        default:
            viewModel.opened(item)
            DetailTransition.shared.open(item) { onOpenInPlace(item) }
        }
    }

    /// The query joins the recent ones.
    private func remember() {
        let query = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        let list = [query] + recent.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        recentStorage = list.prefix(8).joined(separator: "\n")
    }
}

/// Search's scopes.
enum SearchScope: Hashable, CaseIterable {
    case top, movies, series, people, studios

    var label: String {
        switch self {
        case .top: return "Top Results"
        case .movies: return "Movies"
        case .series: return "Series"
        case .people: return "People"
        case .studios: return "Studios"
        }
    }
}

/// THE LINE under the suggestions, as in the Apple TV app: Top Results |
/// Movies | Series in a flat pill (in the page, not floating: no glass),
/// the Apple TV app's shape and sizes (measured on its search: a capsule
/// 68 pt tall, the highlight 10 pt inside it, 29 pt labels 33 pt from its
/// ends, a faint light edge along the top) in `FlatControl`'s fills: the
/// pill at rest, the current scope the current one of a set, the focused
/// one white with dark text; the highlight glides between them — set into it (the system's own line is hidden —
/// `SearchKeyboardLine`); the field empty, the line alone. Moving focus
/// along the pill switches the scope, as along the top bar.
struct SearchScopeBar: View {
    @ObservedObject var viewModel: SearchViewModel
    var showsPill = true
    @FocusState private var focus: SearchScope?
    @Namespace private var highlight

    private static let itemHeight: CGFloat = 48
    private static let inset: CGFloat = 10
    private static let textSize: CGFloat = 29
    private static let textPadding: CGFloat = 33
    static let pillHeight = itemHeight + 2 * inset
    /// The line's gap around the pill.
    private static let lineGap: CGFloat = 40

    var body: some View {
        let focused = focus != nil
        let lit = focus ?? viewModel.scope
        return HStack(spacing: Self.lineGap) {
            line
            if showsPill {
                HStack(spacing: 0) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Button { viewModel.scope = scope } label: {
                            Text(scope.label)
                                .font(.system(size: Self.textSize, weight: .semibold))
                                .padding(.horizontal, Self.textPadding)
                                .foregroundStyle(GlassPill.contentColor(current: lit == scope,
                                                                        onFocusHighlight: focused && lit == scope))
                                .frame(height: Self.itemHeight)
                                .animation(.easeOut(duration: 0.18), value: lit)
                                .glassPillItem(scope, in: highlight)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focus, equals: scope)
                    }
                }
                .background {
                    Capsule().fill(focused ? FlatControl.focus : FlatControl.selected)
                        .matchedGeometryEffect(id: lit, in: highlight, isSource: false)
                        .animation(GlassPill.glide, value: lit)
                        .animation(GlassPill.focusChange, value: focused)
                }
                .padding(Self.inset)
                // Its full width: the line's halves give way, not the labels.
                .fixedSize()
                .background {
                    Capsule().fill(FlatControl.rest)
                        .overlay(Capsule().strokeBorder(ActionFace.pillEdge, lineWidth: 1))
                }
                .defaultFocus($focus, viewModel.scope)
                // Focused, it grows a little (as the top bar).
                .scaleEffect(focused ? GlassSidebar.focusedScale : 1)
                .animation(.smooth(duration: 0.3), value: focused)
                line
            }
        }
        .focusSection()
        .frame(height: Self.pillHeight)
        .padding(.horizontal, FixedFocusMetrics.inset)
        .onChange(of: focus) { old, now in
            guard let now else { return }
            if old == nil {
                // Coming in (Down from the suggestions, Up from the row):
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

/// THE ROW: Saved for Later's cards (`FixedFocusDestinationCell` — moving
/// focus, the focused card grown, name and year under each), one shape for
/// every kind — 2:3 like a poster: a title's poster, a person's portrait,
/// a studio's logo on a light plate — as tall as the room under the line
/// allows (six fit across: Top Results doesn't scroll); it scrolls
/// sideways only.
private struct SearchResultsRow: UIViewControllerRepresentable {
    let items: [MetaItem]
    let subtitles: [String: String]
    /// The row's room: the cards, their lift and their captions.
    let height: CGFloat
    let onSelect: (MetaItem) -> Void

    func makeUIViewController(context: Context) -> SearchRowController { SearchRowController() }

    func updateUIViewController(_ controller: SearchRowController, context: Context) {
        controller.onSelect = onSelect
        controller.show(items, subtitles: subtitles, height: height)
    }
}

final class SearchRowController: UIViewController, UICollectionViewDataSource,
                                 UICollectionViewDelegateFlowLayout, HoldMenuProviding {
    var onSelect: (MetaItem) -> Void = { _ in }

    private var items: [MetaItem] = []
    private var subtitles: [String: String] = [:]
    private var card = CGSize(width: 200, height: 300)
    private var rowHeight: CGFloat = 0
    private let layout = UICollectionViewFlowLayout()
    private var collectionView: UICollectionView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layout.scrollDirection = .horizontal
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // The lifted card and its shadow reach past the row.
        collectionView.clipsToBounds = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FixedFocusDestinationCell.self, forCellWithReuseIdentifier: "poster")
        view.addSubview(collectionView)
    }

    /// The card: the row's room less its captions and the growth above.
    static func cardHeight(rowHeight: CGFloat) -> CGFloat {
        ((rowHeight - FixedFocusMetrics.captionRoom) / (1 + FixedFocusMetrics.movingFocusLift / 2)).rounded(.down)
    }

    /// Above the cards: what a focused one grows by on each side.
    static func growthRoom(rowHeight: CGFloat) -> CGFloat {
        (cardHeight(rowHeight: rowHeight) * FixedFocusMetrics.movingFocusLift / 2).rounded()
    }

    func show(_ items: [MetaItem], subtitles: [String: String], height: CGFloat) {
        loadViewIfNeeded()
        rowHeight = height
        applyCardSize()
        self.subtitles = subtitles
        guard items.map(\.id) != self.items.map(\.id) else { return }
        self.items = items
        collectionView.reloadData()
        collectionView.contentOffset = .zero
    }

    /// 2:3 cards as tall as the room holds.
    private func applyCardSize() {
        let height = Self.cardHeight(rowHeight: rowHeight)
        let size = CGSize(width: (height / 1.5).rounded(), height: height)
        if size != card, size.width > 0 {
            card = size
            let gap = FixedFocusMetrics.destinationGap(cardWidth: size.width)
            layout.minimumLineSpacing = gap
            layout.itemSize = CGSize(width: size.width, height: size.height + FixedFocusMetrics.captionRoom)
            layout.sectionInset = UIEdgeInsets(top: Self.growthRoom(rowHeight: rowHeight),
                                               left: FixedFocusMetrics.inset, bottom: 0, right: FixedFocusMetrics.inset)
            collectionView.reloadData()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = items[indexPath.item]
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
            as! FixedFocusDestinationCell
        cell.configure(item, subtitle: subtitles[item.id], index: indexPath.item, rowCell: nil, card: card,
                       isLogo: item.type == "company")
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect(items[indexPath.item])
    }

    /// Select held on a title: its menu (`TitleMenu`, see `HoldMenu`).
    func holdMenu(for focused: UIView) -> HoldMenuRequest? {
        guard let cell = focused as? FixedFocusDestinationCell, let path = collectionView.indexPath(for: cell),
              items.indices.contains(path.item), ["movie", "series"].contains(items[path.item].type)
        else { return nil }
        let entries = TitleMenu.shared.entries(for: items[path.item])
        guard !entries.isEmpty else { return nil }
        return HoldMenuRequest(entries: entries, anchor: cell.convert(cell.cardFrame, to: nil))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HoldMenu.shared.install()
    }
}

/// Back on Search (the page's `onExitCommand` asks): from the scopes or the
/// row, onto the keyboard (`SearchKeyboardLine.Anchor.backToKeyboard`).
@MainActor
final class SearchBack {
    static let shared = SearchBack()
    weak var anchor: SearchKeyboardLine.Anchor?
}

/// The page's top at its lowest, in window points: where the system puts it
/// with its suggestions on show (up by their room while none do —
/// `suggestionsRoom`); the posters are sized for it. Our line sits at the
/// page's top, its pill inside the page (focus never reaches what's outside
/// it). The system's line is hidden (the scope bar draws its own). Also: no
/// "search for what's typed" chip (`styleSuggestions`).
struct SearchKeyboardLine: UIViewRepresentable {
    var onLowestTop: (CGFloat) -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.onLowestTop = onLowestTop
        DispatchQueue.main.async { anchor.measure() }
    }

    final class Anchor: UIView {
        var onLowestTop: (CGFloat) -> Void = { _ in }
        private weak var search: UISearchController?
        /// The system's page under the keyboard (ours is in it).
        private weak var page: UIView?
        private var lowestTop: CGFloat?
        /// How far the system's line moves down when its suggestions show
        /// (their row and its gaps — tvOS 27: 66 pt row, 102 in all)…
        private static let suggestionsRoom: CGFloat = 102
        /// …and from it to the page's top.
        private static let lineToPage: CGFloat = 31

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
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
            styleSuggestions(search)
            measure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        func measure() {
            guard let root = search?.view, let window, let systemLine = lines(root).first else { return }
            for line in lines(root) { line.isHidden = true }
            let y = systemLine.convert(systemLine.bounds, to: window).maxY
                + (suggestionsShown(in: systemLine.superview, above: systemLine) ? 0 : Self.suggestionsRoom)
                + Self.lineToPage
            guard y != lowestTop else { return }
            lowestTop = y
            onLowestTop(y)
        }

        /// The suggestions as the Apple TV app's: without the system's own
        /// first one, "what you typed" in quotes (its default suggestion —
        /// a private switch, left alone where it's missing).
        private func styleSuggestions(_ search: UISearchController) {
            if search.responds(to: NSSelectorFromString("_setShouldDisplayDefaultSuggestion:")) {
                search.setValue(false, forKey: "shouldDisplayDefaultSuggestion")
            }
        }

        /// The system's line under the keyboard: a 1 pt view across it.
        private func lines(_ view: UIView) -> [UIView] {
            let hairline = view.bounds.height <= 1.5 && view.bounds.width > 1000
                && view.backgroundColor == .tertiaryLabel
            return (hairline ? [view] : []) + view.subviews.flatMap(lines)
        }

        /// The suggestions' row (a collection view beside the line) on show.
        private func suggestionsShown(in container: UIView?, above line: UIView) -> Bool {
            container?.subviews.contains { view in
                guard let row = view as? UICollectionView, !row.isHidden, row.frame.maxY <= line.frame.minY
                else { return false }
                return !row.visibleCells.isEmpty
            } ?? false
        }

        /// Back with focus in our page (the scopes, the row): onto the
        /// keyboard. False: focus isn't there.
        func backToKeyboard() -> Bool {
            guard let page, let search, let window,
                  let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                  Self.environment(focused, isIn: page) else { return false }
            // (A request straight into the keyboard is ignored: the page
            // steps out of focus's way for a moment, and the search screen's
            // own choice — its keyboard — takes it.)
            guard let system = UIFocusSystem.focusSystem(for: window) else { return true }
            page.isUserInteractionEnabled = false
            system.requestFocusUpdate(to: search)
            system.updateFocusIfNeeded()
            page.isUserInteractionEnabled = true
            return true
        }

        /// Focus somewhere in `view` (SwiftUI's controls aren't views: by
        /// their environments).
        private static func environment(_ item: UIFocusEnvironment, isIn view: UIView) -> Bool {
            var environment: UIFocusEnvironment? = item
            while let current = environment {
                if current === view { return true }
                environment = current.parentFocusEnvironment
            }
            return false
        }
    }
}
