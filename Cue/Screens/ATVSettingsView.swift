import SwiftUI
import UIKit

/// The Settings screen: the categories a sidebar on the left; centred,
/// the focused one's settings, following focus (a
/// moment after it settles, so passing over a category doesn't redraw the
/// column). Right or Select goes into the settings, on the row last focused
/// there (first time: the first); Left or Back comes back to the category.
/// Pages the settings open stay in the right column (`SettingsNav`); Back
/// takes them off first. Up from the first category or the first row: the
/// top bar; Down from it goes back there (first time: the category).
///
/// Only the column holding focus takes it (from the top bar, only the spot
/// it went up from), so the engine never picks a target by where things
/// sit; Left and Right between the columns are ours (`crossFailed`).
struct ATVSettingsView: View {

    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @Environment(\.isEnabled) private var isEnabled

    /// The top bar holds focus.
    let barFocused: Bool
    /// Back with focus on a category: out (to the top bar).
    let onExit: () -> Void

    @StateObject private var nav = SettingsNav()
    @FocusState private var focused: SettingsCategory?
    /// The category whose settings show.
    @State private var shown: SettingsCategory = Self.launchCategory ?? .account
    @State private var showTask: Task<Void, Never>?
    /// The focused row in the right column (by name), and the column's
    /// rows in order — Select on a category focuses the first.
    @FocusState private var row: String?
    @State private var rows: [String] = []
    /// While a page opens or closes in the column, no category takes focus
    /// (it would, as the row in focus goes) — it stays in the column.
    @State private var turning = false
    /// The rows that opened the pages in the column, to go back to.
    @State private var openedFrom: [String?] = []

    /// Where focus is; `crossing` while we move it between the columns
    /// (both take focus for that moment).
    private enum Place { case bar, sidebar, page, crossing }
    private enum Spot: Equatable { case category(SettingsCategory), row(String) }
    @State private var place: Place = .bar
    /// Where Up into the top bar left from.
    @State private var upFrom: Spot?
    @State private var lastCategory: SettingsCategory?
    /// Each page's last focused row (the category's settings by its name,
    /// a page opened in the column by its id).
    @State private var lastRow: [String: String] = [:]

    /// How long focus rests on a category before its settings show.
    private static let showAfter: Duration = .milliseconds(150)

