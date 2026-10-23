import SwiftUI

// THE SETTINGS LOOK — a sidebar and a column. On the left the
// categories (`ATVSettingsView`); centred on the screen, the focused category's
// settings, following focus. Right or Select goes into them, Left or Back
// comes out again. Pages a row opens (a list to manage, a sign-in) open in
// that right column, the categories staying beside them (`SettingsNav`).
// Rows rest on a faint fill and, focused, sit on the top bar's light
// highlight with their description under the pill — only the focused row
// says what it does. (Tried: an info pane beside the
// rows with the category's symbol in a box and the description below it —
// the box wasted room, the words were far from their row.)
//
// - `SettingsPage`: a category's settings, in the column.
// - `SettingsSection`: a titled group of rows.
// - Rows: `SettingsToggleRow` (Select flips On / Off), `SettingsChoiceRow`
//   (Select opens the options in the glass dropdown), `SettingsLinkRow`
//   (opens a page in the column), `SettingsButtonRow` (runs an action).

enum SettingsMetrics {
    /// Apple TV's Settings rows, measured: 65 pt capsules, 14 apart, 38 pt
    /// text (the name medium, the value regular) 33 pt in from the ends, a
    /// 38 pt chevron. (Tried: 72 pt rows with the cards' corners, 29 / 27 pt
    /// text 22 pt in.)
    static let rowHeight: CGFloat = 65
    static var rowRadius: CGFloat { rowHeight / 2 }
    /// A row's text from its ends. Labels and headings outside the rows
    /// line up with what's inside them: the settings' text, the
    /// categories' icons. (Tried: just in from the rows' edge, as Home's
    /// row names from their cards — `textIndent`; on the edge itself.)
    static let rowInset: CGFloat = 33
    static var labelIndent: CGFloat { rowInset }
    static let rowTextSize: CGFloat = 38
    /// A page's title and its sections' labels, as Apple TV's Settings
    /// (57 pt semibold, 29 pt semibold), both in the labels' grey.
    static let titleTextSize: CGFloat = 57
    static let sectionTextSize: CGFloat = 29
    static let valueTextSize: CGFloat = 38
    static let descriptionSize: CGFloat = 24
    static let sectionGap: CGFloat = 40
    static let rowGap: CGFloat = 14
    /// The settings centred on the screen, the categories a sidebar
    /// `columnGap` left of them: single-column rows read better narrow than
    /// across the content's width (tried: the categories a third of it,
    /// the settings the rest; both columns centred together, 440 + 780;
    /// the sidebar 400 wide at the screen's left inset).
    static let listWidth: CGFloat = 320
    static let columnWidth: CGFloat = 780
    static let columnGap: CGFloat = 64
    /// Where both columns start, on every page: where Home's focused row
    /// has its name, below the top bar.
    static var top: CGFloat { FixedFocusMetrics.rowTop }
    /// A section's label line (kept empty in a section without one), so
    /// the first row starts at the same height on every page.
    static let sectionLabelHeight: CGFloat = 36
    /// Between a page's title and its description.
    static let headingSpacing: CGFloat = 6

    /// The categories: the settings' rows and labels, a size smaller
    /// (about 80 %), no icons (tried: each with its symbol in its colour).
    enum Sidebar {
        static let rowHeight: CGFloat = 52
        static var rowRadius: CGFloat { rowHeight / 2 }
        static let rowInset: CGFloat = 26
        static let rowGap: CGFloat = 11
        static let textSize: CGFloat = 30
        static let sectionTextSize: CGFloat = 23
        static var titleTextSize: CGFloat { SettingsMetrics.titleTextSize }
        static let sectionLabelHeight: CGFloat = 29
        static let sectionGap: CGFloat = 32
        /// Where it starts: its first label on the line of the page's
        /// description (baselines level), not the page's title — the
        /// titles' sizes don't match. (Tried: level with the title.)
        static var top: CGFloat {
            let title = UIFont.systemFont(ofSize: titleTextSize, weight: .semibold).lineHeight
            let description = UIFont.systemFont(ofSize: 24, weight: .medium).ascender
            let label = sectionLabelHeight + UIFont.systemFont(ofSize: sectionTextSize, weight: .semibold).descender
            return SettingsMetrics.top + title + SettingsMetrics.headingSpacing + description - label
        }
    }
    /// The focused platter: the top bar's bright glass highlight
    /// (`GlassHighlight`); this, where a plain fill is needed.
    static let focusedFill = FlatControl.focus
    static let restingFill = FlatControl.restSubtle
    static let focusedText = Color.black
    /// The app's text levels (`FixedFocusText`): names, values, labels.
    static let primaryText = Color.white.opacity(FixedFocusText.primary)
    static let secondaryText = Color.white.opacity(FixedFocusText.secondary)
    static let labelText = Color.white.opacity(FixedFocusText.heading)
}

