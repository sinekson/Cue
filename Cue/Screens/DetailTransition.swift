import SwiftUI
import AVFoundation
import Combine

/// THE way into Details, from everywhere (billboard, cards, Search, folders,
/// More Like This). Nothing shown before it's final; every move is Core
/// Animation (played by the render server — the main thread can't make it
/// jump), and nothing heavy runs while something moves. STRICT PHASES:
/// A. Move 1 — the page goes into Details' background (the title's bands,
///    `TitleBands`); the card pressed grows into Details' card, the picture
///    in it crossfading in and settling at Details' framing. Starts once
///    the picture is decoded (usually at the press).
/// B. Still — the card alone on the background while everything else is
///    loaded (`DetailPreparer`) and Details is pushed and built under it,
///    until the main thread has been quiet for a few frames.
/// C. Move 2 — the cover fades off as one over Details, which draws the
///    same card and background: only what's new appears (text, badges,
///    buttons, episodes), nothing moves. Focus is on Play from its first
///    frame. (The cover's parts faded one by one — the page under the card
///    showed through it mid-fade: a flicker.)
/// Back: the mirror. Every phase's main-thread hitches go to the LAN log
/// ("details") — `FrameWatch`.
@MainActor
final class DetailTransition {
    static let shared = DetailTransition()

    // The look — tune here (the real durations; no multiplier).
    /// A: the page going into Details' background (it only dimmed before —
    /// scaled too, it fought the picture's zoom: in, out, in).
    static let pageTime: Double = 0.3
    /// A: the window, from the card pressed into Details' card, the
    /// picture settling at Details' framing.
    static let pictureDelay: Double = 0.05
    static let pictureSettle: Double = 0.55
    /// …the window's picture crossfading in over the card's, quickly: on
    /// the window's quick start a slower fade (0.38 s) left a large
    /// see-through window over the page.
    static let windowFade: Double = 0.15
    /// Settings → Appearance → Opening Details: Fade (`DetailOpening`) — no
    /// morph: Details' card fades in where it lands, with the background,
    /// growing from this size as a whole (as a card's focus), over
    /// `pictureSettle`. Calmer; Grow, the morph, is the default.
    static let crossfadeFrom: CGFloat = 0.95
    static let crossfadeTime: Double = 0.3
    static var crossfades: Bool { DetailOpening.current == .fade }
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
    /// Back from Details, the same from everywhere, nothing moving: one
    /// dissolve into the page below (`detailsBack`), Details' parts — text,
    /// badges, buttons, episodes — on a quicker fade inside it
    /// (`partsBack`), so they're gone before the card and background (its
    /// text crossed the page's mid-fade). (0.25 s for it all was before.)
    static let detailsBack: Double = 0.3
    static let partsBack: Double = 0.18
    /// …into Home's billboard card, the one exception (the same picture
    /// nearly in place: a dissolve read as a jump): Details' card shrinks
    /// into it, eased in and out, the background going round it, the
    /// card fading off over the end (`shrinkFadeFrom`) onto the billboard
    /// card's own text and dots.
    static let shrinkTime: Double = 0.4
    static let shrinkFadeFrom: Double = 0.55
    /// The opening's zoom curve, quick from the start, did most of the
    /// shrink in 0.1 s under the parts' fade: a snap.
    static let shrinkCurve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    static let ringAfter: Double = 1.5
    static let giveUp: Double = 8

    static let inOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let out = CAMediaTimingFunction(name: .easeOut)

    private(set) var busy = false
    private var appeared: String?
    /// The picture each opened page shows (Back brings it over it again).
    private var pictures: [String: String] = [:]
    /// Details pages whose card plays a trailer now.
    private var playing = Set<String>()
    /// Details pages opened from Home's billboard card (Back shrinks into it).
    private var fromBillboard = Set<String>()
    /// Details pages opened from Today's Pick: Back shrinks into it too,
    /// wherever it is then.
    private var fromSpotlight: [String: () -> Window?] = [:]
    func cardPlays(_ itemID: String, _ shown: Bool) {
        if shown { playing.insert(itemID) } else { playing.remove(itemID) }
    }
    private let overlay = DetailTransitionOverlay()

