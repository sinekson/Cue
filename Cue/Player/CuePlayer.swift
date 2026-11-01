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
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> PlayerController {
        PlayerController(request: request, progress: progress, settings: settings, onClose: onClose)
    }

    func updateUIViewController(_ controller: PlayerController, context: Context) {}
}

/// A change of focus, as the hold menus' rows: quick both ways, not the system's
/// slow way out.
private func focusChange(duration: TimeInterval = 0.12, _ changes: @escaping () -> Void) {
    UIView.animate(withDuration: duration, delay: 0,
                   options: [.curveEaseOut, .beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve],
                   animations: changes)
}

/// The hold menus' lift under a focused platter; it fades with the platter.
private func liftShadow(_ view: UIView) {
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.25
    view.layer.shadowRadius = 12
    view.layer.shadowOffset = CGSize(width: 0, height: 6)
}

/// Takes focus, so the remote's presses reach the controller.
private final class PlayerFocusView: UIView {
    var takesFocus = true
    override var canBecomeFocused: Bool { takesFocus }
}

/// The app's one glass, as a backing for UIKit controls.
private final class GlassBacking: UIView {
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

/// One track: nothing at rest, focused a white capsule, as the hold menus' rows.
private final class TrackCell: UICollectionViewCell {
    static let height: CGFloat = 66
    /// With a value under the title.
    private static let tallHeight: CGFloat = 92
    /// The line's room above a row that starts a new part.
    private static let separation: CGFloat = 20
    private static let headerHeight: CGFloat = 46

    private static func room(_ separated: Bool, _ header: Bool) -> CGFloat {
        (separated ? separation : 0) + (header ? headerHeight : 0)
    }

    static func height(of row: TrackList.Row) -> CGFloat {
        (row.detail == nil ? height : tallHeight) + room(row.separated, row.header != nil)
    }

    /// What grows with focus; the line and header above it stay put.
    private let face = UIView()
    private let platter = UIView()
    private let check = UIImageView()
    private let title = RunningLine(font: .systemFont(ofSize: 28, weight: .medium), rest: 0.5)
    private let detail = RunningLine(font: .systemFont(ofSize: 24), rest: 0.5)
    private let chevron = UIImageView()
    private let separator = UIView()
    private let header = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        platter.backgroundColor = .white
        platter.alpha = 0
        liftShadow(platter)
        check.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        check.contentMode = .center
        title.running = false
        detail.running = false
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        chevron.contentMode = .center
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        header.font = TrackList.headingFont
        header.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        for sub in [separator, header, face] as [UIView] { contentView.addSubview(sub) }
        for sub in [platter, check, title, detail, chevron] as [UIView] { face.addSubview(sub) }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { focusChange { self.paint() } }
    }

    func show(_ row: TrackList.Row) {
        title.text = row.title
        detail.text = row.detail ?? ""
        detail.isHidden = row.detail == nil
        check.isHidden = !row.active
        chevron.isHidden = row.page == nil
        separator.isHidden = !row.separated
        header.text = row.header
        header.isHidden = row.header == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let room = Self.room(!separator.isHidden, !header.isHidden)
        let inner = contentView.bounds.insetBy(dx: 6, dy: 0)
            .inset(by: UIEdgeInsets(top: room, left: 0, bottom: 0, right: 0))
        header.frame = CGRect(x: 24, y: room - Self.headerHeight, width: inner.width - 36, height: Self.headerHeight)
        separator.frame = CGRect(x: inner.minX + 62, y: Self.separation / 2, width: inner.width - 80, height: 1)
        face.bounds = CGRect(origin: .zero, size: inner.size)
        face.center = CGPoint(x: inner.midX, y: inner.midY)
        platter.frame = face.bounds
        platter.layer.cornerRadius = min(inner.height, Self.height) / 2
        platter.layer.shadowPath = UIBezierPath(roundedRect: platter.bounds, cornerRadius: platter.layer.cornerRadius).cgPath
        check.frame = CGRect(x: 18, y: 0, width: 28, height: inner.height)
        chevron.frame = CGRect(x: inner.width - 54, y: 0, width: 28, height: inner.height)
        let width = inner.width - 90 - (chevron.isHidden ? 0 : 36)
        if detail.isHidden {
            title.frame = CGRect(x: 62, y: 0, width: width, height: inner.height)
        } else {
            title.frame = CGRect(x: 62, y: 12, width: width, height: 36)
            detail.frame = CGRect(x: 62, y: 48, width: width, height: 30)
        }
    }

