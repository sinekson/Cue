import SwiftUI

/// The primary navigation destinations. The app keys tab state off these raw
/// ints in many places, so don't renumber them.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings, movies, series
    var id: Int { rawValue }

    /// The top navigation: the search icon first, left of Home. Movies and
    /// Series are Home filtered to one type; the library is a row on Home
    /// ("My List") — its old tab stays reachable only from within the app.
    static let topBarOrder: [AppTab] = [.search, .home, .movies, .series, .settings]

    /// Home and its filtered twins: the same page (see `HomeView.typeFilter`).
    var isHomeLike: Bool { self == .home || self == .movies || self == .series }

    /// Movies / Series: the content type the tab shows (nil: everything).
    var typeFilter: String? {
        switch self {
        case .movies: return "movie"
        case .series: return "series"
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .settings: return "Settings"
        case .movies: return "Movies"
        case .series: return "Series"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "bookmark.fill"
        case .settings: return "gearshape.fill"
        case .movies: return "film.fill"
        case .series: return "tv.fill"
        }
    }
}

/// The top bar's avatar on the screen (moved out with the bar, too) — the
/// gate's picked avatar lands on it.
@MainActor
enum TopBarAvatar {
    static var frame: CGRect?
}

/// Where the page in front has put the top bar: Home's (and Movies',
/// Series') below the billboard — the bar has gone up with it. Set by the
/// page (`HomeUIKitView`); other tabs are always at their top.
@MainActor
final class TopBarPlace: ObservableObject {
    static let shared = TopBarPlace()
    @Published var pageDown = false
}

/// The top navigation: part of the page, not floating over it — the tabs
/// as words at the page's left edge, the profile at its right, on the
/// background with nothing behind them. The current tab's name brighter;
/// focused, the one white capsule (dark text) gliding from tab to tab.
/// Pages are laid out below it (`topBarClearance`); on Home it is on the
/// billboard's picture and goes up with it (`lifted`).
struct GlassSidebar: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Binding var selected: Int
    var focusBinding: FocusState<Int?>.Binding
    var onProfileTap: () -> Void = {}
    /// Fires when a tab is tapped, BEFORE `selected` is mutated, so the root
    /// can tell whether this is actually a change of tab (vs. re-tapping the
    /// tab you're already on) and react accordingly.
    var onTabSelected: (Int) -> Void = { _ in }
    /// Hidden: the bar moves out the top (shown: back in) — with the page's
    /// parts (off a tab's root, into Details in place, a trailer). On the
    /// items themselves — an offset on the whole full-screen bar view never
    /// showed.
    var hidden = false
    /// Home's page below its billboard: up with the billboard, as far and
    /// on the same move, so it reads as the page's own top.
    var lifted = false

    var expanded: Bool { focusBinding.wrappedValue != nil }

    /// Clearance a tab gives the TOP bar, applied as SAFE-AREA padding rather
    /// than plain padding (plain padding clipped a scrolled page at a line
    /// under the bar). Sized to sit just under the bar minus the top
    /// title-safe inset the system already gives.
    static let topBarClearance: CGFloat = 52

    /// Moving focus along it SWITCHES tab right away (no Select needed), so
    /// the page underneath follows as you browse the tabs. Select on a tab
    /// (or Down) goes into its content.
    var body: some View {
        let tabs = AppTab.topBarOrder
        let navFocused = focusBinding.wrappedValue != nil
        // The highlighted item: the focused one (a tab or the profile, -1)
        // while the navigation has focus, else the current tab.
        let lit = focusBinding.wrappedValue ?? selected
        return HStack(alignment: .center, spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    onTabSelected(tab.rawValue)
                    selected = tab.rawValue
                } label: {
                    TopNavLabel(tab: tab, current: selected == tab.rawValue,
                                focusPlatter: navFocused && lit == tab.rawValue)
                        .glassPillItem(tab.rawValue, in: navHighlight)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused(focusBinding, equals: tab.rawValue)
            }
            Spacer(minLength: 0)
            // The profile, at the right edge — a square slot, so the
            // highlight is a circle on it (as on the search icon).
            Button(action: onProfileTap) {
                ProfileAvatarView(profile: profiles.active, size: Self.topBarItemHeight - 4)
                    // Where the gate's picked avatar flies (`ProfileGate`).
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        TopBarAvatar.frame = $0
                    }
                    .frame(width: Self.topBarItemHeight, height: Self.topBarItemHeight)
                    .glassPillItem(-1, in: navHighlight)
            }
            .buttonStyle(PlainCardButtonStyle())
            .focused(focusBinding, equals: -1)
        }
        // Focused: the white capsule on the focused item, gliding; at rest
        // nothing behind the words (the current one is brighter).
        .background {
            Capsule()
                .fill(AppGlass.focusTint)
                .matchedGeometryEffect(id: lit, in: navHighlight, isSource: false)
                .opacity(navFocused ? 1 : 0)
                .animation(GlassPill.glide, value: lit)
                .animation(GlassPill.focusChange, value: navFocused)
        }
        .defaultFocus(focusBinding, selected)
        // The words start on the page's left edge (the first item's padding
        // is the capsule's room, so the edge is the slot's).
        .padding(.horizontal, Spotlight.screenInset - Self.slotPadding)
        .frame(maxWidth: .infinity)
        .offset(y: hidden ? -Self.hideTravel : lifted ? -HomeUIKitView.rigidBillboardTravel : 0)
        .animation(Motion.move, value: hidden)
        .animation(Motion.move, value: lifted)
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

    /// Hiding: up past the screen's top edge.
    static var hideTravel: CGFloat { topBarTop + topBarItemHeight + 30 }

    /// The highlight gliding between the tabs.
    @Namespace private var navHighlight

    static let topBarTop: CGFloat = 44
    /// The items' height: the focus capsule's.
    static let topBarItemHeight: CGFloat = 52
    static let textSize: CGFloat = 28
    /// A name's room each side inside its capsule.
    static let slotPadding: CGFloat = 22
}

/// One tab in the top navigation: its name (Search: its icon), the current
/// one at the primary level, the others two levels down; on the focus
/// capsule, dark.
private struct TopNavLabel: View {
    let tab: AppTab
    let current: Bool
    /// On the white focus capsule: dark text.
    var focusPlatter = false

    var body: some View {
        Group {
            if tab == .search {
                // A square slot, so the highlight is a circle here.
                Image(systemName: tab.icon)
                    .font(.system(size: GlassSidebar.textSize - 2, weight: .semibold))
                    .frame(width: GlassSidebar.topBarItemHeight)
            } else {
                Text(tab.label)
                    .font(.system(size: GlassSidebar.textSize, weight: .medium))
                    .padding(.horizontal, GlassSidebar.slotPadding)
            }
        }
        .foregroundStyle(focusPlatter ? AppGlass.textOnFocus
                         : .white.opacity(current ? FixedFocusText.primary : FixedFocusText.secondary))
        .frame(height: GlassSidebar.topBarItemHeight)
        .animation(.easeOut(duration: 0.18), value: current)
        .animation(.easeOut(duration: 0.18), value: focusPlatter)
    }
}
