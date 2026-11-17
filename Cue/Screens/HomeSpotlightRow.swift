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

    /// Height of the focus box AND the posters beside it: 12 % past THE
    /// poster (`FixedFocusMetrics.posterCard`, 387: the box at its height
    /// was too small for what it carries). (490 and 440 were too large.)
    static let rowHeight: CGFloat = 434
    /// Portrait 2:3 poster at row height (289 pt).
    static var posterWidth: CGFloat { rowHeight * 2 / 3 }
    /// Landscape 16:9 box at row height (~707 pt).
    static var boxWidth: CGFloat { rowHeight * 16 / 9 }
    /// Corner radius of the box and posters.
    static let cornerRadius: CGFloat = 22

    static let logoInset: CGFloat = 28
    /// How dark the gradient behind the logo gets at the box's bottom edge.
    static let logoScrimOpacity: Double = 0.75
    /// A card's state (Continue Watching, the episode rows, Details'
    /// episodes, the Top Shelf's cards): the player's bar, thicker for the
    /// card (3 pt, scaled, was too faint), at the foot, as far from it as from
    /// the sides; the episode and the time on plates at the top, their words
    /// in line with the bar's ends (`FixedFocusProgressView`).
    static let stateBarHeight: CGFloat = 6
    static let stateInset: CGFloat = 30

    /// The billboard's / Details' trailer starts after resting on a title
    /// this long (`StageTrailer`; Settings → Home & Details → Trailers,
    /// and not under Reduce Motion).
    static let trailerDelay: TimeInterval = 2.0

    // Vertical layout (fixed positions — every row puts the box in exactly
    // the same place, which is what lets the rows glide between spots).

    /// Left margin of everything. Shared with the Detail page, so both
    /// screens line up.
    static let screenInset: CGFloat = 84
    static let labelHeight: CGFloat = 40
    /// Focus row's name / the "▴ ▾" labels.
    static let headerTitleSize: CGFloat = 34

    // Next-row preview

    /// How much of the preview row shows above the screen edge.
    static let previewVisibleHeight: CGFloat = 247

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
            // On the card's picture, no pill (it was there for the open
            // picture): the text's shadow.
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
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

// MARK: - Shared label