/// The right column's pages: a category's own, or what one of its rows
/// opened over it (Back takes it off again).
@MainActor
final class SettingsNav: ObservableObject {
    struct Page: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    @Published private(set) var stack: [Page] = []

    func push(_ view: some View) {
        withAnimation(.easeOut(duration: 0.25)) { stack.append(Page(view: AnyView(view))) }
    }

    /// False when there was nothing to take off.
    @discardableResult
    func pop() -> Bool {
        guard !stack.isEmpty else { return false }
        withAnimation(.easeOut(duration: 0.25)) { _ = stack.removeLast() }
        return true
    }

    func clear() { stack.removeAll() }
}

/// The column's rows, for Select on a category: each row reports its name
/// (in order, top to bottom) and takes the screen's row focus by it — the
/// first one gets focus.
private struct SettingsRowFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<String?>.Binding? = nil
}

/// Where a row's pill is: its line, without the description under it.
struct SettingsPillKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The focused row with a description, reported up to its page, which
/// opens it (`settingsDescribed`) in one animation — so the rows below
/// step down with it.
struct SettingsDescribedKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

private struct SettingsDescribedEnvKey: EnvironmentKey {
    /// nil outside a page: a row then opens its own on focus. Inside, the
    /// page's row ("" for none).
    static let defaultValue: String? = nil
}

struct SettingsRowsKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

extension EnvironmentValues {
    var settingsDescribed: String? {
        get { self[SettingsDescribedEnvKey.self] }
        set { self[SettingsDescribedEnvKey.self] = newValue }
    }
    var settingsRowFocus: FocusState<String?>.Binding? {
        get { self[SettingsRowFocusKey.self] }
        set { self[SettingsRowFocusKey.self] = newValue }
    }
}

struct SettingsRowEntry: ViewModifier {
    @Environment(\.settingsRowFocus) private var focus
    let id: String

    func body(content: Content) -> some View {
        Group {
            if let focus { content.focused(focus, equals: id) } else { content }
        }
        .preference(key: SettingsRowsKey.self, value: [id])
    }
}

extension View {
    /// A settings row's chrome, and its place in the column's focus.
    func settingsRow(id: String, _ style: SettingsRowStyle = SettingsRowStyle()) -> some View {
        buttonStyle(style).modifier(SettingsRowEntry(id: id))
    }
}

/// A category's settings, or a page they open, in the right column: its
/// heading (`SettingsScrollingPage`), at its right end the page's round
/// buttons (`accessory`) — then its sections.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        SettingsScrollingPage(title: title, subtitle: subtitle) {
            accessory
        } content: {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                content
            }
        }
    }
}

/// A round button beside a page's header (Sync now, Sign out): a circle a
/// row tall, its icon muted; focused white, its name under it.
struct SettingsRoundButton: View {
    let icon: String
    let title: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(icon: icon, title: title, spinning: spinning) }
            .buttonStyle(PlainCardButtonStyle())
            .modifier(SettingsRowEntry(id: title))
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let icon: String
        let title: String
        let spinning: Bool

        var body: some View {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .bold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                           value: spinning)
                .foregroundStyle(focused ? SettingsMetrics.focusedText : SettingsMetrics.secondaryText)
                .frame(width: SettingsMetrics.rowHeight, height: SettingsMetrics.rowHeight)
                .background {
                    Circle().fill(focused ? FlatControl.focus : FlatControl.rest)
                        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 16, y: 8)
                }
                .scaleEffect(focused ? 1.06 : 1)
                // Its name under it while focused (not in the layout).
                .overlay(alignment: .bottom) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(SettingsMetrics.primaryText)
                        .fixedSize()
                        .offset(y: 40)
                        .opacity(focused ? 1 : 0)
                }
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

