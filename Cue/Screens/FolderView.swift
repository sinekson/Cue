import SwiftUI
import UIKit

/// Titles as a poster grid (Discover, a browse page): Home's
/// destination cards (outline, grow, shadow; name and year below), six to a
/// line; scrolls vertically only, the header (when given) scrolling with it.
/// Back on a grid page: the page's `onExitCommand` asks first (a press
/// the grid took itself still reached the navigation, which left).
@MainActor
final class GridBack {
    weak var controller: FolderGridController?
    /// True: handled (the grid goes back up to its top). `then`: at the
    /// top, focus goes there (a tab's bar) instead of the first title.
    func handle(then: (() -> Void)? = nil) -> Bool { controller?.backToTopIfDeep(then: then) ?? false }
}

struct FolderPosterGrid: UIViewControllerRepresentable {
    /// Two lines of empty posters (no picture, no caption).
    static let placeholderItems: [MetaItem] = (0..<12).map {
        MetaItem(id: "placeholder-\($0)", type: "collection", name: "", poster: nil, background: nil)
    }

    let header: AnyView?
    /// The header's height (its content's, as laid out), fixed from the
    /// first frame.
    var headerHeight: CGFloat = FolderGridController.defaultHeaderHeight
    let items: [MetaItem]
    /// The line under each title's name (its year), by title id.
    let subtitles: [String: String]
    let onSelect: (MetaItem) -> Void
    let onOpenDetails: ((MetaItem) -> Void)?
    /// A title is about to show (more can load as the end nears).
    var onDisplay: ((MetaItem) -> Void)? = nil
    /// Placeholders while the titles load (`placeholderItems`): drawn, out
    /// of focus's way; the titles take over in one fade, focus then going
    /// to the first.
    var placeholder = false
    /// Back's way in (see `GridBack`).
    var back: GridBack? = nil
    /// Focus lands on the header's controls, not the first title, and Back
    /// from any line goes up to them (a browse page's Movies | Series).
    var headerFirst = false
    /// Room above the header (`FolderGridController.headerTopMargin`).
    var headerTop = FolderGridController.defaultHeaderTop
    var onScroll: ((CGFloat) -> Void)? = nil
    /// Room above the grid's frame (`FolderGridController.bleedTop`).
    var bleedTop: CGFloat = 0
    /// The tab whose page this is (with `headerFirst`): Down from its bar,
    /// the page at its top, goes straight to the header (`TopBar.entries`).
    var barTab: AppTab? = nil

    func makeUIViewController(context: Context) -> FolderGridController { FolderGridController() }

    func updateUIViewController(_ controller: FolderGridController, context: Context) {
        back?.controller = controller
        controller.onSelect = onSelect
        controller.onOpenDetails = onOpenDetails
        controller.onDisplay = onDisplay
        controller.headerFirst = headerFirst
        controller.headerTopMargin = headerTop
        controller.onScroll = onScroll
        controller.bleedTop = bleedTop
        if let barTab {
            TopBar.shared.entries[barTab.rawValue] = { [weak controller] in controller?.barEntry }
        }
        controller.show(header: header, headerHeight: headerHeight, items: items,
                        subtitles: subtitles, placeholder: placeholder)
    }
}

final class FolderGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                  HoldMenuProviding {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onOpenDetails: ((MetaItem) -> Void)?
    var onDisplay: ((MetaItem) -> Void)?

    /// Placeholders show (`FolderPosterGrid.placeholder`).
    private var isPlaceholder = false

    private var header: AnyView?
    private var items: [MetaItem] = []
    private var subtitles: [String: String] = [:]
    private var collectionView: UICollectionView!

    fileprivate static let columns = 6
    static let defaultHeaderHeight: CGFloat = 150
    private var headerHeight = FolderGridController.defaultHeaderHeight
    private var filledOnce = false
    /// The first titles are where focus lands, until it has moved by itself
    /// (controls in the header would take it otherwise).
    private var prefersFirstTitle = false
    /// `FolderPosterGrid.headerFirst`: the header's controls instead.
    var headerFirst = false

    /// A poster: THE portrait poster (`columns` of them fill the width).
    static var card: CGSize { FixedFocusMetrics.posterCard }

