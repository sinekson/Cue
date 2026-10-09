import SwiftUI
import UIKit

// MARK: - Model

/// One episode as the Detail page's episode row shows it: everything
/// already worked out (the row only draws).
struct EpisodeRowItem: Equatable {
    let id: String
    let season: Int
    let number: Int
    /// The episode's title (under the box).
    let title: String
    /// Under the title: its length, when it aired / airs.
    let facts: String
    let synopsis: String?
    let image: String?
    /// The card's state line — Continue Watching's.
    let state: EpisodeRowState
}

/// A card's state line, as on Continue Watching's cards: which episode on
/// the left; a progress bar and the time left, or a status on the right.
struct EpisodeRowState: Equatable {
    let label: String
    /// In progress: how far (0…1), and "20m left".
    var progress: Double?
    var remaining: String?
    /// Not in progress: "Watched" (with a check), "Airs Fri", "45m".
    var status: String?
    var watched = false
}

// MARK: - SwiftUI

/// The Detail page's episode row — Home's Continue Watching row, exactly:
/// landscape cards sliding under a FIXED box whose content drifts, the
/// title and synopsis under it; native focus, our own Core Animation moves
/// (see `FixedFocusRowsController`). One continuous row across all seasons,
/// a season card between two seasons.
struct EpisodeRow: UIViewControllerRepresentable {
    let episodes: [EpisodeRowItem]
    /// The episode in the box (set from outside: opening on Play's episode,
    /// a jump from the season selector).
    let index: Int
    /// A new value moves focus into the row (onto the episode in the box).
    let focusRequest: Int
    /// Focus moved to episode `i` (native Left/Right).
    let onFocus: (Int) -> Void
    /// The row gained / lost focus.
    let onFocusChange: (Bool) -> Void
    let onSelect: (Int) -> Void
    /// Holding Select: the episode's menu.
    let menu: (Int) -> (title: String, entries: [MenuEntry])?

    /// The box plus the text under it.
    static let height: CGFloat = FixedFocusMetrics.height + EpisodeBoxView.infoHeight

    func makeUIViewController(context: Context) -> EpisodeRowController {
        let controller = EpisodeRowController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: EpisodeRowController, context: Context) {
        apply(to: controller)
    }

    private func apply(to controller: EpisodeRowController) {
        controller.onFocus = onFocus
        controller.onFocusChange = onFocusChange
        controller.onSelect = onSelect
        controller.menu = menu
        controller.update(episodes: episodes, index: index)
        controller.requestFocus(focusRequest)
    }
}

// MARK: - Controller

final class EpisodeRowController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                  HoldMenuProviding {
    var onFocus: (Int) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSelect: (Int) -> Void = { _ in }
    var menu: (Int) -> (title: String, entries: [MenuEntry])? = { _ in nil }

    /// A slot in the row: an episode, or the season card before a season's
    /// first episode.
    private enum Slot: Equatable {
        case episode(Int)
        case season(Int)
    }

    private var episodes: [EpisodeRowItem] = []
    private var slots: [Slot] = []
    /// Episode index → its slot.
    private var slotOf: [Int] = []
    /// The episode in the box.
    private var current = 0
    private var hasFocus = false
    private var lastFocusRequest = 0

    private let layout = EpisodeStripLayout()
    private var strip: UICollectionView!
    private let box = EpisodeBoxView()

    override func loadView() {
        let root = UIView()
        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        strip.backgroundColor = .clear
        strip.clipsToBounds = false
        // The system never scrolls: only our animation moves the row.
        strip.isScrollEnabled = false
        strip.showsHorizontalScrollIndicator = false
        strip.contentInsetAdjustmentBehavior = .never
        // Focus enters on the episode in the box (not the last one focused:
        // a season jump moves the box while focus is elsewhere).
        strip.remembersLastFocusedIndexPath = false
        strip.dataSource = self
        strip.delegate = self
        strip.register(EpisodeCardCell.self, forCellWithReuseIdentifier: "episode")
        strip.register(EpisodeSeasonCell.self, forCellWithReuseIdentifier: "season")
        root.addSubview(strip)
        box.isUserInteractionEnabled = false
        root.addSubview(box)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Wider than the screen on both sides: cards sliding in or out at
        // the edges keep their cells and SLIDE (see `FixedFocusStripLayout`).
        let over = FixedFocusStripLayout.overscan
        strip.frame = CGRect(x: -over, y: 0, width: view.bounds.width + 2 * over,
                             height: FixedFocusMetrics.height)
        box.frame = CGRect(x: FixedFocusMetrics.inset, y: 0,
                           width: FixedFocusMetrics.boxWidth, height: FixedFocusMetrics.height)
        if strip.layer.animationKeys()?.isEmpty ?? true { strip.contentOffset = offset(for: current) }
    }