/// A titled group of rows. Its label as Apple TV's Settings', measured:
/// 29 pt semibold capitals, no extra spacing, the title's grey (tried:
/// Home's section hint, small and widely spaced). The sidebar's groups
/// the same, at its scale (`Sidebar`).
struct SettingsSection<Content: View>: View {
    var title: String = ""
    var sidebar = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: sidebar ? SettingsMetrics.Sidebar.rowGap : SettingsMetrics.rowGap) {
            // Untitled: the rows alone, no label's room.
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: sidebar ? SettingsMetrics.Sidebar.sectionTextSize : SettingsMetrics.sectionTextSize,
                                  weight: .semibold))
                    .foregroundStyle(SettingsMetrics.labelText)
                    .padding(.leading, sidebar ? SettingsMetrics.Sidebar.rowInset : SettingsMetrics.labelIndent)
                    .frame(height: sidebar ? SettingsMetrics.Sidebar.sectionLabelHeight : SettingsMetrics.sectionLabelHeight,
                           alignment: .bottomLeading)
            }
            content
        }
        .focusSection()
    }
}

// MARK: - Rows

/// A row's content: name left, value (and chevron) right; focused, its
/// description under the pill, the rows below stepping down to make room
/// (as text under tvOS's posters). (Tried: the description inside the
/// pill, under the name — the pill grew tall.)
struct SettingsRowLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsDescribed) private var described
    let title: String
    var value: String? = nil
    var chevron = false
    var checked = false
    var description: String? = nil
    /// Before the name (a profile's avatar).
    var leading: AnyView? = nil

    private var describes: Bool {
        guard let description, !description.isEmpty else { return false }
        return described.map { $0 == describedID } ?? isFocused
    }
    private var describedID: String { "\(title)\n\(description ?? "")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                leading
                Text(title)
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                    .foregroundStyle(isFocused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 24)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: SettingsMetrics.valueTextSize))
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.6)
                                                   : SettingsMetrics.secondaryText)
                        .lineLimit(1)
                }
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.45)
                                                   : SettingsMetrics.secondaryText)
                        .padding(.leading, 14)
                }
            }
            .frame(height: SettingsMetrics.rowHeight)
            .padding(.horizontal, SettingsMetrics.rowInset)
            .anchorPreference(key: SettingsPillKey.self, value: .bounds) { $0 }
            if describes, let description {
                Text(description)
                    .font(.system(size: SettingsMetrics.descriptionSize))
                    .foregroundStyle(SettingsMetrics.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.rowInset)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.focus, value: isFocused)
        .preference(key: SettingsDescribedKey.self,
                    value: isFocused && !(description ?? "").isEmpty ? describedID : nil)
    }
}

/// A row only to read (Apple's way): name and value, no fill, no focus.
struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        SettingsRowLabel(title: title, value: value)
    }
}

/// Rows' chrome, as Apple TV's Settings: the cards' corners; a faint fill at
/// rest; focused, the top bar's bright glass highlight, lifted a little.
struct SettingsRowStyle: ButtonStyle {
    /// Select held (`holdAfter`): this instead of the action — `didHold`
    /// tells the action to skip the release that follows.
    var onHold: (() -> Void)? = nil
    var didHold: Binding<Bool>? = nil

