import os
import AVKit
import SwiftAssRenderer
import AetherEngine
import SwiftUI
import UIKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let meta: MetaItem
    let video: MetaVideo?
    let entry: StreamEntry
    let allEntries: [StreamEntry]
    let resumePosition: Double?
    /// A test stream: nothing of it is saved or synced.
    var isDemo = false
}

/// The player: AetherEngine's picture, Cue's subtitles, progress to the same
/// `ProgressStore` calls the sync reads. Remote: select pause, left/right or a
/// swipe scrub, up the Audio and Subtitles buttons, down the shelf (Details,
/// Episodes, Sources), Back out.
struct CuePlayer: UIViewControllerRepresentable {
    let request: PlaybackRequest
    let progress: ProgressStore
    let settings: PlayerSettings
    /// The first frame has come up over the stage.
    let onShown: () -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> PlayerController {
        PlayerController(request: request, progress: progress, settings: settings, onShown: onShown, onClose: onClose)
    }

    func updateUIViewController(_ controller: PlayerController, context: Context) {}
}

/// Takes focus, so the remote's presses reach the controller.
private final class PlayerFocusView: UIView {
    var takesFocus = true
    override var canBecomeFocused: Bool { takesFocus }
}

/// The app's one glass, as a backing for UIKit controls.
final class GlassBacking: UIView {
    private let host: UIViewController

    init<S: Shape>(_ shape: S) {
        let host = UIHostingController(rootView: Color.clear.liquidGlass(in: shape))
        // Near the screen's edge the safe area would push the glass off its bounds.
        host.safeAreaRegions = []
        self.host = host
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}

/// A round glass button; focused white with a dark icon, 5 % larger. Focusable
/// only while the buttons are in use, so the arrows scrub during playback.
private final class PlayerButton: UIButton {
    static let size: CGFloat = 72

    var takesFocus = false
    private let glass = GlassBacking(Circle())
    private let platter = UIView()

    init(icon: String, label: String) {
        super.init(frame: .zero)
        accessibilityLabel = label
        let symbol = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        setImage(UIImage(systemName: icon, withConfiguration: symbol)?.withRenderingMode(.alwaysTemplate), for: .normal)
        adjustsImageWhenHighlighted = false
        tintColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        platter.backgroundColor = .white
        platter.alpha = 0
        platter.isUserInteractionEnabled = false
        liftShadow(platter)
        insertSubview(glass, at: 0)
        insertSubview(platter, at: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { takesFocus && super.canBecomeFocused }

    override var isHighlighted: Bool {
        didSet { focusChange { self.paint() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        platter.frame = bounds
        platter.layer.cornerRadius = bounds.width / 2
        platter.layer.shadowPath = UIBezierPath(ovalIn: platter.bounds).cgPath
        imageView.map(bringSubviewToFront)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        focusChange { self.paint() }
    }

    private func paint() {
        platter.alpha = isFocused ? 1 : 0
        tintColor = isFocused ? UIColor.black.withAlphaComponent(0.85)
                              : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        let scale: CGFloat = isHighlighted ? 0.97 : isFocused ? 1.05 : 1
        transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

/// A tab of the shelf: focused a white capsule, the chosen one brighter at rest.
private final class PanelTab: UIView {
    static let height: CGFloat = 56
    /// The word's distance from the pill's edge.
    static let padding: CGFloat = 24
    /// `FlatControl.selected`.
    private static let chosenFill: CGFloat = 0.28

    private let platter = UIView()
    private let title = UILabel()
    private let icon = UIImageView()
    let text: String
    /// Select's job, for a tab that's a button (Refresh).
    var action: (() -> Void)?
    /// A button looks like one at rest, as Audio and Subtitles: it needs a
    /// press, where a tab acts on focus.
    private var glass: GlassBacking?
    private var pressed = false
    /// The symbol turns while it works, as the loading dots: a half turn (it
    /// looks the same there), a brief rest, again; stopped, it settles on its
    /// next half turn, never longer than a quick settle.
    var busy = false {
        didSet {
            guard busy != oldValue else { return }
            busy ? turn() : stopTurning()
        }
    }
    private static let halfTurn: CFTimeInterval = 0.7
    private static let turnRest: CFTimeInterval = 0.3
    private static let settleDuration: CFTimeInterval = 0.4

    private func turn() {
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = [0, CGFloat.pi, CGFloat.pi]
        spin.keyTimes = [0, NSNumber(value: Self.halfTurn / (Self.halfTurn + Self.turnRest)), 1]
        spin.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        spin.duration = Self.halfTurn + Self.turnRest
        spin.isCumulative = true
        spin.repeatCount = .infinity
        icon.layer.add(spin, forKey: "turn")
    }

    private func stopTurning() {
        guard icon.layer.animation(forKey: "turn") != nil else { return }
        var angle = (icon.layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        if angle < 0 { angle += .pi * 2 }
        let target = (angle / .pi).rounded(.up) * .pi
        let rest = CABasicAnimation(keyPath: "transform.rotation.z")
        rest.fromValue = angle
        rest.toValue = target
        rest.duration = min(Self.halfTurn * Double((target - angle) / .pi), Self.settleDuration)
        rest.timingFunction = CAMediaTimingFunction(name: .easeOut)
        icon.layer.add(rest, forKey: "turn")
    }

    var chosen = false {
        didSet { paint() }
    }

    /// The chosen one keeps a pill at rest, as Details' season: the flat
    /// control's selected fill. Not while the shelf only peeks.
    var marksChosen = true {
        didSet { paint() }
    }

    /// Folded away it can't take focus.
    var available = true

    /// Asks every add-on again, past the caches.
    static func refresh() -> PanelTab { PanelTab(symbol: "arrow.trianglehead.2.clockwise.rotate.90", named: "Refresh") }

    /// A symbol in place of the word: a round glass button.
    convenience init(symbol: String, named text: String) {
        self.init(text)
        title.text = nil
        let glass = GlassBacking(Circle())
        insertSubview(glass, at: 0)
        self.glass = glass
        liftShadow(platter)
        icon.image = UIImage(systemName: symbol,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium))
        icon.contentMode = .center
        icon.layer.shadowColor = UIColor.black.cgColor
        icon.layer.shadowOffset = .zero
        icon.layer.shadowRadius = 8
        paint()
    }

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        platter.backgroundColor = .white
        platter.alpha = 0
        title.text = text
        title.font = .systemFont(ofSize: 26, weight: .medium)
        title.textAlignment = .center
        title.layer.shadowColor = UIColor.black.cgColor
        title.layer.shadowOffset = .zero
        title.layer.shadowRadius = 8
        for sub in [platter, title, icon] as [UIView] { addSubview(sub) }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { available }

    var width: CGFloat { icon.image == nil ? title.intrinsicContentSize.width + Self.padding * 2 : Self.height }

    override func layoutSubviews() {
        super.layoutSubviews()
        platter.frame = bounds
        platter.layer.cornerRadius = bounds.height / 2
        title.frame = bounds
        icon.frame = bounds
        glass?.frame = bounds
        platter.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard action != nil, presses.contains(where: { $0.type == .select }) else {
            return super.pressesBegan(presses, with: event)
        }
        setPressed(true)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let action, presses.contains(where: { $0.type == .select }) else {
            return super.pressesEnded(presses, with: event)
        }
        setPressed(false)
        action()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        setPressed(false)
        super.pressesCancelled(presses, with: event)
    }

    private func setPressed(_ down: Bool) {
        pressed = down
        focusChange { self.paint() }
    }

    private func paint() {
        title.textColor = isFocused ? UIColor.black.withAlphaComponent(0.85)
            : UIColor.white.withAlphaComponent(chosen || glass != nil ? FixedFocusText.primary : FixedFocusText.body)
        icon.tintColor = title.textColor
        title.layer.shadowOpacity = isFocused ? 0 : 0.8
        icon.layer.shadowOpacity = title.layer.shadowOpacity
        platter.alpha = isFocused ? 1 : chosen && marksChosen && glass == nil ? Self.chosenFill : 0
        let scale: CGFloat = isFocused ? (pressed ? 0.97 : 1.05) : 1
        transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        focusChange(duration: 0.2) { self.paint() }
    }
}

/// From the bottom: tabs, plain words, over a page of glass. The tab follows
/// the focus; one height for every page, so a switch moves nothing.
class PlayerSheet: UIView {
    enum Place { case away, peek, open }

    fileprivate static let inset: CGFloat = 28
    /// How much lower the controls, its peek and a prompt rest with the controls gone.
    fileprivate static let drop: CGFloat = 24
    private static let tabsGap: CGFloat = 24
    /// The tabs and the gap under them; the page starts past the screen's edge.
    fileprivate static let tabRow = PanelTab.height + tabsGap
    fileprivate static let tabSpacing: CGFloat = 8

    private let clip = UIView()
    fileprivate let glass: GlassBacking
    fileprivate let tabRow = UIView()
    private var tabs: [PanelTab]
    /// Tabs that unfold from one (Sources into its add-ons) while one of them
    /// is chosen, in its place; they share its page.
    private var fold: (tab: Int, extras: Range<Int>)?
    /// Where focus goes on the folded tab: the last one chosen.
    private var lastExtra: Int?
    /// Unfolded as the sheet closed: it folds, and opens unfolded on this one.
    private var heldExtra: String?
    /// The stage's: the fold is all there is, unfolded for good, nothing before it.
    fileprivate var foldOnly = false
    private var unfolded: Bool { foldOnly || fold?.extras.contains(current) == true }
    /// On the folded tab or one it unfolded into, open: Refresh and when the
    /// links were found come out after them.
    private var inFold: Bool {
        place == .open && (fold.map { $0.tab == current || $0.extras.contains(current) } ?? false)
    }
    fileprivate let again = PanelTab.refresh()
    fileprivate let found = PlayerSheet.foundLabel()
    fileprivate static let foundGap: CGFloat = 16
    /// Unfolded, they stand a little apart from the tabs before them.
    private static let foldGap: CGFloat = 32
    /// Refresh's distance from the last of them.
    fileprivate static let refreshGap: CGFloat = 16

    /// When the links in hand were found, beside Refresh: body level, the tabs' shadow.
    fileprivate static func foundLabel() -> UILabel {
        let found = UILabel()
        found.font = .systemFont(ofSize: 24, weight: .medium)
        found.textColor = UIColor.white.withAlphaComponent(FixedFocusText.body)
        found.layer.shadowColor = UIColor.black.cgColor
        found.layer.shadowOffset = .zero
        found.layer.shadowRadius = 8
        found.layer.shadowOpacity = 0.8
        return found
    }

    /// When the links in hand were found, beside Refresh.
    var foundAt: Date? {
        didSet { showFound() }
    }

    /// Refresh's arrow turning and "Searching" while the add-ons are asked again.
    var searching = false {
        didSet {
            again.busy = searching
            showFound()
            // Done: the cards say so.
            if oldValue, !searching, let row = linksRow, !row.isHidden {
                row.layoutIfNeeded()
                FixedFocusMotion.pulse(row.visibleCells)
            }
        }
    }

    /// The links' row: it pulses when a search ends.
    fileprivate var linksRow: ShelfRow?
    private var clock: Timer?

    fileprivate func showFound() { found.text = Self.foundText(searching: searching, at: foundAt) }

    /// New links swap in one fade; the same links stay put.
    fileprivate func swapLinks(_ change: () -> Void) {
        guard let row = linksRow, !row.isHidden, let page = row.superview,
              let before = row.snapshotView(afterScreenUpdates: false) else { return change() }
        change()
        before.frame = row.frame
        before.alpha = row.alpha
        page.insertSubview(before, aboveSubview: row)
        UIView.animate(withDuration: Motion.fadeDuration, delay: 0, options: [.curveEaseInOut]) {
            before.alpha = 0
        } completion: { _ in before.removeFromSuperview() }
    }

    fileprivate static func foundText(searching: Bool, at foundAt: Date?) -> String? {
        if searching { return "Searching" }
        guard let foundAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(foundAt) / 60)
        return minutes < 1 ? "Found just now" : "Found \(minutes) min ago"
    }
    /// One per tab; two tabs may share one.
    fileprivate var pages: [UIView] = []
    /// In the gap under the tabs: Down lands on the page's preferred row, not
    /// the nearest, and Up reaches a tab from anywhere along it.
    private let guide = UIFocusGuide()
    /// Past the links' first and last card: on to the add-on before or after.
    private let sides = [UIFocusGuide(), UIFocusGuide()]
    /// Where the next add-on's page lands: its first card going right, its
    /// last going left. The pages read it as their page opens.
    fileprivate enum Landing { case first, last }
    fileprivate var landing: Landing?
    /// Focus asked for once, past the tabs' own preference.
    fileprivate var focusTarget: UIFocusEnvironment?
    private(set) var current = 0
    private(set) var place = Place.away
    private var reachedEdge = Date.distantPast

    private var onTabs: Bool { tabs.contains(where: \.isFocused) || again.isFocused }

    init(tabs titles: [String], height: CGFloat) {
        let radius = FixedFocusMetrics.panelRadius
        glass = GlassBacking(RoundedRectangle(cornerRadius: radius, style: .continuous))
        tabs = titles.map(PanelTab.init)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height))
        isHidden = true
        isUserInteractionEnabled = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = radius
        clip.layer.cornerCurve = .continuous
        addSubview(glass)
        addSubview(clip)
        addSubview(tabRow)
        for tab in tabs + [again] { tabRow.addSubview(tab) }
        again.alpha = 0
        again.available = false
        found.alpha = 0
        tabRow.addSubview(found)
        tabRow.transform = rowTransform(for: place)
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor, constant: PanelTab.height),
            guide.heightAnchor.constraint(equalToConstant: Self.tabsGap)
        ])
        for (index, side) in sides.enumerated() {
            side.isEnabled = false
            addLayoutGuide(side)
            NSLayoutConstraint.activate([
                index == 0 ? side.leadingAnchor.constraint(equalTo: leadingAnchor)
                           : side.trailingAnchor.constraint(equalTo: trailingAnchor),
                side.widthAnchor.constraint(equalToConstant: 8),
                side.topAnchor.constraint(equalTo: topAnchor, constant: Self.tabRow),
                side.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    fileprivate func add(pages new: [UIView]) {
        pages = new
        for page in Set(new) { clip.addSubview(page) }
        showTab()
    }

    /// Where the page goes: under the tabs, to the sheet's foot.
    fileprivate var pageFrame: CGRect {
        CGRect(x: Self.inset, y: Self.inset, width: bounds.width - Self.inset * 2,
               height: bounds.height - Self.tabRow - Self.inset * 2)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { focusTarget.map { [$0] } ?? [tabs[current]] }

    /// The add-on `step` away from the chosen one, among those unfolded.
    private func neighbour(_ step: Int) -> Int? {
        guard unfolded, let fold, fold.extras.contains(current + step) else { return nil }
        return current + step
    }

    /// Only Left and Right out of the links' row reach the sides: there they
    /// stop, and the next add-on's page opens with focus on its near card.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard let row = linksRow, context.previouslyFocusedView?.isDescendant(of: row) == true,
              !(context.nextFocusedView?.isDescendant(of: row) ?? false),
              context.focusHeading.contains(.left) || context.focusHeading.contains(.right),
              let next = neighbour(context.focusHeading.contains(.right) ? 1 : -1)
        else { return super.shouldUpdateFocus(in: context) }
        let going = context.focusHeading.contains(.right) ? Landing.first : .last
        DispatchQueue.main.async { [self] in
            slideLinks(going == .first ? 1 : -1) {
                landing = going
                // The tabs' pills cross over as the cards do.
                let fade = CATransition()
                fade.type = .fade
                fade.duration = Motion.moveDuration
                tabRow.layer.add(fade, forKey: "chosen")
                choose(next)
                focusTarget = row
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
                focusTarget = nil
                landing = nil
            }
        }
        return false
    }

    /// The cards going out toward the side being left, the new ones coming in
    /// from the other, a page's width, as one strip, on the move spring. Only the
    /// picture moves (the row itself stays put and whole, so focus lands).
    /// A press mid-way settles the last one first.
    private var leaving: UIView?
    private func slideLinks(_ direction: CGFloat, _ change: () -> Void) {
        guard let row = linksRow, !row.isHidden, let page = row.superview else { return change() }
        leaving?.removeFromSuperview()
        row.layer.removeAnimation(forKey: "slide")
        // What shows, to the glass's edge: the cards the row holds past it
        // would otherwise sweep over the new ones.
        let reach = ShelfRow.over - Self.inset
        let seen = CGRect(x: row.bounds.minX + reach, y: row.bounds.minY,
                          width: row.bounds.width - reach * 2, height: row.bounds.height)
        guard let before = row.resizableSnapshotView(from: seen, afterScreenUpdates: false, withCapInsets: .zero)
        else { return change() }
        change()
        row.layoutIfNeeded()
        before.frame = CGRect(x: row.frame.minX + reach, y: row.frame.minY, width: seen.width, height: seen.height)
        page.insertSubview(before, aboveSubview: row)
        leaving = before
        let move = { (layer: CALayer, from: CGFloat, to: CGFloat) in
            let spring = CASpringAnimation(perceptualDuration: Motion.moveDuration, bounce: 0)
            spring.keyPath = "transform.translation.x"
            spring.fromValue = from
            spring.toValue = to
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            layer.add(spring, forKey: "slide")
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak before] in
            before?.removeFromSuperview()
            // Only the latest slide clears the row: an earlier one's end mustn't cut it.
            guard let self, self.leaving === before else { return }
            self.leaving = nil
            row.layer.removeAnimation(forKey: "slide")
        }
        // The page's width plus a gap, so the strip reads as one.
        let distance = page.bounds.width + ShelfRow.gap
        move(before.layer, 0, -direction * distance)
        move(row.layer, direction * distance, 0)
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The sides only while focus is on a link with an add-on beside its own.
    private func aimSides() {
        let onLinks = linksRow.map { row in (UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView)?.isDescendant(of: row) == true } ?? false
        for (index, side) in sides.enumerated() {
            side.isEnabled = onLinks && neighbour(index == 0 ? -1 : 1) != nil
            side.preferredFocusEnvironments = [tabs[current]]
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let panel = bounds.inset(by: UIEdgeInsets(top: Self.tabRow, left: 0, bottom: 0, right: 0))
        tabRow.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: PanelTab.height)
        tabRow.center = CGPoint(x: bounds.midX, y: PanelTab.height / 2)
        glass.frame = panel
        clip.frame = panel
        var x: CGFloat = 0
        for (index, tab) in tabs.enumerated() where !tab.isHidden && fold?.extras.contains(index) != true {
            tab.frame = CGRect(x: x, y: 0, width: tab.width, height: PanelTab.height)
            guard let fold, index == fold.tab else {
                x += tab.width + Self.tabSpacing
                continue
            }
            // Folded, they wait in its place, so they unfold from it.
            let start = x
            x += foldOnly ? 0 : unfolded ? Self.foldGap : tab.width + Self.tabSpacing
            for extra in fold.extras {
                let width = tabs[extra].width
                tabs[extra].frame = CGRect(x: unfolded ? x : start, y: 0, width: width, height: PanelTab.height)
                if unfolded { x += width + Self.tabSpacing }
            }
            let end = !inFold || fold.extras.isEmpty ? start : x - Self.tabSpacing + Self.refreshGap
            again.frame = CGRect(x: end, y: 0, width: PanelTab.height, height: PanelTab.height)
            let after = end + PanelTab.height + Self.foundGap
            found.frame = CGRect(x: after, y: 0, width: max(bounds.width - after, 0), height: PanelTab.height)
            x = end + PanelTab.height + Self.tabSpacing
        }
        for page in pages {
            page.frame = page is ShelfRow ? pageFrame.insetBy(dx: -ShelfRow.over, dy: 0) : pageFrame
        }
    }

    /// One tab unfolds into these; `preferred` is where it opens.
    fileprivate func setFold(_ tab: Int, into titles: [String], preferred: Int?) {
        let old = fold.map { tabs[$0.extras].map(\.text) } ?? []
        if old != titles {
            let chosen = unfolded ? tabs[current].text : nil
            if let fold {
                for extra in tabs[fold.extras] { extra.removeFromSuperview() }
                tabs.removeSubrange(fold.extras)
                pages.removeSubrange(fold.extras)
            }
            let start = tabs.count
            for title in titles {
                let extra = PanelTab(title)
                tabRow.insertSubview(extra, belowSubview: again)
                tabs.append(extra)
                pages.append(pages[tab])
            }
            fold = (tab, start..<tabs.count)
            if current >= tabs.count || (chosen != nil && titles.isEmpty) { current = tab }
            if let chosen, let fold, let same = tabs[fold.extras].firstIndex(where: { $0.text == chosen }) {
                current = same
            }
        }
        lastExtra = fold.flatMap { fold in
            fold.extras.isEmpty ? nil : preferred.map { fold.extras.lowerBound + $0 } ?? fold.extras.lowerBound
        }
        // Nothing to fold back to: on the first add-on as it comes.
        if foldOnly, current == tab, let lastExtra { current = lastExtra }
        showFold()
        showTab()
        setNeedsLayout()
    }

    /// The add-on behind a tab of the fold, by its place in it.
    fileprivate func extra(_ index: Int) -> Int? {
        guard let fold, fold.extras.contains(index) else { return nil }
        return index - fold.extras.lowerBound
    }

    private func showFold() {
        guard let fold else { return }
        again.alpha = inFold ? 1 : 0
        again.available = inFold
        found.alpha = again.alpha
        tabs[fold.tab].alpha = unfolded ? 0 : 1
        tabs[fold.tab].available = !unfolded
        for extra in fold.extras {
            tabs[extra].alpha = unfolded ? 1 : 0
            tabs[extra].available = unfolded
        }
    }

    fileprivate func setTabHidden(_ index: Int, _ hidden: Bool) {
        tabs[index].isHidden = hidden
        if hidden, current == index, let other = tabs.firstIndex(where: { !$0.isHidden }) { choose(other) }
        setNeedsLayout()
    }

    fileprivate func choose(_ index: Int) {
        let was = (unfolded, inFold)
        current = index
        if unfolded { lastExtra = index }
        if was != (unfolded, inFold) {
            showFound()
            showFoldMoving()
        }
        showTab()
    }

    private func showFoldMoving() {
        UIView.animate(withDuration: Motion.focusDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve]) {
            self.showFold()
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// Gone, its tabs up the bottom edge with the controls, or open. The peek
    /// fades and moves a little as they do.
    func move(to new: Place) {
        guard new != place else { return }
        if new == .open {
            pageWillOpen()
            // The minutes go on while it's open.
            clock?.invalidate()
            clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.place == .open else { return timer.invalidate() }
                    self.showFound()
                }
            }
            // Focus lands on the folded tab and passes on to it, unfolding.
            if let held = heldExtra, let fold, let index = tabs[fold.extras].firstIndex(where: { $0.text == held }) {
                lastExtra = index
            }
            heldExtra = nil
            showTab()
        } else if place == .open, unfolded, let fold {
            // Folded as it goes; the page keeps its links until it's gone.
            heldExtra = tabs[current].text
            lastExtra = current
            current = fold.tab
            place = new
            for (index, tab) in tabs.enumerated() { tab.chosen = index == current }
            showFound()
            showFoldMoving()
            aimGuide()
        }
        if isHidden {
            pageWillPeek()
            isHidden = false
            alpha = 0
            transform = transform(for: .away)
        }
        place = new
        isUserInteractionEnabled = new == .open
        for tab in tabs { tab.marksChosen = new == .open }
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.transform = self.transform(for: new)
            self.tabRow.transform = self.rowTransform(for: new)
        }
        UIView.animate(withDuration: Motion.fadeDuration) {
            self.alpha = new == .away ? 0 : 1
        } completion: { _ in
            if self.place == .away { self.isHidden = true }
        }
    }

    private func transform(for place: Place) -> CGAffineTransform {
        let page = superview?.bounds.height ?? 0
        let top = center.y - bounds.height / 2
        switch place {
        case .open: return .identity
        case .peek: return CGAffineTransform(translationX: 0, y: page - Self.tabRow - top)
        case .away: return CGAffineTransform(translationX: 0, y: page - Self.tabRow - top + Self.drop)
        }
    }

    /// Peeking, the words line up with the bar; open, the pills with the page.
    private func rowTransform(for place: Place) -> CGAffineTransform {
        place == .open ? .identity : CGAffineTransform(translationX: -PanelTab.padding, y: 0)
    }

    /// How far it rises from the peek when it opens.
    var rise: CGFloat { transform(for: .peek).ty }

    /// Up from the tabs leaves it. A press that climbed to them reaches the
    /// controller after the focus has moved, so it has to have rested there.
    var closes: Bool { onTabs && Date().timeIntervalSince(reachedEdge) > 0.2 }

    /// The page as it opens or its tab comes up.
    fileprivate func showPage(_ index: Int) {}
    fileprivate func pageWillPeek() {}
    fileprivate func pageWillOpen() {}
    fileprivate func pageTakesFocus(_ index: Int) -> Bool { true }
    fileprivate var pageFocus: UIFocusEnvironment { pages[current] }

    private func showTab() {
        for (index, tab) in tabs.enumerated() { tab.chosen = index == current }
        for page in pages { page.isHidden = page !== pages[current] }
        showPage(current)
        aimGuide()
    }

    private func aimGuide() {
        guide.isEnabled = pageTakesFocus(current) || !onTabs
        guide.preferredFocusEnvironments = onTabs ? [pageFocus] : [tabs[current]]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if (context.nextFocusedView is PanelTab) != (context.previouslyFocusedView is PanelTab) { reachedEdge = Date() }
        if let tab = context.nextFocusedView as? PanelTab, let fold, !fold.extras.isEmpty, tab === tabs[fold.tab] {
            // The folded tab passes its focus on to the one it unfolds into.
            choose(lastExtra ?? fold.extras.lowerBound)
            DispatchQueue.main.async {
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        } else if let tab = context.nextFocusedView as? PanelTab, let index = tabs.firstIndex(of: tab), index != current {
            choose(index)
        } else {
            aimGuide()
        }
        aimSides()
    }
}

/// One line of text. Too long for its place it runs: a rest, then round through
/// a second copy in the same label, back where it began.
final class RunningLine: UIView {
    private static let gap = "          "
    private static let speed: Double = 60
    private static let edge: CGFloat = 40

    private let font: UIFont
    private let rest: CFTimeInterval
    private let value = UILabel()
    private let edgeMask = CAGradientLayer()
    private var fittedWidth: CGFloat = 0
    private var shift: CGFloat = 0

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            fittedWidth = 0
            setNeedsLayout()
        }
    }

    var color: UIColor? {
        get { value.textColor }
        set { value.textColor = newValue }
    }

    /// Set again, it starts over, so it opens readable.
    var running = true {
        didSet { run() }
    }

    init(font: UIFont, rest: CFTimeInterval = 3) {
        self.font = font
        self.rest = rest
        super.init(frame: .zero)
        value.font = font
        clipsToBounds = true
        addSubview(value)
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != fittedWidth else { return }
        fittedWidth = bounds.width
        fit()
        run()
    }

    private func fit() {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let long = width > fittedWidth
        let once = text + Self.gap
        shift = long ? (once as NSString).size(withAttributes: [.font: font]).width : 0
        value.text = long ? once + text : text
        value.sizeToFit()
        value.frame.origin = CGPoint(x: 0, y: (bounds.height - value.bounds.height) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        edgeMask.locations = [0, NSNumber(value: Double(1 - Self.edge / max(fittedWidth, 1))), 1]
        CATransaction.commit()
        layer.mask = long ? edgeMask : nil
    }

    private func run() {
        value.layer.removeAnimation(forKey: "run")
        guard running, shift > 0 else { return }
        let moving = Double(shift) / Self.speed
        let total = rest + moving
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -shift]
        animation.keyTimes = [0, NSNumber(value: rest / total), 1]
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        value.layer.add(animation, forKey: "run")
    }
}

/// What's really going out, in two columns.
private final class DetailsPage: UIView {
    struct Fact: Equatable {
        let label: String
        let value: String
    }

