import SwiftUI

// THE SETTINGS LOOK — close to Apple TV's own Settings, in Cue's style:
// two panes. On the left, at the app's left edge, a compact list of
// one-line rows (name left, value right) — what you came for, where you
// read first. (Apple has them the other way round; everything else in Cue
// starts at the left edge.) On the right, like an inspector, ONE BOX
// anchored level with the first row — the category's symbol (on the main
// page the focused category's; inside one, its own, with its name: where
// you are), or a preview where words can't show it (a background colour) —
// and the focused row's description below it. Both start at a fixed height
// — Home's row-name line — so nothing moves from page to page; only the
// box's content and the words change. Rows rest on a faint fill and,
// focused, sit on the light platter of the app's own buttons. (Tried: each
// section on one glass panel with the top bar's highlight — too heavy.)
//
// - `SettingsPage`: the two panes (and the info model the rows feed).
// - `SettingsSection`: a titled group of rows.
// - Rows: `SettingsToggleRow` (Select flips On / Off), `SettingsChoiceRow`
//   (Select opens `SettingsChoicePage`, a list with a tick), `SettingsLinkRow`
//   (opens a page), `SettingsButtonRow` (runs an action).

/// What the info pane shows for the focused row. (Its name is on the row
/// itself; `title` only tells rows apart, for the pane's crossfade.) In the
/// box: its preview, else its symbol, else the page's.
struct SettingsInfo {
    var title: String
    var description: String?
    var preview: AnyView? = nil
    var icon: String? = nil
    /// The symbol's colour (a category's own), else the page's.
    var tint: Color? = nil
}

/// Where a page belongs: its category's symbol and name, for the box. Pages
/// a page opens (a choice's list) keep it.
struct SettingsPlace {
    var icon: String
    /// Shown under the symbol inside a category; nil on the main page.
    var name: String?
    /// The symbol's colour (the category's).
    var tint: Color = .white
}

/// The page's focused-row info, fed by its rows.
@MainActor
final class SettingsInfoModel: ObservableObject {
    @Published var info: SettingsInfo?
}

enum SettingsMetrics {
    static let rowHeight: CGFloat = 72
    /// Home's cards' corners, for the rows and the box alike.
    /// Fully rounded, as Apple TV's own Settings rows (and the top bar).
    static var rowRadius: CGFloat { rowHeight / 2 }
    /// A row's text from its ends (more than a square corner needs).
    static let rowInset: CGFloat = 32
    static let rowTextSize: CGFloat = 29
    static let valueTextSize: CGFloat = 27
    static let sectionGap: CGFloat = 40
    static let rowGap: CGFloat = 12
    static let paneGap: CGFloat = 100
    /// Two equal columns: the list's and the info pane's.
    static var columnWidth: CGFloat { (1920 - 2 * FixedFocusMetrics.inset - paneGap) / 2 }
    static var infoWidth: CGFloat { columnWidth }
    /// Where both panes start, on every page: where Home's focused row
    /// has its name, below the top bar (which Settings always shows; the
    /// pages it opens don't, and start at the same spot).
    static var top: CGFloat { FixedFocusMetrics.rowTop }
    /// A section's label line (kept empty in a section without one), so
    /// the first row starts at the same height on every page…
    static let sectionLabelHeight: CGFloat = 30
    /// …here — and the box with it, top edge to top edge.
    static var firstRowTop: CGFloat { top + sectionLabelHeight + rowGap }
    /// The box: 16:9 across the info pane.
    static var boxHeight: CGFloat { infoWidth * 9 / 16 }
    /// A preview's corners (an account card): as round as a big card gets.
    static let boxRadius: CGFloat = 40
    static let descriptionGap: CGFloat = 30
    static let descriptionSize: CGFloat = 25
    /// The focused platter: the top bar's bright glass highlight
    /// (`GlassHighlight`); this, where a plain fill is needed.
    static let focusedFill = FlatControl.focus
    static let restingFill = FlatControl.restSubtle
    static let focusedText = Color.black
    static let secondaryText = Color.white.opacity(0.5)
}

/// The two panes: the rows on the left, the box and the focused row's
/// description on the right. With nothing focused yet, the description is
/// the page's.
struct SettingsPage<Content: View>: View {
    let place: SettingsPlace
    let subtitle: String
    @ViewBuilder let content: Content
    @StateObject private var model = SettingsInfoModel()

