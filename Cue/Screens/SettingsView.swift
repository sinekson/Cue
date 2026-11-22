import SwiftUI

/// Settings categories, each a pushed pane on the Settings screen.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, tmdb, mdblist, appearance, homeContent, playback, storage, about, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Nuvio"
        case .tmdb: return "TMDB"
        case .mdblist: return "MDBList"
        case .appearance: return "Appearance"
        case .homeContent: return "Home & Details"
        case .playback: return "Playback"
        case .storage: return "Storage"
        case .about: return "About"
        case .developer: return "Developer"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Keeps your profiles, add-ons and watch progress in sync across your devices."
        case .tmdb: return ServiceKey.tmdb.about
        case .mdblist: return ServiceKey.mdblist.about
        case .appearance: return "Change how Cue's pages and cards look."
        case .homeContent: return "Choose what Home shows and how titles behave."
        case .playback: return "Choose the language titles play in."
        case .storage: return "See what Cue keeps on this Apple TV and clear it."
        case .about: return "See Cue's version, privacy and licenses."
        case .developer: return "Measure the frame rate, inspect playback and keep a log."
        }
    }

    /// Its symbol on Settings' tile, on its pages (the categories: the play).
    var symbol: String {
        switch self {
        case .account: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .tmdb: return "photo.badge.magnifyingglass"
        case .mdblist: return "hand.thumbsup"
        case .appearance: return "paintpalette"
        case .homeContent: return "rectangle.grid.3x1"
        case .playback: return "playpause"
        case .storage: return "internaldrive"
        case .about: return "info.circle"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The accounts and keys, in their own section up top.
    static let accounts: [SettingsCategory] = [.account, .tmdb, .mdblist]
}

struct SettingsCategoryPane: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .account:      AccountSettingsDetail()
        case .tmdb:         TMDBServicePage()
        case .mdblist:      MDBListServicePage()
        case .appearance:   AppearanceSettingsDetail()
        case .homeContent:  HomeContentSettingsDetail()
        case .playback:     PlaybackSettingsDetail()
        case .storage:      StorageSettingsDetail()
        case .about:        AboutDetail()
        case .developer:    DeveloperSettingsDetail()
        }
    }
}

// MARK: - Detail scaffolding

/// A rounded, accent-tinted tile holding an SF Symbol. Gives every settings row
/// a consistent, scannable icon "chip" (iOS-Settings style) — the core visual
/// motif of the redesigned panes.
struct SettingsIconTile: View {
    let symbol: String
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [CuePalette.secondary.opacity(0.32), CuePalette.secondary.opacity(0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(CuePalette.secondary.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
            )
            .frame(width: size, height: size)
    }
}

struct SettingsDetailHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: CueSpacing.md) {
                // Accent spine — a bold vertical bar that anchors the title and
                // sets the new, more editorial header rhythm.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CuePalette.secondary)
                    .frame(width: 6, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(CuePalette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 21))
                        .foregroundStyle(CuePalette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped settings section rendered as a rounded card (title + optional
/// subtitle + rows), matching the APK's `secondaryCardRadius` (18dp) groups.
struct SettingsGroupCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.sm) {
            // Section label sits ABOVE the card (grouped-list style) — the
            // accent-tinted, letter-spaced title reads as a real section break
            // instead of another boxed header stacked inside the card.
            if !title.isEmpty || (subtitle?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title.uppercased())
                            .font(.system(size: 18, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(CuePalette.secondary)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 19))
                            .foregroundStyle(CuePalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            }
            // The rows live in one shared surface; each row is flat until
            // focused, so the card groups them like a single list.
            VStack(spacing: 4) {
                content
            }
            .padding(CueSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CuePalette.backgroundCard.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    // Hairline reads mid-grey on dark; in ATV light mode that
                    // same grey is a heavy outline — use a soft dark line.
                    .strokeBorder(scheme == .light ? Color.black.opacity(0.10)
                                  : CuePrimitives.neutral750.opacity(0.55), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable settings row with strong focus, matching the Android SettingsActionRow.
struct SettingsActionRow: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let title: String
    var subtitle: String?
    var value: String?
    var leadingIcon: String?

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            if let leadingIcon {
                SettingsIconTile(symbol: leadingIcon)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(CuePalette.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(CuePalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            Spacer(minLength: CueSpacing.lg)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? CuePalette.textSecondary : CuePalette.textTertiary)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, CueSpacing.md)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
        // Was a spring, so one row type bounced while the value row directly
        // beneath it eased. One focus response for the whole app.
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

/// Shared row backdrop for the redesigned settings: transparent when idle so
/// rows read as one grouped list, and an accent-tinted, ringed highlight when
/// focused. No per-row scale — the fill/ring alone carries focus.
struct SettingsRowBackground: View {
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
            .fill(isFocused ? CuePalette.focusBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? CuePalette.focusRing : .clear, lineWidth: 3)
            )
    }
}

struct DetailScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: CueSpacing.xl) {
                SettingsDetailHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, CueSpacing.xs)
                content
            }
            .padding(.horizontal, CueSpacing.xl)
            .padding(.top, CueSpacing.lg)
            .padding(.bottom, CueSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Clips scrolled content to the pane so rows stay inside the workspace card.
    }
}

struct CueSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? CuePalette.secondary : Color.primary.opacity(0.18))
                .frame(width: 64, height: 36)
            Circle()
                // The knob has to read against TWO different tracks: the dark
                // off-track and the accent on-track. A hardcoded white knob
                // vanished on the White theme, whose accent track is white too
                // — the "toggles are invisible with the white colour" report.
                // `onSecondary` is the accent's own ink (dark on White), so the
                // knob contrasts when on; white is right for the dark off-track.
                .fill(isOn ? CuePalette.onSecondary : .white)
                .frame(width: 28, height: 28)
                .padding(4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
    }
}

/// Storage: what Cue keeps on this Apple TV — the cache and the search
/// history, each a page with what it holds and its clear — and the space
/// left. No confirmations.
struct StorageSettingsDetail: View {
    @EnvironmentObject private var search: SearchViewModel
    @State private var total: Int64?
    @State private var free: Int64?

    var body: some View {
        SettingsPage(title: SettingsCategory.storage.title,
                     subtitle: "What Cue keeps on this Apple TV.") {
            SettingsSection {
                SettingsLinkRow(title: "Cache", value: total.map(CachePage.size)) {
                    CachePage(measured: { total = $0 })
                }
                SettingsLinkRow(title: "Search History",
                                value: search.hasHistory ? nil : "Empty") { SearchHistoryPage() }
            }
            SettingsSection {
                SettingsInfoRows {
                    SettingsInfoRow(title: "Free on This Apple TV", value: free.map(CachePage.size) ?? "—")
                }
            }
        }
        .task {
            total = await CacheStorage.measure().reduce(0) { $0 + $1.bytes }
            free = CacheStorage.available()
        }
    }
}

