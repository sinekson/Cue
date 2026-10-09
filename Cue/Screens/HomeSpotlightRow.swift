import SwiftUI
import AVFoundation

// MARK: - Tuning
//
// Every number that decides how the spotlight row looks and feels lives
// here, so the feel can be tuned on the Apple TV without hunting through
// the view code.

enum Spotlight {
    /// Home's rows with their own role, by id: Continue Watching (Select
    /// resumes) and the Featured billboard.
    static let continueRowID = "spotlight.continueWatching"
    static let featuredRowID = "spotlight.featured"

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
    static var wrapSlide: Animation { Motion.move }
    /// Which rows are rings: catalogs from this many titles up (and the
    /// billboard). Continue Watching and short rows END instead — at an end
    /// the cards give (the same resistance) and spring back (`endBounce`).
    static let minRingCount = 6
    static var endBounce: Animation { Motion.move }
    /// The resistance: how far the row gives, how fast, and the beat at
    /// full resistance before it turns.
    static let wrapNudge: CGFloat = 36
    /// End of a row that doesn't loop: how far the cards give.
    static let endNudge: CGFloat = 14
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
    static var slide: Animation { Motion.move }
    /// Up/Down: ONE movement — all rows scroll one row (no fading), and on
    /// the way the arriving row OPENS (its first poster widens into the
    /// box, the posters beside it make room) while the leaving row keeps
    /// its box as it scrolls out. Up: the old focus row closes back into
    /// posters on its way down to the preview spot.
    ///
    /// Fast start, gentle finish: most of the way is covered early, the
    /// rest eases in.
    static var rowChange: Animation { Motion.move }
    /// (`.scroll`) Down, Netflix-style, in ONE go: the preview opens its box
    /// (fast, `prepare`) while the scroll (`downScroll`) is still barely
    /// moving — its start is slow — so the opening is done within the first
    /// 10–20% of the scroll, and then the row moves off and eases in.
    /// Up: the old focus row folds back into posters as it scrolls down,
    /// finishing together (`rowChange`).
    static let prepareDuration: Double = 0.12
    static var prepare: Animation { .linear(duration: prepareDuration) }
    /// Down's scroll: slower start than `rowChange`, same length.
    static var downScroll: Animation { Motion.move }
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
    static var textFade: Animation { Motion.fade }
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

/// The billboard's position: round dots in a small glass capsule (the top
/// bar's glass), the CURRENT one a pill — which, while the billboard pages
/// by itself (`BillboardAutoPage`), fills from its left end with the time
/// left (the iOS page control's timer look). The dots behind you a little
/// brighter than the ones ahead (the progress map's levels). Changing title
/// the old pill shrinks back into a dot as the new one widens — in place,
/// on the billboard's Left/Right curve and time. Flat inside, glass around.
/// (Tried: segments in a glass capsule — pills in a pill; segments alone;
/// circles in the map's levels; a page-control pill; 14 pt dots with a
/// 20 pt marker gliding between them.)
struct BillboardDots: View {
    let count: Int
    let current: Int
    /// The billboard has focus: the current one at full strength.
    let focused: Bool
    /// Paging by itself: the current pill FILLS over this many seconds — the
    /// next title when it's full. Nil: solid.
    var timer: Double? = nil
    /// A new run of the clock on the same title (back on the billboard).
    var cycle = 0
    @State private var fill: CGFloat = 0

    static let dot: CGFloat = 12
    static let pill: CGFloat = 36
    static let gap: CGFloat = 12
    /// Around the dots inside their glass capsule.
    static let capsulePadding: CGFloat = 16

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<max(count, 0), id: \.self) { k in
                let on = k == current
                Capsule()
                    .fill(Color.white.opacity(on && timer != nil ? 0.3 : opacity(k)))
                    .frame(width: on ? Self.pill : Self.dot, height: Self.dot)
                    // Timed: the current pill fills from its left end.
                    .overlay(alignment: .leading) {
                        if on, timer != nil {
                            Capsule().fill(Color.white)
                                .frame(width: max(Self.pill * fill, Self.dot), height: Self.dot)
                        }
                    }
            }
        }
        .animation(FixedFocusMotion.horizontalAnimation(duration: Motion.durations.move), value: current)
        .animation(FixedFocusMotion.horizontalAnimation(duration: Motion.durations.move), value: focused)
        .padding(.horizontal, Self.capsulePadding)
        .padding(.vertical, Self.capsulePadding * 0.75)
        .background { Color.clear.liquidGlass(in: Capsule()) }
        .opacity(count > 1 ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear { restartFill() }
        .onChange(of: current) { _, _ in restartFill() }
        .onChange(of: timer) { _, _ in restartFill() }
        .onChange(of: cycle) { _, _ in restartFill() }
    }

    /// Behind 62 %, the current one white (fainter without focus), ahead 30 %.
    private func opacity(_ k: Int) -> Double {
        if k == current { return focused ? 1 : 0.62 }
        return k < current ? 0.62 : 0.3
    }

    /// The fill from empty, then over `timer` — linear: it's a clock.
    private func restartFill() {
        var none = Transaction()
        none.disablesAnimations = true
        withTransaction(none) { fill = 0 }
        guard let timer else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: timer)) { fill = 1 }
        }
    }
}

