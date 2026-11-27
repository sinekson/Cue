import Combine
import SwiftUI

// MARK: - Discover

/// Discover: one sentence of words to change ("Show me fantasy anime movies
/// about anything…"), TMDB's titles under it. A browse page (a person, a
/// studio, a network) is the same page round its subject (`Subject`).
@MainActor
final class DiscoverModel: ObservableObject, PreparedPage {
    /// What a browse page is about (Details' cast, studios and networks,
    /// Search's people and studios): Discover's sentence round it.
    struct Subject: Hashable, Codable {
        enum Kind: String, Codable { case person, company, network }
        let kind: Kind
        let id: Int
        let name: String

        /// Its words in the sentence: "with Bryan Cranston", "from A24",
        /// "on HBO".
        var preposition: String {
            switch kind {
            case .person: "with"
            case .company: "from"
            case .network: "on"
            }
        }
    }

    enum Slot: String, CaseIterable, Identifiable {
        case genre, style, type, theme, origin, era, rating, order, watched
        var id: String { rawValue }
        var title: String {
            switch self {
            case .genre: "Genre"
            case .style: "Style"
            case .type: "Movies or Shows"
            case .theme: "Theme"
            case .origin: "Language"
            case .era: "Year"
            case .rating: "Rating"
            case .order: "Order"
            case .watched: "Watched"
            }
        }
    }

    /// One choice in a slot: its word in the sentence, its name in the list,
    /// what it asks TMDB (films' and shows' query, `isMovie`); false: this
    /// side has nothing for it.
    struct Option {
        let id: String
        let word: String
        var name: String? = nil
        var apply: (inout [String: String], Bool) -> Bool = { _, _ in true }
        /// A season's: its year and quarter (1–4), read at the asking.
        var quarter: (() -> (year: Int, quarter: Int))? = nil

        func with(quarter: @escaping () -> (year: Int, quarter: Int)) -> Option {
            var copy = self
            copy.quarter = quarter
            return copy
        }
    }

    /// The sentence. The tab's is kept per profile (Discover opens on the
    /// last one); one opened filled in (Details' genre or tag) is its own.
    @Published private(set) var picks: [Slot: String] {
        didSet { if persists { save() } }
    }
    private let persists: Bool
    /// A browse page's person, studio or network (nil: Discover itself).
    let subject: Subject?
    /// A person's credits, read once (their titles come from them, not
    /// TMDB's discover).
    private var credits: Task<TMDBService.PersonCredits, Never>?
    /// Choices the lists don't have: the genre or tag it was opened with.
    private var extras: [Slot: [Option]] = [:]
    /// A Home row's titles only: no line to fill.
    private var forRow = false
    /// Starting points, three runs of five: from your taste, from what's
    /// popular this week, curveballs away from your taste.
    /// (A browse page's: read from its subject's titles, then the people
    /// it works with most, or studios or networks like it.)
    /// Shuffled, so the tail gets its turn too.
    @Published private(set) var line: [LinePill] = DiscoverModel.fixedPresets.shuffled().map(LinePill.sentence)

    enum LinePill: Hashable {
        /// A sentence to fill in.
        case sentence([Slot: String])
        /// A related person's, studio's or network's page.
        case page(Subject)
    }

    /// The tab's own sentence.
    init() {
        picks = Self.saved()
        persists = true
        subject = nil
    }

    /// Filled in: `extras` added to their words' choices.
    init(picks: [Slot: String], extras: [Slot: [Option]], subject: Subject? = nil) {
        self.picks = picks
        self.extras = extras
        self.subject = subject
        persists = false
        if subject != nil { line = [] }
    }

    /// A browse page: movies and shows (a network's shows), the best known
    /// first, the rest open.
    convenience init(subject: Subject) {
        self.init(picks: Self.opening(subject), extras: [:], subject: subject)
    }

    static func opening(_ subject: Subject) -> [Slot: String] {
        [.type: subject.kind == .network ? "shows" : "both", .order: "known"]
    }

    var isReady: Bool { loadedOnce }

    /// The words a subject's sentence has (no theme or language: a
    /// person's credits carry no keywords, and one shape for all three).
    static func slots(for subject: Subject?) -> [Slot] {
        guard let subject else { return Slot.allCases }
        return [.genre, .style] + (subject.kind == .network ? [] : [.type]) + [.era, .rating, .order, .watched]
    }

    /// The page's model under `subject`, kept for the page.
    static func key(_ subject: Subject) -> String { "browse|\(subject.kind)|\(subject.id)" }

    /// A press: the titles start loading and the page opens under the
    /// still, shown once they're in or after `PagePreparer.wait`.
    static func open(_ subject: Subject, push: @escaping () -> Void) {
        let model = DiscoverModel(subject: subject)
        Task { await model.start() }
        PagePreparer.shared.open(key(subject), model, push: push)
    }

    /// The model the press prepared, else a new one.
    static func prepared(_ subject: Subject) -> DiscoverModel {
        PagePreparer.shared.take(key(subject)) ?? DiscoverModel(subject: subject)
    }

    /// What Details' genre opens: its genre, films or shows (a genre the
    /// list has by name, else TMDB's own for that side).
    static func genre(id: Int, name: String, isMovie: Bool) -> DiscoverModel {
        let type = isMovie ? "movies" : "shows"
        if id == 16 { return DiscoverModel(picks: [.type: type, .style: "animation"], extras: [:]) }
        if options(.genre).contains(where: { $0.id == name }) {
            return DiscoverModel(picks: [.type: type, .genre: name], extras: [:])
        }
        let own = Option(id: "g\(id)", word: name.lowercased(), name: name) { query, side in
            guard side == isMovie else { return false }
            addGenre(id, &query)
            return true
        }
        return DiscoverModel(picks: [.type: type, .genre: own.id], extras: [.genre: [own]])
    }

    /// What Details' tag opens: its titles, films or shows.
    static func keyword(id: Int, name: String, isMovie: Bool) -> DiscoverModel {
        let type = isMovie ? "movies" : "shows"
        let known = options(.theme).first { $0.id == "k\(id)" }
        let own = known ?? keyword(String(id), name.lowercased(), name.prefix(1).uppercased() + name.dropFirst())
        return DiscoverModel(picks: [.type: type, .theme: own.id], extras: known == nil ? [.theme: [own]] : [:])
    }

    /// What a card's Discover opens: the title's own words — its most
    /// telling genre (a specific one over action, adventure, drama or
    /// comedy), its style (anime, animated, live action), films or shows,
    /// and a theme where one of its keywords is on the list. The rest
    /// open ("Fantasy anime shows about isekai").
    static func like(_ traits: TMDBService.TitleTraits, isMovie: Bool) -> [Slot: String] {
        var picks: [Slot: String] = [.type: isMovie ? "movies" : "shows"]
        let animated = traits.genres.contains(16)
        picks[.style] = !animated ? "live" : traits.language == "ja" ? "anime" : "animation"
        let fantasy = Set(fantasyKeywords.split(separator: "|").compactMap { Int($0) })
        let names: [String] = traits.genres.compactMap { id in
            id == 10765 ? (traits.keywords.contains(where: fantasy.contains) ? "Fantasy" : "Science Fiction")
                : genreWord(id)
        }
        let broad: Set<String> = ["Action", "Adventure", "Drama", "Comedy"]
        if let genre = names.first(where: { !broad.contains($0) }) ?? names.first { picks[.genre] = genre }
        let keywords = Set(traits.keywords)
        if let theme = options(.theme).dropFirst().first(where: { option in
            option.id.dropFirst().split(separator: "|").contains { Int($0).map(keywords.contains) ?? false }
        }) {
            picks[.theme] = theme.id
        }
        return picks
    }

    /// The year's joining word: "of" after a studio's "from A24".
    static func eraWord(_ subject: Subject?) -> String { subject?.kind == .company ? "of" : "from" }

    /// TMDB's genre id as the Genre word's choice (films' and shows'
    /// alike; shows' Sci-Fi & Fantasy is the caller's to split).
    static func genreWord(_ id: Int) -> String? {
        switch id {
        case 28, 10759: "Action"
        case 12: "Adventure"
        case 35: "Comedy"
        case 80: "Crime"
        case 99: "Documentary"
        case 18: "Drama"
        case 10751: "Family"
        case 14: "Fantasy"
        case 36: "History"
        case 27: "Horror"
        case 9648: "Mystery"
        case 10749: "Romance"
        case 878: "Science Fiction"
        case 53: "Thriller"
        case 10752, 10768: "War"
        case 37: "Western"
        default: nil
        }
    }

    /// A browse page's starting points, read from its subject's titles:
    /// the side it does less of, its two biggest genres (drama only when
    /// nothing else is), animation or anime (or live action, for an
    /// animation studio), its busiest decade, acclaimed. Only what has
    /// four titles at least; five at most.
    static func points(for subject: Subject, from titles: [TMDBService.WorkTitle]) -> [[Slot: String]] {
        let base = opening(subject)
        func with(_ slot: Slot, _ id: String) -> [Slot: String] { base.merging([slot: id]) { $1 } }
        let least = 4
        var out: [[Slot: String]] = []
        // Genres.
        var genres: [String: Int] = [:]
        for title in titles {
            for word in Set(title.genres.compactMap { $0 == 10765 ? "Science Fiction" : genreWord($0) }) {
                genres[word, default: 0] += 1
            }
        }
        let ranked = genres.filter { $0.value >= least }.sorted { $0.value > $1.value }.map(\.key)
        let telling = ranked.filter { $0 != "Drama" }
        out += (telling.isEmpty ? ranked : telling).prefix(2).map { with(.genre, $0) }
        // Style.
        let animated = titles.filter { $0.genres.contains(16) }
        let anime = animated.filter { $0.language == "ja" }.count
        if anime >= least, anime * 10 < titles.count * 7 {
            out.append(with(.style, "anime"))
        } else if animated.count >= least, animated.count * 10 < titles.count * 7 {
            out.append(with(.style, "animation"))
        } else if animated.count * 10 >= titles.count * 7, titles.count - animated.count >= least {
            out.append(with(.style, "live"))
        }
        // The side it does less of (both in good number).
        if subject.kind != .network {
            let movies = titles.filter(\.isMovie).count, shows = titles.count - movies
            if min(movies, shows) >= least { out.append(with(.type, movies < shows ? "movies" : "shows")) }
        }
        // Its busiest decade, when its work spans more.
        var decades: [Int: Int] = [:]
        for year in titles.compactMap(\.year) where year >= 1970 { decades[year / 10 * 10, default: 0] += 1 }
        if let (decade, count) = decades.max(by: { $0.value < $1.value }), count >= least,
           count * 10 < titles.count * 8 {
            out.append(with(.era, "\(decade)s"))
        }
        // Acclaimed (TMDB's numbers as a guess; IMDb's decide on the page).
        if titles.filter({ $0.average >= 7.5 && $0.votes >= 1_000 }).count >= least {
            out.append(with(.rating, "acclaimed"))
        }
        return Array(out.prefix(5))
    }

    /// The sentence as a name, in sentence case: "Well rated fantasy anime
    /// movies about isekai from the 2010s" (the order only when it's
    /// popular or newest; anime's Japanese not said again).
    var title: String { Self.name(of: picks, extras: extras, subject: subject) }

    static func name(of picks: [Slot: String], extras: [Slot: [Option]] = [:], subject: Subject? = nil) -> String {
        func option(_ slot: Slot) -> Option? {
            guard let id = picks[slot], id != options(slot)[0].id else { return nil }
            return (options(slot) + (extras[slot] ?? [])).first { $0.id == id }
        }
        var words: [String] = []
        switch picks[.order] {
        case "popular": words.append("popular")
        case "new": words.append("new")
        default: break
        }
        if let rating = option(.rating) { words.append(rating.id == "gems" ? "hidden gem" : rating.word) }
        if let genre = option(.genre) { words.append(genre.word) }
        if let style = option(.style) { words.append(style.word) }
        words.append((options(.type).first { $0.id == picks[.type] } ?? options(.type)[0]).word)
        if let subject { words.append("\(subject.preposition) \(subject.name)") }
        if let theme = option(.theme) { words.append("about \(theme.word)") }
        if let origin = option(.origin), picks[.style] != "anime" { words.append("in \(origin.word)") }
        if let era = option(.era) { words.append("\(eraWord(subject)) \(era.word)") }
        let name = words.joined(separator: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Only a sentence of the lists' own words can go on Home (a genre or
    /// tag added from Details isn't kept).
    var pinnable: Bool { extras.isEmpty }

    /// On Home; Select again takes it off.
    func togglePin() {
        if let pin = DiscoverPins.shared.pin(for: picks, subject: subject) { DiscoverPins.shared.remove(pin.id) }
        else { DiscoverPins.shared.add(picks, subject: subject) }
    }

    /// A pin's sentence, loaded.
    func load(_ pin: DiscoverPins.Pin) { apply(preset: pin.slots) }

    /// The first titles, for a Home row.
    static func titles(for picks: [Slot: String], subject: Subject? = nil) async -> [MetaItem] {
        let model = DiscoverModel(picks: picks, extras: [:], subject: subject)
        model.forRow = true
        model.hideWatched = { _ in false }
        await model.start()
        return model.items
    }

    /// A word's choices: the list's, then this sentence's own.
    func choices(_ slot: Slot) -> [Option] { Self.options(slot) + (extras[slot] ?? []) }

    private static var savedKey: String {
        ProfileScopedDefaults.key("cue.discover.sentence", ProfileScopedDefaults.activeProfileID)
    }

    private static func saved() -> [Slot: String] {
        let raw = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            Slot(rawValue: key).flatMap { slot in
                options(slot).contains { $0.id == value } ? (slot, value) : nil
            }
        })
    }