    /// The header: a view of its own in the scroll view's top inset, there
    /// while it scrolls (a cell goes once scrolled off, and its controls with
    /// it, out of reach).
    private var headerHost: UIHostingController<AnyView>?
    private var headerPositioned = false
    /// Above the header, in the inset.
    static let defaultHeaderTop: CGFloat = 60
    /// Above the header, in the inset (`FolderPosterGrid.headerTop`): the
    /// header's own view covers only its content, so nothing above it (a
    /// tab's bar) reads as part of it to the focus engine.
    var headerTopMargin = FolderGridController.defaultHeaderTop
    /// How far the page has scrolled from its top (a tab's page moves its
    /// bar with it, `TopBarFollow`).
    var onScroll: ((CGFloat) -> Void)?
    /// The page's room above its frame, under a tab's bar (Discover): the
    /// grid's frame starts below the bar (SwiftUI took the whole-screen
    /// grid for the bar's neighbour, and Left and Right along the bar fell
    /// into it), its titles still scroll up to the screen's top.
    var bleedTop: CGFloat = 0
    /// Scrolled, the line before the focused one: its top this far below
    /// the screen's — the line above it peeking as much as the next one
    /// at the foot (two lines, one caption and the gaps between them: the
    /// rest of the screen, halved).
    static var pairTop: CGFloat {
        let shown = card.height * 2 + FixedFocusMetrics.captionRoom + FixedFocusMetrics.gap * 3
        return FixedFocusMetrics.gap + (DetailTransition.screen.height - shown) / 2
    }
    /// Between the header and the first line.
    static let firstLineGap: CGFloat = 12

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // Scrolling up, posters go under the header's edge — not over it.
        collectionView.clipsToBounds = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.bottom = 80
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FixedFocusDestinationCell.self, forCellWithReuseIdentifier: "poster")
        view.addSubview(collectionView)
        syncHeaderHost()
    }

    /// The header as a view in the scroll view's top inset: its height above
    /// the first title. Under it a focus guide, the page's width: Up from a
    /// title far to the right of the header's controls (they sit at the
    /// left) goes to them — the focus engine only looks straight up.
    private func syncHeaderHost() {
        guard isViewLoaded else { return }
        guard let header else {
            if let host = headerHost {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                headerHost = nil
            }
            applyTopInset(headerTopMargin)
            return
        }
        let host: UIHostingController<AnyView>
        if let existing = headerHost {
            host = existing
        } else {
            host = UIHostingController(rootView: AnyView(header.ignoresSafeArea()))
            host.view.backgroundColor = .clear
            addChild(host)
            collectionView.addSubview(host.view)
            host.didMove(toParent: self)
            // On the page, not in the scroll view (there focus never finds
            // it); placed under the header, on while the page is at its top.
            let guide = UIFocusGuide()
            view.addLayoutGuide(guide)
            let guideTop = guide.topAnchor.constraint(equalTo: view.topAnchor)
            NSLayoutConstraint.activate([
                guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                guide.heightAnchor.constraint(equalToConstant: 8),
                guideTop,
            ])
            guide.preferredFocusEnvironments = [host.view]
            controlsGuide = guide
            controlsGuideTop = guideTop
            headerHost = host
        }
        applyTopInset(headerHeight + headerTopMargin)
        host.view.frame = CGRect(x: 0, y: -headerHeight, width: collectionView.bounds.width, height: headerHeight)
        controlsGuideTop?.constant = headerTopMargin + headerHeight - 8 - bleedTop
        syncControlsGuide()
    }

    /// The titles' start (the header and what's above it in the inset);
    /// at the top, the page stays at the top.
    private func applyTopInset(_ top: CGFloat) {
        let oldTop = collectionView.contentInset.top
        if oldTop != top {
            collectionView.contentInset.top = top
            if headerPositioned, collectionView.contentOffset.y == -oldTop {
                collectionView.contentOffset = CGPoint(x: 0, y: -top)
            }
        }
        if !headerPositioned, collectionView.bounds.height > 0 {
            headerPositioned = true
            collectionView.contentOffset = CGPoint(x: 0, y: -top)
        }
    }

    private var controlsGuide: UIFocusGuide?
    private var controlsGuideTop: NSLayoutConstraint?

    /// The guide under the header only while the header shows whole (else
    /// it would sit among the titles).
    private func syncControlsGuide() {
        controlsGuide?.isEnabled = collectionView.contentOffset.y <= -collectionView.contentInset.top + 1
    }

    /// Down from the tab's bar, the page at its top: the header (else the
    /// engine's own move).
    var barEntry: UIView? {
        guard headerFirst, collectionView.contentOffset.y <= -collectionView.contentInset.top + 1 else { return nil }
        return headerHost?.view
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncControlsGuide()
        onScroll?(max(0, scrollView.contentOffset.y + scrollView.contentInset.top))
    }

    /// Where focus scrolls the page (tvOS asks here for focus moves too).
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let top = -collectionView.contentInset.top
        // The first line: the page at its top, header whole. Any other: the
        // line before it near the top (`pairTop`), it under it with its
        // caption, the lines past them peeking alike; a press moves one
        // line, both ways. By the layout to come (the caption's room moves
        // with focus, in the same move), not the one on screen.
        guard let path = focusedPath, path.item >= Self.columns else {
            targetContentOffset.pointee.y = top
            return
        }
        let line = path.item / Self.columns
        let upper = Self.firstLineGap + CGFloat(line - 1) * (Self.card.height + FixedFocusMetrics.gap)
        let lines = (items.count + Self.columns - 1) / Self.columns
        let content = Self.firstLineGap + CGFloat(lines) * (Self.card.height + FixedFocusMetrics.gap)
            + FixedFocusMetrics.captionRoom + 48
        let maxY = max(top, content + collectionView.contentInset.bottom - collectionView.bounds.height)
        targetContentOffset.pointee.y = min(maxY, max(top, upper - Self.pairTop))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.clipsToBounds = false
        let frame = CGRect(x: 0, y: -bleedTop, width: view.bounds.width, height: view.bounds.height + bleedTop)
        if collectionView.frame != frame { collectionView.frame = frame }
        syncHeaderHost()
    }

    /// The header is never reloaded (it updates itself, its focus stays).
    func show(header: AnyView?, headerHeight: CGFloat, items: [MetaItem],
              subtitles: [String: String], placeholder: Bool = false) {
        let swapping = isPlaceholder != placeholder
        isPlaceholder = placeholder
        // Before the first titles nothing takes focus; later placeholders (a
        // Movies | Series or sort change) leave the header's controls in
        // focus — only the cards can't take it (`canFocusItemAt`).
        if isViewLoaded { collectionView.isUserInteractionEnabled = !(placeholder && !filledOnce) }
        let changed = items.map(\.id) != self.items.map(\.id)
        let heightChanged = headerHeight != self.headerHeight
        self.header = header
        self.headerHeight = headerHeight
        syncHeaderHost()
        if heightChanged, isViewLoaded { collectionView.collectionViewLayout.invalidateLayout() }
        guard changed else { return }
        guard isViewLoaded else {
            self.items = items
            self.subtitles = subtitles
            return
        }
        // A pill pressed (Search's Movies | Series): reloadData takes focus
        // away from the header (it's in the collection view) to the first
        // title. A section reload leaves it there.
        let headerFocused = headerHost.map { Self.focus(in: $0.view) } ?? false
        reloadGeneration += 1
        // The page still scrolling up to the header (Up onto the pill, then
        // a quick Right): that scroll finishes quickly first (0.1 s), then the
        // titles swap, on a settled page (swapped mid-scroll, they jumped).
        let top = -collectionView.contentInset.top
        if headerFocused, collectionView.contentOffset.y > top + 0.5 {
            let generation = reloadGeneration
            // (Stops the focus scroll where it is drawn.)
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            UIView.animate(withDuration: Self.hurryDuration, delay: 0,
                           options: [.beginFromCurrentState, .curveEaseOut]) {
                self.collectionView.contentOffset = CGPoint(x: 0, y: top)
            } completion: { _ in
                guard generation == self.reloadGeneration else { return }
                self.reload(items, subtitles, swapping: swapping, headerFocused: true)
            }
        } else {
            reload(items, subtitles, swapping: swapping, headerFocused: headerFocused)
        }
        if !filledOnce, !items.isEmpty, !placeholder {
            filledOnce = true
            // The first titles in: focus to the first, unless it has moved on
            // (the loading state, which held focus, goes in the same update).
            prefersFirstTitle = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.prefersFirstTitle else { return }
                self.collectionView.layoutIfNeeded()
                // (From placeholders focus is nowhere yet: the window's.)
                if let window = self.view.window, let system = UIFocusSystem.focusSystem(for: window) {
                    system.requestFocusUpdate(to: self)
                    system.updateFocusIfNeeded()
                }
            }
        }
    }

    /// A press finishing the scroll up quickly (`show`).
    private static let hurryDuration: TimeInterval = 0.1
    /// The latest reload asked for: one waiting for the hurried scroll is
    /// dropped when a later one came meanwhile.
    private var reloadGeneration = 0

    /// The titles in with the reload (not before: cells shown meanwhile
    /// would read them against the old count).
    private func reload(_ items: [MetaItem], _ subtitles: [String: String],
                        swapping: Bool, headerFocused: Bool) {
        self.items = items
        self.subtitles = subtitles
        if swapping, !PageFade.shared.covering {
            // Placeholders and titles take over from each other: one fade
            // (under the push's still, its fade is the one).
            UIView.transition(with: collectionView, duration: Motion.fadeDuration,
                              options: [.transitionCrossDissolve, .allowAnimatedContent]) {
                if headerFocused {
                    self.collectionView.reloadSections(IndexSet(integer: 0))
                } else {
                    self.collectionView.reloadData()
                }
                self.collectionView.layoutIfNeeded()
            }
            // The titles in: they swell a little and settle, as Search's
            // new results (the sign that what's shown is new).
            if !isPlaceholder { FixedFocusMotion.pulse(collectionView.visibleCells) }
        } else if headerFocused {
            UIView.performWithoutAnimation { collectionView.reloadSections(IndexSet(integer: 0)) }
        } else {
            collectionView.reloadData()
        }
    }

    // MARK: Titles

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = items[indexPath.item]
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
            as! FixedFocusDestinationCell
        cell.configure(item, subtitle: subtitles[item.id], index: indexPath.item, rowCell: nil, card: Self.card)
        cell.setCaptionShown(captionLine == indexPath.item / Self.columns)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        onDisplay?(items[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        !isPlaceholder
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // (Back's scroll up running: dropped, as a move.)
        guard !backToTop else { return }
        let item = items[indexPath.item]
        if let onOpenDetails {
            onOpenDetails(item)
        } else {
            onSelect(item)
        }
    }

    /// Select held on a title: its menu (`TitleMenu`, see `HoldMenu`).
    func holdMenu(for focused: UIView) -> HoldMenuRequest? {
        guard let cell = focused as? UICollectionViewCell, let path = collectionView.indexPath(for: cell),
              items.indices.contains(path.item) else { return nil }
        let entries = TitleMenu.shared.entries(for: items[path.item])
        guard !entries.isEmpty else { return nil }
        if let card = cell as? FixedFocusDestinationCell { return card.holdMenu(entries) }
        return HoldMenuRequest(entries: entries, anchor: cell.convert(cell.bounds, to: nil))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HoldMenu.shared.install()
    }

    // MARK: Back to the top

    /// Where focus goes back to: the first title.
    private var firstTitle: IndexPath? { items.isEmpty ? nil : IndexPath(item: 0, section: 0) }
    /// Going back up to the first title.
    private var backToTop = false

    /// Back below the first line (the page asks — `GridBack`): up to the
    /// top, the header whole, then focus onto the first title. On the first
    /// line (or the header): false — the page leaves. `headerFirst`: from
    /// any line up to the header's controls; on them, the page leaves.
    func backToTopIfDeep(then: (() -> Void)? = nil) -> Bool {
        guard firstTitle != nil, let focused = focusedPath,
              focused.item >= (headerFirst ? 0 : Self.columns),
              !(headerHost.map { Self.focus(in: $0.view) } ?? false) else { return false }
        backToTop = true
        afterTop = then
        let top = CGPoint(x: 0, y: -collectionView.contentInset.top)
        if collectionView.contentOffset.y > top.y {
            collectionView.setContentOffset(top, animated: true)
        } else {
            focusFirst()
        }
        return true
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if backToTop { focusFirst() }
    }

    private func focusFirst() {
        if let afterTop {
            self.afterTop = nil
            backToTop = false
            return afterTop()
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        backToTop = false
    }
    /// Where focus goes once Back's scroll is at the top (a tab's bar).
    private var afterTop: (() -> Void)?

    /// A move during Back's scroll up (focus still on the card left —
    /// moved, it fought the scroll): dropped, the scroll going on at its
    /// own pace (hurried, a page's way in 0.1 s was a jump; held and run
    /// after it, it came late — an action from the past).
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // Up into the page from outside it: only from a tab's bar (nothing
        // sits below the grid). Its frame runs up behind the bar, so the
        // engine found it above, and it sent focus to the title it
        // remembered — Back's, far down the page.
        if context.focusHeading.contains(.up),
           context.previouslyFocusedView.map({ !$0.isDescendant(of: view) }) ?? false,
           context.nextFocusedView?.isDescendant(of: view) == true {
            return false
        }
        guard backToTop, !context.focusHeading.isEmpty else { return super.shouldUpdateFocus(in: context) }
        return false
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if backToTop || prefersFirstTitle {
            if headerFirst, let host = headerHost { return [host.view] }
            if let first = firstTitle, let cell = collectionView.cellForItem(at: first) { return [cell] }
        }
        return super.preferredFocusEnvironments
    }

    private var focusedPath: IndexPath?
    /// The focused line: only it has its captions and their room (Home's
    /// rows' way: the others are only their posters, a gap apart), on the
    /// move's spring with the scroll.
    private var captionLine: Int? { didSet { layout.captionLine = captionLine } }
    /// The grid's places by arithmetic, only what's in view asked for (a
    /// flow layout sized every title loaded on each line change: frames
    /// dropped all through a long grid).
    private let layout = FolderGridLayout(columns: FolderGridController.columns, card: FolderGridController.card,
                                          top: FolderGridController.firstLineGap)

    private func showCaptions(on line: Int?, _ context: UIFocusUpdateContext) {
        guard line != captionLine else { return }
        captionLine = line
        _ = FixedFocusMotion.focusChange(context) { [self] in
            for path in collectionView.indexPathsForVisibleItems {
                (collectionView.cellForItem(at: path) as? FixedFocusDestinationCell)?
                    .setCaptionShown(line == path.item / Self.columns)
            }
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }
    /// Focus somewhere in `view` (SwiftUI's controls aren't views: by
    /// their environments).
    private static func focus(in view: UIView) -> Bool {
        var environment: UIFocusEnvironment? = view.window?.windowScene?.focusSystem?.focusedItem
        while let current = environment {
            if current === view { return true }
            environment = current.parentFocusEnvironment
        }
        return false
    }


    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        focusedPath = context.nextFocusedIndexPath
        showCaptions(on: focusedPath.map { $0.item / Self.columns }, context)
        TitlePictures.shared.resting(on: focusedPath.flatMap { items.indices.contains($0.item) ? items[$0.item] : nil })
        // Moved by the viewer (from something in the page): no longer ours.
        if prefersFirstTitle, context.previouslyFocusedView?.isDescendant(of: collectionView) == true {
            prefersFirstTitle = false
        }
    }
}

