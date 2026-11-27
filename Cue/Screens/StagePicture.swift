import SwiftUI
import UIKit

/// THE STAGE PICTURE, in UIKit — the billboard's backdrop as a physical
/// sheet: the picture with the billboard's shade on it (one piece: a
/// change of title slides the next in over the last, shade and all), a
/// plain bottom edge.
///
/// Home: part of the Featured row (`FixedFocusRowCell`), so it moves with
/// exactly the rows' animation.
final class StagePictureView: UIView {
    static let pictureSize = CGSize(width: 1920, height: 1080)
    /// Below the billboard the picture darkens by this much (its shade is
    /// gone there: no text to keep readable).
    nonisolated static let dimBelow: CGFloat = 0.55
    /// How far past the screen's edges the picture reaches (the room the
    /// old drift on a change needed; the transition's geometry keeps it).
    static let drift: CGFloat = 16
    /// A change of title: the new picture slides in over the old (a
    /// no-bounce spring: fast, then slow); the old one moves this share of
    /// the width — text and shade on it.
    static let slideDuration: Double = 0.7
    static let outgoingShare: CGFloat = 0.5
    /// HOME'S BILLBOARD AS A CARD (trying): the picture in a large card
    /// on the page — the rows' edges, `cardGap` under the top bar and
    /// above the next row's name, the cards' corners. (Full screen, edge
    /// to edge, was before.)
    static let cardGap: CGFloat = 40
    /// The `cardGap` above the next row's name is to the card GROWN (focus
    /// grows it round its middle): its room for the growth reserved, as a
    /// row's grown card's.
    static var homeCard: CGRect {
        let top = GlassSidebar.topBarTop + GlassSidebar.topBarItemHeight + cardGap
        let bottom = FixedFocusRowsLayout.nextNameY - cardGap
        let width = 1920 - 2 * Spotlight.screenInset
        // Its growth's share (by its width, the longer side).
        let growth = FixedFocusMetrics.focusLift(CGSize(width: width, height: 1))
        return CGRect(x: Spotlight.screenInset, y: top,
                      width: width, height: ((bottom - top) / (1 + growth / 2)).rounded())
    }
    /// DETAILS AS THE CARD, OPENED: its picture the same card, larger —
    /// `detailsInset` from the screen's top and sides (the rows' edges was
    /// before) — its foot `cardGap` above the episodes' name, as Home's
    /// card's; the buttons in it, bottom right. No focus of its own, never
    /// grown. (The card smaller, the buttons on the page under it, was
    /// before.)
    static let detailsInset: CGFloat = 24
    static var detailsCard: CGRect {
        let bottom = FixedFocusRowsLayout.nextNameY - cardGap
        return CGRect(x: detailsInset, y: detailsInset, width: 1920 - 2 * detailsInset,
                      height: bottom - detailsInset)
    }
    /// Details' buttons, in its card bottom right where Home's dots are:
    /// their foot on the tagline's line, Play's caption ("S1:E5") under
    /// them in the margin.
    static var detailsButtonsY: CGFloat { detailsCard.maxY - cardMargin - DetailActionButton.height }
    /// Their right end, from the screen's right.
    static var detailsButtonsTrailing: CGFloat { 1920 - detailsCard.maxX + cardMargin }
    /// What's in it this far in from its sides and foot: the text bottom
    /// left, the dots bottom right on its last baseline. No buttons: the
    /// card takes focus (its buttons, as Details', bottom left, then right
    /// over the dots, were before).
    static let cardMargin: CGFloat = 63
    static var dotsY: CGFloat { homeCard.maxY - cardMargin - BillboardDots.dot }
    /// A card's text block, its bottom (the tagline's line) at the margin.
    static func textBottom(_ card: CGRect) -> CGFloat { card.maxY - cardMargin + FixedFocusBillboardText.lineInset }
    /// The text's shift in from the rows' text edge.
    static func textIn(_ card: CGRect) -> CGFloat { card.minX + cardMargin - FixedFocusMetrics.titleInset }