/// Settings → Appearance → "Billboard pages by itself": resting on the
/// billboard, the next title every `interval` seconds.
enum BillboardAutoPage {
    static let key = "cue.home.billboardAutoPage"
    static let interval: Double = 5
}

// MARK: - Place memory

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

extension SpotlightTint {
    @MainActor private static var grounds: [String: Double] = [:]

    /// How bright the picture is where the billboard's text sits (the left
    /// 45 %, from the top bar down): mean relative luminance, 0...1. The
    /// shade's strength follows it (`StageArt.boost`): a bright picture gets
    /// the darkening it needs, a dark one is left alone.
    @MainActor
    static func textGround(for url: String) async -> Double? {
        if let cached = grounds[url] { return cached }
        let value: Double? = await Task.detached(priority: .utility) {
            guard let cg = await smallImage(url)?.cgImage else { return nil }
            let width = 32, height = 18
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            func linear(_ v: UInt8) -> Double {
                let c = Double(v) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            var sum = 0.0, count = 0.0
            for y in 3..<height {
                for x in 0..<Int(Double(width) * 0.45) {
                    let i = (y * width + x) * 4
                    sum += 0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
                    count += 1
                }
            }
            return count > 0 ? sum / count : nil
        }.value
        if let value { grounds[url] = value }
        return value
    }

    /// One of the artwork's main colours (hue and saturation only; whoever
    /// shows it picks the brightness).
    struct Swatch {
        let hue: CGFloat
        let saturation: CGFloat
    }

    @MainActor private static var palettes: [String: [Swatch]] = [:]

    /// The artwork's strongest colours, strongest first (one or two): its
    /// colourful pixels sorted into twelve hue groups — the winning GROUP's
    /// colour, not the average of everything (yellow and red average to an
    /// orange that is in neither).
    @MainActor
    static func palette(for url: String) async -> [Swatch]? {
        let always = RenderProbe.shared.flags.tintAlwaysTwo
        let key = always ? url + "|two" : url
        if let cached = palettes[key] { return cached }
        let found: [Swatch]? = await Task.detached(priority: .utility) {
            guard let image = await smallImage(url) else { return nil }
            return swatches(from: image, alwaysTwo: always)
        }.value
        guard let found else { return nil }
        palettes[key] = found
        return found
    }

    private static func swatches(from image: UIImage, alwaysTwo: Bool) -> [Swatch]? {
        guard let cg = image.cgImage else { return nil }
        let side = 24, groups = 12
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

        var weight = [Double](repeating: 0, count: groups)
        var red = weight, green = weight, blue = weight
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let hi = max(r, g, b), lo = min(r, g, b)
            let saturation = hi == 0 ? 0 : (hi - lo) / hi
            // Greys, near-black and near-white have no colour to offer.
            guard hi > 0.15, saturation > 0.2 else { continue }
            var hue: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &s, brightness: &v, alpha: &a)
            // Groups centred on the pure hues (red spans 345°–15°, …).
            let group = Int((Double(hue) * Double(groups) + 0.5)) % groups
            let w = saturation * saturation * hi
            weight[group] += w
            red[group] += r * w; green[group] += g * w; blue[group] += b * w
        }
        func swatch(_ group: Int) -> Swatch {
            var hue: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: red[group] / weight[group], green: green[group] / weight[group],
                    blue: blue[group] / weight[group], alpha: 1)
                .getHue(&hue, saturation: &s, brightness: &v, alpha: &a)
            return Swatch(hue: hue, saturation: min(s * Spotlight.tintSaturationBoost, Spotlight.tintMaxSaturation))
        }
        guard let first = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[first] > 0 else {
            // No colour at all (black-and-white artwork): neutral (and a
            // faint cool grey beside it).
            return [Swatch(hue: 0, saturation: 0)] + (alwaysTwo ? [Swatch(hue: 0.6, saturation: 0.15)] : [])
        }
        if !alwaysTwo {
            // A second colour only if it is a DIFFERENT one (not the
            // neighbouring group) and carries real weight.
            let second = weight.indices
                .filter { min(abs($0 - first), groups - abs($0 - first)) >= 2 && weight[$0] >= weight[first] * 0.3 }
                .max(by: { weight[$0] < weight[$1] })
            return [swatch(first)] + (second.map { [swatch($0)] } ?? [])
        }
        // ALWAYS a second colour (Render Lab → Tint: always two colours), the best there
        // is: a DIFFERENT colour (two groups away or more) with some weight,
        // else the neighbouring group's, else one made from the first — its
        // hue turned 30° (towards the side with more weight), a little less
        // full. A trace (under 5 % of the first) is noise, not a colour.
        func distance(_ g: Int) -> Int { min(abs(g - first), groups - abs(g - first)) }
        let floor = weight[first] * 0.05
        let other = weight.indices
            .filter { distance($0) >= 2 && weight[$0] >= floor }
            .max(by: { weight[$0] < weight[$1] })
        let neighbour = weight.indices
            .filter { distance($0) == 1 && weight[$0] >= floor }
            .max(by: { weight[$0] < weight[$1] })
        if let second = other ?? neighbour { return [swatch(first), swatch(second)] }
        let main = swatch(first)
        let left = weight[(first + groups - 1) % groups], right = weight[(first + 1) % groups]
        let turn: CGFloat = right >= left ? 1.0 / 12 : -1.0 / 12
        var hue = main.hue + turn
        if hue < 0 { hue += 1 } else if hue >= 1 { hue -= 1 }
        return [main, Swatch(hue: hue, saturation: main.saturation * 0.8)]
    }
}