    // MARK: Updates from SwiftUI

    func update(episodes new: [EpisodeRowItem], index: Int) {
        let structureChanged = new.map(\.id) != episodes.map(\.id)
        let contentChanged = new != episodes
        episodes = new
        if structureChanged {
            buildSlots()
            current = min(max(index, 0), max(episodes.count - 1, 0))
            if isViewLoaded {
                strip.reloadData()
                strip.layoutIfNeeded()
                strip.contentOffset = offset(for: current)
                applyDimming()
            }
            if episodes.indices.contains(current) { box.show(episodes[current], animated: false) }
            return
        }
        if contentChanged, isViewLoaded {
            // Watched state, stills, runtimes arriving: the visible cards and
            // the box take them in place (a reload would drop focus).
            for case let cell as EpisodeCardCell in strip.visibleCells {
                if case let .episode(i)? = slot(of: cell) { cell.configure(episodes[i]) }
            }
            if episodes.indices.contains(current) { box.refresh(episodes[current]) }
        }
        // A jump from outside (the season selector, opening on Play's
        // episode) — ignored while it's our own focus that moved it.
        if index != current, episodes.indices.contains(index) {
            move(to: index)
        }
    }

    func requestFocus(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        guard isViewLoaded, episodes.indices.contains(current) else { return }
        // Deferred a turn: the engine's own move (onto the season selector,
        // in the way) must finish before this one can win.
        DispatchQueue.main.async { [weak self] in
            guard let self, let focusSystem = UIFocusSystem.focusSystem(for: self.strip) else { return }
            focusSystem.requestFocusUpdate(to: self.strip)
            focusSystem.updateFocusIfNeeded()
        }
    }

    private func buildSlots() {
        slots = []
        slotOf = []
        for (i, episode) in episodes.enumerated() {
            if i > 0, episodes[i - 1].season != episode.season { slots.append(.season(episode.season)) }
            slotOf.append(slots.count)
            slots.append(.episode(i))
        }
        layout.count = slots.count
    }

    private func slot(of cell: UICollectionViewCell) -> Slot? {
        guard let path = strip.indexPath(for: cell), slots.indices.contains(path.item) else { return nil }
        return slots[path.item]
    }

    /// The row's offset that puts episode `i` at the spot (under the box).
    private func offset(for i: Int) -> CGPoint {
        let slot = slotOf.indices.contains(i) ? slotOf[i] : 0
        return CGPoint(x: CGFloat(slot) * FixedFocusMetrics.continuePitch, y: 0)
    }

    // MARK: Moving

    /// Episode `i` into the box: the row slides under it, the box's content
    /// drifts the way you went.
    private func move(to i: Int) {
        guard episodes.indices.contains(i), i != current else { return }
        let direction: CGFloat = i > current ? 1 : -1
        current = i
        box.show(episodes[i], animated: true, direction: direction)
        FixedFocusMotion.run(vertical: false, duration: Motion.durations.continueMove, damping: 1) {
            self.strip.contentOffset = self.offset(for: i)
            self.applyDimming()
        } completion: { _ in }
    }

    /// Left of the box: where you came from — dimmed (Render Lab → Previous
    /// poster), as on Home's rows.
    private func applyDimming() {
        let dimmed = RenderProbe.shared.flags.previousPosterAlpha
        let spot = slotOf.indices.contains(current) ? slotOf[current] : 0
        for cell in strip.visibleCells {
            guard let path = strip.indexPath(for: cell) else { continue }
            Self.dim(cell, path.item < spot ? dimmed : 1)
        }
    }

