import SwiftUI

@MainActor
final class TMDBBrowseViewModel: ObservableObject, PreparedPage {
    enum Source {
        case company(Int)
        /// A network's shows.
        case network(Int)
        case person(Int)
    }

    let source: Source
    let title: String

    @Published private(set) var items: [MetaItem] = []
    /// How many titles TMDB knows of for the current type.
    @Published private(set) var total = 0
    @Published private(set) var isLoading = true
    /// The first titles are in (until then the grid shows placeholders).
    @Published private(set) var loadedOnce = false
    var isReady: Bool { loadedOnce }
    /// The grid shows placeholders: before the first titles, and while a
    /// Movies | Series change loads.
    var showsPlaceholder: Bool { !loadedOnce || isLoading }
    /// Movies (true) and series (false) this page has something for.
    @Published private(set) var types: [Bool] = []
    @Published private(set) var isMovie: Bool
    @Published private(set) var person: TMDBService.PersonProfile?
    @Published private(set) var brand: TMDBService.BrandProfile?

    private var credits = TMDBService.PersonCredits.empty
    private var page = 1
    private var hasMore = false
    private var isLoadingMore = false
    private var started = false
    /// A newer load makes an older one's answer stale.
    private var generation = 0
    /// Each side's first page, its posters decoded: Movies | Series swaps
    /// at once, as Search's scopes (no placeholders between).
    private var firstPages: [Bool: TMDBService.BrowsePage] = [:]

    init(source: Source, title: String) {
        self.source = source
        self.title = title
        switch source {
        case .company:
            isMovie = true
            types = [true, false]
        case .network:
            isMovie = false
            types = [false]
        case .person:
            isMovie = true
        }
    }

    // MARK: Loading

    func start() async {
        guard !started else { return }
        started = true
        switch source {
        case let .person(id):
            async let profile = TMDBService.person(id: id)
            async let all = TMDBService.personCredits(id: id)
            person = await profile
            credits = await all
            types = [true, false].filter { credits.count(isMovie: $0) > 0 }
            if let first = types.first, !types.contains(isMovie) { isMovie = first }
        default:
            break
        }
        // A studio's or network's logo and country: in with the titles (the
        // header swaps in whole).
        async let profile = Self.brand(of: source)
        // The other side offered only where it has titles too (most studios
        // make one kind; a person's are known from the credits).
        let other = !isMovie
        async let otherHasTitles = otherSideHasTitles(other)
        await reload()
        brand = await profile
        if types.count > 1, !(await otherHasTitles) {
            types = [isMovie]
        } else if types.count > 1, items.isEmpty {
            // No films (or the other way round): the other side alone.
            isMovie = other
            types = [other]
            await reload()
        }
        loadedOnce = true
        // The other side ready before the pill is pressed.
        if types.count > 1, firstPages[!isMovie] == nil {
            let side = !isMovie
            let first = await fetch(page: 1, isMovie: side)
            await Self.decode(first)
            firstPages[side] = first
        }
    }

    private func otherSideHasTitles(_ side: Bool) async -> Bool {
        if case .person = source { return true }
        guard types.contains(side) else { return false }
        let first = await fetch(page: 1, isMovie: side)
        await Self.decode(first)
        firstPages[side] = first
        return !first.items.isEmpty
    }

    /// The first two lines' posters decoded: the grid swaps in whole.
    private static func decode(_ first: TMDBService.BrowsePage) async {
        await FixedFocusImages.prefetch(first.items.prefix(12).map {
            (url: $0.poster ?? $0.background, maxDimension: PictureSize.poster)
        }, within: .milliseconds(700))
    }

    private static func brand(of source: Source) async -> TMDBService.BrandProfile? {
        switch source {
        case let .company(id): await TMDBService.brandProfile(id: id, isNetwork: false)
        case let .network(id): await TMDBService.brandProfile(id: id, isNetwork: true)
        default: nil
        }
    }

    func choose(isMovie newValue: Bool) {
        guard newValue != isMovie else { return }
        isMovie = newValue
        if let first = firstPages[newValue] {
            generation += 1
            show(first)
        } else {
            Task { await reload() }
        }
    }

