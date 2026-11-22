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

    static let restingFill = FlatControl.restSubtle
    static let focusedText = Color.black
    /// The app's text levels (`FixedFocusText`): names and titles, values
    /// and descriptions, section labels.
    static let primaryText = CueInk.primary
    static let secondaryText = CueInk.secondary
    static let labelText = CueInk.tertiary
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

    /// False when there was nothing to take off. `with`: changes made in
    /// the same update, which the page going out, frozen, never sees.
    @discardableResult
    func pop(with update: () -> Void = {}) -> Bool {
        guard !stack.isEmpty else { return false }
        change(forward: false) {
            update()
            _ = self.stack.popLast()
        }
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

private struct SettingsCardsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsInCardKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsOpenTitleKey: EnvironmentKey {
    static let defaultValue: ((MetaItem) -> Void)? = nil
}

extension EnvironmentValues {
    /// Settings 2: a page's place ("Storage › Cache"), drawn at the top of
    /// its scroll so it goes up with the page.
    @Entry var settingsPath: AnyView? = nil

    /// Settings 2's look (`CardSettingsRoot`): sections as flat cards, the
    /// description inside the row, focus Upcoming's white plate.
    var settingsCards: Bool {
        get { self[SettingsCardsKey.self] }
        set { self[SettingsCardsKey.self] = newValue }
    }

    /// Opens a title's Details from Settings (its tab's stack).
    var settingsOpenTitle: ((MetaItem) -> Void)? {
        get { self[SettingsOpenTitleKey.self] }
        set { self[SettingsOpenTitleKey.self] = newValue }
    }

    /// Inside a section's card (Settings 2): a note draws no card of its own.
    var settingsInCard: Bool {
        get { self[SettingsInCardKey.self] }
        set { self[SettingsInCardKey.self] = newValue }
    }

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
    @Environment(\.settingsCards) private var cards

    var body: some View {
        SettingsScrollingPage(title: title, subtitle: subtitle) {
            accessory
        } content: {
            if cards {
                // Settings 2: rows not in a section go on a card together
                // (a page of one button, Account's Sign Out).
                Group(subviews: content) { parts in
                    VStack(alignment: .leading, spacing: 40) {
                        ForEach(Self.runs(parts), id: \.first!.id) { run in
                            if run.count == 1, run[0].containerValues.settingsOwnCard {
                                run[0]
                            } else {
                                SettingsSection { ForEach(run) { $0 } }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                    content
                }
            }
        }
    }

    /// Sections alone, the rest in runs between them.
    private static func runs(_ parts: SubviewsCollection) -> [[Subview]] {
        var runs: [[Subview]] = []
        var loose: [Subview] = []
        for part in parts {
            if part.containerValues.settingsOwnCard {
                if !loose.isEmpty { runs.append(loose); loose = [] }
                runs.append([part])
            } else {
                loose.append(part)
            }
        }
        if !loose.isEmpty { runs.append(loose) }
        return runs
    }
}

extension ContainerValues {
    /// A page's part with a card of its own, or none to have (a section, a
    /// note, the unseen focus holder): Settings 2 leaves it alone.
    @Entry var settingsOwnCard = false
    /// Only to read (`SettingsInfoRow`): sunk into the card, with the ones
    /// beside it, so it doesn't look like it can be pressed.
    @Entry var settingsEmbedded = false
}

/// A titled group of rows. Its label as Apple TV's Settings', measured:
/// 29 pt semibold capitals, no extra spacing, the title's grey (tried:
/// Home's section hint, small and widely spaced).
struct SettingsSection<Content: View>: View {
    var title: String = ""
    /// Rows holding buttons: `tallRowGap`.
    var spacing = SettingsMetrics.rowGap
    @ViewBuilder let content: Content
    @Environment(\.settingsCards) private var cards

    var body: some View {
        if cards {
            VStack(alignment: .leading, spacing: 0) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CueInk.tertiary)
                        .padding(.leading, CardSettingsRow.textInset)
                        .padding(.bottom, 12)
                }
                // A hairline between two rows (Upcoming's), under them: a
                // focused row's plate covers the ones beside it.
                // Rows only to read go together into a well sunk into the
                // card, a gap instead of the hairline beside it.
                Group(subviews: content) { rows in
                    let runs = Self.runs(rows)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                            let sunk = run[0].containerValues.settingsEmbedded
                            if index > 0 {
                                if sunk || runs[index - 1][0].containerValues.settingsEmbedded {
                                    // The well's bleed and a focus plate's, then
                                    // the inset between them.
                                    Color.clear.frame(height: 2 * CardSettingsRow.plateBleed + CardSettingsRow.plateInset)
                                } else {
                                    Self.hairline
                                }
                            }
                            if sunk {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(run.enumerated()), id: \.element.id) { i, row in
                                        if i > 0 { Self.hairline }
                                        row
                                    }
                                }
                                // Out to the card's edge by the plates' inset on
                                // every side, as a focus plate.
                                .background(EmbeddedWell().padding(.vertical, -CardSettingsRow.plateBleed))
                            } else {
                                run[0].zIndex(1)
                            }
                        }
                    }
                }
                .padding(CardSettingsRow.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
                    .fill(CardFocusPlate.cardFill))
                .environment(\.settingsInCard, true)
            }
            .focusSection()
            .preference(key: CardFirstLabelKey.self, value: !title.isEmpty)
            .containerValue(\.settingsOwnCard, true)
        } else {
            plain
        }
    }

    private static var hairline: some View {
        Rectangle()
            .fill(CueInk.color(0.10))
            .frame(height: 1)
            .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
            .padding(.vertical, 4)
    }

    /// Each row alone, but rows only to read together.
    private static func runs(_ rows: SubviewsCollection) -> [[Subview]] {
        var runs: [[Subview]] = []
        for row in rows {
            if row.containerValues.settingsEmbedded, let last = runs.last?.first,
               last.containerValues.settingsEmbedded {
                runs[runs.count - 1].append(row)
            } else {
                runs.append([row])
            }
        }
        return runs
    }

    private var plain: some View {
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
    /// What no menu undoes (Delete Profile): its name in red.
    var danger = false

    @Environment(\.settingsCards) private var cards

    private var lit: Bool { isFocused && !focusHidden }

    var body: some View {
        if cards { card } else { apple }
    }

    /// Settings 2's: the name over the description; value and chevron at
    /// the end, centred on the row (on the name's line, a two-line row's
    /// chevron sat high).
    private var card: some View {
        let ink = danger ? Color.red : isFocused ? Color.black : CueInk.primary
        let quiet = isFocused ? Color.black.opacity(0.6) : CueInk.body
        return HStack(spacing: 16) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 24))
                        .foregroundStyle(quiet)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 24))
                        .foregroundStyle(quiet)
                        .lineLimit(1)
                }
                trailing
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ink)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(quiet)
                }
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apple: some View {
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
            .containerValue(\.settingsEmbedded, true)
    }
}

