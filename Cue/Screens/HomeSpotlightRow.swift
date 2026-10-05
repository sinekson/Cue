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

/// The billboard's position: one dot per title, and a highlight gliding to
/// the current one — larger, bright white while the billboard has focus.
/// Flat (it's in the page).
struct BillboardDots: View {
    let count: Int
    let current: Int
    /// The billboard has focus: the highlight is bright white (else faint).
    let focused: Bool

    /// Centre to centre; a glass dot; the highlight on the current one.
    static let pitch: CGFloat = 28
    static let dot: CGFloat = 14
    static let marker: CGFloat = 20

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(count, 0), id: \.self) { k in
                ZStack {
                    // (The current one IS the highlight.)
                    Circle().fill(AppGlass.idleTint)
                        .frame(width: Self.dot, height: Self.dot)
                        .opacity(k == current ? 0 : 1)
                        .animation(GlassPill.glide, value: current)
                    Color.clear
                        .frame(width: Self.marker, height: Self.marker)
                        .glassPillItem(k, in: highlight)
                }
                .frame(width: Self.pitch, height: Self.marker)
            }
        }
        // (In the page: flat, not glass.)
        .glassHighlight(on: current, in: highlight, focused: focused, glass: false)
        .opacity(count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }
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
        if let cached = palettes[url] { return cached }
        let found: [Swatch]? = await Task.detached(priority: .utility) {
            guard let image = await smallImage(url) else { return nil }
            return swatches(from: image)
        }.value
        guard let found else { return nil }
        palettes[url] = found
        return found
    }

    private static func swatches(from image: UIImage) -> [Swatch]? {
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
            // No colour at all (black-and-white artwork): neutral.
            return [Swatch(hue: 0, saturation: 0)]
        }
        // A second colour only if it is a DIFFERENT one (not the neighbouring
        // group) and carries real weight.
        let second = weight.indices
            .filter { min(abs($0 - first), groups - abs($0 - first)) >= 2 && weight[$0] >= weight[first] * 0.3 }
            .max(by: { weight[$0] < weight[$1] })
        return [swatch(first)] + (second.map { [swatch($0)] } ?? [])
    }
}

// MARK: - Shared label
