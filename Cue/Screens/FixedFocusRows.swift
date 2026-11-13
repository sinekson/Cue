import SwiftUI

struct FixedFocusRows: UIViewControllerRepresentable {
    /// A page's rows while its content loads: two unnamed rows of empty
    /// cards (flat, the card edge) — exactly where the content will be.
    static let placeholderRows: [HomeRow] = (0..<2).map { row in
        HomeRow(id: "placeholder-\(row)", title: "", items: (0..<8).map {
            MetaItem(id: "placeholder-\(row)-\($0)", type: "collection", name: "", poster: nil, background: nil)
        })
    }

    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let rows: [HomeRow]
    let featuredRowID: String
    let continueRowID: String
    let active: Bool
    let progress: [String: WatchProgress]
    /// Placeholders while the page's content loads (`placeholderRows`):
    /// drawn, but out of focus's way; focus goes in once the content's in.
    var placeholder = false
    /// Rows of landscape cards besides Continue Watching (Search's).
    var landscapeRowIDs: Set<String> = []
    /// Collection rows: landscape tiles in a panel (see `FixedFocusPanelView`).
    var panelRowIDs: Set<String> = []
    /// Destination rows (see `FixedFocusMetrics.posterCard`).
    var destinationRowIDs: Set<String> = []
    /// Of them, ranked (Top 10: each card's place beside it).
    var rankedRowIDs: Set<String> = []
    /// Of them, showcases (New & Notable: tall cards, the trailer in the
    /// focused one), and whether its trailers play, with sound.
    var showcaseRowIDs: Set<String> = []
    var showcaseTrailers: (on: Bool, sound: Bool) = (false, false)
    /// Names under moving-focus cards (Home has none: the art says it).
    var captions = true
    /// The focused row centred on the screen (Home, as Apple TV's), the
    /// rows above and below peeking alike.
    var centred = false
    /// Rows of ONE wide banner (Search's Top Result: see
    /// `FixedFocusBannerCell`), and its height.
    var bannerRowIDs: Set<String> = []
    var bannerHeight: CGFloat = FixedFocusMetrics.bannerHeight
    /// Destination rows of smaller portraits (`FixedFocusMetrics.portraitCard`).
    var portraitRowIDs: Set<String> = []
    /// Where the focused row's name sits (Home's spot by default)…
    var rowTop: CGFloat = FixedFocusMetrics.rowTop
    /// …and how much of the rows above and below shows.
    var aboveVisible: CGFloat = FixedFocusMetrics.aboveVisible
    var belowVisible: CGFloat = FixedFocusMetrics.belowVisible
    /// The focus outline only while focus is in the rows.
    var ringOnlyWithFocus = false
    /// New content starts over: the first row, each row's first title
    /// (Search: a new query). Home keeps its places.
    var startsOverOnChange = false
    let onSelect: (MetaItem) -> Void
    let onSelectFeatured: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    /// Select on a title's card (not the billboard, not Continue Watching,
    /// not a folder): the title and the card as the morph's start — Details
    /// opens through `DetailTransition`. nil: `onSelect`.
    var onOpenDetails: ((MetaItem) -> Void)? = nil
    /// A choice in a Continue Watching card's hold menu (the system context
    /// menu): the row and the card as a zoom's start. nil: no menu.
    var onContinueMenu: ((ContinueMenuAction, WatchProgress) -> Void)? = nil
    /// Select held on a title's card (not a billboard, not a folder): its
    /// menu's items (`TitleMenu`), given the title and its row's id. nil: no menu.
    var titleMenu: ((MetaItem, String) -> [MenuEntry])? = nil
    /// How far below the billboard the focused row is (0: on it or no
    /// billboard; 1: the first row below).
    var onDepth: (Int) -> Void = { _ in }
    /// Details: the billboard's focus is OUTSIDE the rows (its buttons) —
    /// its invisible cards take focus only on the way back up.
    var externalBillboard = false
    /// A card's state line on its picture (Details' episodes).
    var cardStates: [String: FixedFocusCardState] = [:]
    /// Select on a card, before anything else (true: handled) — Details plays
    /// its episodes.
    var onSelectInRow: ((MetaItem, String) -> Bool)? = nil
    /// Up out of these rows doesn't go to the row above: `onUpExit` gets
    /// the row's id (Details: its season pill takes focus).
    var upExitRowIDs: Set<String> = []
    var onUpExit: (String) -> Void = { _ in }
    /// Rows whose name doesn't show (something drawn in its place —
    /// Details' season control).
    var hiddenTitleRowIDs: Set<String> = []
    /// A one-off request from outside (a new id runs it once).
    var command: FixedFocusRowsCommand? = nil
    /// RIGID billboard (Details): under the billboard the first row waits
    /// with its name HERE (screen y) and its cards hidden right below it —
    /// the layout of the rows, just lower. Down / Up move everything one
    /// distance, nothing else (nil: Home's scroll, the name lifted onto the
    /// billboard).
    var rigidRest: CGFloat? = nil
    /// …and, lifted above its cards, where its NAME shows on the billboard
    /// (screen y of its line): the lift shrinks to nothing on Down, so the
    /// name and the cards meet (Home's `liftNextTitle`).
    var rigidNameY: CGFloat? = nil
    /// RIGID billboard: the next row PEEKS instead — its cards' top this far
    /// up the screen's bottom edge (dimmed, its name hidden); the row rests
    /// that much higher (nil: hidden, its name on the billboard).
    var rigidPeek: CGFloat? = nil
    /// …and its name stays above its cards (Home); off: hidden (Details).
    var rigidPeekShowsName = false
    /// The peek and the dots out the bottom (while the billboard's trailer
    /// is on it); the cards stay focusable.
    var peekHidden = false
    /// Home's billboard in Details' looks (`BillboardOpening`).
    var openingLook = false
    /// Details: its peek follows `BillboardOpening.detailsArriving` itself
    /// (the page observing it re-rendered whole — a stall mid-move).
    var followsDetailsArriving = false
    /// Paged with the peek moved out: back in at the press (the controller
    /// moves it; this tells the page, for the dots).
    var onPeekBack: () -> Void = {}
    /// The billboard's picture isn't drawn by the rows (Details draws its
    /// own, fixed, behind them).
    var hidesBillboardPicture = false
    /// SwiftUI on its own line under a row's name (or its header) — the
    /// row's cards lower by as much (`titleAccessoryHeight`, under a header
    /// `headerAccessoryHeight`); shown while the row has focus (Details'
    /// season progress).
    var rowTitleAccessories: [String: AnyView] = [:]
    /// Rows with glass buttons in their name's place while they have focus
    /// (Details' seasons): moving focus along them (Up from the cards),
    /// Up to the billboard, Down into the row. A button taking focus is
    /// reported to `onHeaderFocus` (row id, button index).
    var rowHeaders: [String: FixedFocusRowHeader] = [:]
    var onHeaderFocus: (String, Int) -> Void = { _, _ in }
    /// The billboard's own text and buttons (Details), hosted by the rows
    /// and moved (and dimmed) with them in the SAME animation — as a SwiftUI
    /// layer outside, it was animated by SwiftUI on the main thread and fell
    /// behind the rows (Core Animation) whenever the page was busy.
    var billboardOverlay: AnyView? = nil
    /// A page's header above the first row (a folder page), from the
    /// screen's top, `pageHeaderHeight` tall: moves up with that row.
    var pageHeader: AnyView? = nil
    var pageHeaderHeight: CGFloat = 0
    /// Its height from the top of the screen: no more than its content needs
    /// — over the rows it hides them from focus (tvOS skips what's covered).
    var billboardOverlayHeight: CGFloat = 1080
    /// The overlay UNDER the rows (Home: its dots reach down over the first
    /// row's peek — over the rows it would hide it from focus; its buttons
    /// go over them, `billboardControls`).
    var billboardOverlayBelowRows = false
    /// Moved by this much more once the billboard is up (Home's dots: from
    /// the peek to the strip's middle), in the same animation.
    var billboardOverlayShift: CGFloat = 0
    /// The billboard's buttons, over the rows when the text is under them
    /// (Home), from the screen's top, `billboardControlsHeight` tall.
    var billboardControls: AnyView? = nil
    var billboardControlsHeight: CGFloat = 1080
    /// The billboard's text ON its pictures (Home): each picture carries
    /// its title's text — one card, sliding as one (`StagePictureView`).
    var billboardPageText: ((MetaItem) -> AnyView)? = nil
    /// A press during the billboard's slide paged (+1 / -1).
    var onBillboardStep: (Int) -> Void = { _ in }
    /// Focus on the billboard's last button (+1, Next) / first (-1, Details),
    /// else 0 — holding Left/Right there pages on.
    var billboardEdge: () -> Int = { 0 }
    /// RIGID billboard (Home): its picture doesn't scroll with the rows — it
    /// stays, blurs and darkens on the way down, then gives way to the
    /// background's colours (`StagePictureView.blursBelow`).
    var pinnedBillboardPicture = false
    /// The billboard's trailer plays on the pinned picture.
    var billboardTrailer: StageTrailer? = nil
    /// How far the billboard itself (picture, text) goes up for the first
    /// row, if not the rows' distance (Home: until its edge is at the top
    /// bar's middle — the rows' usual peek above).
    var rigidBillboardTravel: CGFloat? = nil
    /// Moving-focus rows whose focus stays in place: every step also scrolls
    /// the row, the focused card always at the first card's spot (Details'
    /// episodes). Others scroll only at the edge of the cards in view.
    var anchoredRowIDs: Set<String> = []
    /// Rows that are a SwiftUI view, not cards (Details' About): its own
    /// focusable parts; focus moving into it moves the rows as any row.
    var customRows: [String: FixedFocusCustomRow] = [:]
    /// Moving-focus rows of logos (Details' network & studios): small wide
    /// cards, each logo fitted on a light plate (logos are drawn for light
    /// ground).
    var logoRowIDs: Set<String> = []
    let onFocusItem: (MetaItem, FixedFocusBillboardPosition?) -> Void

    func makeUIViewController(context: Context) -> FixedFocusRowsController {
        let controller = FixedFocusRowsController()
        apply(to: controller, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: FixedFocusRowsController, context: Context) {
        apply(to: controller, animated: context.transaction.animation != nil
              && !context.transaction.disablesAnimations)
    }

    private func apply(to controller: FixedFocusRowsController, animated: Bool) {
        controller.onSelect = onSelect
        controller.onSelectFeatured = onSelectFeatured
        controller.onResume = onResume
        controller.onOpenDetails = onOpenDetails
        controller.onContinueMenu = onContinueMenu
        controller.titleMenu = titleMenu
        // SwiftUI inside the cells (the banner's chips) gets the app's stores.
        controller.environment = { [mdblist] in
            AnyView($0.environmentObject(mdblist))
        }
        controller.billboardPageText = billboardPageText
        controller.onBillboardStep = onBillboardStep
        controller.billboardEdge = billboardEdge
        controller.onFocusItem = onFocusItem
        controller.onDepth = onDepth
        controller.externalBillboard = externalBillboard
        controller.cardStates = cardStates
        controller.onSelectInRow = onSelectInRow
        controller.upExitRowIDs = upExitRowIDs
        controller.onUpExit = onUpExit
        controller.hiddenTitleRowIDs = hiddenTitleRowIDs
        controller.rigidRest = rigidRest
        controller.rigidPeek = rigidPeek
        controller.rigidPeekShowsName = rigidPeekShowsName
        controller.onPeekBack = onPeekBack
        controller.peekHidden = peekHidden
        controller.followsDetailsArriving = followsDetailsArriving
        if !followsDetailsArriving { controller.setOpeningLook(openingLook, animated: animated) }
        controller.rigidNameY = rigidNameY
        controller.hidesBillboardPicture = hidesBillboardPicture
        controller.rowTitleAccessories = rowTitleAccessories
        controller.anchoredRowIDs = anchoredRowIDs
        controller.customRows = customRows
        controller.logoRowIDs = logoRowIDs
        controller.onHeaderFocus = onHeaderFocus
        controller.rowHeaders = rowHeaders
        controller.continueRowID = continueRowID
        controller.landscapeRowIDs = landscapeRowIDs
        controller.panelRowIDs = panelRowIDs
        controller.rankedRowIDs = rankedRowIDs
        controller.showcaseRowIDs = showcaseRowIDs
        controller.showcaseTrailers = showcaseTrailers
        controller.captions = captions
        controller.centred = centred
        controller.destinationRowIDs = destinationRowIDs
        controller.bannerRowIDs = bannerRowIDs
        controller.bannerHeight = bannerHeight
        controller.portraitRowIDs = portraitRowIDs
        controller.rowTop = rowTop
        controller.aboveVisible = aboveVisible
        controller.belowVisible = belowVisible
        controller.ringOnlyWithFocus = ringOnlyWithFocus
        controller.startsOverOnChange = startsOverOnChange
        controller.featuredRowID = featuredRowID
        // Another tab in front: out of the focus engine's way (a
        // transparent SwiftUI layer alone doesn't guarantee that) —
        // `setActive`.
        if controller.isViewLoaded { controller.setActive(active) }
        let progressChanged = controller.progress != progress
        controller.progress = progress
        if controller.isPlaceholder, !placeholder, controller.isViewLoaded, !PageFade.shared.covering {
            // The content takes over the placeholders: one fade, the page.
            UIView.transition(with: controller.view, duration: Motion.fadeDuration,
                              options: [.transitionCrossDissolve, .allowAnimatedContent]) {
                controller.update(rows)
            }
        } else {
            controller.update(rows)
        }
        // The same titles with new positions don't reload: the visible cards
        // take them here.
        if progressChanged, controller.isViewLoaded { controller.showProgress() }
        controller.setPlaceholder(placeholder)
        if let command { controller.run(command) }
        controller.billboardOverlayHeight = billboardOverlayHeight
        controller.billboardOverlayBelowRows = billboardOverlayBelowRows
        controller.billboardOverlayShift = billboardOverlayShift
        controller.rigidBillboardTravel = rigidBillboardTravel
        controller.pinnedBillboardPicture = pinnedBillboardPicture
        billboardTrailer?.stage = controller.pinnedStage
        controller.setBillboardOverlay(billboardOverlay)
        controller.billboardControlsHeight = billboardControlsHeight
        controller.setBillboardControls(billboardControls)
        controller.setPageHeader(pageHeader, height: pageHeaderHeight)
    }
}

/// Geometry shared by the controller and its cells (points, 1920 × 1080).
enum FixedFocusMetrics {
    /// THE GAP between cards at rest, every row (fixed or moving focus,
    /// the box beside its posters, grids): Apple TV's. A lifted card grows
    /// into it. (24 in the fixed rows beside 32 in the others read uneven.)
    static let gap: CGFloat = 40
    /// The original margin: the box lines up with the row names; a strip
    /// of the previous poster peeks in left of it.
    static let inset: CGFloat = Spotlight.screenInset
    /// Text next to the rounded box is indented a little (optical
    /// alignment: the corner makes the edge look further in than it is).
    static let textIndent: CGFloat = 5
    static var titleInset: CGFloat { inset + textIndent }
    /// The box 16:9 and the posters 2:3, both the portrait poster's height
    /// (`Spotlight.rowHeight`) — about 3½ posters right of the box.
    static let height: CGFloat = Spotlight.rowHeight
    static let posterWidth: CGFloat = Spotlight.posterWidth
    static let boxWidth: CGFloat = Spotlight.boxWidth
    static var pitch: CGFloat { posterWidth + gap }
    /// A landscape card's width at a given height (the box's 16:9).
    static func landscapeWidth(height card: CGFloat) -> CGFloat { card * boxWidth / height }
    /// The row name (the original Home's size): its line, then a small gap
    /// to the row — it belongs to the row.
    static let titleLine: CGFloat = 48
    static let titleHeight: CGFloat = titleLine + 14
    /// The name sits this much low in its line, near its cards (centred it
    /// looked to float above the row).
    static let titleDrop: CGFloat = 6
    /// The row below shows as much as on the original Home at the bottom
    /// edge (a little under half); the row above shows what's left of it.
    /// Rows further up / down than the neighbours: a whole row apart.
    static var rowPitch: CGFloat { titleHeight + height + 70 }
    /// The row above: this much of its cards shows at the top (trial: fixed,
    /// 44 pt above the focused row's name).
    static let aboveVisible: CGFloat = 78
    /// Between the focused row's cards and the row below's name.
    static let peekGap: CGFloat = 56
    /// Home's centred rows (`FixedFocusRows.centred`): a little more room
    /// between the focused row and its peeks.
    static let centredGap: CGFloat = 64
    /// The row below: this much of its posters shows at the bottom (as on
    /// the original Home — a little under half).
    static var belowVisible: CGFloat { Spotlight.previewVisibleHeight }
    /// Rows out of focus that peek (above and below, under a billboard):
    /// gently dimmed (45 % was too dark, full brightness too loud).
    static let peekAlpha: CGFloat = 0.8
    /// Rows waiting under a rigid billboard (Details) that don't peek.
    static let dimmedAlpha: CGFloat = 0.45
    /// The posters left of the box in the focused row.
    static let previousAlpha: CGFloat = 0.45
    /// The focused row's name (trial: fixed, just under the top bar).
    static let rowTop: CGFloat = 122
    /// DESTINATION rows (Saved for Later, collections) — you go there for
    /// something you already know, not to be shown one title at a time:
    /// the system's own scrolling and lift, and a caption under every card.
    /// THE PORTRAIT POSTER, everywhere — Home's fixed rows (their height,
    /// `Spotlight.rowHeight`), moving focus (Search, Saved for Later, Top
    /// 10, Details' rows) and the grids: six across the content's width,
    /// the rows' gaps between them, the next one peeking (Apple TV's size).
    static let posterCard = posters(across: 6)
    /// THE SHOWCASE CARD (New & Notable): 4:5, three across (Apple TV's).
    static let showcaseCard: CGSize = {
        let width = cardWidth(across: 3)
        return CGSize(width: width, height: (width * 5 / 4).rounded())
    }()
    /// A TOP 10'S CARD: a small showcase card, five across (two lines of
    /// five fill the screen), square (8:9 left the row below only its
    /// name to peek): the
    /// picture, its place and logo on it, a slim genre line.
    static let rankedCard: CGSize = {
        let width = cardWidth(across: 5)
        return CGSize(width: width, height: width)
    }()
    /// Smaller portraits for long rows of people (Details' Cast & Crew):
    /// seven across.
    static let portraitCard = posters(across: 7)
    /// 2:3 cards, `count` across the content's width with the rows' gaps.
    private static func posters(across count: Int) -> CGSize {
        let width = cardWidth(across: count)
        return CGSize(width: width, height: (width * 1.5).rounded())
    }
    /// A moving-focus card's width, `count` across the content's width
    /// with the rows' gaps.
    private static func cardWidth(across count: Int) -> CGFloat {
        let n = CGFloat(count)
        var width = (bannerWidth / n).rounded(.down)
        while width > 100, n * width + (n - 1) * gap > bannerWidth {
            width -= 1
        }
        return width
    }
    /// A short custom row in focus ends this far above the screen's bottom
    /// (see `FixedFocusCustomRow.contentHeight`).
    static let customBottomGap: CGFloat = 60
    /// A logo row's cards (Details' network & studios): 16:9, five across —
    /// room for wide logos (a poster's width, 140 tall, was a thin strip).
    static let logoCard: CGSize = {
        let width = cardWidth(across: 5)
        return CGSize(width: width, height: (width * 9 / 16).rounded())
    }()
    /// THE LANDSCAPE CARD (Continue Watching, Details' episodes,
    /// collections' tiles, landscape rows): 16:9, three across the
    /// content's width (Apple TV's size; 300 tall, 3.2 across, looked small).
    static let landscapeHeight: CGFloat = (cardWidth(across: 3) * 9 / 16).rounded()
    /// How much a moving-focus card grows when focused.
    static let movingFocusLift: CGFloat = 0.06
    /// The text under cards (captions, the box's description): the base
    /// size (22 looked too small); the second line this far below the first.
    static let captionSize: CGFloat = 24
    static let captionLineOffset: CGFloat = 35
    /// The fixed box while Select is pressed or held: a little smaller.
    /// (A moving-focus card instead loses its lift: back to its own size.)
    static let pressScale: CGFloat = 0.97
    /// …and while its hold menu is open: a little larger than focused.
    static let heldGrowth: CGFloat = 0.03
    /// How long the card takes to grow to that, the dim's hole with it.
    static let heldDuration: Double = 0.28
    /// The fixed box's own size: the portrait posters' height, its left edge
    /// on the row name's (not grown: 4 % larger was tried).
    static let boxScale: CGFloat = 1
    /// Their focus: tvOS's lift (tilt, sheen) — off: Cue's own outline, as
    /// on the other rows.
    static let destinationSystemLift = false
    /// The least of the cards before / after that shows once a row moves.
    static let destinationSliver: CGFloat = 24
    /// A banner row's card: the content's width, this tall (at most).
    static let bannerHeight: CGFloat = 380
    static var bannerWidth: CGFloat { 1920 - 2 * inset }
    /// Under each card: its name and a second line, with room for the lift.
    static let captionRoom: CGFloat = 90
    /// The panel around a collection row: how far it reaches beyond the
    /// row's name and cards (left of the box, above the name, under the
    /// info), and its corners.
    static let panelPad: CGFloat = 36
    static let panelRadius: CGFloat = 32
    /// How far a panel reaches beyond its row's name and cards: above the
    /// name, and below the cards (the info under the box, then its pad).
    static var panelReach: (above: CGFloat, below: CGFloat) { (panelPad, panelPad) }
    /// Under the box: the title's name, then its facts (meta) line.
    static let infoGap: CGFloat = 18
    static let factsOffset: CGFloat = 36
    static let factsHeight: CGFloat = 30
    /// The box (and a grown card) carries its text on the picture, left,
    /// from the foot up: the facts line, the logo over it, the badges over
    /// that (as a showcase card). Nothing under the box.
    static let footPad: CGFloat = 24
    static let factsGap: CGFloat = 10
    static let badgesGap: CGFloat = 14
    static func factsFrame(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: Spotlight.logoInset, y: height - footPad - factsHeight,
               width: width - 2 * Spotlight.logoInset, height: factsHeight)
    }
    static func styleFacts(_ label: UILabel) {
        label.font = FixedFocusText.infoFont(textSize)
        label.textColor = UIColor.white.withAlphaComponent(FixedFocusText.body)
        label.lineBreakMode = .byTruncatingTail
    }
    /// The logo's room, over the facts.
    static func logoRoom(width: CGFloat, height: CGFloat) -> CGRect {
        let room = height * 0.26
        return CGRect(x: Spotlight.logoInset, y: factsFrame(width: width, height: height).minY - factsGap - room,
                      width: width * 0.5, height: room)
    }
    /// The badges' frame (`FixedFocusBadges` lays out from its bottom left):
    /// their foot just over the logo as drawn, else over its room.
    static func badgesFrame(width: CGFloat, over logo: FixedFocusLogo) -> CGRect {
        let top = logo.drawnTop ?? logo.room.minY
        let inset = FixedFocusBadges.inset
        let plate = FixedFocusBadges.plateHeight
        let bottom = top - badgesGap
        // Room for two stacked, should they not fit side by side.
        let height = 2 * plate + FixedFocusBadges.gap
        return CGRect(x: Spotlight.logoInset - inset, y: bottom - height - inset,
                      width: width - 2 * Spotlight.logoInset + 2 * inset, height: height + 2 * inset)
    }
    static func descriptionText(_ item: MetaItem) -> String? {
        item.description?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// ONE size for the text around the box and on the billboard: the
    /// title's name, its facts line and the summary (they differ only in
    /// brightness). Just above the smallest size that reads well on a TV.
    static let textSize: CGFloat = 24
    /// One row below the billboard, none of it shows: Down scrolls one whole
    /// screen.
    static let billboardTopPeek: CGFloat = 0
    /// …and that row stands this much lower than usual, under the strip.
    static var billboardStripDrop: CGFloat { max(0, billboardTopPeek + 10 - rowTop) }
    /// The box, on screen.
    static var boxFrame: CGRect {
        CGRect(x: inset, y: rowTop + titleHeight, width: boxWidth, height: height)
    }
}

final class FixedFocusRowsController: UIViewController, UICollectionViewDataSource,
                                      UICollectionViewDelegateFlowLayout {
    var onSelect: (MetaItem) -> Void = { _ in }
    var onResume: (WatchProgress) -> Void = { _ in }
    /// The focused title (for the background tint) — and, on the billboard,
    /// which of its titles.
    var onFocusItem: (MetaItem, FixedFocusBillboardPosition?) -> Void = { _, _ in }
    var onDepth: (Int) -> Void = { _ in }

    /// The first row below the billboard stands lower while it is in focus
    /// (see `FixedFocusMetrics.billboardStripDrop`).
    var rowDrop: CGFloat {
        if let drop = centredDrop(focusedRow) { return drop }
        guard let featured = rows.firstIndex(where: { $0.id == featuredRowID }),
              focusedRow == featured + 1 else { return centredDrop(focusedRow) ?? 0 }
        if rigidRest != nil { return 0 }
        return FixedFocusMetrics.billboardStripDrop
    }

    private func depth(of rowIndex: Int) -> Int {
        // (No billboard: below the first row.)
        rows.firstIndex(where: { $0.id == featuredRowID }).map { max(rowIndex - $0, 0) } ?? rowIndex
    }
    /// The Featured row: THE BILLBOARD. Its cells are invisible focus
    /// targets (native Left/Right between its titles, Down to the rows);
    /// what you see is drawn full screen by `HomeUIKitView.billboardLayer`.
    var featuredRowID = ""

    func isFeatured(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && rows[rowIndex].id == featuredRowID
    }
    /// Continue Watching: landscape cards (no growing, no fixed box — the
    /// focused card itself sits at the spot), Select resumes.
    var continueRowID = ""
    var progress: [String: WatchProgress] = [:]

    func showProgress() {
        for case let cell as FixedFocusRowCell in outer.visibleCells where isContinue(cell.rowIndex) {
            cell.showProgress()
        }
    }

    func isContinue(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && rows[rowIndex].id == continueRowID
    }
    /// Landscape cards: Continue Watching's look, for other rows too.
    var landscapeRowIDs: Set<String> = []

    func isLandscape(_ rowIndex: Int) -> Bool {
        isContinue(rowIndex) || isPanel(rowIndex)
            || (rows.indices.contains(rowIndex) && landscapeRowIDs.contains(rows[rowIndex].id))
    }
    /// Collection rows: their tiles in a panel.
    var panelRowIDs: Set<String> = []

    func isPanel(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && panelRowIDs.contains(rows[rowIndex].id)
    }
    /// Destination rows: native scrolling, the system's lift, captions.
    /// A change rebuilds the rows
    /// at once — half-switched, a row showed both kinds of cards.
    var destinationRowIDs: Set<String> = [] {
        didSet {
            guard destinationRowIDs != oldValue, isViewLoaded else { return }
            if isDestination(focusedRow) { box.alpha = 0 }
            outer.reloadData()
            outer.collectionViewLayout.invalidateLayout()
            applyDimming()
        }
    }

    /// Ranked rows (Top 10): moving focus, each card's place beside it.
    var rankedRowIDs: Set<String> = []

    func isRanked(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && rankedRowIDs.contains(rows[rowIndex].id)
    }

    /// Showcase rows (New & Notable): tall cards with everything on them,
    /// no caption; the focused card's trailer after a rest (`showcaseTrailer`).
    var showcaseRowIDs: Set<String> = []
    /// Names under moving-focus cards (`FixedFocusRows.captions`).
    var captions = true
    /// The focused row centred (`FixedFocusRows.centred`).
    var centred = false {
        didSet { if centred != oldValue, isViewLoaded { view.setNeedsLayout() } }
    }
    /// Centred: how much lower than `rowTop` row `r` stands in focus, its
    /// cards in the screen's middle (Apple TV's; a collection: its panel)
    /// (nil: not centred, or the billboard).
    func centredDrop(_ r: Int) -> CGFloat? {
        guard centred, rows.indices.contains(r), !isFeatured(r) else { return nil }
        // (A Top 10's grid: with its name, so the rows above and below
        // both keep a peek.)
        let whole = isPanel(r) || isRanked(r)
        let above = whole ? 0 : FixedFocusMetrics.titleHeight + titleExtra(r)
        let content = whole ? drawnHeight(r) : cardHeight(r)
        return ((1080 - content) / 2).rounded() - above - rowTop
    }
    /// Centred, how far the billboard goes up for the row under it: its
    /// edge `peekGap` over that row's name.
    private var centredBillboardTravel: CGFloat? {
        guard let featured = featuredIndex, let drop = centredDrop(featured + 1) else { return nil }
        return 1080 - (rowTop + drop - FixedFocusMetrics.centredGap)
    }
    /// How far a focused row draws, from its anchor (its name; a panel's
    /// top) to the end of its cards (a panel's edge).
    func drawnHeight(_ r: Int) -> CGFloat {
        let named = FixedFocusMetrics.titleHeight + titleExtra(r) + cardHeight(r)
        // A collection: its panel is its edge.
        if isPanel(r) {
            let reach = FixedFocusMetrics.panelReach
            return reach.above + named + reach.below
        }
        return named
    }
    var showcaseTrailers: (on: Bool, sound: Bool) = (false, false) {
        didSet { if !showcaseTrailers.on { showcaseTrailer.rest(on: nil, sound: false) } }
    }
    let showcaseTrailer = StageTrailer()

    func isShowcase(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && showcaseRowIDs.contains(rows[rowIndex].id)
    }

    /// The trailer on the focused showcase card (nil: none) — another card,
    /// or focus anywhere else, lets it go.
    func restShowcase(on cell: FixedFocusShowcaseCell?) {
        guard let cell, showcaseTrailers.on, let item = cell.item else {
            showcaseTrailer.rest(on: nil, sound: false)
            return
        }
        if showcaseTrailer.stage !== cell {
            showcaseTrailer.rest(on: nil, sound: false)
            showcaseTrailer.stage = cell
        }
        showcaseTrailer.rest(on: item, sound: showcaseTrailers.sound, rise: true)
    }

    func isDestination(_ rowIndex: Int) -> Bool {
        isBanner(rowIndex) || (rows.indices.contains(rowIndex) && destinationRowIDs.contains(rows[rowIndex].id))
    }

    /// Banner rows: one wide card, drawn like a small billboard. They move
    /// and focus as destination rows do.
    var bannerRowIDs: Set<String> = []
    var bannerHeight = FixedFocusMetrics.bannerHeight
    var portraitRowIDs: Set<String> = []

    func isBanner(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && bannerRowIDs.contains(rows[rowIndex].id)
    }

    /// A destination row's card (picture only — the caption is below it).
    func destinationCard(_ rowIndex: Int) -> CGSize {
        if isBanner(rowIndex) { return CGSize(width: FixedFocusMetrics.bannerWidth, height: bannerHeight) }
        if isShowcase(rowIndex) { return FixedFocusMetrics.showcaseCard }
        if isLogo(rowIndex) { return FixedFocusMetrics.logoCard }
        // Continue Watching (moving focus): its cards at their own size —
        // the fixed box's.
        if isContinue(rowIndex) {
            return CGSize(width: FixedFocusMetrics.landscapeWidth(height: FixedFocusMetrics.landscapeHeight),
                          height: FixedFocusMetrics.landscapeHeight)
        }
        if isRanked(rowIndex) { return FixedFocusMetrics.rankedCard }
        return isLandscape(rowIndex)
            ? CGSize(width: FixedFocusMetrics.landscapeWidth(height: FixedFocusMetrics.landscapeHeight),
                     height: FixedFocusMetrics.landscapeHeight)
            : rows.indices.contains(rowIndex) && portraitRowIDs.contains(rows[rowIndex].id)
                ? FixedFocusMetrics.portraitCard : FixedFocusMetrics.posterCard
    }
    /// The focused row's name, on screen (the box below it).
    var rowTop: CGFloat = FixedFocusMetrics.rowTop {
        didSet { if rowTop != oldValue, isViewLoaded { view.setNeedsLayout() } }
    }
    /// How much of the rows above and below the focused one shows.
    var aboveVisible: CGFloat = FixedFocusMetrics.aboveVisible
    var belowVisible: CGFloat = FixedFocusMetrics.belowVisible
    /// The focus outline only while focus is in the rows (Search; Home
    /// keeps it while you're up in the top bar).
    var ringOnlyWithFocus = false
    /// The row's cards' height (a Top 10: its grid's).
    func cardHeight(_ rowIndex: Int) -> CGFloat {
        let caption = captions ? FixedFocusMetrics.captionRoom : 0
        if let custom = custom(rowIndex) { return custom.height }
        return isBanner(rowIndex) ? bannerHeight
            : isShowcase(rowIndex) ? FixedFocusMetrics.showcaseCard.height
            : isRanked(rowIndex) ? FixedFocusGridLayout.height(card: FixedFocusMetrics.rankedCard.height,
                                                               count: rows[rowIndex].items.count)
            : isDestination(rowIndex) ? destinationCard(rowIndex).height + caption
            : FixedFocusMetrics.height
    }

    /// The box, on screen, for the focused row's card size (under its name:
    /// lower for a collection, whose panel's top is the row's anchor).
    private var boxFrame: CGRect {
        let height = cardHeight(focusedRow)
        let anchorOffset = isPanel(focusedRow) ? FixedFocusMetrics.panelReach.above : 0
        let width = FixedFocusMetrics.landscapeWidth(height: height)
        return CGRect(x: FixedFocusMetrics.inset, y: rowTop + rowDrop + anchorOffset + FixedFocusMetrics.titleHeight,
                      width: width, height: height)
    }
    private(set) var rows: [HomeRow] = []
    /// Each row's title at the spot.
    private(set) var selected: [String: Int] = [:]
    /// The row focus is in (only it has a grown cell).
    private(set) var focusedRow = 0 {
        didSet {
            belowGuide.isEnabled = isFeatured(focusedRow)
        }
    }
    private var outer: UICollectionView!
    /// Reuse identifiers registered so far (one per catalog).
    private var registeredRows = Set<String>()
    /// THE FIXED BOX: on Left/Right it never moves — only its content
    /// changes; the posters slide in behind it.
    private let box = FixedFocusBoxView()
    private var hasFocus = false
    /// See `FixedFocusRows.externalBillboard`. (Focus is "in" the billboard
    /// from the start: Down from its buttons is the billboard's scroll.)
    var externalBillboard = false {
        didSet { if externalBillboard, !oldValue { hasFocus = true } }
    }
    /// The billboard has the focus outside (its buttons): its cards don't
    /// take focus.
    /// Placeholders (see `FixedFocusRows.placeholder`): no focus in them;
    /// when the content takes over, focus goes in.
    private(set) var isPlaceholder = false

    func setPlaceholder(_ on: Bool) {
        guard isViewLoaded else { isPlaceholder = on; return }
        view.isUserInteractionEnabled = !on
        guard on != isPlaceholder else { return }
        isPlaceholder = on
        guard !on else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window,
                  let system = UIFocusSystem.focusSystem(for: window) else { return }
            system.requestFocusUpdate(to: self)
            system.updateFocusIfNeeded()
        }
    }

