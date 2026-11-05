import SwiftUI
import UIKit

/// One item of a hold menu (`TitleMenu`, Continue Watching's, an episode's),
/// shown by `HoldMenu`.
struct MenuEntry {
    let title: String
    let icon: String
    var destructive = false
    /// A dropdown's current choice: a check at the row's end.
    var checked = false
    let run: () -> Void
}

// MARK: - The hold menu

/// What a hold opens: the entries, and the card they belong to (window
/// points — the menu opens beside it).
struct HoldMenuRequest {
    let entries: [MenuEntry]
    /// The card as it is while its menu is open (held size).
    let anchor: CGRect
    /// The card as it is when the menu opens (pressed, a little smaller):
    /// the dim's hole grows from it with the card (at the held size at
    /// once, the page showed undimmed around it).
    var from: CGRect? = nil
    /// The card back at its focused size (Select let go by then): the hole
    /// shrinks to it with the card on closing (kept at the held size, a
    /// thin undimmed ring showed; shrunk to `from`, dim on its edges).
    var rest: CGRect? = nil
    /// The card held (true, the menu open) or back (false).
    var onHeld: ((Bool) -> Void)? = nil
    /// No menu: the hold runs the (first) entry at once (Details' Play →
    /// its sources).
    var direct = false
    /// A dropdown: the panel opens under the anchor, on its left edge.
    var below = false
    /// The neighbouring cards' facing edges (window x): the menu starts on
    /// the next card's left edge, or ends on the one before's right edge.
    /// Nil: `gap` beside the held card.
    var beside: (left: CGFloat?, right: CGFloat?)? = nil
}

extension UICollectionViewCell {
    /// Where the cards beside it start (right) and end (left) in the window,
    /// on its own line — a missing one (the row's end) where it would be.
    func neighbourEdges() -> (left: CGFloat?, right: CGFloat?)? {
        guard let list = superview as? UICollectionView, let path = list.indexPath(for: self) else { return nil }
        let me = list.layoutAttributesForItem(at: path)?.frame ?? frame
        func card(_ step: Int) -> CGRect? {
            let item = path.item + step
            guard item >= 0, item < list.numberOfItems(inSection: path.section),
                  let other = list.layoutAttributesForItem(at: IndexPath(item: item, section: path.section))?.frame,
                  abs(other.midY - me.midY) < 1 else { return nil }
            return other
        }
        let next = card(1), before = card(-1)
        let right = next?.minX ?? before.map { me.maxX + (me.minX - $0.maxX) }
        let left = before?.maxX ?? next.map { me.minX - ($0.minX - me.maxX) }
        func window(_ x: CGFloat?) -> CGFloat? { x.map { list.convert(CGPoint(x: $0, y: me.midY), to: nil).x } }
        return (window(left), window(right))
    }
}

/// A UIKit screen with hold menus: the menu for the focused card (nil: none
/// there). Found along the focused view's responder chain.
@MainActor
protocol HoldMenuProviding: AnyObject {
    func holdMenu(for focused: UIView) -> HoldMenuRequest?
}

/// HOLDING SELECT, app-wide — Cue's own menu, not the system's context menu.
/// (That one kept focus inside itself until its closing animation ended:
/// focus came back late, and on the fixed-box rows the next press only
/// brought it back, the press lost.)
///
/// One long-press recogniser on the window: when Select has been held for
/// `holdDuration`, whatever has focus is asked for a menu — a UIKit
/// `HoldMenuProviding` up the focused view's responder chain, or a SwiftUI
/// view's `.holdMenu` while it has focus. Nothing offered: the recogniser
/// doesn't start, and the press goes on as usual. Offered: the press is
/// cancelled (no Select on release) and the menu opens beside the card —
/// presented modally, so focus stays in it; Back or a choice closes it, and
/// focus is on the card as it goes.
@MainActor
final class HoldMenu: NSObject, UIGestureRecognizerDelegate {
    /// How much the screen dims behind a hold menu (not the held card, not
    /// behind a dropdown) and behind the source panel.
    /// (Tried: 35 % — heavy under the glass.)
    static let dimming: CGFloat = 0.15