/// Every cache by kind with its size and allowance, and one clear for all
/// of it (`CacheStorage`): everything here loads again as needed.
struct CachePage: View {
    /// The total, back to Storage's row.
    let measured: (Int64) -> Void
    @State private var parts: [CacheStorage.Part] = []
    @State private var done = false
    @State private var clearing = false

    var body: some View {
        SettingsPage(title: "Cache",
                     subtitle: "Cue keeps pictures and title details on this Apple TV so pages open at once. "
                        + "Clearing them is safe: they load again as needed.") {
            SettingsSection {
                SettingsButtonRow(title: "Clear Cache",
                                  description: "Removes everything below. Your account, profiles, progress, "
                                    + "library and settings stay.",
                                  value: clearing ? "Clearing…" : (done ? Self.size(total) : nil)) {
                    clear()
                }
            }
            SettingsSection(title: "Cache") {
                SettingsInfoRows {
                    ForEach(parts) { part in
                        SettingsInfoRow(title: part.name, value: Self.value(part))
                    }
                }
            }
        }
        .task { await measure() }
    }

    private var total: Int64 { parts.reduce(0) { $0 + $1.bytes } }

    private func measure() async {
        parts = await CacheStorage.measure()
        done = true
        measured(total)
    }

    private func clear() {
        guard !clearing else { return }
        clearing = true
        Task {
            await CacheStorage.clear()
            await measure()
            clearing = false
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private static func value(_ part: CacheStorage.Part) -> String {
        guard let limit = part.limit else { return size(part.bytes) }
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
        return part.bytes == 0 ? "Empty, up to \(limitText)" : "\(size(part.bytes)) of \(limitText)"
    }
}

/// This profile's recent searches (under Search's keyboard) and the titles
/// opened from Search (its row before you type), and one clear for both.
struct SearchHistoryPage: View {
    @EnvironmentObject private var search: SearchViewModel

    var body: some View {
        SettingsPage(title: "Search History",
                     subtitle: "What this profile searched for, and the titles it opened from Search.") {
            SettingsSection {
                SettingsButtonRow(title: "Clear Search History",
                                  description: "Removes the searches and titles below.",
                                  value: search.hasHistory ? nil : "Empty") {
                    search.clearHistory()
                }
            }
            if !search.recentSearches.isEmpty {
                SettingsSection(title: "Searches") {
                    SettingsInfoRows {
                        ForEach(search.recentSearches, id: \.self) { SettingsInfoRow(title: $0, value: "") }
                    }
                }
            }
            if !search.recentTitles.isEmpty {
                SettingsSection(title: "Titles") {
                    SettingsInfoRows {
                        ForEach(search.recentTitles, id: \.id) { item in
                            SettingsInfoRow(title: item.name,
                                            value: item.type == "movie" ? "Movie" : "Series")
                        }
                    }
                }
            }
        }
    }
}

/// About: what's behind Cue, then what's only to read. Pressing leads to
/// Privacy and Licenses & Credits, in the column.
struct AboutDetail: View {
    var body: some View {
        SettingsPage(title: SettingsCategory.about.title) {
            SettingsSection {
                SettingsLinkRow(title: "Privacy") { AboutPrivacyPage() }
                SettingsLinkRow(title: "Licenses & Credits") { AboutLicensesPage() }
                SettingsInfoRows {
                    SettingsInfoRow(title: "Version", value: DiagnosticsService.appVersion)
                    SettingsInfoRow(title: "Device", value: DiagnosticsService.deviceName)
                    SettingsInfoRow(title: "Software", value: DiagnosticsService.systemVersion)
                    SettingsInfoRow(title: "Source Code", value: DiagnosticsService.sourceAddress)
                }
                .padding(.top, SettingsMetrics.infoGap)
            }
        }
    }
}

/// Running text on a page of its own, lined up with the rows' text.
private struct AboutText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { SettingsNote(text) }
}

/// Only to read: focus stays on the page, unseen.
struct AboutPrivacyPage: View {
    var body: some View {
        SettingsPage(title: "Privacy") {
            SettingsSection {
                AboutText("Cue collects nothing about you and has no analytics or tracking.")
                AboutText("It talks only to the services it needs: Nuvio to sync your account, "
                    + "TMDB for search and details, MDBList for ratings if you add a key, the add-ons "
                    + "you installed for titles and sources, and YouTube for trailers.")
                AboutText("What those services receive is covered by their own privacy policies.")
            }
            .background(alignment: .top) { SettingsFocusHolder() }
        }
    }
}

struct AboutLicensesPage: View {
    var body: some View {
        SettingsPage(title: "Licenses & Credits") {
            SettingsSection {
                AboutText("Cue is free software under the GNU General Public License, version 3. "
                    + "Its source code is at \(DiagnosticsService.sourceAddress).")
            }
            .background(alignment: .top) { SettingsFocusHolder() }
            SettingsSection(title: "Built With") {
                SettingsInfoRows {
                    SettingsInfoRow(title: "AetherEngine", value: "LGPLv3")
                    SettingsInfoRow(title: "FFmpeg", value: "LGPLv2.1")
                    SettingsInfoRow(title: "libass", value: "ISC")
                    SettingsInfoRow(title: "Inter", value: "SIL OFL 1.1")
                    SettingsInfoRow(title: "FriBidi", value: "LGPLv2.1")
                    SettingsInfoRow(title: "HarfBuzz", value: "MIT")
                    SettingsInfoRow(title: "FreeType", value: "FTL")
                    SettingsInfoRow(title: "Fontconfig", value: "MIT")
                    SettingsInfoRow(title: "YouTubeKit", value: "MIT")
                    SettingsInfoRow(title: "libdovi", value: "MIT")
                }
            }
            SettingsSection {
                AboutText("This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }
        }
    }
}

// MARK: - Settings 2 (prototype, 2026-11-22)

/// SETTINGS 2 (prototype): Upcoming's language instead of Apple TV's
/// Settings, in two columns — the categories on the left (names only),
/// the focused one's settings on the right, headed by its name and what's
/// behind it; each section one flat card, its rows the name over a
/// description inside the row, a hairline between them, focus Upcoming's
/// white plate. Right goes in, Left and Back come out. Only Appearance has
/// settings so far.
struct CardSettingsRoot: View {
    let onBack: () -> Void
    @State private var shown = SettingsCategory.account
    @FocusState private var focused: String?
    /// The pages a link opened, in the right column.
    @StateObject private var nav = SettingsNav()
    /// Each open page's name, for the path over it.
    @State private var titles: [UUID: String] = [:]
    @State private var pageRows: [String] = []
    /// The last row focused in the settings, and the link each open page
    /// came from (Back lands on it).
    @State private var lastRow: String?
    @State private var cameFrom: [String?] = []
    /// The right column's first section has a label: it goes on the left's
    /// first label's line, else its card starts level with the left's.
    @State private var firstLabelled = false

    static let leftWidth: CGFloat = 480
    static let columnGap: CGFloat = 40
    static var rightWidth: CGFloat { 1920 - 2 * FixedFocusMetrics.inset - leftWidth - columnGap }
    private static let watching: [SettingsCategory] = [.homeContent, .playback, .appearance]
    private static let device: [SettingsCategory] = [.storage, .developer, .about]

    /// Focus is in the settings (not on a category).
    private var inSettings: Bool {
        if !nav.stack.isEmpty { return true }
        guard let focused else { return false }
        return SettingsCategory(rawValue: focused) == nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.columnGap) {
            // No column titles: the top bar says Settings, the grey row the
            // category; both columns start with their first label.
            VStack(alignment: .leading, spacing: 0) {
                CardSettingsMenu(groups: [("Accounts", SettingsCategory.accounts.map(categoryRow)),
                                          ("Watching", Self.watching.map(categoryRow)),
                                          ("This Apple TV", Self.device.map(categoryRow))],
                                 focused: $focused)
            }
            .frame(width: Self.leftWidth, alignment: .leading)
            .focusSection()
            VStack(alignment: .leading, spacing: 0) {
                if let page = nav.stack.last {
                    // A page opened from a row: where it is, on the first
                    // label's line, its own first label under it.
                    page.view
                        .environment(\.settingsPath, AnyView(path(page)))
                        .id(page.id)
                        .onPreferenceChange(SettingsPageHeaderKey.self) { header in
                            if let title = header?.title, !title.isEmpty { titles[page.id] = title }
                        }
                        .onPreferenceChange(SettingsRowsKey.self) { pageRows = $0 }
                        .onPreferenceChange(CardFirstLabelKey.self) { firstLabelled = $0 ?? false }
                } else {
                    // Its own scroll: a page taller than the screen (Home &
                    // Details) moved the whole layout as focus came to it.
                    ScrollView(.vertical) {
                        CardSettingsPages(category: shown, focused: $focused)
                            .padding(.top, firstLabelled ? 0 : CardSettingsSection.labelRoom)
                            .padding(.bottom, 60)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .settingsTopFade()
                    .onPreferenceChange(CardFirstLabelKey.self) { firstLabelled = $0 ?? false }
                }
            }
            .frame(width: Self.rightWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()
            .environmentObject(nav)
            .environment(\.settingsCards, true)
            .environment(\.settingsRowFocus, $focused)
        }
        .padding(.leading, FixedFocusMetrics.inset)
        .padding(.top, StagePictureView.homeCard.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        // Moving along the categories shows each one's settings.
        .onChange(of: focused) { _, now in
            guard let now else { return }
            if let category = SettingsCategory(rawValue: now) { shown = category } else { lastRow = now }
        }
        // A page opened: focus on its first row; Back: on the link again.
        .onChange(of: nav.stack.count) { old, new in
            if new > old {
                cameFrom.append(lastRow)
                pageRows = []
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    if let first = pageRows.first { focused = first }
                }
            } else if new < old {
                let back = cameFrom.popLast() ?? nil
                Task { @MainActor in focused = back }
            }
        }
        .onChange(of: shown) { _, _ in
            while nav.pop() {}
            cameFrom = []
        }
        .onExitCommand {
            if !nav.stack.isEmpty { nav.pop() }
            else if inSettings { focused = shown.rawValue }
            else { onBack() }
        }
    }

    /// A page's place, "Storage › Cache", in the cards' label style: the
    /// category and the pages before it quiet, its own name brighter.
    private func path(_ page: SettingsNav.Page) -> some View {
        let names = [shown.title] + nav.stack.map { titles[$0.id] ?? "" }.filter { !$0.isEmpty }
        let before = names.dropLast().map { $0 + "  ›  " }.joined()
        return (Text(before).foregroundStyle(CueInk.tertiary)
                + Text(names.last ?? "").foregroundStyle(CueInk.secondary))
            .font(.system(size: 24, weight: .semibold))
            .lineLimit(1)
            .padding(.leading, CardSettingsRow.textInset)
            .frame(height: CardSettingsSection.labelRoom - 12, alignment: .top)
            .padding(.bottom, 12)
    }

    /// A category: its name; the one shown on the selected grey while
    /// focus is in its settings, and the only one focus can come back to.
    private func categoryRow(_ category: SettingsCategory) -> CardSettingsRow {
        CardSettingsRow(id: category.rawValue, title: category.title,
                        selected: inSettings && shown == category,
                        reachable: !inSettings || shown == category, compact: true) {}
    }

}

/// One section of Settings 2: its label, then its rows on one card, a
/// hairline between two rows unless one of them has focus or is selected.
/// Whether a page's first section has a label (Settings 2's columns
/// line up by it).
struct CardFirstLabelKey: PreferenceKey {
    static let defaultValue: Bool? = nil
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
        if value == nil { value = nextValue() }
    }
}

struct CardSettingsSection: View {
    /// A label's room above its card.
    static let labelRoom: CGFloat = 42
    var label: String? = nil
    /// Below the card, to the next section.
    var gap: CGFloat = 40
    let rows: [CardSettingsRow]
    var focused: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(CueInk.tertiary)
                    .padding(.leading, CardSettingsRow.textInset)
                    .frame(height: Self.labelRoom - 12, alignment: .top)
                    .padding(.bottom, 12)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        let quiet = [row, rows[index - 1]].contains { focused.wrappedValue == $0.id || $0.selected }
                        Rectangle()
                            .fill(CueInk.color(0.10))
                            .frame(height: 1)
                            .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
                            .padding(.vertical, 5)
                            .opacity(quiet ? 0 : 1)
                    }
                    row.focused(focused, equals: row.id)
                }
            }
            .padding(CardSettingsRow.cardPadding)
            .background(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
                .fill(CardFocusPlate.cardFill))
        }
        .padding(.bottom, gap)
        .preference(key: CardFirstLabelKey.self, value: label != nil)
    }
}