    private func save() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: picks.map { ($0.key.rawValue, $0.value) }),
                                  forKey: Self.savedKey)
    }
    @Published private(set) var items: [MetaItem] = []
    @Published private(set) var total = 0
    @Published private(set) var loadedOnce = false
    @Published private(set) var isLoading = false

    /// The next TMDB page to read (a chunk can read several).
    private var nextPage = 1
    private var hasMore = false
    private var isLoadingMore = false
    private var generation = 0
    private var started = false
    var hideWatched: (MetaItem) -> Bool = { _ in false }

    /// The sides asked: films, shows, or both.
    var sides: [Bool] {
        switch pick(.type) {
        case "shows": [false]
        case "both": [true, false]
        default: [true]
        }
    }

    var countLabel: String {
        switch pick(.type) {
        case "shows": "shows"
        case "both": "titles"
        default: "movies"
        }
    }

    func pick(_ slot: Slot) -> String { picks[slot] ?? Self.options(slot)[0].id }
    func option(_ slot: Slot) -> Option {
        let id = pick(slot)
        return choices(slot).first { $0.id == id } ?? Self.options(slot)[0]
    }
    func isSet(_ slot: Slot) -> Bool { pick(slot) != Self.options(slot)[0].id }

    func set(_ slot: Slot, _ id: String) {
        guard pick(slot) != id else { return }
        picks[slot] = id
        Task { await reload() }
    }

    func apply(preset: [Slot: String]) {
        picks = preset
        Task { await reload() }
    }

    func start() async {
        guard !started else { return }
        started = true
        async let tasteful: Void = loadPresets()
        await reload()
        await tasteful
    }

    /// Fifteen starting points: five from your taste (the fixed ones
    /// filling in), five from this week's trending, five curveballs; none
    /// twice.
    private func loadPresets() async {
        guard !forRow else { return }
        if let subject { return await loadPoints(subject) }
        guard persists else { return }
        async let trending = TMDBService.trendingKinds()
        let model = await CueRows.tasteModel()
        let runs = [(model.map(Self.forYou) ?? []) + Self.fixedPresets,
                    Self.popular(await trending),
                    Self.curveballs(model)]
        var seen = Set<String>()
        var out: [[Slot: String]] = []
        for run in runs {
            out += run.filter { seen.insert(DiscoverPins.Pin.id(of: $0)).inserted }.prefix(5)
        }
        line = out.shuffled().map(LinePill.sentence)
    }

    /// A browse page's line: its starting points and related pages,
    /// together (pills coming in after would move the one in focus).
    private func loadPoints(_ subject: Subject) async {
        let titles: [TMDBService.WorkTitle]
        switch subject.kind {
        case .person: titles = TMDBService.work(of: await personCredits(subject.id).value)
        case .company, .network: titles = await TMDBService.work(brand: subject.id, isNetwork: subject.kind == .network)
        }
        let points = Self.points(for: subject, from: titles)
        let found = subject.kind == .person
            ? await TMDBService.collaborators(of: subject.id, in: titles)
            : await TMDBService.kindred(brand: subject.id, isNetwork: subject.kind == .network, in: titles)
        line = (points.map(LinePill.sentence)
                + found.map { LinePill.page(Subject(kind: subject.kind, id: $0.id, name: $0.name)) }).shuffled()
    }

    /// A person's credits, read once for the page.
    private func personCredits(_ id: Int) -> Task<TMDBService.PersonCredits, Never> {
        let all = credits ?? Task { await TMDBService.personCredits(id: id) }
        credits = all
        return all
    }

    /// The options whose ids hold a trait's (`"k:9882"` in `"k9882"`,
    /// `"l:da"` in `"sv|da|no"`).
    private static func option(_ slot: Slot, feature: String) -> Option? {
        let value = feature.split(separator: ":").last.map(String.init) ?? ""
        return options(slot).dropFirst().first { option in
            let id = slot == .theme ? String(option.id.dropFirst()) : option.id
            return id.split(separator: "|").contains { $0 == value }
        }
    }

    /// The anime themes: with an anime watcher, anime.
    private static let animeThemes: Set<String> = ["k237451", "k10046", "k9914", "k291483"]

    /// Your themes, your language with your genre, your genres (well
    /// rated; from your decade, else new).
    private static func forYou(_ model: CueRows.Model) -> [[Slot: String]] {
        let shares = model.taste.shares
        let features = shares.keys.sorted { model.pull($0) > model.pull($1) }
        let animeFan = (shares["g:16"] ?? 0) > 0.2 && (shares["l:ja"] ?? 0) > 0.15
        let type = model.taste.movieShare > 0.65 ? "movies" : model.taste.movieShare < 0.35 ? "shows" : "both"
        let themes = features.filter { $0.hasPrefix("k:") }.compactMap { option(.theme, feature: $0) }
        let genres = features.compactMap { feature -> Option? in
            guard feature.hasPrefix("g:"), let id = Int(feature.dropFirst(2)), id != 16,
                  let name = TMDBService.genre(id: id) else { return nil }
            return options(.genre).first { $0.id == name }
        }
        let language = features.first { $0.hasPrefix("l:") && $0 != "l:en" }.flatMap { option(.origin, feature: $0) }
        let decade = features.first { $0.hasPrefix("d:") && $0 < "d:2020" }.flatMap { feature -> String? in
            guard let year = Int(feature.dropFirst(2)) else { return nil }
            return year < 1970 ? "older" : "\(year)s"
        }

        var out: [[Slot: String]] = []
        for theme in themes.prefix(2) {
            out.append(animeFan && animeThemes.contains(theme.id)
                       ? [.type: "shows", .style: "anime", .theme: theme.id]
                       : [.type: "both", .theme: theme.id])
        }
        if let language {
            var picks: [Slot: String] = language.id == "ja" && animeFan ? [.style: "anime"] : [.origin: language.id]
            picks[.type] = type
            if let genre = genres.first { picks[.genre] = genre.id }
            out.append(picks)
        }
        if let genre = genres.first { out.append([.type: type, .genre: genre.id, .rating: "good"]) }
        if genres.count > 1 {
            out.append(decade.map { [.type: type, .genre: genres[1].id, .era: $0] }
                       ?? [.type: type, .genre: genres[1].id, .order: "new"])
        }
        return out
    }

    /// This week's trending as kinds: its films' and shows' biggest genres
    /// (drama only when nothing else is), anime, a language beyond English;
    /// popular now first.
    private static func popular(_ kinds: [TMDBService.TrendingKind]) -> [[Slot: String]] {
        // TMDB's shows' joined genres, as the list's words.
        let showGenres = ["Action & Adventure": "Action", "Sci-Fi & Fantasy": "Science Fiction", "War & Politics": "War"]
        var genres: [String: [String: Int]] = [:]
        var anime = 0
        var languages: [String: Int] = [:]
        for kind in kinds {
            if kind.genres.contains("Animation"), kind.language == "ja" { anime += 1; continue }
            let side = kind.isMovie ? "movies" : "shows"
            for name in kind.genres {
                let word = showGenres[name] ?? name
                guard options(.genre).contains(where: { $0.id == word }) else { continue }
                genres[side, default: [:]][word, default: 0] += 1
            }
            if let code = kind.language, code != "en", let origin = option(.origin, feature: "l:" + code) {
                languages[origin.id, default: 0] += 1
            }
        }
        func top(_ side: String) -> [String] {
            let counts = genres[side] ?? [:]
            let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            return ranked.filter { $0 != "Drama" } + ranked.filter { $0 == "Drama" }
        }
        let movies = top("movies"), shows = top("shows")
        var out: [[Slot: String]] = []
        func genre(_ side: String, _ list: [String], _ index: Int) {
            guard index < list.count else { return }
            out.append([.type: side, .genre: list[index], .order: "popular"])
        }
        genre("movies", movies, 0)
        genre("shows", shows, 0)
        if anime >= 3 { out.append([.type: "both", .style: "anime", .order: "popular"]) }
        if let (language, count) = languages.max(by: { $0.value < $1.value }), count >= 3 {
            out.append([.type: "both", .origin: language, .order: "popular"])
        }
        genre("movies", movies, 1)
        genre("shows", shows, 1)
        genre("movies", movies, 2)
        genre("shows", shows, 2)
        return out
    }

    /// Good things away from your taste, new each day: a theme, a language
    /// (with your genre), an older decade, a genre you don't watch.
    private static func curveballs(_ model: CueRows.Model?) -> [[Slot: String]] {
        let shares = model?.taste.shares ?? [:]
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        var random = SeededRandom(seed: UInt64(day) &* 7919)
        func unfamiliar(_ prefix: String, _ id: String) -> Bool {
            id.split(separator: "|").allSatisfy { (shares[prefix + $0] ?? 0) < 0.02 }
        }
        let themes = options(.theme).dropFirst().filter { unfamiliar("k:", String($0.id.dropFirst())) }
            .shuffled(using: &random)
        let languages = options(.origin).dropFirst().filter { $0.id != "en" && unfamiliar("l:", $0.id) }
            .shuffled(using: &random)
        let decades = ["older": "1960", "1970s": "1970", "1980s": "1980", "1990s": "1990"]
        let eras = decades.keys.sorted().filter { unfamiliar("d:", decades[$0]!) }.shuffled(using: &random)
        let yourGenre = model.flatMap { model in
            shares.keys.filter { $0.hasPrefix("g:") && $0 != "g:16" }.max { model.pull($0) < model.pull($1) }
        }.flatMap { Int($0.dropFirst(2)) }.flatMap { TMDBService.genre(id: $0) }
            .flatMap { name in options(.genre).first { $0.id == name } }
        let otherGenres = options(.genre).dropFirst().filter { genre in
            TMDBService.genre(named: genre.id, isMovie: true).map { (shares["g:\($0.id)"] ?? 0) < 0.02 } ?? false
        }.shuffled(using: &random)

        var out: [[Slot: String]] = []
        if let theme = themes.first { out.append([.type: "both", .theme: theme.id, .rating: "good"]) }
        if let language = languages.first {
            var picks: [Slot: String] = [.type: "movies", .origin: language.id, .rating: "good"]
            if let yourGenre { picks[.genre] = yourGenre.id }
            out.append(picks)
        }
        if let era = eras.first { out.append([.type: "movies", .era: era, .rating: "acclaimed"]) }
        if let genre = otherGenres.first { out.append([.type: "movies", .genre: genre.id, .rating: "acclaimed"]) }
        if languages.count > 1 { out.append([.type: "shows", .origin: languages[1].id, .rating: "good"]) }
        if themes.count > 1 { out.append([.type: "both", .theme: themes[1].id, .rating: "good"]) }
        return out
    }

    private func reload() async {
        generation += 1
        let mine = generation
        isLoading = true
        let (result, next) = await chunk(from: 1)
        guard mine == generation else { return }
        await FixedFocusImages.prefetch(result.items.prefix(12).map {
            (url: $0.poster ?? $0.background, maxDimension: PictureSize.poster)
        }, within: .milliseconds(700))
        guard mine == generation else { return }
        nextPage = next
        items = result.items
        total = result.total
        hasMore = result.hasMore
        isLoading = false
        loadedOnce = true
    }

    func loadMore(after item: MetaItem) async {
        guard hasMore, !isLoadingMore, let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 10 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let mine = generation
        let (result, next) = await chunk(from: nextPage)
        guard mine == generation else { return }
        nextPage = next
        hasMore = result.hasMore
        let known = Set(items.map(\.id))
        items += result.items.filter { !known.contains($0.id) }
    }

    /// TMDB's total is the count only while Cue drops nothing itself.
    var countIsExact: Bool {
        pick(.rating) == "any" && pick(.watched) != "hidden" && option(.era).quarter == nil
    }

    /// The next titles from `start`: TMDB's pages until a screenful is
    /// kept (IMDb's ratings, watched titles and a season's long runners are
    /// Cue's to drop), at most five (a season's ten: it drops many);
    /// "best for you" ranks three pages of the best known at a time.
    private func chunk(from start: Int) async -> (page: TMDBService.BrowsePage, next: Int) {
        await IMDbRatings.ready()
        let model = pick(.order) == "foryou" ? await CueRows.tasteModel() : nil
        let least = model == nil ? 1 : 3
        let rating = pick(.rating)
        let hideSeen = pick(.watched) == "hidden"
        let quarter = option(.era).quarter?()
        let pages = quarter == nil ? 5 : 10
        var items: [MetaItem] = []
        var known = Set<String>()
        var total = 0
        var more = true
        var page = start
        while more, page < start + pages, page - start < least || items.count < 18 {
            let result = await fetch(page: page)
            if page == start { total = result.total }
            var kept = result.items.filter {
                !known.contains($0.id) && Self.passes($0, rating: rating) && !(hideSeen && hideWatched($0))
            }
            if let quarter { kept = await Self.begun(kept, in: quarter) }
            for item in kept where known.insert(item.id).inserted { items.append(item) }
            more = result.hasMore
            page += 1
        }
        if let model { items = await Self.rank(items, by: model) }
        return (TMDBService.BrowsePage(items: items, total: total, hasMore: more), page)
    }

    /// The rating word by IMDb's own numbers, the badges' rules.
    private static func passes(_ item: MetaItem, rating: String) -> Bool {
        guard rating != "any" else { return true }
        guard let imdb = IMDbRatings.rating(item.id) else { return false }
        switch rating {
        case "good": return imdb.value >= 7 && imdb.votes >= 1_000
        case "acclaimed": return imdb.value >= 8 && imdb.votes >= 50_000
        case "gems": return imdb.value >= 7.5 && (1_000...20_000).contains(imdb.votes)
        default: return true
        }
    }

    /// A season's shows: only those that began something in it, not every
    /// show with an episode out. Anime by AniList, where each cour is its
    /// own entry dated by its start (a new cour counts; Detective Conan,
    /// One Piece, a cour begun the season before don't); TMDB's seasons
    /// lump cours and split long runners by year. Other shows: a season of
    /// TMDB's premiering in it. Films pass (their date is the release).
    private static func begun(_ items: [MetaItem], in quarter: (year: Int, quarter: Int)) async -> [MetaItem] {
        guard items.contains(where: { $0.type != "movie" }) else { return items }
        let anime = await AniList.begun(AniList.Season(quarter: quarter.quarter, year: quarter.year))
        let first = String(format: "%04d-%02d-01", quarter.year, (quarter.quarter - 1) * 3 + 1)
        let last = "\(quarter.year)-\(["03-31", "06-30", "09-30", "12-31"][quarter.quarter - 1])"
        let keep = await boundedConcurrentMap(items, limit: 8) { item -> Bool in
            guard item.type != "movie" else { return true }
            guard let found = await TMDBService.cueTraits(imdbID: item.id, type: item.type) else { return false }
            // (AniList unreached: TMDB's seasons rather than none.)
            if found.traits.genres.contains(16), found.traits.language == "ja", !anime.isEmpty {
                return anime.contains(imdb: item.id, tmdb: found.tmdbID, name: item.name)
            }
            return await TMDBService.seasonPremieres(tmdbID: found.tmdbID).contains { $0 >= first && $0 <= last }
        }
        return zip(items, keep).filter(\.1).map(\.0)
    }

    /// Best for you: the rows' fit for your taste, a little of the quality.
    private static func rank(_ items: [MetaItem], by model: CueRows.Model) async -> [MetaItem] {
        let keys = items.map { [$0.id, $0.type] }
        let scores = await boundedConcurrentMap(keys, limit: 8) { key -> Double in
            guard let found = await TMDBService.cueTraits(imdbID: key[0], type: key[1]) else { return -1 }
            let title = TMDBService.CueTitle(item: MetaItem(id: key[0], type: key[1], name: "", poster: nil, background: nil),
                                             tmdbID: found.tmdbID, isMovie: found.isMovie, traits: found.traits)
            return 0.7 * model.affinity(title) + 0.3 * CueRows.quality(found.traits)
        }
        return zip(items, scores).enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
    }

    /// A page of each side asked, mixed: one of each in turn (TMDB orders
    /// each side alone).
    private func fetch(page: Int) async -> TMDBService.BrowsePage {
        let pages = await withTaskGroup(of: (Bool, TMDBService.BrowsePage).self) { group in
            for side in sides { group.addTask { await (side, self.fetch(page: page, isMovie: side)) } }
            var all: [Bool: TMDBService.BrowsePage] = [:]
            for await (side, result) in group { all[side] = result }
            return all
        }
        let lists = sides.compactMap { pages[$0] }
        var items: [MetaItem] = []
        for index in 0..<(lists.map(\.items.count).max() ?? 0) {
            for list in lists where index < list.items.count { items.append(list.items[index]) }
        }
        return TMDBService.BrowsePage(items: items, total: lists.reduce(0) { $0 + $1.total },
                                      hasMore: lists.contains(where: \.hasMore))
    }

    private func fetch(page: Int, isMovie: Bool) async -> TMDBService.BrowsePage {
        var query: [String: String] = [:]
        // Order first: a rating's vote floor may raise its own.
        for slot in [Slot.order] + Slot.allCases.filter({ $0 != .order }) {
            guard option(slot).apply(&query, isMovie) else {
                return TMDBService.BrowsePage(items: [], total: 0, hasMore: false)
            }
        }
        // "16,14": every genre asked (Style's Animation and the Genre slot).
        if let genres = query["with_genres"] {
            query["with_genres"] = genres.split(separator: ",").map(String.init).uniqued().joined(separator: ",")
        }
        switch subject?.kind {
        case .person:
            return await TMDBService.credits(await personCredits(subject!.id).value, filter: query,
                                             isMovie: isMovie, page: page)
        case .company:
            query["with_companies"] = String(subject!.id)
        case .network:
            guard !isMovie else { return TMDBService.BrowsePage(items: [], total: 0, hasMore: false) }
            query["with_networks"] = String(subject!.id)
        case nil:
            break
        }
        return await TMDBService.browse(filter: query, isMovie: isMovie, page: page)
    }

    // MARK: The choices

    /// TMDB numbers a genre differently for movies and for shows, and a few
    /// are one genre on one side and two on the other.
    static func genreID(id: Int, name: String, from: Bool, to: Bool) -> Int? {
        if from == to { return id }
        let aliases: [String: [String]] = [
            "Action": ["Action & Adventure"], "Adventure": ["Action & Adventure"],
            "Action & Adventure": ["Action", "Adventure"],
            "Science Fiction": ["Sci-Fi & Fantasy"], "Fantasy": ["Sci-Fi & Fantasy"],
            "Sci-Fi & Fantasy": ["Science Fiction", "Fantasy"],
            "War": ["War & Politics"], "War & Politics": ["War"],
        ]
        for candidate in [name] + (aliases[name] ?? []) {
            if let genre = TMDBService.genre(named: candidate, isMovie: to) { return genre.id }
        }
        return nil
    }


    /// Keywords as one more condition (`,`: and); each list's own `|`: any.
    static func addKeywords(_ ids: String, _ query: inout [String: String]) {
        query["with_keywords"] = [query["with_keywords"], ids].compactMap { $0 }.joined(separator: ",")
    }

    static func addGenre(_ id: Int, _ query: inout [String: String]) {
        query["with_genres"] = [query["with_genres"], String(id)].compactMap { $0 }.joined(separator: ",")
    }

    private static func genre(_ name: String, _ word: String) -> Option {
        Option(id: name, word: word, name: name) { query, isMovie in
            // Shows have no Romance genre: theirs is by keywords
            // (`TMDBService.showGenres`).
            if !isMovie, name == "Romance" {
                addKeywords(TMDBService.romanceKeywords, &query)
                return true
            }
            let id: Int
            if let own = TMDBService.genre(named: name, isMovie: isMovie) {
                id = own.id
            } else if let other = TMDBService.genre(named: name, isMovie: !isMovie),
                      let mapped = genreID(id: other.id, name: name, from: !isMovie, to: isMovie) {
                id = mapped
            } else {
                return false
            }
            addGenre(id, &query)
            // Shows: TMDB has one "Sci-Fi & Fantasy"; its fantasy is the
            // part with fantasy's keywords, its sci-fi the rest.
            if !isMovie, id == 10765 {
                if name == "Fantasy" { addKeywords(fantasyKeywords, &query) }
                else { query["without_keywords"] = fantasyKeywords }
            }
            return true
        }
    }

    /// Magic, dragons, witches, myths, fairy tales, isekai.
    private static let fantasyKeywords = "2343|12554|616|2035|3205|237451"

    static func keyword(_ id: String, _ word: String, _ name: String) -> Option {
        Option(id: "k\(id)", word: word, name: name) { query, _ in
            addKeywords(id, &query)
            return true
        }
    }

    private static func language(_ code: String, _ word: String) -> Option {
        Option(id: code, word: word) { query, _ in
            if query["with_original_language"] == nil { query["with_original_language"] = code }
            return true
        }
    }

    private static func years(_ id: String, _ word: String, _ from: Int?, _ to: Int?) -> Option {
        Option(id: id, word: word) { query, isMovie in
            let key = isMovie ? "primary_release_date" : "first_air_date"
            if let from { query["\(key).gte"] = "\(from)-01-01" }
            if let to { query["\(key).lte"] = "\(to)-12-31" }
            return true
        }
    }

    /// The year's quarters by AniList's names: winter January–March, then
    /// spring, summer, fall.
    static let seasonNames = ["Winter", "Spring", "Summer", "Fall"]

    /// The quarter `ahead` of today's (0: this one): its year and number (1–4).
    static func quarter(ahead: Int) -> (year: Int, quarter: Int) {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        let index = (parts.year ?? 2026) * 4 + ((parts.month ?? 1) - 1) / 3 + ahead
        return (index / 4, index % 4 + 1)
    }

    /// A quarter: films released in it; shows on air in it (an episode
    /// out), then only those that began something in it (`begun`): new
    /// shows, new seasons and cours, no long runners. `when` read at the
    /// asking: "this season" moves on.
    private static func season(_ id: String, _ word: String, _ name: String,
                               _ when: @escaping () -> (year: Int, quarter: Int)) -> Option {
        Option(id: id, word: word, name: name) { query, isMovie in
            let (year, quarter) = when()
            let first = (quarter - 1) * 3 + 1
            let last = ["03-31", "06-30", "09-30", "12-31"][quarter - 1]
            let key = isMovie ? "primary_release_date" : "air_date"
            query["\(key).gte"] = String(format: "%04d-%02d-01", year, first)
            query["\(key).lte"] = "\(year)-\(last)"
            return true
        }
        .with(quarter: when)
    }

    private static func seasonLabel(_ when: (year: Int, quarter: Int)) -> String {
        "\(seasonNames[when.quarter - 1]) \(when.year)"
    }

    /// The year an era's id is in ("y2019", "2019-q3"), for the list's
    /// checks on its decades and years.
    static func year(ofEra id: String) -> Int? {
        if id.hasPrefix("y") { return Int(id.dropFirst()) }
        if id.contains("-q") { return Int(id.prefix(4)) }
        return nil
    }

    /// The years with pages of their own in Year's list (each with its
    /// seasons), newest first.
    static var listedYears: [Int] {
        Array((1970...Calendar.current.component(.year, from: Date())).reversed())
    }

    private static func floor(_ votes: Int, _ query: inout [String: String]) {
        query["vote_count.gte"] = String(max(votes, Int(query["vote_count.gte"] ?? "0") ?? 0))
    }

    static func options(_ slot: Slot) -> [Option] {
        let year = Calendar.current.component(.year, from: Date())
        switch slot {
        case .type:
            return [Option(id: "movies", word: "movies", name: "Movies"),
                    Option(id: "shows", word: "shows", name: "Shows"),
                    Option(id: "both", word: "movies & shows", name: "Movies & Shows")]
        case .style:
            return [
                Option(id: "any", word: "any style", name: "Any Style"),
                Option(id: "live", word: "live-action", name: "Live Action") { query, _ in
                    query["without_genres"] = "16"; return true
                },
                Option(id: "animation", word: "animated", name: "Animation") { query, _ in
                    addGenre(16, &query); return true
                },
                Option(id: "anime", word: "anime", name: "Anime") { query, _ in
                    addGenre(16, &query); query["with_original_language"] = "ja"; return true
                },
            ]
        case .genre:
            return [Option(id: "any", word: "any genre", name: "Any Genre")] + [
                ("Action", "action"), ("Adventure", "adventure"), ("Comedy", "comedy"), ("Crime", "crime"),
                ("Documentary", "documentary"), ("Drama", "drama"), ("Family", "family"),
                ("Fantasy", "fantasy"), ("History", "historical"), ("Horror", "horror"),
                ("Mystery", "mystery"), ("Romance", "romance"), ("Science Fiction", "sci-fi"),
                ("Thriller", "thriller"), ("War", "war"), ("Western", "western"),
            ].map { genre($0.0, $0.1) }
        case .theme:
            return [Option(id: "any", word: "anything", name: "Anything")] + [
                ("237451", "isekai", "Isekai"), ("10046", "mecha", "Mecha"), ("9914", "slice of life", "Slice of Life"),
                ("291483", "gentle things", "Iyashikei"), ("4379", "time travel", "Time Travel"),
                ("10854", "time loops", "Time Loops"), ("33465|336874", "parallel worlds", "Parallel Worlds"),
                ("9882", "space", "Set in Space"), ("4565", "dystopias", "Dystopias"),
                ("4458|359337|12332", "the apocalypse", "After the Apocalypse"), ("12190", "cyberpunk", "Cyberpunk"),
                ("2343", "magic", "Magic"), ("12554", "dragons", "Dragons"), ("616", "witches", "Witches"),
                ("2035", "myths & legends", "Myths & Legends"), ("9715", "superheroes", "Superheroes"),
                ("12377", "zombies", "Zombies"), ("3133", "vampires", "Vampires"), ("162846", "ghosts", "Ghosts"),
                ("10051", "heists", "Heists"), ("470|383851", "spies", "Spies"), ("10714", "serial killers", "Serial Killers"),
                ("9748", "revenge", "Revenge"), ("1462", "samurai", "Samurai"), ("779", "martial arts", "Martial Arts"),
                ("10683", "growing up", "Coming of Age"), ("10349", "survival", "Survival"),
                ("9672", "true stories", "Based on a True Story"), ("818", "books", "Based on a Book"),
                ("326438", "twist endings", "Twist Endings"),
            ].map { keyword($0.0, $0.1, $0.2) }
        case .origin:
            return [Option(id: "any", word: "any language", name: "Any Language")] + [
                ("en", "English"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("hi", "Hindi"),
                ("fr", "French"), ("es", "Spanish"), ("de", "German"), ("it", "Italian"), ("tr", "Turkish"),
                ("sv|da|no", "Scandinavian"),
            ].map { language($0.0, $0.1) }
        case .era:
            let now = quarter(ahead: 0), next = quarter(ahead: 1)
            return [
                years("any", "any year", nil, nil),
                season("season-now", "this season", "This Season · \(seasonLabel(now))") { quarter(ahead: 0) },
                season("season-next", "next season", "Next Season · \(seasonLabel(next))") { quarter(ahead: 1) },
                years("now", "this year", year, nil),
                years("recent", "the last 5 years", year - 4, nil),
                years("2020s", "the 2020s", 2020, 2029), years("2010s", "the 2010s", 2010, 2019),
                years("2000s", "the 2000s", 2000, 2009), years("1990s", "the '90s", 1990, 1999),
                years("1980s", "the '80s", 1980, 1989), years("1970s", "the '70s", 1970, 1979),
                years("older", "before 1970", nil, 1969),
            ] + listedYears.flatMap { listed in
                [years("y\(listed)", String(listed), listed, listed)] + (1...4).map { number in
                    season("\(listed)-q\(number)", seasonLabel((listed, number)), seasonLabel((listed, number))) {
                        (listed, number)
                    }
                }
            }
        case .rating:
            return [
                Option(id: "any", word: "any rating", name: "Any Rating"),
                // IMDb decides (`passes`); TMDB only narrows loosely
                // first: its votes are far fewer, its scores close.
                Option(id: "good", word: "well rated", name: "Well Rated (7+)") { query, _ in
                    query["vote_average.gte"] = "6.5"; floor(50, &query); return true
                },
                Option(id: "acclaimed", word: "acclaimed", name: "Acclaimed (8+)") { query, _ in
                    query["vote_average.gte"] = "7.2"; floor(500, &query); return true
                },
                Option(id: "gems", word: "hidden gems", name: "Hidden Gems") { query, _ in
                    query["vote_average.gte"] = "6.8"; floor(20, &query); query["vote_count.lte"] = "3000"; return true
                },
            ]
        case .order:
            return [
                Option(id: "foryou", word: "best for you first", name: "Best for You") { query, _ in
                    query["sort_by"] = "vote_count.desc"; return true
                },
                Option(id: "known", word: "best known first", name: "Best Known") { query, _ in
                    query["sort_by"] = "vote_count.desc"; return true
                },
                Option(id: "popular", word: "popular now first", name: "Popular Now") { query, _ in
                    query["sort_by"] = "popularity.desc"; floor(20, &query); return true
                },
                Option(id: "top", word: "top rated first", name: "Top Rated") { query, _ in
                    query["sort_by"] = "vote_average.desc"; floor(300, &query); return true
                },
                Option(id: "new", word: "newest first", name: "Newest") { query, isMovie in
                    let key = isMovie ? "primary_release_date" : "first_air_date"
                    query["sort_by"] = "\(key).desc"
                    if query["\(key).lte"] == nil { query["\(key).lte"] = Date().formatted(.iso8601.year().month().day()) }
                    floor(10, &query)
                    return true
                },
            ]
        case .watched:
            return [Option(id: "shown", word: "watched included", name: "Include Watched"),
                    Option(id: "hidden", word: "watched hidden", name: "Hide Watched")]
        }
    }

    /// Starting points with no taste yet: the sentence filled in.
    static let fixedPresets: [[Slot: String]] = [
        [.type: "movies", .style: "anime", .genre: "Fantasy"],
        [.type: "shows", .style: "anime", .theme: "k237451"],
        [.type: "movies", .genre: "Thriller", .origin: "ko"],
        [.type: "movies", .era: "1980s", .rating: "good"],
        [.type: "movies", .rating: "gems"],
    ]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

struct DiscoverView: View {
    @StateObject private var model: DiscoverModel
    @EnvironmentObject private var watched: WatchedStore
    @Environment(\.pageBack) private var pageBack
    @Environment(\.dismiss) private var dismiss
    @State private var gridBack = GridBack()
    let onOpenInPlace: (MetaItem) -> Void
    let onBack: () -> Void
    /// A browse page's related pill: that page.
    private var onOpenSubject: ((DiscoverModel.Subject) -> Void)? = nil
    /// Opened filled in from Details (a genre, a tag): a page pushed on
    /// Details' bands (that title's picture), no bar above it.
    private let opened: Bool
    private let backdrop: String?

    /// The tab.
    init(onOpenInPlace: @escaping (MetaItem) -> Void, onBack: @escaping () -> Void) {
        _model = StateObject(wrappedValue: DiscoverModel())
        opened = false
        backdrop = nil
        self.onOpenInPlace = onOpenInPlace
        self.onBack = onBack
    }

    /// Filled in, from Details (Back: the page's own way back).
    init(_ model: @autoclosure @escaping () -> DiscoverModel, backdrop: String?,
         onOpenInPlace: @escaping (MetaItem) -> Void,
         onOpenSubject: ((DiscoverModel.Subject) -> Void)? = nil) {
        _model = StateObject(wrappedValue: model())
        opened = true
        self.backdrop = backdrop
        self.onOpenInPlace = onOpenInPlace
        self.onOpenSubject = onOpenSubject
        onBack = {}
    }

    private var showsPlaceholder: Bool { !model.loadedOnce || model.isLoading }

    /// The bar's room above the grid (none on a pushed page).
    private var barRoom: CGFloat { opened ? 0 : DiscoverSentence.barRoom }
    private var headerTop: CGFloat { opened ? DiscoverSentence.top - DiscoverSentence.barRoom : DiscoverSentence.top }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if opened { TitleBandsBackground(url: backdrop) } else { ATVBackground() }
            FolderPosterGrid(
                // Filled in: focus starts on the first title (the sentence
                // is written; the titles are what you came for), the words
                // out of focus's way until they're in.
                header: AnyView(DiscoverSentence(model: model, waitsForTitles: opened, onOpenSubject: onOpenSubject)),
                headerHeight: DiscoverSentence.height,
                // Loading (the first titles, or a word changed): placeholders
                // in the grid's place, as Search's — the old titles no
                // longer match the sentence.
                items: showsPlaceholder ? FolderPosterGrid.placeholderItems : model.items,
                subtitles: Dictionary(model.items.compactMap { item in item.year.map { (item.id, $0) } },
                                      uniquingKeysWith: { first, _ in first }),
                onSelect: { _ in },
                onOpenDetails: { item in DetailTransition.shared.open(item) { onOpenInPlace(item) } },
                onDisplay: { item in Task { await model.loadMore(after: item) } },
                placeholder: showsPlaceholder,
                back: gridBack,
                // The tab: the words first, and Back's way up; filled in,
                // the titles, Back leaving from their first line.
                headerFirst: !opened,
                headerTop: headerTop,
                // The bar is on the page: it goes up with it, as Home's.
                onScroll: opened ? nil : { TopBarFollow.shared.set(-$0, for: "discover") },
                bleedTop: barRoom,
                barTab: opened ? nil : .discover)
                .padding(.top, barRoom)
                .ignoresSafeArea()
            if model.loadedOnce, !model.isLoading, model.items.isEmpty {
                Text("Nothing matches all of that. Try changing a word.")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(CueInk.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, headerTop + DiscoverSentence.height + 120)
            }
        }
        .task {
            model.hideWatched = { [weak watched] item in
                guard let watched else { return false }
                return watched.items.values.contains { $0.contentID == item.id }
            }
            await model.start()
        }
        // The tab: one of your rows opened from Settings (Your Rows).
        .onReceive(DiscoverPins.shared.$opening) { pin in
            guard !opened, let pin, pin.subject == nil else { return }
            model.load(pin)
            DispatchQueue.main.async { DiscoverPins.shared.opening = nil }
        }
        .onExitCommand {
            // The tab: the page up to its top on the way, focus on the bar
            // (never the sentence), as every tab.
            guard !gridBack.handle(then: opened ? nil : onBack) else { return }
            if !opened { onBack() } else if let pageBack { pageBack() } else { dismiss() }
        }
    }
}