    // MARK: Focus

    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if case .episode = slots[indexPath.item] { return true }
        return false
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        slotOf.indices.contains(current) ? IndexPath(item: slotOf[current], section: 0) : nil
    }

    func collectionView(_ cv: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        let focusedHere: Bool
        if let next = context.nextFocusedIndexPath, slots.indices.contains(next.item),
           case let .episode(i) = slots[next.item] {
            focusedHere = true
            if i != current {
                move(to: i)
                onFocus(i)
            }
        } else {
            focusedHere = false
        }
        if focusedHere != hasFocus {
            hasFocus = focusedHere
            box.setFocused(focusedHere)
            onFocusChange(focusedHere)
        }
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if case let .episode(i) = slots[indexPath.item] { onSelect(i) }
    }

    /// Select held on an episode: its menu (see `HoldMenu`), beside the box.
    func holdMenu(for focused: UIView) -> HoldMenuRequest? {
        guard let cell = focused as? UICollectionViewCell, let path = strip.indexPath(for: cell),
              case let .episode(i) = slots[path.item], let menu = menu(i), !menu.entries.isEmpty else { return nil }
        let anchor = box.window != nil && box.alpha > 0 && !box.isHidden
            ? box.convert(box.bounds, to: nil) : cell.convert(cell.bounds, to: nil)
        return HoldMenuRequest(entries: menu.entries, anchor: anchor)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HoldMenu.shared.install()
    }

    // MARK: Data

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { slots.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch slots[indexPath.item] {
        case let .episode(i):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "episode", for: indexPath) as! EpisodeCardCell
            cell.configure(episodes[i])
            return cell
        case let .season(season):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "season", for: indexPath) as! EpisodeSeasonCell
            let count = episodes.filter { $0.season == season }.count
            cell.configure(season: season, count: count)
            return cell
        }
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        let spot = slotOf.indices.contains(current) ? slotOf[current] : 0
        Self.dim(cell, indexPath.item < spot ? RenderProbe.shared.flags.previousPosterAlpha : 1)
    }

    private static func dim(_ cell: UICollectionViewCell, _ alpha: CGFloat) {
        if let card = cell as? EpisodeCardCell { card.setDim(alpha) } else { cell.contentView.alpha = alpha }
    }
}

extension FixedFocusMetrics {
    /// Continue Watching's step: a box-wide card and the gap.
    static var continuePitch: CGFloat { boxWidth + gap }
}

/// Every slot box-wide, one after another from the spot (shifted by the
/// overscan, see `FixedFocusStripLayout`).
final class EpisodeStripLayout: UICollectionViewLayout {
    var count = 0

    override var collectionViewContentSize: CGSize {
        CGSize(width: 2 * FixedFocusStripLayout.overscan + FixedFocusMetrics.inset
               + CGFloat(count) * FixedFocusMetrics.continuePitch + 1920,
               height: FixedFocusMetrics.height)
    }