/// Settings 2's categories: three groups of three, each its own card
/// under its label as the settings' sections (Sync), the rows compact:
/// all of it in view, no scrolling.
struct CardSettingsMenu: View {
    let groups: [(label: String, rows: [CardSettingsRow])]
    var focused: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                CardSettingsSection(label: group.label, gap: 24, rows: group.rows, focused: focused)
            }
        }
    }
}

/// Settings 2's rows' helpers: the next of a list of choices (Select on a
/// choice steps through them), On / Off.
enum CardSettings {
    static func next<T: Equatable>(_ all: [T], after current: T) -> T {
        all[((all.firstIndex(of: current) ?? -1) + 1) % all.count]
    }
    static func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
}

/// Each category's settings in Settings 2; a link opens its page (the
/// old Settings' own, drawn in this look) in the same column.
struct CardSettingsPages: View {
    let category: SettingsCategory
    var focused: FocusState<String?>.Binding

    var body: some View {
        switch category {
        case .account: CardNuvioPage(focused: focused)
        case .tmdb: CardTMDBPage(focused: focused)
        case .mdblist: CardMDBListPage(focused: focused)
        case .appearance: CardAppearancePage(focused: focused)
        case .homeContent: CardHomePage(focused: focused)
        case .playback: CardPlaybackPage(focused: focused)
        case .storage: CardStoragePage(focused: focused)
        case .about: CardAboutPage(focused: focused)
        case .developer: CardDeveloperPage(focused: focused)
        }
    }
}