/// The sentence: plain words joining the slots' words, each slot a flat
/// pill (set ones on the selected grey), then the starting points.
private struct DiscoverSentence: View {
    @ObservedObject var model: DiscoverModel
    /// Filled in: out of focus's way until the titles are in (they take
    /// it first). Here, not on the grid's side: its header is made once.
    var waitsForTitles = false
    /// A related person's, studio's or network's page.
    var onOpenSubject: ((DiscoverModel.Subject) -> Void)? = nil
    @ObservedObject private var pins = DiscoverPins.shared
    /// Each word's place on the screen: its list opens under it.
    @State private var anchors = DiscoverAnchors()
    /// Coming in: the sentence's first word. Only it is bound (a focus
    /// value for every word redrew the whole sentence and its line on each
    /// move between words); a scope's default only held the first time.
    @FocusState private var onFirst: Bool

    /// From the screen's top to the first line (the grid's room above
    /// the header): its pills' tops where Home's billboard card's top is.
    static var top: CGFloat { StagePictureView.homeCard.minY - (line - 58) / 2 }
    static let line: CGFloat = 72
    /// The top bar's room: the grid's frame starts under it.
    static let barRoom: CGFloat = 110
    static let height: CGFloat = line * 3 + 24 + 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                // The count at the first line's end, on the rows' right edge.
                HStack(spacing: 0) {
                    line(firstLine)
                    Spacer(minLength: 24)
                    Text(count)
                        .font(.system(size: 24))
                        .foregroundStyle(CueInk.tertiary)
                }
                line(secondLine)
            }
            .padding(.horizontal, FixedFocusMetrics.titleInset)
            // Side-scrolling, as Search's: Add to Home (On Home once it
            // is: Select takes it off), then the starting points.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LineChip.gap) {
                    if model.pinnable {
                        let pinned = pins.pin(for: model.picks, subject: model.subject) != nil
                        if pinned || !pins.full {
                            Button { model.togglePin() } label: {
                                LineChip(name: pinned ? "On Home" : "＋ Add to Home", checked: pinned)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        } else {
                            // (Eight on Home: room is made in Settings.)
                            Text("Home has \(DiscoverPins.limit) of your rows")
                                .font(.system(size: 24))
                                .foregroundStyle(CueInk.tertiary)
                                .padding(.horizontal, 8)
                        }
                    }
                    ForEach(model.line, id: \.self) { pill in
                        switch pill {
                        case let .sentence(picks):
                            Button { model.apply(preset: picks) } label: {
                                LineChip(name: DiscoverModel.name(of: picks, subject: model.subject))
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        case let .page(other):
                            Button { onOpenSubject?(other) } label: {
                                LineChip(name: other.name, icon: Self.icon(other.kind))
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, FixedFocusMetrics.titleInset)
                .frame(height: Self.line)
            }
            .scrollClipDisabled()
            .padding(.top, 24)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(waitsForTitles && !model.loadedOnce)
        .defaultFocus($onFirst, true)
        // The tab's (a filled-in page has no bar to come from).
    }

    /// Discover's: "Show me [genre] [style] [movies] about [theme]"; a
    /// browse page's: "Show me [genre] [style] [movies & shows] with Bryan
    /// Cranston".
    private var firstLine: [Part] {
        guard let subject = model.subject else {
            return [.word("Show me"), .slot(.genre), .slot(.style), .slot(.type), .word("about"), .slot(.theme)]
        }
        var parts: [Part] = [.word("Show me"), .slot(.genre), .slot(.style)]
        parts.append(subject.kind == .network ? .word("shows") : .slot(.type))
        parts += [.word(subject.preposition), .name(subject.name)]
        return parts
    }

    /// The rest (a browse page's without a language).
    private var secondLine: [Part] {
        (model.subject == nil ? [.word("in"), .slot(.origin)] : [])
            + [.word(DiscoverModel.eraWord(model.subject)), .slot(.era), .word("·"), .slot(.rating), .word("·"), .slot(.order),
               .word("·"), .slot(.watched)]
    }

    /// A related pill's symbol: it opens a page, not a sentence.
    private static func icon(_ kind: DiscoverModel.Subject.Kind) -> String {
        switch kind {
        case .person: "person.fill"
        case .company: "building.2.fill"
        case .network: "tv.fill"
        }
    }

    private var count: String {
        guard model.loadedOnce else { return " " }
        if model.isLoading { return "Looking…" }
        guard model.countIsExact else { return " " }
        return "\(model.total.formatted(.number)) \(model.countLabel)"
    }

    /// The word's choices in the menus' glass panel, under it; a pick
    /// changes the sentence and the titles under it, the page staying.
    private func open(_ slot: DiscoverModel.Slot) {
        guard let view = anchors.views[slot.rawValue], view.window != nil else { return }
        let current = model.pick(slot)
        let entries = slot == .era ? eraEntries(current) : model.choices(slot).map { option in
            MenuEntry(title: option.name ?? option.word.capitalized, icon: "", checked: option.id == current) {
                model.set(slot, option.id)
            }
        }
        HoldMenu.shared.open(HoldMenuRequest(entries: entries, anchor: view.convert(view.bounds, to: nil),
                                             below: true))
    }

    /// Year's list in pages: the relative and broad choices, then each
    /// decade's page (all of it, then its years), each year's page (all
    /// of it, then its four seasons). A decade or year holding the pick
    /// has its check.
    private func eraEntries(_ current: String) -> [MenuEntry] {
        let options = Dictionary(model.choices(.era).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pickedYear = DiscoverModel.year(ofEra: current)
        func choice(_ id: String, _ title: String? = nil) -> MenuEntry? {
            guard let option = options[id] else { return nil }
            return MenuEntry(title: title ?? option.name ?? option.word.capitalized, icon: "",
                             checked: id == current) { model.set(.era, id) }
        }
        func yearPage(_ year: Int) -> MenuEntry {
            MenuEntry(title: String(year), icon: "", checked: pickedYear == year, run: {},
                      pageTitle: String(year)) {
                [choice("y\(year)", "All of \(year)")].compactMap { $0 } + (1...4).compactMap { number in
                    choice("\(year)-q\(number)", DiscoverModel.seasonNames[number - 1])
                }
            }
        }
        let years = DiscoverModel.listedYears
        let decades = [("2020s", 2020), ("2010s", 2010), ("2000s", 2000), ("1990s", 1990), ("1980s", 1980), ("1970s", 1970)]
        let decadePages = decades.map { id, start in
            MenuEntry(title: id, icon: "",
                      checked: current == id || pickedYear.map { (start...start + 9).contains($0) } == true,
                      run: {}, pageTitle: id) {
                [choice(id, "All of the \(id)")].compactMap { $0 }
                    + years.filter { (start...start + 9).contains($0) }.map(yearPage)
            }
        }
        return ["any", "season-now", "season-next", "now", "recent"].compactMap { choice($0) }
            + decadePages + [choice("older")].compactMap { $0 }
    }

    enum Part: Hashable { case word(String), slot(DiscoverModel.Slot), name(String) }

    private func line(_ parts: [Part]) -> some View {
        HStack(spacing: 12) {
            ForEach(parts, id: \.self) { part in
                switch part {
                case let .word(text):
                    Text(text)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(CueInk.secondary)
                case let .name(text):
                    Text(text)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(CueInk.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                case let .slot(slot):
                    let word = Button { open(slot) } label: {
                        SentenceWord(text: model.option(slot).word, set: model.isSet(slot))
                            .background { AnchorView(anchors: anchors, key: slot.rawValue) }
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    if slot == .genre { word.focused($onFirst) } else { word }
                }
            }
        }
        .frame(height: Self.line)
        .focusSection()
    }
}

private struct SentenceWord: View {
    @Environment(\.isFocused) private var isFocused
    let text: String
    let set: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: set ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(height: 58)
            .foregroundStyle(isFocused ? FlatControl.contentOnFocus : set ? CueInk.primary : CueInk.tertiary)
            .background(Capsule().fill(isFocused ? FlatControl.focus : set ? FlatControl.selected : FlatControl.rest))
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(FlatControl.focusChange, value: isFocused)
    }
}

/// The sentence's words as UIKit sees them (the list opens under the one
/// pressed, in window points).
@MainActor
private final class DiscoverAnchors {
    var views: [String: UIView] = [:]
}

private struct AnchorView: UIViewRepresentable {
    let anchors: DiscoverAnchors
    let key: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { anchors.views[key] = view }
}

/// A pill in Discover's line: a sentence (a check before one on Home), or
/// Add to Home. A name too long for its room runs while focused.
private struct LineChip: View {
    @Environment(\.isFocused) private var isFocused
    let name: String
    var checked = false
    /// A symbol before the name (a related page's kind).
    var icon: String? = nil

    private static let font = UIFont.systemFont(ofSize: 24, weight: .medium)
    /// The words' room at most: about half the screen.
    private static let room: CGFloat = 760
    /// Between pills; focused, one grows at most `grow` each side (6 % of
    /// a long one ate the gap and touched its neighbours).
    static let gap: CGFloat = 24
    private static let grow: CGFloat = 8

    var body: some View {
        let ink = isFocused ? FlatControl.contentOnFocus : FlatControl.content
        let width = (name as NSString).size(withAttributes: [.font: Self.font]).width
        let long = width > Self.room
        let pill = min(width, Self.room) + 44 + (checked || icon != nil ? 32 : 0)
        let scale = min(1.06, 1 + 2 * Self.grow / pill)
        HStack(spacing: 10) {
            if checked || icon != nil {
                Image(systemName: icon ?? "checkmark")
                    .font(.system(size: 22, weight: .semibold))
            }
            Text(name)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)
                .frame(width: long ? Self.room : nil, alignment: .leading)
                .opacity(isFocused && long ? 0 : 1)
                .overlay {
                    if isFocused, long { RunningText(text: name, color: UIColor(ink)) }
                }
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .foregroundStyle(ink)
        .background(Capsule().fill(isFocused ? FlatControl.focus : FlatControl.rest))
        .scaleEffect(isFocused ? scale : 1)
        .animation(FlatControl.focusChange, value: isFocused)
    }
}

/// The player's running line (`RunningLine`) in SwiftUI: too long for its
/// place, it runs after a short rest.
private struct RunningText: UIViewRepresentable {
    let text: String
    let color: UIColor

    func makeUIView(context: Context) -> RunningLine {
        let line = RunningLine(font: .systemFont(ofSize: 24, weight: .medium), rest: 0.8)
        line.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return line
    }

    func updateUIView(_ line: RunningLine, context: Context) {
        line.text = text
        line.color = color
        line.running = true
    }
}

/// Your rows: Discover's sentences put on Home (per profile, eight at
/// most), each a large row from Home's second large-row slot on (after
/// Because You Watched), in your order, its name after the Discover compass:
/// the sentence in title case, or a name of your own. Arranged in Settings →
/// Home & Details → Your Rows. Their titles are fetched at launch and when
/// one is added.
@MainActor
final class DiscoverPins: ObservableObject {
    static let shared = DiscoverPins()
    static let limit = 8
    static let rowPrefix = "discover.pin."

    struct Pin: Codable, Equatable {
        let picks: [String: String]
        /// A name of your own (nil: the sentence).
        var title: String? = nil
        /// A browse page's person, studio or network.
        var subject: DiscoverModel.Subject? = nil

        var id: String { Self.id(of: slots, subject: subject) }
        static func id(of picks: [DiscoverModel.Slot: String], subject: DiscoverModel.Subject? = nil) -> String {
            let words = picks.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
            return ((subject.map { ["\($0.kind.rawValue)=\($0.id)"] } ?? []) + words).joined(separator: "&")
        }
        var slots: [DiscoverModel.Slot: String] {
            Dictionary(uniqueKeysWithValues: picks.compactMap { key, value in
                DiscoverModel.Slot(rawValue: key).map { ($0, value) }
            })
        }
        /// The sentence, in its own case ("Fantasy anime movies about isekai").
        @MainActor var name: String { DiscoverModel.name(of: slots, subject: subject) }
        /// Its name on Home (a subject's own name kept as it is: "the" in
        /// a studio's isn't the sentence's).
        @MainActor var rowName: String {
            if let title { return title }
            guard let subject else { return DiscoverPins.titleCase(name) }
            let mark = "\u{1}"
            return DiscoverPins.titleCase(DiscoverModel.name(of: slots, subject: DiscoverModel.Subject(
                kind: subject.kind, id: subject.id, name: mark))).replacingOccurrences(of: mark, with: subject.name)
        }
    }

    @Published private(set) var pins: [Pin] = [] { didSet { madeRows = nil } }
    /// A pin to open in Discover's tab (Your Rows' Open in Discover).
    @Published var opening: Pin?
    /// Your Rows' Add from Discover: the tab, at its sentence.
    let showDiscover = PassthroughSubject<Void, Never>()
    /// Each pin's titles, by its id.
    @Published private(set) var titles: [String: [MetaItem]] = [:] { didSet { madeRows = nil } }
    /// `rows` as last made, and the day (a name can say "This Season"):
    /// Home's body asks on every run, a tab switch too, and the names are
    /// worked out from Discover's lists (~15 ms each time in Debug).
    private var madeRows: (day: String, rows: [HomeRow])?
    private var loadedFor: Int?

    private var key: String {
        ProfileScopedDefaults.key("cue.discover.pins", ProfileScopedDefaults.activeProfileID)
    }

    /// The profile's pins (read again when the profile changed).
    private func load() {
        let profile = ProfileScopedDefaults.activeProfileID
        guard loadedFor != profile else { return }
        loadedFor = profile
        pins = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Pin].self, from: $0) } ?? []
        titles = [:]
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pins), forKey: key)
    }

    func pin(for picks: [DiscoverModel.Slot: String], subject: DiscoverModel.Subject? = nil) -> Pin? {
        load()
        let id = Pin.id(of: picks, subject: subject)
        return pins.first { $0.id == id }
    }

    /// On Home, last of your rows; never past the limit.
    func add(_ picks: [DiscoverModel.Slot: String], subject: DiscoverModel.Subject? = nil) {
        load()
        let pin = Pin(picks: Dictionary(uniqueKeysWithValues: picks.map { ($0.key.rawValue, $0.value) }),
                      subject: subject)
        guard !pins.contains(where: { $0.id == pin.id }), pins.count < Self.limit else { return }
        pins.append(pin)
        save()
        Task { await fetch(pin) }
    }

    var full: Bool { load(); return pins.count >= Self.limit }

    /// Up (−) or down (+) by `step` places (a lifted row, at its drop).
    func move(_ id: String, by step: Int) {
        load()
        guard let index = pins.firstIndex(where: { $0.id == id }), pins.indices.contains(index + step), step != 0 else { return }
        pins.insert(pins.remove(at: index), at: index + step)
        save()
    }

    /// A name of your own; empty or the sentence's: the sentence again.
    func rename(_ id: String, to title: String) {
        load()
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = pins[index]
        pins[index].title = trimmed.isEmpty || trimmed == Self.titleCase(pin.name) || trimmed == pin.name
            ? nil : trimmed
        save()
    }

    /// Your rows as they stand (Settings).
    var all: [Pin] { load(); return pins }

    func remove(_ id: String) {
        load()
        pins.removeAll { $0.id == id }
        titles[id] = nil
        save()
    }

    /// Every pin's titles (Home's load).
    func refresh() async {
        load()
        for pin in pins where titles[pin.id] == nil { await fetch(pin) }
    }

    private func fetch(_ pin: Pin) async {
        titles[pin.id] = Array(await DiscoverModel.titles(for: pin.slots, subject: pin.subject).prefix(25))
    }

    /// Home's rows: large rows.
    var rows: [HomeRow] {
        load()
        let day = CueRows.dayKey(Date())
        if let made = madeRows, made.day == day { return made.rows }
        let rows = pins.compactMap { pin -> HomeRow? in
            guard let items = titles[pin.id], !items.isEmpty else { return nil }
            return HomeRow(id: Self.rowPrefix + pin.id, title: pin.rowName, items: items)
        }
        madeRows = (day, rows)
        return rows
    }

    /// Home's rows' names: title case, small words lower but first
    /// ("Fantasy Anime Movies About Isekai from the 2010s").
    static func titleCase(_ text: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "of",
                                  "on", "or", "the", "to", "with", "&"]
        return text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if index > 0, small.contains(bare) { return word.lowercased() }
            return word.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
    }
}

