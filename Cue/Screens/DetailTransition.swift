import SwiftUI
import AVFoundation
import Combine

/// THE way into Details, from everywhere (billboard, cards, Search, folders,
/// More Like This). Nothing shown before it's final; every move is Core
/// Animation (played by the render server — the main thread can't make it
/// jump), and nothing heavy runs while something moves. STRICT PHASES:
/// A. Move 1 — the page dims; Details' picture comes forward over it: in at
///    Home's framing, zooming once into Details' as it fades in. Starts
///    once the picture is decoded (usually at the press).
/// B. Still — everything else is loaded (`DetailPreparer`), Details is pushed
///    and built under the still picture, until the main thread has been
///    quiet for a few frames.
/// C. Move 2 — the picture hands over to Details (its rows' name) and the
///    info block fades in, in place. Focus is on Play from its first frame.
/// Back: the mirror. Every phase's main-thread hitches go to the LAN log
/// ("details") — `FrameWatch`.
@MainActor
final class DetailTransition {
    static let shared = DetailTransition()

    // The look — tune here (the real durations; no multiplier).
    /// A: the page going (it only dims — scaled too, it fought the
    /// picture's zoom: in, out, in).
    static let pageDim: CGFloat = 0.85
    static let pageTime: Double = 0.3
    /// A: the picture, from exactly Home's framing (the billboard's — Details
    /// frames it `ModeSwap.depthScale` larger) zooming ONCE into Details'.
    static let pictureDelay: Double = 0.05
    static let pictureFade: Double = 0.38
    static let pictureSettle: Double = 0.55
    /// Fade: the zoomed backdrop alone this long before the info block
    /// comes in. (Tried: the info block landing WITH the zoom's end, and
    /// 0.1 s before it — not it; a 0.25 s pause — too slow.)
    static let picturePause: Double = 0.0
    /// …the info block starting at this much of the zoom's time (its tail
    /// barely moves; 1: at its very end).
    static let revealAt: Double = 0.85
    /// The picture's zoom: the original curve — quick off the mark, a long
    /// settle — a little slower (0.7 s; was 0.5, then 0.6). (Tried: linear —
    /// too abrupt; gentle starts (0.45, 0, 0.15, 1), (0.3, 0.25, 0.15, 1);
    /// ease in-out (0.35, 0, 0.25, 1).)
    static let zoomInCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
    /// B: quiet frames before C (and at most this long).
    static let quietFrames = 2
    static let quietLimit: Double = 1.0
    /// C: the hand-over and the rise.
    static let reveal: Double = 0.28

    static let textTime: Double = 0.28
    /// Back (the simple exit): one dissolve from the press, Details off
    /// the page below as it was at the opening (`backTime`);
    /// the live page takes over from the still once it's drawn — at most
    /// `exitWait` after the press — the still fading off it
    /// (`exitHandOver`) under Details, still mostly there (swapped at the
    /// end, the two differed — the pressed button, the picture's drift —
    /// and it flickered). (Tried: 0.25 s fade + shrink after the rebuild —
    /// delayed, then rushed; the page dimmed and brightening after — two
    /// steps; shrinking — the dimmed page a black border; growing; through
    /// the background picture — two steps.)
    static let exitWait: Double = 0.25
    static let exitHandOver: Double = 0.2
    /// In and Back, every page's (Details' way in is its zoom) — a layer's (over Home, Movies, Series: the page
    /// under it live, never out of the window) and a pushed one's (into
    /// the still of the page below): the tabs' dissolve — the page coming
    /// back there at once, whole, the one going out fading off it, ease
    /// in-out. (Tried: 0.6 s, a soft start and a long settle, and 0.35 s
    /// ease out — slower
    /// than the tabs'; pushed: a crossfade into a still of the page —
    /// billboard to billboard every part showed twice; Details' text out
    /// first; its picture settling to Home's size; through the background
    /// picture, 0.3 + 0.3 s and 0.4 + 0.6 s — not gentle.)
    static let backTime: Double = Motion.fadeDuration
    static let ringAfter: Double = 1.5
    static let giveUp: Double = 8

    static let inOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let out = CAMediaTimingFunction(name: .easeOut)

    private(set) var busy = false
    private var appeared: String?
    /// The picture each opened page shows (Back brings it over it again).
    private var pictures: [String: String] = [:]
    /// Details' info block (its host view in the rows engine): hidden from
    /// its first frame while `hidesNextText`, then risen in.
    var hidesNextText = false
    private(set) weak var textView: UIView?
    private var textViews: [String: UIView] = [:]
    private let overlay = DetailTransitionOverlay()

    /// The rows engine made a billboard text host.
    func textHostCreated(_ view: UIView) {
        guard hidesNextText else { return }
        hidesNextText = false
        view.alpha = 0
        textView = view
    }

    func pageAppeared(_ id: String) { appeared = id }

    /// Where an opening started (Back returns there): the picture at
    /// Home's framing.
    struct Opening {
        var picture: CGRect
    }
    private var openings: [String: Opening] = [:]

