import os
import AVKit
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

/// Takes focus, so the remote's presses reach the controller.
private final class PlayerFocusView: UIView {
    var takesFocus = true
    override var canBecomeFocused: Bool { takesFocus }
}

/// The app's one glass, as a backing for UIKit controls.
private final class GlassBacking: UIView {
    private let host: UIViewController

    init<S: Shape>(_ shape: S) {
        host = UIHostingController(rootView: Color.clear.liquidGlass(in: shape))
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
        insertSubview(glass, at: 0)
        insertSubview(platter, at: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { takesFocus && super.canBecomeFocused }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        platter.frame = bounds
        platter.layer.cornerRadius = bounds.width / 2
        imageView.map(bringSubviewToFront)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations {
            self.platter.alpha = focused ? 1 : 0
            self.tintColor = focused ? UIColor.black.withAlphaComponent(0.85)
                                     : UIColor.white.withAlphaComponent(FixedFocusText.primary)
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}

/// One track: nothing at rest, focused a white capsule, as the hold menus' rows.
private final class TrackCell: UICollectionViewCell {
    static let height: CGFloat = 66

    private let platter = UIView()
    private let check = UIImageView()
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        platter.backgroundColor = .white
        platter.alpha = 0
        check.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        check.contentMode = .center
        title.font = .systemFont(ofSize: 28, weight: .medium)
        for sub in [platter, check, title] as [UIView] { contentView.addSubview(sub) }
        paint(focused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: TrackList.Row) {
        title.text = row.title
        check.isHidden = !row.active
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = contentView.bounds.insetBy(dx: 6, dy: 0)
        platter.frame = inner
        platter.layer.cornerRadius = inner.height / 2
        check.frame = CGRect(x: inner.minX + 18, y: 0, width: 28, height: inner.height)
        title.frame = CGRect(x: inner.minX + 62, y: 0, width: inner.width - 90, height: inner.height)
    }

    private func paint(focused: Bool) {
        let color = focused ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        title.textColor = color
        check.tintColor = color
        platter.alpha = focused ? 1 : 0
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations { self.paint(focused: focused) }
    }
}

/// The tracks to pick from: a glass panel rising from its button. A collection
/// view: a tvOS table spaces its rows out and fades its edges.
private final class TrackList: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    struct Row {
        let title: String
        let active: Bool
        let pick: () -> Void
    }

    static let width: CGFloat = 620
    private static let inset: CGFloat = 16
    private static let maxHeight: CGFloat = 640

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: TrackCell.height / 2 + inset, style: .continuous))
    private let list: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: width - inset * 2, height: TrackCell.height)
        layout.minimumLineSpacing = 0
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private var rows: [Row] = []
    var picked: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
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
        list.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    /// Unfolds out of its bottom right corner. Its alpha lands at 1 at once:
    /// tvOS wouldn't focus into it otherwise.
    func open(_ rows: [Row], rightEdge: CGFloat, bottom: CGFloat) {
        self.rows = rows
        transform = .identity
        let height = min(CGFloat(rows.count) * TrackCell.height + Self.inset * 2, Self.maxHeight)
        frame = CGRect(x: rightEdge - Self.width, y: bottom - height, width: Self.width, height: height)
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

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        rows.firstIndex(where: \.active).map { IndexPath(item: $0, section: 0) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        rows[indexPath.item].pick()
        picked()
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
    private static let rest: CFTimeInterval = 3
    private static let speed: Double = 60
    private static let edge: CGFloat = 40

    private let font: UIFont
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

    init(font: UIFont) {
        self.font = font
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
        let total = Self.rest + moving
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -shift]
        animation.keyTimes = [0, NSNumber(value: Self.rest / total), 1]
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

/// The bare overlay: what's playing, where it is, and a spinner while the
/// engine waits. Shows nothing that takes focus.
private final class PlayerOverlay: UIView {
    /// A view, so the gradient follows the bounds without its own animation.
    private final class Shade: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
    }

    private(set) var isShown = false

    private let controls = UIView()
    private let shade = Shade()
    private let title = UILabel()
    private let episode = UILabel()
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private let bar = UIView()
    private let held = UIView()
    private let fill = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let preview = UIImageView()
    private static let previewSize = CGSize(width: 480, height: 270)
    private let previewHolder = UIView()
    private let previewGlass = GlassBacking(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
    private let previewSpinner = UIActivityIndicatorView(style: .medium)
    private let scrubStart = UIView()
    private var scrubStartFraction: CGFloat = 0
    private var fraction: CGFloat = 0
    private var isScrubbing = false
    private var promptUp = false
    private var heldSpan: (from: CGFloat, to: CGFloat) = (0, 0)
    private static let barHeight: CGFloat = 6

    init(title text: String, episode line: String?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        controls.alpha = 0
        addSubview(controls)
        addSubview(spinner)
        spinner.color = UIColor.white.withAlphaComponent(0.75)

        let gradient = shade.layer as? CAGradientLayer
        gradient?.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        controls.addSubview(shade)

        episode.font = .systemFont(ofSize: 24)
        episode.textColor = UIColor.white.withAlphaComponent(FixedFocusText.secondary)
        title.text = text
        episode.text = line
        title.font = .systemFont(ofSize: 32, weight: .medium)
        title.textColor = UIColor.white.withAlphaComponent(0.75)
        for label in [elapsed, remaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.55)
        }
        remaining.textAlignment = .right
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        bar.layer.cornerRadius = Self.barHeight / 2
        bar.clipsToBounds = true
        bar.transform = CGAffineTransform(scaleX: 1, y: 1.67)
        fill.backgroundColor = UIColor.white.withAlphaComponent(0.75)
        held.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        bar.addSubview(held)
        bar.addSubview(fill)
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
        scrubStart.backgroundColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        scrubStart.isHidden = true
        previewHolder.addSubview(clip)
        previewHolder.layer.shadowColor = UIColor.black.cgColor
        previewHolder.layer.shadowOpacity = 0.7
        previewHolder.layer.shadowRadius = 36
        previewHolder.layer.shadowOffset = CGSize(width: 0, height: 10)
        previewHolder.layer.shadowPath = UIBezierPath(roundedRect: clip.bounds, cornerRadius: Spotlight.cornerRadius).cgPath
        previewHolder.isHidden = true
        for sub in [title, episode, elapsed, remaining, bar, scrubStart, previewHolder] as [UIView] {
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
        shade.frame = CGRect(x: 0, y: bounds.height - 360, width: bounds.width, height: 360)
        // Left above the bar, level with the buttons, clear of them.
        title.frame = CGRect(x: inset, y: bounds.height - 208, width: width - 220, height: 40)
        episode.frame = CGRect(x: inset, y: bounds.height - 240, width: width - 220, height: 30)
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        bar.center = CGPoint(x: bounds.midX, y: bounds.height - 143)
        fill.frame = CGRect(x: 0, y: 0, width: width * fraction, height: Self.barHeight)
        placeHeld()
        placeElapsed()
        remaining.frame = CGRect(x: inset + width - 200, y: bounds.height - 126, width: 200, height: 32)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        placePreview()
    }

    private func placeHeld() {
        let width = bar.bounds.width
        held.frame = CGRect(x: width * heldSpan.from, y: 0,
                            width: width * max(heldSpan.to - heldSpan.from, 0), height: Self.barHeight)
    }

    /// Left of the bar; scrubbing, under the marker.
    private func placeElapsed() {
        let width = elapsed.intrinsicContentSize.width
        let marker = bar.frame.minX + bar.bounds.width * fraction - width / 2
        let x = isScrubbing ? min(max(marker, bar.frame.minX), bar.frame.maxX - width) : bar.frame.minX
        elapsed.frame = CGRect(x: x, y: bounds.height - 126, width: width, height: 32)
        scrubStart.frame = CGRect(x: bar.frame.minX + bar.bounds.width * scrubStartFraction - 1,
                                  y: bar.center.y - 14, width: 2, height: bar.frame.maxY - bar.center.y + 14)
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
        let alpha: CGFloat = isScrubbing || promptUp ? 0 : 1
        UIView.animate(withDuration: Motion.fadeDuration) {
            self.title.alpha = alpha
            self.episode.alpha = alpha
        }
    }

    /// How far subtitles have to stay above the bottom of the screen.
    var subtitleFloor: CGFloat { isShown ? 250 : 90 }

    func setScrubbing(_ scrubbing: Bool) {
        if scrubbing, previewHolder.isHidden {
            previewHolder.isHidden = false
            showWaiting(preview.image == nil)
        } else if !scrubbing {
            previewHolder.isHidden = true
        }
        guard scrubbing != isScrubbing else { return }
        scrubStartFraction = fraction
        scrubStart.isHidden = !scrubbing
        isScrubbing = scrubbing
        placeElapsed()
        fadeTitle()
        UIView.animate(withDuration: Motion.fadeDuration) { self.remaining.alpha = scrubbing ? 0 : 1 }
    }

    func move(time: Double, duration: Double, mark: String? = nil) {
        fraction = duration > 0 ? CGFloat(min(max(time / duration, 0), 1)) : 0
        fill.frame.size.width = bar.bounds.width * fraction
        placePreview()
        elapsed.text = duration > 0 ? [mark, Self.clock(time)].compactMap { $0 }.joined(separator: "  ") : nil
        placeElapsed()
        remaining.text = duration > 0 ? "-" + Self.clock(max(duration - time, 0)) : nil
    }

    /// What's on disk ahead of the playhead, a shade over the empty bar.
    func setHeld(from start: Double, to end: Double, duration: Double) {
        guard duration > 0 else { return }
        heldSpan = (CGFloat(min(max(start / duration, 0), 1)), CGFloat(min(max(end / duration, 0), 1)))
        placeHeld()
    }

    func update(time: Double, duration: Double, mark: String?, waiting: Bool) {
        move(time: time, duration: duration, mark: mark)
        if waiting != spinner.isAnimating {
            if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        UIView.animate(withDuration: Motion.fadeDuration) { self.controls.alpha = shown ? 1 : 0 }
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
/// episode as a card with its picture. Glass at rest; focused white with dark content, 5 % larger.
/// The controller takes its Select: no button, so nothing fires twice.
private final class PlayerPrompt: UIView {
    private static let pillHeight: CGFloat = 88
    private static let iconSize: CGFloat = 34
    /// Level with the buttons' feet.
    fileprivate static let bottom: CGFloat = 168
    private static let cardWidth: CGFloat = 420
    private static let cardPadding: CGFloat = 16
    private static let pictureHeight: CGFloat = (cardWidth - cardPadding * 2) * 9 / 16

    var takesFocus = false
    override var canBecomeFocused: Bool { takesFocus }

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
    private let platter = UIView()
    private let picture = UIImageView()
    private let icon = UIImageView(image: UIImage(systemName: "forward.end.fill"))
    private let heading = UILabel()
    private let detail = UILabel()
    private var isCard = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        platter.backgroundColor = .white
        platter.alpha = 0
        platter.layer.cornerCurve = .continuous
        platter.layer.cornerRadius = Spotlight.cornerRadius
        icon.contentMode = .scaleAspectFit
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = Spotlight.cornerRadius - Self.cardPadding / 2
        picture.layer.cornerCurve = .continuous
        heading.font = .systemFont(ofSize: 25, weight: .medium)
        detail.font = .systemFont(ofSize: 24)
        for sub in [glass, platter, picture, icon, heading, detail] as [UIView] { addSubview(sub) }
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
            : CGSize(width: text + Self.iconSize + 72, height: Self.pillHeight)
        frame = CGRect(x: 80, y: page.height - Self.bottom - size.height, width: size.width, height: size.height)
        if isFocused { transform = CGAffineTransform(scaleX: 1.05, y: 1.05) }
        picture.isHidden = !isCard
        icon.isHidden = isCard
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        platter.frame = bounds
        guard isCard else {
            icon.frame = CGRect(x: 24, y: (bounds.height - Self.iconSize) / 2,
                                width: Self.iconSize, height: Self.iconSize)
            let x = icon.frame.maxX + 20
            heading.frame = CGRect(x: x, y: 12, width: bounds.width - x - 24, height: 32)
            detail.frame = CGRect(x: x, y: heading.frame.maxY, width: bounds.width - x - 24, height: 32)
            return
        }
        let inset = Self.cardPadding
        let width = bounds.width - inset * 2
        picture.frame = CGRect(x: inset, y: inset, width: width, height: Self.pictureHeight)
        heading.frame = CGRect(x: inset, y: picture.frame.maxY + 12, width: width, height: 32)
        detail.frame = CGRect(x: inset, y: heading.frame.maxY + 2, width: width, height: 32)
    }

    private func restyle() {
        heading.textColor = isFocused ? UIColor.black.withAlphaComponent(0.85)
                                      : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        icon.tintColor = heading.textColor
        detail.textColor = isFocused ? UIColor.black.withAlphaComponent(0.65)
                                     : UIColor.white.withAlphaComponent(FixedFocusText.secondary)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations {
            self.platter.alpha = focused ? 1 : 0
            self.restyle()
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
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
    private let subtitleText = UILabel()
    private let subtitleImage = UIImageView()
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
    private static let scanSpeeds: [Double] = [30, 120, 300]
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

    /// A skip left alone goes after this; it's back while the controls are up.
    private static let skipSeconds: TimeInterval = 10
    /// Without an outro from IntroDB, the next episode comes up this long before the end.
    private static let nextLeadSeconds: Double = 120
    /// Its link is looked for this much before it comes up.
    private static let nextSearchSeconds: Double = 60
    /// Between the end of the file and the next episode playing by itself.
    private static let nextCountdown: TimeInterval = 5

    private enum Prompt: Equatable {
        case skip(String, to: Double)
        case next
    }

    private var segments: PlayerSegments?
    private var segmentsTask: Task<Void, Never>?
    private var prompt: Prompt?
    private var promptSince = Date.distantPast
    private var dismissedPrompt: Prompt?
    private var nextUp: PlayLauncher.NextEpisode?
    private var nextPicture: UIImage?
    private var nextTask: Task<Void, Never>?
    private var nextSearched = false
    private var endedAt: Date?

    private enum Menu { case none, buttons, tracks }
    private var menu = Menu.none
    private weak var lastButton: PlayerButton?
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
        for sub in [focusView, surface, subtitleImage, subtitleText, overlay, audioButton, subtitleButton,
                    promptView, trackList, shelf,
                    readout] as [UIView] {
            view.addSubview(sub)
        }

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

        subtitleText.numberOfLines = 0
        subtitleText.textAlignment = .center
        subtitleText.textColor = .white
        subtitleText.font = .systemFont(ofSize: CGFloat(settings.subtitleSize), weight: .medium)
        subtitleText.shadowColor = .black
        subtitleText.shadowOffset = CGSize(width: 0, height: 2)

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
        let resume = resume
        loadTask = Task { [weak self] in
            do {
                let probe = try await engine.load(url: url, startPosition: resume, options: options)
                self?.probe = probe
            } catch is CancellationError {
            } catch {
                if self?.attempt == attempt { self?.linkFailed() }
            }
            // Left mid-load: the load outlives the stop, so stop what it started.
            if self?.closed ?? true { engine.stop() }
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
        endScrub()
        saveFinal()
        loadTask?.cancel()
        linkSearch?.cancel()
        segmentsTask?.cancel()
        nextTask?.cancel()
        showTask?.cancel()
        episodeTask?.cancel()
        dropStills()
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
            case .playPause: engine.togglePlayPause()
            default: super.pressesBegan(presses, with: event)
            }
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
        case .rightArrow:
            showControls()
            arrowPressed(1)
        default:
            showControls()
            super.pressesBegan(presses, with: event)
        }
    }

    /// A press or a swipe, the same. Down: off the buttons or the prompt to the
    /// bar, else the shelf. Up: to a prompt on screen, else the buttons.
    private func stepVertically(down: Bool, _ engine: AetherEngine) {
        guard scan == nil, hasPlayed else { return }
        if menu == .buttons {
            if down {
                promptLeft = true
                setMenu(.none)
            }
            return
        }
        let toBar = down && promptView.takesFocus
        let toPrompt = !down && promptView.alpha > 0 && !promptView.takesFocus
        guard toBar || toPrompt else { return down ? setShelf(true) : setMenu(.buttons) }
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
        case .tracks: return setMenu(.buttons)
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

    private func moveScrub(to seconds: Double) {
        guard let engine, hasPlayed, engine.duration > 0 else { return }
        scrubTarget = min(max(seconds, 0), max(engine.duration - 1, 0))
        scrubCommitAt = Date().addingTimeInterval(Self.scrubCommitSeconds)
        guard let target = scrubTarget else { return }
        overlay.setScrubbing(true)
        waitForRest()
        loadPreview()
        guard Date().timeIntervalSince(lastScrubDraw) >= Self.scrubDrawInterval else { return }
        lastScrubDraw = Date()
        overlay.move(time: target, duration: engine.duration, mark: scanLabel)
    }

    private var isFine: Bool { engine?.state == .paused && scan == nil }

    private func arrowPressed(_ direction: Double) {
        if scan != nil {
            shiftScan(direction)
        } else if panning, scrubTarget != nil {
            // A swipe ending in a click on the pad's edge.
            commitScrub(resume: true)
        } else {
            glide = 0
            moveScrub(to: (scrubTarget ?? position) + direction * Self.scrubStep)
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
        if shelfOpen { return panVertical && velocity.y < 0 && shelf.closes }
        if menu != .none { return menu == .buttons && panVertical && velocity.y > 0 }
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
            if shelfOpen {
                setShelf(false)
            } else if let engine {
                stepVertically(down: pan.velocity(in: view).y > 0, engine)
            }
            return
        }
        switch pan.state {
        case .began:
            panning = true
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
        if nextUp != nil, engine.state == .ended || time >= nextStart(engine) { return .next }
        if let recap = segments?.recap, recap.contains(time) { return .skip("Skip Recap", to: recap.upperBound) }
        if let intro = segments?.intro, intro.contains(time) { return .skip("Skip Intro", to: intro.upperBound) }
        if nextUp == nil, nextTask == nil, let outro = segments?.outro, outro.contains(time) {
            return .skip("Skip Credits", to: outro.upperBound)
        }
        return nil
    }

    private func updatePrompt(_ engine: AetherEngine) {
        let wanted = wantedPrompt(engine)
        if wanted != prompt {
            prompt = wanted
            promptSince = Date()
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
        var shown = wanted != nil && wanted != dismissedPrompt && !busy
        if case .skip = wanted, Date().timeIntervalSince(promptSince) > Self.skipSeconds, !overlay.isShown {
            shown = false
        }
        let alpha: CGFloat = shown ? 1 : 0
        overlay.setPromptUp(shown)
        if promptView.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) { self.promptView.alpha = alpha }
        }
        // Scrubbing is being on the bar; with the controls gone, nothing holds focus there.
        if scrubTarget != nil || scan != nil { promptLeft = true } else if !overlay.isShown { promptLeft = false }
        let focused = shown && (menu == .buttons || (menu == .none && !shelfOpen && !promptLeft))
        guard focused != promptView.takesFocus else { return }
        promptView.takesFocus = focused
        focusView.takesFocus = !focused && menu == .none && !shelfOpen
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
        dropStills()
        engine?.stop()

        meta = next.meta
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
        trackList.open(button === audioButton ? audioRows(engine) : subtitleRows(engine),
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
        engine.audioTracks.map { track in
            TrackList.Row(title: audioTitle(track), active: track.id == engine.activeAudioTrackIndex) { [weak self] in
                self?.audioPicked = true
                PlaybackMemory.update(self?.meta.id ?? "") { $0.audioLanguage = track.language }
                Task { try? await engine.selectAudioTrack(index: track.id) }
            }
        }
    }

    private func subtitleRows(_ engine: AetherEngine) -> [TrackList.Row] {
        let active = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        let off = TrackList.Row(title: "Off", active: active == nil) { [weak self] in
            engine.clearSubtitle()
            PlaybackMemory.update(self?.meta.id ?? "") { $0.subtitleLanguage = "off" }
        }
        return [off] + engine.subtitleTracks.map { track in
            TrackList.Row(title: subtitleTitle(track), active: track.id == active?.id) { [weak self] in
                engine.selectSubtitleTrack(index: track.id)
                PlaybackMemory.update(self?.meta.id ?? "") { $0.subtitleLanguage = track.language }
            }
        }
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

    private var scanLabel: String? {
        scan.map { String(repeating: $0.direction > 0 ? "▸" : "◂", count: $0.level + 1) }
    }

    private func updateOverlay(_ engine: AetherEngine) {
        let waiting = !hasPlayed || episodeTask != nil || dryAt != nil || engine.state == .seeking || engine.isBuffering
        overlay.update(
            time: scrubTarget ?? landing ?? position, duration: engine.duration,
            mark: scanLabel, waiting: waiting
        )
        overlay.setHeld(from: position, to: engine.bufferedPosition, duration: engine.duration)
        let shown = !shelfOpen && (menu != .none || scrubTarget != nil || !hasPlayed
            || (!controlsDismissed && (engine.state == .paused || Date() < overlayUntil)))
        overlay.setShown(shown)
        let alpha: CGFloat = shown && scrubTarget == nil && scan == nil ? 1 : 0
        if audioButton.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) {
                for button in self.buttons { button.alpha = alpha }
            }
        }
        overlay.setScrubbing(scrubTarget != nil || scan != nil)
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
        let extra = track.isAtmos ? "Atmos" : track.isDTSX ? "DTS:X" : "\(track.channels) ch"
        var title = "\(languageName(track.language)), \(track.codec.uppercased()) \(extra)"
        if track.isCommentary { title += ", Commentary" }
        if track.isVisualImpaired { title += ", Audio Description" }
        return title
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

    private func showSubtitle(_ engine: AetherEngine) {
        let time = engine.clock.sourceTime
        let cue = engine.subtitleCues.first { $0.startTime <= time && time < $0.endTime }
        var text: String?
        var image: SubtitleImage?
        switch cue?.body {
        case .image(let picture): image = picture
        case .some: text = cue?.text
        case nil: break
        }

        subtitleText.text = text
        let width = view.bounds.width - 300
        let height = subtitleText.sizeThatFits(CGSize(width: width, height: 400)).height
        subtitleText.frame = CGRect(x: 150, y: view.bounds.height - overlay.subtitleFloor - height, width: width, height: height)

        if let image {
            let bounds = view.bounds
            subtitleImage.image = UIImage(cgImage: image.cgImage)
            subtitleImage.frame = CGRect(
                x: image.position.minX * bounds.width, y: image.position.minY * bounds.height,
                width: image.position.width * bounds.width, height: image.position.height * bounds.height
            )
        } else {
            subtitleImage.image = nil
        }
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
