import SwiftUI
import AVFoundation

// MARK: - Tuning
//
// Every number that decides how the spotlight row looks and feels lives
// here, so the feel can be tuned on the Apple TV without hunting through
// the view code.

enum Spotlight {
    /// Height of the focus box AND the posters beside it.
    static let rowHeight: CGFloat = 420
    /// Portrait 2:3 poster at row height (280pt). At 420 exactly three
    /// posters fit beside the box, plus a peek of a fourth at the edge.
    static var posterWidth: CGFloat { rowHeight * 2 / 3 }
    /// Landscape 16:9 box at row height (~747pt).
    static var boxWidth: CGFloat { rowHeight * 16 / 9 }
    /// Gap between the box and posters, and between posters.
    static let spacing: CGFloat = 24
    /// Corner radius of the box and posters.
    static let cornerRadius: CGFloat = 16
    /// Posters built to the right of the box (a few past the screen edge).
    static let postersAhead = 5
    /// Rows are RINGS: after the last title comes an END CARD ("↺ Back to
    /// start"), the size of the row's own cards, then the first title
    /// again; left of the first title the same card peeks in (just the ↺).
    /// Right on the last title turns the ring on: the row resists a little
    /// (`wrapNudge`), then the end card slides past under the box and the
    /// first title lands in it (`wrapSlide`). Left on the first: reverse.
    static let wrapSlide: Animation = .timingCurve(0.45, 0, 0.2, 1, duration: 0.55)
    /// Which rows are rings: catalogs from this many titles up (and the
    /// billboard). Continue Watching and short rows END instead — at an end
    /// the cards give (the same resistance) and spring back (`endBounce`).
    static let minRingCount = 6
    static let endBounce: Animation = .smooth(duration: 0.3)
    /// The resistance: how far the row gives, how fast, and the beat at
    /// full resistance before it turns.
    static let wrapNudge: CGFloat = 36
    /// The resistance moves the box too. Off: only the cards give; the box
    /// stays put, as on every other step.
    static let wrapNudgeMovesBox = false
    /// (Experiment) Every Left/Right starts with a short flick of the whole
    /// row (box included) in the pressed direction, then slides. 0 = off;
    /// try 12–16.
    static let stepNudge: CGFloat = 0
    static let stepNudgeDuration: Double = 0.08
    static let wrapPress: Animation = .easeOut(duration: 0.16)
    static let wrapHold: Duration = .milliseconds(230)
    /// The end card "pressed" during the resistance, like a glass button:
    /// it gives a little and brightens, then springs back as the ring turns.
    static let seamPressScale: CGFloat = 0.98
    static let seamPressGlow: Double = 0.18

    // Motion

    /// Left/Right: posters slide one slot (the next one tucks under the
    /// box) while the box crossfades to the new title. (Also the Detail
    /// page's episode row.)
    static let slide: Animation = .smooth(duration: 0.3)
    /// Up/Down: ONE movement — all rows scroll one row (no fading), and on
    /// the way the arriving row OPENS (its first poster widens into the
    /// box, the posters beside it make room) while the leaving row keeps
    /// its box as it scrolls out. Up: the old focus row closes back into
    /// posters on its way down to the preview spot.
    ///
    /// Fast start, gentle finish: most of the way is covered early, the
    /// rest eases in.
    static let rowChange: Animation = .timingCurve(0.5, 0.8, 0.3, 1, duration: 0.6)
    /// (`.scroll`) Down, Netflix-style, in ONE go: the preview opens its box
    /// (fast, `prepare`) while the scroll (`downScroll`) is still barely
    /// moving — its start is slow — so the opening is done within the first
    /// 10–20% of the scroll, and then the row moves off and eases in.
    /// Up: the old focus row folds back into posters as it scrolls down,
    /// finishing together (`rowChange`).
    static let prepareDuration: Double = 0.12
    static var prepare: Animation { .linear(duration: prepareDuration) }
    /// Down's scroll: slower start than `rowChange`, same length.
    static let downScroll: Animation = .timingCurve(0.6, 0.15, 0.3, 1, duration: 0.6)
    /// Which Up/Down to use:
    /// - `.scroll`: the above — rows scroll, the arriving row opens.
    /// - `.fade`: like Left/Right instead. The box never moves and stays
    ///   landscape; its artwork crossfades to the new row's title. Every
    ///   other part moves only a little (`fadeShift`) and fades — the
    ///   preview's first poster grows a bit and moves toward the box as it
    ///   fades.
    /// - `.glide`: like Left/Right, turned upright. The posters travel
    ///   STRAIGHT up (no reshaping) and fade as they reach the focus line;
    ///   then the new content appears in the focus row (box crossfade,
    ///   posters and info fading in place). The names change in place.
    enum VerticalStyle { case scroll, fade, glide }
    static let verticalStyle: VerticalStyle = .scroll
    /// (`.glide`) The change.
    static let glideChange: Animation = .smooth(duration: 0.45)
    /// (`.glide`) Share of the way the travelling posters go before they
    /// start to fade (they're gone on arrival).
    static let glideFadeStart: Double = 0.6
    /// (`.glide`) The arriving content fades in over this last share.
    static let glideAppear: Double = 0.4
    /// (`.glide`) The row moving OUT of the way (old focus on Down, old
    /// preview on Up) shifts this far while it fades, early.
    static let glideLeaveShift: CGFloat = 80
    /// (`.fade`) The change. Even pace (not front-loaded), so the move is
    /// seen before the fade takes over.
    static let fadeChange: Animation = .easeInOut(duration: 0.42)
    static let fadeShift: CGFloat = 50
    /// (`.fade`) Share of the move that happens before the fade takes over.
    static let fadeFrom: Double = 0.65
    /// (`.fade`) How much the preview grows toward the box as it fades.
    static let previewGrow: CGFloat = 1.5
    /// (`.fade`) How far the preview moves toward the box, in `fadeShift`s.
    static let previewTravel: CGFloat = 2.5
    /// The logo and caption sit on the fixed spot: hidden while the rows
    /// travel, back this long after the press.
    static let textReturn: Duration = .milliseconds(320)
    /// Text (info, logo) crossfades in place.
    static let textFade: Animation = .easeOut(duration: 0.12)
    /// Where a new preview row starts when there's no preview spot.
    static let incomingPreviewRise: CGFloat = 120

    // Box

    /// Focus treatment of the box:
    /// - `.plain`: pure artwork, like the posters (content isn't glass —
    ///   glass is for the interface layer: sidebar, buttons, chips).
    /// - `.edge`: a fine light edge.
    /// - `.outline`: the plain white outline.
    enum BoxStyle { case plain, edge, outline }
    static let boxStyle: BoxStyle = .outline
    /// (`.outline`) The focus outline: the glass focus rim (`GlassFocusRim`).
    static let outlineWidth: CGFloat = 4
    /// Fine light edge on every card (box and posters) — the "glass" look
    /// on the moving cards, where REAL glass would be re-rendered on every
    /// animation frame.
    static let cardEdgeHighlight = true
    /// Stylized title (logo) drawn ON the box, bottom-left, over a gradient.
    static var logoMaxWidth: CGFloat { boxWidth * 0.55 }
    static var logoMaxHeight: CGFloat { rowHeight * 0.28 }
    static let logoInset: CGFloat = 28
    /// How dark the gradient behind the logo gets at the box's bottom edge.
    static let logoScrimOpacity: Double = 0.75
    /// Watch-progress pill inside the box (grey track, white fill — the
    /// tvOS look), inset from the box's edges. Continue Watching only: in
    /// the other rows the "38m left" chip already says it.
    static let continueProgressBarHeight: CGFloat = 10
    /// Show the show's logo on the Continue Watching box. Off: the episode
    /// still stands on its own (the name is right below it anyway).
    static let continueShowsLogo = false
    /// Gap between the box pill and the box's left/right and bottom edges.
    static let progressBarInset: CGFloat = 28
    static let progressBarBottomInset: CGFloat = 22
    /// The same pill, smaller, on posters beside the box (Continue Watching).
    static let posterProgressBarHeight: CGFloat = 6
    static let posterProgressBarInset: CGFloat = 14
    /// Continue Watching: the time left beside the bar ("38m left"), or
    /// "Up Next" with no bar — the card's STATE, inside it (its identity,
    /// name and episode, is under the box).
    static let continueStateSize: CGFloat = 22
    static let continueStateGap: CGFloat = 14
    /// The soft dark foot on Continue Watching cards, so the state reads on
    /// bright stills.
    static let continueFootOpacity: Double = 0.7
    /// Where the foot starts (0 = top of the card).
    static let continueFootStart: UnitPoint = UnitPoint(x: 0.5, y: 0.4)
    /// A very slight, constant dimming on the box's artwork — the focused
    /// title was glaring next to the page, and it's the soft starting point
    /// of the box → Details darkening.
    static let boxDim: Double = 0.08
    /// Pill colours.
    /// (A dark track was tried for bright stills — barely better, and apart
    /// from the Top Shelf's cards. Kept light.)
    static let progressTrack = Color.white.opacity(0.3)
    static let progressFill = Color.white

    /// Trailer in the box: starts after resting on a title this long
    /// (the lookup runs during the wait, so this is usually all you wait).
    /// Follows the app's own switches: Settings → Layout → hero trailers /
    /// hero trailer sound, TMDB "Trailers", and Reduce Motion.
    static let trailerDelay: TimeInterval = 1.0
    /// Trailers in the regular rows' box. Off: that's where you BROWSE —
    /// every press would start and cancel a YouTube lookup and a video
    /// player mid-animation. The billboard (where you rest) keeps its own.
    static let boxTrailers = false

    // Info under the box

    /// Detail page episode info: ends where the box ends (its meta line is
    /// short, so a box-wide column reads clean there), one line longer.
    static var episodeDescriptionWidth: CGFloat { boxWidth }
    static let episodeDescriptionLines = 2

    // Vertical layout (fixed positions — every row puts the box in exactly
    // the same place, which is what lets the rows glide between spots).

    /// Left margin of everything. Shared with the Detail page, so both
    /// screens line up.
    static let screenInset: CGFloat = 84
    static let topPadding: CGFloat = 56
    /// With the top navigation: everything starts below it instead.
    static let topPaddingUnderNav: CGFloat = 124
    static let labelHeight: CGFloat = 40
    /// Row name above the box.
    static let headerHeight: CGFloat = 54
    static let headerToRowGap: CGFloat = 24
    /// The catalog title's top on Home — the one formula for it, shared
    /// with the Detail page (whose logo lines up with it): the main block
    /// (title, row, caption) centred between the top label and the preview.
    static func catalogTitleY(screenHeight: CGFloat, topPadding: CGFloat) -> CGFloat {
        let previewY = showNextRowPreview
            ? screenHeight - previewVisibleHeight
            : screenHeight + incomingPreviewRise
        let bottomLabelY = showNextRowPreview
            ? previewY - labelToPreviewGap - labelHeight
            : screenHeight - 48 - labelHeight
        let top = topPadding + labelHeight
        let block = headerHeight + headerToRowGap + rowHeight + rowToInfoGap + infoHeight
        return top + max((bottomLabelY - top - block) / 2, 8)
    }
    static let rowToInfoGap: CGFloat = 28
    /// Focus row's name / the "▴ ▾" labels.
    static let headerTitleSize: CGFloat = 40
    static let headerLabelSize: CGFloat = 22
    /// Fixed height of the caption BELOW the box (name + meta line; three
    /// short lines for Continue Watching), so nothing jumps between rows.
    static let infoHeight: CGFloat = 130
    static let labelToPreviewGap: CGFloat = 14

    // Next-row preview

    /// The next row, laid out EXACTLY like the focus row (same box, same
    /// posters, same size), peeking up from the bottom edge. Because it's
    /// identical, Down only has to move it up — nothing changes shape.
    static let showNextRowPreview = true
    /// How much of the preview row shows above the screen edge.
    static let previewVisibleHeight: CGFloat = 170
    static let previewOpacity: Double = 0.5

    // Featured billboard (the first "row": one big box, Netflix-style)

    static let showFeatured = true
    /// The billboard's artwork runs edge to edge, under the navigation.
    /// Its text and focus area keep to the content margins: from the top
    /// padding down to `featuredBottomGap` above the next row's label.
    static let featuredRightMargin: CGFloat = 64
    static let featuredBottomGap: CGFloat = 28
    /// The billboard's text uses the Detail page's title block (see
    /// `TitleBlock`), in the same place, so Select opens Details without
    /// anything shared moving.

    // Indicators

    static let chevronSize: CGFloat = 30
    /// Distance of the left chevron's centre from the box's left edge — it
    /// sits in the gap between the sidebar and the box.
    static let leftChevronOffset: CGFloat = 44
    /// The chevrons are small glass circles (the app's glass — see
    /// `AppGlass`) carried BY their row. On Left/Right the pressed one
    /// gives a little and brightens, like a glass button.
    static let chevronCircle: CGFloat = 56
    static let chevronIcon: CGFloat = 22
    static let chevronRightInset: CGFloat = 22
    static let chevronPressScale: CGFloat = 0.86
    static let chevronPressGlow: Double = 0.25
    /// Left/Right: the box stretches gently in the pressed direction — its
    /// edge runs ahead, then it settles back (the billboard dots' liquid
    /// move, softly).
    static let boxStretch: CGFloat = 24
    static let boxStretchLead: Animation = .easeOut(duration: 0.1)
    static let boxStretchSettle: Animation = .smooth(duration: 0.28)
    static let boxStretchHold: Duration = .milliseconds(70)
    /// The billboard's position: fixed glass dots and a liquid glass marker
    /// (see `BillboardDots`). Regular rows have none.
    static let showPositionDots = true

    /// Row names travel WITH their rows: big as the focus row's title,
    /// small and faded (with ▴/▾) as the labels of the rows above/below.
    static let labelScale: CGFloat = 0.72
    /// The previous catalog's name at the top (above the current one).
    static let showPreviousLabel = false
    static let labelOpacity: Double = 0.6

    // Background