    /// The picture as a card shows it (screen points, the card unscaled):
    /// the page's size, moved up or down for its faces (`Page.band`) — as
    /// far as they're known yet.
    static func cardPicture(in card: CGRect, url: String?) -> CGRect {
        let size = CGSize(width: pictureSize.width + 2 * drift, height: pictureSize.height)
        var picture = CGRect(origin: CGPoint(x: -drift, y: 0), size: size)
        let known = url.flatMap { faces[$0] ?? faces[TMDBService.originalSize($0) ?? $0] }
        if let known, let centre = known {
            picture.origin.y = min(card.minY, max(card.maxY - size.height, card.midY - centre * size.height))
        }
        return picture
    }
    /// Clipped to this (screen points, before the billboard's travel),
    /// nil: the whole picture.
    var cardFrame: CGRect? { didSet { setNeedsLayout() } }
    private let cardMask = UIView()
    /// The card's edge, as every card's (Card Outlines): the rim
    /// (`FixedFocusCardEdge.rim`), and the bright edge while focused
    /// (`cardLit`: Home's card). Inside the card's mask, over everything.
    private let cardRim = UIImageView()
    private let cardOutline = UIView()
    /// Home's card in focus: the bright edge (with Edges and Focus).
    var cardLit = false { didSet { cardOutline.alpha = cardLit ? 1 : 0 } }

    /// One title's picture with its own shade — and, on Home's billboard,
    /// its own text — on it: one card.
    private final class Page: UIView {
        let picture = UIImageView()
        let shade = UIImageView()
        /// Whose picture.
        var itemID: String?
        var url: String?
        /// Home's card: its bottom fade (`StageArt.cardShade`), not the
        /// screen's left one.
        var inCard = false { didSet { if inCard != oldValue { setNeedsLayout() } } }
        /// Home's card, in its points: the picture moved up or down so its
        /// faces sit in the card (`faces`), never uncovering it.
        var band: CGRect? { didSet { if band != oldValue { setNeedsLayout() } } }
        /// Where its faces are, down the picture (0 top, 1 foot; nil: none
        /// found, it stays centred).
        var faces: CGFloat? { didSet { if faces != oldValue { setNeedsLayout() } } }
        /// Copies riding on it (the buttons going out with it).
        var carried: [UIView] = []
        private var textHost: UIHostingController<AnyView>?
        /// Its text (the trailer full screen: out).
        var textView: UIView? { textHost?.view }

        func setText(_ content: AnyView?) {
            guard let content else {
                textHost?.view.removeFromSuperview()
                textHost = nil
                return
            }
            let screen = content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let textHost {
                textHost.rootView = AnyView(screen)
                return
            }
            let host = UIHostingController(rootView: AnyView(screen))
            // On the picture: dark in both appearances (`CueInk`).
            host.overrideUserInterfaceStyle = .dark
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.safeAreaRegions = []
            addSubview(host.view)
            textHost = host
            setNeedsLayout()
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            StagePictureView.style(picture)
            addSubview(picture)
            addSubview(shade)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            // (Its place, not its frame: it may lean in — `lean`.)
            picture.bounds = CGRect(origin: .zero, size: bounds.size)
            picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
            if inCard, let band, let faces {
                let shift = min(band.minY, max(band.maxY - bounds.height, band.midY - faces * bounds.height))
                picture.center.y += shift
            }
            shade.image = band.map { StageArt.cardShade($0.offsetBy(dx: -StagePictureView.drift, dy: 0)) }
                ?? StageArt.shade
            // The whole picture, edge to edge (on the screen's part only,
            // the strip past it showed as a bright line on a sliding edge).
            shade.frame = bounds
            // The trailer on the picture (`attachTrailer`): the screen's part.
            for case let video as TrailerSurface in subviews {
                video.frame = CGRect(x: StagePictureView.drift, y: 0,
                                     width: StagePictureView.pictureSize.width, height: bounds.height)
            }
            // The text in screen points (the screen's part of the picture).
            textHost?.view.frame = CGRect(x: StagePictureView.drift, y: 0,
                                          width: StagePictureView.pictureSize.width, height: bounds.height)
        }
    }