    static let shared = HoldMenu()
    /// How long Select is held before the menu opens (the system's is about
    /// half a second).
    static let holdDuration: TimeInterval = 0.45

    private weak var window: UIWindow?
    /// A menu is open: the card it belongs to keeps its focus look (focus
    /// itself is in the menu).
    private(set) var isOpen = false
    private var pending: HoldMenuRequest?
    /// The focused SwiftUI view's menu (`.holdMenu`), by its id.
    private var swiftUI: (id: UUID, request: () -> HoldMenuRequest?)?

    /// Puts the recogniser on the app's window (once).
    func install() {
        guard window == nil,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: { $0.isKeyWindow })
        else { return }
        self.window = window
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = Self.holdDuration
        hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        hold.allowedTouchTypes = []
        hold.delegate = self
        window.addGestureRecognizer(hold)
        // Dev (`-holdMenuDemo`): the focused card's menu (else a sample), unasked — the
        // simulator can't hold Select.
        if ProcessInfo.processInfo.arguments.contains("-holdMenuDemo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [self] in
                let entry = { (title: String, icon: String) in MenuEntry(title: title, icon: icon) {} }
                let demo = HoldMenuRequest(
                    entries: [entry("Details", "info.circle"), entry("Start Over", "backward.end"),
                              entry("Choose Source", "list.bullet"), entry("Mark as Watched", "checkmark.circle"),
                              MenuEntry(title: "Remove from Continue Watching", icon: "minus.circle",
                                        destructive: true) {}],
                    anchor: CGRect(x: FixedFocusMetrics.inset, y: FixedFocusMetrics.boxFrame.minY,
                                   width: FixedFocusMetrics.boxWidth, height: FixedFocusMetrics.height))
                // The focused card's own menu, where a hold would open it.
                present(request() ?? demo)
            }
        }
    }

    fileprivate func closed() { isOpen = false }

    func setFocused(_ id: UUID, _ request: @escaping () -> HoldMenuRequest?) { swiftUI = (id, request) }
    func clearFocused(_ id: UUID) { if swiftUI?.id == id { swiftUI = nil } }

    nonisolated func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            pending = request()
            return pending != nil
        }
    }

    /// Alongside everything else (the cards' own press handling, scrolling).
    nonisolated func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func request() -> HoldMenuRequest? {
        guard let window else { return nil }
        // Not while a menu is open (a screen presented over the app — the
        // player — has its own).
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if top is HoldMenuController { return nil }
        if let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView {
            var responder: UIResponder? = focused
            while let current = responder {
                if let provider = current as? HoldMenuProviding {
                    // The nearest provider decides (nil: no menu here).
                    var request = provider.holdMenu(for: focused)
                    if request?.beside == nil, let cell = focused as? UICollectionViewCell {
                        request?.beside = cell.neighbourEdges()
                    }
                    return request
                }
                responder = current.next
            }
        }
        return swiftUI?.request()
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let request = pending else { return }
        pending = nil
        if request.direct { request.entries.first?.run(); return }
        present(request)
    }

    /// The menu, over whatever is in front.
    private func present(_ request: HoldMenuRequest) {
        guard let window else { return }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let menu = HoldMenuController(request: request)
        isOpen = true
        top?.present(menu, animated: false)
    }
}

extension View {
    /// Holding Select while this view has focus opens `entries` beside it
    /// (see `HoldMenu`). `focused`: whether it has focus now.
    func holdMenu(focused: Bool, direct: Bool = false, onHeld: ((Bool) -> Void)? = nil,
                  _ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(HoldMenuModifier(focused: focused, direct: direct, onHeld: onHeld, entries: entries))
    }
}

