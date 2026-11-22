import SwiftUI

/// The primary navigation destinations. The app keys tab state off these raw
/// ints in many places, so don't renumber them.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings
    // (4 and 5 were Movies and Series.)
    case discover = 6, upcoming
    var id: Int { rawValue }

    /// The top navigation: Search first, left of Home; Upcoming the
    /// calendar of your shows. The library is a row
    /// on Home — its old tab stays reachable only from within the app.
    static let topBarOrder: [AppTab] = [.search, .home, .discover, .upcoming, .settings]


    var label: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .settings: return "Settings"
        case .discover: return "Discover"
        case .upcoming: return "Upcoming"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "bookmark.fill"
        case .settings: return "gearshape.fill"
        case .discover: return "safari.fill"
        case .upcoming: return "calendar"
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
/// (`TopBarStrip`), moved by the rows (`FixedFocusRowsController`'s
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

/// The top bar's measures (the bar itself: `TopBar`, `TopBarStrip`).
enum GlassSidebar {
    /// Clearance a tab gives the top bar, applied as SAFE-AREA padding rather
    /// than plain padding (plain padding clipped a scrolled page at a line
    /// under the bar). Sized to sit just under the bar minus the top
    /// title-safe inset the system already gives.
    static let topBarClearance: CGFloat = 52
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
    /// Hiding: up past the screen's top edge.
    static var hideTravel: CGFloat { topBarTop + topBarItemHeight + 30 }
}

/// The top navigation: part of the page, not floating over it — the tabs
/// as words at the page's left edge, the profile at its right, on the
/// background with nothing behind them. The current tab's name brighter;
/// focused, the white capsule on the item. Pages are laid out below it
/// (`topBarClearance`); on Home it is on the billboard's picture and goes
/// up with it (`TopBarFollow`).
///
/// UIKit, focus and drawing in one place (`TopBarStrip`, in the window); the root
/// says which tab is current and is told when it changes. Its focus is no
/// SwiftUI state: a move along it, into it or out of it redraws only its
/// items (a `@FocusState` at the root redrew every tab on each, and Up
/// came in through a failed move and a focus set a runloop later).
@MainActor
final class TopBar: ObservableObject {
    static let shared = TopBar()
    var strip: TopBarStrip?

    /// The item with focus (a tab's raw value, the profile -1); nil: the page.
    private(set) var focused: Int?
    /// Settings remembers where Up left its rows (`ATVSettingsView`): only
    /// it observes this, and it changes only while Settings is the tab.
    @Published private(set) var focusedOnSettings = false

    /// Pages with a way in of their own from the bar, by tab: the view Down
    /// goes to (Discover's sentence), nil for the engine's own move. Through
    /// the bar's guide, in the window: a guide in SwiftUI's page is ignored
    /// (its own search found the first title) and a request into it refused.
    var entries: [Int: () -> UIView?] = [:]

    /// Not focusable for a moment, so the engine seeds focus in the page
    /// (after Select on a tab, Back in the bar, a pop, the stage going, the
    /// gate): as short as focus needs to settle — every Up in it is lost.
    private(set) var enabled = false
    private var reenable: Task<Void, Never>?
    static let settleTime: Double = 0.25

    func noteFocus(_ item: Int?, selected: Int) {
        guard item != focused else { return }
        AppProbe.focus("top bar: " + (item.map { $0 < 0 ? "profile" : RootView.tabName($0) } ?? "page"))
        focused = item
        let onSettings = item != nil && selected == AppTab.settings.rawValue
        if onSettings != focusedOnSettings { focusedOnSettings = onSettings }
    }

    /// Focus to an item (Back on a tab's page, the gate closed from the
    /// avatar): focusable at once, whatever window was pending.
    func focus(_ item: Int) {
        AppProbe.focus("top bar: focus asked (\(item < 0 ? "profile" : RootView.tabName(item)))")
        setEnabled(true)
        strip?.focus(item)
    }

    /// Back in the bar, Select on a tab: focus to the page under it.
    func leave() {
        settle(for: Self.settleTime)
        strip?.release()
    }