    private func frame(_ i: Int) -> CGRect {
        CGRect(x: FixedFocusStripLayout.overscan + FixedFocusMetrics.inset
               + CGFloat(i) * FixedFocusMetrics.continuePitch,
               y: 0, width: FixedFocusMetrics.boxWidth, height: FixedFocusMetrics.height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard count > 0 else { return [] }
        let pitch = FixedFocusMetrics.continuePitch
        let origin = FixedFocusStripLayout.overscan + FixedFocusMetrics.inset
        let first = max(Int(floor((rect.minX - origin) / pitch)) - 1, 0)
        let last = min(Int(ceil((rect.maxX - origin) / pitch)) + 1, count - 1)
        guard first <= last else { return [] }
        return (first...last).map { attributes($0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < count ? attributes(indexPath.item) : nil
    }

    private func attributes(_ i: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
        a.frame = frame(i)
        return a
    }
}

// MARK: - Cards

/// An episode's card: its still, the dark foot, the state line.
final class EpisodeCardCell: UICollectionViewCell {
    private let art = EpisodeArtView()
    /// The cards' edge and shadow — Home's (Render Lab → Card edge).
    private let edge = UIImageView()
    private let cardShadow = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = Spotlight.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.addSubview(art)
        edge.isUserInteractionEnabled = false
        contentView.addSubview(edge)
        cardShadow.isUserInteractionEnabled = false
        insertSubview(cardShadow, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        art.frame = contentView.bounds
        let style = FixedFocusCardEdge.current
        edge.image = style.edgeImage
        edge.frame = contentView.bounds
        cardShadow.image = style.hasShadow ? FixedFocusCardEdge.shadowImage : nil
        cardShadow.frame = bounds.insetBy(dx: -FixedFocusCardEdge.shadowPad, dy: -FixedFocusCardEdge.shadowPad)
    }

    /// Dimmed (left of the box) — its shadow with it.
    func setDim(_ alpha: CGFloat) {
        contentView.alpha = alpha
        cardShadow.alpha = alpha
    }

    func configure(_ episode: EpisodeRowItem) {
        art.show(episode)
    }
}

/// Between two seasons: a card with the season's name and size.
final class EpisodeSeasonCell: UICollectionViewCell {
    private let name = UILabel()
    private let size = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = Spotlight.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        contentView.layer.borderWidth = 1.5
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        name.font = .systemFont(ofSize: 40, weight: .bold)
        name.textColor = .white
        name.textAlignment = .center
        size.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .regular)
        size.textColor = UIColor.white.withAlphaComponent(0.62)
        size.textAlignment = .center
        contentView.addSubview(name)
        contentView.addSubview(size)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        name.frame = CGRect(x: 0, y: b.midY - 44, width: b.width, height: 50)
        size.frame = CGRect(x: 0, y: b.midY + 12, width: b.width, height: 30)
    }

    func configure(season: Int, count: Int) {
        name.text = season == 0 ? "Specials" : "Season \(season)"
        size.text = count == 1 ? "1 Episode" : "\(count) Episodes"
    }
}

/// A card's picture: the still, the dark foot, the state line — shared by
/// the cards and the box.
final class EpisodeArtView: UIView {
    private let image = UIImageView()
    private let foot = CAGradientLayer()
    private let state = EpisodeStateView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.backgroundColor = UIColor(white: 0.12, alpha: 1)
        addSubview(image)
        // Continue Watching's dark foot.
        foot.colors = [UIColor.clear.cgColor,
                       UIColor.black.withAlphaComponent(Spotlight.continueFootOpacity).cgColor]
        foot.startPoint = CGPoint(x: Spotlight.continueFootStart.x, y: Spotlight.continueFootStart.y)
        foot.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(foot)
        addSubview(state)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        image.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foot.frame = bounds
        CATransaction.commit()
        layer.insertSublayer(foot, above: image.layer)
        bringSubviewToFront(state)
        state.frame = CGRect(x: Spotlight.progressBarInset,
                             y: bounds.height - Spotlight.progressBarBottomInset - 34,
                             width: bounds.width - 2 * Spotlight.progressBarInset, height: 34)
    }

    func show(_ episode: EpisodeRowItem) {
        FixedFocusImages.load(episode.image, into: image, maxDimension: FixedFocusMetrics.boxWidth)
        state.show(episode.state)
    }
}

