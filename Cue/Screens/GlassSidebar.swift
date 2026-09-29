import SwiftUI

/// The primary navigation destinations. The app keys tab state off these raw
/// ints in many places, so don't renumber them.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings
    var id: Int { rawValue }

    /// The top navigation: the search icon first, left of Home.
    static let topBarOrder: [AppTab] = [.search, .home, .library, .settings]

    var label: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "bookmark.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The top navigation: `🔍 Home Library Settings (avatar)`, centred as one
/// group (see docs/UI-DESIGN.md §3).
struct GlassSidebar: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @Binding var selected: Int
    var focusBinding: FocusState<Int?>.Binding
    var onProfileTap: () -> Void = {}
    /// Fires when a tab is tapped, BEFORE `selected` is mutated, so the root
    /// can tell whether this is actually a change of tab (vs. re-tapping the
    /// tab you're already on) and react accordingly.
    var onTabSelected: (Int) -> Void = { _ in }
    /// The billboard ⇄ Details swap: the items move away (`ModeSwap`). On
    /// the items themselves — an offset on the whole full-screen bar view
    /// never showed.
    var swapAway = false

    var expanded: Bool { focusBinding.wrappedValue != nil }

    /// Clearance a tab gives the TOP bar, applied as SAFE-AREA padding rather
    /// than plain padding.
    ///
    /// That distinction is the whole behaviour: plain padding shrinks the
    /// page's frame, so a scroll view's viewport starts below the bar and its
    /// content is CLIPPED at that line — a black band under the bar with rows
    /// disappearing into it. As safe-area padding the page still fills the
    /// screen and draws under the glass; only its content's resting inset
    /// moves, so rows slide up under the bar the way they should.
    ///
    /// Sized to sit just under the bar (28pt offset + ~100pt of bar) minus the
    /// top title-safe inset the system already gives, then trimmed so headings
    /// sit CLOSE to the bar rather than marooned below it.
    static let topBarClearance: CGFloat = 52

    /// The top navigation: one floating Liquid Glass pill with the tabs and
    /// the profile, centred; a white capsule glides to the focused tab (dark
    /// text), a faint one marks the current tab otherwise.
    ///
    /// Moving focus along it SWITCHES tab right away (no Select needed), so
    /// the page underneath follows as you browse the tabs. Select on a tab
    /// (or Down) goes into its content.
    var body: some View {
        let tabs = AppTab.topBarOrder
        let navFocused = focusBinding.wrappedValue != nil
        // The highlighted item: the focused one (a tab or the profile, -1)
        // while the navigation has focus, else the current tab.
        let lit = focusBinding.wrappedValue ?? selected
        return HStack(alignment: .center, spacing: 20) {
            // Tabs and profile in ONE floating Liquid Glass pill (tvOS 26).
            HStack(alignment: .center, spacing: 0) {
                ForEach(tabs) { tab in
                    Button {
                        onTabSelected(tab.rawValue)
                        selected = tab.rawValue
                    } label: {
                        TopNavLabel(tab: tab, lit: lit == tab.rawValue,
                                    focusPlatter: navFocused && lit == tab.rawValue)
                            .matchedGeometryEffect(id: tab.rawValue, in: navHighlight, isSource: true)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused(focusBinding, equals: tab.rawValue)
                }
                // The profile, last in the pill — a square slot, so the
                // highlight is a circle on it (as on the search icon).
                Button(action: onProfileTap) {
                    // As large as on the tvOS home screen: nearly the pill's height.
                    ProfileAvatarView(profile: profiles.active, size: Self.topBarItemHeight - 4)
                        .frame(width: Self.topBarItemHeight, height: Self.topBarItemHeight)
                        .matchedGeometryEffect(id: -1, in: navHighlight, isSource: true)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused(focusBinding, equals: -1)
            }
            // The highlight inside the pill, gliding from tab to tab: a
            // bright white capsule on the FOCUSED tab (dark text — the tvOS
            // focus look), a subtle light one on the current tab otherwise.
            // (A capsule: on the square slots — search, profile — a circle;
            // it morphs between the two as it glides.)
            .background {
                GlassHighlight(focused: navFocused, shape: Capsule())
                    .matchedGeometryEffect(id: lit, in: navHighlight, isSource: false)
                    .animation(.smooth(duration: 0.3), value: lit)
                    .animation(.easeOut(duration: 0.2), value: navFocused)
            }
            .padding(Self.pillInset)
            // The app's glass surface (see `AppGlass`).
            .background { Color.clear.liquidGlass(in: Capsule()) }
            .defaultFocus(focusBinding, selected)
            // Focused, the pill grows a little (like the system tab bar).
            .scaleEffect(navFocused ? Self.focusedScale : 1, anchor: .top)
            .animation(.smooth(duration: 0.3), value: navFocused)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(y: swapAway ? -ModeSwap.chromeTravel : 0)
        .animation(swapAway ? ModeSwap.out : ModeSwap.in, value: swapAway)
        .padding(.top, Self.topBarTop)
        .frame(maxWidth: .infinity, alignment: .top)
        // Placed against the real screen edges (the inset above is ours).
        .ignoresSafeArea()
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded && focusBinding.wrappedValue != selected {
                focusBinding.wrappedValue = selected
            }
        }
        // Focus follows → tab follows. Only the selection changes: focus
        // stays in the navigation (unlike Select, which hands it to the
        // page).
        //
        // Only for moves WITHIN the navigation (old value non-nil). Entering
        // it from the page, the engine first lands on the geometrically
        // nearest tab (often Search, in the middle) before the snap to the
        // current tab above — following that first landing flashed the
        // other tab's screen for a frame.
        .onChange(of: focusBinding.wrappedValue) { old, focused in
            guard old != nil, let focused, focused >= 0, focused != selected else { return }
            selected = focused
        }
    }

    /// The tab pill: how much it grows while the navigation has focus, and
    /// the room between its edge and the tabs' highlight.
    static let focusedScale: CGFloat = 1.06
    static let pillInset: CGFloat = 8
    /// The highlight gliding between the tabs.
    @Namespace private var navHighlight

    /// Top navigation geometry (absolute, from the screen edges). The
    /// avatar's right edge mirrors Home's left content margin.
    static let topBarInset: CGFloat = 84
    static let topBarTop: CGFloat = 40
    /// Height of the top navigation's items.
    static let topBarItemHeight: CGFloat = 60
}

/// One tab in the top navigation: its name, grey — white when it's the
/// current or focused tab. Nothing else.
private struct TopNavLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    let tab: AppTab
    /// Highlighted (the current tab, or the focused one): white text.
    let lit: Bool
    /// On the white focus capsule: dark text.
    var focusPlatter = false

    var body: some View {
        Group {
            // Search is an icon; the others are their names.
            if tab == .search {
                // A square slot, so the highlight is a circle here.
                Image(systemName: tab.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: GlassSidebar.topBarItemHeight)
            } else {
                Text(tab.label)
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.horizontal, 26)
            }
        }
        .foregroundStyle(focusPlatter ? AppGlass.textOnFocus
                         : lit ? AppGlass.text : AppGlass.textMuted)
        .frame(height: GlassSidebar.topBarItemHeight)
        .animation(.easeOut(duration: 0.18), value: lit)
        .animation(.easeOut(duration: 0.18), value: focusPlatter)
    }
}