    static let holdAfter: Duration = .milliseconds(500)

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, onHold: onHold, didHold: didHold)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let onHold: (() -> Void)?
        let didHold: Binding<Bool>?
        @State private var holdTask: Task<Void, Never>?

        private var pill: some View {
            let shape = RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius, style: .continuous)
            return Group {
                if isFocused { GlassHighlight(focused: true, shape: shape) }
                else { shape.fill(SettingsMetrics.restingFill) }
            }
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 16, y: 8)
        }

        var body: some View {
            configuration.label
                // The pill behind the row's line only (`SettingsPillKey`;
                // a description sits under it), else the whole label.
                .backgroundPreferenceValue(SettingsPillKey.self) { anchor in
                    GeometryReader { proxy in
                        let rect = anchor.map { proxy[$0] } ?? CGRect(origin: .zero, size: proxy.size)
                        pill
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.0 : 1.02) : 1, anchor: .top)
                .animation(.smooth(duration: 0.18), value: isFocused)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
                // Still pressed after `holdAfter`: the hold (the way Details'
                // buttons watch for it — a long-press gesture is unreliable
                // on tvOS buttons).
                .onChange(of: configuration.isPressed) { _, pressed in
                    holdTask?.cancel()
                    holdTask = nil
                    guard pressed, let onHold else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: SettingsRowStyle.holdAfter)
                        guard !Task.isCancelled else { return }
                        didHold?.wrappedValue = true
                        onHold()
                    }
                }
        }
    }
}

/// On / Off: Select flips it.
struct SettingsToggleRow: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            SettingsRowLabel(title: title, value: isOn ? "On" : "Off", description: description)
        }
        .settingsRow(id: title)
    }
}

/// One option of a `SettingsChoiceRow`.
struct SettingsOption: Identifiable {
    let id: String
    let label: String
    /// Before the label on the options page (a colour's swatch).
    var leading: AnyView? = nil
}

/// A choice: shows the current option; Select opens the options in the
/// glass dropdown under it (`HoldMenu.openDropdown`), the current one checked.
struct SettingsChoiceRow: View {
    let title: String
    var description: String? = nil
    let options: [SettingsOption]
    let selection: String
    let onPick: (String) -> Void
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            let entries = options.map { option in
                MenuEntry(title: option.label, icon: "", checked: option.id == selection) { onPick(option.id) }
            }
            HoldMenu.shared.openDropdown(entries, below: frame)
        } label: {
            SettingsRowLabel(title: title, value: options.first { $0.id == selection }?.label,
                             chevron: true, description: description)
        }
        .settingsRow(id: title)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, rect in frame = rect }
            }
        }
    }
}

/// A choice that opens its options as a page in the column (no pop-up):
/// the current one on the row's right; on the page, one row each, the
/// current one checked — Select picks it and goes back.
struct SettingsOptionsRow: View {
    @EnvironmentObject private var nav: SettingsNav
    let title: String
    var description: String? = nil
    let options: [SettingsOption]
    let selection: String
    let onPick: (String) -> Void

    var body: some View {
        Button {
            nav.push(SettingsOptionsPage(title: title, subtitle: description ?? "",
                                         options: options, selection: selection, onPick: onPick))
        } label: {
            SettingsRowLabel(title: title, value: options.first { $0.id == selection }?.label,
                             chevron: true, description: description)
        }
        .settingsRow(id: title)
    }
}

private struct SettingsOptionsPage: View {
    @EnvironmentObject private var nav: SettingsNav
    let title: String
    let subtitle: String
    let options: [SettingsOption]
    let selection: String
    let onPick: (String) -> Void

    var body: some View {
        SettingsPage(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ForEach(options) { option in
                    Button {
                        onPick(option.id)
                        nav.pop()
                    } label: {
                        SettingsRowLabel(title: option.label, checked: option.id == selection,
                                         leading: option.leading)
                    }
                    .settingsRow(id: option.id)
                }
            }
        }
    }
}

/// Opens a page in the right column.
struct SettingsLinkRow<Destination: View>: View {
    @EnvironmentObject private var nav: SettingsNav
    let title: String
    var description: String? = nil
    var value: String? = nil
    @ViewBuilder let destination: Destination

    var body: some View {
        Button { nav.push(destination) } label: {
            SettingsRowLabel(title: title, value: value, chevron: true, description: description)
        }
        .settingsRow(id: title)
    }
}

/// Runs an action.
struct SettingsButtonRow: View {
    let title: String
    var description: String? = nil
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowLabel(title: title, value: value, description: description)
        }
        .settingsRow(id: title)
    }
}

// MARK: - Managed lists (Home's rows, the add-ons)

