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
    static let dimBelow: CGFloat = 0.55
    /// How far past the screen's edges the picture reaches (the room the
    /// old drift on a change needed; the transition's geometry keeps it).
    static let drift: CGFloat = 16
    /// A change of title: the new picture slides in over the old (a
    /// no-bounce spring: fast, then slow); the old one moves this share of
    /// the width — text and shade on it.
    static let slideDuration: Double = 0.7
    static let outgoingShare: CGFloat = 0.5

    /// One title's picture with its own shade — and, on Home's billboard,
    /// its own text — on it: one card.
    private final class Page: UIView {
        let picture = UIImageView()
        let shade = UIImageView()
        /// Whose picture.
        var itemID: String?
        var url: String?
        /// Copies riding on it (the buttons going out with it).
        var carried: [UIView] = []
        private var textHost: UIHostingController<AnyView>?
        var textAlpha: CGFloat = 1 { didSet { textHost?.view.alpha = textAlpha } }

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
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.safeAreaRegions = []
            host.view.alpha = textAlpha
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
            picture.frame = bounds
            shade.image = StageArt.shade
            // The whole picture, edge to edge (on the screen's part only,
            // the strip past it showed as a bright line on a sliding edge).
            shade.frame = bounds
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
    /// The text's opacity (dimmed below the billboard, as the rows above).
    var textAlpha: CGFloat = 1 {
        didSet { for case let page as Page in zoom.subviews { page.textAlpha = textAlpha } }
    }

    /// A still copy of something on screen (the billboard's buttons) put
    /// on the current card where it shows: it goes out with the card.
    func carry(_ copy: UIView, from source: UIView) {
        copy.frame = source.convert(source.bounds, to: page)
        copy.isUserInteractionEnabled = false
        page.addSubview(copy)
        page.carried.append(copy)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
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
            load(url, into: page.picture)
            page.setText(item.flatMap { text?($0) })
            page.itemID = item?.id
            page.url = url
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
        incoming.textAlpha = textAlpha
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
        FixedFocusImages.load(url, into: view, maxDimension: Self.pictureSize.width)
    }
}

/// The billboard's shade (the SwiftUI `BillboardShade`: its left fade)
/// as a still image, made once. THE shade: the billboard's, Details' and
/// the transition's alike.
@MainActor
enum StageArt {
    static let shade: UIImage? = {
        let renderer = ImageRenderer(content: BillboardShade()
            .frame(width: StagePictureView.pictureSize.width,
                   height: StagePictureView.pictureSize.height))
        renderer.scale = 1
        return renderer.uiImage
    }()
}
