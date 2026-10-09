import SwiftUI
import UIKit

/// THE STAGE PICTURE, in UIKit — the billboard's backdrop as a physical
/// sheet: the picture (drifting on a change of title, as the box does) with
/// the billboard's shade over it, both fading out at the bottom into the
/// background's colours (Render Lab → Billboard bottom fade). Scrolling
/// away it melts into the colours — which shift to the next title's through
/// the scroll — instead of ending in a line.
///
/// (Earlier: a mirrored, blurred copy of the picture's bottom below the
/// screen. The left fade's near-black carried into it, and that made the
/// line it was meant to hide.)
///
/// Home: part of the Featured row (`FixedFocusRowCell`), so it moves with
/// exactly the rows' animation.
final class StagePictureView: UIView {
    static let pictureSize = CGSize(width: 1920, height: 1080)
    /// How far the picture drifts on a change (the box's 30 pt).
    static let drift: CGFloat = 30
    /// The picture's drift with Depth + cascade (the text's: 44).
    static let depthDrift: CGFloat = 12
    /// Billboard change → Scroll: the dark gap between two pages, and the
    /// time a page takes to cross (longer than a move: it's the screen).
    static let scrollGap: CGFloat = 40
    static let scrollTime: Double = 0.55
    /// Render Lab → Billboard: slow zoom — to this, over this long.
    static let slowZoom: CGFloat = 1.04
    static let slowZoomTime: Double = 9

    /// The picture and its shade, faded out at the bottom.
    private let sheet = UIView()
    private let fade = CAGradientLayer()
    private let clip = UIView()
    /// Holds the pictures: the step-in zoom (the Details swap) scales it.
    private let zoom = UIView()
    private var page = UIImageView()
    private let shade = UIImageView()
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
        Self.style(page)
        zoom.addSubview(page)
        Self.style(blurred)
        blurred.alpha = 0
        zoom.addSubview(blurred)
        sheet.addSubview(shade)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        sheet.addSubview(dim)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        sheet.layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func style(_ view: UIImageView) {
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
        if !StageArt.adapts || shade.image == nil { shade.image = StageArt.shade }
        shade.frame = picture
        dim.frame = picture
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = picture
        let height = CGFloat(RenderProbe.shared.flags.billboardBottomFade)
        let start = NSNumber(value: Double(max(picture.height - height, 0) / picture.height))
        fade.locations = [0, start, 1]
        CATransaction.commit()
    }

    /// `direction`: +1 paging right (the new one comes from the right).
    func show(_ url: String?, direction: CGFloat, animated: Bool) {
        guard url != shownURL else { return }
        shownURL = url
        applyTint(for: url, animated: animated)
        if blursBelow { loadBlurred(url) }
        setNeedsLayout()
        guard animated, RenderProbe.shared.flags.boxDrift else {
            if animated {
                UIView.transition(with: page, duration: Motion.durations.fade,
                                  options: [.transitionCrossDissolve, .allowUserInteraction],
                                  animations: { self.load(url, into: self.page) })
            } else {
                load(url, into: page)
            }
            breathe(page)
            return
        }
        // DRIFT (Home's box): the new picture fades in shifting a little the
        // way you went, the old one fades out shifting on. (Render Lab →
        // Billboard change → Depth + cascade: less — the picture is far.)
        // (Billboard change → Scroll: a real page scroll — the whole width
        // and a gap, no fade: the old page slides out as the new slides in.)
        let change = RenderProbe.shared.flags.billboardChange
        let scrolls = change == "scroll"
        let dx = direction * (scrolls ? pageFrame.width + Self.scrollGap
            : change == "depthCascade" ? Self.depthDrift : Self.drift)
        let incoming = UIImageView(frame: pageFrame.offsetBy(dx: dx, dy: 0))
        Self.style(incoming)
        load(url, into: incoming)
        breathe(incoming)
        incoming.alpha = scrolls ? 1 : 0
        zoom.addSubview(incoming)
        let outgoing = page
        page = incoming
        let target = pageFrame
        FixedFocusMotion.run(vertical: false, duration: scrolls ? Self.scrollTime : Motion.durations.move,
                             damping: 1) {
            incoming.frame = target
            incoming.alpha = 1
            outgoing.frame = target.offsetBy(dx: -dx, dy: 0)
            outgoing.alpha = scrolls ? 1 : 0
        } completion: { _ in
            if outgoing !== self.page { outgoing.removeFromSuperview() }
        }
    }

