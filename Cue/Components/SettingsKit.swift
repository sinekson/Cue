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

    /// Settings 2: the room over a page whose first section has no label,
    /// so its first card is level with the categories' first.
    @Entry var settingsFirstRoom: CGFloat = 0

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
                    // The categories' labels' room: both columns' cards level.
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CueInk.tertiary)
                        .padding(.leading, CardSettingsRow.textInset)
                        .frame(height: CardSettingsSection.labelRoom - 12, alignment: .top)
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
            .settingsSectionTop()
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
            else if selected { shape.fill(FlatControl.selected) }
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
    /// Its title in words on a capsule, not a symbol (Remove All: a trash
    /// symbol read as the rows' own Remove).
    var spelled = false
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
                .background {
                    // The shadow outside the plate only: the chosen grey is
                    // see-through, a shadow under it greyed the row.
                    RoundedRectangle(cornerRadius: UISettings.plateRadius, style: .continuous)
                        .fill(.black)
                        .padding(.vertical, -CardSettingsRow.plateBleed)
                        .shadow(color: .black.opacity(moving ? 0.35 : 0), radius: 18, y: 9)
                        .mask {
                            Rectangle().padding(-80)
                                .overlay(RoundedRectangle(cornerRadius: UISettings.plateRadius, style: .continuous)
                                    .padding(.vertical, -CardSettingsRow.plateBleed)
                                    .blendMode(.destinationOut))
                                .compositingGroup()
                        }
                }
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
    @Environment(\.settingsFirstRoom) private var firstRoom


    var body: some View {
        if cards { cardsBody } else { appleBody }
    }

    /// Settings 2's: the page, scrolling under the fade into the gap above
    /// it (where you are is the breadcrumbs', over the columns).
    private var cardsBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.top, firstRoom)
                .padding(.bottom, SettingsTopFade.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(.named(SettingsTopFade.space))
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

/// Settings 2's scrolls: one top line for both columns (the categories'
/// first label's), what goes up past it fading over the gap to the
/// breadcrumbs, the page stopping with a section on the line. Unclipped
/// at the sides and foot.
struct SettingsTopFade: ViewModifier {
    /// The gap between the top bar and the columns.
    static let height: CGFloat = 40
    /// The fade, ending at the column's top: most of the gap up to the
    /// breadcrumbs, so what goes up dissolves rather than being cut (16 pt
    /// read as a cut above the categories' first label).
    static let fade: CGFloat = 32
    /// Room under a page, so its last section too can come up to the line
    /// (the page's end stopped it short, a card half in the fade).
    static let tail: CGFloat = 640
    /// The page's content, where its sections' tops are measured.
    static let space = "settingsPage"
    @State private var tops = SettingsSectionTops()

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, Self.height, for: .scrollContent)
            // The page stops with a section's top on the column's top line,
            // never a card cut half in the fade.
            .scrollTargetBehavior(SettingsSectionSnap(tops: tops))
            .onPreferenceChange(SettingsSectionTopsKey.self) { frames in
                tops.values = frames.map(\.lowerBound).sorted()
                tops.end = frames.map(\.upperBound).max() ?? 0
            }
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

/// The sections' tops in the page (`SettingsTopFade.space`).
final class SettingsSectionTops: @unchecked Sendable {
    var values: [CGFloat] = []
    /// Where the last section ends (the page's room under it is not
    /// content).
    var end: CGFloat = 0
}

struct SettingsSectionTopsKey: PreferenceKey {
    static let defaultValue: [ClosedRange<CGFloat>] = []
    static func reduce(value: inout [ClosedRange<CGFloat>], nextValue: () -> [ClosedRange<CGFloat>]) {
        value += nextValue()
    }
}

/// Where focus scrolls the page: the focused row's section's top on the
/// line, so a section comes up whole (the engine's own stops left cards
/// cut in the fade, and jumped further than needed). A section taller
/// than the column (a long list): the engine's own stop, a row at a time.
struct SettingsSectionSnap: ScrollTargetBehavior {
    let tops: SettingsSectionTops

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard abs(target.rect.minY - context.originalTarget.rect.minY) > 0.5,
              let row = MainActor.assumeIsolated({ Self.focusedInScroll() }) else { return }
        // The scroll's content starts with the top margin; the sections'
        // tops are measured under it.
        let top = row.minY - SettingsTopFade.height
        let view = context.containerSize.height - SettingsTopFade.height
        guard let section = tops.values.last(where: { $0 <= top + 1 }),
              top + row.height - section <= view else {
            // A long list: the engine's stop, but never past its end into
            // the room under the page.
            target.rect.origin.y = min(target.rect.minY, max(0, tops.end - view))
            return
        }
        // The first: the page as it opens (its room over the first card).
        target.rect.origin.y = section == tops.values.first ? 0 : max(0, section)
    }

    /// The focused item's frame in its scroll's content (SwiftUI's focus
    /// items report it so), when it is in one.
    @MainActor private static func focusedInScroll() -> CGRect? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let item = window.windowScene?.focusSystem?.focusedItem else { return nil }
        return item.frame
    }
}

extension View {
    func settingsTopFade() -> some View { modifier(SettingsTopFade()) }

    /// A section's top, for the page's scroll to stop on.
    func settingsSectionTop() -> some View {
        background {
            GeometryReader { geo in
                let frame = geo.frame(in: .named(SettingsTopFade.space))
                Color.clear.preference(key: SettingsSectionTopsKey.self, value: [frame.minY...max(frame.minY, frame.maxY)])
            }
        }
    }
}

// MARK: - Settings 2 in UIKit (2026-11-23)

/// Settings 2's look in UIKit, value for value with the SwiftUI parts it
/// replaces: the cards' fill and corners, the rows' insets, the pills' and
/// round buttons' focus (the white in 0.15 s on a spring, out 0.15 s
/// linear, grown 10 % on focus's 0.3 s spring, a press back to the resting
/// size), the rows' plate (the glass, lit, 0.12 s).
enum UISettings {
    static let textSize: CGFloat = 24
    /// The words from the card's edge, and a plate's inset from it.
    static let textInset = CardSettingsRow.textInset
    static let plateInset = CardSettingsRow.plateInset
    static let plateBleed = CardSettingsRow.plateBleed
    static let rowInset = textInset - plateInset
    static let rowVertical: CGFloat = 14
    static let lift = DetailActionButton.detailsFocusScale
    /// A section's label's room over its card.
    static let labelRoom = CardSettingsSection.labelRoom
    static let sectionGap: CGFloat = 40
    /// Between two rows: a hairline 4 pt either side; beside the well of
    /// rows only to read, room for its bleed and a plate's.
    static let hairlineRoom: CGFloat = 9
    static var wellGap: CGFloat { 2 * plateBleed + plateInset }
    static let plateRadius = Spotlight.cornerRadius - CardSettingsRow.plateInset
    static var cardFill: UIColor { CueInk.uiFill(dark: 0.07, light: 0.24) }
    static var restFill: UIColor { CueInk.uiFill(dark: 0.13, light: 0.32) }
    static var selectedFill: UIColor { CueInk.uiFill(dark: 0.28, light: 0.55) }
    static var hairline: UIColor { CueInk.ui(0.10) }
    static var quietOnPlate: UIColor { UIColor.black.withAlphaComponent(0.6) }

    static func label(_ size: CGFloat = textSize, _ weight: UIFont.Weight = .regular,
                      _ level: CGFloat = FixedFocusText.primary) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = CueInk.ui(level)
        label.adjustsFontForContentSizeCategory = false
        return label
    }

    /// A row's name over its line.
    static func titleStack(_ title: UILabel, _ detail: UILabel, spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func symbol(_ name: String, _ size: CGFloat, _ weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// The view focus is on now, if any.
    @MainActor static func focusedView(in view: UIView) -> UIView? {
        view.window?.windowScene?.focusSystem?.focusedItem as? UIView
    }
}

// MARK: Parts

/// A SwiftUI view inside a UIKit row (an avatar, a rating's mark, a
/// poster, the glass plate): not hit-testable, no safe area.
final class UISettingsHosted: UIView {
    private let host: UIHostingController<AnyView>

    init(_ view: AnyView, size: CGSize? = nil) {
        host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        addSubview(host.view)
        if let size {
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size.width),
                                         heightAnchor.constraint(equalToConstant: size.height)])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ view: AnyView) { host.rootView = view }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}

/// A row's plate: the glass (`GlassHighlight`), lit for focus, faint for
/// the shown category or a lifted row (flat, the chosen grey); concentric with the card, past its
/// row by the bleed above and below.
final class UISettingsPlate {
    private weak var row: UIView?
    private var lit: UISettingsHosted?
    private var faint: UISettingsHosted?

    init(row: UIView) { self.row = row }

    private func make(_ focused: Bool) -> UISettingsHosted {
        let shape = RoundedRectangle(cornerRadius: UISettings.plateRadius, style: .continuous)
        // The shown one flat, the pills' chosen grey: as glass it read raised
        // beside the focus.
        let view = UISettingsHosted(focused ? AnyView(GlassHighlight(focused: true, shape: shape))
                                            : AnyView(shape.fill(FlatControl.selected)))
        view.alpha = 0
        row?.insertSubview(view, at: 0)
        return view
    }

    func layout() {
        guard let row else { return }
        let frame = row.bounds.insetBy(dx: 0, dy: -UISettings.plateBleed)
        lit?.frame = frame
        faint?.frame = frame
    }

    /// Glass only where it shows: made the first time it's wanted.
    func show(lit on: Bool, faint faintOn: Bool, animated: Bool) {
        if on, lit == nil { lit = make(true); layout() }
        if faintOn, faint == nil { faint = make(false); layout() }
        let change = {
            self.lit?.alpha = on ? 1 : 0
            self.faint?.alpha = faintOn && !on ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: change)
        } else {
            change()
        }
    }
}

/// A focusable capsule or circle: its resting face (nothing, the grey of
/// the chosen one, or the rest fill), the white platter with its shadow
/// fading in and out over it, grown on focus, back to size on a press.
class UISettingsPill: UIView {
    let platter = UIView()
    let white = UIView()
    var onSelect: () -> Void = {}
    /// While false, focus passes it by (a choice row's pills but the
    /// chosen one, coming into the row; the other buttons while a row is
    /// lifted).
    var reachable: () -> Bool = { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        platter.isUserInteractionEnabled = false
        white.isUserInteractionEnabled = false
        white.backgroundColor = .white
        white.alpha = 0
        white.layer.shadowColor = UIColor.black.cgColor
        white.layer.shadowOpacity = 0.35
        white.layer.shadowRadius = 12
        white.layer.shadowOffset = CGSize(width: 0, height: 6)
        addSubview(platter)
        addSubview(white)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { reachable() }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [platter, white] {
            view.bounds = CGRect(origin: .zero, size: bounds.size)
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
            view.layer.cornerRadius = bounds.height / 2
        }
        white.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: bounds.size),
                                              cornerRadius: bounds.height / 2).cgPath
    }

    /// Words and symbols in their focused or resting colour.
    func styleContent(focused: Bool) {}

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard focused || context.previouslyFocusedView === self else { return }
        if focused {
            UIView.animate(springDuration: 0.15, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { self.white.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveLinear]) {
                self.white.alpha = 0
            }
        }
        UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .beginFromCurrentState,
                                                                .allowUserInteraction]) {
            self.styleContent(focused: focused)
        }
        UIView.animate(springDuration: Motion.focusDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = focused ? CGAffineTransform(scaleX: UISettings.lift, y: UISettings.lift) : .identity
        }
    }

    // A press: back to the resting size (0.1 s), up again on release.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.transform = .identity
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        settle()
        onSelect()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesCancelled(presses, with: event) }
        settle()
    }

    private func settle() {
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.transform = self.isFocused ? CGAffineTransform(scaleX: UISettings.lift, y: UISettings.lift) : .identity
        }
    }
}