    var body: some View {
        HStack(alignment: .top, spacing: SettingsMetrics.paneGap) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                    content
                }
                .padding(.top, SettingsMetrics.top)
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            .frame(width: SettingsMetrics.columnWidth)
            SettingsInfoPane(place: place,
                             info: model.info ?? SettingsInfo(title: "", description: subtitle))
                .frame(width: SettingsMetrics.infoWidth)
                .padding(.top, SettingsMetrics.firstRowTop)
        }
        .padding(.horizontal, FixedFocusMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Screen coordinates: the same start with or without the top bar.
        .ignoresSafeArea(edges: [.top, .bottom])
        .background(ATVBackground())
        .environmentObject(model)
        .environment(\.settingsPlace, place)
    }
}

private struct SettingsPlaceKey: EnvironmentKey {
    static let defaultValue = SettingsPlace(icon: "gearshape.fill", name: nil)
}

extension EnvironmentValues {
    /// The page's place (see `SettingsPlace`), for the pages it opens.
    var settingsPlace: SettingsPlace {
        get { self[SettingsPlaceKey.self] }
        set { self[SettingsPlaceKey.self] = newValue }
    }
}

/// The info pane: the box, the description below it.
private struct SettingsInfoPane: View {
    let place: SettingsPlace
    let info: SettingsInfo

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.descriptionGap) {
            ZStack {
                if let preview = info.preview {
                    preview
                        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
                        .frame(height: SettingsMetrics.boxHeight)
                } else {
                    SettingsSymbol(icon: info.icon ?? place.icon, tint: info.tint ?? place.tint,
                                   name: place.name)
                        .padding(.top, 40)
                }
            }
            .frame(width: SettingsMetrics.infoWidth)
            .animation(.easeOut(duration: 0.15), value: info.title)

            Text(info.description ?? "")
                .font(.system(size: SettingsMetrics.descriptionSize))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .padding(.horizontal, FixedFocusMetrics.textIndent)
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.easeOut(duration: 0.15), value: info.title)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// The page's symbol, large and in its category's colour, on the page
/// itself (no box — as Apple TV's Settings); inside a category its name
/// below.
private struct SettingsSymbol: View {
    let icon: String
    let tint: Color
    let name: String?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: icon)
                .font(.system(size: 180, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(height: 230)
            if let name {
                Text(name.uppercased())
                    .font(.system(size: SectionHint.size, weight: SectionHint.weight))
                    .tracking(SectionHint.tracking)
                    .foregroundStyle(SettingsMetrics.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A titled group of rows.
struct SettingsSection<Content: View>: View {
    var title: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
            Text(title.uppercased())
                .font(.system(size: SectionHint.size, weight: SectionHint.weight))
                .tracking(SectionHint.tracking)
                .foregroundStyle(SettingsMetrics.secondaryText)
                .padding(.leading, SettingsMetrics.rowInset)
                .frame(height: SettingsMetrics.sectionLabelHeight, alignment: .bottomLeading)
            content
        }
        .focusSection()
    }
}

// MARK: - Rows

/// A row's content: name left, value (and chevron) right. Focused, it tells
/// the page what the info pane should show.
struct SettingsRowLabel: View {
    @Environment(\.isFocused) private var isFocused
    @EnvironmentObject private var model: SettingsInfoModel
    let title: String
    var value: String? = nil
    var chevron = false
    var checked = false
    let info: SettingsInfo

    /// What the info pane shows, as text — to notice it changing.
    private var infoKey: String {
        "\(info.title)|\(info.description ?? "")|\(info.icon ?? "")|\(info.preview != nil)|\(value ?? "")"
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                .foregroundStyle(isFocused ? SettingsMetrics.focusedText : Color.white)
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
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? SettingsMetrics.focusedText : Color.white)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.45)
                                               : SettingsMetrics.secondaryText)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .frame(height: SettingsMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .onChange(of: isFocused, initial: true) { _, focused in
            if focused { model.info = info }
        }
        // The focused row's info changing under it (a status updating).
        .onChange(of: infoKey) { _, _ in
            if isFocused { model.info = info }
        }
    }
}

/// Rows' chrome, as Apple TV's Settings: fully rounded; a faint fill at
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

        var body: some View {
            configuration.label
                .background {
                    let shape = RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius, style: .continuous)
                    if isFocused { GlassHighlight(focused: true, shape: shape) }
                    else { shape.fill(SettingsMetrics.restingFill) }
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.0 : 1.02) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 16, y: 8)
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
            SettingsRowLabel(title: title, value: isOn ? "On" : "Off",
                             info: SettingsInfo(title: title, description: description))
        }
        .buttonStyle(SettingsRowStyle())
    }
}

