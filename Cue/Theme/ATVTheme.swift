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

/// Settings → Appearance → Background, Dynamic (true): Home, Movies and
/// Series take on the focused title's colours (`TitleBackground`), a
/// folder its cover's. Static — and on every other page — the Projector
/// picture. (A page opened from Details shows that title's blurred
/// picture either way — `DetailsBackdropBackground`.)
enum AppBackground {
    static let followsTitleKey = "cue.appearance.backgroundFollowsTitle"

    /// The setting (outside SwiftUI).
    static var followsTitle: Bool { UserDefaults.standard.bool(forKey: followsTitleKey) }

    /// The still picture: Projector, or Settings' flat grey (tried, kept).
    enum Picture { case projector, settingsGrey }
    static let picture: Picture = .projector
}

/// The app's still background, after tvOS's own dark backdrop (Photos,
/// the TV app — not available to apps): a dark warm grey, lighter across
/// the top, a cool shadow bottom left, a brown one bottom right — a base
/// gradient and large, soft pools, blurred and grained (the grain also
/// keeps the dark gradients from banding on a TV). Drawn once with Core
/// Image at 1080p.
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
    private static let top: UInt32 = 0x2A2826
    private static let bottom: UInt32 = 0x262324
    private static let tilt: CGFloat = 0

    private static let pools = [
        // Warm grey light across the top, brightest a little right of centre.
        Pool(color: 0x2E2A28, x: 0.46, y: 0.05, rx: 0.34, ry: 0.42),
        // The top corners darker: neutral left, grey right (from a dip
        // just right of the light).
        Pool(color: 0x262624, x: 0.00, y: 0.10, rx: 0.22, ry: 0.40),
        Pool(color: 0x222222, x: 1.00, y: 0.00, rx: 0.22, ry: 0.25),
        Pool(color: 0x242222, x: 0.70, y: 0.00, rx: 0.12, ry: 0.22),
        // A dark band across the left, just under the middle.
        Pool(color: 0x1E1E1F, x: 0.18, y: 0.68, rx: 0.28, ry: 0.16),
        // A cool shadow, bottom left.
        Pool(color: 0x191A1E, x: 0.02, y: 1.00, rx: 0.30, ry: 0.42),
        // A warm mauve low in the middle, a brown shadow bottom right.
        Pool(color: 0x2D272A, x: 0.55, y: 1.00, rx: 0.30, ry: 0.30),
        Pool(color: 0x24221C, x: 0.98, y: 1.00, rx: 0.30, ry: 0.28),
        // A faint warmth on the right, middle, and across the middle.
        Pool(color: 0x2C2929, x: 0.80, y: 0.66, rx: 0.30, ry: 0.30),
        Pool(color: 0x2B2828, x: 0.50, y: 0.38, rx: 0.40, ry: 0.18),
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

/// tvOS Settings' own backdrop, recreated (tried as the app's background,
/// kept — `AppBackground.picture`): a flat neutral grey (measured off its screen: 28–29 of 255, ~#1D1D1D)
/// with a fine grey grain (±2 levels, as measured). Drawn once at 1080p.
enum SettingsGreyPicture {
    /// The grey (sRGB, 0–255).
    private static let level: Float = 28.5
    /// The grain's full range (sRGB, 0–1): up to ±2 levels of 255.
    static let grain: CGFloat = 4.0 / 255
    static let size = CGSize(width: 1920, height: 1080)

    /// Draws the picture: each pixel the same random offset on every
    /// channel (grey grain), from two dice (triangular).
    static func render() -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x9E3779B9
        let amplitude = Float(Self.grain) * 255 / 2
        pixels.withUnsafeMutableBufferPointer { dst in
            for i in stride(from: 0, to: dst.count, by: 4) {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let dice = Float(seed & 0xFFFF) + Float(seed >> 16)
                let v = UInt8(max(0, min(255, level + (dice / 65535 - 1) * amplitude + 0.5)))
                dst[i] = v; dst[i + 1] = v; dst[i + 2] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The drawn Projector picture (~8 MB), off the main thread: asked for at
/// launch, from a copy on disk once drawn (a first draw took longer than
/// the launch's play — the background faded in after the gate).
@MainActor
final class ProjectorPictureStore: ObservableObject {
    static let shared = ProjectorPictureStore()
    @Published private(set) var image: UIImage?
    private var drawing = false

    /// Asks for the picture (nil until it's in).
    func load() {
        guard image == nil, !drawing else { return }
        drawing = true
        let file = Self.file
        Task.detached(priority: .userInitiated) {
            var picture = UIImage(contentsOfFile: file.path)?.preparingForDisplay()
            if picture == nil {
                let cg = AppBackground.picture == .projector
                    ? ProjectorPicture.render() : SettingsGreyPicture.render()
                if let cg {
                    let drawn = UIImage(cgImage: cg)
                    picture = drawn
                    let folder = file.deletingLastPathComponent()
                    let files = FileManager.default
                    try? files.createDirectory(at: folder, withIntermediateDirectories: true)
                    // Earlier builds' copies go.
                    for old in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
                    where old.hasPrefix("background-") {
                        try? files.removeItem(at: folder.appendingPathComponent(old))
                    }
                    try? drawn.pngData()?.write(to: file, options: .atomic)
                }
            }
            await MainActor.run {
                self.drawing = false
                if let picture { self.image = picture }
            }
        }
    }

    /// The copy on disk: one per build (the drawing may change with it) and
    /// picture.
    private static var file: URL {
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.map { Int($0.timeIntervalSince1970) } ?? 0
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueCache/background-\(AppBackground.picture)-\(built).png")
    }
}

/// The app's background, behind every screen: the Projector picture — on
/// Home, Movies, Series and a folder (`titles`) with Background: Dynamic,
/// the title background (`TitleBackground`).
struct ATVBackground: View {
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @ObservedObject private var projector = ProjectorPictureStore.shared
    /// Home, Movies, Series, a folder: pages that follow the title.
    var titles = false

    var body: some View {
        let followed = titles && followsTitle
        ZStack {
            Color("AppBackground")   // also the launch screen's
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