// MARK: - Colour grid

extension SpotlightTint {
    /// The picture's average colour in each cell of a grid (row 0 at the
    /// top; sRGB 0…1) — "Picture's colour layout". Near-black pixels count
    /// little, so a dark corner doesn't turn its cell grey-black.
    @MainActor
    static func grid(for url: String, columns: Int, rows: Int) async -> [[(Double, Double, Double)]]? {
        await Task.detached(priority: .userInitiated) { () -> [[(Double, Double, Double)]]? in
            guard let image = await smallImage(url), let cg = image.cgImage else { return nil }
            let w = columns * 8, h = rows * 8
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            return (0..<rows).map { row in
                (0..<columns).map { column in
                    var r = 0.0, g = 0.0, b = 0.0, total = 0.0
                    for y in row * 8..<(row + 1) * 8 {
                        for x in column * 8..<(column + 1) * 8 {
                            let i = (y * w + x) * 4
                            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
                            let weight = 0.15 + max(pr, pg, pb)
                            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
                        }
                    }
                    return (r / total, g / total, b / total)
                }
            }
        }.value
    }
}

// MARK: - Area + vivid accent

/// Render Lab → Tint colour → "Area + vivid accent": the picture's colours
/// grouped by how they LOOK (OKLab, a perceptual colour space — a light sky
/// blue and a deep navy are different groups, a muted brown and a bright
/// orange too), not by hue alone.
/// - The main colour: the group covering the most of the picture — area
///   counts more than saturation, so earthy browns, olives and muted greens
///   can win; the top quarter (often sky) counts half.
/// - The second: the most VIVID group of a different hue (at least 40°
///   away) — the accent (a logo, hair, a costume), even when small.
extension SpotlightTint {
    @MainActor private static var areaPalettes: [String: [Swatch]] = [:]

    @MainActor
    static func areaPalette(for url: String) async -> [Swatch]? {
        let always = RenderProbe.shared.flags.tintAlwaysTwo
        let key = always ? url + "|two" : url
        if let cached = areaPalettes[key] { return cached }
        let found: [Swatch]? = await Task.detached(priority: .utility) {
            guard let image = await smallImage(url) else { return nil }
            return areaSwatches(from: image, alwaysTwo: always)
        }.value
        guard let found else { return nil }
        areaPalettes[key] = found
        return found
    }

    private struct Lab { var l: Double, a: Double, b: Double
        var chroma: Double { (a * a + b * b).squareRoot() }
        var hue: Double { let h = atan2(b, a) / (2 * .pi); return h < 0 ? h + 1 : h }
    }

