import SwiftUI
import UIKit

/// THE STAGE PICTURE, in UIKit — the billboard's backdrop as a physical
/// sheet: the picture (drifting on a change of title, as the box does) with
/// the billboard's shade over it, a plain bottom edge.
///
/// Home: part of the Featured row (`FixedFocusRowCell`), so it moves with
/// exactly the rows' animation.
final class StagePictureView: UIView {
    static let pictureSize = CGSize(width: 1920, height: 1080)
    /// Below the billboard the picture darkens by this much.
    static let dimBelow: CGFloat = 0.45
    /// …and its shade (the left fade) shows this much of itself.
    static let shadeBelow: CGFloat = 0.4
    /// How far the billboard's picture drifts on a change (its text only
    /// crossfades — `BillboardCrossfade`).
    static let drift: CGFloat = 16

    /// The picture and its shade.
    private let sheet = UIView()
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
        shade.image = StageArt.shade
        shade.frame = picture
        dim.frame = picture
    }

    /// `direction`: +1 paging right (the new one comes from the right).
    func show(_ url: String?, direction: CGFloat, animated: Bool) {
        guard url != shownURL else { return }
        shownURL = url
        if blursBelow { loadBlurred(url) }
        setNeedsLayout()
        guard animated else {
            load(url, into: page)
            return
        }
        // DRIFT: the new picture fades in shifting a little the way you
        // went, the old one fades out shifting on.
        let dx = direction * Self.drift
        let incoming = UIImageView(frame: pageFrame.offsetBy(dx: dx, dy: 0))
        Self.style(incoming)
        load(url, into: incoming)
        incoming.alpha = 0
        zoom.addSubview(incoming)
        let outgoing = page
        page = incoming
        let target = pageFrame
        FixedFocusMotion.run(duration: Motion.moveDuration) {
            incoming.frame = target
            incoming.alpha = 1
            outgoing.frame = target.offsetBy(dx: -dx, dy: 0)
            outgoing.alpha = 0
        } completion: { _ in
            if outgoing !== self.page { outgoing.removeFromSuperview() }
        }
    }

    /// Below the billboard (pinned): blurred and darker — set inside the
    /// rows' move, it rides it. The shade lightens as the blur and dim take
    /// over.
    func setBelow(_ below: Bool) {
        blurred.alpha = below ? 1 : 0
        // The brightness cap replaces the dim (both: near black).
        dim.alpha = below ? Self.dimBelow : 0
        shade.alpha = below ? Self.shadeBelow : 1
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

/// The billboard's shade (the SwiftUI `BillboardShade`: its two fades)
/// as a still image, made once — and again when its Render Lab
/// settings change. THE shade: the billboard's, Details' and the
/// transition's alike.
@MainActor
enum StageArt {
    private static var shadeKey = ""
    private static var shadeImage: UIImage?

    static var shade: UIImage? {
        let flags = RenderProbe.shared.flags
        let key = "\(flags.noScrim)"
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