    static var screen: CGRect { CGRect(origin: .zero, size: StagePictureView.pictureSize) }
    /// Details' picture on screen: a little wider than it (the drift),
    /// stepped closer (`ModeSwap.depthScale`).
    static func detailsPicture(scale: CGFloat? = nil) -> CGRect {
        let scale = scale ?? ModeSwap.depthScale(1)
        let size = CGSize(width: (1920 + 2 * StagePictureView.drift) * scale, height: 1080 * scale)
        return CGRect(x: 960 - size.width / 2, y: 540 - size.height / 2, width: size.width, height: size.height)
    }

    /// The opening's start: Home's framing of the picture (the billboard's,
    /// as large as it is at the press).
    private static func opening(startScale: CGFloat) -> Opening {
        Opening(picture: detailsPicture(scale: startScale))
    }

    /// `keepsPicture`: Details opens with the picture `item` carries (the
    /// billboard's) — else with TMDB's (`TitlePictures`).
    /// `trailer`: the billboard's, playing — it plays on over the picture,
    /// never zooming, into Details' (which takes it, `StageTrailer.adopt`).
    func open(_ item: MetaItem, keepsPicture: Bool = false, trailer: AVPlayer? = nil, push: @escaping () -> Void) {
        guard !busy, !PageFade.shared.busy, let window = Self.window else { return }
        CueRows.Memory.shared.opened(item.id)
        let opening = Self.opening(startScale: 1)
        busy = true
        ModeSwap.shared.handingOver = true
        DetailOpenProbe.pressed()
        DetailPreparer.shared.start(item, keepsPicture: keepsPicture)
        // The screen as it is, in the overlay: what dims and what the picture
        // comes over — so Details can be pushed and BUILT under it at once,
        // during move 1 (the moves are the render server's; the main thread
        // building doesn't touch them).
        let page = window.snapshotView(afterScreenUpdates: false)
        overlay.install(in: window, page: page)
        // Kept: Back dissolves into it at once (`close`).
        if let page { PageFade.shared.keep(page, for: item.id) }
        let watch = FrameWatch()
        let k = Self.length
        Task { @MainActor in
            let start = CACurrentMediaTime()
            let ring = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.ringAfter * Self.length))
                if !Task.isCancelled { self.overlay.ring(true) }
            }
            // A. Move 1: the page dims at once; the picture as soon as it's
            // decoded. (Not awaited: Details is built meanwhile.)
            watch.begin("move 1")
            // (A trailer playing: no dim — the video comes over Home's at
            // full brightness, in its place, only Home's text and buttons
            // fading; the picture zooms under it.)
            var moves: [Task<Void, Never>] = []
            if trailer == nil { moves.append(Task { await Self.run {
                Self.animate(self.overlay.dim, "opacity", from: 0, to: Self.pageDim, Self.pageTime * k, Self.inOut)
            } }) }
            let url = await DetailPreparer.shared.picture(for: item, within: Self.giveUp)
            let image = url.flatMap(Self.decoded)
            let wait = Self.pictureDelay * k - (CACurrentMediaTime() - start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            var zoomEnd: CFTimeInterval?
            if let url, let image {
                pictures[item.id] = url
                openings[item.id] = opening
                overlay.picture.image = image
                overlay.video.player = trailer
                overlay.video.alpha = trailer == nil ? 0 : 1
                // The billboard's own shade (Details uses the same).
                overlay.place(opening, shade: StageArt.shade)
                zoomEnd = CACurrentMediaTime() + Self.pictureSettle * k
                moves.append(Task {
                    await Self.run {
                        Self.animate(self.overlay.pictureFrame.layer, "opacity", from: 0, to: 1, Self.pictureFade * k, Self.out)
                        self.overlay.open(from: opening, Self.pictureSettle * k, Self.zoomInCurve)
                    }
                })
            }
            // A frame for the moves to be handed over before the main thread
            // gets busy (Details is built during them).
            try? await Task.sleep(for: .milliseconds(20))
            // Under it: the rest of the data, then Details, pushed and built.
            await DetailPreparer.shared.ready(item, within: Self.giveUp)
            ModeSwap.shared.billboardItemID = item.id
            ModeSwap.shared.billboardRatings = nil
            ModeSwap.shared.billboardFacts = nil
            ModeSwap.shared.billboardSeriesSize = nil
            ModeSwap.shared.billboardTint = (nil, nil)
            appeared = nil
            hidesNextText = true
            DetailOpenProbe.note("push")
            DetailsOpen.shared.depth += 1
            push()
            ModeSwap.shared.handingOver = false
            let built = CACurrentMediaTime()
            while appeared != item.id, CACurrentMediaTime() - built < 1 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let drawnAt = CACurrentMediaTime()
            // The rest once the picture looks landed — `revealAt` of its zoom
            // (its last bit hardly moves and runs out under the fade) — and
            // Details is ready.
            if let zoomEnd {
                await moves.first?.value
                let at = zoomEnd - Self.pictureSettle * k * (1 - Self.revealAt) - CACurrentMediaTime()
                if at > 0 { try? await Task.sleep(for: .seconds(at)) }
                if Self.picturePause > 0 { try? await Task.sleep(for: .seconds(Self.picturePause * k)) }
            } else {
                for move in moves { await move.value }
            }
            // B. Only if Details was drawn just now: its first frames.
            watch.begin("still")
            if CACurrentMediaTime() - drawnAt < 0.15 {
                await watch.quiet(frames: Self.quietFrames, within: Self.quietLimit)
            }
            hidesNextText = false
            ring.cancel()
            overlay.ring(false)
            if let text = textView { textViews[item.id] = text }
            let covered = image != nil
            // The page (the snapshot) gone under the picture.
            if covered {
                Self.set(overlay.dim, "opacity", 0)
                overlay.dropPage()
            }
            // (Dev: `-detailsHold` keeps the cover up a while — to compare it
            // with Details on screenshots.)
            if ProcessInfo.processInfo.arguments.contains("-detailsHold") {
                try? await Task.sleep(for: .seconds(3))
            }
            // C. Hand-over and rise.
            watch.begin("move 2")
            DetailOpenProbe.note("reveal")
            let text = textView
            Self.refocus()
            await Self.run {
                if !covered {
                    Self.animate(self.overlay.dim, "opacity", from: Self.pageDim, to: 0, Self.reveal * k, Self.inOut)
                    self.overlay.fadePage(Self.reveal * k)
                }
                Self.animate(self.overlay.pictureFrame.layer, "opacity", from: covered ? 1 : 0, to: 0, Self.reveal * k, Self.inOut)
                // The info block: a plain fade, in place.
                if let text {
                    text.alpha = 1
                    Self.animate(text.layer, "opacity", from: 0, to: 1, Self.textTime * k, Self.inOut)
                }
            }
            watch.end()
            overlay.remove()
            busy = false
        }
    }

    /// FROM THE BILLBOARD, IN PLACE, in two phases on the move spring (0.35 s).
    /// Out (`BillboardOpening`): the top bar, the peek and the dots move
    /// out, the reason goes; the buttons stay, the pressed one dimmed. Then Details, built
    /// under a still of that (it looks the same — its buttons wearing
    /// Home's), takes over, and in: its peek rises, its trailer hint
    /// appears, its buttons become its own (Details → Play, › → About),
    /// the picture leans in (`detailsArriving`). `trailer`: going on into Details
    /// (`StageTrailer.adopt`).
    func openInPlace(_ item: MetaItem, trailer: AVPlayer?, push: @escaping () -> Void) {
        guard !busy, !PageFade.shared.busy, let window = Self.window else { return }
        CueRows.Memory.shared.opened(item.id)
        busy = true
        InputHold.begin()
        // (Kept off under Details: back with Home's parts on Back.)
        BillboardOpening.shared.dimFocus(true)
        ModeSwap.shared.handingOver = true
        DetailOpenProbe.pressed()
        DetailPreparer.shared.start(item, keepsPicture: true)
        BillboardOpening.shared.move(to: true)
        BillboardOpening.shared.opened(item.id)
        let k = Self.length
        Task { @MainActor in
            let start = CACurrentMediaTime()
            await DetailPreparer.shared.ready(item, within: Self.giveUp)
            let left = Motion.moveDuration * k - (CACurrentMediaTime() - start)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            // Home as Details looks, still, over everything; Details built
            // under it.
            overlay.install(in: window, page: Self.seeThrough(window.snapshotView(afterScreenUpdates: false)))
            ModeSwap.shared.billboardItemID = item.id
            ModeSwap.shared.billboardRatings = nil
            ModeSwap.shared.billboardFacts = nil
            ModeSwap.shared.billboardSeriesSize = nil
            ModeSwap.shared.billboardTint = (nil, nil)
            appeared = nil
            DetailsOpen.shared.depth += 1
            BillboardOpening.shared.moveDetailsParts(out: true, animated: false)
            BillboardOpening.shared.leanDetails(false, animated: false)
            push()
            ModeSwap.shared.handingOver = false
            let built = CACurrentMediaTime()
            while appeared != item.id, CACurrentMediaTime() - built < 1 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let watch = FrameWatch()
            await watch.quiet(frames: Self.quietFrames, within: Self.quietLimit)
            watch.end()
            Self.refocus()
            overlay.remove()
            BillboardOpening.shared.moveDetailsParts(out: false)
            BillboardOpening.shared.leanDetails(true)
            try? await Task.sleep(for: .seconds(Motion.moveDuration * k))
            // Home, hidden under it now, as it was (after: its re-render
            // stalled the move).
            BillboardOpening.shared.move(to: false, animated: false)
            InputHold.end()
            busy = false
        }
    }

    /// Back to the billboard from a Details opened in place: the opening
    /// reversed — Home shown under a still of Details in Details' looks,
    /// then its parts back.
    private func closeInPlace(close: @escaping () -> Void, gone: @escaping () -> Void) {
        guard let window = Self.window else { close(); gone(); return }
        busy = true
        InputHold.begin()
        BillboardOpening.shared.close(true)
        let k = Self.length
        BillboardOpening.shared.moveDetailsParts(out: true)
        Task { @MainActor in
            // Details' peek and hint out first (nearly: the spring's tail is slow).
            try? await Task.sleep(for: .seconds(Self.peekOutTime * k))
            overlay.install(in: window, page: Self.seeThrough(window.snapshotView(afterScreenUpdates: false)))
            BillboardOpening.shared.move(to: true, animated: false)
            BillboardOpening.shared.moveDetailsParts(out: false, animated: false)
            close()
            let watch = FrameWatch()
            await watch.quiet(frames: Self.quietFrames, within: Self.quietLimit)
            watch.end()
            overlay.remove()
            BillboardOpening.shared.move(to: false)
            BillboardOpening.shared.dimFocus(false)
            try? await Task.sleep(for: .seconds(Motion.moveDuration * k))
            BillboardOpening.shared.close(false)
            InputHold.end()
            gone()
            busy = false
        }
    }

    /// Back: Details' peek is all but out by then.
    static let peekOutTime = 0.23

    /// A still not quite opaque: the page under it is drawn while covered
    /// (wholly covered, it was first drawn as the still went — a stall that
    /// the moves starting then ran through: they popped in at their end).
    /// As `PageFade`'s cover.
    private static func seeThrough(_ still: UIView?) -> UIView? {
        still?.alpha = 0.995
        return still
    }

    /// 1 — or 4 with the dev slow motion.
    static var length: Double { slowMotion ? 4 : 1 }
    /// Dev: `-transitionSlowMo` — every move 4× longer (to watch / screenshot).
    static let slowMotion = ProcessInfo.processInfo.arguments.contains("-transitionSlowMo")

    /// Back from Details: Details dissolves into the page below — one
    /// crossfade, from the press.
    func close(itemID: String?, pop: @escaping () -> Void) {
        guard !busy else { pop(); return }
        // THE EXIT (from anywhere, the billboard too): every page's Back
        // (`PageFade`), into the still of the page below at the opening.
        // (No picture brought back into its card.)
        forget(itemID)
        PageFade.shared.back(key: itemID, pop)
        DetailsOpen.shared.depth = max(0, DetailsOpen.shared.depth - 1)
    }

    /// Back from Details as a layer: it fades off the live page under it
    /// (`backTime`); `close` shows the page under it, `gone` removes the
    /// layer once the fade is over.
    func closeLayer(itemID: String, close: @escaping () -> Void, gone: @escaping () -> Void) {
        guard !busy else { close(); gone(); return }
        forget(itemID)
        PageFade.shared.drop(itemID)
        if BillboardOpening.shared.closes(itemID) {
            DetailsOpen.shared.depth = max(0, DetailsOpen.shared.depth - 1)
            closeInPlace(close: close, gone: gone)
            return
        }
        // (Opened in place and taken off the trail since.)
        BillboardOpening.shared.dimFocus(false)
        PageFade.shared.fadeOff(close, gone: gone)
        DetailsOpen.shared.depth = max(0, DetailsOpen.shared.depth - 1)
    }

    /// A Details taken off the trail under the page on screen
    /// (`RootView.trail`): as if closed.
    func dropped(itemID: String) {
        forget(itemID)
        PageFade.shared.drop(itemID)
        DetailsOpen.shared.depth = max(0, DetailsOpen.shared.depth - 1)
    }

    private func forget(_ itemID: String?) {
        guard let itemID else { return }
        textViews[itemID] = nil
        pictures[itemID] = nil
        openings[itemID] = nil
    }

    // MARK: Core Animation

    /// The animations added in `body`, until Core Animation says they're
    /// ALL done (a fixed wait cut them short when they began late).
    /// …or until their longest one has ended by the clock, whichever comes
    /// first (a late report never holds the next phase back).
    private static func run(_ body: () -> Void) async {
        collecting = 0
        var resumed = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            func finish() {
                guard !resumed else { return }
                resumed = true
                done.resume()
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            body()
            CATransaction.commit()
            // To the render server NOW: otherwise only when the main thread
            // next returns to its run loop — after building Details, the
            // moves began ~0.25 s late.
            CATransaction.flush()
            let longest = collecting ?? 0
            collecting = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(longest + 1.0 / 60))
                finish()
            }
        }
    }
    /// The longest animation added inside a `run` so far.
    private static var collecting: Double?
    private static func note(_ duration: Double) {
        if let longest = collecting { collecting = max(longest, duration) }
    }

    /// From → to, the model value set to the end (it stays there).
    static func animate(_ layer: CALayer, _ path: String, from: CGFloat, to: CGFloat,
                        _ duration: Double, _ curve: CAMediaTimingFunction, delay: Double = 0) {
        let animation = CABasicAnimation(keyPath: path)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = curve
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        note(duration + delay)
        set(layer, path, to)
        layer.add(animation, forKey: path)
    }

    /// A layer from one frame (in its superlayer) to another: its size and
    /// place (Core Animation scales a picture's contents with it).
    static func move(_ layer: CALayer, from: CGRect, to: CGRect, _ duration: Double, _ curve: CAMediaTimingFunction) {
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = CGRect(origin: .zero, size: from.size)
        bounds.toValue = CGRect(origin: .zero, size: to.size)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = CGPoint(x: from.midX, y: from.midY)
        position.toValue = CGPoint(x: to.midX, y: to.midY)
        for animation in [bounds, position] {
            animation.duration = duration
            animation.timingFunction = curve
        }
        note(duration)
        place(layer, to)
        layer.add(bounds, forKey: "bounds")
        layer.add(position, forKey: "position")
    }

    static func place(_ layer: CALayer, _ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()
    }

    static func set(_ layer: CALayer, _ path: String, _ value: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: path)
        layer.setValue(value, forKeyPath: path)
        CATransaction.commit()
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The picture as Details decodes it (same size: same memory entry).
    private static func decoded(_ url: String) -> UIImage? {
        ImageCache.shared.image(for: RemoteImage.memoryKey(url, maxDimension: PictureSize.screen,
                                                           maxPixels: nil))
    }

    /// Focus onto the page that's now up.
    private static func refocus() {
        window?.rootViewController?.setNeedsFocusUpdate()
        window?.rootViewController?.updateFocusIfNeeded()
    }
}

