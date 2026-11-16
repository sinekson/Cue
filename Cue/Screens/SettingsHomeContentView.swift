import SwiftUI

// MARK: - Home & Details

/// Settings → Home & Details: Home's rows (their order, names, which
/// show), Continue Watching's order, hiding watched titles, the billboard
/// paging by itself, trailers, hiding spoilers.
/// (The add-ons are Nuvio's, synced: under Nuvio → Sync.)
struct HomeContentSettingsDetail: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(BillboardAutoPage.key) private var billboardAutoPage = true
    @AppStorage(HomeHideWatched.key) private var hideWatched = false
    @AppStorage(DetailHideSpoilers.key) private var hideSpoilers = false
    @AppStorage(HomeRowSource.key) private var rowSource = HomeRowSource.current.rawValue

    var body: some View {
        let rows = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
        SettingsPage(title: SettingsCategory.homeContent.title) {
            SettingsSection {
                SettingsOptionsRow(
                    title: "Rows",
                    pageDescription: "Choose where Home's rows come from. Made for You builds them from what "
                        + "you watch and rate, new each day, with titles from TMDB. From Add-ons shows the "
                        + "catalogs of your add-ons, arranged in Home Rows.",
                    options: HomeRowSource.allCases.map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: rowSource
                ) { rowSource = $0 }

                // The second row is about the rows you have: Made for You's
                // reasons, or the add-ons' rows to arrange.
                if rowSource == HomeRowSource.madeForYou.rawValue {
                    SettingsLinkRow(
                        title: "Why These Rows",
                        description: "What Cue read from your watching, and why each row is on Home today."
                    ) { WhyTheseRowsPage() }
                } else {
                    SettingsLinkRow(
                        title: "Home Rows",
                        description: "Choose which rows show on Home, their order and their names.",
                        value: "\(rows.filter { $0.isShown(settings: settings) }.count)"
                    ) { HomeRowsPage() }
                }

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
private struct WhyTheseRowsPage: View {
    @State private var saved: CueRows.Saved?
    @State private var loaded = false

    private static let tabs = [("home", "Home"), ("movie", "Movies"), ("series", "Series")]

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
                SettingsSection {
                    Text("Not built yet. Open Home and Cue builds its rows.")
                        .font(.system(size: SettingsMetrics.descriptionTextSize))
                        .foregroundStyle(Color.white.opacity(FixedFocusText.body))
                        .padding(.horizontal, SettingsMetrics.rowInset)
                }
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
            .foregroundStyle(Color.white.opacity(FixedFocusText.body))
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
                    .foregroundStyle(Color.white.opacity(FixedFocusText.tertiary))
            }
        }
        .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
    }
}

/// What You Watch: your traits by kind, each a bar of its share of your
/// watching (against the largest), the share, and how many times more it
/// is in yours than in what's popular. Two columns of kinds.
private struct WhyTastePanel: View {
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
                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 120, height: 10)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(FixedFocusText.primary))
                        .frame(width: max(10, 120 * line.share / max(most, 0.0001)))
                }
            Text("\(Int((line.share * 100).rounded())) %")
                .font(.system(size: WhyPanel.textSize))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(FixedFocusText.body))
                .frame(width: 64, alignment: .trailing)
            Text(line.lift.map { $0 >= 1.5 ? String(format: "%.0f×", $0.rounded()) : "" } ?? "")
                .font(.system(size: WhyPanel.textSize))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(FixedFocusText.tertiary))
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
                            WhyThumbs(rating: rating)
                            Text(rating.name)
                                .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                            Text("\(names.count)")
                                .font(.system(size: SettingsMetrics.rowTextSize))
                                .foregroundStyle(Color.white.opacity(FixedFocusText.tertiary))
                        }
                        .padding(.bottom, 6)
                        ForEach(names, id: \.self) { name in
                            Text(name)
                                .font(.system(size: WhyPanel.textSize))
                                .foregroundStyle(Color.white.opacity(FixedFocusText.body))
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

/// The rating's thumbs, as its tile's: down, up, two up.
private struct WhyThumbs: View {
    let rating: TitleRatings.Rating

    var body: some View {
        let font = Font.system(size: 30, weight: .semibold)
        Group {
            switch rating {
            case .notForMe: Image(systemName: "hand.thumbsdown.fill").font(font)
            case .like: Image(systemName: "hand.thumbsup.fill").font(font)
            case .love:
                HStack(spacing: -10) {
                    Image(systemName: "hand.thumbsup.fill").font(font)
                    Image(systemName: "hand.thumbsup.fill").font(font).offset(y: -3)
                }
            }
        }
        .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
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
                        .foregroundStyle(Color.white.opacity(FixedFocusText.body))
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
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
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
                    .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                    .lineLimit(1)
                Text(facts)
                    .font(.system(size: WhyPanel.textSize))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.body))
                    .lineLimit(1)
                if let badge {
                    BadgeLabel(badge: .init(symbol: FixedFocusBadges.symbol(badge.kind), mark: nil, text: badge.text))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Rows

/// One of Home's rows, as the Rows page lists it: a catalog or a
/// collection (each its own row on Home).
private struct HomeRowEntry: Identifiable {
    let key: String
    let defaultTitle: String
    /// The add-on it comes from.
    let source: String
    var id: String { key }

    @MainActor
    func title(settings: HomeCatalogSettingsStore) -> String {
        settings.customTitle(for: key) ?? defaultTitle
    }

    @MainActor
    func isShown(settings: HomeCatalogSettingsStore) -> Bool { settings.isEnabled(key: key) }

    @MainActor
    static func collectionKeys(_ collections: CollectionsStore) -> [String] {
        collections.collections.map { HomeCatalogSettingsStore.collectionKey($0.id) }
    }

    /// Every catalog an add-on offers as a plain row (no required extras).
    @MainActor
    static func catalogKeys(_ addonManager: AddonManager) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
        return keys
    }

    /// The rows in Home's order.
    @MainActor
    static func all(addonManager: AddonManager, collections: CollectionsStore,
                    settings: HomeCatalogSettingsStore) -> [HomeRowEntry] {
        var byKey: [String: HomeRowEntry] = [:]
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                if byKey[key] == nil {
                    byKey[key] = HomeRowEntry(key: key, defaultTitle: catalog.displayName, source: addon.displayName)
                }
            }
        }
        for collection in collections.collections {
            let key = HomeCatalogSettingsStore.collectionKey(collection.id)
            byKey[key] = HomeRowEntry(key: key, defaultTitle: collection.title, source: "Collection")
        }
        var result: [HomeRowEntry] = []
        for key in settings.mergedOrder(catalogKeys: catalogKeys(addonManager),
                                        collectionKeys: collectionKeys(collections)) {
            if let entry = byKey[key] { result.append(entry) }
        }
        return result
    }
}

