import SwiftUI

// MARK: - Home & Details

/// Settings → Home & Details: why Home's rows are there, your rows
/// (Discover's sentences on Home), Continue Watching's order, hiding watched titles, the billboard
/// paging by itself, trailers, hiding spoilers.
/// (The add-ons are Nuvio's, synced: under Nuvio → Sync.)
struct HomeContentSettingsDetail: View {
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @ObservedObject private var pins = DiscoverPins.shared
    @AppStorage(BillboardAutoPage.key) private var billboardAutoPage = true
    @AppStorage(HomeHideWatched.key) private var hideWatched = false
    @AppStorage(DetailHideSpoilers.key) private var hideSpoilers = false

    var body: some View {
        SettingsPage(title: SettingsCategory.homeContent.title) {
            SettingsSection {
                SettingsLinkRow(
                    title: "Why These Rows",
                    description: "What Cue read from your watching, and why each row is on Home today."
                ) { WhyTheseRowsPage() }

                SettingsLinkRow(
                    title: "Your Rows",
                    description: "Sentences from Discover you put on Home: their order and their names. "
                        + "Add one in Discover with Add to Home.",
                    value: pins.all.isEmpty ? "None" : "\(pins.all.count)"
                ) { YourRowsPage() }

                SettingsOptionsRow(
                    title: "Continue Watching Order",
                    pageDescription: "Choose how Continue Watching is sorted. Last Watched puts what you played "
                        + "most recently first. In Progress First puts titles you're part way through "
                        + "ahead of the rest.",
                    options: ContinueWatchingSortMode.allCases.map { SettingsOption(id: $0.rawValue, label: $0.displayName) },
                    selection: settings.continueWatchingSortMode.rawValue
                ) { settings.continueWatchingSortMode = ContinueWatchingSortMode(rawValue: $0) ?? .recentlyWatched }

                SettingsToggleRow(
                    title: "Hide Watched Titles",
                    description: "Leaves films you've watched and shows you've finished out of Home's rows.",
                    isOn: $hideWatched
                )

                SettingsToggleRow(
                    title: "Auto-Advance Billboard",
                    description: "Moves on to the next title every \(Int(BillboardAutoPage.interval)) seconds.",
                    isOn: $billboardAutoPage
                )

                SettingsOptionsRow(
                    title: "Trailers",
                    pageDescription: "Choose how trailers play when you rest on a title on the billboard or Details. "
                        + "With Sound plays them with it. Silent plays them without sound. "
                        + "Off leaves the picture still.",
                    options: [SettingsOption(id: "sound", label: "With Sound"),
                              SettingsOption(id: "silent", label: "Silent"),
                              SettingsOption(id: "off", label: "Off")],
                    selection: !settings.heroTrailersEnabled ? "off" : settings.heroTrailerSound ? "sound" : "silent"
                ) {
                    settings.heroTrailersEnabled = $0 != "off"
                    if $0 != "off" { settings.heroTrailerSound = $0 == "sound" }
                }

                SettingsToggleRow(
                    title: "Hide Spoilers",
                    description: "Blurs the pictures of episodes you haven't watched.",
                    isOn: $hideSpoilers
                )
            }
        }
    }
}

/// Home & Details → Why These Rows, from the last saved build of this
/// profile's rows: what Cue read from your watching, then each tab's rows,
/// each a tall row with a short preview; Select opens it in full in the
/// About panel (`TextPanel`). When they were built, to read, last.
struct WhyTheseRowsPage: View {
    @State private var saved: CueRows.Saved?
    @State private var loaded = false

    private static let tabs = [("home", "Home")]

    var body: some View {
        SettingsPage(title: "Why These Rows") {
            if let saved {
                SettingsSection(title: "Your Taste", spacing: SettingsMetrics.tallRowGap) {
                    tasteRows(saved)
                }
                ForEach(Self.tabs, id: \.0) { tab, name in
                    let rows = saved.why.filter { $0.tab == tab }
                    if !rows.isEmpty {
                        SettingsSection(title: name, spacing: SettingsMetrics.tallRowGap) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, why in
                                SettingsTallRow(title: why.title, preview: why.reason, id: "why.\(tab).\(index)") {
                                    let row = saved.rows.first { $0.title == why.title && ($0.tabs?.contains(tab) ?? true) }
                                    TextPanel.present(title: why.title, subtitle: name,
                                                      content: WhyRowPanel(reason: why.reason, row: row))
                                }
                            }
                        }
                    }
                }
                SettingsSection {
                    SettingsInfoRow(title: "Built",
                                    value: DateFormatter.settingsWhen.string(from: saved.builtAt))
                }
            } else if loaded {
                SettingsNote("Not built yet. Open Home and Cue builds its rows.")
                .background(alignment: .top) { SettingsFocusHolder() }
            }
        }
        .task { saved = await CueRows.saved(); loaded = true }
    }

    @ViewBuilder
    private func tasteRows(_ saved: CueRows.Saved) -> some View {
        let taste = saved.taste
        SettingsTallRow(title: "What You Watch",
                        preview: taste.prefix(4).map(\.label).joined(separator: ", "),
                        id: "why.taste") {
            TextPanel.present(title: "What You Watch",
                              subtitle: "From \(saved.titles) titles you watched or saved",
                              content: WhyTastePanel(taste: taste))
        }
        let ratings = TitleRatings.shared.snapshot()
        if !ratings.isEmpty {
            let groups = TitleRatings.Rating.allCases.reversed().compactMap { rating -> (TitleRatings.Rating, [String])? in
                let names = ratings.values.filter { $0.rating == rating }.sorted { $0.at > $1.at }.map(\.name)
                return names.isEmpty ? nil : (rating, names)
            }
            SettingsTallRow(title: "Your Ratings",
                            preview: groups.map { "\($0.0.name) \($0.1.count)" }.joined(separator: " · "),
                            id: "why.ratings") {
                TextPanel.present(title: "Your Ratings", content: WhyRatingsPanel(groups: groups))
            }
        }
        if !saved.passedOver.isEmpty {
            SettingsTallRow(title: "Passed Over", preview: saved.passedOver.joined(separator: ", "),
                            id: "why.passed") {
                TextPanel.present(title: "Passed Over", content: WhyTitlesPanel(
                    intro: "Titles you rested on and moved past on three days are left out of the rows "
                        + "for 30 days.",
                    names: saved.passedOver))
            }
        }
        if let dropped = saved.dropped, !dropped.isEmpty {
            SettingsTallRow(title: "Dropped", preview: dropped.joined(separator: ", "), id: "why.dropped") {
                TextPanel.present(title: "Dropped", content: WhyTitlesPanel(
                    intro: "A film stopped before 20 % and left for 14 days, or a show left for 30 days "
                        + "after one or two episodes, is left out of the rows and counts against its "
                        + "traits half as much as Not for Me. Rating it changes that.",
                    names: dropped))
            }
        }
    }
}