/// A choice's pill: its word, 23 pt medium, 20 pt either side, 48 tall;
/// the chosen one on the selected grey.
final class UISettingsChoicePill: UISettingsPill {
    let label = UISettings.label(23, .medium)
    var chosen = false {
        didSet {
            platter.backgroundColor = chosen ? UISettings.selectedFill : .clear
            styleContent(focused: isFocused)
        }
    }

    init(text: String) {
        super.init(frame: .zero)
        label.text = text
        label.textAlignment = .center
        addSubview(label)
        styleContent(focused: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func styleContent(focused: Bool) {
        label.textColor = focused ? .black : CueInk.ui(chosen ? FixedFocusText.primary : FixedFocusText.secondary)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(label.intrinsicContentSize.width) + 40, height: 48)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 20, dy: 0)
    }
}

/// A round button: 52 pt, the rest fill, its symbol 21 pt semibold (red
/// for what no menu undoes), nudged where a symbol is lopsided.
final class UISettingsRoundButton: UISettingsPill {
    let symbol = UIImageView()
    /// Words in place of the symbol: a capsule as tall, 22 pt in each side.
    private let words = UISettings.label(23, .medium)
    private(set) var danger = false
    private var nudge: CGFloat = 0
    /// Lit row (a lifted one): no fill, the symbol dimmer.
    var onLitRow = false { didSet { platter.alpha = onLitRow ? 0 : 1; styleContent(focused: isFocused) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        platter.backgroundColor = UISettings.restFill
        symbol.contentMode = .center
        addSubview(symbol)
        words.textAlignment = .center
        words.isHidden = true
        addSubview(words)
    }

    /// The title in words instead of the symbol (`SettingsAction.spelled`).
    func set(words text: String?) {
        guard words.text != text || words.isHidden != (text == nil) else { return }
        words.text = text
        words.isHidden = text == nil
        symbol.isHidden = text != nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(icon: String, danger: Bool, nudge: CGFloat) {
        symbol.image = UISettings.symbol(icon, 21)?.withRenderingMode(.alwaysTemplate)
        self.danger = danger
        self.nudge = nudge
        styleContent(focused: isFocused)
        setNeedsLayout()
    }

    override func styleContent(focused: Bool) {
        symbol.tintColor = danger ? .systemRed : focused ? .black
            : onLitRow ? UISettings.quietOnPlate : CueInk.ui(FixedFocusText.primary)
        words.textColor = symbol.tintColor
    }

    override var intrinsicContentSize: CGSize {
        words.isHidden ? CGSize(width: 52, height: 52)
            : CGSize(width: ceil(words.intrinsicContentSize.width) + 44, height: 52)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        symbol.frame = CGRect(origin: CGPoint(x: nudge, y: 0), size: bounds.size)
        words.frame = bounds.insetBy(dx: 22, dy: 0)
    }
}

/// A profile's avatar to press: 120 pt, focused a white ring round it
/// (the pills' white, 6 pt past it) and grown as the pills.
final class UISettingsAvatarButton: UISettingsPill {
    private let avatar: UISettingsHosted
    private var key = ""
    static let size: CGFloat = 120
    static let ring: CGFloat = 6

    init() {
        avatar = UISettingsHosted(AnyView(EmptyView()))
        super.init(frame: .zero)
        platter.backgroundColor = .clear
        addSubview(avatar)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(key: String, _ view: () -> AnyView) {
        guard key != self.key else { return }
        self.key = key
        avatar.set(AnyView(view().frame(width: Self.size, height: Self.size)))
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.size + 2 * Self.ring, height: Self.size + 2 * Self.ring)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        avatar.frame = bounds.insetBy(dx: Self.ring, dy: Self.ring)
    }
}

/// A profile's top row (`UISettingsRow.Profile`): the avatar (Select:
/// change it), the name over what it is, its actions round buttons at the
/// end. Coming in: the nearest across.
final class UISettingsProfileRow: UISettingsControlRow, UISettingsRowView {
    private var model: UISettingsRow.Profile
    private let avatar = UISettingsAvatarButton()
    private var buttons: [String: UISettingsRoundButton] = [:]

    init(_ model: UISettingsRow.Profile) {
        self.model = model
        super.init(spacing: 14, textSpacing: 4)
        title.font = .systemFont(ofSize: 36, weight: .semibold)
        row.insertArrangedSubview(avatar, at: 0)
        row.setCustomSpacing(26, after: avatar)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .profile(let model) = row else { return false }
        self.model = model
        configure()
        return true
    }

    private func configure() {
        title.text = model.title
        detail.text = model.detail
        detail.isHidden = model.detail.isEmpty
        title.alpha = model.dimmed ? 0.6 : 1
        detail.alpha = title.alpha
        avatar.alpha = model.dimmed ? 0.4 : 1
        avatar.set(key: model.key, model.avatar)
        avatar.onSelect = { [weak self] in self?.model.onAvatar() }
        let dimmed = model.dimmed
        avatar.reachable = { !dimmed }
        var kept: [UISettingsRoundButton] = []
        for action in model.actions {
            let button = buttons[action.id] ?? UISettingsRoundButton()
            buttons[action.id] = button
            button.set(icon: action.icon, danger: action.danger, nudge: action.nudge)
            button.accessibilityLabel = action.title
            button.onSelect = { action.action() }
            kept.append(button)
        }
        for (key, button) in buttons where !kept.contains(where: { $0 === button }) {
            button.removeFromSuperview()
            buttons[key] = nil
        }
        for (index, button) in kept.enumerated() where controls.arrangedSubviews.firstIndex(of: button) != index {
            controls.insertArrangedSubview(button, at: index)
        }
    }

    override var entry: UIView? {
        let ordered = ([avatar] + controls.arrangedSubviews).filter { $0.canBecomeFocused }
        guard let from = UISettings.focusedView(in: self), let window else { return avatar }
        let x = from.convert(CGPoint(x: from.bounds.midX, y: 0), to: window).x
        return ordered.min { abs($0.convert(CGPoint(x: $0.bounds.midX, y: 0), to: window).x - x)
            < abs($1.convert(CGPoint(x: $1.bounds.midX, y: 0), to: window).x - x) }
    }
}

// MARK: Rows

/// What a page's row is (`UISettingsSection.rows`): built anew on every
/// change; the cards keep each row's view by its id and update it.
enum UISettingsRow {
    case link(Link)
    case choice(Choice)
    case actions(Actions)
    case info(title: String, value: String)
    case note(String)
    /// A SwiftUI piece (the taste's columns, a profile's header).
    case hosted(Hosted)
    /// Tiles to pick from, ten across under their kinds' names (avatars).
    case tiles(Tiles)
    /// Capsule buttons side by side, centred, on no card (a wizard's
    /// Continue and Skip).
    case buttons(Buttons)
    /// Posters to like in one line, each over its name (the wizard's taste).
    case posters(Posters)
    /// A profile's top row: the avatar to press, its name,
    /// its actions as round buttons.
    case profile(Profile)

    struct Profile {
        let id: String
        /// Changes when the avatar does.
        let key: String
        let title: String
        let detail: String
        /// Going away (deleted when the page is left): faded, as a removed row.
        var dimmed = false
        let avatar: () -> AnyView
        let onAvatar: () -> Void
        let actions: [SettingsAction]
    }

    struct Hosted {
        let id: String
        /// Changes when the piece does.
        let key: String
        /// Only to read: in the well with rows to read.
        var readOnly = false
        let view: () -> AnyView
    }

    struct Buttons {
        let id: String
        let actions: [SettingsAction]
    }

    struct Posters {
        let id: String
        /// The row's name, as Home's.
        var title: String? = nil
        let items: [PosterItem]
    }

    struct PosterItem {
        let id: String
        let title: String
        let detail: String
        let poster: String?
        /// Liked: its heart on the poster.
        let on: Bool
        let action: () -> Void
    }

    struct Tiles {
        let id: String
        let groups: [(name: String, tiles: [Tile])]
        /// The gate's round look at this size (a new profile's avatars and
        /// profiles): the circle alone with the cards' rim, focused 5 %
        /// larger with the bright edge and a soft shadow, a caption under
        /// it; left-aligned slots, a group a line of its own, no labels.
        var round: CGFloat? = nil
    }

    struct Tile {
        enum Face {
            case colour(hex: String, initial: String)
            case avatar(url: String, name: String)
            /// A symbol on the flat plate (Start Fresh), as Add Profile.
            case symbol(String)
        }
        let id: String
        let face: Face
        let chosen: Bool
        /// Under a round tile.
        var caption: String? = nil
        /// Focus came to it (the wizard's preview follows it).
        var onFocus: (() -> Void)? = nil
        let action: () -> Void
    }

    /// A row that opens a page (a chevron) or does something (none).
    struct Link {
        let id: String
        let title: String
        var description: String? = nil
        var value: String? = nil
        var leading: Leading? = nil
        var checked = false
        var danger = false
        var chevron = true
        let action: () -> Void
    }

    /// Two or three choices on the row (`SettingsChoiceRow`).
    struct Choice {
        let id: String
        let title: String
        var description: String? = nil
        let options: [SettingsOption]
        let selection: String
        let onPick: (String) -> Void
    }

    /// A list item with its actions on it as round buttons (`ActionListRow`).
    struct Actions {
        let id: String
        var leading: Leading? = nil
        let title: String
        let detail: String
        var dimmed = false
        let actions: [SettingsAction]
        /// This row is lifted / any row is.
        var moving = false
        var anyMoving = false
        /// Dropped, how far it went (rows, + down): the store moves once.
        var onMove: (Int) -> Void = { _ in }
        var onDrop: () -> Void = {}
    }

    /// A picture before the name, drawn in SwiftUI; `key` says when it
    /// changed.
    struct Leading {
        let key: String
        var size = CGSize(width: 56, height: 56)
        var view: (() -> AnyView)? = nil
        /// A title's poster, small, drawn in UIKit (a long list: a SwiftUI
        /// host each was too heavy).
        var poster: String? = nil

        static func poster(_ url: String?) -> Leading {
            Leading(key: url ?? "none", size: CGSize(width: 44, height: 66), poster: url ?? "")
        }
    }

    var id: String {
        switch self {
        case .link(let row): row.id
        case .choice(let row): row.id
        case .actions(let row): row.id
        case .info(let title, _): "info." + title
        case .note(let text): "note." + text
        case .hosted(let row): row.id
        case .tiles(let row): row.id
        case .buttons(let row): row.id
        case .posters(let row): row.id
        case .profile(let row): row.id
        }
    }

    var onlyToRead: Bool {
        switch self {
        case .info: true
        case .hosted(let row): row.readOnly
        default: false
        }
    }

    /// On / Off as a choice row: Off first.
    static func onOff(id: String, title: String, description: String? = nil, isOn: Bool,
                      set: @escaping (Bool) -> Void) -> UISettingsRow {
        .choice(Choice(id: id, title: title, description: description,
                       options: [SettingsOption(id: "off", label: "Off"), SettingsOption(id: "on", label: "On")],
                       selection: isOn ? "on" : "off") { set($0 == "on") })
    }
}

/// A row's view: takes a new model of its kind (false: another kind, made
/// anew).
@MainActor protocol UISettingsRowView: UIView {
    func apply(_ row: UISettingsRow) -> Bool
}

/// A leading picture's view, remade only when its key changes.
@MainActor private final class UISettingsLeadingView {
    private(set) var view: UISettingsHosted?
    private(set) var poster: UIView?
    private var key: String?
    private var size: CGSize = .zero

    /// The picture's view, whichever kind.
    var shown: UIView? { view ?? poster }

    /// A poster: 6 pt corners, a faint edge, a faint fill while it loads.
    private func posterView(size: CGSize) -> UIView {
        let frame = UIView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        frame.layer.cornerRadius = 6
        frame.layer.cornerCurve = .continuous
        frame.layer.borderWidth = 1
        frame.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        frame.clipsToBounds = true
        let image = UIImageView()
        image.contentMode = .scaleAspectFill
        image.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(image)
        NSLayoutConstraint.activate([
            frame.widthAnchor.constraint(equalToConstant: size.width),
            frame.heightAnchor.constraint(equalToConstant: size.height),
            image.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            image.topAnchor.constraint(equalTo: frame.topAnchor),
            image.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
        ])
        frame.bringSubviewToFront(image)
        return frame
    }

    /// The view for this picture: the same one while its key holds.
    func update(_ leading: UISettingsRow.Leading?, dimmed: Bool, in stack: UIStackView) {
        guard let leading else {
            view?.removeFromSuperview()
            poster?.removeFromSuperview()
            view = nil
            poster = nil
            key = nil
            return
        }
        let wanted = leading.key + (dimmed ? ".dim" : "")
        guard wanted != key || leading.size != size else { return }
        key = wanted
        if let url = leading.poster {
            poster?.removeFromSuperview()
            view?.removeFromSuperview()
            view = nil
            let made = posterView(size: leading.size)
            UISettingsPicture.load(url.isEmpty ? nil : url, size: leading.size.height, into: made.subviews[0] as! UIImageView)
            made.alpha = 1
            (made.subviews[0] as! UIImageView).alpha = dimmed ? 0.4 : 1
            stack.insertArrangedSubview(made, at: 0)
            poster = made
            size = leading.size
            return
        }
        poster?.removeFromSuperview()
        poster = nil
        guard let make = leading.view else { return }
        let content = AnyView(make().saturation(dimmed ? 0 : 1)
            .frame(width: leading.size.width, height: leading.size.height))
        if let view, leading.size == size {
            view.set(content)
        } else {
            view?.removeFromSuperview()
            let made = UISettingsHosted(content, size: leading.size)
            stack.insertArrangedSubview(made, at: 0)
            view = made
        }
        size = leading.size
    }
}

/// A row that opens a page or does something (`SettingsRowLabel`'s card
/// look): the name over its description at the left; value, checkmark and
/// chevron at the end; focused, the lit plate, dark words. Also the
/// categories (`compact`: 9 pt above and below), the one shown on the flat
/// grey while focus is in its settings; an options list's current choice
/// on the grey too.
final class UISettingsLinkRow: UIView, UISettingsRowView {
    private var model: UISettingsRow.Link
    private let compact: Bool
    private let title = UISettings.label(UISettings.textSize, .medium)
    private let detail = UISettings.label(UISettings.textSize, .regular, FixedFocusText.body)
    private let value = UISettings.label(UISettings.textSize, .regular, FixedFocusText.body)
    private let check = UIImageView(image: UISettings.symbol("checkmark", 22)?.withRenderingMode(.alwaysTemplate))
    private let chevron = UIImageView(image: UISettings.symbol("chevron.right", 20)?.withRenderingMode(.alwaysTemplate))
    private let row = UIStackView()
    private let leading = UISettingsLeadingView()
    private lazy var plate = UISettingsPlate(row: self)
    /// The shown category (`compact` rows): the faint plate.
    var selected = false { didSet { if selected != oldValue { plate.show(lit: isFocused, faint: marked, animated: true) } } }
    var reachable: () -> Bool = { true }

    init(_ model: UISettingsRow.Link, compact: Bool = false) {
        self.model = model
        self.compact = compact
        super.init(frame: .zero)
        detail.numberOfLines = 2
        let text = UISettings.titleStack(title, detail, spacing: 2)
        let trailing = UIStackView(arrangedSubviews: [value, check, chevron])
        trailing.axis = .horizontal
        trailing.spacing = 12
        trailing.alignment = .center
        let spacer = UIView()
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 24 - 2 * 16).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(trailing)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        text.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let vertical: CGFloat = compact ? 9 : UISettings.rowVertical
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UISettings.rowInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UISettings.rowInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
        ])
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .link(let model) = row else { return false }
        self.model = model
        configure()
        return true
    }

    /// The shown category, or the current choice of a list: the flat grey.
    private var marked: Bool { selected || model.checked }

    private func configure() {
        plate.show(lit: isFocused, faint: marked, animated: window != nil)
        title.text = model.title
        detail.text = model.description
        detail.isHidden = (model.description ?? "").isEmpty
        value.text = model.value
        value.isHidden = (model.value ?? "").isEmpty
        check.isHidden = !model.checked
        chevron.isHidden = !model.chevron
        leading.update(model.leading, dimmed: false, in: row)
        paint(isFocused)
    }

    private func paint(_ lit: Bool) {
        title.textColor = model.danger ? .systemRed : lit ? .black : CueInk.ui(FixedFocusText.primary)
        let quiet = lit ? UISettings.quietOnPlate : CueInk.ui(FixedFocusText.body)
        detail.textColor = quiet
        value.textColor = quiet
        chevron.tintColor = quiet
        check.tintColor = lit ? .black : CueInk.ui(FixedFocusText.primary)
    }

    override var canBecomeFocused: Bool { reachable() }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.layout()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard focused || context.previouslyFocusedView === self else { return }
        plate.show(lit: focused, faint: marked, animated: true)
        UIView.transition(with: self, duration: 0.12, options: [.transitionCrossDissolve, .beginFromCurrentState,
                                                                .allowUserInteraction]) {
            self.paint(focused)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        model.action()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
    }
}

