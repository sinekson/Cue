import SwiftUI
import UIKit

// MARK: - A folder

/// A collection's folder, opened: its catalogs as Home's rows (fixed focus,
/// the focused row at its spot, the next one peeking), the folder's header
/// above the first — it moves up with it. One catalog: its titles
/// in the poster grid instead (a single row on its own page looks empty).
/// The same for every collection, whatever its layout in Nuvio (`viewMode`
/// is kept as it is). Its background is Home's (the same picture, or —
/// following the title — the folder's cover's colours, already there:
/// Home followed the folder's tile), so nothing changes as it opens.
struct FolderView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @Environment(\.dismiss) private var dismiss
    let collection: CueCollection
    let folder: CueCollectionFolder
    /// Opened from Movies / Series: only that type ("movie" / "series").
    var type: String? = nil
    let onSelect: (MetaItem) -> Void
    /// Details pushed without the system's slide (the zoom brings it in).
    var onOpenInPlace: ((MetaItem) -> Void)? = nil

    /// The catalogs, loading (started at the press — `PagePreparer`).
    @StateObject private var load: PageLoad<[CollectionResolver.FolderCatalog]>
    /// Rows: how far below the first row focus is (not the page's state —
    /// a move needn't re-render it), and Back's move up to it.
    @State private var rowsDepth = RowsDepth()
    @State private var rowsCommand: FixedFocusRowsCommand?
    @State private var gridBack = GridBack()

    final class RowsDepth { var depth = 0 }
    private var catalogs: [CollectionResolver.FolderCatalog]? { load.value }

    init(collection: CueCollection, folder: CueCollectionFolder, type: String? = nil,
         onSelect: @escaping (MetaItem) -> Void, onOpenInPlace: ((MetaItem) -> Void)? = nil) {
        self.collection = collection
        self.folder = folder
        self.type = type
        self.onSelect = onSelect
        self.onOpenInPlace = onOpenInPlace
        _load = StateObject(wrappedValue: PagePreparer.shared.take(Self.loadKey(collection, folder, type: type))
                                ?? PageLoad())
    }

    static func loadKey(_ collection: CueCollection, _ folder: CueCollectionFolder, type: String?) -> String {
        "folder|\(collection.id)|\(folder.id)|\(type ?? "")"
    }

    @MainActor
    static func catalogs(of folder: CueCollectionFolder, type: String?, addonManager: AddonManager,
                         tmdb: TMDBSettingsStore) async -> [CollectionResolver.FolderCatalog] {
        let catalogs = await CollectionResolver.catalogs(
            of: folder, addonManager: addonManager, addons: addonManager.addons,
            providers: CollectionProviders(tmdb: tmdb.isEnabled, trakt: TraktService.isConfigured),
            tmdbLanguage: tmdb.settings.language, type: type)
        // The first screen's pictures too: the page swaps in whole.
        await FixedFocusImages.prefetch(firstScreen(catalogs), within: .milliseconds(700))
        return catalogs
    }

    /// The pictures the page shows first, at the sizes its cards ask for:
    /// rows — the first row's wide card (backdrop, logo) and the posters
    /// beside it, the next row's posters; one catalog — the grid's first
    /// two lines.
    private static func firstScreen(_ catalogs: [CollectionResolver.FolderCatalog])
        -> [(url: String?, maxDimension: CGFloat)] {
        let poster = { (item: MetaItem, size: CGFloat) in (url: item.poster ?? item.background, maxDimension: size) }
        if catalogs.count == 1, let only = catalogs.first {
            return only.items.prefix(12).map { poster($0, FolderGridController.card.height) }
        }
        guard let first = catalogs.first?.items else { return [] }
        var pictures: [(url: String?, maxDimension: CGFloat)] = []
        if let box = first.first {
            pictures.append((box.background ?? box.poster, FixedFocusMetrics.boxWidth))
            pictures.append((box.logo, FixedFocusMetrics.boxWidth * 0.55))
        }
        pictures += first.dropFirst().prefix(4).map { poster($0, FixedFocusMetrics.height) }
        if catalogs.count > 1 {
            pictures += catalogs[1].items.prefix(7).map { poster($0, FixedFocusMetrics.height) }
        }
        return pictures
    }

    /// Above the header.
    private static let headerTop: CGFloat = 60
    /// The header: the cover tile (its height), name and subtitle.
    private static let headerHeight: CGFloat = FolderHeader.tileHeight
    /// The focused row's name: under the header.
    private static var rowTop: CGFloat { max(FixedFocusMetrics.rowTop, headerTop + headerHeight + 36) }

    private var providers: CollectionProviders {
        CollectionProviders(tmdb: tmdbSettings.isEnabled, trakt: TraktService.isConfigured)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ATVBackground(titles: true)
            content
        }
        // Back below the first row: up to it (one move, the header back in
        // view); on it, out. The grid: below its first line, up to the top
        // (`GridBack`).
        .onExitCommand {
            if rowsDepth.depth > 0 {
                rowsCommand = FixedFocusRowsCommand(action: .focusBillboard)
            } else if !gridBack.handle() {
                dismiss()
            }
        }
        .onAppear {
            // Opened without a press (a demo): it loads from here.
            load.start { [folder, type, addonManager, tmdbSettings] in
                await Self.catalogs(of: folder, type: type, addonManager: addonManager, tmdb: tmdbSettings)
            }
        }
        .onAppear {
            if let cover = folder.tileCoverImageUrl { TitleBackground.shared.follow(cover, key: folder.id) }
        }
    }

    /// The header: the folder's cover, its name, where it is and what's in
    /// it — the same while loading, over the rows and over the grid.
    private var header: FolderHeader {
        let subtitle: String
        if let catalogs, catalogs.count > 1 {
            subtitle = "\(collection.title) · \(catalogs.count) catalogs"
        } else if let only = catalogs?.first {
            subtitle = "\(collection.title) · \(Self.count(only.items.count))"
        } else {
            subtitle = collection.title
        }
        return FolderHeader(title: folder.title, subtitle: subtitle,
                            cover: folder.tileCoverImageUrl, emoji: folder.coverEmoji,
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
        // Loading: the rows' placeholders (most folders are rows) — the
        // same view the rows then fill.
        if catalogs == nil || catalogs!.count > 1 {
            rows(catalogs)
        } else if let only = catalogs?.first {
            FolderPosterGrid(header: AnyView(header), headerHeight: FolderGridController.defaultHeaderHeight,
                             items: only.items, subtitles: Self.years(only.items),
                             onSelect: onSelect, onOpenDetails: openDetails, back: gridBack)
                .ignoresSafeArea()
        } else {
            // Nothing to show: the header where the rows have it.
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(height: Self.headerHeight, alignment: .bottomLeading)
                    .padding(.top, Self.headerTop)
                Text(emptyMessage)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Rows

    /// Each catalog a row, Home's (the box tells the focused title); still
    /// loading (nil), two rows of empty cards, unnamed, out of focus's way.
    private func rows(_ catalogs: [CollectionResolver.FolderCatalog]?) -> some View {
        FixedFocusRows(rows: catalogs?.map { HomeRow(id: $0.id, title: $0.title, items: $0.items) }
                           ?? FixedFocusRows.placeholderRows,
                       featuredRowID: "", continueRowID: "", active: true, progress: [:],
                       placeholder: catalogs == nil,
                       rowTop: Self.rowTop,
                       aboveVisible: Self.rowTop - FixedFocusMetrics.peekGap,
                       onSelect: onSelect, onSelectFeatured: onSelect, onResume: { _ in },
                       onOpenDetails: openDetails,
                       titleMenu: { item, _ in TitleMenu.shared.entries(for: item) },
                       onDepth: { rowsDepth.depth = $0 },
                       command: rowsCommand,
                       pageHeader: AnyView(header
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

    /// The tile's height: the folder page's header (the rows keep their
    /// place).
    static let tileHeight: CGFloat = 100

    /// The tile at the folder's own shape, at a header's height.
    private var tileSize: CGSize {
        let height = Self.tileHeight
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
                        Text(emoji).font(.system(size: 46))
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
/// Back on a grid page: the page's `onExitCommand` asks first (a press
/// the grid took itself still reached the navigation, which left).
@MainActor
final class GridBack {
    weak var controller: FolderGridController?
    /// True: handled (the grid goes back up to its top).
    func handle() -> Bool { controller?.backToTopIfDeep() ?? false }
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
    /// Room above the header, part of the page (Search: under the keyboard,
    /// which scrolls with it).
    var topSpace: CGFloat = 0
    /// The first titles in: focus onto the first (Search: it stays on the
    /// keyboard).
    var focusesFirstTitle = true
    /// Search's Top Results: up to three tall cards, instead of the posters.
    var topResults: [MetaItem] = []
    /// Their height (Search: down to near the screen's bottom).
    var topResultHeight: CGFloat = 400

    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var theme: ThemeManager

    func makeUIViewController(context: Context) -> FolderGridController { FolderGridController() }

    func updateUIViewController(_ controller: FolderGridController, context: Context) {
        controller.topSpace = topSpace
        back?.controller = controller
        controller.focusesFirstTitle = focusesFirstTitle
        controller.topResultHeight = topResultHeight
        // The top results' chips get the app's stores.
        controller.environment = { [mdblist, theme] in
            AnyView($0.environmentObject(mdblist).environmentObject(theme))
        }
        controller.onSelect = onSelect
        controller.onOpenDetails = onOpenDetails
        controller.onDisplay = onDisplay
        controller.show(header: header, headerHeight: headerHeight, items: topResults.isEmpty ? items : topResults,
                        banner: !topResults.isEmpty, subtitles: subtitles, placeholder: placeholder)
    }
}

final class FolderGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                  UICollectionViewDelegateFlowLayout, HoldMenuProviding {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onOpenDetails: ((MetaItem) -> Void)?
    var onDisplay: ((MetaItem) -> Void)?

    var topSpace: CGFloat = 0 {
        didSet { if topSpace != oldValue { syncHeaderHost() } }
    }
    var focusesFirstTitle = true
    var environment: (AnyView) -> AnyView = { $0 }
    /// The titles show as Search's top results.
    private var isBanner = false
    /// Placeholders show (`FolderPosterGrid.placeholder`).
    private var isPlaceholder = false
    /// Their height (Search: down to near the screen's bottom).
    var topResultHeight: CGFloat = 400 {
        didSet { if topResultHeight != oldValue, isViewLoaded { collectionView.collectionViewLayout.invalidateLayout() } }
    }
    /// The page (Search's keyboard follows it).
    var scrollView: UIScrollView { collectionView }

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
    static var card: CGSize {
        let width = ((FixedFocusMetrics.bannerWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return CGSize(width: width, height: (width * 1.5).rounded())
    }

    /// The header: a view of its own in the scroll view's top inset, there
    /// while it scrolls (a cell goes once scrolled off, and its controls with
    /// it, out of reach).
    private var headerHost: UIHostingController<AnyView>?
    private var headerPositioned = false
    /// Above the header, in the inset.
    static let headerTopMargin: CGFloat = 60
    /// How close to the screen's top or bottom a focused line may come before
    /// the page moves.
    static let edgeMargin: CGFloat = 60
    /// Between the header and the first line.
    static let firstLineGap: CGFloat = 12

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.gap
        layout.minimumLineSpacing = 24
        layout.sectionInset = UIEdgeInsets(top: Self.firstLineGap, left: FixedFocusMetrics.inset, bottom: 48,
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
        collectionView.register(SearchTopResultCell.self, forCellWithReuseIdentifier: "top")
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
            // No header (Search): the titles still start under `topSpace`.
            applyTopInset(topSpace + Self.headerTopMargin)
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
        applyTopInset(topSpace + headerHeight + Self.headerTopMargin)
        host.view.frame = CGRect(x: 0, y: -headerHeight, width: collectionView.bounds.width, height: headerHeight)
        controlsGuideTop?.constant = topSpace + Self.headerTopMargin + headerHeight - 8
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
    func show(header: AnyView?, headerHeight: CGFloat, items: [MetaItem], banner: Bool = false,
              subtitles: [String: String], placeholder: Bool = false) {
        let leavingPlaceholder = isPlaceholder && !placeholder
        isPlaceholder = placeholder
        if isViewLoaded { collectionView.isUserInteractionEnabled = !placeholder }
        let changed = items.map(\.id) != self.items.map(\.id) || banner != isBanner
        isBanner = banner
        let heightChanged = headerHeight != self.headerHeight
        self.header = header
        self.headerHeight = headerHeight
        syncHeaderHost()
        if heightChanged, isViewLoaded { collectionView.collectionViewLayout.invalidateLayout() }
        guard changed else { return }
        self.items = items
        self.subtitles = subtitles
        guard isViewLoaded else { return }
        // A pill pressed (Search's Movies | Series): reloadData takes focus
        // away from the header (it's in the collection view) to the first
        // title. A section reload leaves it there.
        if leavingPlaceholder {
            // The titles take over the placeholders: one fade.
            UIView.transition(with: collectionView, duration: Motion.fadeDuration,
                              options: [.transitionCrossDissolve, .allowAnimatedContent]) {
                self.collectionView.reloadData()
                self.collectionView.layoutIfNeeded()
            }
        } else if let host = headerHost?.view, Self.focus(in: host) {
            UIView.performWithoutAnimation { collectionView.reloadSections(IndexSet(integer: 0)) }
        } else {
            collectionView.reloadData()
        }
        if !filledOnce, !items.isEmpty, focusesFirstTitle, !placeholder {
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

    // MARK: Titles

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = items[indexPath.item]
        if isBanner {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "top", for: indexPath)
                as! SearchTopResultCell
            cell.environment = environment
            cell.configure(item, index: indexPath.item)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
            as! FixedFocusDestinationCell
        cell.configure(item, subtitle: subtitles[item.id], index: indexPath.item, rowCell: nil, card: Self.card)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if isBanner { return CGSize(width: FixedFocusMetrics.bannerWidth, height: topResultHeight) }
        return CGSize(width: Self.card.width, height: Self.card.height + FixedFocusMetrics.captionRoom)
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
        let card = (cell as? FixedFocusDestinationCell)?.cardFrame ?? (cell as? SearchTopResultCell)?.cardFrame
            ?? cell.bounds
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

    /// Back below the first line (the page asks — `GridBack`): up to the
    /// top, the header whole, then focus onto the first title. On the first
    /// line (or the header): false — the page leaves.
    func backToTopIfDeep() -> Bool {
        guard firstTitle != nil, let focused = focusedPath, focused.item >= Self.columns else { return false }
        backToTop = true
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
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        backToTop = false
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if backToTop || prefersFirstTitle, let first = firstTitle,
           let cell = collectionView.cellForItem(at: first) { return [cell] }
        return super.preferredFocusEnvironments
    }

    private var focusedPath: IndexPath?
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

/// Search's Top Result: a card the content's width, from the grid's top
/// down to near the screen's bottom, the backdrop's middle filling it; at its foot, over a
/// dark fade, the billboard's text in its styles — the logo (or the name),
/// the chips, the facts, the tagline (no tagline: the name). Focused: Cue's
/// outline (no lift).
final class SearchTopResultCell: UICollectionViewCell, FixedFocusDestinationItem {
    private(set) var itemIndex = 0
    var rowCell: FixedFocusRowCell? { nil }
    /// Outside a row: the app's stores for its chips.
    var environment: (AnyView) -> AnyView = { $0 }

    private static let pad: CGFloat = 36
    private static let logoHeight: CGFloat = 84

    private let card = UIView()
    private let picture = UIImageView()
    private let fade = CAGradientLayer()
    private let logo = LeftAlignedImageView()
    /// The title in big type, where there's no logo.
    private let name = UILabel()
    private let facts = UILabel()
    /// The tagline (TMDB) — no tagline: the name.
    private let tagline = UILabel()
    private let chips = UIHostingController(rootView: AnyView(EmptyView()))
    /// Loads the facts' season count and the tagline.
    private var extras: Task<Void, Never>?
    private let outline = UIView()
    private let edge = UIImageView()
    private var item: MetaItem?

    var cardFrame: CGRect { bounds }

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        contentView.addSubview(card)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        card.addSubview(picture)
        fade.colors = [0, 0.6, 0.9].map { UIColor.black.withAlphaComponent($0).cgColor }
        fade.locations = [0, 0.5, 1]
        card.layer.addSublayer(fade)
        // The billboard's styles: the name big and bold, the facts bright,
        // the tagline quiet and italic.
        name.font = .systemFont(ofSize: 44, weight: .bold)
        name.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        name.numberOfLines = 2
        facts.font = .systemFont(ofSize: FixedFocusMetrics.textSize, weight: .medium)
        facts.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        tagline.font = UIFont(descriptor: UIFont.systemFont(ofSize: FixedFocusMetrics.textSize)
            .fontDescriptor.withSymbolicTraits(.traitItalic) ?? UIFont.systemFont(ofSize: FixedFocusMetrics.textSize).fontDescriptor,
                              size: FixedFocusMetrics.textSize)
        tagline.textColor = UIColor.white.withAlphaComponent(FixedFocusText.tagline)
        chips.view.backgroundColor = .clear
        chips.safeAreaRegions = []
        for view: UIView in [logo, name, chips.view, facts, tagline] { card.addSubview(view) }
        edge.isUserInteractionEnabled = false
        card.addSubview(edge)
        // A logo arriving replaces the name: laid out again.
        logo.imageView.onImage = { [weak self] in self?.setNeedsLayout() }
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = FixedFocusRing.color.cgColor
        outline.layer.borderWidth = FixedFocusRing.width
        outline.layer.cornerRadius = Spotlight.cornerRadius
        outline.layer.cornerCurve = .continuous
        outline.alpha = 0
        contentView.addSubview(outline)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: MetaItem, index: Int) {
        itemIndex = index
        if self.item?.id != item.id {
            picture.image = nil
            FixedFocusImages.load(item.background ?? item.poster, into: picture, maxDimension: 1280)
            logo.image = nil
            FixedFocusImages.load(item.logo, into: logo.imageView, maxDimension: 600)
            facts.text = FixedFocusShowInfo.factsLine(item)
            tagline.text = TMDBService.knownFacts(for: item)?.tagline ?? item.name
            extras?.cancel()
            extras = Task { @MainActor [weak self] in
                async let info = FixedFocusShowInfo.load(item)
                async let facts = TMDBService.facts(for: item)
                let (size, titleFacts) = await (info, facts)
                guard let self, !Task.isCancelled, self.item?.id == item.id else { return }
                self.facts.text = FixedFocusShowInfo.factsLine(item, info: size)
                if let line = titleFacts?.tagline { self.tagline.text = line }
            }
        }
        self.item = item
        name.text = item.name
        chips.rootView = environment(AnyView(TitleChipsLine(item: item)))
        outline.alpha = isFocused ? 1 : 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = bounds
        outline.frame = bounds
        picture.frame = card.bounds
        edge.image = FixedFocusCardEdge.rim
        edge.frame = card.bounds
        // At the card's foot, up from the bottom in the billboard's order
        // and rhythm: the logo (or the name), the chips, the facts, the
        // tagline.
        let x = Self.pad, width = bounds.width - 2 * Self.pad
        let hasLogo = logo.image != nil
        name.isHidden = hasLogo
        logo.isHidden = !hasLogo
        let titleHeight = hasLogo ? Self.logoHeight
            : name.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let line = FixedFocusMetrics.factsHeight
        let gap = FixedFocusMetrics.factsOffset - 30   // the billboard's line step
        var y = bounds.height - Self.pad - 30
        tagline.frame = CGRect(x: x, y: y, width: width, height: 30)
        y -= gap + line
        facts.frame = CGRect(x: x, y: y, width: width, height: line)
        y -= gap + FixedFocusBillboardText.chipsGap + line
        chips.view.frame = CGRect(x: x, y: y, width: width, height: line)
        y -= FixedFocusBillboardText.logoToChips + titleHeight
        logo.frame = CGRect(x: x, y: y, width: min(width, 520), height: Self.logoHeight)
        name.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        let fadeTop = max(0, y - 100)
        fade.frame = CGRect(x: 0, y: fadeTop, width: bounds.width, height: bounds.height - fadeTop)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        FixedFocusMotion.run(duration: Motion.focusDuration) {
            self.outline.alpha = focused ? 1 : 0
        } completion: { _ in }
    }
}