/// One option of a `SettingsChoiceRow`.
struct SettingsOption: Identifiable {
    let id: String
    let label: String
    var description: String? = nil
    var preview: AnyView? = nil
}

/// A choice: shows the current option; Select opens the list.
struct SettingsChoiceRow: View {
    @Environment(\.settingsPlace) private var place
    let title: String
    var description: String? = nil
    let options: [SettingsOption]
    let selection: String
    var preview: AnyView? = nil
    /// The option focused in the list (nil: none — the list is gone): for
    /// choices that preview themselves live, like the background.
    var onFocusOption: ((String?) -> Void)? = nil
    let onPick: (String) -> Void

    private var current: SettingsOption? { options.first { $0.id == selection } }

    var body: some View {
        NavigationLink {
            SettingsChoicePage(place: place, title: title, description: description, options: options,
                               selection: selection, onFocusOption: onFocusOption, onPick: onPick)
        } label: {
            SettingsRowLabel(title: title, value: current?.label, chevron: true,
                             info: SettingsInfo(title: title, description: description,
                                                preview: preview ?? current?.preview))
        }
        .buttonStyle(SettingsRowStyle())
    }
}

/// The options of a choice, the current one ticked; picking one goes back.
struct SettingsChoicePage: View {
    @Environment(\.dismiss) private var dismiss
    let place: SettingsPlace
    let title: String
    let description: String?
    let options: [SettingsOption]
    let selection: String
    var onFocusOption: ((String?) -> Void)? = nil
    let onPick: (String) -> Void
    @FocusState private var focused: String?

    var body: some View {
        SettingsPage(place: place, subtitle: description ?? "") {
            SettingsSection {
                ForEach(options) { option in
                    Button {
                        onPick(option.id)
                        dismiss()
                    } label: {
                        SettingsRowLabel(title: option.label, checked: option.id == selection,
                                         info: SettingsInfo(title: option.label,
                                                            description: option.description ?? description,
                                                            preview: option.preview))
                    }
                    .buttonStyle(SettingsRowStyle())
                    .focused($focused, equals: option.id)
                }
            }
        }
        // Opens on the option in use, not the first one.
        .defaultFocus($focused, selection)
        .onChange(of: focused) { _, id in if let id { onFocusOption?(id) } }
        .onDisappear { onFocusOption?(nil) }
    }
}

/// Opens a page.
struct SettingsLinkRow<Destination: View>: View {
    let title: String
    var description: String? = nil
    var value: String? = nil
    var preview: AnyView? = nil
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRowLabel(title: title, value: value, chevron: true,
                             info: SettingsInfo(title: title, description: description, preview: preview))
        }
        .buttonStyle(SettingsRowStyle())
    }
}

/// Runs an action.
struct SettingsButtonRow: View {
    let title: String
    var description: String? = nil
    var value: String? = nil
    /// The box's symbol while it's focused (else the page's)…
    var icon: String? = nil
    /// …or a preview in it.
    var preview: AnyView? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowLabel(title: title, value: value,
                             info: SettingsInfo(title: title, description: description,
                                                preview: preview, icon: icon))
        }
        .buttonStyle(SettingsRowStyle())
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

/// A page for managing a list: a centred column of compact, one-line rows —
/// the name left, small controls right (`SettingsEntryRow`); an optional
/// round button by the heading (adding).
struct SettingsManagePage<Content: View>: View {
    let title: String
    let subtitle: String
    var headerAction: SettingsEntryAction? = nil
    @ViewBuilder let content: Content

    static var width: CGFloat { 1100 }

    var body: some View {
        // The reader goes to the rows (`settingsScroll`): a row being MOVED
        // keeps focus, so the system never scrolls for it — the row scrolls
        // itself into view on every step.
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title.uppercased())
                            .font(.system(size: SectionHint.size, weight: SectionHint.weight))
                            .tracking(SectionHint.tracking)
                            .foregroundStyle(SettingsMetrics.secondaryText)
                        Text(subtitle)
                            .font(.system(size: 23))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    Spacer()
                    if let headerAction {
                        SettingsIconButton(icon: headerAction.icon, action: headerAction.action)
                    }
                }
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.bottom, 16)
                content
            }
            .frame(width: Self.width)
            .padding(.top, SettingsMetrics.top)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: [.top, .bottom])
        .background(ATVBackground())
        .environment(\.settingsScroll, proxy)
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
                    .foregroundStyle(Color.white.opacity(dimmed && !isMoving ? 0.45 : 1))
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
                                           : (destructive ? Self.red : Color.white))
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
