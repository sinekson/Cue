import CoreImage
import SwiftUI

extension View {
}

/// Settings → Appearance → Background, Dynamic (true): Home, Movies and
/// Series take on the focused title's colours (`TitleBackground`), a
/// folder its cover's. Static — and on every other page — the Bands
/// picture. (A page opened from Details shows that title's blurred
/// picture either way — `DetailsBackdropBackground`.)
enum AppBackground {
    static let followsTitleKey = "cue.appearance.backgroundFollowsTitle"

    /// The setting (outside SwiftUI).
    static var followsTitle: Bool { UserDefaults.standard.bool(forKey: followsTitleKey) }
}

/// The app's still background, tvOS's light Settings backdrop gone dark:
/// tvOS Settings' grey (measured off its screen: 28–29 of 255) under tall,
/// soft bands, lighter and darker, no colour — blurred and grained (the
/// grain also keeps the dark gradients from banding on a TV). Drawn once
/// with Core Image at 1080p.
enum BandsPicture {
    private struct Pool {
        let color: UInt32
        /// Centre, as fractions of the screen.
        let x: CGFloat, y: CGFloat
        /// Radii, as fractions of the screen's width and height.
        let rx: CGFloat, ry: CGFloat
    }

    private static let base: UInt32 = 0x1D1D1D
    private static let pools = [
        // Lighter down the left and the right.
        Pool(color: 0x2B2B2B, x: 0.10, y: 0.35, rx: 0.26, ry: 0.75),
        Pool(color: 0x2E2E2E, x: 0.95, y: 0.45, rx: 0.18, ry: 0.70),
        // A dark band from the top, left of the middle.
        Pool(color: 0x212121, x: 0.42, y: 0.05, rx: 0.13, ry: 0.55),
        // The lightest: top right, again bottom right.
        Pool(color: 0x363636, x: 0.68, y: 0.10, rx: 0.22, ry: 0.55),
        Pool(color: 0x323232, x: 0.82, y: 0.98, rx: 0.20, ry: 0.40),
        // Dark low in the middle, lighter beside it.
        Pool(color: 0x1F1F1F, x: 0.46, y: 0.95, rx: 0.20, ry: 0.50),
        Pool(color: 0x2A2A2A, x: 0.20, y: 0.95, rx: 0.16, ry: 0.40),
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
        var image = CIImage(color: color(base)).cropped(to: rect)

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

/// The drawn picture (~8 MB), off the main thread: asked for at
/// launch, from a copy on disk once drawn (a first draw took longer than
/// the launch's play — the background faded in after the gate).
@MainActor
final class BandsPictureStore: ObservableObject {
    static let shared = BandsPictureStore()
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
                if let cg = BandsPicture.render() {
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

    /// The copy on disk: one per build (the drawing may change with it).
    private static var file: URL {
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.map { Int($0.timeIntervalSince1970) } ?? 0
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueCache/background-\(built).png")
    }
}

/// The app's background, behind every screen: the Bands picture — on
/// Home, Movies, Series and a folder (`titles`) with Background: Dynamic,
/// the title background (`TitleBackground`).
struct ATVBackground: View {
    @AppStorage(AppBackground.followsTitleKey) private var followsTitle = false
    @ObservedObject private var picture = BandsPictureStore.shared
    /// Home, Movies, Series, a folder: pages that follow the title.
    var titles = false

    var body: some View {
        let followed = titles && followsTitle
        ZStack {
            Color("AppBackground")   // also the launch screen's
            if followed {
                TitleBackgroundView()
                    .transition(.opacity)
            } else if let image = picture.image {
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Motion.fadeDuration), value: followed)
        .animation(.easeInOut(duration: Motion.fadeDuration), value: picture.image)
        .ignoresSafeArea()
        .onAppear { picture.load() }
    }
}
