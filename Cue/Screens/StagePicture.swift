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

    /// The picture and its shade, faded out at the bottom.
    private let sheet = UIView()
    private let fade = CAGradientLayer()
    private let clip = UIView()
    /// Holds the pictures: the step-in zoom (the Details swap) scales it.
    private let zoom = UIView()
    private var page = UIImageView()
    private let shade = UIImageView()
    private var shownURL: String?

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
        sheet.addSubview(shade)
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
        shade.image = StageArt.shade
        shade.frame = picture
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
        setNeedsLayout()
        guard animated, RenderProbe.shared.flags.boxDrift else {
            if animated {
                UIView.transition(with: page, duration: Motion.durations.fade,
                                  options: [.transitionCrossDissolve, .allowUserInteraction],
                                  animations: { self.load(url, into: self.page) })
            } else {
                load(url, into: page)
            }
            return
        }
        // DRIFT (Home's box): the new picture fades in shifting a little the
        // way you went, the old one fades out shifting on.
        let dx = direction * Self.drift
        let incoming = UIImageView(frame: pageFrame.offsetBy(dx: dx, dy: 0))
        Self.style(incoming)
        load(url, into: incoming)
        incoming.alpha = 0
        zoom.addSubview(incoming)
        let outgoing = page
        page = incoming
        let target = pageFrame
        FixedFocusMotion.run(vertical: false, duration: Motion.durations.move, damping: 1) {
            incoming.frame = target
            incoming.alpha = 1
            outgoing.frame = target.offsetBy(dx: -dx, dy: 0)
            outgoing.alpha = 0
        } completion: { _ in
            if outgoing !== self.page { outgoing.removeFromSuperview() }
        }
    }

    /// Billboard → Details: the picture steps closer (and back) — on the
    /// swap's one curve and duration (`ModeSwap.swap`), in Core Animation.
    func setStepIn(_ on: Bool) {
        let scale = on ? ModeSwap.depthScale : 1
        let target = CGAffineTransform(scaleX: scale, y: scale)
        guard zoom.transform != target else { return }
        let (c1, c2) = ModeSwap.swapControlPoints
        let animator = UIViewPropertyAnimator(duration: ModeSwap.swapDuration,
                                              controlPoint1: c1, controlPoint2: c2) {
            self.zoom.transform = target
        }
        animator.startAnimation()
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
}
