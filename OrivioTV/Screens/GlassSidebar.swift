import SwiftUI

/// The primary sidebar destinations. The app keys tab state off these raw
/// ints in many places, so don't renumber them.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings
    var id: Int { rawValue }

    /// Order the navigation renders in.
    static let sidebarOrder: [AppTab] = [.home, .library, .search, .settings]
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

/// The always-visible left navigation rail, drawn as Liquid Glass (tvOS 26;
/// translucent material before that). Collapsed it is a floating glass pill of
/// icons, vertically centered at the left edge. When focus enters it expands
/// rightward into a wider glass panel with the profile chip on top and
/// labeled rows; the parent dims the content behind it.
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
    /// Which edge the rail lives on. The ONLY thing that differs between the
    /// two layouts: same items, same icons and labels, same focus bindings,
    /// same glass — laid out along the other axis.
    var position: NavigationPosition = .left
    /// The billboard ⇄ Details swap: the items move away (`ModeSwap`). On
    /// the items themselves — an offset on the whole full-screen bar view
    /// never showed.
    var swapAway = false

    var expanded: Bool { focusBinding.wrappedValue != nil }
    private var horizontal: Bool { position.isHorizontal }

    /// Space (inside the safe area) the content reserves so it clears the
    /// floating collapsed pill, which hugs the screen edge at absolute
    /// 28..112pt — the safe inset (~90) covers most of it.
    static let collapsedWidth: CGFloat = 60
    static let expandedWidth: CGFloat = 240
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

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? 34 : 42, style: .continuous)
    }

    var body: some View {
        // Two orientations of ONE layout. The horizontal bar keeps the profile
        // chip ahead of the items on the same line, exactly as the vertical
        // panel keeps it above them.
        Group {
            if horizontal { horizontalBody } else { verticalBody }
        }
    }

    /// The top navigation: no bar, no pill — just the tab names, sitting
    /// straight on the screen, centred. The profile picture sits at the
    /// top-right, on the content margin. Grey text, white for the current /
    /// focused tab — no highlight shapes.
    ///
    /// Moving focus along it SWITCHES tab right away (no Select needed), so
    /// the page underneath follows as you browse the tabs. Select on a tab
    /// (or Down) goes into its content.
    private var horizontalBody: some View {
        let tabs = AppTab.topBarOrder
        let navFocused = focusBinding.wrappedValue != nil
        // The highlighted item: the focused one (a tab or the profile, -1)
        // while the navigation has focus, else the current tab.
        let lit = focusBinding.wrappedValue ?? selected
        let flat = Self.topBarStyle == .flat
        return HStack(alignment: .center, spacing: 20) {
            // Tabs and profile in ONE floating Liquid Glass pill (tvOS 26) —
            // or, flat, straight on the screen.
            HStack(alignment: .center, spacing: flat ? Self.flatSpacing : 0) {
                ForEach(tabs) { tab in
                    Button {
                        onTabSelected(tab.rawValue)
                        selected = tab.rawValue
                    } label: {
                        TopNavLabel(tab: tab, lit: lit == tab.rawValue,
                                    focusPlatter: !flat && navFocused && lit == tab.rawValue,
                                    flatFocused: flat && navFocused && lit == tab.rawValue)
                            .matchedGeometryEffect(id: tab.rawValue, in: navHighlight, isSource: true)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused(focusBinding, equals: tab.rawValue)
                }
                // The profile, last in the pill — a square slot, so the
                // highlight is a circle on it (as on the search icon).
                Button(action: onProfileTap) {
                    ProfileAvatarView(profile: profiles.active, size: flat ? Self.flatAvatarSize : 44)
                        // Flat: a thin white ring and a small lift on focus.
                        .overlay {
                            if flat {
                                Circle().strokeBorder(Color.white, lineWidth: 3)
                                    .padding(-5)
                                    .opacity(navFocused && lit == -1 ? 1 : 0)
                            }
                        }
                        .scaleEffect(flat && navFocused && lit == -1 ? Self.flatFocusScale : 1)
                        .animation(.easeOut(duration: 0.18), value: navFocused && lit == -1)
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
                if !flat {
                    GlassHighlight(focused: navFocused, shape: Capsule())
                        .matchedGeometryEffect(id: lit, in: navHighlight, isSource: false)
                        .animation(.smooth(duration: 0.3), value: lit)
                        .animation(.easeOut(duration: 0.2), value: navFocused)
                }
            }
            .padding(Self.pillInset)
            // The app's glass surface (see `AppGlass`) — the pill style only.
            .background {
                if !flat { Color.clear.liquidGlass(in: Capsule()) }
            }
            .defaultFocus(focusBinding, selected)
            // Focused, the pill grows a little (like the system tab bar).
            .scaleEffect(!flat && navFocused ? Self.focusedScale : 1, anchor: .top)
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

    /// The top bar's look. `.glass`: one Liquid Glass pill with a gliding
    /// highlight. `.flat`: no pill, no highlight shape — the names straight
    /// on the screen (grey; white for the current tab; the focused one also
    /// grows a little), the avatar with a thin white ring on focus. Both
    /// kept for comparison.
    enum TopBarStyle { case glass, flat }
    static let topBarStyle: TopBarStyle = .flat
    /// Flat: the room between the items (their own padding does the rest),
    /// and how much the focused one grows.
    static let flatSpacing: CGFloat = 0
    /// Flat: each name's own side padding (the pill style uses 26).
    static let flatItemPadding: CGFloat = 16
    /// Flat: the names' size — the hints' capitals (18pt), a little larger
    /// for reading from the couch.
    static let flatTextSize: CGFloat = 21
    /// Flat: the avatar, smaller to sit with the capitals.
    static let flatAvatarSize: CGFloat = 36
    static let flatFocusScale: CGFloat = 1.12

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

    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded { Spacer(minLength: 0) }

            // Profile chip — expanded panel only, sitting DIRECTLY above the
            // nav items (one centered group, not pinned to the panel top).
            if expanded {
                Button(action: onProfileTap) {
                    GlassProfileHeader(profile: profiles.active)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused(focusBinding, equals: -1)
                .transition(.opacity)
                .padding(.horizontal, OrivioSpacing.sm)
                .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: expanded ? 10 : 24) {
                ForEach(AppTab.sidebarOrder) { tab in
                    Button {
                        // Fire BEFORE mutating `selected` so the root can still
                        // see which tab we're coming FROM.
                        onTabSelected(tab.rawValue)
                        selected = tab.rawValue
                        // NOTE: do NOT clear focusBinding here — unfocusing
                        // with no destination makes the engine grab the nearest
                        // candidate. The root force-moves focus into content.
                    } label: {
                        GlassItemLabel(tab: tab, selected: selected == tab.rawValue,
                                       expanded: expanded, horizontal: false)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused(focusBinding, equals: tab.rawValue)
                }
            }
            .padding(.horizontal, expanded ? OrivioSpacing.sm : 12)
            // Entering the sidebar lands on the tab you're on, not a stale row.
            .defaultFocus(focusBinding, selected)
            .padding(.vertical, expanded ? 0 : 20)

            if expanded { Spacer(minLength: 0) }
        }
        .offset(x: swapAway ? -ModeSwap.chromeTravel : 0)
        .animation(swapAway ? ModeSwap.out : ModeSwap.in, value: swapAway)
        .frame(width: expanded ? Self.expandedWidth : 84, alignment: .leading)
        // Clip to the ANIMATING width so labels are revealed by the expanding
        // edge instead of rendering at their final position over the content.
        .clipped()
        // The pill hugs its icons vertically; the expanded panel stretches.
        .frame(maxHeight: expanded ? .infinity : nil)
        // Background-style glass: glassEffect WRAPPING focusable content hides
        // it from the focus engine (see liquidGlassIf).
        .background(Color.clear.liquidGlass(in: panelShape))
        .padding(.vertical, expanded ? OrivioSpacing.xl : 0)
        .padding(.leading, 28)
        .frame(maxHeight: .infinity, alignment: .center)
        // Hug the screen edge: the rail sits INSIDE the TV safe inset, not
        // pushed to the content's title-safe column.
        .ignoresSafeArea(edges: .horizontal)
        .animation(PerformanceSettingsStore.shared.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: expanded)
        // On ENTRY (collapsed → expanded), snap focus to the current tab —
        // tvOS otherwise lands on the geometrically nearest row.
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded && focusBinding.wrappedValue != selected {
                focusBinding.wrappedValue = selected
            }
        }
    }
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
    /// The flat style's focus: white, a little larger.
    var flatFocused = false

    private var flat: Bool { GlassSidebar.topBarStyle == .flat }

    var body: some View {
        Group {
            // Search is an icon; the others are their names.
            if tab == .search {
                // A square slot, so the highlight is a circle here.
                Image(systemName: tab.icon)
                    .font(.system(size: flat ? GlassSidebar.flatTextSize + 2 : 26, weight: .semibold))
                    .frame(width: GlassSidebar.topBarItemHeight)
            } else if flat {
                // The section hints' typography ("▾ EPISODES"): small spaced
                // capitals — one quiet navigation language, top and bottom.
                Text(tab.label.uppercased())
                    .font(.system(size: GlassSidebar.flatTextSize, weight: .semibold))
                    .tracking(SectionHint.tracking)
                    .padding(.horizontal, GlassSidebar.flatItemPadding)
            } else {
                Text(tab.label)
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.horizontal, 26)
            }
        }
        .foregroundStyle(focusPlatter ? AppGlass.textOnFocus
                         : lit ? AppGlass.text
                         : flat ? Color.white.opacity(SectionHint.opacity) : AppGlass.textMuted)
        // Flat: straight on the artwork — the hints' soft shadow.
        .shadow(color: flat ? .black.opacity(0.4) : .clear, radius: 6, y: 2)
        .scaleEffect(flatFocused ? GlassSidebar.flatFocusScale : 1)
        .frame(height: GlassSidebar.topBarItemHeight)
        .animation(.easeOut(duration: 0.18), value: lit)
        .animation(.easeOut(duration: 0.18), value: focusPlatter)
        .animation(.easeOut(duration: 0.18), value: flatFocused)
    }
}

/// The tappable profile chip at the top of the expanded panel.
private struct GlassProfileHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let profile: UserProfile
    /// The top bar's chip hugs its content instead of filling a panel width.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: OrivioSpacing.sm) {
            ProfileAvatarView(profile: profile, size: compact ? 44 : 52)
            Text(profile.name)
                .font(.system(size: compact ? 22 : 26, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            if !compact { Spacer(minLength: 0) }
        }
        .padding(.horizontal, OrivioSpacing.sm)
        .frame(height: compact ? 56 : 64)
        .background(
            Capsule(style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.18) : .clear)
        )
    }
}