private struct HoldMenuModifier: ViewModifier {
    let focused: Bool
    let direct: Bool
    let onHeld: ((Bool) -> Void)?
    let entries: () -> [MenuEntry]
    @State private var id = UUID()
    @State private var frame = HoldMenuFrame()

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { frame.rect = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { _, rect in frame.rect = rect }
                }
            }
            .onAppear { HoldMenu.shared.install(); register(focused) }
            .onChange(of: focused) { _, now in register(now) }
            .onDisappear { HoldMenu.shared.clearFocused(id) }
    }

    private func register(_ focused: Bool) {
        guard focused else { HoldMenu.shared.clearFocused(id); return }
        let entries = entries, frame = frame, onHeld = onHeld, direct = direct
        HoldMenu.shared.setFocused(id) {
            let list = entries()
            return list.isEmpty ? nil
                : HoldMenuRequest(entries: list, anchor: frame.rect, onHeld: onHeld, direct: direct)
        }
    }
}

/// Where a `.holdMenu` view is (kept without redrawing it).
private final class HoldMenuFrame {
    var rect: CGRect = .zero
}

/// The menu itself: a glass panel beside the card, unfolding out of the
/// card's side (`openScale`); the screen behind it dimmed, the held card left out (`HoldMenu.dimming`).
private final class HoldMenuController: UIViewController {
    private let request: HoldMenuRequest
    private let dim = UIView()
    /// The dim's hole: the held card, as it shows.
    private let hole = CAShapeLayer()
    private let panel = MenuPanel()
    private var placed = false
    private var closing = false

    /// The panel's gap to a card with none beside it, and the screen margin
    /// it keeps.
    static let gap: CGFloat = 18
    static let margin: CGFloat = 60