    func pageAppeared(_ id: String) { appeared = id }


    /// The card Details grows out of, on the screen: the window opens from
    /// `card` to Details' card, the picture inside going from where the
    /// card shows it to Details' framing; a trailer from the card's screen
    /// part to the screen. Home's billboard card knows its picture (it's
    /// Details'); any other card: the picture as Details' card frames it,
    /// scaled to cover the card.
    struct Window {
        var card: CGRect
        var picture: CGRect?
        var screen: CGRect
    }

    static var screen: CGRect { CGRect(origin: .zero, size: StagePictureView.pictureSize) }
    /// Details' picture on screen: a little wider than it (the drift),
    /// stepped closer (`ModeSwap.depthScale`).
    static func detailsPicture(scale: CGFloat? = nil) -> CGRect {
        let scale = scale ?? ModeSwap.depthScale(1)
        let size = CGSize(width: (1920 + 2 * StagePictureView.drift) * scale, height: 1080 * scale)
        return CGRect(x: 960 - size.width / 2, y: 540 - size.height / 2, width: size.width, height: size.height)
    }


    /// `keepsPicture`: Details opens with the picture `item` carries (the
    /// billboard's) — else with TMDB's (`TitlePictures`).
    /// `trailer`: one playing (the billboard's, else a card's handed over —
    /// `StageTrailer.carried`) — it plays on over the picture, never
    /// zooming, into Details' (which takes it, `StageTrailer.adopt`).
    /// `from`: a window grown out of a card showing Details' own picture
    /// (Home's billboard card).
    func open(_ item: MetaItem, keepsPicture: Bool = false, trailer: AVPlayer? = nil,
              from grown: Window? = nil, push: @escaping () -> Void) {
        guard !busy, !PageFade.shared.busy, let window = Self.window else { return }
        let trailer = trailer ?? StageTrailer.carried(for: item.id)
        // Details' picture is a card (`StagePictureView.detailsCard`): every
        // way in grows into it, from the card pressed (a trailer playing in
        // it: from where it plays).
        let target = StagePictureView.detailsCard
        // (Not from Home's billboard card: the same picture, nearly the
        // same size and place — a second copy fading in a little off it
        // read as a doubled picture; out of its own card the move is
        // small and as calm.)
        let crossfade = Self.crossfades && grown == nil
        let small = target.insetBy(dx: target.width * (1 - Self.crossfadeFrom) / 2,
                                   dy: target.height * (1 - Self.crossfadeFrom) / 2)
        let card = crossfade ? small
            : grown?.card ?? StageTrailer.carriedFrame(for: item.id) ?? Self.focusedCard(in: window) ?? small
        let carriedFrame = grown == nil && !crossfade ? StageTrailer.carriedFrame(for: item.id) : nil
        CueRows.Memory.shared.opened(item.id)
        if grown != nil { fromBillboard.insert(item.id) }
        if grown == nil, let cell = UIFocusSystem.focusSystem(for: window)?.focusedItem as? FixedFocusShowcaseCell,
           cell.spotlight, cell.item?.id == item.id {
            fromSpotlight[item.id] = { [weak cell] in cell?.backWindow() }
        }
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
            // A. Move 1: the page goes into Details' background at once; the
            // card grows as soon as the picture is decoded. (Not awaited:
            // Details is built meanwhile.)
            watch.begin("move 1")
            var moves: [Task<Void, Never>] = []
            let known = DetailPreparer.shared.peek(item.id)?.picture
            self.overlay.backdrop(TitleBands.shared.cached(known))
            // The page goes with the window's start (going at the press, a
            // picture still loading left the background alone a moment).
            let pageGoes = {
                Self.animate(self.overlay.background.layer, "opacity", from: 0, to: 1, Self.pageTime * k, Self.inOut)
            }
            let url = await DetailPreparer.shared.picture(for: item, within: Self.giveUp)
            let image = url.flatMap(Self.decoded)
            // The bands drawn late (focus didn't rest on the title): faded in
            // over the app's while the card waits — before the reveal, so
            // Details opens on the same.
            if let url, TitleBands.shared.cached(url) == nil {
                Task { @MainActor in
                    if let bands = await TitleBands.shared.image(for: url), self.busy {
                        self.overlay.backdrop(bands, fade: Motion.fadeDuration)
                    }
                }
            } else if let url, known != url {
                self.overlay.backdrop(TitleBands.shared.cached(url), fade: Motion.fadeDuration)
            }
            let wait = Self.pictureDelay * k - (CACurrentMediaTime() - start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            var zoomEnd: CFTimeInterval?
            if let url, let image {
                pictures[item.id] = url
                overlay.picture.image = image
                // Where Details' card shows it, and where the card pressed
                // shows it (Home's billboard card: its own; any other: that
                // framing scaled to cover the card).
                let framed = StagePictureView.cardPicture(in: target, url: url)
                let scale = max(card.width / target.width, card.height / target.height)
                let from = Window(
                    card: card,
                    picture: (crossfade ? nil : grown?.picture) ?? CGRect(x: card.midX + (framed.minX - target.midX) * scale,
                                                      y: card.midY + (framed.minY - target.midY) * scale,
                                                      width: framed.width * scale, height: framed.height * scale),
                    screen: (crossfade ? nil : grown?.screen) ?? carriedFrame
                        ?? (crossfade ? Self.screen.insetBy(dx: Self.screen.width * (1 - Self.crossfadeFrom) / 2,
                                                            dy: Self.screen.height * (1 - Self.crossfadeFrom) / 2) : card))
                zoomEnd = CACurrentMediaTime() + Self.pictureSettle * k
                moves.append(Task {
                    await Self.run {
                        // The window from the card into Details', the
                        // picture crossfading in over the card's.
                        self.overlay.window(from, into: target, picture: framed, player: trailer,
                                            Self.pictureSettle * k, Self.zoomInCurve)
                        Self.animate(self.overlay.pictureFrame.layer, "opacity", from: 0, to: 1,
                                     (crossfade ? Self.crossfadeTime : Self.windowFade) * k,
                                     crossfade ? Self.inOut : Self.out)
                        pageGoes()
                    }
                })
            } else {
                moves.append(Task { await Self.run(pageGoes) })
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
            appeared = nil
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
            ring.cancel()
            overlay.ring(false)
            // (Dev: `-detailsHold` keeps the cover up a while — to compare it
            // with Details on screenshots.)
            if ProcessInfo.processInfo.arguments.contains("-detailsHold") {
                try? await Task.sleep(for: .seconds(3))
            }
            // C. Hand-over: the cover off as one (Details under it draws the
            // same card on the same background — only its parts appear).
            watch.begin("move 2")
            DetailOpenProbe.note("reveal")
            Self.refocus()
            await Self.run {
                Self.animate(self.overlay.root.layer, "opacity", from: 1, to: 0, Self.reveal * k, Self.inOut)
            }
            watch.end()
            overlay.remove()
            busy = false
        }
    }

    /// 1 — or 4 with the dev slow motion.
    static var length: Double { slowMotion ? 4 : 1 }
    /// Dev: `-transitionSlowMo` — every move 4× longer (to watch / screenshot).
    static let slowMotion = ProcessInfo.processInfo.arguments.contains("-transitionSlowMo")

    /// Back from Details: Details dissolves into the page below — one
    /// crossfade, from the press, its parts quicker (`detailsBack`).
    func close(itemID: String?, pop: @escaping () -> Void) {
        guard !busy else { pop(); return }
        // THE EXIT (from anywhere, the billboard too): every page's Back
        // (`PageFade`), into the still of the page below at the opening.
        // (No picture brought back into its card.)
        let card = cardCover(itemID)
        forget(itemID)
        PageFade.shared.back(key: itemID, under: card, time: Self.detailsBack, pop)
        DetailsOpen.shared.depth = max(0, DetailsOpen.shared.depth - 1)
    }

    /// Back from Details as a layer: it fades off the live page under it
    /// (`backTime`); `close` shows the page under it, `gone` removes the
    /// layer once the fade is over.
    func closeLayer(itemID: String, close: @escaping () -> Void, gone: @escaping () -> Void) {
        guard !busy else { close(); gone(); return }
        let card = cardCover(itemID)
        // Opened from Home's billboard card, the card still on its title
        // (it never pages while Details is up): back into it.
        var shrink: (() -> Void)?
        if let card, fromBillboard.contains(itemID), let home = StagePictureView.homeCardShown,
           home.shownItemID == itemID, let into = home.openingWindow() {
            shrink = { Self.shrink(card, into: into) }
        } else if let card, let into = fromSpotlight[itemID]?() {
            shrink = { Self.shrink(card, into: into) }
        }
        forget(itemID)
        PageFade.shared.drop(itemID)
        PageFade.shared.fadeOff(under: card, time: shrink == nil ? Self.detailsBack : Self.shrinkTime,
                                underMove: shrink, close, gone: gone)
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
        pictures[itemID] = nil
        playing.remove(itemID)
        fromBillboard.remove(itemID)
        fromSpotlight[itemID] = nil
    }

    /// Back into Home's billboard card: `cover` (`cardCover`: Details'
    /// card on its background) — the card into `into`'s card, its picture
    /// from Details' framing to the card's, the shade with it (the same
    /// fade, scaled as the card); the background going round it; the card
    /// fading off over the end onto the billboard card under it.
    private static func shrink(_ cover: UIView, into: Window) {
        guard cover.subviews.count == 2 else { return }
        let background = cover.subviews[0], card = cover.subviews[1]
        guard card.subviews.count == 2 else { return }
        let picture = card.subviews[0], shade = card.subviews[1]
        let target = StagePictureView.detailsCard
        let k = length
        let time = shrinkTime * k
        animate(background.layer, "opacity", from: 1, to: 0, detailsBack * k, inOut)
        move(card.layer, from: target, to: into.card, time, shrinkCurve)
        if let end = into.picture {
            move(picture.layer, from: picture.frame,
                 to: end.offsetBy(dx: -into.card.minX, dy: -into.card.minY), time, shrinkCurve)
        }
        let sx = into.card.width / target.width, sy = into.card.height / target.height
        let shadeEnd = CGRect(x: -target.minX * sx, y: -target.minY * sy,
                              width: screen.width * sx, height: screen.height * sy)
        move(shade.layer, from: shade.frame, to: shadeEnd, time, shrinkCurve)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: shrinkFadeFrom), 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .linear), inOut]
        fade.duration = time
        set(card.layer, "opacity", 0)
        card.layer.add(fade, forKey: "opacity")
    }

    /// Back: Details without its parts — its card on its background, drawn
    /// as the opening's cover draws them (the same as Details, to the
    /// pixel) — under the still of Details, which fades off it quicker
    /// (`partsBack`): the parts go first. Nil (one plain dissolve) with a
    /// trailer on the card (it would turn into the still) or no picture.
    private func cardCover(_ itemID: String?) -> UIView? {
        guard let itemID, !playing.contains(itemID), let url = pictures[itemID],
              let image = Self.decoded(url) else { return nil }
        let screen = Self.screen
        let target = StagePictureView.detailsCard
        let cover = UIView(frame: screen)
        let background = UIImageView(frame: screen)
        background.contentMode = .scaleToFill
        background.image = TitleBands.shared.cached(url) ?? BackgroundStore.shared.image
        background.backgroundColor = DetailTransitionOverlay.backgroundColour
        cover.addSubview(background)
        let card = UIView(frame: target)
        card.clipsToBounds = true
        card.layer.cornerRadius = Spotlight.cornerRadius
        card.layer.cornerCurve = .continuous
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.frame = StagePictureView.cardPicture(in: target, url: url).offsetBy(dx: -target.minX, dy: -target.minY)
        card.addSubview(picture)
        let shade = UIImageView(image: StageArt.cardShade(target))
        shade.contentMode = .scaleToFill
        shade.frame = screen.offsetBy(dx: -target.minX, dy: -target.minY)
        card.addSubview(shade)
        cover.addSubview(card)
        return cover
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

    /// The card focused at the press, on the screen at its focused size
    /// (its caption not counted) — what the window grows out of.
    private static func focusedCard(in window: UIWindow) -> CGRect? {
        guard let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView else { return nil }
        if let cell = focused as? FixedFocusShowcaseCell { return cell.holdMenu([]).rest ?? cell.screenCard }
        if let cell = focused as? FixedFocusDestinationCell { return cell.holdMenu([]).rest }
        return focused.convert(focused.bounds, to: nil)
    }

    /// Focus onto the page that's now up.
    private static func refocus() {
        if FixedFocusRowsController.focusDetailsButtons() { return }
        window?.rootViewController?.setNeedsFocusUpdate()
        window?.rootViewController?.updateFocusIfNeeded()
    }
}


