import SwiftUI
import UIKit

// MARK: - A folder

/// A collection's folder, opened: an overview of its catalogs — as ROWS
/// (each catalog a part: its name and count, two lines of its titles, a
/// "See All" tile when it has more) or a TABBED GRID (a tab per catalog, its
/// titles in the grid), as the collection is set up in Nuvio (rows when
/// unset). With `part`, one catalog's titles in full (its "See All").
/// Only ever scrolls vertically; the header scrolls away with the titles.
/// Poster style of Saved for Later and Search, on the folder's own colour
/// (its cover's).
struct FolderView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let collection: CueCollection
    let folder: CueCollectionFolder
    /// One catalog (its id), in full.
    var part: String? = nil
    let onSelect: (MetaItem) -> Void
    /// Details pushed without the system's slide (the zoom brings it in).
    var onOpenInPlace: ((MetaItem) -> Void)? = nil
    /// A part's "See All": its catalog id.
    var onSeeAll: (String) -> Void = { _ in }

    @State private var catalogs: [CollectionResolver.FolderCatalog]?
    @State private var tint: Color?
    /// The grid's tab (a catalog's id; `allTab` for every title).
    @State private var tab: String?
    private static let allTab = "all"
    /// A part on the overview: two lines of seven (the last a "See All"
    /// tile when there are more).
    private static let partCap = 14

    /// The folder's catalogs as last resolved, for its parts' pages.
    @MainActor private static var resolved: [String: [CollectionResolver.FolderCatalog]] = [:]

    private var isGrid: Bool { part == nil && collection.viewMode.uppercased() == "TABBED_GRID" }

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
            // A part's page: what the folder just showed.
            if part != nil, let known = Self.resolved[folder.id] { catalogs = known; return }
            let found = await CollectionResolver.catalogs(
                of: folder, addonManager: addonManager, addons: addonManager.addons,
                providers: providers, tmdbLanguage: tmdbSettings.settings.language)
            Self.resolved[folder.id] = found
            catalogs = found
        }
        .task(id: folder.tileCoverImageUrl) {
            guard let cover = folder.tileCoverImageUrl else { return }
            FixedFocusColors.color(for: cover) { tint = Color($0) }
        }
    }

    /// The header: the folder's cover, its name (a part's: the part's), and
    /// where it is with what's in it.
    private var header: FolderHeader {
        let shown = part.flatMap { id in catalogs?.first { $0.id == id } }
        let subtitle: String
        if let shown {
            subtitle = [collection.title, folder.title, Self.count(shown.items.count)].joined(separator: " · ")
        } else if let catalogs, catalogs.count > 1 {
            subtitle = "\(collection.title) · \(catalogs.count) catalogs"
        } else {
            subtitle = collection.title
        }
        return FolderHeader(title: shown?.title ?? folder.title, subtitle: subtitle,
                            cover: folder.tileCoverImageUrl, emoji: folder.coverEmoji, shape: folder.tileShape)
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 title" : "\(n) titles" }

    @ViewBuilder private var content: some View {
        if let catalogs, !catalogs.isEmpty {
            if isGrid { grid(catalogs) } else { rows(catalogs) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
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

    /// Titles open Details through `DetailTransition`.
    private var openDetails: ((MetaItem) -> Void)? {
        onOpenInPlace.map { push in
            { item in DetailTransition.shared.open(item) { push(item) } }
        }
    }

    private static func years(_ items: [MetaItem]) -> [String: String] {
        Dictionary(items.compactMap { item in item.year.map { (item.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Rows

    /// The overview: each catalog a part (capped, its "See All" beyond) —
    /// or, for a part's page, that catalog in full.
    private func rows(_ catalogs: [CollectionResolver.FolderCatalog]) -> some View {
        let shown = part.map { id in catalogs.filter { $0.id == id } } ?? catalogs
        return FolderPosterGrid(header: header,
                                sections: shown.map {
                                    FolderSection(id: $0.id, title: part == nil ? $0.title : nil, items: $0.items,
                                                  subtitles: Self.years($0.items))
                                },
                                cap: part == nil ? Self.partCap : nil,
                                onSelect: onSelect, onOpenDetails: openDetails, onSeeAll: onSeeAll)
            .ignoresSafeArea()
    }

    // MARK: Grid

    /// A tab per catalog ("All" first, when the collection has it) — the
    /// grid follows the focused tab — and its titles in a poster grid.
    private func grid(_ catalogs: [CollectionResolver.FolderCatalog]) -> some View {
        let tabs = (collection.showAllTab && catalogs.count > 1
                    ? [(Self.allTab, "All")] : []) + catalogs.map { ($0.id, $0.title) }
        let current = tab ?? tabs.first?.0
        let items = current == Self.allTab ? merged(catalogs) : catalogs.first { $0.id == current }?.items ?? []
        return VStack(alignment: .leading, spacing: 24) {
            header
                .padding(.top, 30)
                .ignoresSafeArea(edges: .horizontal)
            if tabs.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(tabs, id: \.0) { id, title in
                            Button { tab = id } label: { Text(title) }
                                .buttonStyle(PillButtonStyle(selected: id == current))
                                // Focus picks the tab (as the top bar does).
                                .onFocusChange(id: id) { tab = $0 }
                        }
                    }
                    .padding(.horizontal, FixedFocusMetrics.titleInset)
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            FolderPosterGrid(header: nil,
                             sections: [FolderSection(id: current ?? "", title: nil, items: items,
                                                      subtitles: Self.years(items))],
                             cap: nil, onSelect: onSelect, onOpenDetails: openDetails, onSeeAll: { _ in })
                .id(current)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
    }

    /// Every catalog's titles, each once.
    private func merged(_ catalogs: [CollectionResolver.FolderCatalog]) -> [MetaItem] {
        var seen = Set<String>()
        return catalogs.flatMap(\.items).filter { seen.insert($0.id).inserted }
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

private extension View {
    /// Calls `action(id)` when this gets focus.
    func onFocusChange(id: String, _ action: @escaping (String) -> Void) -> some View {
        modifier(FocusPick(id: id, action: action))
    }
}

private struct FocusPick: ViewModifier {
    let id: String
    let action: (String) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, now in if now { action(id) } }
    }
}

/// A part of the folder's grid: a catalog's name (nil: none) and titles.
struct FolderSection {
    let id: String
    let title: String?
    let items: [MetaItem]
    let subtitles: [String: String]
}

/// A folder's titles as a poster grid in parts: Home's destination cards
/// (outline, grow, shadow; name and year below), seven to a line; scrolls
/// vertically only, the header (when given) scrolling with it.
private struct FolderPosterGrid: UIViewControllerRepresentable {
    let header: FolderHeader?
    let sections: [FolderSection]
    /// Titles a part shows at most (the last place then "See All"); nil: all.
    let cap: Int?
    let onSelect: (MetaItem) -> Void
    let onOpenDetails: ((MetaItem) -> Void)?
    let onSeeAll: (String) -> Void

    func makeUIViewController(context: Context) -> FolderGridController { FolderGridController() }

    func updateUIViewController(_ controller: FolderGridController, context: Context) {
        controller.onSelect = onSelect
        controller.onOpenDetails = onOpenDetails
        controller.onSeeAll = onSeeAll
        controller.show(header: header.map { AnyView($0) }, sections: sections, cap: cap)
    }
}

final class FolderGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                  UICollectionViewDelegateFlowLayout, HoldMenuProviding {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onOpenDetails: ((MetaItem) -> Void)?
    var onSeeAll: (String) -> Void = { _ in }

    private var header: AnyView?
    private var sections: [FolderSection] = []
    private var cap: Int?
    private var collectionView: UICollectionView!

    private static let columns = 7
    private static let gap = FixedFocusMetrics.destinationGap
    private static let headerHeight: CGFloat = 150
    /// Between one part and the next.
    private static let partGap: CGFloat = 72

    /// A poster: seven fill the content's width.
    static var card: CGSize {
        let width = ((FixedFocusMetrics.bannerWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return CGSize(width: width, height: (width * 1.5).rounded())
    }

    /// The header takes the first section (one cell, never focused).
    private var offset: Int { header == nil ? 0 : 1 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.gap
        layout.minimumLineSpacing = 24
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
        collectionView.register(FolderSeeAllCell.self, forCellWithReuseIdentifier: "seeAll")
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "header")
        collectionView.register(FolderSectionHeader.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: FolderSectionHeader.id)
        view.addSubview(collectionView)
    }

    func show(header: AnyView?, sections: [FolderSection], cap: Int?) {
        let changed = (header == nil) != (self.header == nil) || cap != self.cap
            || sections.map(\.id) != self.sections.map(\.id)
            || sections.map(\.items.count) != self.sections.map(\.items.count)
        self.header = header
        guard changed else {
            // The header's text can change (the catalogs' count): just it.
            if isViewLoaded, header != nil { collectionView.reloadItems(at: [IndexPath(item: 0, section: 0)]) }
            return
        }
        self.sections = sections
        self.cap = cap
        if isViewLoaded { collectionView.reloadData() }
    }

    // MARK: Parts

    private func part(_ section: Int) -> FolderSection? {
        sections.indices.contains(section - offset) ? sections[section - offset] : nil
    }

    /// More titles than the part shows: its last place is "See All".
    private func isCapped(_ part: FolderSection) -> Bool {
        cap.map { part.items.count > $0 } ?? false
    }

    private func isSeeAll(_ path: IndexPath) -> Bool {
        guard let part = part(path.section), let cap, isCapped(part) else { return false }
        return path.item == cap - 1
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count + offset }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let part = part(section) else { return 1 }
        return isCapped(part) ? cap! : part.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let part = part(indexPath.section) else {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "header", for: indexPath)
            // Its own lead (the rows' names'), not the screen's safe area too.
            if let header {
                cell.contentConfiguration = UIHostingConfiguration { header.ignoresSafeArea() }.margins(.all, 0)
            }
            return cell
        }
        if isSeeAll(indexPath) {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "seeAll", for: indexPath)
                as! FolderSeeAllCell
            cell.configure(count: part.items.count, card: Self.card)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
            as! FixedFocusDestinationCell
        let item = part.items[indexPath.item]
        cell.configure(item, subtitle: part.subtitles[item.id], index: indexPath.item, rowCell: nil,
                       card: Self.card)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        part(indexPath.section) != nil
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard part(indexPath.section) != nil else {
            return CGSize(width: collectionView.bounds.width, height: Self.headerHeight)
        }
        return CGSize(width: Self.card.width, height: Self.card.height + FixedFocusMetrics.captionRoom)
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: FolderSectionHeader.id,
                                                                   for: indexPath) as! FolderSectionHeader
        if let part = part(indexPath.section), let title = part.title {
            view.show(title: title, count: part.items.count)
        }
        return view
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        guard part(section)?.title != nil else { return .zero }
        return CGSize(width: collectionView.bounds.width, height: FixedFocusMetrics.titleHeight)
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        insetForSectionAt section: Int) -> UIEdgeInsets {
        guard part(section) != nil else { return UIEdgeInsets(top: 60, left: 0, bottom: 24, right: 0) }
        let last = section == sections.count + offset - 1
        return UIEdgeInsets(top: 12, left: FixedFocusMetrics.inset, bottom: last ? 48 : Self.partGap,
                            right: FixedFocusMetrics.inset)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let part = part(indexPath.section) else { return }
        if isSeeAll(indexPath) { onSeeAll(part.id); return }
        let item = part.items[indexPath.item]
        if let onOpenDetails {
            onOpenDetails(item)
        } else {
            onSelect(item)
        }
    }

    /// Select held on a title: its menu (`TitleMenu`, see `HoldMenu`).
    func holdMenu(for focused: UIView) -> HoldMenuRequest? {
        guard let cell = focused as? UICollectionViewCell, let path = collectionView.indexPath(for: cell),
              let part = part(path.section), !isSeeAll(path) else { return nil }
        let entries = TitleMenu.shared.entries(for: part.items[path.item])
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
    private var firstTitle: IndexPath? {
        sections.isEmpty ? nil : IndexPath(item: 0, section: offset)
    }
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
        if collectionView.contentOffset.y > 0 {
            // Up to the top, then focus onto the first title.
            collectionView.setContentOffset(.zero, animated: true)
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
        if backToTop, let first = firstTitle, let cell = collectionView.cellForItem(at: first) { return [cell] }
        return super.preferredFocusEnvironments
    }

    private var focusedPath: IndexPath?

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        focusedPath = context.nextFocusedIndexPath
    }
}

/// A part's name, as Home's row names, with how many titles it has.
final class FolderSectionHeader: UICollectionReusableView {
    static let id = "folder.section"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.frame = CGRect(x: FixedFocusMetrics.titleInset, y: 0, width: 1400, height: FixedFocusMetrics.titleLine)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, count: Int) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: Spotlight.headerTitleSize, weight: .semibold),
            .foregroundColor: UIColor.white,
        ])
        text.append(NSAttributedString(string: "   \(count)", attributes: [
            .font: UIFont.systemFont(ofSize: Spotlight.headerTitleSize * 0.8, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.45),
        ]))
        label.attributedText = text
    }
}

/// A part's last place on the overview: "See All" and how many titles —
/// a poster-sized tile, lit and grown like a poster when focused.
final class FolderSeeAllCell: UICollectionViewCell {
    private let tile = UIView()
    private let title = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        tile.layer.cornerRadius = TileArt.radius
        tile.layer.cornerCurve = .continuous
        contentView.addSubview(tile)
        title.text = "See All"
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textAlignment = .center
        detail.font = .systemFont(ofSize: 22, weight: .medium)
        detail.textAlignment = .center
        tile.addSubview(title)
        tile.addSubview(detail)
        style(focused: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, card: CGSize) {
        // Bounds and centre: the tile may be grown (a transform) right now.
        tile.bounds = CGRect(origin: .zero, size: card)
        tile.center = CGPoint(x: card.width / 2, y: card.height / 2)
        title.frame = CGRect(x: 0, y: card.height / 2 - 40, width: card.width, height: 40)
        detail.frame = CGRect(x: 0, y: card.height / 2 + 6, width: card.width, height: 30)
        detail.text = FolderView.count(count)
    }

    private func style(focused: Bool) {
        tile.backgroundColor = UIColor(focused ? FlatControl.focus : FlatControl.rest)
        title.textColor = focused ? .black : .white
        detail.textColor = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
        tile.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.style(focused: focused) }
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