    /// The fixed box shows over this row's grown card.
    func boxCovers(_ rowIndex: Int) -> Bool { box.alpha == 1 && rowIndex == focusedRow }
    var billboardFocusOutside: Bool { externalBillboard && isFeatured(focusedRow) && passingUp == nil }
    /// Back's way up (`passUp`): the rows go up to the billboard, focus
    /// held on its hidden cards (never its buttons), then handed on.
    private var passingUp: (() -> Void)?
    var cardStates: [String: FixedFocusCardState] = [:]
    var onSelectInRow: ((MetaItem, String) -> Bool)?

    var startsOverOnChange = false

    /// New rows held back while focus is in a row whose content they
    /// change (`update`), and that row's id: applied once focus leaves it.
    private var heldRows: (rows: [HomeRow], rowID: String)?

    /// The row focus is in now (a hold menu open on one of its cards
    /// counts); nil while Home is covered or focus is elsewhere.
    private var rowHoldingFocus: Int? {
        guard isViewLoaded, view.isUserInteractionEnabled, view.window != nil else { return nil }
        if HoldMenu.shared.isOpen { return focusedRow }
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: outer), let cell = Self.rowCell(containing: focused) else { return nil }
        return cell.rowIndex
    }

    /// Focus moved: held rows go in once it has left their row.
    private func applyHeldRows() {
        guard let held = heldRows else { return }
        if let index = rowHoldingFocus, rows.indices.contains(index), rows[index].id == held.rowID { return }
        heldRows = nil
        update(held.rows)
    }

    /// What a row shows is what Select acts on: the row focus is in keeps
    /// its titles, order and pictures until focus leaves it (else a
    /// reordered Continue Watching showed one title and played another);
    /// every other row takes its new content at once.
    func update(_ incoming: [HomeRow]) {
        var rows = incoming
        heldRows = nil
        if !startsOverOnChange, let index = rowHoldingFocus, !isFeatured(index), self.rows.indices.contains(index) {
            let shown = self.rows[index]
            if let at = rows.firstIndex(where: { $0.id == shown.id }), rows[at].contentKey != shown.contentKey {
                rows[at] = shown
                heldRows = (incoming, shown.id)
            }
        }
        // A row's titles reordered: its selected title kept by id.
        for row in rows {
            guard let was = self.rows.first(where: { $0.id == row.id }), was.contentKey != row.contentKey,
                  let index = selected[row.id], was.items.indices.contains(index),
                  let now = row.items.firstIndex(where: { $0.id == was.items[index].id }), now != index else { continue }
            selected[row.id] = now
        }
        // The titles and their art compared, not just the counts — a new
        // search brings as many results; a setting changes the art — except
        // while focus may be in the rows: a background refresh of Home must
        // not reload them under your focus (count changes only, then).
        let strict = startsOverOnChange || (isViewLoaded && !view.isUserInteractionEnabled)
        let changed = rows.map(\.id) != self.rows.map(\.id)
            || zip(rows, self.rows).contains {
                strict ? $0.contentKey != $1.contentKey : $0.items.count != $1.items.count
            }
        // The billboard's titles (its picks arrive just after Home paints)
        // change in place: only its own row is refreshed.
        let featured = rows.firstIndex { $0.id == featuredRowID }
        let featuredChanged = featured.map { index in
            self.rows.indices.contains(index) && rows[index].contentKey != self.rows[index].contentKey
        } ?? false
        let old = self.rows
        self.rows = rows
        // A row's new name (Details: the season scrolled into): in place.
        if !changed, isViewLoaded {
            for case let cell as FixedFocusRowCell in outer.visibleCells where rows.indices.contains(cell.rowIndex) {
                cell.showTitle(rows[cell.rowIndex].title)
            }
        }
        // Rows focus isn't in (it's held above), changed in place: the same
        // titles with new pictures keep their cards (reconfigured); other
        // changes reload that row alone. (Left for a full reload, which
        // waits while focus is in the rows, the screen fell behind.)
        if !changed, isViewLoaded {
            for case let cell as FixedFocusRowCell in outer.visibleCells
            where cell.rowIndex != featured && rows.indices.contains(cell.rowIndex) && old.indices.contains(cell.rowIndex) {
                let new = rows[cell.rowIndex], was = old[cell.rowIndex]
                guard new.contentKey != was.contentKey else { continue }
                if new.items.map(\.id) == was.items.map(\.id) {
                    cell.refreshArt()
                } else {
                    cell.configure(rowIndex: cell.rowIndex, controller: self)
                }
                if cell.rowIndex == focusedRow, box.alpha > 0 {
                    let index = selected[new.id] ?? 0
                    if new.items.indices.contains(index) {
                        box.show(new.items[index], badges: new.badges(for: new.items[index]), animated: false)
                    }
                }
            }
        }
        if !changed, featuredChanged, let featured, isViewLoaded {
            (outer.cellForItem(at: IndexPath(item: featured, section: 0)) as? FixedFocusRowCell)?
                .configure(rowIndex: featured, controller: self)
            return
        }
        guard changed else { return }
        if startsOverOnChange {
            selected = [:]
            focusedRow = 0
        }
        if focusedRow >= rows.count { focusedRow = max(rows.count - 1, 0) }
        guard isViewLoaded else { return }
        // Rows joining below the ones shown (a folder's later catalogs):
        // inserted — the rows on screen, and focus in them, untouched.
        if !startsOverOnChange, !old.isEmpty, rows.count > old.count,
           zip(rows, old).allSatisfy({ $0.id == $1.id && $0.contentKey == $1.contentKey }),
           outer.numberOfItems(inSection: 0) == old.count {
            UIView.performWithoutAnimation {
                outer.insertItems(at: (old.count..<rows.count).map { IndexPath(item: $0, section: 0) })
            }
            applyDimming()
            return
        }
        outer.reloadData()
        outer.collectionViewLayout.invalidateLayout()
        applyDimming()
        revealNextNameIfNew()
        startOnCollectionIfAsked()
        // The box shows the focused row's title as it is now.
        if box.alpha > 0, rows.indices.contains(focusedRow) {
            let row = rows[focusedRow]
            let index = selected[row.id] ?? 0
            if row.items.indices.contains(index) {
                let item = row.items[index]
                box.show(item, badges: row.badges(for: item), animated: false)
            }
        }
    }

    /// Dev (`-homeFocusCollection`): start on the first collection row —
    /// the simulator can't send arrow keys.
    private var pendingFocusRow: Int?
    private var startedOnCollection = false

    private func startOnCollectionIfAsked() {
        // (`-homeFocusRow N`: start on row N.)
        let args = ProcessInfo.processInfo.arguments
        let asked = args.firstIndex(of: "-homeFocusRow").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        guard !startedOnCollection,
              let index = asked.flatMap({ rows.indices.contains($0) ? $0 : nil })
                ?? (args.contains("-homeFocusCollection") ? rows.indices.first(where: isPanel) : nil)
        else { return }
        startedOnCollection = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            focusedRow = index
            onDepth(depth(of: index))
            applyDimming()
            outer.collectionViewLayout.invalidateLayout()
            outer.layoutIfNeeded()
            place(box, boxFrame)
            pendingFocusRow = index
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// The row focus was on as the rows were hidden (a tab or Details in
    /// front): coming back, focus returns there — not to the first card
    /// on screen.
    var returnRow: Int?

    /// Another tab or Details in front: out of the focus engine (no
    /// interaction), still on screen — the page's own opacity hides it.
    /// (Hidden, the tabs' crossfade lost them: they vanished from the page
    /// going out, and came on a few frames late on the one coming in.)
    func setActive(_ active: Bool) {
        guard view.isUserInteractionEnabled != active else { return }
        if !active { returnRow = focusedRow; restShowcase(on: nil) }
        view.isUserInteractionEnabled = active
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let cell = pendingFocusCell {
            pendingFocusCell = nil
            return [cell]
        }
        // On the billboard, its focus is the overlay's (Details' Play).
        if pendingFocusRow == nil, billboardFocusOutside, let host = controlsHost ?? overlayHost { return [host] }
        if let index = pendingFocusRow {
            pendingFocusRow = nil
            if let rowCell = outer.cellForItem(at: IndexPath(item: index, section: 0)) as? FixedFocusRowCell,
               let cell = rowCell.posterCell(at: selected[rows[index].id] ?? 0) {
                return [cell]
            }
        }
        return super.preferredFocusEnvironments
    }

    override func loadView() {
        Self.all.add(self)
        let root = UIView()
        let layout = FixedFocusRowsLayout()
        layout.focusedRow = { [weak self] in self?.focusedRow ?? 0 }
        layout.rowTop = { [weak self] in (self?.rowTop ?? FixedFocusMetrics.rowTop) + (self?.rowDrop ?? 0) }
        layout.rowDrop = { [weak self] in self?.rowDrop ?? 0 }
        layout.rigidRest = { [weak self] in self?.rigidRest }
        layout.billboardUp = { [weak self] in self?.rigidBillboardTravel == nil ? nil : self?.billboardUp(depth: $0) }
        layout.cardHeight = { [weak self] in self?.cardHeight($0) ?? FixedFocusMetrics.height }
        layout.titleExtra = { [weak self] in self?.titleExtra($0) ?? 0 }
        layout.peeks = { [weak self] in
            (self?.aboveVisible ?? FixedFocusMetrics.aboveVisible, self?.belowVisible ?? FixedFocusMetrics.belowVisible)
        }
        layout.belowCards = { [weak self] in
            // (Not a collection's: its panel is its edge — placed by that.)
            self?.isDestination($0) == true && self?.isBanner($0) == false && self?.isPanel($0) == false
                && self?.isShowcase($0) == false && self?.isRanked($0) == false && self?.captions == true
                ? FixedFocusMetrics.captionRoom : 0
        }
        layout.reach = { [weak self] in
            self?.isPanel($0) == true ? FixedFocusMetrics.panelReach : (0, 0)
        }
        layout.customContent = { [weak self] in
            guard let self, let content = self.custom($0)?.contentHeight else { return nil }
            return FixedFocusMetrics.titleHeight + self.titleExtra($0) + content
        }
        layout.drawnHeight = { [weak self] in
            self?.drawnHeight($0) ?? FixedFocusMetrics.titleHeight + FixedFocusMetrics.height
        }
        layout.centredDrop = { [weak self] in self?.centredDrop($0) }
        layout.featuredRow = { [weak self] in
            guard let self else { return nil }
            return self.rows.firstIndex { $0.id == self.featuredRowID }
        }
        layout.belowAway = { [weak self] in self?.belowAway ?? false }
        outer = UICollectionView(frame: .zero, collectionViewLayout: layout)
        outer.backgroundColor = .clear
        outer.clipsToBounds = false
        // The system never scrolls: only our animation moves the rows.
        outer.isScrollEnabled = false
        outer.showsVerticalScrollIndicator = false
        outer.contentInsetAdjustmentBehavior = .never
        outer.dataSource = self
        outer.delegate = self
        root.addSubview(outer)
        place(box, FixedFocusMetrics.boxFrame)
        box.alpha = 0
        box.isUserInteractionEnabled = false
        root.addSubview(box)
        // Along the bottom edge, below the billboard's (invisible) cells.
        root.addLayoutGuide(belowGuide)
        observeHeldSteps()
        observeBadges()
        NSLayoutConstraint.activate([
            belowGuide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            belowGuide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            belowGuide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            belowGuide.heightAnchor.constraint(equalToConstant: 1),
        ])
        belowGuide.isEnabled = isFeatured(focusedRow)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Taller than the screen: rows sliding out of (or into) the screen
        // stay inside the list's visible area, so UIKit keeps their cells
        // and they SLIDE — outside it, it drops them and fades them in place.
        outer.frame = CGRect(origin: .zero, size: view.bounds.size).insetBy(dx: 0, dy: -FixedFocusRowsLayout.overscan)
        if let stage = pinnedStage {
            stage.bounds = CGRect(origin: .zero, size: StagePictureView.pictureSize)
            stage.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        }
        layoutOverlay()
        if let host = pageHeaderHost {
            host.view.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: pageHeaderHeight)
            host.view.center = CGPoint(x: view.bounds.midX, y: pageHeaderHeight / 2)
            UIView.performWithoutAnimation { applyPageHeaderPosition() }
        }
        place(box, boxFrame)
        if !boxPressed, !boxHeld {
            UIView.performWithoutAnimation { box.applyScale(FixedFocusMetrics.boxScale) }
        }
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        // One reuse identifier PER CATALOG: UIKit only ever hands a row cell
        // back to its own catalog — with its poster row's native focus
        // memory (`remembersLastFocusedIndexPath`) and scroll position
        // intact. (One shared identifier recycled a row's cell, memory and
        // all, for a different catalog: rows "forgot" their title.)
        let reuseID = "row-" + rows[indexPath.item].id
        if registeredRows.insert(reuseID).inserted {
            cv.register(FixedFocusRowCell.self, forCellWithReuseIdentifier: reuseID)
        }
        let cell = cv.dequeueReusableCell(withReuseIdentifier: reuseID, for: indexPath) as! FixedFocusRowCell
        cell.configure(rowIndex: indexPath.item, controller: self)
        // (contentView, not the cell: the collection view resets a cell's
        // own alpha from its layout attributes.)
        cell.contentView.alpha = rowAlpha(indexPath.item)
        cell.concealed = rowConcealed(indexPath.item)
        cell.drop = peekDrop(indexPath.item)
        cell.titleAlpha = titleAlpha(indexPath.item)
        cell.titleLift = peekNameLift(indexPath.item)
        cell.titleScale = 1
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: 1920, height: FixedFocusMetrics.titleHeight + titleExtra(indexPath.item) + cardHeight(indexPath.item))
    }

    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { false }

    /// A row coming into view mid-animation gets its dimming too.
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        cell.contentView.alpha = rowAlpha(indexPath.item)
        (cell as? FixedFocusRowCell)?.concealed = rowConcealed(indexPath.item)
        (cell as? FixedFocusRowCell)?.drop = peekDrop(indexPath.item)
        (cell as? FixedFocusRowCell)?.titleAlpha = titleAlpha(indexPath.item)
    }

    /// Focus moved (natively). Left/Right: the box stays, its content
    /// changes, the row slides behind it. Up/Down ("opening a book"): the
    /// box steps aside, the new row's title grows into the box as the rows
    /// move up; at the end the box takes over again, in the same place.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if heldRows != nil { DispatchQueue.main.async { self.applyHeldRows() } }
        // Back in view after hiding, the system puts focus on the first
        // card on screen (without asking): on to `returnRow`'s instead,
        // nothing moving meanwhile.
        if let returnRow, let next = context.nextFocusedView, next.isDescendant(of: view) {
            if context.previouslyFocusedView?.isDescendant(of: outer) != true,
               let rowCell = Self.rowCell(containing: next), rowCell.rowIndex != returnRow {
                DispatchQueue.main.async { self.requestFocus(row: returnRow) }
                return
            }
            self.returnRow = nil
        }
        // Focus into a hold menu and back: the card is still the focused one
        // (see `HoldMenu`) — nothing changes.
        if HoldMenu.shared.isOpen { return }
        if let next = context.nextFocusedView, !next.isDescendant(of: outer) {
            passingUp = nil
            // Onto the billboard's buttons: the page is at its top, whatever
            // was said before (a stale depth left Home's top bar lifted).
            if billboardFocusOutside, let host = controlsHost, next.isDescendant(of: host.view) {
                onDepth(0)
            }
            // (Into a hold menu: the card keeps its look.)
            if ringOnlyWithFocus, !HoldMenu.shared.isOpen { box.ringHidden = true }
            return
        }
        box.ringHidden = false
        if let button = context.nextFocusedView as? FixedFocusHeaderButton, let rowCell = button.rowCell,
           rows.indices.contains(rowCell.rowIndex) {
            onHeaderFocus(rows[rowCell.rowIndex].id, button.index)
            return
        }
        // Into a custom row's view (or within it): the row comes to the spot.
        if let next = context.nextFocusedView, let rowCell = Self.rowCell(containing: next),
           custom(rowCell.rowIndex) != nil {
            enterRow(rowCell.rowIndex)
            return
        }
        restShowcase(on: (context.nextFocusedView as? FixedFocusShowcaseCell).flatMap { $0.rank == nil ? $0 : nil })
        if let tile = context.nextFocusedView as? FixedFocusDestinationItem, let rowCell = tile.rowCell,
           rows.indices.contains(rowCell.rowIndex) {
            focusDestination(tile.itemIndex, in: rowCell)
            return
        }
        guard let cell = context.nextFocusedView as? FixedFocusPosterCell,
              let rowCell = cell.rowCell, rows.indices.contains(rowCell.rowIndex) else { return }
        let rowIndex = rowCell.rowIndex
        let row = rows[rowIndex]
        // A billboard whose focus is outside (Home's buttons) takes focus on
        // its hidden cards only on the way back up — on whichever is above
        // the row's card: it's the CURRENT title that arrives (the card
        // above switched the billboard to another).
        let itemIndex = isFeatured(rowIndex) && externalBillboard
            ? min(selected[row.id] ?? cell.itemIndex, max(row.items.count - 1, 0)) : cell.itemIndex
        guard row.items.indices.contains(itemIndex) else { return }
        let item = row.items[itemIndex]
        let featured = isFeatured(rowIndex)
        onFocusItem(item, featured ? FixedFocusBillboardPosition(index: itemIndex, count: row.items.count) : nil)
        TitlePreloader.shared.focused(rows: rows, row: rowIndex, index: itemIndex)
        preloadReachable(row: rowIndex, index: itemIndex)
        onDepth(depth(of: rowIndex))
        // Back on the SAME card from outside the rows (a menu closing, down
        // from the top bar, back from a page): nothing moved — no move to
        // play (it replayed the box's slide, and the next press waited on it).
        let fromOutside = context.previouslyFocusedView.map { !$0.isDescendant(of: outer) } ?? true
        if fromOutside, hasFocus, rowIndex == focusedRow, itemIndex == selected[row.id],
           box.alpha == 1 || featured {
            return
        }
        let rowChanged = rowIndex != focusedRow || !hasFocus
        // An opening into a fixed-box row: Left/Right waits for it to land.
        if rowChanged, !featured, !isDestination(rowIndex) { openingRow = rowIndex }
        // Up/Down is the "opening": the box steps aside, the new row's title
        // grows into it, the old one shrinks back to a poster.
        let direction: CGFloat = rowChanged
            ? (rowIndex > focusedRow ? 1 : -1)
            : (itemIndex >= (selected[row.id] ?? 0) ? 1 : -1)
        let oldRowCell = rowChanged
            ? outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell : nil
        if rowChanged, box.alpha == 1 {
            // Opening: the old row's cell first takes on the box's exact
            // look (still the focused row here) — the box can step aside
            // without anything changing — and then shrinks, animated.
            oldRowCell?.contentHidden = false
            // Commit that look NOW: the, animation below continues from what's
            // on screen (beginFromCurrentState), and without this it started
            // from the plain poster — the old box was instantly small.
            CATransaction.flush()
        }
        // Between the billboard and the rows: ONE SCROLL — the picture goes
        // up a whole screen while the rows rise from just below the screen,
        // where they wait under the billboard (no jump first).
        let billboardScroll = rowChanged && hasFocus && (featured != isFeatured(focusedRow))
        if featured {
            // The billboard's picture: the title's, drifting on Left/Right.
            rowCell.showStage(item, direction: direction, animated: !rowChanged)
        }
        if billboardScroll, !featured, rigidRest == nil { sendRowsBelowAway() }
        // Up: the rows sink a whole scroll, with the picture.
        if billboardScroll, featured, rigidRest == nil { belowAway = true }
        selected[row.id] = itemIndex
        focusedRow = rowIndex
        // The row's card size (a change of row hands the box over to the
        // cells first, so it never visibly resizes).
        if rowChanged {
            UIView.performWithoutAnimation { place(box, boxFrame); box.layoutIfNeeded() }
        }

        if featured, let handOn = passingUp {
            // Back's way up: the top bar takes it from here.
            DispatchQueue.main.async(execute: handOn)
        } else if featured, externalBillboard, rowChanged {
            // Up into a billboard whose focus is outside (Details' buttons):
            // its cards stop taking focus now (`billboardCardsOff`), so focus
            // settles again — on the outside's own default (Play; see
            // `preferredFocusEnvironments`).
            // (To these rows, not the window: from there, Home's top bar
            // was the default.)
            focusBillboardOutside()
        }
        // This Left/Right's cut-out (`FixedFocusRowCell.cutOut`), gone once
        // it settles unless a later one took over.
        var cut: Int?
        if featured {
            // The billboard has no box (coming up from a catalog, that row's
            // cell already took over its look above and shrinks back).
            box.alpha = 0
        } else if rowChanged {
            // The opening: the grown cell shows its own content.
            box.alpha = 0
            rowCell.contentHidden = false
        } else if box.alpha < 1 {
            // Left/Right while an opening is still running: the CELLS carry
            // it — the old one shrinks, the next grows, in this step's move,
            // riding the row's rise. (The box taking over at once sat in its
            // final place, full grown, while the row still rose under it: the
            // card seemed to grow at once and slide in diagonally.) The box
            // takes over once every move has settled (see `handOverToBox`).
            rowCell.contentHidden = false
        } else {
            // The box stays; its content changes with the row's move
            // (`FixedFocusBoxView.show`).
            rowCell.contentHidden = true
            oldRowCell?.contentHidden = true
            if !rowChanged {
                cutToken += 1
                cut = cutToken
                cutRow?.cutOut(nil)
                cutRow = rowCell
                rowCell.cutOut(box.convert(box.bounds, to: rowCell),
                               radius: Spotlight.cornerRadius * FixedFocusMetrics.boxScale)
            }
            box.show(item, badges: row.badges(for: item), animated: true, direction: direction, vertical: rowChanged)
        }
        // Up/Down moves much more than a step: its own, longer spring.
        let duration = billboardScroll ? FixedFocusMotion.billboardScroll
            : rowChanged ? Motion.verticalDuration : Motion.moveDuration
        // For the cells' Up/Down details: the image drift's direction and
        // the outlines' own, gradual crossfade (see `setGrown`).
        // Down from the billboard: the rows show at once (the move is the
        // scroll, not a fade); Up hides them as they sink back.
        // (Now: focus is taken right after, and a held move runs later.)
        let hadFocus = hasFocus
        let move = {
            let id = self.beginMove(FixedFocusMove(
                vertical: rowChanged && hadFocus ? (direction: direction, duration: duration) : nil,
                reshaping: (rowChanged && hadFocus) || self.box.alpha < 1 ? duration : nil))
            defer { self.move = nil }
            FixedFocusMotion.run(duration: duration) {
                self.applyDimming()
                oldRowCell?.relayout()
                rowCell.focus(index: itemIndex)
                // The row list doesn't scroll: its layout places every row
                // around the focused one, and the rows glide to their places.
                self.outer.collectionViewLayout.invalidateLayout()
                self.outer.layoutIfNeeded()
                self.applyPageHeaderPosition()
            } completion: { _ in
                if let cut, cut == self.cutToken { self.cutRow?.cutOut(nil); self.cutRow = nil }
                if billboardScroll, featured, self.focusedRow == rowIndex {
                    // Back on the billboard: the rows (off the screen) return to
                    // wait, hidden, at the bottom edge.
                    self.belowAway = false
                    UIView.performWithoutAnimation {
                        self.applyDimming(settled: true)
                        self.outer.collectionViewLayout.invalidateLayout()
                        self.outer.layoutIfNeeded()
                    }
                }
                guard self.endMove(id) else { return }
                if !rowChanged, !self.isMoving { self.runPendingStep() }
                if !self.isMoving { self.landBack() }
                self.runHeldSelect()
                guard !featured, self.focusedRow == rowIndex else { return }
                self.handOverToBox(rowCell, row: row, rowIndex: rowIndex)
            }
            if billboardScroll { self.liftNextTitle(down: !featured) }
        }
        // A Select held for the move before: focus has moved on, it's gone.
        heldSelect = nil
        move()
        hasFocus = true
        loadShowInfo(for: item, in: row, at: itemIndex)
    }

    /// The move being set up (inside `FixedFocusMotion.run`'s animation
    /// block): what the cells laid out in it animate by (`setGrown`).
    private(set) var move: FixedFocusMove?
    /// Moves (Up/Down, Left/Right) still running in the rows; a hurry
    /// (`hurryMoves`) empties it, so their own completions do nothing.
    private var liveMoves: Set<Int> = []
    private var lastMoveID = 0
    private var isMoving: Bool { !liveMoves.isEmpty }
    private func beginMove(_ move: FixedFocusMove) -> Int {
        lastMoveID += 1
        liveMoves.insert(lastMoveID)
        self.move = move
        return lastMoveID
    }
    /// False for a move already counted done (hurried).
    private func endMove(_ id: Int) -> Bool { liveMoves.remove(id) != nil }
    private var cutToken = 0
    private weak var cutRow: FixedFocusRowCell?
    /// A fixed-box row opening (Up/Down into it), until the box has it.
    private var openingRow: Int?
    /// Left/Right presses held during an opening (+ right, − left).
    private var pendingSteps = 0
    /// What focus can reach from here, decoded ahead at the size it shows
    /// at (`PicturePreloader`), so it's there from the first frame:
    /// Left/Right's next titles (the box's picture and logo, or on the
    /// billboard its full-screen picture), and the one title Up/Down lands
    /// on in each of the 3 nearest rows each way (its selected one) — a
    /// first opening otherwise decoded from disk mid-move and flickered.
    /// (Every row: at 4K a full-screen picture is 33 MB, too many evict
    /// the cache.)
    static let reachRows = 3
    private func preloadReachable(row rowIndex: Int, index itemIndex: Int) {
        var wants: [PicturePreloader.Want] = []
        var extras: [MetaItem] = []
        func add(_ item: MetaItem, in index: Int) {
            if !isDestination(index), custom(index) == nil { extras.append(item) }
            if isFeatured(index) {
                wants.append(.init(TMDBService.originalSize(item.background) ?? item.poster, PictureSize.screen))
                wants.append(.init(item.logo, PictureSize.logo))
            } else if !isLandscape(index), !isDestination(index), custom(index) == nil {
                wants.append(.init(item.background ?? item.poster, PictureSize.landscape))
                wants.append(.init(item.logo, PictureSize.cardLogo))
            }
        }
        let items = rows[rowIndex].items
        for offset in [1, -1, 2] where items.indices.contains(itemIndex + offset) {
            add(items[itemIndex + offset], in: rowIndex)
        }
        for distance in 1...Self.reachRows {
            for index in [rowIndex + distance, rowIndex - distance] where rows.indices.contains(index) {
                let row = rows[index]
                let current = selected[row.id] ?? 0
                if row.items.indices.contains(current) { add(row.items[current], in: index) }
            }
        }
        PicturePreloader.shared.want(wants)
        TitleExtras.shared.want(extras)
    }

    private var hurried = false
    /// The opening's rest in this much time, from where it is now.
    static let hurryDuration: Double = 0.10

    /// A held press (its move failed: `shouldUpdateFocus` said no) counts
    /// once — as a step to run after the opening.
    /// The launch's records are in (`TitleRecords.badgesSettled`, under
    /// the curtain): the cards and box drawn before them take their badges.
    private var badgesToken: NSObjectProtocol?
    private func observeBadges() {
        guard badgesToken == nil else { return }
        badgesToken = NotificationCenter.default.addObserver(
            forName: TitleRecords.badgesSettled, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
    }
    private func refreshBadges() {
        guard isViewLoaded else { return }
        for case let cell as FixedFocusRowCell in outer.visibleCells { cell.refreshArt() }
        guard box.alpha > 0, rows.indices.contains(focusedRow) else { return }
        let row = rows[focusedRow]
        let index = selected[row.id] ?? 0
        guard row.items.indices.contains(index) else { return }
        let item = row.items[index]
        box.show(item, badges: row.badges(for: item), animated: false)
    }

    private var heldStepToken: NSObjectProtocol?
    private func observeHeldSteps() {
        guard heldStepToken == nil else { return }
        heldStepToken = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            else { return }
            MainActor.assumeIsolated {
                // (Back's scroll drops its presses.)
                guard let self, !self.backing, let opening = self.openingRow,
                      let from = ctx.previouslyFocusedItem as? FixedFocusPosterCell,
                      from.rowCell?.rowIndex == opening, from.isDescendant(of: self.outer) else { return }
                if ctx.focusHeading.contains(.left) { self.pendingSteps -= 1 }
                if ctx.focusHeading.contains(.right) { self.pendingSteps += 1 }
                self.hurryOpening(opening)
            }
        }
    }

    /// Finish the running opening quickly, from where it is (once per
    /// opening): every animation running in the rows is replaced by a short
    /// one from what's on screen to its end (re-animating to the same target
    /// doesn't retarget a spring), and the opening counts as done at once.
    private func hurryOpening(_ rowIndex: Int) {
        guard !hurried, openingRow == rowIndex,
              let rowCell = outer.cellForItem(at: IndexPath(item: rowIndex, section: 0)) as? FixedFocusRowCell
        else { return }
        hurried = true
        hurryMoves {
            guard self.focusedRow == rowIndex, self.openingRow == rowIndex else { return }
            self.handOverToBox(rowCell, row: self.rows[rowIndex], rowIndex: rowIndex)
        }
    }

    /// Every animation running in the rows replaced by a short one from
    /// what's on screen to its end; the moves count as done at once, `then`
    /// once they've landed.
    private func hurryMoves(then: @escaping () -> Void) {
        let duration = Self.hurryDuration
        let ease = CAMediaTimingFunction(name: .easeOut)
        func hurry(_ layer: CALayer) {
            if let keys = layer.animationKeys(), !keys.isEmpty, let shown = layer.presentation() {
                let now: [(String, Any?)] = [
                    ("position", NSValue(cgPoint: shown.position)),
                    ("bounds", NSValue(cgRect: shown.bounds)),
                    ("transform", NSValue(caTransform3D: shown.transform)),
                    ("opacity", shown.opacity),
                ]
                layer.removeAllAnimations()
                for (key, from) in now {
                    let to = layer.value(forKeyPath: key)
                    guard let from, let to, !(from as AnyObject).isEqual(to) else { continue }
                    let move = CABasicAnimation(keyPath: key)
                    move.fromValue = from
                    move.toValue = to
                    move.duration = duration
                    move.timingFunction = ease
                    layer.add(move, forKey: "hurry.\(key)")
                }
            }
            layer.sublayers?.forEach(hurry)
        }
        // The moves count as done now — first: removing their animations
        // calls their completions.
        liveMoves.removeAll()
        hurry(view.layer)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: then)
    }

    private static let all = NSHashTable<FixedFocusRowsController>.weakObjects()
    /// Rows on screen still moving (a page opening now would take its still
    /// mid-move — Back dissolved into the rows landed: they seemed to scroll).
    static var moving: Bool { all.allObjects.contains { $0.isMoving && $0.view.window != nil } }
    /// Every move on screen finished quickly, as for a held press, then
    /// `run` once the landed rows are drawn.
    static func land(then run: @escaping () -> Void) {
        // Back's scroll isn't hurried: its end is waited for.
        if let rows = all.allObjects.first(where: { $0.backing && $0.view.window != nil }) {
            rows.afterBack.append { land(then: run) }
            return
        }
        for rows in all.allObjects where rows.isMoving && rows.view.window != nil {
            if let opening = rows.openingRow, opening == rows.focusedRow {
                rows.hurryOpening(opening)
            } else {
                rows.hurryMoves {}
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hurryDuration) {
            CATransaction.flush()
            DispatchQueue.main.asyncAfter(deadline: .now() + drawnDelay, execute: run)
        }
    }

    /// Back's scroll up on screen (a press on the billboard's buttons
    /// meanwhile is dropped — `DetailActionButton`).
    static var backScrolling: Bool { all.allObjects.contains { $0.backing && $0.view.window != nil } }

    /// Back's scroll up to the billboard (or the first row) running: it
    /// goes at its own pace (hurried, a long way in 0.1 s looked wrong);
    /// a press in its first part is dropped (held and run after it, it
    /// came late — an action from the past), later it acts as usual.
    private var backing = false
    private var backToken = 0
    /// How long into Back's scroll (0.6 s) presses are dropped: by then
    /// it's ~95 % of the way.
    static let backDropTime: Double = 0.35
    private var afterBack: [() -> Void] = []

    private func landBack() {
        guard backing else { return }
        backing = false
        backToken += 1
        let waiting = afterBack
        afterBack = []
        waiting.forEach { $0() }
    }

    /// One held Left/Right, as a normal step (the box has the row now).
    private func runPendingStep() {
        guard openingRow == nil, !isMoving, pendingSteps != 0,
              rows.indices.contains(focusedRow),
              let rowCell = outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell
        else { return }
        let step = pendingSteps > 0 ? 1 : -1
        pendingSteps -= step
        let target = (selected[rows[focusedRow].id] ?? 0) + step
        guard rows[focusedRow].items.indices.contains(target), let cell = rowCell.posterCell(at: target),
              let system = UIFocusSystem.focusSystem(for: view) else { pendingSteps = 0; return }
        // (Through this controller's preferred focus: a request straight to
        // a card in a strip is ignored.)
        pendingFocusCell = cell
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
    }
    private var pendingFocusCell: UIView?

    /// After an opening, once NOTHING moves any more (a Left/Right during it
    /// keeps the cells carrying it): the box takes over — identical look,
    /// same place, no jump — on the title focused now.
    private func handOverToBox(_ rowCell: FixedFocusRowCell, row: HomeRow, rowIndex: Int) {
        guard !isMoving else { return }
        if box.alpha < 1, let current = selected[row.id], row.items.indices.contains(current) {
            let now = row.items[current]
            // The grown cell's picture and logo, as they are: the box's own
            // copy (the same decode) is often gone from memory by a revisit
            // — back from disk a few frames late, its see-through
            // placeholder flashed the cell's poster, the logo popped in.
            let cell = rowCell.posterCell(at: current) as? FixedFocusPosterCell
            box.show(now, badges: row.badges(for: now), animated: false, pictures: cell?.pictures(for: now))
            box.alpha = 1
            rowCell.contentHidden = true
        }
        openingRow = nil
        hurried = false
        // Held presses: now, one step at a time.
        DispatchQueue.main.async { self.runPendingStep(); self.runHeldSelect(); self.runWaitingPress() }
    }

    /// Focus in a destination row: the system scrolls it and lifts the card;
    /// here only the rest — the background and panel colour, and on arriving
    /// from another row, the rows moving so this one is at the spot (the box
    /// steps aside: it's not used here).
    private func focusDestination(_ index: Int, in rowCell: FixedFocusRowCell) {
        let rowIndex = rowCell.rowIndex
        let row = rows[rowIndex]
        guard row.items.indices.contains(index) else { return }
        let item = row.items[index]
        onFocusItem(item, nil)
        TitlePreloader.shared.focused(rows: rows, row: rowIndex, index: index)
        onDepth(depth(of: rowIndex))
        selected[row.id] = index
        enterRow(rowIndex)
    }

    /// The row a view is in (nil: none).
    private static func rowCell(containing view: UIView) -> FixedFocusRowCell? {
        var current: UIView? = view
        while let v = current {
            if let cell = v as? FixedFocusRowCell { return cell }
            current = v.superview
        }
        return nil
    }

    /// Focus came into a row that moves the rows itself (moving focus, a
    /// custom row): from another row, the rows move so it's at the spot.
    private func enterRow(_ rowIndex: Int) {
        if custom(rowIndex) != nil { onDepth(depth(of: rowIndex)) }
        let rowChanged = rowIndex != focusedRow || !hasFocus
        let fromBillboard = rowChanged && hasFocus && isFeatured(focusedRow)
        let hadFocus = hasFocus
        hasFocus = true
        guard rowChanged else { return }
        let oldRowCell = outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell
        if box.alpha == 1 {
            // The old row's grown cell takes the box's look, then shrinks.
            oldRowCell?.contentHidden = false
            CATransaction.flush()
        }
        box.alpha = 0
        if fromBillboard, rigidRest == nil { sendRowsBelowAway() }
        let direction: CGFloat = rowIndex > focusedRow ? 1 : -1
        focusedRow = rowIndex
        let duration = fromBillboard ? FixedFocusMotion.billboardScroll : Motion.verticalDuration
        let move = {
            // The old row's card closes as into a fixed row (see `setGrown`).
            let id = self.beginMove(FixedFocusMove(
                vertical: hadFocus ? (direction: direction, duration: duration) : nil,
                reshaping: hadFocus ? duration : nil))
            defer { self.move = nil }
            FixedFocusMotion.run(duration: duration) {
                self.applyDimming()
                oldRowCell?.relayout()
                self.outer.collectionViewLayout.invalidateLayout()
                self.outer.layoutIfNeeded()
                self.applyPageHeaderPosition()
            } completion: { _ in
                guard self.endMove(id) else { return }
                if !self.isMoving { self.landBack() }
                self.runHeldSelect()
            }
            if fromBillboard { self.liftNextTitle(down: true) }
        }
        move()
    }

    /// The season count for the title you rest on — then the box's text
    /// takes it. (The ones focus can reach next: `TitleExtras`.)
    private var infoLoading: Task<Void, Never>?

    private func loadShowInfo(for item: MetaItem, in row: HomeRow, at index: Int) {
        infoLoading?.cancel()
        infoLoading = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if await TitleRecords.shared.refresh(item, [.show, .facts, .ratings]), !Task.isCancelled {
                self?.box.refreshInfo(for: item)
            }
        }
    }

    var onSelectFeatured: (MetaItem) -> Void = { _ in }

    var onOpenDetails: ((MetaItem) -> Void)?
    var onContinueMenu: ((ContinueMenuAction, WatchProgress) -> Void)?
    var titleMenu: ((MetaItem, String) -> [MenuEntry])?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HoldMenu.shared.install()
    }

    private func menuEntries(rowIndex: Int, itemIndex: Int) -> (String, [MenuEntry])? {
        guard rows.indices.contains(rowIndex), rows[rowIndex].items.indices.contains(itemIndex) else { return nil }
        let row = rows[rowIndex]
        let item = row.items[itemIndex]
        if isContinue(rowIndex) {
            guard let onContinueMenu, let entry = progress[item.id] else { return nil }
            return (entry.name, ContinueMenuAction.allCases.map { action in
                MenuEntry(title: action.title(series: entry.season != nil), icon: action.icon, destructive: action == .remove) {
                    onContinueMenu(action, entry)
                }
            })
        }
        // Not the billboards (Home's, Search's Top Result) or folders.
        guard let titleMenu, !isFeatured(rowIndex), !isBanner(rowIndex), !isPanel(rowIndex),
              item.type != "collection" else { return nil }
        return (item.name, titleMenu(item, row.id))
    }

    /// What the context menu lifts: a COPY of the fixed box (it covers the
    /// cell), in the box's place. Handed the box itself, the system takes it
    /// off the screen while the menu is up — its info under it too — and
    /// only puts it back once its closing animation has fully run.
    private var boxPressed = false

    /// The box's place, by bounds and centre: a frame set while it is scaled
    /// (pressed) silently enlarged it — it grew after the press.
    private func place(_ view: UIView, _ rect: CGRect) {
        view.bounds = CGRect(origin: .zero, size: rect.size)
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Select pressed or held on a fixed row's card: the box sinks a little
    /// (as Apple TV's cards do), back on release or when the menu closes.
    func setBoxPressed(_ pressed: Bool) {
        // Down mid-move (a quick hold after Up/Down): the move finishes
        // quickly first, as for a held Select, then the settled box sinks
        // (sunk while the grown card still stood in for it, it came in
        // shrunk over that card's edges).
        if pressed, !settled {
            pressWaiting = true
            if let opening = openingRow, opening == focusedRow {
                hurryOpening(opening)
            } else if isMoving {
                hurryMoves { self.runWaitingPress() }
            }
            return
        }
        if !pressed { pressWaiting = false }
        // One state, one move: repeats (began twice, end after cancel) change nothing.
        guard pressed != boxPressed else { return }
        boxPressed = pressed
        applyBoxScale(duration: pressed ? 0.12 : 0.2)
    }

    /// Select went down mid-move and is still down: the box sinks once
    /// the move has landed.
    private var pressWaiting = false
    private func runWaitingPress() {
        guard settled, pressWaiting else { return }
        pressWaiting = false
        setBoxPressed(true)
    }

    /// The box's hold menu open (see `HoldMenuRequest.onHeld`): 102 %.
    private func setBoxHeld(_ held: Bool) {
        guard held != boxHeld else { return }
        boxHeld = held
        applyBoxScale(duration: FixedFocusMetrics.heldDuration)
    }
    private var boxHeld = false

    /// 97 % pressed, 102 % with its menu open, else 100 %. Smaller, the card
    /// under it is out of sight (its edges showed around the box).
    private func applyBoxScale(duration: Double) {
        let base = FixedFocusMetrics.boxScale
        let scale = boxHeld ? base + FixedFocusMetrics.heldGrowth
            : boxPressed ? base - (1 - FixedFocusMetrics.pressScale) : base
        let covered = currentCard(row: focusedRow).first as? FixedFocusPosterCell
        // (Below its own size the card under it — as large — shows. Not
        // while an opening's card still carries the box's look, the box
        // unseen: hidden, the card vanished at the press.)
        if scale < base, box.alpha == 1 { covered?.setUnderPressedBox(true) }
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.box.applyScale(scale)
        } completion: { _ in
            if !self.boxPressed { covered?.setUnderPressedBox(false) }
        }
    }

    /// Gives SwiftUI hosted in a cell the app's stores.
    var environment: (AnyView) -> AnyView = { $0 }

    /// Where a row's first card sits on the screen (window points) while the
    /// row is at the spot.
    func restingCardOrigin(_ rowIndex: Int) -> CGPoint? {
        guard isViewLoaded, view.window != nil else { return nil }
        let anchor = isPanel(rowIndex) ? FixedFocusMetrics.panelReach.above : 0
        return view.convert(CGPoint(x: FixedFocusMetrics.inset,
                                    y: rowTop + (rowIndex == focusedRow ? rowDrop : 0) + anchor
                                        + FixedFocusMetrics.titleHeight), to: nil)
    }

    /// Handing over to Details: Home holds still; a Down waits for Details.
    var upExitRowIDs: Set<String> = []
    var onUpExit: (String) -> Void = { _ in }
    var hiddenTitleRowIDs: Set<String> = [] {
        didSet { if hiddenTitleRowIDs != oldValue, isViewLoaded { applyDimming() } }
    }
    private var lastCommand: UUID?

    /// See `FixedFocusRows.rigidRest` — or, peeking (`rigidPeek`), where
    /// the next row rests so its cards' top is the peek up the bottom edge.
    var rigidRest: CGFloat? {
        get {
            guard let rest = rigidRestSetting else { return nil }
            guard let peek = rigidPeek, let featured = featuredIndex, rows.indices.contains(featured + 1)
            else { return rest }
            return 1080 - peek - FixedFocusMetrics.titleHeight - titleExtra(featured + 1)
        }
        set { rigidRestSetting = newValue }
    }
    private var rigidRestSetting: CGFloat?
    var rigidPeek: CGFloat?
    var rigidPeekShowsName = false
    /// The trailer on the picture: the peek and the dots out the bottom,
    /// back as it goes (the billboard paging: from the press) — as into
    /// Details in place (`movePeek`).
    var peekHidden = false {
        didSet {
            guard peekHidden != oldValue, isViewLoaded else { return }
            peekGuide.isEnabled = peekHidden
            movePeek(animated: true)
        }
    }
    var onPeekBack: () -> Void = {}
    /// Into / out of Details in place (`BillboardOpening`): the peek out
    /// the bottom, the picture leaning in as Details' — the move spring.
    private(set) var openingLook = false
    var followsDetailsArriving = false {
        didSet {
            guard followsDetailsArriving != oldValue else { return }
            BillboardOpening.shared.unfollowDetailsArriving(self)
            guard followsDetailsArriving else { return }
            setOpeningLook(BillboardOpening.shared.detailsArriving, animated: false)
            BillboardOpening.shared.followDetailsArriving(self) { [weak self] on in
                self?.setOpeningLook(on, animated: BillboardOpening.shared.detailsAnimated)
            }
        }
    }
    func setOpeningLook(_ on: Bool, animated: Bool) {
        guard on != openingLook else { return }
        openingLook = on
        guard isViewLoaded else { return }
        movePeek(animated: animated)
        // Home's picture leans in only at once (Back: under Details' still,
        // then out with its parts) — opening, Details' picture leans in as
        // it arrives (`BillboardOpening.leanDetails`), Home's stays still.
        if !on || !animated { pinnedStage?.lean(on, animated: animated) }
    }
    /// The peek out the bottom or back (`peekDrop`), on the move spring.
    private func movePeek(animated: Bool) {
        let apply = {
            for case let cell as FixedFocusRowCell in self.outer.visibleCells {
                cell.drop = self.peekDrop(cell.rowIndex)
            }
            // Home's dots (its overlay) go with the peek, the same distance
            // in the same animation — attached to it.
            if !self.followsDetailsArriving, let dots = self.overlayHost?.view.layer,
               let featured = self.featuredIndex {
                Self.drop(dots, by: self.peekDrop(featured + 1))
            }
        }
        if animated {
            UIView.animate(springDuration: Motion.moveDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
    }
    /// As a row cell's `drop` on the spring: drawn only, in the
    /// surrounding animation's time.
    private static func drop(_ layer: CALayer, by drop: CGFloat) {
        let from = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        layer.sublayerTransform = CATransform3DMakeTranslation(0, drop, 0)
        let duration = UIView.inheritedAnimationDuration
        guard duration > 0 else { layer.removeAnimation(forKey: "drop"); return }
        let move = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        move.duration = move.settlingDuration
        move.keyPath = "sublayerTransform"
        move.fromValue = from
        layer.add(move, forKey: "drop")
    }
    /// Out of the way (a trailer, into Details in place): down past the
    /// screen's bottom.
    func peekDrop(_ rowIndex: Int) -> CGFloat {
        guard peekHidden || openingLook, isNext(rowIndex),
              let frame = outer.layoutAttributesForItem(at: IndexPath(item: rowIndex, section: 0))?.frame
        else { return 0 }
        // Only its cards show (Details): out by what shows, so its whole
        // move is seen.
        if let peek = rigidPeek, !rigidPeekShowsName { return peek + Self.peekDropSlack }
        return max(0, view.bounds.height - outer.convert(frame, to: view).minY) + Self.peekDropSlack
    }
    /// Past the edge by the cards' shadow too.
    static let peekDropSlack: CGFloat = 40
    /// Moved out, the row is off the screen to the focus engine too (it
    /// counts the drawn move): Down lands here, where it rests, and goes in.
    private lazy var peekGuide: FixedFocusRedirectGuide = {
        let guide = FixedFocusRedirectGuide { [weak self] in
            guard let self, let featured = self.featuredIndex else { return [] }
            self.pendingFocusRow = featured + 1
            return [self]
        }
        view.addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            guide.heightAnchor.constraint(equalToConstant: 120),
        ])
        guide.isEnabled = false
        return guide
    }()
    var rigidNameY: CGFloat?
    var hidesBillboardPicture = false
    /// The line under the name (gap, map) — the cards that much lower.
    static let titleAccessoryHeight: CGFloat = 40
    /// Under a header: the accessory's line, with the same gap above it
    /// (to the buttons) as below it (to the cards).
    static let headerAccessoryGap: CGFloat = 28
    static let headerAccessoryHeight: CGFloat = 26

    var rowTitleAccessories: [String: AnyView] = [:] {
        didSet {
            guard isViewLoaded else { return }
            // (A row gaining / losing one changes its height.)
            if Set(rowTitleAccessories.keys) != Set(oldValue.keys) {
                outer.collectionViewLayout.invalidateLayout()
            }
            for case let cell as FixedFocusRowCell in outer.visibleCells { cell.showAccessory() }
        }
    }

    var rowHeaders: [String: FixedFocusRowHeader] = [:] {
        didSet {
            guard rowHeaders != oldValue, isViewLoaded else { return }
            // (A row gaining / losing one changes its height.)
            if Set(rowHeaders.keys) != Set(oldValue.keys) {
                outer.collectionViewLayout.invalidateLayout()
            }
            for case let cell as FixedFocusRowCell in outer.visibleCells { cell.showHeader() }
        }
    }
    var onHeaderFocus: (String, Int) -> Void = { _, _ in }

    /// How much lower than usual a row's cards are under its name: the
    /// header's buttons and their gap take more room than a name; the line
    /// under the name (or the header).
    func titleExtra(_ rowIndex: Int) -> CGFloat {
        guard rows.indices.contains(rowIndex) else { return 0 }
        let id = rows[rowIndex].id
        let accessory = rowTitleAccessories[id] != nil
        guard rowHeaders[id] != nil else { return accessory ? Self.titleAccessoryHeight : 0 }
        let below = accessory ? 2 * Self.headerAccessoryGap + Self.headerAccessoryHeight
            : FixedFocusHeaderButton.gapBelow
        return FixedFocusHeaderButton.height + below - FixedFocusMetrics.titleHeight
    }

    /// The billboard's overlay (see `FixedFocusRows.billboardOverlay`).
    private var overlayHost: UIHostingController<AnyView>?
    /// The billboard's buttons (see `FixedFocusRows.billboardControls`).
    private var controlsHost: UIHostingController<AnyView>?
    /// …in their place, which moves with the billboard (up and down); the
    /// buttons slide sideways inside it — two layers, so the rows' own
    /// updates never restart the slide on another curve (they did: the
    /// buttons drifted from their card).
    private let controlsPlace = UIView()
    var billboardControlsHeight: CGFloat = 1080
    var billboardOverlayHeight: CGFloat = 1080
    var billboardOverlayBelowRows = false
    var billboardOverlayShift: CGFloat = 0
    var rigidBillboardTravel: CGFloat?
    var anchoredRowIDs: Set<String> = []
    var customRows: [String: FixedFocusCustomRow] = [:] {
        didSet {
            guard isViewLoaded else { return }
            for case let cell as FixedFocusRowCell in outer.visibleCells { cell.showCustom() }
            // (A content height measured: where the rows rest may change.)
            if customRows.mapValues(\.contentHeight) != oldValue.mapValues(\.contentHeight) {
                outer.collectionViewLayout.invalidateLayout()
            }
        }
    }

    var logoRowIDs: Set<String> = []
    func isLogo(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && logoRowIDs.contains(rows[rowIndex].id)
    }

    func custom(_ rowIndex: Int) -> FixedFocusCustomRow? {
        rows.indices.contains(rowIndex) ? customRows[rows[rowIndex].id] : nil
    }

    /// How far the billboard is up with focus `depth` rows below it.
    func billboardUp(depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        if let travel = centredBillboardTravel ?? rigidBillboardTravel {
            return travel + CGFloat(depth - 1) * FixedFocusMetrics.rowPitch
        }
        return rigidRest.map {
            FixedFocusRowsLayout.billboardScroll(depth: depth, rigidRest: $0, rowTop: rowTop + rowDrop)
        } ?? FixedFocusRowsLayout.billboardScroll(depth: depth)
    }

    var pinnedBillboardPicture = false {
        didSet {
            guard pinnedBillboardPicture != oldValue else { return }
            if pinnedBillboardPicture { loadViewIfNeeded(); makePinnedStage() } else {
                pinnedStage?.removeFromSuperview()
                pinnedStage = nil
            }
            if isViewLoaded { outer.reloadData() }
        }
    }
    /// The pinned billboard picture (see `FixedFocusRows.pinnedBillboardPicture`).
    private(set) var pinnedStage: StagePictureView?
    /// The billboard's text on each of its pictures (see
    /// `FixedFocusRows.billboardPageText`).
    var billboardPageText: ((MetaItem) -> AnyView)? {
        didSet {
            pinnedStage?.text = billboardPageText.map { text in { [weak self] in self?.environment(text($0)) ?? text($0) } }
            pinnedStage?.refreshText()
        }
    }

    private func makePinnedStage() {
        guard pinnedStage == nil else { return }
        let stage = StagePictureView()
        stage.blursBelow = rigidBillboardTravel == nil
        stage.text = billboardPageText.map { text in { [weak self] in self?.environment(text($0)) ?? text($0) } }
        view.insertSubview(stage, at: 0)
        stage.bounds = CGRect(origin: .zero, size: StagePictureView.pictureSize)
        stage.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        pinnedStage = stage
    }

    /// The pinned picture at a depth: blurred and darker below the
    /// billboard (in the move's animation), and — once the rows are up — out,
    /// to the background's colours; back at once on the way up.
    private func applyPinnedStage(depth: Int) {
        guard let stage = pinnedStage else { return }
        // Home: the picture travels the billboard's own distance (its hard
        // edge ends at the top bar's middle) — under the text, which is
        // under the rows.
        if rigidBillboardTravel != nil {
            stage.transform = CGAffineTransform(translationX: 0, y: -billboardUp(depth: depth))
            return
        }
        stage.setBelow(depth > 0)
        let alpha: CGFloat = depth > 0 ? 0 : 1
        guard stage.alpha != alpha else { return }
        let move = FixedFocusMotion.billboardScroll
        UIView.animate(withDuration: depth > 0 ? move * 0.8 : move * 0.4,
                       delay: depth > 0 ? move * 0.3 : 0,
                       options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
            stage.alpha = alpha
        }
    }

    // MARK: Page header (a folder page)

    /// Above the first row, from the screen's top, this tall: moves with the
    /// first row, in the rows' own animation (a SwiftUI layer outside would
    /// move on the main thread, behind them — or only fade).
    private var pageHeaderHost: UIHostingController<AnyView>?
    private var pageHeaderHeight: CGFloat = 0
    /// The first row's top with it in focus: the header's rest.
    private var pageHeaderRest: CGFloat?

    func setPageHeader(_ content: AnyView?, height: CGFloat) {
        pageHeaderHeight = height
        guard let content else {
            pageHeaderHost?.willMove(toParent: nil)
            pageHeaderHost?.view.removeFromSuperview()
            pageHeaderHost?.removeFromParent()
            pageHeaderHost = nil
            return
        }
        if let pageHeaderHost {
            pageHeaderHost.rootView = environment(content)
            return
        }
        loadViewIfNeeded()
        let host = UIHostingController(rootView: environment(content))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.isUserInteractionEnabled = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        pageHeaderHost = host
        view.setNeedsLayout()
    }

    /// The header as far up as the first row has gone.
    private func applyPageHeaderPosition() {
        guard let host = pageHeaderHost,
              let top = outer.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY else { return }
        if focusedRow == 0 { pageHeaderRest = top }
        guard let rest = pageHeaderRest else { return }
        host.view.transform = CGAffineTransform(translationX: 0, y: top - rest)
    }

    func setBillboardOverlay(_ content: AnyView?) {
        guard content != nil || overlayHost != nil else { return }
        // (In from the first frame: Details takes over from Home's billboard
        // looking exactly like it.)
        loadViewIfNeeded()
        guard let content else {
            overlayHost?.willMove(toParent: nil)
            overlayHost?.view.removeFromSuperview()
            overlayHost?.removeFromParent()
            overlayHost = nil
            return
        }
        if let overlayHost {
            overlayHost.rootView = environment(content)
            return
        }
        let host = UIHostingController(rootView: environment(content))
        host.view.backgroundColor = .clear
        // (Its own safe area off: it's laid out in screen points, as the rows.)
        host.safeAreaRegions = []
        // Details' info block: hidden until it rises in (`DetailTransition`).
        DetailTransition.shared.textHostCreated(host.view)
        addChild(host)
        // Over the rows (their names on the billboard stay under the text) —
        // or under them (see `billboardOverlayBelowRows`).
        if billboardOverlayBelowRows {
            view.insertSubview(host.view, belowSubview: outer)
            host.view.isUserInteractionEnabled = false
        } else {
            view.addSubview(host.view)
        }
        host.didMove(toParent: self)
        overlayHost = host
        layoutOverlay()
        UIView.performWithoutAnimation { applyOverlayPosition() }
    }

    /// The billboard's buttons over the rows — the text under them (Home:
    /// `billboardOverlayBelowRows`) — reaching down to them and their
    /// captions, no further (it would cover the rows from focus). Moved and
    /// dimmed with the overlay.
    func setBillboardControls(_ content: AnyView?) {
        guard content != nil || controlsHost != nil else { return }
        loadViewIfNeeded()
        guard let content else {
            controlsPlace.removeFromSuperview()
            controlsHost?.willMove(toParent: nil)
            controlsHost?.view.removeFromSuperview()
            controlsHost?.removeFromParent()
            controlsHost = nil
            return
        }
        if let controlsHost {
            controlsHost.rootView = environment(content)
            return
        }
        let host = UIHostingController(rootView: environment(content))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        addChild(host)
        if controlsPlace.superview == nil { view.addSubview(controlsPlace) }
        controlsPlace.addSubview(host.view)
        host.didMove(toParent: self)
        controlsHost = host
        layoutOverlay()
        UIView.performWithoutAnimation { applyOverlayPosition() }
    }

    /// From the top of the screen, its height; moved by a transform (see
    /// `applyOverlayPosition`).
    private func layoutOverlay() {
        let height = min(billboardOverlayHeight, view.bounds.height)
        if let host = overlayHost {
            host.view.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
            host.view.center = CGPoint(x: view.bounds.midX, y: height / 2)
        }
        if let host = controlsHost {
            let height = min(billboardControlsHeight, view.bounds.height)
            let bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
            controlsPlace.bounds = bounds
            controlsPlace.center = CGPoint(x: view.bounds.midX, y: height / 2)
            host.view.bounds = bounds
            host.view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// The overlay where the billboard is: scrolled up with it, and above
    /// the rows. Inside a move: on its animation.
    private func applyOverlayPosition() {
        guard let featured = featuredIndex else { return }
        let depth = max(focusedRow - featured, 0)
        applyPinnedStage(depth: depth)
        let scroll = billboardUp(depth: depth)
        for moved in [overlayHost?.view, controlsHost == nil ? nil : controlsPlace].compactMap({ $0 }) {
            let shift = moved === overlayHost?.view && depth > 0 ? billboardOverlayShift : 0
            moved.transform = CGAffineTransform(translationX: 0, y: shift - scroll)
            moved.alpha = 1
        }
    }

    /// The row under a rigid billboard whose name has come in.
    private var revealedNextRowID: String?

    /// A rigid billboard's next row arriving (Details: its episodes land a
    /// beat after the swap): its name on the billboard comes down into place
    /// (`ModeSwap.lift`) on the swap's arriving curve — not a pop.
    private func revealNextNameIfNew() {
        guard rigidRest != nil, isFeatured(focusedRow), let featured = featuredIndex,
              rows.indices.contains(featured + 1), rows[featured + 1].id != revealedNextRowID else { return }
        revealedNextRowID = rows[featured + 1].id
        outer.layoutIfNeeded()
        nextRowCell?.revealTitle()
    }

    func header(_ rowIndex: Int) -> FixedFocusRowHeader? {
        rows.indices.contains(rowIndex) ? rowHeaders[rows[rowIndex].id] : nil
    }

    /// A row's header shows (and takes focus) while its row has focus.
    /// Never from the billboard: Down lands on the cards.
    func headerShown(_ rowIndex: Int) -> Bool {
        header(rowIndex) != nil && rowIndex == focusedRow && hasFocus
    }

    func run(_ command: FixedFocusRowsCommand) {
        guard command.id != lastCommand, isViewLoaded else { return }
        lastCommand = command.id
        switch command.action {
        case let .aim(rowID, index):
            guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }),
                  rows[rowIndex].items.indices.contains(index) else { return }
            selected[rowID] = index
            (outer.cellForItem(at: IndexPath(item: rowIndex, section: 0)) as? FixedFocusRowCell)?.aim(index)
        case let .focusRow(rowID):
            guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }) else { return }
            requestFocusFar(row: rowIndex)
        case .focusBillboard, .passUp:
            // (No billboard — a folder's rows: the first row.)
            let target = featuredIndex ?? 0
            if case .passUp = command.action {
                guard hasFocus, focusedRow != target else { command.then?(); return }
                let handOn = command.then ?? {}
                passingUp = handOn
                // (Focus never got there: handed on anyway.)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.passingUp != nil else { return }
                    self.passingUp = nil
                    handOn()
                }
            }
            if hasFocus, focusedRow != target {
                backToken += 1
                let token = backToken
                backing = true
                // Presses back once it's nearly there (its tail barely
                // moves; dropped through it, the button lit but dead).
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.backDropTime) { [weak self] in
                    guard let self, self.backToken == token else { return }
                    self.landBack()
                }
            }
            requestFocusFar(row: target)
        case let .page(rowID, index):
            // (After the page's update: its callbacks set the page's state.)
            DispatchQueue.main.async { self.page(rowID: rowID, index: index) }
        case let .step(rowID, by):
            DispatchQueue.main.async { self.step(rowID: rowID, by: by) }
        }
    }

    /// While the billboard slides, Left/Right page again from any of its
    /// buttons (no walking along them to Play or Next first).
    private var slidingUntil: CFTimeInterval = 0
    /// …in its first half only: later, a press moves along the buttons
    /// (when that's possible again is easy to tell).
    private static let pagingShare: CFTimeInterval = 0.75
    /// A step from a press during the slide, not yet taken.
    private var slideStepQueued = false
    /// The way the running slide goes (+1 / -1): only a press that way
    /// pages again — the other way moves along the buttons (no reversing).
    private var slideDirection = 0
    /// A press during the slide that paged: focus to the side it went
    /// (+1: the last button, Next; -1: the first, Play).
    var onBillboardStep: (Int) -> Void = { _ in }

    /// The buttons in with the new card: from where it started, in its
    /// spring (inside their place — see `controlsPlace`).
    private func slideControls(from offset: CGFloat) {
        guard let host = controlsHost else { return }
        // (From `offset` itself: a slide still running would have started
        // this one from where the buttons were — the wrong side, a reverse.)
        host.view.layer.removeAnimation(forKey: "transform")
        host.view.mask = nil
        UIView.performWithoutAnimation {
            host.view.transform = CGAffineTransform(translationX: offset, y: 0)
        }
        FixedFocusMotion.run(duration: StagePictureView.slideDuration) {
            host.view.transform = .identity
        } completion: { _ in }
    }

    /// HOLDING Left/Right on the billboard's buttons: tvOS repeats focus
    /// moves along them, and once at the end (Details going left, Next going
    /// right) — nowhere to go — it pages on, steadily, while held.
    var billboardEdge: () -> Int = { 0 }
    private var holdTimer: Timer?
    private static let holdInterval: TimeInterval = 0.15

    private func arrow(_ presses: Set<UIPress>) -> Int? {
        if presses.contains(where: { $0.type == .rightArrow }) { return 1 }
        if presses.contains(where: { $0.type == .leftArrow }) { return -1 }
        return nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let step = arrow(presses), billboardFocusOutside {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.billboardFocusOutside, self.billboardEdge() == step,
                          let featured = self.featuredIndex, self.rows.indices.contains(featured) else { return }
                    let id = self.rows[featured].id
                    self.step(rowID: id, by: step)
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if arrow(presses) != nil { holdTimer?.invalidate(); holdTimer = nil }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if arrow(presses) != nil { holdTimer?.invalidate(); holdTimer = nil }
        super.pressesCancelled(presses, with: event)
    }

    /// A reverse whose leaving card is in front: the buttons (over
    /// everything) show only beside its edge — a mask moving with it, in
    /// the buttons' own coordinates (both in the same spring: so is the
    /// edge there).
    private func coverControls(_ cover: (from: CGFloat, to: CGFloat, showsRight: Bool), startOffset: CGFloat) {
        guard let host = controlsHost else { return }
        let size = host.view.bounds.size
        func shown(_ edge: CGFloat) -> CGRect {
            cover.showsRight ? CGRect(x: edge, y: 0, width: 3 * size.width, height: size.height)
                : CGRect(x: edge - 3 * size.width, y: 0, width: 3 * size.width, height: size.height)
        }
        let mask = UIView(frame: shown(cover.from - startOffset))
        mask.backgroundColor = .black
        host.view.mask = mask
        FixedFocusMotion.run(duration: StagePictureView.slideDuration) {
            mask.frame = shown(cover.to)
        } completion: { _ in
            if host.view.mask === mask { host.view.mask = nil }
        }
    }

    /// The billboard to a title (`page` command).
    /// One title along, as a press (Next, Right, a held arrow).
    private func step(rowID: String, by step: Int) {
        page(rowID: rowID, index: (selected[rowID] ?? 0) + step)
    }

    private func page(rowID: String, index: Int) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }), isFeatured(rowIndex) else { return }
        let row = rows[rowIndex]
        let old = selected[rowID] ?? 0
        guard row.items.indices.contains(index), index != old else { return }
        selected[rowID] = index
        let item = row.items[index]
        let direction: CGFloat = index > old ? 1 : -1
        slideDirection = Int(direction)
        let cell = outer.cellForItem(at: IndexPath(item: rowIndex, section: 0)) as? FixedFocusRowCell
        // Its hidden cards at the title (the way back up lands there).
        cell?.jump(to: index)
        // The buttons go with the cards: a still copy out on the old one,
        // the buttons themselves in on the new one.
        if billboardFocusOutside, let stage = pinnedStage, let host = controlsHost {
            // Drawn at rest, the frost as a flat stand-in (`ActionFace.still`:
            // a blur can't be drawn into an image — it came out black).
            let size = host.view.bounds.size
            let renderer = ImageRenderer(content: host.rootView
                .environment(\.actionFaceStill, true)
                .frame(width: size.width, height: size.height))
            renderer.scale = view.traitCollection.displayScale
            if let image = renderer.uiImage { stage.carry(UIImageView(image: image), from: host.view) }
        }
        cell?.showStage(item, direction: direction, animated: true)
        if billboardFocusOutside {
            let start = pinnedStage?.lastStartOffset ?? direction * StagePictureView.pictureSize.width
            slideControls(from: start)
            if let cover = pinnedStage?.lastCover { coverControls(cover, startOffset: start) }
        }
        slidingUntil = CACurrentMediaTime() + StagePictureView.slideDuration * Self.pagingShare
        // Moved out for the trailer: back in now, with the slide (its stop
        // reaches here through the page a few frames later).
        if peekHidden {
            peekHidden = false
            onPeekBack()
        }
        onFocusItem(item, FixedFocusBillboardPosition(index: index, count: row.items.count))
        TitlePreloader.shared.focused(rows: rows, row: rowIndex, index: index)
    }

    /// Focus to the billboard's buttons (`preferredFocusEnvironments`).
    /// The first time after launch the request finds nothing to focus and
    /// focus stays on the hidden card — unlit, though Select still acted:
    /// asked again a moment later (50 ms), it takes. A few tries at most.
    private func focusBillboardOutside(tries: Int = 4, after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.billboardFocusOutside,
                  let system = UIFocusSystem.focusSystem(for: self.view) else { return }
            system.requestFocusUpdate(to: self)
            system.updateFocusIfNeeded()
            if tries > 1, (system.focusedItem as? UIView)?.isDescendant(of: self.outer) == true {
                self.focusBillboardOutside(tries: tries - 1, after: 0.05)
            }
        }
    }

    /// Focus to one view in the rows, through this controller's preferred
    /// focus (a request straight to it is ignored).
    private func requestFocus(view target: UIView) {
        guard let system = UIFocusSystem.focusSystem(for: view) else { return }
        pendingFocusCell = target
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
    }

    /// Focus to a row's current card in ONE move, however far (Back up to
    /// the billboard or the first row). Next to it: Up's own move. Far off
    /// screen it has no cell to focus: the rows' view reaches up to it
    /// (frame and bounds together — nothing on screen moves) until the move
    /// has landed, the rows in between keeping their cells all the way.
    private func requestFocusFar(row: Int) {
        let path = IndexPath(item: row, section: 0)
        guard outer.cellForItem(at: path) == nil,
              let top = outer.collectionViewLayout.layoutAttributesForItem(at: path)?.frame.minY,
              top < outer.bounds.minY else {
            requestFocus(row: row)
            return
        }
        let frame = outer.frame, bounds = outer.bounds
        let reach = bounds.minY - top
        UIView.performWithoutAnimation {
            outer.frame = CGRect(x: frame.minX, y: frame.minY - reach, width: frame.width, height: frame.height + reach)
            outer.bounds = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.height + reach)
            outer.layoutIfNeeded()
        }
        requestFocus(row: row)
        DispatchQueue.main.asyncAfter(deadline: .now() + FixedFocusMotion.billboardScroll + 0.05) { [weak self] in
            guard let self else { return }
            UIView.performWithoutAnimation {
                self.outer.frame = frame
                self.outer.bounds = bounds
            }
        }
    }

    /// Focus to a row's current card, from wherever focus is now.
    private func requestFocus(row: Int) {
        pendingFocusRow = row
        if let system = UIFocusSystem.focusSystem(for: view) {
            system.requestFocusUpdate(to: self)
            system.updateFocusIfNeeded()
        }
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // BACK'S SCROLL UP: a move meanwhile is dropped — the scroll goes
        // on at its own pace.
        if backing, !context.focusHeading.isEmpty { return false }
        // (The rows, not this view: the billboard's overlay is in it too.)
        let previousInside = context.previouslyFocusedView?.isDescendant(of: outer) == true
        // Left/Right DURING the billboard's slide, the way it goes: the title
        // after that, focus staying on its button. (The other way: along
        // the buttons, as at rest.)
        let heading = context.focusHeading.contains(.right) ? 1 : context.focusHeading.contains(.left) ? -1 : 0
        if CACurrentMediaTime() < slidingUntil, heading != 0, heading == slideDirection,
           let host = controlsHost,
           context.previouslyFocusedView?.isDescendant(of: host.view) == true,
           let featured = featuredIndex, rows.indices.contains(featured) {
            // (One press asks this for every candidate it tries: one step.)
            guard !slideStepQueued else { return false }
            slideStepQueued = true
            let step = heading
            let id = rows[featured].id
            DispatchQueue.main.async {
                self.slideStepQueued = false
                self.step(rowID: id, by: step)
                self.onBillboardStep(step)
            }
            return false
        }
        // Down from the billboard's own focus (Details' buttons) that doesn't
        // reach the rows — the first row's current card isn't under the
        // button (an episode further along) and the search settled back on
        // the button: to that card.
        if context.focusHeading.contains(.down), billboardFocusOutside, !previousInside,
           (context.nextFocusedView?.isDescendant(of: outer) ?? false) == false,
           let featured = featuredIndex, rows.indices.contains(featured + 1) {
            DispatchQueue.main.async { self.requestFocus(row: featured + 1) }
            return false
        }
        // Up from a row with a header: its selected button (the engine kept
        // the move in the row's focus group — another of its cards).
        if context.focusHeading.contains(.up), previousInside,
           let from = context.previouslyFocusedView, !(from is FixedFocusHeaderButton),
           let rowCell = (from as? FixedFocusDestinationItem)?.rowCell ?? (from as? FixedFocusPosterCell)?.rowCell,
           let target = rowCell.headerFocusTarget, context.nextFocusedView !== target {
            DispatchQueue.main.async { self.requestFocus(view: target) }
            return false
        }
        // A header (Details' seasons): along it natively; Up goes to the
        // billboard, Down to the row's card.
        if let button = context.previouslyFocusedView as? FixedFocusHeaderButton,
           let rowCell = button.rowCell, rows.indices.contains(rowCell.rowIndex),
           !(context.nextFocusedView is FixedFocusHeaderButton) {
            if context.focusHeading.contains(.up), let featured = featuredIndex, rowCell.rowIndex == featured + 1 {
                DispatchQueue.main.async { self.requestFocus(row: featured) }
                return false
            }
            if context.focusHeading.contains(.down) {
                let row = rowCell.rowIndex
                DispatchQueue.main.async { self.requestFocus(row: row) }
                return false
            }
        }
        // Up from the first row into a billboard whose focus is outside
        // (its buttons): through its hidden card (the billboard's arrival),
        // then on to the buttons — the engine went past it (Home: to the
        // top bar).
        // Up out of a row with its own way out (Details' episodes → seasons).
        if context.focusHeading.contains(.up), previousInside,
           let from = context.previouslyFocusedView as? FixedFocusDestinationItem, let fromRow = from.rowCell,
           rows.indices.contains(fromRow.rowIndex), upExitRowIDs.contains(rows[fromRow.rowIndex].id),
           (context.nextFocusedView as? FixedFocusDestinationItem)?.rowCell !== fromRow {
            let id = rows[fromRow.rowIndex].id
            DispatchQueue.main.async { self.onUpExit(id) }
            return false
        }
        // LEFT/RIGHT DURING AN OPENING: held — first land, then step. The
        // opening is hurried to its end (`hurryOpening`); the press runs as
        // a normal step after it (`runPendingStep`). The card beside never
        // takes focus mid-move (it grew in both ways while still moving).
        if let opening = openingRow, previousInside,
           context.focusHeading.contains(.left) || context.focusHeading.contains(.right),
           let from = context.previouslyFocusedView as? FixedFocusPosterCell, from.rowCell?.rowIndex == opening {
            // (Counted once per press, when the move fails — see
            // `observeHeldSteps`: tvOS asks this several times per press.)
            DispatchQueue.main.async { self.hurryOpening(opening) }
            return false
        }
        // Into a moving-focus row from outside: its CURRENT card, not the
        // one nearest by position (it may be aimed — Details' episodes).
        if !previousInside, !ModeSwap.shared.handingOver,
           let to = context.nextFocusedView as? FixedFocusDestinationItem, let toRow = to.rowCell,
           rows.indices.contains(toRow.rowIndex),
           let current = selected[rows[toRow.rowIndex].id], current != to.itemIndex {
            let rowIndex = toRow.rowIndex
            DispatchQueue.main.async { self.requestFocus(row: rowIndex) }
            return false
        }
        guard ModeSwap.shared.handingOver else { return super.shouldUpdateFocus(in: context) }
        if context.focusHeading.contains(.down) { ModeSwap.shared.heldPress = .down }
        return false
    }

    /// Nothing moving in the rows, the box holding its row (an opening's
    /// card handed over).
    private var settled: Bool { !isMoving && openingRow != focusedRow }
    /// A Select during a move: held, run as the move lands (opened mid-move,
    /// Details took the screen with the box still empty — the grown card
    /// had its content until the hand-over). The move finishes quickly
    /// first, as for a held Left/Right (`hurryOpening`, `hurryMoves`).
    private var heldSelect: (() -> Void)?
    /// At the latest (a move whose end never came).
    static let heldSelectLimit: Double = 1

    private func runHeldSelect() {
        guard settled, let run = heldSelect else { return }
        heldSelect = nil
        // The landed rows drawn first (the box just took the card over):
        // Details starts from a still of the screen as last drawn.
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drawnDelay, execute: run)
    }
    /// Two frames.
    static let drawnDelay: Double = 2.0 / 60

    private var heldSelectToken = 0

    func select(_ item: MetaItem, rowIndex: Int) {
        // (Back's scroll up running: dropped, as a move.)
        guard !backing else { return }
        // (A showcase card's trailer stops at the press; into Details with
        // it playing is for later.)
        restShowcase(on: nil)
        guard settled || ModeSwap.shared.handingOver else {
            heldSelectToken += 1
            let token = heldSelectToken
            heldSelect = { [weak self] in self?.perform(item, rowIndex: rowIndex) }
            // The move finishing quickly, as for a held Left/Right.
            if let opening = openingRow, opening == focusedRow {
                hurryOpening(opening)
            } else if isMoving {
                hurryMoves { self.runHeldSelect() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.heldSelectLimit) { [weak self] in
                guard let self, self.heldSelectToken == token, let held = self.heldSelect else { return }
                self.heldSelect = nil
                held()
            }
            return
        }
        heldSelect = nil
        perform(item, rowIndex: rowIndex)
    }

    private func perform(_ item: MetaItem, rowIndex: Int) {
        if let onSelectInRow, rows.indices.contains(rowIndex), onSelectInRow(item, rows[rowIndex].id) { return }
        // Handing over to Details: this Select is Play there.
        if ModeSwap.shared.handingOver {
            ModeSwap.shared.heldPress = .play
            return
        }
        if !isFeatured(rowIndex), !isContinue(rowIndex), item.type != "collection", let onOpenDetails {
            onOpenDetails(item)
        } else if isFeatured(rowIndex) {
            onSelectFeatured(item)
        } else if isContinue(rowIndex), let entry = progress[item.id] {
            onResume(entry)
        } else {
            onSelect(item)
        }
    }

    /// The focused row full, every other row dimmed. `settled`: a move to
    /// the billboard has ended (rigid: only now the rows below hide).
    private func applyDimming(settled: Bool = false) {
        applyOverlayPosition()
        for case let cell as FixedFocusRowCell in outer.visibleCells {
            cell.contentView.alpha = rowAlpha(cell.rowIndex)
            cell.applyCaptions()
            // (Rigid: by a line fixed on the screen, moved in the scroll —
            // see `concealTravel`.)
            if let rest = rigidRest {
                let next = featuredIndex.flatMap { centredDrop($0 + 1) } ?? 0
                let travel = FixedFocusRowsLayout.billboardScroll(depth: 1, rigidRest: rest, rowTop: rowTop + next)
                if cell.concealTravel != travel { UIView.performWithoutAnimation { cell.concealTravel = travel } }
            }
            cell.concealed = rowConcealed(cell.rowIndex)
            cell.drop = peekDrop(cell.rowIndex)
            cell.titleAlpha = titleAlpha(cell.rowIndex)
            // (Never animated here: Down/Up give it its own move.)
            UIView.performWithoutAnimation { cell.titleLift = peekNameLift(cell.rowIndex); cell.titleScale = 1 }
            cell.applyAccessory()
            cell.applyHeader()
            cell.applyNameRoom()
        }
    }

    /// Under the billboard the rows wait at the bottom edge, hidden (see
    /// `rowConcealed`), at full brightness: the scroll is a move, not a fade.
    private func rowAlpha(_ rowIndex: Int) -> CGFloat {
        // (A custom row — Details' About, the page's end — is never dimmed.)
        if custom(rowIndex) != nil { return 1 }
        // (The billboard's picture is never dimmed: it scrolls away whole.)
        // (Under the billboard the rows are full: the scroll is a move.)
        if isFeatured(focusedRow) {
            // Rigid: the row peeking under it (`rigidPeek`) gently dimmed;
            // the others waiting there dimmed.
            if rigidPeek != nil, isNext(rowIndex) { return FixedFocusMetrics.peekAlpha }
            return rigidRest != nil && !isFeatured(rowIndex) ? FixedFocusMetrics.dimmedAlpha : 1
        }
        // (Rows out of focus, peeking above and below: gently dimmed.)
        return rowIndex == focusedRow || isFeatured(rowIndex) ? 1 : FixedFocusMetrics.peekAlpha
    }

    /// Waiting under the billboard (at the bottom edge) the rows are hidden:
    /// their names and their cards' contents — the cards stay on the screen,
    /// so tvOS can focus them. (Not through the row's own alpha: the focus
    /// engine skips everything inside a fully transparent view.) Away (off
    /// the screen, scrolling) they show.
    private func rowConcealed(_ rowIndex: Int) -> Bool {
        // (Peeking: the next row's cards show.)
        isFeatured(focusedRow) && !isFeatured(rowIndex) && !belowAway && !(rigidPeek != nil && isNext(rowIndex))
    }

    /// THE NEXT ROW'S NAME ON THE BILLBOARD is that row's own name, lifted
    /// above its (hidden) cards — `titleLift` — up to its spot on the
    /// billboard (bottom left, in line with the dots), dimmed like a row
    /// out of focus. The other waiting rows' names are hidden; that one too
    /// while the billboard steps into Details.
    private func titleAlpha(_ rowIndex: Int) -> CGFloat {
        if rows.indices.contains(rowIndex), hiddenTitleRowIDs.contains(rows[rowIndex].id) { return 0 }
        guard isFeatured(focusedRow) else { return 1 }
        // (Rigid: the row's own brightness dims it. Peeking: no name.)
        if isNext(rowIndex) {
            if rigidPeek != nil {
                return rigidPeekShowsName ? 1 : 0
            }
            return rigidRest != nil ? 1 : FixedFocusMetrics.dimmedAlpha
        }
        return belowAway ? 1 : 0
    }

    /// A header row peeking with its name (Details' "Episodes"): the name
    /// just above its cards — not at the header's place, the season
    /// buttons and their map's room between (one season: the map's).
    private func peekNameLift(_ rowIndex: Int) -> CGFloat {
        guard rigidPeek != nil, rigidPeekShowsName, isFeatured(focusedRow), isNext(rowIndex),
              titleExtra(rowIndex) > 0 else { return 0 }
        return -titleExtra(rowIndex)
    }

    /// A header row's name, going up with the billboard (`liftNextTitle`):
    /// smaller.
    static let nextNameScale: CGFloat = 0.75
    /// Up to the billboard, the share of the row's move over which the
    /// season buttons and their map fade out (Down: the whole move).
    static let headerOutShare: CGFloat = 0.4
    /// A header row's name (Details' "Episodes") stays at least this far
    /// below the billboard's buttons while they're on the screen.
    static let nameButtonsMargin: CGFloat = 32

    private func isNext(_ rowIndex: Int) -> Bool {
        featuredIndex.map { rowIndex == $0 + 1 } ?? false
    }

    private var nextRowCell: FixedFocusRowCell? {
        featuredIndex.flatMap { outer.cellForItem(at: IndexPath(item: $0 + 1, section: 0)) as? FixedFocusRowCell }
    }

    /// Down / Up between the billboard and the rows — right after the rows'
    /// move was set off: a header row's name and header (Details' seasons)
    /// on the row's own move. (Other rows' names come with their row.)
    private func liftNextTitle(down: Bool) {
        guard let cell = nextRowCell else { return }
        let end = cell.convert(CGPoint.zero, to: view).y
        let start = end + (cell.layer.presentation()?.frame.minY ?? cell.frame.minY) - cell.frame.minY
        let distance = end - start
        guard abs(distance) > 1 else { return }
        let rowMove = cell.layer.animationKeys()?
            .compactMap { cell.layer.animation(forKey: $0) as? CABasicAnimation }
            .first { $0.keyPath == "position" }
        let timing = rowMove?.timingFunction ?? CAMediaTimingFunction(name: .easeInEaseOut)
        let duration = rowMove?.duration ?? FixedFocusMotion.billboardScroll
        let spot = rigidRest != nil ? rigidNameY ?? FixedFocusRowsLayout.nextNameY : FixedFocusRowsLayout.nextNameY
        // One season (no buttons), peeking with its name: the name, just
        // above its cards in the peek, steps up over the map's room on
        // Down (Up: back down), on the row's own move.
        if header(cell.rowIndex) == nil {
            guard rigidPeek != nil, rigidPeekShowsName, titleExtra(cell.rowIndex) > 0 else { return }
            let spring = rowMove as? CASpringAnimation
            let progress = spring.map { Self.springProgress($0) }
            let samples = progress?.values ?? (0...40).map { CGFloat($0) / 40 }
            let lift = -titleExtra(cell.rowIndex)
            cell.moveTitle(lift: samples.map { lift * (down ? 1 - $0 : $0) },
                           timing: spring == nil ? timing : nil, duration: progress?.duration ?? duration)
            return
        }
        // Peeking with its name (Details' "Episodes"): the name stays on its
        // cards and fades out as the season buttons fade in (Up: back).
        if rigidPeek != nil, rigidPeekShowsName {
            let spring = rowMove as? CASpringAnimation
            let progress = spring.map { Self.springProgress($0) }
            let samples = progress?.values ?? (0...40).map { CGFloat($0) / 40 }
            let lift = -titleExtra(cell.rowIndex)
            // (Up: the season buttons go over the move's first part only —
            // `headerOutShare` — gone before the name is back.)
            cell.moveHeader(fade: samples.map { down ? $0 : 1 - min($0 / Self.headerOutShare, 1) },
                            lift: samples.map { _ in lift },
                            titleOpacity: samples.map { down ? 1 - min($0, 1) : min($0, 1) },
                            scale: 1,
                            timing: spring == nil ? timing : nil,
                            duration: progress?.duration ?? duration, entering: down)
            return
        }
        // A row with a header (Details' seasons): its name goes up from its
        // spot on the billboard and out past the screen's top (Down) / comes
        // back down from there (Up) — no fade, its brightness kept against
        // the row's own brightening (the row is dimmed on the billboard).
        // It follows the billboard's buttons, never touching them: the gap
        // to them closes only as they leave the screen. The header (with
        // the line under it) comes up with the row, fading in / goes down
        // with it, fading out.
        let away = -FixedFocusMetrics.titleLine - 20
        let travel = billboardUp(depth: 1)
        // The buttons' lower edge (focused, a little grown) at rest.
        let buttons = FixedFocusBillboardText.buttonsY + TitleBlock.buttonHeight + Self.nameButtonsMargin
        let gap = spot - buttons
        // Past the buttons' own end, if that isn't out of the screen yet.
        let extra = max(buttons - travel - away, 0)
        // Along the move's progress p: the name's place on screen, the
        // row's brightness; lift = the row's place minus the name's.
        func name(_ p: CGFloat) -> CGFloat {
            let up = down ? p : 1 - p   // how far the billboard is up
            return buttons - travel * up + gap * (1 - up) * (1 - up) - extra * up * up
        }
        let spring = rowMove as? CASpringAnimation
        let progress = spring.map { Self.springProgress($0) }
        let samples = progress?.values ?? (0...40).map { CGFloat($0) / 40 }
        cell.moveHeader(fade: samples.map { down ? $0 : 1 - $0 },
                        lift: samples.map { start + (end - start) * $0 - name($0) },
                        titleOpacity: samples.map { _ in 0 },
                        scale: Self.nextNameScale,
                        timing: spring == nil ? timing : nil,
                        duration: progress?.duration ?? duration, entering: down)
    }

    /// A spring's progress (0…1, overshoot included) at even steps across
    /// its settling time — as Core Animation runs it (mass, stiffness,
    /// damping, from rest).
    private static func springProgress(_ spring: CASpringAnimation, steps: Int = 90)
        -> (values: [CGFloat], duration: Double, map: ((CGFloat) -> CGFloat) -> [CGFloat]) {
        let duration = spring.settlingDuration
        let m = Double(spring.mass), k = Double(spring.stiffness), c = Double(spring.damping)
        var x = 0.0, v = Double(spring.initialVelocity)
        let substeps = 8, dt = duration / Double(steps * substeps)
        var values: [CGFloat] = [0]
        for _ in 0..<steps {
            for _ in 0..<substeps {
                // Toward 1: semi-implicit Euler.
                v += (-k * (x - 1) - c * v) / m * dt
                x += v * dt
            }
            values.append(CGFloat(x))
        }
        values[values.count - 1] = 1
        return (values, duration, { f in values.map(f) })
    }

    /// Scrolling to or from the rows (see `FixedFocusRowsLayout.belowAway`).
    private var belowAway = false

    /// Down from the billboard: the waiting rows first go — unseen, off the
    /// screen — a whole scroll below their places and show; then they rise
    /// with the picture, the same distance: one page, a constant gap.
    private func sendRowsBelowAway() {
        belowAway = true
        UIView.performWithoutAnimation {
            applyDimming()
            outer.collectionViewLayout.invalidateLayout()
            outer.layoutIfNeeded()
            // The next row's name stays at its spot on the billboard.
            if let cell = nextRowCell {
                cell.titleLift = cell.convert(CGPoint.zero, to: view).y - FixedFocusRowsLayout.nextNameY
            }
        }
        // (Committed now: the move starts from there, not from the edge.)
        CATransaction.flush()
    }

    /// Down from the billboard: the rows wait at the bottom edge, so the
    /// focus engine isn't left to pick a card by position — a guide along
    /// the bottom edge (on only while the billboard has focus) hands Down to
    /// the row's current title. (Up needs none: with the billboard scrolled
    /// away its card list takes focus and hands it to its remembered title.)
    private lazy var belowGuide = FixedFocusRedirectGuide { [weak self] in
        guard let self, let featured = self.featuredIndex else { return [] }
        return self.currentCard(row: featured + 1)
    }

    private var featuredIndex: Int? { rows.firstIndex(where: { $0.id == featuredRowID }) }

    private func currentCard(row: Int) -> [UIFocusEnvironment] {
        guard rows.indices.contains(row),
              let rowCell = outer.cellForItem(at: IndexPath(item: row, section: 0)) as? FixedFocusRowCell
        else { return [] }
        return [rowCell.posterCell(at: selected[rows[row].id] ?? 0) ?? rowCell]
    }

}

