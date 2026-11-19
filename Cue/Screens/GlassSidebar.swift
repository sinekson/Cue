import SwiftUI

/// The primary navigation destinations. The app keys tab state off these raw
/// ints in many places, so don't renumber them.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings
    // (4 and 5 were Movies and Series.)
    case discover = 6, placeholder
    var id: Int { rawValue }

    /// The top navigation: Search first, left of Home; the placeholder an
    /// empty page for now. The library is a row
    /// on Home — its old tab stays reachable only from within the app.
    static let topBarOrder: [AppTab] = [.search, .home, .discover, .placeholder, .settings]


    var label: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .settings: return "Settings"
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
        case .discover: return "safari.fill"
        case .placeholder: return "square.dashed"
        }
    }
}

/// The top bar's avatar on the screen (moved out with the bar, too) — the
/// gate's picked avatar lands on it.
@MainActor
enum TopBarAvatar {
    /// At the bar's spot (the focus layer's); `frame` where it's drawn.
    static var base: CGRect?
    static var frame: CGRect? { base?.offsetBy(dx: 0, dy: TopBarFollow.shared.offset) }
}

/// Home's top bar's place: the UIKit view the bar is drawn in
/// (`TopBarFace`), moved by the rows (`FixedFocusRowsController`'s
/// `applyPinnedStage`) inside the same animation as the billboard card,
/// so it moves as printed on the page with it. (Set frame by frame from
/// SwiftUI, it fell behind whenever the main thread skipped frames, as a
/// move begins; its own SwiftUI spring started a frame late.)
@MainActor
final class TopBarFollow {
    static let shared = TopBarFollow()
    weak var view: UIView? { didSet { apply() } }
    /// The page it goes with ("home": Home and Movies / Series, on the
    /// card; "discover": scrolled away with its page); nil: at its spot.
    var page: String? {
        didSet { if page != oldValue { UIView.performWithoutAnimation(apply) } }
    }
    /// Each page's own place for it (a tab switch shows the new page's).
    private var ys: [String: CGFloat] = [:]
    /// In the caller's animation, if any.
    func set(_ value: CGFloat, for page: String = "home") {
        ys[page] = value
        if page == self.page { apply() }
    }
    /// Where it's drawn, from its spot.
    var offset: CGFloat { page.flatMap { ys[$0] } ?? 0 }
    private func apply() {
        view?.transform = CGAffineTransform(translationX: 0, y: offset)
    }
}

