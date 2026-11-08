import SwiftUI

@MainActor
final class TMDBBrowseViewModel: ObservableObject, PreparedPage {
    enum Source {
        case genre(id: Int, name: String, isMovie: Bool)
        case keyword(id: Int, isMovie: Bool)
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
        case let .genre(id, name, isMovie):
            let both = [isMovie, !isMovie].filter { Self.genreID(id: id, name: name, from: isMovie, to: $0) != nil }
            // Both sides: always Movies first (predictable, whatever the
            // title it was opened from).
            self.isMovie = both.count > 1 || isMovie
            types = both
        case .keyword:
            isMovie = true
            types = [true, false]
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
        case let .genre(id, name, from):
            guard let genre = Self.genreID(id: id, name: name, from: from, to: isMovie) else {
                return TMDBService.BrowsePage(items: [], total: 0, hasMore: false)
            }
            filter = ["with_genres": String(genre)]
        case let .keyword(id, _): filter = ["with_keywords": String(id)]
        case let .company(id): filter = ["with_companies": String(id)]
        case let .network(id): filter = ["with_networks": String(id)]
        }
        return await TMDBService.browse(filter: filter, isMovie: isMovie, page: page)
    }

    /// TMDB numbers a genre differently for movies and for shows, and a few
    /// are one genre on one side and two on the other.
    private static func genreID(id: Int, name: String, from: Bool, to: Bool) -> Int? {
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

/// A genre's, a tag's, a studio's, a network's or a person's titles (Details'
/// genres, tags, studios and cast): what it is, then the titles — movies or
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

    /// A tag's titles (Details' tags).
    init(keywordID: Int, title: String, isMovie: Bool, onSelect: @escaping (MetaItem) -> Void,
         onOpenInPlace: ((MetaItem) -> Void)? = nil, backdrop: String? = nil) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel.prepared(
             .keyword(id: keywordID, isMovie: isMovie), title: title))
        self.onSelect = onSelect
        self.onOpenInPlace = onOpenInPlace
        self.backdrop = backdrop
    }

    /// A genre's titles (Details' genres).
    init(genreID: Int, title: String, isMovie: Bool, onSelect: @escaping (MetaItem) -> Void,
         onOpenInPlace: ((MetaItem) -> Void)? = nil, backdrop: String? = nil) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel.prepared(
             .genre(id: genreID, name: title, isMovie: isMovie), title: title))
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
            DetailsBackdropBackground(url: backdrop)
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
                        .foregroundStyle(Color.white.opacity(FixedFocusText.tertiary))
                        .frame(height: Self.kind, alignment: .leading)
                    Text(viewModel.title)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(height: Self.name, alignment: .leading)
                    Text(facts ?? " ")
                        .font(.system(size: FixedFocusMetrics.textSize))
                        .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                        .lineLimit(1)
                        .frame(height: Self.facts, alignment: .leading)
                    if case .person = viewModel.source {
                        Text(viewModel.person?.biography ?? " ")
                            .font(.system(size: FixedFocusMetrics.textSize))
                            .lineSpacing(5)
                            .foregroundStyle(Color.white.opacity(FixedFocusText.body))
                            .lineLimit(3)
                            .frame(maxWidth: 1100, minHeight: Self.bio, maxHeight: Self.bio, alignment: .topLeading)
                            .padding(.top, -4)
                    }
                }
    }

    // MARK: Emblem

    /// A person's portrait, a studio's or network's logo on its light plate.
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
                    Color.white.opacity(0.14)
                        .overlay {
                            Text(initials)
                                .font(.system(size: 64, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                }
            }
            .frame(width: Self.portrait.width, height: Self.portrait.height)
            .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
            .overlay { CardRim() }
        case .company, .network:
            if let url = viewModel.brand?.logoURL {
                let size = Self.logoPlate
                RemoteImage(url: url, contentMode: .fit, maxDimension: size.width)
                    .padding(24)
                    .frame(width: size.width, height: size.height)
                    .background(Color.white.opacity(0.92))
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
        case .genre: return "GENRE"
        case .keyword: return "TAG"
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

