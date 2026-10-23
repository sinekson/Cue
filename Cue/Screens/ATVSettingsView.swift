import SwiftUI

/// The Settings screen: the categories a sidebar on the left; centred,
/// the focused one's settings, following focus (a
/// moment after it settles, so passing over a category doesn't redraw the
/// column). Right or Select goes into the settings; Left or Back comes back
/// to the category. Pages the settings open stay in the right column
/// (`SettingsNav`); Back takes them off first.
struct ATVSettingsView: View {

    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore

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
        .onChange(of: focused) { _, category in
            showTask?.cancel()
            guard let category else { return }
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
            if focused != nil { onExit() } else if !nav.pop() { focused = shown }
        }
    }

    /// The category's settings, in the right column. Pages not yet on the
    /// new rows keep their own layout, from the same top.
    @ViewBuilder
    private func column(_ category: SettingsCategory) -> some View {
        switch category {
        case .account, .tmdb, .mdblist, .appearance, .homeContent:
            SettingsCategoryPane(category: category)
        default:
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
        // Focus in the settings (or the top bar): only the shown category
        // takes it, so Left — or Down from the top bar — lands there.
        let away = focused == nil
        return Button {
            showTask?.cancel()
            if category != shown {
                nav.clear()
                shown = category
            }
            // Into the settings, on their first row (once they're there).
            DispatchQueue.main.async { row = rows.first }
        } label: {
            SettingsCategoryLabel(category: category, value: value)
        }
        .buttonStyle(SettingsCategoryStyle(current: away && category == shown))
        .focused($focused, equals: category)
        .disabled(turning || (away && category != shown))
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