/// Settings 2's Why These Rows, from the last saved build, one screen:
/// See Everything (Home's rows in order, each its reason and its titles
/// with theirs, full screen: the About panel's `TextPanel`), Rebuild Rows
/// (the build its second line); what's left out (ratings, passed over,
/// dropped: lists with their actions). (Home's rows as a list here, each
/// opening its page, were before: the page scrolled.) (Before, 2026-11-23: every reason and
/// list in full on one page of cards, read a card at a time with dots, a
/// custom scroll; then the taste on it too, a page per kind: read-only
/// parts on a page that scrolls by focus.)
struct WhyTheseRowsCardPage: View {
    @EnvironmentObject private var nav: SettingsNav
    @State private var saved: CueRows.Saved?
    @State private var loaded = false
    @State private var rebuild = CueRows.rebuildRequested

    var body: some View {
        SettingsPage(title: "Why These Rows") {
            if let saved {
                content(saved)
            } else if loaded {
                SettingsNote("Not built yet. Open Home and Cue builds its rows.")
                SettingsFocusHolder()
            }
        }
        .task {
            saved = await CueRows.saved()
            loaded = true
        }
    }

    @ViewBuilder private func content(_ saved: CueRows.Saved) -> some View {
        let whys = saved.why.filter { $0.tab == "home" }
        SettingsSection {
            if !whys.isEmpty {
                Button {
                    TextPanel.present(title: "Why These Rows",
                                      subtitle: "Built " + DateFormatter.settingsWhen.string(from: saved.builtAt),
                                      content: WhyAllRowsPanel(saved: saved, whys: whys))
                } label: {
                    SettingsRowLabel(title: "See Everything", value: "\(whys.count) rows", chevron: true,
                                     description: "Each row on Home, why it's there, and why its titles are.")
                }
                .settingsRow(id: "why.all")
            }
            Button {
                CueRows.rebuildRequested = true
                rebuild = true
            } label: {
                SettingsRowLabel(title: "Rebuild Rows", value: rebuild ? "When Home opens" : nil,
                                 description: "Built " + DateFormatter.settingsWhen.string(from: saved.builtAt)
                                    + " from \(saved.titles) titles.")
            }
            .settingsRow(id: "why.rebuild")
        }
        leftOut(saved)
    }

    // MARK: Left out and rated

    @ViewBuilder private func leftOut(_ saved: CueRows.Saved) -> some View {
        let ratings = TitleRatings.shared.snapshot()
        let passed = saved.passedTitles?.count ?? saved.passedOver.count
        let dropped = saved.droppedTitles?.count ?? saved.dropped?.count ?? 0
        if !ratings.isEmpty || passed > 0 || dropped > 0 {
            SettingsSection(title: "Left Out and Rated") {
                if !ratings.isEmpty {
                    Button { nav.push(WhyRatingsPage()) } label: {
                        SettingsRowLabel(title: "Your Ratings", value: "\(ratings.count)", chevron: true,
                                         description: "Liked and loved count more; Not for Me is never shown.")
                    }
                    .settingsRow(id: "why.ratings")
                }
                if passed > 0 {
                    Button { nav.push(WhyPassedPage(saved: saved)) } label: {
                        SettingsRowLabel(title: "Passed Over", value: "\(passed)", chevron: true,
                                         description: "Looked at and left on three days: out for 30 days.")
                    }
                    .settingsRow(id: "why.passed")
                }
                if dropped > 0 {
                    Button { nav.push(WhyDroppedPage(saved: saved)) } label: {
                        SettingsRowLabel(title: "Dropped", value: "\(dropped)", chevron: true,
                                         description: "Stopped early and left: out, and counted against. Rate it to change that.")
                    }
                    .settingsRow(id: "why.dropped")
                }
            }
        }
    }
}

/// Settings 2's Your Taste: what Cue read from your watching, one screen.
/// See Everything first (every trait, full screen: the About panel's
/// `TextPanel`), then only to read (in the well): the kinds' top six in
/// two columns, each trait its name, a bar of its share of your watching,
/// the share; the small kinds a line each under them. (Before, 2026-11-23: a page per
/// kind, every trait with "× usual" and Discover on Select: too much.)
struct YourTasteCardPage: View {
    @State private var saved: CueRows.Saved?
    @State private var loaded = false