/// A row that is a SwiftUI view (see `FixedFocusRows.customRows`): its
/// height (where the cards would be) and the view.
struct FixedFocusCustomRow {
    var height: CGFloat
    var view: AnyView
    /// How tall its content actually is (nil: its height). Focused, the
    /// rows go up only so far that this ends `customBottomGap` above the
    /// screen's bottom — never higher than the usual spot.
    var contentHeight: CGFloat? = nil
}

/// A row's header (see `FixedFocusRows.rowHeaders`): its buttons' names
/// and which one the row is at.
struct FixedFocusRowHeader: Equatable {
    var labels: [String]
    var selected: Int
}

/// A header's button: Details' button look (glass at rest, the bright
/// highlight focused, a touch larger) — moving focus along the header.
/// Select: down into the row.
final class FixedFocusHeaderButton: UIView {
    weak var rowCell: FixedFocusRowCell?
    let label: String
    let index: Int
    static let height: CGFloat = 64
    static let spacing: CGFloat = 16
    /// Between the buttons and the cards.
    static let gapBelow: CGFloat = 36

    var selected = false {
        didSet { if selected != oldValue { render() } }
    }
    private var lit = false
    private var pressed = false
    private let host: UIHostingController<FixedFocusSeasonFace>

    init(label: String, index: Int) {
        self.label = label
        self.index = index
        host = UIHostingController(rootView: FixedFocusSeasonFace(label: label, lit: false, selected: false))
        super.init(frame: .zero)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { rowCell?.headerFocusable(self) == true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: host.sizeThatFits(in: CGSize(width: 600, height: Self.height)).width, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }

    private func render(released: Bool = false) {
        host.rootView = FixedFocusSeasonFace(label: label, lit: lit, selected: selected)
        let scale = lit && !pressed ? DetailActionButton.focusScale : 1
        // The action buttons' timing: a press quick in, back on a spring;
        // focus in quick, out slower.
        let duration = pressed ? DetailActionButton.pressInTime : released ? 0.3 : lit ? 0.15 : 0.35
        if pressed {
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
            return
        }
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    /// When Select went down: a quick tap still shrinks all the way
    /// (`DetailActionButton.pressInTime`) before it grows back.
    private var pressedAt = Date.distantPast

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Along the row the season follows focus: marked at once here (the
        // page's own update came a frame later — the old button showed the
        // season's pill for a moment: a flicker).
        let along = (context.nextFocusedView as? FixedFocusHeaderButton)?.rowCell === rowCell
            && (context.previouslyFocusedView as? FixedFocusHeaderButton)?.rowCell === rowCell
        if context.nextFocusedView === self {
            if along { selected = true }
            lit = true; render()
        } else if context.previouslyFocusedView === self {
            if along { selected = false }
            lit = false; pressed = false; render()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesBegan(presses, with: event) }
        pressed = true
        pressedAt = .now
        render()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else { return super.pressesEnded(presses, with: event) }
        let left = DetailActionButton.pressInTime - Date.now.timeIntervalSince(pressedAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, left)) { [weak self] in
            guard let self, self.pressed else { return }
            self.pressed = false
            self.render(released: true)
            // Select: into the row, on the season's episode.
            self.rowCell?.focusCards()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressed = false
        render()
        super.pressesCancelled(presses, with: event)
    }
}

/// A season button's face (see `FixedFocusHeaderButton`): the action
/// buttons' (`ActionFace`) — the row's season in the text's colour, the
/// others quieter.
struct FixedFocusSeasonFace: View {
    let label: String
    let lit: Bool
    let selected: Bool

    var body: some View {
        Text(label)
            .font(.system(size: DetailActionButton.textSize, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DetailActionButton.textPadding)
            .frame(height: FixedFocusHeaderButton.height)
            // The row's season on the light grey (the current one of a
            // set), the others plain.
            .modifier(ActionFace(lit: lit, rest: selected ? DetailActionButton.restContent : FlatControl.contentMuted,
                                 pill: selected, current: true))
    }
}

/// A card's state line on its picture (`FixedFocusProgressView`): an
/// episode's "S1:E3", its progress, and "20m left" / "Watched" / "Airs Fri".
struct FixedFocusCardState: Equatable {
    var label: String?
    /// In progress: how far (0…1) — the bar.
    var fraction: Double?
    var right: String?
    /// Hide spoilers: the picture blurred (an episode not yet watched).
    var blurred = false
}

/// A row's list of cards. Doesn't take focus itself while `selfFocus` says
/// no (the billboard's, its focus outside — see `externalBillboard`).
final class FixedFocusStripView: UICollectionView {
    var selfFocus: () -> Bool = { true }
    override var canBecomeFocused: Bool { selfFocus() && super.canBecomeFocused }
}

/// A focus guide whose destination is worked out when focus arrives.
/// Something asked of the rows from outside (`FixedFocusRows.command`).
struct FixedFocusRowsCommand: Equatable {
    enum Action: Equatable {
        /// The row's current card becomes `index` and the row moves to show
        /// it (first in view) — no focus change; the next way in lands there.
        case aim(rowID: String, index: Int)
        /// Focus to the row's current card (from outside the rows).
        case focusRow(rowID: String)
        /// Back to the billboard (Details: on to its buttons).
        case focusBillboard
        /// Up to the billboard without focus landing on its buttons; `then`
        /// takes focus on (Home's Back: to the top bar).
        case passUp
        /// The billboard to its title `index` with focus where it is — its
        /// buttons (Home's): the picture drifts, the text crossfades, as a
        /// press on its cards did.
        case page(rowID: String, index: Int)
        /// One title along (+1 / -1), as a press (none past either end).
        case step(rowID: String, by: Int)
    }
    let action: Action
    var then: (() -> Void)? = nil
    let id = UUID()

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

final class FixedFocusRedirectGuide: UIFocusGuide {
    private let targets: () -> [UIFocusEnvironment]
    init(targets: @escaping () -> [UIFocusEnvironment]) {
        self.targets = targets
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var preferredFocusEnvironments: [UIFocusEnvironment]! {
        get { targets() }
        set {}
    }
}

/// The fixed box: backdrop, shade, logo, focus outline. Content changes
/// crossfade; the box itself never moves.
final class FixedFocusBoxView: UIView {
    /// One "page" of the box: backdrop, shade, logo. A change either slides
    /// a new page in (the old one out) or crossfades on the current page.
    private final class Page: UIView {
        let backdrop = UIImageView()
        let shade = FixedFocusShade()
        let logo = FixedFocusLogo()
        /// The facts line under the logo; drifts with it.
        let facts = UILabel()
        /// The backdrop on its way: the placeholder's look, nothing over it.
        let loadingCard = FixedFocusPlaceholder()
        /// It waits (true) or is in: the box's edge waits with it.
        var onWaiting: (Bool) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backdrop.contentMode = .scaleAspectFill
            backdrop.clipsToBounds = true
            backdrop.layer.contentsRect = FixedFocusBoxView.zoomRect
            addSubview(backdrop)
            addSubview(shade)
            loadingCard.isHidden = true
            loadingCard.layer.cornerRadius = 0
            addSubview(loadingCard)
            addSubview(logo)
            FixedFocusMetrics.styleFacts(facts)
            addSubview(facts)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            backdrop.frame = bounds
            loadingCard.frame = bounds
            shade.frame = bounds
            logo.room = FixedFocusMetrics.logoRoom(width: bounds.width, height: bounds.height)
            let factsFrame = FixedFocusMetrics.factsFrame(width: bounds.width, height: bounds.height)
            facts.bounds = CGRect(origin: .zero, size: factsFrame.size)
            facts.center = CGPoint(x: factsFrame.midX, y: factsFrame.midY)
        }

        func showFacts(_ item: MetaItem) {
            facts.text = FixedFocusPlaceholder.isPlaceholder(item) || item.type == "collection"
                ? nil : FixedFocusShowInfo.factsLine(item)
        }

        /// `pictures`: the picture and logo a grown cell shows for it (same
        /// files, same size) — taken as they are, nothing to wait for.
        func show(_ item: MetaItem, pictures: FixedFocusPosterCell.Pictures? = nil) {
            showFacts(item)
            // A folder's cover is its own picture, name and all: no shade.
            shade.isHidden = item.type == "collection"
            // (A banner row's box is wider than a landscape card: the
            // screen's size.)
            let large = bounds.width > FixedFocusMetrics.boxWidth * FixedFocusMetrics.boxScale
            let width = large ? PictureSize.screen : PictureSize.landscape
            let shaded = item.type != "collection"
            self.shaded = shaded
            let backdropURL = item.background ?? item.poster
            let pictureIn: (Bool) -> Void = { [weak self] waiting in
                guard let self else { return }
                self.waiting = waiting
                if self.overPicture {
                    // Over the old picture: the page itself waits, unseen,
                    // and comes in once its picture's there.
                    if waiting {
                        self.isHidden = true
                    } else if self.isHidden {
                        self.isHidden = false
                        if self.layer.animation(forKey: "opacity") == nil {
                            self.alpha = 0
                            UIView.animate(withDuration: Motion.fadeDuration) { self.alpha = 1 }
                        }
                    }
                } else {
                    self.showWaiting(waiting)
                }
                self.onWaiting(waiting)
            }
            if let picture = pictures?.backdrop {
                FixedFocusImages.adopt(picture, url: backdropURL, into: backdrop)
                pictureIn(false)
            } else {
                FixedFocusImages.load(backdropURL, into: backdrop, maxDimension: width, waiting: pictureIn)
            }
            if let logoPicture = pictures?.logo {
                FixedFocusImages.adopt(logoPicture, url: item.logo, into: logo)
            } else {
                FixedFocusImages.load(item.logo, into: logo, maxDimension: large ? PictureSize.logo : PictureSize.cardLogo)
            }
        }

        private var shaded = true
        /// Its picture isn't there yet.
        private(set) var waiting = false
        /// Coming in over the old picture (the box's change): a wait shows
        /// nothing — the placeholder's fill, then the shade coming back,
        /// flashed bright then dim over the old picture.
        var overPicture = false {
            didSet {
                guard oldValue, !overPicture, waiting else { return }
                // Still waiting once the old one goes: the placeholder.
                isHidden = false
                showWaiting(true)
            }
        }

        private func showWaiting(_ waiting: Bool) {
            loadingCard.follow(waiting: waiting)
            shade.isHidden = waiting || !shaded
            logo.isHidden = waiting
            facts.isHidden = waiting
        }
    }

    /// Clips the pages to the box's rounded shape (the box itself doesn't
    /// clip: the focus shadow).
    private let clip = UIView()
    private var page = Page()
    /// The title's badges: the box's, not a page's — they don't drift or
    /// fade, they change at the press.
    private let badges = FixedFocusBadges()
    /// The new badges wait this long after a move's press.
    private static let badgesDelay: TimeInterval = 0.1
    private var badgesHeld = false
    private var shownID: String?
    /// The cards' rim (see `FixedFocusCardEdge`), and the focus outline in
    /// the top bar's light.
    private let edge = UIImageView()
    private let focusRing = UIImageView()

    /// The season count arrived for the title shown: its text takes it,
    /// with a short fade.
    func refreshInfo(for item: MetaItem) {
        guard shownID == item.id else { return }
        let page = page
        UIView.transition(with: page.facts, duration: Motion.fadeDuration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: { page.showFacts(item) })
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        FixedFocusRing.follow(self)
        clipsToBounds = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = Spotlight.cornerRadius
        clip.layer.cornerCurve = .continuous
        addSubview(clip)
        clip.addSubview(page)
        follow(page)
        addSubview(badges)
        edge.isUserInteractionEnabled = false
        addSubview(edge)
        focusRing.isUserInteractionEnabled = false
        addSubview(focusRing)
        FixedFocusRing.attachShadow(to: focusRing)
        // (A layer's border is drawn above its sublayers: above the pages.)
        layer.cornerRadius = Spotlight.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.cgColor
        applyOutlineStyle()
    }

    /// The focus outline: the top bar's light or a white line.
    /// Focus is elsewhere (Search: on the keyboard or the top result): the
    /// box keeps showing its title, without the focus outline.
    var ringHidden = false {
        didSet { if ringHidden != oldValue { applyOutlineStyle() } }
    }
    private func applyOutlineStyle() {
        // The focus outline: the top bar's light, clearer, or a plain
        // white line.
        let lit = FixedFocusCardEdge.focusLight
        let hidden = ringHidden
        focusRing.image = lit && !hidden ? FixedFocusCardEdge.focusImage : nil
        focusRing.isHidden = hidden
        layer.borderWidth = lit || hidden ? 0 : FixedFocusRing.width
        layer.borderColor = FixedFocusRing.color.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyOutlineStyle()
        clip.frame = bounds
        placeBadges()
        // The cards' rim.
        edge.image = FixedFocusCardEdge.rim
        edge.frame = bounds
        focusRing.frame = bounds
        if page.layer.animationKeys()?.isEmpty ?? true { page.frame = bounds }
    }

    /// The badges over the current page's logo (they wait for it).
    private func placeBadges() {
        page.layoutIfNeeded()
        badges.frame = FixedFocusMetrics.badgesFrame(width: bounds.width, over: page.logo)
    }

    /// The box at `scale` (lifted, pressed, held).
    func applyScale(_ scale: CGFloat) {
        transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// The current page's backdrop on its way: no edge (the placeholder's
    /// look).
    private func follow(_ page: Page) {
        page.onWaiting = { [weak self, weak page] waiting in
            guard let self, page === self.page else { return }
            self.syncEdge()
        }
        page.logo.onPlace = { [weak self, weak page] in
            guard let self, page === self.page else { return }
            self.placeBadges()
        }
    }
    /// The edge waits with the current page's picture — except while it
    /// comes in over the old picture (a picture under it — hidden for the
    /// first frames, it flickered in). Set from the state, not from the
    /// callbacks alone: a page that got its picture before it was the
    /// current one (a quick second move) left the edge off for good.
    private func syncEdge() {
        edge.isHidden = page.waiting && covered == nil
        badges.alpha = edge.isHidden || badgesHeld ? 0 : 1
    }
    /// The old page under the one coming in, until its move ends.
    private var covered: Page?
    /// Counts the box's moves: a move's end only clears what a later move
    /// hasn't taken over.
    private var moveID = 0

    /// The box's picture a little larger than the box (as the grown cell's
    /// landscape, so they match): room for the drift (`show`).
    static let driftZoom: CGFloat = 1.04
    /// That zoom as the part of the picture shown.
    static let zoomRect: CGRect = {
        let margin = (1 - 1 / driftZoom) / 2
        return CGRect(x: margin, y: margin, width: 1 - 2 * margin, height: 1 - 2 * margin)
    }()
    /// `direction`: +1 moving right (new content comes from the right),
    /// −1 moving left; `vertical`: an Up/Down move (its longer spring).
    /// `pictures` (not animated): a grown cell's, for the hand-over.
    func show(_ item: MetaItem, badges: [CardBadge], animated: Bool,
              direction: CGFloat = 1, vertical: Bool = false,
              pictures: FixedFocusPosterCell.Pictures? = nil) {
        self.badges.show(badges)
        guard item.id != shownID else { syncEdge(); return }
        shownID = item.id
        applyOutlineStyle()
        guard animated else {
            badgesHeld = false
            page.show(item, pictures: pictures)
            placeBadges()
            syncEdge()
            return
        }
        // One movement with the row, on its spring:
        // - the picture, logo and facts drift a share of that, on the same curve —
        //   old and new alike, the old one out, the new one in — inside the
        //   room the picture's zoom leaves (`driftZoom`), so the box stays
        //   covered. The new one fades in with the captions over the old,
        //   which stays opaque until covered: the box is never see-through
        //   (both fading at once, the posters passing under it showed
        //   through).
        // (Tried: the page itself shifted 30 pt — the old picture showed in
        // a strip at the edge; everything in place — no movement.)
        let move = vertical ? Motion.verticalDuration : Motion.moveDuration
        let margin = Self.zoomRect.minX
        let shift = CGPoint(x: vertical ? 0 : direction, y: vertical ? direction : 0)
        let drift = CGPoint(x: shift.x * bounds.width * (Self.driftZoom - 1) / 2,
                            y: shift.y * bounds.height * (Self.driftZoom - 1) / 2)
        let incoming = Page(frame: bounds)
        follow(incoming)
        incoming.overPicture = true
        incoming.show(item)
        incoming.alpha = 0
        clip.addSubview(incoming)
        // The page in front still waiting, unseen, over the picture the
        // last move left: that picture is the one on screen, so it goes out
        // now (with the waiting page dropped, the old one removed at the
        // last move's end left the box see-through — a flicker).
        var outgoing = page
        let reused = outgoing.isHidden && covered != nil
        if reused, let under = covered {
            outgoing.removeFromSuperview()
            outgoing = under
        }
        page = incoming
        placeBadges()
        covered = outgoing
        moveID += 1
        let id = moveID
        syncEdge()
        // Core Animation: a layer's contents don't move in a UIView animation.
        func slide(_ page: Page, from: CGPoint, to: CGPoint) {
            let spring = CASpringAnimation(perceptualDuration: move, bounce: 0)
            spring.keyPath = "contentsRect"
            spring.fromValue = NSValue(cgRect: Self.zoomRect.offsetBy(dx: from.x * margin, dy: from.y * margin))
            spring.toValue = NSValue(cgRect: Self.zoomRect.offsetBy(dx: to.x * margin, dy: to.y * margin))
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            page.backdrop.layer.add(spring, forKey: "drift")
        }
        let still = CGPoint.zero
        slide(incoming, from: CGPoint(x: -shift.x, y: -shift.y), to: still)
        if !reused { slide(outgoing, from: still, to: shift) }
        // The logo rides the picture's drift. The badges, the box's, go at
        // the press and the new ones appear 0.1 s later, no fade (riding
        // the drift, they read as on a pane over the picture; at once was
        // too fast, 30 % and 75 % of the drift, and fades, were tried).
        incoming.logo.transform = CGAffineTransform(translationX: drift.x, y: drift.y)
        incoming.facts.transform = incoming.logo.transform
        // (Held by the view's own alpha: under an opacity animation, the
        // new words weren't always drawn — a plate with nothing on it.)
        badgesHeld = true
        syncEdge()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.badgesDelay) { [weak self] in
            guard let self, id == self.moveID else { return }
            self.badgesHeld = false
            self.syncEdge()
        }
        FixedFocusMotion.run(duration: move) {
            incoming.logo.transform = .identity
            incoming.facts.transform = .identity
            outgoing.logo.transform = CGAffineTransform(translationX: -drift.x, y: -drift.y)
            outgoing.facts.transform = outgoing.logo.transform
        } completion: { _ in }
        let start = FixedFocusPosterCell.fadeInStart(duration: move)
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction,
                                                .overrideInheritedDuration, .overrideInheritedCurve]
        UIView.animate(withDuration: move - start, delay: start, options: options.union(.curveEaseOut)) {
            incoming.alpha = 1
        } completion: { _ in
            // The old picture handed on to a later move: that move's.
            if outgoing === self.covered, id != self.moveID { return }
            if self.covered === outgoing { self.covered = nil }
            // Its move done: from now on it waits as any page (a change
            // without a move shows on it).
            if incoming === self.page, !incoming.waiting { incoming.overPicture = false }
            self.syncEdge()
            if outgoing !== self.page {
                // The new picture still on its way: the old one goes now,
                // the edge with it; the placeholder shows.
                if incoming === self.page, incoming.waiting {
                    incoming.overPicture = false
                    UIView.animate(withDuration: Motion.fadeDuration) { outgoing.alpha = 0 } completion: { _ in
                        outgoing.removeFromSuperview()
                    }
                } else {
                    outgoing.removeFromSuperview()
                }
            }
        }
    }
}

/// Image loading for the UIKit cells: memory cache, then disk, then network
/// (decoded off the main thread); stale results are dropped.
@MainActor
/// Loading's breathing: every placeholder (`FixedFocusPlaceholder`, its
/// bars) between full and `low` opacity, slowly, all in step — the page
/// breathes as one. Still under Reduce Motion.
class FixedFocusPulsing: UIView {
    private static let half: CFTimeInterval = 1.2
    private static let low: Float = 0.55
    /// The layer that breathes (a sublayer: the view's own alpha stays free
    /// to fade).
    var pulseLayer: CALayer { layer }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let layer = pulseLayer
        layer.removeAnimation(forKey: "pulse")
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = Self.low
        pulse.duration = Self.half
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // In step with every other: from the last whole cycle on the clock.
        let now = CACurrentMediaTime()
        pulse.beginTime = layer.convertTime(now - fmod(now, 2 * Self.half), from: nil)
        pulse.fillMode = .backwards
        layer.add(pulse, forKey: "pulse")
    }
}

/// A card whose content is still loading (`FixedFocusRows.placeholderRows`,
/// `FolderPosterGrid.placeholderItems`) — or whose picture is (`follow`):
/// only a soft fill over the page, lighter at the top, at the card's
/// corners, as the Apple TV app's — no edge (that belongs to a picture),
/// nothing in it, no text to come. It breathes (`FixedFocusPulsing`).
final class FixedFocusPlaceholder: FixedFocusPulsing {
    private let fill = CAGradientLayer()
    override var pulseLayer: CALayer { fill }

    /// Over a picture on its way (`FixedFocusImages.load`'s `waiting`):
    /// shown while it waits; once it's in, it fades away over it.
    func follow(waiting: Bool) {
        if waiting {
            layer.removeAllAnimations()
            alpha = 1
            isHidden = false
        } else if !isHidden, window != nil, !unseen {
            UIView.animate(withDuration: Motion.fadeDuration, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.alpha = 0
            } completion: { finished in
                guard finished, self.alpha == 0 else { return }
                self.isHidden = true
                self.alpha = 1
            }
        } else {
            isHidden = true
        }
    }

    /// Nothing of it on screen (a card or the box transparent or hidden):
    /// it goes at once. (Fading off a box that came in meanwhile, the
    /// picture showed lighter for a moment.)
    private var unseen: Bool {
        var view: UIView? = self
        while let v = view {
            if v.isHidden || v.alpha == 0 { return true }
            view = v.superview
        }
        return false
    }

    /// While it shows: the picture's not there yet (its edge waits too).
    var isWaiting: Bool { !isHidden && alpha > 0 }

    static func isPlaceholder(_ item: MetaItem?) -> Bool { item?.id.hasPrefix("placeholder-") == true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerRadius = Spotlight.cornerRadius
        layer.cornerCurve = .continuous
        // Over the page itself (no dark base: it hid the card on the page).
        fill.colors = [UIColor(white: 1, alpha: 0.09).cgColor, UIColor(white: 1, alpha: 0.07).cgColor]
        layer.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }
}

/// Pictures decoded ahead into memory, each at the size it will show at
/// (`PictureSize`): what focus can reach (`preloadReachable`) and the
/// title preloader's (`TitlePreloader`). One place, one decode per picture.
@MainActor
final class PicturePreloader {
    static let shared = PicturePreloader()

    struct Want {
        let url: String?
        let size: CGFloat
        init(_ url: String?, _ size: CGFloat) { self.url = url; self.size = size }
    }

    private var loading = Set<String>()
    /// The latest `want`'s pictures: one still waiting for its turn
    /// (`DecodeGate`) when focus has moved on is dropped, not decoded.
    private var wanted = Set<String>()

    /// Decodes what isn't in memory, through the queue's focus band
    /// (`LoadQueue`), in order; returns at once. Replaces the last call's
    /// wishes.
    func want(_ wants: [Want]) {
        wanted = Set(wants.compactMap { want in
            want.url.map { RemoteImage.memoryKey($0, maxDimension: want.size, maxPixels: nil) }
        })
        var jobs: [LoadQueue.Job] = []
        for want in wants {
            guard let url = want.url else { continue }
            let key = RemoteImage.memoryKey(url, maxDimension: want.size, maxPixels: nil)
            guard ImageCache.shared.image(for: key) == nil else { continue }
            jobs.append(.picture(url, want.size, band: .focus, order: jobs.count, source: "reach",
                                 still: { [weak self] in self?.wanted.contains(key) ?? false }))
        }
        LoadQueue.shared.replace(source: "reach", with: jobs)
    }

    /// Decodes it unless it's in memory; returns once it is (or failed).
    func load(_ want: Want) async {
        guard let url = want.url else { return }
        let key = RemoteImage.memoryKey(url, maxDimension: want.size, maxPixels: nil)
        guard ImageCache.shared.image(for: key) == nil, loading.insert(key).inserted else { return }
        await ImageCache.shared.preload(url, maxDimension: want.size, turn: .ahead)
        loading.remove(key)
    }
}

/// The records (`TitleRecords`) of what focus can reach
/// (`preloadReachable`'s titles) brought up to date, in the queue's focus band behind the
/// pictures (`LoadQueue`). After a 0.3 s rest, so a held Left/Right
/// doesn't ask for every title it passes (MDBList counts requests); a
/// record is asked again once a day at most.
@MainActor
final class TitleExtras {
    static let shared = TitleExtras()
    private var task: Task<Void, Never>?

    func want(_ titles: [MetaItem]) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            LoadQueue.shared.replace(source: "extras", with: titles.enumerated().map { index, item in
                .record(item, band: .focus, order: 100 + index, source: "extras")
            })
        }
    }
}