private struct CardNuvioPage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var nav: SettingsNav
    /// The sign-in screen open: by code, or straight to email.
    @State private var signingIn: SignInWay?
    @State private var confirmSignOut = false
    /// Profiles: adding one (the guided steps), unlocking one to switch.
    @State private var addingProfile = false
    @State private var unlocking: UserProfile?

    private enum SignInWay: String, Identifiable {
        case phone, email
        var id: String { rawValue }
    }
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var profiles: ProfileStore

    var body: some View {
        if case .signedIn(_, let email) = account.authState {
            VStack(alignment: .leading, spacing: 40) {
                SettingsSection(title: "Account") {
                    // The account: its email, Sign Out on the row (confirmed).
                    ActionListRow(
                        id: "n.account",
                        title: "Account",
                        detail: (email.isEmpty ? "Nuvio account" : email) + " · " + syncState,
                        actions: [
                            SettingsAction(title: "Sync Now", icon: "arrow.triangle.2.circlepath") {
                                Task { await NuvioSyncManager.shared?.syncNow() }
                            },
                            SettingsAction(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right",
                                           danger: true, nudge: 2) { confirmSignOut = true },
                        ],
                        columnFocus: true)
                }
                // The same card and gap as every section (the menu's own
                // card, with its label room, sat further from Profiles).
                SettingsSection(title: "Sync") {
                    syncRow("n.addons", "Add-ons", addons.addons.count) { nav.push(AddonsCardPage()) }
                    syncRow("n.progress", "Watch Progress", progress.items.count) { nav.push(WatchProgressCardPage()) }
                    syncRow("n.library", "Library", library.items.count) { nav.push(LibraryCardPage()) }
                    syncRow("n.watched", "Watched", watched.items.count) { nav.push(WatchedCardPage()) }
                }
                // Every profile on the page: Switch (not the active one) and
                // Edit (its one page) on its row; Add Profile after them.
                SettingsSection(title: "Profiles · \(profiles.profiles.count) of \(ProfileStore.maxProfiles)") {
                    ForEach(profiles.profiles) { profile in
                        let active = profile.id == profiles.activeProfileID
                        ActionListRow(
                            id: "n.profile.\(profile.id)",
                            leading: AnyView(ProfileAvatarView(profile: profile, size: 56)),
                            title: profile.name,
                            detail: Self.profileDetail(profiles.notes(for: profile), pin: profile.pinEnabled),
                            actions: (active ? [] : [
                                SettingsAction(title: "Switch to \(profile.name)", icon: "arrow.right.circle",
                                               key: "switch") {
                                    if profile.pinEnabled { unlocking = profile } else { profiles.setActive(profile.id) }
                                },
                            ]) + [
                                SettingsAction(title: "Edit", icon: "pencil", key: "edit") {
                                    nav.push(ProfileEditPage(profileID: profile.id))
                                },
                            ],
                            columnFocus: true)
                    }
                    if profiles.canAddProfile {
                        SettingsButtonRow(title: "Add Profile") { addingProfile = true }
                    }
                }
                .fullScreenCover(isPresented: $addingProfile) {
                    ProfileSetup(onFinish: { created in
                        addingProfile = false
                        nav.push(ProfileEditPage(profileID: created.id))
                    }, onCancel: { addingProfile = false })
                    .environmentObject(profiles)
                }
                .fullScreenCover(item: $unlocking) { profile in
                    ProfilePinCheck(profile: profile) {
                        unlocking = nil
                        profiles.setActive(profile.id)
                    } onCancel: { unlocking = nil }
                }
                .alert("Sign out?", isPresented: $confirmSignOut) {
                    Button("Sign out", role: .destructive) { account.signOut() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your watch progress, library and add-ons stay on this TV, but they'll stop syncing until you sign in again.")
                }
            }
        } else {
            SettingsSection(title: "Account") {
                // Signed out: the two ways in, on the row.
                ActionListRow(
                    id: "n.signin",
                    title: "Account",
                    detail: "Not signed in",
                    actions: [
                        SettingsAction(title: "Sign In with Phone", icon: "qrcode") { signingIn = .phone },
                        SettingsAction(title: "Sign In with Email", icon: "envelope") { signingIn = .email },
                    ],
                    columnFocus: true)
            }
            .fullScreenCover(item: $signingIn) { way in
                NuvioSignInView(account: account, onSignedIn: { signingIn = nil },
                                emailOnly: way == .email, onClose: { signingIn = nil })
                    .onExitCommand { signingIn = nil }
            }
        }
    }

    /// "Primary, Active · PIN"; neither: "Profile".
    private func syncRow(_ id: String, _ title: String, _ count: Int, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            SettingsRowLabel(title: title, value: count.formatted(), chevron: true)
        }
        .settingsRow(id: id)
    }

    static func profileDetail(_ notes: String, pin: Bool) -> String {
        let parts = [notes.isEmpty ? nil : notes, pin ? "PIN" : nil].compactMap { $0 }
        return parts.isEmpty ? "Profile" : parts.joined(separator: " · ")
    }

    private var syncState: String {
        guard let sync = NuvioSyncManager.shared else { return "—" }
        if sync.isSyncing { return "Syncing…" }
        if sync.lastSyncError != nil { return "Sync failed" }
        guard let last = sync.lastSyncedAt else { return "Not synced yet" }
        return "Synced " + DateFormatter.settingsWhen.string(from: last)
    }
}

private struct CardTMDBPage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var tmdb: TMDBSettingsStore

    var body: some View {
        let key = tmdb.settings.trimmedAPIKey
        VStack(alignment: .leading, spacing: 40) {
            SettingsSection(title: "Connection") {
                ServiceKeyActionRow(service: .tmdb, key: key) { tmdb.setAPIKey($0) }
                if key.isEmpty { SettingsNote(ServiceKey.tmdb.howTo) }
            }
            SettingsSection(title: "Language") {
                SettingsOptionsRow(
                    title: "Language",
                    description: "Titles, taglines and descriptions in this language where TMDB has it.",
                    options: TMDBLanguages.options.map { SettingsOption(id: $0, label: TMDBLanguages.displayName($0)) },
                    selection: tmdb.settings.language
                ) { tmdb.settings.language = $0 }
            }
        }
    }
}