/// Rows only to read, sunk into their card: a darker well with the focus
/// plates' corners, a soft shade along its top edge.
struct EmbeddedWell: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Spotlight.cornerRadius - CardSettingsRow.plateInset, style: .continuous)
            .fill(Color.black.opacity(scheme == .dark ? 0.22 : 0.06)
                .shadow(.inner(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 3, y: 1.5)))
    }
}

/// Rows only to read, together: tight in Apple's look; in Settings 2's
/// each its own row in the section, a hairline between.
struct SettingsInfoRows<Content: View>: View {
    @Environment(\.settingsCards) private var cards
    @ViewBuilder let content: Content

    var body: some View {
        if cards { Group { content } } else { VStack(spacing: 0) { content } }
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
            .containerValue(\.settingsOwnCard, true)
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

        @Environment(\.settingsCards) private var cards

        var body: some View {
            if cards { card } else { apple }
        }

        /// Settings 2's: nothing at rest, focused Settings 1's glass, flat.
        private var card: some View {
            configuration.label
                .background { CardFocusPlate(lit: isFocused) }
                .animation(.easeOut(duration: 0.12), value: isFocused)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
                .modifier(Hold(isPressed: configuration.isPressed, onHold: onHold, didHold: didHold, task: $holdTask))
        }

        private var apple: some View {
            configuration.label
                .background {
                    pill.padding(.vertical, -growth)
                }
                .scaleEffect(lit && !configuration.isPressed ? SettingsMetrics.focusScale : 1,
                             anchor: .top)
                .animation(.smooth(duration: 0.18), value: lit)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
                .modifier(Hold(isPressed: configuration.isPressed, onHold: onHold, didHold: didHold, task: $holdTask))
        }
    }