    /// Off now, focusable again after `delay` (from the curtain's lift).
    func settle(for delay: Double) {
        setEnabled(false)
        schedule(after: delay)
    }

    /// Focusable after `delay`, leaving it as it is meanwhile (Home's rows
    /// ready: disabling first would kick focus off a bar in use).
    func enable(after delay: Double) { schedule(after: delay) }

    /// Cold launch: focusable 3 s after the curtain lifts, unless a settle
    /// has decided by then.
    func start() async {
        await LaunchPreloader.shared.lifted()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard !Task.isCancelled, reenable == nil, !enabled else { return }
        setEnabled(true)
    }

    private func setEnabled(_ on: Bool) {
        reenable?.cancel()
        reenable = nil
        guard on != enabled else { return }
        enabled = on
        AppProbe.rail = on ? "enabled" : "disabled"
        strip?.refresh()
    }

    private func schedule(after delay: Double) {
        reenable?.cancel()
        reenable = Task { @MainActor [weak self] in
            await LaunchPreloader.shared.lifted()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reenable = nil
            self.setEnabled(true)
        }
    }
}

/// The top bar's place in the root's view tree: it draws nothing, and puts
/// the bar (`TopBarStrip`) in the window beside the SwiftUI root and hands
/// it the root's state: out of SwiftUI's tree, its focus is UIKit's alone.
/// (A hit-testable view of its own over the page, in SwiftUI's tree, kept
/// SwiftUI's focus from the page: Down found nothing, Back left nothing
/// focused — hence the anchor's zero size and no hit testing.)
struct TopBarView: UIViewRepresentable {
    let profiles: ProfileStore
    let profile: UserProfile
    let selected: Int
    /// Off a tab's root (Details, a pushed page): out of the way at once,
    /// in place again at once (the page's change covers it).
    let hidden: Bool
    /// Something of the root's over the page (curtain, gate, stage,
    /// welcome): the bar fades out and takes no focus.
    let blocked: Bool
    /// The page it goes with (`TopBarFollow.page`).
    let follows: String?
    /// Focus moved along it: that tab (the page follows).
    let onSwitch: (Int) -> Void
    /// Select on the avatar.
    let onProfile: () -> Void

    func makeUIView(context: Context) -> TopBarAnchor {
        let strip = TopBar.shared.strip ?? TopBarStrip(profiles: profiles, profile: profile)
        TopBar.shared.strip = strip
        update(strip)
        return TopBarAnchor()
    }

    func updateUIView(_ anchor: TopBarAnchor, context: Context) {
        if let strip = TopBar.shared.strip { update(strip) }
    }

    private func update(_ strip: TopBarStrip) {
        strip.onSwitch = onSwitch
        strip.onProfile = onProfile
        strip.update(selected: selected, hidden: hidden, blocked: blocked, profile: profile)
        TopBarFollow.shared.page = follows
    }
}

/// Puts the bar in the window, right above the SwiftUI root, so what the
/// app adds to the window later (Details' opening, the hold menus, the
/// player) comes over it.
final class TopBarAnchor: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, let strip = TopBar.shared.strip, strip.superview !== window,
              let root = window.rootViewController?.view else { return }
        strip.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: TopBarStrip.height)
        strip.autoresizingMask = [.flexibleWidth]
        window.insertSubview(strip, aboveSubview: root)
    }
}

/// The bar's items in a UIKit view the rows can move (`TopBarFollow`),
/// each a focusable view drawing its SwiftUI face (`TopBarItem`). Coming in
/// from the page only the current tab can take focus, and a focus guide
/// the screen's width under the bar sends Up there from anywhere (from a
/// page whose topmost row was close under it, or far to the side of the
/// current tab, the engine found nothing).
final class TopBarStrip: UIView {
    var onSwitch: (Int) -> Void = { _ in }
    var onProfile: () -> Void = {}
    private let profiles: ProfileStore
    private var profile: UserProfile
    private(set) var selected = -99
    private var offRoot = false
    private var blocked = false
    /// Moved by `TopBarFollow`; the items in it.
    private let moved = UIView()
    private var items: [TopBarItem] = []
    private let guide = UIFocusGuide()
    /// An item asked for (`focus`), focusable for that request.
    private(set) var pending: Int?