/// The browsing grids' layout: `columns` cards a line between the rows'
/// edges, the cards' one gap both ways, only the focused line with its
/// caption's room (`captionLine`), the lines after it moved down by it.
final class FolderGridLayout: UICollectionViewLayout {
    let columns: Int
    let card: CGSize
    let top: CGFloat
    let bottom: CGFloat = 48
    var captionLine: Int?
    private var count = 0

    init(columns: Int, card: CGSize, top: CGFloat) {
        self.columns = columns
        self.card = card
        self.top = top
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var pitch: CGFloat { card.height + FixedFocusMetrics.gap }
    private var lines: Int { (count + columns - 1) / columns }

    override func prepare() {
        super.prepare()
        count = collectionView.map { $0.numberOfSections > 0 ? $0.numberOfItems(inSection: 0) : 0 } ?? 0
    }

    override var collectionViewContentSize: CGSize {
        let width = collectionView?.bounds.width ?? 0
        guard lines > 0 else { return CGSize(width: width, height: top + bottom) }
        return CGSize(width: width, height: top + CGFloat(lines) * pitch - FixedFocusMetrics.gap
                      + (captionLine == nil ? 0 : FixedFocusMetrics.captionRoom) + bottom)
    }

    private func lineTop(_ line: Int) -> CGFloat {
        top + CGFloat(line) * pitch + (captionLine.map { line > $0 ? FixedFocusMetrics.captionRoom : 0 } ?? 0)
    }

    private func attributes(_ item: Int) -> UICollectionViewLayoutAttributes {
        let line = item / columns, column = item % columns
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
        attributes.frame = CGRect(x: FixedFocusMetrics.inset + CGFloat(column) * (card.width + FixedFocusMetrics.gap),
                                  y: lineTop(line), width: card.width,
                                  height: card.height + (line == captionLine ? FixedFocusMetrics.captionRoom : 0))
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard count > 0 else { return [] }
        // A line either way past the rect: the caption's room may shift them.
        let first = max(0, Int(((rect.minY - top) / pitch).rounded(.down)) - 1)
        let last = min(lines - 1, Int(((rect.maxY - top) / pitch).rounded(.up)) + 1)
        guard first <= last else { return [] }
        return (first * columns..<min(count, (last + 1) * columns)).map(attributes)
            .filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < count ? attributes(indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

// MARK: - Tile art

/// Tile pictures: the art at the tile's size with rounded corners, made once
/// and cached (the system's focus effect needs the corners in the picture).
@MainActor
enum TileArt {
    static let radius: CGFloat = 14
    private static let cache = NSCache<NSString, UIImage>()
    private static let background = UIColor(white: 0.17, alpha: 1)

    static func load(_ url: String, size: CGSize, contain: Bool, completion: @escaping (UIImage?) -> Void) {
        let key = "\(url)|\(Int(size.width))x\(Int(size.height))|\(contain)" as NSString
        if let hit = cache.object(forKey: key) { completion(hit); return }
        let budget = RemoteImage.pixelBudget(maxDimension: max(size.width, size.height) * 2, maxPixels: nil)
        Task { @MainActor in
            var image = await ImageCache.shared.diskImage(for: url, budget: budget)
            if image == nil, let remote = URL(string: url), let data = try? await ImageCache.shared.download(remote) {
                image = ImageCache.decodeDownsampled(data, budget: budget)
                if image != nil { ImageCache.shared.insertData(data, for: url) }
            }
            guard let image else { completion(nil); return }
            let tile = render(size: size) { rect in
                if contain {
                    background.setFill()
                    UIRectFill(rect)
                    image.draw(in: fit(image.size, in: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)))
                } else {
                    image.draw(in: fill(image.size, in: rect))
                }
            }
            cache.setObject(tile, forKey: key)
            completion(tile)
        }
    }

    /// Without art (or while it loads): a dark tile — with the emoji or the
    /// name in it when there's no art at all.
    static func placeholder(size: CGSize, text: String?) -> UIImage {
        render(size: size) { rect in
            background.setFill()
            UIRectFill(rect)
            guard let text else { return }
            let isEmoji = text.unicodeScalars.first?.properties.isEmojiPresentation ?? false
            let font = UIFont.systemFont(ofSize: isEmoji ? rect.height * 0.4 : 34, weight: .semibold)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white,
                                                             .paragraphStyle: style]
            let bounds = rect.insetBy(dx: 20, dy: 0)
            let height = (text as NSString).boundingRect(with: bounds.size, options: .usesLineFragmentOrigin,
                                                         attributes: attributes, context: nil).height
            (text as NSString).draw(in: CGRect(x: bounds.minX, y: rect.midY - height / 2,
                                               width: bounds.width, height: height),
                                    withAttributes: attributes)
        }
    }

    private static func render(size: CGSize, draw: (CGRect) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: TileArt.radius).addClip()
            draw(rect)
            _ = context
        }
    }

    private static func fill(_ image: CGSize, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func fit(_ image: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}