    private func reload() async {
        generation += 1
        let mine = generation
        if let first = firstPages[isMovie] { return show(first) }
        items = []
        isLoading = true
        let result = await fetch(page: 1)
        guard mine == generation else { return }
        await Self.decode(result)
        guard mine == generation else { return }
        firstPages[isMovie] = result
        show(result)
    }

    private func show(_ first: TMDBService.BrowsePage) {
        page = 1
        items = first.items
        total = first.total
        hasMore = first.hasMore
        isLoading = false
    }

    /// The page's model under `source`, kept for the page.
    static func key(_ source: Source) -> String { "browse|\(source)" }

    /// A press: the page's titles start loading and the page opens under
    /// the still, shown once they're in or after `PagePreparer.wait`.
    static func open(_ source: Source, title: String, push: @escaping () -> Void) {
        let model = TMDBBrowseViewModel(source: source, title: title)
        Task { await model.start() }
        PagePreparer.shared.open(key(source), model, push: push)
    }

    /// The model the press prepared, else a new one.
    static func prepared(_ source: Source, title: String) -> TMDBBrowseViewModel {
        PagePreparer.shared.take(key(source)) ?? TMDBBrowseViewModel(source: source, title: title)
    }

    /// More as focus nears the end of what's there.
    func loadMore(after item: MetaItem) async {
        guard hasMore, !isLoadingMore, let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 10 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let mine = generation
        let result = await fetch(page: page + 1)
        guard mine == generation else { return }
        page += 1
        hasMore = result.hasMore
        let known = Set(items.map(\.id))
        items += result.items.filter { !known.contains($0.id) }
    }

    /// A page of `isMovie`'s side (else the one chosen).
    private func fetch(page: Int, isMovie side: Bool? = nil) async -> TMDBService.BrowsePage {
        let isMovie = side ?? isMovie
        let filter: [String: String]
        switch source {
        case .person:
            return await TMDBService.credits(credits, isMovie: isMovie, page: page)
        case let .company(id): filter = ["with_companies": String(id)]
        case let .network(id): filter = ["with_networks": String(id)]
        }
        return await TMDBService.browse(filter: filter, isMovie: isMovie, page: page)
    }

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
}

/// A studio's, a network's or a person's titles (Details' studios and cast): what it is, then the titles — movies or
/// series, in the order asked — as Home's own cards: the folder pages' grid
/// (`FolderPosterGrid`: `FixedFocusDestinationCell`, six across), the header
/// and its controls scrolling with it.
struct TMDBBrowseView: View {
    @StateObject private var viewModel: TMDBBrowseViewModel
    @Environment(\.pageBack) private var pageBack
    @Environment(\.dismiss) private var dismiss
    /// Back: below the grid's first line, up to the top first.
    @State private var gridBack = GridBack()

    let onSelect: (MetaItem) -> Void
    /// Details pushed without the system's slide (the zoom brings it in).
    var onOpenInPlace: ((MetaItem) -> Void)? = nil
    /// The picture of the title whose page opened this one: blurred behind
    /// it, as on that page.
    var backdrop: String? = nil