    private let sheet = UIView()
    private let clip = UIView()
    /// Holds the pictures: the step-in zoom (the Details swap) scales it.
    private let zoom = UIView()
    private var page = Page()
    /// The shades' opacity (none below the billboard).
    private var shadeAlpha: CGFloat = 1
    /// Home's billboard: each picture's text, for its title (nil: none).
    var text: ((MetaItem) -> AnyView)?
    private var shownItem: MetaItem?
    /// The card a slide is taking out, while it's moving (a change back to
    /// it reverses the slide).
    private var leaving: Page?
    /// The last change: where the incoming card started, from its place
    /// (the buttons follow it in — `FixedFocusRowsController`).
    private(set) var lastStartOffset: CGFloat = 0
    /// …and, a reverse whose leaving card is in FRONT: its edge toward the
    /// returning card, from / to (screen x), and whether what's on the
    /// returning card shows right of it (else left) — the buttons hide
    /// behind it (they're over everything; they showed in front of it).
    private(set) var lastCover: (from: CGFloat, to: CGFloat, showsRight: Bool)?

    /// A still copy of something on screen (the billboard's buttons) put
    /// on the current card where it shows: it goes out with the card.
    func carry(_ copy: UIView, from source: UIView) {
        copy.frame = source.convert(source.bounds, to: page)
        copy.isUserInteractionEnabled = false
        page.addSubview(copy)
        page.carried.append(copy)
    }

    /// The trailer (`StageTrailer`) onto the current card, over its
    /// picture, under its shade: it goes out with the card.
    func attachTrailer(_ surface: TrailerSurface) {
        guard surface.superview !== page else { return }
        page.insertSubview(surface, aboveSubview: page.picture)
        page.setNeedsLayout()
    }

    /// The current title's text again (its data arriving: a rating, the
    /// tagline).
    func refreshText() {
        page.setText(shownItem.flatMap { text?($0) })
    }
    private var shownURL: String?
    /// PINNED (Home's rigid billboard — see `FixedFocusRows.pinnedBillboardPicture`):
    /// below the billboard the picture stays, its blurred copy over it and
    /// darker, then it gives way to the background's colours.
    var blursBelow = false
    private let blurred = UIImageView()
    private let dim = UIView()
    private var blurredFor: String?