typealias DetailTransitionOpening = DetailTransition.Opening

/// Into Details from the billboard in place (`DetailTransition.openInPlace`):
/// Home's billboard in Details' looks — the parts that follow it (the
/// top bar, the peek, the dots, the text's first line, the buttons, the
/// picture) read `opened`.
@MainActor
/// Observed per property (`@Observable`): each view updates only for what
/// it reads — as one `ObservableObject` every change (eight a transition)
/// re-ran the root's and Home's bodies, mid-move.
@Observable
final class BillboardOpening {
    static let shared = BillboardOpening()
    private(set) var opened = false
    /// The tab in front's billboard trailer on its picture: the top bar
    /// moves out with the peek and the dots, as into Details (Home sets it).
    var trailerShown = false
    /// A move running (the top bar takes its spring) — read with `opened`,
    /// never watched.
    @ObservationIgnored private(set) var running = false
    /// Details' incoming parts held out — the peek (its first row) below
    /// the screen, the trailer hint hidden: Details comes in built that
    /// way, they come in together after the hand-over (the second phase);
    /// on Back they go first.
    private(set) var detailsArriving = false
    /// Details' picture leaned in. Opened in place it comes in at Home's
    /// size and leans in with its arriving parts — the picture moves with
    /// what arrives, as on Back (Home's parts, the picture leaning out).
    private(set) var detailsLeaned = true
    /// The billboard buttons' highlight dimmed: from the press into
    /// Details (Details' own buttons undim as they arrive) until Home's
    /// parts come back on Back.
    private(set) var focusDimmed = false
    func dimFocus(_ on: Bool) { focusDimmed = on }
    /// Back to the billboard in place running (`closeInPlace`).
    private(set) var closing = false
    func close(_ on: Bool) { closing = on }
    /// Back: Home's billboard buttons in Details' looks (Play, About) until
    /// its parts come back (`opened` going off, the second phase).
    var homeWearsDetails: Bool { closing && opened }
    /// The last change to it animated.
    @ObservationIgnored private(set) var detailsAnimated = false
    /// The Details pages opened this way (their Back reverses it).
    @ObservationIgnored private var inPlace: Set<String> = []
    @ObservationIgnored private var moves = 0
    /// Controllers following `detailsArriving` (`followsDetailsArriving`).
    @ObservationIgnored private var followers: [(owner: () -> AnyObject?, follow: (Bool) -> Void)] = []

