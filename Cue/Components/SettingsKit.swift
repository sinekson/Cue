import SwiftUI

// THE SETTINGS LOOK — one column, centred, a level at a time: the
// categories (`ATVSettingsView`), a category's settings, the pages its rows
// open (a list to manage, a sign-in) — each in its place (`SettingsNav`);
// Back goes up a level.
// Rows rest on a faint fill and, focused, sit on the top bar's light
// highlight; on the left an icon (`SettingsIcon`) and under it the focused
// row's description, else the page's (`SettingsDescriptionText`). (Tried: in
// a card right of the rows, following focus; a row's description under
// its pill, always; an info pane beside the rows with
// the category's symbol in a box and the description below it — the box
// wasted room, the words were far from their row.)
//
// - `SettingsPage`: a category's settings, in the column.
// - `SettingsSection`: a titled group of rows.
// - Rows: `SettingsToggleRow` (Select flips On / Off), `SettingsChoiceRow`
//   (Select opens the options in the glass dropdown), `SettingsLinkRow`
//   (opens a page in the column), `SettingsButtonRow` (runs an action).

enum SettingsMetrics {
    /// Apple TV's Settings, measured off its screen (1920 × 1080 pt):
    /// 65 pt capsules, 80 pt apart, 38 pt text (the name medium, the value
    /// regular) 30 pt in from the ends, the chevron 36 pt from the end.
    static let rowHeight: CGFloat = 65
    static var rowRadius: CGFloat { rowHeight / 2 }
    /// A row's text from its ends. Labels outside the rows line up with it.
    static let rowInset: CGFloat = 30
    static var labelIndent: CGFloat { rowInset }
    /// The chevron's extra room at the row's end (36 pt from it).
    static let chevronInset: CGFloat = 6
    static let rowTextSize: CGFloat = 38
    /// A page's title and its sections' labels (57 pt semibold, centred on
    /// the screen; 29 pt semibold capitals).
    static let titleTextSize: CGFloat = 57
    static let sectionTextSize: CGFloat = 29
    static let valueTextSize: CGFloat = 38
    /// A row's bottom to the next section's label.
    static let sectionGap: CGFloat = 46
    static let rowGap: CGFloat = 15
    /// Rows holding buttons (Apple's Languages): 119 pt tall, 30 pt
    /// corners, 16 apart; their round buttons 66 pt, centres 117 apart,
    /// the last 18 pt from the row's end.
    static let tallRowHeight: CGFloat = 119
    static let tallRowRadius: CGFloat = 30
    static let tallRowGap: CGFloat = 16
    /// From a list's last row to the button under it (Apple's Add
    /// Language…, measured).
    static let listButtonGap: CGFloat = 29
    /// A page's title at most this wide, centred ("…" past it).
    static let titleMaxWidth: CGFloat = 800
    static let rowButtonSize: CGFloat = 66
    static let rowButtonGap: CGFloat = 51
    static let rowButtonInset: CGFloat = 18
    /// A row's button on the row's own fill: lighter than it.
    static let rowButtonFill = Color.white.opacity(0.16)
    /// Apple's extra room between a button and the rows only to read under it.
    static let infoGap: CGFloat = 14
    /// Focused: the platter 4.5 pt larger each side (788 × 74), its content
    /// a little larger (the width's share).
    static let focusScale: CGFloat = 1.012
    static let focusGrowth: CGFloat = 4.5
    /// The rows' column, on the screen's right: 1060 pt in, 779 wide.
    static let columnX: CGFloat = 1060
    static let columnWidth: CGFloat = 779
    /// On the left, centred 525 in, Apple's picture: a 537 pt square tile
    /// (Apple's corners), its top 48 below the first row's (Apple's); the
    /// description under it as Apple's, centred.
    static let iconCenterX: CGFloat = 525
    static let iconSize = CGSize(width: 537, height: 537)
    static let iconRadius: CGFloat = 112
    static let iconSymbolSize: CGFloat = 180
    static let iconBelowTop: CGFloat = 48
    static let descriptionGapBelowIcon: CGFloat = 56
    static let descriptionWidth: CGFloat = 880
    static let descriptionTextSize: CGFloat = 29
    /// The first row's (or section label's) top, whether the page starts
    /// with a label or a row: as far under the title as Apple's (its 189
    /// under a title at 56) — 254 under ours at 121.
    static let top: CGFloat = 254
    /// The title's top: Apple's (56) lowered well clear of our top bar.
    static let titleTop: CGFloat = 121

