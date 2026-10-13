import CoreImage
import SwiftUI

extension View {
    /// Player-overlay chrome (toasts, pills, control sheets shown OVER playing
    /// video). `.ultraThinMaterial` here re-blurs the moving frame underneath on
    /// every displayed frame — one of the worst per-frame costs on the A8, and
    /// it drops playback frames while any control is up. On the low-power box
    /// fall back to a solid dark fill (visually near-identical, since these
    /// chips already sit under dark text scrims). `solid` is opaque enough that
    /// the missing blur doesn't read as a change.
    @ViewBuilder
    func playerChrome<S: Shape>(in shape: S, solid: Color = Color(hex: 0x121418).opacity(0.86)) -> some View {
        // Mid tier included: this blurs a MOVING frame on every displayed frame,
        // while the same chip is decoding it. The worst composite in the app,
        // and it was landing on the 4K gen 1 because that box is `isMidPower`.
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            self.background(solid, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The tone hero/backdrop scrims fade into so full-bleed art dissolves into
/// `ATVBackground` without a seam — approximately the wash's color at the
/// lower-middle of the screen (the flat `palette.background` used to leave a
/// visible hard line where the hero band met the lighter graphite stage).
enum ATVStage {
    static let blend = Color(hex: 0x1E2126)
}

/// "Background follows the title" (Settings → Appearance): Home, Movies
/// and Series take on the focused title's colours (`TitleBackground`), a
/// folder its cover's, a page opened from Details (a genre, a person, a
/// studio…) that title's blurred picture. Off — and on every other page —
/// the Projector picture.
enum AppBackground {
    static let followsTitleKey = "cue.appearance.backgroundFollowsTitle"

    /// The setting (outside SwiftUI).
    static var followsTitle: Bool { UserDefaults.standard.bool(forKey: followsTitleKey) }
}

/// The app's still background: warm light from the top left (and,
/// fainter, across the middle), a cool shadow bottom right — a base
/// gradient and large, soft pools of
/// light, blurred and grained (the grain also keeps the dark gradients from
/// banding on a TV). Drawn once with Core Image at 1080p.
enum ProjectorPicture {
    private struct Pool {
        let color: UInt32
        /// Centre, as fractions of the screen.
        let x: CGFloat, y: CGFloat
        /// Radii, as fractions of the screen's width and height.
        let rx: CGFloat, ry: CGFloat
    }

    /// Base gradient, top → bottom, leaning: its top end this many screen
    /// widths to the left.
    private static let top: UInt32 = 0x232220
    private static let bottom: UInt32 = 0x18181A
    private static let tilt: CGFloat = 0.18

    private static let pools = [
        Pool(color: 0x3A3329, x: 0.08, y: -0.10, rx: 0.82, ry: 0.85),
        // The same warmth, fainter, carried across the middle.
        Pool(color: 0x2F2A23, x: 0.74, y: 0.75, rx: 0.42, ry: 0.55),
        Pool(color: 0x1D2330, x: 1.00, y: 1.10, rx: 0.60, ry: 0.50),
    ]

    /// The grain's full range (sRGB, 0–1): up to ±3 levels of 255.
    static let grain: CGFloat = 6.0 / 255
    static let size = CGSize(width: 1920, height: 1080)

    /// Draws the picture (Core Image on the GPU, the grain on the CPU).
    static func render() -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: srgb, .workingFormat: CIFormat.RGBAh])
        let w = Self.size.width, h = Self.size.height
        let rect = CGRect(origin: .zero, size: Self.size)
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CIColor {
            CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha, colorSpace: srgb)!
        }

        // Core Image's y runs up: the top of the screen is y = h.
        let linear = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: w * (0.5 - tilt), y: h),
            "inputPoint1": CIVector(x: w * 0.5, y: 0),
            "inputColor0": color(top),
            "inputColor1": color(bottom),
        ])!.outputImage!
        var image = linear.cropped(to: rect)

        for pool in pools {
            // A circle of radius 1000 scaled into the pool's ellipse.
            let r: CGFloat = 1000
            let circle = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": 0, "inputRadius1": r,
                "inputColor0": color(pool.color),
                "inputColor1": color(pool.color, 0),
            ])!.outputImage!
            let ellipse = circle
                .transformed(by: CGAffineTransform(scaleX: pool.rx * w / r, y: pool.ry * h / r))
                .transformed(by: CGAffineTransform(translationX: pool.x * w, y: (1 - pool.y) * h))
            image = ellipse.composited(over: image).cropped(to: rect)
        }

        // Softens the gradients' cone-shaped centres into round light.
        image = image.clampedToExtent().applyingGaussianBlur(sigma: 60).cropped(to: rect)

        // Read back at 16 bits, then grain while going down to 8: each
        // channel gets the same random offset (grey grain), from two dice
        // (triangular — dithers the gradients without banding).
        let width = Int(w), height = Int(h)
        var smooth = [Float16](repeating: 0, count: width * height * 4)
        smooth.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 8,
                           bounds: rect, format: .RGBAh, colorSpace: srgb)
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x9E3779B9
        let amplitude = Float(Self.grain) * 255 / 2
        smooth.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for i in stride(from: 0, to: src.count, by: 4) {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    let dice = Float(seed & 0xFFFF) + Float(seed >> 16)
                    let offset = (dice / 65535 - 1) * amplitude
                    for c in 0..<3 {
                        let v = Float(src[i + c]) * 255 + offset + 0.5
                        dst[i + c] = UInt8(max(0, min(255, v)))
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The drawn Projector picture (~8 MB), drawn off the main thread the first
/// time it's asked for.
@MainActor
final class ProjectorPictureStore: ObservableObject {
    static let shared = ProjectorPictureStore()
    @Published private(set) var image: UIImage?
    private var drawing = false

    /// Asks for the picture (nil until it's drawn).
    func load() {
        guard image == nil, !drawing else { return }
        drawing = true
        Task.detached(priority: .userInitiated) {
            let cg = ProjectorPicture.render()
            await MainActor.run {
                self.drawing = false
                if let cg { self.image = UIImage(cgImage: cg) }
            }
        }
    }
}

/// The app's background, behind every screen: the Projector picture — on
/// Home, Movies, Series and a folder (`titles`) with "Background follows the
/// title", the title background (`TitleBackground`).
struct ATVBackground: View {
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @ObservedObject private var projector = ProjectorPictureStore.shared
    /// Home, Movies, Series, a folder: pages that follow the title.
    var titles = false

    var body: some View {
        let followed = titles && followsTitle
        ZStack {
            Color(hex: 0x1B1C1F)
            if followed {
                TitleBackgroundView()
                    .transition(.opacity)
            } else if let image = projector.image {
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Motion.fadeDuration), value: followed)
        .animation(.easeInOut(duration: Motion.fadeDuration), value: projector.image)
        .ignoresSafeArea()
        .onAppear { projector.load() }
    }
}