    /// One fact.
    private final class Row: UIView {
        private static let labelWidth: CGFloat = 170
        fileprivate static let font = UIFont.systemFont(ofSize: 24)

        private let name = UILabel()
        private let value = RunningLine(font: font)
        private var fact = Fact(label: "", value: "")

        override init(frame: CGRect) {
            super.init(frame: frame)
            name.font = Self.font
            name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
            value.color = UIColor.white.withAlphaComponent(FixedFocusText.primary)
            addSubview(name)
            addSubview(value)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func set(_ new: Fact) {
            guard new != fact else { return }
            fact = new
            name.text = new.label
            value.text = new.value
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            name.frame = CGRect(x: 0, y: 0, width: Self.labelWidth, height: bounds.height)
            value.frame = CGRect(x: Self.labelWidth, y: 0, width: bounds.width - Self.labelWidth, height: bounds.height)
        }

        func setRunning(_ running: Bool) { value.running = running }
    }

    private var rows: [Row] = []

    override func layoutSubviews() {
        super.layoutSubviews()
        let column = (bounds.width - 40) / 2
        // As the other tabs' cards: the first line's capitals level with the
        // cards' tops, the longer column's last baseline with their caption's.
        let font = Row.font
        let lines = max(leftCount, rows.count - leftCount)
        let pitch = (PlayerShelf.cardRow - font.capHeight) / CGFloat(max(lines - 1, 1))
        let capTop = (pitch - font.lineHeight) / 2 + font.ascender - font.capHeight
        let top = ShelfShape.rowInsets.top - capTop
        for (index, row) in rows.enumerated() {
            let left = index < leftCount
            row.frame = CGRect(x: left ? ShelfShape.rowInsets.left : bounds.midX + 20,
                               y: top + CGFloat(left ? index : index - leftCount) * pitch,
                               width: column, height: pitch)
        }
    }

    private var leftCount = 0

    /// The file on the left, what plays on the right.
    func show(left: [Fact], right: [Fact]) {
        let new = left + right
        leftCount = left.count
        while rows.count < new.count {
            let row = Row()
            rows.append(row)
            addSubview(row)
        }
        while rows.count > new.count { rows.removeLast().removeFromSuperview() }
        for (row, fact) in zip(rows, new) { row.set(fact) }
        setNeedsLayout()
    }

    func startRunning() {
        layoutIfNeeded()
        rows.forEach { $0.setRunning(true) }
    }

    func stopRunning() { rows.forEach { $0.setRunning(false) } }
}

/// Settings → Appearance → Source Cards.
/// The source cards' colour: the title's picture's dominant one (the stage's
/// picture, so every card of a list shares it), always dark enough for the
/// text. Grey pictures get a quiet slate.
enum SourceTint {
    private static let tints = NSCache<NSString, UIColor>()
    private static let sampleBudget: CGFloat = 200
    static let plain = UIColor(hue: 0.58, saturation: 0.15, brightness: 0.3, alpha: 1)

    /// The picture the colour comes from.
    @MainActor static var art: String? { PlayStage.shared.scene?.art }

    static func cached(for url: String?) -> UIColor? {
        url.flatMap { tints.object(forKey: $0 as NSString) }
    }

    static func tint(for url: String) async -> UIColor {
        if let hit = cached(for: url) { return hit }
        var image = await ImageCache.shared.diskImage(for: url, budget: sampleBudget)
        if image == nil, let remote = URL(string: url),
           let data = try? await ImageCache.shared.download(remote) {
            ImageCache.shared.insertData(data, for: url)
            image = ImageCache.decodeDownsampled(data, budget: sampleBudget)
        }
        guard let cg = image?.cgImage else { return plain }
        let tint = await Task.detached(priority: .userInitiated) { sample(cg) }.value
        tints.setObject(tint, forKey: url as NSString)
        return tint
    }

    /// The hue that weighs most, by how colourful and bright its pixels are,
    /// as the mean of those pixels.
    private static func sample(_ image: CGImage) -> UIColor {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bins = [(weight: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        for start in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[start]) / 255, green = CGFloat(pixels[start + 1]) / 255
            let blue = CGFloat(pixels[start + 2]) / 255
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.12, brightness > 0.1 else { continue }
            let weight = saturation * brightness
            let bin = min(Int(hue * 12), 11)
            bins[bin].weight += weight
            bins[bin].red += red * weight
            bins[bin].green += green * weight
            bins[bin].blue += blue * weight
        }
        guard let top = bins.max(by: { $0.weight < $1.weight }), top.weight > 0 else { return plain }
        var hue: CGFloat = 0, saturation: CGFloat = 0
        UIColor(red: top.red / top.weight, green: top.green / top.weight, blue: top.blue / top.weight, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
        return UIColor(hue: hue, saturation: min(max(saturation, 0.3), 0.6), brightness: 0.32, alpha: 1)
    }

    /// The text's ink: the card's hue, barely, near white, so the words read
    /// as printed on the card rather than laid over it.
    static func ink(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
        return UIColor(hue: hue, saturation: min(saturation, inkSaturation), brightness: 1, alpha: alpha)
    }
    private static let inkSaturation: CGFloat = 0.14

    /// The colour at another brightness, for rest, playing and focus.
    static func shade(_ color: UIColor, _ brightness: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}

enum SourceCardStyle: String, CaseIterable {
    case styled, raw

    static let key = "cue.appearance.sourceCards"
    static var current: Self { UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .styled }

    var label: String { self == .styled ? "Styled" : "Raw" }
}

/// What's playing, as Music's: three thin bars rising and falling, each at its
/// own slow pace, so they never read as the loading dots.
private final class PlayingBars: UIView {
    static let size = CGSize(width: 16, height: 16)
    private let bars = (0..<3).map { _ in CALayer() }
    private static let barWidth: CGFloat = 3
    private static let paces: [CFTimeInterval] = [0.9, 1.25, 0.75]
    private static let lows: [CGFloat] = [0.3, 0.45, 0.25]

    var colour: UIColor = .white {
        didSet { bars.forEach { $0.backgroundColor = colour.cgColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        bars.forEach { layer.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = (bounds.width - Self.barWidth * 3) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + gap) + Self.barWidth / 2, y: bounds.height)
            bar.cornerRadius = Self.barWidth / 2
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        run()
    }

    override var isHidden: Bool { didSet { run() } }

    /// Running only while seen; started again after the app was away.
    func run() {
        guard window != nil, !isHidden else {
            bars.forEach { $0.removeAnimation(forKey: "rise") }
            return
        }
        for (index, bar) in bars.enumerated() where bar.animation(forKey: "rise") == nil {
            let rise = CABasicAnimation(keyPath: "transform.scale.y")
            rise.fromValue = Self.lows[index]
            rise.toValue = 1
            rise.duration = Self.paces[index]
            rise.autoreverses = true
            rise.repeatCount = .infinity
            rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            rise.timeOffset = Self.paces[index] * Double(index) * 0.6
            bar.add(rise, forKey: "rise")
        }
    }
}

/// The resolution on a source card, shaped as the billboard's `TitleBadge`,
/// larger: an off-white outline, the words dark on a plate of that colour.
private final class SourceBadge: UIView {
    let height: CGFloat = 44
    private static let padding: CGFloat = 15
    private let plate = UIView()
    private let label = UILabel()
    /// The outline and plate: the card's ink.
    var colour = UIColor(white: 1, alpha: FixedFocusText.primary) {
        didSet {
            layer.borderColor = colour.cgColor
            plate.backgroundColor = colour
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.borderColor = colour.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        plate.backgroundColor = colour
        plate.layer.cornerRadius = 6
        plate.layer.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 23, weight: .heavy)
        label.textColor = .black
        addSubview(plate)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var words: String? {
        didSet {
            label.text = words
            isHidden = words == nil
        }
    }

    func width(upTo limit: CGFloat) -> CGFloat {
        min(label.sizeThatFits(.zero).width + Self.padding * 2, limit)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds.insetBy(dx: 7, dy: 7)
        label.frame = bounds.insetBy(dx: Self.padding, dy: 0)
    }
}

/// One link, on the shelf and the stage, on the title's dominant colour:
/// dimmed at rest, less for what's playing; focused, lit and lifted.
/// Styled: every fact has one fixed place, and a place with nothing to show
/// stays clear, so a row can be scanned. Raw: the add-on's own text, its first
/// line large.
final class SourceCard: UICollectionViewCell {
    /// Styled: an episode card, the cell keeping its caption room so the tops line up.
    private static let face = PlayerShelf.card
    /// Raw: down to the episodes' caption baseline and 16:9, room for the
    /// add-on's text.
    static let rawFace = CGSize(width: FixedFocusMetrics.landscapeWidth(height: PlayerShelf.cardRow), height: PlayerShelf.cardRow)
    static var size: CGSize {
        SourceCardStyle.current == .raw ? rawFace : CGSize(width: face.width, height: PlayerShelf.cardRow)
    }
    private var faceSize: CGSize { isRaw ? Self.rawFace : Self.face }
    /// The episode card's growth in points: as a share, a wide card grows too far.
    private var lift: CGFloat { PlayerShelf.cardWidth * FixedFocusMetrics.movingFocusLift / faceSize.width }
    private static let inset: CGFloat = 28
    private static let lineGap: CGFloat = 6
    private static let footGap: CGFloat = 14
    private static let fadeHeight: CGFloat = 56
    /// A line of facts, at Details' size.
    private static let rowHeight: CGFloat = 30
    /// The rule's gap each side: to the language's baseline above, the foot's
    /// capitals below.
    private static let ruleGap: CGFloat = 18
    /// Room for the cached mark.
    private static let cachedRoom: CGFloat = 40
    /// The foot stops short of the score at its end.
    private static let scoreRoom: CGFloat = 110
    /// The resolution's widest, so quality keeps its room.
    private static let playingEnd: CGFloat = 140
    /// Raw's first line: leading the card, not shouting.
    private static let rawNameFont = UIFont.systemFont(ofSize: 26, weight: .semibold)
    /// Details' size.
    private static let detailFont = UIFont.systemFont(ofSize: 23)
    /// Raw's lines: the text's floor, add-ons' descriptions run long.
    private static let rawDetailFont = UIFont.systemFont(ofSize: 23)
    private static let footFont = UIFont.systemFont(ofSize: 23, weight: .semibold)
    private static let footKern: CGFloat = 3
    private static let nameFont = UIFont.systemFont(ofSize: 28, weight: .bold)
    /// The colour's brightness: dimmed at rest, less for what's playing, lit focused.
    private static let restLight: CGFloat = 0.24
    private static let playingLight: CGFloat = 0.3
    private static let focusLight: CGFloat = 0.4
    /// A link that didn't play: its words at about half.
    private static let failedDim: CGFloat = 0.5
    /// On the player's shelf: the colour at this, the glass showing through.
    private static let overFilmOpacity: CGFloat = 0.6

    private let card = UIView()
    private let shadow = UIView()
    /// Styled's places.
    private let styled = UIView()
    private let title = UILabel()
    private let resolution = SourceBadge()
    /// Size and bitrate.
    private let weight = UILabel()
    private let language = UILabel()
    /// Cached: a bolt (it starts at once); not cached: a dimmer hourglass;
    /// nothing where the add-on doesn't say.
    private let cached = UIImageView()
    private let video = UILabel()
    private let audio = UILabel()
    private let rule = UIView()
    private let score = UILabel()
    /// Raw's lines: one label a line with a gap between, so the add-on's breaks
    /// still read when one wraps. Lines past the card fade out.
    private let text = UIView()
    private let fade = CAGradientLayer()
    private var nameLines: [UILabel] = []
    private var detailLines: [UILabel] = []
    /// The foot's own line, kept clear of the add-on's text, however long.
    private let foot = UILabel()
    /// Playing, or Didn't play: Styled, under the card in its caption room;
    /// Raw, at the foot. Led by the bars, or the mark.
    private let playing = UILabel()
    private let bars = PlayingBars()
    private let mark = UIImageView(image: UIImage(systemName: "play.slash"))
    /// The note's size under the card: the episodes' caption.
    private static let captionFont = UIFont.systemFont(ofSize: FixedFocusMetrics.captionSize)
    private var isPlaying = false
    private var isRaw = false
    private var art: String?
    private var tint = SourceTint.plain
    private var footWords: String?
    private var cachedAlpha: CGFloat = 0.85
    private var overFilm = false
    /// Size and bitrate, rounded, their numbers apart from their units.
    private var weightParts: [(number: String, unit: String)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.isUserInteractionEnabled = false
        contentView.addSubview(shadow)
        FixedFocusRing.attachShadow(to: shadow)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        title.font = Self.nameFont
        for label in [weight, language, video, audio] { label.font = Self.detailFont }
        cached.contentMode = .right
        cached.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.detailFont)
        score.font = .systemFont(ofSize: 26, weight: .semibold)
        score.textAlignment = .right
        for sub in [title, resolution, weight, language, cached, video, audio, rule, score] as [UIView] {
            styled.addSubview(sub)
        }
        text.clipsToBounds = true
        fade.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        // A quiet note, not a label: the card's own brighter rest says it too.
        for sub in [styled, text, foot] as [UIView] { card.addSubview(sub) }
        mark.contentMode = .center
        applyFocus(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The foot's spaced capitals.
    private func footText(_ words: String, _ colour: UIColor) -> NSAttributedString {
        NSAttributedString(string: words.uppercased(), attributes: [
            .font: Self.footFont, .kern: Self.footKern, .foregroundColor: colour,
        ])
    }

    /// `failed`: tried and didn't play: set aside, still to pick (a link that
    /// timed out can work a minute later).
    /// `overFilm`: on the player's shelf, its glass coloured by the film: the
    /// card's colour lets that through a little.
    func show(_ entry: StreamEntry, playing isPlaying: Bool, failed: Bool = false, overFilm: Bool = false) {
        self.overFilm = overFilm
        isRaw = SourceCardStyle.current == .raw
        styled.isHidden = isRaw
        text.isHidden = !isRaw
        self.isPlaying = isPlaying
        setTint(SourceTint.art)
        playing.text = isPlaying ? "Playing" : "Didn't play"
        // Raw has no caption room: its note stays on the card.
        let host = isRaw ? card : contentView
        playing.font = isRaw ? Self.detailFont : Self.captionFont
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: playing.font)
        for sub in [playing, bars, mark] as [UIView] where sub.superview !== host { host.addSubview(sub) }
        playing.sizeToFit()
        playing.isHidden = !(isPlaying || failed)
        bars.isHidden = !isPlaying
        mark.isHidden = !failed || isPlaying
        styled.alpha = failed ? Self.failedDim : 1
        text.alpha = styled.alpha
        if isRaw {
            let words = (entry.displayName + "\n" + entry.displayDetail)
                .components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            nameLines = lines(words.first, into: nameLines, font: Self.rawNameFont)
            detailLines = lines(words.dropFirst().joined(separator: "\n"), into: detailLines, font: Self.rawDetailFont)
            footWords = nil
        } else {
            let found = entry.facts
            title.text = found.quality
            resolution.words = found.resolution
            weightParts = [found.size, found.bitrate].compactMap { $0.flatMap(Self.rounded) }
            language.text = found.language
            cached.image = found.cached.map { UIImage(systemName: $0 ? "bolt.fill" : "hourglass") } ?? nil
            cachedAlpha = found.cached == true ? 0.85 : 0.55
            video.text = found.video
            audio.text = found.audio
            // A score starts the add-on's first line, where there is one.
            let leading = entry.displayName.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespacesAndNewlines)
            score.text = leading.flatMap { Double($0) == nil ? nil : $0 }
            // AIOStreams gathers other add-ons: the one that found this link.
            let isGathered = entry.sourceAddonName.localizedCaseInsensitiveContains("aiostreams")
            let source = (isGathered ? found.gatheredFrom : nil) ?? entry.sourceAddonName
            let origin = found.origin.filter { $0.caseInsensitiveCompare(source) != .orderedSame }
            footWords = ([source] + origin).joined(separator: " · ")
        }
        applyFocus(isFocused)
        setNeedsLayout()
    }

    private func lines(_ words: String?, into old: [UILabel], font: UIFont) -> [UILabel] {
        let wanted = (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        var pool = old
        while pool.count > wanted.count { pool.removeLast().removeFromSuperview() }
        while pool.count < wanted.count {
            let line = UILabel()
            line.numberOfLines = 0
            line.lineBreakMode = .byWordWrapping
            text.addSubview(line)
            pool.append(line)
        }
        for (line, words) in zip(pool, wanted) {
            line.font = font
            line.text = words
        }
        return pool
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre: they may be grown (transformed).
        card.bounds = CGRect(origin: .zero, size: faceSize)
        card.center = CGPoint(x: bounds.midX, y: faceSize.height / 2)
        styled.frame = card.bounds
        shadow.center = card.center
        sizeShadow()
        let inner = card.bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let footHeight = ceil(Self.detailFont.lineHeight)
        let footY = inner.maxY - footHeight
        if isRaw {
            playing.frame.origin = CGPoint(x: inner.maxX - playing.bounds.width, y: footY)
            placeLead()
            foot.frame = .zero
            // The tabs name the add-on; the foot is only for Playing.
            layoutRaw(in: inner, bottom: playing.isHidden ? inner.maxY : footY - Self.footGap)
        } else {
            foot.frame = CGRect(x: inner.minX, y: footY, width: inner.width - Self.scoreRoom, height: footHeight)
            // As far from the foot's capitals as from the language's baseline.
            let capsTop = footY + (footHeight - Self.footFont.lineHeight) / 2 + Self.footFont.ascender - Self.footFont.capHeight
            rule.frame = CGRect(x: inner.minX, y: capsTop - Self.ruleGap - 2, width: inner.width, height: 2)
            score.frame = CGRect(x: inner.maxX - Self.scoreRoom, y: foot.frame.midY - 20, width: Self.scoreRoom, height: 40)
            layoutStyled(in: inner)
            placeNote()
        }
    }

    private func layoutStyled(in inner: CGRect) {
        let pill = resolution.width(upTo: Self.playingEnd)
        resolution.frame = CGRect(x: inner.maxX - pill, y: inner.minY, width: pill, height: resolution.height)
        // Quality and its size from the top; the rest stacked on the rule, the
        // room left between them.
        title.frame = CGRect(x: inner.minX, y: inner.minY - 2, width: inner.width - pill - 20,
                             height: ceil(Self.nameFont.lineHeight))
        weight.frame = CGRect(x: inner.minX, y: title.frame.maxY, width: inner.width, height: Self.rowHeight)
        let baseline = rule.frame.minY - Self.ruleGap
        let lastY = baseline - (Self.rowHeight - Self.detailFont.lineHeight) / 2 - Self.detailFont.ascender
        language.frame = CGRect(x: inner.minX, y: lastY, width: inner.width - Self.cachedRoom, height: Self.rowHeight)
        cached.frame = CGRect(x: inner.maxX - Self.cachedRoom, y: lastY, width: Self.cachedRoom, height: Self.rowHeight)
        audio.frame = CGRect(x: inner.minX, y: lastY - Self.rowHeight, width: inner.width, height: Self.rowHeight)
        video.frame = audio.frame.offsetBy(dx: 0, dy: -Self.rowHeight)
    }

    /// Styled: under the card as the episodes' caption, keeping its distance
    /// to the card at its focused size.
    private func placeNote() {
        let lead = PlayingBars.size.width + Self.leadGap
        let top = Self.face.height * (isFocused ? 1 + lift : 1) / 2 + card.center.y + FixedFocusMetrics.infoGap
        let left = card.center.x - Self.face.width / 2 + FixedFocusMetrics.textIndent
        playing.frame = CGRect(x: left + lead, y: top, width: playing.bounds.width, height: 30)
        placeLead()
    }
    private static let leadGap: CGFloat = 10

    /// The bars or the mark before the words, standing on their baseline.
    private func placeLead() {
        let font = playing.font!
        let baseline = playing.frame.minY + (playing.frame.height - font.lineHeight) / 2 + font.ascender
        let size = PlayingBars.size
        bars.frame = CGRect(x: playing.frame.minX - Self.leadGap - size.width, y: baseline - size.height,
                            width: size.width, height: size.height)
        mark.frame = CGRect(x: bars.frame.minX - 4, y: baseline - font.capHeight / 2 - 12, width: size.width + 8, height: 24)
    }

    private func layoutRaw(in inner: CGRect, bottom: CGFloat) {
        var y: CGFloat = 0
        for (index, line) in (nameLines + detailLines).enumerated() {
            if index > 0 { y += Self.lineGap }
            let height = ceil(line.sizeThatFits(CGSize(width: inner.width, height: .greatestFiniteMagnitude)).height)
            line.frame = CGRect(x: 0, y: y, width: inner.width, height: height)
            y += height
        }
        text.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: bottom - inner.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = text.bounds
        let from = (text.bounds.height - Self.fadeHeight) / max(text.bounds.height, 1)
        fade.locations = [NSNumber(value: Double(from)), 1]
        CATransaction.commit()
        text.layer.mask = y > text.bounds.height ? fade : nil
    }

    /// Sized, not scaled, as the focus ring.
    private func sizeShadow() {
        let size = faceSize
        shadow.bounds = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
    }

    private var scale: CGFloat = 1
    private var pressed = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(true) }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setPressed(false) }
        super.pressesCancelled(presses, with: event)
    }

    private func setPressed(_ new: Bool) {
        guard new != pressed else { return }
        pressed = new
        UIView.animate(withDuration: new ? 0.12 : 0.2, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.applyFocus(self.isFocused)
        }
    }

    private func setTint(_ new: String?) {
        guard new != art else { return }
        art = new
        tint = SourceTint.cached(for: new) ?? SourceTint.plain
        applyFocus(isFocused)
        guard SourceTint.cached(for: new) == nil, let new else { return }
        Task { @MainActor [weak self] in
            let found = await SourceTint.tint(for: new)
            guard let self, self.art == new else { return }
            self.tint = found
            UIView.animate(withDuration: Motion.fadeDuration) { self.applyFocus(self.isFocused) }
        }
    }

    /// Every word in the card's ink, at its level.
    private func applyInk() {
        let ink = { self.neutral == 0 ? SourceTint.ink(self.tint, $0) : UIColor(white: 1, alpha: $0) }
        nameLines.forEach { $0.textColor = ink(0.95) }
        detailLines.forEach { $0.textColor = ink(0.8) }
        title.textColor = ink(0.95)
        score.textColor = ink(0.95)
        [weight, language].forEach { $0.textColor = ink(0.85) }
        [video, audio].forEach { $0.textColor = ink(0.72) }
        cached.tintColor = ink(cachedAlpha)
        weight.attributedText = weightText(ink)
        rule.backgroundColor = ink(0.3)
        // Under the card: the caption's white, brighter focused.
        let caption = UIColor.white.withAlphaComponent(isFocused ? FixedFocusText.primary : FixedFocusText.secondary)
        playing.textColor = isRaw ? ink(0.55) : caption
        bars.colour = isRaw ? ink(0.7) : caption
        mark.tintColor = playing.textColor
        resolution.colour = ink(FixedFocusText.primary)
        foot.attributedText = footWords.map { footText($0, ink(0.7)) }
        let words = nameLines + detailLines + [title, score, weight, language, video, audio, foot] + (isRaw ? [playing] : [])
        words.forEach(Self.press)
        Self.pressDarkEdge(cached.layer)
        // Pressed into the card only where it's on it.
        for layer in [bars.layer, mark.layer] {
            if isRaw { Self.pressDarkEdge(layer) } else { layer.shadowOpacity = 0 }
        }
        if !isRaw { playing.shadowColor = nil }
    }

    /// "6.6 GB at 37 Mbps": the numbers at the line's level in equal-width
    /// digits, so they line up across the row; units and "at" a level down.
    private func weightText(_ ink: (CGFloat) -> UIColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let number: [NSAttributedString.Key: Any] = [.font: Self.weightFont, .foregroundColor: ink(0.85)]
        let quiet: [NSAttributedString.Key: Any] = [.font: Self.detailFont, .foregroundColor: ink(FixedFocusText.secondary)]
        for (index, part) in weightParts.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " at ", attributes: quiet)) }
            text.append(NSAttributedString(string: part.number, attributes: number))
            text.append(NSAttributedString(string: " " + part.unit, attributes: quiet))
        }
        return text
    }
    private static let weightFont = UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .regular)

    /// "6.56 GB" → 6.6 GB, "36.69 Mbps" → 37 Mbps: a decimal only under 10.
    private static func rounded(_ value: String) -> (number: String, unit: String)? {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let amount = Double(parts[0]) else { return nil }
        let number = amount < 10 && amount.rounded() != amount
            ? String(format: "%.1f", amount) : String(format: "%.0f", amount)
        return (number, parts[1])
    }

    /// Letterpress: the words pressed into the card, lit from above: a dark edge at the top of each letter, a faint light one below.
    private static func press(_ label: UILabel) {
        label.shadowColor = UIColor.white.withAlphaComponent(pressLight)
        label.shadowOffset = CGSize(width: 0, height: 1)
        pressDarkEdge(label.layer)
    }

    private static func pressDarkEdge(_ layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = pressDark
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowRadius = 0
    }
    private static let pressLight: CGFloat = 0.18
    private static let pressDark: Float = 0.45

    /// On the shelf, a neutral see-through card where Developer says so:
    /// black, darker at rest; white, a little more when focused.
    private var neutral: Int { overFilm ? PerformanceSettingsStore.shared.settings.shelfCardColour % 3 : 0 }

    private func cardColour(_ focused: Bool) -> UIColor {
        switch neutral {
        case 1: return UIColor(white: 0, alpha: focused ? 0.3 : isPlaying ? 0.45 : 0.55)
        case 2: return UIColor(white: 1, alpha: focused ? 0.24 : isPlaying ? 0.14 : 0.08)
        default:
            return SourceTint.shade(tint, focused ? Self.focusLight : isPlaying ? Self.playingLight : Self.restLight)
                .withAlphaComponent(overFilm ? Self.overFilmOpacity : 1)
        }
    }

    /// As `FixedFocusDestinationCell`: the same lift and shadow.
    private func applyFocus(_ focused: Bool) {
        applyInk()
        card.backgroundColor = cardColour(focused)
        scale = focused ? 1 + lift - (pressed ? 1 - FixedFocusMetrics.pressScale : 0) : 1
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        sizeShadow()
        shadow.alpha = focused ? 1 : 0
        if !isRaw { placeNote() }
        if focused { superview?.bringSubviewToFront(self) }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.applyFocus(focused)
        } completion: { _ in }
    }
}