    /// - `.plain`: static dark gradient. Zero per-title work (fastest).
    /// - `.tint`: the title's dominant colour as ONE full-screen layer whose
    ///   colour blends in place, under a static dark gradient.
    /// - `.glow`: blurred backdrop + radial colour glow (prettiest, but
    ///   drops frames when scrolling fast).
    enum BackgroundStyle { case plain, tint, glow }
    static let backgroundStyle: BackgroundStyle = .tint
    /// (`.tint`) Darkened by the shared `StageScrim` (see `StageScrimStyle`),
    /// the same layer as the billboard and the Detail page.
    /// (`.tint`) The title's artwork, pre-blurred, faintly over the colour.
    /// Blurred ahead of time for the neighbours (like the colour), so it
    /// usually follows the press as fast as the colour does.
    static let tintBackdrop = true
    static let tintBackdropOpacity: Double = 0.35
    /// (`.plain`) Colours top → bottom.
    static let plainTop = Color(white: 0.09)
    static let plainBottom = Color(white: 0.02)
    /// (`.glow`) Blurred backdrop layer + glow settings.
    static let ambientBackground = true
    static let ambientOpacity: Double = 0.42
    static let glowStrength: Double = 0.85
    static let glowRadius: CGFloat = 0.8
    static let glowCenterY: CGFloat = 0.5
    static let shadeTop: Double = 0.05
    static let shadeBottom: Double = 0.5
    /// Extracted colours are forced to this brightness (deep, muted tones).
    static let tintBrightness: CGFloat = 0.34
    static let tintSaturationBoost: CGFloat = 1.2
    static let tintMaxSaturation: CGFloat = 0.6
    /// Wait this long on a title before the background follows (0 = instant).
    static let settleDelay: Duration = .zero
    /// How long the background takes to blend to the new colour.
    static let colorFade: Double = 0.35
    /// Colours computed ahead of time on each side of the current title.
    static let tintLookAhead = 4
    static let tintLookBehind = 2

    /// Soft shadows under the cards (re-rendered every animation frame;
    /// barely visible on a dark background). Also respects Settings →
    /// Performance → Card Shadows.
    static let cardShadows = false
}

// MARK: - Billboard dots

/// One dot per title, each at a fixed spot. The current one is large and
/// white; moving on, it shrinks back as the next one grows — in place (no
/// marker travelling between them, so fast paging never stretches the row).
/// Liquid touches: the new dot swells with a little overshoot, arrives
/// stretched the way you paged (as if it had flowed in) and springs round.
private struct BillboardDots: View {
    let count: Int
    let current: Int
    /// The billboard has focus: the current dot is full white (else dimmer).
    let focused: Bool

    static let dot: CGFloat = 12
    static let current: CGFloat = 20
    /// Centre to centre — room for the large one.
    static let pitch: CGFloat = 32
    /// The swell: a spring with a little overshoot.
    static let change: Animation = .spring(response: 0.34, dampingFraction: 0.58)
    /// The arrival stretch, springing back.
    static let settle: Animation = .spring(response: 0.42, dampingFraction: 0.45)
    static let stretch: CGFloat = 0.45

    /// The last page's direction (+1 right, -1 left) — at full strength
    /// right after a step, springing back to 0.
    @State private var pulse: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(count, 0), id: \.self) { k in
                let isCurrent = k == current
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .glassSurface(in: Circle())
                        .overlay { GlassRim(cornerRadius: Self.dot / 2, strength: 1.2) }
                        .opacity(isCurrent ? 0 : 1)
                    Circle()
                        .fill(Color.white.opacity(focused ? 1 : 0.7))
                        .opacity(isCurrent ? 1 : 0)
                }
                .frame(width: isCurrent ? Self.current : Self.dot,
                       height: isCurrent ? Self.current : Self.dot)
                // Arrives stretched the way you paged (from the side it came
                // from), then rounds off.
                .scaleEffect(x: isCurrent ? 1 + Self.stretch * abs(pulse) : 1,
                             y: isCurrent ? 1 - Self.stretch * 0.4 * abs(pulse) : 1,
                             anchor: isCurrent ? (pulse > 0 ? .trailing : .leading) : .center)
                .frame(width: Self.pitch, height: Self.current)
            }
        }
        .animation(Self.change, value: current)
        .animation(.easeOut(duration: 0.2), value: focused)
        .onChange(of: current) { old, new in
            // Wrapping round the ring counts as one step onward.
            let step: CGFloat = new == old + 1 || (old == count - 1 && new == 0) ? 1 : -1
            var jolt = Transaction()
            jolt.disablesAnimations = true
            withTransaction(jolt) { pulse = step }
            // Next turn: in the same update the jolt and the settle merged
            // into one change, and the stretch never showed.
            DispatchQueue.main.async { withAnimation(Self.settle) { pulse = 0 } }
        }
        .opacity(count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Place memory

/// Where Home was left — which row, and the title in each row — kept for
/// the app's lifetime so switching tabs and coming back lands in the same
/// place. (A relaunch starts at the top.)
final class SpotlightMemory {
    static let shared = SpotlightMemory()
    var rowID: String?
    /// Per row id: the title in the box (by title id), and its position as
    /// a fallback for when that title is no longer in the row.
    var items: [String: String] = [:]
    var positions: [String: Int] = [:]
}

// MARK: - Fade shift

/// (`.fade` Up/Down) Moves a view `distance` × `progress` (growing by
/// `grow`, from its top-left) and fades it once `Spotlight.fadeFrom` of the
/// way is done — a small move first, then mostly fade. One animatable value
/// drives all three, so they stay in step.
private struct FadeShift: ViewModifier, Animatable {
    var progress: Double
    let distance: CGFloat
    let grow: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let from = Spotlight.fadeFrom
        let t = min(max((progress - from) / max(1 - from, 0.001), 0), 1)
        content
            .scaleEffect(1 + (grow - 1) * progress, anchor: .topLeading)
            .offset(y: distance * progress)
            .opacity(1 - t * t * (3 - 2 * t))
    }
}

// MARK: - Glide

/// (`.glide` Up/Down) Moves a view `distance` × `progress` and fades it
/// out between `fadeStart` and `fadeEnd` of the way. As an INSERTION the
/// progress runs 1 → 0, so e.g. `fadeStart 0, fadeEnd 0.4` means "appear
/// over the last 40%". One animatable value drives both.
private struct Glide: ViewModifier, Animatable {
    var progress: Double
    let distance: CGFloat
    let fadeStart: Double
    let fadeEnd: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(max((progress - fadeStart) / max(fadeEnd - fadeStart, 0.001), 0), 1)
        content
            .offset(y: distance * progress)
            .opacity(1 - t * t * (3 - 2 * t))
    }
}

// MARK: - Sidebar gate

// MARK: - View