    /// Billboard change → Scroll, with the text (the rows' controller runs
    /// it — `FixedFocusRowsController.scrollBillboard`): the next picture put
    /// a page over, and what moves both pages, to run in the SAME animation
    /// as the text. (`show` would run its own.)
    func prepareScroll(_ url: String?, direction: CGFloat) -> (distance: CGFloat, moves: () -> Void,
                                                                 done: () -> Void)? {
        guard url != shownURL else { return nil }
        shownURL = url
        applyTint(for: url, animated: true)
        if blursBelow { loadBlurred(url) }
        let dx = direction * (pageFrame.width + Self.scrollGap)
        let incoming = UIImageView(frame: pageFrame.offsetBy(dx: dx, dy: 0))
        Self.style(incoming)
        load(url, into: incoming)
        zoom.addSubview(incoming)
        let outgoing = page
        // (The old one's slow zoom stopped where it is: it slides out still.)
        freezeBreathe(outgoing)
        page = incoming
        let target = pageFrame
        return (dx, {
            incoming.frame = target
            outgoing.frame = target.offsetBy(dx: -dx, dy: 0)
        }, {
            if outgoing !== self.page { outgoing.removeFromSuperview() }
            // The slow zoom only once the page has landed — zooming while it
            // moves, the picture swam under the text.
            if incoming === self.page { self.breathe(incoming) }
        })
    }

    /// Render Lab → Billboard: slow zoom — the picture zooms in very slowly
    /// while it shows (from the start of each title). A layer animation
    /// only: the view's own transform and frame stay as they are (the drift
    /// moves the frame at the same time).
    /// The slow zoom held where it is now (a page leaving).
    private func freezeBreathe(_ view: UIImageView) {
        guard view.layer.animation(forKey: "breathe") != nil,
              let scale = view.layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat else { return }
        view.layer.removeAnimation(forKey: "breathe")
        let hold = CABasicAnimation(keyPath: "transform.scale")
        hold.fromValue = scale
        hold.toValue = scale
        hold.duration = 60
        hold.fillMode = .forwards
        hold.isRemovedOnCompletion = false
        view.layer.add(hold, forKey: "breathe")
    }

    /// The billboard picture slowly zooming now (`DetailTransition` starts
    /// Details' picture at its exact size).
    static weak var breathing: UIImageView?
    static var shownScale: CGFloat {
        (breathing?.layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
    }

    private func breathe(_ view: UIImageView) {
        view.layer.removeAnimation(forKey: "breathe")
        Self.breathing = view
        guard RenderProbe.shared.flags.billboardSlowZoom else { return }
        let zoom = CABasicAnimation(keyPath: "transform.scale")
        zoom.fromValue = 1
        zoom.toValue = Self.slowZoom
        zoom.duration = Self.slowZoomTime
        zoom.timingFunction = CAMediaTimingFunction(name: .easeOut)
        zoom.fillMode = .forwards
        zoom.isRemovedOnCompletion = false
        view.layer.add(zoom, forKey: "breathe")
    }

    /// Below the billboard (pinned): blurred and darker — set inside the
    /// rows' move, it rides it. The shade lightens as the blur and dim take
    /// over (Render Lab → Left fade: Episodes).
    func setBelow(_ below: Bool) {
        let flags = RenderProbe.shared.flags
        blurred.alpha = below ? 1 : 0
        // The brightness cap replaces the dim (both: near black).
        dim.alpha = below && flags.detailsBlurCap == 0 ? CGFloat(flags.detailsPictureDim) : 0
        shade.alpha = below ? CGFloat(flags.episodesLeftFade) : 1
    }

    private func loadBlurred(_ url: String?) {
        guard url != blurredFor else { return }
        blurredFor = url
        let strength = RenderProbe.shared.flags.detailsPictureBlur
        Task { @MainActor [weak self] in
            let image = await BlurredBackdrop.image(for: url, strength: strength)
            guard let self, self.blurredFor == url else { return }
            self.blurred.image = image
        }
    }

    /// The shade in the title's colour (tinted scrims): crossfades in once
    /// the colour is known.
    private func applyTint(for url: String?, animated: Bool) {
        guard StageArt.adapts, let url else { return }
        Task { @MainActor [weak self] in
            guard let image = await StageArt.shade(for: url), let self, self.shownURL == url else { return }
            UIView.transition(with: self.shade, duration: animated ? Motion.durations.move : 0,
                              options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.shade.image = image
            }
        }
    }

    private func load(_ url: String?, into view: UIImageView) {
        FixedFocusImages.load(url, into: view, maxDimension: Self.pictureSize.width)
    }
}

/// The billboard's shade (the SwiftUI `BillboardShade`: its left fade,
/// vignette, top) as a still image, made once — and again when its Render
/// Lab settings change.
@MainActor
enum StageArt {
    private static var shadeKey = ""
    private static var shadeImage: UIImage?