/// A row of the shelf's cards, as Details' rows: their gap, and their way of
/// scrolling (`FixedFocusRowCell.windowOffset`): as many cards in full as fit,
/// once it has moved a sliver of the one before and after, moved on the move
/// spring as focus goes, never by the system.
class ShelfRow: UICollectionView {
    /// Details' gap, whatever the card's width.
    static let gap: CGFloat = 40
    /// The row reaches a card past the page on both sides (the widest, Raw's),
    /// so the cards leaving are still drawn as they slide under the glass's
    /// edge (a collection view drops cells outside its bounds).
    static let over = SourceCard.rawFace.width + gap

    init(item: CGSize) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = item
        layout.minimumLineSpacing = Self.gap
        var insets = ShelfShape.rowInsets
        insets.left += Self.over
        insets.right += Self.over
        layout.sectionInset = insets
        super.init(frame: .zero, collectionViewLayout: layout)
        backgroundColor = .clear
        // The focused card and its shadow reach past the row; the shelf clips.
        clipsToBounds = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        remembersLastFocusedIndexPath = false
        isScrollEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The first card shown in full.
    private var windowStart = 0

    /// Focus on `index`: the row follows.
    func follow(_ index: Int) {
        let offset = windowOffset(focusing: index)
        guard offset != contentOffset.x else { return }
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.contentOffset = CGPoint(x: offset, y: 0)
        } completion: { _ in }
    }

    /// `index` first in view, at once (opening on what plays).
    func show(_ index: Int) {
        windowStart = index
        layoutIfNeeded()
        contentOffset = CGPoint(x: windowOffset(focusing: index), y: 0)
    }

    private func windowOffset(focusing index: Int) -> CGFloat {
        let count = numberOfItems(inSection: 0)
        let card = (collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize.width ?? 0
        let gap = Self.gap
        let pitch = card + gap
        // The page's width, without the reach past it.
        let width = bounds.width - Self.over * 2
        let room = width - 2 * (gap + FixedFocusMetrics.destinationSliver)
        let shown = max(1, Int((room + gap) / pitch))
        if index < windowStart { windowStart = index }
        if index > windowStart + shown - 1 { windowStart = index - shown + 1 }
        windowStart = min(windowStart, max(0, count - shown))
        guard windowStart > 0 else { return 0 }
        let insets = ShelfShape.rowInsets
        let edge = (width - CGFloat(shown) * card - CGFloat(shown - 1) * gap) / 2
        let content = insets.left + insets.right + CGFloat(count) * pitch - gap
        return min(insets.left + CGFloat(windowStart) * pitch - edge, max(0, content - width))
    }
}

/// The shelf's measures, for the stage's: it has the same shelf for the links.
/// The stage's source list: the player's sheet, open, its Sources the whole
/// row of tabs (the add-ons, Refresh, when they were found) over the links.
final class StageSheet: PlayerSheet, UICollectionViewDataSource, UICollectionViewDelegate {
    var onPick: (StreamEntry) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onBack: () -> Void = {}

    private let row = ShelfRow(item: SourceCard.size)
    /// Links tried that didn't play (`rejectionKey`): marked, and focus
    /// starts past them.
    var failed: Set<String> = [] {
        didSet { if failed != oldValue { row.reloadData() } }
    }
    private var entries: [StreamEntry] = []
    private var addons: [String] = []
    private var shown: [StreamEntry] = []
    /// The card last on, else the first.
    private var preferred: UUID?
    /// Where focus starts, until the first link is in.
    private var waitsOnRefresh = true
    /// Focus has come in from the stage once.
    private var entered = false
    /// A card to focus once its add-on's page is in.
    private var pendingFocus = false

    init() {
        super.init(tabs: ["Sources"], height: PlayerShelf.height)
        foldOnly = true
        row.dataSource = self
        row.delegate = self
        row.register(SourceCard.self, forCellWithReuseIdentifier: "card")
        add(pages: [row])
        linksRow = row
        again.action = { [weak self] in self?.onRefresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, place != .open else { return }
        // Open from the start: the stage fades in as a whole. The add-ons may
        // be in already: their tabs again, open, so Refresh comes out with them.
        UIView.performWithoutAnimation {
            move(to: .open)
            setFold(0, into: addons, preferred: nil)
        }
    }

    /// The links as they come, into a shelf that's there from the start
    /// (glass, the add-ons' tabs, Refresh searching).
    func update(entries new: [StreamEntry], addons names: [String], loading: Bool, active: Bool) {
        row.isUserInteractionEnabled = active
        guard new.map(\.id) != entries.map(\.id) || names != addons else { return }
        let first = entries.isEmpty
        let change = {
            self.entries = new
            self.addons = names
            self.setFold(0, into: names, preferred: nil)
            self.showPage(self.current)
        }
        if first {
            change()
            // The first links fade in; only the picture, so focus can land
            // on them meanwhile.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = Motion.fadeDuration
            row.layer.add(fade, forKey: "fade")
        } else {
            swapLinks(change)
        }
        // The first link in: focus on it, once, unless focus is already on a
        // card; past the links that didn't play.
        if waitsOnRefresh, let link = new.first(where: { !failed.contains($0.rejectionKey) }) ?? new.first {
            waitsOnRefresh = false
            let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView
            if !(focused?.isDescendant(of: row) ?? false) { focus(on: link.id) }
        }
    }

    /// Focus on a link: the first as it comes, the one picked when Back returns.
    /// SwiftUI's host above refuses UIKit's focus requests, so the tabs are
    /// out of focus for a moment and focus falls to the row's preferred card.
    func focus(on id: UUID) {
        preferred = id
        DispatchQueue.main.async { [self] in
            // The add-ons' names can come after the links: their page first.
            guard let index = shown.firstIndex(where: { $0.id == id }) else {
                pendingFocus = true
                return
            }
            pendingFocus = false
            row.show(index)
            guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView,
                  focused.isDescendant(of: tabRow) else { return }
            tabRow.isUserInteractionEnabled = false
            setNeedsFocusUpdate()
            // Back once focus has left them (`didUpdateFocus`), or in any case soon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tabRow.isUserInteractionEnabled = true }
        }
    }

    /// Focus falls in from the stage where SwiftUI likes (a tab): on to the
    /// card it should be on.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if !tabRow.isUserInteractionEnabled, let next = context.nextFocusedView, !next.isDescendant(of: tabRow) {
            tabRow.isUserInteractionEnabled = true
        }
        guard !entered, let next = context.nextFocusedView, next.isDescendant(of: self) else { return }
        entered = true
        if !waitsOnRefresh, let id = shown.first(where: { $0.id == preferred })?.id ?? shown.first?.id ?? preferred {
            focus(on: id)
        }
    }

    /// Refresh first, while there's nothing else.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        focusTarget.map { [$0] } ?? (waitsOnRefresh || addons.isEmpty ? [again] : [row])
    }

    /// The chosen add-on's links, on the card last on, else from the start.
    override func showPage(_ index: Int) {
        let addon = extra(index).map { addons[$0] }
        shown = addon.map { addon in entries.filter { $0.addonName == addon } } ?? []
        if let landing { preferred = (landing == .first ? shown.first : shown.last)?.id }
        row.reloadData()
        row.show(shown.firstIndex { $0.id == preferred } ?? 0)
        // The link asked for, else this page's first (the first link can be another add-on's).
        if pendingFocus, let id = shown.first(where: { $0.id == preferred })?.id ?? shown.first?.id { focus(on: id) }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
        let entry = shown[indexPath.item]
        (cell as? SourceCard)?.show(entry, playing: false, failed: failed.contains(entry.rejectionKey))
        return cell
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        shown.isEmpty ? nil : IndexPath(item: shown.firstIndex { $0.id == preferred } ?? 0, section: 0)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let next = context.nextFocusedIndexPath else { return }
        preferred = shown[next.item].id
        row.follow(next.item)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick(shown[indexPath.item])
    }

    /// Back here never reaches SwiftUI's handler.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { onBack() } else { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !presses.contains(where: { $0.type == .menu }) { super.pressesEnded(presses, with: event) }
    }
}

enum ShelfShape {
    static let width: CGFloat = 1920 - 160
    /// Its top, tabs included; it ends `margin` above the screen's foot.
    static let top: CGFloat = 1080 - PlayerShelf.margin - PlayerShelf.height
    static let height = PlayerShelf.height
    static let rowInsets = PlayerShelf.rowInsets
}

/// Down: the stream's details, the show's episodes, as Home's cards, and the
/// links, in the add-ons' order. A film has no episodes. Opens on the tabs; a
/// page's focus starts on what's playing.
private final class PlayerShelf: PlayerSheet, UICollectionViewDataSource, UICollectionViewDelegate {
    struct Episode {
        let item: MetaItem
        let subtitle: String?
        let state: FixedFocusCardState
        let playing: Bool
        let pick: () -> Void
    }

    struct Source {
        let entry: StreamEntry
        let addon: String
        let playing: Bool
        let pick: () -> Void

        /// The same link, whoever's copy: refreshed entries are new values.
        var key: String {
            "\(entry.stream.url ?? entry.stream.infoHash ?? "")|\(entry.stream.title ?? "")|\(playing)"
        }
    }

    private enum Tab: Int { case details, episodes, sources }

    /// A little smaller than Details' episode cards (300 tall): three in full
    /// and the next one peeking, and once moved three with slivers.
    private static let cardHeight: CGFloat = 280
    fileprivate static let card = CGSize(width: FixedFocusMetrics.landscapeWidth(height: cardHeight), height: cardHeight)
    private static let growth: CGFloat = 15
    fileprivate static let rowInsets = UIEdgeInsets(top: growth, left: 8, bottom: growth, right: 8)
    fileprivate static let cardWidth = card.width
    /// A card and its one caption line (an episode's name), to the line's
    /// baseline: what shows, so it sits centred in the page.
    fileprivate static let cardRow = card.height + FixedFocusMetrics.infoGap + captionBaseline
    /// The caption's baseline below its line's top (`FixedFocusDestinationCell`:
    /// a 30 pt line, the text centred in it).
    private static let captionBaseline: CGFloat = {
        let font = UIFont.systemFont(ofSize: FixedFocusMetrics.captionSize)
        return ((30 - font.lineHeight) / 2 + font.ascender).rounded()
    }()
    static let height = PlayerSheet.tabRow + PlayerSheet.inset * 2 + cardRow + growth * 2
    /// Its foot above the screen's.
    static let margin: CGFloat = 30

    /// Filled as it opens: what's playing may have changed.
    var fill: () -> (episodes: [Episode], sources: [Source]) = { ([], []) }

    let details = DetailsPage()
    private let episodesRow = ShelfRow(item: CGSize(width: PlayerShelf.card.width, height: PlayerShelf.cardRow))
    private let sourcesRow = ShelfRow(item: SourceCard.size)
    private var episodes: [Episode] = []
    private var sources: [Source] = []
    /// The chosen add-on's: Sources unfolds into the add-ons.
    private var shown: [Source] = []
    private var addons: [String] = []