    /// Still pressed after `holdAfter`: the hold (the way Details' buttons
    /// watch for it — a long-press gesture is unreliable on tvOS buttons).
    private struct Hold: ViewModifier {
        let isPressed: Bool
        let onHold: (() -> Void)?
        let didHold: Binding<Bool>?
        @Binding var task: Task<Void, Never>?

        func body(content: Content) -> some View {
            content.onChange(of: isPressed) { _, pressed in
                task?.cancel()
                task = nil
                guard pressed, let onHold else { return }
                task = Task { @MainActor in
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
    /// What picking it means (a choice row says it while it's focused).
    var detail: String? = nil
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

struct SettingsOptionsPage: View {
    let title: String
    let subtitle: String
    let options: [SettingsOption]
    @State var selection: String
    let onPick: (String) -> Void

    var body: some View {
        SettingsPage(title: title, subtitle: subtitle) {
            SettingsSection {
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

/// A tall row (Apple's Languages' height) with a line under its name: a
/// short preview of what Select opens (Why These Rows: each reason, opened
/// in full in the About panel, `TextPanel`).
struct SettingsTallRow: View {
    let title: String
    let preview: String
    let id: String
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.settingsFocusHidden) private var focusHidden
    @Environment(\.settingsCards) private var cards
    private var lit: Bool { focused && !focusHidden }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPress(lift: SettingsMetrics.focusScale))
            .focused($focused)
            .modifier(SettingsRowEntry(id: id))
    }

    private var face: some View {
        let look = SettingsLook(cards: cards)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: cards ? 2 : 4) {
                Text(title)
                    .font(look.name)
                    .foregroundStyle(SettingsInk.name(lit, cards: cards))
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(preview)
                        .font(look.detail)
                        .foregroundStyle(SettingsInk.quiet(lit, cards: cards))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 24)
            Image(systemName: "chevron.right")
                .font(look.chevron)
                .foregroundStyle(SettingsInk.chevron(lit, cards: cards))
                .padding(.leading, 14)
                .padding(.trailing, look.chevronGap)
        }
        // Both sides as the add-ons' rows (`SettingsReorderRow`): the
        // chevron as far in from the end.
        .padding(.horizontal, look.inset)
        .settingsTallChrome(lit: lit, cards: cards)
    }
}

/// A row's sizes in either look: Apple TV's measures, or Settings 2's
/// (`settingsCards`: 24 pt words, the words 24 pt from the card's edge).
struct SettingsLook {
    let cards: Bool
    var name: Font { .system(size: cards ? 24 : SettingsMetrics.rowTextSize, weight: .medium) }
    var value: Font { .system(size: cards ? 24 : SettingsMetrics.valueTextSize) }
    var detail: Font { .system(size: cards ? 24 : SettingsMetrics.descriptionTextSize) }
    var chevron: Font {
        cards ? .system(size: 20, weight: .semibold) : .system(size: SettingsMetrics.rowTextSize, weight: .medium)
    }
    /// The words from the row's edge.
    var inset: CGFloat { cards ? CardSettingsRow.textInset - CardSettingsRow.plateInset : SettingsMetrics.rowInset }
    /// A round button from the row's end.
    var buttonInset: CGFloat { cards ? 8 : SettingsMetrics.rowButtonInset }
    var buttonGap: CGFloat { cards ? 16 : SettingsMetrics.rowButtonGap }
    var chevronGap: CGFloat { cards ? 0 : SettingsMetrics.chevronInset }
}

extension View {
    /// A tall row's chrome (lists, Watched, Why These Rows): Apple's fill
    /// and glass, or Settings 2's — nothing at rest, Upcoming's white plate.
    func settingsTallChrome(lit: Bool, moving: Bool = false, cards: Bool) -> some View {
        modifier(SettingsTallChrome(lit: lit, moving: moving, cards: cards))
    }
}

struct SettingsTallChrome: ViewModifier {
    let lit: Bool
    var moving = false
    let cards: Bool

    func body(content: Content) -> some View {
        if cards {
            content
                .padding(.vertical, 14)
                .frame(minHeight: 72)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // Flat when focused; a row being moved lifts.
                    CardFocusPlate(lit: lit)
                        .shadow(color: .black.opacity(moving ? 0.4 : 0), radius: 18, y: 9)
                }
                .scaleEffect(moving ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: lit)
                .animation(.smooth(duration: 0.18), value: moving)
        } else {
            content
                .frame(height: SettingsMetrics.tallRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: SettingsMetrics.tallRowRadius, style: .continuous)
                    Group {
                        if lit { GlassHighlight(focused: true, shape: shape) }
                        else { shape.fill(SettingsMetrics.restingFill) }
                    }
                    .padding(.vertical, lit ? -(SettingsMetrics.focusGrowth
                        - SettingsMetrics.tallRowHeight * (SettingsMetrics.focusScale - 1) / 2) : 0)
                    .shadow(color: .black.opacity(moving ? 0.4 : (lit ? 0.3 : 0)),
                            radius: moving ? 24 : 16, y: moving ? 12 : 8)
                }
                .scaleEffect(moving ? 1.03 : (lit ? SettingsMetrics.focusScale : 1))
                .animation(.smooth(duration: 0.18), value: lit)
                .animation(.smooth(duration: 0.18), value: moving)
        }
    }
}

/// A row's words in either look: dark on the lit plate, else the page's.
enum SettingsInk {
    static func name(_ lit: Bool, cards: Bool, dimmed: Bool = false) -> Color {
        lit ? (cards ? .black : SettingsMetrics.focusedText)
            : dimmed ? (cards ? CueInk.tertiary : SettingsMetrics.labelText)
            : (cards ? CueInk.primary : SettingsMetrics.primaryText)
    }
    static func quiet(_ lit: Bool, cards: Bool) -> Color {
        lit ? (cards ? .black.opacity(0.6) : SettingsMetrics.focusedText.opacity(0.6))
            : (cards ? CueInk.body : SettingsMetrics.secondaryText)
    }
    static func chevron(_ lit: Bool, cards: Bool) -> Color {
        lit ? (cards ? .black.opacity(0.6) : SettingsMetrics.focusedText.opacity(0.45))
            : (cards ? CueInk.body : SettingsMetrics.secondaryText)
    }
}

/// A line of text on a page (an empty list, About's running text), lined
/// up with the rows' words; in Settings 2 on a card of its own.
struct SettingsNote: View {
    @Environment(\.settingsCards) private var cards
    @Environment(\.settingsInCard) private var inCard
    let text: String
    /// Apple's look: a value's size (an empty list) or a description's.
    var large = false
    init(_ text: String, large: Bool = false) {
        self.text = text
        self.large = large
    }