/// Netflix-style Home: ONE catalog row in focus at a time. The first column
/// is a fixed landscape "focus box"; portrait posters of the same height sit
/// to its right. Left/Right never moves focus — it changes which title is in
/// the box, and the row slides underneath. Up/Down switch catalogs: the
/// rows themselves glide between three fixed spots (above / focus / preview)
/// while all text crossfades in place.
///
/// Focus model: the box is the only real focus target. Invisible
/// "sentinels" sit on its edges; a directional press lands on one, the
/// handler performs the step and hands focus straight back to the box.
struct HomeSpotlightView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var layoutSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared

    let rows: [HomeRow]
    let onSelect: (MetaItem) -> Void
    /// Select on the billboard: opens Details WITHOUT the push slide — the
    /// billboard is laid out as the Detail page's top, so it's a swap.
    var onSelectFeatured: ((MetaItem) -> Void)? = nil
    /// Back: hand over to the sidebar (HomeView passes its `onHomeBack`).
    var onBack: () -> Void = {}

    // Continue Watching. HomeView puts it first, as a row with this id, and
    // passes the progress entry behind each of its titles (keyed by title
    // id). In that row Select RESUMES playback instead of opening Details.
    static let continueRowID = "spotlight.continueWatching"
    /// HomeView puts the Featured billboard first, as a row with this id.
    static let featuredRowID = "spotlight.featured"
    var continueProgress: [String: WatchProgress] = [:]
    var onResume: (WatchProgress) -> Void = { _ in }
    var onResumeFromStart: (WatchProgress) -> Void = { _ in }
    var onPlayManually: (WatchProgress) -> Void = { _ in }

    /// Which catalog row is in focus.
    @State private var rowIndex = 0
    /// Position inside each row, keyed by row id, so coming back to a row
    /// lands on the title you left it on.
    @State private var positions: [String: Int] = [:]
    /// The remembered row has been put back (see `restorePlace`).
    @State private var placeRestored = false
    /// Rows whose remembered title has been put back.
    @State private var restoredRows: Set<String> = []

    /// True while the box's trailer is actually on screen — the logo steps
    /// aside for it, and comes back when the trailer ends or you move on.
    @State private var trailerPlaying = false
    /// Up / Back during the billboard's trailer: the page is back, the
    /// trailer runs on muted (see `TrailerMode`).
    @State private var trailerRevealed = false
    /// Details (opened from the billboard) is up / on its way: the
    /// billboard's own parts are out (see `ModeSwap`).
    @State private var swappedToDetail = false
    /// The billboard's backdrop depth, 0…1 (see `ModeSwap.depthHandover`):
    /// Select starts it part-way (Details finishes); back from Details it
    /// arrives part-way and eases out of it with Home's parts.
    @State private var billboardDepth: CGFloat = 0
    /// Box → Details (see `ModeSwap.boxGrow`): the title whose box artwork
    /// grows to the full screen, whether it has grown, and the depth it
    /// carries (like `billboardDepth`). The rest of Home fades meanwhile.
    @State private var growingBox: MetaItem?
    @State private var boxGrown = false
    @State private var boxDepth: CGFloat = 0
    /// The billboard's MDBList ratings and TMDB facts, per title (fetched
    /// as it shows).
    @State private var billboardRatings: [String: MDBListRatings] = [:]
    @State private var billboardFacts: [String: TMDBService.TitleFacts] = [:]
    /// Continue Watching: full-resolution TMDB episode stills, by title id,
    /// replacing the (often small) still stored with the progress entry.
    @State private var sharpStills: [String: String] = [:]
    /// Season/episode counts from TMDB, by title id, for series whose
    /// catalog entry came without an episode list.
    @State private var showSizes: [String: TMDBService.ShowSize] = [:]
    @State private var settledBackdrop: String?
    @State private var ambientImage: UIImage?
    @State private var glowColor: Color?
    /// Direction of the last Up/Down: +1 Down, -1 Up. Sets which way the
    /// rows and names shift as they fade.
    @State private var scrollDirection: CGFloat = 0
    /// Rows are travelling (Up/Down): the logo and caption are hidden.
    @State private var rowMoving = false
    /// (`.scroll`) The preview row drawn OPEN — Down's preparation. nil:
    /// the preview is all posters.
    @State private var openPreviewID: String?
    @State private var rowTask: Task<Void, Never>?
    /// (Ring) The focus row's resistance nudge, and a wrap in progress.
    @State private var wrapNudge: CGFloat = 0
    /// The box's share of a nudge (see `wrapNudgeMovesBox`, `stepNudge`).
    @State private var boxNudge: CGFloat = 0
    @State private var wrapping = false
    /// The end card is being pressed (the ring's resistance).
    @State private var seamPressed = false
    /// The chevron being pressed: -1 left, +1 right, 0 none.
    @State private var pressedChevron = 0
    /// The billboard's section hint being pressed (Down).
    @State private var downPressed = false
    /// The box's liquid stretch (points; + right, − left).
    @State private var boxStretch: CGFloat = 0
    @State private var stretchTask: Task<Void, Never>?
    private enum Slot: Hashable { case box, left, right, up, down }
    @FocusState private var focus: Slot?

    /// Fixed vertical positions, computed from the screen height.
    private struct Layout {
        let topLabelY: CGFloat
        let headerY: CGFloat
        let rowY: CGFloat
        let infoY: CGFloat
        let bottomLabelY: CGFloat
        let previewY: CGFloat
        /// The billboard: from the top margin down to just above the next
        /// row's label, full width minus the right margin.
        let featuredY: CGFloat
        let featuredSize: CGSize
        /// The billboard's artwork fills this (full bleed).
        let screen: CGSize
    }

    // MARK: Derived state

    private var row: HomeRow? {
        rows.indices.contains(rowIndex) ? rows[rowIndex] : nil
    }

    /// The title in the box, 0..<count. `positions` holds each row's
    /// VIRTUAL position — it keeps counting past the end (the row is a
    /// ring), so every card keeps its identity round the loop and slides on.
    private func position(in row: HomeRow) -> Int {
        guard !row.items.isEmpty else { return 0 }
        return wrap(virtualPosition(in: row), row.items.count)
    }

    private func virtualPosition(in row: HomeRow) -> Int {
        let v = positions[row.id] ?? 0
        return loops(row) ? v : min(max(v, 0), max(row.items.count - 1, 0))
    }

    /// Rings: catalogs with at least `minRingCount` titles, and the
    /// billboard (a carousel). Continue Watching and short rows end.
    private func loops(_ row: HomeRow) -> Bool {
        if isFeatured(row) { return row.items.count > 1 }
        return !isContinueRow(row) && row.items.count >= Spotlight.minRingCount
    }

    /// Gaps (end → start) crossed going from virtual `a` to `b` (a ≤ b).
    private func gaps(_ row: HomeRow, from a: Int, to b: Int) -> Int {
        guard loops(row), b > a else { return 0 }
        let n = Double(row.items.count)
        // Multiples of n in (a, b].
        return Int((Double(b) / n).rounded(.down)) - Int((Double(a) / n).rounded(.down))
    }

    private func wrap(_ k: Int, _ n: Int) -> Int { ((k % n) + n) % n }

    private var itemIndex: Int { row.map { position(in: $0) } ?? 0 }

    private var item: MetaItem? {
        guard let row, row.items.indices.contains(itemIndex) else { return nil }
        return row.items[itemIndex]
    }

    private func isContinueRow(_ row: HomeRow) -> Bool { row.id == Self.continueRowID }
    private func isFeatured(_ row: HomeRow) -> Bool { row.id == Self.featuredRowID }

    /// Size of the focus box for a row: the billboard for Featured, the
    /// regular landscape box everywhere else.
    private func boxSize(for row: HomeRow, _ spots: Layout) -> CGSize {
        isFeatured(row) ? spots.featuredSize
                        : CGSize(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
    }

    /// The progress entry behind the title in the box — only in Continue
    /// Watching.
    private var currentProgress: WatchProgress? {
        guard let row, isContinueRow(row), let item else { return nil }
        return continueProgress[item.id]
    }

    private var leadingInset: CGFloat { Spotlight.screenInset }

    /// The left step target spans the gap between the screen edge and the box.
    private var leftSentinelWidth: CGFloat { max(leadingInset - 110, 20) }

    /// Home doesn't dim its own content while focus is in the top bar.
    private var unfocusedOpacity: Double { 1 }

    private var topPadding: CGFloat { Spotlight.topPaddingUnderNav }

    private var showsAmbient: Bool {
        Spotlight.ambientBackground && !PerformanceProfile.isLowPower
    }

    private var cardShadows: Bool { Spotlight.cardShadows && perf.settings.cardShadows }

    // MARK: Body

    var body: some View {
        // Everything is sized to the SCREEN, explicitly — the rows are wider
        // than the screen and must run off the right edge, not widen the
        // layout (which centred it and pushed it off the left edge).
        GeometryReader { geo in
            content(screen: geo.size)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .defaultFocus($focus, .box)
        // A directional press landed on a sentinel: do the step, then hand
        // focus straight back to the box. Only a move that STARTED on the box
        // counts — focus arriving on a sentinel from elsewhere steps nothing.
        .onChange(of: focus) { old, new in
            guard let new, new != .box else { return }
            if old == .box {
                switch new {
                case .left:  step(by: -1)
                case .right: step(by: 1)
                case .up:    changeRow(by: -1)
                case .down:  changeRow(by: 1)
                case .box:   break
                }
            }
            focus = .box
        }
        // Rows can be replaced by a refresh or sync; never point past the end.
        .onChange(of: rows.count) { _, count in
            if rowIndex >= count { rowIndex = max(count - 1, 0) }
        }
        // Home is rebuilt on every tab switch: pick up where it was left —
        // same row (by id, so a row appearing above doesn't shift it), same
        // title in every row. Rows may still be loading, so retry as they
        // arrive until the remembered row is there.
        .onAppear { restorePlace() }
        // Trailer mode: the top bar goes with the page (and comes back).
        .onChange(of: trailerMode) { _, on in
            withAnimation(on ? ModeSwap.out : ModeSwap.in) { ModeSwap.shared.trailerChromeOut = on }
        }
        // A trailer ending (or stopped) starts the next one from scratch.
        .onChange(of: trailerPlaying) { _, playing in
            if !playing { trailerRevealed = false }
        }
        .onDisappear { ModeSwap.shared.trailerChromeOut = false }
        // Back from Details: RootView brings the top bar back (on the pop)
        // and the billboard's parts come in with it, in the same animation.
        .onReceive(ModeSwap.shared.$homeChromeOut) { out in
            if !out && swappedToDetail { swappedToDetail = false }
            // Back from Details opened from a box: the backdrop shrinks back
            // into the box, Home fades back in around it.
            if !out, growingBox != nil, boxGrown {
                withAnimation(ModeSwap.boxGrow) {
                    boxGrown = false
                    boxDepth = 0
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ModeSwap.boxGrowDuration))
                    guard !boxGrown else { return }
                    growingBox = nil
                }
            }
            if !out && billboardDepth > 0 {
                withAnimation(ModeSwap.in) { billboardDepth = 0 }
            }
        }
        // (Also when a row's titles arrive after the row itself.)
        .onChange(of: rows.map { "\($0.id)#\($0.items.count)" }) { _, _ in restorePlace() }
        .onChange(of: rowIndex) { _, index in
            if rows.indices.contains(index) { SpotlightMemory.shared.rowID = rows[index].id }
        }
        .onChange(of: positions) { _, positions in
            // Remember the TITLE in each row, not just its number: a
            // catalog can come back reloaded or reshuffled.
            for (rowID, virtual) in positions {
                guard let row = rows.first(where: { $0.id == rowID }),
                      !row.items.isEmpty else { continue }
                let index = wrap(virtual, row.items.count)
                SpotlightMemory.shared.items[rowID] = row.items[index].id
                SpotlightMemory.shared.positions[rowID] = index
            }
        }
        // Background colour for the title in the box (pre-computed for the
        // neighbours, so it's usually a cache hit and follows the press).
        .task(id: item?.id) {
            guard Spotlight.backgroundStyle != .plain else { return }
            guard let item, let row else { return }
            if Spotlight.settleDelay > .zero {
                try? await Task.sleep(for: Spotlight.settleDelay)
                guard !Task.isCancelled else { return }
            }
            let url = item.background ?? item.poster
            var color: Color?
            if let url { color = await SpotlightTint.color(for: url) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Spotlight.colorFade)) {
                settledBackdrop = url
                if let color { glowColor = color }
            }
            let wantsBlur = showsAmbient && (Spotlight.backgroundStyle == .glow
                || (Spotlight.backgroundStyle == .tint && Spotlight.tintBackdrop))
            if wantsBlur, let url {
                let blurred = await ImageCache.shared.blurredImage(for: url, screenBlurRadius: 50)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: Spotlight.colorFade)) { ambientImage = blurred }
            }
            let neighbours = neighbourBackdrops(in: row, around: itemIndex)
            await SpotlightTint.warm(urls: neighbours)
            // Blur the neighbours ahead of time too (memory-cached), so the
            // next press finds its backdrop ready — as instant as the colour.
            if wantsBlur {
                for next in neighbours {
                    guard !Task.isCancelled else { return }
                    _ = await ImageCache.shared.blurredImage(for: next, screenBlurRadius: 50)
                }
            }
        }
        // Continue Watching: fetch sharp TMDB stills for the title in the box
        // and its neighbours (TMDBService caches whole seasons, so stepping
        // along usually costs nothing).
        .task(id: "\(row?.id ?? "")#\(itemIndex)") {
            guard let row, isContinueRow(row), !row.items.isEmpty else { return }
            let window = max(itemIndex - 1, 0)...min(itemIndex + 2, row.items.count - 1)
            for index in window where sharpStills[row.items[index].id] == nil {
                let id = row.items[index].id
                guard let progress = continueProgress[id] else { continue }
                if let still = await EpisodeStill.url(metaID: progress.metaID, type: progress.type,
                                                      season: progress.season, episode: progress.episode) {
                    guard !Task.isCancelled else { return }
                    sharpStills[id] = still
                }
            }
        }
        // Season/episode counts for the meta line: the title in the box and
        // the next two (so stepping right finds them ready). Only series
        // without an episode list of their own; needs a TMDB key.
        .task(id: "\(row?.id ?? "")#\(itemIndex)#size") {
            guard TMDBService.hasAPIKey, let row, !row.items.isEmpty else { return }
            let window = itemIndex...min(itemIndex + 2, row.items.count - 1)
            for index in window {
                let candidate = row.items[index]
                guard candidate.isSeries, candidate.regularSeasons.isEmpty,
                      showSizes[candidate.id] == nil else { continue }
                if let size = await TMDBService.showSize(imdbID: candidate.id, type: candidate.type) {
                    guard !Task.isCancelled else { return }
                    showSizes[candidate.id] = size
                }
            }
        }
    }

    // MARK: Layout

    private func layout(_ screen: CGSize) -> Layout {
        let previewY = Spotlight.showNextRowPreview
            ? screen.height - Spotlight.previewVisibleHeight
            : screen.height + Spotlight.incomingPreviewRise
        let bottomLabelY = Spotlight.showNextRowPreview
            ? previewY - Spotlight.labelToPreviewGap - Spotlight.labelHeight
            : screen.height - 48 - Spotlight.labelHeight
        // Centre the main block (header, row, info) between the two labels.
        let topLabelY = topPadding
        let headerY = Spotlight.catalogTitleY(screenHeight: screen.height, topPadding: topPadding)
        let rowY = headerY + Spotlight.headerHeight + Spotlight.headerToRowGap
        let infoY = rowY + Spotlight.rowHeight + Spotlight.rowToInfoGap
        let featuredY = topPadding
        let featuredSize = CGSize(
            width: screen.width - leadingInset - Spotlight.featuredRightMargin,
            height: bottomLabelY - Spotlight.featuredBottomGap - featuredY)
        return Layout(topLabelY: topLabelY, headerY: headerY, rowY: rowY,
                      infoY: infoY, bottomLabelY: bottomLabelY, previewY: previewY,
                      featuredY: featuredY, featuredSize: featuredSize, screen: screen)
    }

    private func content(screen: CGSize) -> some View {
        let spots = layout(screen)
        let rowWidth = screen.width - leadingInset

        return ZStack(alignment: .topLeading) {
            background(screen: screen)
                .frame(width: screen.width, height: screen.height)
                .clipped()

            if let row, let item {
                Group {
                // The rows — the only things that MOVE on Up/Down.
                rowStrips(width: rowWidth, spots: spots)

                // Title-level text — fades in place, never travels.
                if isFeatured(row) {
                    billboardText(item, row: row, screen: spots.screen)
                }

                // The stationary focus spot: box outline, logo, chevrons and
                // the invisible focus targets. Never moves; between the
                // billboard and a regular row it SWITCHES size instantly —
                // animated, its logo scrim visibly slid and stretched from
                // one to the other. (The text in it still fades.)
                focusLayer(row: row, width: rowWidth, box: boxSize(for: row, spots))
                    .placed(x: leadingInset, y: isFeatured(row) ? spots.featuredY : spots.rowY)
                    .transaction(value: isFeatured(row)) { $0.animation = nil }
                }
                // Box → Details: everything but the growing box fades —
                // quickly (scoped: only the opacity is re-timed).
                .animation(ModeSwap.boxHomeFade) { $0.opacity(boxGrown ? 0 : 1) }
                growingBoxLayer(spots: spots)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Specular edge: bright at the top-left, fading towards the
    /// bottom-right, like light catching the rim of a glass pane.
    /// The shared glass rim (see `GlassRim`).
    private func edgeHighlight(opacity: Double = 1) -> some View {
        GlassRim(cornerRadius: Spotlight.cornerRadius, strength: opacity)
    }

    // MARK: Rows (moving)

    private struct RowEntry: Identifiable {
        let index: Int
        let row: HomeRow
        let role: Int
        /// Keyed by row: on Up/Down each row keeps its view and TRAVELS to
        /// its new spot.
        var id: String { row.id }
        /// (`.fade`) Keyed by role AND row: every slot gets a new view on
        /// Up/Down, so the old one fades out and the new one in.
        var fadeID: String { "\(role)|\(row.id)" }
        /// The key the current vertical style uses.
        var styledID: String { Spotlight.verticalStyle == .scroll ? id : fadeID }
    }

    private func entries(roles: ClosedRange<Int>) -> [RowEntry] {
        roles.map { rowIndex + $0 }
            .filter { rows.indices.contains($0) }
            .map { RowEntry(index: $0, row: rows[$0], role: $0 - rowIndex) }
    }

    /// Open = drawn with its box: the focus row, and the row above
    /// (off-screen, ready to scroll back in). The preview is all posters.
    private func isOpen(_ entry: RowEntry) -> Bool {
        entry.role <= 0 || entry.row.id == openPreviewID
    }

    /// The row above, the focus row and the preview row, each at its spot.
    /// On Up/Down they scroll together to their new spots.
    private func rowStrips(width: CGFloat, spots: Layout) -> some View {
        ZStack(alignment: .topLeading) {
            // The stage: the billboard's artwork (the rows' is the
            // background), then THE scrim — the same everywhere, never
            // dimmed — then the content on top.
            ForEach(entries(roles: -1...1).filter { isFeatured($0.row) }, id: \.styledID) { entry in
                featuredArt(entry.row, size: spots.screen, isFocusRow: entry.role == 0)
                    .frame(width: spots.screen.width, height: spots.screen.height)
                    .offset(x: -leadingInset, y: rowY(for: entry.role, featured: true, spots))
                    // Artwork is stage, not content: it doesn't dim when
                    // focus goes to the top bar (only leaves with its row).
                    .opacity(entry.role == 0 ? 1 : rowOpacity(for: entry.role))
                    .transition(styledTransition(role: entry.role, spots: spots))
            }
            StageScrim()
                .frame(width: spots.screen.width, height: spots.screen.height)
                .offset(x: -leadingInset)
                // Eased back while the billboard's trailer plays.
                .opacity(trailerMode ? TrailerMode.scrimOpacity : trailerPlaying ? 0.5 : 1)
                .animation(TrailerMode.fade, value: trailerMode)
                .animation(.easeInOut(duration: 0.4), value: trailerPlaying)

            switch Spotlight.verticalStyle {
            case .scroll:
                ForEach(entries(roles: -1...1).filter { !isFeatured($0.row) }) { entry in
                    let y = rowY(for: entry.role, featured: isFeatured(entry.row), spots)
                    rowContent(entry, width: width, spots: spots, y: y, showBox: true)
                        .offset(y: y)
                        .transition(scrollTransition(spots, fades: false))
                }
            case .fade:
                ForEach(entries(roles: 0...1).filter { !isFeatured($0.row) }, id: \.fadeID) { entry in
                    let y = rowY(for: entry.role, featured: isFeatured(entry.row), spots)
                    rowContent(entry, width: width, spots: spots, y: y, showBox: false)
                        .offset(y: y)
                        .transition(fadeTransition(role: entry.role))
                }
                // The box: never moves, crossfades to the new row's title.
                if let row, !isFeatured(row) {
                    stationaryBox()
                        .offset(y: spots.rowY)
                        .opacity(focus == nil ? unfocusedOpacity : 1)
                }
            case .glide:
                ForEach(entries(roles: 0...1).filter { !isFeatured($0.row) }, id: \.fadeID) { entry in
                    let y = rowY(for: entry.role, featured: isFeatured(entry.row), spots)
                    rowContent(entry, width: width, spots: spots, y: y, showBox: false,
                               titles: false)
                        .offset(y: y)
                        .transition(glideTransition(role: entry.role, spots: spots))
                }
                // The box: never moves. Keyed by row, so on Up/Down the new
                // row's box fades in (as the travellers arrive) over the old.
                ForEach(row.flatMap { isFeatured($0) ? nil : [$0] } ?? [], id: \.id) { _ in
                    stationaryBox()
                        .offset(y: spots.rowY)
                        .opacity(focus == nil ? unfocusedOpacity : 1)
                        .transition(.asymmetric(
                            insertion: glide(0, from: 0, to: Spotlight.glideAppear),
                            removal: glide(0, from: 1 - Spotlight.glideAppear, to: 1)))
                }
                // The names: in place, swapping text.
                ForEach(entries(roles: -1...1), id: \.fadeID) { entry in
                    rowTitle(entry.row, role: entry.role)
                        .offset(y: namesInPlaceY(entry.role, spots))
                        .transition(.opacity.animation(Spotlight.textFade))
                }
            }
        }
        .padding(.leading, leadingInset)
        .allowsHitTesting(false)
    }

    /// One row's view at its spot: its cards (and, `showBox`, its own box),
    /// its name, its info, and — in focus — the "▴" label above.
    @ViewBuilder
    private func rowContent(_ entry: RowEntry, width: CGFloat, spots: Layout, y: CGFloat,
                            showBox: Bool, titles: Bool = true) -> some View {
        let featured = isFeatured(entry.row)
        ZStack(alignment: .topLeading) {
            Group {
                if featured {
                    featuredArt(entry.row, size: spots.screen,
                                isFocusRow: entry.role == 0)
                } else {
                    stripVisual(entry.row, open: isOpen(entry), isFocusRow: entry.role == 0,
                                    showBox: showBox)
                }
            }
            .frame(width: featured ? spots.screen.width : width,
                   height: featured ? spots.screen.height : Spotlight.rowHeight,
                   alignment: .topLeading)
            // Full bleed: from the screen's own corner, past the margin.
            .offset(x: featured ? -leadingInset : 0)
            .opacity(rowOpacity(for: entry.role))

            // Each row CARRIES its texts, rigidly — they scroll
            // exactly with it: its own name (a title above the box,
            // or the "▾" label at the preview spot) and, above
            // that, the "▴" label naming the row before it — shown
            // only while it's the focus row.
            if titles {
                // (Under the billboard the next row's name is the billboard's
                // section hint instead — this one fades in as the row comes
                // up.)
                let underBillboard = entry.role == 1 && (row.map(isFeatured) ?? false)
                rowTitle(entry.row, role: entry.role == -1 ? 0 : entry.role)
                    .offset(y: titleY(for: entry.role, spots) - y)
                    // Leaving at the top: fades with its row.
                    .opacity(entry.role == -1 || underBillboard ? 0 : 1)
            }
            // Its info under the first card — it rides along with the row.
            if !featured, entry.row.items.indices.contains(position(in: entry.row)) {
                let item = entry.row.items[position(in: entry.row)]
                info(for: item, progress: isContinueRow(entry.row)
                        ? continueProgress[item.id] : nil)
                    .frame(height: Spotlight.infoHeight, alignment: .topLeading)
                    .offset(y: Spotlight.rowHeight + Spotlight.rowToInfoGap)
                    .opacity(rowOpacity(for: entry.role))
            }
            // Its chevrons — carried by the row, shown while it's in focus.
            if !featured {
                rowChevrons(entry, width: width)
            }
            if titles, Spotlight.showPreviousLabel, entry.index > 0 {
                rowTitle(rows[entry.index - 1], role: -1)
                    .offset(y: spots.topLabelY - spots.rowY)
                    .opacity(entry.role == 0 ? 1 : 0)
            }
    }
    }

    /// (`.glide`) One view's movement: `distance` × progress, faded out
    /// between `from` and `to` of the way (see `Glide`).
    private func glide(_ distance: CGFloat, from: Double, to: Double) -> AnyTransition {
        .modifier(active: Glide(progress: 1, distance: distance, fadeStart: from, fadeEnd: to),
                  identity: Glide(progress: 0, distance: distance, fadeStart: from, fadeEnd: to))
    }

    /// (`.glide`) Down: the preview row travels straight up to the focus
    /// line, fading as it gets there; the old focus row moves out of the
    /// way (up a little, fading early); the new content appears in place
    /// at the end. Up: the focus row travels down to the preview spot the
    /// same way; the old preview makes way downward.
    private func glideTransition(role: Int, spots: Layout) -> AnyTransition {
        let pitch = spots.previewY - spots.rowY
        let down = scrollDirection > 0
        let appear = glide(0, from: 0, to: Spotlight.glideAppear)
        let travel = glide((down ? -1 : 1) * pitch, from: Spotlight.glideFadeStart, to: 1)
        let leave = glide((down ? -1 : 1) * Spotlight.glideLeaveShift, from: 0, to: 0.6)
        let travels = (role == 1) == down
        return .asymmetric(insertion: appear, removal: travels ? travel : leave)
    }

    /// (`.glide`) Where each name stays: "▴" at the top, the title above
    /// the box, "▾" above the preview (under the billboard, at the bottom).
    private func namesInPlaceY(_ role: Int, _ spots: Layout) -> CGFloat {
        switch role {
        case 0:  return spots.headerY
        case 1:  return (row.map(isFeatured) ?? false)
                     ? TitleBlock.hintY(screenHeight: spots.screen.height) : spots.bottomLabelY
        default: return spots.topLabelY
        }
    }

    /// (`.fade`) Up/Down: a small move, then a heavy fade (see
    /// `FadeShift`). On Down the preview grows toward the box as it goes.
    private func fadeTransition(role: Int) -> AnyTransition {
        let shift = scrollDirection * Spotlight.fadeShift
        let fade = { (distance: CGFloat, grow: CGFloat) -> AnyTransition in
            .modifier(active: FadeShift(progress: 1, distance: distance, grow: grow),
                      identity: FadeShift(progress: 0, distance: distance, grow: grow))
        }
        let removal = role == 1 && scrollDirection > 0
            ? fade(-Spotlight.fadeShift * Spotlight.previewTravel, Spotlight.previewGrow)
            : fade(-shift, 1)
        return .asymmetric(insertion: fade(shift, 1), removal: removal)
    }

    /// The Up/Down transition of the current vertical style.
    private func styledTransition(role: Int, spots: Layout) -> AnyTransition {
        switch Spotlight.verticalStyle {
        case .scroll: return scrollTransition(spots, fades: false)
        case .fade:   return fadeTransition(role: role)
        case .glide:  return glideTransition(role: role, spots: spots)
        }
    }

    private func rowY(for role: Int, featured: Bool, _ spots: Layout) -> CGFloat {
        if featured {
            // Only ever focus or above (it's the first row).
            return role == 0 ? 0 : -spots.screen.height
        }
        switch role {
        case 0:  return spots.rowY
        case 1:  return spots.previewY
        // Just off the top edge — with the info it carries below it —
        // ready to scroll in on Up.
        default: return -(Spotlight.rowHeight + Spotlight.rowToInfoGap + Spotlight.infoHeight + 40)
        }
    }

    private func pitch(_ spots: Layout) -> CGFloat { spots.previewY - spots.rowY }

    /// Rows (and names) entering or leaving the window scroll in and out
    /// the same way the others move: Down, in from below and out at the
    /// top; Up, the reverse.
    private func scrollTransition(_ spots: Layout, fades: Bool) -> AnyTransition {
        let shift = scrollDirection * pitch(spots)
        let move = AnyTransition.asymmetric(insertion: .offset(y: shift),
                                            removal: .offset(y: -shift))
        return fades ? move.combined(with: .opacity) : move
    }

    private func rowOpacity(for role: Int) -> Double {
        switch role {
        case 0:  return focus == nil ? unfocusedOpacity : 1
        // Not under the billboard: there only the "▾" label says what's next.
        case 1:  return Spotlight.showNextRowPreview && !(row.map(isFeatured) ?? false)
                     ? Spotlight.previewOpacity : 0
        // The row above fades as it scrolls away (and in as it scrolls
        // back) — like a poster sliding under the box on Left/Right.
        default: return 0
        }
    }

    /// The billboard's artwork: the featured title's backdrop, crossfading
    /// on Left/Right — drawn EXACTLY like the Detail page's backdrop (same
    /// image size; the shared `StageScrim` goes over it in `rowStrips`),
    /// which it becomes on Select.
    private func featuredArt(_ row: HomeRow, size: CGSize, isFocusRow: Bool) -> some View {
        let current = position(in: row)
        let item = row.items.indices.contains(current) ? row.items[current] : nil
        return ZStack {
            Color.black.opacity(0.3)
            if let item {
                RemoteImage(url: item.background ?? item.poster,
                            maxPixels: PerformanceProfile.backdropPixelCap)
                    .frame(width: size.width, height: size.height)
                    .id(item.id)
                    .transition(.opacity)
            }
            // Full-bleed trailer (a regular row's plays in its box).
            // Only while the billboard IS the focus row: Down stops it.
            SpotlightTrailerLayer(item: item, active: focus != nil && isFocusRow,
                                  isPlaying: $trailerPlaying,
                                  // The billboard's plays with sound — muted
                                  // once Up / Back brought the page back.
                                  sound: !trailerRevealed,
                                  delay: TrailerMode.delay)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        // Back from Details: arrives in its depth, eases out of it.
        .overlay { Color.black.opacity(ModeSwap.depthDim(billboardDepth)) }
        .scaleEffect(ModeSwap.depthScale(billboardDepth))
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: trailerPlaying)
    }

    /// One row. OPEN: the current title is the landscape box and the
    /// posters start after it — the current title's own poster sits BEHIND
    /// the box, so on Left/Right a poster stepping into focus slides under
    /// the box instead of widening inside it. CLOSED: all posters, the
    /// current one first. Opening widens the box from poster size (from
    /// its middle) while the posters beside it slide right to make room.
    private func stripVisual(_ row: HomeRow, open: Bool, isFocusRow: Bool,
                             showBox: Bool = true) -> some View {
        let n = row.items.count
        let v = virtualPosition(in: row)
        let current = position(in: row)
        let isContinue = isContinueRow(row)
        let cardWidth = self.cardWidth(row)
        let slotWidth = cardWidth + Spotlight.spacing
        let first = loops(row) ? v - 2 : max(v - 2, 0)
        let last = loops(row) ? v + Spotlight.postersAhead : min(v + Spotlight.postersAhead, n - 1)
        let afterStart = (open ? Spotlight.boxWidth : cardWidth) + Spotlight.spacing
        // The end card takes one card slot between the last title and the
        // first.
        let gap = slotWidth

        // x of virtual card k. The current one: in the focus row it waits
        // at the box's right end (Left/Right slides the next one in under
        // the box from there); anywhere else it stays at the start while
        // its row opens, fading as the box grows out of it. After it: the
        // cards after the box. Before it: the previous ones, left of the
        // box — the nearest peeking into the margin. Plus the end card's
        // slot for every end → start crossed.
        func x(_ k: Int) -> CGFloat {
            if k == v { return open && isFocusRow ? Spotlight.boxWidth - cardWidth : 0 }
            if k > v {
                return afterStart + CGFloat(k - v - 1) * slotWidth
                    + CGFloat(gaps(row, from: v, to: k)) * gap
            }
            return -CGFloat(v - k) * slotWidth - CGFloat(gaps(row, from: k, to: v)) * gap
        }

        return ZStack(alignment: .topLeading) {
            if n > 0 {
                ForEach(Array(first...max(first, last)), id: \.self) { k in
                    let item = row.items[wrap(k, n)]
                    poster(item,
                           continueEntry: isContinue ? continueProgress[item.id] : nil,
                           landscape: isContinue)
                        .offset(x: x(k))
                        // The previous card peeks (across the gap it's off
                        // screen anyway); older ones have slid away; the
                        // current one is under the open box — so a dimmed
                        // row never shows it through.
                        .opacity(k < v - 1 || (open && k == v) ? 0 : 1)
                }
                // The end cards: in the slot before every card that starts
                // the row again. Left of the current title (the first) it
                // only peeks into the margin — there just the ↺.
                ForEach(Array(first...max(first, last)).filter { loops(row) && wrap($0, n) == 0 },
                        id: \.self) { k in
                    endCard(row, compact: k == v, pressed: isFocusRow && seamPressed)
                        .offset(x: (k == v ? 0 : x(k)) - slotWidth)
                        .opacity(k >= v ? 1 : 0)
                }
            }
            if showBox {
                boxArt(row, current: current, open: open, isFocusRow: isFocusRow)
                    // Takes back the cards' nudge, plus its own share.
                    .offset(x: isFocusRow ? boxNudge - wrapNudge : 0)
            }
        }
        // The ring's resistance: the cards give a little before it turns.
        .offset(x: isFocusRow ? wrapNudge : 0)
    }

    /// A row's box. Always mounted — closed it's a hidden poster-sized card
    /// — so its backdrop is loaded before it opens. In the focus row it
    /// never moves on Left/Right: its artwork crossfades in place, with
    /// the neighbours' backdrops mounted invisibly so that's instant. It
    /// carries the focus outline, so the outline travels with it.
    /// Every OPEN box has its own outline — the old one leaves (fading)
    /// with its row, the new one opens with its box. Never handed over.
    /// Every open box carries its outline — it appears, moves, resizes and
    /// disappears together with the box, never separately.
    private func boxArt(_ row: HomeRow, current: Int, open: Bool, isFocusRow: Bool) -> some View {
        boxView(boxCandidates(row, current: current, neighbours: isFocusRow),
                open: open, closedWidth: cardWidth(row), outlined: focus != nil,
                stretch: isFocusRow ? boxStretch : 0)
    }

    /// A row's box candidates: its current title, plus — `neighbours` —
    /// the titles either side (so Left/Right finds them loaded).
    private func boxCandidates(_ row: HomeRow, current: Int, neighbours: Bool) -> [BoxCandidate] {
        var candidates: [BoxCandidate] = []
        let n = row.items.count
        guard n > 0 else { return [] }
        // Either side wraps around (the row loops); a short row can bring
        // the same title twice — keep it once.
        var seen = Set<Int>()
        for offset in neighbours ? [0, -1, 1] : [0] {
            let raw = current + offset
            guard loops(row) || (0..<n).contains(raw) else { continue }
            let index = wrap(raw, n)
            guard seen.insert(index).inserted else { continue }
            candidates.append(BoxCandidate(
                id: "\(row.id)#\(index)", item: row.items[index],
                isContinue: isContinueRow(row), shown: index == current))
        }
        return candidates
    }

    /// (`.fade`) The box on the fixed spot: the focus row's titles, and the
    /// rows above and below's current ones — all mounted, so Up/Down is a
    /// crossfade of loaded artwork, like Left/Right.
    private func stationaryBox() -> some View {
        var candidates: [BoxCandidate] = []
        for offset in [-1, 0, 1] where rows.indices.contains(rowIndex + offset) {
            let row = rows[rowIndex + offset]
            guard !isFeatured(row), !row.items.isEmpty else { continue }
            for candidate in boxCandidates(row, current: position(in: row), neighbours: offset == 0) {
                candidates.append(BoxCandidate(
                    id: candidate.id, item: candidate.item, isContinue: candidate.isContinue,
                    shown: offset == 0 && candidate.shown))
            }
        }
        return boxView(candidates, open: true, closedWidth: Spotlight.posterWidth,
                       outlined: focus != nil)
    }

    private func boxView(_ candidates: [BoxCandidate], open: Bool, closedWidth: CGFloat,
                         outlined: Bool, stretch: CGFloat = 0) -> some View {
        // (Continue Watching: a softer foot for its state line.)
        let showsScrim = candidates.contains { !$0.isContinue } || Spotlight.continueShowsLogo
        let showsFoot = !showsScrim && candidates.contains { $0.isContinue }
        return ZStack {
            Color.black
            ForEach(candidates) { candidate in
                let item = candidate.item
                RemoteImage(url: (candidate.isContinue ? sharpStills[item.id] : nil)
                                 ?? item.background ?? item.poster,
                            maxDimension: Spotlight.boxWidth)
                    .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
                    .opacity(candidate.shown ? 1 : 0)
                    // The incoming title fades in ON TOP, whichever way
                    // you stepped.
                    .zIndex(candidate.shown ? 1 : 0)
            }
            // The constant slight dimming (see `boxDim`).
            Color.black.opacity(Spotlight.boxDim)
                .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
            // Dark behind the logo (drawn on the fixed spot). The same for
            // every title, so it's part of the box: it travels with it and
            // never crossfades — and stays under the outline.
            if showsScrim || showsFoot {
                LinearGradient(colors: [.clear, .black.opacity(showsScrim ? Spotlight.logoScrimOpacity
                                                                          : Spotlight.continueFootOpacity)],
                               startPoint: showsScrim ? .center : Spotlight.continueFootStart,
                               endPoint: .bottom)
                    .frame(width: Spotlight.boxWidth, height: Spotlight.rowHeight)
            }
        }
        // Closed: poster-wide, showing the backdrop's LEFT part — it opens
        // to the right, its left edge (and the logo) staying put.
        // (+ `stretch`: the liquid step — wider toward the pressed side.)
        .frame(width: (open ? Spotlight.boxWidth : closedWidth) + abs(stretch),
               height: Spotlight.rowHeight, alignment: .leading)
        // The logo (and Continue Watching's progress bar) are PART of the
        // box: they travel with their row on Up/Down and grow with the box
        // as it opens; on Left/Right they crossfade with the artwork. Every
        // candidate's logo is mounted, so it's loaded before it's needed.
        .overlay(alignment: .bottomLeading) {
            ZStack(alignment: .bottomLeading) {
                ForEach(candidates) { candidate in
                    boxLogo(candidate)
                        .opacity(candidate.shown ? 1 : 0)
                        .zIndex(candidate.shown ? 1 : 0)
                }
            }
            .scaleEffect(open ? 1 : closedWidth / Spotlight.boxWidth, anchor: .bottomLeading)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                ForEach(candidates) { candidate in
                    if candidate.isContinue, let entry = continueProgress[candidate.item.id] {
                        continueState(entry, width: (open ? Spotlight.boxWidth : closedWidth)
                                          - 2 * Spotlight.progressBarInset)
                            .padding(.bottom, Spotlight.progressBarBottomInset)
                            .opacity(candidate.shown ? 1 : 0)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
        // The same glass rim as the posters (under the focus outline).
        .overlay { if Spotlight.cardEdgeHighlight { edgeHighlight() } }
        // The focus outline is part of the box too: it travels with the
        // row, grows with the box as it opens (and fades in with it), and
        // sits above the logo and its scrim, so nothing darkens it.
        .overlay { boxFrame(focused: outlined) }
        .opacity(open ? 1 : 0)
        .shadow(color: cardShadows ? .black.opacity(0.45) : .clear,
                radius: cardShadows ? 22 : 0, y: cardShadows ? 10 : 0)
        // Stretching left: grow to the left (the right edge stays).
        .offset(x: min(stretch, 0))
    }

    /// Continue Watching: how far along a box title is, when worth a bar.
    private func boxProgress(_ candidate: BoxCandidate) -> Double? {
        guard candidate.isContinue,
              let fraction = continueProgress[candidate.item.id]?.fraction,
              fraction > 0.02 else { return nil }
        return fraction
    }

    /// A box title's logo, bottom-left (above the progress bar if any).
    /// None in Continue Watching unless `continueShowsLogo`.
    @ViewBuilder
    private func boxLogo(_ candidate: BoxCandidate) -> some View {
        if !candidate.isContinue || Spotlight.continueShowsLogo {
            logo(for: candidate.item)
                .padding(Spotlight.logoInset)
                .padding(.bottom, boxProgress(candidate) == nil ? 0
                         : Spotlight.continueProgressBarHeight + Spotlight.progressBarBottomInset
                           - Spotlight.logoInset / 2)
        }
    }

    private struct BoxCandidate: Identifiable {
        let id: String
        let item: MetaItem
        let isContinue: Bool
        let shown: Bool
    }

    /// The card between a row's end and its start again: the size of the
    /// row's cards, the app's glass, "↺ Back to start".
    /// `compact`: only its right edge shows (peeking left of the first
    /// title) — just the glass edge; the ‹ chevron sits over it there.
    /// The name in place of a logo (none, or it failed to load).
    private func logoText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .frame(width: Spotlight.logoMaxWidth, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.6), radius: 10, y: 3)
    }

    private func endCard(_ row: HomeRow, compact: Bool, pressed: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous)
        return ZStack {
            // The app's glass surface (see `AppGlass`).
            Color.clear.glassSurface(in: shape)
            // (Compact: no content — the ‹ chevron takes that margin.)
            // Always part of the card (so it moves WITH it); only hidden
            // while compact.
            VStack(spacing: 16) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 44, weight: .semibold))
                Text("Back to start")
                    .font(.system(size: 24, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .foregroundStyle(AppGlass.textMuted)
            .opacity(compact ? 0 : 1)
        }
        .frame(width: cardWidth(row), height: Spotlight.rowHeight)
        // Pressed (the ring's resistance): gives a little and brightens,
        // like a glass button under the finger. (Compact: its visible right
        // edge is what gives.)
        .overlay {
            shape.fill(Color.white.opacity(pressed ? Spotlight.seamPressGlow : 0))
        }
        .scaleEffect(pressed ? Spotlight.seamPressScale : 1,
                     anchor: compact ? .trailing : .center)
    }

    /// Width of a row's cards: portrait posters, except in Continue
    /// Watching, where every card is landscape (episode stills) — the same
    /// size as the box.
    private func cardWidth(_ row: HomeRow) -> CGFloat {
        isContinueRow(row) ? Spotlight.boxWidth : Spotlight.posterWidth
    }

    /// One card: a portrait poster, or — `landscape` (Continue Watching) —
    /// the episode still / backdrop with its progress (no logo: the name
    /// is under the box).
    private func poster(_ item: MetaItem, continueEntry: WatchProgress?,
                        landscape: Bool = false) -> some View {
        let width = landscape ? Spotlight.boxWidth : Spotlight.posterWidth
        return ZStack(alignment: .bottomLeading) {
            if landscape {
                RemoteImage(url: sharpStills[item.id] ?? item.background ?? item.poster,
                            maxDimension: Spotlight.boxWidth)
                    .frame(width: width, height: Spotlight.rowHeight)
                LinearGradient(colors: [.clear, .black.opacity(Spotlight.continueFootOpacity)],
                               startPoint: Spotlight.continueFootStart, endPoint: .bottom)
            } else {
                RemoteImage(url: item.poster ?? item.background, maxDimension: Spotlight.rowHeight)
            }
        }
            .frame(width: width, height: Spotlight.rowHeight)
            // Continue Watching: the same state line as the box (the cards
            // are the box's size) — bar + time left, or "Up Next".
            .overlay(alignment: .bottom) {
                if let continueEntry {
                    continueState(continueEntry, width: width - 2 * Spotlight.progressBarInset)
                        .padding(.bottom, Spotlight.progressBarBottomInset)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
            .overlay {
                if Spotlight.cardEdgeHighlight { edgeHighlight() }
            }
            .shadow(color: cardShadows ? .black.opacity(0.25) : .clear,
                    radius: cardShadows ? 10 : 0, y: cardShadows ? 5 : 0)
    }

    // MARK: Focus spot (stationary)

    private func focusLayer(row: HomeRow, width: CGFloat, box: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Muted trailer over the box artwork, UNDER the logo, progress
            // bar and outline (those are drawn by `focusTargets`' overlay).
            // `active` = the box has focus. Moving to the sidebar stops the
            // trailer; coming back starts it again after the usual delay.
            // No trailer in Continue Watching: you've already started it.
            // (The billboard plays its trailer full bleed, in its art.)
            if !isFeatured(row), Spotlight.boxTrailers {
                SpotlightTrailerLayer(item: item,
                                      active: focus != nil && !isContinueRow(row),
                                      isPlaying: $trailerPlaying)
                    .frame(width: box.width, height: box.height)
                    .clipShape(RoundedRectangle(cornerRadius: Spotlight.cornerRadius,
                                                style: .continuous))
                    .allowsHitTesting(false)
            }
            focusTargets(row: row, current: itemIndex, box: box)
        }
        .frame(width: width, height: box.height, alignment: .topLeading)
        .opacity(focus == nil ? unfocusedOpacity : 1)
        .animation(.easeOut(duration: 0.2), value: focus == nil)
    }

    /// The box (the only real focus target) framed by its sentinels. Missing
    /// sentinels are replaced by placeholders so the box never shifts, and a
    /// press with nothing to step to falls through to what's really there:
    /// Left on the first title → sidebar, Up on the first row → top bar.
    private func focusTargets(row: HomeRow, current: Int, box: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sentinel(.up, enabled: rowIndex > 0,
                     width: box.width, height: 1)
            HStack(spacing: 0) {
                // WIDE, not 1pt: fills the gap between the screen edge and the box.
                sentinel(.left, enabled: true,
                         width: leftSentinelWidth, height: box.height)
                Color.clear
                    .frame(width: box.width, height: box.height)
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($focus, equals: .box)
                    .onTapGesture { select() }
                    // Hold-Select menu. ONE menu whose CONTENT depends on the
                    // row — not two different modifiers swapped in and out,
                    // which would rebuild this view and drop its focus.
                    .contextMenu { holdMenuItems() }
                    // Back is handled on the focused view: mid-row the
                    // sidebar is gated off, so RootView couldn't reach it.
                    .onExitCommand { handleBack() }
                    // Trailer mode: Up brings the page back (the top bar
                    // can't take focus meanwhile, so the engine won't move).
                    .onMoveCommand { direction in
                        if direction == .up, trailerMode { revealTrailerPage() }
                    }
                // (Always: at the end of a row that ends, Right bounces.)
                sentinel(.right, enabled: !row.items.isEmpty,
                         width: 1, height: box.height)
            }
            sentinel(.down, enabled: rowIndex < rows.count - 1,
                     width: box.width, height: 1)
        }
        .padding(.leading, -leftSentinelWidth)
        .padding(.top, -1)
    }

    @ViewBuilder
    private func sentinel(_ slot: Slot, enabled: Bool,
                          width: CGFloat, height: CGFloat) -> some View {
        if enabled {
            Color.clear
                .frame(width: width, height: height)
                .focusable()
                .focused($focus, equals: slot)
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }

    /// The focus outline (or edge), per `Spotlight.boxStyle`.
    @ViewBuilder
    private func boxFrame(focused: Bool) -> some View {
        switch Spotlight.boxStyle {
        case .outline:
            // The glass focus rim (bold sibling of the posters' rim).
            GlassFocusRim(cornerRadius: Spotlight.cornerRadius, lineWidth: Spotlight.outlineWidth)
                .opacity(focused ? 1 : 0)
                // Only its own fade when focus comes or goes (top bar).
                // Otherwise it has NO animation of its own: it's part of
                // the box and moves, resizes and fades exactly with it.
                .animation(.easeOut(duration: 0.2), value: focus != nil)
        case .edge:
            edgeHighlight(opacity: focused ? 1.2 : 0.8)
                .animation(.easeOut(duration: 0.2), value: focus != nil)
        case .plain:
            EmptyView()
        }
    }

    /// The billboard's position: fixed glass dots, one per title, and a
    /// larger glass marker on the current one that moves like a drop (see
    /// `BillboardDots`).
    private func billboardDots(_ row: HomeRow) -> some View {
        BillboardDots(count: row.items.count, current: position(in: row), focused: focus != nil)
    }

    /// The billboard's ratings row (nil = none at all) — the catalog's IMDb
    /// score until MDBList's arrive, as on the Detail page.
    private func billboardRatingsRow(_ item: MetaItem) -> AnyView? {
        let entries = MDBListRatingsRow.entries(billboardRatings[item.id], settings: mdblist.settings,
                                                imdbFallback: item.imdbRating)
        return entries.isEmpty ? nil : AnyView(MDBListRatingsRow(entries: entries))
    }

    private func billboardText(_ item: MetaItem, row: HomeRow, screen: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            TitleBlockView(item: item, facts: billboardFacts[item.id],
                           seriesSize: seriesSizeText(item),
                           textHidden: trailerMode,
                           showsLogo: !trailerMode,
                           ratings: billboardRatingsRow(item))
                .padding(.top, TitleBlock.topY(screenHeight: screen.height))
                .id(item.id)
                // What the Detail page loads for the block: the ratings
                // (cached 30 minutes by the service) and TMDB's facts (for
                // the session) — so paging back is free.
                .task(id: item.id) {
                    async let ratings = billboardRatings[item.id] == nil
                        ? MDBListService.ratings(for: item, settings: mdblist.settings) : nil
                    async let facts = billboardFacts[item.id] == nil
                        ? TMDBService.facts(for: item) : nil
                    if let ratings = await ratings { billboardRatings[item.id] = ratings }
                    if let facts = await facts { billboardFacts[item.id] = facts }
                }
                .transition(.opacity.animation(Spotlight.textFade))
        }
        // The section hint to the row below — the same signpost as on the
        // Detail page, in the same place. Pressed on Down.
        .overlay(alignment: .topLeading) {
            if rows.indices.contains(rowIndex + 1) {
                SectionHint.place(
                    // Stays through the trailer: it's navigation.
                    SectionHint(title: rows[rowIndex + 1].title, pressed: downPressed))
                    .frame(width: screen.width)
                    .offset(x: -Spotlight.screenInset,
                            y: TitleBlock.hintY(screenHeight: screen.height))
                    // Down and fading; Details' hint comes down in.
                    .offset(y: swappedToDetail ? ModeSwap.bottomTravel : 0)
                    .opacity(swappedToDetail ? 0 : 1)
                    .animation(swappedToDetail ? ModeSwap.fadeOut : ModeSwap.fadeIn,
                               value: swappedToDetail)
            }
        }
        // The billboard's position: bottom right, on the hint's line — the
        // navigation cues together (the hint: Down; the dots: Left/Right).
        .overlay(alignment: .topLeading) {
            if Spotlight.showPositionDots {
                billboardDots(row)
                    .frame(height: SectionHint.size * 1.3)
                    .padding(.trailing, Spotlight.screenInset)
                    .frame(width: screen.width, alignment: .trailing)
                    .offset(x: -Spotlight.screenInset,
                            y: TitleBlock.hintY(screenHeight: screen.height))
                    // Down and fading, with the hint.
                    .offset(y: swappedToDetail ? ModeSwap.bottomTravel : 0)
                    .opacity(swappedToDetail ? 0 : 1)
            }
        }
        .padding(.leading, Spotlight.screenInset)
        .animation(TrailerMode.fade, value: trailerMode)
        // Content (not stage): steps back while focus is in the top bar.
        .opacity(focus == nil ? unfocusedOpacity : 1)
        .animation(.easeOut(duration: 0.2), value: focus == nil)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func logo(for item: MetaItem) -> some View {
        if let logo = item.logo {
            // A logo that can't be loaded falls back to the name as text.
            RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading,
                        maxDimension: Spotlight.logoMaxWidth, showsPlaceholder: false,
                        fallback: AnyView(logoText(item.name)))
                .frame(width: Spotlight.logoMaxWidth, height: Spotlight.logoMaxHeight,
                       alignment: .bottomLeading)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        } else {
            logoText(item.name)
        }
    }

    // MARK: Text (fades in place)

    /// The names of the previous, focused and next rows, keyed by row id so
    /// each one TRAVELS with its row on Up/Down: the preview's "▾ Label"
    /// rises and grows into the focus row's title while the old title
    /// shrinks into the "▴ Label" at the top. Nothing fades except the
    /// chevrons and dots.
    private func titleY(for role: Int, _ spots: Layout) -> CGFloat {
        switch role {
        case 0:  return spots.headerY
        // Exactly as far above the preview as the title is above the focus
        // row — so the name stays attached to its row when it moves up.
        // (Under the billboard too: hidden there, it arrives WITH its row;
        // the billboard's own section hint just goes.)
        case 1:  return spots.previewY - (spots.rowY - spots.headerY)
        // Off-screen above, as a title — the same place relative to its
        // row as in focus, so it scrolls in rigidly.
        default: return rowY(for: -1, featured: false, spots) - (spots.rowY - spots.headerY)
        }
    }

    /// One row name. Same text view in every role — only its scale,
    /// opacity and the chevron in front change, so SwiftUI can animate
    /// between them instead of swapping views.
    private func rowTitle(_ row: HomeRow, role: Int) -> some View {
        let isFocus = role == 0
        // The billboard has no title above it (it's the whole screen); as
        // the row ABOVE Continue Watching it shows as "▴ Featured".
        let hidden = isFocus && isFeatured(row)
        return VStack(alignment: .leading, spacing: 0) {
            // Drawn at the TITLE size and scaled down as a label, so the
            // change between the two animates (a font size can't).
            Text(row.title)
                .font(.system(size: Spotlight.headerTitleSize, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .fixedSize()
                // The name keeps ONE size as it goes from "▾" (preview) to
                // title — a size change mid-scroll looked wonky. Only the
                // "▴ previous" label is small.
                .scaleEffect(role < 0 ? Spotlight.headerLabelSize / Spotlight.headerTitleSize : 1,
                             anchor: .topLeading)
                .opacity(isFocus ? 1 : Spotlight.labelOpacity)
        }
        .opacity(hidden ? 0 : 1)
    }

    /// Name + meta line, under the row.
    private func info(for item: MetaItem, progress: WatchProgress?) -> some View {
        Group {
            if let progress {
                continueInfo(item, progress)
            } else {
                catalogInfo(item)
            }
        }
        .id(item.id)
        // Left/Right: crossfades in place. (Up/Down: travels with its row.)
        .transition(.opacity.animation(Spotlight.textFade))
    }

    /// Continue Watching: "where was I?" — two lines: the show's name (+ "N
    /// new"), then the episode's name. S1:E1 and the time left are in the
    /// card itself.
    private func continueInfo(_ item: MetaItem, _ progress: WatchProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(item.name)
                    .font(FusionType.bodyText(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                ForEach(statusChips(for: item, continueEntry: progress), id: \.text) { chip in
                    statusChip(chip)
                }
            }
            // The episode's name (a movie: the catalogs' meta line). Which
            // episode and how far along live IN the card.
            Group {
                if progress.season != nil {
                    Text(progress.episodeTitle ?? "")
                } else {
                    Text(metaSegments(for: item).joined(separator: " • "))
                }
            }
            .font(FusionType.bodyText(theme.font))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
        }
        // Long names / episode titles truncate at the box's edge.
        .frame(maxWidth: Spotlight.boxWidth, alignment: .leading)
    }

    private func catalogInfo(_ item: MetaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name, then small status chips ON THE SAME LINE — so the info
            // block keeps its fixed height whether a title has any or not.
            // Both lines stay within the box: when they'd run past it, the
            // least useful pieces drop out (see `fitted`).
            // Explicitly "not in Continue Watching" (a bare nil would mean
            // "use the box's entry").
            let chips = statusChips(for: item, continueEntry: .some(nil))
            fitted((0...chips.count).reversed().map { Array(chips.prefix($0)) }) { shown in
                HStack(spacing: 12) {
                    Text(item.name)
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    ForEach(shown, id: \.text) { chip in
                        statusChip(chip)
                    }
                }
            }

            // Rating as plain text in the meta line (no yellow badge).
            fitted(metaVariants(for: item)) { MetaLine(segments: $0) }
        }
    }

    /// The first variant (longest first) that fits the box's width; the
    /// last one, truncated, if none does.
    private func fitted<V, Content: View>(_ variants: [V], width: CGFloat = Spotlight.boxWidth,
                                          @ViewBuilder _ content: @escaping (V) -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(variants.indices, id: \.self) { index in
                content(variants[index]).fixedSize(horizontal: true, vertical: false)
            }
            if let last = variants.last { content(last) }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The meta line, then shorter versions of it: without the type, then
    /// without the season/episode count.
    private func metaVariants(for item: MetaItem) -> [[String]] {
        let full = metaSegments(for: item)
        var variants = [full]
        func add(_ segments: [String]) {
            if segments != variants.last { variants.append(segments) }
        }
        let type = full.first
        let size = item.isSeries ? seriesSizeText(item) : nil
        var shorter = full
        if let type { shorter.removeAll { $0 == type }; add(shorter) }
        if let size { shorter.removeAll { $0 == size }; add(shorter) }
        return variants
    }

    /// The shared meta line (see `TitleBlock.metaSegments`), with the
    /// show's size from TMDB when the catalog entry had no episode list.
    private func metaSegments(for item: MetaItem) -> [String] {
        TitleBlock.metaSegments(for: item, seriesSize: seriesSizeText(item))
    }

    /// The show's size — from TMDB (`showSizes`) when the catalog entry
    /// came without an episode list.
    private func seriesSizeText(_ item: MetaItem) -> String? {
        guard item.regularSeasons.isEmpty, let size = showSizes[item.id] else {
            return TitleBlock.seriesSizeText(item)
        }
        return TitleBlock.seriesSizeText(item, seasons: size.seasons, episodes: size.episodes)
    }

    // MARK: Status (progress, library, watched)

    private struct StatusChip {
        let icon: String
        let text: String
        let accent: Bool
    }

    /// The title's most recent in-progress entry (a movie, or the latest
    /// episode of a series), if it's somewhere between started and done.
    private func inProgress(_ item: MetaItem) -> WatchProgress? {
        progressStore.items.values
            .filter { $0.metaID == item.id && $0.fraction > 0.02 && $0.fraction < 0.95 }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// At most a few, most useful first: where you are, then whether it's
    /// saved or finished.
    /// `continueEntry`: the item's Continue Watching entry when it's in
    /// that row (default: the box's, if the focus row is Continue Watching).
    private func statusChips(for item: MetaItem,
                             continueEntry: WatchProgress?? = .none) -> [StatusChip] {
        let currentProgress = continueEntry ?? self.currentProgress
        var chips: [StatusChip] = []
        if let progress = currentProgress {
            // Continue Watching: the info lines already say where you are;
            // the chip only flags episodes that aired since you started.
            if let new = progress.newEpisodeCount, new > 0 {
                chips.append(StatusChip(icon: "sparkles",
                                        text: new == 1 ? "1 new" : "\(new) new",
                                        accent: true))
            }
        } else if let progress = inProgress(item) {
            var text = progress.remainingTimeText.map { "\($0) left" } ?? "In progress"
            if let season = progress.season, let episode = progress.episode {
                text = "S\(season):E\(episode) · " + text
            }
            chips.append(StatusChip(icon: "play.circle.fill", text: text, accent: true))
        } else if !item.isSeries, watched.isWatched(item) {
            chips.append(StatusChip(icon: "checkmark.circle.fill", text: "Watched", accent: false))
        }
        // Not in Continue Watching: it's about the show, not the episode.
        if currentProgress == nil, library.contains(item) {
            chips.append(StatusChip(icon: "bookmark.fill", text: "In Library", accent: false))
        }
        return chips
    }

    private func statusChip(_ chip: StatusChip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: chip.icon)
                .font(.system(size: 16, weight: .semibold))
            Text(chip.text)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(chip.accent ? theme.palette.secondary : theme.palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .liquidGlass(in: Capsule())
        .fixedSize()
    }

    /// tvOS-style pill: grey track, white fill, fully rounded ends.
    /// A Continue Watching card's state, one line — the episode row's own:
    /// which episode LEFT, its status RIGHT. "S1:E1 ▬▬▬░░ 38m left"; not
    /// started "S1:E1 … Up Next"; not aired yet "S1:E1 … Airs in 3 days".
    /// Every card says where it is, not only the focused one.
    @ViewBuilder
    private func continueState(_ entry: WatchProgress, width: CGFloat) -> some View {
        let episode: Text? = entry.season.flatMap { season in
            entry.episode.map { Text("S\(season):E\($0)") }
        }
        let label = Text(entry.fraction > 0.02
                         ? (entry.remainingTimeText.map { "\($0) left" } ?? "In progress")
                         : entry.notAiredYet
                            // The episode row's own wording (one source).
                            ? MetaVideo.airCountdownText(until: entry.airsAt == .distantFuture
                                                         ? nil : entry.airsAt)
                            : "Up Next")
            .font(.system(size: Spotlight.continueStateSize, weight: .semibold))
            .foregroundStyle(AppGlass.text)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .lineLimit(1)
            .fixedSize()
        let episodeLabel = episode?
            .font(.system(size: Spotlight.continueStateSize, weight: .semibold))
            .foregroundStyle(AppGlass.text)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .lineLimit(1)
            .fixedSize()
        if entry.fraction > 0.02 {
            HStack(spacing: Spotlight.continueStateGap) {
                if let episodeLabel { episodeLabel }
                GeometryReader { proxy in
                    progressBar(entry.fraction, height: Spotlight.continueProgressBarHeight,
                                width: proxy.size.width)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: Spotlight.continueProgressBarHeight)
                label
            }
            .frame(width: width)
        } else {
            // The episode row's layout: which episode left, its status right.
            HStack(spacing: Spotlight.continueStateGap) {
                if let episodeLabel { episodeLabel }
                Spacer(minLength: 0)
                label
            }
            .frame(width: width)
        }
    }

    private func progressBar(_ fraction: Double, height: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Spotlight.progressTrack)
            Capsule().fill(Spotlight.progressFill)
                // Never narrower than the pill is tall, so a small value
                // still reads as a round dot rather than a sliver.
                .frame(width: max(width * CGFloat(fraction), height))
        }
        .frame(width: width, height: height)
    }

    // MARK: Indicators

    // MARK: Actions

    private func step(by delta: Int) {
        guard let row, !row.items.isEmpty, !wrapping else { return }
        pressChevron(delta)
        if !isFeatured(row) { stretchBox(delta) }
        let v = virtualPosition(in: row)
        var next = v + delta
        if !loops(row) {
            next = min(max(next, 0), row.items.count - 1)
        }
        // At the end of a row that ends: resistance, then back.
        guard next != v else { bounce(pushing: CGFloat(delta)); return }
        // Round the ring (across the gap): resistance first, then the
        // heavier slide.
        guard gaps(row, from: min(v, next), to: max(v, next)) > 0 else {
            guard Spotlight.stepNudge > 0 else {
                withAnimation(Spotlight.slide) { positions[row.id] = next }
                return
            }
            // (Experiment) A flick of the whole row first, then the slide.
            withAnimation(.easeOut(duration: Spotlight.stepNudgeDuration)) {
                wrapNudge = -CGFloat(delta) * Spotlight.stepNudge
                boxNudge = wrapNudge
            }
            Task {
                try? await Task.sleep(for: .seconds(Spotlight.stepNudgeDuration))
                withAnimation(Spotlight.slide) {
                    wrapNudge = 0
                    boxNudge = 0
                    positions[row.id] = next
                }
            }
            return
        }
        wrapping = true
        withAnimation(Spotlight.wrapPress) {
            wrapNudge = -CGFloat(delta) * Spotlight.wrapNudge
            if Spotlight.wrapNudgeMovesBox { boxNudge = wrapNudge }
            seamPressed = true
        }
        Task {
            try? await Task.sleep(for: Spotlight.wrapHold)
            // Released: springs back as the ring turns.
            withAnimation(.smooth(duration: 0.25)) { seamPressed = false }
            withAnimation(Spotlight.wrapSlide) {
                wrapNudge = 0
                boxNudge = 0
                positions[row.id] = next
            }
            try? await Task.sleep(for: .seconds(0.3))
            wrapping = false
        }
    }

    /// A row's ‹ and ›: in the margin left of the box, and at the right
    /// edge. Only while the row is in focus, and only where the press
    /// does something (rows that END lose ‹ on the first title, › on the
    /// last; rings keep both).
    @ViewBuilder
    private func rowChevrons(_ entry: RowEntry, width: CGFloat) -> some View {
        let row = entry.row
        let current = position(in: row)
        let inFocus = entry.role == 0
        let size = Spotlight.chevronCircle
        let y = (Spotlight.rowHeight - size) / 2
        chevron("chevron.left", pressed: inFocus && pressedChevron == -1)
            .offset(x: -Spotlight.leftChevronOffset - size / 2, y: y)
            .opacity(inFocus && (current > 0 || loops(row)) ? 1 : 0)
        chevron("chevron.right", pressed: inFocus && pressedChevron == 1)
            .offset(x: width - size - Spotlight.chevronRightInset, y: y)
            .opacity(inFocus && (loops(row) || current < row.items.count - 1) ? 1 : 0)
    }

    /// One chevron: a small glass circle (the app's glass), pressable.
    private func chevron(_ symbol: String, pressed: Bool) -> some View {
        GlassChevron(symbol: symbol, pressed: pressed)
    }

    /// The box's liquid step: its edge runs ahead in the pressed direction,
    /// then it settles back.
    private func stretchBox(_ delta: Int) {
        stretchTask?.cancel()
        withAnimation(Spotlight.boxStretchLead) {
            boxStretch = (delta > 0 ? 1 : -1) * Spotlight.boxStretch
        }
        stretchTask = Task { @MainActor in
            try? await Task.sleep(for: Spotlight.boxStretchHold)
            guard !Task.isCancelled else { return }
            withAnimation(Spotlight.boxStretchSettle) { boxStretch = 0 }
        }
    }

    /// The billboard's section hint: a quick push of its chevron.
    private func pressDownChevron() {
        withAnimation(.easeOut(duration: 0.08)) { downPressed = true }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.smooth(duration: 0.25)) { downPressed = false }
        }
    }

    /// The pressed direction's chevron: a quick press and release.
    private func pressChevron(_ delta: Int) {
        let side = delta > 0 ? 1 : -1
        withAnimation(.easeOut(duration: 0.08)) { pressedChevron = side }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.smooth(duration: 0.25)) {
                if pressedChevron == side { pressedChevron = 0 }
            }
        }
    }

    /// The end of a row that doesn't loop: the cards give in the pressed
    /// direction — the ring's resistance — and spring back.
    private func bounce(pushing: CGFloat) {
        wrapping = true
        withAnimation(Spotlight.wrapPress) { wrapNudge = -pushing * Spotlight.wrapNudge }
        Task {
            try? await Task.sleep(for: Spotlight.wrapHold)
            withAnimation(Spotlight.endBounce) { wrapNudge = 0 }
            try? await Task.sleep(for: .seconds(0.15))
            wrapping = false
        }
    }

    /// Select: resume in Continue Watching, otherwise open the Detail page.
    private func select() {
        if let progress = currentProgress {
            onResume(progress)
        } else if let item {
            if let row, isFeatured(row), let onSelectFeatured {
                // Home's half of the swap out, then Details takes over.
                guard !swappedToDetail else { return }
                withAnimation(ModeSwap.out) {
                    swappedToDetail = true
                    ModeSwap.shared.homeChromeOut = true
                }
                // The depth starts on the press — Details takes it on.
                withAnimation(ModeSwap.depthLeaving) { billboardDepth = ModeSwap.depthHandover }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ModeSwap.handoverDelay))
                    ModeSwap.shared.billboardItemID = item.id
                    ModeSwap.shared.billboardRatings = billboardRatings[item.id]
                    ModeSwap.shared.billboardFacts = billboardFacts[item.id]
                    ModeSwap.shared.billboardSeriesSize = seriesSizeText(item)
                    onSelectFeatured(item)
                    // Once Details covers Home (next turn, never on screen):
                    // ready to come back where Details' leaving half will
                    // leave the depth.
                    DispatchQueue.main.async {
                        var still = Transaction()
                        still.disablesAnimations = true
                        withTransaction(still) { billboardDepth = 1 - ModeSwap.depthHandover }
                    }
                }
            } else {
                growBoxIntoDetails(item)
            }
        }
    }

    /// Box → Details: the box's artwork grows to the full screen while
    /// everything else fades and the top bar lifts; then Details (no
    /// system slide) fades its parts in over that same backdrop. Back runs
    /// it the other way (see `.onReceive(ModeSwap.shared.$homeChromeOut)`).
    private func growBoxIntoDetails(_ item: MetaItem) {
        guard growingBox == nil, let onSelectFeatured else { onSelect(item); return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            growingBox = item
            boxGrown = false
            boxDepth = 0
        }
        // Next turn: the copy is on screen at the box's spot, now grow it.
        DispatchQueue.main.async {
            withAnimation(ModeSwap.boxGrow) {
                boxGrown = true
                boxDepth = ModeSwap.boxDepthHandover
            }
            withAnimation(ModeSwap.out) { ModeSwap.shared.homeChromeOut = true }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ModeSwap.boxGrowDuration))
            ModeSwap.shared.billboardItemID = item.id
            ModeSwap.shared.arrivedFromBox = true
            ModeSwap.shared.billboardRatings = nil
            ModeSwap.shared.billboardFacts = nil
            ModeSwap.shared.billboardSeriesSize = nil
            onSelectFeatured(item)
            // Behind Details from here: ready to come back where its
            // leaving half will leave the depth.
            DispatchQueue.main.async {
                withTransaction(still) { boxDepth = ModeSwap.boxDepthHandover }
            }
        }
    }

    /// The growing box: at first an exact twin of the box (its artwork,
    /// its slight dimming, its focus rim), then — the rim fading at once —
    /// growing to the full screen while the scrim and the depth come in
    /// EVENLY over the whole grow (on the grow's own fast-start curve they
    /// all but switched on). At the end exactly Details' backdrop. (The
    /// box-sized image under the full one, so nothing blinks while the
    /// sharper one loads.)
    @ViewBuilder
    private func growingBoxLayer(spots: Layout) -> some View {
        if let item = growingBox {
            // Aimed at the TRUE screen, measured: Home's own area can sit
            // inset from it, and the copy then landed a few points off
            // Details' backdrop (which fills the screen) — it shifted at the
            // switch.
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let screen = CGRect(x: -origin.x, y: -origin.y,
                                    width: UIScreen.main.bounds.width,
                                    height: UIScreen.main.bounds.height)
                let box = CGRect(x: leadingInset, y: spots.rowY,
                                 width: Spotlight.boxWidth, height: Spotlight.rowHeight)
                let frame = boxGrown ? screen : box
                // The darkening moves WITH the growth: the same fast-then-
                // slow (see `ModeSwap.boxScrimHandover`).
                let shade = ModeSwap.boxGrow
                ZStack {
                    RemoteImage(url: item.background ?? item.poster, maxDimension: Spotlight.boxWidth)
                    RemoteImage(url: item.background ?? item.poster,
                                maxPixels: PerformanceProfile.backdropPixelCap)
                    // From the box's slight dimming towards Details' scrim
                    // (half of it — Details finishes) + the depth. SCOPED
                    // animations: only the opacity is re-timed, never the
                    // size (see the design doc's timing trap).
                    Color.black
                        .animation(shade) { $0.opacity(boxGrown ? 0 : Spotlight.boxDim) }
                    StageScrim()
                        .animation(shade) { $0.opacity(boxGrown ? ModeSwap.boxScrimHandover : 0) }
                    Color.black
                        .animation(shade) { $0.opacity(ModeSwap.depthDim(boxDepth)) }
                }
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(ModeSwap.depthScale(boxDepth))
                .clipShape(RoundedRectangle(cornerRadius: boxGrown ? 0 : Spotlight.cornerRadius,
                                            style: .continuous))
                // The box's own rim, gone as soon as it starts to grow.
                .overlay {
                    GlassFocusRim(cornerRadius: Spotlight.cornerRadius, lineWidth: Spotlight.outlineWidth)
                        .animation(.easeOut(duration: 0.12)) { $0.opacity(boxGrown ? 0 : 1) }
                }
                .offset(x: frame.minX, y: frame.minY)
            }
            .allowsHitTesting(false)
        }
    }

    /// Mirrors the app's own hold menus (PosterHoldMenu / ContinueHoldMenu).
    /// No `role: .destructive` anywhere: tvOS refuses to present a context
    /// menu containing one.
    @ViewBuilder
    private func holdMenuItems() -> some View {
        if let progress = currentProgress, let item {
            Button { onPlayManually(progress) } label: {
                Label("Play Manually", systemImage: "list.and.film")
            }
            Button { onSelect(item) } label: {
                Label("Go to Details", systemImage: "info.circle")
            }
            Button { onResumeFromStart(progress) } label: {
                Label("Start Over", systemImage: "gobackward")
            }
            Button { progressStore.removeShow(metaID: progress.metaID, notifySync: true) } label: {
                Label("Remove from Continue Watching", systemImage: "xmark")
            }
        } else if let item {
            Button { onSelect(item) } label: {
                Label("Go to Details", systemImage: "info.circle")
            }
            Button { library.toggle(item) } label: {
                Label(library.contains(item) ? "Remove from Library" : "Add to Library",
                      systemImage: library.contains(item) ? "bookmark.slash" : "bookmark")
            }
            if !item.isSeries {
                Button { watched.toggleMovie(item) } label: {
                    Label(watched.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: watched.isWatched(item) ? "eye.slash" : "checkmark.circle")
                }
            }
        }
    }

    /// Put Home back where it was left. Runs as rows arrive (they load one
    /// by one), each row once: its remembered title is found by id — so a
    /// reloaded or reshuffled catalog still lands on the same show — and
    /// only if that title is gone, on the same position.
    private func restorePlace() {
        let memory = SpotlightMemory.shared
        var restored = positions
        for row in rows where !restoredRows.contains(row.id) && !row.items.isEmpty {
            restoredRows.insert(row.id)
            if let itemID = memory.items[row.id],
               let index = row.items.firstIndex(where: { $0.id == itemID }) {
                restored[row.id] = index
            } else if let index = memory.positions[row.id] {
                restored[row.id] = min(index, row.items.count - 1)
            }
        }
        if restored != positions { positions = restored }

        guard !placeRestored else { return }
        guard let id = memory.rowID else { placeRestored = true; return }
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rowIndex = index
            placeRestored = true
        }
    }

    private var verticalAnimation: Animation {
        switch Spotlight.verticalStyle {
        case .scroll: return Spotlight.rowChange
        case .fade:   return Spotlight.fadeChange
        case .glide:  return Spotlight.glideChange
        }
    }

    private func changeRow(by delta: Int) {
        if Spotlight.verticalStyle == .scroll { preparedScroll(by: delta); return }
        let next = min(max(rowIndex + delta, 0), rows.count - 1)
        guard next != rowIndex else { return }
        let direction: CGFloat = next > rowIndex ? 1 : -1
        rowTask?.cancel()
        rowMoving = true
        // The direction must be rendered BEFORE the row changes: a leaving
        // view uses the transition from its last render. Same direction as
        // last time (repeated presses): already there, change right away.
        if scrollDirection != direction {
            scrollDirection = direction
            Task {
                await Task.yield()
                withAnimation(verticalAnimation) { rowIndex = next }
            }
        } else {
            withAnimation(verticalAnimation) { rowIndex = next }
        }
        rowTask = Task {
            try? await Task.sleep(for: Spotlight.textReturn)
            guard !Task.isCancelled else { return }
            rowMoving = false
        }
    }

    /// (`.scroll`) Down: prepare (the preview opens, fast), then scroll.
    /// Up: one movement — scroll, with the old focus row folding back into
    /// posters on the way.
    private func preparedScroll(by delta: Int) {
        let next = min(max(rowIndex + delta, 0), rows.count - 1)
        guard next != rowIndex else { return }
        let down = next > rowIndex
        if down, let row, isFeatured(row) { pressDownChevron() }
        let direction: CGFloat = down ? 1 : -1
        rowTask?.cancel()
        let change = {
            if down {
                // Both start together; the opening is done while the
                // scroll is still in its slow start.
                withAnimation(Spotlight.prepare) { openPreviewID = rows[next].id }
                withAnimation(Spotlight.downScroll) { rowIndex = next }
            } else {
                // The old focus row folds back into posters DURING the
                // scroll — same curve, finishing together.
                withAnimation(Spotlight.rowChange) {
                    openPreviewID = nil
                    rowIndex = next
                }
            }
        }
        // The direction must be rendered BEFORE the rows change: a leaving
        // view uses the transition from its last render.
        if scrollDirection != direction {
            scrollDirection = direction
            Task { await Task.yield(); change() }
        } else {
            change()
        }
    }

    /// The billboard's trailer has the screen (see `TrailerMode`).
    private var trailerMode: Bool {
        trailerPlaying && !trailerRevealed
            && rows.indices.contains(rowIndex) && isFeatured(rows[rowIndex])
    }

    /// Up / Back in trailer mode: the page comes back, the trailer runs on
    /// muted.
    private func revealTrailerPage() {
        withAnimation(TrailerMode.fade) { trailerRevealed = true }
    }

    private func handleBack() {
        if trailerMode { revealTrailerPage(); return }
        // Straight to the top bar from ANY title; the row keeps its position.
        onBack()
    }

    /// Backdrop URLs just ahead of / behind the current title, nearest first.
    private func neighbourBackdrops(in row: HomeRow, around index: Int) -> [String] {
        var indices: [Int] = []
        for distance in 1...max(Spotlight.tintLookAhead, Spotlight.tintLookBehind, 1) {
            if distance <= Spotlight.tintLookAhead { indices.append(index + distance) }
            if distance <= Spotlight.tintLookBehind { indices.append(index - distance) }
        }
        return indices
            .filter { row.items.indices.contains($0) }
            .compactMap { row.items[$0].background ?? row.items[$0].poster }
    }

    // MARK: Background

    @ViewBuilder
    private func background(screen: CGSize) -> some View {
        switch Spotlight.backgroundStyle {
        case .plain:
            LinearGradient(colors: [Spotlight.plainTop, Spotlight.plainBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        case .tint:
            ZStack {
                // ONE layer; its colour interpolates in place.
                Rectangle().fill(glowColor ?? Spotlight.plainTop)
                if Spotlight.tintBackdrop, showsAmbient, let ambientImage {
                    Image(uiImage: ambientImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: screen.width, height: screen.height)
                        .clipped()
                        .opacity(Spotlight.tintBackdropOpacity)
                        .id(ObjectIdentifier(ambientImage))
                        .transition(.opacity)
                }
                // (Darkened by the shared `StageScrim`, in `rowStrips`.)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        case .glow:
            glowBackground(screen: screen)
        }
    }

    private func glowBackground(screen: CGSize) -> some View {
        ZStack {
            Color.black
            if showsAmbient, let ambientImage {
                Image(uiImage: ambientImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: screen.width, height: screen.height)
                    .clipped()
                    .opacity(Spotlight.ambientOpacity)
                    .id(ObjectIdentifier(ambientImage))
                    .transition(.opacity)
            }
            if let glow = glowColor {
                RadialGradient(
                    colors: [glow.opacity(Spotlight.glowStrength),
                             glow.opacity(Spotlight.glowStrength * 0.35),
                             .clear],
                    center: UnitPoint(x: (leadingInset + Spotlight.boxWidth / 2) / max(screen.width, 1),
                                      y: Spotlight.glowCenterY),
                    startRadius: 0,
                    endRadius: screen.width * Spotlight.glowRadius
                )
                .id(glow)
                .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(Spotlight.shadeTop),
                                    .black.opacity(Spotlight.shadeBottom)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Position a view's top-leading corner at (x, y) inside the screen-
    /// sized ZStack. Padding, not offset: it's real layout, so the focus
    /// engine sees the focus targets exactly where they're drawn.
    func placed(x: CGFloat, y: CGFloat) -> some View {
        padding(.leading, x).padding(.top, y)
    }
}

// MARK: - Trailer in the box

/// Muted trailer preview for the title in the box — the same pipeline the
/// stock Home hero uses (TMDB trailer keys → YouTube extraction →
/// `BackdropVideoView`), and the same switches. Starts after the viewer has
/// rested on a title for `Spotlight.trailerDelay`; any step (Left/Right or
/// Up/Down) stops it at once. Plays once, then fades back to the artwork.
///
/// Mounted ALWAYS and revealed by opacity: inserting/removing the video view
/// mid-browse makes the focus engine re-resolve (see the stock hero's notes).
private struct SpotlightTrailerLayer: View {
    let item: MetaItem?
    /// False while focus is elsewhere (the sidebar): no trailer then.
    let active: Bool
    /// Mirrors "trailer visible" out to the spotlight (hides the logo).
    @Binding var isPlaying: Bool
    /// With sound (the billboard); nil: the Home setting (the rows' boxes).
    var sound: Bool? = nil
    /// Rest before it starts.
    var delay: TimeInterval = Spotlight.trailerDelay

    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore

    @State private var player: AVPlayer?
    @State private var visible = false
    @State private var endToken: NSObjectProtocol?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var failureObserver: NSKeyValueObservation?
    @State private var fadeOutTask: Task<Void, Never>?
    @State private var activatedAudio = false

    private static let resolveTimeout: TimeInterval = 12
    private static let fadeOutSeconds: TimeInterval = 0.6

    var body: some View {
        BackdropVideoView(player: player)
            .opacity(visible ? 1 : 0)
            // Restarts on a new title AND on focus leaving/returning.
            .task(id: "\(item?.id ?? "")|\(active)") { await run() }
            .onDisappear { teardown() }
            // Focus leaving: stop NOW, in the same update — not a beat later
            // when the restarted task gets round to it, which left the last
            // frame showing through the dimmed box.
            .onChange(of: active) { _, isActive in
                if !isActive { teardown() }
            }
            .onChange(of: homeCatalogSettings.heroTrailersEnabled) { _, enabled in
                if !enabled { teardown() }
            }
            // Muted / unmuted while it plays (the page coming back mutes it).
            .onChange(of: sound) { _, _ in
                if let player { setSound(sound ?? homeCatalogSettings.heroTrailerSound, on: player) }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in player?.play() }
            // Real playback started from somewhere without leaving Home:
            // never keep a second decoder running behind it.
            .task(id: player != nil) {
                guard player != nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if OrivioSyncManager.playbackActive { teardown(); break }
                }
            }
    }

    private func run() async {
        teardown()
        guard TrailerMode.enabled, active, let item, item.type != "collection",
              homeCatalogSettings.heroTrailersEnabled, !perf.reduceMotion,
              tmdbSettings.settings.isUsable, tmdbSettings.settings.useTrailers else { return }
        let t0 = Date()
        // Short settle first, so stepping through a row doesn't fire a TMDB
        // lookup + YouTube extraction for every title passed on the way.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        // Resolve DURING the rest delay, not after it.
        async let prepared: (item: AVPlayerItem, youtubeKey: String)? = {
            let keys = await TMDBService.trailerKeys(id: item.id, type: item.type)
            guard !keys.isEmpty else { return nil }
            return await TrailerResolver.backdropItem(candidates: keys)
        }()
        try? await Task.sleep(for: .seconds(max(delay - 0.2, 0)))
        guard !Task.isCancelled, !PiPHandoff.shared.isActive,
              !OrivioSyncManager.playbackActive else { return }
        guard let resolved = await prepared, !Task.isCancelled,
              Date().timeIntervalSince(t0) < Self.resolveTimeout else { return }

        let avItem = resolved.item
        avItem.preferredForwardBufferDuration = 2
        let p = AVPlayer(playerItem: avItem)
        setSound(sound ?? homeCatalogSettings.heroTrailerSound, on: p)
        // Play once and hold the last frame, which then fades into the art.
        p.actionAtItemEnd = .none
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main
        ) { _ in
            Task { @MainActor in restoreArtwork() }
        }
        player = p
        let key = resolved.youtubeKey
        failureObserver = avItem.observe(\.status, options: [.new]) { observed, _ in
            guard observed.status == .failed else { return }
            TrailerResolver.invalidate(youtubeKey: key)
        }
        // Reveal on the FIRST FRAME, so the box never shows a black layer
        // while the stream buffers.
        statusObserver = p.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
            guard observed.timeControlStatus == .playing else { return }
            Task { @MainActor in
                guard player === observed else { return }
                withAnimation(.easeInOut(duration: 0.45)) { visible = true }
                isPlaying = true
            }
        }
        p.playImmediately(atRate: 1)
    }

    private func setSound(_ sound: Bool, on player: AVPlayer) {
        if sound, !PiPHandoff.shared.isActive, !OrivioSyncManager.playbackActive {
            // (Without the category a bare AVPlayer on tvOS can stay silent.)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            activatedAudio = true
            player.isMuted = false
        } else {
            player.isMuted = true
        }
    }

    @MainActor
    private func restoreArtwork() {
        guard player != nil else { return }
        guard visible else { teardown(); return }
        withAnimation(.easeInOut(duration: Self.fadeOutSeconds)) { visible = false }
        // Logo back as the artwork returns.
        isPlaying = false
        fadeOutTask?.cancel()
        fadeOutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.fadeOutSeconds))
            guard !Task.isCancelled else { return }
            teardown()
        }
    }

    private func teardown() {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        visible = false
        isPlaying = false
        statusObserver?.invalidate()
        statusObserver = nil
        failureObserver?.invalidate()
        failureObserver = nil
        player?.pause()
        // Clear the item too, so the muted preview never stays the system
        // "Now Playing" target.
        player?.replaceCurrentItem(with: nil)
        player = nil
        if activatedAudio {
            activatedAudio = false
            if !PiPHandoff.shared.isActive, !OrivioSyncManager.playbackActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        if let endToken {
            NotificationCenter.default.removeObserver(endToken)
            self.endToken = nil
        }
    }
}