    init(request: HoldMenuRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dim.backgroundColor = .black
        dim.alpha = 0
        hole.fillRule = .evenOdd
        dim.layer.mask = hole
        view.addSubview(dim)
        let entries = request.entries
        panel.load { [weak self] in
            MenuPanel.Menu(entries: entries, pick: { self?.close(then: $0.run) })
        }
        // A pick closes it itself, once the choice is known (`close(then:)`).
        panel.picked = {}
        view.addSubview(panel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dim.frame = view.bounds
        guard !closing, !placed else { return }
        placed = true
        let size = panel.size
        let anchor = view.convert(request.anchor, from: nil)
        hole.frame = view.bounds
        hole.path = holePath(around: request.anchor)
        // Right of the card (held), level with its top, starting on the
        // next card's left edge; left of it, ending on the one before's
        // right edge, if it doesn't fit. (No cards beside it: `gap` away.)
        let start = request.beside?.right ?? anchor.maxX + Self.gap
        let end = request.beside?.left ?? anchor.minX - Self.gap
        if request.below {
            // Under the button, sharing its left edge — or its right edge, for
            // a button on the screen's right half.
            let alignRight = anchor.midX > view.bounds.midX
            let x = min(max(alignRight ? anchor.maxX - size.width : anchor.minX, Self.margin),
                        view.bounds.width - Self.margin - size.width)
            let y = min(anchor.maxY + 14, view.bounds.height - Self.margin - size.height)
            panel.layer.anchorPoint = CGPoint(x: alignRight ? 1 : 0, y: 0)
            panel.bounds = CGRect(origin: .zero, size: size)
            panel.center = CGPoint(x: alignRight ? x + size.width : x, y: y)
            return
        }
        let right = start + size.width <= view.bounds.width - Self.margin
        let x = right ? start : end - size.width
        // Level with the card's top — a card low on the screen (Search's):
        // with its bottom instead, rather than somewhere in between.
        let bottom = view.bounds.height - Self.margin
        let top = anchor.minY + size.height <= bottom
        let y = top ? max(anchor.minY, Self.margin)
            : min(max(anchor.maxY - size.height, Self.margin), bottom - size.height)
        // Grows out of its corner facing the card, on the edge it shares.
        panel.layer.anchorPoint = CGPoint(x: right ? 0 : 1, y: top ? 0 : 1)
        panel.bounds = CGRect(origin: .zero, size: size)
        panel.center = CGPoint(x: right ? x : x + size.width, y: top ? y : y + size.height)
    }

    /// The dim with the card cut out (window rect), its corners grown with it.
    private func holePath(around card: CGRect) -> CGPath {
        let path = UIBezierPath(rect: view.bounds)
        let grown = 1 + FixedFocusMetrics.movingFocusLift + FixedFocusMetrics.heldGrowth
        path.append(UIBezierPath(roundedRect: view.convert(card, from: nil),
                                 cornerRadius: Spotlight.cornerRadius * grown))
        return path.cgPath
    }

    /// The hole following the card to `card`, on the card's own timing.
    private func moveHole(to card: CGRect, from start: CGRect) {
        let move = CABasicAnimation(keyPath: "path")
        move.fromValue = holePath(around: start)
        move.toValue = holePath(around: card)
        move.duration = FixedFocusMetrics.heldDuration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hole.path = holePath(around: card)
        hole.add(move, forKey: "path")
    }

    /// Unfolding out of the card (the Apple TV app's way): from this size,
    /// at its corner facing the card, on the present spring; the glass
    /// shows at once, the entries a moment later.
    static let openScale: CGFloat = 0.5
    static let openFade: Double = 0.12
    /// Closing: back into that corner, quicker.
    static let closeScale: CGFloat = 0.6
    static let closeDuration: Double = 0.22

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: Self.openScale, y: Self.openScale)
        panel.revealRows()
        request.onHeld?(true)
        if let from = request.from { moveHole(to: request.anchor, from: from) }
        UIView.animate(springDuration: Motion.presentDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction]) {
            self.panel.transform = .identity
        }
        UIView.animate(withDuration: Self.openFade, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.panel.alpha = 1
        }
        UIView.animate(withDuration: Motion.fadeDuration, delay: 0, options: [.allowUserInteraction]) {
            self.dim.alpha = self.request.below ? 0 : HoldMenu.dimming
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [panel] }

    /// Back closes it.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { close(); return }
        super.pressesBegan(presses, with: event)
    }

    /// Out quickly; then (focus back on the card) the choice runs.
    private func close(then action: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        request.onHeld?(false)
        if let rest = request.rest { moveHole(to: rest, from: request.anchor) }
        UIView.animate(withDuration: Self.closeDuration, delay: 0, options: [.curveEaseIn]) {
            self.panel.alpha = 0
            self.panel.transform = CGAffineTransform(scaleX: Self.closeScale, y: Self.closeScale)
            self.dim.alpha = 0
        } completion: { _ in
            self.dismiss(animated: false) {
                HoldMenu.shared.closed()
                action?()
            }
        }
    }
}

// MARK: - The menu panel

/// A change of focus, as the menus' rows: quick both ways, not the system's
/// slow way out.
func focusChange(duration: TimeInterval = 0.12, _ changes: @escaping () -> Void) {
    UIView.animate(withDuration: duration, delay: 0,
                   options: [.curveEaseOut, .beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve],
                   animations: changes)
}

/// The menus' lift under a focused platter; it fades with the platter.
func liftShadow(_ view: UIView) {
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.25
    view.layer.shadowRadius = 12
    view.layer.shadowOffset = CGSize(width: 0, height: 6)
}