    static var shade: UIImage? {
        let flags = RenderProbe.shared.flags
        let key = "\(flags.billboardScrim)|\(flags.billboardVignette)|\(flags.noScrim)"
        if key != shadeKey || shadeImage == nil {
            let renderer = ImageRenderer(content: BillboardShade()
                .frame(width: StagePictureView.pictureSize.width,
                       height: StagePictureView.pictureSize.height))
            renderer.scale = 1
            shadeImage = renderer.uiImage
            shadeKey = key
        }
        return shadeImage
    }

    /// The shade in a title's own colour (the tinted scrims), made once per
    /// colour (a few dozen at most) — at the screen's half size, stretched:
    /// it's all soft gradients.
    private static var tinted: [String: UIImage] = [:]
    static var usesTint: Bool {
        (FixedFocusBillboardScrim(rawValue: RenderProbe.shared.flags.billboardScrim) ?? .leftFade).tinted
    }
    /// The scrim's strength for a picture whose text area has this
    /// luminance: 1 at a middling picture (as designed), down to 0.7 on a
    /// dark one, up to 1.5 on a bright one (steps of 0.1: few images made).
    static func boost(ground: Double?) -> Double {
        guard let ground else { return 1 }
        let raw = min(max(0.65 + 1.25 * ground, 0.7), 1.5)
        return (raw * 10).rounded() / 10
    }

    private static var style: FixedFocusBillboardScrim {
        FixedFocusBillboardScrim(rawValue: RenderProbe.shared.flags.billboardScrim) ?? .leftFade
    }
    static var adapts: Bool { style.adaptive }

    /// THE shade for a picture — the billboard's, Details' and the
    /// transition's alike (they must be identical): the plain one, or —
    /// adaptive scrims — in the title's deep colour and as strong as its
    /// text area needs. nil: not yet known (the colour not found).
    static func shade(for url: String?) async -> UIImage? {
        guard adapts, let url else { return shade }
        let key = "\(url)|\(RenderProbe.shared.flags.billboardScrim)|\(RenderProbe.shared.flags.billboardVignette)"
        if let hit = forPicture[key] { return hit }
        let flags = RenderProbe.shared.flags
        let colors = usesTint ? await FixedFocusTint.colors(for: url, flags: flags) : nil
        guard colors != nil || !usesTint else { return nil }
        let ground = await SpotlightTint.textGround(for: url)
        let image = shade(tint: colors.map { UIColor($0.deep) }, boost: boost(ground: ground))
        if forPicture.count > 120 { forPicture.removeAll() }
        forPicture[key] = image
        return image
    }
    /// …already made (no wait).
    static func knownShade(for url: String?) -> UIImage? {
        guard adapts, let url else { return shade }
        return forPicture["\(url)|\(RenderProbe.shared.flags.billboardScrim)|\(RenderProbe.shared.flags.billboardVignette)"]
    }
    private static var forPicture: [String: UIImage] = [:]
    static func shade(tint: UIColor?, boost: Double = 1) -> UIImage? {
        guard adapts, tint != nil || !usesTint else { return shade }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let flags = RenderProbe.shared.flags
        let key = String(format: "%@|%d|%.2f%.2f%.2f|%.1f", flags.billboardScrim, flags.billboardVignette ? 1 : 0, r, g, b, boost)
        if let hit = tinted[key] { return hit }
        let renderer = ImageRenderer(content: BillboardShade(tint: tint.map { Color(uiColor: $0) }, boost: boost)
            .frame(width: StagePictureView.pictureSize.width / 2,
                   height: StagePictureView.pictureSize.height / 2))
        renderer.scale = 1
        let image = renderer.uiImage
        if tinted.count > 60 { tinted.removeAll() }
        tinted[key] = image
        return image
    }
}