enum FixedFocusImages {
    private static var requested: [ObjectIdentifier: String] = [:]

    /// Decodes pictures into memory ahead — a page's first screen, so it
    /// swaps in whole: a card asking for one has it at once. Returns once
    /// they're in, or after `limit` (the rest go on loading).
    @MainActor
    static func prefetch(_ pictures: [(url: String?, maxDimension: CGFloat)], within limit: Duration) async {
        let wanted = pictures.compactMap { picture in picture.url.map { ($0, picture.maxDimension) } }
        guard !wanted.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: limit) }
            group.addTask { @MainActor in
                await withTaskGroup(of: Void.self) { all in
                    for (url, size) in wanted { all.addTask { @MainActor in await warm(url, maxDimension: size) } }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    @MainActor
    private static func warm(_ url: String, maxDimension: CGFloat) async {
        let memoryKey = RemoteImage.memoryKey(url, maxDimension: maxDimension, maxPixels: nil)
        if ImageCache.shared.image(for: memoryKey) != nil { return }
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil)
        if await ImageCache.shared.diskImage(for: url, budget: budget, memoryKey: memoryKey) != nil { return }
        guard let remote = URL(string: url), let data = try? await ImageCache.shared.download(remote) else { return }
        if let image = await DecodeGate.shared.run(.now, { ImageCache.decodeDownsampled(data, budget: budget) }) {
            ImageCache.shared.insert(image, for: url, data: data, memoryKey: memoryKey)
        } else {
            ImageCache.shared.insertData(data, for: url)
        }
    }

    /// A logo without its empty edges (`LogoFit.trimmed`, as the billboard's).
    @MainActor
    private static func trimmedIfLogo(_ image: UIImage, in view: UIImageView, key: String) -> UIImage {
        view is FixedFocusLogo ? LogoFit.trimmed(image, key: key) : image
    }

    /// A picture another view already shows for `url` at this size: in at
    /// once, any load still running into `view` dropped.
    @MainActor
    static func adopt(_ image: UIImage, url: String?, into view: UIImageView) {
        requested[ObjectIdentifier(view)] = url
        view.image = image
    }

    /// `waiting`: true while the picture is on its way (the card shows the
    /// placeholder — `FixedFocusPlaceholder`), false once it's in, or when
    /// there's none to wait for.
    @MainActor
    static func load(_ url: String?, into view: UIImageView, maxDimension: CGFloat,
                     waiting: ((Bool) -> Void)? = nil) {
        let slot = ObjectIdentifier(view)
        requested[slot] = url
        guard let url else { view.image = nil; waiting?(false); return }
        let memoryKey = RemoteImage.memoryKey(url, maxDimension: maxDimension, maxPixels: nil)
        if let hit = ImageCache.shared.image(for: memoryKey) {
            view.image = trimmedIfLogo(hit, in: view, key: memoryKey)
            waiting?(false)
            return
        }
        view.image = nil
        waiting?(true)
        let budget = RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil)
        // Dropped, not decoded, once the view has asked for another
        // (a held Left/Right: the box has moved on).
        let still: @MainActor () -> Bool = { requested[slot] == url }
        Task { @MainActor [weak view] in
            var image = await ImageCache.shared.diskImage(for: url, budget: budget, memoryKey: memoryKey,
                                                          still: still)
            if image == nil, still(), let remote = URL(string: url),
               let data = try? await ImageCache.shared.download(remote) {
                // Off the main thread (it decoded here, mid-scroll).
                image = await DecodeGate.shared.run(.now) { ImageCache.decodeDownsampled(data, budget: budget) }
                // In memory too (under the same key a SwiftUI RemoteImage of
                // this size uses): the Detail page opened from the billboard
                // shows the very same picture from its first frame.
                if let image {
                    ImageCache.shared.insert(image, for: url, data: data, memoryKey: memoryKey)
                } else {
                    ImageCache.shared.insertData(data, for: url)
                }
            }
            guard let view, requested[slot] == url else { return }
            view.image = image.map { trimmedIfLogo($0, in: view, key: memoryKey) }
            waiting?(false)
        }
    }
}