/// One row: nothing at rest, focused a white capsule, 2 % larger — sized as
/// tvOS's own context menu (measured off its screen).
private final class MenuPanelRow: UICollectionViewCell {
    static let height: CGFloat = 66
    /// With a value under the title.
    private static let tallHeight: CGFloat = 92
    /// The line's room above a row that starts a new part.
    private static let separation: CGFloat = 20
    private static let headerHeight: CGFloat = 46
    /// The capsule's distance from the row's edges.
    private static let face: CGFloat = 6
    private static let lead: CGFloat = 18
    private static let trail: CGFloat = 36
    private static let checkWidth: CGFloat = 28
    private static let iconWidth: CGFloat = 34
    private static let spacing: CGFloat = 16
    private static let chevronRoom: CGFloat = 36
    static let destructive = UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)

    private static func room(_ separated: Bool, _ header: Bool) -> CGFloat {
        (separated ? separation : 0) + (header ? headerHeight : 0)
    }

    static func height(of row: MenuPanel.Row) -> CGFloat {
        (row.detail == nil ? height : tallHeight) + room(row.separated, row.header != nil)
    }

    private static let titleFont = UIFont.systemFont(ofSize: 28, weight: .medium)
    private static let detailFont = UIFont.systemFont(ofSize: 24)

    /// Where the words start: a check's room (the menu has checks), then the icon.
    private static func textStart(checks: Bool, icon: Bool) -> CGFloat {
        lead + (checks ? checkWidth + spacing : 0) + (icon ? iconWidth + spacing : 0)
    }

    /// What the row needs to show its words whole: the margins of `layoutSubviews`.
    static func width(of row: MenuPanel.Row, checks: Bool) -> CGFloat {
        func measure(_ text: String?, _ font: UIFont) -> CGFloat {
            text.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) } ?? 0
        }
        let words = max(measure(row.title, titleFont), measure(row.detail, detailFont))
        let face = textStart(checks: checks, icon: row.icon != nil) + words + trail + (row.page == nil ? 0 : chevronRoom)
        return max(face + Self.face * 2, measure(row.header, MenuPanel.headingFont) + 48)
    }

    /// What grows with focus; the line and header above it stay put.
    private let face = UIView()
    private let platter = UIView()
    private let check = UIImageView()
    private let icon = UIImageView()
    private let title = RunningLine(font: MenuPanelRow.titleFont, rest: 0.5)
    private let detail = RunningLine(font: MenuPanelRow.detailFont, rest: 0.5)
    private let chevron = UIImageView()
    private let separator = UIView()
    private let header = UILabel()
    private var checks = true
    private var isDestructive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        platter.backgroundColor = .white
        platter.alpha = 0
        liftShadow(platter)
        check.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        check.contentMode = .center
        icon.contentMode = .center
        title.running = false
        detail.running = false
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        chevron.contentMode = .center
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        header.font = MenuPanel.headingFont
        header.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        for sub in [separator, header, face] as [UIView] { contentView.addSubview(sub) }
        for sub in [platter, check, icon, title, detail, chevron] as [UIView] { face.addSubview(sub) }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { focusChange { self.paint() } }
    }

    func show(_ row: MenuPanel.Row, checks: Bool) {
        self.checks = checks
        isDestructive = row.destructive
        title.text = row.title
        detail.text = row.detail ?? ""
        detail.isHidden = row.detail == nil
        check.isHidden = !row.active
        icon.image = row.icon.map {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium))
        } ?? nil
        icon.isHidden = row.icon == nil
        chevron.isHidden = row.page == nil
        separator.isHidden = !row.separated
        header.text = row.header
        header.isHidden = row.header == nil
        paint()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let room = Self.room(!separator.isHidden, !header.isHidden)
        let inner = contentView.bounds.insetBy(dx: Self.face, dy: 0)
            .inset(by: UIEdgeInsets(top: room, left: 0, bottom: 0, right: 0))
        let start = Self.textStart(checks: checks, icon: !icon.isHidden)
        header.frame = CGRect(x: 24, y: room - Self.headerHeight, width: inner.width - 36, height: Self.headerHeight)
        separator.frame = CGRect(x: inner.minX + start, y: Self.separation / 2, width: inner.width - start - 18, height: 1)
        face.bounds = CGRect(origin: .zero, size: inner.size)
        face.center = CGPoint(x: inner.midX, y: inner.midY)
        platter.frame = face.bounds
        platter.layer.cornerRadius = min(inner.height, Self.height) / 2
        platter.layer.shadowPath = UIBezierPath(roundedRect: platter.bounds, cornerRadius: platter.layer.cornerRadius).cgPath
        check.frame = CGRect(x: Self.lead, y: 0, width: Self.checkWidth, height: inner.height)
        icon.frame = CGRect(x: Self.lead + (checks ? Self.checkWidth + Self.spacing : 0), y: 0,
                            width: Self.iconWidth, height: inner.height)
        chevron.frame = CGRect(x: inner.width - 54, y: 0, width: 28, height: inner.height)
        let width = inner.width - start - Self.trail - (chevron.isHidden ? 0 : Self.chevronRoom)
        if detail.isHidden {
            title.frame = CGRect(x: start, y: 0, width: width, height: inner.height)
        } else {
            title.frame = CGRect(x: start, y: 12, width: width, height: 36)
            detail.frame = CGRect(x: start, y: 48, width: width, height: 30)
        }
    }

    private func paint() {
        let focused = isFocused
        let color = isDestructive ? Self.destructive
            : focused ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        title.color = color
        check.tintColor = color
        icon.tintColor = color
        chevron.tintColor = color
        detail.color = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        platter.alpha = focused ? 1 : 0
        let scale: CGFloat = isHighlighted ? 0.97 : focused ? 1.02 : 1
        face.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        if title.running != focused {
            title.running = focused
            detail.running = focused
        }
        focusChange { self.paint() }
    }
}