/// While a list entry is being moved, the top bar can't take focus — Up at
/// the top of the list would otherwise escape there (Settings keeps the top
/// bar focusable on every page).
@MainActor
final class TopBarLock: ObservableObject {
    static let shared = TopBarLock()
    @Published var locked = false
}

/// A page for managing a list, in the right column: compact, one-line rows —
/// the name left, small controls right (`SettingsEntryRow`); an optional
/// button by the heading (adding: round; a labelled one says what it does).
/// The heading as a folder page's: the name as the row names, the subtitle
/// under it quieter.
struct SettingsManagePage<Content: View>: View {
    let title: String
    let subtitle: String
    var headerAction: SettingsEntryAction? = nil
    @ViewBuilder let content: Content

    var body: some View {
        SettingsScrollingPage(title: title, subtitle: subtitle) {
            if let headerAction {
                if headerAction.labelled {
                    SettingsLabelButton(icon: headerAction.icon, title: headerAction.title,
                                        destructive: headerAction.destructive,
                                        action: headerAction.action)
                } else {
                    SettingsIconButton(icon: headerAction.icon, action: headerAction.action)
                }
            }
        } content: {
            content
        }
    }
}

/// A page in the right column: its heading stays where the page starts
/// (level with the categories), the rows scroll under it — nothing goes
/// higher than the heading's foot, where the rows fade out over a short
/// edge. (Tried: the whole page scrolling, up past where it started.)
/// The reader goes to the rows (`settingsScroll`): a row being MOVED keeps
/// focus, so the system never scrolls for it — the row scrolls itself into
/// view on every step.
///
/// The heading: every page's title alone (one title on the column, ever)
/// at a row's size, the description under it. (Tried: every page titled,
/// 40 pt, as Home's row names — it outweighed the categories; the trail
/// over the title, "NUVIO › PROFILES"; a category's own page untitled —
/// a title at times and not at others.)
struct SettingsScrollingPage<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    /// The rows' fade under the heading, kept as room above the first row.
    static var edge: CGFloat { 24 }
    @State private var described = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
                .focusSection()
                .padding(.leading, SettingsMetrics.labelIndent)
                .padding(.top, SettingsMetrics.top)
                .padding(.bottom, 28 - Self.edge)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                        .environment(\.settingsDescribed, described)
                        .onPreferenceChange(SettingsDescribedKey.self) { row in
                            withAnimation(Motion.focus) { described = row ?? "" }
                        }
                        .padding(.top, Self.edge)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Unclipped at the sides and bottom (focused rows' shadows),
                // cut at the top with a short fade.
                .scrollClipDisabled()
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edge)
                        Rectangle()
                    }
                    .padding(.horizontal, -60)
                    .padding(.bottom, -200)
                }
                .environment(\.settingsScroll, proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: some View {
        HStack(spacing: SettingsMetrics.rowGap) {
            VStack(alignment: .leading, spacing: SettingsMetrics.headingSpacing) {
                Text(title)
                    .font(.system(size: SettingsMetrics.titleTextSize, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.labelText)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.white.opacity(FixedFocusText.captionDetail))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
    }
}

private struct SettingsScrollKey: EnvironmentKey {
    static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
    /// The managed page's scroll view (see `SettingsManagePage`).
    var settingsScroll: ScrollViewProxy? {
        get { self[SettingsScrollKey.self] }
        set { self[SettingsScrollKey.self] = newValue }
    }
}

/// One of an entry's controls.
struct SettingsEntryAction: Identifiable {
    let id: String
    let icon: String
    /// Its name — shown after the entry's name while it has focus.
    let title: String
    /// By a page's heading: its name on it, not just the icon.
    var labelled = false
    var destructive = false
    let action: () -> Void
}

/// An on / off of an entry, as a switch.
struct SettingsEntrySwitch {
    let isOn: Bool
    /// Its name while focused ("Turn off", "Show").
    let title: String
    let toggle: () -> Void
}

/// A compact, one-line entry: its name (and, while one of its controls has
/// focus, that control's name after it), then on the right — left to right —
/// an optional control (`extra`: its slot kept, so the others line up),
/// the always-there buttons, the switch, and Remove in red.
/// MOVING (the `move` button): the entry lifts; Up / Down move it as far as
/// you like; Select or Back puts it down — nothing else takes focus.
struct SettingsEntryRow: View {
    @Environment(\.settingsScroll) private var scroll
    let title: String
    /// Its identity in the list (for scrolling it into view while moving).
    var scrollID: String? = nil
    var dimmed = false
    var leading: AnyView? = nil
    /// A quiet value before the controls (as a settings row's).
    var value: String? = nil
    /// Kept as an empty slot when nil and `reservesExtra` (so rows align).
    var extra: SettingsEntryAction? = nil
    var reservesExtra = false
    let actions: [SettingsEntryAction]
    /// The id of the action that starts moving.
    var moveID = "move"
    var toggle: SettingsEntrySwitch? = nil
    var remove: SettingsEntryAction? = nil
    let isMoving: Bool
    let anyMoving: Bool
    /// One step up (−1) or down (+1).
    var onMoveStep: (Int) -> Void = { _ in }
    var onDrop: () -> Void = {}

    @FocusState private var focused: String?

    private var focusedName: String? {
        if isMoving { return "Up and Down move it, Select puts it down" }
        guard let focused else { return nil }
        if focused == "switch" { return toggle?.title }
        return ([extra, remove].compactMap { $0 } + actions).first { $0.id == focused }?.title
    }

    var body: some View {
        HStack(spacing: 16) {
            if let leading { leading.frame(width: 40, height: 40) }
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                    .foregroundStyle(Color.white.opacity(dimmed && !isMoving ? 0.45 : FixedFocusText.primary))
                    .lineLimit(1)
                if let focusedName {
                    Text("· " + focusedName)
                        .font(.system(size: 23))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 16)
            if let value {
                Text(value)
                    .font(.system(size: SettingsMetrics.valueTextSize))
                    .foregroundStyle(SettingsMetrics.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 14) {
                if let extra {
                    button(extra)
                } else if reservesExtra {
                    Color.clear.frame(width: SettingsIconButton.size, height: SettingsIconButton.size)
                }
                ForEach(actions) { button($0) }
                if let toggle {
                    SettingsSwitchButton(isOn: toggle.isOn, action: toggle.toggle)
                        .focused($focused, equals: "switch")
                        .disabled(anyMoving)
                }
                if let remove { button(remove, destructive: true) }
            }
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .frame(height: SettingsMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius, style: .continuous)
                .fill(Color.white.opacity(isMoving ? 0.18 : (focused != nil ? 0.1 : 0.05)))
        )
        .scaleEffect(isMoving ? 1.02 : 1)
        .shadow(color: .black.opacity(isMoving ? 0.35 : 0), radius: 18, y: 10)
        .animation(.smooth(duration: 0.18), value: isMoving)
        .animation(.smooth(duration: 0.15), value: focused)
        .focusSection()
        .id(scrollID ?? title)
    }

    private func button(_ action: SettingsEntryAction, destructive: Bool = false) -> some View {
        let isTheMove = isMoving && action.id == moveID
        return SettingsIconButton(icon: isTheMove ? "checkmark" : action.icon, destructive: destructive) {
            isTheMove ? onDrop() : action.action()
        }
        .focused($focused, equals: action.id)
        .disabled(anyMoving && !isTheMove)
        .onMoveCommand { direction in
            guard isTheMove else { return }
            switch direction {
            case .up: withAnimation(.smooth(duration: 0.2)) { onMoveStep(-1) }
            case .down: withAnimation(.smooth(duration: 0.2)) { onMoveStep(1) }
            default: return
            }
            // After the list has taken the new order: into view, if it left it.
            let id = scrollID ?? title
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.2)) { scroll?.scrollTo(id) }
            }
        }
        // Only while moving — otherwise Back goes back.
        .onExitCommand(perform: isTheMove ? onDrop : nil)
    }
}