private struct CardMDBListPage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @ObservedObject private var usage = MDBListUsage.shared
    @State private var moving: MDBListProvider?

    var body: some View {
        let key = mdblist.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = mdblist.settings.orderedProviders
        VStack(alignment: .leading, spacing: 40) {
            // The key on its row; what MDBList last said of the account
            // under it, only to read (its Usage page is gone).
            SettingsSection(title: "Connection") {
                ServiceKeyActionRow(service: .mdblist, key: key) { new in
                    mdblist.settings.apiKey = new
                    // Kept true for older Cue versions, which still read it.
                    mdblist.settings.enabled = !new.isEmpty
                }
                if key.isEmpty {
                    SettingsNote(ServiceKey.mdblist.howTo)
                } else {
                    if let account = usage.account, !account.plan.isEmpty {
                        SettingsInfoRow(title: "Plan", value: account.username.isEmpty
                                        ? account.plan : "\(account.username) · \(account.plan)")
                    }
                    if let snapshot = usage.snapshot {
                        SettingsInfoRow(title: "Requests Today", value: snapshot.requestsToday)
                    }
                }
            }
            SettingsSection(title: "Ratings") {
                SettingsChoiceRow(
                    id: "m.place", title: "Show Ratings",
                    description: "Everywhere, on Details only, or nowhere.",
                    options: RatingsPlace.allCases.reversed().map { SettingsOption(id: $0.rawValue, label: $0.label) },
                    selection: mdblist.settings.place.rawValue
                ) { mdblist.settings.place = RatingsPlace(rawValue: $0) ?? .everywhere }
            }
            // The sources in order, each its row: the first three show on
            // titles, the rest stand in; Move on each.
            SettingsSection(title: "Rating Providers") {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    ActionListRow(
                        id: "m.p.\(provider.id)",
                        leading: AnyView(RatingMark(provider: provider).frame(height: 24)),
                        title: provider.fullName,
                        detail: index < FixedFocusBillboardText.ratingsShown ? "Shown on titles"
                            : "Stands in when one is missing",
                        actions: [SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true) {
                            moving = provider
                        }],
                        columnFocus: true,
                        moving: moving == provider,
                        anyMoving: moving != nil,
                        onMoveStep: { mdblist.settings.move(provider, by: $0) },
                        onDrop: { moving = nil })
                }
            }
        }
        .onChange(of: moving) { _, now in TopBarLock.shared.locked = now != nil }
    }
}

private struct CardAppearancePage: View {
    var focused: FocusState<String?>.Binding
    @AppStorage(FixedFocusRing.outlinesKey) private var outlines = FixedFocusRing.outlines.rawValue
    @AppStorage(SourceCardStyle.key) private var sourceCards = SourceCardStyle.current.rawValue
    @AppStorage(BackgroundPicks.AtLaunch.key) private var atLaunch = BackgroundPicks.AtLaunch.home.rawValue
    @ObservedObject private var background = BackgroundStore.shared
    /// Saved ones removed here, not yet sent (undone with a second press).
    @State private var pending: Set<String> = []

    var body: some View {
        let outline = FixedFocusRing.Outlines(rawValue: outlines) ?? .high
        let source = SourceCardStyle(rawValue: sourceCards) ?? .current
        VStack(alignment: .leading, spacing: 40) {
            SettingsSection(title: "Background") {
                current
                SettingsChoiceRow(
                    id: "a.launch", title: "Change at Launch",
                    description: "What each launch brings.",
                    options: BackgroundPicks.AtLaunch.allCases.reversed()
                        .filter { $0 != .saved || !background.saved.isEmpty }
                        .map { SettingsOption(id: $0.rawValue, label: $0.label, detail: Self.launchDetail($0)) },
                    selection: atLaunch
                ) { atLaunch = $0 }
            }
            SettingsSection(title: "Look") {
                SettingsChoiceRow(
                    id: "a.outlines", title: "Card Outlines",
                    description: "How cards are framed, at rest and in focus.",
                    options: [
                        SettingsOption(id: FixedFocusRing.Outlines.off.rawValue, label: "Off",
                                       detail: "No edges: the pictures alone."),
                        SettingsOption(id: FixedFocusRing.Outlines.low.rawValue, label: "Edges Only",
                                       detail: "A thin edge on every card, none brighter."),
                        SettingsOption(id: FixedFocusRing.Outlines.high.rawValue, label: "Edges and Focus",
                                       detail: "A thin edge on every card, a bright one in focus."),
                    ],
                    selection: outline.rawValue
                ) { id in
                    let next = FixedFocusRing.Outlines(rawValue: id) ?? .high
                    FixedFocusRing.outlines = next
                    outlines = next.rawValue
                }
                SettingsChoiceRow(
                    id: "a.sources", title: "Source Cards",
                    description: "How links read when you pick a source.",
                    options: [
                        SettingsOption(id: SourceCardStyle.raw.rawValue, label: "Raw",
                                       detail: "The add-on's own text, as it sends it."),
                        SettingsOption(id: SourceCardStyle.styled.rawValue, label: "Styled",
                                       detail: "Quality, size and audio, read from the file name."),
                    ],
                    selection: source.rawValue
                ) { sourceCards = $0 }
            }
            if !background.saved.isEmpty {
                SettingsSection(title: "Saved · \(background.saved.count - pending.count) of \(BackgroundPicks.savedLimit)") {
                    ForEach(background.saved, id: \.id) { entry in
                        saved(entry)
                    }
                }
            }
        }
        .onDisappear { commit() }
    }

    /// The one up: its colours, how it came; Shuffle and Save on the row.
    @ViewBuilder private var current: some View {
        let shown = background.shown
        let isSaved = shown.map { background.isSaved($0.id) && !pending.contains($0.id) } ?? false
        ActionListRow(
            id: "a.background",
            leading: AnyView(BackgroundColours(entry: shown)),
            leadingSize: BackgroundColours.size,
            title: shown?.name ?? "Grey",
            detail: reason,
            actions: [
                SettingsAction(title: "Shuffle", icon: "shuffle", key: "shuffle") { background.another() },
            ] + (shown == nil ? [] : [
                SettingsAction(title: isSaved ? "Saved" : "Save", icon: isSaved ? "bookmark.fill" : "bookmark",
                               key: "save") {
                    if let id = shown?.id, pending.contains(id) { pending.remove(id) } else { background.toggleSaved() }
                },
            ]),
            columnFocus: true)
    }

