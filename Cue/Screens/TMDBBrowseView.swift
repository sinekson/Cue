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
    /// Movies (true) and series (false) this page has something for.
    @Published private(set) var types: [Bool] = []
    @Published private(set) var isMovie: Bool
    @Published private(set) var sort: TMDBService.BrowseSort = .popular
    @Published private(set) var person: TMDBService.PersonProfile?
    @Published private(set) var brand: TMDBService.BrandProfile?

    private var credits = TMDBService.PersonCredits.empty
    private var page = 1
    private var hasMore = false
    private var isLoadingMore = false
    private var started = false
    /// A newer load makes an older one's answer stale.
    private var generation = 0

    init(source: Source, title: String) {
        self.source = source
        self.title = title
        switch source {
        case let .genre(id, name, isMovie):
            self.isMovie = isMovie
            types = [isMovie, !isMovie].filter { Self.genreID(id: id, name: name, from: isMovie, to: $0) != nil }
        case let .keyword(_, isMovie):
            self.isMovie = isMovie
            types = [isMovie, !isMovie]
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
        case let .company(id):
            Task { brand = await TMDBService.brandProfile(id: id, isNetwork: false) }
        case let .network(id):
            Task { brand = await TMDBService.brandProfile(id: id, isNetwork: true) }
        default:
            break
        }
        await reload()
        // A studio with no films (or the other way round): the other type.
        if items.isEmpty, let other = types.first(where: { $0 != isMovie }) {
            isMovie = other
            await reload()
        }
        // The first two lines' posters too: the page swaps in whole.
        await FixedFocusImages.prefetch(items.prefix(12).map {
            (url: $0.poster ?? $0.background, maxDimension: FolderGridController.card.height)
        }, within: .milliseconds(700))
        loadedOnce = true
    }

    func choose(isMovie newValue: Bool) {
        guard newValue != isMovie else { return }
        isMovie = newValue
        Task { await reload() }
    }

    func choose(sort newValue: TMDBService.BrowseSort) {
        guard newValue != sort else { return }
        sort = newValue
        Task { await reload() }
    }

    private func reload() async {
        generation += 1
        let mine = generation
        items = []
        isLoading = true
        page = 1
        let result = await fetch(page: 1)
        guard mine == generation else { return }
        items = result.items
        total = result.total
        hasMore = result.hasMore
        isLoading = false
    }

    /// The page's model under `source`, kept for the page.
    static func key(_ source: Source) -> String { "browse|\(source)" }

    /// A press: the page's titles start loading; the page opens once
    /// they're in, or after `PagePreparer.wait`.
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

    private func fetch(page: Int) async -> TMDBService.BrowsePage {
        let filter: [String: String]
        switch source {
        case .person:
            return await TMDBService.credits(credits, isMovie: isMovie, sort: sort, page: page)
        case let .genre(id, name, from):
            guard let genre = Self.genreID(id: id, name: name, from: from, to: isMovie) else {
                return TMDBService.BrowsePage(items: [], total: 0, hasMore: false)
            }
            filter = ["with_genres": String(genre)]
        case let .keyword(id, _): filter = ["with_keywords": String(id)]
        case let .company(id): filter = ["with_companies": String(id)]
        case let .network(id): filter = ["with_networks": String(id)]
        }
        return await TMDBService.browse(filter: filter, isMovie: isMovie, sort: sort, page: page)
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
    @Environment(\.dismiss) private var dismiss
    /// Back: below the grid's first line, up to the top first.
    @State private var gridBack = GridBack()

    let onSelect: (MetaItem) -> Void
    /// Details pushed without the system's slide (the zoom brings it in).
    var onOpenInPlace: ((MetaItem) -> Void)? = nil
    /// The picture of the title whose page opened this one: blurred behind
    /// it, as on that page (with "Background follows the title").
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

    private var showsControls: Bool { !viewModel.types.isEmpty }

    /// Titles open Details through `DetailTransition`.
    private var openDetails: ((MetaItem) -> Void)? {
        onOpenInPlace.map { push in
            { item in DetailTransition.shared.open(item) { push(item) } }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DetailsBackdropBackground(url: backdrop)
            // Until the first titles are in: two lines of empty posters,
            // out of focus's way (`FolderPosterGrid.placeholder`).
            FolderPosterGrid(
                header: AnyView(BrowseHeader(viewModel: viewModel)),
                headerHeight: BrowseHeader.height(source: viewModel.source),
                items: viewModel.loadedOnce ? viewModel.items : FolderPosterGrid.placeholderItems,
                subtitles: years,
                onSelect: onSelect, onOpenDetails: openDetails,
                onDisplay: { item in Task { await viewModel.loadMore(after: item) } },
                placeholder: !viewModel.loadedOnce,
                back: gridBack)
                .ignoresSafeArea()
            if viewModel.loadedOnce, viewModel.isLoading || viewModel.items.isEmpty {
                status.padding(.top, BrowseHeader.height(source: viewModel.source) + 60)
            }
        }
        .task { await viewModel.start() }
        .onExitCommand { if !gridBack.handle() { dismiss() } }
    }

    /// The year under each title.
    private var years: [String: String] {
        Dictionary(viewModel.items.compactMap { item in item.year.map { (item.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    @ViewBuilder
    private var status: some View {
        if viewModel.isLoading {
            CueLoadingView(label: "Loading titles", holdsFocus: !showsControls)
                .frame(width: 1920, height: 420)
        } else {
            CueEmptyState(icon: "film", title: viewModel.title, message: "No titles available.",
                          holdsFocus: !showsControls)
                .frame(width: 1920, height: 420)
        }
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

    /// The controls' room is kept from the first frame (they come with the
    /// first page), so the header's height never changes.
    static func height(source: TMDBBrowseViewModel.Source) -> CGFloat {
        let text = kind + gap + name + gap + facts
        var content = text
        switch source {
        case .person: content = max(portrait.height, text + 8 + bio)
        case .company, .network: content = max(FixedFocusMetrics.logoCard.height, text)
        default: break
        }
        // Below the controls as much room as above them (with the grid's 12).
        return content + controlsGap + FixedFocusHeaderButton.height + controlsGap - 12
    }

    private var showsControls: Bool { !viewModel.types.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 48) {
                emblem
                VStack(alignment: .leading, spacing: Self.gap) {
                    Text(kindLabel)
                        .font(.system(size: FixedFocusMetrics.textSize, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppGlass.textMuted)
                        .frame(height: Self.kind, alignment: .leading)
                    Text(viewModel.title)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(height: Self.name, alignment: .leading)
                    Text(facts ?? " ")
                        .font(.system(size: FixedFocusMetrics.textSize))
                        .foregroundStyle(AppGlass.textMuted)
                        .lineLimit(1)
                        .frame(height: Self.facts, alignment: .leading)
                    if case .person = viewModel.source {
                        Text(viewModel.person?.biography ?? " ")
                            .font(.system(size: FixedFocusMetrics.textSize))
                            .lineSpacing(5)
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(3)
                            .frame(maxWidth: 1100, minHeight: Self.bio, maxHeight: Self.bio, alignment: .topLeading)
                            .padding(.top, -4)
                    }
                }
                Spacer(minLength: 0)
            }
            if showsControls { controls.padding(.top, Self.controlsGap) }
        }
        .padding(.leading, FixedFocusMetrics.titleInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Emblem

    /// A person's portrait, a studio's or network's logo on its light plate.
    @ViewBuilder
    private var emblem: some View {
        switch viewModel.source {
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
                let size = FixedFocusMetrics.logoCard
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

    private var controls: some View {
        HStack(spacing: 16) {
            if viewModel.types.count > 1 {
                ForEach([true, false], id: \.self) { movie in
                    BrowseButton(label: movie ? "Movies" : "Series", selected: viewModel.isMovie == movie) {
                        viewModel.choose(isMovie: movie)
                    }
                }
            }
            // The order, apart from the filters: at the grid's right edge.
            Spacer(minLength: 32)
            BrowseSortButton(sort: viewModel.sort) { viewModel.choose(sort: $0) }
        }
        .padding(.trailing, FixedFocusMetrics.inset)
        .focusSection()
    }
}

/// The card's light frame (`FixedFocusCardEdge.rim`): the corners keep their
/// shape, the edges between them stretch.
private struct CardRim: View {
    var body: some View {
        let cap = Spotlight.cornerRadius + 4
        Image(uiImage: FixedFocusCardEdge.rim)
            .resizable(capInsets: EdgeInsets(top: cap, leading: cap, bottom: cap, trailing: cap))
            .allowsHitTesting(false)
    }
}

/// A control of the page: Search's glass pill — the selected one lighter, the
/// focused one lit (the season buttons' look).
struct BrowseButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(label: label, selected: selected) }
            .buttonStyle(BrowseBareStyle())
    }

    private struct Face: View {
        @Environment(\.isFocused) private var isFocused
        let label: String
        let selected: Bool

        var body: some View {
            FixedFocusHeaderPill(label: label, lit: isFocused, selected: selected)
                .scaleEffect(isFocused ? FixedFocusHeaderPill.focusScale : 1)
                .animation(Motion.focus, value: isFocused)
        }
    }
}

/// The order, in one button: its list opens under it (Cue's glass panel, as
/// the hold menus), the current one checked.
private struct BrowseSortButton: View {
    let sort: TMDBService.BrowseSort
    let onChoose: (TMDBService.BrowseSort) -> Void
    @State private var frame = CGRect.zero
    @State private var open = false

    var body: some View {
        Button { show() } label: { Face(label: sort.label, selected: open) }
            .buttonStyle(BrowseBareStyle())
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { frame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { _, rect in frame = rect }
                }
            }
    }

    private func show() {
        let entries = TMDBService.BrowseSort.allCases.map { option in
            MenuEntry(title: option.label, icon: "", checked: option == sort) { onChoose(option) }
        }
        HoldMenu.shared.openDropdown(entries, below: frame) { open = $0 }
    }

    private struct Face: View {
        @Environment(\.isFocused) private var isFocused
        let label: String
        let selected: Bool

        var body: some View {
            FixedFocusHeaderPill(label: label, lit: isFocused, selected: selected, chevron: true,
                                 icon: "arrow.up.arrow.down")
                .scaleEffect(isFocused ? FixedFocusHeaderPill.focusScale : 1)
                .animation(Motion.focus, value: isFocused)
        }
    }
}

/// The control draws its own focus.
private struct BrowseBareStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
