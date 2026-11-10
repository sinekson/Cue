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

    /// Height of the focus box AND the posters beside it: THE portrait
    /// poster's (`FixedFocusMetrics.posterCard`, 398 — every poster in the
    /// app one size; was 420).
    static let rowHeight: CGFloat = FixedFocusMetrics.posterCard.height
    /// Portrait 2:3 poster at row height (265 pt).
    static var posterWidth: CGFloat { rowHeight * 2 / 3 }
    /// Landscape 16:9 box at row height (~707 pt).
    static var boxWidth: CGFloat { rowHeight * 16 / 9 }
    /// Gap between the box and posters, and between posters.
    static let spacing: CGFloat = 24
    /// Corner radius of the box and posters.
    static let cornerRadius: CGFloat = 22

    static let logoInset: CGFloat = 28
    /// How dark the gradient behind the logo gets at the box's bottom edge.
    static let logoScrimOpacity: Double = 0.75
    /// A card's state line (Continue Watching, Details' episodes, the Top
    /// Shelf's cards): the player's bar, thicker for the card (3 pt, scaled,
    /// was too faint), at the foot, as far from it as from the sides; one line
    /// above it: the episode on the left, the time left at its end (text above
    /// and below the bar looked odd).
    static let stateBarHeight: CGFloat = 6
    static let stateInset: CGFloat = 30
    /// The caption's size under the card (24 read larger than it), medium.
    static let stateTextSize: CGFloat = FixedFocusMetrics.captionSize
    /// From the line's baseline to the bar's top.
    static let stateBaselineGap: CGFloat = 12

    /// The billboard's / Details' trailer starts after resting on a title
    /// this long (`StageTrailer`; Settings → Home & Details → Trailers,
    /// and not under Reduce Motion).
    static let trailerDelay: TimeInterval = 2.0

    // Vertical layout (fixed positions — every row puts the box in exactly
    // the same place, which is what lets the rows glide between spots).

    /// Left margin of everything. Shared with the Detail page, so both
    /// screens line up.
    static let screenInset: CGFloat = 84
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
    /// Where a new preview row starts when there's no preview spot.
    static let incomingPreviewRise: CGFloat = 120

    // Featured billboard (the first "row": one big box, Netflix-style)

    static let showFeatured = true

    // Background

    /// Extracted colours: a little fuller, never loud.
    static let tintSaturationBoost: CGFloat = 1.2
    static let tintMaxSaturation: CGFloat = 0.6
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

    static let dot: CGFloat = 12
    static let pill: CGFloat = 36
    static let gap: CGFloat = 12
    /// Around the dots inside their glass capsule.
    static let capsulePadding: CGFloat = 16

    /// The row's width: one pill, the rest dots — the same at every title.
    static func width(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * (dot + gap) + pill
    }

    var body: some View {
        // The dots in Core Animation (`BillboardDotsView`): moved in SwiftUI,
        // the main thread's work at each page (picture, text, colours) made
        // the pill stutter, and the fill, taken off one pill and put on the
        // next, flickered at the end of quick paging.
        BillboardDotsRepresentable(count: count, current: current, focused: focused,
                                   timer: timer, cycle: cycle)
            .frame(width: Self.width(count: count), height: Self.dot)
            .padding(.horizontal, Self.capsulePadding)
            .padding(.vertical, Self.capsulePadding * 0.75)
            .background { Color.clear.liquidGlass(in: Capsule()) }
            .opacity(count > 1 ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct BillboardDotsRepresentable: UIViewRepresentable {
    let count: Int
    let current: Int
    let focused: Bool
    let timer: Double?
    let cycle: Int

    func makeUIView(context: Context) -> BillboardDotsView { BillboardDotsView() }

    func updateUIView(_ view: BillboardDotsView, context: Context) {
        view.show(count: count, current: current, focused: focused, timer: timer, cycle: cycle)
    }
}

/// The dots: each a capsule view, the current one a pill, widened and
/// narrowed on Left/Right's spring (`FixedFocusMotion.run`: a press mid-move
/// carries its speed on). Timed, the pill's fill (white, inside it, clipped
/// to it) grows from its left end, linear — it's a clock; at the last
/// title (no timer) it completes to a solid pill on the same spring.
final class BillboardDotsView: UIView {
    private var dots: [UIView] = []
    private var fills: [UIView] = []
    private var shown: (count: Int, current: Int, focused: Bool, timer: Double?, cycle: Int)?

    func show(count: Int, current: Int, focused: Bool, timer: Double?, cycle: Int) {
        let old = shown
        shown = (count, current, focused, timer, cycle)
        guard count > 0 else { return }
        if old?.count != count || dots.isEmpty {
            build(count: count)
            UIView.performWithoutAnimation { lay(current: current, focused: focused, timer: timer) }
            startFill(at: current, timer: timer)
            return
        }
        guard let old else { return }
        let moved = old.current != current
        let restart = moved || old.timer != timer || old.cycle != cycle
        guard restart || old.focused != focused else { return }
        if restart, timer != nil, (0..<count).contains(current) {
            // The new pill's fill from its left end, at once; it shows with
            // the move.
            UIView.performWithoutAnimation {
                let fill = fills[current]
                fill.layer.removeAllAnimations()
                fill.frame = CGRect(x: 0, y: 0, width: BillboardDots.dot, height: BillboardDots.dot)
                if moved { fill.alpha = 0 }
            }
        }
        FixedFocusMotion.run(duration: Motion.moveDuration, animations: {
            self.lay(current: current, focused: focused, timer: timer)
        }, completion: { _ in })
        if restart { startFill(at: current, timer: timer) }
    }

    private func build(count: Int) {
        dots.forEach { $0.removeFromSuperview() }
        dots = []
        fills = []
        for _ in 0..<count {
            let dot = UIView()
            dot.layer.cornerRadius = BillboardDots.dot / 2
            dot.layer.cornerCurve = .continuous
            dot.clipsToBounds = true
            let fill = UIView(frame: CGRect(x: 0, y: 0, width: BillboardDots.dot, height: BillboardDots.dot))
            fill.backgroundColor = .white
            fill.layer.cornerRadius = BillboardDots.dot / 2
            fill.layer.cornerCurve = .continuous
            fill.alpha = 0
            dot.addSubview(fill)
            addSubview(dot)
            dots.append(dot)
            fills.append(fill)
        }
    }

    /// Every dot's place, width and level; the fill shown only in the pill.
    private func lay(current: Int, focused: Bool, timer: Double?) {
        var x: CGFloat = 0
        for (k, dot) in dots.enumerated() {
            let on = k == current
            let width = on ? BillboardDots.pill : BillboardDots.dot
            dot.frame = CGRect(x: x, y: 0, width: width, height: BillboardDots.dot)
            x += width + BillboardDots.gap
            let level: Double
            if on { level = timer != nil ? 0.3 : (focused ? 1 : 0.62) }
            else { level = k < current ? 0.62 : 0.3 }
            dot.backgroundColor = UIColor.white.withAlphaComponent(level)
            let fill = fills[k]
            // (Without a clock, the pill keeps a fill already showing: it
            // completes, the track brightening under it.)
            fill.alpha = on && (timer != nil || fill.alpha > 0) ? 1 : 0
            if on, timer == nil, fill.layer.animationKeys() != nil {
                // The clock stopped: the fill completes into the solid pill,
                // from where it is on screen (its frame is already the end).
                let now = fill.layer.presentation()?.frame ?? fill.frame
                fill.layer.removeAllAnimations()
                UIView.performWithoutAnimation { fill.frame = now }
                fill.frame.size.width = BillboardDots.pill
            }
        }
    }

    /// The clock: the pill's fill to its full width over `timer`, linear.
    private func startFill(at current: Int, timer: Double?) {
        guard let timer, (0..<fills.count).contains(current) else { return }
        let fill = fills[current]
        UIView.animate(withDuration: timer, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            fill.frame.size.width = BillboardDots.pill
        }
    }
}

/// Settings → Appearance → "Billboard pages by itself": resting on the
/// billboard, the next title every `interval` seconds.
enum BillboardAutoPage {
    static let key = "cue.home.billboardAutoPage"
    static let interval: Double = 5
}

/// Settings → Home & Details → Hide watched titles: Home's catalog rows
/// leave out watched films and shows with every aired episode watched
/// (Continue Watching, Saved for Later and the collections keep theirs).
enum HomeHideWatched {
    static let key = "cue.home.hideWatched"
}

/// Settings → Home & Details → Hide spoilers: Details' episodes not yet
/// watched or started show their still blurred.
enum DetailHideSpoilers {
    static let key = "cue.details.hideSpoilers"
}

// MARK: - Place memory

/// The artwork's colours for the title background, from a 64 px copy of
/// the picture (the disk cache — the box has usually downloaded it already).
enum SpotlightTint {
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

    /// One of the artwork's main colours (hue and saturation only; whoever
    /// shows it picks the brightness).
    struct Swatch {
        let hue: CGFloat
        let saturation: CGFloat
    }
}

// MARK: - Area + vivid accent

/// The picture's colours
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
        if let cached = areaPalettes[url] { return cached }
        let found: [Swatch]? = await Task.detached(priority: .utility) {
            guard let image = await smallImage(url) else { return nil }
            return areaSwatches(from: image)
        }.value
        guard let found else { return nil }
        areaPalettes[url] = found
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

    private static func areaSwatches(from image: UIImage) -> [Swatch]? {
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
            // No colour to speak of: neutral.
            return [Swatch(hue: 0, saturation: 0)]
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
        return [first]
    }
}

// MARK: - Shared label
