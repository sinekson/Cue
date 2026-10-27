import SwiftUI

/// The Settings screen: one column, centred, a level at a time — as Apple
/// TV's Settings. First the categories (`SettingsCategoriesPage`); Select
/// opens one's settings, and their rows open lower pages, each in the same
/// column (`SettingsNav`). Back goes up a level, focus back on the row that
/// opened it; on the categories, to the top bar. Up from the first row: the
/// top bar; Down from it goes back to the row it left (first time: the
/// first). (Tried: the categories a sidebar beside the settings — floating
/// on the page; in a glass panel, as macOS Tahoe's; flat and flush, as
/// macOS Sequoia's.)
struct ATVSettingsView: View {

    /// The top bar holds focus.
    let barFocused: Bool
    /// The column's first page instead of the categories (the gate's
    /// profiles); Back on it: out.
    var root: AnyView? = nil
    /// Back on the categories: out (to the top bar).
    let onExit: () -> Void

    @StateObject private var nav = SettingsNav()
    /// The focused row (by name), and the page's rows in order.
    @FocusState private var row: String?
    @State private var rows: [String] = []
    /// The rows that opened the pages in the column, to go back to.
    @State private var openedFrom: [String?] = []
    /// Back from a page: the row that opened it, the only one taking focus
    /// as its page comes back (else the engine took the first for a moment).
    @State private var returning: String?
    /// A page just opened: the rows before it, to tell its first row by
    /// (focus goes there — the engine took the row nearest the one left).
    @State private var opening: Set<String>?
    /// Where Up into the top bar left from.
    @State private var upFrom: String?
    /// Each page's last focused row (the categories by "", a page opened
    /// in the column by its id).
    @State private var lastRow: [String: String] = [:]

    /// `-settingsPage <category>`: opens with that category's settings.
    private static var launchCategory: SettingsCategory? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-settingsPage"), flag + 1 < args.count else {
            return args.contains("-accountDemo") ? .account : nil
        }
        return SettingsCategory(rawValue: args[flag + 1])
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let page = nav.stack.last {
                page.view.id(page.id)
                    .transition(.opacity)
            } else if let root {
                root.transition(.opacity)
            } else {
                SettingsCategoriesPage()
                    .transition(.opacity)
            }
        }
        .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.settingsOnlyRow, barFocused ? barRow : returning)
        // Screen coordinates: the same start with or without the top bar.
        .ignoresSafeArea()
        .background(ATVBackground())
        .environmentObject(nav)
        .environment(\.settingsRowFocus, $row)
        .onPreferenceChange(SettingsRowsKey.self) { new in
            rows = new
            guard let before = opening, let first = new.first(where: { !before.contains($0) }) else { return }
            opening = nil
            returning = first
            DispatchQueue.main.async { row = first }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { returning = nil }
        }
        .onAppear {
            nav.leave = onExit
            // Opened on its own page: focus on that page's first row.
            if root != nil { opening = []; return }
            guard let category = Self.launchCategory, nav.stack.isEmpty else { return }
            nav.push(SettingsCategoryPane.inColumn(category))
        }
        .onChange(of: nav.stack.count) { old, new in
            if new > old {
                openedFrom.append(row)
                opening = Set(rows)
                // A page without the new rows (the old cards): none to find.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { opening = nil }
                return
            }
            opening = nil
            let back = new < old ? openedFrom.popLast() ?? nil : nil
            if new == 0, old > 1 || back == nil { openedFrom.removeAll() }
            returning = back
            DispatchQueue.main.async { if let back { row = back } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let back, row == nil { row = back }
                returning = nil
            }
        }
        .onChange(of: barFocused) { _, bar in
            if bar { upFrom = lastRow[pageKey] }
        }
        .onChange(of: row) { _, id in
            if let id { lastRow[pageKey] = id }
        }
        // One handler for the whole screen (a nested one takes every press).
        .onExitCommand {
            // The row to land on, before its page is back (see `returning`).
            returning = nav.stack.isEmpty ? nil : openedFrom.last ?? nil
            if !nav.pop() { onExit() }
        }
    }

    /// The page in the column: a page opened there, else the categories.
    private var pageKey: String { nav.stack.last?.id.uuidString ?? "" }

    /// While the top bar holds focus: the one row Down goes back to — where
    /// Up left, if it's still on the page — else the first.
    private var barRow: String? {
        if let upFrom, rows.contains(upFrom) { return upFrom }
        return rows.first
    }
}

/// Settings' first level: the categories, as rows — the accounts and keys
/// up top (each saying what's missing, if anything), then the rest, then
/// Developer. No descriptions (each category's line heads its own page).
private struct SettingsCategoriesPage: View {
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore

    /// Categories under General (the accounts have their own section up
    /// top, Developer its own at the bottom).
    private var generalCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { !SettingsCategory.accounts.contains($0) && $0 != .developer }
    }

    var body: some View {
        SettingsPage(title: "Settings") {
            SettingsSection(title: "Accounts") {
                ForEach(SettingsCategory.accounts) { row($0, value: state(of: $0)) }
            }
            SettingsSection(title: "General") {
                ForEach(generalCategories) { row($0) }
            }
            SettingsSection(title: "Developer") {
                row(.developer)
            }
        }
    }

    private func row(_ category: SettingsCategory, value: String? = nil) -> some View {
        SettingsLinkRow(title: category.title, value: value) {
            SettingsCategoryPane.inColumn(category)
        }
    }

    /// An account's state, on its row — only when something needs doing
    /// (all well, the state is in its settings).
    private func state(of category: SettingsCategory) -> String? {
        switch category {
        case .account: return account.authState.isSignedIn ? nil : "Signed out"
        case .tmdb: return tmdb.hasAPIKey ? nil : "Add key"
        case .mdblist: return mdblist.settings.isConfigured ? nil : "Add key"
        default: return nil
        }
    }
}

extension SettingsCategoryPane {
    /// Categories on the new rows.
    private static let rowCategories: Set<SettingsCategory> = [.account, .tmdb, .mdblist, .appearance, .homeContent]

    /// A category's settings in the column. Pages not yet on the new rows
    /// keep their own layout, from the same top.
    @ViewBuilder
    static func inColumn(_ category: SettingsCategory) -> some View {
        if rowCategories.contains(category) {
            SettingsCategoryPane(category: category)
        } else {
            SettingsCategoryPane(category: category)
                .padding(.top, SettingsMetrics.top - CueSpacing.lg)
        }
    }
}