// MARK: - Upcoming (prototype, 2026-11-19)

/// UPCOMING: what's on, as a calendar — the days as columns along a
/// strip, today held at the second spot (yesterday beside it), the days
/// sliding under it. Each day a square tile (its headline: the day's first
/// line) with its date, the day's lines under it; the tile follows focus
/// down the list; a day with more than fits takes another column. Your
/// shows' episodes first, then TMDB's popular shows airing, films opening
/// in your country and the season's popular anime (AniList), a week back
/// to two ahead; days with nothing left out.
@MainActor
final class UpcomingModel: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        /// nil: an anime with no IMDb id known (it can't open).
        let item: MetaItem?
        let name: String
        let date: Date
        let picture: String?
        /// "S2:E7", "S1:E1 · Premiere", "In cinemas", "E8", a studio…
        let info: String
        /// One of your shows (first in its day).
        let mine: Bool
        /// An episode's season and (last) number: its watched mark.
        let episode: (season: Int, number: Int)?

        init(id: String, item: MetaItem?, name: String? = nil, date: Date, picture: String?, info: String,
             mine: Bool, episode: (season: Int, number: Int)?) {
            self.id = id
            self.item = item
            self.name = name ?? item?.name ?? ""
            self.date = date
            self.picture = picture
            self.info = info
            self.mine = mine
            self.episode = episode
        }
    }

    struct Column: Identifiable {
        let id: String
        let day: Date
        let entries: [Entry]
    }

    struct Built {
        var columns: [Column]
        /// The column focus starts in: today's (or the first after it).
        var start: Int
    }

    @Published private(set) var calendar: Built?
    private var loading = false
    var following: [MetaItem] = []
    var addonManager: AddonManager?

    func load() async {
        guard calendar == nil, !loading else { return }
        loading = true
        defer { loading = false }
        calendar = await week()
    }

    static let daysBack = 7
    static let daysAhead = 14
    /// A day's lines at most: yours always, the rest by popularity.
    static let perDay = 10
    static let shows = 60
    /// A show not yours on more days than this in the window is a daily.
    static let dailyLimit = 6

    private typealias Dated = (order: Int, entry: Entry)

    /// A column a day, its lines by their order; every day of the window,
    /// an empty one too (a calendar).
    private static func build(_ days: [Date: [Dated]], from first: Date, to end: Date,
                              cap: ([Entry]) -> [Entry] = { $0 }) -> Built {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard !days.isEmpty else { return Built(columns: [], start: 0) }
        var columns: [Column] = []
        var start: Int?
        var day = first
        while day < end {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? end }
            let entries = cap(days[day, default: []].sorted { $0.order < $1.order }.map(\.entry))
            if start == nil, day >= today { start = columns.count }
            columns.append(Column(id: "\(Int(day.timeIntervalSince1970))", day: day, entries: entries))
        }
        return Built(columns: columns, start: start ?? max(0, columns.count - 1))
    }

    private func week() async -> Built {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let addonManager,
              let start = calendar.date(byAdding: .day, value: -Self.daysBack, to: today),
              let end = calendar.date(byAdding: .day, value: Self.daysAhead + 1, to: today)
        else { return Built(columns: [], start: 0) }
        async let mine = Self.mine(following, addonManager: addonManager, start: start, end: end)
        async let shows = Self.popularShows(start: start, end: end, skip: Set(following.map(\.id)))
        async let films = Self.films(start: start, end: end)
        async let anime = Self.anime(start: start, end: end)
        var days: [Date: [Dated]] = [:]
        var placed = Set<String>()
        for dated in await mine + shows + films + anime {
            let day = calendar.startOfDay(for: dated.entry.date)
            // An anime TMDB lists too, or one of yours: once a day.
            if let id = dated.entry.item?.id, !placed.insert("\(id)-\(day)").inserted { continue }
            days[day, default: []].append(dated)
        }
        return Self.build(days, from: start, to: end) { sorted in
            Array(sorted.prefix(max(sorted.filter(\.mine).count, Self.perDay)))
        }
    }

    // MARK: Anime

    /// Anime as titles, by IMDb id: the community's AniList → IMDb / TMDB
    /// list (`AnimeIDs`), else TMDB's search by name (only a name that
    /// matches); TMDB's pictures where it has them. Those found nowhere
    /// are left out (an id of AniList's own would reach the library).
    private static func items(for shows: [AniList.Show]) async -> [Int: MetaItem] {
        let ids = await AnimeIDs.map()
        let found = await boundedConcurrentMap(shows, limit: 8) { show -> MetaItem? in
            let type = show.isFilm && show.format == "MOVIE" ? "movie" : "series"
            var imdb: String?
            if let ref = ids[show.id] {
                imdb = ref.imdb
                if imdb == nil, let tmdb = ref.tmdb { imdb = await TMDBService.imdbID(tmdbID: tmdb, isMovie: ref.isMovie) }
            }
            if imdb == nil { imdb = await searched(show) }
            guard let imdb else { return nil }
            if let title = await TMDBService.cueTitle(imdbID: imdb, type: type) { return title.item }
            return MetaItem(id: imdb, type: type, name: show.name, poster: show.cover, background: show.banner)
        }
        var out: [Int: MetaItem] = [:]
        for (index, show) in shows.enumerated() { if let item = found[index] { out[show.id] = item } }
        return out
    }

    /// A show the list doesn't have yet, by TMDB's search: the first title
    /// whose name matches AniList's (a season's suffix aside).
    private static func searched(_ show: AniList.Show) async -> String? {
        let plain = AniList.plain
        for name in [show.english, show.romaji].compactMap({ $0 }) {
            let wanted = plain(name)
            guard wanted.count >= 4 else { continue }
            let hits = await TMDBService.searchMulti(name).filter { $0.type != "person" }
            if let hit = hits.prefix(3).first(where: { plain($0.name) == wanted }) { return hit.id }
        }
        return nil
    }

    /// The season's popular anime in the calendar: each airing weekly
    /// round its next episode (AniList gives only the next).
    private static func anime(start: Date, end: Date) async -> [Dated] {
        let season = AniList.season(of: Date())
        async let fresh = AniList.shows(season)
        async let carried = AniList.continuing(season)
        let shows = Array(await fresh.filter { !$0.isFilm && $0.next != nil }.prefix(20))
            + Array(await carried.prefix(8))
        let items = await items(for: shows)
        let calendar = Calendar.current
        var out: [Dated] = []
        for (index, show) in shows.enumerated() {
            guard let item = items[show.id], let next = show.next, let number = show.nextEpisode else { continue }
            for week in -3...3 {
                let episode = number + week
                guard episode >= 1, show.episodes.map({ episode <= $0 }) ?? true,
                      let date = calendar.date(byAdding: .day, value: 7 * week, to: next),
                      date >= start, date < end else { continue }
                let day = calendar.startOfDay(for: date)
                // AniList knows the minute: the time it airs, here.
                let time = date.formatted(date: .omitted, time: .shortened)
                out.append((1002 + 3 * index, Entry(
                    id: "anime-\(show.id)-\(episode)", item: item, name: show.name, date: day,
                    picture: item.background ?? show.banner ?? show.cover,
                    info: (episode == 1 ? "E1 · Premiere" : "E\(episode)") + " · " + time,
                    mine: false, episode: nil)))
            }
        }
        return out
    }

    /// A day's episodes of one show as a line (a season dropped at once is one).
    private static func episodeEntry(item: MetaItem, day: Date, season: Int, numbers: [Int],
                                     mine: Bool) -> Entry? {
        let numbers = numbers.sorted()
        guard let low = numbers.first, let high = numbers.last else { return nil }
        var info = low == high ? "S\(season):E\(low)" : "S\(season):E\(low)–\(high)"
        if low == 1 { info += season == 1 ? " · Premiere" : " · New season" }
        return Entry(id: "\(item.id)-\(Int(day.timeIntervalSince1970))", item: item, date: day,
                     picture: item.background ?? item.poster, info: info, mine: mine,
                     episode: (season, high))
    }

    /// Your shows (watched, started or saved, the latest first): their
    /// episode lists, the add-ons'.
    private static func mine(_ following: [MetaItem], addonManager: AddonManager,
                             start: Date, end: Date) async -> [Dated] {
        let shows = Array(following.prefix(Self.shows))
        let metas: [Int: MetaItem] = await withTaskGroup(of: (Int, MetaItem).self) { group in
            for (rank, show) in shows.enumerated() {
                group.addTask { @MainActor in
                    (rank, await SeriesEpisodes.fullMeta(for: show, addonManager: addonManager))
                }
            }
            var out: [Int: MetaItem] = [:]
            for await (rank, meta) in group { out[rank] = meta }
            return out
        }
        let calendar = Calendar.current
        var out: [Dated] = []
        for (rank, meta) in metas {
            let show = shows[rank]
            let item = MetaItem(id: meta.id, type: meta.type, name: meta.name.isEmpty ? show.name : meta.name,
                                poster: meta.poster ?? show.poster, background: meta.background ?? show.background,
                                logo: meta.logo ?? show.logo)
            var byDay: [Date: [MetaVideo]] = [:]
            for video in meta.videos ?? [] {
                guard let season = video.season, season > 0, video.episode != nil,
                      let date = video.airedDate, date >= start, date < end else { continue }
                byDay[calendar.startOfDay(for: date), default: []].append(video)
            }
            for (day, videos) in byDay {
                let season = videos.compactMap(\.season).max() ?? 0
                let numbers = videos.filter { $0.season == season }.compactMap(\.episode)
                if let entry = episodeEntry(item: item, day: day, season: season, numbers: numbers, mine: true) {
                    out.append((rank, entry))
                }
            }
        }
        return out
    }

    private static func ymd(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// TMDB's most popular shows with an episode in the window, their
    /// current season's dates. News, reality, soap and talk left out, and
    /// any show on most days (a daily one filled every day).
    private static func popularShows(start: Date, end: Date, skip: Set<String>) async -> [Dated] {
        var titles: [TMDBService.CueTitle] = []
        for page in 1...2 {
            let list = await TMDBService.cueList("/discover/tv", query: [
                "air_date.gte": ymd(start), "air_date.lte": ymd(end), "sort_by": "popularity.desc",
                "without_genres": "10763,10764,10766,10767", "vote_count.gte": "20", "include_adult": "false",
                "page": String(page)], isMovie: false)
            titles += list.titles
        }
        var seen = skip
        titles = titles.filter { seen.insert($0.item.id).inserted }
        let dates = await boundedConcurrentMap(titles, limit: 8) { await TMDBService.airDates(tmdbID: $0.tmdbID) }
        var out: [Dated] = []
        for (index, title) in titles.enumerated() {
            var byDay: [Date: [(season: Int, episode: Int)]] = [:]
            for found in dates[index] {
                guard let day = TMDBService.localDay(found.date), day >= start, day < end else { continue }
                byDay[day, default: []].append((found.season, found.episode))
            }
            guard byDay.count <= Self.dailyLimit else { continue }
            for (day, episodes) in byDay {
                let season = episodes.map(\.season).max() ?? 0
                if let entry = episodeEntry(item: title.item, day: day, season: season,
                                            numbers: episodes.filter { $0.season == season }.map(\.episode),
                                            mine: false) {
                    out.append((1000 + 3 * index, entry))
                }
            }
        }
        return out
    }

    /// Films opening in the window in your country: in cinemas, or
    /// streaming (TMDB's digital release).
    private static func films(start: Date, end: Date) async -> [Dated] {
        let region = CueRows.region
        let titles = await TMDBService.cueList("/discover/movie", query: [
            "region": region, "release_date.gte": ymd(start), "release_date.lte": ymd(end),
            "with_release_type": "2|3|4", "sort_by": "popularity.desc", "include_adult": "false"],
            isMovie: true).titles
        let releases = await boundedConcurrentMap(titles, limit: 8) {
            await TMDBService.releases(tmdbID: $0.tmdbID, region: region)
        }
        var out: [Dated] = []
        for (index, title) in titles.enumerated() {
            let found = releases[index]
            for (date, info) in [(found.cinemas, "In cinemas"), (found.streaming, "Streaming")] {
                guard let date, date >= start, date < end else { continue }
                out.append((1001 + 3 * index, Entry(
                    id: "\(title.item.id)-\(info)", item: title.item, date: date,
                    picture: title.item.background ?? title.item.poster, info: info, mine: false, episode: nil)))
            }
        }
        return out
    }
}