    private static func lab(r: Double, g: Double, b: Double) -> Lab {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(r), g = linear(g), b = linear(b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Back to a swatch (hue and saturation, as the background shows it).
    private static func swatch(_ c: Lab) -> Swatch {
        let l = pow(c.l + 0.3963377774 * c.a + 0.2158037573 * c.b, 3)
        let m = pow(c.l - 0.1055613458 * c.a - 0.0638541728 * c.b, 3)
        let s = pow(c.l - 0.0894841775 * c.a - 1.2914855480 * c.b, 3)
        func encode(_ v: Double) -> CGFloat {
            let v = min(max(v, 0), 1)
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        let r = encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let b = encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        var hue: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &sat, brightness: &v, alpha: &a)
        return Swatch(hue: hue, saturation: min(sat * Spotlight.tintSaturationBoost, Spotlight.tintMaxSaturation))
    }

    private static func areaSwatches(from image: UIImage, alwaysTwo: Bool) -> [Swatch]? {
        guard let cg = image.cgImage else { return nil }
        let w = 32, h = 18
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // The pixels with some colour (not near-black, not grey), each
        // weighted by its place: the top quarter (row 0 is the TOP — the
        // context draws flipped into memory) counts half.
        var points: [(c: Lab, w: Double)] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let c = lab(r: Double(pixels[i]) / 255, g: Double(pixels[i + 1]) / 255, b: Double(pixels[i + 2]) / 255)
                guard c.l > 0.2, c.chroma > 0.025 else { continue }
                let place = y < h / 4 ? 0.5 : 1.0
                // Area first; colourfulness only a little (a muted brown
                // ~0.8 of a vivid one).
                let colour = min(1, 0.6 + c.chroma * 3)
                points.append((c, place * colour))
            }
        }
        guard points.count >= 4 else {
            // No colour to speak of: neutral (and a faint cool grey).
            return [Swatch(hue: 0, saturation: 0)] + (alwaysTwo ? [Swatch(hue: 0.6, saturation: 0.15)] : [])
        }

        // k-means in OKLab (lightness counted half: the background shows
        // every colour at its own brightness anyway), six groups, seeded
        // far apart.
        func distance(_ p: Lab, _ q: Lab) -> Double {
            let dl = (p.l - q.l) * 0.5, da = p.a - q.a, db = p.b - q.b
            return dl * dl + da * da + db * db
        }
        let k = min(6, points.count)
        var centres = [points.max { $0.w < $1.w }!.c]
        while centres.count < k {
            let next = points.max { a, b in
                centres.map { distance(a.c, $0) }.min()! < centres.map { distance(b.c, $0) }.min()!
            }!
            centres.append(next.c)
        }
        var weights = [Double](repeating: 0, count: k)
        for _ in 0..<10 {
            var sums = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: k)
            weights = [Double](repeating: 0, count: k)
            for p in points {
                let j = (0..<k).min { distance(p.c, centres[$0]) < distance(p.c, centres[$1]) }!
                sums[j].l += p.c.l * p.w; sums[j].a += p.c.a * p.w; sums[j].b += p.c.b * p.w
                weights[j] += p.w
            }
            for j in 0..<k where weights[j] > 0 {
                centres[j] = Lab(l: sums[j].l / weights[j], a: sums[j].a / weights[j], b: sums[j].b / weights[j])
            }
        }
        let total = weights.reduce(0, +)
        let groups = (0..<k).filter { weights[$0] > 0 }
        // The main colour: the biggest group.
        guard let main = groups.max(by: { weights[$0] < weights[$1] }) else { return nil }
        // The accent: the most vivid group of a different hue (40°+ away),
        // at least 2 % of the picture — its vividness counted far more
        // than its size.
        func hueGap(_ x: Double, _ y: Double) -> Double { let d = abs(x - y); return min(d, 1 - d) }
        let accent = groups
            .filter { $0 != main && weights[$0] / total >= 0.02 && centres[$0].chroma >= 0.05
                && hueGap(centres[$0].hue, centres[main].hue) >= 40.0 / 360 }
            .max { a, b in
                centres[a].chroma * (weights[a] / total).squareRoot()
                    < centres[b].chroma * (weights[b] / total).squareRoot()
            }
        let first = swatch(centres[main])
        if let accent { return [first, swatch(centres[accent])] }
        guard alwaysTwo else { return [first] }
        // None: one made from the main colour, its hue turned 30°.
        var hue = first.hue + 1.0 / 12
        if hue >= 1 { hue -= 1 }
        return [first, Swatch(hue: hue, saturation: first.saturation * 0.8)]
    }
}

// MARK: - Shared label