/// Continue Watching's state line (see `FixedFocusProgressView`), for an
/// episode: "S1:E4" · bar · "20m left" — or "S1:E4 … ✓ Watched" / "… Airs
/// Fri" / "… 45m".
final class EpisodeStateView: UIView {
    private let label = UILabel()
    private let right = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)))
    private let track = UIView()
    private let fill = UIView()
    private var fraction: CGFloat = 0
    private var inProgress = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for text in [label, right] {
            text.font = .systemFont(ofSize: Spotlight.continueStateSize, weight: .semibold)
            text.textColor = .white
            text.layer.shadowColor = UIColor.black.cgColor
            text.layer.shadowOpacity = 0.6
            text.layer.shadowRadius = 6
            text.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(text)
        }
        check.tintColor = .white
        addSubview(check)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        track.layer.cornerRadius = Spotlight.continueProgressBarHeight / 2
        fill.backgroundColor = .white
        fill.layer.cornerRadius = Spotlight.continueProgressBarHeight / 2
        track.addSubview(fill)
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: EpisodeRowState) {
        label.text = state.label
        inProgress = state.progress != nil
        fraction = CGFloat(state.progress ?? 0)
        right.text = inProgress ? state.remaining.map { "\($0) left" } : state.status
        check.isHidden = inProgress || !state.watched
        track.isHidden = !inProgress
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = Spotlight.continueStateGap
        let h = bounds.height
        label.sizeToFit()
        right.sizeToFit()
        label.frame = CGRect(x: 0, y: (h - label.bounds.height) / 2,
                             width: label.bounds.width, height: label.bounds.height)
        right.frame = CGRect(x: bounds.width - right.bounds.width, y: (h - right.bounds.height) / 2,
                             width: right.bounds.width, height: right.bounds.height)
        check.sizeToFit()
        check.center = CGPoint(x: right.frame.minX - 6 - check.bounds.width / 2, y: h / 2)
        let barX = label.frame.maxX + gap
        let barEnd = (right.text?.isEmpty ?? true) ? bounds.width : right.frame.minX - gap
        let barH = Spotlight.continueProgressBarHeight
        track.frame = CGRect(x: barX, y: (h - barH) / 2, width: max(barEnd - barX, 0), height: barH)
        fill.frame = CGRect(x: 0, y: 0, width: max(track.bounds.width * fraction, barH), height: barH)
    }
}

// MARK: - The box

/// THE FIXED BOX of the episode row (Home's, for episodes): the episode's
/// card, which drifts in on a change, the white focus outline, and — part
/// of the box, drifting with it — the episode's title, facts and synopsis.
final class EpisodeBoxView: UIView {
    /// Under the box: title, facts, two lines of synopsis.
    static let infoHeight: CGFloat = FixedFocusMetrics.infoGap + 36 + 36 + 70

    /// The text under the box.
    private final class Info: UIView {
        let title = UILabel()
        let facts = UILabel()
        let synopsis = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            let size = FixedFocusMetrics.textSize
            title.font = .systemFont(ofSize: size, weight: .regular)
            title.textColor = .white
            facts.font = .systemFont(ofSize: size, weight: .regular)
            facts.textColor = UIColor.white.withAlphaComponent(0.62)
            synopsis.font = .systemFont(ofSize: size, weight: .regular)
            synopsis.textColor = UIColor.white.withAlphaComponent(0.8)
            synopsis.numberOfLines = 2
            for label in [title, facts, synopsis] { addSubview(label) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 30)
            facts.frame = CGRect(x: 0, y: 36, width: bounds.width, height: FixedFocusMetrics.factsHeight)
            synopsis.frame = CGRect(x: 0, y: 72, width: bounds.width, height: 64)
            synopsis.sizeToFit()
            synopsis.frame.size.width = bounds.width
        }