/// A row: its name over its line at the left, its controls at the right,
/// the rows' insets; coming in from another row, a guide over it sends
/// focus to the control it prefers (`entry`): SwiftUI's `focusSection`.
class UISettingsControlRow: UIView {
    let title = UISettings.label(UISettings.textSize, .medium)
    let detail = UISettings.label(UISettings.textSize, .regular, FixedFocusText.body)
    let controls = UIStackView()
    let row = UIStackView()
    let text: UIStackView
    private let guide = UIFocusGuide()

    init(spacing: CGFloat, textSpacing: CGFloat) {
        text = UISettings.titleStack(title, detail, spacing: textSpacing)
        super.init(frame: .zero)
        controls.axis = .horizontal
        controls.spacing = spacing
        controls.alignment = .center
        row.addArrangedSubview(text)
        row.addArrangedSubview(controls)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 24
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addLayoutGuide(guide)
        guide.preferredFocusEnvironments = [self]
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UISettings.rowInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UISettings.rowInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: UISettings.rowVertical),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -UISettings.rowVertical),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where focus goes coming into the row.
    var entry: UIView? { nil }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { entry.map { [$0] } ?? [] }

    var holdsFocus: Bool { UISettings.focusedView(in: self)?.isDescendant(of: self) ?? false }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // The guide only from outside: inside, it would catch every move.
        guide.isEnabled = !(context.nextFocusedView?.isDescendant(of: self) ?? false)
    }
}

/// Two or three choices on their row (`SettingsChoiceRow`): the pills 12
/// apart; coming in only the chosen one takes focus; the line under the
/// name says what the focused choice means, else the chosen one's.
final class UISettingsChoiceRow: UISettingsControlRow, UISettingsRowView {
    private var model: UISettingsRow.Choice
    private var pills: [UISettingsChoicePill] = []
    private var focusedOption: String?

    init(_ model: UISettingsRow.Choice) {
        self.model = model
        super.init(spacing: 12, textSpacing: 4)
        for option in model.options {
            let pill = UISettingsChoicePill(text: option.label)
            pill.reachable = { [weak self, weak pill] in (pill?.chosen ?? false) || (self?.holdsFocus ?? false) }
            pills.append(pill)
            controls.addArrangedSubview(pill)
        }
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .choice(let model) = row, model.options.map(\.id) == self.model.options.map(\.id) else { return false }
        self.model = model
        configure()
        return true
    }

    private func configure() {
        title.text = model.title
        for (pill, option) in zip(pills, model.options) {
            pill.label.text = option.label
            pill.chosen = option.id == model.selection
            pill.onSelect = { [weak self] in
                guard let self else { return }
                self.model.onPick(option.id)
            }
        }
        let shown = model.options.first { $0.id == (focusedOption ?? model.selection) }
        detail.text = shown?.detail ?? model.description ?? ""
    }

    override var entry: UIView? { pills.first(where: \.chosen) ?? pills.first }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let index = pills.firstIndex { $0 === context.nextFocusedView }
        focusedOption = index.map { model.options[$0].id }
        configure()
    }
}

/// A list item with its actions on the row as round buttons, 14 apart
/// (`ActionListRow`): its picture, name over detail; dimmed (removed, to
/// undo) its words and picture faded; lifted to move, the faint plate, a
/// shadow outside it, 2 % larger, Up and Down moving it.
final class UISettingsActionRow: UISettingsControlRow, UISettingsRowView {
    private var model: UISettingsRow.Actions
    private var buttons: [String: UISettingsRoundButton] = [:]
    private let leading = UISettingsLeadingView()
    private lazy var plate = UISettingsPlate(row: self)

    init(_ model: UISettingsRow.Actions) {
        self.model = model
        super.init(spacing: 14, textSpacing: 2)
        row.spacing = 18
        text.spacing = 2
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .actions(let model) = row else { return false }
        let wasMoving = self.model.moving
        self.model = model
        configure()
        if wasMoving != model.moving {
            lift(model.moving)
            moveGuides.forEach { $0.isEnabled = model.moving }
        }
        return true
    }