    init() {
        super.init(tabs: ["Details", "Episodes", "Sources"], height: Self.height)
        for row in [episodesRow, sourcesRow] {
            row.dataSource = self
            row.delegate = self
        }
        episodesRow.register(FixedFocusDestinationCell.self, forCellWithReuseIdentifier: "card")
        sourcesRow.register(SourceCard.self, forCellWithReuseIdentifier: "card")
        add(pages: [details, episodesRow, sourcesRow])
        linksRow = sourcesRow
    }

    override func pageTakesFocus(_ index: Int) -> Bool { index != Tab.details.rawValue }

    /// Its tabs show from here, so they have to be right.
    override func pageWillPeek() {
        let filled = fill()
        setTabHidden(Tab.episodes.rawValue, filled.episodes.isEmpty)
        unfold(filled.sources)
    }

    override func pageWillOpen() {
        (episodes, sources) = fill()
        setTabHidden(Tab.episodes.rawValue, episodes.isEmpty)
        unfold(sources)
        layoutIfNeeded()
        episodesRow.reloadData()
        episodesRow.show(episodes.firstIndex(where: \.playing) ?? 0)
    }

    /// Refresh's links, found while it's open: changed, the page swaps them in
    /// one fade; the same links stay put.
    func refreshSources() {
        let fresh = fill().sources
        guard fresh.map(\.key) != sources.map(\.key) else { return }
        swapLinks {
            sources = fresh
            unfold(sources)
        }
    }

    /// The add-ons in their order, opening on the one that's playing.
    private func unfold(_ sources: [Source]) {
        var seen = Set<String>()
        addons = sources.map(\.addon).filter { seen.insert($0).inserted }
        let playing = sources.first(where: \.playing).flatMap { addons.firstIndex(of: $0.addon) }
        setFold(Tab.sources.rawValue, into: addons, preferred: playing)
    }

    /// The links of the chosen add-on, on what's playing, else from the start.
    override func showPage(_ index: Int) {
        guard index == Tab.sources.rawValue || extra(index) != nil else { return }
        let addon = extra(index).map { addons[$0] }
        shown = addon.map { addon in sources.filter { $0.addon == addon } } ?? sources
        sourcesRow.reloadData()
        sourcesRow.show(landingIndex ?? shown.firstIndex(where: \.playing) ?? 0)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === episodesRow ? episodes.count : shown.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
        if let card = cell as? FixedFocusDestinationCell {
            let episode = episodes[indexPath.item]
            card.configure(episode.item, subtitle: episode.subtitle, index: indexPath.item, rowCell: nil,
                           card: Self.card, cardState: episode.state)
        } else if let card = cell as? SourceCard {
            let source = shown[indexPath.item]
            card.show(source.entry, playing: source.playing, overFilm: true)
        }
        return cell
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        (collectionView === episodesRow ? episodes.firstIndex(where: \.playing)
                                        : landingIndex ?? shown.firstIndex(where: \.playing))
            .map { IndexPath(item: $0, section: 0) }
    }

    /// From the add-on beside it: its near card.
    private var landingIndex: Int? {
        guard let landing, !shown.isEmpty else { return nil }
        return landing == .first ? 0 : shown.count - 1
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if let next = context.nextFocusedIndexPath { (collectionView as? ShelfRow)?.follow(next.item) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === episodesRow {
            episodes[indexPath.item].pick()
        } else {
            shown[indexPath.item].pick()
        }
    }
}

/// An ASS track, sorted: dialogue goes to `SubtitleText`, in Cue's one style;
/// whatever depends on its place or motion (signs, karaoke) stays as its authors
/// drew it, through libass, in a layer of its own.
private final class AssTrack {
    private struct Key: Hashable {
        let id: Int
        let start: Double
    }

    private struct Line {
        let runs: [SubtitleText.Run]
        let top: Bool
    }

    private struct Style {
        var italic = false
        var top = false
    }

    /// In an override block: placed, moved, clipped, turned, sheared, drawn, animated or karaoke.
    private static let signTags = "\\{[^}]*\\\\(pos|move|org|i?clip|fr[xyz]?-?[0-9.]|fa[xy]|t\\(|p[1-9]|k[fo]?[0-9]|K[0-9])[^}]*\\}"
    /// A style's name, for signs and songs that need no tag.
    private static let signStyles = ["sign", "song", "kara", "lyric", "romaji", "typeset", "title", "opening", "ending"]

    let trackID: Int
    private let builder: ASSScriptBuilder
    private let styles: [String: Style]
    private let fonts: [FontAttachment]
    private let host: UIView
    private let time: () -> Double
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("cue-ass-fonts", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var lines: [Key: [Line]] = [:]
    private var renderer: AssSubtitlesRenderer?
    private let picture = UIImageView()
    private var link: CADisplayLink?
    private var starting = false
    private var stopped = false
    private var dirty = false
    private var busy = false

    init(trackID: Int, header: String, fonts: [FontAttachment], host: UIView, time: @escaping () -> Double) {
        self.trackID = trackID
        self.fonts = fonts
        self.host = host
        self.time = time
        builder = ASSScriptBuilder(header: header)
        styles = Self.styles(in: header)
    }

    func stop() {
        stopped = true
        link?.invalidate()
        link = nil
        renderer = nil
        picture.removeFromSuperview()
        let folder = folder
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: folder) }
    }

    /// What's dialogue right now, at the bottom and at the top. Signs among
    /// new cues go to libass on the way.
    func dialogue(in cues: [SubtitleCue], at time: Double) -> (bottom: [SubtitleText.Run], top: [SubtitleText.Run]) {
        var bottom: [[SubtitleText.Run]] = []
        var top: [[SubtitleText.Run]] = []
        for cue in cues {
            let key = Key(id: cue.id, start: cue.startTime)
            let found = lines[key] ?? sort(cue)
            lines[key] = found
            guard cue.startTime <= time, time < cue.endTime else { continue }
            for line in found where !(bottom + top).contains(line.runs) {
                if line.top { top.append(line.runs) } else { bottom.append(line.runs) }
            }
        }
        if dirty { load() }
        return (SubtitleText.joined(bottom), SubtitleText.joined(top))
    }

    private func sort(_ cue: SubtitleCue) -> [Line] {
        guard case .text(let raw) = cue.body else { return [] }
        var out: [Line] = []
        for event in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let fields = event.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { continue }
            let name = fields[2].replacingOccurrences(of: "*", with: "")
            let text = String(fields[8])
            if Self.isSign(style: name, effect: fields[7], text: text) {
                if builder.add(rawEventText: String(event), start: cue.startTime, end: cue.endTime) { dirty = true }
            } else {
                let line = Self.dialogue(text, style: styles[name] ?? Style())
                if !line.runs.isEmpty { out.append(line) }
            }
        }
        return out
    }

    private static func isSign(style: String, effect: Substring, text: String) -> Bool {
        if !effect.isEmpty || text.range(of: signTags, options: .regularExpression) != nil { return true }
        let name = style.lowercased().replacingOccurrences(of: "subtitle", with: "")
        return name == "op" || name == "ed" || signStyles.contains { name.contains($0) }
    }

    /// The text without its tags, keeping what `SubtitleText` keeps: italics,
    /// and a line asking for the top.
    private static func dialogue(_ text: String, style: Style) -> Line {
        var italic = style.italic
        var top = style.top
        var runs: [SubtitleText.Run] = []
        func add(_ part: Substring) {
            let plain = part.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            if !plain.isEmpty { runs.append(.init(text: plain, italic: italic)) }
        }
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            add(rest[..<open])
            let tags = rest[open...close]
            if tags.contains("\\r") { italic = style.italic }
            if let flag = tags.range(of: "\\\\i[01]", options: .regularExpression) { italic = tags[flag].last == "1" }
            if let place = tags.range(of: "\\\\an[1-9]", options: .regularExpression) { top = tags[place].last! >= "7" }
            rest = rest[rest.index(after: close)...]
        }
        add(rest)
        return Line(runs: runs, top: top)
    }

    /// Italic and Alignment of each style, by the header's own Format line.
    private static func styles(in header: String) -> [String: Style] {
        var columns: [String] = []
        var out: [String: Style] = [:]
        for line in header.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Format:"), line.contains("Alignment") {
                columns = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("Style:") {
                let values = line.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                func value(_ name: String) -> String? {
                    columns.firstIndex(of: name).flatMap { $0 < values.count ? values[$0] : nil }
                }
                guard let name = value("Name") else { continue }
                out[name.replacingOccurrences(of: "*", with: "")] = Style(italic: value("Italic") == "-1",
                                                                          top: (value("Alignment").flatMap(Int.init) ?? 2) >= 7)
            }
        }
        return out
    }

    /// Only a track with signs pays for libass; the fonts go to disk off the
    /// main thread. The whole script again on each new sign: libass parses it
    /// in milliseconds, and the package has no way to add a line.
    private func load() {
        guard !starting, !busy, !stopped else { return }
        guard let renderer else {
            starting = true
            let (fonts, folder) = (fonts, folder)
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for font in fonts {
                    try? font.data.write(to: folder.appendingPathComponent((font.filename as NSString).lastPathComponent))
                }
                DispatchQueue.main.async { [weak self] in self?.start() }
            }
            return
        }
        dirty = false
        renderer.loadTrack(content: builder.script())
        draw()
    }

    private func start() {
        starting = false
        guard !stopped else { return }
        let renderer = AssSubtitlesRenderer(fontConfig: FontConfig(fontsPath: folder, fontProvider: .coreText))
        renderer.setCanvasSize(host.bounds.size, scale: UIScreen.main.scale)
        self.renderer = renderer
        host.insertSubview(picture, at: 0)
        let link = CADisplayLink(target: self, selector: #selector(draw))
        link.add(to: .main, forMode: .common)
        self.link = link
        load()
    }

    /// From the frame's completion, not the package's publisher: a load empties
    /// that first, and the sign on screen would blink.
    @objc private func draw() {
        guard !busy, let renderer else { return }
        busy = true
        renderer.loadFrame(offset: time()) { [weak self] frame in
            DispatchQueue.main.async { self?.show(frame) }
        }
    }

    private func show(_ frame: ProcessedImage?) {
        busy = false
        guard !stopped else { return }
        if picture.image?.cgImage !== frame?.image {
            picture.image = frame.map { UIImage(cgImage: $0.image) }
        }
        picture.frame = frame?.imageRect ?? .zero
    }
}

/// One setting of a subtitle's look, under Style: a few named options, the
/// viewer's own, kept across launches.
private protocol SubtitleChoice: AnyObject {
    var title: String { get }
    var names: [String] { get }
    var name: String { get set }
    var isStandard: Bool { get }
}

private final class SubtitleOption<Value>: SubtitleChoice {
    let title: String
    private let key: String
    private let options: [(name: String, value: Value)]
    private let standard: String

    init(_ title: String, key: String, standard: String, _ options: [(name: String, value: Value)]) {
        self.title = title
        self.key = "cue.subtitle." + key
        self.standard = standard
        self.options = options
    }

    var names: [String] { options.map(\.name) }

    var name: String {
        get {
            let saved = UserDefaults.standard.string(forKey: key)
            return names.contains { $0 == saved } ? saved ?? standard : standard
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var isStandard: Bool { name == standard }

    var value: Value {
        let name = name
        return options.first { $0.name == name }?.value ?? options[0].value
    }
}

/// A subtitle's text: a solid edge drawn under the fill so the letters keep
/// their weight, a bar behind each line if asked for. The colours are content,
/// not interface. Dialogue only: signs stay as drawn.
private final class SubtitleText: UIView {
    struct Run: Equatable {
        let text: String
        let italic: Bool
    }

    private static let face = SubtitleOption("Font", key: "font", standard: "SF Pro", [
        ("SF Pro", false), ("Inter", true)
    ])
    /// With Inter's name for each.
    private static let weight = SubtitleOption("Weight", key: "weight", standard: "Medium", [
        ("Regular", (UIFont.Weight.regular, "Regular")), ("Medium", (.medium, "Medium")),
        ("Semibold", (.semibold, "SemiBold")), ("Bold", (.bold, "Bold"))
    ])
    private static let size = SubtitleOption<CGFloat>("Size", key: "size", standard: "Medium", [
        ("Small", 40), ("Medium", 48), ("Large", 56), ("Largest", 64)
    ])
    private static let color = SubtitleOption("Colour", key: "color", standard: "Warm", [
        ("Pure", UIColor.white),
        ("Soft", UIColor(red: 242 / 255, green: 240 / 255, blue: 239 / 255, alpha: 1)),
        ("Warm", UIColor(red: 1, green: 249 / 255, blue: 230 / 255, alpha: 1))
    ])
    /// What shows of the edge: as much again is under the fill.
    private static let edge = SubtitleOption<CGFloat>("Outline", key: "outline", standard: "Thick", [
        ("Off", 0), ("Thin", 1.5), ("Medium", 2.5), ("Thick", 3.5), ("Heavy", 4)
    ])
    private static let edgeOpacity = SubtitleOption<CGFloat>("Outline Opacity", key: "outlineOpacity", standard: "Solid", [
        ("Light", 0.5), ("Medium", 0.75), ("Solid", 1)
    ])
    private static let background = SubtitleOption<CGFloat>("Background", key: "background", standard: "Off", [
        ("Off", 0), ("Light", 0.5), ("Medium", 0.65), ("Dark", 0.8)
    ])

    /// Style's page, in order; no opacity for an outline that's off.
    static var choices: [any SubtitleChoice] {
        [face, weight, size, color, edge] + (edge.value > 0 ? [edgeOpacity] : []) + [background]
    }

    static var isStandard: Bool {
        ([face, weight, size, color, edge, edgeOpacity, background] as [any SubtitleChoice]).allSatisfy(\.isStandard)
    }

    private static var font: UIFont {
        let (system, inter) = weight.value
        return face.value ? UIFont(name: "Inter-\(inter)", size: size.value) ?? .systemFont(ofSize: size.value, weight: system)
                          : .systemFont(ofSize: size.value, weight: system)
    }

    private static var hasBox: Bool { background.value > 0 }
    /// How far a bar reaches past its line: as much above the capitals as
    /// under the baseline, with room left for g, p and y.
    private static let boxTop: CGFloat = 2
    private static let boxBottom: CGFloat = 4
    private static let boxSide: CGFloat = 10
    /// What leaves 4 pt between two bars.
    private static let boxLineSpacing: CGFloat = 10
    private static let boxRadius: CGFloat = 10
    /// Room for the edge and an italic's overhang, and the box's padding.
    private static var inset: CGSize {
        let edged = edge.value + 2
        return hasBox ? CGSize(width: max(boxSide, edged), height: max(boxBottom + 2, edged)) : CGSize(width: edged, height: edged)
    }
    private static let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// Lines on screen together, each on its own.
    static func joined(_ lines: [[Run]]) -> [Run] {
        var out: [Run] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append(Run(text: "\n", italic: false)) }
            out += line
        }
        return out
    }

    private var runs: [Run] = []
    private var fill = NSAttributedString()
    private var outline = NSAttributedString()
    private(set) var fitted = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// False when it's what already shows.
    func show(_ new: [Run], within width: CGFloat) -> Bool {
        guard new != runs else { return false }
        runs = new
        isHidden = new.isEmpty
        render(within: width)
        return true
    }

    func render(within width: CGFloat) {
        fill = text(.foregroundColor, Self.color.value)
        let edged = NSMutableAttributedString(attributedString: fill)
        edged.addAttributes([.strokeColor: UIColor.black.withAlphaComponent(Self.edgeOpacity.value),
                             .strokeWidth: Self.edge.value * 2 / Self.font.pointSize * 100],
                            range: NSRange(location: 0, length: edged.length))
        outline = edged
        fitted = balanced(within: width)
        setNeedsDisplay()
    }

    private func text(_ key: NSAttributedString.Key, _ value: Any) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = Self.hasBox ? Self.boxLineSpacing : 0
        let upright = Self.font
        let out = NSMutableAttributedString()
        for run in runs {
            // With the upright's traits, or a bold line loses its weight.
            let slanted = upright.fontDescriptor.withSymbolicTraits(upright.fontDescriptor.symbolicTraits.union(.traitItalic))
                .map { UIFont(descriptor: $0, size: upright.pointSize) }
            out.append(NSAttributedString(string: run.text, attributes: [
                key: value, .paragraphStyle: paragraph, .font: run.italic ? slanted ?? upright : upright
            ]))
        }
        return out
    }

    /// The narrowest width with the same number of lines: a long line wraps
    /// into even ones, never one word alone.
    private func balanced(within width: CGFloat) -> CGSize {
        func measure(_ width: CGFloat) -> CGSize {
            fill.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                              options: Self.options, context: nil).size
        }
        let height = measure(width).height
        var (low, high) = (CGFloat(0), width)
        while high - low > 4 {
            let middle = (low + high) / 2
            if measure(middle).height > height { low = middle } else { high = middle }
        }
        let size = measure(high)
        return CGSize(width: ceil(size.width) + Self.inset.width * 2, height: ceil(size.height) + Self.inset.height * 2)
    }

    override func draw(_ rect: CGRect) {
        let area = bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if Self.hasBox {
            drawBox(in: area, context)
        } else {
            context.setLineJoin(.round)
            if Self.edge.value > 0 { outline.draw(with: area, options: Self.options, context: nil) }
            fill.draw(with: area, options: Self.options, context: nil)
        }
    }

    /// Through TextKit, so the bars and the text share one layout.
    private func drawBox(in area: CGRect, _ context: CGContext) {
        let storage = NSTextStorage(attributedString: fill)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: area.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        let string = fill.string as NSString
        var lines: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
            // Without the space a wrapped line ends on, or the bar leans right.
            var characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            while characters.length > 0, CharacterSet.whitespacesAndNewlines.contains(
                UnicodeScalar(string.character(at: NSMaxRange(characters) - 1)) ?? "x") {
                characters.length -= 1
            }
            guard characters.length > 0 else { return }
            let visible = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            lines.append(layout.boundingRect(forGlyphRange: visible, in: container)
                .offsetBy(dx: area.minX, dy: area.minY))
        }
        for line in lines {
            let bar = CGRect(x: line.minX - Self.boxSide, y: line.minY - Self.boxTop,
                             width: line.width + Self.boxSide * 2,
                             height: Self.font.lineHeight + Self.boxTop + Self.boxBottom)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: Self.boxRadius).cgPath)
        }
        context.setFillColor(UIColor.black.withAlphaComponent(Self.background.value).cgColor)
        context.fillPath()
        context.setLineJoin(.round)
        if Self.edge.value > 0 {
            storage.setAttributedString(outline)
            layout.drawGlyphs(forGlyphRange: glyphs, at: area.origin)
            storage.setAttributedString(fill)
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: area.origin)
    }
}

/// The bare overlay: what's playing, where it is, and a spinner while the
/// engine waits. Shows nothing that takes focus.
private final class PlayerOverlay: UIView {
    /// A view, so the gradient follows the bounds without its own animation.
    /// What goes beside the time, as Apple's.
    enum Mark: Equatable {
        case paused
        case step(forward: Bool)
        case scan(forward: Bool, level: Int)

        var symbol: String {
            switch self {
            case .paused: "pause.circle"
            case .step(let forward): forward ? "goforward.10" : "gobackward.10"
            case .scan(let forward, _): forward ? "forward.circle" : "backward.circle"
            }
        }

        /// The scan's level, from the second on.
        var number: String? {
            if case .scan(_, let level) = self, level > 0 { return String(level + 1) }
            return nil
        }
    }

    private(set) var isShown = false

    private let controls = UIView()
    private let title = UILabel()
    private let episode = UILabel()
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private let bar = UIView()
    /// Its own view: the bar clips.
    private let barShadow = UIView()
    private var barFocused = false
    /// What's on disk, every span of it, the dimmer white wherever the fill
    /// isn't: masked to the bar past the fill, so it moves with it.
    private let held = UIView()
    private let heldMask = UIView()
    private let fill = UIView()
    private let scrubStart = UIView()
    private let scrubMarker = UIView()
    private let markIcon = UIImageView()
    private let markNumber = UILabel()
    private var mark: Mark?
    private let spinner = LoadingSymbol(size: 64)
    private let preview = UIImageView()
    private static let previewSize = CGSize(width: 480, height: 270)
    private let previewHolder = UIView()
    private var scrubStartFraction: CGFloat = 0
    private var fraction: CGFloat = 0
    private var isScrubbing = false
    private var isDetached = false
    private var promptUp = false
    private var heldSpans: [(from: CGFloat, to: CGFloat)] = []
    private static let barHeight: CGFloat = 8
    private static let restingFill: CGFloat = 0.56
    private static let focusedFill: CGFloat = 0.85
    /// To 12 pt, focused.
    private static let barGrowth = CGAffineTransform(scaleX: 1, y: 1.5)