// MARK: - Colour extraction

/// Pulls one representative colour out of a backdrop and tames it into a
/// deep, muted background tone. Cheap: the image is decoded at 64px (from
/// the disk cache — the box has usually downloaded it already) and sampled
/// at 16×16. Results are cached per URL.
enum SpotlightTint {
    @MainActor private static var cache: [String: Color] = [:]

    /// Compute and cache colours ahead of time (nearest first). Stops early
    /// if the viewer moves on — the next position warms its own neighbours.
    @MainActor
    static func warm(urls: [String]) async {
        for url in urls where cache[url] == nil {
            if Task.isCancelled { return }
            _ = await color(for: url)
        }
    }

    @MainActor
    static func color(for url: String) async -> Color? {
        if let cached = cache[url] { return cached }
        let tuned: UIColor? = await Task.detached(priority: .utility) {
            guard let image = await smallImage(url) else { return nil }
            return extract(from: image)
        }.value
        guard let tuned else { return nil }
        let color = Color(uiColor: tuned)
        cache[url] = color
        return color
    }

    private static func smallImage(_ url: String) async -> UIImage? {
        // Separate memory key so this 64px copy never replaces a full-size
        // decode the rows are using.
        if let disk = await ImageCache.shared.diskImage(for: url, budget: 64,
                                                        memoryKey: url + "#tint") {
            return disk
        }
        guard let remote = URL(string: url),
              let data = try? await ImageCache.shared.download(remote) else { return nil }
        // Keep the bytes: this backdrop is about to be shown in the box, and
        // now that's a disk hit instead of a second download.
        ImageCache.shared.insertData(data, for: url)
        return ImageCache.decodeDownsampled(data, budget: 64)
    }