    var body: some View {
        if cards {
            Text(text)
                .font(.system(size: 24))
                .foregroundStyle(CueInk.body)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, inCard ? CardSettingsRow.textInset - CardSettingsRow.plateInset
                                             : CardSettingsRow.textInset)
                .padding(.vertical, inCard ? 10 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
                    .fill(CardFocusPlate.cardFill).opacity(inCard ? 0 : 1))
        } else {
            Text(text)
                .font(.system(size: large ? SettingsMetrics.valueTextSize : SettingsMetrics.descriptionTextSize))
                .foregroundStyle(large ? SettingsMetrics.secondaryText : CueInk.body)
                .lineSpacing(large ? 0 : 6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsMetrics.rowInset)
        }
    }
}

/// Settings 2's colours, Settings 1's: the cards its rows' faint fill
/// (`restingFill`); a focused row its glass highlight, flat (no lift or
/// shadow: elevated, it didn't sit in the cards); the shown category the
/// glass's resting tint. Concentric with the card, 6 pt in; over the
/// hairlines beside its row.
struct CardFocusPlate: View {
    static let cardFill = SettingsMetrics.restingFill
    let lit: Bool
    var selected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Spotlight.cornerRadius - CardSettingsRow.plateInset,
                                     style: .continuous)
        // Glass only where it shows: hidden at opacity 0 it was still drawn,
        // two layers for every row.
        Group {
            if lit { GlassHighlight(focused: true, shape: shape) }
            else if selected { GlassHighlight(focused: false, shape: shape) }
        }
        .padding(.vertical, -CardSettingsRow.plateBleed)
    }
}

// MARK: - Rows with actions (Settings 2)

/// One of a row's actions: a pill.
struct SettingsAction: Identifiable {
    let title: String
    /// Its round button's symbol.
    let icon: String
    /// What no menu undoes (Remove): red words.
    var danger = false
    /// Lifts the row to move it (`ActionListRow.moving`).
    var move = false
    /// What stays the same as its title changes (Turn Off / Turn On), so
    /// focus stays on it: a renamed button was a new one, and focus fell
    /// to the page's top.
    var key: String? = nil
    /// An optical nudge for a lopsided symbol, in points (negative: left):
    /// centred by its box, sign-out's door and arrow read off-centre.
    var nudge: CGFloat = 0
    var action: () -> Void = {}
    var id: String { key ?? title }
}