    private func configure() {
        title.text = model.title
        detail.text = model.detail
        detail.isHidden = model.detail.isEmpty
        let fade: CGFloat = model.dimmed ? 0.6 : 1
        title.alpha = fade
        detail.alpha = fade
        leading.update(model.leading, dimmed: model.dimmed, in: row)
        leading.view?.alpha = fade
        if let picture = leading.shown { row.setCustomSpacing(18, after: picture) }
        // The buttons by their key: focus stays on one as it turns.
        var kept: [UISettingsRoundButton] = []
        for action in model.actions {
            let button = buttons[action.id] ?? UISettingsRoundButton()
            buttons[action.id] = button
            let icon = action.move && model.moving ? "checkmark" : action.icon
            button.set(icon: icon, danger: action.danger, nudge: action.nudge)
            button.set(words: action.spelled ? action.title : nil)
            button.accessibilityLabel = action.title
            button.onLitRow = false
            let moving = model.moving, anyMoving = model.anyMoving
            button.reachable = { !anyMoving || (action.move && moving) }
            button.onSelect = { [weak self] in
                guard let self else { return }
                if action.move, self.model.moving { self.drop() } else { action.action() }
            }
            kept.append(button)
        }
        for (key, button) in buttons where !kept.contains(where: { $0 === button }) {
            button.removeFromSuperview()
            buttons[key] = nil
        }
        for (index, button) in kept.enumerated() where controls.arrangedSubviews.firstIndex(of: button) != index {
            controls.insertArrangedSubview(button, at: index)
        }
    }

    /// The lifted row's shadow, outside the plate only: the chosen grey is
    /// see-through (white 55 % in light), a shadow under it greyed the row
    /// (read dirty, 2026-11-28).
    private lazy var liftShadow: CALayer = {
        let shadow = CALayer()
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: 9)
        shadow.shadowOpacity = 0.35
        shadow.opacity = 0
        let cut = CAShapeLayer()
        cut.fillRule = .evenOdd
        shadow.mask = cut
        layer.insertSublayer(shadow, at: 0)
        return shadow
    }()

    private func lift(_ up: Bool) {
        plate.show(lit: false, faint: up, animated: true)
        if up { layoutLiftShadow() }
        UIView.animate(springDuration: 0.18, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = up ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = liftShadow.presentation()?.opacity ?? liftShadow.opacity
        liftShadow.opacity = up ? 1 : 0
        fade.toValue = liftShadow.opacity
        fade.duration = 0.18
        liftShadow.add(fade, forKey: "lift")
    }

    private func layoutLiftShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let plateRect = bounds.insetBy(dx: 0, dy: -UISettings.plateBleed)
        let shape = UIBezierPath(roundedRect: plateRect, cornerRadius: UISettings.plateRadius)
        liftShadow.frame = bounds
        liftShadow.shadowPath = shape.cgPath
        let cut = UIBezierPath(rect: plateRect.insetBy(dx: -80, dy: -80))
        cut.append(shape)
        (liftShadow.mask as? CAShapeLayer)?.path = cut.cgPath
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.layout()
        if model.moving { layoutLiftShadow() }
    }

    /// Coming in: the button nearest the one focus leaves, across.
    override var entry: UIView? {
        let ordered = controls.arrangedSubviews.filter { $0.canBecomeFocused }
        guard let from = UISettings.focusedView(in: self), let window else { return ordered.last }
        let x = from.convert(CGPoint(x: from.bounds.midX, y: 0), to: window).x
        return ordered.min { abs($0.convert(CGPoint(x: $0.bounds.midX, y: 0), to: window).x - x)
            < abs($1.convert(CGPoint(x: $1.bounds.midX, y: 0), to: window).x - x) }
    }

    /// Lifted: Up and Down move the row (focus stays on its Move button),
    /// nothing else takes focus.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard model.moving else { return super.shouldUpdateFocus(in: context) }
        if context.focusHeading.contains(.up) { step(-1) }
        else if context.focusHeading.contains(.down) { step(1) }
        return false
    }

    /// It can be lifted, so others can pass it.
    var canMove: Bool { model.actions.contains(where: \.move) }

    /// One step a press: a click reaches both the press and the guides,
    /// and the engine asks again as the row moves. Only the card's views
    /// move while it's lifted (the page and the store wait for the drop:
    /// a rebuild, a save and a Nuvio push each step dropped frames).
    private var lastStep = Date.distantPast
    private var moved = 0
    private func step(_ by: Int) {
        guard Date().timeIntervalSince(lastStep) > 0.2 else { return }
        lastStep = Date()
        guard let card = sequence(first: superview, next: { $0?.superview }).compactMap({ $0 as? UISettingsCard }).first,
              card.shift(self, by: by) else { return }
        moved += by
        if let page = sequence(first: superview, next: { $0?.superview }).compactMap({ $0 as? UISettingsPageView }).first,
           let focused = UISettings.focusedView(in: self) {
            page.scrollTo(focused, animated: true)
        }
    }

    private func drop() {
        let by = moved
        moved = 0
        if by != 0 { model.onMove(by) }
        model.onDrop()
    }

    /// Lifted, a click Up or Down moves it (the engine has nowhere to go:
    /// nothing else can take focus); a swipe reaches `shouldUpdateFocus`
    /// through the guides above and below.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard model.moving else { return super.pressesBegan(presses, with: event) }
        if presses.contains(where: { $0.type == .upArrow }) { step(-1) }
        else if presses.contains(where: { $0.type == .downArrow }) { step(1) }
        else if !presses.contains(where: { $0.type == .menu }) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard model.moving else { return super.pressesEnded(presses, with: event) }
        if presses.contains(where: { $0.type == .menu }) { drop() }
        else if !presses.contains(where: { [.upArrow, .downArrow].contains($0.type) }) { super.pressesEnded(presses, with: event) }
    }

    private lazy var moveGuides: [UIFocusGuide] = {
        let up = UIFocusGuide(), down = UIFocusGuide()
        for guide in [up, down] {
            addLayoutGuide(guide)
            guide.preferredFocusEnvironments = [self]
            guide.isEnabled = false
        }
        NSLayoutConstraint.activate([
            up.leadingAnchor.constraint(equalTo: leadingAnchor), up.trailingAnchor.constraint(equalTo: trailingAnchor),
            up.bottomAnchor.constraint(equalTo: topAnchor, constant: -1), up.heightAnchor.constraint(equalToConstant: 40),
            down.leadingAnchor.constraint(equalTo: leadingAnchor), down.trailingAnchor.constraint(equalTo: trailingAnchor),
            down.topAnchor.constraint(equalTo: bottomAnchor, constant: 1), down.heightAnchor.constraint(equalToConstant: 40),
        ])
        return [up, down]
    }()
}

/// A row only to read: name and value, the value in the body's level.
final class UISettingsInfoRow: UIView, UISettingsRowView {
    private let title = UISettings.label(UISettings.textSize, .medium)
    private let value = UISettings.label(UISettings.textSize, .regular, FixedFocusText.body)

    init(title: String, value: String) {
        super.init(frame: .zero)
        let spacer = UIView()
        let row = UIStackView(arrangedSubviews: [self.title, spacer, self.value])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        self.title.setContentCompressionResistancePriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.value.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UISettings.rowInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UISettings.rowInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: UISettings.rowVertical),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -UISettings.rowVertical),
        ])
        set(title: title, value: value)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func set(title: String, value: String) {
        self.title.text = title
        self.value.text = value
    }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .info(let title, let value) = row else { return false }
        set(title: title, value: value)
        return true
    }
}

/// A line of text in a card (an empty list, how to get a key).
final class UISettingsNoteRow: UIView, UISettingsRowView {
    private let label = UISettings.label(UISettings.textSize, .regular, FixedFocusText.body)

    init(_ text: String) {
        super.init(frame: .zero)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UISettings.rowInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UISettings.rowInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        set(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func set(_ text: String) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        label.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: style])
    }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .note(let text) = row else { return false }
        set(text)
        return true
    }
}

@MainActor
func makeSettingsRow(_ row: UISettingsRow, compact: Bool = false) -> UISettingsRowView {
    switch row {
    case .link(let model): UISettingsLinkRow(model, compact: compact)
    case .choice(let model): UISettingsChoiceRow(model)
    case .actions(let model): UISettingsActionRow(model)
    case .info(let title, let value): UISettingsInfoRow(title: title, value: value)
    case .note(let text): UISettingsNoteRow(text)
    case .hosted(let model): UISettingsHostedRow(model)
    case .tiles(let model): UISettingsTileGridRow(model)
    case .buttons(let model): UISettingsButtonsRow(model)
    case .posters(let model): UISettingsPosterGridRow(model)
    case .profile(let model): UISettingsProfileRow(model)
    }
}

/// A picture for a UIKit row, from the app's cache, decoded at its size.
enum UISettingsPicture {
    @MainActor static func load(_ url: String?, size: CGFloat, into view: UIImageView) {
        view.accessibilityIdentifier = url
        guard let url else { view.image = nil; return }
        let key = RemoteImage.memoryKey(url, maxDimension: size, maxPixels: nil)
        if let hit = ImageCache.shared.image(for: key) { view.image = hit; return }
        view.image = nil
        Task { @MainActor [weak view] in
            _ = await ImageCache.shared.preload(url, maxDimension: size)
            guard let view, view.accessibilityIdentifier == url else { return }
            UIView.transition(with: view, duration: 0.2, options: .transitionCrossDissolve) {
                view.image = ImageCache.shared.image(for: key)
            }
        }
    }
}

/// A SwiftUI piece in a card, as tall as it wants to be.
final class UISettingsHostedRow: UIView, UISettingsRowView {
    private let host: UIHostingController<AnyView>
    private var key: String

    /// Measured at the card's width (SwiftUI's own intrinsic size came
    /// out zero for pieces that fill their width).
    private var height: CGFloat = 0
    private var measuredWidth: CGFloat = 0

    init(_ model: UISettingsRow.Hosted) {
        host = UIHostingController(rootView: model.view())
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        key = model.key
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .hosted(let model) = row else { return false }
        if model.key != key {
            key = model.key
            host.rootView = model.view()
            measuredWidth = 0
            setNeedsLayout()
        }
        return true
    }

    private func measure(_ width: CGFloat) -> CGFloat {
        ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height > 0 ? height : measure(1200))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.width != measuredWidth {
            measuredWidth = bounds.width
            let measured = measure(bounds.width)
            if abs(measured - height) > 0.5 {
                height = measured
                invalidateIntrinsicContentSize()
            }
        }
        host.view.frame = bounds
    }
}

/// One tile to pick: a colour with the initial on it, or an avatar over
/// its name; focused the rows' lit glass, chosen the faint one, 4 pt in
/// from its room either side, 16 pt corners.
/// A tile in a grid of tiles (the page scrolls by its lines).
protocol UISettingsGridTile: UIView {
    /// The one picked (a grid opens on it).
    var chosen: Bool { get }
}

extension UISettingsGridTile {
    var chosen: Bool { false }
}

final class UISettingsTile: UIView, UISettingsGridTile {
    private var model: UISettingsRow.Tile
    var chosen: Bool { model.chosen }
    private let picture = UIImageView()
    private let initial = UILabel()
    private let name = UISettings.label(23, .medium)
    private var lit: UISettingsHosted?
    private var faint: UISettingsHosted?

    static let picture: CGFloat = 80
    static func height(_ face: UISettingsRow.Tile.Face) -> CGFloat {
        switch face {
        case .colour, .symbol: 12 + picture + 12
        case .avatar: 12 + picture + 8 + ceil(UIFont.systemFont(ofSize: 23, weight: .medium).lineHeight) + 12
        }
    }