    /// The focused platter: the top bar's bright glass highlight
    /// (`GlassHighlight`); this, where a plain fill is needed.
    static let focusedFill = FlatControl.focus
    static let restingFill = FlatControl.restSubtle
    static let focusedText = Color.black
    /// The app's text levels (`FixedFocusText`): names and titles, values
    /// and descriptions, section labels.
    static let primaryText = Color.white.opacity(FixedFocusText.primary)
    static let secondaryText = Color.white.opacity(FixedFocusText.secondary)
    static let labelText = Color.white.opacity(FixedFocusText.tertiary)
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

    /// Which way the last change went. Not published: a page going out
    /// reads it as it leaves (`SettingsPageMove`) — its transition is
    /// otherwise the one from before the change.
    private(set) var forward = true

    /// A page changing: no row lights on the new page until it's at rest
    /// (focus is there all along, unseen). The page going out is frozen as
    /// it was, so its lit row rides out with it, fading with its rows.
    @Published private(set) var settling = false
    private var settle: Task<Void, Never>?

    /// Measured off Apple TV's Settings: half the way in ~0.2 s, then a
    /// long landing; the highlight about 0.15 s after it.
    private static let motion = Animation.spring(duration: 0.55, bounce: 0)
    private static let settleTime: TimeInterval = 0.7

    private func change(forward: Bool, _ update: () -> Void) {
        self.forward = forward
        withAnimation(Self.motion) {
            settling = true
            update()
        }
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleTime))
            guard !Task.isCancelled else { return }
            self?.settling = false
        }
    }

    func push(_ view: some View) {
        let page = Page(view: AnyView(view))
        change(forward: true) { self.stack.append(page) }
    }

    /// False when there was nothing to take off.
    @discardableResult
    func pop() -> Bool {
        guard !stack.isEmpty else { return false }
        change(forward: false) { _ = self.stack.popLast() }
        return true
    }

    /// The category whose pages are in the column (its symbol on the tile);
    /// set as its page appears, nil with none in the column.
    @Published var category: SettingsCategory?

    /// Out of the column (Back on its first page) — set by its host.
    var leave: () -> Void = {}

    /// Back a page, or out when there's none (a page opened as the
    /// column's first — the gate's profiles).
    func back() { if !pop() { leave() } }
}

/// A level's rows between pages, as Apple TV's Settings': into a page the
/// rows go left and the new ones come from the right; Back the other way.
/// The old rows fade early, the new ones over the whole move. The title and
/// description aren't on the page, so they fade in place
/// (`SettingsPageHeaderKey`).
struct SettingsPageMove: ViewModifier {
    @EnvironmentObject private var nav: SettingsNav
    /// Off to the right (1) or left (-1) going forward; 0: in place.
    let side: CGFloat

    static let distance: CGFloat = 200

    func body(content: Content) -> some View {
        content.offset(x: side * Self.distance * (nav.forward ? 1 : -1))
    }
}

extension AnyTransition {
    static var settingsPage: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity.animation(.easeInOut(duration: 0.5))
                .combined(with: .modifier(active: SettingsPageMove(side: 1),
                                          identity: SettingsPageMove(side: 0))),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.25))
                .combined(with: .modifier(active: SettingsPageMove(side: -1),
                                          identity: SettingsPageMove(side: 0))))
    }
}

/// The column's rows, for Select on a category: each row reports its name
/// (in order, top to bottom) and takes the screen's row focus by it — the
/// first one gets focus.
private struct SettingsRowFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<String?>.Binding? = nil
}

/// While the top bar holds focus: the one row Down goes back to (the others
/// take no focus, so the engine can't pick one by where it is).
private struct SettingsOnlyRowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// The focused row and its description (nil: none — the page's shows),
/// reported up to its page, which shows it left of the rows
/// (`SettingsDescriptionText`).
struct SettingsDescribedKey: PreferenceKey {
    struct Described {
        let text: String?
        let pill: Anchor<CGRect>
    }
    static let defaultValue: Described? = nil
    static func reduce(value: inout Described?, nextValue: () -> Described?) {
        value = value ?? nextValue()
    }
}

