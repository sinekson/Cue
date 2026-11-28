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
    /// Destination rows (see `FixedFocusMetrics.posterCard`).
    var destinationRowIDs: Set<String> = []
    /// Of them, ranked (Top 10: each card's place beside it).
    var rankedRowIDs: Set<String> = []
    /// Of them, grids of their own cards (Details' people and studios):
    /// lines of them, all in view, as Top 10's, no place numbers.
    var gridRowIDs: Set<String> = []
    /// Of them, showcases (New & Notable: tall cards, the trailer in the
    /// focused one), and whether its trailers play, with sound.
    var showcaseRowIDs: Set<String> = []
    var showcaseTrailers: (on: Bool, sound: Bool) = (false, false)
    /// Of them, Today's Pick: one card the content's width (`spotlightCard`).
    var spotlightRowIDs: Set<String> = []
    /// Poster rows as large landscape rows (`FixedFocusFeatureLayout`; Home).
    var featureRows = false
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
    /// The pinned picture as a card here (screen points; nil: the whole
    /// picture): Home's billboard card, Details' card.
    var billboardCard: CGRect? = nil
    /// Details' trailer full screen: the card opens to the screen, the rows
    /// and the buttons fade (`StagePictureView.setFullScreen`).
    var billboardFull = false
    /// The card takes focus (Home): grown, its shadow, the top bar on it.
    /// Off: a card on the page (Details, its buttons under it).
    var billboardCardFocus = false
    /// The billboard's picture, if not its title's own (Details': the
    /// one it opened with).
    var billboardPicture: String? = nil
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
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: FixedFocusRowsController, context: Context) {
        apply(to: controller)
    }

    private func apply(to controller: FixedFocusRowsController) {
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
        controller.rigidNameY = rigidNameY
        controller.rowTitleAccessories = rowTitleAccessories
        controller.anchoredRowIDs = anchoredRowIDs
        controller.customRows = customRows
        controller.logoRowIDs = logoRowIDs
        controller.onHeaderFocus = onHeaderFocus
        controller.rowHeaders = rowHeaders
        controller.continueRowID = continueRowID
        controller.landscapeRowIDs = landscapeRowIDs
        controller.rankedRowIDs = rankedRowIDs
        controller.gridRowIDs = gridRowIDs
        controller.showcaseRowIDs = showcaseRowIDs
        controller.showcaseTrailers = showcaseTrailers
        controller.spotlightRowIDs = spotlightRowIDs
        controller.featureRows = featureRows
        controller.captions = captions
        controller.centred = centred
        controller.destinationRowIDs = destinationRowIDs
        controller.bannerRowIDs = bannerRowIDs
        controller.bannerHeight = bannerHeight
        controller.portraitRowIDs = portraitRowIDs
        controller.rowTop = rowTop
        controller.aboveVisible = aboveVisible
        controller.belowVisible = belowVisible
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
        controller.rigidBillboardTravel = rigidBillboardTravel
        controller.billboardCard = billboardCard
        controller.billboardFull = billboardFull
        controller.billboardCardFocus = billboardCardFocus
        controller.billboardPicture = billboardPicture
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
    /// Upcoming's past days: gently dimmed. (Rows' peeks were too, until
    /// 2026-11-28: full brightness now, trying.)
    static let peekAlpha: CGFloat = 0.8
    /// Rows waiting under a rigid billboard (Details) that don't peek.
    static let dimmedAlpha: CGFloat = 0.45
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
    /// TODAY'S PICK: one showcase card the content's width, as tall as
    /// the tall cards (600 pt looked short beside them).
    static let spotlightCard = CGSize(width: bannerWidth, height: showcaseCard.height)
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
    /// THE FOCUS GROWTH, every card everywhere: on its longer side, by the
    /// square root of that side — a bigger card grows more points but a
    /// smaller share — the tall cards `focusGrowth`, at most `focusGrowthCap`
    /// (the wide ones). (6 % of each card grew the tall ones 42, the squares
    /// 19; 33 pt on every card made the squares jump, 10 %.)
    static let focusGrowth: CGFloat = 33
    static let focusGrowthCap: CGFloat = 36
    /// That growth as a card's scale share.
    static func focusLift(_ size: CGSize) -> CGFloat {
        let side = max(size.width, size.height, 1)
        let points = min(focusGrowth * (side / max(showcaseCard.width, showcaseCard.height)).squareRoot(), focusGrowthCap)
        return points / side
    }
    /// Pressed, half of it back; held (its hold menu open), half more.
    static func pressDrop(_ size: CGSize) -> CGFloat { focusLift(size) / 2 }
    static func heldGrowth(_ size: CGSize) -> CGFloat { focusLift(size) / 2 }
    /// The text under cards (captions, the box's description): the base
    /// size (22 looked too small); the second line this far below the first.
    static let captionSize: CGFloat = 24
    static let captionLineOffset: CGFloat = 35
    /// Details' buttons while their hold menu is open: a little larger
    /// than focused.
    static let heldGrowth: CGFloat = 0.03
    /// How long the card takes to grow to that, the dim's hole with it.
    static let heldDuration: Double = 0.28
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
    /// A large row's posters and its open card (`FixedFocusFeatureLayout`):
    /// one height, the open card's right edge near the screen's middle.
    static let featurePoster = CGSize(width: 330, height: 495)
    static let featureCard = CGSize(width: 880, height: 495)
    /// Panels of cards' corners (the player's shelf).
    static let panelRadius: CGFloat = 32
    /// Under the box: the title's name, then its facts (meta) line.
    static let infoGap: CGFloat = 18
    static let factsOffset: CGFloat = 36
    static let factsHeight: CGFloat = 30
    /// The box (and a grown card) carries its text on the picture, left,
    /// from the foot up: the facts line, the logo over it, the badges over
    /// that (as a showcase card). Nothing under the box.
    static let footPad: CGFloat = 24
    static let factsGap: CGFloat = 10
    static func factsFrame(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: Spotlight.logoInset, y: height - footPad - factsHeight,
               width: width - 2 * Spotlight.logoInset, height: factsHeight)
    }
    static func styleFacts(_ label: UILabel) {
        label.font = FixedFocusText.infoFont(textSize)
        label.textColor = CueInk.ui(FixedFocusText.body)
        label.lineBreakMode = .byTruncatingTail
    }
    /// The logo's room, over the facts.
    static func logoRoom(width: CGFloat, height: CGFloat) -> CGRect {
        let room = height * 0.26
        return CGRect(x: Spotlight.logoInset, y: factsFrame(width: width, height: height).minY - factsGap - room,
                      width: width * 0.5, height: room)
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
        isContinue(rowIndex)
            || (rows.indices.contains(rowIndex) && landscapeRowIDs.contains(rows[rowIndex].id))
    }
    /// Destination rows: native scrolling, the system's lift, captions.
    /// A change rebuilds the rows
    /// at once — half-switched, a row showed both kinds of cards.
    var destinationRowIDs: Set<String> = [] {
        didSet {
            guard destinationRowIDs != oldValue, isViewLoaded else { return }
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
    /// Grids of their own cards (see `FixedFocusRows.gridRowIDs`).
    var gridRowIDs: Set<String> = []
    /// Laid out as a grid, all in view: Top 10's, or one of `gridRowIDs`.
    func isGrid(_ rowIndex: Int) -> Bool {
        isRanked(rowIndex) || (rows.indices.contains(rowIndex) && gridRowIDs.contains(rows[rowIndex].id))
    }
    /// A grid's line, its card and caption room.
    func gridLine(_ rowIndex: Int) -> CGFloat {
        destinationCard(rowIndex).height
            + (isRanked(rowIndex) || !hasCaptions(rowIndex) ? 0 : captionRoom(rowIndex))
    }
    /// A grid's lines in view: two; more move a line at a time.
    static let gridLinesShown = 2
    /// The first of a grid's lines in view: the focused line and the one
    /// before it (the first two at its start), the rest peeking as rows.
    func gridStart(_ rowIndex: Int) -> Int {
        guard isGrid(rowIndex), rows.indices.contains(rowIndex) else { return 0 }
        let columns = gridColumns(rowIndex)
        let lines = (rows[rowIndex].items.count + columns - 1) / columns
        guard lines > Self.gridLinesShown else { return 0 }
        let line = (selected[rows[rowIndex].id] ?? 0) / columns
        return min(max(0, line - 1), lines - Self.gridLinesShown)
    }
    /// Each grid's first line in view as last laid out.
    private var shownGridStart: [String: Int] = [:]
    /// A grid's cards across: portraits seven (as their rows), else five.
    func gridColumns(_ rowIndex: Int) -> Int {
        rows.indices.contains(rowIndex) && portraitRowIDs.contains(rows[rowIndex].id) ? 7 : 5
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
    /// cards in the screen's middle (Apple TV's)
    /// (nil: not centred, or the billboard).
    func centredDrop(_ r: Int) -> CGFloat? {
        guard centred, rows.indices.contains(r), !isFeatured(r) else { return nil }
        // (A Top 10's grid: with its name, so the rows above and below
        // both keep a peek.)
        let whole = isGrid(r)
        // A grid of more lines than shown: the two in view in the middle,
        // with its name while they're its first.
        let columns = gridColumns(r)
        if isGrid(r), (rows[r].items.count + columns - 1) / columns > Self.gridLinesShown {
            let start = gridStart(r), line = gridLine(r), gap = FixedFocusMetrics.gap
            let name = FixedFocusMetrics.titleHeight + titleExtra(r)
            let shown = CGFloat(Self.gridLinesShown) * line + CGFloat(Self.gridLinesShown - 1) * gap
            let content = (start == 0 ? name : 0) + shown
            let top = start == 0 ? 0 : name + CGFloat(start) * (line + gap)
            return ((1080 - content) / 2).rounded() - top - rowTop
        }
        let above = whole ? 0 : FixedFocusMetrics.titleHeight + titleExtra(r)
        // (A poster row's strip with its cards; the cards alone, not
        // their captions.)
        let content = whole ? drawnHeight(r) : cardHeight(r) - captionBelow(r)
        return ((1080 - content) / 2).rounded() - above - rowTop
    }
    /// Centred, how far the billboard goes up for the row under it: its
    /// edge (the screen's; Home's card's foot) `centredGap` over that
    /// row's name, as any row above the focused one.
    private var centredBillboardTravel: CGFloat? {
        guard let featured = featuredIndex, let drop = centredDrop(featured + 1) else { return nil }
        let edge = pinnedStage?.cardFrame?.maxY ?? 1080
        return edge - (rowTop + drop - FixedFocusMetrics.centredGap)
    }
    /// How far a focused row draws, from its name to the end of its cards.
    func drawnHeight(_ r: Int) -> CGFloat {
        FixedFocusMetrics.titleHeight + titleExtra(r) + cardHeight(r)
    }
    var showcaseTrailers: (on: Bool, sound: Bool) = (false, false) {
        didSet { if !showcaseTrailers.on { showcaseTrailer.rest(on: nil, sound: false) } }
    }
    let showcaseTrailer = StageTrailer()
    /// A trailer handed into Details: by then Details covers its card.
    private static let handOverCovered: Double = 1.5

    /// Today's Pick: its one card the content's width.
    var spotlightRowIDs: Set<String> = []

    func isSpotlight(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && spotlightRowIDs.contains(rows[rowIndex].id)
    }

    func isShowcase(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex) && showcaseRowIDs.contains(rows[rowIndex].id)
    }
    /// Poster rows as large landscape rows (Home): the focused card large
    /// at the spot, the rest small landscape cards (`FixedFocusFeatureLayout`).
    var featureRows = false

    func isFeature(_ rowIndex: Int) -> Bool {
        featureRows && isDestination(rowIndex) && !isFeatured(rowIndex) && !isBanner(rowIndex)
            && !isShowcase(rowIndex) && !isGrid(rowIndex) && !isContinue(rowIndex)
            && custom(rowIndex) == nil && !isLandscape(rowIndex) && !isLogo(rowIndex)
            && !(rows.indices.contains(rowIndex) && portraitRowIDs.contains(rows[rowIndex].id))
            // Saved for Later and the rewatch rows: plain posters, moving focus.
            && !isPlain(rowIndex)
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
        if isSpotlight(rowIndex) { return FixedFocusMetrics.spotlightCard }
        if isShowcase(rowIndex) { return FixedFocusMetrics.showcaseCard }
        if isFeature(rowIndex) { return FixedFocusMetrics.featureCard }
        // (A grid of logos: Top 10's squares.)
        if isLogo(rowIndex) { return isGrid(rowIndex) ? FixedFocusMetrics.rankedCard : FixedFocusMetrics.logoCard }
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
    /// Captions under the cards: everywhere but Home, where only the
    /// landscape rows (Continue Watching, New Episodes: the show over the
    /// episode's title), Saved for Later (when it was added) and the
    /// rewatch rows (when you finished it) have them.
    func hasCaptions(_ rowIndex: Int) -> Bool {
        !captionsOnCards(rowIndex) && (captions || isLandscape(rowIndex) || isPlain(rowIndex))
    }
    /// Plain posters with moving focus and a line under them: Saved for
    /// Later, the rewatch rows (`CueRows.CardShape.plain`).
    func isPlain(_ rowIndex: Int) -> Bool {
        rows.indices.contains(rowIndex)
            && (rows[rowIndex].id == HomeView.libraryRowID || rows[rowIndex].shape == .plain)
    }
    /// The room under a row's cards for their caption: two lines, one
    /// where no card has a second (the studios: two left a gap under the
    /// grid far larger than its one line). Landscape rows' second line
    /// is the episode's (`progress`, card states), not `subtitles`.
    func captionRoom(_ rowIndex: Int) -> CGFloat {
        let one = rows.indices.contains(rowIndex) && rows[rowIndex].subtitles.isEmpty
            && !isLandscape(rowIndex) && !isContinue(rowIndex)
        return FixedFocusMetrics.captionRoom - (one ? FixedFocusMetrics.captionLineOffset : 0)
    }
    /// A grid of portraits: names on the cards, not under them.
    func captionsOnCards(_ rowIndex: Int) -> Bool {
        isGrid(rowIndex) && !isRanked(rowIndex)
            && rows.indices.contains(rowIndex) && portraitRowIDs.contains(rows[rowIndex].id)
    }
    /// The room under a row's cards for their captions (in `cardHeight`).
    func captionBelow(_ r: Int) -> CGFloat {
        isDestination(r) && !isBanner(r) && !isShowcase(r) && !isRanked(r)
            && !isFeature(r) && custom(r) == nil && hasCaptions(r) ? captionRoom(r) : 0
    }
    /// The row's cards' height (a Top 10: its grid's).
    func cardHeight(_ rowIndex: Int) -> CGFloat {
        let caption = hasCaptions(rowIndex) ? captionRoom(rowIndex) : 0
        if let custom = custom(rowIndex) { return custom.height }
        return isBanner(rowIndex) ? bannerHeight
            : isSpotlight(rowIndex) ? FixedFocusMetrics.spotlightCard.height
            : isShowcase(rowIndex) ? FixedFocusMetrics.showcaseCard.height
            : isFeature(rowIndex) ? FixedFocusMetrics.featureCard.height
            : isRanked(rowIndex) ? FixedFocusGridLayout.height(card: FixedFocusMetrics.rankedCard.height,
                                                               count: rows[rowIndex].items.count)
            : isGrid(rowIndex) ? FixedFocusGridLayout.height(card: gridLine(rowIndex),
                                                             count: rows[rowIndex].items.count,
                                                             columns: gridColumns(rowIndex))
            : isDestination(rowIndex) ? destinationCard(rowIndex).height + caption
            : FixedFocusMetrics.height
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

    /// A change you made: rows held from before go in now (`UserAction`).
    @objc private func userActed() {
        guard let held = heldRows else { return }
        heldRows = nil
        update(held.rows)
    }

    /// Focus moved: held rows go in once it has left their row.
    private func applyHeldRows() {
        guard let held = heldRows else { return }
        if let index = rowHoldingFocus, rows.indices.contains(index), rows[index].id == held.rowID { return }
        heldRows = nil
        update(held.rows)
    }

    /// What a row shows is what Select acts on: a change you didn't make
    /// (a sync, a rebuild) waits in the row focus is in until focus leaves
    /// it (else a reordered Continue Watching showed one title and played
    /// another); every other row takes its new content at once. A change
    /// you made (`UserAction`: a hold menu's pick, back from the player)
    /// goes in at once there too, focus following the title acted on (by
    /// id, below), else on the card that took its place.
    func update(_ incoming: [HomeRow]) {
        var rows = incoming
        heldRows = nil
        var refocus: Int?
        if !startsOverOnChange, let index = rowHoldingFocus, !isFeatured(index), self.rows.indices.contains(index) {
            let shown = self.rows[index]
            if let at = rows.firstIndex(where: { $0.id == shown.id }), rows[at].contentKey != shown.contentKey {
                if UserAction.recent {
                    refocus = at
                } else {
                    rows[at] = shown
                    heldRows = (incoming, shown.id)
                }
            }
        }
        // Focus was in the row you changed: on its title (where it moved),
        // else the card in its place, once the change is laid out.
        defer { if let refocus, isViewLoaded { refocusAfterChange(refocus) } }
        // A row's titles changed: its selected title kept by id; gone (taken
        // out), the one after it in its place, the last at the end (an index
        // past the row's end left focus nowhere to land: Up and Down passed
        // the row by).
        for row in rows {
            guard let was = self.rows.first(where: { $0.id == row.id }), was.contentKey != row.contentKey,
                  let index = selected[row.id] else { continue }
            if was.items.indices.contains(index),
               let now = row.items.firstIndex(where: { $0.id == was.items[index].id }) {
                if now != index { selected[row.id] = now }
            } else {
                selected[row.id] = row.items.isEmpty ? nil : min(index, row.items.count - 1)
            }
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
        startOnRowIfAsked()
    }

    private func refocusAfterChange(_ index: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.rows.indices.contains(index) else { return }
            self.outer.layoutIfNeeded()
            self.requestFocus(row: index)
        }
    }

    /// Dev (`-homeFocusRow`): start on a row.
    private var pendingFocusRow: Int?
    private var startedOnRow = false

    private func startOnRowIfAsked() {
        // (`-homeFocusRow N`: start on row N; `last`: the bottom row.)
        let args = ProcessInfo.processInfo.arguments
        let value = args.firstIndex(of: "-homeFocusRow").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let wantsLast = value == "last"
        let asked = wantsLast ? rows.indices.last : value.flatMap { Int($0) }
        guard !startedOnRow,
              let index = asked.flatMap({ rows.indices.contains($0) ? $0 : nil })
        else { return }
        startedOnRow = true
        // After the launch's curtain (under it, the gate took the focus
        // update and Home's lift sent focus to the billboard).
        Task { @MainActor [self] in
            await LaunchPreloader.shared.lifted()
            try? await Task.sleep(for: .milliseconds(600))
            // `last` by the rows then (they may have grown since).
            let index = wantsLast ? rows.indices.last ?? index : index
            focusedRow = index
            onDepth(depth(of: index))
            applyDimming()
            outer.collectionViewLayout.invalidateLayout()
            outer.layoutIfNeeded()
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
    /// Something over the page took focus without deactivating it (the
    /// stage): coming back, focus goes to the row it left, not the first
    /// card on screen.
    static func keepReturnRows() {
        for controller in all.allObjects where controller.isViewLoaded && controller.view.window != nil
            && controller.view.isUserInteractionEnabled && controller.returnRow == nil {
            controller.returnRow = controller.focusedRow
        }
    }

    /// …and once it's gone, focus sent there: on the TV it landed on the
    /// top bar (outside the rows, where `returnRow` never redirects).
    static func returnFocus() {
        for controller in all.allObjects where controller.isViewLoaded && controller.view.window != nil
            && controller.view.isUserInteractionEnabled {
            guard let row = controller.returnRow else { continue }
            controller.returnFocus(row: row, tries: 6)
        }
    }

    /// Asked again until focus is in the rows: while the page that had it
    /// is still on screen (the stage, gone a frame later) the request is
    /// refused, and focus then fell to the top bar.
    private func returnFocus(row: Int, tries: Int) {
        requestFocus(row: row)
        let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
        guard focused?.isDescendant(of: view) != true, tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.returnFocus(row: row, tries: tries - 1)
        }
    }

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
               let cell = rowCell.posterCell(at: min(selected[rows[index].id] ?? 0, max(rows[index].items.count - 1, 0))) {
                return [cell]
            }
        }
        return super.preferredFocusEnvironments
    }

    /// Its rows' pictures let go while the player is up (`PictureRelease`).
    private var releasedForPlayer = false
    @objc private func releaseForPlayer() {
        guard isViewLoaded, PictureRelease.outOfSight(view) else { return }
        releasedForPlayer = true
        for case let cell as FixedFocusRowCell in outer.visibleCells { cell.setArtHeld(false) }
    }
    @objc private func restoreAfterPlayer() {
        guard releasedForPlayer else { return }
        releasedForPlayer = false
        for case let cell as FixedFocusRowCell in outer.visibleCells { cell.setArtHeld(true) }
    }

    override func loadView() {
        Self.all.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseForPlayer),
                                               name: PictureRelease.release, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreAfterPlayer),
                                               name: PictureRelease.restore, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userActed),
                                               name: UserAction.acted, object: nil)
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
        layout.belowCards = { [weak self] in self?.captionBelow($0) ?? 0 }
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
        // Along the bottom edge, below the billboard's (invisible) cells.
        root.addLayoutGuide(belowGuide)
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

    /// A row gone from view lets its cards' pictures go: parked for reuse
    /// it kept them (700 MB after a short browse). Shown again, it's
    /// configured anew and they come back from the image cache.
    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? FixedFocusRowCell)?.setArtHeld(false)
    }

    /// A row coming into view mid-animation gets its dimming too.
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        cell.contentView.alpha = rowAlpha(indexPath.item)
        // Shown again without being dequeued: its pictures back.
        if let row = cell as? FixedFocusRowCell, !row.artHeld { row.setArtHeld(true) }
        (cell as? FixedFocusRowCell)?.concealed = rowConcealed(indexPath.item)
        (cell as? FixedFocusRowCell)?.titleAlpha = titleAlpha(indexPath.item)
    }

    /// Focus moved (natively). Left/Right: the box stays, its content
    /// changes, the row slides behind it. Up/Down ("opening a book"): the
    /// box steps aside, the new row's title grows into the box as the rows
    /// move up; at the end the box takes over again, in the same place.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Arriving from elsewhere (Details pushed over the card pressed;
        // the engine asks nothing first) with the billboard's focus outside
        // the rows: on to its buttons, not the episode nearest the old focus
        // by position — no move of the rows.
        if billboardFocusOutside, context.focusHeading.isEmpty,
           context.previouslyFocusedView?.isDescendant(of: view) != true,
           context.nextFocusedView?.isDescendant(of: outer) == true {
            focusBillboardOutside()
            return
        }
        if heldRows != nil { DispatchQueue.main.async { self.applyHeldRows() } }
        // Home's billboard card: grown while focus is on it (its hidden
        // cards; a hold menu over it keeps it so).
        if !HoldMenu.shared.isOpen {
            let rows = [context.previouslyFocusedView, context.nextFocusedView]
                .map { $0.flatMap { Self.rowCell(containing: $0) }?.rowIndex }
            // Between the billboard and the rows, it grows (or shrinks) as
            // part of the scroll — in its move, as a row's grown card is
            // part of the rows' (on its own 0.3 s spring beside the scroll's
            // 0.6 the gap closed on two clocks). To and from the top bar:
            // focus's.
            setBillboardLit(rows[1].map { isFeatured($0) } ?? false,
                            inScroll: rows[0] != nil && rows[1] != nil && rows[0] != rows[1])
        }
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
            return
        }
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
        restShowcase(on: (context.nextFocusedView as? FixedFocusShowcaseCell).flatMap { $0.plays ? $0 : nil })
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
        if fromOutside, hasFocus, rowIndex == focusedRow, itemIndex == selected[row.id], featured {
            return
        }
        let rowChanged = rowIndex != focusedRow || !hasFocus
        let direction: CGFloat = rowChanged
            ? (rowIndex > focusedRow ? 1 : -1)
            : (itemIndex >= (selected[row.id] ?? 0) ? 1 : -1)
        let oldRowCell = rowChanged
            ? outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell : nil
        // Between the billboard and the rows: ONE SCROLL — the picture goes
        // up a whole screen while the rows rise from just below the screen,
        // where they wait under the billboard (no jump first).
        let billboardScroll = rowChanged && hasFocus && (featured != isFeatured(focusedRow))
        if featured {
            // The billboard's picture: the title's, drifting on Left/Right.
            rowCell.showStage(item, direction: direction, animated: !rowChanged)
            if !rowChanged { dipBillboardCard() }
        }
        if billboardScroll, !featured, rigidRest == nil { sendRowsBelowAway() }
        // Up: the rows sink a whole scroll, with the picture.
        if billboardScroll, featured, rigidRest == nil { belowAway = true }
        selected[row.id] = itemIndex
        focusedRow = rowIndex

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
        // Up/Down moves much more than a step: its own, longer spring.
        let duration = billboardScroll ? FixedFocusMotion.billboardScroll
            : rowChanged ? Motion.verticalDuration : Motion.moveDuration
        // Down from the billboard: the rows show at once (the move is the
        // scroll, not a fade); Up hides them as they sink back.
        let move = {
            let id = self.beginMove()
            FixedFocusMotion.run(duration: duration) {
                self.applyDimming()
                oldRowCell?.relayout()
                rowCell.focus(index: itemIndex)
                // The row list doesn't scroll: its layout places every row
                // around the focused one, and the rows glide to their places.
                self.outer.collectionViewLayout.invalidateLayout()
                self.outer.layoutIfNeeded()
                self.applyPageHeaderPosition()
                // The billboard by the rows' new layout (`billboardUp`).
                self.applyOverlayPosition()
            } completion: { _ in
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
                if !self.isMoving { self.landBack() }
                self.runHeldSelect()
            }
            if billboardScroll { self.liftNextTitle(down: !featured) }
        }
        // A Select held for the move before: focus has moved on, it's gone.
        heldSelect = nil
        move()
        hasFocus = true
        loadShowInfo(for: item, in: row, at: itemIndex)
    }

    /// Moves (Up/Down, Left/Right) still running in the rows; a hurry
    /// (`hurryMoves`) empties it, so their own completions do nothing.
    private var liveMoves: Set<Int> = []
    private var lastMoveID = 0
    private var isMoving: Bool { !liveMoves.isEmpty }
    private func beginMove() -> Int {
        lastMoveID += 1
        liveMoves.insert(lastMoveID)
        holdNewRows()
        return lastMoveID
    }
    /// Rows coming into the list in this move, off screen, are made just
    /// after it has started (`FixedFocusRowsLayout.holding`): the move is
    /// with Core Animation by then, so it runs on while they're made.
    /// (After the press's commit: a main-queue block can run before it.)
    private var holdToken = 0
    private func holdNewRows() {
        guard let layout = outer.collectionViewLayout as? FixedFocusRowsLayout else { return }
        if layout.holding == nil { layout.holding = Set(outer.indexPathsForVisibleItems.map(\.item)) }
        holdToken += 1
        let token = holdToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, token == self.holdToken, layout.holding != nil else { return }
            layout.holding = nil
            UIView.performWithoutAnimation {
                layout.invalidateLayout()
                self.outer.layoutIfNeeded()
            }
        }
    }
    /// False for a move already counted done (hurried).
    private func endMove(_ id: Int) -> Bool { liveMoves.remove(id) != nil }
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
            } else if isFeature(index) {
                // A large row's open card, as its box loads it
                // (`FixedFocusShowcaseCell.wantBackdrop`): left out, the
                // first visit opened a dark card until its backdrop came.
                let art = rows[index].art[item.id] ?? item.poster ?? item.background
                wants.append(.init(item.background ?? art, PictureSize.openCard))
                wants.append(.init(item.logo, PictureSize.cardLogo))
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

    /// A hurried move's rest in this much time, from where it is now.
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
            rows.hurryMoves {}
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hurryDuration) {
            CATransaction.flush()
            DispatchQueue.main.asyncAfter(deadline: .now() + drawnDelay, execute: run)
        }
    }

    /// Details opening: focus to its buttons (its billboard's, outside the
    /// rows) — by position the engine took the episodes or the seasons
    /// nearer the card pressed. False with no such rows on screen.
    static func focusDetailsButtons() -> Bool {
        guard let rows = all.allObjects.first(where: { $0.billboardFocusOutside && $0.view.window != nil })
        else { return false }
        rows.focusBillboardOutside(tries: 6)
        return true
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

    private var pendingFocusCell: UIView?

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
        hasFocus = true
        // (Along a grid onto a line out of view: the page moves a line.)
        let gridID = rows.indices.contains(rowIndex) ? rows[rowIndex].id : ""
        let gridMoved = isGrid(rowIndex) && shownGridStart[gridID] != gridStart(rowIndex)
        shownGridStart[gridID] = gridStart(rowIndex)
        guard rowChanged || gridMoved else { return }
        let oldRowCell = outer.cellForItem(at: IndexPath(item: focusedRow, section: 0)) as? FixedFocusRowCell
        if fromBillboard, rigidRest == nil { sendRowsBelowAway() }
        focusedRow = rowIndex
        let duration = fromBillboard ? FixedFocusMotion.billboardScroll : Motion.verticalDuration
        let move = {
            let id = self.beginMove()
            FixedFocusMotion.run(duration: duration) {
                self.applyDimming()
                oldRowCell?.relayout()
                self.outer.collectionViewLayout.invalidateLayout()
                self.outer.layoutIfNeeded()
                self.applyPageHeaderPosition()
                // The billboard by the rows' new layout (`billboardUp`).
                self.applyOverlayPosition()
            } completion: { _ in
                guard self.endMove(id) else { return }
                if !self.isMoving { self.landBack() }
                self.runHeldSelect()
            }
            if fromBillboard { self.liftNextTitle(down: true) }
        }
        move()
    }

    /// The title you rest on, its records brought up to date. (The ones
    /// focus can reach next: `TitleExtras`.)
    private var infoLoading: Task<Void, Never>?

    private func loadShowInfo(for item: MetaItem, in row: HomeRow, at index: Int) {
        infoLoading?.cancel()
        infoLoading = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            _ = await TitleRecords.shared.refresh(item, [.show, .facts, .ratings])
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
            // Its own, short (the title's entries are in Details): play
            // (Start Over only once started; Select resumes), Go to, the
            // mark, the removal last (red: no menu brings it back).
            let series = entry.season != nil
            let own = { (action: ContinueMenuAction) in
                MenuEntry(title: action.title(series: series), icon: action.icon,
                          destructive: action == .remove) { onContinueMenu(action, entry) }
            }
            var entries: [MenuEntry] = []
            if entry.isStarted { entries.append(own(.startOver)) }
            entries += [own(.chooseSource), own(.details), own(.markWatched), own(.remove)]
            return (entry.name, entries)
        }
        // Not the billboards (Search's Top Result; Home's as a card has
        // one, as every card) or folders.
        guard let titleMenu, !isFeatured(rowIndex) || pinnedStage?.cardFrame != nil,
              !isBanner(rowIndex) else { return nil }
        return (item.name, titleMenu(item, row.id))
    }

    /// Gives SwiftUI hosted in a cell the app's stores.
    var environment: (AnyView) -> AnyView = { $0 }

    /// Where a row's first card sits on the screen (window points) while the
    /// row is at the spot.
    func restingCardOrigin(_ rowIndex: Int) -> CGPoint? {
        guard isViewLoaded, view.window != nil else { return nil }
        return view.convert(CGPoint(x: FixedFocusMetrics.inset,
                                    y: rowTop + (rowIndex == focusedRow ? rowDrop : 0)
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
    var rigidNameY: CGFloat?
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
    var rigidBillboardTravel: CGFloat?
    var billboardCard: CGRect?
    var billboardCardFocus = false
    var billboardFull = false {
        didSet {
            guard billboardFull != oldValue, isViewLoaded, let stage = pinnedStage else { return }
            let full = billboardFull
            stage.setFullScreen(full)
            let fade = StagePictureView.fullPartsFade
            let shrink = DetailTransition.shrinkTime
            UIView.animate(withDuration: fade, delay: full ? 0 : shrink - fade,
                           options: [.curveEaseInOut, .beginFromCurrentState]) {
                for part in [self.outer, self.overlayHost?.view, self.controlsHost?.view].compactMap({ $0 }) {
                    part.alpha = full ? 0 : 1
                }
            }
        }
    }
    var billboardPicture: String? {
        didSet {
            guard billboardPicture != oldValue, let stage = pinnedStage, let featured = featuredIndex,
                  let item = rows[featured].items.first else { return }
            stage.show(billboardPicture, item: item, direction: 0, animated: false)
        }
    }
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
            // Deeper: as far again as the row under it has gone up since
            // (rows differ in height: by one pitch a row, the billboard and
            // the rows travelled different distances, the gap between them
            // breathing mid-move — printed on one sheet, they don't).
            if depth > 1, let featured = featuredIndex,
               let layout = outer.collectionViewLayout as? FixedFocusRowsLayout,
               let rest = layout.rowTop(featured + 1, focus: featured + 1),
               let top = layout.rowTop(featured + 1, focus: featured + depth) {
                return travel + rest - top
            }
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
                billboardShadow?.removeFromSuperview()
                billboardShadow = nil
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
        stage.cardFrame = billboardCard
        if billboardCardFocus { StagePictureView.homeCardShown = stage }
        stage.text = billboardPageText.map { text in { [weak self] in self?.environment(text($0)) ?? text($0) } }
        view.insertSubview(stage, at: 0)
        stage.bounds = CGRect(origin: .zero, size: StagePictureView.pictureSize)
        stage.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        pinnedStage = stage
        if billboardCardFocus, let card = stage.cardFrame {
            // Home's card: focused, the cards' soft shadow (the picture is
            // masked to the card: it can't hold it). A screen-sized layer
            // under it, moved, grown and dipped as it is.
            let holder = UIView(frame: stage.frame)
            holder.isUserInteractionEnabled = false
            holder.alpha = 0
            let image = FixedFocusCardEdge.shadowImage
            let caps = image.capInsets, size = image.size
            let shadow = UIView(frame: card.insetBy(dx: -FixedFocusCardEdge.shadowPad, dy: -FixedFocusCardEdge.shadowPad))
            shadow.layer.contents = image.cgImage
            shadow.layer.contentsScale = image.scale
            shadow.layer.contentsCenter = CGRect(x: caps.left / size.width, y: caps.top / size.height,
                                                 width: max(0, size.width - caps.left - caps.right) / size.width,
                                                 height: max(0, size.height - caps.top - caps.bottom) / size.height)
            holder.addSubview(shadow)
            view.insertSubview(holder, belowSubview: stage)
            billboardShadow = holder
        }
    }
    /// Home's card's focus shadow (`makePinnedStage`).
    private var billboardShadow: UIView?

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
                .scaledBy(x: cardScale, y: cardScale)
            billboardShadow?.transform = stage.transform
            billboardShadow?.alpha = billboardLit ? 1 : 0
            stage.cardLit = billboardLit
            // Home's top bar with the card — set here, in the same
            // animation, so it moves as printed on the page with it. Its
            // place, not its growth (following the top edge as it grew,
            // the bar stepped up and down as focus came and went), nor the
            // paging dip (it would bob).
            if billboardCardFocus { TopBarFollow.shared.set(stage.transform.ty) }
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
        // On the billboard's picture: dark in both appearances (`CueInk`).
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        // (Its own safe area off: it's laid out in screen points, as the rows.)
        host.safeAreaRegions = []
        // Details' info block: hidden until it rises in (`DetailTransition`).
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
        host.overrideUserInterfaceStyle = .dark
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

    /// HOME'S BILLBOARD CARD focused: grown as every card (the wide ones'
    /// growth on its width), its dots with it.
    private var billboardLit = false
    /// Held (its hold menu open): half its focus growth more, as every card.
    private var billboardHeld = false
    /// Select down on it: a little less grown, as every card (the press
    /// reaches the hidden focus cell, not the card).
    private var billboardPressed = false
    private var cardScale: CGFloat {
        guard billboardLit, let card = pinnedStage?.cardFrame else { return 1 }
        return 1 + FixedFocusMetrics.focusLift(card.size)
            - (billboardPressed ? FixedFocusMetrics.pressDrop(card.size) : 0)
            + (billboardHeld ? FixedFocusMetrics.heldGrowth(card.size) : 0)
    }

    /// The cards' press timing (`FixedFocusDestinationCell.setPressed`).
    private func setBillboardPressed(_ pressed: Bool) {
        guard pressed != billboardPressed, !pressed || (billboardLit && isFeatured(focusedRow)) else { return }
        billboardPressed = pressed
        UIView.animate(withDuration: pressed ? 0.12 : 0.2, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.applyOverlayPosition()
        }
    }

    /// Home's card at `scale` (window points), where it is now.
    private func billboardCardRect(scale: CGFloat) -> CGRect? {
        guard let stage = pinnedStage, let card = stage.cardFrame, let featured = featuredIndex else { return nil }
        let up = billboardUp(depth: max(focusedRow - featured, 0))
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: stage.center.x + (p.x - stage.bounds.midX) * scale,
                    y: stage.center.y - up + (p.y - stage.bounds.midY) * scale)
        }
        let a = place(card.origin), b = place(CGPoint(x: card.maxX, y: card.maxY))
        return view.convert(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), to: nil)
    }

    /// Its hold menu: the card itself held (not the hidden focus cell), the
    /// panel over its right as Today's Pick's (too wide for a side).
    fileprivate func billboardHoldMenu(_ entries: [MenuEntry]) -> HoldMenuRequest? {
        guard billboardLit, let size = pinnedStage?.cardFrame?.size else { return nil }
        let lit = 1 + FixedFocusMetrics.focusLift(size)
        guard let held = billboardCardRect(scale: lit + FixedFocusMetrics.heldGrowth(size)),
              let now = billboardCardRect(scale: cardScale),
              let rest = billboardCardRect(scale: lit) else { return nil }
        return HoldMenuRequest(entries: entries, anchor: held, from: now, rest: rest,
                               onHeld: { [weak self] in self?.setBillboardHeld($0) },
                               inside: Self.billboardMenuInset)
    }
    static let billboardMenuInset: CGFloat = 32

    private func setBillboardHeld(_ held: Bool) {
        guard held != billboardHeld else { return }
        billboardHeld = held
        billboardPressed = false
        UIView.animate(withDuration: FixedFocusMetrics.heldDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            self.applyOverlayPosition()
        }
    }

    /// A page on Home's card: it dips to its resting size, its
    /// text and dots with it (the picture alone, the text still, felt
    /// disconnected) — down quickly (`dipDown`), up slowly (`dipUp`): the
    /// drop reads as the press, the rise is calm. A press while it's low
    /// or rising goes back down from where it is and rises again, so quick
    /// paging is one dip, not a bounce a press. (All the way down and up on one
    /// 0.35 s curve, as the large rows' box, was heavy on so large a card;
    /// a third faint and bobbing; half too faint.) (Lit only on the billboard,
    /// at its place: grown is a plain scale.)
    static let dipDepth: CGFloat = 1
    static let dipDown: Double = 0.12
    static let dipUp: Double = 0.4
    /// The running dip, to start the next from where it is.
    private var dipRun: (start: CFTimeInterval, from: CGFloat, low: CGFloat, down: Double)?
    /// The dip's own factor now (1: none), on its two eased legs.
    private func dipFactor(at time: CFTimeInterval) -> CGFloat {
        guard let run = dipRun else { return 1 }
        let t = time - run.start
        if t < run.down {
            let p = CGFloat(t / run.down)
            return run.from + (run.low - run.from) * (1 - (1 - p) * (1 - p))
        }
        let p = CGFloat(min(1, (t - run.down) / Self.dipUp))
        return run.low + (1 - run.low) * (p * p * (3 - 2 * p))
    }

    /// Added onto the card's own transform (a scale relative to it), so the
    /// dip rides on whatever else moves it: a page while the rows are still
    /// scrolling to the billboard (replacing the transform dropped the
    /// scroll: the card jumped to its place, then the scroll went on).
    private func dipBillboardCard() {
        guard billboardLit, let stage = pinnedStage, stage.cardFrame != nil else { return }
        let grown = cardScale
        let low = (1 + (grown - 1) * (1 - Self.dipDepth)) / grown
        let clock = CACurrentMediaTime()
        let now = dipFactor(at: clock)
        // Down only as far as it still has to go.
        let left = low < 1 ? max(0, min(1, (now - low) / (1 - low))) : 1
        let down = Self.dipDown * Double(left)
        dipRun = (clock, now, low, down)
        let dip = CAKeyframeAnimation(keyPath: "transform")
        dip.isAdditive = true
        dip.values = [now, low, 1].map { CATransform3DMakeScale($0, $0, 1) }
        dip.keyTimes = [0, NSNumber(value: down / (down + Self.dipUp)), 1]
        dip.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        dip.duration = down + Self.dipUp
        for layer in [stage.layer, overlayHost?.view.layer, billboardShadow?.layer].compactMap({ $0 }) {
            layer.add(dip, forKey: "dip")
        }
    }

    private func setBillboardLit(_ lit: Bool, inScroll: Bool = false) {
        guard lit != billboardLit, billboardCardFocus, pinnedStage?.cardFrame != nil else { return }
        billboardLit = lit
        if !lit { billboardPressed = false; billboardHeld = false }
        // The scroll's move places it (`applyOverlayPosition`), grown or not.
        if inScroll { return }
        UIView.animate(springDuration: Motion.focusDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.applyOverlayPosition()
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
            moved.transform = CGAffineTransform(translationX: 0, y: -scroll)
                .scaledBy(x: moved === overlayHost?.view ? cardScale : 1, y: moved === overlayHost?.view ? cardScale : 1)
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
        if presses.contains(where: { $0.type == .select }) { setBillboardPressed(true) }
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
        if presses.contains(where: { $0.type == .select }) { setBillboardPressed(false) }
        if arrow(presses) != nil { holdTimer?.invalidate(); holdTimer = nil }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { setBillboardPressed(false) }
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

    /// Nothing moving in the rows.
    private var settled: Bool { !isMoving }
    /// A Select during a move: held, run as the move lands; the move
    /// finishes quickly first (`hurryMoves`).
    private var heldSelect: (() -> Void)?
    /// At the latest (a move whose end never came).
    static let heldSelectLimit: Double = 1

    private func runHeldSelect() {
        guard settled, let run = heldSelect else { return }
        heldSelect = nil
        // The landed rows drawn first: Details starts from a still of the
        // screen as last drawn.
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drawnDelay, execute: run)
    }
    /// Two frames.
    static let drawnDelay: Double = 2.0 / 60

    private var heldSelectToken = 0

    func select(_ pressed: MetaItem, rowIndex: Int) {
        // (Back's scroll up running: dropped, as a move.)
        guard !backing else { return }
        // The billboard: the title it shows. Paged by itself (`page`), its
        // hidden cards jump but focus stays on the card it had: Select
        // opened that one, the first title.
        var item = pressed
        if isFeatured(rowIndex), rows.indices.contains(rowIndex),
           let shown = selected[rows[rowIndex].id], rows[rowIndex].items.indices.contains(shown) {
            item = rows[rowIndex].items[shown]
        }
        // A showcase card's trailer: playing, it goes on into Details
        // (`perform`); still to come, it stops at the press.
        if showcaseTrailer.playingTitle != item.id { restShowcase(on: nil) }
        guard settled || ModeSwap.shared.handingOver else {
            heldSelectToken += 1
            let token = heldSelectToken
            heldSelect = { [weak self] in self?.perform(item, rowIndex: rowIndex) }
            // The move finishing quickly.
            if isMoving { hurryMoves { self.runHeldSelect() } }
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
            // A card playing its trailer: it goes on into Details (the
            // opening plays it, Details takes it — `StageTrailer.adopt`).
            // The card lets go of the picture once Details covers it (its
            // player is Details' now: stopped there, it would leave the card black).
            if showcaseTrailer.playingTitle == item.id,
               let carried = showcaseTrailer.handOver(from: (showcaseTrailer.stage as? FixedFocusShowcaseCell)?.screenCard) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.handOverCovered) { [weak self] in
                    guard let self, self.showcaseTrailer.surface.player === carried else { return }
                    self.showcaseTrailer.stop()
                }
            }
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
            // Rigid: the row peeking under it (`rigidPeek`) at full
            // brightness; the others waiting there dimmed.
            if rigidPeek != nil, isNext(rowIndex) { return 1 }
            return rigidRest != nil && !isFeatured(rowIndex) ? FixedFocusMetrics.dimmedAlpha : 1
        }
        // (Rows out of focus, peeking above and below: full brightness,
        // trying 2026-11-28; 80 % was before.)
        return 1
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
        let buttons = StagePictureView.detailsButtonsY + TitleBlock.buttonHeight + Self.nameButtonsMargin
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