/// The top navigation: part of the page, not floating over it — the tabs
/// as words at the page's left edge, the profile at its right, on the
/// background with nothing behind them. The current tab's name brighter;
/// focused, the white capsule on the item. Pages are laid out below it
/// (`topBarClearance`); on Home it is on the billboard's picture and goes
/// up with it (`TopBarFollow`).
///
/// Two layers at the same spots: this one holds focus (SwiftUI's focus
/// state runs Back, tab switching and the hand-offs to the pages; SwiftUI's
/// host refuses UIKit's focus requests) and draws nothing; `TopBarFace`
/// draws the bar in a UIKit view the rows can move.
struct GlassSidebar: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Binding var selected: Int
    var focusBinding: FocusState<Int?>.Binding
    var onProfileTap: () -> Void = {}
    /// Fires when a tab is tapped, BEFORE `selected` is mutated, so the root
    /// can tell whether this is actually a change of tab (vs. re-tapping the
    /// tab you're already on) and react accordingly.
    var onTabSelected: (Int) -> Void = { _ in }
    /// Hidden: off a tab's root — out of the way at once, in place again at
    /// once (the page's change covers it: moving back in, a second bar slid
    /// over the one in the page's still on Back).
    var hidden = false
    /// The item held down (Select), for the face's press dip.
    var onPress: (Int?) -> Void = { _ in }

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
        let navFocused = focusBinding.wrappedValue != nil
        return Self.layout(hidden: hidden) {
            ForEach(AppTab.topBarOrder) { tab in
                Button {
                    onTabSelected(tab.rawValue)
                    selected = tab.rawValue
                } label: {
                    TopNavLabel(tab: tab, current: false, ghost: true)
                }
                .buttonStyle(PlainCardButtonStyle { onPress($0 ? tab.rawValue : nil) })
                .focused(focusBinding, equals: tab.rawValue)
                // Coming in from the page only the current tab takes focus,
                // so the engine lands on it (it landed on the nearest tab
                // first, Home lit faintly before the snap).
                .disabled(!navFocused && tab.rawValue != selected)
            }
        } profile: {
            Button(action: onProfileTap) {
                ProfileItem(profile: profiles.active, ghost: true)
                    // Where the gate's picked avatar flies (`ProfileGate`).
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        let side = Self.topBarItemHeight - 2 * Self.avatarInset
                        TopBarAvatar.base = CGRect(x: $0.maxX - Self.avatarInset - side,
                                                    y: $0.minY + Self.avatarInset, width: side, height: side)
                    }
            }
            .buttonStyle(PlainCardButtonStyle { onPress($0 ? -1 : nil) })
            .focused(focusBinding, equals: -1)
            .disabled(!navFocused)
        }
        .defaultFocus(focusBinding, selected)
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

    /// The bar's items placed on the screen — the same for the focus layer
    /// and the face, so they sit on each other.
    static func layout<Tabs: View, Profile: View>(hidden: Bool,
                                                  @ViewBuilder tabs: () -> Tabs,
                                                  @ViewBuilder profile: () -> Profile) -> some View {
        HStack(alignment: .center, spacing: itemSpacing) {
            if centred {
                // The avatar's room mirrored, so the tabs sit on the
                // screen's middle.
                Color.clear.frame(width: topBarItemHeight, height: 1)
                Spacer(minLength: 0)
            }
            tabs()
            Spacer(minLength: 0)
            profile()
        }
        // The first icon starts on the rows' text edge, as their names (on
        // the cards' edge it read 4 pt left of them; the first item's
        // padding is the capsule's room, so the edge is the slot's).
        .padding(.leading, centred ? Spotlight.screenInset - slotPadding
                                   : FixedFocusMetrics.titleInset - slotPadding)
        .padding(.trailing, Spotlight.screenInset - avatarInset)
        .frame(maxWidth: .infinity)
        .offset(y: hidden ? -hideTravel : 0)
        .padding(.top, topBarTop)
        .frame(maxWidth: .infinity, alignment: .top)
        // Placed against the real screen edges (the inset above is ours).
        .ignoresSafeArea()
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
struct TopNavFocus: ViewModifier {
    let lit: Bool
    let rest: Color
    var pill = false

    func body(content: Content) -> some View {
        content
            .modifier(ActionFace(lit: lit, rest: rest, pill: pill, current: true, restShadow: false,
                                 open: Self.open, leave: Self.leave, leaveFade: Self.leaveFade))
            .scaleEffect(lit ? DetailActionButton.focusScale : 1)
            .animation(lit ? Self.open : Self.leave, value: lit)
    }

    /// Quicker than the buttons' (0.15 s in, 0.35 s out): focus runs along
    /// the bar, switching tabs as it goes.
    static let open: Animation = .spring(duration: 0.12, bounce: 0)
    static let leaveTime = 0.28
    static let leave: Animation = .spring(duration: leaveTime, bounce: 0)
    static let leaveFade: Animation = .linear(duration: leaveTime)
}

/// One tab in the top navigation: its icon and name, the current one at
/// the primary level, the others two levels down; focused, dark on the
/// white capsule (`TopNavFocus`).
private struct TopNavLabel: View {
    let tab: AppTab
    let current: Bool
    var focused = false
    /// The focus layer's: laid out, nothing drawn.
    var ghost = false

    var body: some View {
        let label = HStack(spacing: GlassSidebar.iconGap) {
            Image(systemName: tab.icon)
                .font(.system(size: GlassSidebar.iconSize, weight: .semibold))
            Text(tab.label)
                .font(.system(size: GlassSidebar.textSize, weight: .medium))
        }
        .padding(.horizontal, GlassSidebar.slotPadding)
        .frame(height: GlassSidebar.topBarItemHeight)
        if ghost {
            label.foregroundStyle(.clear).contentShape(Capsule())
        } else {
            label
                .modifier(TopNavFocus(lit: focused,
                                      rest: CueInk.color(current ? FixedFocusText.primary : FixedFocusText.secondary),
                                      pill: current))
                .animation(.easeOut(duration: 0.18), value: current)
        }
    }
}

/// The profile at the bar's right edge: its name as a tab's, then the
/// avatar near the bar's full height with the cards' light rim,
/// `avatarInset` inside the capsule's round end (flush, focused it had no
/// white round it); its edge on the cards' right edge. (A 42 pt avatar
/// alone, 16 pt past the cards, read lost.)
private struct ProfileItem: View {
    let profile: UserProfile
    var lit = false
    var ghost = false

    var body: some View {
        let item = HStack(spacing: GlassSidebar.iconGap) {
            Text(profile.name)
                .font(.system(size: GlassSidebar.textSize, weight: .medium))
                .lineLimit(1)
            ProfileAvatarView(profile: profile,
                              size: GlassSidebar.topBarItemHeight - 2 * GlassSidebar.avatarInset)
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2) }
                .opacity(ghost ? 0 : 1)
        }
        .padding(.leading, GlassSidebar.slotPadding)
        .padding(.trailing, GlassSidebar.avatarInset)
        .frame(height: GlassSidebar.topBarItemHeight)
        if ghost {
            item.foregroundStyle(.clear).contentShape(Capsule())
        } else {
            item.modifier(TopNavFocus(lit: lit, rest: CueInk.color(FixedFocusText.secondary)))
        }
    }
}

/// The top bar as seen: drawn in a UIKit view (`TopBarFollow.view`) the
/// rows move with the billboard card in their own animation; no focus of
/// its own (`GlassSidebar` holds it, at the same spots).
struct TopBarFace: UIViewRepresentable {
    let profiles: ProfileStore
    let selected: Int
    /// The focused item (a tab, or the profile, -1); nil: the page has focus.
    let focused: Int?
    let pressed: Int?
    let hidden: Bool
    /// The page it goes with (`TopBarFollow.page`).
    let follows: String?

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        // Moved inside the view SwiftUI places (it sets that one's geometry).
        let moved = UIView(frame: container.bounds)
        moved.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(moved)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = moved.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        moved.addSubview(host.view)
        context.coordinator.host = host
        TopBarFollow.shared.view = moved
        TopBarFollow.shared.page = follows
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.host?.rootView = content
        TopBarFollow.shared.page = follows
    }

    private var content: Content {
        Content(profiles: profiles, profile: profiles.active, selected: selected, focused: focused,
                pressed: pressed, hidden: hidden)
    }

    struct Content: View {
        let profiles: ProfileStore
        let profile: UserProfile
        let selected: Int
        let focused: Int?
        let pressed: Int?
        let hidden: Bool

        var body: some View {
            let lit = focused ?? selected
            GlassSidebar.layout(hidden: hidden) {
                ForEach(AppTab.topBarOrder) { tab in
                    TopNavLabel(tab: tab, current: selected == tab.rawValue,
                                focused: focused != nil && lit == tab.rawValue)
                        .cardPressDip(pressed == tab.rawValue)
                }
            } profile: {
                ProfileItem(profile: profile, lit: focused == -1)
                    .cardPressDip(pressed == -1)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .environmentObject(profiles)
        }
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