/// Settings → Appearance → Opening Details: the card pressed growing into
/// Details' card (Grow, the default), or Details' card fading in where it
/// lands (Fade — `DetailTransition.crossfades`).
enum DetailOpening: String, CaseIterable {
    case grow, fade

    static let key = "cue.appearance.detailOpening"
    static var current: Self { UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .grow }

    var label: String { self == .grow ? "Grow" : "Fade" }
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
    /// `under`: a view between the two (Details' card on its background,
    /// `DetailTransition.cardCover`) fading over `time`, the page's still
    /// quicker (`DetailTransition.partsBack`).
    func back(key: AnyHashable?, under: UIView? = nil, time: Double = DetailTransition.backTime,
              _ pop: @escaping () -> Void) {
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
        let delay = below == nil ? DetailTransition.exitWait * k : 0
        if let under { add(under) }
        if let shot {
            add(shot)
            CATransaction.begin()
            DetailTransition.animate(shot.layer, "opacity", from: 1, to: 0,
                                     (under == nil ? time : DetailTransition.partsBack) * k, DetailTransition.inOut,
                                     delay: delay)
            if let under {
                DetailTransition.animate(under.layer, "opacity", from: 1, to: 0, time * k, DetailTransition.inOut,
                                         delay: delay)
            }
            CATransaction.commit()
            CATransaction.flush()
        }
        instant()
        Task { @MainActor in
            let end = CACurrentMediaTime()
                + (time + (below == nil ? DetailTransition.exitWait : 0)) * k
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
            under?.removeFromSuperview()
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
    /// `under`, `time`: as `back`'s; `underMove`: `under`'s own animation
    /// in place of its fade (Back into Home's billboard card).
    func fadeOff(under: UIView? = nil, time: Double = DetailTransition.backTime,
                 underMove: (() -> Void)? = nil,
                 _ close: @escaping () -> Void, gone: @escaping () -> Void) {
        guard !busy, let window = Self.window,
              let shot = window.rootViewController?.view.snapshotView(afterScreenUpdates: false)
        else { close(); gone(); return }
        busy = true
        let k = DetailTransition.length
        install(in: window)
        if let under { add(under) }
        add(shot)
        CATransaction.flush()
        close()
        // The next turn of the run loop: the close committed (drawn on the
        // next frame), the fade starting a frame after it.
        Task { @MainActor in
            CATransaction.begin()
            DetailTransition.animate(shot.layer, "opacity", from: 1, to: 0,
                                     (under == nil ? time : DetailTransition.partsBack) * k, DetailTransition.inOut)
            if let underMove {
                underMove()
            } else if let under {
                DetailTransition.animate(under.layer, "opacity", from: 1, to: 0, time * k, DetailTransition.inOut)
            }
            CATransaction.commit()
            try? await Task.sleep(for: .seconds(time * k))
            under?.removeFromSuperview()
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

/// Over everything (on the window, above the app): Details' background
/// over the page, Details' card with its picture and shade exactly as
/// Details draws them, a ring for a long wait.
@MainActor
final class DetailTransitionOverlay {
    let root = UIView()
    /// Details' background (`TitleBands`, else the app's), over the page.
    let background = UIImageView()
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
        background.frame = root.bounds
        background.contentMode = .scaleToFill
        background.layer.opacity = 0
        root.addSubview(background)
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

    /// Under the background picture, as `ATVBackground`'s.
    static var backgroundColour: UIColor? {
        BackgroundPicks.Mode.now == .light ? UIColor(white: 0.68, alpha: 1) : UIColor(named: "AppBackground")
    }

    /// Details' background: the title's bands, else the app's (as
    /// `TitleBandsBackground` draws it); `fade`: crossfaded in.
    func backdrop(_ bands: UIImage?, fade: Double = 0) {
        let image = bands ?? BackgroundStore.shared.image
        background.backgroundColor = Self.backgroundColour
        guard fade > 0 else { background.image = image; return }
        let swap = CATransition()
        swap.type = .fade
        swap.duration = fade
        background.layer.add(swap, forKey: "swap")
        background.image = image
    }

    func ring(_ on: Bool) { on ? spinner.startAnimating() : spinner.stopAnimating() }

    /// Details' card (`StagePictureView.detailsCard`): what shows of the
    /// cover, at once.
    private func cardMask(_ target: CGRect) {
        let mask = CALayer()
        mask.backgroundColor = UIColor.black.cgColor
        mask.cornerCurve = .continuous
        mask.cornerRadius = Spotlight.cornerRadius
        DetailTransition.place(mask, target)
        pictureFrame.layer.mask = mask
    }

    /// Out of a card (`DetailTransition.Window`): a window from that card
    /// into Details' (`target`), the cards' corners all the way, the
    /// picture in it from the card's framing to Details' (`picture`), and
    /// Details' shade on it from the start, going with the window (it
    /// came in late, over the move: the picture went bright, then dim —
    /// most cards have a fade already); a trailer from the card's screen
    /// part to the screen.
    func window(_ grown: DetailTransition.Window, into target: CGRect, picture framed: CGRect,
                player: AVPlayer?, _ duration: Double, _ curve: CAMediaTimingFunction) {
        pictureFrame.backgroundColor = .clear
        cardMask(target)
        if let mask = pictureFrame.layer.mask {
            DetailTransition.move(mask, from: grown.card, to: target, duration, curve)
        }
        DetailTransition.move(picture.layer, from: grown.picture ?? framed, to: framed, duration, curve)
        // The shade drawn for Details' card over the screen: scaled as the
        // window is, so its fade sits on the card all the way.
        shade.image = StageArt.cardShade(target)
        let sx = grown.card.width / target.width, sy = grown.card.height / target.height
        let screen = DetailTransition.screen
        let shadeStart = CGRect(x: grown.card.minX - target.minX * sx, y: grown.card.minY - target.minY * sy,
                                width: screen.width * sx, height: screen.height * sy)
        DetailTransition.set(shade.layer, "opacity", 1)
        DetailTransition.move(shade.layer, from: shadeStart, to: screen, duration, curve)
        video.player = player
        video.alpha = player == nil ? 0 : 1
        if player != nil {
            DetailTransition.move(video.layer, from: grown.screen, to: DetailTransition.screen, duration, curve)
        }
    }

    /// The picture at Details' framing (no animation). The video always on
    /// the screen, as on Home (`StagePictureView.Page`): a trailer never zooms.
    func placeOpen() {
        DetailTransition.place(picture.layer, DetailTransition.detailsPicture())
        DetailTransition.place(video.layer, DetailTransition.screen)
    }

    func remove() {
        dropPage()
        root.removeFromSuperview()
        root.layer.removeAllAnimations()
        root.layer.opacity = 1
        background.layer.removeAllAnimations()
        background.layer.opacity = 0
        background.image = nil
        for layer in [pictureFrame.layer, picture.layer, video.layer] { layer.removeAllAnimations() }
        video.player = nil
        video.alpha = 0
        for layer in [picture.layer, shade.layer] { layer.removeAllAnimations(); layer.opacity = 1 }
        pictureFrame.backgroundColor = .black
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