    func followDetailsArriving(_ owner: AnyObject, _ follow: @escaping (Bool) -> Void) {
        followers.append(({ [weak owner] in owner }, follow))
    }

    func unfollowDetailsArriving(_ owner: AnyObject) {
        followers.removeAll { $0.owner().map { $0 === owner } ?? true }
    }

    func move(to on: Bool, animated: Bool = true) {
        guard on != opened else { return }
        guard animated else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { opened = on }
            return
        }
        moves += 1
        let move = moves
        running = true
        withAnimation(Motion.move) { opened = on }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Motion.moveDuration * DetailTransition.length))
            if self.moves == move { self.running = false }
        }
    }

    func moveDetailsParts(out: Bool, animated: Bool = true) {
        guard out != detailsArriving else { return }
        detailsAnimated = animated
        followers.removeAll { $0.owner() == nil }
        followers.forEach { $0.follow(out) }
        guard animated else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { detailsArriving = out }
            return
        }
        withAnimation(Motion.move) { detailsArriving = out }
    }

    /// Opening: Details built unleaned (`animated` false), then leaning in
    /// with its parts. (Back leaves it: Home's picture leans out.)
    func leanDetails(_ on: Bool, animated: Bool = true) {
        guard on != detailsLeaned else { return }
        guard animated else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { detailsLeaned = on }
            return
        }
        withAnimation(Motion.move) { detailsLeaned = on }
    }

    func opened(_ itemID: String) { inPlace.insert(itemID) }
    /// Whether `itemID`'s Details was opened in place (forgotten here).
    func closes(_ itemID: String) -> Bool { inPlace.remove(itemID) != nil }
}