/// A small round icon button: translucent at rest, the light platter with a
/// dark symbol focused; destructive ones red.
struct SettingsIconButton: View {
    static let size: CGFloat = 48
    let icon: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(Style(destructive: destructive))
    }

    private struct Style: ButtonStyle {
        let destructive: Bool
        func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, destructive: destructive) }
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let destructive: Bool
        private static let red = Color(red: 1, green: 0.27, blue: 0.23)

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? (destructive ? Color.white : SettingsMetrics.focusedText)
                                           : (destructive ? Self.red : SettingsMetrics.primaryText))
                .background {
                    // Focused: the top bar's glass highlight (red to remove).
                    if isFocused, !destructive { GlassHighlight(focused: true, shape: Circle()) }
                    else {
                        Circle().fill(isFocused ? Self.red
                                      : (destructive ? Self.red.opacity(0.18) : FlatControl.rest))
                    }
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.04 : 1.12) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
                .animation(.smooth(duration: 0.15), value: isFocused)
        }
    }
}

/// A capsule with an icon and its name, for an action that needs saying
/// (by a list's heading); destructive ones red: a red edge and text at
/// rest, solid red focused.
struct SettingsLabelButton: View {
    let icon: String
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 24, weight: .semibold))
                .padding(.horizontal, 24)
                .frame(height: 56)
        }
        .buttonStyle(Style(destructive: destructive))
    }

    private struct Style: ButtonStyle {
        let destructive: Bool
        func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, destructive: destructive) }
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let destructive: Bool
        private static let red = Color(red: 1, green: 0.27, blue: 0.23)

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? (destructive ? Color.white : SettingsMetrics.focusedText)
                                           : (destructive ? Self.red : SettingsMetrics.primaryText))
                .background {
                    if isFocused, !destructive { GlassHighlight(focused: true, shape: Capsule()) }
                    else {
                        Capsule().fill(isFocused ? Self.red
                                       : (destructive ? Self.red.opacity(0.18) : FlatControl.rest))
                    }
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 0.97 : 1.05) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
                .animation(.smooth(duration: 0.15), value: isFocused)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// The on / off switch, as Apple draws it: green with the knob right when