/// A list item with its actions on the row itself (Settings 2): its
/// picture, its name, a detail line under it, its actions at its end as
/// round buttons; while focus is in the row it's on the selected tint, the
/// focused button the glass. Up /
/// Down: the next row's pill nearest. A Move pill lifts the row: Up / Down
/// move it, Select or Back puts it down, nothing else takes focus meanwhile.
struct ActionListRow: View {
    @Environment(\.settingsScroll) private var scroll
    let id: String
    var leading: AnyView? = nil
    /// The picture's room (a logo square, a poster tall).
    var leadingSize = CGSize(width: 56, height: 56)
    let title: String
    let detail: String
    var dimmed = false
    let actions: [SettingsAction]
    /// The page's focus, when it moves focus itself (to the next row after
    /// a removal): the buttons by "row id.action id"; else the row's own.
    var focus: FocusState<String?>.Binding? = nil
    /// In the column's focus (`settingsRowFocus`): a row on a category's
    /// own page, so Settings 2 knows focus is in the settings. Not for long
    /// lists: every move would redraw the column.
    var columnFocus = false
    @Environment(\.settingsRowFocus) private var columnBinding
    private var pageFocus: FocusState<String?>.Binding? { focus ?? (columnFocus ? columnBinding : nil) }
    /// This row is lifted / any row is.
    var moving = false
    var anyMoving = false
    var onMoveStep: (Int) -> Void = { _ in }
    var onDrop: () -> Void = {}

    @FocusState private var ownPill: String?
    /// The focused button's action id.
    private var pill: String? {
        guard let focus = pageFocus else { return ownPill }
        guard let value = focus.wrappedValue, value.hasPrefix(id + ".") else { return nil }
        return String(value.dropFirst(id.count + 1))
    }

    static let buttonSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 18) {
            // Off: its picture grey and faded, its words faded, at a glance
            // (its buttons stay as they are, to turn it on).
            HStack(spacing: 18) {
                if let leading {
                    leading.frame(width: leadingSize.width, height: leadingSize.height).saturation(dimmed ? 0 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(CueInk.primary)
                        .lineLimit(1)
                    // No second line where a list has nothing to say: the
                    // name centred (an empty line under it looked odd).
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 24))
                            .foregroundStyle(CueInk.body)
                            .lineLimit(1)
                    }
                }
            }
            .opacity(dimmed ? 0.6 : 1)
            Spacer(minLength: 24)
            // At the row's end, always shown.
            HStack(spacing: 14) {
                ForEach(actions) { action in
                    pillButton(action)
                }
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only a lifted row has a plate: the buttons are separate items
        // (a plate following focus from row to row flickered).
        .background {
            CardFocusPlate(lit: false, selected: moving)
                .shadow(color: .black.opacity(moving ? 0.35 : 0), radius: 18, y: 9)
        }
        .scaleEffect(moving ? 1.02 : 1)
        .animation(.smooth(duration: 0.18), value: moving)
        .focusSection()
        .id(id)
    }

    private func pillButton(_ action: SettingsAction) -> some View {
        let focused = pill == action.id
        let icon = action.move && moving ? "checkmark" : action.icon
        return Button {
            if action.move { moving ? onDrop() : action.action() } else { action.action() }
        } label: {
            // The pills' focus everywhere (the top bar, Discover, Details'
            // buttons): flat at rest; focused the white circle, dark symbol,
            // grown 10 % on focus's spring, the white quick in and out.
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(action.danger ? Color.red : focused ? FlatControl.contentOnFocus : CueInk.primary)
                .offset(x: action.nudge)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    ZStack {
                        Circle().fill(FlatControl.rest)
                        Circle().fill(DetailActionButton.focusFill)
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                            .opacity(focused ? 1 : 0)
                            .animation(focused ? DetailActionButton.open : DetailActionButton.outFade, value: focused)
                    }
                }
                .scaleEffect(focused ? DetailActionButton.detailsFocusScale : 1)
                .animation(Motion.focus, value: focused)
                .accessibilityLabel(action.title)
        }
        .buttonStyle(SettingsPress(lift: DetailActionButton.detailsFocusScale))
        .modifier(PillFocus(own: $ownPill, page: pageFocus, id: action.id, pageID: "\(id).\(action.id)"))
        .disabled(anyMoving && !(action.move && moving))
        // Only while lifted: otherwise the engine moves focus.
        .onMoveCommand(perform: action.move && moving ? { direction in
            switch direction {
            case .up: withAnimation(.smooth(duration: 0.2)) { onMoveStep(-1) }
            case .down: withAnimation(.smooth(duration: 0.2)) { onMoveStep(1) }
            default: return
            }
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.2)) { scroll?.scrollTo(id) }
            }
        } : nil)
        .onExitCommand(perform: action.move && moving ? onDrop : nil)
    }
}

