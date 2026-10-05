import SwiftUI
import UIKit

/// One item of a hold menu (`TitleMenu`, Continue Watching's, an episode's),
/// shown by `HoldMenu`.
struct MenuEntry {
    let title: String
    let icon: String
    var destructive = false
    /// A second step before it acts (a whole series marked watched).
    var confirm: String?
    let run: () -> Void
}

// MARK: - The hold menu

/// What a hold opens: the entries, and the card they belong to (window
/// points — the menu opens beside it).
struct HoldMenuRequest {
    let entries: [MenuEntry]
    /// The card as it is while its menu is open (held size).
    let anchor: CGRect
    /// The card held (true, the menu open) or back (false).
    var onHeld: ((Bool) -> Void)? = nil
    /// No menu: the hold runs the (first) entry at once (Details' Play →
    /// its sources).
    var direct = false
    /// The card at rest in its row and the gap to its neighbours: the menu
    /// then starts where the next card does (right) or ends where the one
    /// before ends (left). Nil: just beside the held card.
    var row: (rest: CGRect, gap: CGFloat)? = nil
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
                    return provider.holdMenu(for: focused)
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

/// The menu itself: a glass panel beside the card, growing out of the card's
/// side (the screen behind it not dimmed — see `dimming`).
private final class HoldMenuController: UIViewController {
    private let request: HoldMenuRequest
    private let dim = UIView()
    private var panel: UIHostingController<HoldMenuPanel>!
    private var closing = false

    /// How much the screen dims behind the menu (off: the held card's
    /// growth says enough).
    static let dimming: CGFloat = 0
    /// The panel's gap to the card, and the screen margin it keeps.
    static let gap: CGFloat = 28
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
        view.addSubview(dim)
        panel = UIHostingController(rootView: HoldMenuPanel(entries: request.entries,
                                                            onPick: { [weak self] in self?.close(then: $0.run) },
                                                            onCancel: { [weak self] in self?.close() }))
        panel.view.backgroundColor = .clear
        addChild(panel)
        view.addSubview(panel.view)
        panel.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dim.frame = view.bounds
        guard !closing else { return }
        let size = panel.sizeThatFits(in: CGSize(width: view.bounds.width, height: view.bounds.height))
        let anchor = view.convert(request.anchor, from: nil)
        // Right of the card, level with its top; left of it if it doesn't
        // fit. In a row: on the neighbouring card's edge.
        let (start, end): (CGFloat, CGFloat) = request.row.map { row in
            let rest = view.convert(row.rest, from: nil)
            return (rest.maxX + row.gap, rest.minX - row.gap)
        } ?? (anchor.maxX + Self.gap, anchor.minX - Self.gap)
        let right = start + size.width <= view.bounds.width - Self.margin
        let x = right ? start : end - size.width
        let y = min(max(anchor.minY, Self.margin), view.bounds.height - Self.margin - size.height)
        // Grows out of its top corner facing the card.
        panel.view.layer.anchorPoint = CGPoint(x: right ? 0 : 1, y: 0)
        panel.view.bounds = CGRect(origin: .zero, size: size)
        panel.view.center = CGPoint(x: right ? x : x + size.width, y: y)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        panel.view.alpha = 0
        panel.view.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        request.onHeld?(true)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            self.panel.view.alpha = 1
            self.panel.view.transform = .identity
            self.dim.alpha = Self.dimming
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [panel] }

    /// Back closes it (a confirmation step first goes back to the list —
    /// the panel handles that itself).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { close(); return }
        super.pressesBegan(presses, with: event)
    }

    /// Out quickly; then (focus back on the card) the choice runs.
    private func close(then action: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        request.onHeld?(false)
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn]) {
            self.panel.view.alpha = 0
            self.panel.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            self.dim.alpha = 0
        } completion: { _ in
            self.dismiss(animated: false) {
                HoldMenu.shared.closed()
                action?()
            }
        }
    }
}

/// The menu's glass panel: one row per entry — nothing at rest, the white
/// highlight when focused (as the source picker's rows). An entry with a
/// confirmation asks first, in place.
private struct HoldMenuPanel: View {
    let entries: [MenuEntry]
    let onPick: (MenuEntry) -> Void
    let onCancel: () -> Void
    @State private var confirming: Int?
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let index = confirming, let question = entries[index].confirm {
                row(question, icon: entries[index].icon, destructive: true, id: 0) { onPick(entries[index]) }
                row("Cancel", icon: "xmark", destructive: false, id: 1) { confirming = nil; focused = index }
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    row(entry.title, icon: entry.icon, destructive: entry.destructive, id: index) {
                        if entry.confirm != nil {
                            confirming = index
                            focused = 0
                        } else {
                            onPick(entry)
                        }
                    }
                }
            }
        }
        // As wide as its longest entry.
        .fixedSize(horizontal: true, vertical: false)
        .padding(HoldMenuRowStyle.inset)
        .liquidGlass(in: RoundedRectangle(cornerRadius: HoldMenuRowStyle.corner + HoldMenuRowStyle.inset,
                                          style: .continuous))
        .defaultFocus($focused, 0)
        .onExitCommand {
            if let index = confirming { confirming = nil; focused = index } else { onCancel() }
        }
    }

    private func row(_ title: String, icon: String, destructive: Bool, id: Int,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 32)
                Text(title)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 24)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68, alignment: .leading)
        }
        .buttonStyle(HoldMenuRowStyle(destructive: destructive))
        .focused($focused, equals: id)
    }
}

/// A menu row: nothing at rest, the white highlight when focused.
private struct HoldMenuRowStyle: ButtonStyle {
    static let corner: CGFloat = 30
    static let inset: CGFloat = 14
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View { Platter(configuration: configuration, destructive: destructive) }

    private struct Platter: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let destructive: Bool

        var body: some View {
            configuration.label
                .foregroundStyle(destructive ? Color(red: 1, green: 0.27, blue: 0.23)
                                 : isFocused ? AppGlass.textOnFocus : AppGlass.text)
                .background(RoundedRectangle(cornerRadius: HoldMenuRowStyle.corner, style: .continuous)
                    .fill(isFocused ? FlatControl.focus : Color.clear))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

// MARK: - Full text

/// A long text in full — Details' summary: a glass panel over the screen,
/// Back closes it (the same presentation as `HoldMenu`).
@MainActor
enum TextPanel {
    static func present(title: String, text: String) {
        guard !text.isEmpty,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: { $0.isKeyWindow }) else { return }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(TextPanelView(title: title, text: text) { [weak host] in
            host?.dismiss(animated: true)
        })
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        top?.present(host, animated: true)
    }
}

private struct TextPanelView: View {
    let title: String
    let text: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.white)
                Text(text)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineSpacing(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(48)
            .frame(width: 1100, alignment: .leading)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            // Focusable (for Back) — nothing to choose.
            .focusable()
        }
        .onExitCommand(perform: onClose)
    }
}