/// The shade under a card's logo: the picture's lower half darkening to
/// its foot. A view, not a bare layer: it moves and resizes with its
/// picture in the moves' animations (a bare layer took Core Animation's
/// own 0.25 s — behind the growing or closing card, the picture showed
/// undimmed for a moment) and shows or hides at once.
final class FixedFocusShade: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // A bottom fade under the words (the box's, a tall card's): dark at
        // the foot, eased, clear by the card's upper third.
        let gradient = layer as! CAGradientLayer
        gradient.colors = [0, 0.5, 0.8, 0.9].map { UIColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0.3, 0.55, 0.8, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A card's logo, as the billboard's: trimmed of its empty edges (many
/// come wide and transparent — fitted into the room they sat centred, too
/// far right), sized by area (`areaShare` of the room, within it) and
/// standing at the room's bottom left.
final class FixedFocusLogo: UIImageView {
    var areaShare: CGFloat = 0.4
    var room: CGRect = .zero { didSet { if room != oldValue { place() } } }
    /// A dark logo (made for a bright poster) is drawn in white: on the
    /// art's dark foot it didn't read.
    override var image: UIImage? {
        didSet {
            if let image, image.renderingMode != .alwaysTemplate, Self.isDark(image) {
                tintColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
                self.image = image.withRenderingMode(.alwaysTemplate)
                return
            }
            place()
        }
    }

    /// Dark: one even colour, none of it bright (The Odyssey's dim blue,
    /// spread 0.004; a deep red goes white too), from a tiny copy, once
    /// per picture.
    private static let darkness = NSCache<UIImage, NSNumber>()
    static func isDark(_ image: UIImage) -> Bool {
        if let known = darkness.object(forKey: image) { return known.boolValue }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var peak: Double = 0, weight: Double = 0, square: Double = 0
        if let cg = image.cgImage,
           let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                   bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Double(pixels[i + 3]) / 255
                guard alpha > 0.5 else { continue }
                // Premultiplied: back to the colour, then its luminance.
                let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha
                let b = Double(pixels[i + 2]) / 255 / alpha
                let light = max(r, g, b)
                peak += light * alpha
                square += light * light * alpha
                weight += alpha
            }
        }
        let mean = weight > 0 ? peak / weight : 1
        let spread = weight > 0 ? (max(0, square / weight - mean * mean)).squareRoot() : 0
        // One even colour only: a logo with a picture in it (Infinity
        // Castle's emblem, spread 0.2) went a white blob.
        let dark = weight > 0 && mean < 0.7 && spread < 0.1
        darkness.setObject(NSNumber(value: dark), forKey: image)
        return dark
    }
    /// Called once it's placed (the badges sit over it).
    var onPlace: (() -> Void)?
    /// Its top as drawn (nil: no picture yet). Bounds and centre: a
    /// transform (the box's drift) leaves them be.
    var drawnTop: CGFloat? { image == nil || bounds.height == 0 ? nil : center.y - bounds.height / 2 }

    private func place() {
        defer { onPlace?() }
        guard let size = image?.size, size.width > 0, size.height > 0, !room.isEmpty else {
            bounds = .zero
            center = CGPoint(x: room.minX, y: room.maxY)
            return
        }
        let fitted = LogoFit(area: room.width * room.height * areaShare, maxSize: room.size)
            .size(for: size)
        bounds = CGRect(origin: .zero, size: fitted)
        center = CGPoint(x: room.minX + fitted.width / 2, y: room.maxY - fitted.height / 2)
    }
}