/// No row lights (`SettingsNav.settling`).
private struct SettingsFocusHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsFocusHidden: Bool {
        get { self[SettingsFocusHiddenKey.self] }
        set { self[SettingsFocusHiddenKey.self] = newValue }
    }
}

/// The page's title and line, reported up to the screen, which draws them.
struct SettingsPageHeaderKey: PreferenceKey {
    struct Header: Equatable {
        let title: String
        let subtitle: String
    }
    static let defaultValue: Header? = nil
    /// The newest page's, with a page on its way out beside it.
    static func reduce(value: inout Header?, nextValue: () -> Header?) {
        value = nextValue() ?? value
    }
}

struct SettingsRowsKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

extension EnvironmentValues {
    var settingsRowFocus: FocusState<String?>.Binding? {
        get { self[SettingsRowFocusKey.self] }
        set { self[SettingsRowFocusKey.self] = newValue }
    }
    var settingsOnlyRow: String? {
        get { self[SettingsOnlyRowKey.self] }
        set { self[SettingsOnlyRowKey.self] = newValue }
    }
}

struct SettingsRowEntry: ViewModifier {
    @Environment(\.settingsRowFocus) private var focus
    @Environment(\.settingsOnlyRow) private var only
    let id: String

    func body(content: Content) -> some View {
        Group {
            if let focus { content.focused(focus, equals: id) } else { content }
        }
        .disabled(only.map { $0 != id } ?? false)
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
/// Home's section hint, small and widely spaced).
struct SettingsSection<Content: View>: View {
    var title: String = ""
    /// Rows holding buttons: `tallRowGap`.
    var spacing = SettingsMetrics.rowGap
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Untitled: the rows alone, no label's room.
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: SettingsMetrics.sectionTextSize, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.labelText)
                    .padding(.leading, SettingsMetrics.labelIndent)
            }
            content
        }
        .focusSection()
    }
}

// MARK: - Rows

/// A row's content: name left, value (and chevron) right; focused, its
/// description left of the rows. (Tried: in a card right of the rows; inside the pill,
/// under the name — the pill grew tall; under the pill only while focused,
/// the rows below stepping down to make room; under the pill, always.)
struct SettingsRowLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsFocusHidden) private var focusHidden
    let title: String
    var value: String? = nil
    var chevron = false
    var checked = false
    var description: String? = nil
    /// Before the name (a profile's avatar).
    var leading: AnyView? = nil
    /// In the value's place (the ratings' order: their chips).
    var trailing: AnyView? = nil

    private var lit: Bool { isFocused && !focusHidden }

    var body: some View {
        HStack(spacing: 16) {
            leading
            Text(title)
                .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                .foregroundStyle(lit ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                .lineLimit(1)
            Spacer(minLength: 24)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: SettingsMetrics.valueTextSize))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText.opacity(0.6)
                                               : SettingsMetrics.secondaryText)
                    .lineLimit(1)
            }
            trailing
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText.opacity(0.45)
                                               : SettingsMetrics.secondaryText)
                    .padding(.leading, 14)
                    .padding(.trailing, SettingsMetrics.chevronInset)
            }
        }
        .frame(height: SettingsMetrics.rowHeight)
        .padding(.horizontal, SettingsMetrics.rowInset)
        .anchorPreference(key: SettingsDescribedKey.self, value: .bounds) { pill in
            guard isFocused else { return nil }
            return .init(text: description?.isEmpty == false ? description : nil, pill: pill)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.focus, value: lit)
    }
}

/// A row only to read (Apple's way): name and value as a row's, no fill,
/// no focus. Only ever below the buttons, none under it: a page's rows to
/// read come last.
struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        SettingsRowLabel(title: title, value: value)
    }
}