    init(title text: String, episode line: String?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        controls.alpha = 0
        addSubview(controls)
        addSubview(spinner)


        episode.font = .systemFont(ofSize: 26, weight: .medium)
        episode.textColor = UIColor.white.withAlphaComponent(FixedFocusText.body)
        title.text = text
        episode.text = line
        title.font = .systemFont(ofSize: 32, weight: .medium)
        title.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        for label in [title, episode] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOffset = .zero
            label.layer.shadowRadius = 8
            label.layer.shadowOpacity = 0.8
        }
        for label in [elapsed, remaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        }
        remaining.textAlignment = .right
        markIcon.tintColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        markIcon.isHidden = true
        markNumber.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        markNumber.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        bar.layer.cornerRadius = Self.barHeight / 2
        bar.clipsToBounds = true
        barShadow.layer.shadowColor = UIColor.black.cgColor
        barShadow.layer.shadowOpacity = 0.4
        barShadow.layer.shadowRadius = 10
        barShadow.layer.shadowOffset = .zero
        fill.backgroundColor = .white
        fill.alpha = Self.restingFill
        heldMask.backgroundColor = .black
        held.mask = heldMask
        for sub in [held, fill, scrubStart, scrubMarker] {
            bar.addSubview(sub)
        }
        for line in [scrubStart, scrubMarker] {
            line.backgroundColor = .white
            line.isHidden = true
        }
        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = .black
        let clip = UIView()
        clip.layer.cornerRadius = Spotlight.cornerRadius
        clip.layer.cornerCurve = .continuous
        clip.clipsToBounds = true
        clip.layer.borderWidth = 1
        clip.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        clip.frame = CGRect(origin: .zero, size: Self.previewSize)
        preview.frame = clip.bounds
        clip.addSubview(preview)
        previewHolder.addSubview(clip)
        previewHolder.layer.shadowColor = UIColor.black.cgColor
        previewHolder.layer.shadowRadius = 36
        previewHolder.layer.shadowOffset = CGSize(width: 0, height: 10)
        previewHolder.layer.shadowPath = UIBezierPath(roundedRect: clip.bounds, cornerRadius: Spotlight.cornerRadius).cgPath
        previewHolder.layer.shadowOpacity = 0.7
        previewHolder.isHidden = true
        for sub in [title, episode, elapsed, markIcon, markNumber, remaining, barShadow, bar, previewHolder] as [UIView] {
            controls.addSubview(sub)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 80
        let width = bounds.width - inset * 2
        // Bounds and center: its transform is what the shelf pushes.
        controls.bounds = bounds
        controls.center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Left above the bar, level with the buttons, clear of them.
        title.frame = CGRect(x: inset, y: bounds.height - 208, width: width - 220, height: 40)
        episode.frame = CGRect(x: inset, y: bounds.height - 242, width: width - 220, height: 32)
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        bar.center = CGPoint(x: bounds.midX, y: bounds.height - 143)
        barShadow.bounds = bar.bounds
        barShadow.center = bar.center
        barShadow.layer.shadowPath = UIBezierPath(roundedRect: bar.bounds, cornerRadius: Self.barHeight / 2).cgPath
        placeFill()
        placeHeld()
        placeElapsed()
        remaining.frame = CGRect(x: inset + width - 200, y: bounds.height - 126, width: 200, height: 32)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        placePreview()
    }

    func setBarFocused(_ focused: Bool) {
        guard focused != barFocused else { return }
        barFocused = focused
        UIView.animate(withDuration: Motion.focusDuration, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState]) { [self] in
            bar.transform = focused ? Self.barGrowth : .identity
            barShadow.transform = bar.transform
            fill.alpha = focused ? Self.focusedFill : Self.restingFill
        }
    }

    /// Detached, the fill stops at the nearer of the two lines; past it the
    /// bar shows what's on disk, the scrub's span marked only by the lines.
    private func placeFill() {
        let (width, height) = (bar.bounds.width, Self.barHeight)
        let start = isDetached ? scrubStartFraction : fraction
        let from = min(fraction, start)
        fill.frame = CGRect(x: 0, y: 0, width: width * from, height: height)
        heldMask.frame = CGRect(x: width * from, y: 0, width: width * (1 - from), height: height)
        scrubStart.frame = CGRect(x: width * scrubStartFraction - 1, y: 0, width: 2, height: height)
        scrubMarker.frame = CGRect(x: width * fraction - 1, y: 0, width: 2, height: height)
    }

    private func placeHeld() {
        let width = bar.bounds.width
        held.frame = bar.bounds
        while held.subviews.count < heldSpans.count {
            let span = UIView()
            span.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            held.addSubview(span)
        }
        for (index, span) in held.subviews.enumerated() {
            guard index < heldSpans.count else { span.isHidden = true; continue }
            let (from, to) = heldSpans[index]
            span.isHidden = false
            span.frame = CGRect(x: width * from, y: 0, width: width * max(to - from, 0), height: Self.barHeight)
        }
    }

    /// Under the marker, always, the mark to its right; the time left makes
    /// way for them at the end.
    private func placeElapsed() {
        let width = elapsed.intrinsicContentSize.width
        let extra = markWidth
        let marker = bar.frame.minX + bar.bounds.width * fraction - width / 2
        let x = min(max(marker, bar.frame.minX), bar.frame.maxX - width - extra)
        elapsed.frame = CGRect(x: x, y: bounds.height - 126, width: width, height: 32)
        placeMark()
        let alpha: CGFloat = x + width + extra > bar.frame.maxX - remaining.intrinsicContentSize.width - 24 ? 0 : 1
        guard remaining.alpha != alpha else { return }
        UIView.animate(withDuration: Motion.fadeDuration) { self.remaining.alpha = alpha }
    }

    private var markWidth: CGFloat {
        guard mark != nil else { return 0 }
        let number = markNumber.isHidden ? 0 : markNumber.intrinsicContentSize.width + 8
        return 12 + (markIcon.image?.size.width ?? 0) + number
    }

    private func placeMark() {
        let icon = markIcon.image?.size ?? .zero
        markIcon.frame = CGRect(x: elapsed.frame.maxX + 12, y: elapsed.frame.midY - icon.height / 2,
                                width: icon.width, height: icon.height)
        markNumber.frame = CGRect(x: markIcon.frame.maxX + 8, y: elapsed.frame.minY,
                                  width: markNumber.intrinsicContentSize.width, height: 32)
    }

    /// Placed at once: a mark coming in doesn't fly in from where it last was.
    private func setMark(_ new: Mark?) {
        guard new != mark else { return }
        mark = new
        // In the image itself: its size places it, and a configuration on the
        // view wouldn't change that.
        let size = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        markIcon.image = new.map { UIImage(systemName: $0.symbol, withConfiguration: size) } ?? nil
        markIcon.isHidden = new == nil
        markNumber.text = new?.number
        markNumber.isHidden = new?.number == nil
        placeMark()
    }

    private func placePreview() {
        let size = Self.previewSize
        let x = min(max(bar.frame.minX + bar.bounds.width * fraction - size.width / 2, bar.frame.minX),
                    bar.frame.maxX - size.width)
        previewHolder.frame = CGRect(x: x, y: bounds.height - 176 - size.height, width: size.width, height: size.height)
    }

    /// nil: time only (no still for that spot yet). The preview isn't there
    /// until its first still, then fades in.
    func setPreview(_ image: CGImage?) {
        guard image !== preview.image?.cgImage else { return }
        preview.image = image.map { UIImage(cgImage: $0) }
        if image == nil { hidePreview() } else { revealPreview() }
    }

    private func revealPreview() {
        guard previewHolder.isHidden else { return }
        previewHolder.alpha = 0
        previewHolder.isHidden = false
        UIView.animate(withDuration: Motion.fadeDuration) { self.previewHolder.alpha = 1 }
    }

    private func hidePreview() {
        previewHolder.layer.removeAllAnimations()
        previewHolder.isHidden = true
        previewHolder.alpha = 1
    }

    func setTitle(_ text: String, episode line: String?) {
        title.text = text
        episode.text = line
    }

    /// A prompt takes the title's place for as long as it's there.
    func setPromptUp(_ up: Bool) {
        guard up != promptUp else { return }
        promptUp = up
        fadeTitle()
    }

    private func fadeTitle() {
        let alpha: CGFloat = isDetached || promptUp ? 0 : 1
        UIView.animate(withDuration: Motion.fadeDuration) {
            self.title.alpha = alpha
            self.episode.alpha = alpha
        }
    }

    /// `detached`: the fill stays behind the marker. A press while playing
    /// isn't: the two move as one.
    func setScrubbing(_ scrubbing: Bool, detached: Bool) {
        if scrubbing, preview.image != nil {
            revealPreview()
        } else if !scrubbing {
            hidePreview()
        }
        if scrubbing != isScrubbing {
            scrubStartFraction = fraction
            scrubMarker.isHidden = !scrubbing
            isScrubbing = scrubbing
            placeElapsed()
        }
        let detach = scrubbing && detached
        guard detach != isDetached else { return }
        isDetached = detach
        scrubStart.isHidden = !detach
        fadeTitle()
        glide(placeFill)
    }

    private func glide(_ place: @escaping () -> Void) {
        UIView.animate(withDuration: Motion.moveDuration, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: place)
    }

    func move(time: Double, duration: Double, mark: Mark?, animated: Bool = false) {
        fraction = duration > 0 ? CGFloat(min(max(time / duration, 0), 1)) : 0
        elapsed.text = duration > 0 ? Self.clock(time) : nil
        setMark(duration > 0 ? mark : nil)
        let place = { [self] in
            placeFill()
            placePreview()
            placeElapsed()
        }
        if animated { glide(place) } else { place() }
        remaining.text = duration > 0 ? "-" + Self.clock(max(duration - time, 0)) : nil
    }

    /// What's on disk, a shade over the empty bar.
    func setHeld(_ spans: [ClosedRange<Double>], duration: Double) {
        guard duration > 0 else { return }
        let clamp = { (t: Double) in CGFloat(min(max(t / duration, 0), 1)) }
        heldSpans = spans.map { (clamp($0.lowerBound), clamp($0.upperBound)) }
        UIView.performWithoutAnimation(placeHeld)
    }

    func update(time: Double, duration: Double, mark: Mark?, waiting: Bool) {
        move(time: time, duration: duration, mark: mark)
        if waiting != spinner.isAnimating {
            if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        UIView.animate(withDuration: Motion.fadeDuration) {
            self.controls.alpha = shown ? 1 : 0
        }
    }

    /// Up as the shelf opens; in and out with no shelf, a short way as they fade.
    func setShift(_ shift: CGFloat) {
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.controls.transform = CGAffineTransform(translationX: 0, y: shift)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

/// What IntroDB knows of an episode or film: community timings, by IMDb id.
struct PlayerSegments {
    var recap: Range<Double>?
    var intro: Range<Double>?
    var outro: Range<Double>?

    static func fetch(meta: MetaItem, video: MetaVideo?) async -> PlayerSegments? {
        guard let id = ((video?.id ?? meta.id).firstMatch(of: /tt\d{6,}/) ?? meta.id.firstMatch(of: /tt\d{6,}/))
            .map({ String($0.output) }),
            var parts = URLComponents(string: "https://api.introdb.app/segments") else { return nil }
        parts.queryItems = [URLQueryItem(name: "imdb_id", value: id)]
        if let video {
            guard let season = video.season, let episode = video.episode else { return nil }
            parts.queryItems? += [URLQueryItem(name: "season", value: String(season)),
                                  URLQueryItem(name: "episode", value: String(episode))]
        } else {
            parts.queryItems?.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        guard let url = parts.url,
              let (data, reply) = try? await URLSession.shared.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PlayerSegments(recap: span(json["recap"]), intro: span(json["intro"]), outro: span(json["outro"]))
    }

    private static func span(_ value: Any?) -> Range<Double>? {
        guard let segment = value as? [String: Any],
              let start = seconds(segment["start_sec"]), let end = seconds(segment["end_sec"]),
              start < end else { return nil }
        return start..<end
    }

    /// A number, or "mm:ss".
    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        guard let text = value as? String else { return nil }
        return text.split(separator: ":").reduce(0.0 as Double?) { total, part in
            guard let total, let part = Double(part) else { return nil }
            return total * 60 + part
        }
    }
}

/// Above the title: Skip Intro and where it ends. Opposite it: the next
/// episode as a card with its picture. Glass at rest; focused white with dark
/// content, 12 pt wider.
/// The controller takes its Select: no button, so nothing fires twice.
private final class PlayerPrompt: UIView {
    private static let pillHeight: CGFloat = 88
    private static let pillPadding: CGFloat = 44
    /// Level with the buttons' feet.
    fileprivate static let bottom: CGFloat = 172
    private var shift: CGFloat = 0
    private static let cardWidth: CGFloat = 420
    private static let cardPadding: CGFloat = 16
    private static let pictureHeight: CGFloat = (cardWidth - cardPadding * 2) * 9 / 16

    var takesFocus = false
    override var canBecomeFocused: Bool { takesFocus }

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: SettingsMetrics.tallRowRadius, style: .continuous))
    private let platter = UIView()
    private let picture = UIImageView()
    private let heading = UILabel()
    private let detail = UILabel()
    private var isCard = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        platter.backgroundColor = .white
        platter.alpha = 0
        platter.layer.cornerCurve = .continuous
        platter.layer.cornerRadius = SettingsMetrics.tallRowRadius
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = SettingsMetrics.tallRowRadius - Self.cardPadding
        picture.layer.cornerCurve = .continuous
        heading.font = .systemFont(ofSize: 25, weight: .medium)
        detail.font = .systemFont(ofSize: 24)
        for sub in [glass, platter, picture, heading, detail] as [UIView] { addSubview(sub) }
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showPill(_ text: String, detail second: String) {
        isCard = false
        heading.text = text
        detail.text = second
        picture.image = nil
        place()
    }

    func showCard(heading text: String, detail second: String, picture image: UIImage?) {
        isCard = true
        heading.text = text
        detail.text = second
        picture.image = image
        place()
    }

    func setHeading(_ text: String) { heading.text = text }

    /// Center, not transform: its transform is its focus.
    func setShift(_ shift: CGFloat) {
        center.y += shift - self.shift
        self.shift = shift
    }

    private func place() {
        guard let page = superview?.bounds else { return }
        transform = .identity
        let text = max(heading.intrinsicContentSize.width, detail.intrinsicContentSize.width)
        let size = isCard
            ? CGSize(width: Self.cardWidth, height: Self.cardPadding * 2 + Self.pictureHeight + 86)
            : CGSize(width: text + Self.pillPadding * 2, height: Self.pillHeight)
        frame = CGRect(x: 80, y: page.height - Self.bottom + shift - size.height, width: size.width, height: size.height)
        if isFocused { transform = focusGrowth }
        picture.isHidden = !isCard
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        platter.frame = bounds
        guard isCard else {
            let width = bounds.width - Self.pillPadding * 2
            heading.frame = CGRect(x: Self.pillPadding, y: 12, width: width, height: 32)
            detail.frame = CGRect(x: Self.pillPadding, y: heading.frame.maxY, width: width, height: 32)
            return
        }
        let inset = Self.cardPadding
        let width = bounds.width - inset * 2
        picture.frame = CGRect(x: inset, y: inset, width: width, height: Self.pictureHeight)
        heading.frame = CGRect(x: inset, y: picture.frame.maxY + 12, width: width, height: 32)
        detail.frame = CGRect(x: inset, y: heading.frame.maxY + 2, width: width, height: 32)
    }

    /// In points, as a menu's rows: a share of a wide card is a big jump.
    private var focusGrowth: CGAffineTransform {
        let scale = (bounds.width + 12) / max(bounds.width, 1)
        return CGAffineTransform(scaleX: scale, y: scale)
    }

    private func restyle() {
        heading.textColor = isFocused ? UIColor.black.withAlphaComponent(0.85)
                                      : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        detail.textColor = isFocused ? UIColor.black.withAlphaComponent(0.65)
                                     : UIColor.white.withAlphaComponent(FixedFocusText.secondary)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        focusChange(duration: 0.2) {
            self.platter.alpha = focused ? 1 : 0
            self.restyle()
            self.transform = focused ? self.focusGrowth : .identity
        }
    }
}

final class PlayerController: UIViewController, UIGestureRecognizerDelegate {
    /// What's on disk around the playhead: 10 minutes ahead at most, and the
    /// budget (the engine keeps it under a quarter of free space) holds that
    /// and what's behind. Seeks and stills inside it never touch the network.
    private static let windowSegments = 150
    private static let windowBytes = 6 << 30

    /// Background preloading stands down while a title plays.
    private(set) static var isPlaying = false

    private static let tickInterval: TimeInterval = 0.2
    /// How far the subtitles' time runs on past the engine's, which it updates
    /// ten times a second. A stall stops it here.
    private static let subtitleClockReach: CFTimeInterval = 0.25
    private static let subtitleDelayStep = 0.25
    /// Played this long in a session, it counts. Until then nothing is saved,
    /// so a Start Over keeps its old position.
    private static let countsAfterSeconds: Double = 30
    /// Worst-case loss if the app dies: periodic saves reach disk this often.
    private static let saveInterval: TimeInterval = 10
    /// Links tried silently after the first, then the source list (two in a
    /// row failing usually share a cause; the list beats a third guess).
    private static let maxRetries = 1
    /// A failure with a list older than this searches again (the Play cache's age).
    private static let linksFreshSeconds: TimeInterval = 5 * 60
    /// No first frame by then: the link counts as failed.
    private static let firstFrameSeconds: TimeInterval = 20
    /// Meant to play and getting nowhere this long: the engine's own
    /// reconnecting has had its turn and the link counts as lost.
    private static let stuckSeconds: TimeInterval = 20
    /// Less than this ahead of the playhead, a stalled source has run dry.
    private static let dryAheadSeconds: Double = 2
    /// An end further than this from the duration is the stream cutting out.
    private static let earlyEndSeconds: Double = 30

    /// The episode playing: the player stays open from one to the next.
    private var meta: MetaItem
    private var video: MetaVideo?
    private var resume: Double?
    private var links: [StreamEntry]
    private var linksFound = Date()
    /// A search of our own replaced the list: the launcher's is the older one.
    private var linksOwn = false
    private var linkSearch: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private let isDemo: Bool
    private let progress: ProgressStore
    private let settings: PlayerSettings
    private let onShown: () -> Void
    private let onClose: () -> Void
    private let engine: AetherEngine?

    private let focusView = PlayerFocusView()
    private let surface = AetherPlayerView()
    private let subtitleText = SubtitleText()
    private let subtitleImage = UIImageView()
    private let subtitleTop = SubtitleText()
    /// What stays where it is when the controls come up: signs, and lines
    /// asking for the top.
    private let fixedSubtitles = UIView()
    private var assTrack: AssTrack?
    /// Both kinds of subtitle: they make way as the controls come up.
    private let subtitles = UIView()
    private var subtitleFloor = PlayerController.subtitleRest
    private let overlay: PlayerOverlay
    private let audioButton = PlayerButton(icon: "waveform", label: "Audio")
    private let subtitleButton = PlayerButton(icon: "captions.bubble", label: "Subtitles")
    private let trackList: MenuPanel = {
        let menu = MenuPanel()
        menu.minWidth = 400
        menu.maxWidth = 620
        return menu
    }()
    private let shelf = PlayerShelf()
    private let promptView = PlayerPrompt()
    private let readout = UILabel()

    /// The link playing, once failover has moved on from the request's.
    private var entry: StreamEntry
    private var tried: [String]
    private var loadStarted = Date()
    /// Tells a superseded load from the current one.
    private var attempt = 0

    private var probe: SourceProbe?
    private var failure: String?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var started = false
    private var closed = false

    /// The first frame has played: only then does the clock mean anything.
    private var hasPlayed = false
    /// The first frame has come up over the stage. Until then the view is
    /// clear, and all there is to see is the stage.
    private var revealed = false
    private var closing = false
    /// Time actually played this session, seeks not included.
    private var played: Double = 0
    private var wasPaused = false
    /// Until then a save would stomp the saved position with the clock's zero.
    private var resumeFloor: Double
    private var lastSave = Date.distantPast
    private var saves = 0
    private var audioPicked = false
    /// The clock's last value, and when it last moved.
    private var lastClock: Double = 0
    private var clockMoved = Date()
    /// Where the picture stopped with the source gone. The engine's clock runs
    /// on, still "playing", over a frozen picture: it can't be believed.
    private var dryAt: Double?
    private var drySince = Date()
    /// Where a cut-short stream ended: ending there again is the file's real end.
    private var earlyEnd: Double?
    private var leftAt: Double = 0
    private var away = false
    private var mountPaused = false
    /// From lights down until the film has risen: no controls (it's held
    /// paused at first), and presses dropped but Back (most are a stray
    /// second Play).
    private var arriving = false
    /// How long the overlay stays after a press.
    private static let overlaySeconds: TimeInterval = 3
    private var overlayUntil = Date.distantPast
    /// Back in this long after the controls hid by themselves was meant for them.
    private static let backGuardSeconds: TimeInterval = 1
    private var backGuardUntil = Date.distantPast
    /// Back put them away: they stay gone, even paused, until the next press.
    private var controlsDismissed = false

    /// A press moves the target this far, paused or playing.
    private static let scrubStep: Double = 10
    /// Paused, a swipe is fine control: about 45 s across the pad, whatever the
    /// title's length, so going far stays a job for the scan.
    private static let swipeSecondsPerPoint: Double = 0.03
    /// A swipe lets go with its speed and eases out over this.
    private static let swipeFastSpeed: Double = 2000
    private static let swipeMostGain: Double = 4
    /// A swipe only opens something when it's clearly up or down; the rest scrubs.
    private static let verticalSwipeRatio: CGFloat = 2
    private static let glideSeconds: Double = 0.25
    private static let glideStop: Double = 1
    /// Playing, a press held this long starts the scan, which goes on by itself.
    private static let scanHoldSeconds: TimeInterval = 0.5
    /// The scan's slider, in seconds of title per second. The picture is paused:
    /// the engine plays 2× at most and never backwards.
    private static let scanSpeeds: [Double] = [30, 120, 300, 600]
    /// The seek waits this long after the last input, so a run of inputs is one seek.
    private static let scrubCommitSeconds: TimeInterval = 0.3
    /// The bar follows at this rate; the swipe comes in at twice it.
    private static let scrubDrawInterval: TimeInterval = 1.0 / 30
    private static let stillWidth = 480
    /// Past what's on disk, a still waits for the target to stop.
    private static let stillSettleSeconds: TimeInterval = 0.3
    private static let stillRestSeconds: TimeInterval = 0.25