/// One row: its name and a horizontal collection view of posters.
final class FixedFocusRowCell: UICollectionViewCell, UICollectionViewDataSource,
                               UICollectionViewDelegateFlowLayout {
    private(set) var rowIndex = 0
    private weak var controller: FixedFocusRowsController?
    /// The move its controller is setting up (`FixedFocusMove`).
    var move: FixedFocusMove? { controller?.move }
    private let title = UILabel()
    private let strip: UICollectionView
    private var row: HomeRow? {
        guard let controller, controller.rows.indices.contains(rowIndex) else { return nil }
        return controller.rows[rowIndex]
    }
    private var selectedIndex: Int { row.flatMap { controller?.selected[$0.id] } ?? 0 }
    /// Only the focused row has a grown cell; the others are all posters.
    private var isFocusRow: Bool { controller?.focusedRow == rowIndex }

    /// A moving-focus row's captions only while it has focus: rows above
    /// and below show only their cards (Home has none at all).
    private var captionsShown: Bool { isFocusRow && controller?.captions != false }
    func applyCaptions() {
        guard let destinationStrip else { return }
        for case let card as FixedFocusDestinationCell in destinationStrip.visibleCells { card.setCaptionShown(captionsShown) }
    }


    /// Continue Watching: landscape cards (its progress, Select resumes).
    var isContinue: Bool { controller?.isContinue(rowIndex) == true }
    /// Landscape cards (Continue Watching's, Search's rows).
    var isLandscape: Bool { controller?.isLandscape(rowIndex) == true }
    /// A collection: its name and tiles in a panel.
    var isPanel: Bool { controller?.isPanel(rowIndex) == true }
    /// Its box at the posters' size (no wide card).
    /// A destination row: its own strip (native scrolling, system lift).
    var isDestination: Bool { controller?.isDestination(rowIndex) == true }
    private var destinationStrip: UICollectionView?
    /// The cards' size.
    var cardHeight: CGFloat { controller?.cardHeight(rowIndex) ?? FixedFocusMetrics.height }
    var cardWidth: CGFloat {
        isLandscape ? FixedFocusMetrics.landscapeWidth(height: cardHeight) : FixedFocusMetrics.posterWidth
    }
    /// The billboard: no name, invisible cells (focus targets only).
    var isFeatured: Bool { controller?.isFeatured(rowIndex) == true }
    /// A header button takes focus while the row has it: from the cards
    /// only the selected one (Up lands on the row's season), along the
    /// header any.
    func headerFocusable(_ button: FixedFocusHeaderButton) -> Bool {
        guard controller?.headerShown(rowIndex) == true else { return false }
        if button.selected { return true }
        let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem
        return (focused as? FixedFocusHeaderButton)?.rowCell === self
    }

    /// The header's selected button (nil: no header showing).
    var headerFocusTarget: UIView? {
        guard controller?.headerShown(rowIndex) == true, let header = controller?.header(rowIndex),
              headerButtons.indices.contains(header.selected) else { return nil }
        return headerButtons[header.selected]
    }
    /// The cards' top: under the name (and its line, if any).
    var cardsTop: CGFloat { FixedFocusMetrics.titleHeight + (controller?.titleExtra(rowIndex) ?? 0) }
    /// A row's name.
    static let titleFont = UIFont.systemFont(ofSize: Spotlight.headerTitleSize, weight: .semibold)
    /// Waiting under the billboard: the row's cards don't show (they stay
    /// focusable).
    var concealed = false {
        didSet {
            for case let poster as FixedFocusPosterCell in strip.visibleCells {
                poster.setConcealed(postersHidden)
            }
            // (A destination row's list through a mask, not its alpha: the
            // focus engine skips everything in a fully transparent view, and
            // Down from the billboard went past the row.)
            applyConcealMask()
        }
    }
    /// RIGID billboard (Details): concealed, the cards are cut off by a LINE
    /// at their top instead of hidden whole; shown, the line is this much
    /// lower (past them). Changed inside the scroll it moves with the row's
    /// curve against the row's own move — so it stays put on the screen and
    /// the cards rise out from under it (no fade, no pop).
    var concealTravel: CGFloat? {
        didSet { if concealTravel != oldValue { applyConcealMask() } }
    }

    /// Moved down (the controller's `peekDrop`) — drawn only: the views
    /// stay where they are, so Down still finds the row. In the surrounding
    /// animation block's time, on a no-bounce spring.
    var drop: CGFloat = 0 {
        didSet {
            guard drop != oldValue else { return }
            let layer = contentView.layer
            let from = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
            layer.sublayerTransform = CATransform3DMakeTranslation(0, drop, 0)
            let duration = UIView.inheritedAnimationDuration
            guard duration > 0 else { layer.removeAnimation(forKey: "drop"); return }
            let move = CASpringAnimation(perceptualDuration: duration, bounce: 0)
            move.duration = move.settlingDuration
            move.keyPath = "sublayerTransform"
            move.fromValue = from
            layer.add(move, forKey: "drop")
        }
    }
    /// The posters' contents hidden (concealed by a line: not them).
    private var postersHidden: Bool { concealed && concealTravel == nil }

    private func applyConcealMask() {
        let over = FixedFocusStripLayout.overscan
        let base = stripHost.bounds.insetBy(dx: -2 * over, dy: -200)
        guard let travel = concealTravel else {
            concealMask.alpha = concealed ? 0 : 1
            concealMask.frame = base
            return
        }
        concealMask.alpha = 1
        // (Stretched to the cards' top, or past them by the travel.)
        // (Shown: past the cards' end however tall they are — a Top 10's
        // grid is taller than the travel.)
        let line = cardsTop - stripHost.frame.minY + (concealed ? 0 : max(travel, cardHeight + 200))
        concealMask.frame = CGRect(x: base.minX, y: base.minY, width: base.width, height: line - base.minY)
    }
    /// Hides a destination row's list while it waits under the billboard.
    private let concealMask = UIView()
    /// The name's brightness (see the controller's `titleAlpha`).
    var titleAlpha: CGFloat = 1 {
        didSet { applyHeader() }
    }
    /// How far the name sits above its usual place over the cards (the next
    /// row's, waiting under the billboard: up on the billboard).
    var titleLift: CGFloat = 0 {
        didSet {
            // (Unchanged: a move under way stays — a Left/Right mid-scroll.)
            guard titleLift != oldValue else { return }
            titleHolder.layer.removeAnimation(forKey: "lift")
            titleHolder.transform = CGAffineTransform(translationX: 0, y: -titleLift)
        }
    }
    private let titleHolder = UIView()
    /// The name stepping up out of a focused card's way, as the captions
    /// step down (inside the holder, apart from its lift).
    private let titleRoomView = UIView()
    /// How far the name has stepped up (see `applyNameRoom`).
    private var nameRoom: CGFloat = 0
    /// The name makes room for the focused card when that card grows
    /// under it: a fixed row's box while the row has focus; a moving-focus
    /// row's card while it's under the name (the row's first cards).
    /// Inside the surrounding animation (the row's move).
    func applyNameRoom(focusing index: Int? = nil) {
        var room: CGFloat = 0
        if isFocusRow, !isFeatured, controller?.custom(rowIndex) == nil {
            if let cv = destinationStrip, let controller {
                let focused = index ?? (UIFocusSystem.focusSystem(for: self)?.focusedItem as? UICollectionViewCell)
                    .flatMap { $0.superview === cv ? cv.indexPath(for: $0)?.item : nil }
                if let focused, let frame = cv.layoutAttributesForItem(at: IndexPath(item: focused, section: 0))?.frame,
                   frame.minY < 1 {
                    let card = controller.destinationCard(rowIndex)
                    let lift = FixedFocusMetrics.movingFocusLift
                    let centre = frame.midX - cv.contentOffset.x + cv.frame.minX + stripHost.frame.minX
                    let half = card.width * (1 + lift) / 2
                    let nameEnd = FixedFocusMetrics.titleInset + title.intrinsicContentSize.width
                    if centre - half < nameEnd, centre + half > FixedFocusMetrics.titleInset {
                        room = card.height * lift / 2
                    }
                }
            }
        }
        guard room != nameRoom else { return }
        nameRoom = room
        // On the card's own timing (it grows on the move's spring, also
        // inside Up/Down's longer one): on the row's, the card rose ahead
        // of the name and the gap between them closed up mid-move.
        // (Core Animation: a nested UIView animation takes the outer spring.)
        let layer = titleRoomView.layer
        let from = layer.presentation()?.transform ?? layer.transform
        layer.transform = CATransform3DMakeTranslation(0, -room, 0)
        guard UIView.inheritedAnimationDuration > 0 else { layer.removeAnimation(forKey: "room"); return }
        let move = CASpringAnimation(perceptualDuration: Motion.moveDuration, bounce: 0)
        move.duration = move.settlingDuration
        move.keyPath = "transform"
        move.fromValue = from
        layer.add(move, forKey: "room")
    }
    /// A placeholder row's name still to come (`FixedFocusRows.placeholderRows`).
    private let titleBar = FixedFocusPlaceholder()

    /// The row's name accessory (see `FixedFocusRows.rowTitleAccessories`):
    /// on its own line under the name, shown while the row has focus.
    private var accessory: UIHostingController<AnyView>?

    func showAccessory() {
        guard let controller, let row else { return }
        guard let view = controller.rowTitleAccessories[row.id] else {
            accessory?.view.isHidden = true
            return
        }
        if let accessory {
            accessory.rootView = view
            accessory.view.isHidden = false
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.safeAreaRegions = []
            accessory = host
        }
        // (Under a header: in its block — they move as one.)
        if let host = accessory?.view {
            let parent = controller.header(rowIndex) != nil ? headerBlock : contentView
            if host.superview !== parent { parent.addSubview(host) }
        }
        setNeedsLayout()
        placeAccessory()
        applyAccessory()
    }

    func applyAccessory() { accessory?.view.alpha = isFocusRow ? 1 : 0 }

    private func placeAccessory() {
        if let host = accessory?.view {
            // Its own line: under the name, centred in the extra room (above
            // the usual gap to the cards) — or under the header, in its room.
            let size = host.sizeThatFits(CGSize(width: 1920, height: 200))
            let y: CGFloat
            if controller?.header(rowIndex) != nil {
                let room = FixedFocusRowsController.headerAccessoryHeight
                y = FixedFocusHeaderButton.height + FixedFocusRowsController.headerAccessoryGap + (room - size.height) / 2
            } else {
                let room = FixedFocusRowsController.titleAccessoryHeight
                y = FixedFocusMetrics.titleLine + (room - size.height) / 2 + 4
            }
            host.frame = CGRect(x: FixedFocusMetrics.titleInset, y: y, width: size.width, height: size.height)
        }
    }

    /// A custom row's view (see `FixedFocusRows.customRows`), where the
    /// cards would be — over them, so its focusable parts aren't covered.
    private var customHost: UIHostingController<AnyView>?

    func showCustom() {
        guard let controller else { return }
        guard let custom = controller.custom(rowIndex) else {
            customHost?.view.isHidden = true
            return
        }
        let view = controller.environment(custom.view)
        if let customHost {
            customHost.rootView = view
            customHost.view.isHidden = false
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            // (A child of the rows: focus and the environment reach it. Under
            // the row's name: what it draws may reach up behind it.)
            controller.addChild(host)
            contentView.insertSubview(host.view, belowSubview: titleHolder)
            host.didMove(toParent: controller)
            customHost = host
        }
        setNeedsLayout()
    }

    /// The row's header (see `FixedFocusRows.rowHeaders`): season buttons in
    /// the name's place while the row has focus — the name gives way.
    private var headerButtons: [FixedFocusHeaderButton] = []
    private let headerStack = UIStackView()
    /// The header scrolls along: tvOS keeps the focused button in view; from
    /// the cards, the row's season is brought in (`revealSelected`).
    private let headerScroll = UIScrollView()
    /// The header and the line under it (the row's accessory), shown and
    /// hidden as one (see `moveHeader`).
    private let headerBlock = UIView()
    private var revealedSelection: Int?

    /// Focus back to the row's current card (Select on the header).
    func focusCards() {
        controller?.run(FixedFocusRowsCommand(action: .focusRow(rowID: row?.id ?? "")))
    }

    func showHeader() {
        guard let controller else { return }
        let labels = controller.header(rowIndex)?.labels ?? []
        if headerButtons.map(\.label) != labels {
            headerButtons.forEach { $0.removeFromSuperview() }
            headerButtons = labels.enumerated().map { index, label in
                let button = FixedFocusHeaderButton(label: label, index: index)
                button.rowCell = self
                headerStack.addArrangedSubview(button)
                return button
            }
        }
        applyHeader(animated: false)
        // (The line under it moves into / out of its block.)
        showAccessory()
    }

    /// The header or the name, whichever the row's state says; the selected
    /// button marked.
    func applyHeader(animated: Bool = true) {
        let header = controller?.header(rowIndex)
        let shown = controller?.headerShown(rowIndex) == true
        for button in headerButtons { button.selected = button.index == header?.selected }
        if let selected = header?.selected, selected != revealedSelection {
            revealedSelection = selected
            revealSelected(animated: animated && shown)
        }
        // (Hidden by Up's `moveHeader`; shown again with the header.)
        if shown, headerBlock.alpha != 1 { UIView.performWithoutAnimation { headerBlock.alpha = 1 } }
        let trading = shown || headerStack.alpha != 0
        let apply = {
            self.headerStack.alpha = shown ? 1 : 0
            // (Never a fade where the name and the header trade places in
            // the billboard's move — `moveHeader`. Otherwise the name
            // brightens with the row's move, as the row itself does.)
            if trading {
                UIView.performWithoutAnimation { self.title.alpha = shown ? 0 : self.titleAlpha }
            } else {
                self.title.alpha = self.titleAlpha
            }
        }
        if animated, headerStack.alpha != (shown ? 1 : 0) {
            UIView.animate(withDuration: Motion.fadeDuration, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    /// Down from the billboard (`entering`) / Up to it, on the row's move
    /// (its timing over even steps of its progress, or — `timing` nil — a
    /// spring's sampled progress): the header's offset below its place
    /// along `fade`; the name's lift and opacity along `lift` and
    /// `titleOpacity` at `scale` (its ⌄ with it); then the end state.
    /// The name alone moving (`lift` along the move) — a row without a
    /// header (Details' one season).
    func moveTitle(lift: [CGFloat], timing: CAMediaTimingFunction?, duration: Double) {
        UIView.performWithoutAnimation { titleLift = lift.last ?? 0 }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = lift.map { NSNumber(value: Double(-$0)) }
        animation.keyTimes = lift.indices.map { NSNumber(value: Double($0) / Double(max(lift.count - 1, 1))) }
        animation.calculationMode = .linear
        animation.timingFunction = timing
        animation.duration = duration
        titleHolder.layer.add(animation, forKey: "lift")
    }

    func moveHeader(fade: [CGFloat], lift: [CGFloat], titleOpacity: [CGFloat], scale: CGFloat,
                    timing: CAMediaTimingFunction?, duration: Double, entering: Bool) {
        let times = fade.indices.map { NSNumber(value: Double($0) / Double(max(fade.count - 1, 1))) }
        func keyframes(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values.map { NSNumber(value: Double($0)) }
            animation.keyTimes = times
            animation.calculationMode = .linear
            animation.timingFunction = timing
            animation.duration = duration
            return animation
        }
        UIView.performWithoutAnimation {
            // (The block's own value at its end too: a move hurried —
            // `hurryMoves` — runs from what's shown to it; left shown, the
            // map flashed back after Up.)
            headerBlock.alpha = entering ? 1 : 0
            accessory?.view.alpha = entering ? 1 : 0
            headerStack.alpha = entering ? 1 : 0
            title.alpha = entering ? 0 : titleAlpha
            titleLift = lift.last ?? 0
            titleScale = scale
        }
        let ones = [CGFloat](repeating: 1, count: fade.count)
        // (The block fades; inside it both are shown throughout.)
        headerBlock.layer.add(keyframes("opacity", fade), forKey: "opacity")
        accessory?.view.layer.add(keyframes("opacity", ones), forKey: "opacity")
        headerStack.layer.add(keyframes("opacity", ones), forKey: "opacity")
        titleHolder.layer.add(keyframes("transform.translation.y", lift.map { -$0 }), forKey: "lift")
        title.layer.add(keyframes("opacity", titleOpacity), forKey: "opacity")
    }

    /// The row's season in view (a step across a season seam, opening on
    /// a later season) — not while focus is on the header: tvOS scrolls it.
    private func revealSelected(animated: Bool) {
        guard let index = revealedSelection, headerButtons.indices.contains(index),
              !headerButtons.contains(where: \.isFocused) else { return }
        layoutIfNeeded()
        let frame = headerButtons[index].frame.offsetBy(dx: headerStack.frame.minX, dy: 0)
        let inset = FixedFocusMetrics.inset
        let width = headerScroll.bounds.width
        let maxX = max(headerScroll.contentSize.width - width, 0)
        var x = headerScroll.contentOffset.x
        if frame.maxX + inset > x + width { x = frame.maxX + inset - width }
        if frame.minX - inset < x { x = frame.minX - inset }
        x = min(max(x, 0), maxX)
        guard x != headerScroll.contentOffset.x else { return }
        let move = { self.headerScroll.contentOffset.x = x }
        if animated {
            UIView.animate(withDuration: Motion.moveDuration, delay: 0,
                           usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: move)
        } else {
            move()
        }
    }

    /// The name's size (the next row's, on the billboard: smaller).
    var titleScale: CGFloat = 1 {
        didSet {
            guard titleScale != oldValue else { return }
            title.layer.removeAnimation(forKey: "scale")
            title.transform = CGAffineTransform(scaleX: titleScale, y: titleScale)
        }
    }
    /// The grown cell's own content hidden (the fixed box shows it).
    var contentHidden = true {
        didSet { if !contentHidden { cutOut(nil) }; applyGrown() }
    }
    /// Left/Right under the fixed box: the box's place cut out of the row,
    /// so the posters drifting under it don't show at its rounded corners
    /// and beside its edges. Only while a move runs (a mask costs a pass).
    func cutOut(_ hole: CGRect?, radius: CGFloat = 0) {
        guard let hole else { layer.mask = nil; return }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = UIBezierPath(rect: bounds.insetBy(dx: -4000, dy: -4000))
        path.append(UIBezierPath(roundedRect: hole, cornerRadius: radius))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .evenOdd
        mask.frame = bounds
        mask.path = path.cgPath
        CATransaction.commit()
        layer.mask = mask
    }

    private let layout = FixedFocusStripLayout()

    override init(frame: CGRect) {
        strip = FixedFocusStripView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        // The billboard's invisible cards: not while its focus is outside
        // (Details' buttons) — neither they nor the list in their place.
        (strip as? FixedFocusStripView)?.selfFocus = { [weak self] in !(self?.billboardCardsOff ?? false) }
        layout.wideIndex = { [weak self] in
            guard let self, self.isFocusRow, !self.isLandscape, !self.isFeatured else { return nil }
            return self.selectedIndex
        }
        layout.cardWidth = { [weak self] in self?.cardWidth ?? FixedFocusMetrics.posterWidth }
        layout.cardHeight = { [weak self] in self?.cardHeight ?? FixedFocusMetrics.height }
        clipsToBounds = false
        contentView.clipsToBounds = false
        title.font = Self.titleFont
        title.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        // The name in a holder: the holder lifts (`titleLift`), the name in
        // it scales from its left edge (`titleScale`).
        title.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        titleRoomView.addSubview(title)
        titleBar.isHidden = true
        titleRoomView.addSubview(titleBar)
        titleHolder.addSubview(titleRoomView)
        contentView.addSubview(titleHolder)
        headerStack.axis = .horizontal
        headerStack.spacing = FixedFocusHeaderButton.spacing
        headerStack.alpha = 0
        headerScroll.clipsToBounds = false
        headerScroll.showsHorizontalScrollIndicator = false
        headerScroll.contentInsetAdjustmentBehavior = .never
        headerScroll.addSubview(headerStack)
        headerBlock.addSubview(headerScroll)
        contentView.addSubview(headerBlock)
        strip.backgroundColor = .clear
        strip.clipsToBounds = false
        strip.isScrollEnabled = false
        strip.showsHorizontalScrollIndicator = false
        strip.contentInsetAdjustmentBehavior = .never
        strip.remembersLastFocusedIndexPath = true
        strip.dataSource = self
        strip.delegate = self
        strip.register(FixedFocusPosterCell.self, forCellWithReuseIdentifier: "poster")
        stripHost.layer.cornerRadius = FixedFocusMetrics.panelRadius
        stripHost.layer.cornerCurve = .continuous
        stripHost.addSubview(strip)
        contentView.addSubview(stripHost)
        // The header over the cards' host (it spans the cell): it must not
        // be covered, or tvOS won't focus it.
        // (The name too: as a control it must not be covered either.)
        contentView.bringSubviewToFront(titleHolder)
        contentView.bringSubviewToFront(headerBlock)

    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // (Last: once the strip has its size.)
        defer { applyPendingAim() }
        // (Bounds and centre: the name may be lifted — a transform.)
        // (Wide: as a control, Up from any card finds it.)
        titleHolder.bounds = CGRect(x: 0, y: 0, width: 1700, height: FixedFocusMetrics.titleLine)
        titleHolder.center = CGPoint(x: FixedFocusMetrics.titleInset + 850,
                                     y: FixedFocusMetrics.titleLine / 2 + FixedFocusMetrics.titleDrop)
        titleRoomView.bounds = titleHolder.bounds
        titleRoomView.center = CGPoint(x: titleHolder.bounds.midX, y: titleHolder.bounds.midY)
        title.bounds = CGRect(x: 0, y: 0, width: 1200, height: FixedFocusMetrics.titleLine)
        title.center = CGPoint(x: 0, y: FixedFocusMetrics.titleLine / 2)
        let barHeight = (Self.titleFont.pointSize * 0.72).rounded()
        titleBar.layer.cornerRadius = barHeight / 2
        titleBar.frame = CGRect(x: 0, y: (FixedFocusMetrics.titleLine - barHeight) / 2, width: 300, height: barHeight)
        placeAccessory()
        customHost?.view.frame = CGRect(x: 0, y: cardsTop, width: bounds.width, height: cardHeight)
        let headerSize = headerStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        headerBlock.frame = CGRect(x: 0, y: 0, width: bounds.width, height: cardsTop)
        headerScroll.bounds.size = CGSize(width: bounds.width, height: FixedFocusHeaderButton.height)
        headerScroll.center = CGPoint(x: bounds.width / 2, y: FixedFocusHeaderButton.height / 2)
        headerStack.frame = CGRect(x: FixedFocusMetrics.inset, y: 0,
                                   width: headerSize.width, height: FixedFocusHeaderButton.height)
        headerScroll.contentSize = CGSize(width: headerSize.width + 2 * FixedFocusMetrics.inset,
                                          height: FixedFocusHeaderButton.height)
        // Wider than the screen on both sides: posters sliding in or out at
        // the edges keep their cells and SLIDE (outside the visible area
        // UIKit creates / drops them with a fade, in place).
        let over = FixedFocusStripLayout.overscan
        strip.frame = CGRect(x: -over, y: cardsTop,
                             width: 1920 + 2 * over, height: cardHeight)
        // The billboard's picture: the whole screen while this row is at the
        // focus spot (its edge below).
        stage?.frame = CGRect(x: 0, y: -FixedFocusMetrics.rowTop, width: 1920,
                              height: StagePictureView.pictureSize.height)
        panel?.frame = FixedFocusPanelView.frame(cardHeight: cardHeight)
        // A collection's tiles stay inside its panel: they slide under its
        // edges (the strip's host clips to it).
        let stripFrame = strip.frame
        if let panel, isPanel {
            stripHost.frame = panel.frame
            stripHost.clipsToBounds = true
        } else {
            stripHost.frame = bounds
            stripHost.clipsToBounds = false
        }
        strip.frame = stripFrame.offsetBy(dx: -stripHost.frame.minX, dy: -stripHost.frame.minY)
        // A destination strip: the screen plus the overscan on both sides.
        destinationStrip?.frame = CGRect(x: -over, y: cardsTop,
                                         width: 1920 + 2 * over, height: cardHeight)
            .offsetBy(dx: -stripHost.frame.minX, dy: -stripHost.frame.minY)
        // Covers the list wherever its cards (and their lift) reach.
        UIView.performWithoutAnimation { applyConcealMask() }
    }

    /// Holds the strip; a panel row's clips to the panel.
    private let stripHost = UIView()

    /// The Featured row: the billboard's picture (see `StagePictureView`).
    private var stage: StagePictureView?
    /// A collection row's panel (see `FixedFocusPanelView`).
    private var panel: FixedFocusPanelView?

    func showStage(_ item: MetaItem, direction: CGFloat, animated: Bool) {
        // Full screen: TMDB's ORIGINAL file, whatever size the pick came
        // with (a saved pick or cached catalog may still carry a smaller
        // rendition — soft on a 4K TV).
        placeStage(TMDBService.originalSize(item.background) ?? item.poster, item: item,
                   direction: direction, animated: animated)
    }

    private func placeStage(_ url: String?, item: MetaItem, direction: CGFloat, animated: Bool) {
        guard isFeatured, controller?.hidesBillboardPicture != true else { return }
        // Pinned: the controller's, not part of this row.
        if let pinned = controller?.pinnedStage {
            stage?.removeFromSuperview()
            stage = nil
            pinned.show(url, item: item, direction: direction, animated: animated)
            return
        }
        if stage == nil {
            let view = StagePictureView()
            contentView.insertSubview(view, at: 0)
            stage = view
            setNeedsLayout()
            layoutIfNeeded()
        }
        stage?.show(url, item: item, direction: direction, animated: animated)
    }

    /// The catalog (and its titles and art) this cell last showed.
    private var shownRow: (id: String, content: [String])?

    /// The name coming down into place (see the controller's
    /// `revealNextNameIfNew`).
    func revealTitle() {
        let alpha = title.alpha
        title.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.title.alpha = alpha
        }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -ModeSwap.lift
        drop.toValue = 0
        drop.isAdditive = true
        drop.duration = 0.45
        drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.85, 0.25, 1)
        title.layer.add(drop, forKey: "reveal")
    }

    /// A new name, crossfaded (the row itself unchanged).
    func showTitle(_ text: String) {
        guard title.text != text else { return }
        UIView.transition(with: title, duration: Motion.fadeDuration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: { self.title.text = text })
        setNeedsLayout()
    }

    func showProgress() {
        guard let row, let controller else { return }
        func entry(_ index: Int) -> WatchProgress? {
            row.items.indices.contains(index) ? controller.progress[row.items[index].id] : nil
        }
        for case let card as FixedFocusDestinationCell in destinationStrip?.visibleCells ?? [] {
            if let progress = entry(card.itemIndex) { card.showProgress(progress) }
        }
        for case let card as FixedFocusPosterCell in strip.visibleCells {
            if let progress = entry(card.itemIndex) { card.showProgress(progress) }
        }
    }

    func configure(rowIndex: Int, controller: FixedFocusRowsController) {
        self.rowIndex = rowIndex
        self.controller = controller
        title.text = row?.title
        title.isHidden = isFeatured
        titleBar.isHidden = row?.id.hasPrefix("placeholder-") != true
        setNeedsLayout()
        showAccessory()
        showHeader()
        showCustom()
        if isPanel {
            if panel == nil {
                let view = FixedFocusPanelView()
                contentView.insertSubview(view, at: 0)
                panel = view
                setNeedsLayout()
            }
            // The page's colour (or neutral), as it is now.
            panel?.show(nil, fade: 0, follows: false)
        }
        panel?.isHidden = !isPanel
        if isFeatured, let row, row.items.indices.contains(selectedIndex) {
            showStage(row.items[selectedIndex], direction: 1, animated: false)
        }
        strip.isHidden = isDestination
        if isDestination, destinationStrip == nil { makeDestinationStrip() }
        destinationStrip?.isHidden = !isDestination
        if let cv = destinationStrip {
            // A Top 10: all ten at once, two lines of five (no scrolling).
            let ranked = controller.isRanked(rowIndex)
            if ranked {
                gridLayout.cell = FixedFocusMetrics.rankedCard
                gridLayout.lineHeight = FixedFocusMetrics.rankedCard.height
            }
            let layout: UICollectionViewLayout = ranked ? gridLayout : flowLayout
            if cv.collectionViewLayout !== layout {
                cv.setCollectionViewLayout(layout, animated: false)
                shownRow = nil
            }
        }
        // The same catalog coming back (it keeps its own cell): leave its
        // posters, scroll position and focus memory as they are — a reload
        // would erase exactly that. Only new content reloads.
        if let row, let shown = shownRow, shown.id == row.id, shown.content == row.contentKey {
            return
        }
        shownRow = row.map { ($0.id, $0.contentKey) }
        if isDestination {
            // Scrolled by their own rule (see `windowOffset`).
            destinationStrip?.isScrollEnabled = false
            windowStart = 0
            destinationStrip?.reloadData()
            destinationStrip?.contentOffset = .zero
            // (Aimed before its cell was made: there at once — and again once
            // the strip has its size: a page built in one go (Details with
            // its data) made this cell before layout, the offset set then
            // was lost, and the row sat at its first card while the engine
            // took it to be at the aimed one — Down then found nothing.)
            if selectedIndex > 0 {
                destinationStrip?.layoutIfNeeded()
                aim(selectedIndex, animated: false)
                pendingAim = selectedIndex
                setNeedsLayout()
            }
            return
        }
        // Under the box only while it shows: before focus first arrives
        // (a page just opened) the cell draws the grown card itself — else
        // the wide place showed the plain poster until the box popped in.
        contentHidden = controller.boxCovers(rowIndex)
        strip.reloadData()
        strip.layoutIfNeeded()
        strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0)
    }

    /// The same titles with new pictures: the cards on screen reconfigured
    /// in place (focus, scroll and cells kept), the rest as they come.
    func refreshArt() {
        guard let row else { return }
        shownRow = (row.id, row.contentKey)
        for cv in [strip, destinationStrip].compactMap({ $0 }) where !cv.isHidden {
            cv.reconfigureItems(at: cv.indexPathsForVisibleItems)
        }
    }

    /// Select pressed on a fixed row's card (the box shows it).
    func setBoxPressed(_ pressed: Bool) { controller?.setBoxPressed(pressed) }

    /// This row's first card on screen, at rest (see the controller).
    func restingCardOrigin() -> CGPoint? { controller?.restingCardOrigin(rowIndex) }
    /// SwiftUI for a card, with the app's stores.
    func hosted(_ view: some View) -> AnyView { controller?.environment(AnyView(view)) ?? AnyView(view) }

    func posterCell(at index: Int) -> UIView? {
        let shown = destinationStrip.flatMap { isDestination ? $0 : nil } ?? strip
        shown.layoutIfNeeded()
        return shown.cellForItem(at: IndexPath(item: index, section: 0))
    }

    /// A destination row's strip: the system's horizontal scrolling — focus
    /// moves along, the row follows only near its edge.
    private let flowLayout = UICollectionViewFlowLayout()
    private let gridLayout = FixedFocusGridLayout()
    private func makeDestinationStrip() {
        let flow = flowLayout
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = FixedFocusMetrics.gap
        // Wider than the screen by the strips' overscan (positions shifted
        // by it): cards scrolling out keep their cells and SLIDE away —
        // outside its bounds UIKit drops them at once.
        let over = FixedFocusStripLayout.overscan
        flow.sectionInset = UIEdgeInsets(top: 0, left: over + FixedFocusMetrics.inset, bottom: 0,
                                         right: over + FixedFocusMetrics.inset)
        gridLayout.left = over + FixedFocusMetrics.inset
        let view = UICollectionView(frame: .zero, collectionViewLayout: flow)
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        // No memory: the way in is always the row's current card (see
        // `indexPathForPreferredFocusedView`). A remembered card that's no
        // longer current (aimed elsewhere — Details' seasons) can't take
        // focus, and the strip itself took it instead: a dead end.
        view.remembersLastFocusedIndexPath = false
        view.dataSource = self
        view.delegate = self
        view.register(FixedFocusDestinationCell.self, forCellWithReuseIdentifier: "destination")
        view.register(FixedFocusBannerCell.self, forCellWithReuseIdentifier: "banner")
        view.register(FixedFocusShowcaseCell.self, forCellWithReuseIdentifier: "showcase")
        stripHost.addSubview(view)
        destinationStrip = view
        concealMask.backgroundColor = .black
        concealMask.alpha = concealed ? 0 : 1
        stripHost.mask = concealMask
        setNeedsLayout()
    }

    /// Inside the controller's animation: grow the new, shrink the old,
    /// move the row so the new one sits at the spot.
    func focus(index: Int) {
        guard !isDestination else { return }
        relayout()
        strip.contentOffset = CGPoint(x: offset(for: index), y: 0)
    }

    /// Re-lay out (grown cell or not) and restyle the visible cells.
    func relayout() {
        guard !isDestination else { return }
        strip.collectionViewLayout.invalidateLayout()
        strip.layoutIfNeeded()
        applyGrown()
        if !isFocusRow { strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0) }
    }

    private func applyGrown() {
        for cell in strip.visibleCells {
            guard let poster = cell as? FixedFocusPosterCell else { continue }
            poster.setGrown(isFocusRow && poster.itemIndex == selectedIndex,
                            contentHidden: contentHidden)
            poster.setPast(isPast(poster.itemIndex))
        }
    }

    /// Left of the box in the focused row: where you came from — dimmed.
    private func isPast(_ index: Int) -> Bool { isFocusRow && index < selectedIndex }

    /// The row offset that puts title `index` at the spot. Exact: every
    /// title before it is card-wide (`FixedFocusStripLayout`).
    private func offset(for index: Int) -> CGFloat {
        CGFloat(index) * (cardWidth + FixedFocusMetrics.gap)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        row?.items.count ?? 0
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if cv === destinationStrip, controller?.isBanner(rowIndex) == true {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "banner", for: indexPath) as! FixedFocusBannerCell
            if let row, row.items.indices.contains(indexPath.item) {
                cell.configure(row.items[indexPath.item], index: indexPath.item, rowCell: self)
            }
            return cell
        }
        if cv === destinationStrip, let controller,
           controller.isShowcase(rowIndex) || controller.isRanked(rowIndex) {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "showcase", for: indexPath) as! FixedFocusShowcaseCell
            if let row, row.items.indices.contains(indexPath.item) {
                let item = row.items[indexPath.item]
                let ranked = controller.isRanked(rowIndex)
                cell.configure(item, index: indexPath.item, rowCell: self, art: row.art[item.id],
                               badge: ranked ? nil : row.badges[item.id], rank: ranked ? indexPath.item + 1 : nil)
            }
            return cell
        }
        if cv === destinationStrip {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "destination", for: indexPath)
                as! FixedFocusDestinationCell
            if let row, let controller, row.items.indices.contains(indexPath.item) {
                let item = row.items[indexPath.item]
                cell.configure(item, subtitle: row.subtitles[item.id], index: indexPath.item, rowCell: self,
                               card: controller.destinationCard(rowIndex),
                               progress: controller.isContinue(rowIndex) ? controller.progress[item.id] : nil,
                               cardState: controller.cardStates[item.id],
                               isLogo: controller.isLogo(rowIndex))
                cell.setCaptionShown(captionsShown)
            }
            return cell
        }
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath) as! FixedFocusPosterCell
        if let row {
            let item = row.items[indexPath.item]
            cell.configure(item, index: indexPath.item, rowCell: self,
                           progress: isContinue ? controller?.progress[item.id] : nil,
                           landscape: isLandscape, invisible: isFeatured,
                           cardHeight: cardHeight, badges: row.badges(for: item))
            cell.setGrown(isFocusRow && indexPath.item == selectedIndex, contentHidden: contentHidden)
            cell.setPast(isPast(indexPath.item))
            cell.setConcealed(concealed)
        }
        return cell
    }

    private var billboardCardsOff: Bool { isFeatured && controller?.billboardFocusOutside == true }

    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if cv === strip && billboardCardsOff { return false }
        // Into a moving-focus row from outside: only its current card. The
        // nearest by position is often the sliver of the one before (an
        // aimed row — Details' episodes), and redirecting from there fails
        // when focus comes from outside the rows (SwiftUI's Play, the
        // season name).
        // (SwiftUI's focused item isn't always a UIView: anything but a
        // view inside this row counts as outside.)
        if cv === destinationStrip,
           (UIFocusSystem.focusSystem(for: cv)?.focusedItem as? UIView)?.isDescendant(of: cv) != true {
            return indexPath.item == selectedIndex
        }
        // A fixed row, from outside the rows altogether (Details' Play down
        // into a row last left further along): its current card too, not
        // the sliver of the one before. (Between rows the box's own move
        // decides.)
        if cv === strip, !isFeatured, let rows = superview,
           (UIFocusSystem.focusSystem(for: cv)?.focusedItem as? UIView)?.isDescendant(of: rows) != true {
            return indexPath.item == selectedIndex
        }
        return true
    }

    func indexPathForPreferredFocusedView(in cv: UICollectionView) -> IndexPath? {
        guard cv === destinationStrip, let row, row.items.indices.contains(selectedIndex) else { return nil }
        return IndexPath(item: selectedIndex, section: 0)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if cv === destinationStrip, let controller {
            return CGSize(width: controller.destinationCard(rowIndex).width, height: cardHeight)
        }
        return CGSize(width: isFocusRow && !isLandscape && indexPath.item == selectedIndex
                        ? FixedFocusMetrics.boxWidth : cardWidth,
                      height: cardHeight)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        FixedFocusMetrics.gap
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row, row.items.indices.contains(indexPath.item) else { return }
        controller?.select(row.items[indexPath.item], rowIndex: rowIndex)
    }

    /// A destination row: moves to its window for the focused card, on
    /// Home's curve and timing.
    func collectionView(_ cv: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard cv === destinationStrip, let index = context.nextFocusedIndexPath?.item,
              let controller, let row else { return }
        let card = controller.destinationCard(rowIndex)
        let offset = windowOffset(focusing: index, card: card.width, count: row.items.count)
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            if offset != cv.contentOffset.x { cv.contentOffset = CGPoint(x: offset, y: 0) }
            self.applyNameRoom(focusing: index)
        } completion: { _ in }
    }

    /// The first card a destination row shows in full.
    private var windowStart = 0
    /// An aim's scroll: very fast, and at most this far (a longer way starts
    /// this far short of it).
    static let aimDuration: Double = 0.3
    static let aimLead: CGFloat = 1100
    /// An aim made before the strip had its size (see `configure`).
    private var pendingAim: Int?

    private func applyPendingAim() {
        guard let index = pendingAim, let cv = destinationStrip, cv.bounds.width > 0 else { return }
        pendingAim = nil
        guard index == selectedIndex else { return }
        cv.layoutIfNeeded()
        aim(index, animated: false)
    }

    /// Shows `index` first in view (aimed from outside — see
    /// `FixedFocusRowsCommand.aim`): a very fast scroll (Details' season
    /// buttons). A long way: from just short of it — the cards between
    /// were never drawn.
    /// A fixed-focus row (the billboard's) straight at `index` — its card
    /// there, for focus to land on (the billboard paging by itself, the
    /// last title to the first). Destination rows: `aim`.
    func jump(to index: Int) {
        guard !isDestination, let row, row.items.indices.contains(index) else { return }
        strip.contentOffset = CGPoint(x: offset(for: index), y: 0)
        strip.layoutIfNeeded()
    }

    func aim(_ index: Int, animated: Bool = true) {
        guard isDestination, let cv = destinationStrip, let controller, let row,
              row.items.indices.contains(index) else { return }
        let card = controller.destinationCard(rowIndex)
        windowStart = index
        let offset = windowOffset(focusing: index, card: card.width, count: row.items.count)
        let distance = abs(offset - cv.contentOffset.x)
        guard distance > 0.5 else { return }
        guard animated else {
            cv.contentOffset = CGPoint(x: offset, y: 0)
            return
        }
        if distance > Self.aimLead {
            let lead = offset > cv.contentOffset.x ? Self.aimLead : -Self.aimLead
            UIView.performWithoutAnimation {
                cv.contentOffset = CGPoint(x: offset - lead, y: 0)
                cv.layoutIfNeeded()
            }
        }
        UIView.animate(withDuration: Self.aimDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            cv.contentOffset = CGPoint(x: offset, y: 0)
        }
    }

    /// Destination rows scroll by a rule, not the system's: as many cards in
    /// full as their space holds (a collection's panel; the screen) with, once
    /// the row has moved, a sliver of the one before and the one after split
    /// evenly — always a hint when there's more. At the start: the cards from
    /// the usual inset, the next one's sliver at the right.
    private func windowOffset(focusing index: Int, card: CGFloat, count: Int) -> CGFloat {
        let gap = FixedFocusMetrics.gap
        let pitch = card + gap
        // A Top 10's grid shows all its cards: never moves.
        if controller?.isRanked(rowIndex) == true { return 0 }
        // Focus stays in place (`FixedFocusRows.anchoredRowIDs`): the
        // focused card always at the first card's spot — to the last one,
        // the row's end left open.
        if let row, controller?.anchoredRowIDs.contains(row.id) == true {
            windowStart = index
            return CGFloat(index) * pitch
        }
        let space = isPanel ? FixedFocusPanelView.frame(cardHeight: cardHeight)
                            : CGRect(x: 0, y: 0, width: 1920, height: 0)
        // Room for the slivers (and their gaps) on both sides.
        let room = space.width - 2 * (gap + FixedFocusMetrics.destinationSliver)
        let shown = max(1, Int((room + gap) / pitch))
        if index < windowStart { windowStart = index }
        if index > windowStart + shown - 1 { windowStart = index - shown + 1 }
        guard windowStart > 0 else { return 0 }
        let edge = (space.width - CGFloat(shown) * card - CGFloat(shown - 1) * gap) / 2
        let content = 2 * FixedFocusMetrics.inset + CGFloat(count) * pitch - gap
        let end = max(0, content - 1920)
        return min(FixedFocusMetrics.inset + CGFloat(windowStart) * pitch - (space.minX + edge), end)
    }
}