struct UpcomingView: View {
    @StateObject private var model = UpcomingModel()
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var library: LibraryStore
    let onOpen: (MetaItem) -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ATVBackground()
            if let built = model.calendar {
                if built.columns.isEmpty {
                    Text("Nothing on this week or the next two.")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(CueInk.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    UpcomingStrip(columns: built.columns, start: built.start, watched: watched,
                                  watchedRevision: watched.revision, onOpen: onOpen)
                        .frame(width: 1920, height: 1080)
                }
            } else {
                LoadingSpinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .task {
            guard model.addonManager == nil else { return }
            model.addonManager = addonManager
            model.following = BillboardPicks.History(progress: progressStore, watched: watched,
                                                     library: library).following
            await model.load()
        }
        .onExitCommand(perform: onBack)
    }
}

/// The calendar's strip, UIKit (`UpcomingStripController`): every day a
/// tall card, focus, the strip's slide and each day's scroll on Core
/// Animation (in SwiftUI every press re-rendered the days, their masks and
/// a large shadow frame by frame).
private struct UpcomingStrip: UIViewControllerRepresentable {
    let columns: [UpcomingModel.Column]
    let start: Int
    let watched: WatchedStore
    let watchedRevision: Int
    let onOpen: (MetaItem) -> Void

    func makeUIViewController(context: Context) -> UpcomingStripController {
        let controller = UpcomingStripController()
        TopBar.shared.entries[AppTab.upcoming.rawValue] = { [weak controller] in controller?.barEntry }
        return controller
    }

