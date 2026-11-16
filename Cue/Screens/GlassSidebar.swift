import SwiftUI

/// The primary navigation destinations. The app keys tab state off these raw
/// ints in many places, so don't renumber them.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings, movies, series, discover, placeholder
    var id: Int { rawValue }

    /// The top navigation: Search first, left of Home. Movies and Series
    /// (Home filtered to one type) are off the bar, going away; Discover
    /// and the placeholder are empty pages for now. The library is a row
    /// on Home — its old tab stays reachable only from within the app.
    static let topBarOrder: [AppTab] = [.search, .home, .discover, .placeholder, .settings]

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
        case .discover: return "Discover"
        case .placeholder: return "Placeholder"
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
        case .discover: return "safari.fill"
        case .placeholder: return "square.dashed"
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
        return HStack(alignment: .center, spacing: Self.itemSpacing) {
            if Self.centred {
                // The avatar's room mirrored, so the tabs sit on the
                // screen's middle.
                Color.clear.frame(width: Self.topBarItemHeight, height: 1)
                Spacer(minLength: 0)
            }
            ForEach(tabs) { tab in
                Button {
                    onTabSelected(tab.rawValue)
                    selected = tab.rawValue
                } label: {
                    TopNavLabel(tab: tab, current: selected == tab.rawValue,
                                focused: navFocused && lit == tab.rawValue)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused(focusBinding, equals: tab.rawValue)
                // Coming in from the page only the current tab takes focus,
                // so the engine lands on it (it landed on the nearest tab
                // first, Home lit faintly before the snap).
                .disabled(!navFocused && tab.rawValue != selected)
            }
            Spacer(minLength: 0)
            // The profile, at the right edge: its name as a tab's, then the
            // avatar near the bar's full height with the cards' light rim,
            // `avatarInset` inside the capsule's round end (flush, focused
            // it had no white round it); its edge on the cards' right
            // edge. (A 42 pt avatar alone, 16 pt past the cards, read lost.)
            Button(action: onProfileTap) {
                HStack(spacing: Self.iconGap) {
                    Text(profiles.active.name)
                        .font(.system(size: Self.textSize, weight: .medium))
                        .lineLimit(1)
                    ProfileAvatarView(profile: profiles.active, size: Self.topBarItemHeight - 2 * Self.avatarInset)
                        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2) }
                        // Where the gate's picked avatar flies (`ProfileGate`).
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            TopBarAvatar.frame = $0
                        }
                }
                .padding(.leading, Self.slotPadding)
                .padding(.trailing, Self.avatarInset)
                .frame(height: Self.topBarItemHeight)
                .modifier(TopNavFocus(lit: navFocused && lit == -1,
                                      rest: CueInk.color(FixedFocusText.secondary)))
            }
            .buttonStyle(PlainCardButtonStyle())
            .focused(focusBinding, equals: -1)
            .disabled(!navFocused)
        }
        .defaultFocus(focusBinding, selected)
        // The first icon starts on the rows' text edge, as their names (on
        // the cards' edge it read 4 pt left of them; the first item's
        // padding is the capsule's room, so the edge is the slot's).
        .padding(.leading, Self.centred ? Spotlight.screenInset - Self.slotPadding
                                        : FixedFocusMetrics.titleInset - Self.slotPadding)
        .padding(.trailing, Spotlight.screenInset - Self.avatarInset)
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


    /// The tabs centred on the screen, the avatar at the right: tried,
    /// liked as much; left (the rows' text edge) for now.
    static let centred = false
    static let topBarTop: CGFloat = 44
    /// The items' height: the focus capsule's. (52 and 28 pt words were
    /// before, words alone, Search an icon.)
    static let topBarItemHeight: CGFloat = 46
    static let textSize: CGFloat = 25
    static let iconSize: CGFloat = 22
    /// The avatar inside its capsule's round end.
    static let avatarInset: CGFloat = 4
    /// Between an item's icon and its name.
    static let iconGap: CGFloat = 10
    /// A name's room each side inside its capsule (with `itemSpacing`, the
    /// words 40 pt apart; 42 read a little far).
    static let slotPadding: CGFloat = 15
    /// Between the items' capsules: room for one growing in beside one
    /// fading at its full size (6 pt touched once the fade stopped
    /// shrinking; with none, they touched; 12 pt was too far apart).
    static let itemSpacing: CGFloat = 10
}

/// The top bar's focus: the season buttons' (`ActionFace`): the white
/// capsule growing in on the focused item, only fading out of the one left
/// (shrinking as it faded, as the buttons', was before), the item 5 %
/// larger — nothing travels along the bar. At rest
/// the current tab keeps the season's flat grey pill (`FlatControl.selected`).
private struct TopNavFocus: ViewModifier {
    let lit: Bool
    let rest: Color
    var pill = false

    func body(content: Content) -> some View {
        content
            .modifier(ActionFace(lit: lit, rest: rest, pill: pill, current: true, restShadow: false,
                                 open: Self.open, leave: Self.leave, leaveFade: Self.leaveFade,
                                 shrinks: false))
            .scaleEffect(lit ? DetailActionButton.focusScale : 1)
            .animation(lit ? Self.open : Self.leave, value: lit)
    }

    /// Quicker than the buttons' (0.15 s in, 0.35 s out): focus runs along
    /// the bar, switching tabs as it goes.
    static let open: Animation = .spring(duration: 0.12, bounce: 0)
    static let leave: Animation = .spring(duration: 0.28, bounce: 0)
    static let leaveFade: Animation = .linear(duration: 0.28)
}

/// One tab in the top navigation: its icon and name, the current one at
/// the primary level, the others two levels down; focused, dark on the
/// white capsule (`TopNavFocus`).
private struct TopNavLabel: View {
    let tab: AppTab
    let current: Bool
    var focused = false

    var body: some View {
        HStack(spacing: GlassSidebar.iconGap) {
            Image(systemName: tab.icon)
                .font(.system(size: GlassSidebar.iconSize, weight: .semibold))
            Text(tab.label)
                .font(.system(size: GlassSidebar.textSize, weight: .medium))
        }
        .padding(.horizontal, GlassSidebar.slotPadding)
        .frame(height: GlassSidebar.topBarItemHeight)
        .modifier(TopNavFocus(lit: focused,
                              rest: CueInk.color(current ? FixedFocusText.primary : FixedFocusText.secondary),
                              pill: current))
        .animation(.easeOut(duration: 0.18), value: current)
    }
}

/// A tab with nothing on it yet (Discover, the placeholder): its name and
/// one empty card, so Down from the bar has somewhere to land (with
/// nothing focusable, focus went nowhere). Back: the bar.
struct EmptyTabPage: View {
    let title: String
    let onBack: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(CueInk.primary)
            Button {} label: {
                RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
                    .fill(focused ? FlatControl.focus : FlatControl.rest)
                    .frame(width: 557, height: 313)
                    .overlay {
                        Text("Nothing here yet")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(focused ? FlatControl.contentOnFocus : FlatControl.content)
                    }
                    .scaleEffect(focused ? 1 + FixedFocusMetrics.focusLift(CGSize(width: 557, height: 313)) : 1)
                    .animation(Motion.focus, value: focused)
            }
            .buttonStyle(PlainCardButtonStyle())
            .focused($focused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, FixedFocusMetrics.titleInset)
        .padding(.top, 40)
        // The whole page one section: Down from any tab lands on the card.
        .focusSection()
        .background { ATVBackground() }
        .onExitCommand(perform: onBack)
    }
}