    init(profiles: ProfileStore, profile: UserProfile) {
        self.profiles = profiles
        self.profile = profile
        super.init(frame: .zero)
        backgroundColor = .clear
        // Out until the root says nothing covers the page (the curtain).
        alpha = 0
        moved.frame = bounds
        moved.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(moved)
        items = AppTab.topBarOrder.map { TopBarItem(id: $0.rawValue, profiles: profiles, profile: profile) }
            + [TopBarItem(id: -1, profiles: profiles, profile: profile)]
        for item in items {
            item.strip = self
            moved.addSubview(item)
        }
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor,
                                       constant: GlassSidebar.topBarTop + GlassSidebar.topBarItemHeight + 2),
            guide.heightAnchor.constraint(equalToConstant: 8),
        ])
        TopBarFollow.shared.view = moved
        // Down from the bar with nothing in line below (Settings' rows, at
        // the screen's right): to the page, as Back.
        NotificationCenter.default.addObserver(forName: UIFocusSystem.movementDidFailNotification,
                                               object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  context.focusHeading.contains(.down),
                  (context.previouslyFocusedItem as? TopBarItem)?.strip != nil else { return }
            MainActor.assumeIsolated { TopBar.shared.leave() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its height: the items and the guide under them.
    static var height: CGFloat { GlassSidebar.topBarTop + GlassSidebar.topBarItemHeight + 12 }


    /// Nothing in the way of focus coming here.
    var focusable: Bool { TopBar.shared.enabled && !offRoot && !blocked && !TopBarLock.shared.locked }

    func canFocus(_ item: TopBarItem) -> Bool {
        focusable && (TopBar.shared.focused != nil || item.id == (pending ?? selected))
    }

    func update(selected: Int, hidden: Bool, blocked: Bool, profile: UserProfile) {
        if profile != self.profile {
            self.profile = profile
            items.last?.profile = profile
            setNeedsLayout()
        }
        if selected != self.selected { mark(selected) }
        if hidden != offRoot {
            offRoot = hidden
            setNeedsLayout()
        }
        if blocked != self.blocked {
            self.blocked = blocked
            // The root's covers came over the bar when it was in the root:
            // now beside it, it goes as they come (their fade).
            UIView.animate(withDuration: Motion.fadeDuration, delay: 0, options: [.beginFromCurrentState]) {
                self.alpha = blocked ? 0 : 1
            }
        }
        refresh()
    }

    /// The current tab's pill, at once (a move along: the page's own update
    /// came later — the old item showed the pill a moment: a flicker).
    private func mark(_ tab: Int) {
        selected = tab
        for item in items where item.id >= 0 { item.current = item.id == tab }
        refresh()
    }

    /// The guide under the bar: from the page, Up to the current tab; from
    /// the bar, Down into a page's own way in (`TopBar.entries`).
    func refresh() {
        if TopBar.shared.focused != nil {
            let entry = TopBar.shared.entries[selected]?()
            guide.preferredFocusEnvironments = entry.map { [$0] } ?? []
            guide.isEnabled = entry != nil
        } else {
            guide.preferredFocusEnvironments = items.first { $0.id == selected }.map { [$0] } ?? []
            guide.isEnabled = focusable
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        let target = pending ?? selected
        return items.first { $0.id == target }.map { [$0] } ?? []
    }

    /// Focus to an item; asked again on the next turn if it didn't take
    /// (the gate's going, or a disabled window, still blocked it).
    func focus(_ item: Int, retry: Bool = true) {
        guard let system = UIFocusSystem.focusSystem(for: self), let window else { return }
        pending = item
        if system.focusedItem is TopBarItem {
            system.requestFocusUpdate(to: self)
            system.updateFocusIfNeeded()
        } else {
            // From the page: SwiftUI's host refuses a request from outside
            // while focus is in it. With nothing in it focusable for this one
            // update, the window seeds focus anew — here, on the item asked
            // for (the only one `canFocus` lets in meanwhile).
            let root = window.rootViewController?.view
            root?.isUserInteractionEnabled = false
            system.requestFocusUpdate(to: window)
            system.updateFocusIfNeeded()
            root?.isUserInteractionEnabled = true
        }
        if (system.focusedItem as? TopBarItem)?.id == item { return }
        guard retry else { pending = nil; return }
        DispatchQueue.main.async { [weak self] in self?.focus(item, retry: false) }
    }

    /// Focus to the page (the items can't take it now): the engine's pick
    /// from the window down.
    func release() {
        guard let window, let system = UIFocusSystem.focusSystem(for: window) else { return }
        system.requestFocusUpdate(to: window)
        system.updateFocusIfNeeded()
    }

    func select(_ item: TopBarItem) {
        if item.id < 0 { onProfile(); return }
        if item.id != selected { mark(item.id); onSwitch(item.id) }
        TopBar.shared.leave()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y = GlassSidebar.topBarTop - (offRoot ? GlassSidebar.hideTravel : 0)
        let height = GlassSidebar.topBarItemHeight
        let tabs = items.filter { $0.id >= 0 }
        let widths = tabs.map(\.width)
        let run = widths.reduce(0, +) + GlassSidebar.itemSpacing * CGFloat(max(0, tabs.count - 1))
        // The first icon starts on the rows' text edge, as their names (on
        // the cards' edge it read 4 pt left of them; the first item's
        // padding is the capsule's room, so the edge is the slot's).
        var x = GlassSidebar.centred ? ((bounds.width - run) / 2).rounded()
                                     : FixedFocusMetrics.titleInset - GlassSidebar.slotPadding
        for (item, width) in zip(tabs, widths) {
            item.frame = CGRect(x: x, y: y, width: width, height: height)
            x += width + GlassSidebar.itemSpacing
        }
        if let avatar = items.last {
            let width = avatar.width
            let right = bounds.width - (Spotlight.screenInset - GlassSidebar.avatarInset)
            avatar.frame = CGRect(x: right - width, y: y, width: width, height: height)
            // Where the gate's picked avatar flies (`ProfileGate`).
            let side = height - 2 * GlassSidebar.avatarInset
            TopBarAvatar.base = CGRect(x: right - GlassSidebar.avatarInset - side,
                                       y: y + GlassSidebar.avatarInset, width: side, height: side)
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let next = (context.nextFocusedItem as? TopBarItem).flatMap { $0.strip === self ? $0 : nil }
        let previous = (context.previouslyFocusedItem as? TopBarItem).flatMap { $0.strip === self ? $0 : nil }
        guard next != nil || previous != nil else { return }
        previous?.lit = false
        next?.lit = true
        pending = nil
        // Focus follows → tab follows, only for moves along the bar (focus
        // stays here; Select hands it to the page).
        if let next, previous != nil, next.id >= 0, next.id != selected {
            mark(next.id)
            onSwitch(next.id)
        }
        TopBar.shared.noteFocus(next?.id, selected: selected)
        refresh()
    }
}

/// One item of the bar: focusable, drawing its face (`TopNavLabel`, the
/// avatar's `ProfileItem`) in a small host of its own, redrawn only when
/// its own state changes. Select: a tab hands focus to its page, the
/// avatar opens the gate; Back: to the page.
final class TopBarItem: UIView {
    let id: Int
    weak var strip: TopBarStrip?
    private let profiles: ProfileStore
    var profile: UserProfile { didSet { render(); invalidateIntrinsicContentSize() } }
    var lit = false { didSet { if lit != oldValue { if !lit { pressed = false }; render() } } }
    var current = false { didSet { if current != oldValue { render() } } }
    private var pressed = false
    private let host: UIHostingController<TopBarItemFace>

    init(id: Int, profiles: ProfileStore, profile: UserProfile) {
        self.id = id
        self.profiles = profiles
        self.profile = profile
        host = UIHostingController(rootView: TopBarItemFace(tab: AppTab(rawValue: id), profiles: profiles,
                                                            profile: profile, lit: false, current: false,
                                                            pressed: false))
        super.init(frame: .zero)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { strip?.canFocus(self) == true }

    /// Measured once per face (the strip is laid out on every frame the
    /// bar follows a scroll: measuring SwiftUI each time cost ~3 ms a frame).
    var width: CGFloat {
        if let measured { return measured }
        let width = host.sizeThatFits(in: CGSize(width: 800, height: GlassSidebar.topBarItemHeight)).width.rounded(.up)
        measured = width
        return width
    }
    private var measured: CGFloat?

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }

    private func render() {
        measured = nil
        strip?.setNeedsLayout()
        host.rootView = TopBarItemFace(tab: AppTab(rawValue: id), profiles: profiles, profile: profile,
                                       lit: lit, current: current, pressed: pressed)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { pressed = true; render(); return }
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            pressed = false
            render()
            strip?.select(self)
            return
        }
        // Back in the bar: to the page (never out of the app).
        if presses.contains(where: { $0.type == .menu }) { TopBar.shared.leave(); return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if pressed { pressed = false; render() }
        super.pressesCancelled(presses, with: event)
    }
}

/// An item's face: a tab's icon and name, or the profile's name and avatar,
/// with the cards' press dip.
struct TopBarItemFace: View {
    let tab: AppTab?
    let profiles: ProfileStore
    let profile: UserProfile
    let lit: Bool
    let current: Bool
    let pressed: Bool

    var body: some View {
        Group {
            if let tab {
                TopNavLabel(tab: tab, current: current, focused: lit)
            } else {
                ProfileItem(profile: profile, lit: lit)
            }
        }
        .fixedSize()
        .cardPressDip(pressed)
        .environmentObject(profiles)
    }
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
struct TopNavLabel: View {
    let tab: AppTab
    let current: Bool
    var focused = false

    var body: some View {
        let label = HStack(spacing: GlassSidebar.iconGap) {
            Image(systemName: tab.icon)
                .font(.system(size: GlassSidebar.iconSize, weight: .semibold))
            Text(tab.label)
                .font(.system(size: GlassSidebar.textSize, weight: .medium))
        }
        .padding(.horizontal, GlassSidebar.slotPadding)
        .frame(height: GlassSidebar.topBarItemHeight)
        label
            .modifier(TopNavFocus(lit: focused,
                                  rest: CueInk.color(current ? FixedFocusText.primary : FixedFocusText.secondary),
                                  pill: current))
            .animation(.easeOut(duration: 0.18), value: current)
    }
}

/// The profile at the bar's right edge: its name as a tab's, then the
/// avatar near the bar's full height with the cards' light rim,
/// `avatarInset` inside the capsule's round end (flush, focused it had no
/// white round it); its edge on the cards' right edge. (A 42 pt avatar
/// alone, 16 pt past the cards, read lost.)
struct ProfileItem: View {
    let profile: UserProfile
    var lit = false

    var body: some View {
        let item = HStack(spacing: GlassSidebar.iconGap) {
            Text(profile.name)
                .font(.system(size: GlassSidebar.textSize, weight: .medium))
                .lineLimit(1)
            ProfileAvatarView(profile: profile,
                              size: GlassSidebar.topBarItemHeight - 2 * GlassSidebar.avatarInset)
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2) }
        }
        .padding(.leading, GlassSidebar.slotPadding)
        .padding(.trailing, GlassSidebar.avatarInset)
        .frame(height: GlassSidebar.topBarItemHeight)
        item.modifier(TopNavFocus(lit: lit, rest: CueInk.color(FixedFocusText.secondary)))
    }
}

/// Settings' page with the bar's focus, observed here, not at the root
/// (only while Settings is the tab does it change: `focusedOnSettings`).
struct SettingsRoot: View {
    @ObservedObject private var bar = TopBar.shared
    let onExit: () -> Void

    var body: some View {
        ATVSettingsView(barFocused: bar.focusedOnSettings, onExit: onExit)
    }
}
