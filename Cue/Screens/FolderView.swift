import SwiftUI
import UIKit

// MARK: - A folder

/// A collection's folder, opened: its catalogs as Home's rows (fixed focus,
/// the focused row at its spot, the next one peeking), the folder's header
/// above the first — it moves up with it. One catalog: its titles
/// in the poster grid instead (a single row on its own page looks empty).
/// The same for every collection, whatever its layout in Nuvio (`viewMode`
/// is kept as it is). On the folder's own colour (its cover's).
struct FolderView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    let collection: CueCollection
    let folder: CueCollectionFolder
    /// Opened from Movies / Series: only that type ("movie" / "series").
    var type: String? = nil
    let onSelect: (MetaItem) -> Void
    /// Details pushed without the system's slide (the zoom brings it in).
    var onOpenInPlace: ((MetaItem) -> Void)? = nil

    @State private var catalogs: [CollectionResolver.FolderCatalog]?
    @State private var tint: Color?

    /// Above the header.
    private static let headerTop: CGFloat = 60
    /// The rows' header: name and subtitle (no cover — the rows need the room).
    private static let headerHeight: CGFloat = 100
    /// The focused row's name: under the header.
    private static var rowTop: CGFloat { max(FixedFocusMetrics.rowTop, headerTop + headerHeight + 36) }

    private var providers: CollectionProviders {
        CollectionProviders(tmdb: tmdbSettings.isEnabled, trakt: TraktService.isConfigured)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TitleTintBackground(tint: tint).ignoresSafeArea()
            content
        }
        .task(id: folder.id) {
            guard catalogs == nil else { return }
            catalogs = await CollectionResolver.catalogs(
                of: folder, addonManager: addonManager, addons: addonManager.addons,
                providers: providers, tmdbLanguage: tmdbSettings.settings.language, type: type)
        }
        .task(id: folder.tileCoverImageUrl) {
            // Home's own colour from a picture (its brightness), not brighter.
            guard let cover = folder.tileCoverImageUrl,
                  let colors = await FixedFocusTint.colors(for: cover, flags: RenderProbe.shared.flags) else { return }
            tint = colors.first
        }
    }

    /// The header: the folder's name, where it is and what's in it; with a
    /// cover over the grid (it scrolls away there).
    private func header(cover: Bool) -> FolderHeader {
        let subtitle: String
        if let catalogs, catalogs.count > 1 {
            subtitle = "\(collection.title) · \(catalogs.count) catalogs"
        } else if let only = catalogs?.first {
            subtitle = "\(collection.title) · \(Self.count(only.items.count))"
        } else {
            subtitle = collection.title
        }
        return FolderHeader(title: folder.title, subtitle: subtitle,
                            cover: cover ? folder.tileCoverImageUrl : nil, emoji: cover ? folder.coverEmoji : nil,
                            shape: folder.tileShape)
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 title" : "\(n) titles" }

    /// Titles open Details through `DetailTransition`.
    private var openDetails: ((MetaItem) -> Void)? {
        onOpenInPlace.map { push in
            { item in DetailTransition.shared.open(item) { push(item) } }
        }
    }

    private static func years(_ items: [MetaItem]) -> [String: String] {
        Dictionary(items.compactMap { item in item.year.map { (item.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    @ViewBuilder private var content: some View {
        if let catalogs, catalogs.count > 1 {
            rows(catalogs)
        } else if let only = catalogs?.first {
            FolderPosterGrid(header: AnyView(header(cover: true)), headerHeight: FolderGridController.defaultHeaderHeight,
                             items: only.items, subtitles: Self.years(only.items),
                             onSelect: onSelect, onOpenDetails: openDetails)
                .ignoresSafeArea()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header(cover: true)
                    .padding(.top, 30)
                    .ignoresSafeArea(edges: .horizontal)
                Group {
                    if catalogs == nil {
                        ProgressView()
                    } else {
                        Text(emptyMessage)
                            .font(.system(size: 26))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 900)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Rows

    /// Each catalog a row, Home's (the box tells the focused title).
    private func rows(_ catalogs: [CollectionResolver.FolderCatalog]) -> some View {
        FixedFocusRows(rows: catalogs.map { HomeRow(id: $0.id, title: $0.title, items: $0.items) },
                       featuredRowID: "", continueRowID: "", active: true, progress: [:],
                       rowTop: Self.rowTop,
                       aboveVisible: Self.rowTop - FixedFocusMetrics.peekGap,
                       onSelect: onSelect, onSelectFeatured: onSelect, onResume: { _ in },
                       onOpenDetails: openDetails,
                       titleMenu: { item, _ in TitleMenu.shared.entries(for: item) },
                       pageHeader: AnyView(header(cover: false)
                           .frame(height: Self.headerHeight, alignment: .bottomLeading)
                           .padding(.top, Self.headerTop)
                           .frame(maxHeight: .infinity, alignment: .top)),
                       pageHeaderHeight: Self.headerTop + Self.headerHeight) { _, _ in }
            .ignoresSafeArea()
    }

    private var emptyMessage: String {
        switch CollectionResolver.blocker(for: folder, providers: providers, addons: addonManager.addons) {
        case .needsTMDB, .needsEither: return "This folder's catalogs come from TMDB. Add your TMDB key in Settings → TMDB."
        case .needsTrakt: return "This folder's catalogs come from Trakt."
        case .needsAddon: return "The add-on this folder's catalogs come from isn't installed."
        case .unsupportedSources, .empty: return "This folder has no catalogs Cue can show."
        case .none: return "Nothing here right now."
        }
    }
}

/// A folder page's header: the folder's cover as a small tile, the name
/// large, where it is and what's in it below.
struct FolderHeader: View {
    let title: String
    let subtitle: String
    let cover: String?
    let emoji: String?
    let shape: String

    /// The tile at the folder's own shape, at a header's height.
    private var tileSize: CGSize {
        let height: CGFloat = 120
        switch shape.uppercased() {
        case "POSTER": return CGSize(width: height * 2 / 3, height: height)
        case "LANDSCAPE": return CGSize(width: height * 16 / 9, height: height)
        default: return CGSize(width: height, height: height)
        }
    }

    var body: some View {
        HStack(spacing: 28) {
            if cover != nil || emoji != nil {
                ZStack {
                    Color(white: 0.17)
                    if let cover {
                        RemoteImage(url: cover, maxDimension: 300)
                    } else if let emoji {
                        Text(emoji).font(.system(size: 56))
                    }
                }
                .frame(width: tileSize.width, height: tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: TileArt.radius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.leading, FixedFocusMetrics.titleInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Titles as a poster grid (a one-catalog folder, a browse page): Home's
/// destination cards (outline, grow, shadow; name and year below), six to a
/// line; scrolls vertically only, the header (when given) scrolling with it.
struct FolderPosterGrid: UIViewControllerRepresentable {
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

    func makeUIViewController(context: Context) -> FolderGridController { FolderGridController() }

    func updateUIViewController(_ controller: FolderGridController, context: Context) {
        controller.onSelect = onSelect
        controller.onOpenDetails = onOpenDetails
        controller.onDisplay = onDisplay
        controller.show(header: header, headerHeight: headerHeight, items: items, subtitles: subtitles)
    }
}

final class FolderGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                  UICollectionViewDelegateFlowLayout, HoldMenuProviding {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onOpenDetails: ((MetaItem) -> Void)?
    var onDisplay: ((MetaItem) -> Void)?

    private var header: AnyView?
    private var items: [MetaItem] = []
    private var subtitles: [String: String] = [:]
    private var collectionView: UICollectionView!

    private static let columns = 6
    private static let gap = FixedFocusMetrics.destinationGap
    static let defaultHeaderHeight: CGFloat = 150
    private var headerHeight = FolderGridController.defaultHeaderHeight
    private var filledOnce = false
    /// The first titles are where focus lands, until it has moved by itself
    /// (controls in the header would take it otherwise).
    private var prefersFirstTitle = false

    /// A poster: `columns` fill the content's width.
    private static var card: CGSize {
        let width = ((FixedFocusMetrics.bannerWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return CGSize(width: width, height: (width * 1.5).rounded())
    }

    /// The header: a view of its own in the scroll view's top inset, there
    /// while it scrolls (a cell goes once scrolled off, and its controls with
    /// it, out of reach).
    private var headerHost: UIHostingController<AnyView>?
    private var headerPositioned = false
    /// Above the header, in the inset.
    private static let headerTopMargin: CGFloat = 60
    /// How close to the screen's top or bottom a focused line may come before
    /// the page moves.
    private static let edgeMargin: CGFloat = 60

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.gap
        layout.minimumLineSpacing = 24
        layout.sectionInset = UIEdgeInsets(top: 12, left: FixedFocusMetrics.inset, bottom: 48,
                                           right: FixedFocusMetrics.inset)
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
                collectionView.contentInset.top = 0
            }
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
        let top = headerHeight + Self.headerTopMargin
        if collectionView.contentInset.top != top { collectionView.contentInset.top = top }
        if !headerPositioned, collectionView.bounds.height > 0 {
            headerPositioned = true
            collectionView.contentOffset = CGPoint(x: 0, y: -top)
        }
        host.view.frame = CGRect(x: 0, y: -headerHeight, width: collectionView.bounds.width, height: headerHeight)
        controlsGuideTop?.constant = Self.headerTopMargin + headerHeight - 8
        syncControlsGuide()
    }

    private var controlsGuide: UIFocusGuide?
    private var controlsGuideTop: NSLayoutConstraint?

    /// The guide under the header only while the header shows whole (else
    /// it would sit among the titles).
    private func syncControlsGuide() {
        controlsGuide?.isEnabled = collectionView.contentOffset.y <= -collectionView.contentInset.top + 1
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncControlsGuide()
    }

    /// Where focus scrolls the page (tvOS asks here for focus moves too): the
    /// first line — or the header's controls — the page at its top, the
    /// header whole; any other line only moves the page once it would reach
    /// the screen's edge, then just far enough to show it whole. Within what
    /// shows: still.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let top = -collectionView.contentInset.top
        guard let path = focusedPath, path.item >= Self.columns,
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame else {
            targetContentOffset.pointee.y = top
            return
        }
        let maxY = max(top, collectionView.contentSize.height + collectionView.contentInset.bottom
                       - collectionView.bounds.height)
        let current = scrollView.contentOffset.y
        var y = current
        if frame.maxY > current + scrollView.bounds.height - Self.edgeMargin {
            y = frame.maxY - scrollView.bounds.height + Self.edgeMargin
        } else if frame.minY < current + Self.edgeMargin {
            y = frame.minY - Self.edgeMargin
        }
        targetContentOffset.pointee.y = min(maxY, max(top, y))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncHeaderHost()
    }

    /// The header is never reloaded (it updates itself, its focus stays).
    func show(header: AnyView?, headerHeight: CGFloat, items: [MetaItem], subtitles: [String: String]) {
        let changed = items.map(\.id) != self.items.map(\.id)
        let heightChanged = headerHeight != self.headerHeight
        self.header = header
        self.headerHeight = headerHeight
        syncHeaderHost()
        if heightChanged, isViewLoaded { collectionView.collectionViewLayout.invalidateLayout() }
        guard changed else { return }
        self.items = items
        self.subtitles = subtitles
        guard isViewLoaded else { return }
        collectionView.reloadData()
        if !filledOnce, !items.isEmpty {
            filledOnce = true
            // The first titles in: focus to the first, unless it has moved on
            // (the loading state, which held focus, goes in the same update).
            prefersFirstTitle = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.prefersFirstTitle else { return }
                self.collectionView.layoutIfNeeded()
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }
    }

    // MARK: Titles

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
            as! FixedFocusDestinationCell
        let item = items[indexPath.item]
        cell.configure(item, subtitle: subtitles[item.id], index: indexPath.item, rowCell: nil, card: Self.card)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: Self.card.width, height: Self.card.height + FixedFocusMetrics.captionRoom)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        onDisplay?(items[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
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
        // The card, without its caption (a destination card's picture).
        let card = (cell as? FixedFocusDestinationCell)?.cardFrame ?? cell.bounds
        return HoldMenuRequest(entries: entries, anchor: cell.convert(card, to: nil))
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
    /// Its Back press: not passed on.
    private var swallowing = false

    /// Back deep in the page: up to the top first (the first title);
    /// at the top it leaves.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }), let first = firstTitle,
              let focused = focusedPath, focused != first
        else { return super.pressesBegan(presses, with: event) }
        backToTop = true
        swallowing = true
        let top = CGPoint(x: 0, y: -collectionView.contentInset.top)
        if collectionView.contentOffset.y > top.y {
            // Up to the top, then focus onto the first title.
            collectionView.setContentOffset(top, animated: true)
        } else {
            focusFirst()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if backToTop { focusFirst() }
    }

    private func focusFirst() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        backToTop = false
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallowed with its press (else the page still leaves).
        guard presses.contains(where: { $0.type == .menu }), swallowing else {
            return super.pressesEnded(presses, with: event)
        }
        swallowing = false
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if backToTop || prefersFirstTitle, let first = firstTitle,
           let cell = collectionView.cellForItem(at: first) { return [cell] }
        return super.preferredFocusEnvironments
    }

    private var focusedPath: IndexPath?

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        focusedPath = context.nextFocusedIndexPath
        // Moved by the viewer (from something in the page): no longer ours.
        if prefersFirstTitle, context.previouslyFocusedView?.isDescendant(of: collectionView) == true {
            prefersFirstTitle = false
        }
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