/// A setting with a few choices, all on its row (Settings 2): its name and
/// description left, the choices right as pills — the chosen one on the
/// selected grey, the focused one the pills' white, grown as every pill.
/// Select picks. The description is the row's at rest, the focused
/// option's while one is focused, two lines' room always (nothing jumps).
/// For two or three choices; more open their page (`SettingsOptionsRow`),
/// On / Off is the row itself.
struct SettingsChoiceRow: View {
    @Environment(\.settingsRowFocus) private var columnFocus
    let id: String
    let title: String
    var description: String? = nil
    let options: [SettingsOption]
    let selection: String
    let onPick: (String) -> Void

    /// The option whose pill has focus.
    private var focusedOption: SettingsOption? {
        guard let value = columnFocus?.wrappedValue, value.hasPrefix(id + ".") else { return nil }
        let option = String(value.dropFirst(id.count + 1))
        return options.first { $0.id == option }
    }

    /// The chosen one says what it means, until focus moves to another.
    private var shownDetail: String {
        focusedOption?.detail ?? options.first { $0.id == selection }?.detail ?? description ?? ""
    }

    var body: some View {
        // Coming in, only the chosen pill takes focus (the top bar's way), so
        // passing through the row keeps its line still.
        let inRow = focusedOption != nil
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(CueInk.primary)
                    .lineLimit(1)
                Text(shownDetail)
                    .font(.system(size: 24))
                    .foregroundStyle(CueInk.body)
                    .lineLimit(1)
                    .animation(nil, value: shownDetail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                ForEach(options) { option in
                    ChoicePill(label: option.label, chosen: option.id == selection) { onPick(option.id) }
                        .modifier(SettingsRowEntry(id: "\(id).\(option.id)"))
                        .disabled(!inRow && option.id != selection)
                }
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private struct ChoicePill: View {
        let label: String
        let chosen: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) { Face(label: label, chosen: chosen) }
                .buttonStyle(SettingsPress(lift: DetailActionButton.detailsFocusScale))
        }

        private struct Face: View {
            @Environment(\.isFocused) private var focused
            let label: String
            let chosen: Bool

            var body: some View {
                Text(label)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(focused ? FlatControl.contentOnFocus : chosen ? CueInk.primary : CueInk.secondary)
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .background {
                        // The chosen one on the grey, the others nothing behind
                        // them (the top bar's tabs).
                        ZStack {
                            if chosen { Capsule().fill(FlatControl.selected) }
                            Capsule().fill(DetailActionButton.focusFill)
                                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                                .opacity(focused ? 1 : 0)
                                .animation(focused ? DetailActionButton.open : DetailActionButton.outFade, value: focused)
                        }
                    }
                    .scaleEffect(focused ? DetailActionButton.detailsFocusScale : 1)
                    .animation(Motion.focus, value: focused)
            }
        }
    }
}

/// On / Off as a choice row: two pills, Off first (the lowest left, as every row), the row's description under its name.
struct SettingsOnOffRow: View {
    let id: String
    let title: String
    var description: String? = nil
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        SettingsChoiceRow(id: id, title: title, description: description,
                          options: [SettingsOption(id: "off", label: "Off"), SettingsOption(id: "on", label: "On")],
                          selection: isOn ? "on" : "off") { set($0 == "on") }
    }
}

/// A row's button in its row's focus, or in the page's.
private struct PillFocus: ViewModifier {
    var own: FocusState<String?>.Binding
    let page: FocusState<String?>.Binding?
    let id: String
    let pageID: String

    func body(content: Content) -> some View {
        if let page { content.focused(page, equals: pageID) } else { content.focused(own, equals: id) }
    }
}