    /// Saturation-weighted average: colourful pixels count far more than
    /// grey ones, so a mostly-dark frame with a red sky reads as red rather
    /// than as a muddy brown. Near-black and near-white pixels are ignored.
    private static func extract(from image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255
            let pg = Double(pixels[i + 1]) / 255
            let pb = Double(pixels[i + 2]) / 255
            let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
            if hi < 0.08 || lo > 0.92 { continue }
            let saturation = hi == 0 ? 0 : (hi - lo) / hi
            let weight = 0.05 + saturation * saturation
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }

        let average = UIColor(red: r / total, green: g / total, blue: b / total, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bright: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &sat, brightness: &bright, alpha: &alpha)
        return UIColor(hue: hue,
                       saturation: min(sat * Spotlight.tintSaturationBoost, Spotlight.tintMaxSaturation),
                       brightness: Spotlight.tintBrightness,
                       alpha: 1)
    }
}

// MARK: - Shared label

/// "▴ Previous" / "▾ Next" hint in the spotlight's label look — exactly what
/// a Home row name looks like in its label role (see `rowTitle`). Used by the
/// Detail page's page hints so both screens share one style.
struct SpotlightLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .bold))
                .frame(width: 26, alignment: .leading)
            Text(title)
                .font(FusionType.moduleHeading(theme.font))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(theme.palette.textPrimary)
        .scaleEffect(Spotlight.labelScale, anchor: .topLeading)
        .opacity(Spotlight.labelOpacity)
        .allowsHitTesting(false)
    }
}

/// Home's row chevrons, shared with the Detail page's episode row. Attach as
/// `.overlay(alignment: .leading / .trailing)` on the row's frame (which
/// starts at the focus box): `‹` sits in the margin left of the box, `›` at
/// the right screen edge.
struct SpotlightChevron: View {
    @EnvironmentObject private var theme: ThemeManager
    enum Direction { case left, right }
    let direction: Direction

    var body: some View {
        switch direction {
        case .left:
            Image(systemName: "chevron.left")
                .font(.system(size: Spotlight.chevronSize, weight: .bold))
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: Spotlight.chevronSize * 1.4)
                .offset(x: -Spotlight.leftChevronOffset - Spotlight.chevronSize * 0.7)
                .opacity(0.9)
                .allowsHitTesting(false)
        case .right:
            Image(systemName: "chevron.right")
                .font(.system(size: Spotlight.chevronSize, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary.opacity(0.9))
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(.trailing, 22)
                .allowsHitTesting(false)
        }
    }
}