/// on, grey with it left when off. Focused, it lifts with a light ring.
struct SettingsSwitchButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Track(isOn: isOn) }
            .buttonStyle(Style())
    }

    private struct Track: View {
        let isOn: Bool
        var body: some View {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color.white.opacity(0.22))
                Circle().fill(Color.white).padding(3)
            }
            .frame(width: 66, height: 38)
            .animation(.smooth(duration: 0.2), value: isOn)
        }
    }

    private struct Style: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        var body: some View {
            configuration.label
                .padding(5)
                .overlay(Capsule().strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 3))
                .scaleEffect(isFocused ? 1.1 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
                .animation(.smooth(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - The keyboard, at once

/// A text to edit on the tvOS keyboard (see `KeyboardPresenter`).
struct KeyboardRequest: Identifiable {
    let id = UUID()
    let text: String
    let placeholder: String
    /// The text when the keyboard closes (empty: cleared).
    let onCommit: (String) -> Void
}

/// Opens the tvOS keyboard STRAIGHT AWAY for a `KeyboardRequest` — no field
/// to select first: a hidden text field becomes first responder, which on
/// tvOS presents the keyboard screen. Place it once on the page.
struct KeyboardPresenter: UIViewRepresentable {
    @Binding var request: KeyboardRequest?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HiddenField {
        let field = HiddenField()
        field.delegate = context.coordinator
        field.alpha = 0.01
        return field
    }

    func updateUIView(_ field: HiddenField, context: Context) {
        context.coordinator.request = $request
        guard let request, context.coordinator.shown != request.id else { return }
        context.coordinator.shown = request.id
        field.text = request.text
        field.placeholder = request.placeholder
        DispatchQueue.main.async { field.becomeFirstResponder() }
    }

    /// Never takes focus itself (the keyboard is all that's wanted).
    final class HiddenField: UITextField {
        override var canBecomeFocused: Bool { false }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var request: Binding<KeyboardRequest?>?
        var shown: UUID?

        func textFieldDidEndEditing(_ field: UITextField) {
            if let current = request?.wrappedValue, current.id == shown {
                current.onCommit(field.text ?? "")
            }
            request?.wrappedValue = nil
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}