/// Every page's way in and Back (Details' way in is its zoom): one
/// crossfade, no system slide. In: the page below, as a still, fades off
/// the new one once it's drawn; Back: the page fades into that still at
/// once (the press), the live page below rebuilt under it and taking over
/// as soon as it's drawn (`DetailTransition.exitHandOver`).
@MainActor
final class PageFade {
    static let shared = PageFade()
    private var landing = false
    private let root = UIView()
    /// The page below each open page, as it was at the push (key: the route).
    private var stills: [AnyHashable: UIView] = [:]
    private var order: [AnyHashable] = []
    /// Stills kept at most (~8 MB each).
    private static let kept = 8
    private(set) var busy = false
    /// A pushed page still under its still: its content comes in without
    /// a fade of its own (the still's is the one).
    private(set) var covering = false
    /// The longest a page's cover waits for it (then the page as it is).
    private static let coverWait: Duration = .seconds(4)
    /// The cover fading off the page whole (tried: the dissolve's 0.25 s —
    /// abrupt beside the other transitions).
    private static let handOver: Double = 0.5
    private static let coverOpacity: CGFloat = 0.995

    private init() {
        root.isUserInteractionEnabled = false
        root.frame = DetailTransition.screen
    }

    /// The page below `key`'s page (Details keeps its opening's still).
    func keep(_ still: UIView, for key: AnyHashable) {
        stills[key] = still
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.kept { stills[order.removeFirst()] = nil }
    }