/// A list of titles to open or remove (Settings 2's Watch Progress and
/// Library): Remove All on top (confirmed), then a row per title, its
/// poster, name and detail, at its end Open (its Details) and the bin. A
/// removal stays in place, faded, its bin an undo arrow (focus on it): it
/// reaches the account only as you leave the page — so an undo never has
/// to be sent.
struct RemovableListPage: View {
    struct Item: Identifiable {
        let id: String
        let poster: String?
        let name: String
        let detail: String
        let meta: MetaItem?
        /// One more action, between Open and Remove (Watched: a show's
        /// episodes).
        var more: SettingsAction? = nil
    }

    let title: String
    let items: [Item]
    /// The list's records are in (else nothing yet, not "empty").
    var ready = true
    let empty: String
    let removeAllTitle: String
    let removeAllMessage: String
    let remove: (String) -> Void
    let removeAll: () -> Void

    @Environment(\.settingsOpenTitle) private var openTitle
    @FocusState private var focus: String?
    @State private var confirmAll = false
    /// Removed here, not yet sent (undone with a second press).
    @State private var pending: Set<String> = []

    var body: some View {
        SettingsPage(title: title) {
            if !ready {
                EmptyView()
            } else if items.isEmpty {
                SettingsNote(empty)
            } else {
                SettingsSection {
                    Button { confirmAll = true } label: {
                        SettingsRowLabel(title: "Remove All", value: "\(items.count - pending.count)", danger: true)
                    }
                    .settingsRow(id: "remove-all")
                }
                SettingsSection {
                    ForEach(items) { item in
                        let gone = pending.contains(item.id)
                        ActionListRow(
                            id: item.id,
                            leading: AnyView(Poster(url: item.poster)),
                            leadingSize: CGSize(width: 44, height: 66),
                            title: item.name,
                            detail: gone ? "Removed" : item.detail,
                            dimmed: gone,
                            actions: actions(item, gone: gone),
                            focus: $focus)
                    }
                }
            }
        }
        .onDisappear { commit() }
        .alert(removeAllTitle, isPresented: $confirmAll) {
            Button("Remove All", role: .destructive) {
                pending = []
                removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeAllMessage)
        }
    }