/// A Top 10's cards: two lines of five, all on screen, in rank order
/// (1–5 above, 6–10 below), the rows' gap between cards and lines alike.
final class FixedFocusGridLayout: UICollectionViewLayout {
    static let columns = 5
    /// The grid's height for `count` cards, each line `card` tall (its
    /// caption room in).
    static func height(card: CGFloat, count: Int) -> CGFloat {
        let lines = CGFloat(max(1, (count + columns - 1) / columns))
        return lines * card + (lines - 1) * FixedFocusMetrics.gap
    }
    var left: CGFloat = 0
    var cell: CGSize = .zero
    /// A line's height: the card and its caption room.
    var lineHeight: CGFloat = 0
    private var frames: [CGRect] = []

    override func prepare() {
        super.prepare()
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let gap = FixedFocusMetrics.gap
        frames = (0..<count).map { i in
            let column = CGFloat(i % Self.columns), line = CGFloat(i / Self.columns)
            return CGRect(x: left + column * (cell.width + gap), y: line * (lineHeight + gap),
                          width: cell.width, height: lineHeight)
        }
    }
    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.filter { frames[$0].intersects(rect) }.compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}

extension UIView {
    /// A picture of this view as it looks now.
    @MainActor
    func picture() -> UIImage? {
        guard window != nil else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

@MainActor
/// Holding Select on a card (see `HoldMenu`): Continue Watching's menu, or
/// the title's — beside the fixed box, or the moving-focus card itself.
extension FixedFocusRowsController: HoldMenuProviding {
    func holdMenu(for focused: UIView) -> HoldMenuRequest? {
        let rowIndex: Int, itemIndex: Int
        if let poster = focused as? FixedFocusPosterCell, let rowCell = poster.rowCell {
            (rowIndex, itemIndex) = (rowCell.rowIndex, poster.itemIndex)
        } else if let tile = focused as? FixedFocusDestinationItem, let rowCell = tile.rowCell {
            (rowIndex, itemIndex) = (rowCell.rowIndex, tile.itemIndex)
        } else {
            return nil
        }
        guard let (_, entries) = menuEntries(rowIndex: rowIndex, itemIndex: itemIndex), !entries.isEmpty
        else { return nil }
        // The card at its held size (the menu lines up with its top).
        func held(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
            rect.insetBy(dx: -rect.width * (scale - 1) / 2, dy: -rect.height * (scale - 1) / 2)
        }
        if isDestination(rowIndex), let cell = focused as? FixedFocusDestinationCell {
            return cell.holdMenu(entries)
        }
        if let cell = focused as? FixedFocusShowcaseCell { return cell.holdMenu(entries) }
        guard box.alpha == 1 else {
            return HoldMenuRequest(entries: entries, anchor: focused.convert(focused.bounds, to: nil))
        }
        // (`frame`: the box's own transform — pressed — left out.)
        let boxRect = view.convert(CGRect(x: box.center.x - box.bounds.width / 2,
                                          y: box.center.y - box.bounds.height / 2,
                                          width: box.bounds.width, height: box.bounds.height), to: nil)
        let base = FixedFocusMetrics.boxScale
        return HoldMenuRequest(entries: entries,
                               anchor: held(boxRect, base + FixedFocusMetrics.heldGrowth),
                               from: held(boxRect, boxPressed ? base - (1 - FixedFocusMetrics.pressScale) : base),
                               rest: held(boxRect, base),
                               onHeld: { [weak self] in self?.setBoxHeld($0) })
    }
}

/// A label whose lines start at its top, however many there are (a plain
/// `UILabel` centres them in its height).
final class TopAlignedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        let fitted = textRect(forBounds: rect, limitedToNumberOfLines: numberOfLines)
        super.drawText(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: fitted.height))
    }
}