    private func take(_ key: AnyHashable?) -> UIView? {
        guard let key else { return nil }
        order.removeAll { $0 == key }
        return stills.removeValue(forKey: key)
    }

    private func install(in window: UIWindow) {
        if root.superview !== window { window.addSubview(root) }
        window.bringSubviewToFront(root)
    }

    private func add(_ view: UIView) {
        view.frame = root.bounds
        view.isUserInteractionEnabled = false
        view.layer.mask = nil
        view.layer.removeAllAnimations()
        view.layer.opacity = 1
        root.addSubview(view)
    }

    /// In: at the press the new page's background (`background`) fades
    /// in over this page — something moves at once, run by Core Animation while the page is pushed and built
    /// under it; once the page is in (`PagePreparer`: ready, or after its
    /// wait) and drawn, the cover fades off it. The tabs' dissolve both ways
    /// (`backTime`). Without a background: the still of this page fades
    /// off the new one. (Tried: the still fading off once the page was in
    /// — nothing moved for ~0.6 s; pushed only after the data's wait —
    /// ~0.8 s; 0.6 s, after two on-time frames.)
    func push(key: AnyHashable, background: AnyView? = nil, _ push: @escaping () -> Void) {
        // The page below still moving: it lands first (its still is Back's).
        guard !landing else { return }
        // (Taken now: it's handed over only during the press's call.)
        let opening = PagePreparer.shared.takeOpening()
        if FixedFocusRowsController.moving {
            landing = true
            FixedFocusRowsController.land {
                self.landing = false
                self.push(key: key, background: background, opening: opening, push)
            }
            return
        }
        self.push(key: key, background: background, opening: opening, push)
    }

    private func push(key: AnyHashable, background: AnyView?,
                      opening: (page: PreparedPage, deadline: ContinuousClock.Instant)?,
                      _ push: @escaping () -> Void) {
        let instant: () -> Void = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { push() }
        }
        guard !busy, !DetailTransition.shared.busy, let window = Self.window,
              let still = window.snapshotView(afterScreenUpdates: false) else { instant(); return }
        busy = true
        covering = true
        let k = DetailTransition.length
        let fade = DetailTransition.backTime * k
        install(in: window)
        add(still)
        var cover: UIView = still
        if let background {
            let host = UIHostingController(rootView: background)
            host.view.backgroundColor = .clear
            host.view.frame = root.bounds
            // Faded in a plain view: the hosting view's own opacity
            // darkened the whole screen mid-fade (~25 % at half way — a
            // dip over two identical backgrounds).
            let box = UIView(frame: root.bounds)
            box.isUserInteractionEnabled = false
            box.addSubview(host.view)
            root.addSubview(box)
            host.view.layoutIfNeeded()
            // Never quite opaque: the page under it is drawn meanwhile
            // (wholly covered, it was first drawn as the cover went —
            // the fade's first 0.15 s skipped).
            DetailTransition.animate(box.layer, "opacity", from: 0, to: Self.coverOpacity, fade, DetailTransition.inOut)
            cover = box
        }
        CATransaction.flush()
        let start = ContinuousClock.now
        instant()
        Task { @MainActor in
            if let opening {
                // The background stays until the page is whole: one hand-over
                // (its placeholders showing after it, then its content,
                // flickered; the header first, the titles later, came apart).
                let deadline = cover === still ? opening.deadline : start + Self.coverWait
                while !opening.page.isReady, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            // The content's update drawn (a frame for it, one more drawn).
            let watch = FrameWatch()
            await watch.quiet(frames: opening == nil ? 1 : 2, within: DetailTransition.exitWait)
            watch.end()
            // The background all in first.
            if cover !== still {
                let left = start + .seconds(fade) - ContinuousClock.now
                if left > .zero { try? await Task.sleep(for: left) }
                still.removeFromSuperview()
            }
            // Background into the page: slower, the page settling in.
            let off = cover === still ? fade : Self.handOver * k
            CATransaction.begin()
            DetailTransition.animate(cover.layer, "opacity", from: CGFloat(cover.layer.opacity), to: 0, off, DetailTransition.inOut)
            CATransaction.commit()
            // On screen before the page's own update (its focus going in):
            // committed after it, the fade's first frames were skipped.
            CATransaction.flush()
            covering = false
            try? await Task.sleep(for: .seconds(off))
            cover.removeFromSuperview()
            still.removeFromSuperview()
            keep(still, for: key)
            root.removeFromSuperview()
            busy = false
        }
    }