    init(companyID: Int, title: String, network: Bool = false, onSelect: @escaping (MetaItem) -> Void,
         onOpenInPlace: ((MetaItem) -> Void)? = nil, backdrop: String? = nil) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel.prepared(
             network ? .network(companyID) : .company(companyID), title: title))
        self.onSelect = onSelect
        self.onOpenInPlace = onOpenInPlace
        self.backdrop = backdrop
    }

    /// A person's titles (Details' cast).
    init(personID: Int, title: String, onSelect: @escaping (MetaItem) -> Void,
         onOpenInPlace: ((MetaItem) -> Void)? = nil, backdrop: String? = nil) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel.prepared(.person(personID), title: title))
        self.onSelect = onSelect
        self.onOpenInPlace = onOpenInPlace
        self.backdrop = backdrop
    }

    private var showsControls: Bool { viewModel.types.count > 1 }

    /// Titles open Details through `DetailTransition`.
    private var openDetails: ((MetaItem) -> Void)? {
        onOpenInPlace.map { push in
            { item in DetailTransition.shared.open(item) { push(item) } }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Details' page: the title's bands, following the setting.
            TitleBandsBackground(url: backdrop)
            // Until the titles are in (the first, or after a Movies | Series
            // change): two lines of empty posters, out of focus's way
            // (`FolderPosterGrid.placeholder`).
            FolderPosterGrid(
                header: AnyView(BrowseHeader(viewModel: viewModel)),
                headerHeight: BrowseHeader.height(viewModel),
                items: viewModel.showsPlaceholder ? FolderPosterGrid.placeholderItems : viewModel.items,
                subtitles: years,
                onSelect: onSelect, onOpenDetails: openDetails,
                onDisplay: { item in Task { await viewModel.loadMore(after: item) } },
                placeholder: viewModel.showsPlaceholder,
                back: gridBack,
                headerFirst: viewModel.types.count > 1)
                .ignoresSafeArea()
            if !viewModel.showsPlaceholder, viewModel.items.isEmpty {
                CueEmptyState(icon: "film", title: viewModel.title, message: "No titles available.",
                              holdsFocus: !showsControls)
                    .frame(width: 1920, height: 420)
                    .padding(.top, BrowseHeader.height(viewModel) + 60)
            }
        }
        .task { await viewModel.start() }
        .onExitCommand {
            if !gridBack.handle() { if let pageBack { pageBack() } else { dismiss() } }
        }
    }

    /// The year under each title.
    private var years: [String: String] {
        Dictionary(viewModel.items.compactMap { item in item.year.map { (item.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

}

/// The page's header, scrolling with the grid: what it is, then its controls.
/// It follows the model itself — the grid never reloads it, so a control
/// keeps its focus while the titles change. Fixed heights throughout, so the
/// grid knows the cell's (`height`).
private struct BrowseHeader: View {
    @ObservedObject var viewModel: TMDBBrowseViewModel

    private static let kind: CGFloat = 30
    private static let name: CGFloat = 70
    private static let facts: CGFloat = 30
    private static let bio: CGFloat = 108
    private static let gap: CGFloat = 12
    private static let controlsGap: CGFloat = 36
    private static let portrait = CGSize(width: 200, height: 300)
    /// A studio's or network's logo plate: a poster's width, as the grid under it.
    private static let logoPlate = CGSize(width: FixedFocusMetrics.posterCard.width, height: 140)

    /// The controls' room is kept while the page loads (a person's or a
    /// studio's sides are known only then — still under the page's cover);
    /// without both sides, no controls and no room for them.
    static func height(_ viewModel: TMDBBrowseViewModel) -> CGFloat {
        let source = viewModel.source
        let text = kind + gap + name + gap + facts
        var content = text
        switch source {
        case .person: content = max(portrait.height, text + 8 + bio)
        case .company, .network: content = max(Self.logoPlate.height, text)
        default: break
        }
        guard !viewModel.loadedOnce || viewModel.types.count > 1 else { return content + controlsGap - 12 }
        // Below the controls as much room as above them (with the grid's 12).
        return content + controlsGap + ScopePill<Bool>.height + controlsGap - 12
    }

    /// Before the first titles: every part a placeholder in its place —
    /// the picture, the lines of text, the controls (the page swaps in
    /// whole).
    private var placeholder: Bool { !viewModel.loadedOnce }
    private var showsControls: Bool { placeholder || viewModel.types.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 48) {
                emblem
                if placeholder { textBars } else { text }
                Spacer(minLength: 0)
            }
            if showsControls { controls.padding(.top, Self.controlsGap) }
        }
        .padding(.leading, FixedFocusMetrics.titleInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A line of text still to come: a bar of the placeholder's look, as
    /// tall as the text's capitals, at its line's place.
    private static func bar(width: CGFloat, size: CGFloat, line: CGFloat) -> some View {
        PlaceholderShimmer()
            .frame(width: width, height: (size * 0.72).rounded())
            .clipShape(Capsule())
            .frame(height: line, alignment: .leading)
    }

    private var textBars: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            Self.bar(width: 130, size: FixedFocusMetrics.textSize, line: Self.kind)
            Self.bar(width: 420, size: 56, line: Self.name)
            Self.bar(width: 300, size: FixedFocusMetrics.textSize, line: Self.facts)
            if case .person = viewModel.source {
                VStack(alignment: .leading, spacing: 5) {
                    Self.bar(width: 1100, size: FixedFocusMetrics.textSize, line: 31)
                    Self.bar(width: 1040, size: FixedFocusMetrics.textSize, line: 31)
                    Self.bar(width: 640, size: FixedFocusMetrics.textSize, line: 31)
                }
                .frame(height: Self.bio, alignment: .topLeading)
                .padding(.top, -4)
            }
        }
    }

    private var text: some View {
                VStack(alignment: .leading, spacing: Self.gap) {
                    Text(kindLabel)
                        .font(.system(size: FixedFocusMetrics.textSize, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(CueInk.tertiary)
                        .frame(height: Self.kind, alignment: .leading)
                    Text(viewModel.title)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(CueInk.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(height: Self.name, alignment: .leading)
                    Text(facts ?? " ")
                        .font(.system(size: FixedFocusMetrics.textSize))
                        .foregroundStyle(CueInk.body)
                        .lineLimit(1)
                        .frame(height: Self.facts, alignment: .leading)
                    if case .person = viewModel.source {
                        Text(viewModel.person?.biography ?? " ")
                            .font(.system(size: FixedFocusMetrics.textSize))
                            .lineSpacing(5)
                            .foregroundStyle(CueInk.body)
                            .lineLimit(3)
                            .frame(maxWidth: 1100, minHeight: Self.bio, maxHeight: Self.bio, alignment: .topLeading)
                            .padding(.top, -4)
                    }
                }
    }

    // MARK: Emblem

    /// A person's portrait, a studio's or network's logo as Details' grid
    /// shows it (`BrandLogo`).
    @ViewBuilder
    private var emblem: some View {
        switch viewModel.source {
        case .person where placeholder:
            PlaceholderShimmer()
                .frame(width: Self.portrait.width, height: Self.portrait.height)
                .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
        case .company where placeholder, .network where placeholder:
            PlaceholderShimmer()
                .frame(width: Self.logoPlate.width, height: Self.logoPlate.height)
                .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
        case .person:
            ZStack {
                if let url = viewModel.person?.photoURL {
                    RemoteImage(url: url, maxDimension: Self.portrait.height)
                } else {
                    Color(uiColor: FixedFocusDestinationCell.logoPlate)
                        .overlay {
                            Text(initials)
                                .font(.system(size: 64, weight: .semibold))
                                .foregroundStyle(CueInk.body)
                        }
                }
            }
            .frame(width: Self.portrait.width, height: Self.portrait.height)
            .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
            .overlay { CardRim() }
        case .company, .network:
            if let url = viewModel.brand?.logoURL {
                let size = Self.logoPlate
                BrandLogo(url: url)
                    .padding(24)
                    .frame(width: size.width, height: size.height)
                    .background(Color(uiColor: FixedFocusDestinationCell.logoPlate))
                    .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
                    .overlay { CardRim() }
            }
        default:
            EmptyView()
        }
    }

    private var initials: String {
        viewModel.title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var kindLabel: String {
        switch viewModel.source {
        case .company: return "STUDIO"
        case .network: return "NETWORK"
        case .person:
            switch viewModel.person?.department {
            case "Acting": return "ACTOR"
            case "Directing": return "DIRECTOR"
            case "Writing": return "WRITER"
            case "Production": return "PRODUCER"
            default: return "PERSON"
            }
        }
    }

    /// One line under the name: where from / born, and how many.
    private var facts: String? {
        var parts: [String] = []
        switch viewModel.source {
        case .company, .network:
            if let code = viewModel.brand?.country, let name = Locale.current.localizedString(forRegionCode: code) {
                parts.append(name)
            }
        case .person:
            if let year = viewModel.person?.bornYear { parts.append("Born \(year)") }
            if let place = viewModel.person?.birthplace { parts.append(place) }
        default:
            break
        }
        if viewModel.total > 0 {
            parts.append("\(viewModel.total.formatted(.number)) \(viewModel.isMovie ? "movies" : "series")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: Controls

    /// Search's scope pill: moving along it switches. (Loading: its shape,
    /// both scopes — a person's are known only then.)
    private var controls: some View {
        ScopePill(scopes: [true, false], label: { $0 ? "Movies" : "Series" },
                  current: viewModel.isMovie) { viewModel.choose(isMovie: $0) }
            .placeholderShape(placeholder, Capsule())
            .focusSection()
    }
}

private extension View {
    /// Loading: the control's shape in the placeholder's look, the control
    /// itself out of sight and out of focus's way.
    @ViewBuilder
    func placeholderShape<S: Shape>(_ on: Bool, _ shape: S) -> some View {
        if on {
            opacity(0).disabled(true).overlay { PlaceholderShimmer().clipShape(shape) }
        } else {
            self
        }
    }
}

/// The card's light frame (`FixedFocusCardEdge.rim`): the corners keep their
/// shape, the edges between them stretch.
private struct CardRim: View {
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue
    var body: some View {
        let cap = Spotlight.cornerRadius + 4
        if outlines != FixedFocusRing.Outlines.off.rawValue, let rim = FixedFocusCardEdge.rim {
            Image(uiImage: rim)
                .resizable(capInsets: EdgeInsets(top: cap, leading: cap, bottom: cap, trailing: cap))
                .allowsHitTesting(false)
        }
    }
}


/// A studio's or network's logo as Details' Network & Studios cards draw
/// it: in the page's ink, unless it's on a box of its own or has a clear
/// colour of its own (`FixedFocusDestinationCell.boxed`, `.colourful`).
private struct BrandLogo: UIViewRepresentable {
    let url: String

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.tintColor = CueInk.ui(FixedFocusText.primary)
        guard view.accessibilityIdentifier != url else { return }
        view.accessibilityIdentifier = url
        FixedFocusImages.load(url, into: view, maxDimension: PictureSize.landscape, waiting: { [weak view] waiting in
            guard let view, !waiting, let image = view.image,
                  !FixedFocusDestinationCell.boxed(image), !FixedFocusDestinationCell.colourful(image) else { return }
            view.image = image.withRenderingMode(.alwaysTemplate)
        })
    }
}

// MARK: - Discover (rough prototype)

/// Discover: one sentence of words to change ("Show me fantasy anime movies
/// about anything…"), TMDB's titles under it. A prototype, to see the idea
/// in action before it's made properly.
@MainActor
final class DiscoverModel: ObservableObject {
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
    }

    /// The sentence. The tab's is kept per profile (Discover opens on the
    /// last one); one opened filled in (Details' genre or tag) is its own.
    @Published private(set) var picks: [Slot: String] {
        didSet { if persists { save() } }
    }
    private let persists: Bool
    /// Choices the lists don't have: the genre or tag it was opened with.
    private var extras: [Slot: [Option]] = [:]
    /// Starting points, three runs of five: from your taste, from what's
    /// popular this week, curveballs away from your taste.
    @Published private(set) var presets: [[Slot: String]] = DiscoverModel.fixedPresets

    /// The tab's own sentence.
    init() {
        picks = Self.saved()
        persists = true
    }

    /// Filled in: `extras` added to their words' choices.
    init(picks: [Slot: String], extras: [Slot: [Option]]) {
        self.picks = picks
        self.extras = extras
        persists = false
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

    /// The sentence as a name, in sentence case: "Well rated fantasy anime
    /// movies about isekai from the 2010s" (the order only when it's
    /// popular or newest; anime's Japanese not said again).
    var title: String { Self.name(of: picks, extras: extras) }

    static func name(of picks: [Slot: String], extras: [Slot: [Option]] = [:]) -> String {
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
        if let theme = option(.theme) { words.append("about \(theme.word)") }
        if let origin = option(.origin), picks[.style] != "anime" { words.append("in \(origin.word)") }
        if let era = option(.era) { words.append("from \(era.word)") }
        let name = words.joined(separator: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Only a sentence of the lists' own words can go on Home (a genre or
    /// tag added from Details isn't kept).
    var pinnable: Bool { extras.isEmpty }
    var pinned: Bool { DiscoverPins.shared.pin(for: picks) != nil }

    /// On Home, in place of `replacing` (a pin's id) when three are there.
    func pin(replacing: String? = nil) {
        DiscoverPins.shared.add(picks, replacing: replacing)
    }

    func picksMatch(_ pin: DiscoverPins.Pin) -> Bool { DiscoverPins.Pin.id(of: picks) == pin.id }

    /// A pin's sentence, loaded.
    func load(_ pin: DiscoverPins.Pin) { apply(preset: pin.slots) }

    /// The first titles, for a Home row.
    static func titles(for picks: [Slot: String]) async -> [MetaItem] {
        let model = DiscoverModel(picks: picks, extras: [:])
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
        presets = out
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
    var countIsExact: Bool { pick(.rating) == "any" && pick(.watched) != "hidden" }

    /// The next titles from `start`: TMDB's pages until a screenful is
    /// kept (IMDb's ratings and watched titles are Cue's to drop), at most
    /// five; "best for you" ranks three pages of the best known at a time.
    private func chunk(from start: Int) async -> (page: TMDBService.BrowsePage, next: Int) {
        await IMDbRatings.ready()
        let model = pick(.order) == "foryou" ? await CueRows.tasteModel() : nil
        let least = model == nil ? 1 : 3
        let rating = pick(.rating)
        let hideSeen = pick(.watched) == "hidden"
        var items: [MetaItem] = []
        var known = Set<String>()
        var total = 0
        var more = true
        var page = start
        while more, page < start + 5, page - start < least || items.count < 18 {
            let result = await fetch(page: page)
            if page == start { total = result.total }
            for item in result.items where !known.contains(item.id) {
                guard Self.passes(item, rating: rating), !(hideSeen && hideWatched(item)) else { continue }
                known.insert(item.id)
                items.append(item)
            }
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
        return await TMDBService.browse(filter: query, isMovie: isMovie, page: page)
    }

    // MARK: The choices

    static func addGenre(_ id: Int, _ query: inout [String: String]) {
        query["with_genres"] = [query["with_genres"], String(id)].compactMap { $0 }.joined(separator: ",")
    }

    private static func genre(_ name: String, _ word: String) -> Option {
        Option(id: name, word: word, name: name) { query, isMovie in
            let id: Int
            if let own = TMDBService.genre(named: name, isMovie: isMovie) {
                id = own.id
            } else if let other = TMDBService.genre(named: name, isMovie: !isMovie),
                      let mapped = TMDBBrowseViewModel.genreID(id: other.id, name: name, from: !isMovie, to: isMovie) {
                id = mapped
            } else {
                return false
            }
            addGenre(id, &query)
            // Shows: TMDB has one "Sci-Fi & Fantasy"; its fantasy is the
            // part with fantasy's keywords, its sci-fi the rest.
            if !isMovie, id == 10765 {
                query[name == "Fantasy" ? "with_keywords" : "without_keywords"] = fantasyKeywords
            }
            return true
        }
    }

    /// Magic, dragons, witches, myths, fairy tales, isekai.
    private static let fantasyKeywords = "2343|12554|616|2035|3205|237451"

    static func keyword(_ id: String, _ word: String, _ name: String) -> Option {
        Option(id: "k\(id)", word: word, name: name) { query, _ in
            query["with_keywords"] = id
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
            return [
                years("any", "any year", nil, nil),
                years("now", "this year", year, nil),
                years("recent", "the last 5 years", year - 4, nil),
                years("2020s", "the 2020s", 2020, 2029), years("2010s", "the 2010s", 2010, 2019),
                years("2000s", "the 2000s", 2000, 2009), years("1990s", "the '90s", 1990, 1999),
                years("1980s", "the '80s", 1980, 1989), years("1970s", "the '70s", 1970, 1979),
                years("older", "before 1970", nil, 1969),
            ]
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
         onOpenInPlace: @escaping (MetaItem) -> Void) {
        _model = StateObject(wrappedValue: model())
        opened = true
        self.backdrop = backdrop
        self.onOpenInPlace = onOpenInPlace
        onBack = {}
    }

    /// The bar's room above the grid (none on a pushed page).
    private var barRoom: CGFloat { opened ? 0 : DiscoverSentence.barRoom }
    private var headerTop: CGFloat { opened ? DiscoverSentence.top - DiscoverSentence.barRoom : DiscoverSentence.top }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if opened { TitleBandsBackground(url: backdrop) } else { ATVBackground() }
            FolderPosterGrid(
                header: AnyView(DiscoverSentence(model: model)),
                headerHeight: DiscoverSentence.height,
                items: model.loadedOnce ? model.items : FolderPosterGrid.placeholderItems,
                subtitles: Dictionary(model.items.compactMap { item in item.year.map { (item.id, $0) } },
                                      uniquingKeysWith: { first, _ in first }),
                onSelect: { _ in },
                onOpenDetails: { item in DetailTransition.shared.open(item) { onOpenInPlace(item) } },
                onDisplay: { item in Task { await model.loadMore(after: item) } },
                placeholder: !model.loadedOnce,
                back: gridBack,
                headerFirst: true,
                headerTop: headerTop,
                // The bar is on the page: it goes up with it, as Home's.
                onScroll: opened ? nil : { TopBarFollow.shared.set(-$0, for: "discover") },
                bleedTop: barRoom)
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
        .onExitCommand {
            guard !gridBack.handle() else { return }
            if !opened { onBack() } else if let pageBack { pageBack() } else { dismiss() }
        }
    }
}

/// The sentence: plain words joining the slots' words, each slot a flat
/// pill (set ones on the selected grey), then the starting points.
private struct DiscoverSentence: View {
    @ObservedObject var model: DiscoverModel
    @ObservedObject private var pins = DiscoverPins.shared
    /// Each word's place on the screen: its list opens under it.
    @State private var anchors = DiscoverAnchors()
    /// Coming in: the sentence's first word.
    @FocusState private var focused: DiscoverModel.Slot?
    /// The pin with focus (its hold menu).
    @FocusState private var focusedPin: String?

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
                    line([.word("Show me"), .slot(.genre), .slot(.style), .slot(.type), .word("about"), .slot(.theme)])
                    Spacer(minLength: 24)
                    Text(count)
                        .font(.system(size: 24))
                        .foregroundStyle(CueInk.tertiary)
                }
                line([.word("in"), .slot(.origin), .word("from"), .slot(.era), .word("·"), .slot(.rating),
                      .word("·"), .slot(.order), .word("·"), .slot(.watched)])
            }
            .padding(.horizontal, FixedFocusMetrics.titleInset)
            // Side-scrolling, as Search's: yours on Home first (Select
            // loads one, held it can go), then the starting points.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LineChip.gap) {
                    ForEach(pins.pins, id: \.id) { pin in
                        Button { model.load(pin) } label: {
                            LineChip(name: pin.name, checked: true, current: model.picksMatch(pin))
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focusedPin, equals: pin.id)
                        .holdMenu(focused: focusedPin == pin.id) {
                            [MenuEntry(title: "Remove from Home", icon: "minus.circle") { pins.remove(pin.id) }]
                        }
                    }
                    if model.pinnable, !model.pinned {
                        Button { addToHome() } label: {
                            LineChip(name: "＋ Add to Home")
                                .background { AnchorView(anchors: anchors, key: "add") }
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                    ForEach(starts, id: \.self) { picks in
                        Button { model.apply(preset: picks) } label: {
                            LineChip(name: DiscoverModel.name(of: picks))
                        }
                        .buttonStyle(PlainCardButtonStyle())
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
        .defaultFocus($focused, .genre)
    }

    /// The starting points, leaving out what's on Home already.
    private var starts: [[DiscoverModel.Slot: String]] {
        let pinned = Set(pins.pins.map(\.id))
        return model.presets.filter { !pinned.contains(DiscoverPins.Pin.id(of: $0)) }
    }

    private var count: String {
        guard model.loadedOnce else { return " " }
        if model.isLoading { return "Looking…" }
        guard model.countIsExact else { return " " }
        return "\(model.total.formatted(.number)) \(model.countLabel)"
    }

    /// On Home; with three there, which one it takes the place of, in the
    /// menus' glass panel under the pill.
    private func addToHome() {
        guard pins.pins.count >= DiscoverPins.limit else { return model.pin() }
        guard let view = anchors.views["add"], view.window != nil else { return }
        let entries = pins.pins.map { pin in
            MenuEntry(title: "Replace \u{201C}\(pin.name)\u{201D}", icon: "arrow.triangle.2.circlepath") {
                model.pin(replacing: pin.id)
            }
        }
        HoldMenu.shared.open(HoldMenuRequest(entries: entries, anchor: view.convert(view.bounds, to: nil),
                                             below: true))
    }

    /// The word's choices in the menus' glass panel, under it; a pick
    /// changes the sentence and the titles under it, the page staying.
    private func open(_ slot: DiscoverModel.Slot) {
        guard let view = anchors.views[slot.rawValue], view.window != nil else { return }
        let current = model.pick(slot)
        let entries = model.choices(slot).map { option in
            MenuEntry(title: option.name ?? option.word.capitalized, icon: "", checked: option.id == current) {
                model.set(slot, option.id)
            }
        }
        HoldMenu.shared.open(HoldMenuRequest(entries: entries, anchor: view.convert(view.bounds, to: nil),
                                             below: true))
    }

    enum Part: Hashable { case word(String), slot(DiscoverModel.Slot) }

    private func line(_ parts: [Part]) -> some View {
        HStack(spacing: 12) {
            ForEach(parts, id: \.self) { part in
                switch part {
                case let .word(text):
                    Text(text)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(CueInk.secondary)
                case let .slot(slot):
                    Button { open(slot) } label: {
                        SentenceWord(text: model.option(slot).word, set: model.isSet(slot))
                            .background { AnchorView(anchors: anchors, key: slot.rawValue) }
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused($focused, equals: slot)
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
    /// The sentence showing now.
    var current = false

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
        let pill = min(width, Self.room) + 44 + (checked ? 32 : 0)
        let scale = min(1.06, 1 + 2 * Self.grow / pill)
        HStack(spacing: 10) {
            if checked {
                Image(systemName: "checkmark")
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
        .background(Capsule().fill(isFocused ? FlatControl.focus : current ? FlatControl.selected : FlatControl.rest))
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

/// Discover's sentences put on Home (per profile, three at most): each a
/// large row in Home's large-row slots 2–4 (after Because You Watched),
/// its name in title case after the Discover compass; with the add-ons'
/// rows, after Saved for Later. Their titles are fetched at launch and when
/// one is added.
@MainActor
final class DiscoverPins: ObservableObject {
    static let shared = DiscoverPins()
    static let limit = 3
    static let rowPrefix = "discover.pin."

    struct Pin: Codable, Equatable {
        let picks: [String: String]

        var id: String { Self.id(of: slots) }
        static func id(of picks: [DiscoverModel.Slot: String]) -> String {
            picks.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
                .joined(separator: "&")
        }
        var slots: [DiscoverModel.Slot: String] {
            Dictionary(uniqueKeysWithValues: picks.compactMap { key, value in
                DiscoverModel.Slot(rawValue: key).map { ($0, value) }
            })
        }
        /// The sentence, in its own case ("Fantasy anime movies about isekai").
        @MainActor var name: String { DiscoverModel.name(of: slots) }
    }

    @Published private(set) var pins: [Pin] = []
    /// Each pin's titles, by its id.
    @Published private(set) var titles: [String: [MetaItem]] = [:]
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

    func pin(for picks: [DiscoverModel.Slot: String]) -> Pin? {
        load()
        let id = Pin.id(of: picks)
        return pins.first { $0.id == id }
    }

    /// On Home, in `replacing`'s place (its slot) when given; never past
    /// the limit.
    func add(_ picks: [DiscoverModel.Slot: String], replacing: String? = nil) {
        load()
        let pin = Pin(picks: Dictionary(uniqueKeysWithValues: picks.map { ($0.key.rawValue, $0.value) }))
        guard !pins.contains(where: { $0.id == pin.id }) else { return }
        if let replacing, let index = pins.firstIndex(where: { $0.id == replacing }) {
            pins[index] = pin
            titles[replacing] = nil
        } else {
            guard pins.count < Self.limit else { return }
            pins.append(pin)
        }
        save()
        Task { await fetch(pin) }
    }

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
        titles[pin.id] = Array(await DiscoverModel.titles(for: pin.slots).prefix(25))
    }

    /// Home's rows: large rows.
    var rows: [HomeRow] {
        load()
        return pins.compactMap { pin in
            guard let items = titles[pin.id], !items.isEmpty else { return nil }
            return HomeRow(id: Self.rowPrefix + pin.id, title: Self.titleCase(pin.name), items: items)
        }
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