    func updateUIViewController(_ controller: UpcomingStripController, context: Context) {
        controller.onOpen = onOpen
        let watched = watched
        controller.seen = { entry in
            guard let id = entry.item?.id else { return false }
            guard let episode = entry.episode else {
                return entry.item?.type == "movie" && watched.isWatched(contentID: id)
            }
            return watched.isWatched(contentID: id, season: episode.season, episode: episode.number)
        }
        controller.show(columns, start: start, revision: watchedRevision)
    }
}

/// The calendar (Upcoming): every day (an empty one too) a tall card along
/// a strip, four across between the rows' edges, the days either side
/// peeking alike; opening with today second; moving focus: the strip moves
/// a card only when focus goes past the four in view. Above, the first day
/// in view's month as Home's row names, up by the card's growth while the
/// day under it has focus.
final class UpcomingStripController: UIViewController {
    var onOpen: (MetaItem) -> Void = { _ in }
    var seen: (UpcomingModel.Entry) -> Bool = { _ in false }

    static let across = 4
    /// A day's card: four across between the rows' edges, the cards' gap
    /// between, so the days either side peek alike (Home's rows).
    static var card: CGFloat {
        ((1920 - 2 * FixedFocusMetrics.inset - CGFloat(across - 1) * FixedFocusMetrics.gap) / CGFloat(across)).rounded(.down)
    }
    static var pitch: CGFloat { card + FixedFocusMetrics.gap }
    static var stripTop: CGFloat { StagePictureView.homeCard.minY + FixedFocusMetrics.titleHeight }

    private let strip = UIView()
    private let month = UILabel()
    private var days: [UpcomingDayView] = []
    private var ids: [String] = []
    private var revision = -1
    /// The day focus is in (or last was).
    private var spot = 0
    /// The first day in full view.
    private var shown = 0
    /// The day with focus now (nil: focus elsewhere).
    private var lit: Int?
    /// The days whose guides are on (`UpcomingDayView.aim`).
    private var aimed: Set<Int> = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(strip)
        month.font = FixedFocusRowCell.titleFont
        month.textColor = CueInk.ui(FixedFocusText.primary)
        month.frame = CGRect(x: FixedFocusMetrics.titleInset,
                             y: StagePictureView.homeCard.minY + FixedFocusMetrics.titleDrop,
                             width: 1200, height: FixedFocusMetrics.titleLine)
        view.addSubview(month)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseForPlayer),
                                               name: PictureRelease.release, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreAfterPlayer),
                                               name: PictureRelease.restore, object: nil)
    }

    /// The days' pictures let go while the player is up (`PictureRelease`).
    private var releasedForPlayer = false
    @objc private func releaseForPlayer() {
        guard isViewLoaded, PictureRelease.outOfSight(view) else { return }
        releasedForPlayer = true
        days.forEach { $0.releasePicture() }
    }
    @objc private func restoreAfterPlayer() {
        guard releasedForPlayer, !days.isEmpty else { return }
        releasedForPlayer = false
        for index in max(0, shown - 2)...min(days.count - 1, shown + Self.across + 1) { days[index].loadPicture() }
    }

    /// Down from the tab's bar: the day the strip holds, its first title
    /// (the engine's way went to the day nearest the tab).
    var barEntry: UIView? { days.indices.contains(spot) ? days[spot].firstFocusable : nil }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        barEntry.map { [$0] } ?? []
    }

    func show(_ columns: [UpcomingModel.Column], start: Int, revision: Int) {
        loadViewIfNeeded()
        let newIDs = columns.map { $0.id + ":" + $0.entries.map(\.id).joined(separator: ",") }
        if newIDs != ids {
            ids = newIDs
            build(columns, start: start)
        } else if revision != self.revision {
            days.forEach { $0.refreshSeen(seen) }
        }
        self.revision = revision
    }

    private func build(_ columns: [UpcomingModel.Column], start: Int) {
        days.forEach { $0.removeFromSuperview() }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        days = columns.enumerated().map { index, column in
            let day = UpcomingDayView(column: column, past: column.day < today, today: column.day == today,
                                      showsMonth: calendar.component(.day, from: column.day) == 1,
                                      seen: seen, onOpen: { [weak self] in self?.onOpen($0) })
            day.frame = CGRect(x: CGFloat(index) * Self.pitch, y: 0, width: Self.card, height: UpcomingDayView.height)
            strip.addSubview(day)
            return day
        }
        strip.frame = CGRect(x: 0, y: Self.stripTop, width: CGFloat(columns.count) * Self.pitch,
                             height: UpcomingDayView.height)
        spot = min(max(0, start), max(0, columns.count - 1))
        shown = max(0, spot - 1)
        lit = nil
        place(animated: false)
    }

    /// The strip at `shown`, the month of its first day, pictures near it.
    private func place(animated: Bool) {
        let moves = { self.strip.transform = CGAffineTransform(translationX: FixedFocusMetrics.inset - CGFloat(self.shown) * Self.pitch, y: 0) }
        if animated { FixedFocusMotion.run(duration: Motion.moveDuration, animations: moves) { _ in } } else { moves() }
        if days.indices.contains(shown) {
            let name = days[shown].column.day.formatted(.dateTime.month(.wide).year())
            if month.text != name {
                if animated, month.text != nil {
                    UIView.transition(with: month, duration: Motion.fadeDuration, options: .transitionCrossDissolve) {
                        self.month.text = name
                    }
                } else {
                    month.text = name
                }
            }
        }
        for index in max(0, shown - 2)...min(days.count - 1, shown + Self.across + 1) where days.indices.contains(index) {
            days[index].loadPicture()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let line = context.nextFocusedView as? UpcomingLineView
        let index = line.flatMap { line in days.firstIndex { line.isDescendant(of: $0) } }
        if let index, let line {
            spot = index
            if index < shown { shown = index; place(animated: true) }
            if index >= shown + Self.across { shown = index - Self.across + 1; place(animated: true) }
            days[index].focus(line)
        }
        // Left/Right reach the next day even with nothing level there (a
        // shorter day): each other day's guide aims at its title nearest
        // the focused one's height, the last if it's shorter.
        // Only the days either side: re-aiming every guide each press made
        // the engine rebuild its map.
        let height = line.map { $0.convert($0.bounds, to: nil).midY }
        let near = index.map { Set([$0 - 1, $0 + 1]) } ?? []
        for i in aimed.union(near) where days.indices.contains(i) { days[i].aim(near.contains(i) ? height : nil) }
        aimed = near
        guard index != lit else { return }
        let old = lit
        lit = index
        if let index { strip.bringSubviewToFront(days[index]) }
        FixedFocusMotion.run(duration: Motion.focusDuration, animations: {
            if let old, self.days.indices.contains(old) { self.days[old].setOn(false) }
            if let index { self.days[index].setOn(true) }
            // As a row's name over a grown card: up by the card's growth at
            // its top while the day under it (the first in view) has focus.
            self.month.transform = index == self.shown
                ? CGAffineTransform(translationX: 0, y: -UpcomingDayView.height * (UpcomingDayView.lift - 1) / 2)
                : .identity
        }) { _ in }
    }
}