/// A single rail entry: icon (+ label when expanded). Focused/selected shows a
/// soft translucent capsule fill — no border, no scale; the glass carries it.
private struct GlassItemLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let tab: AppTab
    let selected: Bool
    let expanded: Bool
    /// Laid out in the top bar: the tile hugs its content rather than
    /// stretching to a panel's width, and there is no trailing `Spacer`.
    var horizontal: Bool = false

    private var highlighted: Bool { isFocused || selected }

    var body: some View {
        HStack(spacing: OrivioSpacing.sm) {
            Image(systemName: tab.icon)
                .font(.system(size: expanded ? 30 : 36, weight: .semibold))
                .foregroundStyle(highlighted ? theme.palette.textPrimary : theme.palette.textSecondary)
                .frame(width: expanded ? 44 : 60, height: expanded ? nil : 60, alignment: .center)

            if expanded {
                Text(tab.label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(highlighted ? theme.palette.textPrimary : theme.palette.textSecondary)
                    .lineLimit(1)
                    .transition(.opacity)
                if !horizontal { Spacer(minLength: 0) }
            }
        }
        .padding(.leading, expanded ? OrivioSpacing.md : 0)
        .padding(.trailing, expanded ? OrivioSpacing.md : 0)
        .frame(height: expanded ? 76 : 60)
        .frame(maxWidth: (expanded && !horizontal) ? .infinity : nil, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(highlighted ? Color.white.opacity(isFocused ? 0.22 : 0.10) : .clear)
        )
    }
}