    /// Where the viewer is scrubbing to; playback goes on until it lands.
    private var scrubTarget: Double?
    private var scrubCommitAt = Date.distantPast
    private var lastScrubDraw = Date.distantPast
    /// Where a commit is going: the bar stays there until the seek is done.
    private var landing: Double?
    /// The arrow going down, until it's up or the scan takes over.
    private var holdDirection: Double = 0
    private var holdWait: Task<Void, Never>?
    private var scan: (direction: Double, level: Int)?
    /// The way of the last arrow press in this scrub; 0 once a swipe took over.
    private var stepDirection: Double = 0
    private var glide: Double = 0
    private var runLink: CADisplayLink?
    private var panning = false
    private var panVertical = false
    private var panLast: CGFloat = 0
    private var previewBusy = false
    /// Stills for what the engine doesn't hold: its own connection to the link,
    /// made at the first such scrub.
    private var stills: FrameExtractor?
    private var restWait: Task<Void, Never>?
    private var exactWanted = false
    private var exactStale: OSAllocatedUnfairLock<Bool>?

    /// Without an outro from IntroDB, the next episode comes up this long before the end.
    private static let nextLeadSeconds: Double = 120
    /// Its link is looked for this much before it comes up.
    private static let nextSearchSeconds: Double = 60
    /// Between the end of the file and the next episode playing by itself.
    private static let nextCountdown: TimeInterval = 5
    /// Skip goes this long before what it skips ends: by then there's nothing left to save.
    private static let skipGoneSeconds: Double = 3

    private enum Prompt: Equatable {
        case skip(String, to: Double)
        case next
    }

    private var segments: PlayerSegments?
    private var segmentsTask: Task<Void, Never>?
    private var prompt: Prompt?
    private var dismissedPrompt: Prompt?
    private var nextUp: PlayLauncher.NextEpisode?
    private var nextPicture: UIImage?
    private var nextTask: Task<Void, Never>?
    private var nextSearched = false
    private var endedAt: Date?

    private enum Menu { case none, buttons, tracks }

    /// Subtitles' foot above the bottom of the screen: at rest, and clear of
    /// the title and the buttons.
    private static let subtitleRest: CGFloat = 90
    private static let subtitleTopInset: CGFloat = 60
    private static let subtitleClear: CGFloat = 250
    private var menu = Menu.none
    private weak var lastButton: PlayerButton?
    /// What On turns back on.
    private var lastSubtitle: Int?
    private var externalSubtitlesTask: Task<Void, Never>?
    /// Seconds a track shows later, for a file out of sync. Until the track or
    /// the episode changes.
    private var subtitleDelay: Double = 0
    private var subtitleClock: (time: Double, at: CFTimeInterval, shown: Double) = (0, 0, 0)
    private var subtitleLink: CADisplayLink?
    /// The next start or end of a cue: the frame that changes what's up.
    private var nextSubtitleEdge = Double.infinity
    /// External tracks whose address doesn't say the format.
    private var unknownFormats: Set<Int> = []
    private var buttons: [PlayerButton] { [audioButton, subtitleButton] }
    private var shelfOpen = false
    private var controlsShift: CGFloat = 0
    private var show: (meta: MetaItem, episodes: [MetaVideo])?
    private var showTask: Task<Void, Never>?
    /// An episode from the shelf, its link being found.
    private var episodeTask: Task<Void, Never>?
    /// Stepped down off the prompt: it stays up, the bar has the remote.
    private var promptLeft = false

    init(request: PlaybackRequest, progress: ProgressStore, settings: PlayerSettings,
         onShown: @escaping () -> Void, onClose: @escaping () -> Void) {
        meta = request.meta
        video = request.video
        resume = request.resumePosition
        links = request.allEntries
        isDemo = request.isDemo
        self.progress = progress
        self.settings = settings
        self.onShown = onShown
        self.onClose = onClose
        resumeFloor = request.resumePosition ?? 0
        entry = request.entry
        tried = [request.entry.rejectionKey]
        overlay = PlayerOverlay(title: request.meta.name, episode: request.video?.title)
        do {
            engine = try AetherEngine()
        } catch {
            engine = nil
            failure = error.localizedDescription
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if shelfOpen { return [shelf] }
        switch menu {
        case .none: return [promptView.takesFocus ? promptView : focusView]
        case .buttons: return [lastButton ?? audioButton]
        case .tracks: return [trackList]
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.alpha = 0
        for sub in [focusView, surface, subtitles, fixedSubtitles, audioButton, subtitleButton, overlay,
                    promptView, trackList, shelf,
                    readout] as [UIView] {
            view.addSubview(sub)
        }

        for sub in [subtitleImage, subtitleText] as [UIView] { subtitles.addSubview(sub) }
        subtitles.isUserInteractionEnabled = false
        fixedSubtitles.addSubview(subtitleTop)
        fixedSubtitles.isUserInteractionEnabled = false

        trackList.isHidden = true
        trackList.picked = { [weak self] in self?.setMenu(.none) }
        for button in buttons {
            button.alpha = 0
            button.addTarget(self, action: #selector(buttonPressed), for: .primaryActionTriggered)
        }
        shelf.fill = { [weak self] in
            (self?.shelfEpisodes() ?? [], self?.shelfSources() ?? [])
        }
        shelf.again.action = { [weak self] in self?.refreshLinks() }

        let back = UITapGestureRecognizer(target: self, action: #selector(backPressed))
        back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(back)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        view.addGestureRecognizer(pan)

        readout.numberOfLines = 0
        readout.textColor = .white
        readout.font = .monospacedSystemFont(ofSize: 23, weight: .regular)
        readout.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        readout.layer.cornerRadius = 12
        readout.clipsToBounds = true

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(leavingApp), name: UIApplication.willResignActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(wentAway), name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        focusView.frame = view.bounds
        surface.frame = view.bounds
        overlay.frame = view.bounds
        subtitles.bounds = view.bounds
        subtitles.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        fixedSubtitles.frame = view.bounds
        placeButtons()
        shelf.bounds.size = CGSize(width: view.bounds.width - 160, height: PlayerShelf.height)
        shelf.center = CGPoint(x: view.bounds.midX, y: view.bounds.height - PlayerShelf.margin - PlayerShelf.height / 2)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Self.isPlaying = true
        setNeedsFocusUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let link = CADisplayLink(target: self, selector: #selector(subtitleFrame))
        link.add(to: .main, forMode: .common)
        subtitleLink = link
        start()
        loadSegments()
        loadShow()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardown()
    }

    private func start() {
        guard let engine else { return }
        engine.bind(view: surface)
        guard let raw = entry.stream.url, let url = URL(string: raw) else {
            linkFailed()
            return
        }
        attempt += 1
        let attempt = attempt
        loadStarted = Date()
        // Developer: every link fails, a few seconds in, for the stage's lines.
        if PerformanceSettingsStore.shared.settings.failEveryLink {
            loadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, self?.attempt == attempt else { return }
                self?.linkFailed()
            }
            return
        }
        var options = LoadOptions(
            httpHeaders: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders ?? [:],
            matchContentEnabled: view.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true,
            confirmAtmos: true
        )
        options.forwardBufferSegments = Self.windowSegments
        options.sessionCacheByteBudget = Self.windowBytes
        options.softwarePacketCacheStorage = .disk
        options.preferredAudioLanguages = audioLanguages()
        options.preferredSubtitleLanguages = subtitleLanguages()
        options.preserveASSMarkup = true
        let resume = resume
        loadTask = Task { [weak self] in
            do {
                let probe = try await engine.load(url: url, startPosition: resume, options: options)
                self?.probe = probe
                self?.loadExternalSubtitles(engine)
            } catch is CancellationError {
            } catch {
                if self?.attempt == attempt { self?.linkFailed() }
            }
            // Left mid-load: the load outlives the stop, so stop what it started.
            if self?.closed ?? true { engine.stop() }
        }
    }

    /// The subtitle add-ons' files, each a track of its own, once the link plays:
    /// a slow add-on holds nothing up.
    private func loadExternalSubtitles(_ engine: AetherEngine) {
        externalSubtitlesTask?.cancel()
        unknownFormats = []
        let (meta, video) = (meta, video)
        externalSubtitlesTask = Task { [weak self] in
            var id = meta.id
            if id.hasPrefix("tmdb:"), let number = Int(id.dropFirst("tmdb:".count)),
               let imdb = await TMDBService.imdbID(tmdbID: number, isMovie: !meta.isSeries) {
                id = imdb
            }
            if id.hasPrefix("tt"), let season = video?.season, let episode = video?.episode {
                id = "\(id):\(season):\(episode)"
            } else {
                id = video?.id ?? id
            }
            let (found, type) = (id, meta.type)
            let addons = AddonManager.shared?.subtitleAddons.filter { $0.handles(id: found) } ?? []
            await withTaskGroup(of: (String, [StremioAPI.AddonSubtitle]).self) { group in
                for addon in addons {
                    group.addTask {
                        (addon.displayName, (try? await StremioAPI.subtitles(addon: addon, type: type, id: found)) ?? [])
                    }
                }
                for await (name, files) in group {
                    guard !Task.isCancelled else { return }
                    for file in files {
                        guard let url = URL(string: file.url) else { continue }
                        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: name, language: file.lang))
                        if !["srt", "ass", "ssa", "vtt", "sup"].contains(url.pathExtension.lowercased()) {
                            self?.unknownFormats.insert(track.id)
                        }
                    }
                }
            }
        }
    }

    /// Before the first frame, the next link in the add-ons' order, silently;
    /// out of tries or links, the source list.
    private func linkFailed() {
        guard !closed, !hasPlayed, linkSearch == nil else { return }
        if Date().timeIntervalSince(linksFound) > Self.linksFreshSeconds {
            searchAgain()
            return
        }
        let links = (linksOwn ? nil : PlayLauncher.shared.links(meta, video)) ?? links
        let next = links.first {
            !$0.stream.isTorrent && !tried.contains($0.rejectionKey)
        }
        guard tried.count <= Self.maxRetries, let next else {
            let (meta, video, fromStart) = (meta, video, resume == nil)
            close()
            SourcePicker.shared.open(meta, video, fromStart: fromStart)
            PlayStage.shared.note = .allFailed(tried: tried.count)
            SourcePicker.shared.failed.formUnion(tried)
            return
        }
        PlayStage.shared.note = .swapping
        tried.append(next.rejectionKey)
        entry = next
        loadTask?.cancel()
        dropStills()
        engine?.stop()
        start()
    }

    /// The list is old, so its links likely are too. Nothing found: on through
    /// the old one.
    private func searchAgain() {
        loadTask?.cancel()
        dropStills()
        engine?.stop()
        let (meta, video, current) = (meta, video, entry)
        linkSearch = Task { [weak self] in
            let found = await PlayLauncher.shared.freshLinks(meta, video)
            guard let self, !Task.isCancelled else { return }
            self.linkSearch = nil
            self.linksFound = Date()
            if !found.isEmpty {
                self.links = Self.sameReleaseFirst(found, as: current)
                self.linksOwn = true
                self.tried = []
            }
            self.linkFailed()
        }
    }

    /// The shelf's Refresh: every add-on asked again, past the caches; what
    /// plays goes on.
    private func refreshLinks() {
        refreshTask?.cancel()
        shelf.searching = true
        let (meta, video, id) = (meta, video, UUID())
        refreshID = id
        refreshTask = Task { [weak self] in
            let found = await PlayLauncher.shared.freshLinks(meta, video) { [weak self] fresh, answered in
                guard let self, self.refreshID == id, self.meta.id == meta.id, self.video?.id == video?.id else { return }
                self.takeFresh(fresh, answered: answered)
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            defer { self.shelf.searching = false }
            guard !found.isEmpty, self.meta.id == meta.id, self.video?.id == video?.id else { return }
            self.links = found
            self.linksOwn = true
            self.linksFound = Date()
            self.tried = []
            self.shelf.foundAt = self.linksFound
            self.shelf.refreshSources()
        }
    }

    /// Refresh's links as the add-ons answer: theirs replace what they gave
    /// before, the rest stay, in the add-ons' order.
    private func takeFresh(_ fresh: [StreamEntry], answered: Set<String>) {
        let old = (linksOwn ? nil : PlayLauncher.shared.links(meta, video)) ?? links
        var names: [String] = []
        for name in (old + fresh).map(\.sourceAddonName) where !names.contains(name) { names.append(name) }
        links = names.flatMap { name in
            let new = fresh.filter { $0.sourceAddonName == name }
            return !new.isEmpty || answered.contains(name) ? new : old.filter { $0.sourceAddonName == name }
        }
        linksOwn = true
        shelf.refreshSources()
    }

    /// The same file, freshly signed, then its release, then the add-ons' order.
    private static func sameReleaseFirst(_ links: [StreamEntry], as entry: StreamEntry) -> [StreamEntry] {
        let group = entry.stream.behaviorHints?.bingeGroup
        func rank(_ link: StreamEntry) -> Int {
            if link.rejectionKey == entry.rejectionKey { return 0 }
            return group != nil && link.stream.behaviorHints?.bingeGroup == group ? 1 : 2
        }
        return (0...2).flatMap { wanted in links.filter { rank($0) == wanted } }
    }

    /// Past the first frame: an error, an end well before the duration, or the
    /// clock stuck while it should run.
    private func streamLost(_ engine: AetherEngine) -> Bool {
        guard hasPlayed else { return false }
        let time = engine.currentTime
        var lost = false
        switch engine.state {
        case .error: lost = true
        case .ended:
            let early = engine.duration - time > Self.earlyEndSeconds
                && earlyEnd.map { abs($0 - time) > Self.earlyEndSeconds } ?? true
            if early { earlyEnd = time }
            lost = early
        case .playing, .seeking:
            if case .stalled = engine.playbackPhase, engine.bufferedPosition - time < Self.dryAheadSeconds {
                if dryAt == nil {
                    dryAt = time
                    drySince = Date()
                }
                lost = Date().timeIntervalSince(drySince) > Self.stuckSeconds
            } else {
                dryAt = nil
                if time != lastClock { clockMoved = Date() }
                lost = Date().timeIntervalSince(clockMoved) > Self.stuckSeconds
            }
        default:
            dryAt = nil
            clockMoved = Date()
        }
        lastClock = time
        if lost { recover(engine) }
        return lost
    }

    /// The same link again from here, then on through the links as at the
    /// start (`linkFailed`). What's on screen stays until it plays.
    private func recover(_ engine: AetherEngine) {
        if counts { save(engine) }
        reload(engine, from: position)
    }

    private func reload(_ engine: AetherEngine, from here: Double) {
        linkSearch?.cancel()
        linkSearch = nil
        dryAt = nil
        endScrub()
        hasPlayed = false
        audioPicked = false
        if here > 0 {
            resume = here
            resumeFloor = here
        }
        tried = [entry.rejectionKey]
        clockMoved = Date()
        loadTask?.cancel()
        dropStills()
        engine.stop()
        start()
    }

    // MARK: Tracks

    /// What was picked by hand for this title, then the setting, then the
    /// device's own language. Never the file's first track: that may be a dub.
    private func audioLanguages() -> [String] {
        let device = Locale.preferredLanguages.first.map { String($0.prefix(2)) }
        let wanted = [PlaybackMemory.memory(for: meta.id)?.audioLanguage,
                      settings.preferredAudioLanguage, device]
        var out: [String] = []
        for case let language? in wanted where !language.isEmpty && !out.contains(language) {
            out.append(language)
        }
        return out
    }

    private func subtitleLanguages() -> [String] {
        if let picked = PlaybackMemory.memory(for: meta.id)?.subtitleLanguage {
            return picked == "off" ? [] : [picked]
        }
        return settings.subtitlesOnByDefault ? [settings.preferredSubtitleLanguage] : []
    }

    /// TrueHD loses its objects in the bridge, so E-AC-3 Atmos in the same
    /// language plays instead. Atmos is confirmed during playback, hence here.
    private func preferAtmos(_ engine: AetherEngine) {
        guard !audioPicked,
              let active = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }),
              active.codec.lowercased() == "truehd",
              let atmos = engine.audioTracks.first(where: {
                  $0.isAtmos && $0.codec.lowercased() == "eac3" && !$0.isCommentary
                      && $0.language == active.language
              }) else { return }
        audioPicked = true
        Task { try? await engine.selectAudioTrack(index: atmos.id) }
    }

    // MARK: Progress

    private var position: Double {
        dryAt ?? max(engine?.currentTime ?? 0, resumeFloor)
    }

    private var counts: Bool {
        hasPlayed && played >= Self.countsAfterSeconds && !isDemo
    }

    /// Transient: a publish would redraw Home behind the player.
    private func save(_ engine: AetherEngine) {
        lastSave = Date()
        progress.updateTransient(
            meta: meta, video: video, streamURL: entry.stream.url,
            position: position, duration: engine.duration,
            signature: entry.stream.signature(addonName: entry.addonName)
        )
    }

    /// To the device every 10 s, to the account on the first save and every 30 s.
    private func saveDuringPlayback(_ engine: AetherEngine) {
        guard counts, Date().timeIntervalSince(lastSave) > Self.saveInterval else { return }
        save(engine)
        saves &+= 1
        if saves == 1 || saves % 3 == 0 { progress.requestSyncPush() }
    }

    /// Pausing or leaving the app: now, to both.
    private func saveAndPush() {
        guard counts, !closed, let engine else { return }
        save(engine)
        progress.requestSyncPush()
    }

    /// Before the engine's teardown, which may take the clock with it.
    @objc private func leavingApp() {
        leftAt = position
        saveAndPush()
    }

    /// The engine lets go of its picture in the background, and a link may
    /// expire there, so a return loads again, paused at the spot.
    @objc private func wentAway() { away = true }

    @objc private func cameBack() {
        guard away, !closed, let engine else { return }
        away = false
        // Silent, because a paused load (`autoplay`) draws no picture, even after a seek.
        mountPaused = hasPlayed
        if mountPaused { engine.volume = 0 }
        controlsDismissed = false
        reload(engine, from: leftAt)
        tick()
    }

    /// Publishes, and `update` pushes. The end counts however little was played;
    /// going on to the next episode is the end.
    private func saveFinal(finished: Bool = false) {
        guard let engine, hasPlayed, !isDemo else { return }
        let ended = finished || engine.state == .ended
        guard ended || counts else { return }
        progress.update(
            meta: meta, video: video, streamURL: entry.stream.url,
            position: ended ? engine.duration : position, duration: engine.duration,
            signature: entry.stream.signature(addonName: entry.addonName)
        )
    }

    /// With a picture up, it fades back to the page; the engine stops after.
    private func close() {
        guard !closing else { return }
        closing = true
        guard revealed else {
            teardown()
            return onClose()
        }
        UIView.animate(withDuration: Motion.fadeDuration) {
            self.view.alpha = 0
        } completion: { _ in
            self.teardown()
            self.onClose()
        }
    }

    /// Lights down: the first frame is in; the film holds while the stage
    /// goes dark, then rises out of the black, playing.
    private func reveal() {
        guard !revealed, let engine else { return }
        revealed = true
        guard PlayStage.shared.scene != nil else { return rise() }
        arriving = true
        engine.volume = 0
        engine.pause()
        PlayStage.shared.dark = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayStage.lightsDown) { [weak self] in
            guard let self, !self.closed, !self.closing else { return }
            engine.play()
            self.rise()
            self.soundUp(engine)
        }
    }

    /// The sound comes up with the picture: a ramp a little longer than the
    /// rise, squared so it feels even to the ear.
    private func soundUp(_ engine: AetherEngine) {
        let start = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return timer.invalidate() }
                let t = min(1, (CACurrentMediaTime() - start) / Self.soundRise)
                engine.volume = Float(t * t)
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    nonisolated static let soundRise: Double = 0.8

