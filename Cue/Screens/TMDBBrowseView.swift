import SwiftUI

@MainActor
final class TMDBBrowseViewModel: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var isLoading = true

    private var hasLoaded = false

    enum Source {
        case company(Int)
        /// A network's shows.
        case network(Int)
        /// A genre's films or shows.
        case genre(Int, isMovie: Bool)
        /// A keyword's (tag's) films or shows.
        case keyword(Int, isMovie: Bool)
    }
    let source: Source
    let title: String

    init(source: Source, title: String) {
        self.source = source
        self.title = title
    }

    /// A genre or tag: its first pages together (a page is twenty).
    private static let discoverPages = 3

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        defer { isLoading = false }
        switch source {
        case let .company(id): items = await TMDBService.browseCompany(id: id)
        case let .network(id): items = await TMDBService.browseNetwork(id: id)
        case let .genre(id, isMovie):
            items = await Self.pages { await TMDBService.titlesByGenre(id: id, isMovie: isMovie, page: $0) }
        case let .keyword(id, isMovie):
            items = await Self.pages { await TMDBService.titlesByKeyword(id: id, isMovie: isMovie, page: $0) }
        }
    }

    private static func pages(_ load: (Int) async -> [MetaItem]) async -> [MetaItem] {
        var all: [MetaItem] = []
        for page in 1...discoverPages { all += await load(page) }
        return all.deduplicatedByID()
    }
}

/// Browses a TMDB entity's catalog (currently production companies, reached by
/// focusing a company logo on the Detail screen). Mirrors Android's
/// `TmdbEntityBrowseScreen`.
struct TMDBBrowseView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @StateObject private var viewModel: TMDBBrowseViewModel

    let onSelect: (MetaItem) -> Void

    /// Bound to the poster-size setting, like Home, Search, Library and
    /// Discover. A hardcoded 220pt column clipped: `PosterCard` draws at the
    /// user's chosen 180/220/264, so at Large the card was 44pt wider than its
    /// column and neighbouring cards overlapped, while at Small it left 40pt of
    /// dead gutter.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: GridPoster.width,
                            maximum: GridPoster.width),
                  spacing: CueSpacing.lg, alignment: .top)]
    }

    init(companyID: Int, title: String, network: Bool = false, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel(
            source: network ? .network(companyID) : .company(companyID), title: title))
        self.onSelect = onSelect
    }

    /// A tag's titles (Details' tags).
    init(keywordID: Int, title: String, isMovie: Bool, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel(source: .keyword(keywordID, isMovie: isMovie),
                                                                   title: title))
        self.onSelect = onSelect
    }

    /// A genre's titles (Details' genre tags).
    init(genreID: Int, title: String, isMovie: Bool, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel(source: .genre(genreID, isMovie: isMovie),
                                                                   title: title))
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if viewModel.isLoading {
                CueLoadingView(label: "Loading titles", holdsFocus: true)
            } else if viewModel.items.isEmpty {
                CueEmptyState(
                    icon: "building.2.fill",
                    title: viewModel.title,
                    message: "No titles available.",
                    holdsFocus: true
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: CueSpacing.xl) {
                        Text(viewModel.title)
                            .font(.system(size: 52, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.leading, CueSpacing.huge)
                            .padding(.top, CueSpacing.xxl)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: CueSpacing.xl) {
                            ForEach(viewModel.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    PosterCard(item: item)
                                }
                                .mediaCardButtonStyle()
                                .titleMenu(item)
                            }
                        }
                        .padding(.horizontal, CueSpacing.huge)
                        .padding(.bottom, CueSpacing.huge)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task { await viewModel.load() }
    }
}