        func show(_ episode: EpisodeRowItem) {
            title.text = episode.title
            facts.text = episode.facts
            synopsis.text = episode.synopsis
            setNeedsLayout()
        }
    }

    private let clip = UIView()
    private var page = EpisodeArtView()
    private var info = Info()
    private let outline = UIView()
    private var shownID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = Spotlight.cornerRadius
        clip.layer.cornerCurve = .continuous
        clip.backgroundColor = UIColor(white: 0.12, alpha: 1)
        addSubview(clip)
        clip.addSubview(page)
        // The cards' edge (Home's, Render Lab → Card edge) — no shadow: the
        // card right under the box casts it.
        edge.isUserInteractionEnabled = false
        addSubview(edge)
        addSubview(info)
        // The focus outline: white, as on Home's box.
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = UIColor.white.cgColor
        outline.layer.borderWidth = 4
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        addSubview(outline)
        // (The top bar's light — as on Home's box: see `FixedFocusCardEdge`.)
        outline.addSubview(outlineLight)
    }

    private let outlineLight = UIImageView()
    private let edge = UIImageView()

    required init?(coder: NSCoder) { fatalError() }

    /// Where the text sits: as under Home's box (18 pt below, indented).
    private var infoFrame: CGRect {
        CGRect(x: FixedFocusMetrics.textIndent, y: bounds.height + FixedFocusMetrics.infoGap,
               width: bounds.width - 2 * FixedFocusMetrics.textIndent, height: Self.infoHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        outline.frame = bounds
        edge.image = FixedFocusCardEdge.current.edgeImage
        edge.frame = bounds
        let lit = FixedFocusCardEdge.focusLight
        outline.layer.borderWidth = lit ? 0 : FixedFocusRing.width
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outlineLight.image = lit ? FixedFocusCardEdge.focusImage : nil
        outlineLight.frame = outline.bounds
        if page.layer.animationKeys()?.isEmpty ?? true { page.frame = bounds }
        if info.layer.animationKeys()?.isEmpty ?? true { info.frame = infoFrame }
    }

    func setFocused(_ focused: Bool) {
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.outline.alpha = focused ? 1 : 0
        }
    }

    /// New data for the episode shown (watched, still, runtime): in place.
    func refresh(_ episode: EpisodeRowItem) {
        guard episode.id == shownID else { return }
        page.show(episode)
        info.show(episode)
    }

    /// `direction`: +1 moving right (the new content comes from the right).
    func show(_ episode: EpisodeRowItem, animated: Bool, direction: CGFloat = 1) {
        guard episode.id != shownID else { return }
        shownID = episode.id
        guard animated, RenderProbe.shared.flags.boxDrift else {
            if animated {
                UIView.transition(with: self, duration: Motion.durations.fade,
                                  options: [.transitionCrossDissolve, .beginFromCurrentState,
                                            .allowUserInteraction],
                                  animations: { self.page.show(episode); self.info.show(episode) })
            } else {
                page.show(episode)
                info.show(episode)
            }
            return
        }
        // DRIFT (Home's box): the new picture and text fade in shifting a
        // little in the direction of travel, the old ones fade out shifting on.
        let dx = direction * 30
        let incoming = EpisodeArtView(frame: bounds.offsetBy(dx: dx, dy: 0))
        incoming.show(episode)
        incoming.alpha = 0
        clip.addSubview(incoming)
        let outgoing = page
        page = incoming
        let infoIn = Info(frame: infoFrame.offsetBy(dx: dx, dy: 0))
        infoIn.show(episode)
        infoIn.alpha = 0
        insertSubview(infoIn, belowSubview: outline)
        let infoOut = info
        info = infoIn
        let infoTarget = infoFrame
        FixedFocusMotion.run(vertical: false, duration: Motion.durations.continueMove, damping: 1) {
            incoming.frame = self.bounds
            incoming.alpha = 1
            outgoing.frame = self.bounds.offsetBy(dx: -dx, dy: 0)
            outgoing.alpha = 0
            infoIn.frame = infoTarget
            infoIn.alpha = 1
            infoOut.frame = infoTarget.offsetBy(dx: -dx, dy: 0)
            infoOut.alpha = 0
        } completion: { _ in
            if outgoing !== self.page { outgoing.removeFromSuperview() }
            if infoOut !== self.info { infoOut.removeFromSuperview() }
        }
    }
}

// MARK: - Blurred backdrop

/// A backdrop blurred ONCE into a still image (a small copy — a blur has no
/// detail to keep — scaled up on screen): no live blur filter, nothing
/// recomputed per frame. Kept per picture and strength.
@MainActor
enum BlurredBackdrop {
    private static let cache = NSCache<NSString, UIImage>()
    /// The working width (`strength` is the blur's radius in its pixels).
    private static let width: CGFloat = 640

    /// The brightness cap's soft shoulder (sRGB in → out) for a ceiling
    /// `c`: untouched up to half of it, then easing into it — white ends at
    /// `c`. (Render Lab → Details: blurred picture, brightness cap.)
    nonisolated static func capCurve(_ c: Double) -> [(Double, Double)] {
        [(0, 0), (0.5 * c, 0.5 * c), (c, 0.82 * c), ((1 + c) / 2, 0.95 * c), (1, c)]
    }