/// Settings → Home & Details → Home Rows: Home's rows in order, as the
/// add-ons': a row each (its name, where it comes from, "Off" when hidden),
/// lit whole; Select opens its page (`HomeRowPage`). Edit, on the title's
/// line, gives each row an on / off and the ≡ handle; Done or Back ends it.
/// (Tried: each one line with Rename, Move and a switch.)
private struct HomeRowsPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus
    @State private var editing = false
    @State private var moving: String?

    var body: some View {
        let rows = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
        SettingsPage(title: "Home Rows",
                     accessory: AnyView(accessory(hasRows: !rows.isEmpty))) {
            SettingsSection(spacing: SettingsMetrics.tallRowGap) {
                ForEach(rows) { row in
                    let shown = row.isShown(settings: settings)
                    SettingsReorderRow(
                        title: row.title(settings: settings), id: row.id,
                        value: shown ? row.source : "Off",
                        chevron: true,
                        dimmed: !shown,
                        toggle: SettingsEntrySwitch(isOn: shown, title: shown ? "Hide" : "Show") {
                            settings.setEnabled(!shown, key: row.key)
                        },
                        editing: editing, isMoving: moving == row.id, anyMoving: moving != nil,
                        onSelect: { nav.push(HomeRowPage(key: row.key)) },
                        onLift: { moving = row.id },
                        onMoveStep: { step in
                            settings.move(key: row.key, up: step < 0,
                                          within: HomeRowEntry.catalogKeys(addonManager)
                                              + HomeRowEntry.collectionKeys(collections))
                        },
                        onDrop: { moving = nil })
                }
            }
        }
        .onExitCommand(perform: editing && moving == nil ? endEditing : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    @ViewBuilder private func accessory(hasRows: Bool) -> some View {
        if editing {
            SettingsCapsuleButton(title: "Done", action: endEditing).disabled(moving != nil)
        } else if hasRows {
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

/// A Home row's own page: Rename (the keyboard; empty or the original: its
/// own name again), and where it comes from, to read.
private struct HomeRowPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    let key: String

    @State private var keyboard: KeyboardRequest?

    var body: some View {
        if let row = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
            .first(where: { $0.key == key }) {
            let name = row.title(settings: settings)
            SettingsPage(title: name) {
                SettingsSection {
                    SettingsButtonRow(title: "Rename", value: name) {
                        keyboard = KeyboardRequest(text: name, placeholder: row.defaultTitle) { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.setCustomTitle(trimmed == row.defaultTitle ? nil : trimmed, key: row.key)
                        }
                    }
                    SettingsInfoRow(title: "Source", value: row.source)
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
                VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
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
                VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
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
private struct AddonLogo: View {
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