    /// A saved one: Use (unless it's up), Remove (undo in place).
    private func saved(_ entry: BackgroundPicks.Entry) -> some View {
        let gone = pending.contains(entry.id)
        let up = background.shown?.id == entry.id
        return ActionListRow(
            id: "a.saved.\(entry.id)",
            leading: AnyView(BackgroundColours(entry: entry)),
            leadingSize: BackgroundColours.size,
            title: entry.name,
            // The one up is told by its checkmark: no line under the names.
            detail: "",
            dimmed: gone,
            // Use stays on the one up, a checkmark (one key both ways: focus
            // stays on it as it turns).
            actions: (gone ? [] : [
                SettingsAction(title: up ? "In Use" : "Use", icon: up ? "checkmark" : "paintbrush", key: "use") {
                    if !up { background.set(entry) }
                },
            ]) + [
                gone
                    ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { pending.remove(entry.id) }
                    : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { pending.insert(entry.id) },
            ])
    }

    private func commit() {
        for id in pending { background.unsave(id) }
        pending = []
    }

    private var reason: String {
        guard background.shown != nil else { return "Until a title is picked" }
        switch background.source {
        case .home: return "From Home"
        case .saved: return "From Saved"
        case .chosen: return "Chosen by you"
        }
    }

    private static func launchDetail(_ choice: BackgroundPicks.AtLaunch) -> String {
        switch choice {
        case .home: "A title on Home, a new one each launch."
        case .saved: "One of your saved ones, never twice running."
        case .never: "The one up now stays."
        }
    }
}

private struct CardHomePage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var nav: SettingsNav
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @ObservedObject private var pins = DiscoverPins.shared
    @AppStorage(BillboardAutoPage.key) private var billboardAutoPage = true
    @AppStorage(HomeHideWatched.key) private var hideWatched = false
    @AppStorage(DetailHideSpoilers.key) private var hideSpoilers = false
    /// Your rows: the one lifted, the ones removed here (undo in place).
    @State private var moving: String?
    @State private var pending: Set<String> = []
    @State private var keyboard: KeyboardRequest?

    var body: some View {
        let trailers = !settings.heroTrailersEnabled ? "off" : settings.heroTrailerSound ? "sound" : "silent"
        VStack(alignment: .leading, spacing: 40) {
            SettingsSection(title: "Rows") {
                Button { nav.push(WhyTheseRowsPage()) } label: {
                    SettingsRowLabel(title: "Why These Rows", chevron: true,
                                     description: "What Cue read from your watching, and why each row is on Home.")
                }
                .settingsRow(id: "h.why")
                SettingsChoiceRow(
                    id: "h.order", title: "Continue Watching Order",
                    options: [
                        SettingsOption(id: ContinueWatchingSortMode.recentlyWatched.rawValue, label: "Last Watched",
                                       detail: "What you watched last comes first."),
                        SettingsOption(id: ContinueWatchingSortMode.streamingStyle.rawValue, label: "In Progress First",
                                       detail: "Started titles first, next episodes after."),
                    ],
                    selection: settings.continueWatchingSortMode.rawValue
                ) { settings.continueWatchingSortMode = ContinueWatchingSortMode(rawValue: $0) ?? .recentlyWatched }
                SettingsOnOffRow(id: "h.hide", title: "Hide Watched Titles",
                                 description: "Watched films and finished shows stay out of the rows.",
                                 isOn: hideWatched) { hideWatched = $0 }
            }
            SettingsSection(title: "Billboard & Details") {
                SettingsOnOffRow(id: "h.advance", title: "Auto-Advance Billboard",
                                 description: "The next title every \(Int(BillboardAutoPage.interval)) seconds.",
                                 isOn: billboardAutoPage) { billboardAutoPage = $0 }
                SettingsChoiceRow(
                    id: "h.trailers", title: "Trailers",
                    options: [
                        SettingsOption(id: "off", label: "Off", detail: "The pictures stay still."),
                        SettingsOption(id: "silent", label: "Silent",
                                       detail: "Trailers play when you rest, muted."),
                        SettingsOption(id: "sound", label: "With Sound",
                                       detail: "Trailers play when you rest, with sound."),
                    ],
                    selection: trailers
                ) { pick in
                    settings.heroTrailersEnabled = pick != "off"
                    if pick != "off" { settings.heroTrailerSound = pick == "sound" }
                }
                SettingsOnOffRow(id: "h.spoilers", title: "Hide Spoilers",
                                 description: "Blurs the pictures of episodes you haven't watched.",
                                 isOn: hideSpoilers) { hideSpoilers = $0 }
            }
            yourRows
        }
        .onDisappear { commit() }
        .onChange(of: moving) { _, now in TopBarLock.shared.locked = now != nil }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
    }

    /// Sentences from Discover on Home, in their order: Open in Discover,
    /// Move, Rename, Remove (undo in place). Last on the page: it grows.
    @ViewBuilder private var yourRows: some View {
        let rows = pins.all
        let label = "Your Rows · \(rows.count - pending.count) of \(DiscoverPins.limit)"
        if rows.isEmpty {
            SettingsSection(title: label) {
                SettingsNote("None yet. In Discover, Add to Home puts a sentence on Home.")
            }
        } else {
            SettingsSection(title: label) {
                ForEach(rows, id: \.id) { pin in
                    let gone = pending.contains(pin.id)
                    let name = pin.rowName
                    ActionListRow(
                        id: "h.pin.\(pin.id)",
                        title: name,
                        detail: DiscoverPins.titleCase(pin.name) == name ? "" : pin.name,
                        dimmed: gone,
                        actions: actions(pin, name: name, gone: gone, count: rows.count),
                        moving: moving == pin.id,
                        anyMoving: moving != nil,
                        onMoveStep: { pins.move(pin.id, by: $0) },
                        onDrop: { moving = nil })
                }
            }
        }
    }

    private func actions(_ pin: DiscoverPins.Pin, name: String, gone: Bool, count: Int) -> [SettingsAction] {
        var list: [SettingsAction] = []
        if !gone {
            list.append(SettingsAction(title: "Open in Discover", icon: "safari", key: "open") { pins.opening = pin })
            if count > 1 {
                list.append(SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true, key: "move") {
                    moving = pin.id
                })
            }
            list.append(SettingsAction(title: "Rename", icon: "pencil", key: "rename") {
                keyboard = KeyboardRequest(text: name, placeholder: DiscoverPins.titleCase(pin.name)) {
                    pins.rename(pin.id, to: $0)
                }
            })
        }
        list.append(gone
            ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { pending.remove(pin.id) }
            : SettingsAction(title: "Remove from Home", icon: "trash", danger: true, key: "remove") {
                pending.insert(pin.id)
            })
        return list
    }

    private func commit() {
        for id in pending { pins.remove(id) }
        pending = []
        TopBarLock.shared.locked = false
    }
}

