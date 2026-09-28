import SwiftUI

/// One chip row drives the whole screen: All / Movies / Shows filter the one
/// unified grid.
private enum LibraryFilter: String, CaseIterable {
    case all = "All", movies = "Movies", shows = "Shows"
}

struct LibraryView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progressStore: ProgressStore

    let onSelect: (MetaItem) -> Void
    /// Back pressed while already at the top of the grid: leave the screen.
    var onBackAtRoot: () -> Void = {}

    @State private var filter: LibraryFilter = .all
    @State private var sort = "Added"              // Added / Name / Recently Watched
    @FocusState private var focusedID: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth, maximum: posterLayout.posterSize.posterWidth), spacing: OrivioSpacing.lg, alignment: .top)] }

    private var sorted: [SavedLibraryItem] {
        var items = library.sorted
        switch sort {
        case "Name":
            items = items.sorted { $0.metaItem.name.lowercased() < $1.metaItem.name.lowercased() }
        case "Recently Watched":
            // Latest Continue Watching activity per title; unwatched titles
            // keep their added order at the bottom.
            let lastWatched = Dictionary(
                progressStore.allForSync().map { ($0.metaID, $0.updatedAt) },
                uniquingKeysWith: max
            )
            items = items.sorted {
                let a = lastWatched[$0.id] ?? .distantPast
                let b = lastWatched[$1.id] ?? .distantPast
                return a > b
            }
        default:
            break
        }
        return items
    }

    /// "12 movies · 8 shows" beside the title.
    private func countLine(movies: Int, shows: Int) -> String? {
        guard movies + shows > 0 else { return nil }
        var parts: [String] = []
        if movies > 0 { parts.append("\(movies) movie\(movies == 1 ? "" : "s")") }
        if shows > 0 { parts.append("\(shows) show\(shows == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        // Derived ONCE per body pass. These used to be chained computed
        // properties (`sorted` → `savedMovies`/`savedShows` → `visibleItems`
        // → `countLine`), and one pass touched the chain 6–8 times — each
        // touch re-sorting the whole library. `focusedID` is `@FocusState`
        // on this view, so every D-pad move in the grid pays a body pass;
        // on an A8 with a few hundred saved items that was per-press jank.
        let sortedItems = sorted
        let movies = sortedItems.filter { !$0.metaItem.isSeries }
        let shows = sortedItems.filter { $0.metaItem.isSeries }
        let visibleItems: [SavedLibraryItem] = {
            switch filter {
            case .movies: return movies
            case .shows: return shows
            default: return sortedItems
            }
        }()
        ZStack {
            ATVBackground()
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                    header(countLine: countLine(movies: movies.count, shows: shows.count))
                    chipRow
                    if visibleItems.isEmpty {
                        OrivioEmptyState(icon: "bookmark",
                                        title: emptyTitle,
                                        message: "Save titles with the + button on their page and they'll live here.")
                            .frame(height: 460)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: OrivioSpacing.xl) {
                            // Identified by the store's own type|id key: one
                            // title saved under two types (`series`/`tv`, or a
                            // `tmdb:<n>` that names a movie AND a show) would
                            // otherwise be a duplicate `ForEach` identifier —
                            // undefined in SwiftUI, and it crashes the tvOS
                            // focus engine.
                            ForEach(visibleItems, id: \.key) { item in
                                GridPosterCell(
                                    item: item.metaItem,
                                    captionWidth: posterLayout.posterSize.posterWidth,
                                    onSelect: onSelect,
                                    gridFocus: $focusedID
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, OrivioSpacing.huge)
                        .padding(.bottom, OrivioSpacing.huge)
                        .focusSection()
                    }
                }
                .padding(.top, OrivioSpacing.xl)
            }
            .scrollClipDisabled()
            .onExitCommand { backToTop(proxy, firstID: visibleItems.first?.id) }
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .movies: return "No saved movies"
        case .shows: return "No saved shows"
        default: return "Nothing saved yet"
        }
    }

    /// Back deep in the grid scrolls to (and focuses) the first poster; a second
    /// Back — already at the top — leaves the screen via `onBackAtRoot`.
    private func backToTop(_ proxy: ScrollViewProxy, firstID: String?) {
        // `focusedID` is nil while the chips / Sort pill hold focus — Back from
        // there leaves the screen; it used to yank focus down into the grid.
        guard let first = firstID, let focused = focusedID, focused != first else {
            onBackAtRoot(); return
        }
        withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .top) }
        DispatchQueue.main.async { focusedID = first }
    }

    private func header(countLine: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Library")
                .font(FusionType.pageTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)
            if let countLine {
                Text(countLine)
                    .font(FusionType.metadata(theme.font))
                    .foregroundStyle(theme.palette.textTertiary)
                    .padding(.leading, OrivioSpacing.sm)
            }
            Spacer()
            Image("OrivioLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 40)
                .accessibilityLabel("Cue")
        }
        .padding(.horizontal, OrivioSpacing.huge)
    }

    /// One row drives everything: All / Movies / Shows chips on the
    /// left, the Sort pill on the right.
    private var chipRow: some View {
        HStack(spacing: OrivioSpacing.md) {
            ForEach(LibraryFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    LibraryChip(title: f.rawValue, selected: filter == f)
                }
                .buttonStyle(PlainCardButtonStyle())
            }
            Spacer()
            OrivioDropdown(
                title: "Sort",
                selection: sort,
                options: [
                    OrivioDropdownOption("Added"),
                    OrivioDropdownOption("Name"),
                    OrivioDropdownOption("Recently Watched")
                ],
                triggerWidth: 380
            ) { sort = $0 }
        }
        .padding(.horizontal, OrivioSpacing.huge)
        .focusSection()
    }
}

/// A Liquid Glass filter chip: glass in every state, accent tint + accent ring
/// when selected, white ring + lift while focused.
private struct LibraryChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(selected ? theme.palette.onAccentTint : theme.palette.textSecondary)
            .padding(.horizontal, OrivioSpacing.xl)
            .padding(.vertical, OrivioSpacing.sm)
            .background {
                if selected {
                    Capsule().fill(theme.palette.secondary.opacity(0.30))
                }
            }
            .liquidGlassIf(!selected, in: Capsule())
            .overlay(Capsule().strokeBorder(
                isFocused ? Color.white.opacity(0.9)
                          : (selected ? theme.palette.secondary.opacity(0.7) : .clear),
                lineWidth: 3))
            .shadow(color: isFocused ? .black.opacity(0.35) : .clear, radius: isFocused ? 16 : 0, y: 6)
            .focusLift(OrivioFocus.card, isFocused)
            .animation(PerformanceSettingsStore.shared.buttonMotion(FusionMotion.focusEntry),
                       value: isFocused)
    }
}