    private func paint() {
        let focused = isFocused
        let color = focused ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        title.color = color
        check.tintColor = color
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

/// A button's menu: a glass panel rising from it, its title on top, a row can
/// open a page of its own, Back returns. A collection view: a tvOS table spaces
/// its rows out and fades its edges.
private final class TrackList: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Row {
        let title: String
        var detail: String?
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
    }

    static let width: CGFloat = 620
    private static let inset: CGFloat = 16
    private static let headingHeight: CGFloat = 44
    static let headingFont = UIFont.systemFont(ofSize: 24, weight: .medium)
    private static let maxHeight: CGFloat = 640

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: TrackCell.height / 2 + inset, style: .continuous))
    private let list: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private let heading = UILabel()
    /// Built anew on the way back, so a row shows what its page changed.
    private var pages: [(menu: () -> Menu, from: Int)] = []
    private var rows: [Row] = []
    private var rightEdge: CGFloat = 0
    private var bottom: CGFloat = 0
    private var focusedRow: Int?
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
        list.register(TrackCell.self, forCellWithReuseIdentifier: "row")
        addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [list] }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        heading.frame = CGRect(x: Self.inset + 24, y: Self.inset, width: bounds.width - Self.inset * 2 - 48, height: Self.headingHeight)
        list.frame = bounds.inset(by: UIEdgeInsets(top: Self.inset + headingRoom, left: Self.inset,
                                                   bottom: Self.inset, right: Self.inset))
    }

    private var headingRoom: CGFloat { heading.text == nil ? 0 : Self.headingHeight }

    private func height(of rows: [Row]) -> CGFloat {
        min(rows.reduce(0) { $0 + TrackCell.height(of: $1) } + Self.inset * 2 + headingRoom, Self.maxHeight)
    }

    private func panel(height: CGFloat) -> CGRect {
        CGRect(x: rightEdge - Self.width, y: bottom - height, width: Self.width, height: height)
    }

    /// Unfolds out of its bottom right corner. Its alpha lands at 1 at once:
    /// tvOS wouldn't focus into it otherwise.
    func open(_ menu: @escaping () -> Menu, rightEdge: CGFloat, bottom: CGFloat) {
        let first = menu()
        pages = [(menu, 0)]
        rows = first.rows
        heading.text = first.title
        focusedRow = nil
        self.rightEdge = rightEdge
        self.bottom = bottom
        transform = .identity
        let height = self.height(of: rows)
        frame = panel(height: height)
        list.reloadData()
        layoutIfNeeded()
        isHidden = false
        alpha = 0
        transform = CGAffineTransform(translationX: Self.width * 0.2, y: height * 0.2).scaledBy(x: 0.6, y: 0.6)
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.alpha = 1
            self.transform = .identity
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
        rows = menu.rows
        heading.text = menu.title
        focusedRow = focus
        UIView.transition(with: list, duration: Motion.fadeDuration, options: .transitionCrossDissolve) {
            self.list.reloadData()
            self.list.contentOffset = .zero
        }
        UIView.animate(withDuration: Motion.moveDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.frame = self.panel(height: self.height(of: self.rows))
            self.layoutIfNeeded()
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    func close() {
        guard !isHidden else { return }
        UIView.animate(withDuration: Motion.fadeDuration) { self.alpha = 0 } completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        (cell as? TrackCell)?.show(rows[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: Self.width - Self.inset * 2, height: TrackCell.height(of: rows[indexPath.item]))
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        (focusedRow ?? rows.firstIndex(where: \.active)).map { IndexPath(item: $0, section: 0) }
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
            (list.cellForItem(at: path) as? TrackCell)?.show(rows[path.item])
        }
    }
}

/// A tab of the shelf: focused a white capsule, the chosen one brighter at rest.
private final class PanelTab: UIView {
    private let platter = UIView()
    private let title = UILabel()

    var chosen = false {
        didSet { paint() }
    }

    init(_ text: String) {
        super.init(frame: .zero)
        platter.backgroundColor = .white
        platter.alpha = 0
        title.text = text
        title.font = .systemFont(ofSize: 28, weight: .medium)
        title.textAlignment = .center
        for sub in [platter, title] as [UIView] { addSubview(sub) }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { true }

    var width: CGFloat { title.intrinsicContentSize.width + 64 }

    override func layoutSubviews() {
        super.layoutSubviews()
        platter.frame = bounds
        platter.layer.cornerRadius = bounds.height / 2
        title.frame = bounds
    }

    private func paint() {
        title.textColor = isFocused ? UIColor.black.withAlphaComponent(0.85)
            : UIColor.white.withAlphaComponent(chosen ? FixedFocusText.primary : FixedFocusText.tertiary)
        platter.alpha = isFocused ? 1 : 0
        transform = isFocused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.paint() }
    }
}

/// Glass from the bottom: tabs, and a page under them. The tab follows the
/// focus; one height for every page, so a switch moves nothing.
private class PlayerSheet: UIView {
    fileprivate static let inset: CGFloat = 28
    private static let tabsGap: CGFloat = 16
    private static let tabSpacing: CGFloat = 8

    private let clip = UIView()
    private let glass: GlassBacking
    private let tabs: [PanelTab]
    /// One per tab; two tabs may share one.
    fileprivate var pages: [UIView] = []
    /// In the gap under the tabs: Down lands on the page's preferred row, not
    /// the nearest, and Up reaches a tab from anywhere along it.
    private let guide = UIFocusGuide()
    private(set) var current = 0
    private var reachedEdge = Date.distantPast

    private var onTabs: Bool { tabs.contains(where: \.isFocused) }

    init(tabs titles: [String], height: CGFloat) {
        let radius = TrackCell.height / 2 + Self.inset
        glass = GlassBacking(RoundedRectangle(cornerRadius: radius, style: .continuous))
        tabs = titles.map(PanelTab.init)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height))
        isHidden = true
        clip.clipsToBounds = true
        clip.layer.cornerRadius = radius
        clip.layer.cornerCurve = .continuous
        addSubview(glass)
        addSubview(clip)
        for tab in tabs { clip.addSubview(tab) }
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset + TrackCell.height),
            guide.heightAnchor.constraint(equalToConstant: Self.tabsGap)
        ])
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
        let top = Self.inset + TrackCell.height + Self.tabsGap
        return CGRect(x: Self.inset, y: top, width: bounds.width - Self.inset * 2, height: bounds.height - top - Self.inset / 2)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [tabs[current]] }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        clip.frame = bounds
        var x = Self.inset + 8
        for tab in tabs where !tab.isHidden {
            tab.frame = CGRect(x: x, y: Self.inset, width: tab.width, height: TrackCell.height)
            x += tab.width + Self.tabSpacing
        }
        for page in pages { page.frame = pageFrame }
    }

    fileprivate func setTabHidden(_ index: Int, _ hidden: Bool) {
        tabs[index].isHidden = hidden
        if hidden, current == index, let other = tabs.firstIndex(where: { !$0.isHidden }) { choose(other) }
        setNeedsLayout()
    }

    fileprivate func choose(_ index: Int) {
        current = index
        showTab()
    }

    /// Off the screen and back, never faded: tvOS won't focus into a transparent view.
    func open() {
        guard isHidden else { return }
        pageWillOpen()
        showTab()
        isHidden = false
        transform = awayTransform
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.transform = .identity
        }
    }

    func close() {
        guard !isHidden else { return }
        UIView.animate(withDuration: Motion.moveDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.transform = self.awayTransform
        } completion: { _ in
            if self.transform != .identity { self.isHidden = true }
        }
    }

    private var awayTransform: CGAffineTransform {
        CGAffineTransform(translationX: 0, y: (superview?.bounds.height ?? 0) - center.y + bounds.height / 2 + 40)
    }

    /// Up from the tabs leaves it. A press that climbed to them reaches the
    /// controller after the focus has moved, so it has to have rested there.
    var closes: Bool { onTabs && Date().timeIntervalSince(reachedEdge) > 0.2 }

    /// The page as it opens or its tab comes up.
    fileprivate func showPage(_ index: Int) {}
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
        if let tab = context.nextFocusedView as? PanelTab, let index = tabs.firstIndex(of: tab), index != current {
            choose(index)
        } else {
            aimGuide()
        }
    }
}