    /// Back: this page fades into the still of the one below at once; the
    /// live page, rebuilt under both, takes over once it's drawn. Without
    /// a still, the fade waits for the page to be drawn.
    func back(key: AnyHashable?, _ pop: @escaping () -> Void) {
        let instant: () -> Void = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pop() }
        }
        guard !busy, let window = Self.window else { instant(); return }
        busy = true
        let k = DetailTransition.length
        let watch = FrameWatch()
        watch.begin("back")
        let shot = window.rootViewController?.view.snapshotView(afterScreenUpdates: false)
        let below = take(key)
        install(in: window)
        if let below { add(below) }
        if let shot {
            add(shot)
            CATransaction.begin()
            DetailTransition.animate(shot.layer, "opacity", from: 1, to: 0,
                                     DetailTransition.backTime * k, DetailTransition.inOut,
                                     delay: below == nil ? DetailTransition.exitWait * k : 0)
            CATransaction.commit()
            CATransaction.flush()
        }
        instant()
        Task { @MainActor in
            let end = CACurrentMediaTime()
                + (DetailTransition.backTime + (below == nil ? DetailTransition.exitWait : 0)) * k
            // The live page drawn (a frame or two after the pop): the still
            // fades off it — swapped at the end, the two differed (the
            // pressed button, a picture's drift) and it flickered…
            await watch.quiet(frames: 2, within: DetailTransition.exitWait)
            if let below {
                CATransaction.begin()
                DetailTransition.animate(below.layer, "opacity", from: 1, to: 0,
                                         DetailTransition.exitHandOver * k, DetailTransition.inOut)
                CATransaction.commit()
            }
            // …and the page's fade done.
            let left = end - CACurrentMediaTime()
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            watch.end()
            shot?.removeFromSuperview()
            below?.removeFromSuperview()
            root.removeFromSuperview()
            busy = false
        }
    }

    /// A still no longer needed.
    func drop(_ key: AnyHashable) { _ = take(key) }

    /// `key`'s page now right above `from`'s page's below (the trail moved
    /// on): it takes that still — nil, none.
    func reroot(_ key: AnyHashable, from: AnyHashable?) {
        let still = take(from)
        _ = take(key)
        if let still { keep(still, for: key) }
    }

    /// A layer's Back: a still of the screen over it, `close` (the layer
    /// gone, the page under it shown — it never left the window), the still
    /// fading off it as soon as the close is committed (`backTime`; set
    /// off with the close, the page under it came a frame late — a dip;
    /// waiting for an on-time frame cost up to 0.1 s more).
    func fadeOff(_ close: @escaping () -> Void, gone: @escaping () -> Void) {
        guard !busy, let window = Self.window,
              let shot = window.rootViewController?.view.snapshotView(afterScreenUpdates: false)
        else { close(); gone(); return }
        busy = true
        let k = DetailTransition.length
        install(in: window)
        add(shot)
        CATransaction.flush()
        close()
        // The next turn of the run loop: the close committed (drawn on the
        // next frame), the fade starting a frame after it.
        Task { @MainActor in
            CATransaction.begin()
            DetailTransition.animate(shot.layer, "opacity", from: 1, to: 0,
                                     DetailTransition.backTime * k, DetailTransition.inOut)
            CATransaction.commit()
            try? await Task.sleep(for: .seconds(DetailTransition.backTime * k))
            shot.removeFromSuperview()
            root.removeFromSuperview()
            busy = false
            gone()
        }
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }
}

/// Back off a pushed page (`PageFade.back`, set for each route by the
/// navigation; nil at a tab's root).
private struct PageBackKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var pageBack: (() -> Void)? {
        get { self[PageBackKey.self] }
        set { self[PageBackKey.self] = newValue }
    }
}

/// Over everything (on the window, above the app): the page's dimming,
/// Details' picture exactly where Details draws it (without its shade), a
/// ring for a long wait.
@MainActor
final class DetailTransitionOverlay {
    let root = UIView()
    let dim = CALayer()
    /// The screen, clipped: the cover picture's frame — it fades.
    let pictureFrame = UIView()
    let picture = UIImageView()
    /// The billboard's trailer, going on over the picture (`open(trailer:)`).
    let video = TrailerSurface()
    /// Details' shade over the picture (the cover is Details without its
    /// text — the reveal only adds things).
    let shade = UIImageView()
    private let spinner = LoadingSymbol(size: 64)