    var body: some View {
        SettingsPage(title: "Your Taste") {
            if let saved, !saved.taste.isEmpty {
                SettingsSection {
                    Button {
                        TextPanel.present(title: "Your Taste",
                                          subtitle: "From \(saved.titles) titles you watched, started or saved",
                                          content: WhyTastePanel(taste: saved.taste))
                    } label: {
                        SettingsRowLabel(title: "See Everything", value: "\(saved.taste.count) traits", chevron: true,
                                         description: "Read from the last \(saved.titles) titles you watched, "
                                            + "started or saved; newer ones count more.")
                    }
                    .settingsRow(id: "taste.all")
                    WhyTasteGrid(saved: saved)
                        .containerValue(\.settingsEmbedded, true)
                }
            } else if loaded {
                SettingsNote("Nothing read yet. Watch something and Cue learns your taste.")
                SettingsFocusHolder()
            }
        }
        .task {
            saved = await CueRows.saved()
            loaded = true
        }
    }
}

/// The taste, laid out to fit the column without scrolling.
struct WhyTasteGrid: View {
    let saved: CueRows.Saved

    private typealias Block = (name: String, lines: [CueRows.TasteLine])

    /// The kinds with blocks (top five each), studios and networks as one;
    /// and the ones read in a line (a language or two).
    private static let blocks: [(name: String, keys: Set<String>)] = [
        ("Genres", ["g"]), ("Themes", ["k"]), ("People", ["p"]), ("Studios & Networks", ["c", "n"]),
    ]
    private static let lines: [(name: String, key: String)] = [
        ("Languages", "l"), ("Countries", "o"), ("Decades", "d"),
    ]