    static func image(for url: String?, strength: Double) async -> UIImage? {
        guard let url, strength > 0 else { return nil }
        let cap = RenderProbe.shared.flags.detailsBlurCap
        let key = "\(url)|\(strength)|\(cap)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var source = await ImageCache.shared.diskImage(for: url, budget: width)
        if source == nil, let remote = URL(string: url),
           let data = try? await ImageCache.shared.download(remote) {
            ImageCache.shared.insertData(data, for: url)
            source = ImageCache.decodeDownsampled(data, budget: width)
        }
        guard let cgImage = source?.cgImage else { return nil }
        let blurred = await Task.detached(priority: .utility) { () -> UIImage? in
            let input = CIImage(cgImage: cgImage)
            var output = input.clampedToExtent()
                .applyingGaussianBlur(sigma: strength)
                .cropped(to: input.extent)
            // The cap: bright parts pulled down (one rule for every picture).
            if cap > 0, let tone = CIFilter(name: "CIToneCurve") {
                tone.setValue(output, forKey: kCIInputImageKey)
                for (i, point) in capCurve(cap).enumerated() {
                    tone.setValue(CIVector(x: point.0, y: point.1), forKey: "inputPoint\(i)")
                }
                output = tone.outputImage ?? output
            }
            // Core Image's own working space: the curve's numbers come out as
            // display values (white → `cap`). (A plain sRGB working space
            // darkened and greyed everything to ~15 %.)
            let context = CIContext()
            guard let result = context.createCGImage(output, from: input.extent) else { return nil }
            return UIImage(cgImage: result)
        }.value
        if let blurred { cache.setObject(blurred, forKey: key) }
        return blurred
    }
}

// MARK: - Progress map

/// Where you are in the season, under the episode row: one tick per
/// episode — watched ones filled, the one in the box highlighted — and
/// "Season 2 • 8 of 12 watched". Long seasons: the ticks narrow; past
/// `barFrom` episodes they merge into one bar with a marker.
struct SeasonProgressMap: View {
    struct Tick: Equatable {
        let id: String
        let watched: Bool
        let current: Bool
    }

    let ticks: [Tick]
    let label: String
    /// INLINE (beside the row's name, Details): the ticks, then the label
    /// after them on the same line, in `width` at most.
    var inline = false
    var width: CGFloat = Self.width

    /// The map's width: the box's text column.
    static let width = FixedFocusMetrics.boxWidth - 2 * FixedFocusMetrics.textIndent
    /// Inline: at most this wide (the ticks; the label follows).
    static let inlineWidth: CGFloat = 360
    static let height: CGFloat = 8
    static let gap: CGFloat = 4
    static let barFrom = 60

    /// Over this many episodes: one bar (inline sooner — less room).
    private var asBar: Bool { ticks.count > (inline ? 30 : Self.barFrom) }

    var body: some View {
        Group {
            if inline {
                HStack(spacing: 16) {
                    if asBar { bar } else { row }
                    labelText
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    labelText
                    if asBar { bar } else { row }
                }
            }
        }
        .animation(GlassPill.glide, value: ticks)
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(AppGlass.textMuted)
            .lineLimit(1)
            .fixedSize()
    }

    private var row: some View {
        let n = max(ticks.count, 1)
        let tick = (width - CGFloat(n - 1) * Self.gap) / CGFloat(n)
        return HStack(spacing: Self.gap) {
            ForEach(ticks, id: \.id) { t in
                Capsule()
                    .fill(Color.white.opacity(t.current ? 1 : t.watched ? 0.62 : 0.2))
                    .frame(width: max(min(tick, 44), 3),
                           height: t.current ? Self.height + 4 : Self.height)
            }
        }
        .frame(height: Self.height + 4)
    }

    /// Many episodes: the share watched as one bar, the episode in the box
    /// as a marker on it.
    private var bar: some View {
        let watched = CGFloat(ticks.filter(\.watched).count) / CGFloat(max(ticks.count, 1))
        let at = CGFloat(ticks.firstIndex(where: \.current) ?? 0) / CGFloat(max(ticks.count - 1, 1))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.2))
                .frame(width: width, height: Self.height)
            Capsule().fill(Color.white.opacity(0.62))
                .frame(width: max(width * watched, Self.height), height: Self.height)
            Capsule().fill(Color.white)
                .frame(width: 6, height: Self.height + 8)
                .offset(x: (width - 6) * at)
        }
        .frame(width: width, height: Self.height + 8, alignment: .leading)
    }
}