    init(_ model: UISettingsRow.Tile) {
        self.model = model
        super.init(frame: .zero)
        picture.clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.layer.cornerRadius = Self.picture / 2
        picture.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        initial.font = .systemFont(ofSize: 36, weight: .heavy)
        initial.textColor = .white
        initial.textAlignment = .center
        name.textAlignment = .center
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.9
        for view in [picture, initial, name] as [UIView] { addSubview(view) }
        configure(loading: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ model: UISettingsRow.Tile) {
        self.model = model
        configure(loading: false)
    }

    private func configure(loading: Bool) {
        switch model.face {
        case .colour(let hex, let letter):
            picture.backgroundColor = UIColor(Color(profileHex: hex))
            initial.text = letter
            initial.isHidden = false
            name.isHidden = true
        case .avatar(let url, let title):
            if loading { UISettingsPicture.load(url, size: Self.picture, into: picture) }
            initial.isHidden = true
            name.isHidden = false
            name.text = title
        case .symbol:
            initial.isHidden = true
            name.isHidden = true
        }
        paint()
        show(animated: !loading)
    }

    private func paint() {
        name.textColor = isFocused ? .black : CueInk.ui(FixedFocusText.primary)
    }

    private func plate(_ focused: Bool) -> UISettingsHosted {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let view = UISettingsHosted(focused ? AnyView(GlassHighlight(focused: true, shape: shape))
                                            : AnyView(shape.fill(FlatControl.selected)))
        view.alpha = 0
        insertSubview(view, at: 0)
        view.frame = bounds.insetBy(dx: 4, dy: 0)
        return view
    }

    private func show(animated: Bool) {
        if isFocused, lit == nil { lit = plate(true) }
        if model.chosen, faint == nil { faint = plate(false) }
        let change = {
            self.lit?.alpha = self.isFocused ? 1 : 0
            self.faint?.alpha = self.model.chosen && !self.isFocused ? 1 : 0
            self.paint()
        }
        if animated {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: change)
        } else {
            change()
        }
    }

    override var canBecomeFocused: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.picture
        picture.frame = CGRect(x: (bounds.width - side) / 2, y: 12, width: side, height: side)
        initial.frame = picture.frame
        name.frame = CGRect(x: 6, y: picture.frame.maxY + 8, width: bounds.width - 12,
                            height: ceil(name.font.lineHeight))
        for plate in [lit, faint].compactMap({ $0 }) { plate.frame = bounds.insetBy(dx: 4, dy: 0) }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard context.nextFocusedView === self || context.previouslyFocusedView === self else { return }
        show(animated: true)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        model.action()
    }
}

/// One tile in the gate's look (a new profile's avatars and profiles):
/// the circle alone with the cards' rim, focused 5 % larger with the
/// bright edge and a soft shadow on focus's spring; a caption under it at
/// a caption's levels, stepping down by the growth.
final class UISettingsRoundTile: UIView, UISettingsGridTile {
    private var model: UISettingsRow.Tile
    var chosen: Bool { model.chosen }
    private let side: CGFloat
    private let disc = UIView()
    private let picture = UIImageView()
    private let initial = UILabel()
    private let symbol = UIImageView()
    private let rim = UIView()
    private let caption = UISettings.label(24, .medium)
    private var loadedURL: String?

    static let captionGap: CGFloat = 22
    static func height(side: CGFloat, captioned: Bool) -> CGFloat {
        side + (captioned ? captionGap + ceil(UIFont.systemFont(ofSize: 24, weight: .medium).lineHeight) : 0)
    }

    init(_ model: UISettingsRow.Tile, side: CGFloat) {
        self.model = model
        self.side = side
        super.init(frame: .zero)
        disc.layer.cornerRadius = side / 2
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0
        disc.layer.shadowRadius = 18
        disc.layer.shadowOffset = CGSize(width: 0, height: 10)
        disc.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).cgPath
        picture.clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.layer.cornerRadius = side / 2
        initial.font = .systemFont(ofSize: side * 0.42, weight: .heavy)
        initial.textColor = .white
        initial.textAlignment = .center
        symbol.contentMode = .center
        rim.isUserInteractionEnabled = false
        rim.layer.cornerRadius = side / 2
        rim.layer.borderWidth = 2
        caption.textAlignment = .center
        caption.lineBreakMode = .byTruncatingTail
        addSubview(disc)
        for view in [picture, initial, symbol, rim] as [UIView] { disc.addSubview(view) }
        addSubview(caption)
        configure()
        style(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ model: UISettingsRow.Tile) {
        self.model = model
        configure()
    }

    private func configure() {
        initial.isHidden = true
        symbol.isHidden = true
        picture.isHidden = true
        switch model.face {
        case .colour(let hex, let letter):
            picture.backgroundColor = UIColor(Color(profileHex: hex))
            picture.image = nil
            picture.isHidden = false
            loadedURL = nil
            initial.text = letter
            initial.isHidden = false
        case .avatar(let url, _):
            picture.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            picture.isHidden = false
            if loadedURL != url {
                loadedURL = url
                picture.image = nil
                UISettingsPicture.load(url, size: side, into: picture)
            }
        case .symbol(let name):
            loadedURL = nil
            symbol.isHidden = false
            symbol.image = UISettings.symbol(name, side * 0.3)
        }
        caption.text = model.caption
        caption.isHidden = model.caption == nil
        style(animated: false)
    }

    private func style(animated: Bool) {
        let focused = isFocused
        let outlines = FixedFocusRing.outlines
        let plate: Bool = { if case .symbol = model.face { return true } else { return false } }()
        let change = {
            if plate {
                self.disc.backgroundColor = focused ? UIColor(FlatControl.focus) : UIColor(FlatControl.rest)
                self.symbol.tintColor = focused ? UIColor(FlatControl.contentOnFocus) : UIColor(FlatControl.content)
                self.symbol.image = self.symbol.image?.withRenderingMode(.alwaysTemplate)
            } else {
                self.disc.backgroundColor = .clear
            }
            self.rim.layer.borderColor = UIColor.white.withAlphaComponent(focused && outlines == .high ? 0.75 : 0.30).cgColor
            self.rim.alpha = outlines == .off || (plate && focused) ? 0 : 1
            self.disc.layer.shadowOpacity = focused ? 0.45 : 0
            self.caption.textColor = CueInk.ui(focused ? FixedFocusText.primary : FixedFocusText.secondary)
        }
        let grow = {
            let scale = focused ? ProfileGate.focusScale : 1
            self.disc.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.caption.transform = CGAffineTransform(translationX: 0, y: focused ? self.side * (scale - 1) / 2 : 0)
        }
        guard animated else { change(); grow(); return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        FixedFocusMotion.run(duration: Motion.focusDuration, animations: grow) { _ in }
    }

    override var canBecomeFocused: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        let saved = disc.transform
        disc.transform = .identity
        disc.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        disc.transform = saved
        for view in [picture, initial, symbol, rim] as [UIView] { view.frame = disc.bounds }
        let savedCaption = caption.transform
        caption.transform = .identity
        caption.frame = CGRect(x: 0, y: side + Self.captionGap, width: bounds.width,
                               height: ceil(caption.font.lineHeight))
        caption.transform = savedCaption
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self { model.onFocus?() }
        guard context.nextFocusedView === self || context.previouslyFocusedView === self else { return }
        style(animated: true)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        model.action()
    }
}

/// Tiles to pick from: each kind under its name (24 pt semibold,
/// tertiary), ten across, 6 apart, lines 12 apart. Round (the wizard):
/// slots of the circle's size, the cards' gap apart, each line centred,
/// each group starting a line, no names.
final class UISettingsTileGridRow: UIView, UISettingsRowView {
    private var model: UISettingsRow.Tiles
    private var tiles: [String: UIView] = [:]
    private var labels: [UILabel] = []
    private var shape: [String] = []
    static let across = 10
    static let gap: CGFloat = 6
    static let lineGap: CGFloat = 12
    private var height: CGFloat = 0

    init(_ model: UISettingsRow.Tiles) {
        self.model = model
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .tiles(let model) = row else { return false }
        self.model = model
        build()
        return true
    }

    private var round: CGFloat? { model.round }
    private var captioned: Bool { model.groups.contains { $0.tiles.contains { $0.caption != nil } } }

    private func build() {
        let ids = ["\(round ?? 0)"] + model.groups.flatMap { [$0.name] + $0.tiles.map(\.id) }
        if ids != shape {
            shape = ids
            tiles.values.forEach { $0.removeFromSuperview() }
            labels.forEach { $0.removeFromSuperview() }
            tiles = [:]
            labels = []
            for group in model.groups {
                if round == nil {
                    let label = UISettings.label(UISettings.textSize, .semibold, FixedFocusText.tertiary)
                    label.text = group.name
                    labels.append(label)
                    addSubview(label)
                }
                for tile in group.tiles {
                    let view: UIView = round.map { UISettingsRoundTile(tile, side: $0) } ?? UISettingsTile(tile)
                    tiles[tile.id] = view
                    addSubview(view)
                }
            }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        } else {
            for group in model.groups {
                for tile in group.tiles {
                    (tiles[tile.id] as? UISettingsTile)?.update(tile)
                    (tiles[tile.id] as? UISettingsRoundTile)?.update(tile)
                }
            }
        }
    }

    private var labelHeight: CGFloat { 12 + ceil(UIFont.systemFont(ofSize: UISettings.textSize, weight: .semibold).lineHeight) + 4 }

    /// Round: room above and below for the grown circle and its shadow.
    private static let roundRoom: CGFloat = 24

    /// Round lines are centred, so a short one leaves room either side the
    /// engine finds nothing in (Down from an edge tile went nowhere, or past
    /// it to a wider line): a guide fills each side, to its nearest tile.
    private var sideGuides: [UIFocusGuide] = []

    private var guidedLines: [CGRect] = []

    private func guideSides(_ lines: [(frame: CGRect, first: UIView, last: UIView)]) {
        // Only when the lines moved (new constraints lay the view out again).
        let frames = lines.map(\.frame) + [CGRect(x: 0, y: 0, width: bounds.width, height: 0)]
        guard frames != guidedLines else { return }
        guidedLines = frames
        sideGuides.forEach { removeLayoutGuide($0) }
        sideGuides = []
        for line in lines {
            for (x, width, target) in [(CGFloat(-400), line.frame.minX + 400, line.first),
                                       (line.frame.maxX, bounds.width + 400 - line.frame.maxX, line.last)] where width > 1 {
                let guide = UIFocusGuide()
                addLayoutGuide(guide)
                NSLayoutConstraint.activate([
                    guide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
                    guide.widthAnchor.constraint(equalToConstant: width),
                    guide.topAnchor.constraint(equalTo: topAnchor, constant: line.frame.minY),
                    guide.heightAnchor.constraint(equalToConstant: line.frame.height),
                ])
                guide.preferredFocusEnvironments = [target]
                sideGuides.append(guide)
            }
        }
    }