/// A day as a tall card: the cards' corners, the cards' edge by Card
/// Outlines (bright on the day with focus), on the page's flat grey. At its
/// top the day's first title's picture (16:9), still, the date over the
/// weekday low on it over a shade; under it its titles, scrolling as focus
/// moves, each day on its own, fading out under the picture and at the
/// card's foot only where titles go on out of sight. The day with focus
/// grows 2 %, the cards' shadow under it (outside the card only); past
/// days dimmed.
final class UpcomingDayView: UIView, UIScrollViewDelegate {
    let column: UpcomingModel.Column
    private let past: Bool
    private let onOpen: (MetaItem) -> Void

    /// The picture, the card's width at 16:9.
    static var header: CGFloat { (UpcomingStripController.card * 9 / 16).rounded() }
    /// From the picture to the first line, the lines fading out over it.
    static let edge: CGFloat = 20
    /// The lines' fade at the card's foot (the focused line kept above it).
    static let foot: CGFloat = 80
    /// The line between titles and the room either side of it.
    static let rule: CGFloat = 1
    static let ruleGap: CGFloat = 5
    static var ruleRoom: CGFloat { rule + 2 * ruleGap }
    /// The titles' plates inside the card, each side.
    static let inset: CGFloat = 14
    /// Whole, its foot 60 pt above the screen's.
    static var height: CGFloat { 1080 - UpcomingStripController.stripTop - 60 }
    /// Grown a little: 2 % (6 % was far too strong on a card this tall).
    static let lift: CGFloat = 1.02
    /// The lines' room under the picture, to the card's foot.
    static var room: CGFloat { height - header }
    /// Below the last title, at the list's end: the card's inner margin
    /// with the focused shadow.
    static var endPad: CGFloat { UpcomingLineView.shadowBelow + 8 }

    private let shadow = UIImageView(image: FixedFocusCardEdge.shadowImage)
    private let content = UIView()
    private let picture = UIImageView()
    private let rim = UIImageView()
    private let edgeLine = UIView()
    private let linesClip = UIView()
    /// A scroll view, though scrolled only by us (`scrollTarget`): titles
    /// out of a plain clip's view were "not visible" to the focus engine,
    /// so Down to them and Right into them failed.
    private let linesContent = UIScrollView()
    private let fades = CALayer()
    private let topSolid = CALayer()
    private let footSolid = CALayer()
    private var lines: [UpcomingLineView] = []
    private var rules: [UIView] = []
    private var scroll: CGFloat = 0
    private var pictureAsked = false
    /// The whole card, for Left/Right from a neighbouring day (`aim`).
    private let guide = UIFocusGuide()

    init(column: UpcomingModel.Column, past: Bool, today: Bool, showsMonth: Bool,
         seen: (UpcomingModel.Entry) -> Bool, onOpen: @escaping (MetaItem) -> Void) {
        self.column = column
        self.past = past
        self.onOpen = onOpen
        let width = UpcomingStripController.card
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.height))
        let bounds = self.bounds
        let pad = FixedFocusCardEdge.shadowPad
        shadow.frame = bounds.insetBy(dx: -pad, dy: -pad)
        shadow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shadow.alpha = 0
        addSubview(shadow)

        content.frame = bounds
        content.clipsToBounds = true
        content.layer.cornerRadius = Spotlight.cornerRadius
        content.layer.cornerCurve = .continuous
        content.backgroundColor = CueInk.uiFill(dark: 0.13, light: 0.32)
        addSubview(content)

        // The picture with the cards' shade, no colour in it: a hard edge
        // on the card's grey.
        let onPicture = column.entries.first?.picture != nil
        if onPicture {
            picture.frame = CGRect(x: 0, y: 0, width: width, height: Self.header)
            picture.contentMode = .scaleAspectFill
            picture.clipsToBounds = true
            content.addSubview(picture)
            let shade = UpcomingShade(frame: picture.frame)
            content.addSubview(shade)
        }
        let header = Self.headerView(day: column.day, today: today, showsMonth: showsMonth, onPicture: onPicture)
        header.frame.origin = CGPoint(x: 24, y: Self.header - 16 - header.frame.height)
        content.addSubview(header)

        linesClip.frame = CGRect(x: 0, y: Self.header, width: width, height: Self.room)
        linesClip.clipsToBounds = true
        content.addSubview(linesClip)
        linesContent.frame = linesClip.bounds
        linesContent.showsVerticalScrollIndicator = false
        linesContent.delegate = self
        linesClip.addSubview(linesContent)
        let lineWidth = width - 2 * Self.inset
        for (index, entry) in column.entries.enumerated() {
            let top = Self.place(index).lowerBound
            if index > 0 {
                let rule = UIView(frame: CGRect(x: 24, y: top - Self.ruleGap - Self.rule,
                                                width: width - 48, height: Self.rule))
                rule.backgroundColor = CueInk.ui(0.1)
                linesContent.addSubview(rule)
                rules.append(rule)
            }
            let line = UpcomingLineView(entry: entry, seen: seen(entry), width: lineWidth)
            line.frame.origin = CGPoint(x: Self.inset, y: top)
            line.onSelect = { [weak self] in if let item = entry.item { self?.onOpen(item) } }
            linesContent.addSubview(line)
            lines.append(line)
        }
        linesContent.contentSize = CGSize(width: width, height: Self.room + maxScroll)
        buildFades()
        updateFades(animated: false)

        // The cards' edge (Card Outlines): the thin rim, bright on focus.
        rim.image = FixedFocusCardEdge.rim
        rim.frame = bounds
        rim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(rim)
        edgeLine.frame = bounds
        edgeLine.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        edgeLine.layer.cornerRadius = Spotlight.cornerRadius
        edgeLine.layer.cornerCurve = .continuous
        edgeLine.layer.borderWidth = 2
        edgeLine.layer.borderColor = FixedFocusRing.color.cgColor
        edgeLine.alpha = 0
        edgeLine.isUserInteractionEnabled = false
        addSubview(edgeLine)
        alpha = past ? FixedFocusMetrics.peekAlpha : 1
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        guide.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Focus in another day at `height` (on screen): the guide sends a move
    /// here to the title nearest it; nil (focus here, or out of the strip):
    /// off.
    func aim(_ height: CGFloat?) {
        let focusable = lines.filter(\.canBecomeFocused)
        guard let height, !focusable.isEmpty else {
            if guide.isEnabled { guide.isEnabled = false }
            return
        }
        let nearest = focusable.map { ($0, abs($0.convert($0.bounds, to: nil).midY - height)) }
            .min { $0.1 < $1.1 }!.0
        if guide.preferredFocusEnvironments.first !== nearest { guide.preferredFocusEnvironments = [nearest] }
        if !guide.isEnabled { guide.isEnabled = true }
    }

    var firstFocusable: UIView? { lines.first { $0.canBecomeFocused } }

    /// Line `index`'s top and foot in its day's list, unscrolled: every
    /// line one height, so the scroll, its end and the fades follow from
    /// its place (measured, they fell out of step).
    private static func place(_ index: Int) -> ClosedRange<CGFloat> {
        let top = edge + CGFloat(index) * (UpcomingLineView.height + ruleRoom)
        return top...top + UpcomingLineView.height
    }

    /// As far as the list scrolls: its last title at the card's foot.
    private var maxScroll: CGFloat {
        guard !column.entries.isEmpty else { return 0 }
        return max(0, Self.place(column.entries.count - 1).upperBound + Self.endPad - Self.room)
    }

    /// The fades: under the picture and at the foot, each only where titles
    /// go on out of sight (a solid over it otherwise).
    private func buildFades() {
        let w = linesClip.bounds.width, h = linesClip.bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fades.frame = linesClip.bounds
        let top = CAGradientLayer()
        top.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        top.frame = CGRect(x: 0, y: 0, width: w, height: Self.edge)
        let middle = CALayer()
        middle.backgroundColor = UIColor.black.cgColor
        middle.frame = CGRect(x: 0, y: Self.edge, width: w, height: h - Self.edge - Self.foot)
        let bottom = CAGradientLayer()
        bottom.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        bottom.frame = CGRect(x: 0, y: h - Self.foot, width: w, height: Self.foot)
        topSolid.backgroundColor = UIColor.black.cgColor
        topSolid.frame = top.frame
        footSolid.backgroundColor = UIColor.black.cgColor
        footSolid.frame = bottom.frame
        [top, middle, bottom, topSolid, footSolid].forEach(fades.addSublayer)
        linesClip.layer.mask = fades
        CATransaction.commit()
    }

    private func updateFades(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Motion.moveDuration)
        topSolid.opacity = scroll > 0 ? 0 : 1
        footSolid.opacity = scroll < maxScroll ? 0 : 1
        CATransaction.commit()
    }

    /// The day with focus: grown, the cards' shadow under it, its edge
    /// bright (Card Outlines high); past days at full brightness then.
    func setOn(_ on: Bool) {
        transform = on ? CGAffineTransform(scaleX: Self.lift, y: Self.lift) : .identity
        shadow.alpha = on ? 1 : 0
        edgeLine.alpha = on && FixedFocusRing.outlines == .high ? 1 : 0
        alpha = past && !on ? FixedFocusMetrics.peekAlpha : 1
    }

    /// Focus on one of its lines: scrolled just enough to show it, clear of
    /// the fades (its shadow too: cut by them as lines moved, it flickered);
    /// the rules beside it gone.
    func focus(_ line: UpcomingLineView) {
        guard let index = lines.firstIndex(of: line) else { return }
        for (i, rule) in rules.enumerated() {
            let hidden = i == index - 1 || i == index
            UIView.animate(withDuration: UpcomingLineView.time, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                rule.alpha = hidden ? 0 : 1
            }
        }
        let target = scrollTarget(index)
        guard target != scroll else { return }
        scroll = target
        FixedFocusMotion.run(duration: Motion.moveDuration, animations: {
            self.linesContent.contentOffset = CGPoint(x: 0, y: target)
        }) { _ in }
        updateFades(animated: true)
    }

    /// Where the list goes for line `index`: just enough to show it.
    private func scrollTarget(_ index: Int) -> CGFloat {
        let place = Self.place(index)
        var target = scroll
        let footLimit = Self.room - Self.foot - UpcomingLineView.shadowBelow
        let topLimit = Self.edge + UpcomingLineView.shadowAbove
        if place.upperBound - target > footLimit { target = place.upperBound - footLimit }
        if place.lowerBound - target < topLimit { target = max(0, place.lowerBound - topLimit) }
        return min(target, maxScroll)
    }

    /// The engine's own scroll to a title, stopped where the list is: its
    /// animation runs on the main thread; ours (`focus`) on Core Animation.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee = scrollView.contentOffset
    }

    /// The rules come back when focus leaves the day.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, !next.isDescendant(of: self) else { return }
        UIView.animate(withDuration: UpcomingLineView.time, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            self.rules.forEach { $0.alpha = 1 }
        }
    }

    func refreshSeen(_ seen: (UpcomingModel.Entry) -> Bool) {
        for line in lines { line.setSeen(seen(line.entry)) }
    }

    func releasePicture() {
        picture.image = nil
        pictureAsked = false
    }

    /// The day's first title's picture, once near the strip's view.
    func loadPicture() {
        guard !pictureAsked, let url = column.entries.first?.picture else { return }
        pictureAsked = true
        let maxDimension = UpcomingStripController.card * 2
        let key = RemoteImage.memoryKey(url, maxDimension: maxDimension, maxPixels: nil)
        if let cached = ImageCache.shared.image(for: key) { picture.image = cached; return }
        Task { [weak self] in
            guard let image = await Self.load(url, key: key, maxDimension: maxDimension), let self else { return }
            UIView.transition(with: self.picture, duration: 0.28, options: .transitionCrossDissolve) {
                self.picture.image = image
            }
        }
    }

    /// As `RemoteImage` loads: disk, else the network, decoded off the
    /// main thread at the card's size.
    private static func load(_ url: String, key: String, maxDimension: CGFloat) async -> UIImage? {
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil)
        if let disk = await ImageCache.shared.diskImage(for: url, budget: budget, memoryKey: key) { return disk }
        guard let parsed = URL(string: url), let data = try? await ImageCache.shared.download(parsed),
              let image = await DecodeGate.shared.run(.now, { ImageCache.decodeDownsampled(data, budget: budget) })
        else { return nil }
        ImageCache.shared.insert(image, for: url, data: data, memoryKey: key)
        return image
    }

    /// The date over the weekday, the weekday lowest (nearest the shade's
    /// darkest); on the picture white (dark always), else the page's ink.
    /// Today: the number dark on the selected tab's pill as light mode
    /// draws it (white 55 %) on the picture, else on the selected grey.
    private static func headerView(day: Date, today: Bool, showsMonth: Bool, onPicture: Bool) -> UIView {
        let ink: (CGFloat) -> UIColor = { onPicture ? UIColor.white.withAlphaComponent($0) : CueInk.ui($0) }
        let box = UIView()
        let number = UILabel()
        number.text = day.formatted(.dateTime.day())
        number.font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        number.textColor = today && onPicture ? .black : ink(FixedFocusText.primary)
        number.sizeToFit()
        var x: CGFloat = 0
        if today {
            let pill = UIView(frame: CGRect(x: -14, y: 0, width: number.frame.width + 28, height: number.frame.height))
            pill.layer.cornerRadius = 10
            pill.layer.cornerCurve = .continuous
            pill.backgroundColor = onPicture ? UIColor.white.withAlphaComponent(0.55)
                : CueInk.uiFill(dark: 0.28, light: 0.55)
            box.addSubview(pill)
        }
        number.frame.origin = CGPoint(x: x, y: 0)
        box.addSubview(number)
        x += number.frame.width + (today ? 14 : 0) + 10
        if showsMonth {
            let monthName = UILabel()
            monthName.text = day.formatted(.dateTime.month(.abbreviated)).uppercased()
            monthName.font = .systemFont(ofSize: 24, weight: .semibold)
            monthName.textColor = ink(FixedFocusText.body)
            monthName.sizeToFit()
            // On the number's baseline.
            monthName.frame.origin = CGPoint(x: x, y: number.font.ascender - monthName.font.ascender
                                             + (number.frame.height - number.font.lineHeight) / 2)
            box.addSubview(monthName)
        }
        let weekday = UILabel()
        weekday.attributedText = NSAttributedString(
            string: today ? "TODAY" : day.formatted(.dateTime.weekday(.wide)).uppercased(),
            attributes: [.font: UIFont.systemFont(ofSize: 23, weight: .semibold), .kern: 1,
                         .foregroundColor: ink(today ? FixedFocusText.primary : FixedFocusText.body)])
        weekday.sizeToFit()
        weekday.frame.origin = CGPoint(x: 0, y: number.frame.maxY + 2)
        box.addSubview(weekday)
        box.frame.size = CGSize(width: 600, height: weekday.frame.maxY)
        return box
    }
}