/// One line of text. Too long for its place it runs: a rest, then round through
/// a second copy in the same label, back where it began.
private final class RunningLine: UIView {
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
        private static let font = UIFont.systemFont(ofSize: 24)

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

    private static let factHeight: CGFloat = 50

    private var rows: [Row] = []

    override func layoutSubviews() {
        super.layoutSubviews()
        let column = (bounds.width - 40) / 2
        let half = (rows.count + 1) / 2
        for (index, row) in rows.enumerated() {
            let left = index < half
            row.frame = CGRect(x: left ? 8 : bounds.midX + 20, y: 12 + CGFloat(left ? index : index - half) * Self.factHeight,
                               width: column, height: Self.factHeight)
        }
    }

    func show(_ new: [Fact]) {
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

/// One link, on the shelf: the add-on's words on the shelf's glass, a pane when focused.
private final class SourceCard: UICollectionViewCell {
    static let size = CGSize(width: 680, height: PlayerShelf.cardRow)
    /// The episode card's growth in points: as a share, a wide card grows too far.
    private static let lift = PlayerShelf.cardWidth * FixedFocusMetrics.movingFocusLift / size.width
    private static let lineGap: CGFloat = 15
    private static let fadeHeight: CGFloat = 56
    private static let nameFont = UIFont.systemFont(ofSize: 25, weight: .medium)
    private static let detailFont = UIFont.systemFont(ofSize: 23)

    private let card = UIView()
    private let frost = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let edge = UIImageView(image: FixedFocusCardEdge.rim)
    private let outline = UIView()
    /// The add-on's lines, one label each with a gap between, so its breaks
    /// still read when one wraps. Lines past the card fade out.
    private let text = UIView()
    private let fade = CAGradientLayer()
    private var nameLines: [UILabel] = []
    private var detailLines: [UILabel] = []
    /// The foot's own line, kept clear of the add-on's text, however long.
    private let addon = UILabel()
    private let playing = UILabel()
    private var isPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        frost.isUserInteractionEnabled = false
        outline.isUserInteractionEnabled = false
        outline.layer.borderWidth = FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        contentView.addSubview(outline)
        FixedFocusRing.attachShadow(to: outline)
        text.clipsToBounds = true
        fade.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        playing.font = Self.detailFont
        playing.text = "Playing"
        playing.sizeToFit()
        addon.font = Self.detailFont
        for sub in [frost, edge, text, addon, playing] as [UIView] { card.addSubview(sub) }
        applyFocus(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The add-on's own words, its line breaks kept.
    func show(_ entry: StreamEntry, addon: String?, playing isPlaying: Bool) {
        self.addon.text = addon
        nameLines = lines(entry.displayName, into: nameLines, font: Self.nameFont)
        detailLines = lines(entry.displayDetail, into: detailLines, font: Self.detailFont)
        self.isPlaying = isPlaying
        playing.isHidden = !isPlaying
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
            line.font = font
            line.numberOfLines = 0
            line.lineBreakMode = .byWordWrapping
            text.addSubview(line)
            pool.append(line)
        }
        for (line, words) in zip(pool, wanted) { line.text = words }
        return pool
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre: they may be grown (transformed).
        card.bounds = contentView.bounds
        card.center = CGPoint(x: bounds.midX, y: bounds.midY)
        frost.frame = card.bounds
        edge.frame = card.bounds
        outline.center = card.center
        sizeOutline()
        let inner = card.bounds.insetBy(dx: 28, dy: 28)
        let hasFoot = addon.text != nil || isPlaying
        let footHeight = playing.bounds.height
        let footY = inner.maxY - footHeight
        playing.frame.origin = CGPoint(x: inner.maxX - playing.bounds.width, y: footY)
        addon.frame = CGRect(x: inner.minX, y: footY, width: inner.width - playing.bounds.width - 20, height: footHeight)
        let room = hasFoot ? footY - Self.lineGap - inner.minY : inner.height
        text.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width,
                            height: hasFoot ? room : card.bounds.maxY - inner.minY)
        var y: CGFloat = 0
        for (index, line) in (nameLines + detailLines).enumerated() {
            if index > 0 { y += Self.lineGap }
            let height = ceil(line.sizeThatFits(CGSize(width: inner.width, height: .greatestFiniteMagnitude)).height)
            line.frame = CGRect(x: 0, y: y, width: inner.width, height: height)
            y += height
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = text.bounds
        let from = (text.bounds.height - Self.fadeHeight) / max(text.bounds.height, 1)
        fade.locations = [NSNumber(value: Double(from)), 1]
        CATransaction.commit()
        text.layer.mask = y > room ? fade : nil
    }

    /// Sized, not scaled: its line keeps its width.
    private func sizeOutline() {
        let size = contentView.bounds.size
        outline.bounds = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        outline.layer.cornerRadius = Spotlight.cornerRadius * scale
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

    /// As `FixedFocusDestinationCell`: the same lift, shadow and text levels.
    private func applyFocus(_ focused: Bool) {
        let bright = UIColor.white.withAlphaComponent(focused ? FixedFocusText.primary : FixedFocusText.secondary)
        let dim = UIColor.white.withAlphaComponent(focused ? FixedFocusText.secondary : FixedFocusText.tertiary)
        nameLines.forEach { $0.textColor = bright }
        detailLines.forEach { $0.textColor = dim }
        playing.textColor = dim
        addon.textColor = dim
        // Only the glass at rest; a pane for what's playing, a blur focused.
        card.backgroundColor = UIColor.white.withAlphaComponent(!focused && isPlaying ? 0.07 : 0)
        frost.alpha = focused ? 0.9 : 0
        edge.alpha = focused ? 1 : 0.5
        scale = focused ? 1 + Self.lift - (pressed ? 1 - FixedFocusMetrics.pressScale : 0) : 1
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        sizeOutline()
        outline.alpha = focused ? 1 : 0
        if focused { superview?.bringSubviewToFront(self) }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            self.applyFocus(focused)
        } completion: { _ in }
    }
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
        /// Named only when the links come from more than one.
        let addon: String?
        let playing: Bool
        let pick: () -> Void
    }

    private enum Tab: Int { case details, episodes, sources }

    private static let card = CGSize(width: 480, height: 270)
    private static let growth: CGFloat = 15
    fileprivate static let cardWidth = card.width
    fileprivate static let cardRow = card.height + FixedFocusMetrics.infoGap + FixedFocusMetrics.captionLineOffset
        + FixedFocusMetrics.factsHeight
    static let height = PlayerSheet.inset * 2 + TrackCell.height + 16 + cardRow + growth * 2

    /// Filled as it opens: what's playing may have changed.
    var fill: () -> (episodes: [Episode], sources: [Source]) = { ([], []) }

    let details = DetailsPage()
    private let episodesRow = PlayerShelf.row()
    private let sourcesRow = PlayerShelf.row()
    private var episodes: [Episode] = []
    private var sources: [Source] = []

    init() {
        super.init(tabs: ["Details", "Episodes", "Sources"], height: Self.height)
        for (row, size) in [(episodesRow, CGSize(width: Self.card.width, height: Self.cardRow)),
                            (sourcesRow, SourceCard.size)] {
            (row.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize = size
            row.dataSource = self
            row.delegate = self
        }
        episodesRow.register(FixedFocusDestinationCell.self, forCellWithReuseIdentifier: "card")
        sourcesRow.register(SourceCard.self, forCellWithReuseIdentifier: "card")
        add(pages: [details, episodesRow, sourcesRow])
    }

    private static func row() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 24
        layout.sectionInset = UIEdgeInsets(top: growth, left: 8, bottom: growth, right: 8)
        let row = UICollectionView(frame: .zero, collectionViewLayout: layout)
        row.backgroundColor = .clear
        // The focused card and its shadow reach past the row; the sheet clips.
        row.clipsToBounds = false
        row.showsHorizontalScrollIndicator = false
        row.contentInsetAdjustmentBehavior = .never
        row.remembersLastFocusedIndexPath = false
        return row
    }

    override func pageTakesFocus(_ index: Int) -> Bool { index != Tab.details.rawValue }

    override func pageWillOpen() {
        (episodes, sources) = fill()
        setTabHidden(Tab.episodes.rawValue, episodes.isEmpty)
        layoutIfNeeded()
        episodesRow.reloadData()
        sourcesRow.reloadData()
        for (row, playing) in [(episodesRow, episodes.firstIndex(where: \.playing)),
                               (sourcesRow, sources.firstIndex(where: \.playing))] {
            row.layoutIfNeeded()
            if let playing {
                row.scrollToItem(at: IndexPath(item: playing, section: 0), at: .centeredHorizontally, animated: false)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === episodesRow ? episodes.count : sources.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
        if let card = cell as? FixedFocusDestinationCell {
            let episode = episodes[indexPath.item]
            card.configure(episode.item, subtitle: episode.subtitle, index: indexPath.item, rowCell: nil,
                           card: Self.card, cardState: episode.state)
        } else if let card = cell as? SourceCard {
            let source = sources[indexPath.item]
            card.show(source.entry, addon: source.addon, playing: source.playing)
        }
        return cell
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        (collectionView === episodesRow ? episodes.firstIndex(where: \.playing)
                                        : sources.firstIndex(where: \.playing))
            .map { IndexPath(item: $0, section: 0) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === episodesRow {
            episodes[indexPath.item].pick()
        } else {
            sources[indexPath.item].pick()
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
    private let held = UIView()
    private let fill = UIView()
    private let scrubSpan = UIView()
    private let scrubStart = UIView()
    private let scrubMarker = UIView()
    private let markIcon = UIImageView()
    private let markNumber = UILabel()
    private var mark: Mark?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let preview = UIImageView()
    private static let previewSize = CGSize(width: 480, height: 270)
    private let previewHolder = UIView()
    private let previewGlass = GlassBacking(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
    private let previewSpinner = UIActivityIndicatorView(style: .medium)
    private var scrubStartFraction: CGFloat = 0
    private var fraction: CGFloat = 0
    private var isScrubbing = false
    private var isDetached = false
    private var promptUp = false
    private var heldSpan: (from: CGFloat, to: CGFloat) = (0, 0)
    private static let barHeight: CGFloat = 6
    private static let restingFill: CGFloat = 0.75
    /// To 10 pt, focused.
    private static let barGrowth = CGAffineTransform(scaleX: 1, y: 1.67)

    init(title text: String, episode line: String?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        controls.alpha = 0
        addSubview(controls)
        addSubview(spinner)
        spinner.color = UIColor.white.withAlphaComponent(0.75)


        episode.font = .systemFont(ofSize: 24)
        episode.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        title.text = text
        episode.text = line
        title.font = .systemFont(ofSize: 32, weight: .medium)
        title.textColor = UIColor.white.withAlphaComponent(0.75)
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
        fill.backgroundColor = UIColor.white.withAlphaComponent(0.75)
        fill.alpha = Self.restingFill
        held.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        scrubSpan.backgroundColor = held.backgroundColor
        for sub in [held, scrubSpan, fill, scrubStart, scrubMarker] {
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
        previewGlass.frame = clip.bounds
        previewSpinner.color = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        previewSpinner.center = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        clip.addSubview(previewGlass)
        clip.addSubview(previewSpinner)
        clip.addSubview(preview)
        previewHolder.addSubview(clip)
        previewHolder.layer.shadowColor = UIColor.black.cgColor
        previewHolder.layer.shadowRadius = 36
        previewHolder.layer.shadowOffset = CGSize(width: 0, height: 10)
        previewHolder.layer.shadowPath = UIBezierPath(roundedRect: clip.bounds, cornerRadius: Spotlight.cornerRadius).cgPath
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
        controls.frame = bounds
        // Left above the bar, level with the buttons, clear of them.
        title.frame = CGRect(x: inset, y: bounds.height - 208, width: width - 220, height: 40)
        episode.frame = CGRect(x: inset, y: bounds.height - 240, width: width - 220, height: 30)
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
            fill.alpha = focused ? 1 : Self.restingFill
        }
    }

    /// Detached, the fill stops at the nearer of the two lines, the scrub's
    /// span between them.
    private func placeFill() {
        let (width, height) = (bar.bounds.width, Self.barHeight)
        let start = isDetached ? scrubStartFraction : fraction
        let (from, to) = (min(fraction, start), max(fraction, start))
        fill.frame = CGRect(x: 0, y: 0, width: width * from, height: height)
        scrubSpan.frame = CGRect(x: width * from, y: 0, width: width * (to - from), height: height)
        scrubStart.frame = CGRect(x: width * scrubStartFraction - 1, y: 0, width: 2, height: height)
        scrubMarker.frame = CGRect(x: width * fraction - 1, y: 0, width: 2, height: height)
    }

    private func placeHeld() {
        let width = bar.bounds.width
        held.frame = CGRect(x: width * heldSpan.from, y: 0,
                            width: width * max(heldSpan.to - heldSpan.from, 0), height: Self.barHeight)
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

    /// nil: time only (no still for that spot yet).
    func setPreview(_ image: CGImage?) {
        guard image !== preview.image?.cgImage else { return }
        preview.image = image.map { UIImage(cgImage: $0) }
        showWaiting(image == nil)
        previewHolder.isHidden = image == nil
    }

    private func showWaiting(_ waiting: Bool) {
        preview.isHidden = waiting
        previewGlass.isHidden = !waiting
        // A shadow falls under its shape too, and would darken the glass.
        previewHolder.layer.shadowOpacity = waiting ? 0 : 0.7
        if waiting { previewSpinner.startAnimating() } else { previewSpinner.stopAnimating() }
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
        if scrubbing, previewHolder.isHidden {
            previewHolder.isHidden = false
            showWaiting(preview.image == nil)
        } else if !scrubbing {
            previewHolder.isHidden = true
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
        UIView.animate(withDuration: Motion.fadeDuration) { self.held.alpha = detach ? 0 : 1 }
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

    /// What's on disk ahead of the playhead, a shade over the empty bar.
    func setHeld(from start: Double, to end: Double, duration: Double) {
        guard duration > 0 else { return }
        heldSpan = (CGFloat(min(max(start / duration, 0), 1)), CGFloat(min(max(end / duration, 0), 1)))
        placeHeld()
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
    fileprivate static let bottom: CGFloat = 168
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

    private func place() {
        guard let page = superview?.bounds else { return }
        transform = .identity
        let text = max(heading.intrinsicContentSize.width, detail.intrinsicContentSize.width)
        let size = isCard
            ? CGSize(width: Self.cardWidth, height: Self.cardPadding * 2 + Self.pictureHeight + 86)
            : CGSize(width: text + Self.pillPadding * 2, height: Self.pillHeight)
        frame = CGRect(x: 80, y: page.height - Self.bottom - size.height, width: size.width, height: size.height)
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
    /// Links tried silently after the first, then the source list.
    private static let maxRetries = 3
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
    private let isDemo: Bool
    private let progress: ProgressStore
    private let settings: PlayerSettings
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
    private let trackList = TrackList()
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
    /// How long the overlay stays after a press.
    private static let overlaySeconds: TimeInterval = 4
    private var overlayUntil = Date.distantPast
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
    private var show: (meta: MetaItem, episodes: [MetaVideo])?
    private var showTask: Task<Void, Never>?
    /// An episode from the shelf, its link being found.
    private var episodeTask: Task<Void, Never>?
    /// Stepped down off the prompt: it stays up, the bar has the remote.
    private var promptLeft = false

    init(request: PlaybackRequest, progress: ProgressStore, settings: PlayerSettings,
         onClose: @escaping () -> Void) {
        meta = request.meta
        video = request.video
        resume = request.resumePosition
        links = request.allEntries
        isDemo = request.isDemo
        self.progress = progress
        self.settings = settings
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
        view.backgroundColor = .black
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
        // Bounds and center: its transform is what moves it.
        let size = PlayerButton.size
        let center = view.bounds.height - PlayerPrompt.bottom - size / 2
        for (index, button) in buttons.reversed().enumerated() {
            button.bounds.size = CGSize(width: size, height: size)
            button.center = CGPoint(x: view.bounds.width - 80 - size / 2 - CGFloat(index) * (size + 20), y: center)
        }
        shelf.bounds.size = CGSize(width: view.bounds.width - 160, height: PlayerShelf.height)
        shelf.center = CGPoint(x: view.bounds.midX, y: view.bounds.height - 60 - PlayerShelf.height / 2)
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
            !$0.stream.isExternal && !$0.stream.isTorrent && !tried.contains($0.rejectionKey)
        }
        guard tried.count <= Self.maxRetries, let next else {
            let (meta, video, fromStart) = (meta, video, resume == nil)
            close()
            SourcePicker.shared.open(meta, video, fromStart: fromStart)
            return
        }
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

    private func close() {
        teardown()
        onClose()
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
        if press.type == .select, promptView.isFocused {
            promptPressed(engine)
            return
        }
        if shelfOpen {
            switch press.type {
            case .upArrow where shelf.closes: setShelf(false)
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
    /// bar, else the shelf. Up: to a prompt on screen, else the buttons; off the
    /// buttons the controls go; off a prompt, nothing (Right is the way to the
    /// buttons).
    private func stepVertically(down: Bool, _ engine: AetherEngine) {
        guard scan == nil, hasPlayed else { return }
        if menu == .buttons {
            if down { promptLeft = true }
            setMenu(.none)
            if !down { hideControls() }
            return
        }
        if !down && promptView.takesFocus { return }
        let toBar = down && promptView.takesFocus
        let toPrompt = !down && promptView.alpha > 0 && !promptView.takesFocus
        guard toBar || toPrompt else {
            if down { return setShelf(true) }
            // With the controls gone, Up brings them back on the bar.
            return overlay.isShown ? setMenu(.buttons) : showControls()
        }
        showControls()
        promptLeft = down
        updateOverlay(engine)
        updatePrompt(engine)
    }

    /// A recognizer, not `pressesBegan`: with a button or list focused, the
    /// system takes Back first and dismisses the player.
    @objc private func backPressed() {
        guard !shelfOpen else { return setShelf(false) }
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

    private func setShelf(_ open: Bool) {
        if open {
            commitScrub()
            overlayUntil = .distantPast
            if let engine { shelf.details.show(facts(engine)) }
            shelf.details.startRunning()
            shelf.open()
        } else {
            shelf.details.stopRunning()
            shelf.close()
        }
        shelfOpen = open
        promptView.takesFocus = false
        focusView.takesFocus = !open && menu == .none
        if let engine { updateOverlay(engine) }
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
        if new != .tracks { trackList.close() }
        showControls()
        if let engine { updateOverlay(engine) }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func buttonPressed(_ button: PlayerButton) {
        guard let engine else { return }
        lastButton = button
        let audio = button === audioButton
        trackList.open({ [unowned self] in
            audio ? TrackList.Menu(rows: audioRows(engine)) : subtitleMenu(engine)
        },
                       rightEdge: view.bounds.width - 80,
                       bottom: view.bounds.height - PlayerPrompt.bottom - PlayerButton.size - 24)
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
        let playable = all.filter { !$0.stream.isExternal && !$0.stream.isTorrent }
        let several = Set(playable.map(\.sourceAddonName)).count > 1
        return playable.map { link in
            PlayerShelf.Source(entry: link, addon: several ? link.sourceAddonName : nil, playing: link.rejectionKey == entry.rejectionKey) { [weak self] in
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

    private func audioRows(_ engine: AetherEngine) -> [TrackList.Row] {
        engine.audioTracks.enumerated().map { index, track in
            TrackList.Row(title: audioTitle(track), detail: audioDetail(track, among: engine.audioTracks), active: track.id == engine.activeAudioTrackIndex,
                          header: index == 0 ? "Audio Track" : nil) { [weak self] in
                self?.audioPicked = true
                PlaybackMemory.update(self?.meta.id ?? "") { $0.audioLanguage = track.language }
                Task { try? await engine.selectAudioTrack(index: track.id) }
            }
        }
    }

    private func subtitleMenu(_ engine: AetherEngine) -> TrackList.Menu {
        let tracks = engine.subtitleTracks
        let active = tracks.first { $0.id == engine.activeSubtitleTrackIndex }
        if let active { lastSubtitle = active.id }
        let language = settings.preferredSubtitleLanguage.prefix(2).lowercased()
        let next = active ?? tracks.first { $0.id == lastSubtitle }
            ?? tracks.first { $0.language?.lowercased().hasPrefix(language) == true } ?? tracks.first
        var rows: [TrackList.Row] = []
        if let next {
            rows.append(TrackList.Row(title: "On", active: active != nil) { [weak self] in self?.pickSubtitle(next, engine) })
        }
        rows.append(TrackList.Row(title: "Off", active: active == nil) { [weak self] in
            engine.clearSubtitle()
            PlaybackMemory.update(self?.meta.id ?? "") { $0.subtitleLanguage = "off" }
        })
        if let next {
            rows.append(TrackList.Row(title: "Track", detail: subtitleTitle(next), separated: true, page: { [unowned self] in
                TrackList.Menu(rows: subtitleTrackRows(tracks, active: active, engine))
            }))
            rows.append(TrackList.Row(title: "Delay", detail: subtitleDelayText ?? "None", page: { [unowned self] in
                subtitleDelayMenu(engine)
            }))
        }
        rows.append(TrackList.Row(title: "Style", detail: styleDetail(active),
                                  separated: next == nil, page: { [unowned self] in subtitleStyleMenu }))
        return TrackList.Menu(title: "Subtitles", rows: rows)
    }

    /// What's in the file, then the add-ons', the preferred language first:
    /// they can be hundreds.
    private func subtitleTrackRows(_ tracks: [TrackInfo], active: TrackInfo?, _ engine: AetherEngine) -> [TrackList.Row] {
        let language = settings.preferredSubtitleLanguage.prefix(2).lowercased()
        let external = tracks.filter(\.isExternal)
        let preferred = external.filter { $0.language?.lowercased().hasPrefix(language) == true }
        let parts = [("Included", tracks.filter { !$0.isExternal }),
                     ("External", preferred + external.filter { track in !preferred.contains { $0.id == track.id } })]
            .filter { !$0.1.isEmpty }
        return parts.enumerated().flatMap { part, entry in
            entry.1.enumerated().map { index, track in
                TrackList.Row(title: subtitleTitle(track), detail: subtitleDetail(track, among: entry.1), active: track.id == active?.id,
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

    private func subtitleDelayMenu(_ engine: AetherEngine) -> TrackList.Menu {
        func row(_ title: String, _ delay: @escaping (Double) -> Double, active: Bool = false, separated: Bool = false) -> TrackList.Row {
            TrackList.Row(title: title, active: active, separated: separated, stays: true) { [weak self] in
                guard let self else { return }
                subtitleDelay = delay(subtitleDelay)
                showSubtitle(engine)
            }
        }
        return TrackList.Menu(title: subtitleDelayText ?? "Delay", rows: [
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

    private var subtitleStyleMenu: TrackList.Menu {
        TrackList.Menu(title: "Style", rows: SubtitleText.choices.map { choice in
            TrackList.Row(title: choice.title, detail: choice.name, page: { [unowned self] in subtitleChoiceMenu(choice) })
        })
    }

    private func subtitleChoiceMenu(_ choice: any SubtitleChoice) -> TrackList.Menu {
        TrackList.Menu(title: choice.title, rows: choice.names.map { name in
            TrackList.Row(title: name, active: name == choice.name, stays: true) { [weak self] in
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
            if shelfOpen { shelf.details.show(facts(engine)) }
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
        let waiting = !hasPlayed || episodeTask != nil || dryAt != nil || engine.state == .seeking || engine.isBuffering
        overlay.setBarFocused(barHasFocus)
        overlay.update(
            time: scrubTarget ?? landing ?? position, duration: engine.duration,
            mark: mark, waiting: waiting
        )
        overlay.setHeld(from: position, to: engine.bufferedPosition, duration: engine.duration)
        let shown = !shelfOpen && (menu != .none || scrubTarget != nil || !hasPlayed
            || (!controlsDismissed && (engine.state == .paused || Date() < overlayUntil)))
        overlay.setShown(shown)
        placeSubtitles()
        let alpha: CGFloat = shown && !(scrubTarget != nil && isDetached) ? 1 : 0
        if audioButton.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) {
                for button in self.buttons { button.alpha = alpha }
            }
        }
        overlay.setScrubbing(scrubTarget != nil || scan != nil, detached: isDetached)
    }

    /// What's really playing, to check against what the stream claims.
    private func facts(_ engine: AetherEngine) -> [DetailsPage.Fact] {
        typealias Fact = DetailsPage.Fact
        var out = [Fact(label: "Title", value: meta.name)]
        if let video, let season = video.season, let episode = video.episode {
            out.append(Fact(label: "Episode", value: "Season \(season), Episode \(episode)"))
        }
        if let file = entry.stream.behaviorHints?.filename, !file.isEmpty {
            out.append(Fact(label: "File", value: file))
        }
        if engine.duration > 0 {
            let minutes = Int(engine.duration / 60)
            let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
            out.append(Fact(label: "Length", value: length))
        }
        if let label = entry.stream.fileSizeLabel { out.append(Fact(label: "File Size", value: label)) }
        out.append(Fact(label: "Add-on", value: entry.addonName))
        if let probe, probe.videoWidth > 0 {
            let tier = probe.videoWidth >= 3200 ? " (4K)" : probe.videoWidth >= 1800 ? " (1080p)"
                : probe.videoWidth >= 1200 ? " (720p)" : ""
            let video = [probe.videoCodecName.map(Self.codecName), "\(probe.videoWidth) × \(probe.videoHeight)\(tier)",
                         probe.videoFrameRate.map { String(format: "%.3g fps", $0) }]
            out.append(Fact(label: "Video", value: video.compactMap { $0 }.joined(separator: ", ")))
            var range = Self.rangeName(engine.videoFormat)
            if engine.videoFormat != probe.videoFormat {
                range += " (file: \(Self.rangeName(probe.videoFormat)))"
            } else if let profile = probe.dvProfile {
                range += " Profile \(profile)"
            }
            out.append(Fact(label: "Range", value: range))
        }
        let size = entry.stream.sizeBytes
        let rate = engine.sourceVideoBitrate > 0 ? engine.sourceVideoBitrate
            : size.map { engine.duration > 0 ? Int64(Double($0) * 8 / engine.duration) : 0 } ?? 0
        if rate > 0 { out.append(Fact(label: "Bitrate", value: String(format: "%.0f Mbps", Double(rate) / 1_000_000))) }
        if let audio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) {
            out.append(Fact(label: "Audio", value: audioFact(audio, engine)))
        }
        let subtitle = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        out.append(Fact(label: "Subtitles", value: subtitle.map { [$0.language, $0.codec].compactMap { $0 }.joined(separator: ", ") } ?? "Off"))
        out.append(Fact(label: "Route", value: engine.videoRoute.rawValue))
        return out
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
            floor = 60 + PlayerShelf.height + 24
        } else if promptView.alpha > 0 {
            floor = max(floor, PlayerPrompt.bottom + promptView.bounds.height + 24)
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