    private func measure(width: CGFloat, place: Bool) -> CGFloat {
        if let side = round {
            var lineFrames: [(frame: CGRect, first: UIView, last: UIView)] = []
            // A caption's slot is wider than its circle (a longer name).
            let slot = side + (captioned ? 60 : 0)
            let gap = FixedFocusMetrics.gap - (captioned ? 60 : 0)
            let across = max(1, Int((width + gap) / (slot + gap)))
            let tileHeight = UISettingsRoundTile.height(side: side, captioned: captioned)
            let lineGap: CGFloat = captioned ? 40 : 32
            var y = Self.roundRoom
            for (index, group) in model.groups.enumerated() where !group.tiles.isEmpty {
                if index > 0 { y += lineGap }
                for (i, tile) in group.tiles.enumerated() {
                    let line = i / across, column = i % across
                    // Each line centred (the wizard is centred).
                    let inLine = CGFloat(min(across, group.tiles.count - line * across))
                    let left = (width - (inLine * slot + (inLine - 1) * gap)) / 2
                    if place {
                        tiles[tile.id]?.frame = CGRect(x: left + CGFloat(column) * (slot + gap),
                                                       y: y + CGFloat(line) * (tileHeight + lineGap),
                                                       width: slot, height: tileHeight)
                    }
                }
                let lines = (group.tiles.count + across - 1) / across
                if place {
                    for line in 0..<lines {
                        let members = group.tiles[(line * across)..<min(group.tiles.count, (line + 1) * across)]
                            .compactMap { tiles[$0.id] }
                        guard let first = members.first, let last = members.last else { continue }
                        lineFrames.append((first.frame.union(last.frame), first, last))
                    }
                }
                y += CGFloat(lines) * tileHeight + CGFloat(max(0, lines - 1)) * lineGap
            }
            if place, lineFrames.count > 1 { guideSides(lineFrames) }
            return y + Self.roundRoom
        }
        let tileWidth = (width - CGFloat(Self.across - 1) * Self.gap) / CGFloat(Self.across)
        var y: CGFloat = 0
        for (index, group) in model.groups.enumerated() {
            if place, labels.indices.contains(index) {
                labels[index].frame = CGRect(x: UISettings.rowInset, y: y + 12, width: width - UISettings.rowInset,
                                             height: labelHeight - 16)
            }
            y += labelHeight
            guard let first = group.tiles.first else { continue }
            let tileHeight = UISettingsTile.height(first.face)
            for (i, tile) in group.tiles.enumerated() {
                let line = i / Self.across, column = i % Self.across
                if place {
                    tiles[tile.id]?.frame = CGRect(x: CGFloat(column) * (tileWidth + Self.gap),
                                                   y: y + CGFloat(line) * (tileHeight + Self.lineGap),
                                                   width: tileWidth, height: tileHeight)
                }
            }
            let lines = (group.tiles.count + Self.across - 1) / Self.across
            y += CGFloat(lines) * tileHeight + CGFloat(max(0, lines - 1)) * Self.lineGap
        }
        return y + 12
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: bounds.width > 0 ? height : measure(width: 1200, place: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let measured = measure(width: bounds.width, place: true)
        if abs(measured - height) > 0.5 {
            height = measured
            invalidateIntrinsicContentSize()
        }
    }
}

/// Capsule buttons centred on a row of no card: the wizard's Continue,
/// Skip, Create (the card rows' pills, spelled out).
final class UISettingsButtonsRow: UIView, UISettingsRowView {
    private var model: UISettingsRow.Buttons
    private var buttons: [String: UISettingsRoundButton] = [:]
    private let stack = UIStackView()

    init(_ model: UISettingsRow.Buttons) {
        self.model = model
        super.init(frame: .zero)
        stack.axis = .horizontal
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .buttons(let model) = row else { return false }
        self.model = model
        configure()
        return true
    }

    private func configure() {
        var kept: [UISettingsRoundButton] = []
        for action in model.actions {
            let button = buttons[action.id] ?? UISettingsRoundButton()
            buttons[action.id] = button
            button.set(icon: action.icon, danger: action.danger, nudge: 0)
            button.set(words: action.title)
            button.accessibilityLabel = action.title
            button.onSelect = { action.action() }
            kept.append(button)
        }
        for (key, button) in buttons where !kept.contains(where: { $0 === button }) {
            button.removeFromSuperview()
            buttons[key] = nil
        }
        for (index, button) in kept.enumerated() where stack.arrangedSubviews.firstIndex(of: button) != index {
            stack.insertArrangedSubview(button, at: index)
        }
    }

    var entry: UIView? { stack.arrangedSubviews.first }
}

/// A poster to like, as every poster card: the cards' corners and rim,
/// focused grown by `focusLift` with the bright edge and the soft shadow;
/// its name and line under it at a caption's levels, stepping down by the
/// growth. Liked: the taste badge's heart (Cue's red on the badges'
/// plate) top left.
final class UISettingsPosterTile: UIView, UISettingsGridTile {
    private var model: UISettingsRow.PosterItem
    private let card = UIView()
    private let picture = UIImageView()
    private let rim = UIImageView()
    private let ring = UIView()
    private let shadow = UIImageView()
    private let heart = UIView()
    private let heartSymbol = UIImageView()
    private let name = UISettings.label(FixedFocusMetrics.captionSize, .medium)
    private let detail = UISettings.label(FixedFocusMetrics.captionSize, .regular)

    static let size = FixedFocusMetrics.posterCard
    static let captionGap: CGFloat = 16
    static let font = UIFont.systemFont(ofSize: FixedFocusMetrics.captionSize, weight: .medium)
    static var height: CGFloat { size.height + captionGap + 2 * ceil(font.lineHeight) + 2 }
    private static var lift: CGFloat { FixedFocusMetrics.focusLift(size) }

    init(_ model: UISettingsRow.PosterItem) {
        self.model = model
        super.init(frame: .zero)
        shadow.image = FixedFocusCardEdge.shadowImage
        shadow.alpha = 0
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = Spotlight.cornerRadius
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        rim.image = FixedFocusCardEdge.rim
        // Home's focus edge: the rim's width, bright (Card Outlines' high only).
        ring.layer.cornerRadius = Spotlight.cornerRadius
        ring.layer.cornerCurve = .continuous
        ring.alpha = 0
        heart.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        heart.layer.cornerRadius = 10
        heart.layer.cornerCurve = .continuous
        heartSymbol.contentMode = .center
        heartSymbol.image = UISettings.symbol("heart.fill", 21)?
            .withTintColor(FixedFocusBadges.cue, renderingMode: .alwaysOriginal)
        heart.addSubview(heartSymbol)
        card.addSubview(shadow)
        for view in [picture, rim, ring, heart] as [UIView] { card.addSubview(view) }
        for view in [card, name, detail] as [UIView] { addSubview(view) }
        configure(loading: true)
        style(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ model: UISettingsRow.PosterItem) {
        self.model = model
        configure(loading: false)
    }

    private func configure(loading: Bool) {
        if loading { UISettingsPicture.load(model.poster, size: Self.size.width, into: picture) }
        name.text = model.title
        detail.text = model.detail
        detail.isHidden = model.detail.isEmpty
        heart.isHidden = !model.on
    }

    private func style(animated: Bool) {
        let focused = isFocused
        let lift = Self.lift
        let fade = {
            self.ring.alpha = focused ? 1 : 0
            self.shadow.alpha = focused ? 1 : 0
            self.name.textColor = CueInk.ui(focused ? FixedFocusText.primary : FixedFocusText.secondary)
            self.detail.textColor = CueInk.ui(focused ? FixedFocusText.body : FixedFocusText.tertiary)
        }
        let grow = {
            let scale = focused ? 1 + lift : 1
            self.card.transform = CGAffineTransform(scaleX: scale, y: scale)
            let step = CGAffineTransform(translationX: 0, y: focused ? Self.size.height * lift / 2 : 0)
            self.name.transform = step
            self.detail.transform = step
        }
        guard animated else { fade(); grow(); return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: fade)
        FixedFocusMotion.run(duration: Motion.focusDuration, animations: grow) { _ in }
    }

    override var canBecomeFocused: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = Self.size
        let saved = card.transform
        card.transform = .identity
        card.frame = CGRect(origin: .zero, size: size)
        card.transform = saved
        for view in [picture, rim, ring] as [UIView] { view.frame = card.bounds }
        ring.layer.borderWidth = FixedFocusRing.width
        ring.layer.borderColor = FixedFocusRing.color.cgColor
        let pad = FixedFocusCardEdge.shadowPad
        shadow.frame = card.bounds.insetBy(dx: -pad, dy: -pad)
        heart.frame = CGRect(x: 12, y: 12, width: 45, height: 40)
        heartSymbol.frame = heart.bounds
        let line = ceil(Self.font.lineHeight)
        for (label, y) in [(name, size.height + Self.captionGap), (detail, size.height + Self.captionGap + line + 2)] {
            let kept = label.transform
            label.transform = .identity
            label.frame = CGRect(x: FixedFocusMetrics.textIndent, y: y, width: size.width - FixedFocusMetrics.textIndent, height: line)
            label.transform = kept
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard context.nextFocusedView === self || context.previouslyFocusedView === self else { return }
        if context.nextFocusedView === self { superview?.bringSubviewToFront(self) }
        style(animated: true)
    }

    /// The focused card's growth above its top (the row's name steps up by it).
    static var growthAbove: CGFloat { size.height * lift / 2 }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        model.action()
    }
}

/// Posters in one line under the row's name, as Home's moving-focus rows:
/// running the screen's width, scrolled only by us on the move's spring by
/// Home's window (`windowOffset`: as many in full as fit, slivers either
/// side once it has moved); the name steps up by the focused card's growth
/// while that card is under it.
final class UISettingsPosterGridRow: UIView, UISettingsRowView, UIScrollViewDelegate {
    private var model: UISettingsRow.Posters
    private var tiles: [String: UISettingsPosterTile] = [:]
    private var shape: [String] = []
    private let scroll = UIScrollView()
    private let name = UILabel()
    private var windowStart = 0
    private var offset: CGFloat = 0
    static let gap = FixedFocusMetrics.gap
    static var tileWidth: CGFloat { UISettingsPosterTile.size.width }
    /// Above and below the cards: their growth and shadow.
    private static let room: CGFloat = 40
    private static var titleHeight: CGFloat { FixedFocusMetrics.titleHeight }

    init(_ model: UISettingsRow.Posters) {
        self.model = model
        super.init(frame: .zero)
        scroll.clipsToBounds = false
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        name.font = FixedFocusRowCell.titleFont
        name.textColor = CueInk.ui(FixedFocusText.primary)
        addSubview(name)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: UISettingsRow) -> Bool {
        guard case .posters(let model) = row else { return false }
        self.model = model
        build()
        return true
    }

    private func build() {
        name.text = model.title
        name.isHidden = model.title == nil
        let ids = model.items.map(\.id)
        if ids != shape {
            shape = ids
            let old = tiles
            tiles = [:]
            for item in model.items {
                if let view = old[item.id] {
                    view.update(item)
                    tiles[item.id] = view
                } else {
                    let view = UISettingsPosterTile(item)
                    tiles[item.id] = view
                    scroll.addSubview(view)
                }
            }
            for (id, view) in old where tiles[id] == nil { view.removeFromSuperview() }
            setNeedsLayout()
        } else {
            for item in model.items { tiles[item.id]?.update(item) }
        }
    }

    private var tileHeight: CGFloat { UISettingsPosterTile.height }
    private var top: CGFloat { model.title == nil ? 0 : Self.titleHeight }