/// A page with nothing to press holds focus here, unseen: else it left for
/// the top bar.
struct SettingsFocusHolder: View {
    var body: some View {
        Color.white.opacity(0.001)
            .frame(height: 1)
            .focusable()
            .modifier(SettingsRowEntry(id: "holder"))
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
        @Environment(\.settingsFocusHidden) private var focusHidden
        let configuration: ButtonStyle.Configuration
        let onHold: (() -> Void)?
        let didHold: Binding<Bool>?
        @State private var holdTask: Task<Void, Never>?

        private var lit: Bool { isFocused && !focusHidden }

        private var pill: some View {
            let shape = Capsule(style: .continuous)
            return Group {
                if lit { GlassHighlight(focused: true, shape: shape) }
                else { shape.fill(SettingsMetrics.restingFill) }
            }
            .shadow(color: .black.opacity(lit ? 0.3 : 0), radius: 16, y: 8)
        }

        /// Focused, the platter's extra height each side (beyond the scale).
        private var growth: CGFloat {
            guard lit, !configuration.isPressed else { return 0 }
            return SettingsMetrics.focusGrowth
                - SettingsMetrics.rowHeight * (SettingsMetrics.focusScale - 1) / 2
        }

        var body: some View {
            configuration.label
                .background {
                    pill.padding(.vertical, -growth)
                }
                .scaleEffect(lit && !configuration.isPressed ? SettingsMetrics.focusScale : 1,
                             anchor: .top)
                .animation(.smooth(duration: 0.18), value: lit)
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
/// current one checked — Select picks it, the page stays (Back goes up).
struct SettingsOptionsRow: View {
    @EnvironmentObject private var nav: SettingsNav
    let title: String
    var description: String? = nil
    /// The options page's line under its title, when it's not the row's
    /// description (a row without one).
    var pageDescription: String? = nil
    let options: [SettingsOption]
    let selection: String
    let onPick: (String) -> Void

    var body: some View {
        Button {
            nav.push(SettingsOptionsPage(title: title, subtitle: pageDescription ?? description ?? "",
                                         options: options, selection: selection, onPick: onPick))
        } label: {
            SettingsRowLabel(title: title, value: options.first { $0.id == selection }?.label,
                             chevron: true, description: description)
        }
        .settingsRow(id: title)
    }
}

private struct SettingsOptionsPage: View {
    let title: String
    let subtitle: String
    let options: [SettingsOption]
    @State var selection: String
    let onPick: (String) -> Void

    var body: some View {
        SettingsPage(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ForEach(options) { option in
                    Button {
                        selection = option.id
                        onPick(option.id)
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
    var trailing: AnyView? = nil
    @ViewBuilder let destination: Destination

    var body: some View {
        Button { nav.push(destination) } label: {
            SettingsRowLabel(title: title, value: value, chevron: true, description: description,
                             trailing: trailing)
        }
        .settingsRow(id: title)
    }
}

extension DateFormatter {
    /// When something last happened, as a row's value ("Today at 22:34").
    static let settingsWhen: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
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

/// A page as Apple TV's Settings, the picture's place holding an icon (the
/// screen's, `ATVSettingsView`) and under it the focused row's
/// description, else the page's (`SettingsDescriptionText`): the
/// title centred over the screen, the rows in the right column, its round
/// buttons at the column's end on the title's line. Only the rows scroll,
/// from where the first starts, fading out over a short edge above it.
/// The reader goes to the rows (`settingsScroll`): a row being MOVED keeps
/// focus, so the system never scrolls for it — the row scrolls itself into
/// view on every step. (Tried: one centred column, the title over it.)
struct SettingsScrollingPage<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    /// The rows' fade above the first row, as Apple's: from ~18 pt under
    /// the title down to where the first row starts.
    static var edge: CGFloat { 47 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
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
        .padding(.top, SettingsMetrics.top - Self.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preference(key: SettingsPageHeaderKey.self, value: .init(title: title, subtitle: subtitle))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: SettingsMetrics.rowGap) { accessory }
                .focusSection()
                .padding(.top, SettingsMetrics.titleTop)
        }
    }
}

/// The focused row's description (else the page's), left of the rows,
/// under the icon, staying there; plain text, centred, the new one
/// crossfading in. Nothing to say: it fades away.
struct SettingsDescriptionText: View {
    let text: String
    @State private var shown = ""

    var body: some View {
        Text(shown)
            .font(.system(size: SettingsMetrics.descriptionTextSize))
            .foregroundStyle(Color.white.opacity(FixedFocusText.body))
            .lineSpacing(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .id(shown)
            .transition(.opacity)
            .frame(width: SettingsMetrics.descriptionWidth, alignment: .top)
            .opacity(text.isEmpty ? 0 : 1)
            .onChange(of: text, initial: true) { _, new in
                guard !new.isEmpty else { return }
                withAnimation(Motion.fade) { shown = new }
            }
            .animation(Motion.fade, value: text.isEmpty)
            .allowsHitTesting(false)
    }
}

private struct SettingsScrollKey: EnvironmentKey {
    static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
    /// The page's scroll view (see `SettingsScrollingPage`).
    var settingsScroll: ScrollViewProxy? {
        get { self[SettingsScrollKey.self] }
        set { self[SettingsScrollKey.self] = newValue }
    }
}

/// An on / off of an entry, as a switch.
struct SettingsEntrySwitch {
    let isOn: Bool
    /// Its name while focused ("Turn off", "Show").
    let title: String
    let toggle: () -> Void
}

/// A labelled button on the title's line (Apple's Edit, Cancel, Done): a
/// capsule 71 pt tall, its text 36 pt in, flat at rest; focused white, dark
/// text, lifted (~75 tall).
struct SettingsCapsuleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(title: title) }
            .buttonStyle(PlainCardButtonStyle())
            .modifier(SettingsRowEntry(id: title))
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let title: String

        var body: some View {
            Text(title)
                .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                .foregroundStyle(focused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                .padding(.horizontal, 36)
                .frame(height: 71)
                .background {
                    Capsule(style: .continuous).fill(focused ? FlatControl.focus : FlatControl.rest)
                        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 16, y: 8)
                }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

/// A row of a list that reorders (Apple's, as its Languages): the name,
/// the whole row one focus. At rest the row lights when focused, Select
/// does the list's thing (`onSelect`: Rating Providers start Edit, an
/// add-on opens its page — then a chevron); in Edit its round buttons show
/// at its end — an on / off when the list has one (`toggle`: an eye, struck
/// through when off), then the ≡ handle — and focus is theirs (the row
/// stays as it is, the focused one lights); Select on the handle lifts the
/// row — it lights whole, the buttons their symbols alone: Up / Down move
/// it as far as you like, Select or Back puts it down — nothing else takes
/// focus meanwhile.
struct SettingsReorderRow: View {
    @Environment(\.settingsScroll) private var scroll
    let title: String
    let id: String
    var leading: AnyView? = nil
    /// A quiet value at its end ("Off").
    var value: String? = nil
    var chevron = false
    var dimmed = false
    var toggle: SettingsEntrySwitch? = nil
    let editing: Bool
    let isMoving: Bool
    let anyMoving: Bool
    let onSelect: () -> Void
    let onLift: () -> Void
    /// One step up (−1) or down (+1).
    let onMoveStep: (Int) -> Void
    let onDrop: () -> Void

    private enum Part: Hashable { case row, toggle, handle }
    @FocusState private var focused: Part?

    /// At rest and lifted: the row lights. In Edit otherwise: only a button.
    @Environment(\.settingsFocusHidden) private var focusHidden
    private var lit: Bool { (!editing && focused == .row && !focusHidden) || isMoving }

    var body: some View {
        Group {
            if editing {
                face
            } else {
                Button(action: onSelect) { face }
                    .buttonStyle(PressStyle())
                    .focused($focused, equals: .row)
                    .modifier(SettingsRowEntry(id: id))
            }
        }
        // Lifted, how to move it; on the on / off, what it does — left of
        // the rows.
        .anchorPreference(key: SettingsDescribedKey.self, value: .bounds) { pill in
            guard focused != nil || isMoving else { return nil }
            return .init(text: isMoving ? "Up and Down move it; Select puts it down."
                             : focused == .toggle ? toggle?.title : nil, pill: pill)
        }
        .focusSection()
        .id(id)
    }

    private var face: some View {
        HStack(spacing: 16) {
            if let leading { leading.frame(width: 40, height: 40) }
            Text(title)
                .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                .foregroundStyle(lit ? SettingsMetrics.focusedText
                                 : dimmed ? SettingsMetrics.labelText : SettingsMetrics.primaryText)
                .lineLimit(1)
            Spacer(minLength: 24)
            // In Edit the on / off says it.
            if let value, !editing {
                Text(value)
                    .font(.system(size: SettingsMetrics.valueTextSize))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText.opacity(0.6) : SettingsMetrics.secondaryText)
                    .lineLimit(1)
            }
            if editing {
                HStack(spacing: SettingsMetrics.rowButtonGap) {
                    if let toggle {
                        Button(action: toggle.toggle) {
                            SettingsRowButtonFace(icon: toggle.isOn ? "eye" : "eye.slash", focused: focused == .toggle, onLitRow: lit)
                        }
                        .buttonStyle(PressStyle())
                        .focused($focused, equals: .toggle)
                        .disabled(anyMoving)
                    }
                    Button { isMoving ? onDrop() : onLift() } label: {
                        SettingsRowButtonFace(icon: "line.3.horizontal", focused: focused == .handle && !isMoving, onLitRow: lit)
                    }
                    .buttonStyle(PressStyle())
                    .focused($focused, equals: .handle)
                    .modifier(SettingsRowEntry(id: id))
                    .disabled(anyMoving && !isMoving)
                    .onMoveCommand { direction in
                        guard isMoving else { return }
                        switch direction {
                        case .up: withAnimation(.smooth(duration: 0.2)) { onMoveStep(-1) }
                        case .down: withAnimation(.smooth(duration: 0.2)) { onMoveStep(1) }
                        default: return
                        }
                        // After the list has taken the new order: into view, if it left it.
                        DispatchQueue.main.async {
                            withAnimation(.smooth(duration: 0.2)) { scroll?.scrollTo(id) }
                        }
                    }
                    // Only while moving — otherwise Back goes to the page.
                    .onExitCommand(perform: isMoving ? onDrop : nil)
                }
                .transition(.opacity)
            } else if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText.opacity(0.45) : SettingsMetrics.secondaryText)
                    .padding(.leading, 14)
                    .padding(.trailing, SettingsMetrics.chevronInset - SettingsMetrics.rowButtonInset
                             + SettingsMetrics.rowInset)
            }
        }
        .padding(.leading, SettingsMetrics.rowInset)
        .padding(.trailing, SettingsMetrics.rowButtonInset)
        .frame(height: SettingsMetrics.tallRowHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: SettingsMetrics.tallRowRadius, style: .continuous)
            Group {
                if lit { GlassHighlight(focused: true, shape: shape) }
                else { shape.fill(SettingsMetrics.restingFill) }
            }
            .padding(.vertical, lit ? -(SettingsMetrics.focusGrowth
                - SettingsMetrics.tallRowHeight * (SettingsMetrics.focusScale - 1) / 2) : 0)
            .shadow(color: .black.opacity(isMoving ? 0.4 : (lit ? 0.3 : 0)),
                    radius: isMoving ? 24 : 16, y: isMoving ? 12 : 8)
        }
        .scaleEffect(isMoving ? 1.03 : (lit ? SettingsMetrics.focusScale : 1))
        .animation(.smooth(duration: 0.18), value: lit)
        .animation(.smooth(duration: 0.15), value: focused)
        .animation(.smooth(duration: 0.18), value: isMoving)
        .animation(.smooth(duration: 0.2), value: editing)
    }

    /// No system focus look: the row draws it.
    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// A round button, as the rows' others: focused the light platter, dark
/// symbol, lifted; on a lit row its symbol alone.
struct SettingsRowButtonFace: View {
    let icon: String
    let focused: Bool
    let onLitRow: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(focused ? SettingsMetrics.focusedText
                             : onLitRow ? SettingsMetrics.focusedText.opacity(0.45)
                             : SettingsMetrics.primaryText)
        .frame(width: SettingsMetrics.rowButtonSize, height: SettingsMetrics.rowButtonSize)
        .background {
            if focused { GlassHighlight(focused: true, shape: Circle()) }
            else { Circle().fill(SettingsMetrics.rowButtonFill).opacity(onLitRow ? 0 : 1) }
        }
        .scaleEffect(focused ? 1.12 : 1)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 10, y: 5)
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