    init() {
        root.isUserInteractionEnabled = false
        root.frame = DetailTransition.screen
        dim.backgroundColor = UIColor.black.cgColor
        dim.frame = root.bounds
        dim.opacity = 0
        root.layer.addSublayer(dim)
        pictureFrame.frame = root.bounds
        pictureFrame.clipsToBounds = true
        pictureFrame.backgroundColor = .black
        pictureFrame.layer.opacity = 0
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        pictureFrame.addSubview(picture)
        pictureFrame.addSubview(video)
        shade.contentMode = .scaleToFill
        shade.frame = root.bounds
        pictureFrame.addSubview(shade)
        placeOpen()
        root.addSubview(pictureFrame)
        spinner.center = CGPoint(x: 960, y: 540)
        root.addSubview(spinner)
    }

    /// The screen as it was at the press (dimmed; Details is built under it).
    private var page: UIView?

    func install(in window: UIWindow, page snapshot: UIView? = nil) {
        if root.superview !== window { window.addSubview(root) }
        window.bringSubviewToFront(root)
        if let snapshot {
            page?.removeFromSuperview()
            snapshot.frame = root.bounds
            snapshot.isUserInteractionEnabled = false
            root.insertSubview(snapshot, at: 0)
            page = snapshot
        }
    }

    func dropPage() {
        page?.layer.mask = nil
        page?.removeFromSuperview()
        page = nil
    }

    /// Without a picture: the page fades into Details.
    func fadePage(_ duration: Double) {
        guard let page else { return }
        DetailTransition.animate(page.layer, "opacity", from: 1, to: 0, duration, DetailTransition.inOut)
    }

    func ring(_ on: Bool) { on ? spinner.startAnimating() : spinner.stopAnimating() }

    /// The picture at the opening's start, Home's framing (no animation).
    func place(_ opening: DetailTransitionOpening, shade image: UIImage?) {
        shade.image = image
        DetailTransition.place(picture.layer, opening.picture)
        DetailTransition.place(video.layer, DetailTransition.screen)
    }

    /// The picture at Details' framing (no animation). The video always on
    /// the screen, as on Home (`StagePictureView.Page`): a trailer never zooms.
    func placeOpen() {
        DetailTransition.place(picture.layer, DetailTransition.detailsPicture())
        DetailTransition.place(video.layer, DetailTransition.screen)
    }

    /// The zoom in: Home's framing → Details' (the picture only — under a
    /// trailer it doesn't show).
    func open(from opening: DetailTransitionOpening, _ duration: Double, _ curve: CAMediaTimingFunction) {
        DetailTransition.move(picture.layer, from: opening.picture, to: DetailTransition.detailsPicture(), duration, curve)
    }

    /// Back: Details' framing → Home's.
    func close(to opening: DetailTransitionOpening, _ duration: Double, _ curve: CAMediaTimingFunction) {
        DetailTransition.move(picture.layer, from: DetailTransition.detailsPicture(), to: opening.picture, duration, curve)
    }

    func remove() {
        dropPage()
        root.removeFromSuperview()
        dim.removeAllAnimations()
        dim.opacity = 0
        for layer in [pictureFrame.layer, picture.layer, video.layer] { layer.removeAllAnimations() }
        video.player = nil
        video.alpha = 0
        pictureFrame.layer.mask = nil
        pictureFrame.layer.opacity = 0
        placeOpen()
        picture.image = nil
        spinner.stopAnimating()
    }
}

/// Main-thread hitches per phase of a transition (LAN log, "details"): a
/// display link counts frames that came later than one refresh. The moves
/// themselves are Core Animation — this shows what the main thread did
/// meanwhile (and B waits on it: `quiet`).
@MainActor
final class FrameWatch {
    private var link: CADisplayLink?
    private var phase: String?
    private var phaseStart: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0, late = 0
    private var worst: CFTimeInterval = 0
    private var quietRun = 0
    private final class Target: NSObject {
        weak var watch: FrameWatch?
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { watch?.tick(link) } }
    }
    private let target = Target()

    init() {
        target.watch = self
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let refresh = max(link.duration, 1.0 / 120)
        if last > 0 {
            let gap = now - last
            frames += 1
            if gap > refresh * 1.5 { late += 1; quietRun = 0 } else { quietRun += 1 }
            worst = max(worst, gap)
        }
        last = now
    }

    func begin(_ name: String) {
        report()
        phase = name
        phaseStart = CACurrentMediaTime()
        frames = 0; late = 0; worst = 0
    }

    /// Until `frames` frames in a row came on time (or `within` passed).
    func quiet(frames count: Int, within: Double) async {
        quietRun = 0
        let deadline = CACurrentMediaTime() + within
        while quietRun < count, CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    func end() {
        report()
        link?.invalidate()
        link = nil
    }

    private func report() {
        guard let phase else { return }
        PlayerProbe.event("details", String(format: "frames %@: %.0f ms · %d frames · %d late · worst %.0f ms",
                                            phase, (CACurrentMediaTime() - phaseStart) * 1000, frames, late, worst * 1000))
    }
}

/// How many Details pages are up (opened through `DetailTransition`). Its
/// own object: it changes only at a push / pop, not with the animation.
@MainActor
final class DetailsOpen: ObservableObject {
    static let shared = DetailsOpen()
    @Published var depth = 0
}