    /// Its picture let go while the player is up (`PictureRelease`): the
    /// billboard card or Details on a tab out of sight.
    private var releasedForPlayer = false
    @objc private func releaseForPlayer() {
        guard PictureRelease.outOfSight(self) else { return }
        releasedForPlayer = true
        FixedFocusImages.load(nil, into: page.picture, maxDimension: 0)
        blurred.image = nil
    }
    @objc private func restoreAfterPlayer() {
        guard releasedForPlayer else { return }
        releasedForPlayer = false
        load(page.url, into: page.picture)
        if blursBelow { blurredFor = nil; loadBlurred(shownURL) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseForPlayer),
                                               name: PictureRelease.release, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreAfterPlayer),
                                               name: PictureRelease.restore, object: nil)
        isUserInteractionEnabled = false
        clipsToBounds = false
        addSubview(sheet)
        clip.clipsToBounds = true
        clip.backgroundColor = .black
        sheet.addSubview(clip)
        clip.addSubview(zoom)
        zoom.addSubview(page)
        Self.style(blurred)
        blurred.alpha = 0
        zoom.addSubview(blurred)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        sheet.addSubview(dim)
        for edge in [cardRim, cardOutline] {
            edge.isUserInteractionEnabled = false
            addSubview(edge)
        }
        cardOutline.layer.cornerRadius = Spotlight.cornerRadius
        cardOutline.layer.cornerCurve = .continuous
        cardOutline.layer.borderColor = FixedFocusRing.color.cgColor
        cardOutline.alpha = 0
        FixedFocusRing.follow(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    fileprivate static func style(_ view: UIImageView) {
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
    }

    /// The picture, a little wider than the screen: drifting, its edges
    /// never come into view.
    private var pageFrame: CGRect {
        CGRect(x: -Self.drift, y: 0, width: Self.pictureSize.width + 2 * Self.drift,
               height: Self.pictureSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let picture = CGRect(origin: .zero, size: Self.pictureSize)
        sheet.frame = picture
        clip.frame = picture
        if zoom.transform == .identity { zoom.frame = picture } else {
            zoom.bounds = CGRect(origin: .zero, size: picture.size)
            zoom.center = CGPoint(x: picture.midX, y: picture.midY)
        }
        if page.layer.animationKeys()?.isEmpty ?? true { page.frame = pageFrame }
        blurred.frame = pageFrame
        dim.frame = picture
        // A card: no black behind the pictures (unmasked, it covered the page).
        clip.backgroundColor = cardFrame != nil ? .clear : .black
        for case let card as Page in zoom.subviews {
            card.inCard = cardFrame != nil
            card.band = cardFrame?.offsetBy(dx: Self.drift, dy: 0)
        }
        if let cardFrame {
            if cardMask.layer.animationKeys()?.isEmpty ?? true {
                cardMask.frame = fullScreen ? CGRect(origin: .zero, size: Self.pictureSize) : cardFrame
                cardMask.layer.cornerRadius = fullScreen ? 0 : Spotlight.cornerRadius
            }
            cardMask.backgroundColor = .black
            cardMask.layer.cornerCurve = .continuous
            if mask !== cardMask { mask = cardMask }
            cardRim.frame = cardFrame
            cardOutline.frame = cardFrame
        } else if mask != nil {
            mask = nil
        }
        cardRim.image = cardFrame == nil ? nil : FixedFocusCardEdge.rim
        cardOutline.layer.borderWidth = cardFrame == nil ? 0 : FixedFocusRing.width
    }

    /// Details' trailer full screen: the card's window opens to the
    /// screen, the trailer staying where it is (it's laid out on the whole
    /// screen; the card only shows part of it), on the opening's grow
    /// (`DetailTransition.pictureSettle`, `zoomInCurve`); back, closing
    /// as Back's shrink (`shrinkTime`, `shrinkCurve`). The text and shade
    /// fade out first and come back at the end.
    private(set) var fullScreen = false
    static let fullPartsFade: Double = 0.25

    func setFullScreen(_ full: Bool) {
        guard full != fullScreen, let cardFrame else { return }
        fullScreen = full
        let screen = CGRect(origin: .zero, size: Self.pictureSize)
        let (from, to) = full ? (cardFrame, screen) : (screen, cardFrame)
        let duration = full ? DetailTransition.pictureSettle : DetailTransition.shrinkTime
        let curve = full ? DetailTransition.zoomInCurve : DetailTransition.shrinkCurve
        let layer = cardMask.layer
        let current = layer.presentation()
        let start = current?.bounds ?? CGRect(origin: .zero, size: from.size)
        let startPosition = current?.position ?? CGPoint(x: from.midX, y: from.midY)
        let startRadius = current?.cornerRadius ?? (full ? Spotlight.cornerRadius : 0)
        cardMask.frame = to
        layer.cornerRadius = full ? 0 : Spotlight.cornerRadius
        let group = CAAnimationGroup()
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = start
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = startPosition
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = startRadius
        group.animations = [bounds, position, radius]
        group.duration = duration
        group.timingFunction = curve
        layer.add(group, forKey: "full")
        // The text and shade: out at the start, back over the end.
        let parts = zoom.subviews.compactMap { $0 as? Page }.flatMap { [$0.shade, $0.textView].compactMap { $0 } }
        UIView.animate(withDuration: Self.fullPartsFade, delay: full ? 0 : duration - Self.fullPartsFade,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            for part in parts { part.alpha = full ? 0 : (part is UIImageView ? self.shadeAlpha : 1) }
            // The edge is the card's: gone while it's the screen.
            self.cardRim.alpha = full ? 0 : 1
        }
    }

    /// Home's billboard card (the rows' pinned stage), for Details' way in.
    static weak var homeCardShown: StagePictureView?
    /// The title on the card now (Back into it: `DetailTransition`).
    var shownItemID: String? { shownItem?.id }

    /// The card on the screen as it's drawn now — Details' opening grows
    /// a window out of it (`DetailTransition.Window`): the card, its
    /// picture (moved for its faces) and the screen's part (a trailer's).
    func openingWindow() -> DetailTransition.Window? {
        guard let cardFrame, window != nil else { return nil }
        let screenPart = CGRect(x: Self.drift, y: 0, width: Self.pictureSize.width, height: page.bounds.height)
        return DetailTransition.Window(card: convert(cardFrame, to: nil),
                                       picture: page.picture.convert(page.picture.bounds, to: nil),
                                       screen: page.convert(screenPart, to: nil))
    }

    /// `direction`: +1 paging right (the new one comes from the right).
    /// `item`: whose picture (its text on it — `text`).
    func show(_ url: String?, item: MetaItem? = nil, direction: CGFloat, animated: Bool) {
        guard url != shownURL || item?.id != shownItem?.id else { return }
        shownURL = url
        shownItem = item
        if blursBelow { loadBlurred(url) }
        setNeedsLayout()
        guard animated else {
            for case let card as Page in zoom.subviews where card !== page { card.removeFromSuperview() }
            leaving = nil
            page.itemID = item?.id
            page.url = url
            page.faces = nil
            load(url, into: page.picture)
            page.setText(item.flatMap { text?($0) })
            return
        }
        // HOME'S CARD: the next title dissolves in over the old in place
        // (0.25 s), the card dipping a little around it (the rows,
        // `dipBillboardCard`). (Tried: the full screen's slide fitted to
        // the card's edge, a deck of cards and a carousel — each glitched
        // on a quick turn back, retargeted or hurried.)
        if cardFrame != nil {
            lastStartOffset = 0
            lastCover = nil
            let incoming = Page(frame: pageFrame)
            incoming.itemID = item?.id
            incoming.url = url
            incoming.shade.alpha = shadeAlpha
            incoming.inCard = true
            load(url, into: incoming.picture)
            incoming.setText(item.flatMap { text?($0) })
            incoming.alpha = 0
            zoom.insertSubview(incoming, belowSubview: blurred)
            leaving = page
            page = incoming
            // Only the last one in, once it's whole, clears what's under
            // it: a press mid-fade put a new one over a half-faded one, and
            // the first one's end pruned the card still showing through it
            // (a flicker).
            UIView.animate(withDuration: Motion.fadeDuration, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction]) {
                incoming.alpha = 1
            } completion: { _ in
                guard self.page === incoming else { return }
                for case let card as Page in self.zoom.subviews where card !== incoming { card.removeFromSuperview() }
                self.leaving = nil
            }
            return
        }
        let width = Self.pictureSize.width
        // All the way off: the card is wider than the screen (its edges
        // past it) — by the screen's width, a strip stayed in view.
        let off = pageFrame.width
        let target = pageFrame
        // BACK to the card still going out: the slide reverses (a new card
        // on top of the moving pair looked wrong) — the one in front goes
        // back where it came from / comes back over the other.
        if let back = leaving, back.superview != nil, back.itemID == item?.id, back.url == url {
            let current = page
            let backInFront = (zoom.subviews.firstIndex(of: back) ?? 0) > (zoom.subviews.firstIndex(of: current) ?? 0)
            // Both from exactly where they are, at rest (as the buttons:
            // blended into the running slide, the cards took another path
            // than the buttons).
            for moving in [back, current] {
                let shown = moving.layer.presentation()?.frame ?? moving.frame
                moving.layer.removeAllAnimations()
                moving.frame = shown
            }
            lastStartOffset = back.frame.minX - target.minX
            let leavingTo = target.offsetBy(dx: -direction * (backInFront ? width * Self.outgoingShare : off), dy: 0)
            // (Going right, the front card leaves to the left: its right edge.)
            lastCover = backInFront ? nil
                : direction > 0 ? (current.frame.maxX, leavingTo.maxX, true)
                : (current.frame.minX, leavingTo.minX, false)
            back.carried.forEach { $0.removeFromSuperview() }
            back.carried = []
            page = back
            leaving = current
            FixedFocusMotion.run(duration: Self.slideDuration) {
                back.frame = target
                current.frame = leavingTo
            } completion: { _ in self.prune() }
            return
        }
        // SLIDE: the new picture comes in over the old one from the side
        // you went, fast then slow; the old one goes only half as far, the
        // same way (it's covered as it goes — no fade).
        lastStartOffset = direction * off
        lastCover = nil
        let incoming = Page(frame: target.offsetBy(dx: direction * off, dy: 0))
        incoming.itemID = item?.id
        incoming.url = url
        incoming.shade.alpha = shadeAlpha
        incoming.inCard = cardFrame != nil
        load(url, into: incoming.picture)
        incoming.setText(item.flatMap { text?($0) })
        zoom.insertSubview(incoming, belowSubview: blurred)
        let outgoing = page
        page = incoming
        leaving = outgoing
        FixedFocusMotion.run(duration: Self.slideDuration) {
            incoming.frame = target
            outgoing.frame = target.offsetBy(dx: -direction * width * Self.outgoingShare, dy: 0)
        } completion: { _ in self.prune() }
    }

    /// Cards no longer shown and at rest go (a slide cut short by the next
    /// press reported "not finished": its card stayed, under the current
    /// one, and showed when a later slide uncovered it). Again once the
    /// last slide has surely ended.
    private func prune() {
        let moving = { (card: Page) in !(card.layer.animationKeys()?.isEmpty ?? true) }
        if let card = leaving, !moving(card) { leaving = nil }
        for case let card as Page in zoom.subviews where card !== page && card !== leaving && !moving(card) {
            card.removeFromSuperview()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration + 0.1) { [weak self] in
            guard let self else { return }
            if let card = self.leaving, !moving(card) { self.leaving = nil }
            for case let card as Page in self.zoom.subviews where card !== self.page && card !== self.leaving && !moving(card) {
                card.removeFromSuperview()
            }
        }
    }

    /// Below the billboard (pinned): blurred and darker — set inside the
    /// rows' move, it rides it. The shade goes as the blur and dim take
    /// over.
    func setBelow(_ below: Bool) {
        blurred.alpha = below ? 1 : 0
        // The brightness cap replaces the dim (both: near black).
        dim.alpha = below ? Self.dimBelow : 0
        shadeAlpha = below ? 0 : 1
        for case let page as Page in zoom.subviews { page.shade.alpha = shadeAlpha }
    }

    private func loadBlurred(_ url: String?) {
        guard url != blurredFor else { return }
        blurredFor = url
        Task { @MainActor [weak self] in
            let image = await BlurredBackdrop.image(for: url)
            guard let self, self.blurredFor == url else { return }
            self.blurred.image = image
        }
    }

    private func load(_ url: String?, into view: UIImageView) {
        FixedFocusImages.load(url, into: view, maxDimension: PictureSize.screen) { [weak view] waiting in
            guard !waiting, let url, let view, let image = view.image?.cgImage else { return }
            Self.findFaces(url, in: image) { faces in
                guard let page = view.superview as? Page, page.url == url else { return }
                page.faces = faces
            }
        }
    }

    /// Home's card: where a picture's faces are, down it (the cards' rule,
    /// `TMDBService.faceCentre`), once per picture, from a small copy.
    fileprivate static var faces: [String: CGFloat?] = [:]

    /// Found ahead, from the picture decoded (focus resting, the opening's
    /// wait): Details frames it as the opening's window did. Found after
    /// the picture was up, Details moved it (on the TV, at the end of the
    /// opening).
    static func prepareFaces(_ url: String) async {
        guard faces[url] == nil,
              let image = ImageCache.shared.image(for: RemoteImage.memoryKey(url, maxDimension: PictureSize.screen,
                                                                             maxPixels: nil))?.cgImage
        else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            findFaces(url, in: image) { _ in done.resume() }
        }
    }
    private static let faceQueue = DispatchQueue(label: "cue.stage-faces", qos: .utility)
    private static func findFaces(_ url: String, in image: CGImage, done: @escaping (CGFloat?) -> Void) {
        if let known = faces[url] { done(known); return }
        faceQueue.async {
            let width = 480, height = max(1, Int(480 * CGFloat(image.height) / CGFloat(max(image.width, 1))))
            var found: CGFloat?
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                found = context.makeImage().flatMap { TMDBService.faceCentre($0, aspect: TMDBService.wideAspect) }
            }
            DispatchQueue.main.async {
                faces[url] = .some(found)
                done(found)
            }
        }
    }
}