private struct CardPlaybackPage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var nav: SettingsNav
    @EnvironmentObject private var store: PlayerSettingsStore

    var body: some View {
        let settings = store.settings
        let language = settings.language.isEmpty ? "Device Language"
            : PlayerSettings.languages(including: settings.language).first { $0.code == settings.language }?.name
                ?? settings.language
        // Everything else is chosen in the player.
        SettingsSection(title: "Languages") {
            // Many languages: their own page.
            Button {
                nav.push(SettingsOptionsPage(
                    title: "Language", subtitle: "For audio and subtitles. A track you pick in the player is kept.",
                    options: [SettingsOption(id: "", label: "Device Language")]
                        + PlayerSettings.languages(including: settings.language)
                            .map { SettingsOption(id: $0.code, label: $0.name) },
                    selection: settings.language) { store.settings.language = $0 })
            } label: {
                SettingsRowLabel(title: "Language", value: language, chevron: true,
                                 description: "For audio and subtitles. A track you pick in the player is kept.")
            }
            .settingsRow(id: "p.language")
            SettingsChoiceRow(
                id: "p.original", title: "Original Audio",
                options: [
                    SettingsOption(id: PlayerSettings.OriginalAudio.off.rawValue, label: "Off",
                                   detail: "Audio in your language where there is some."),
                    SettingsOption(id: PlayerSettings.OriginalAudio.anime.rawValue, label: "Anime",
                                   detail: "Anime in Japanese, the rest in your language."),
                    SettingsOption(id: PlayerSettings.OriginalAudio.all.rawValue, label: "All Titles",
                                   detail: "Every title in the language it was made in."),
                ],
                selection: settings.originalAudio.rawValue
            ) { store.settings.originalAudio = PlayerSettings.OriginalAudio(rawValue: $0) ?? .off }
            SettingsChoiceRow(
                id: "p.subtitles", title: "Subtitles",
                options: [
                    SettingsOption(id: PlayerSettings.Subtitles.off.rawValue, label: "Off",
                                   detail: "None until you turn them on in the player."),
                    SettingsOption(id: PlayerSettings.Subtitles.auto.rawValue, label: "Auto",
                                   detail: "When the audio isn't your language; else only forced ones."),
                    SettingsOption(id: PlayerSettings.Subtitles.always.rawValue, label: "Always",
                                   detail: "In your language, whatever the audio."),
                ],
                selection: settings.subtitles.rawValue
            ) { store.settings.subtitles = PlayerSettings.Subtitles(rawValue: $0) ?? .auto }
        }
    }
}

/// Storage (every bin red, as everywhere): a row each for the cache and the search history, its summary
/// and Clear on it, its page one press away (list.bullet, as Watched's
/// Episodes); then what's free.
private struct CardStoragePage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var nav: SettingsNav
    @EnvironmentObject private var search: SearchViewModel
    @ObservedObject private var cache = CacheMeter.shared

    var body: some View {
        SettingsSection(title: "Storage") {
            ActionListRow(
                id: "s.cache",
                title: "Cache",
                detail: cache.summary(" · Loads again as needed"),
                actions: [
                    SettingsAction(title: "Show Cache", icon: "list.bullet", key: "more") {
                        nav.push(CacheCardPage())
                    },
                    SettingsAction(title: "Clear Cache", icon: "trash", danger: true, key: "clear") { cache.clear() },
                ],
                columnFocus: true)
            ActionListRow(
                id: "s.search",
                title: "Search History",
                detail: Self.historyDetail(search),
                actions: search.hasHistory ? [
                    SettingsAction(title: "Show Search History", icon: "list.bullet", key: "more") {
                        nav.push(SearchHistoryCardPage())
                    },
                    SettingsAction(title: "Clear Search History", icon: "trash", danger: true, key: "clear") {
                        search.clearHistory()
                    },
                ] : [],
                columnFocus: true)
            SettingsInfoRow(title: "Free on This Apple TV", value: cache.free.map(CachePage.size) ?? "—")
        }
        .task { await cache.measure() }
    }

    static func historyDetail(_ search: SearchViewModel) -> String {
        let searches = search.recentSearches.count, titles = search.recentTitles.count
        guard searches + titles > 0 else { return "Empty" }
        return [searches > 0 ? (searches == 1 ? "1 search" : "\(searches) searches") : nil,
                titles > 0 ? (titles == 1 ? "1 title" : "\(titles) titles") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The cache's kinds and what's free, measured for Storage and its Cache
/// page alike (the page replaces Storage in the column).
@MainActor
private final class CacheMeter: ObservableObject {
    static let shared = CacheMeter()
    @Published private(set) var parts: [CacheStorage.Part]?
    @Published private(set) var free: Int64?
    @Published private(set) var clearing = false

    func measure() async {
        parts = await CacheStorage.measure()
        free = CacheStorage.available()
    }

    func clear() {
        guard !clearing else { return }
        clearing = true
        Task {
            await CacheStorage.clear()
            await measure()
            clearing = false
        }
    }

    func summary(_ tail: String) -> String {
        if clearing { return "Clearing…" }
        guard let parts else { return "Measuring…" }
        return CachePage.size(parts.reduce(0) { $0 + $1.bytes }) + tail
    }
}

/// Every cache by kind, its size and allowance, to read; Clear on top.
private struct CacheCardPage: View {
    @ObservedObject private var cache = CacheMeter.shared

    var body: some View {
        SettingsPage(title: "Cache") {
            SettingsSection {
                ActionListRow(
                    id: "c.all",
                    title: "Cache",
                    detail: cache.summary(" · Your account and settings stay"),
                    actions: [SettingsAction(title: "Clear Cache", icon: "trash", danger: true, key: "clear") { cache.clear() }])
                ForEach(cache.parts ?? []) { part in
                    SettingsInfoRow(title: part.name, value: Self.value(part))
                }
            }
        }
    }

    private static func value(_ part: CacheStorage.Part) -> String {
        guard let limit = part.limit else { return CachePage.size(part.bytes) }
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
        return part.bytes == 0 ? "Empty, up to \(limitText)" : "\(CachePage.size(part.bytes)) of \(limitText)"
    }
}

/// This profile's recent searches and the titles opened from Search: a
/// row each, Remove (undo in place), the titles Open too.
private struct SearchHistoryCardPage: View {
    @EnvironmentObject private var search: SearchViewModel
    @Environment(\.settingsOpenTitle) private var openTitle
    @FocusState private var focus: String?
    /// Removed here, not yet sent.
    @State private var pending: Set<String> = []

    var body: some View {
        SettingsPage(title: "Search History") {
            if !search.hasHistory {
                SettingsNote("Nothing yet.")
            }
            if !search.recentSearches.isEmpty {
                SettingsSection(title: "Recent Searches") {
                    ForEach(search.recentSearches, id: \.self) { query in
                        let key = "q." + query
                        let gone = pending.contains(key)
                        ActionListRow(id: key, title: query, detail: "", dimmed: gone,
                                      actions: [remove(key, gone: gone)], focus: $focus)
                    }
                }
            }
            if !search.recentTitles.isEmpty {
                SettingsSection(title: "Opened from Search") {
                    ForEach(search.recentTitles, id: \.id) { item in
                        let key = "t." + item.id
                        let gone = pending.contains(key)
                        ActionListRow(
                            id: key,
                            leading: AnyView(Poster(url: item.poster)),
                            leadingSize: CGSize(width: 44, height: 66),
                            title: item.name,
                            detail: gone ? "Removed" : item.type == "movie" ? "Movie" : "Series",
                            dimmed: gone,
                            actions: (gone || openTitle == nil ? [] : [
                                SettingsAction(title: "Open", icon: "info.circle", key: "open") { openTitle?(item) },
                            ]) + [remove(key, gone: gone)],
                            focus: $focus)
                    }
                }
            }
        }
        .onDisappear { commit() }
    }

    private func remove(_ key: String, gone: Bool) -> SettingsAction {
        gone
            ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { pending.remove(key) }
            : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { pending.insert(key) }
    }

    private func commit() {
        for key in pending {
            if key.hasPrefix("q.") { search.forgetSearch(String(key.dropFirst(2))) }
            else { search.forgetTitle(String(key.dropFirst(2))) }
        }
        pending = []
    }

    private struct Poster: View {
        let url: String?
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            RemoteImage(url: url, maxDimension: 66, fallback: AnyView(Color.white.opacity(0.08)))
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 1) }
        }
    }
}