    private func actions(_ item: Item, gone: Bool) -> [SettingsAction] {
        var list: [SettingsAction] = []
        if let meta = item.meta, let openTitle, !gone {
            list.append(SettingsAction(title: "Open", icon: "info.circle", key: "open") { openTitle(meta) })
        }
        if let more = item.more, !gone { list.append(more) }
        // One key both ways: focus stays on it as it turns.
        list.append(gone
            ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") { pending.remove(item.id) }
            : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") { pending.insert(item.id) })
        return list
    }

    /// The removals made here, sent as the page goes.
    private func commit() {
        for id in pending { remove(id) }
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
    @Environment(\.settingsCards) private var cards

    @Environment(\.settingsPath) private var path

    var body: some View {
        if cards { cardsBody } else { appleBody }
    }

    /// Settings 2's: the path, then the page, scrolling together under the
    /// fade into the top bar's gap.
    private var cardsBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    path
                    content
                }
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .settingsTopFade()
            .environment(\.settingsScroll, proxy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preference(key: SettingsPageHeaderKey.self, value: .init(title: title, subtitle: subtitle))
    }

    private var appleBody: some View {
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
            .foregroundStyle(CueInk.body)
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
    static let focusScale: CGFloat = 1.06
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(title: title) }
            .buttonStyle(SettingsPress(lift: Self.focusScale))
            .modifier(SettingsRowEntry(id: title))
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        @Environment(\.settingsCards) private var cards
        let title: String

        var body: some View {
            Text(title)
                .font(SettingsLook(cards: cards).name)
                .foregroundStyle(focused ? (cards ? .black : SettingsMetrics.focusedText)
                                 : (cards ? CueInk.primary : SettingsMetrics.primaryText))
                .padding(.horizontal, cards ? 24 : 36)
                .frame(height: cards ? 52 : 71)
                .background {
                    Capsule(style: .continuous).fill(focused ? FlatControl.focus : FlatControl.rest)
                        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 16, y: 8)
                }
                .scaleEffect(focused ? SettingsCapsuleButton.focusScale : 1)
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
    @Environment(\.settingsCards) private var cards
    private var lit: Bool { (!editing && focused == .row && !focusHidden) || isMoving }

    var body: some View {
        Group {
            if editing {
                face
            } else {
                Button(action: onSelect) { face }
                    .buttonStyle(SettingsPress(lift: SettingsMetrics.focusScale))
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
        let look = SettingsLook(cards: cards)
        return HStack(spacing: 16) {
            if let leading { leading.frame(width: cards ? 32 : 40, height: cards ? 32 : 40) }
            Text(title)
                .font(look.name)
                .foregroundStyle(SettingsInk.name(lit, cards: cards, dimmed: dimmed))
                .lineLimit(1)
            Spacer(minLength: 24)
            // In Edit the on / off says it.
            if let value, !editing {
                Text(value)
                    .font(look.value)
                    .foregroundStyle(SettingsInk.quiet(lit, cards: cards))
                    .lineLimit(1)
            }
            if editing {
                HStack(spacing: look.buttonGap) {
                    if let toggle {
                        Button(action: toggle.toggle) {
                            SettingsRowButtonFace(icon: toggle.isOn ? "eye" : "eye.slash", focused: focused == .toggle, onLitRow: lit)
                        }
                        .buttonStyle(SettingsPress(lift: SettingsRowButtonFace.focusScale))
                        .focused($focused, equals: .toggle)
                        .disabled(anyMoving)
                    }
                    Button { isMoving ? onDrop() : onLift() } label: {
                        SettingsRowButtonFace(icon: "line.3.horizontal", focused: focused == .handle && !isMoving, onLitRow: lit)
                    }
                    .buttonStyle(SettingsPress(lift: SettingsRowButtonFace.focusScale))
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
                    .font(look.chevron)
                    .foregroundStyle(SettingsInk.chevron(lit, cards: cards))
                    .padding(.leading, 14)
                    .padding(.trailing, look.chevronGap - look.buttonInset + look.inset)
            }
        }
        .padding(.leading, look.inset)
        .padding(.trailing, look.buttonInset)
        .settingsTallChrome(lit: lit, moving: isMoving, cards: cards)
        .animation(.smooth(duration: 0.15), value: focused)
        .animation(.smooth(duration: 0.2), value: editing)
    }
}

/// No system focus look: the button draws it. Pressed, back to its resting
/// size (`lift`: how much larger its face is when focused), level with the
/// rows and buttons around it, then up again.
struct SettingsPress: ButtonStyle {
    let lift: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1 / lift : 1)
            .animation(.smooth(duration: 0.1), value: configuration.isPressed)
    }
}

/// A round button, as the rows' others: focused the light platter, dark
/// symbol, lifted; on a lit row its symbol alone.
struct SettingsRowButtonFace: View {
    static let focusScale: CGFloat = 1.12
    @Environment(\.settingsCards) private var cards
    let icon: String
    let focused: Bool
    let onLitRow: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: cards ? 21 : 26, weight: .semibold))
            .foregroundStyle(cards
                             ? (focused ? Color.black : onLitRow ? Color.black.opacity(0.6) : CueInk.primary)
                             : focused ? SettingsMetrics.focusedText
                             : onLitRow ? SettingsMetrics.focusedText.opacity(0.45)
                             : SettingsMetrics.primaryText)
        .frame(width: cards ? 52 : SettingsMetrics.rowButtonSize, height: cards ? 52 : SettingsMetrics.rowButtonSize)
        .background {
            if cards {
                if focused { GlassHighlight(focused: true, shape: Circle()) }
                else { Circle().fill(SettingsMetrics.rowButtonFill).opacity(onLitRow ? 0 : 1) }
            } else if focused { GlassHighlight(focused: true, shape: Circle()) }
            else { Circle().fill(SettingsMetrics.rowButtonFill).opacity(onLitRow ? 0 : 1) }
        }
        .scaleEffect(focused && !cards ? Self.focusScale : 1)
        .shadow(color: .black.opacity(focused && !cards ? 0.3 : 0), radius: 10, y: 5)
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

/// Settings 2's scrolls: up past the column's top into the gap under the
/// top bar (room for focus shadows), cut just above the first labels with
/// a short fade (fading across the whole gap left rows under the bar), so
/// rows going up never run under it. Unclipped at the sides and foot.
struct SettingsTopFade: ViewModifier {
    /// The gap between the top bar and the columns.
    static let height: CGFloat = 40
    /// The fade, ending at the column's top.
    static let fade: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, Self.height, for: .scrollContent)
            .scrollClipDisabled()
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.height - Self.fade)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                    Rectangle()
                }
                .padding(.horizontal, -80)
                .padding(.bottom, -200)
            }
            .padding(.top, -Self.height)
    }
}

extension View {
    func settingsTopFade() -> some View { modifier(SettingsTopFade()) }
}