/// The shades over a picture, made once: bottom fades, the cards' way
/// (a fade from the left, darkest at the screen's edge, was Details' and
/// the full-screen billboard's: disliked beside the card's).
@MainActor
enum StageArt {
    /// HOME'S CARD's shade: the cards' bottom fade (`FixedFocusShade`'s
    /// curve, starting higher: the billboard's text is taller than a
    /// card's), over the card's height; no left fade. A column of the
    /// screen's height, stretched across.
    static func cardShade(_ card: CGRect) -> UIImage {
        let key = "\(card.minY)-\(card.maxY)"
        if let made = cardShades[key] { return made }
        let made = bottomFade(over: card.minY...card.maxY, stops: cardStops)
        cardShades[key] = made
        return made
    }
    private static var cardShades: [String: UIImage] = [:]
    private static let cardStops: [(at: CGFloat, dark: CGFloat)] = [(0.3, 0), (0.55, 0.3), (0.8, 0.65), (1, 0.85)]

    /// DETAILS' shade (and the transition's): the card's bottom fade
    /// exactly, over the screen.
    static let shade: UIImage = bottomFade(over: 0...StagePictureView.pictureSize.height, stops: cardStops)

    /// Black, darker down `span` (in the screen's points) by `stops`
    /// (share of the span, darkness), eased between them; a column of the
    /// screen's height, stretched across.
    private static func bottomFade(over span: ClosedRange<CGFloat>,
                                   stops: [(at: CGFloat, dark: CGFloat)]) -> UIImage {
        let h = Int(StagePictureView.pictureSize.height)
        func dark(_ share: CGFloat) -> CGFloat {
            guard share > stops[0].at else { return stops[0].dark }
            for (a, b) in zip(stops, stops.dropFirst()) where share <= b.at {
                let t = (share - a.at) / (b.at - a.at)
                let eased = t * t * (3 - 2 * t)
                return a.dark + (b.dark - a.dark) * eased
            }
            return stops[stops.count - 1].dark
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: h),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { context in
            for y in 0..<h {
                let share = (CGFloat(y) + 0.5 - span.lowerBound) / (span.upperBound - span.lowerBound)
                UIColor.black.withAlphaComponent(dark(min(max(share, 0), 1))).setFill()
                context.fill(CGRect(x: 0, y: y, width: 1, height: 1))
            }
        }
    }