/// The app's one menu: the hold menus and the player's Audio and Subtitles.
/// A glass panel, a title on top if it has one, a row can open a page of its
/// own, Back returns. A collection view: a tvOS table spaces its rows out and
/// fades its edges. It grows and shrinks from its layer's anchor point, so set
/// that to the corner it opens from.
final class MenuPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Row {
        let title: String
        var detail: String?
        var icon: String?
        var destructive = false
        var active = false
        /// A line above it.
        var separated = false
        /// A title above it, for a part of the list.
        var header: String?
        /// Stays open on a pick, for a setting.
        var stays = false
        var page: (() -> Menu)?
        var pick: () -> Void = {}
    }

    struct Menu {
        /// None where the rows' own headers say it all.
        var title: String?
        let rows: [Row]
        /// Every row keeps room for a check in front (the system menus'
        /// way), so the titles line up, checked or not.
        var checks = true
    }

    static let inset: CGFloat = 16
    private static let headingHeight: CGFloat = 44
    static let headingFont = UIFont.systemFont(ofSize: 24, weight: .medium)
    private static let maxHeight: CGFloat = 640
    /// Room above the first row under a title, inside the list.
    private static let headingClearance: CGFloat = 8

    /// As wide as its widest row, within these: a long row runs while focused.
    var minWidth: CGFloat = 0
    var maxWidth: CGFloat = 900

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: MenuPanelRow.height / 2 + inset, style: .continuous))
    private let list: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private let heading = UILabel()
    /// Built anew on the way back, so a row shows what its page changed.
    private var pages: [(menu: () -> Menu, from: Int)] = []
    private var rows: [Row] = []
    private var checks = true
    private var focusedRow: Int?
    private var width: CGFloat = 0
    /// After a pick that doesn't stay: the menu's owner closes it.
    var picked: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        heading.font = Self.headingFont
        heading.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        addSubview(heading)
        list.backgroundColor = .clear
        list.contentInsetAdjustmentBehavior = .never
        list.dataSource = self
        list.delegate = self
        list.remembersLastFocusedIndexPath = false
        list.register(MenuPanelRow.self, forCellWithReuseIdentifier: "row")
        addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [list] }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        heading.frame = CGRect(x: Self.inset + 24, y: Self.inset, width: bounds.width - Self.inset * 2 - 48, height: Self.headingHeight)
        // The margins are the list's own insets, not outside it: a focused
        // row grows and casts a shadow, which the list's edge would cut.
        let top = heading.text == nil ? Self.inset : Self.headingClearance
        list.frame = bounds.inset(by: UIEdgeInsets(top: Self.inset + headingRoom - top, left: Self.inset,
                                                   bottom: 0, right: Self.inset))
        list.contentInset = UIEdgeInsets(top: top, left: 0, bottom: Self.inset, right: 0)
    }

    private var headingRoom: CGFloat { heading.text == nil ? 0 : Self.headingHeight }

    /// The panel's size for the page showing.
    var size: CGSize {
        CGSize(width: width,
               height: min(rows.reduce(0) { $0 + MenuPanelRow.height(of: $1) } + Self.inset * 2 + headingRoom, Self.maxHeight))
    }

    private func show(_ menu: Menu, focus: Int?) {
        rows = menu.rows
        checks = menu.checks
        heading.text = menu.title
        focusedRow = focus
        let title = menu.title.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.headingFont]).width) + 48 } ?? 0
        let content = menu.rows.reduce(title) { max($0, MenuPanelRow.width(of: $1, checks: checks)) } + Self.inset * 2
        width = min(max(content, minWidth), maxWidth)
    }

    private func toTop() {
        layoutIfNeeded()
        list.contentOffset = CGPoint(x: 0, y: -list.contentInset.top)
    }

    /// Its first page, sized, not yet shown: its owner places and opens it.
    func load(_ menu: @escaping () -> Menu) {
        pages = [(menu, 0)]
        show(menu(), focus: nil)
        transform = .identity
        bounds.size = size
        list.reloadData()
        toTop()
    }

    /// The rows coming in a moment after the glass (it unfolds first). Their
    /// alpha lands at 1 at once: tvOS wouldn't focus into them otherwise.
    func revealRows() {
        list.alpha = 0
        UIView.animate(withDuration: 0.2, delay: 0.08, options: [.curveEaseOut, .allowUserInteraction]) {
            self.list.alpha = 1
        }
    }

    /// Back: a page to the one before it. False on the first.
    func back() -> Bool {
        guard pages.count > 1 else { return false }
        let from = pages.removeLast().from
        turn(to: pages[pages.count - 1].menu(), focus: from)
        return true
    }

    private func turn(to menu: Menu, focus: Int?) {
        show(menu, focus: focus)
        UIView.transition(with: list, duration: Motion.fadeDuration, options: .transitionCrossDissolve) {
            self.list.reloadData()
            self.toTop()
        }
        UIView.animate(withDuration: Motion.moveDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.bounds.size = self.size
            self.layoutIfNeeded()
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        (cell as? MenuPanelRow)?.show(rows[indexPath.item], checks: checks)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: width - Self.inset * 2, height: MenuPanelRow.height(of: rows[indexPath.item]))
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        // Always an answer: with none, focus stays on the cell where it was,
        // now a different row of the new page.
        IndexPath(item: focusedRow ?? rows.firstIndex(where: \.active) ?? 0, section: 0)
    }

    /// The row focused, so a focus update while it's open (the page under it
    /// asking, as the menu closes) keeps it there, not on the page's first.
    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if let path = context.nextFocusedIndexPath { focusedRow = path.item }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let row = rows[indexPath.item]
        if let page = row.page {
            pages.append((page, indexPath.item))
            turn(to: page(), focus: nil)
            return
        }
        row.pick()
        guard row.stays else { return picked() }
        let menu = pages[pages.count - 1].menu()
        rows = menu.rows
        heading.text = menu.title
        for path in list.indexPathsForVisibleItems {
            (list.cellForItem(at: path) as? MenuPanelRow)?.show(rows[path.item], checks: checks)
        }
    }
}

extension MenuPanel.Menu {
    /// A hold menu's entries: one page, no title.
    init(entries: [MenuEntry], pick: @escaping (MenuEntry) -> Void) {
        rows = entries.map { entry in
            MenuPanel.Row(title: entry.title, icon: entry.icon.isEmpty ? nil : entry.icon,
                          destructive: entry.destructive, active: entry.checked) { pick(entry) }
        }
        checks = entries.contains(where: \.checked)
    }
}

// MARK: - Full text