    /// The first poster (a page's first row to press).
    var firstTile: UIView? { model.items.first.flatMap { tiles[$0.id] } }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: top + tileHeight + 12) }

    /// The screen's left edge in this row's space.
    private var screenLeft: CGFloat { window.map { -convert(CGPoint.zero, to: $0).x } ?? -FixedFocusMetrics.inset }

    override func layoutSubviews() {
        super.layoutSubviews()
        let left = screenLeft
        name.frame = CGRect(x: left + FixedFocusMetrics.titleInset, y: FixedFocusMetrics.titleDrop + nameStep,
                            width: 1200, height: FixedFocusMetrics.titleLine)
        // The scroll runs the screen's width; the cards from the rows' edge.
        scroll.frame = CGRect(x: left, y: top - Self.room, width: 1920, height: tileHeight + 2 * Self.room)
        var x = FixedFocusMetrics.inset
        for item in model.items {
            tiles[item.id]?.frame = CGRect(x: x, y: Self.room, width: Self.tileWidth, height: tileHeight)
            x += Self.tileWidth + Self.gap
        }
        scroll.contentSize = CGSize(width: x - Self.gap + FixedFocusMetrics.inset, height: scroll.bounds.height)
        if abs(scroll.contentOffset.x - offset) > 0.5 { scroll.contentOffset = CGPoint(x: offset, y: 0) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    // MARK: Home's moves

    private var nameStep: CGFloat = 0

    /// Home's window: as many cards in full as the screen holds, slivers of
    /// the ones before and after split evenly once the row has moved.
    private func windowOffset(focusing index: Int) -> CGFloat {
        let gap = Self.gap, card = Self.tileWidth, pitch = card + gap
        let count = model.items.count
        let room = 1920 - 2 * (gap + FixedFocusMetrics.destinationSliver)
        let shown = max(1, Int((room + gap) / pitch))
        if index < windowStart { windowStart = index }
        if index > windowStart + shown - 1 { windowStart = index - shown + 1 }
        guard windowStart > 0 else { return 0 }
        let edge = (1920 - CGFloat(shown) * card - CGFloat(shown - 1) * gap) / 2
        let content = 2 * FixedFocusMetrics.inset + CGFloat(count) * pitch - gap
        let end = max(0, content - 1920)
        return min(FixedFocusMetrics.inset + CGFloat(windowStart) * pitch - edge, end)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let next = context.nextFocusedView
        let index = model.items.firstIndex { tiles[$0.id] === next }
        if let index { offset = windowOffset(focusing: index) }
        // The name out of the grown card's way, only while it's under it.
        var step: CGFloat = 0
        if let index, model.title != nil {
            let cardLeft = FixedFocusMetrics.inset + CGFloat(index) * (Self.tileWidth + Self.gap) - offset
            let lift = UISettingsPosterTile.growthAbove
            let nameEnd = FixedFocusMetrics.titleInset + name.intrinsicContentSize.width
            if cardLeft - lift < nameEnd, cardLeft + Self.tileWidth + lift > FixedFocusMetrics.titleInset { step = -lift }
        }
        let moved = abs(scroll.contentOffset.x - offset) > 0.5 || step != nameStep
        nameStep = step
        guard moved else { return }
        let target = offset
        FixedFocusMotion.run(duration: Motion.moveDuration, animations: {
            self.scroll.contentOffset = CGPoint(x: target, y: 0)
            self.name.frame.origin.y = FixedFocusMetrics.titleDrop + step
        }) { _ in }
    }

    // The engine's own scroll, stopped: we move the row.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee = scrollView.contentOffset
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // The engine's focus scroll sets the offset directly: put it back.
        if abs(scrollView.contentOffset.x - offset) > 0.5 { scrollView.contentOffset = CGPoint(x: offset, y: 0) }
    }
}

// MARK: Cards, sections, the page

/// A section's card: its rows on the cards' fill, 22 pt corners, the
/// plates' inset round them; a hairline between two rows (under them: a
/// lit plate covers the ones beside it); rows only to read together in a
/// well.
final class UISettingsCard: UIView {
    private let stack = UIStackView()
    private var views: [String: UISettingsRowView] = [:]
    /// A row's view by its id.
    func rowView(_ id: String) -> UISettingsRowView? { views[id] }
    private var shape: [String] = []
    private var wells: [UIView] = []
    private let compact: Bool
    private let hairlineRoom: CGFloat
    private var insets: [NSLayoutConstraint] = []
    /// No fill and no padding: the row is its own card.
    var bare = false {
        didSet {
            guard bare != oldValue else { return }
            backgroundColor = bare ? .clear : UISettings.cardFill
            let pad = CardSettingsRow.cardPadding
            let values = bare ? [0, 0, 0, 0] : [pad.leading, -pad.trailing, pad.top, -pad.bottom]
            for (constraint, value) in zip(insets, values) { constraint.constant = value }
        }
    }

    init(compact: Bool = false) {
        self.compact = compact
        hairlineRoom = compact ? 11 : UISettings.hairlineRoom
        super.init(frame: .zero)
        backgroundColor = UISettings.cardFill
        layer.cornerRadius = Spotlight.cornerRadius
        layer.cornerCurve = .continuous
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = CardSettingsRow.cardPadding
        insets = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad.leading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad.trailing),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad.top),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad.bottom),
        ]
        NSLayoutConstraint.activate(insets)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The row views in order (the categories, a page's focus).
    private(set) var rows: [UISettingsRowView] = []

    func set(_ models: [UISettingsRow]) {
        var next: [UISettingsRowView] = []
        var seen: Set<String> = []
        for model in models {
            let id = model.id
            guard seen.insert(id).inserted else { continue }
            if let view = views[id], view.apply(model) {
                next.append(view)
            } else {
                views[id]?.removeFromSuperview()
                let view = makeSettingsRow(model, compact: compact)
                views[id] = view
                next.append(view)
            }
        }
        for (id, view) in views where !seen.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        let newShape = models.map { ($0.onlyToRead ? "r:" : "a:") + $0.id }
        rows = next
        guard newShape != shape else { return }
        let reorder = Set(newShape) == Set(shape)
        shape = newShape
        arrange(models)
        // A row moved (Up and Down while lifted): the rows slide.
        if reorder, window != nil {
            UIView.animate(springDuration: 0.2, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.layoutIfNeeded()
            }
        }
    }

    /// A lifted row passes its neighbour (one that can move too): the two
    /// views swap in the stack and slide, nothing else is touched (the
    /// rules between them are alike).
    func shift(_ row: UISettingsActionRow, by step: Int) -> Bool {
        guard let index = rows.firstIndex(where: { $0 === row }), rows.indices.contains(index + step),
              let other = rows[index + step] as? UISettingsActionRow, other.canMove,
              let a = stack.arrangedSubviews.firstIndex(of: row),
              let b = stack.arrangedSubviews.firstIndex(of: other) else { return false }
        let (low, high) = a < b ? (row, other) : (other, row)
        let (lowAt, highAt) = (min(a, b), max(a, b))
        stack.insertArrangedSubview(high, at: lowAt)
        stack.insertArrangedSubview(low, at: highAt)
        rows.swapAt(index, index + step)
        // The order the store will have after the drop: no arrange then.
        if shape.indices.contains(index + step) { shape.swapAt(index, index + step) }
        for view in rows { stack.bringSubviewToFront(view) }
        stack.bringSubviewToFront(row)
        UIView.animate(springDuration: 0.2, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.stack.layoutIfNeeded()
        }
        return true
    }

    private func arrange(_ models: [UISettingsRow]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            if !(view is UISettingsRowView) { view.removeFromSuperview() }
        }
        wells.forEach { $0.removeFromSuperview() }
        wells = []
        var runStart: UIView?
        var previous: UIView?
        for (index, model) in models.enumerated() where index < rows.count {
            let view = rows[index]
            let sunk = model.onlyToRead
            if index > 0 {
                let previousSunk = models[index - 1].onlyToRead
                if sunk != previousSunk {
                    stack.addArrangedSubview(Self.space(UISettings.wellGap))
                } else {
                    stack.addArrangedSubview(Self.rule(room: hairlineRoom))
                }
                if previousSunk, !sunk, let start = runStart, let end = previous { addWell(start, end); runStart = nil }
            }
            if sunk, runStart == nil { runStart = view }
            stack.addArrangedSubview(view)
            previous = view
        }
        if let start = runStart, let end = previous { addWell(start, end) }
        // The rows over the hairlines: a lit plate covers the ones beside it.
        for view in rows { stack.bringSubviewToFront(view) }
    }

    private func addWell(_ first: UIView, _ last: UIView) {
        // SwiftUI's own well (its inner shade): Core Animation's blur drew
        // an edge round it.
        let well = UISettingsHosted(AnyView(EmbeddedWell()))
        well.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(well, belowSubview: stack)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            well.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            well.topAnchor.constraint(equalTo: first.topAnchor, constant: -UISettings.plateBleed),
            well.bottomAnchor.constraint(equalTo: last.bottomAnchor, constant: UISettings.plateBleed),
        ])
        wells.append(well)
    }

    private static func space(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private static func rule(room: CGFloat) -> UIView {
        let line = space(room)
        let rule = UIView()
        rule.backgroundColor = UISettings.hairline
        rule.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: UISettings.rowInset),
            rule.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -UISettings.rowInset),
        ])
        return line
    }
}

/// One section of a page (`UISettingsPageView`): its label, then its rows
/// on one card.
struct UISettingsSection {
    var label: String? = nil
    var rows: [UISettingsRow]
    /// No card of its own (a profile's header: its own colour).
    var bare = false
    /// Narrower than the column, centred in it (the wizard's cards).
    var width: CGFloat? = nil
}

/// A section's view: its label (24 pt semibold, tertiary, at the words'
/// edge, 30 pt tall and 12 above the card), then its card.
final class UISettingsSectionView: UIView {
    let label = UISettings.label(UISettings.textSize, .semibold, FixedFocusText.tertiary)
    let card: UISettingsCard
    private var labelHeight: NSLayoutConstraint!
    private var cardTop: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var labelLeading: NSLayoutConstraint!
    private var width: CGFloat?

    init(compact: Bool = false) {
        card = UISettingsCard(compact: compact)
        super.init(frame: .zero)
        for view in [label, card] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.numberOfLines = 1
        labelHeight = label.heightAnchor.constraint(equalToConstant: UISettings.labelRoom - 12)
        cardTop = card.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12)
        leading = card.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailing = card.trailingAnchor.constraint(equalTo: trailingAnchor)
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UISettings.textInset)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            labelLeading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelHeight, cardTop, leading, trailing,
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        let side = width.map { max(0, (bounds.width - $0) / 2) } ?? 0
        if leading.constant != side {
            leading.constant = side
            trailing.constant = -side
            labelLeading.constant = side + UISettings.textInset
        }
        super.layoutSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ section: UISettingsSection) {
        let labelled = !(section.label ?? "").isEmpty
        label.text = section.label
        label.isHidden = !labelled
        labelHeight.constant = labelled ? UISettings.labelRoom - 12 : 0
        cardTop.constant = labelled ? 12 : 0
        card.bare = section.bare
        card.set(section.rows)
        if width != section.width {
            width = section.width
            setNeedsLayout()
        }
    }
}

/// A page in the right column: its sections 40 apart, scrolling under the
/// fade into the gap above the column (`scrollTo`). A page whose first
/// section has no label starts its
/// card level with the categories' first card. Scrolled only by us, on
/// Core Animation (the engine's own scroll runs on the main thread).
class UISettingsPageView: UIView, UIScrollViewDelegate {
    /// The gap above the column the page scrolls into, the fade over it.
    static let above = SettingsTopFade.height
    static let fade = SettingsTopFade.fade
    /// Past the focused row, what shows of the next one (about a row).
    static let peek: CGFloat = 70
    /// Under the last card, to the screen's foot.
    static let foot: CGFloat = 60
    /// Beyond the column: shadows and grown pills, unclipped.
    static let sideRoom: CGFloat = 80
    static let footRoom: CGFloat = 200