    private func rise() {
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, options: .curveEaseOut) {
            self.surface.alpha = 1
        } completion: { _ in
            self.arriving = false
            self.view.backgroundColor = .black
            self.onShown()
        }
    }

    /// Runs however the player goes: its own Back, or the system dismissing it
    /// with the press never reaching us.
    private func teardown() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        subtitleLink?.invalidate()
        subtitleLink = nil
        endScrub()
        saveFinal()
        loadTask?.cancel()
        linkSearch?.cancel()
        refreshTask?.cancel()
        segmentsTask?.cancel()
        externalSubtitlesTask?.cancel()
        nextTask?.cancel()
        showTask?.cancel()
        episodeTask?.cancel()
        dropStills()
        assTrack?.stop()
        assTrack = nil
        engine?.stop()
        Self.isPlaying = false
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, let engine else { return }
        // Back is `backPressed`'s: here it would bring the controls back up.
        guard press.type != .menu else {
            super.pressesBegan(presses, with: event)
            return
        }
        if arriving { return }
        if press.type == .select, promptView.isFocused {
            promptPressed(engine)
            return
        }
        if shelfOpen {
            switch press.type {
            case .upArrow where shelf.closes:
                promptLeft = true
                showControls()
                setShelf(false)
            case .playPause: engine.togglePlayPause()
            default: super.pressesBegan(presses, with: event)
            }
            return
        }
        if menu != .none {
            showControls()
            switch press.type {
            case .downArrow where menu == .buttons: stepVertically(down: true, engine)
            case .upArrow where menu == .buttons: stepVertically(down: false, engine)
            case .playPause: engine.togglePlayPause()
            default: super.pressesBegan(presses, with: event)
            }
            return
        }
        // With the controls gone a prompt holds no focus: Up or Select brings them up on it.
        if !overlay.isShown, promptView.alpha > 0, press.type == .upArrow || press.type == .select {
            showControls()
            updateOverlay(engine)
            updatePrompt(engine)
            return
        }
        switch press.type {
        case .upArrow: stepVertically(down: false, engine)
        case .downArrow: stepVertically(down: true, engine)
        case .select where scrubTarget != nil, .playPause where scrubTarget != nil:
            showControls()
            commitScrub(resume: true)
        case .select, .playPause:
            showControls()
            engine.togglePlayPause()
        case .leftArrow:
            showControls()
            arrowPressed(-1)
        case .rightArrow where promptView.takesFocus:
            setMenu(.buttons)
        case .rightArrow:
            showControls()
            arrowPressed(1)
        default:
            showControls()
            super.pressesBegan(presses, with: event)
        }
    }

    /// A press, or a swipe off the buttons or a prompt. Down: off them to the
    /// bar, then the shelf. Up: to a prompt on screen, else the buttons; off
    /// either the controls go (Right is the way from a prompt to the buttons).
    /// With the controls gone, either brings them back and does nothing else.
    private func stepVertically(down: Bool, _ engine: AetherEngine) {
        guard scan == nil, hasPlayed else { return }
        if menu == .buttons {
            if down { promptLeft = true }
            setMenu(.none)
            if !down { hideControls() }
            return
        }
        if !down && promptView.takesFocus {
            hideControls()
            return updatePrompt(engine)
        }
        let toBar = down && promptView.takesFocus
        let toPrompt = !down && promptView.alpha > 0 && !promptView.takesFocus
        guard toBar || toPrompt else {
            if overlay.isShown { return down ? setShelf(true) : setMenu(.buttons) }
            promptLeft = true
            showControls()
            updateOverlay(engine)
            return updatePrompt(engine)
        }
        showControls()
        promptLeft = down
        updateOverlay(engine)
        updatePrompt(engine)
    }

    /// A recognizer, not `pressesBegan`: with a button or list focused, the
    /// system takes Back first and dismisses the player.
    @objc private func backPressed() {
        guard !shelfOpen else {
            controlsDismissed = true
            return setShelf(false)
        }
        switch menu {
        case .tracks:
            if !trackList.back() { setMenu(.buttons) }
            return
        case .buttons:
            setMenu(.none)
            return hideControls()
        case .none: break
        }
        if scan != nil {
            commitScrub(resume: true)
        } else if scrubTarget != nil {
            endScrub()
            showControls()
        } else if hasPlayed, overlay.isShown {
            hideControls()
        } else if Date() < backGuardUntil {
            return
        } else if promptView.alpha > 0, let prompt {
            dismissedPrompt = prompt
            if let engine { updatePrompt(engine) }
        } else {
            close()
        }
    }

    private func showControls() {
        controlsDismissed = false
        overlayUntil = Date().addingTimeInterval(Self.overlaySeconds)
    }

    private func hideControls() {
        controlsDismissed = true
        if let engine { updateOverlay(engine) }
    }

    /// Arriving, an arrow moves no focus either.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        !(arriving && !context.focusHeading.isEmpty)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endHold(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endHold(presses)
        super.pressesCancelled(presses, with: event)
    }

    // MARK: Scrubbing

    private func moveScrub(to seconds: Double, press: Bool = false) {
        guard let engine, hasPlayed, engine.duration > 0 else { return }
        scrubTarget = min(max(seconds, 0), max(engine.duration - 1, 0))
        scrubCommitAt = Date().addingTimeInterval(Self.scrubCommitSeconds)
        guard let target = scrubTarget else { return }
        overlay.setScrubbing(true, detached: isDetached)
        waitForRest()
        loadPreview()
        guard press || Date().timeIntervalSince(lastScrubDraw) >= Self.scrubDrawInterval else { return }
        lastScrubDraw = Date()
        overlay.move(time: target, duration: engine.duration, mark: mark, animated: press)
    }

    private var isFine: Bool { engine?.state == .paused && scan == nil }
    /// The scan and anything paused: nothing has landed, so the fill stays.
    private var isDetached: Bool { scan != nil || isFine }

    private func arrowPressed(_ direction: Double) {
        if scan != nil {
            shiftScan(direction)
        } else if panning, scrubTarget != nil {
            // A swipe ending in a click on the pad's edge.
            commitScrub(resume: true)
        } else {
            glide = 0
            stepDirection = direction
            moveScrub(to: (scrubTarget ?? position) + direction * Self.scrubStep, press: true)
            if scrubTarget != nil, !isFine { waitForHold(direction) }
        }
    }

    private func waitForHold(_ direction: Double) {
        holdDirection = direction
        holdWait?.cancel()
        holdWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.scanHoldSeconds))
            guard let self, !Task.isCancelled, self.holdDirection == direction else { return }
            self.holdDirection = 0
            self.scan = (direction, 0)
            self.engine?.pause()
            self.startRun()
        }
    }

    private func endHold(_ presses: Set<UIPress>) {
        guard presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) else { return }
        stopHold()
        scrubCommitAt = Date().addingTimeInterval(Self.scrubCommitSeconds)
    }

    private func stopHold() {
        holdDirection = 0
        holdWait?.cancel()
    }

    /// The same way, faster; the other way, slower, and through the slowest
    /// speed it turns round.
    private func shiftScan(_ direction: Double) {
        guard let current = scan else { return }
        if direction == current.direction {
            scan?.level = min(current.level + 1, Self.scanSpeeds.count - 1)
        } else if current.level > 0 {
            scan?.level = current.level - 1
        } else {
            scan?.direction = direction
        }
    }

    private func startRun() {
        guard runLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(runStep))
        link.add(to: .main, forMode: .common)
        runLink = link
    }

    private func stopRun() {
        glide = 0
        runLink?.invalidate()
        runLink = nil
    }

    @objc private func runStep(_ link: CADisplayLink) {
        guard let target = scrubTarget, let engine else { return stopRun() }
        if let scan {
            let next = target + scan.direction * Self.scanSpeeds[scan.level] * link.duration
            moveScrub(to: next)
            if next <= 0 || next >= engine.duration - 1 { commitScrub(resume: true) }
        } else {
            moveScrub(to: target + glide * link.duration)
            glide *= exp(-link.duration / Self.glideSeconds)
            if abs(glide) < Self.glideStop { stopRun() }
        }
    }

    private func tickScrub() {
        guard scrubTarget != nil, holdDirection == 0, scan == nil, !panning, !isFine,
              Date() > scrubCommitAt else { return }
        commitScrub()
    }

    private func commitScrub(resume: Bool = false) {
        guard let engine, let target = scrubTarget else { return }
        endScrub()
        resumeFloor = 0
        landing = target
        Task {
            await engine.seek(to: target)
            if resume { engine.play() }
            landing = nil
        }
    }

    private func endScrub() {
        scrubTarget = nil
        stopHold()
        scan = nil
        stepDirection = 0
        stopRun()
        overlay.setPreview(nil)
    }

    private func dropStills() {
        let old = stills
        stills = nil
        Task { await old?.shutdown() }
    }

    /// One still at a time, always for the latest target. What the engine holds
    /// comes first: the disk window, then its sparse stills across the title.
    /// Moving takes the nearest keyframe, one frame to decode. An exact still
    /// decodes from there to the frame, too much for a 4K file on every move,
    /// so it waits for a rest and is dropped as soon as the target moves.
    private func loadPreview(exact: Bool = false) {
        guard let engine, let target = scrubTarget, !previewBusy else { return }
        previewBusy = true
        if exact { exactWanted = false }
        let stale = OSAllocatedUnfairLock(initialState: false)
        exactStale = exact ? stale : nil
        Task { [weak self] in
            guard let self else { return }
            let held = await engine.scrubPreviewFrame(atSeconds: target, refined: exact,
                                                      maxWidth: Self.stillWidth) { stale.withLock { $0 } }
            var image = held?.image
            if image == nil, !stale.withLock({ $0 }) { image = await self.fetchStill(target, exact: exact) }
            self.previewBusy = false
            guard let latest = self.scrubTarget else { return }
            if let image { self.overlay.setPreview(image) }
            if latest != target {
                self.loadPreview()
            } else if self.exactWanted {
                self.loadPreview(exact: true)
            }
        }
    }

    private func waitForRest() {
        exactStale?.withLock { $0 = true }
        exactWanted = false
        restWait?.cancel()
        guard isFine, let target = scrubTarget else { return }
        restWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stillRestSeconds))
            guard let self, !Task.isCancelled, self.scrubTarget == target, self.isFine else { return }
            self.exactWanted = true
            self.loadPreview(exact: true)
        }
    }

    private func fetchStill(_ target: Double, exact: Bool) async -> CGImage? {
        try? await Task.sleep(for: .seconds(Self.stillSettleSeconds))
        guard let engine, scrubTarget == target else { return nil }
        if stills == nil { stills = engine.makeFrameExtractor() }
        return exact ? await stills?.preview(at: target, maxWidth: Self.stillWidth)
                     : await stills?.thumbnail(at: target, maxWidth: Self.stillWidth)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        if arriving { return false }
        let velocity = pan.velocity(in: view)
        panVertical = abs(velocity.y) > abs(velocity.x) * Self.verticalSwipeRatio
        if shelfOpen { return false }
        if menu != .none { return menu == .buttons && panVertical }
        guard hasPlayed else { return false }
        return panVertical ? scan == nil : isFine && abs(velocity.x) > abs(velocity.y)
    }

    /// Slow stays exact; the gain grows evenly with the speed, so no point in the swipe jumps.
    private static func swipeSeconds(_ speed: Double) -> Double {
        swipeSecondsPerPoint * min(1 + abs(speed) / swipeFastSpeed, swipeMostGain)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard !panVertical else {
            guard pan.state == .began else { return }
            // Never the shelf: a stray touch shouldn't cover the picture.
            if menu != .none || promptView.takesFocus, let engine {
                stepVertically(down: pan.velocity(in: view).y > 0, engine)
            }
            return
        }
        switch pan.state {
        case .began:
            panning = true
            stepDirection = 0
            stopRun()
            panLast = pan.translation(in: view).x
        case .changed:
            let x = pan.translation(in: view).x
            defer { panLast = x }
            let speed = Double(pan.velocity(in: view).x)
            moveScrub(to: (scrubTarget ?? position) + Double(x - panLast) * Self.swipeSeconds(speed))
            showControls()
        default:
            panning = false
            let speed = Double(pan.velocity(in: view).x)
            glide = speed * Self.swipeSeconds(speed)
            if abs(glide) >= Self.glideStop { startRun() }
        }
    }

    // MARK: Skip and next episode

    private func loadSegments() {
        guard !isDemo else { return }
        let (meta, video) = (meta, video)
        segmentsTask = Task { [weak self] in
            let found = await PlayerSegments.fetch(meta: meta, video: video)
            guard !Task.isCancelled else { return }
            self?.segments = found
        }
    }

    /// Where the next episode comes up: the outro, else two minutes before the end.
    private func nextStart(_ engine: AetherEngine) -> Double {
        segments?.outro?.lowerBound ?? engine.duration - Self.nextLeadSeconds
    }

    private func findNext(_ engine: AetherEngine) {
        guard !nextSearched, !isDemo, hasPlayed, let video, engine.duration > 0,
              position >= nextStart(engine) - Self.nextSearchSeconds else { return }
        nextSearched = true
        let (meta, current) = (meta, entry)
        nextTask = Task { [weak self] in
            let next = await PlayLauncher.shared.next(after: meta, video, current: current)
            var picture: UIImage?
            if let address = next?.video.thumbnail { picture = await Self.picture(address) }
            guard !Task.isCancelled else { return }
            self?.nextUp = next
            self?.nextPicture = picture
            self?.nextTask = nil
        }
    }

    private static func picture(_ address: String) async -> UIImage? {
        guard let url = URL(string: address),
              let data = try? await ImageCache.shared.download(url) else { return nil }
        return ImageCache.decodeDownsampled(data)
    }

    private func wantedPrompt(_ engine: AetherEngine) -> Prompt? {
        guard hasPlayed, engine.duration > 0 else { return nil }
        let time = landing ?? position
        let gone = time + Self.skipGoneSeconds
        if nextUp != nil, engine.state == .ended || time >= nextStart(engine) { return .next }
        if let recap = segments?.recap, recap.contains(time), recap.contains(gone) { return .skip("Skip Recap", to: recap.upperBound) }
        if let intro = segments?.intro, intro.contains(time), intro.contains(gone) { return .skip("Skip Intro", to: intro.upperBound) }
        if nextUp == nil, nextTask == nil, let outro = segments?.outro, outro.contains(time), outro.contains(gone) {
            return .skip("Skip Credits", to: outro.upperBound)
        }
        return nil
    }

    private func updatePrompt(_ engine: AetherEngine) {
        let wanted = wantedPrompt(engine)
        if wanted != prompt {
            prompt = wanted
            promptLeft = false
            switch wanted {
            case .skip(let label, let end):
                promptView.showPill(label, detail: "Ends at \(PlayerOverlay.clock(end))")
            case .next:
                if let nextUp {
                    promptView.showCard(heading: "Next Episode", detail: nextUp.video.title ?? nextUp.meta.name,
                                        picture: nextPicture)
                }
            case nil: break
            }
        }
        // Scrubbing or paused, Select keeps its usual job, so no prompt.
        let busy = shelfOpen || menu == .tracks || scrubTarget != nil || scan != nil || engine.state == .paused
        let shown = wanted != nil && wanted != dismissedPrompt && !busy
        let alpha: CGFloat = shown ? 1 : 0
        overlay.setPromptUp(shown)
        if promptView.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) { self.promptView.alpha = alpha }
        }
        // Scrubbing is being on the bar; with the controls gone, nothing holds focus there.
        if scrubTarget != nil || scan != nil { promptLeft = true } else if !overlay.isShown { promptLeft = false }
        let focused = shown && overlay.isShown && (menu == .buttons || (menu == .none && !shelfOpen && !promptLeft))
        guard focused != promptView.takesFocus else { return }
        promptView.takesFocus = focused
        focusView.takesFocus = !focused && menu == .none && !shelfOpen
        overlay.setBarFocused(barHasFocus)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func promptPressed(_ engine: AetherEngine) {
        switch prompt {
        case .skip(_, let end):
            scrubTarget = min(end, max(engine.duration - 1, 0))
            commitScrub()
        case .next: playNext()
        case nil: break
        }
    }

    /// The next episode plays after a moment, unless Back put it away.
    private func reachedEnd(_ engine: AetherEngine) {
        guard dismissedPrompt != .next, !isDemo else { return close() }
        // Scrubbed to the very end: its link may still be coming.
        if nextTask != nil { return }
        guard nextUp != nil else { return close() }
        let ended = endedAt ?? Date()
        endedAt = ended
        updatePrompt(engine)
        let left = Self.nextCountdown - Date().timeIntervalSince(ended)
        guard left > 0 else { return playNext() }
        promptView.setHeading("Next in \(Int(left.rounded(.up)))")
    }

    private func playNext() {
        guard let next = nextUp else { return }
        play(next, finished: true)
    }

    /// The same player goes on: new link, new window, as a fresh start.
    private func play(_ next: PlayLauncher.NextEpisode, finished: Bool) {
        endScrub()
        saveFinal(finished: finished)
        loadTask?.cancel()
        segmentsTask?.cancel()
        externalSubtitlesTask?.cancel()
        dropStills()
        engine?.stop()

        meta = next.meta
        subtitleDelay = 0
        video = next.video
        entry = next.entry
        links = next.links
        linksFound = Date()
        linksOwn = false
        resume = next.resume
        resumeFloor = next.resume ?? 0
        tried = [next.entry.rejectionKey]
        hasPlayed = false
        played = 0
        wasPaused = false
        lastSave = .distantPast
        saves = 0
        audioPicked = false
        landing = nil
        dryAt = nil
        probe = nil
        segments = nil
        prompt = nil
        dismissedPrompt = nil
        nextUp = nil
        nextPicture = nil
        nextSearched = false
        endedAt = nil

        overlay.setTitle(next.meta.name, episode: next.video.title)
        promptView.alpha = 0
        promptView.takesFocus = false
        nextTask?.cancel()
        nextTask = nil
        setShelf(false)
        setMenu(.none)
        showControls()
        start()
        loadSegments()
    }

    // MARK: Panel and shelf

    /// Bounds and center: its transform is its focus.
    private func placeButtons() {
        let size = PlayerButton.size
        let center = view.bounds.height - PlayerPrompt.bottom - size / 2 + controlsShift
        for (index, button) in buttons.reversed().enumerated() {
            button.bounds.size = CGSize(width: size, height: size)
            button.center = CGPoint(x: view.bounds.width - 80 - size / 2 - CGFloat(index) * (size + 20), y: center)
        }
    }

    /// Bar, title and buttons as one, with the shelf.
    private func moveControls() {
        let shift = shelfOpen ? -shelf.rise : overlay.isShown ? 0 : PlayerSheet.drop
        guard shift != controlsShift else { return }
        controlsShift = shift
        overlay.setShift(shift)
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.placeButtons()
            self.promptView.setShift(shift)
        }
    }

    private func setShelf(_ open: Bool) {
        if open {
            commitScrub()
            overlayUntil = .distantPast
            if let engine { showFacts(engine) }
            shelf.foundAt = linksFound
            shelf.details.startRunning()
            shelf.move(to: .open)
        } else {
            shelf.details.stopRunning()
        }
        shelfOpen = open
        promptView.takesFocus = false
        focusView.takesFocus = !open && menu == .none
        if let engine {
            updateOverlay(engine)
            updatePrompt(engine)
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func setMenu(_ new: Menu) {
        if new != .none { commitScrub() }
        // Audio first; the button a list opened from only when the list closes.
        if menu == .none { lastButton = nil }
        menu = new
        // Left off Audio reaches a prompt.
        promptView.takesFocus = new == .buttons && promptView.alpha > 0
        focusView.takesFocus = new == .none && !shelfOpen
        for button in buttons { button.takesFocus = new == .buttons }
        if new != .tracks, !trackList.isHidden {
            UIView.animate(withDuration: Motion.fadeDuration) { self.trackList.alpha = 0 } completion: { _ in
                if self.trackList.alpha == 0 { self.trackList.isHidden = true }
            }
        }
        showControls()
        if let engine { updateOverlay(engine) }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func buttonPressed(_ button: PlayerButton) {
        guard let engine else { return }
        lastButton = button
        let audio = button === audioButton
        trackList.load { [unowned self] in
            audio ? MenuPanel.Menu(rows: audioRows(engine)) : subtitleMenu(engine)
        }
        // Unfolds out of its bottom right corner, over the buttons. Its alpha
        // lands at 1 at once: tvOS wouldn't focus into it otherwise.
        trackList.layer.anchorPoint = CGPoint(x: 1, y: 1)
        trackList.center = CGPoint(x: view.bounds.width - 80,
                                   y: view.bounds.height - PlayerPrompt.bottom - PlayerButton.size - 24)
        trackList.isHidden = false
        trackList.alpha = 0
        trackList.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.trackList.alpha = 1
            self.trackList.transform = .identity
        }
        setMenu(.tracks)
    }

    private func loadShow() {
        guard video != nil, !isDemo else { return }
        let meta = meta
        showTask = Task { [weak self] in
            let found = await PlayLauncher.shared.episodes(of: meta)
            guard !Task.isCancelled else { return }
            self?.show = found
        }
    }

    private func shelfEpisodes() -> [PlayerShelf.Episode] {
        guard let show else { return [] }
        let hideSpoilers = UserDefaults.standard.bool(forKey: DetailHideSpoilers.key)
        return show.episodes.map { episode in
            let saved = progress.progress(for: ProgressStore.key(metaID: show.meta.id, video: episode))
            let playing = episode.id == video?.id
            let watched = saved.map { $0.fraction >= 0.95 } ?? false
            let started = saved?.isStarted == true
            let state = FixedFocusCardState(
                label: episode.seasonEpisodeCode, fraction: started ? saved?.fraction : nil,
                right: playing ? "Playing" : watched ? "Watched" : started ? saved?.remainingTimeText : nil,
                blurred: hideSpoilers && !watched && !started && !playing)
            return PlayerShelf.Episode(
                item: MetaItem(id: episode.id, type: "episode", name: episode.title ?? episode.seasonEpisodeCode,
                               background: episode.thumbnail ?? show.meta.background),
                subtitle: nil, state: state, playing: playing
            ) { [weak self] in self?.pickEpisode(episode, of: show.meta) }
        }
    }

    private func shelfSources() -> [PlayerShelf.Source] {
        let all = (linksOwn ? nil : PlayLauncher.shared.links(meta, video)) ?? links
        let playable = all.filter { !$0.stream.isTorrent }
        return playable.map { link in
            PlayerShelf.Source(entry: link, addon: link.sourceAddonName, playing: link.rejectionKey == entry.rejectionKey) { [weak self] in
                self?.pickSource(link)
            }
        }
    }

    /// What plays goes on until the new one is ready. No link: the source list.
    private func pickEpisode(_ episode: MetaVideo, of show: MetaItem) {
        setShelf(false)
        guard episode.id != video?.id else { return }
        let current = entry
        episodeTask?.cancel()
        episodeTask = Task { [weak self] in
            let ready = await PlayLauncher.shared.ready(episode, of: show, current: current)
            guard let self, !Task.isCancelled else { return }
            self.episodeTask = nil
            if let ready {
                self.play(ready, finished: false)
            } else {
                self.close()
                SourcePicker.shared.open(show, episode)
            }
        }
    }

    /// The same spot on another link.
    private func pickSource(_ link: StreamEntry) {
        setShelf(false)
        guard let engine, link.rejectionKey != entry.rejectionKey else { return }
        if counts { save(engine) }
        entry = link
        reload(engine, from: position)
    }

    private func audioRows(_ engine: AetherEngine) -> [MenuPanel.Row] {
        engine.audioTracks.enumerated().map { index, track in
            MenuPanel.Row(title: audioTitle(track), detail: audioDetail(track, among: engine.audioTracks), active: track.id == engine.activeAudioTrackIndex,
                          header: index == 0 ? "Audio Track" : nil) { [weak self] in
                self?.audioPicked = true
                PlaybackMemory.update(self?.meta.id ?? "") { $0.audioLanguage = track.language }
                Task { try? await engine.selectAudioTrack(index: track.id) }
            }
        }
    }

    private func subtitleMenu(_ engine: AetherEngine) -> MenuPanel.Menu {
        let tracks = engine.subtitleTracks
        let active = tracks.first { $0.id == engine.activeSubtitleTrackIndex }
        if let active { lastSubtitle = active.id }
        let language = settings.preferredSubtitleLanguage.prefix(2).lowercased()
        let next = active ?? tracks.first { $0.id == lastSubtitle }
            ?? tracks.first { $0.language?.lowercased().hasPrefix(language) == true } ?? tracks.first
        var rows: [MenuPanel.Row] = []
        if let next {
            rows.append(MenuPanel.Row(title: "On", active: active != nil) { [weak self] in self?.pickSubtitle(next, engine) })
        }
        rows.append(MenuPanel.Row(title: "Off", active: active == nil) { [weak self] in
            engine.clearSubtitle()
            PlaybackMemory.update(self?.meta.id ?? "") { $0.subtitleLanguage = "off" }
        })
        if let next {
            rows.append(MenuPanel.Row(title: "Track", detail: subtitleTitle(next), separated: true, page: { [unowned self] in
                MenuPanel.Menu(rows: subtitleTrackRows(tracks, active: active, engine))
            }))
            rows.append(MenuPanel.Row(title: "Delay", detail: subtitleDelayText ?? "None", page: { [unowned self] in
                subtitleDelayMenu(engine)
            }))
        }
        rows.append(MenuPanel.Row(title: "Style", detail: styleDetail(active),
                                  separated: next == nil, page: { [unowned self] in subtitleStyleMenu }))
        return MenuPanel.Menu(title: "Subtitles", rows: rows)
    }

    /// What's in the file, then the add-ons', the preferred language first:
    /// they can be hundreds.
    private func subtitleTrackRows(_ tracks: [TrackInfo], active: TrackInfo?, _ engine: AetherEngine) -> [MenuPanel.Row] {
        let language = settings.preferredSubtitleLanguage.prefix(2).lowercased()
        let external = tracks.filter(\.isExternal)
        let preferred = external.filter { $0.language?.lowercased().hasPrefix(language) == true }
        let parts = [("Included", tracks.filter { !$0.isExternal }),
                     ("External", preferred + external.filter { track in !preferred.contains { $0.id == track.id } })]
            .filter { !$0.1.isEmpty }
        return parts.enumerated().flatMap { part, entry in
            entry.1.enumerated().map { index, track in
                MenuPanel.Row(title: subtitleTitle(track), detail: subtitleDetail(track, among: entry.1), active: track.id == active?.id,
                              separated: part > 0 && index == 0, header: index == 0 ? entry.0 : nil) { [weak self] in
                    self?.pickSubtitle(track, engine)
                }
            }
        }
    }

    /// The format; the add-on, or the file's own title where the list needs it
    /// to tell two tracks apart ("Full" and "Signs & Songs").
    private func subtitleDetail(_ track: TrackInfo, among tracks: [TrackInfo]) -> String? {
        let alike = tracks.filter { subtitleTitle($0) == subtitleTitle(track) && $0.codec == track.codec }.count > 1
        var parts = track.isExternal || alike ? fileTitle(track).map { [$0] } ?? [] : []
        if !unknownFormats.contains(track.id) { parts.append(subtitleFormat(track.codec)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A picture track is drawn as its authors drew it: Style can't reach it.
    private func styleDetail(_ active: TrackInfo?) -> String {
        if let active, ["hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvb_subtitle"].contains(active.codec) {
            return "Not used by \(subtitleFormat(active.codec))"
        }
        return SubtitleText.isStandard ? "Default" : "Custom"
    }

    private func subtitleFormat(_ codec: String) -> String {
        switch codec {
        case "subrip", "srt": "SRT"
        case "ass", "ssa": "ASS"
        case "webvtt": "VTT"
        case "mov_text": "Text"
        case "hdmv_pgs_subtitle", "pgssub": "PGS"
        case "dvd_subtitle": "VobSub"
        case "dvb_subtitle": "DVB"
        default: codec.uppercased()
        }
    }

    private var subtitleDelayText: String? {
        guard subtitleDelay != 0 else { return nil }
        return String(format: "%g s %@", abs(subtitleDelay), subtitleDelay > 0 ? "Later" : "Earlier")
    }

    private func subtitleDelayMenu(_ engine: AetherEngine) -> MenuPanel.Menu {
        func row(_ title: String, _ delay: @escaping (Double) -> Double, active: Bool = false, separated: Bool = false) -> MenuPanel.Row {
            MenuPanel.Row(title: title, active: active, separated: separated, stays: true) { [weak self] in
                guard let self else { return }
                subtitleDelay = delay(subtitleDelay)
                showSubtitle(engine)
            }
        }
        return MenuPanel.Menu(title: subtitleDelayText ?? "Delay", rows: [
            row("Earlier") { $0 - Self.subtitleDelayStep },
            row("Later") { $0 + Self.subtitleDelayStep },
            row("No Delay", { _ in 0 }, active: subtitleDelay == 0, separated: true)
        ])
    }

    private func pickSubtitle(_ track: TrackInfo, _ engine: AetherEngine) {
        subtitleDelay = 0
        engine.selectSubtitleTrack(index: track.id)
        PlaybackMemory.update(meta.id) { $0.subtitleLanguage = track.language }
    }

    private var subtitleStyleMenu: MenuPanel.Menu {
        MenuPanel.Menu(title: "Style", rows: SubtitleText.choices.map { choice in
            MenuPanel.Row(title: choice.title, detail: choice.name, page: { [unowned self] in subtitleChoiceMenu(choice) })
        })
    }

    private func subtitleChoiceMenu(_ choice: any SubtitleChoice) -> MenuPanel.Menu {
        MenuPanel.Menu(title: choice.title, rows: choice.names.map { name in
            MenuPanel.Row(title: name, active: name == choice.name, stays: true) { [weak self] in
                guard let self else { return }
                choice.name = name
                for text in [subtitleText, subtitleTop] { text.render(within: view.bounds.width * 0.7) }
                fitSubtitles()
            }
        })
    }

    private func fitSubtitles() {
        let bounds = view.bounds
        let size = subtitleText.fitted
        subtitleText.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - Self.subtitleRest - size.height,
                                    width: size.width, height: size.height)
        let top = subtitleTop.fitted
        subtitleTop.frame = CGRect(x: (bounds.width - top.width) / 2, y: Self.subtitleTopInset,
                                   width: top.width, height: top.height)
    }

    // MARK: Screen

    private func tick() {
        if away { return }
        if let engine {
            if streamLost(engine) { return }
            if engine.state == .ended { reachedEnd(engine); return }
            if !hasPlayed {
                var errored = false
                if case .error = engine.state { errored = true }
                if errored || Date().timeIntervalSince(loadStarted) > Self.firstFrameSeconds {
                    linkFailed()
                    return
                }
            }
            // A resume reads near zero until its seek lands.
            if engine.state == .playing, engine.currentTime > 0, engine.currentTime >= resumeFloor - 5 {
                hasPlayed = true
                reveal()
                resumeFloor = 0
                if mountPaused {
                    engine.pause()
                    engine.volume = 1
                }
                mountPaused = false
            }
            if hasPlayed, engine.state == .playing { played += Self.tickInterval }
            let paused = engine.state == .paused
            if paused, !wasPaused { saveAndPush() }
            wasPaused = paused
            showSubtitle(engine)
            preferAtmos(engine)
            saveDuringPlayback(engine)
            tickScrub()
            updateOverlay(engine)
            findNext(engine)
            updatePrompt(engine)
            if shelfOpen { showFacts(engine) }
        }
        let showReadout = failure != nil || PerformanceSettingsStore.shared.settings.showPlayerDiagnostics
        readout.isHidden = !showReadout
        guard showReadout else { return }
        readout.text = "  " + lines().joined(separator: "  \n  ") + "  "
        let size = readout.sizeThatFits(CGSize(width: 1200, height: 900))
        readout.frame = CGRect(x: 60, y: 40, width: size.width, height: size.height + 16)
    }

    private var mark: PlayerOverlay.Mark? {
        if let scan { return .scan(forward: scan.direction > 0, level: scan.level) }
        if stepDirection != 0, scrubTarget != nil { return .step(forward: stepDirection > 0) }
        return engine?.state == .paused && landing == nil ? .paused : nil
    }

    /// A prompt keeps its claim while the controls are gone, so they come up on it.
    private var barHasFocus: Bool {
        menu == .none && !shelfOpen && (promptView.alpha == 0 || promptLeft)
    }

    private func updateOverlay(_ engine: AetherEngine) {
        let waiting = revealed && (!hasPlayed || episodeTask != nil || dryAt != nil || engine.state == .seeking || engine.isBuffering)
        overlay.setBarFocused(barHasFocus)
        overlay.update(
            time: scrubTarget ?? landing ?? position, duration: engine.duration,
            mark: mark, waiting: waiting
        )
        let resident = engine.residentRanges
        overlay.setHeld(resident.isEmpty ? [position...max(position, engine.bufferedPosition)] : resident,
                        duration: engine.duration)
        let shown = !shelfOpen && !arriving && (menu != .none || scrubTarget != nil || revealed && !hasPlayed
            || (!controlsDismissed && (engine.state == .paused || Date() < overlayUntil)))
        if overlay.isShown, !shown, !controlsDismissed, menu == .none, !shelfOpen {
            backGuardUntil = Date().addingTimeInterval(Self.backGuardSeconds)
        }
        overlay.setShown(shown)
        moveControls()
        placeSubtitles()
        let alpha: CGFloat = shown && !(scrubTarget != nil && isDetached) ? 1 : 0
        if audioButton.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) {
                for button in self.buttons { button.alpha = alpha }
            }
        }
        if !shelfOpen { shelf.move(to: alpha > 0 && hasPlayed ? .peek : .away) }
        overlay.setScrubbing(scrubTarget != nil || scan != nil, detached: isDetached)
    }

    /// What's really playing, to check against what the stream claims.
    private func showFacts(_ engine: AetherEngine) {
        typealias Fact = DetailsPage.Fact
        var left = [Fact(label: "Title", value: meta.name)]
        if let video, let season = video.season, let episode = video.episode {
            left.append(Fact(label: "Episode", value: "Season \(season), Episode \(episode)"))
        }
        left.append(Fact(label: "Add-on", value: entry.addonName))
        if let file = entry.stream.behaviorHints?.filename, !file.isEmpty {
            left.append(Fact(label: "File", value: file))
        }
        if engine.duration > 0 {
            let minutes = Int(engine.duration / 60)
            let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
            left.append(Fact(label: "Length", value: length))
        }
        // As the source card says them.
        if let size = entry.facts.size { left.append(Fact(label: "File Size", value: size)) }
        let bytes = entry.stream.sizeBytes ?? 0
        let rate = entry.facts.bitrate
            ?? (bytes > 0 && engine.duration > 0 ? String(format: "%.2f Mbps", Double(bytes) * 8 / engine.duration / 1_000_000) : nil)
            ?? (engine.sourceVideoBitrate > 0 ? String(format: "%.2f Mbps", Double(engine.sourceVideoBitrate) / 1_000_000) : nil)
        if let rate { left.append(Fact(label: "Bitrate", value: rate)) }

        var right: [Fact] = []
        if let probe, probe.videoWidth > 0 {
            let tier = probe.videoWidth >= 3200 ? " (4K)" : probe.videoWidth >= 1800 ? " (1080p)"
                : probe.videoWidth >= 1200 ? " (720p)" : ""
            let video = [probe.videoCodecName.map(Self.codecName), "\(probe.videoWidth) × \(probe.videoHeight)\(tier)",
                         probe.videoFrameRate.map { String(format: "%.3g fps", $0) }]
            right.append(Fact(label: "Video", value: video.compactMap { $0 }.joined(separator: " · ")))
            var range = Self.rangeName(engine.videoFormat)
            if engine.videoFormat != probe.videoFormat {
                range += " (file: \(Self.rangeName(probe.videoFormat)))"
            } else if let profile = probe.dvProfile {
                range += " Profile \(profile)"
            }
            right.append(Fact(label: "Range", value: range))
        }
        if let audio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) {
            right.append(Fact(label: "Audio", value: audioFact(audio, engine)))
        }
        if let output = Self.audioOutput() { right.append(Fact(label: "Output", value: output)) }
        let subtitle = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        right.append(Fact(label: "Subtitles", value: subtitle.map { "\(languageName($0.language)) · \(subtitleFormat($0.codec))" } ?? "Off"))
        if let container = engine.sourceContainerFormat.map(Self.containerName)
            ?? (engine.videoRoute == .remoteBypass ? "HLS" : nil) {
            right.append(Fact(label: "Container", value: container))
        }
        switch engine.videoRoute {
        case .software: right.append(Fact(label: "Decoding", value: "Software"))
        case .loopback, .remoteBypass: right.append(Fact(label: "Decoding", value: "Hardware"))
        default: break
        }
        shelf.details.show(left: left, right: right)
    }

    /// Where the sound goes, and as how many channels.
    private static func audioOutput() -> String? {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.currentRoute.outputs.first else { return nil }
        let channels = session.outputNumberOfChannels
        let layout = [1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][channels] ?? "\(channels) ch"
        switch port.portType {
        case .HDMI: return "HDMI · \(layout)"
        case .airPlay: return "AirPlay · \(port.portName)"
        default: return "\(port.portName) · \(layout)"
        }
    }

    /// libavformat's names ("matroska,webm") as people know them.
    private static func containerName(_ format: String) -> String {
        let first = format.split(separator: ",").first.map(String.init) ?? format
        let names = ["matroska": "MKV", "mov": "MP4", "mpegts": "MPEG-TS", "avi": "AVI", "hls": "HLS", "flv": "FLV"]
        return names[first] ?? first.uppercased()
    }

    /// A bridged or decoded track has lost its objects, whatever the file says.
    private func audioFact(_ track: TrackInfo, _ engine: AetherEngine) -> String {
        let channels = [1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][track.channels] ?? "\(track.channels) ch"
        let format = "\(Self.codecName(track.codec)) \(channels)"
        let objects = track.isAtmos ? "Atmos" : track.isDTSX ? "DTS:X" : nil
        switch engine.audioDelivery {
        case .streamCopy: return [format, objects].compactMap { $0 }.joined(separator: " ")
        case .bridged, .decoded: return format + (objects.map { ", converted, no \($0)" } ?? ", converted")
        default: return format
        }
    }

    private static func codecName(_ codec: String) -> String {
        let names = ["h264": "H.264", "eac3": "E-AC-3", "ac3": "AC-3", "truehd": "TrueHD", "opus": "Opus", "flac": "FLAC"]
        return names[codec.lowercased()] ?? codec.uppercased()
    }

    private static func rangeName(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    private func audioTitle(_ track: TrackInfo) -> String {
        var title = languageName(track.language)
        if track.isCommentary { title += ", Commentary" }
        if track.isVisualImpaired { title += ", Audio Description" }
        return title
    }

    /// The format; the file's own title only where two tracks would read the same.
    private func audioDetail(_ track: TrackInfo, among tracks: [TrackInfo]) -> String {
        let alike = tracks.filter { audioTitle($0) == audioTitle(track) && audioFormat($0) == audioFormat(track) }.count > 1
        return ((alike ? fileTitle(track).map { [$0] } ?? [] : []) + [audioFormat(track)]).joined(separator: " · ")
    }

    private func audioFormat(_ track: TrackInfo) -> String {
        let codec = switch track.codec {
        case "eac3": "E-AC-3"
        case "ac3": "AC-3"
        case "truehd": "TrueHD"
        case "flac": "FLAC"
        case "opus": "Opus"
        default: track.codec.uppercased()
        }
        let channels = switch track.channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(track.channels) ch"
        }
        let layout = track.isAtmos ? "Atmos" : track.isDTSX ? "DTS:X" : channels
        return "\(codec) \(layout)"
    }

    /// Untitled, the engine makes a name up: "ENG (subrip)".
    private func fileTitle(_ track: TrackInfo) -> String? {
        guard track.name != languageName(track.language), !track.name.hasSuffix("(\(track.codec))") else { return nil }
        return track.name.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
    }

    private func subtitleTitle(_ track: TrackInfo) -> String {
        var title = languageName(track.language)
        if track.isForced { title += ", Forced" }
        if track.isHearingImpaired { title += ", SDH" }
        if track.isCommentary { title += ", Commentary" }
        return title
    }

    private func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Low at rest; above whatever comes up, on the same spring. Gone while
    /// scrubbing: the line belongs to a moment left behind.
    private func placeSubtitles() {
        var floor = overlay.isShown ? Self.subtitleClear : Self.subtitleRest
        if shelfOpen {
            floor = PlayerShelf.margin + PlayerShelf.height + 24
        } else if promptView.alpha > 0 {
            floor = max(floor, PlayerPrompt.bottom - controlsShift + promptView.bounds.height + 24)
        }
        if floor != subtitleFloor {
            subtitleFloor = floor
            UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
                self.subtitles.transform = CGAffineTransform(translationX: 0, y: Self.subtitleRest - floor)
            }
        }
        let alpha: CGFloat = scrubTarget != nil || scan != nil ? 0 : 1
        if subtitles.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) {
                self.subtitles.alpha = alpha
                self.fixedSubtitles.alpha = alpha
            }
        }
    }

    /// The ASS track on, kept across ticks; nil on anything else.
    private func updateAssTrack(_ engine: AetherEngine) -> AssTrack? {
        let track = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        guard let track, let header = track.assHeader ?? engine.sidecarASSHeader else {
            assTrack?.stop()
            assTrack = nil
            return nil
        }
        if assTrack?.trackID != track.id {
            assTrack?.stop()
            assTrack = AssTrack(trackID: track.id, header: header, fonts: engine.fontAttachments, host: fixedSubtitles) { [weak self, weak engine] in
                engine.flatMap { self?.subtitleTime($0) } ?? 0
            }
        }
        return assTrack
    }

    /// The engine's time, run on between its updates, with the delay.
    private func subtitleTime(_ engine: AetherEngine) -> Double {
        let source = engine.clock.sourceTime
        let now = CACurrentMediaTime()
        if source != subtitleClock.time { (subtitleClock.time, subtitleClock.at) = (source, now) }
        var time = source
        if engine.state == .playing { time += min(now - subtitleClock.at, Self.subtitleClockReach) }
        // An update landing just behind isn't a step back; a seek is.
        if time < subtitleClock.shown, subtitleClock.shown - time < Self.subtitleClockReach { time = subtitleClock.shown }
        subtitleClock.shown = time
        return time - subtitleDelay
    }

    @objc private func subtitleFrame() {
        guard let engine, subtitleTime(engine) >= nextSubtitleEdge else { return }
        showSubtitle(engine)
    }

    private func showSubtitle(_ engine: AetherEngine) {
        let time = subtitleTime(engine)
        nextSubtitleEdge = engine.subtitleCues.reduce(.infinity) { edge, cue in
            min(edge, cue.startTime > time ? cue.startTime : .infinity, cue.endTime > time ? cue.endTime : .infinity)
        }
        let cues = engine.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
        var runs: [SubtitleText.Run]
        var top: [SubtitleText.Run] = []
        if let ass = updateAssTrack(engine) {
            (runs, top) = ass.dialogue(in: engine.subtitleCues, at: time)
        } else {
            runs = SubtitleText.joined(cues.compactMap { cue -> [SubtitleText.Run]? in
                switch cue.body {
                case .richText(let parts): parts.map { .init(text: $0.text, italic: $0.isItalic) }
                case .text(let line): [.init(text: Self.plain(line), italic: false)]
                case .image: nil
                }
            })
        }
        let image = cues.lazy.compactMap { cue -> SubtitleImage? in
            if case .image(let picture) = cue.body { return picture }
            return nil
        }.first

        let bounds = view.bounds
        let bottomChanged = subtitleText.show(runs, within: bounds.width * 0.7)
        let topChanged = subtitleTop.show(top, within: bounds.width * 0.7)
        if bottomChanged || topChanged { fitSubtitles() }

        if let image {
            subtitleImage.image = UIImage(cgImage: image.cgImage)
            subtitleImage.frame = CGRect(
                x: image.position.minX * bounds.width, y: image.position.minY * bounds.height,
                width: image.position.width * bounds.width, height: image.position.height * bounds.height
            )
        } else {
            subtitleImage.image = nil
        }
    }

    /// A line as it reads: no leftover tags.
    private static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>|\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
    }

    private func lines() -> [String] {
        var out: [String] = []
        if let failure { out.append("FAILED  \(failure)") }
        guard let engine else { return out }

        if let probe {
            var source = "\(probe.videoCodecName ?? "?") \(probe.videoWidth)x\(probe.videoHeight)"
            if let fps = probe.videoFrameRate { source += String(format: " %.3f fps", fps) }
            if probe.isDolbyVision { source += " DV\(probe.dvProfile.map { " P\($0)" } ?? "")" }
            out.append("source     \(source)")
        } else {
            out.append("source     (probing)")
        }
        out.append("presenting \(engine.videoFormat)   route \(engine.videoRoute.rawValue)")
        let screen = AetherEngine.displayCapabilities
        out.append("display    DV \(screen.supportsDolbyVision)  HDR10 \(screen.supportsHDR10)  HLG \(screen.supportsHLG)")

        let audio = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        let atmos = audio?.isAtmos == true ? " Atmos" : audio?.isDTSX == true ? " DTS:X" : ""
        out.append("audio      \(audio.map { "\($0.codec) \($0.channels)ch\(atmos) \($0.language ?? "")" } ?? "none")")
        out.append("delivery   \(engine.audioDelivery.rawValue)   tracks \(engine.audioTracks.count)")
        out.append("decoder    \(engine.activeAudioDecoder ?? "none")")
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        out.append("output     \(port)  \(session.outputNumberOfChannels)ch of \(session.maximumOutputNumberOfChannels)")
        if let info = engine.errorInfo { out.append("error      \(info.message)") }

        let subtitle = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        out.append("subtitle   \(subtitle.map { "\($0.codec) \($0.language ?? "")" } ?? "off")   tracks \(engine.subtitleTracks.count)")

        out.append("state      \(engine.state)")
        out.append(String(format: "time       %.0f / %.0f s   buffered to %.0f s",
                          engine.currentTime, engine.duration, engine.clock.bufferedPosition))
        out.append("memory     \(memoryMB()) MB")
        return out
    }

    private func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}