/// A header's button (Details' seasons): the top bar's tab, its look,
/// focus and timing (`TopNavFocus`) — moving focus along the header
/// switches season, as along the bar. Select: down into the row.
final class FixedFocusHeaderButton: UIView {
    weak var rowCell: FixedFocusRowCell?
    let label: String
    let index: Int
    static let height = GlassSidebar.topBarItemHeight
    static let spacing = GlassSidebar.itemSpacing
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
        // Focus's growth and timing are the face's (`TopNavFocus`); a
        // press takes it back to its resting size, quick in, on a spring out.
        let scale = pressed ? 1 / DetailActionButton.focusScale : 1
        if pressed {
            UIView.animate(withDuration: DetailActionButton.pressInTime, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
            return
        }
        guard transform != .identity else { return }
        UIView.animate(withDuration: released ? 0.3 : TopNavFocus.leaveTime, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = .identity
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

/// A season button's face (see `FixedFocusHeaderButton`): a top bar
/// tab's (`TopNavFocus`) — the row's season at primary on the flat grey
/// pill, the others at secondary, page ink.
struct FixedFocusSeasonFace: View {
    let label: String
    let lit: Bool
    let selected: Bool

    var body: some View {
        Text(label)
            .font(.system(size: GlassSidebar.textSize, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, GlassSidebar.slotPadding)
            .frame(height: FixedFocusHeaderButton.height)
            .modifier(TopNavFocus(lit: lit,
                                  rest: CueInk.color(selected ? FixedFocusText.primary : FixedFocusText.secondary),
                                  pill: selected))
            .animation(.easeOut(duration: 0.18), value: selected)
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
    /// A symbol before `right` (the episode rows' day: a grey calendar).
    var rightSymbol: FixedFocusBadges.Symbol? = nil
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

    /// A picture's key in memory and how it's decoded: by its longest side
    /// (`maxDimension`, points), or to cover a card (`fill`, points).
    @MainActor
    static func sizing(_ url: String, maxDimension: CGFloat, fill: CGSize?)
        -> (key: String, budget: CGFloat?, fill: CGSize?) {
        guard let fill else {
            return (RemoteImage.memoryKey(url, maxDimension: maxDimension, maxPixels: nil),
                    RemoteImage.pixelBudget(maxDimension: maxDimension, maxPixels: nil), nil)
        }
        let scale = UIScreen.main.scale
        let pixels = CGSize(width: (fill.width * scale).rounded(.up), height: (fill.height * scale).rounded(.up))
        return ("\(url)#\(Int(pixels.width))x\(Int(pixels.height))", nil, pixels)
    }

    /// A card's picture decoded into memory under the key the card reads
    /// (as `load`): on screen from the card's first frame.
    @MainActor
    static func preload(_ url: String, maxDimension: CGFloat, fill: CGSize?) async {
        let (key, budget, fillPixels) = sizing(url, maxDimension: maxDimension, fill: fill)
        if ImageCache.shared.image(for: key) != nil { return }
        if await ImageCache.shared.diskImage(for: url, budget: budget, fill: fillPixels, memoryKey: key) != nil { return }
        guard let remote = URL(string: url), let data = try? await ImageCache.shared.download(remote),
              let image = await DecodeGate.shared.run(.now, {
                  ImageCache.decodeDownsampled(data, budget: budget, fill: fillPixels)
              }) else { return }
        ImageCache.shared.insert(image, for: url, data: data, memoryKey: key)
    }

    /// A card's picture on disk at the size the card reads, not decoded
    /// into memory (the launch's further rows).
    @MainActor
    static func keepOnDisk(_ url: String, maxDimension: CGFloat, fill: CGSize?) async {
        let (key, budget, fillPixels) = sizing(url, maxDimension: maxDimension, fill: fill)
        await ImageCache.shared.keepOnDisk(url, key: key, budget: budget, fill: fillPixels)
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
        }
    }

    /// `image` into `view`; a logo without its empty edges (as the
    /// billboard's), trimmed off the main thread the first time
    /// (`LogoFit.trimmedInBackground`): in once it's made, if still wanted.
    @MainActor
    private static func show(_ image: UIImage?, in view: UIImageView, key: String, url: String,
                             waiting: ((Bool) -> Void)?) {
        guard let image, view is FixedFocusLogo else {
            view.image = image
            waiting?(false)
            return
        }
        if let trimmed = LogoFit.cachedTrim(key: key) {
            view.image = trimmed
            waiting?(false)
            return
        }
        view.image = nil
        let slot = ObjectIdentifier(view)
        Task { @MainActor [weak view] in
            let trimmed = await LogoFit.trimmedInBackground(image, key: key)
            guard let view, requested[slot] == url else { return }
            view.image = trimmed
            waiting?(false)
        }
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
    static func load(_ url: String?, into view: UIImageView, maxDimension: CGFloat, fill: CGSize? = nil,
                     waiting: ((Bool) -> Void)? = nil) {
        let slot = ObjectIdentifier(view)
        requested[slot] = url
        guard let url else { view.image = nil; waiting?(false); return }
        let (memoryKey, budget, fillPixels) = sizing(url, maxDimension: maxDimension, fill: fill)
        if let hit = ImageCache.shared.image(for: memoryKey) {
            show(hit, in: view, key: memoryKey, url: url, waiting: waiting)
            return
        }
        view.image = nil
        waiting?(true)
        // Dropped, not decoded, once the view has asked for another
        // (a held Left/Right: the box has moved on).
        let still: @MainActor () -> Bool = { requested[slot] == url }
        Task { @MainActor [weak view] in
            var image = await ImageCache.shared.diskImage(for: url, budget: budget, fill: fillPixels,
                                                          memoryKey: memoryKey, still: still)
            if image == nil, still(), let remote = URL(string: url),
               let data = await ImageCache.shared.downloadRetrying(remote, still: still) {
                // Off the main thread (it decoded here, mid-scroll).
                image = await DecodeGate.shared.run(.now) {
                    ImageCache.decodeDownsampled(data, budget: budget, fill: fillPixels)
                }
                // In memory too (under the same key a SwiftUI RemoteImage of
                // this size uses): the Detail page opened from the billboard
                // shows the very same picture from its first frame.
                // Not stored when it doesn't decode: on disk it passed
                // for the picture.
                if let image { ImageCache.shared.insert(image, for: url, data: data, memoryKey: memoryKey) }
            }
            guard let view, requested[slot] == url else { return }
            // None after every try: the placeholder stays (the card
            // made again tries anew), not an empty card inside its edge.
            guard let image else { return }
            show(image, in: view, key: memoryKey, url: url, waiting: waiting)
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
        // A bottom fade under the words (the box's, a tall card's), Apple
        // TV's: the picture undimmed down to its middle, then eased dark
        // into the foot (from the upper third, half dark by the middle,
        // dimmed the whole card).
        let gradient = layer as! CAGradientLayer
        gradient.colors = [0, 0.3, 0.65, 0.85].map { UIColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0.45, 0.65, 0.85, 1]
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
                tintColor = CueInk.ui(FixedFocusText.primary)
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
    private let title = UILabel()
    private let strip: UICollectionView
    private var row: HomeRow? {
        guard let controller, controller.rows.indices.contains(rowIndex) else { return nil }
        return controller.rows[rowIndex]
    }
    private var selectedIndex: Int { row.flatMap { controller?.selected[$0.id] } ?? 0 }
    /// Focus kept at the first card's spot (`FixedFocusRows.anchoredRowIDs`).
    var isAnchored: Bool { row.map { controller?.anchoredRowIDs.contains($0.id) == true } ?? false }
    /// Only the focused row has a grown cell; the others are all posters.
    private var isFocusRow: Bool { controller?.focusedRow == rowIndex }

    /// A moving-focus row's captions only while it has focus: rows above
    /// and below show only their cards (`hasCaptions`).
    private var captionsShown: Bool { isFocusRow && controller?.hasCaptions(rowIndex) == true }
    func applyCaptions() {
        guard let destinationStrip else { return }
        for case let card as FixedFocusDestinationCell in destinationStrip.visibleCells {
            card.setCaptionShown(captionsShown)
            card.setDetailsShown(isFocusRow, animated: true)
        }
        // The cards' badges, rating and facts only in the focused row.
        for case let card as FixedFocusShowcaseCell in destinationStrip.visibleCells {
            card.setDetailsShown(isFocusRow, animated: true)
        }
        box?.setDetailsShown(isFocusRow, animated: true)
    }


    /// Continue Watching: landscape cards (its progress, Select resumes).
    var isContinue: Bool { controller?.isContinue(rowIndex) == true }
    /// Landscape cards (Continue Watching's, Search's rows).
    var isLandscape: Bool { controller?.isLandscape(rowIndex) == true }
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
                    let lift = FixedFocusMetrics.focusLift(card)
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
    private let layout = FixedFocusStripLayout()

    override init(frame: CGRect) {
        strip = FixedFocusStripView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        // The billboard's invisible cards: not while its focus is outside
        // (Details' buttons) — neither they nor the list in their place.
        (strip as? FixedFocusStripView)?.selfFocus = { [weak self] in !(self?.billboardCardsOff ?? false) }
        layout.cardWidth = { [weak self] in self?.cardWidth ?? FixedFocusMetrics.posterWidth }
        layout.cardHeight = { [weak self] in self?.cardHeight ?? FixedFocusMetrics.height }
        clipsToBounds = false
        contentView.clipsToBounds = false
        title.font = Self.titleFont
        // Secondary: Apple TV's are ~50 %, primary read too bright.
        title.textColor = CueInk.ui(FixedFocusText.secondary)
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
        stripHost.frame = bounds
        // A destination strip: the screen plus the overscan on both sides.
        destinationStrip?.frame = CGRect(x: -over, y: cardsTop,
                                         width: 1920 + 2 * over, height: cardHeight)
        // Covers the list wherever its cards (and their lift) reach.
        UIView.performWithoutAnimation { applyConcealMask() }
        // The box at the spot (made before the strip had its place).
        if let box, box.frame.origin != boxFrame.origin {
            UIView.performWithoutAnimation { box.frame = boxFrame }
        }
    }

    /// Holds the strip.
    private let stripHost = UIView()

    /// The Featured row: the billboard's picture (see `StagePictureView`).
    private var stage: StagePictureView?

    func showStage(_ item: MetaItem, direction: CGFloat, animated: Bool) {
        // Full screen: TMDB's ORIGINAL file, whatever size the pick came
        // with (a saved pick or cached catalog may still carry a smaller
        // rendition — soft on a 4K TV).
        placeStage(TMDBService.originalSize(item.background) ?? item.poster, item: item,
                   direction: direction, animated: animated)
    }

    private func placeStage(_ url: String?, item: MetaItem, direction: CGFloat, animated: Bool) {
        guard isFeatured else { return }
        let url = controller?.billboardPicture ?? url
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
                          animations: { self.setTitle(text) })
        setNeedsLayout()
    }

    /// The row's name; a Discover sentence on Home has the Discover
    /// compass before it, in the name's ink (no colour).
    private func setTitle(_ text: String?) {
        guard let text, row?.id.hasPrefix(DiscoverPins.rowPrefix) == true, let font = title.font else {
            title.text = text
            return
        }
        let symbol = UIImage(systemName: "safari.fill",
                             withConfiguration: UIImage.SymbolConfiguration(font: font.withSize(font.pointSize * 0.85)))?
            .withTintColor(title.textColor, renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment()
        attachment.image = symbol
        if let size = symbol?.size {
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        }
        let line = NSMutableAttributedString(attachment: attachment)
        line.append(NSAttributedString(string: "  " + text))
        title.attributedText = line
    }

    func showProgress() {
        guard let row, let controller else { return }
        func entry(_ index: Int) -> WatchProgress? {
            row.items.indices.contains(index) ? controller.progress[row.items[index].id] : nil
        }
        for case let card as FixedFocusDestinationCell in destinationStrip?.visibleCells ?? [] {
            if let progress = entry(card.itemIndex) { card.showProgress(progress) }
        }
    }

    func configure(rowIndex: Int, controller: FixedFocusRowsController) {
        self.rowIndex = rowIndex
        self.controller = controller
        // Reused after letting its pictures go: they and the box come back
        // (after this configure has set the row up).
        if !artHeld { DispatchQueue.main.async { [weak self] in self?.setArtHeld(true) } }
        setTitle(row?.title)
        title.isHidden = isFeatured
        titleBar.isHidden = row?.id.hasPrefix("placeholder-") != true
        setNeedsLayout()
        showAccessory()
        showHeader()
        showCustom()
        if isFeatured, let row, row.items.indices.contains(selectedIndex) {
            showStage(row.items[selectedIndex], direction: 1, animated: false)
        }
        strip.isHidden = isDestination
        if isDestination, destinationStrip == nil { makeDestinationStrip() }
        destinationStrip?.isHidden = !isDestination
        if let cv = destinationStrip {
            // A Top 10: all ten at once, two lines of five (no scrolling).
            let ranked = controller.isGrid(rowIndex)
            if ranked {
                let card = controller.destinationCard(rowIndex)
                gridLayout.cell = card
                gridLayout.columns = controller.gridColumns(rowIndex)
                gridLayout.lineHeight = controller.gridLine(rowIndex)
            }
            let feature = controller.isFeature(rowIndex)
            if feature { featureLayout.focused = selectedIndex }
            let layout: UICollectionViewLayout = ranked ? gridLayout : feature ? featureLayout : flowLayout
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
        dropBox()
        if isDestination {
            // Scrolled by their own rule (see `windowOffset`).
            destinationStrip?.isScrollEnabled = false
            windowStart = 0
            // The cards on screen let their pictures go first: a reload puts
            // them back in the pool without `didEndDisplaying`, and parked
            // there they kept them (226 MB once Home had sat open through
            // its rows' refreshes). The ones shown again fill from memory.
            releaseVisibleArt()
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
            // A large row: its box again.
            if controller.isFeature(rowIndex) {
                destinationStrip?.layoutIfNeeded()
                UIView.performWithoutAnimation { syncBox(animated: false) }
            }
            return
        }
        strip.reloadData()
        strip.layoutIfNeeded()
        strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0)
    }

    /// Its cards' pictures held, or let go while the row is out of view:
    /// let go, the cards drop them and the box goes; held again, the cards
    /// are configured anew (from the image cache, which the preload keeps
    /// warm for the rows within reach) and the box comes back.
    private(set) var artHeld = true
    func setArtHeld(_ held: Bool) {
        guard held != artHeld else { return }
        artHeld = held
        if held {
            refreshArt()
            UIView.performWithoutAnimation { syncBox(animated: false) }
            return
        }
        dropBox()
        releaseVisibleArt()
    }

    private func releaseVisibleArt() {
        for cv in [strip, destinationStrip].compactMap({ $0 }) {
            for cell in cv.visibleCells {
                (cell as? FixedFocusShowcaseCell)?.releaseArt()
                (cell as? FixedFocusDestinationCell)?.releaseArt()
            }
        }
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

    /// This row's first card on screen, at rest (see the controller).
    func restingCardOrigin() -> CGPoint? { controller?.restingCardOrigin(rowIndex) }
    /// SwiftUI for a card, with the app's stores.
    func hosted(_ view: some View) -> AnyView { controller?.environment(AnyView(view)) ?? AnyView(view) }

    func posterCell(at index: Int) -> UIView? {
        let shown = destinationStrip.flatMap { isDestination ? $0 : nil } ?? strip
        shown.layoutIfNeeded()
        let path = IndexPath(item: index, section: 0)
        if let cell = shown.cellForItem(at: path) { return cell }
        // Out of view (a title you acted on moved to the front): the row
        // brought to it, so focus can land there.
        guard index < shown.numberOfItems(inSection: 0) else { return nil }
        shown.scrollToItem(at: path, at: .left, animated: false)
        shown.layoutIfNeeded()
        return shown.cellForItem(at: path)
    }

    /// A destination row's strip: the system's horizontal scrolling — focus
    /// moves along, the row follows only near its edge.
    private let flowLayout = UICollectionViewFlowLayout()
    private let gridLayout = FixedFocusGridLayout()
    private let featureLayout = FixedFocusFeatureLayout()
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
        featureLayout.left = over + FixedFocusMetrics.inset
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

    /// Inside the controller's animation: the strip moves so the title
    /// sits at the spot.
    func focus(index: Int) {
        guard !isDestination else { return }
        relayout()
        strip.contentOffset = CGPoint(x: offset(for: index), y: 0)
    }

    /// Re-lay out the strip.
    func relayout() {
        guard !isDestination else { return }
        strip.collectionViewLayout.invalidateLayout()
        strip.layoutIfNeeded()
        if !isFocusRow { strip.contentOffset = CGPoint(x: offset(for: selectedIndex), y: 0) }
    }

    /// The row offset that puts title `index` at the spot.
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
           controller.isShowcase(rowIndex) || controller.isRanked(rowIndex)
            || controller.isFeature(rowIndex) {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "showcase", for: indexPath) as! FixedFocusShowcaseCell
            fill(cell, at: indexPath)
            return cell
        }
        if cv === destinationStrip {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "destination", for: indexPath)
                as! FixedFocusDestinationCell
            fill(cell, at: indexPath)
            return cell
        }
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath) as! FixedFocusPosterCell
        cell.configure(index: indexPath.item, rowCell: self)
        return cell
    }

    /// A card coming into view whose pictures were let go (`releaseArt`)
    /// while it stayed the row's: shown again without being dequeued (the
    /// collection view keeps cells just out of view), it's filled anew —
    /// else it came back empty.
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard cv === destinationStrip else { return }
        if let showcase = cell as? FixedFocusShowcaseCell, showcase.isReleased {
            fill(showcase, at: indexPath)
        } else if let card = cell as? FixedFocusDestinationCell, card.isReleased {
            fill(card, at: indexPath)
        }
    }

    private func fill(_ cell: FixedFocusShowcaseCell, at indexPath: IndexPath) {
        guard let controller else { return }
        if let row, row.items.indices.contains(indexPath.item) {
            configureShowcase(cell, row.items[indexPath.item], index: indexPath.item)
            cell.setDetailsShown(isFocusRow, animated: false)
            if controller.isFeature(rowIndex) {
                showFeature(cell, animated: false)
                // The focused one under the box.
                let under = box != nil && indexPath.item == featureLayout.focused
                cell.mirror = under ? box : nil
                cell.hiddenUnderBox = under
            }
        }
    }

    private func fill(_ cell: FixedFocusDestinationCell, at indexPath: IndexPath) {
        if let row, let controller, row.items.indices.contains(indexPath.item) {
            let item = row.items[indexPath.item]
            cell.configure(item, subtitle: row.subtitles[item.id], index: indexPath.item, rowCell: self,
                           card: controller.destinationCard(rowIndex),
                           progress: controller.isContinue(rowIndex) ? controller.progress[item.id] : nil,
                           // The episode rows' state by title: not Continue Watching's (its own progress).
                           cardState: controller.isLandscape(rowIndex) && !controller.isContinue(rowIndex)
                               ? controller.cardStates[item.id] : nil,
                           art: row.art[item.id],
                           isLogo: controller.isLogo(rowIndex),
                           captionOnCard: controller.captionsOnCards(rowIndex))
            cell.setCaptionShown(captionsShown)
            cell.setDetailsShown(isFocusRow, animated: false)
        }
    }

    private var billboardCardsOff: Bool { isFeatured && controller?.billboardFocusOutside == true }

    /// A card gone from the row's view (parked for reuse) lets its
    /// pictures go; shown again, it's configured anew.
    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? FixedFocusShowcaseCell)?.releaseArt()
        (cell as? FixedFocusDestinationCell)?.releaseArt()
    }

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
        guard cv === destinationStrip, let controller, let row else { return }
        guard let index = context.nextFocusedIndexPath?.item else { return }
        let feature = controller.isFeature(rowIndex)
        let card = controller.destinationCard(rowIndex)
        let offset = windowOffset(focusing: index, card: card.width, count: row.items.count)
        let relayout = feature && featureLayout.focused != index
        if feature { featureLayout.focused = index }
        rowMoves += 1
        let move = rowMoves
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            if relayout { self.applyFeature(in: cv) }
            if offset != cv.contentOffset.x { cv.contentOffset = CGPoint(x: offset, y: 0) }
            self.applyNameRoom(focusing: index)
        } completion: { _ in self.boxMoveEnded(move) }
    }

    /// A showcase card (a row's cell, or a large row's box): the title, its
    /// badges — New & Notable and Coming Soon for You their own one alone,
    /// the others the row's (`HomeRow.badges(for:)`) — and its look.
    private func configureShowcase(_ cell: FixedFocusShowcaseCell, _ item: MetaItem, index: Int) {
        guard let row, let controller else { return }
        let ranked = controller.isRanked(rowIndex)
        let badges = ranked ? [] : row.id.hasSuffix(".newnotable") || row.id.hasSuffix(".comingsoon")
            ? row.badges[item.id].map { [$0] } ?? [] : row.badges(for: item)
        cell.configure(item, index: index, rowCell: self, art: row.art[item.id],
                       badges: badges, rank: ranked ? index + 1 : nil,
                       feature: controller.isFeature(rowIndex), spotlight: controller.isSpotlight(rowIndex))
    }

    /// A large row: the cards to their new frames and the box to its title
    /// (in the caller's animation).
    private func applyFeature(in cv: UICollectionView, animated: Bool = true) {
        featureLayout.invalidateLayout()
        cv.layoutIfNeeded()
        for case let card as FixedFocusShowcaseCell in cv.visibleCells { showFeature(card, animated: animated) }
        syncBox(animated: animated)
    }

    /// A large row's card: a poster; the backdrops near the spot loaded
    /// ahead (the focused card and the next two: the box finds them cached).
    private func showFeature(_ card: FixedFocusShowcaseCell, animated: Bool) {
        let focused = featureLayout.focused
        if (focused...focused + 2).contains(card.itemIndex) { card.wantBackdrop() }
        card.setOpen(false)
    }

    // MARK: The large rows' box

    /// The open card at the spot, Netflix's way: one card above the posters
    /// that stands still, in focus or not (Up/Down only grows it by focus).
    /// Left/Right: the next title dissolves in over it, the posters sliding
    /// one step under it. The poster under it keeps focus, press and hold;
    /// the box shows them and plays its trailer
    /// (`FixedFocusShowcaseCell.mirror`).
    private var box: FixedFocusShowcaseCell?
    private var boxItem: String?

    private var boxFrame: CGRect {
        guard let cv = destinationStrip else { return .zero }
        return CGRect(origin: CGPoint(x: cv.frame.minX + featureLayout.left, y: cv.frame.minY),
                      size: FixedFocusFeatureLayout.large)
    }

    private func underBox(_ index: Int) -> FixedFocusShowcaseCell? {
        destinationStrip?.cellForItem(at: IndexPath(item: index, section: 0)) as? FixedFocusShowcaseCell
    }

    /// The box to the row's state, in the caller's animation (`animated`).
    private func syncBox(animated: Bool) {
        guard let controller, controller.isFeature(rowIndex), let row,
              row.items.indices.contains(featureLayout.focused) else { return dropBox() }
        let index = featureLayout.focused, item = row.items[index]
        let frame = boxFrame
        let under = underBox(index)
        if let box, boxItem == item.id {
            under?.mirror = box
            under?.hiddenUnderBox = true
            return
        }
        // The row's box, at once (the row shown, or its titles changed).
        guard let old = box else {
            let new = makeBox(item, index: index)
            // (Without animation: a reused box's logo, let go to nothing at its
            // corner, grew from there in the press's move.)
            if let under { UIView.performWithoutAnimation { new.adoptPictures(from: under) } }
            UIView.performWithoutAnimation {
                new.frame = frame
                new.setOpen(true)
                new.reflect(focused: under?.isFocused ?? false, pressed: false, held: false)
                under?.mirror = new
                new.layoutIfNeeded()
            }
            under?.hiddenUnderBox = true
            box = new
            boxItem = item.id
            return
        }
        let new = makeBox(item, index: index)
        // Before it opens (it chooses the poster or the backdrop by what it has).
        if let under { UIView.performWithoutAnimation { new.adoptPictures(from: under) } }
        // Along the row: the new title over the old, fading in (the old
        // stays whole under it: no dip), the posters sliding under.
        // Only the picture and words fade in: the outline and its shadow
        // are there at once, the old one's gone in the same frame (both
        // drawn, the shadow doubled dark under the card, then dropped).
        // The old one goes when the new one has covered it.
        if animated {
            new.dissolveIn { [weak self] in
                guard let self else { return old.removeFromSuperview() }
                // (Taken again for a newer box meanwhile: it stays.)
                if old !== self.box { self.retire(old) }
            }
        } else {
            retire(old)
        }
        if let cv = destinationStrip {
            for case let cell as FixedFocusShowcaseCell in cv.visibleCells where cell.mirror === old {
                cell.mirror = nil
                cell.hiddenUnderBox = false
            }
        }
        // (The old one stays as it is, grown, until the new one covers it:
        // easing it back drew its outline shrinking under. The card that
        // was under it leaves it as it is: `passesFocusAlong`.)
        old.dropOutline()
        // The box itself back to its resting size and up again (a press
        // on a focused card's way), the old and the new as one: outline
        // and shadow with it.
        // Held, the presses come faster than the dip: it goes on from
        // where the box is (restarted from full size it jumped), and every
        // box still fading out takes the same one (one left on its own dip
        // showed its edges past the others, flickering).
        if animated, old.isFocusedLook {
            let rest = 1 / (1 + FixedFocusMetrics.focusLift(FixedFocusMetrics.featureCard))
            let now = (old.layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
            let down = 0.4 * max(0, min(1, (now - rest) / (1 - rest)))
            let dip = CAKeyframeAnimation(keyPath: "transform.scale")
            dip.values = [now, rest, 1]
            dip.keyTimes = [0, NSNumber(value: Double(down)), 1]
            dip.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            dip.duration = Motion.moveDuration
            let start = CACurrentMediaTime()
            for case let view as FixedFocusShowcaseCell in stripHost.subviews where !view.isHidden {
                dip.beginTime = view.layer.convertTime(start, from: nil)
                view.layer.add(dip, forKey: "dip")
            }
        }
        // Already grown and outlined, as the old one: only the picture
        // changes. Laid out whole here, the outline's shadow too: laid
        // out late, in the move's spring, it grew in from a stale size
        // (a pale box larger than the card, shrinking).
        UIView.performWithoutAnimation {
            new.frame = frame
            new.setOpen(true)
            // Focused already (the card under it may hear of its focus
            // only after this).
            new.reflect(focused: under?.isFocused ?? false, pressed: false, held: false)
            under?.mirror = new
            new.layoutIfNeeded()
        }
        // Hidden once it has slid in under the box (until then, it
        // shows): at the end of the row's move (`boxMoveEnded`).
        if animated {
            slidingUnder = (under, new)
        } else {
            under?.hiddenUnderBox = true
        }
        box = new
        boxItem = item.id
    }

    /// A box for `item` above the row's posters. Made outside the
    /// move's spring: made in it, its setup was animated too (the shadow
    /// growing in from nothing over the card).
    private func makeBox(_ item: MetaItem, index: Int) -> FixedFocusShowcaseCell {
        var made: FixedFocusShowcaseCell!
        UIView.performWithoutAnimation {
            let new: FixedFocusShowcaseCell
            if let spare = spareBox {
                spareBox = nil
                spare.isHidden = false
                stripHost.bringSubviewToFront(spare)
                new = spare
            } else {
                new = FixedFocusShowcaseCell()
                new.isUserInteractionEnabled = false
                stripHost.addSubview(new)
            }
            configureShowcase(new, item, index: index)
            new.setDetailsShown(isFocusRow, animated: false)
            made = new
        }
        return made
    }

    /// A box gone, kept hidden for the next one: taken out of the window,
    /// a box cost UIKit ~20 ms each time (its autofill check walks the
    /// loaded libraries), and a row leaving the list drops its box in a
    /// press. One kept per row; any more go.
    private var spareBox: FixedFocusShowcaseCell?

    private func retire(_ old: FixedFocusShowcaseCell) {
        guard spareBox == nil, old.superview === stripHost else { return old.removeFromSuperview() }
        UIView.performWithoutAnimation {
            old.isHidden = true
            old.layer.removeAllAnimations()
            old.resetForSpare()
        }
        spareBox = old
    }

    /// The card sliding in under the box along the row, hidden once there.
    private var slidingUnder: (cell: FixedFocusShowcaseCell?, box: FixedFocusShowcaseCell)?
    /// Counts the row's moves: only the last one's end hides it (held, an
    /// earlier move's end came while the next card was still sliding in).
    private var rowMoves = 0

    /// The row's move has ended (the last one, `move` its count).
    private func boxMoveEnded(_ move: Int) {
        guard move == rowMoves, let sliding = slidingUnder else { return }
        slidingUnder = nil
        if box === sliding.box, sliding.cell?.mirror === sliding.box { sliding.cell?.hiddenUnderBox = true }
    }

    private func dropBox() {
        slidingUnder = nil
        if let box { retire(box) }
        box = nil
        boxItem = nil
        guard let cv = destinationStrip else { return }
        for case let cell as FixedFocusShowcaseCell in cv.visibleCells where cell.mirror != nil || cell.hiddenUnderBox {
            cell.mirror = nil
            cell.hiddenUnderBox = false
        }
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
        if controller.isFeature(rowIndex), featureLayout.focused != index {
            featureLayout.focused = index
            UIView.performWithoutAnimation { applyFeature(in: cv, animated: false) }
        }
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
    /// full as the screen holds, with, once
    /// the row has moved, a sliver of the one before and the one after split
    /// evenly — always a hint when there's more. At the start: the cards from
    /// the usual inset, the next one's sliver at the right.
    private func windowOffset(focusing index: Int, card: CGFloat, count: Int) -> CGFloat {
        let gap = FixedFocusMetrics.gap
        let pitch = card + gap
        // A Top 10's grid shows all its cards: never moves.
        if controller?.isGrid(rowIndex) == true { return 0 }
        // A large landscape row: the focused card large at the spot.
        if controller?.isFeature(rowIndex) == true { return featureLayout.offset(for: index) }
        // Focus stays in place (`FixedFocusRows.anchoredRowIDs`): the
        // focused card always at the first card's spot — to the last one,
        // the row's end left open.
        if let row, controller?.anchoredRowIDs.contains(row.id) == true {
            windowStart = index
            return CGFloat(index) * pitch
        }
        // Room for the slivers (and their gaps) on both sides.
        let room = 1920 - 2 * (gap + FixedFocusMetrics.destinationSliver)
        let shown = max(1, Int((room + gap) / pitch))
        if index < windowStart { windowStart = index }
        if index > windowStart + shown - 1 { windowStart = index - shown + 1 }
        guard windowStart > 0 else { return 0 }
        let edge = (1920 - CGFloat(shown) * card - CGFloat(shown - 1) * gap) / 2
        let content = 2 * FixedFocusMetrics.inset + CGFloat(count) * pitch - gap
        let end = max(0, content - 1920)
        return min(FixedFocusMetrics.inset + CGFloat(windowStart) * pitch - edge, end)
    }
}

/// A large row (Home's browsing rows): portrait posters, focus held at
/// the spot. The focused card is open there, in focus or not, a wide card
/// as tall as a poster (`featureCard`, its right edge near the screen's
/// middle; the row's box, `FixedFocusRowCell.syncBox`); the posters after
/// it beside it, the ones before gone out at the left. A card's frame
/// follows from where it is against the focused one, nothing else: a move
/// changes `focused`, and every card goes to its new frame on one spring.
/// The row's height never changes.
final class FixedFocusFeatureLayout: UICollectionViewLayout {
    var focused = 0
    var left: CGFloat = 0
    static var large: CGSize { FixedFocusMetrics.featureCard }
    static var poster: CGSize { FixedFocusMetrics.featurePoster }
    private var frames: [CGRect] = []
    private var width: CGFloat = 0

    /// The offset that puts card `index` at the spot.
    func offset(for index: Int) -> CGFloat { CGFloat(index) * (Self.poster.width + FixedFocusMetrics.gap) }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let count = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        let gap = FixedFocusMetrics.gap
        var x = left
        frames = (0..<count).map { index in
            // Every card a poster: the open card is the row's box above them
            // (`FixedFocusRowCell.syncBox`), its room left after the focused one.
            // The focused one centred in that room: posters go in and come
            // out on both sides alike (at its left, Right's were quicker).
            let under = index == focused
            defer { x += (under ? Self.large.width : Self.poster.width) + gap }
            let inset = under ? (Self.large.width - Self.poster.width) / 2 : 0
            return CGRect(origin: CGPoint(x: x + inset, y: 0), size: Self.poster)
        }
        // Room for the last card open at the spot.
        width = x - gap + left + Self.large.width - Self.poster.width
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(width, collectionView?.bounds.width ?? 0), height: Self.large.height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.indices.filter { frames[$0].intersects(rect) }.map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    private func attributes(_ index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}

/// A Top 10's cards: two lines of five, all on screen, in rank order
/// (1–5 above, 6–10 below), the rows' gap between cards and lines alike.
final class FixedFocusGridLayout: UICollectionViewLayout {
    /// The grid's height for `count` cards, each line `card` tall (its
    /// caption room in).
    static func height(card: CGFloat, count: Int, columns: Int = 5) -> CGFloat {
        let lines = CGFloat(max(1, (count + columns - 1) / columns))
        return lines * card + (lines - 1) * FixedFocusMetrics.gap
    }
    var columns = 5
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
            let column = CGFloat(i % columns), line = CGFloat(i / columns)
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
/// the title's, beside the card itself.
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
        if isDestination(rowIndex), let cell = focused as? FixedFocusDestinationCell {
            return cell.holdMenu(entries)
        }
        if isFeatured(rowIndex), let request = billboardHoldMenu(entries) { return request }
        if let cell = focused as? FixedFocusShowcaseCell { return cell.holdMenu(entries) }
        return HoldMenuRequest(entries: entries, anchor: focused.convert(focused.bounds, to: nil))
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

/// A change you made (a hold menu's pick, back from the player): for a
/// moment the rows take new content at once, even the row focus is in.
/// Only what you didn't do waits there for focus to leave
/// (`FixedFocusRowsController.update`): an action needs its answer on
/// screen at once (a removed card stayed until focus left the row).
@MainActor
enum UserAction {
    /// Long enough for the stores and Home's rows to follow the action.
    static let window: CFTimeInterval = 2
    static let acted = Notification.Name("cue.userActed")
    private static var until: CFTimeInterval = 0
    static var recent: Bool { CACurrentMediaTime() < until }

    static func mark() {
        until = CACurrentMediaTime() + window
        NotificationCenter.default.post(name: acted, object: nil)
    }
}