private struct CardAboutPage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            SettingsSection(title: "Cue") {
                SettingsInfoRow(title: "Version", value: DiagnosticsService.appVersion)
                SettingsInfoRow(title: "Source Code", value: DiagnosticsService.sourceAddress)
            }
            SettingsSection(title: "This Apple TV") {
                SettingsInfoRow(title: "Device", value: DiagnosticsService.deviceName)
                SettingsInfoRow(title: "Software", value: DiagnosticsService.systemVersion)
            }
            // The only rows to press: last, as the lists.
            SettingsSection(title: "Legal") {
                Button { nav.push(AboutPrivacyPage()) } label: {
                    SettingsRowLabel(title: "Privacy", chevron: true,
                                     description: "Cue collects nothing about you.")
                }
                .settingsRow(id: "b.privacy")
                Button { nav.push(AboutLicensesPage()) } label: {
                    SettingsRowLabel(title: "Licenses & Credits", chevron: true,
                                     description: "Free software under the GPLv3, and what it's built with.")
                }
                .settingsRow(id: "b.licenses")
            }
        }
    }
}

private struct CardDeveloperPage: View {
    var focused: FocusState<String?>.Binding
    @EnvironmentObject private var nav: SettingsNav
    @State private var sessions: [CueLog.Session]?
    @ObservedObject private var store = PerformanceSettingsStore.shared
    @State private var logOn = ProbeGate.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            SettingsSection(title: "Overlays") {
                SettingsChoiceRow(
                    id: "d.fps", title: "Frame Rate",
                    options: [
                        SettingsOption(id: "off", label: "Off", detail: "No counter."),
                        SettingsOption(id: "compact", label: "Compact", detail: "Frames per second, top right."),
                        SettingsOption(id: "full", label: "Full", detail: "Adds frame times, CPU and memory."),
                    ],
                    selection: store.settings.frameRate.rawValue
                ) { store.settings.frameRate = PerformanceSettingsStore.FrameRate(rawValue: $0) ?? .off }
                SettingsOnOffRow(id: "d.hud", title: "Playback HUD",
                                 description: "Live numbers over the video: decoding, drops, bitrate.",
                                 isOn: store.settings.showPlaybackHUD) { store.settings.showPlaybackHUD = $0 }
            }
            SettingsSection(title: "Log") {
                SettingsOnOffRow(id: "d.log", title: "Log",
                                 description: "What the app does, to a file here, a week at most.",
                                 isOn: logOn) { logOn = $0; ProbeGate.store($0) }
                Button { nav.push(LogSessionsPage(sessions: $sessions)) } label: {
                    SettingsRowLabel(title: "Sessions", chevron: true)
                }
                .settingsRow(id: "d.sessions")
                if logOn, let address = LogServer.address {
                    SettingsInfoRow(title: "Address", value: address)
                }
            }
        }
        .task { sessions = await CueLog.sessions() }
    }
}

/// A row: its name over its description (where it says something), the
/// value and chevron at the right on the name's line; focused, Upcoming's
/// white plate, dark words.
struct CardSettingsRow: View {
    let id: String
    let title: String
    var description: String? = nil
    var value: String? = nil
    var chevron = false
    /// The category shown beside it (focus in its settings): the selected grey.
    var selected = false
    var reachable = true
    /// Shorter (the categories: all in view).
    var compact = false
    let action: () -> Void

    /// A focus plate from the card's edge: its corners concentric with the
    /// card's (22 − 6 = 16).
    static let plateInset: CGFloat = 6
    /// A plate past its row, above and below: half the gap between two
    /// rows, so it covers the hairlines beside it.
    static let plateBleed: CGFloat = 6
    /// A card's padding round its rows: the plates' inset, and room for a
    /// first or last plate's bleed.
    static var cardPadding: EdgeInsets {
        EdgeInsets(top: plateInset + plateBleed, leading: plateInset,
                   bottom: plateInset + plateBleed, trailing: plateInset)
    }
    /// The words from the card's edge (Upcoming's).
    static let textInset: CGFloat = 24

    var body: some View {
        Button(action: action) { CardSettingsRowFace(row: self) }
            .buttonStyle(CardSettingsRowStyle())
            .disabled(!reachable)
    }
}

private struct CardSettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct CardSettingsRowFace: View {
    @Environment(\.isFocused) private var isFocused
    let row: CardSettingsRow

    var body: some View {
        let ink = isFocused ? Color.black : CueInk.primary
        let quiet = isFocused ? Color.black.opacity(0.6) : CueInk.body
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(row.title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ink)
                Spacer(minLength: 24)
                if let value = row.value {
                    Text(value)
                        .font(.system(size: 24))
                        .foregroundStyle(quiet)
                }
                if row.chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(quiet)
                }
            }
            if let description = row.description {
                Text(description)
                    .font(.system(size: 24))
                    .foregroundStyle(quiet)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, row.compact ? 9 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardFocusPlate(lit: isFocused, selected: row.selected) }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