/// The cards' shade under a day's date: clear, then to 85 % black.
private final class UpcomingShade: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [UIColor.clear, UIColor.black.withAlphaComponent(0.5), UIColor.black.withAlphaComponent(0.85)]
            .map(\.cgColor)
        gradient.locations = [0.25, 0.6, 1]
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One title in a day's card: nothing behind it at rest; focused, shaped
/// as Settings' tall rows with the top bar's focus: its white, its shadow
/// (35 %, 12 pt, 6 down), dark words, the platter 4.5 pt larger each side;
/// the same quick move both ways (0.12 s), growing while fading in,
/// shrinking while fading out. A press takes it back to its resting size,
/// then up again.
final class UpcomingLineView: UIView {
    let entry: UpcomingModel.Entry
    var onSelect: () -> Void = {}
    private var seen: Bool
    private let plate = UIView()
    private let name = UILabel()
    private let info = UILabel()
    private var lit = false

    static let radius: CGFloat = 20
    static let shadowRadius: CGFloat = 12
    static let shadowDrop: CGFloat = 6
    static var shadowAbove: CGFloat { shadowRadius - shadowDrop + SettingsMetrics.focusGrowth }
    static var shadowBelow: CGFloat { shadowRadius + shadowDrop + SettingsMetrics.focusGrowth }
    static let time = 0.12
    /// Every line one height: the name and the info a line each, 14 pt
    /// above and below (the day's scroll is reckoned from it).
    static let pad: CGFloat = 14
    static let gap: CGFloat = 2
    static let height: CGFloat = 2 * pad + gap
        + UIFont.systemFont(ofSize: 24, weight: .medium).lineHeight.rounded(.up)
        + UIFont.systemFont(ofSize: 24, weight: .regular).lineHeight.rounded(.up)

    init(entry: UpcomingModel.Entry, seen: Bool, width: CGFloat) {
        self.entry = entry
        self.seen = seen
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.height))
        plate.frame = bounds
        plate.backgroundColor = .white
        plate.layer.cornerRadius = Self.radius
        plate.layer.cornerCurve = .continuous
        plate.layer.shadowColor = UIColor.black.cgColor
        plate.layer.shadowOpacity = 0.35
        plate.layer.shadowRadius = Self.shadowRadius
        plate.layer.shadowOffset = CGSize(width: 0, height: Self.shadowDrop)
        plate.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.radius).cgPath
        plate.alpha = 0
        addSubview(plate)
        let textX = 24 - UpcomingDayView.inset
        let nameFont = UIFont.systemFont(ofSize: 24, weight: .medium)
        name.font = nameFont
        name.text = entry.name
        name.frame = CGRect(x: textX, y: Self.pad, width: width - 2 * textX, height: nameFont.lineHeight.rounded(.up))
        addSubview(name)
        info.font = .systemFont(ofSize: 24, weight: .regular)
        info.frame = CGRect(x: textX, y: name.frame.maxY + Self.gap, width: width - 2 * textX,
                            height: info.font.lineHeight.rounded(.up))
        addSubview(info)
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// An anime with no IMDb id known can't open: not focusable.
    override var canBecomeFocused: Bool { entry.item != nil }

    func setSeen(_ seen: Bool) {
        guard seen != self.seen else { return }
        self.seen = seen
        paint()
    }

    private func paint() {
        name.textColor = lit ? .black : CueInk.ui(seen ? FixedFocusText.secondary : FixedFocusText.primary)
        let infoColor = lit ? UIColor.black.withAlphaComponent(0.6)
            : CueInk.ui(seen ? FixedFocusText.tertiary : FixedFocusText.body)
        let text = NSMutableAttributedString()
        if seen, let check = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(font: info.font)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: check.withTintColor(infoColor, renderingMode: .alwaysOriginal))))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: entry.info))
        text.addAttributes([.foregroundColor: infoColor, .font: info.font!], range: NSRange(location: 0, length: text.length))
        info.attributedText = text
    }

    private var grownPlate: CGAffineTransform {
        let g = SettingsMetrics.focusGrowth
        return CGAffineTransform(scaleX: (bounds.width + 2 * g) / bounds.width, y: (bounds.height + 2 * g) / bounds.height)
    }
    private var grownLine: CGAffineTransform {
        CGAffineTransform(scaleX: SettingsMetrics.focusScale, y: SettingsMetrics.focusScale)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard focused != lit, focused || context.previouslyFocusedView === self else { return }
        lit = focused
        // The words' colour crossfades with the plate (labels' colours don't animate).
        for label in [name, info] {
            UIView.transition(with: label, duration: Self.time, options: [.transitionCrossDissolve, .beginFromCurrentState]) {}
        }
        paint()
        UIView.animate(withDuration: Self.time, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            self.plate.alpha = focused ? 1 : 0
        }
        UIView.animate(withDuration: Self.time, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.plate.transform = focused ? self.grownPlate : .identity
            self.transform = focused ? self.grownLine : .identity
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }), isFocused else { return super.pressesBegan(presses, with: event) }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.transform = .identity
            self.plate.transform = .identity
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }), isFocused else { return super.pressesEnded(presses, with: event) }
        lift()
        onSelect()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesCancelled(presses, with: event) }
        lift()
    }

    private func lift() {
        FixedFocusMotion.run(duration: Motion.focusDuration, animations: {
            self.transform = self.isFocused ? self.grownLine : .identity
            self.plate.transform = self.isFocused ? self.grownPlate : .identity
        }) { _ in }
    }
}

/// AniList's seasons (no key): the season's anime, the most popular
/// first, with its next airing (a moment: shown on its day here) — the
/// calendar's anime. Asked once a run per list.
@MainActor
enum AniList {
    struct Season: Hashable {
        let name: String
        let year: Int
        init(name: String, year: Int) { self.name = name; self.year = year }
        /// Quarter 1–4: winter to fall.
        init(quarter: Int, year: Int) { self.init(name: AniList.names[quarter - 1], year: year) }
    }

    /// What began in a season, to match TMDB's shows against: Fribb's
    /// ids, else the names (a season's suffix aside).
    struct Begun: Sendable {
        let imdb: Set<String>
        let tmdb: Set<Int>
        let names: Set<String>
        var isEmpty: Bool { imdb.isEmpty && tmdb.isEmpty && names.isEmpty }
        func contains(imdb: String, tmdb: Int, name: String) -> Bool {
            self.imdb.contains(imdb) || self.tmdb.contains(tmdb) || names.contains(AniList.plain(name))
        }
    }

    /// A name compared across AniList and TMDB: lower case, letters and
    /// digits, "2nd Season", "Part 2" or a trailing number dropped.
    nonisolated static func plain(_ text: String) -> String {
        var text = text.lowercased()
        for suffix in [#"\s*(\d+(st|nd|rd|th)\s+)?season(\s+\d+)?$"#, #"\s*part\s+\d+$"#, #"\s+\d+$"#] {
            text = text.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
        }
        return text.filter { $0.isLetter || $0.isNumber }
    }

    /// Every series that began in the season (TV, shorts, web series; up
    /// to 400, a season has fewer), as Discover's season word asks.
    static func begun(_ season: Season) async -> Begun {
        async let listed = list("""
        query($season: MediaSeason, $year: Int, $page: Int) { Page(page: $page, perPage: 50) {
          pageInfo { hasNextPage }
          media(season: $season, seasonYear: $year, type: ANIME, isAdult: false, sort: POPULARITY_DESC,
                format_in: [TV, TV_SHORT, ONA]) { \(fields) } } }
        """, ["season": season.name, "year": season.year], pages: 8)
        let ids = await AnimeIDs.map()
        var imdb = Set<String>(), tmdb = Set<Int>(), names = Set<String>()
        for show in await listed {
            if let ref = ids[show.id] {
                if let id = ref.imdb { imdb.insert(id) }
                if let id = ref.tmdb, !ref.isMovie { tmdb.insert(id) }
            }
            for name in [show.english, show.romaji].compactMap({ $0 }) {
                let plain = plain(name)
                if plain.count >= 4 { names.insert(plain) }
            }
        }
        return Begun(imdb: imdb, tmdb: tmdb, names: names)
    }

    struct Show: Sendable {
        let id: Int
        let english: String?
        let romaji: String?
        let banner: String?
        let cover: String?
        let format: String?
        let episodes: Int?
        let next: Date?
        let nextEpisode: Int?

        var name: String { english ?? romaji ?? "" }
        var isFilm: Bool { ["MOVIE", "SPECIAL", "OVA"].contains(format ?? "") }
    }

    fileprivate static let names = ["WINTER", "SPRING", "SUMMER", "FALL"]

    /// AniList's: winter January–March, then spring, summer, fall.
    static func season(of date: Date) -> Season {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return Season(name: names[((parts.month ?? 1) - 1) / 3], year: parts.year ?? 2026)
    }

    private static let fields = """
    id title { romaji english } bannerImage coverImage { extraLarge } format episodes
    nextAiringEpisode { airingAt episode }
    """

    /// What began in the season (TV, shorts, web series, films, specials).
    /// Two pages: the 100 most popular.
    static func shows(_ season: Season) async -> [Show] {
        await list("""
        query($season: MediaSeason, $year: Int, $page: Int) { Page(page: $page, perPage: 50) {
          pageInfo { hasNextPage }
          media(season: $season, seasonYear: $year, type: ANIME, isAdult: false, sort: POPULARITY_DESC,
                format_in: [TV, TV_SHORT, ONA, MOVIE, SPECIAL, OVA]) { \(fields) } } }
        """, ["season": season.name, "year": season.year], pages: 2)
    }

    /// Shows begun before the season, still airing in it.
    static func continuing(_ season: Season) async -> [Show] {
        let month = (names.firstIndex(of: season.name) ?? 0) * 3 + 1
        return await list("""
        query($before: FuzzyDateInt, $page: Int) { Page(page: $page, perPage: 30) {
          pageInfo { hasNextPage }
          media(type: ANIME, status: RELEASING, startDate_lesser: $before, isAdult: false, sort: POPULARITY_DESC,
                format_in: [TV, TV_SHORT, ONA]) { \(fields) } } }
        """, ["before": season.year * 10000 + month * 100 + 1], pages: 1)
    }

    private static var asked: [String: Task<[Show], Never>] = [:]

    private static func list(_ query: String, _ variables: [String: AnyHashable], pages: Int) async -> [Show] {
        let key = query + variables.map { "\($0.key)=\($0.value)" }.sorted().joined()
        if let task = asked[key] { return await task.value }
        let task = Task { await fetch(query, variables, pages: pages) }
        asked[key] = task
        let shows = await task.value
        if shows.isEmpty { asked[key] = nil }
        return shows
    }

    private static func fetch(_ query: String, _ variables: [String: AnyHashable], pages: Int) async -> [Show] {
        struct Body: Decodable {
            struct DataPart: Decodable { let Page: PagePart }
            struct PagePart: Decodable { let pageInfo: Info; let media: [Media] }
            struct Info: Decodable { let hasNextPage: Bool }
            struct Media: Decodable {
                struct Title: Decodable { let romaji: String?; let english: String? }
                struct Cover: Decodable { let extraLarge: String? }
                struct Airing: Decodable { let airingAt: Int; let episode: Int }
                let id: Int
                let title: Title
                let bannerImage: String?
                let coverImage: Cover?
                let format: String?
                let episodes: Int?
                let nextAiringEpisode: Airing?
            }
            let data: DataPart
        }
        var out: [Show] = []
        for page in 1...pages {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var all: [String: Any] = variables
            all["page"] = page
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": all])
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let body = try? JSONDecoder().decode(Body.self, from: data) else {
                AppProbe.warn("anilist", "\(variables) page \(page) failed")
                break
            }
            for media in body.data.Page.media {
                out.append(Show(
                    id: media.id, english: media.title.english, romaji: media.title.romaji,
                    banner: media.bannerImage, cover: media.coverImage?.extraLarge,
                    format: media.format, episodes: media.episodes,
                    next: media.nextAiringEpisode.map { Date(timeIntervalSince1970: TimeInterval($0.airingAt)) },
                    nextEpisode: media.nextAiringEpisode?.episode))
            }
            guard body.data.Page.pageInfo.hasNextPage else { break }
        }
        return out
    }
}

/// AniList's ids to IMDb's and TMDB's: the community's list (Fribb's
/// anime-lists, ~6 MB), kept on disk a week, read once a run.
enum AnimeIDs {
    struct Ref: Sendable { let imdb: String?; let tmdb: Int?; let isMovie: Bool }

    @MainActor private static var task: Task<[Int: Ref], Never>?

    @MainActor static func map() async -> [Int: Ref] {
        if let task { return await task.value }
        let task = Task.detached(priority: .utility) { await read() }
        self.task = task
        return await task.value
    }

    private static let source = URL(string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-mini.json")!
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private static func read() async -> [Int: Ref] {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueCache/anime-ids.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        var data = try? Data(contentsOf: file)
        if data == nil || age > maxAge, let (fresh, _) = try? await URLSession.shared.data(from: source) {
            data = fresh
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fresh.write(to: file)
        }
        guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [Int: Ref] = [:]
        for entry in list {
            guard let anilist = entry["anilist_id"] as? Int else { continue }
            let imdb = (entry["imdb_id"] as? [String])?.first ?? entry["imdb_id"] as? String
            let ids = entry["themoviedb_id"] as? [String: Any]
            let film = ids?["movie"] as? Int
            let tmdb = ids?["tv"] as? Int ?? film
            guard imdb != nil || tmdb != nil else { continue }
            out[anilist] = Ref(imdb: imdb, tmdb: tmdb, isMovie: film != nil && ids?["tv"] == nil)
        }
        return out
    }
}