    let scroll = UIScrollView()
    /// The scroll and its fade; a pinned view sits beside it, outside the fade.
    private let holder = UIView()
    /// Stays at the column's top while the rows scroll under it (the
    /// avatar picker's preview); its height fixed.
    private var pinned: UIView?
    private var pinnedHeight: CGFloat = 0
    /// With a pinned view: one card from it to the column's foot, the rows
    /// scrolling inside it, fading out at its edges.
    private let pinnedCard = UIView()
    static let edgeFade: CGFloat = 16
    private var column: CGRect?
    private let content = UIStackView()
    private var sectionViews: [UISettingsSectionView] = []
    private var topRoom: NSLayoutConstraint!
    private let fadeMask = CAGradientLayer()
    /// Fades out at the column's foot too (the wizard: its dots are there).
    var fadesAtFoot = false
    private var offset: CGFloat = 0
    /// The row focus was on last in this page (it lands there again).
    private weak var lastFocused: UIView?

    init() {
        super.init(frame: .zero)
        clipsToBounds = false
        scroll.delegate = self
        scroll.clipsToBounds = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        holder.clipsToBounds = false
        addSubview(holder)
        holder.addSubview(scroll)
        content.axis = .vertical
        content.spacing = UISettings.sectionGap
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        topRoom = content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.above)
        NSLayoutConstraint.activate([
            topRoom,
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Self.foot),
        ])
        fadeMask.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        holder.layer.mask = fadeMask
    }

    /// A view kept at the column's top, `height` tall; the rows start a
    /// section's gap under it and scroll there.
    func pin(_ view: UIView, height: CGFloat) {
        pinned?.removeFromSuperview()
        pinned = view
        pinnedHeight = height
        pinnedCard.backgroundColor = UISettings.cardFill
        pinnedCard.layer.cornerRadius = Spotlight.cornerRadius
        pinnedCard.layer.cornerCurve = .continuous
        pinnedCard.isUserInteractionEnabled = false
        insertSubview(pinnedCard, at: 0)
        addSubview(view)
        for view in sectionViews where !view.card.bare { view.card.backgroundColor = .clear }
        if let column { place(column: column) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Laid out over the column: the scroll from the gap above it.
    func place(column: CGRect) {
        self.column = column
        frame = CGRect(x: column.minX - Self.sideRoom, y: column.minY - Self.above,
                       width: column.width + 2 * Self.sideRoom, height: column.height + Self.above + Self.footRoom)
        holder.frame = bounds
        // Pinned: the top of one card level with the categories' first, to
        // the foot; the rows (an unlabelled first section) right under the
        // pinned view, fading out at its edge and at the card's foot.
        let cardTop = Self.above + UISettings.labelRoom
        let cardBottom = Self.above + column.height - Self.foot
        let room = pinned == nil ? 0 : pinnedHeight
        pinned?.frame = CGRect(x: Self.sideRoom, y: cardTop, width: column.width, height: pinnedHeight)
        pinnedCard.frame = CGRect(x: Self.sideRoom, y: cardTop, width: column.width, height: cardBottom - cardTop)
        scroll.frame = CGRect(x: Self.sideRoom, y: room, width: column.width, height: column.height + Self.above - room)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = holder.bounds
        let h = holder.bounds.height
        func at(_ y: CGFloat) -> NSNumber { NSNumber(value: Double(y / h)) }
        if pinned == nil, fadesAtFoot {
            let foot = Self.above + column.height
            fadeMask.colors = [UIColor.clear, .clear, .black, .black, .clear, .clear].map(\.cgColor)
            fadeMask.locations = [0, at(Self.above - Self.fade), at(Self.above), at(foot - 60), at(foot), 1]
        } else if pinned == nil {
            fadeMask.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
            fadeMask.locations = [0, at(Self.above - Self.fade), at(Self.above), 1]
        } else {
            let line = cardTop + pinnedHeight
            fadeMask.colors = [UIColor.clear, .clear, .black, .black, .clear, .clear].map(\.cgColor)
            fadeMask.locations = [0, at(line), at(line + Self.edgeFade),
                                  at(cardBottom - Self.edgeFade), at(cardBottom), 1]
        }
        CATransaction.commit()
    }

    func set(_ sections: [UISettingsSection]) {
        while sectionViews.count < sections.count {
            let view = UISettingsSectionView()
            sectionViews.append(view)
            content.addArrangedSubview(view)
        }
        while sectionViews.count > sections.count {
            sectionViews.removeLast().removeFromSuperview()
        }
        for (view, section) in zip(sectionViews, sections) {
            view.set(section)
            if pinned != nil, !section.bare { view.card.backgroundColor = .clear }
        }
        let labelled = !(sections.first?.label ?? "").isEmpty
        topRoom.constant = Self.above + (labelled ? 0 : UISettings.labelRoom)
        // Its rows came (a page that loads): focus onto them.
        if isFocused, firstFocusable != nil {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        // A row moved (lifted, Up and Down) stays in view.
        if let focused = UISettings.focusedView(in: self), focused.isDescendant(of: content) {
            scrollTo(focused, animated: true)
        }
    }

    /// The first row focus can take.
    var firstFocusable: UIView? {
        for section in sectionViews {
            for row in section.card.rows {
                if row.canBecomeFocused { return row }
                if let control = row as? UISettingsControlRow, let entry = control.entry { return entry }
                if let buttons = row as? UISettingsButtonsRow, let entry = buttons.entry { return entry }
                // A grid: the chosen tile (the avatar picker opens on yours), else the first.
                if let grid = row as? UISettingsTileGridRow {
                    let tiles = grid.subviews.compactMap { $0 as? UISettingsGridTile }
                    if let tile = tiles.first(where: \.chosen) ?? tiles.first { return tile }
                }
                if let posters = row as? UISettingsPosterGridRow, let first = posters.firstTile { return first }
            }
        }
        return nil
    }

    /// Where focus goes next time the page takes it: the row `id` (its
    /// first control). False: no such row.
    @discardableResult
    func prefer(row id: String) -> Bool {
        layoutIfNeeded()
        for section in sectionViews {
            guard let row = section.card.rowView(id) else { continue }
            let target: UIView? = row.canBecomeFocused ? row : (row as? UISettingsControlRow)?.entry
            guard let target else { return false }
            lastFocused = target
            return true
        }
        return false
    }

    /// A page with nothing to press holds focus itself, unseen (Back and
    /// Left still work from it).
    override var canBecomeFocused: Bool { firstFocusable == nil }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let lastFocused, lastFocused.window != nil, lastFocused.canBecomeFocused { return [lastFocused] }
        return firstFocusable.map { [$0] } ?? []
    }

    /// Back at the page's top, as it opens.
    func reset() {
        lastFocused = nil
        offset = 0
        scroll.contentOffset = .zero
    }

    // The engine's own scroll, stopped where the page is.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee = scrollView.contentOffset
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: content) else { return }
        lastFocused = next
        scrollTo(next, animated: true)
    }

    /// Only when needed, and as little as needed (tvOS's own lists): a
    /// page that fits never moves; a taller one moves as focus nears an
    /// edge, just far enough that the next row shows below the focused
    /// one, or going up, its section's label over a section's first row;
    /// never past the last card. (Before, 2026-11-23: the focused row's
    /// section snapped to the column's top line on every move — too much
    /// movement on pages that fit.)
    func scrollTo(_ view: UIView, animated: Bool) {
        layoutIfNeeded()
        guard let section = sectionViews.first(where: { view.isDescendant(of: $0) }) else { return }
        // The row (a tile in the avatars' grid: the tile itself).
        let rowView = view is UISettingsGridTile ? view
            : section.card.rows.first(where: { view.isDescendant(of: $0) }) ?? view
        let row = rowView.convert(rowView.bounds, to: content).offsetBy(dx: 0, dy: content.frame.minY)
        // The section's first row (a tile: the grid's first line).
        var first = section.card.rows.first.map { view.isDescendant(of: $0) } ?? false
        if first, view is UISettingsGridTile, let grid = view.superview {
            let top = grid.subviews.filter { $0 is UISettingsGridTile }.map(\.frame.minY).min() ?? 0
            first = view.frame.minY <= top + 1
        }
        let height = scroll.bounds.height
        let end = (sectionViews.last.map { $0.frame.maxY } ?? 0) + content.frame.minY + Self.foot
        // What shows: a pinned view's page, inside its card's fades.
        let bottom = pinned == nil ? height : height - Self.foot - Self.edgeFade
        var target = offset
        if row.maxY + Self.peek > target + bottom { target = row.maxY + Self.peek - bottom }
        let wantedTop = first ? section.frame.minY + content.frame.minY : row.minY - Self.peek
        // Where what scrolls goes out of sight (a pinned view's page: lower).
        let line = Self.above + (pinned == nil ? 0 : UISettings.labelRoom + Self.edgeFade)
        if wantedTop < target + line { target = wantedTop - line }
        target = min(target, max(0, end - height))
        target = max(0, target)
        // Back in the page's first section: all the way to the top, level
        // with the categories again (its missing label left it a few points short).
        if section === sectionViews.first, first || row.minY - Self.peek < Self.above { target = 0 }
        // The first row to press, below rows only to read (For You's taste):
        // as near the top as it stays in view, so what's above it can be read.
        if let firstRow = firstFocusable, firstRow === view || firstRow.isDescendant(of: rowView) {
            target = max(0, min(target, row.maxY + Self.peek - bottom))
        }
        guard abs(target - offset) > 0.5 else {
            if abs(scroll.contentOffset.y - target) > 0.5 { scroll.contentOffset.y = target }
            return
        }
        offset = target
        if animated {
            FixedFocusMotion.run(duration: Motion.moveDuration, animations: {
                self.scroll.contentOffset = CGPoint(x: 0, y: target)
            }) { _ in }
        } else {
            scroll.contentOffset = CGPoint(x: 0, y: target)
        }
    }
}

// MARK: - The keyboard, from UIKit

/// Opens the tvOS keyboard straight away (`KeyboardPresenter`'s way): a
/// hidden field becomes first responder.
final class UISettingsKeyboard: NSObject, UITextFieldDelegate {
    private let field = KeyboardPresenter.HiddenField()
    private var commit: ((String) -> Void)?

    func attach(to view: UIView) {
        field.alpha = 0.01
        field.delegate = self
        field.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.addSubview(field)
    }

    func ask(text: String, placeholder: String, commit: @escaping (String) -> Void) {
        self.commit = commit
        field.text = text
        field.placeholder = placeholder
        open(tries: 30)
    }

    /// As soon as the field is on screen (a page just made isn't yet).
    private func open(tries: Int) {
        if field.window != nil, field.becomeFirstResponder() { return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.open(tries: tries - 1) }
    }

    func textFieldDidEndEditing(_ field: UITextField) {
        commit?(field.text ?? "")
        commit = nil
    }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        field.resignFirstResponder()
        return true
    }
}