    /// `-settingsPage <category>`: opens with that category's settings.
    private static var launchCategory: SettingsCategory? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-settingsPage"), flag + 1 < args.count else {
            return args.contains("-accountDemo") ? .account : nil
        }
        return SettingsCategory(rawValue: args[flag + 1])
    }

    /// Categories under General (the accounts have their own section up
    /// top, Developer its own at the bottom).
    private var generalCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { !SettingsCategory.accounts.contains($0) && $0 != .developer }
    }

    var body: some View {
        // The settings centred on the screen, the sidebar just left of them.
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SettingsMetrics.Sidebar.sectionGap) {
                SettingsSection(title: "Accounts", sidebar: true) {
                    ForEach(SettingsCategory.accounts) { categoryRow($0, value: state(of: $0)) }
                }
                SettingsSection(title: "General", sidebar: true) {
                    ForEach(generalCategories) { categoryRow($0) }
                }
                SettingsSection(title: "Developer", sidebar: true) {
                    categoryRow(.developer)
                }
            }
            .padding(.top, SettingsMetrics.Sidebar.top)
            .frame(width: SettingsMetrics.listWidth, alignment: .topLeading)
            // Focus in the settings (or the top bar): the categories step
            // back, as the Apple TV app's sidebar.
            .opacity(focused == nil ? 0.5 : 1)
            .animation(.smooth(duration: 0.25), value: focused == nil)
            .focusSection()
            .offset(x: -(SettingsMetrics.columnWidth + SettingsMetrics.listWidth) / 2 - SettingsMetrics.columnGap)

            ZStack(alignment: .topLeading) {
                if let page = nav.stack.last {
                    page.view.id(page.id)
                        .transition(.opacity)
                } else {
                    column(shown).id(shown)
                        .transition(.opacity)
                }
            }
            .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()
            .disabled(!legacy && !columnTakesFocus)
            .environment(\.settingsOnlyRow, place == .bar ? barRow : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Screen coordinates: the same start with or without the top bar.
        .ignoresSafeArea()
        .background(ATVBackground())
        .environmentObject(nav)
        .environment(\.settingsRowFocus, $row)
        .onPreferenceChange(SettingsRowsKey.self) { rows = $0 }
        .onChange(of: nav.stack.count) { old, new in
            if new > old { openedFrom.append(row) }
            let back = new < old ? openedFrom.popLast() ?? nil : nil
            if new == 0, old > 1 || back == nil { openedFrom.removeAll() }
            turning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let back, focused == nil { row = back }
                turning = false
            }
        }
        .onChange(of: barFocused) { _, bar in
            guard bar else { return }
            switch place {
            case .sidebar: upFrom = lastCategory.map(Spot.category)
            case .page: upFrom = lastRow[pageKey].map(Spot.row)
            case .bar, .crossing: break
            }
            place = .bar
        }
        .onChange(of: row) { _, id in
            guard let id else { return }
            place = .page
            lastRow[pageKey] = id
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIFocusSystem.movementDidFailNotification)) { crossFailed($0) }
        .onChange(of: focused) { old, category in
            if let category {
                place = .sidebar
                lastCategory = category
            }
            let pending = showTask != nil && old != nil && old != shown ? old : nil
            showTask?.cancel()
            showTask = nil
            guard let category else {
                // Right before its settings showed: they show now, at once,
                // focus on their first row (it landed in the old ones).
                guard let pending else { return }
                DispatchQueue.main.async {
                    guard row != nil else { return }
                    nav.clear()
                    shown = pending
                    DispatchQueue.main.async { row = rows.first }
                }
                return
            }
            // (Its own category: a page opened over its settings stays.)
            guard category != shown else { return }
            showTask = Task { @MainActor in
                try? await Task.sleep(for: Self.showAfter)
                guard !Task.isCancelled else { return }
                nav.clear()
                withAnimation(.easeOut(duration: 0.25)) { shown = category }
            }
        }
        // One handler for the whole screen (a nested one takes every press).
        .onExitCommand {
            if focused != nil { onExit() } else if !nav.pop() { toSidebar() }
        }
    }

    /// The page in the column: a page opened there, else the category's.
    private var pageKey: String { nav.stack.last?.id.uuidString ?? shown.rawValue }

    /// Categories on the new rows.
    private static let rowCategories: Set<SettingsCategory> = [.account, .tmdb, .mdblist, .appearance, .homeContent]

    /// Pages still on the old cards: focus there goes by the engine's
    /// geometry, as before.
    private var legacy: Bool { !Self.rowCategories.contains(shown) }

    /// Down from the top bar: back where Up left — a row still on the page,
    /// a category — else the shown category.
    private var barTarget: Spot {
        switch upFrom {
        case .row(let id) where rows.contains(id): return .row(id)
        case .category(let category): return .category(category)
        default: return .category(shown)
        }
    }

    private var barRow: String? {
        if case .row(let id) = barTarget { return id } else { return nil }
    }

    private var columnTakesFocus: Bool {
        switch place {
        case .page, .crossing: return true
        case .sidebar: return false
        case .bar: return barRow != nil
        }
    }

    private func categoryTakesFocus(_ category: SettingsCategory) -> Bool {
        if legacy { return focused != nil || category == shown }
        switch place {
        case .sidebar, .crossing: return true
        case .page: return false
        case .bar: return barTarget == .category(category)
        }
    }

    /// Left from the page, Right from a category: with the other column
    /// off, the engine found nothing — we take it there.
    private func crossFailed(_ note: Notification) {
        guard isEnabled, !legacy,
              let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
        else { return }
        if place == .sidebar, context.focusHeading.contains(.right) {
            enterPage()
        } else if place == .page, context.focusHeading.contains(.left) {
            toSidebar()
        }
    }

    /// Into the focused category's settings, on its last focused row (first
    /// time: the first).
    private func enterPage() {
        showTask?.cancel()
        showTask = nil
        let switching = focused.map { $0 != shown } ?? false
        if switching, let focused {
            nav.clear()
            shown = focused
        }
        place = .crossing
        // Once its rows are there (a page just switched: a turn later).
        DispatchQueue.main.async {
            let land = {
                row = lastRow[pageKey].flatMap { rows.contains($0) ? $0 : nil } ?? rows.first
            }
            if switching { DispatchQueue.main.async(execute: land) } else { land() }
        }
    }

    private func toSidebar() {
        place = .crossing
        DispatchQueue.main.async { focused = shown }
    }

    /// The category's settings, in the right column. Pages not yet on the
    /// new rows keep their own layout, from the same top.
    @ViewBuilder
    private func column(_ category: SettingsCategory) -> some View {
        if Self.rowCategories.contains(category) {
            SettingsCategoryPane(category: category)
        } else {
            SettingsCategoryPane(category: category)
                .padding(.top, SettingsMetrics.top - CueSpacing.lg)
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

    private func categoryRow(_ category: SettingsCategory, value: String? = nil) -> some View {
        let away = focused == nil
        return Button {
            enterPage()
        } label: {
            SettingsCategoryLabel(category: category, value: value)
        }
        .buttonStyle(SettingsCategoryStyle(current: away && category == shown))
        .focused($focused, equals: category)
        .disabled(turning || !categoryTakesFocus(category))
    }
}

/// A category in the left column: its name, and (an account needing
/// something) what's missing — a settings row's text, at the sidebar's size.
private struct SettingsCategoryLabel: View {
    @Environment(\.isFocused) private var isFocused
    let category: SettingsCategory
    let value: String?

    var body: some View {
        HStack(spacing: 16) {
            Text(category.title)
                .font(.system(size: SettingsMetrics.Sidebar.textSize, weight: .medium))
                .foregroundStyle(isFocused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                .lineLimit(1)
            Spacer(minLength: 16)
            if let value {
                Text(value)
                    .font(.system(size: SettingsMetrics.Sidebar.textSize))
                    .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.6)
                                               : SettingsMetrics.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, SettingsMetrics.Sidebar.rowInset)
        .frame(height: SettingsMetrics.Sidebar.rowHeight)
        .frame(maxWidth: .infinity)
    }
}

/// A category's chrome, a sidebar's: nothing at rest (the settings' rows
/// have the fills — tried: the rows' faint fill here too, the columns read
/// alike); the shown one, while focus is in its settings, the flat fill of
/// the current one of a set; focused, the rows' highlight.
private struct SettingsCategoryStyle: ButtonStyle {
    let current: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, current: current)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let current: Bool

        var body: some View {
            configuration.label
                .background {
                    let shape = RoundedRectangle(cornerRadius: SettingsMetrics.Sidebar.rowRadius, style: .continuous)
                    if isFocused { GlassHighlight(focused: true, shape: shape) }
                    else if current { shape.fill(FlatControl.selected) }
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.0 : 1.02) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 16, y: 8)
                .animation(.smooth(duration: 0.18), value: isFocused)
                .animation(.smooth(duration: 0.18), value: current)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
        }
    }
}