    var body: some View {
        let byShare = saved.taste.filter { $0.kind != nil }.sorted { $0.share > $1.share }
        let blocks: [Block] = Self.blocks.compactMap { block in
            let lines = byShare.filter { block.keys.contains($0.kind ?? "") }.prefix(6)
            return lines.isEmpty ? nil : (block.name, Array(lines))
        }
        let pairs = stride(from: 0, to: blocks.count, by: 2).map { Array(blocks[$0..<min($0 + 2, blocks.count)]) }
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: 56) {
                    ForEach(pair, id: \.name) { block in
                        blockView(block).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
            let small = Self.lines.compactMap { kind -> (String, String)? in
                let found = byShare.filter { $0.kind == kind.key }.prefix(3)
                return found.isEmpty ? nil
                    : (kind.name, found.map { "\($0.label) \(Self.percent($0.share))" }.joined(separator: "  ·  "))
            }
            if !small.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(small, id: \.0) { name, value in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(name)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(CueInk.tertiary)
                                .frame(width: 160, alignment: .leading)
                            Text(value)
                                .font(.system(size: 24))
                                .monospacedDigit()
                                .foregroundStyle(CueInk.body)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(block.name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(CueInk.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(block.lines, id: \.label) { line in
                    GridRow(alignment: .center) {
                        Text(line.label)
                            .font(.system(size: 24))
                            .foregroundStyle(CueInk.primary)
                            .lineLimit(1)
                            .frame(maxWidth: 240, alignment: .leading)
                        Capsule()
                            .fill(CueInk.color(0.10))
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(CueInk.body)
                                        .frame(width: max(6, geo.size.width * min(max(line.share, 0), 1)))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        Text(Self.percent(line.share))
                            .font(.system(size: 24))
                            .monospacedDigit()
                            .foregroundStyle(CueInk.body)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }
}

/// Your ratings by rating, newest first: Open (Details), Remove (undone in
/// place, gone as the page goes; the rows follow on their next build).
private struct WhyRatingsPage: View {
    @Environment(\.settingsOpenTitle) private var openTitle
    @State private var ratings = TitleRatings.shared.snapshot()
    @State private var pending: Set<String> = []

    var body: some View {
        let groups = TitleRatings.Rating.allCases.reversed().compactMap { rating -> (TitleRatings.Rating, [(String, TitleRatings.Entry)])? in
            let entries = ratings.filter { $0.value.rating == rating }.sorted { $0.value.at > $1.value.at }
                .map { ($0.key, $0.value) }
            return entries.isEmpty ? nil : (rating, entries)
        }
        SettingsPage(title: "Your Ratings") {
            ForEach(groups, id: \.0) { rating, entries in
                SettingsSection(title: rating.name) {
                    ForEach(entries, id: \.0) { id, entry in
                        let gone = pending.contains(id)
                        ActionListRow(
                            id: "why.rating.\(id)",
                            title: entry.name,
                            detail: gone ? "Removed" : "Rated " + DateFormatter.settingsWhen.string(from: entry.at),
                            dimmed: gone,
                            actions: [
                                SettingsAction(title: "Open", icon: "info.circle", key: "open") {
                                    openTitle?(MetaItem(id: id, type: entry.type, name: entry.name))
                                },
                                gone
                                    ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") {
                                        pending.remove(id)
                                    }
                                    : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") {
                                        pending.insert(id)
                                    },
                            ])
                    }
                }
            }
        }
        .onDisappear {
            if !pending.isEmpty { TitleRatings.shared.clear(Array(pending)) }
            pending = []
        }
    }
}

/// Passed over: each with when it's back; Open, Show Again (its passes
/// forgotten, undone in place; the rows made again when Home opens).
private struct WhyPassedPage: View {
    @Environment(\.settingsOpenTitle) private var openTitle
    let saved: CueRows.Saved
    @State private var pending: Set<String> = []

    var body: some View {
        SettingsPage(title: "Passed Over") {
            if let titles = saved.passedTitles {
                SettingsSection {
                    ForEach(titles, id: \.id) { title in
                        let gone = pending.contains(title.id)
                        ActionListRow(
                            id: "why.passed.\(title.id)",
                            title: title.name,
                            detail: gone ? "Back when Home opens" : Self.back(title.until),
                            dimmed: gone,
                            actions: [
                                SettingsAction(title: "Open", icon: "info.circle", key: "open") {
                                    openTitle?(MetaItem(id: title.id, type: title.type, name: title.name))
                                },
                                gone
                                    ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "back") {
                                        pending.remove(title.id)
                                    }
                                    : SettingsAction(title: "Show Again", icon: "eye", key: "back") {
                                        pending.insert(title.id)
                                    },
                            ])
                    }
                }
            } else {
                SettingsNote("Rebuild Rows to see these titles here.")
                SettingsFocusHolder()
            }
        }
        .onDisappear {
            guard !pending.isEmpty else { return }
            CueRows.Memory.shared.letBackIn(Array(pending))
            CueRows.rebuildRequested = true
            pending = []
        }
    }

    private static func back(_ until: Date?) -> String {
        guard let until else { return "Out for now" }
        let days = Int((until.timeIntervalSinceNow / 86_400).rounded(.up))
        return days <= 1 ? "Back tomorrow" : "Back in \(days) days"
    }
}

/// Dropped: each with how far you got; Open (rating it is what changes it).
private struct WhyDroppedPage: View {
    @Environment(\.settingsOpenTitle) private var openTitle
    let saved: CueRows.Saved

    var body: some View {
        SettingsPage(title: "Dropped") {
            if let titles = saved.droppedTitles {
                SettingsSection {
                    ForEach(titles, id: \.id) { title in
                        ActionListRow(
                            id: "why.dropped.\(title.id)",
                            title: title.name,
                            detail: title.note ?? "",
                            actions: [SettingsAction(title: "Open", icon: "info.circle", key: "open") {
                                openTitle?(MetaItem(id: title.id, type: title.type, name: title.name))
                            }])
                    }
                }
            } else {
                SettingsNote("Rebuild Rows to see these titles here.")
                SettingsFocusHolder()
            }
        }
    }
}

/// Why These Rows' See Everything: Home's rows in order, each its name,
/// its reason (and how you've used it lately), its first nine titles with
/// why each is in it, three across (all of them laid out at once was too
/// many pictures for one panel).
struct WhyAllRowsPanel: View {
    let saved: CueRows.Saved
    let whys: [CueRows.Why]
    static let shown = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 80) {
            ForEach(Array(whys.enumerated()), id: \.offset) { index, why in
                let row = saved.rows.first { $0.title == why.title && ($0.tabs?.contains("home") ?? true) }
                VStack(alignment: .leading, spacing: 24) {
                    WhyHeader(icon: "rectangle.stack", title: "\(index + 1). \(why.title)",
                              count: row.map { "\($0.items.count)" })
                        .panelAnchor(.strong)
                    WhyPanel.intro(([why.reason] + (why.notes ?? [])).joined(separator: " "))
                    if let row, !row.items.isEmpty {
                        WhyColumns(Array(row.items.prefix(Self.shown).enumerated()), columns: 3,
                                   width: WhyPanel.column, spacing: WhyPanel.gap, rowSpacing: 22) { entry in
                            WhyTitleLine(rank: row.shape == .ranked ? entry.offset + 1 : nil, item: entry.element,
                                         badge: nil, note: row.whys?[entry.element.id])
                        }
                        if row.items.count > Self.shown {
                            Text("and \(row.items.count - Self.shown) more")
                                .font(.system(size: WhyPanel.textSize))
                                .foregroundStyle(CueInk.tertiary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Why These Rows' panels

/// The panels' parts. One grid in every panel: three columns of 460, 60
/// apart, across the panel's 1500; the intro two of them wide (980: lined
/// up with the grid; the whole width ran past 120 characters a line).
private enum WhyPanel {
    static let textSize = FixedFocusMetrics.textSize
    static let column: CGFloat = 460
    static let gap: CGFloat = 60
    static let introWidth = 2 * column + gap

    static func intro(_ text: String) -> some View {
        Text(text)
            .font(.system(size: SettingsMetrics.descriptionTextSize))
            .lineSpacing(8)
            .foregroundStyle(CueInk.body)
            .frame(maxWidth: introWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Columns laid out at once, every line in place (a lazy grid laid its
/// items out apart from the rest as the panel scrolled): the items in
/// lines of `columns`, left to right; each line a place the scroll can
/// stop (`anchors`: a section's start, or a line).
private struct WhyColumns<Item, Cell: View>: View {
    let items: [Item]
    let columns: Int
    let width: CGFloat
    let spacing: CGFloat
    let rowSpacing: CGFloat
    var anchors: PanelAnchor.Kind = .line
    @ViewBuilder let cell: (Item) -> Cell

    init(_ items: [Item], columns: Int, width: CGFloat, spacing: CGFloat, rowSpacing: CGFloat,
         anchors: PanelAnchor.Kind = .line, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.columns = columns
        self.width = width
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.anchors = anchors
        self.cell = cell
    }

    var body: some View {
        let lines = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(lines[index].indices, id: \.self) { column in
                        cell(lines[index][column]).frame(width: width, alignment: .topLeading)
                    }
                }
                .panelAnchor(anchors)
            }
        }
    }
}

/// A group's header: its icon and name in the section labels' capitals,
/// a quiet count after it.
private struct WhyHeader: View {
    let icon: String
    let title: String
    var count: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 34)
            Text(title.uppercased())
                .font(.system(size: SettingsMetrics.sectionTextSize, weight: .semibold))
            if let count {
                Text(count)
                    .font(.system(size: SettingsMetrics.sectionTextSize))
                    .foregroundStyle(CueInk.tertiary)
            }
        }
        .foregroundStyle(CueInk.secondary)
    }
}

/// What You Watch: your traits by kind, each a bar of its share of your
/// watching (against the largest), the share, and how many times more it
/// is in yours than in what's popular. Two columns of kinds.
struct WhyTastePanel: View {
    let taste: [CueRows.TasteLine]

    private static let kinds: [(key: String, name: String, icon: String)] = [
        ("g", "Genres", "theatermasks"), ("k", "Themes", "tag"), ("l", "Languages", "character.bubble"),
        ("o", "Countries", "globe"), ("d", "Decades", "calendar"), ("c", "Studios", "building.2"),
        ("n", "Networks", "tv"), ("p", "People", "person.2"),
    ]

    /// Three columns across the panel; a group takes a column per 7 lines
    /// (at most three), its lines split evenly between them (read down,
    /// then across). Groups fill each line of the grid in order; one that
    /// doesn't fit takes the columns left if that keeps it to 12 lines a
    /// column (Themes beside Genres, not under it alone), else starts the
    /// next line.
    static let columns = 3
    static let column = WhyPanel.column
    static let gap = WhyPanel.gap

    static func span(_ lines: Int) -> Int { min(columns, max(1, (lines + 6) / 7)) }
    static func leastSpan(_ lines: Int) -> Int { min(columns, max(1, (lines + 11) / 12)) }

    private typealias Group = (name: String, icon: String, lines: [CueRows.TasteLine])

    /// The grid's lines, each group with the columns it takes.
    private static func pack(_ groups: [Group]) -> [[(group: Group, span: Int)]] {
        var out: [[(group: Group, span: Int)]] = []
        var line: [(group: Group, span: Int)] = []
        var used = 0
        for group in groups {
            var span = span(group.lines.count)
            if used + span > columns {
                if !line.isEmpty, columns - used >= leastSpan(group.lines.count) {
                    span = columns - used
                } else if !line.isEmpty {
                    out.append(line)
                    line = []
                    used = 0
                }
            }
            line.append((group, span))
            used += span
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    private var groups: [Group] {
        // Saved before kinds were kept: one group.
        guard taste.contains(where: { $0.kind != nil }) else {
            return taste.isEmpty ? [] : [("Your Traits", "sparkles", taste)]
        }
        return Self.kinds.compactMap { kind in
            let lines = taste.filter { $0.kind == kind.key }.sorted { $0.share > $1.share }
            return lines.isEmpty ? nil : (kind.name, kind.icon, lines)
        }
    }

    var body: some View {
        let most = taste.map(\.share).max() ?? 1
        VStack(alignment: .leading, spacing: 56) {
            WhyPanel.intro("Cue reads a taste from the last titles you watched, started or saved, "
                + "and scores every row against it, with a share of the day's chance so the rows "
                + "change each day. A trait counts more where it's rarer in what's popular: "
                + "the number after each share says how many times more it is in yours.")
            VStack(alignment: .leading, spacing: 64) {
                ForEach(Array(Self.pack(groups).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(line, id: \.group.name) { entry in
                            WhyTasteGroup(name: entry.group.name, icon: entry.group.icon, lines: entry.group.lines,
                                          most: most, span: entry.span)
                        }
                    }
                    .panelAnchor(.strong)
                }
            }
        }
    }
}

/// One kind of trait: its header, its lines in `span` columns.
private struct WhyTasteGroup: View {
    let name: String
    let icon: String
    let lines: [CueRows.TasteLine]
    let most: Double
    let span: Int

    var body: some View {
        let perColumn = Int((Double(lines.count) / Double(span)).rounded(.up))
        let columns = stride(from: 0, to: lines.count, by: max(perColumn, 1))
            .map { Array(lines[$0..<min($0 + perColumn, lines.count)]) }
        VStack(alignment: .leading, spacing: 20) {
            WhyHeader(icon: icon, title: name)
            HStack(alignment: .top, spacing: WhyTastePanel.gap) {
                ForEach(columns.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(columns[index], id: \.label) { line in
                            WhyBar(line: line, most: most).panelAnchor(.line)
                        }
                    }
                    .frame(width: WhyTastePanel.column, alignment: .leading)
                }
            }
        }
    }
}

/// A trait's line: its name, its bar, its share, its lift (the column's
/// 460 pt: 180, 120, 64, 48 and three gaps of 16).
private struct WhyBar: View {
    let line: CueRows.TasteLine
    let most: Double

    var body: some View {
        HStack(spacing: 16) {
            Text(line.label)
                .font(.system(size: WhyPanel.textSize, weight: .medium))
                .foregroundStyle(CueInk.primary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 120, height: 10)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(CueInk.primary)
                        .frame(width: max(10, 120 * line.share / max(most, 0.0001)))
                }
            Text("\(Int((line.share * 100).rounded())) %")
                .font(.system(size: WhyPanel.textSize))
                .monospacedDigit()
                .foregroundStyle(CueInk.body)
                .frame(width: 64, alignment: .trailing)
            Text(line.lift.map { $0 >= 1.5 ? String(format: "%.0f×", $0.rounded()) : "" } ?? "")
                .font(.system(size: WhyPanel.textSize))
                .monospacedDigit()
                .foregroundStyle(CueInk.tertiary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// Your Ratings: a column per rating, its thumbs, its count, its titles.
private struct WhyRatingsPanel: View {
    let groups: [(TitleRatings.Rating, [String])]

    var body: some View {
        VStack(alignment: .leading, spacing: 56) {
            WhyPanel.intro("Love This counts twice and I Like This one and a half times in your taste, "
                + "and seeds Because You Watched more. Not for Me is left out of every row Cue makes, "
                + "and takes its traits off a little.")
            HStack(alignment: .top, spacing: WhyPanel.gap) {
                ForEach(groups, id: \.0) { rating, names in
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            WhySymbol(rating: rating)
                            Text(rating.name)
                                .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                                .foregroundStyle(CueInk.primary)
                            Text("\(names.count)")
                                .font(.system(size: SettingsMetrics.rowTextSize))
                                .foregroundStyle(CueInk.tertiary)
                        }
                        .padding(.bottom, 6)
                        ForEach(names, id: \.self) { name in
                            Text(name)
                                .font(.system(size: WhyPanel.textSize))
                                .foregroundStyle(CueInk.body)
                                .lineLimit(1)
                                .panelAnchor(.line)
                        }
                    }
                    .frame(width: WhyPanel.column, alignment: .leading)
                }
            }
        }
    }
}

/// The rating's symbol, as its tile's: ✕, ✓, ♥.
private struct WhySymbol: View {
    let rating: TitleRatings.Rating

    var body: some View {
        Image(systemName: rating.symbol(filled: true))
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(CueInk.primary)
    }
}

/// Passed Over, Dropped: why, then the titles in three columns.
private struct WhyTitlesPanel: View {
    let intro: String
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 56) {
            WhyPanel.intro(intro)
            VStack(alignment: .leading, spacing: 20) {
                WhyHeader(icon: "eye.slash", title: "Left Out", count: "\(names.count)")
                    .panelAnchor(.strong)
                WhyColumns(names, columns: 3, width: WhyPanel.column, spacing: WhyPanel.gap, rowSpacing: 16) { name in
                    Text(name)
                        .font(.system(size: WhyPanel.textSize))
                        .foregroundStyle(CueInk.body)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A row's reason, then its titles as a table: poster, name, year and
/// kind, the badge it was made with. Three columns.
private struct WhyRowPanel: View {
    let reason: String
    let row: CueRows.Row?

    var body: some View {
        VStack(alignment: .leading, spacing: 56) {
            WhyPanel.intro(reason)
            if let row, !row.items.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                    WhyHeader(icon: "rectangle.stack", title: "In This Row", count: "\(row.items.count)")
                        .panelAnchor(.strong)
                    WhyColumns(Array(row.items.enumerated()), columns: 3, width: WhyPanel.column,
                               spacing: WhyPanel.gap, rowSpacing: 22) { entry in
                        WhyTitleLine(rank: row.shape == .ranked ? entry.offset + 1 : nil, item: entry.element,
                                     badge: row.badges?[entry.element.id])
                    }
                }
            }
        }
    }
}

private struct WhyTitleLine: View {
    let rank: Int?
    let item: MetaItem
    let badge: CardBadge?
    /// Why it's in the row, in words (Why These Rows' See Everything).
    var note: String? = nil

    private var facts: String {
        let kind = item.isSeries ? "Series" : "Movie"
        let year = item.releaseInfo.map { String($0.prefix(4)) } ?? ""
        return year.isEmpty ? kind : "\(kind) · \(year)"
    }

    var body: some View {
        HStack(spacing: 22) {
            if let rank {
                Text("\(rank)")
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(CueInk.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            AsyncImage(url: item.poster.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .frame(width: 64, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: WhyPanel.textSize, weight: .medium))
                    .foregroundStyle(CueInk.primary)
                    .lineLimit(1)
                Text(facts)
                    .font(.system(size: WhyPanel.textSize))
                    .foregroundStyle(CueInk.body)
                    .lineLimit(1)
                if let badge {
                    BadgeLabel(badge: .init(symbol: FixedFocusBadges.symbol(badge.kind), mark: nil, text: badge.text))
                        .lineLimit(1)
                } else if let note {
                    Text(note)
                        .font(.system(size: WhyPanel.textSize))
                        .foregroundStyle(CueInk.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Your rows

/// Settings → Home & Details → Your Rows: Discover's sentences on Home in
/// their order, a row each (its name on Home), lit whole; Select opens its
/// page (`YourRowPage`). Edit, on the title's line, gives each the ≡
/// handle; Done or Back ends it. (Home & Details as Home Rows' and the
/// add-ons' pages.)
struct YourRowsPage: View {
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus
    @ObservedObject private var pins = DiscoverPins.shared
    @State private var editing = false
    @State private var moving: String?

    var body: some View {
        let rows = pins.all
        SettingsPage(title: "Your Rows",
                     subtitle: rows.isEmpty ? "None yet. In Discover, Add to Home puts a sentence on Home." : "",
                     accessory: AnyView(accessory(count: rows.count))) {
            SettingsSection(spacing: SettingsMetrics.tallRowGap) {
                ForEach(rows, id: \.id) { pin in
                    SettingsReorderRow(
                        title: pin.rowName, id: pin.id,
                        chevron: true,
                        editing: editing, isMoving: moving == pin.id, anyMoving: moving != nil,
                        onSelect: { nav.push(YourRowPage(id: pin.id)) },
                        onLift: { moving = pin.id },
                        onMoveStep: { pins.move(pin.id, by: $0) },
                        onDrop: { moving = nil })
                }
            }
        }
        .background(alignment: .top) { if rows.isEmpty { SettingsFocusHolder() } }
        .onExitCommand(perform: editing && moving == nil ? endEditing : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    @ViewBuilder private func accessory(count: Int) -> some View {
        if editing {
            SettingsCapsuleButton(title: "Done", action: endEditing).disabled(moving != nil)
        } else if count > 1 {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func endEditing() {
        moving = nil; editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = "Edit" }
    }
}

/// One of your rows: Open in Discover (the tab with its sentence), Rename
/// (empty or the sentence: the sentence again), Remove from Home; its
/// sentence to read.
private struct YourRowPage: View {
    @EnvironmentObject private var nav: SettingsNav
    @ObservedObject private var pins = DiscoverPins.shared
    let id: String

    @State private var keyboard: KeyboardRequest?

    var body: some View {
        if let pin = pins.all.first(where: { $0.id == id }) {
            let name = pin.rowName
            SettingsPage(title: name) {
                SettingsSection {
                    SettingsButtonRow(title: "Open in Discover") { pins.opening = pin }
                    SettingsButtonRow(title: "Rename", value: name) {
                        keyboard = KeyboardRequest(text: name, placeholder: DiscoverPins.titleCase(pin.name)) {
                            pins.rename(pin.id, to: $0)
                        }
                    }
                    SettingsButtonRow(title: "Remove from Home") {
                        nav.back()
                        pins.remove(pin.id)
                    }
                    SettingsInfoRow(title: "Sentence", value: pin.name)
                        .padding(.top, SettingsMetrics.infoGap)
                }
            }
            .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        }
    }
}

// MARK: - Add-ons

/// Settings → Nuvio → Add-ons: the add-ons in order, a row each (its logo,
/// its name, "Off" when off), lit whole; Select opens its page
/// (`AddonPage`: Configure, Rename, Remove). Edit, on the title's line,
/// gives each row an on / off and the ≡ handle (`SettingsReorderRow`);
/// Done or Back ends it. Then Add Add-on (from your phone), as Profiles'
/// Add Profile, and Refresh Add-ons (their manifests fetched again, this
/// device only). (Tried: each one line with Configure, Rename, Move, a
/// switch and Remove — too many buttons; a round + by the heading.)
struct AddonsPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus
    @State private var editing = false
    @State private var moving: String?
    @State private var adding = false
    @State private var refreshing = false
    /// The last refresh's add-ons that didn't answer (this visit).
    @State private var failed = 0
    @AppStorage("cue.addons.refreshedAt") private var refreshedAt: Double = 0

    private var refreshValue: String {
        if refreshing { return "Refreshing…" }
        if failed > 0 { return failed == 1 ? "1 didn't answer" : "\(failed) didn't answer" }
        guard refreshedAt > 0 else { return "Not yet" }
        return DateFormatter.settingsWhen.string(from: Date(timeIntervalSince1970: refreshedAt))
    }

    var body: some View {
        SettingsPage(title: "Add-ons", subtitle: "Higher ones come first for sources.",
                     accessory: AnyView(accessory)) {
            SettingsSection(spacing: SettingsMetrics.tallRowGap) {
                ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, addon in
                    SettingsReorderRow(
                        title: addon.displayName, id: addon.id,
                        leading: AnyView(AddonLogo(addon: addon)),
                        value: addon.enabled ? nil : "Off",
                        chevron: true,
                        dimmed: !addon.enabled,
                        toggle: SettingsEntrySwitch(isOn: addon.enabled, title: addon.enabled ? "Turn off" : "Turn on") {
                            addonManager.setEnabled(addon, !addon.enabled)
                        },
                        editing: editing, isMoving: moving == addon.id, anyMoving: moving != nil,
                        onSelect: { nav.push(AddonPage(addonID: addon.id)) },
                        onLift: { moving = addon.id },
                        onMoveStep: { addonManager.move(addon, to: index + $0) },
                        onDrop: { moving = nil })
                }
                // Under the list as Apple's Add Language…, the rows' own gap between them.
                SettingsSection {
                    SettingsButtonRow(title: "Add Add-on") { adding = true }
                    SettingsButtonRow(title: "Refresh Add-ons", value: refreshValue) {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            failed = await addonManager.refreshManifests(bypassCache: true)
                            refreshing = false
                            if failed == 0 { refreshedAt = Date().timeIntervalSince1970 }
                        }
                    }
                }
                .disabled(editing)
                .padding(.top, SettingsMetrics.listButtonGap - SettingsMetrics.tallRowGap)
            }
        }
        .onExitCommand(perform: editing && moving == nil ? endEditing : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onDisappear { TopBarLock.shared.locked = false }
        .fullScreenCover(isPresented: $adding) {
            AddonPhoneAddView(addonManager: addonManager) { adding = false }

        }
    }

    @ViewBuilder private var accessory: some View {
        if editing {
            SettingsCapsuleButton(title: "Done", action: endEditing).disabled(moving != nil)
        } else if !addonManager.addons.isEmpty {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func endEditing() {
        moving = nil; editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = "Edit" }
    }
}

/// Settings 2's Add-ons, one page: Add Add-on and Refresh on top, then
/// the add-ons in source order, each a row with its actions on it
/// (`ActionListRow`): Configure (when it has settings), Turn Off / On,
/// Move, Rename, Remove. No add-on page, no Edit mode.
struct AddonsCardPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @State private var moving: String?
    @State private var adding = false
    @State private var configuring: InstalledAddon?
    @State private var removing: InstalledAddon?
    @State private var keyboard: KeyboardRequest?
    @State private var refreshing = false
    @State private var failed = 0
    @AppStorage("cue.addons.refreshedAt") private var refreshedAt: Double = 0

    private var refreshValue: String {
        if refreshing { return "Refreshing…" }
        if failed > 0 { return failed == 1 ? "1 didn't answer" : "\(failed) didn't answer" }
        guard refreshedAt > 0 else { return "Not yet" }
        return DateFormatter.settingsWhen.string(from: Date(timeIntervalSince1970: refreshedAt))
    }

    var body: some View {
        SettingsPage(title: "Add-ons") {
            SettingsSection {
                SettingsButtonRow(title: "Add Add-on", description: "From your phone, with its link.") { adding = true }
                SettingsButtonRow(title: "Refresh Add-ons", value: refreshValue) {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        failed = await addonManager.refreshManifests(bypassCache: true)
                        refreshing = false
                        if failed == 0 { refreshedAt = Date().timeIntervalSince1970 }
                    }
                }
            }
            .disabled(moving != nil)
            if !addonManager.addons.isEmpty {
                SettingsSection(title: "Higher Ones Come First for Sources") {
                    ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, addon in
                        ActionListRow(
                            id: addon.id,
                            leading: AnyView(AddonLogo(addon: addon)),
                            title: addon.displayName,
                            detail: Self.detail(addon),
                            dimmed: !addon.enabled,
                            actions: actions(addon),
                            moving: moving == addon.id,
                            anyMoving: moving != nil,
                            onMoveStep: { addonManager.move(addon, to: index + $0) },
                            onDrop: { moving = nil })
                    }
                }
            }
        }
        .onChange(of: moving) { _, now in TopBarLock.shared.locked = now != nil }
        .onDisappear { TopBarLock.shared.locked = false }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .fullScreenCover(isPresented: $adding) {
            AddonPhoneAddView(addonManager: addonManager) { adding = false }
        }
        .fullScreenCover(item: $configuring) { addon in
            AddonPhoneAddView(addonManager: addonManager, configuring: addon) { configuring = nil }
        }
        .alert("Remove \(removing?.displayName ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { addonManager.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It's removed from this device and your account. You can add it back later with its link.")
        }
    }

    private func actions(_ addon: InstalledAddon) -> [SettingsAction] {
        var list: [SettingsAction] = []
        if addon.configureURL != nil {
            list.append(SettingsAction(title: "Configure", icon: "gearshape") { configuring = addon })
        }
        list.append(SettingsAction(title: addon.enabled ? "Turn Off" : "Turn On",
                                   icon: addon.enabled ? "eye.slash" : "eye", key: "toggle") {
            addonManager.setEnabled(addon, !addon.enabled)
        })
        if addonManager.addons.count > 1 {
            list.append(SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true) { moving = addon.id })
        }
        list.append(SettingsAction(title: "Rename", icon: "pencil") {
            keyboard = KeyboardRequest(text: addon.displayName, placeholder: addon.manifest.name) {
                addonManager.rename(addon, to: $0)
            }
        })
        list.append(SettingsAction(title: "Remove", icon: "trash", danger: true) { removing = addon })
        return list
    }

    /// "v1.4 · Streams, Subtitles": its version and what it gives.
    static func detail(_ addon: InstalledAddon) -> String {
        let kinds = (addon.manifest.resources ?? []).map(\.name).filter { $0 != "manifest" }
        let named = Array(Set(kinds)).sorted().map { name -> String in
            switch name {
            case "stream": return "Streams"
            case "subtitles": return "Subtitles"
            case "catalog": return "Catalogs"
            case "meta": return "Details"
            default: return name.capitalized
            }
        }
        return ([addon.manifest.version.map { "v\($0)" }] + [named.isEmpty ? nil : named.joined(separator: ", ")])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// An add-on's own page: Configure (when it has settings — its page on
/// your phone), Rename (the keyboard; empty: its own name again), Remove
/// (confirmed; back to the list).
private struct AddonPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    let addonID: String

    @State private var keyboard: KeyboardRequest?
    @State private var configuring = false
    @State private var confirmRemove = false

    private var addon: InstalledAddon? { addonManager.addons.first { $0.id == addonID } }

    var body: some View {
        if let addon {
            SettingsPage(title: addon.displayName, subtitle: addon.manifest.description ?? "") {
                SettingsSection {
                    if addon.configureURL != nil {
                        SettingsButtonRow(title: "Configure") { configuring = true }
                    }
                    SettingsButtonRow(title: "Rename", value: addon.displayName) {
                        keyboard = KeyboardRequest(text: addon.displayName, placeholder: addon.manifest.name) {
                            addonManager.rename(addon, to: $0)
                        }
                    }
                    SettingsButtonRow(title: "Remove") { confirmRemove = true }
                }
            }
            .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
            .fullScreenCover(isPresented: $configuring) {
                AddonPhoneAddView(addonManager: addonManager, configuring: addon) { configuring = false }

            }
            .alert("Remove \(addon.displayName)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    nav.back()
                    addonManager.remove(addon)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's removed from this device and your account. You can add it back later with its link.")
            }
        }
    }
}

/// An add-on's logo, small, on the left of its row.
struct AddonLogo: View {
    let addon: InstalledAddon

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08))
            if let logo = addon.manifest.logo {
                RemoteImage(url: logo, contentMode: .fit, maxDimension: 80, showsPlaceholder: false)
                    .padding(4)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }
}