    /// DETAILS' DIM below its billboard, by the picture's own brightness:
    /// at least `StagePictureView.dimBelow`, more for a bright picture —
    /// enough to bring its mean brightness down to `brightestBelow` (a
    /// light one, blurred, glared through the usual dim). Measured once
    /// per picture (its mean luma, from the picture in memory). (0.50 never
    /// took: no picture is that bright under the 55 %.)
    nonisolated static let brightestBelow: CGFloat = 0.28
    private static var brightness: [String: CGFloat] = [:]

    static func dimBelow(for url: String?) -> CGFloat {
        guard let mean = mean(url) else { return StagePictureView.dimBelow }
        return dimBelow(mean: mean)
    }

    nonisolated static func dimBelow(mean: CGFloat) -> CGFloat {
        max(StagePictureView.dimBelow, 1 - brightestBelow / mean)
    }

    private static func mean(_ url: String?) -> CGFloat? {
        guard let url else { return nil }
        if let known = brightness[url] { return known }
        let key = RemoteImage.memoryKey(url, maxDimension: PictureSize.screen, maxPixels: nil)
        guard let cg = ImageCache.shared.image(for: key)?.cgImage else { return nil }
        let (w, h) = (32, 18)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sum: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])
        }
        let mean = max(sum / CGFloat(w * h) / 255, 0.01)
        brightness[url] = mean
        return mean
    }
}

/// The billboard's and Details' picture hosts their trailer.
extension StagePictureView: TrailerHost {}
