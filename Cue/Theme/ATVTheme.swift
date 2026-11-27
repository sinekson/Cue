import Combine
import CoreImage
import simd
import SwiftUI

extension View {
}

/// The app's still background, tvOS's light Settings backdrop gone dark:
/// tvOS Settings' grey (measured off its screen: 28–29 of 255) under tall,
/// soft bands, lighter and darker, no colour — blurred and grained (the
/// grain also keeps the dark gradients from banding on a TV). Drawn once
/// with Core Image at 1080p.
enum BandsPicture {
    /// A picture's main colour and its share of it (`palette`).
    typealias Colour = (r: Double, g: Double, b: Double, share: Double)
    struct Pool {
        /// sRGB, 0–1.
        let r: CGFloat, g: CGFloat, b: CGFloat
        /// Centre, as fractions of the screen.
        let x: CGFloat, y: CGFloat
        /// Radii, as fractions of the screen's width and height.
        let rx: CGFloat, ry: CGFloat

        init(r: CGFloat, g: CGFloat, b: CGFloat, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat) {
            (self.r, self.g, self.b, self.x, self.y, self.rx, self.ry) = (r, g, b, x, y, rx, ry)
        }
        init(color hex: UInt32, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat) {
            self.init(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255,
                      b: CGFloat(hex & 0xFF) / 255, x: x, y: y, rx: rx, ry: ry)
        }
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

    /// The grain added on the GPU before the picture goes to 8 bits (it
    /// keeps the dark gradients from banding): two noises summed, a
    /// triangular ±`grain`/2, the same in each channel, added to the colour
    /// alone by a kernel (added as an image, the noise's alpha of 0 wiped it
    /// out: no grain at all, the bands' steps plain; opaque, alphas summed
    /// to 2 and some pixels came out bright). (A per-pixel loop on the CPU
    /// took seconds in a Debug build on the TV: Details' colours came late.)
    static func grained(_ image: CIImage, in rect: CGRect, context: CIContext) -> CGImage? {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: rect)
        guard let out = grainKernel?.apply(extent: rect, arguments: [image, noise, grain / 2]) else { return nil }
        return context.createCGImage(out, from: rect, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    private static let grainKernel = CIColorKernel(source:
        "kernel vec4 grain(__sample s, __sample n, float a) { return vec4(s.rgb + (n.r + n.g - 1.0) * a, s.a); }")

    /// One for every drawing (making one each time cost tens of ms).
    static let shared = context()

    static func context() -> CIContext {
        // Its intermediates not kept: a drawing is made once per title, and
        // kept they held tens of MB (half floats at the screen's size).
        CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            .workingFormat: CIFormat.RGBAh,
                            .cacheIntermediates: false])
    }

    /// The grey picture (nothing picked yet: a first launch), in the
    /// system's mode (`lifted` for light).
    static func render(light: Bool) -> CGImage? {
        let grey = Pool(color: base, x: 0, y: 0, rx: 0, ry: 0)
        guard light else { return render(base: (grey.r, grey.g, grey.b), pools: pools) }
        // Its bands' contrast doubled first: lifted, the greys sit close.
        func up(_ v: CGFloat) -> CGFloat { lifted(Double(min(1, max(0, (v - grey.r) * 2 + grey.r)))) }
        return render(base: (up(grey.r), up(grey.g), up(grey.b)),
                      pools: pools.map { Pool(r: up($0.r), g: up($0.g), b: up($0.b), x: $0.x, y: $0.y, rx: $0.rx, ry: $0.ry) })
    }

    /// A colour's channel for light mode: toward tvOS's light grey (its
    /// Settings', about 70 %), the picture's colour a soft tint over it —
    /// 0 lands at `liftLow`, 1 at `liftHigh`.
    static func lifted(_ v: Double, darker: Double = 1, _ t: Tuning = Tuning()) -> CGFloat {
        CGFloat((t.liftLow + (t.liftHigh - t.liftLow) * v) * (1 - (1 - darker) * 0.4))
    }

    /// The drawing's values, in one place so the background preview
    /// (`BackgroundPreview`, a card's hold menu) can change them on the fly;
    /// the app draws with the defaults.
    struct Tuning: Equatable {
        // Light: the darkest the base, the rest pools of the picture's
        // colours, `saturation` times its own, lifted to tvOS's light grey
        // (0 at `liftLow`, 1 at `liftHigh`), capped at `lightTint` a channel.
        var saturation = 1.2
        var lightTint: CGFloat = 0.035
        var liftLow = 0.62
        var liftHigh = 0.90
        /// The base (the picture's darkest colour, and the darker pools of
        /// its colour): how much of its colour it keeps, 1 all of it, 0 a
        /// neutral grey; its lightness fixed (nil: the picture's, lifted).
        var baseColour = 1.0
        var baseLight: CGFloat? = nil
        /// Every title to the same amount of colour: the pools' colour,
        /// averaged by share (a channel's most from its grey, after the
        /// lift: `colourAmount`), brought to this by a gain on the
        /// saturation within `gainLimits`; nil: the saturation alone.
        var colourTarget: Double? = nil
        var gainLimits: ClosedRange<Double> = 0.6...3.0

        // Dark (2026-11-27, after tvOS's own dark backdrop, measured on the
        // TV: a neutral grey from ~30 to ~64 of 255 in large soft areas, the
        // colour in a few of them). The title gives the hues, never the
        // amount: the picture's saturation times a factor was everywhere on
        // Barbie (its darkest colour, a maroon, was the base) and nothing on
        // a dull picture, all within 8 levels of lightness.
        /// The base, every title's: a warm dark grey.
        var darkBase: CGFloat = 0.125
        /// Neutral areas over it, lighter and darker: the structure.
        var darkLighter: ClosedRange<CGFloat> = 0.21...0.26
        var darkDarker: ClosedRange<CGFloat> = 0.095...0.105
        /// The spots' lightness (lifted, as tvOS's colour sits in its
        /// lighter areas) and colour: each channel's most from its grey,
        /// the same for every picture.
        var spotLight: CGFloat = 0.21
        var spotColour: CGFloat = 0.07
        /// How many, and the first's radii (fractions of the screen's width
        /// and height; the others 0.06 and 0.10 smaller).
        var spots = 2
        var spotWidth: ClosedRange<CGFloat> = 0.24...0.32
        var spotHeight: ClosedRange<CGFloat> = 0.55...0.75

        /// Both: the blur over the pools (1080p points).
        var blur: CGFloat = 60
        /// Added to the picture's seed: another layout of the same colours.
        var layout: UInt64 = 0

        // Picture (trying in the preview, 2026-11-27, tvOS's way, measured
        // off Photos' light backdrop: 188–244 of 255, colour up to ~52 in
        // its sky, neutral where the photo was): the backdrop itself,
        // blurred to its big masses, its lightness pressed into a band
        // whatever the picture (its 2nd percentile at the low end, 98th at
        // the high), its colour kept but eased in under a ceiling.
        enum Method: Equatable { case backdrop, pools, picture, tinted }
        var method = Method.backdrop
        /// The blur's radius, a fraction of the screen's width.
        var pictureBlur: CGFloat = 0.10
        var darkRange: ClosedRange<CGFloat> = 0.12...0.25
        var lightRange: ClosedRange<CGFloat> = 0.74...0.96
        /// The picture's colour, times its own, then eased under the
        /// ceiling (a channel's most from its grey).
        var pictureColour: CGFloat = 1.0
        var darkCeiling: CGFloat = 0.06
        var lightCeiling: CGFloat = 0.14
        /// Mirrored, so the screen doesn't echo the poster's composition.
        var mirror = false

        // Tinted (trying in the preview, 2026-11-27): one neutral backdrop
        // of lighter and darker areas, the same for every title (its shape
        // from `layout` alone, to change now and then for variety), tinted
        // by the title: its first hue in the lighter areas, its second in
        // the darker, at a set strength (`darkTintAmount`, a channel's most
        // from its grey), the darker areas taking `tintSpread` of it. Dark
        // uses `darkBase`, `darkLighter`, `darkDarker` for its backdrop.
        var lightBase: CGFloat = 0.84
        var lightLighter: ClosedRange<CGFloat> = 0.92...0.96
        var lightDarker: ClosedRange<CGFloat> = 0.74...0.78
        var darkTintAmount: CGFloat = 0.06
        var lightTintAmount: CGFloat = 0.10
        var tintSpread: CGFloat = 0.4

        // Backdrop (2026-11-27, the app's): tvOS's own backdrop, measured
        // off its Photos screens (dark and light share one shape): a
        // coloured band across the top, a neutral middle (warm in dark),
        // a darker coloured mass at one side, the lightest corner below
        // the middle's other side, the darkest beside the mass. The
        // title's first hue in the band, its second in the mass, at a
        // set strength (`…BandColour`, `…MassColour`: a channel's most
        // from its grey, tvOS's ~0.12 and ~0.10 in light, ~0.055 and
        // ~0.04 in dark); its lightness levels tvOS's (of 255: light band
        // 225, middle 215, mass 193, lightest 240; dark band 50, middle
        // 48, mass 34, lightest 54, darkest 32: the cards' edges stay
        // clear of it). The shape mirrored and moved a little by the seed.
        var lightLevels = Levels(band: 0.90, middle: 0.85, mass: 0.73, lightest: 0.97, darkest: 0.77)
        var darkLevels = Levels(band: 0.205, middle: 0.195, mass: 0.12, lightest: 0.225, darkest: 0.11)
        var lightBandColour: CGFloat = 0.12
        var lightMassColour: CGFloat = 0.12
        var darkBandColour: CGFloat = 0.055
        var darkMassColour: CGFloat = 0.045
        var backdropBlur: CGFloat = 90
    }
    struct Levels: Equatable {
        var band: CGFloat, middle: CGFloat, mass: CGFloat, lightest: CGFloat, darkest: CGFloat
    }

    /// Where a part of the Backdrop sits: its centre and radii, fractions
    /// of the screen.
    struct Place { let x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat }
    struct Composition { let band, mass, middle, lightest, darkest: Place }
    /// The Backdrop's compositions, all of the same parts (tvOS's, the
    /// first): the band along an edge or sweeping from a corner, the mass at
    /// a side, a corner or as a second band, the lightest and darkest at
    /// the edges, apart; the neutral middle always as large as the colour.
    /// Mirrored at random, and moved a little, each draw.
    static let compositions: [Composition] = [
        // tvOS's: the band on top, the mass at a side.
        Composition(band: Place(x: 0.50, y: -0.02, rx: 1.25, ry: 0.48), mass: Place(x: 0.90, y: 0.62, rx: 0.30, ry: 0.62),
                    middle: Place(x: 0.42, y: 0.62, rx: 0.30, ry: 0.45), lightest: Place(x: 0.12, y: 1.00, rx: 0.30, ry: 0.40),
                    darkest: Place(x: 0.72, y: 1.00, rx: 0.22, ry: 0.40)),
        // Upside down: the band along the foot.
        Composition(band: Place(x: 0.50, y: 1.02, rx: 1.25, ry: 0.48), mass: Place(x: 0.90, y: 0.38, rx: 0.30, ry: 0.62),
                    middle: Place(x: 0.42, y: 0.38, rx: 0.30, ry: 0.45), lightest: Place(x: 0.12, y: 0.00, rx: 0.30, ry: 0.40),
                    darkest: Place(x: 0.72, y: 0.00, rx: 0.22, ry: 0.40)),
        // A sweep from a top corner, the mass in the opposite one.
        Composition(band: Place(x: 0.05, y: 0.00, rx: 0.75, ry: 0.75), mass: Place(x: 0.95, y: 1.00, rx: 0.40, ry: 0.55),
                    middle: Place(x: 0.55, y: 0.50, rx: 0.35, ry: 0.50), lightest: Place(x: 0.92, y: 0.05, rx: 0.25, ry: 0.35),
                    darkest: Place(x: 0.10, y: 1.00, rx: 0.25, ry: 0.35)),
        // Two bands, top and foot, a light middle between.
        Composition(band: Place(x: 0.50, y: -0.05, rx: 1.25, ry: 0.40), mass: Place(x: 0.50, y: 1.05, rx: 1.10, ry: 0.40),
                    middle: Place(x: 0.50, y: 0.50, rx: 0.35, ry: 0.35), lightest: Place(x: 0.15, y: 0.55, rx: 0.25, ry: 0.35),
                    darkest: Place(x: 0.92, y: 0.55, rx: 0.18, ry: 0.35)),
        // The band down a side, the mass low on the other.
        Composition(band: Place(x: -0.02, y: 0.50, rx: 0.40, ry: 1.20), mass: Place(x: 0.80, y: 1.00, rx: 0.35, ry: 0.45),
                    middle: Place(x: 0.55, y: 0.45, rx: 0.35, ry: 0.50), lightest: Place(x: 0.88, y: 0.00, rx: 0.30, ry: 0.40),
                    darkest: Place(x: 0.98, y: 0.60, rx: 0.18, ry: 0.35)),
        // The band over a top corner, the mass low on the other side, the
        // lightest under the middle.
        Composition(band: Place(x: 0.70, y: 0.00, rx: 0.75, ry: 0.50), mass: Place(x: 0.08, y: 0.75, rx: 0.30, ry: 0.60),
                    middle: Place(x: 0.50, y: 0.55, rx: 0.35, ry: 0.50), lightest: Place(x: 0.55, y: 1.00, rx: 0.35, ry: 0.35),
                    darkest: Place(x: 0.05, y: 0.00, rx: 0.25, ry: 0.35)),
    ]

    /// tvOS's own blue, for a title with no hue of its own (half strength).
    static let tvBlue = SIMD3<Double>(-1, 0.2, 0.86)

    /// The Backdrop method (`Tuning.method`, the app's).
    static func backdrop(from palette: [Colour], light: Bool, seed: UInt64, tuning t: Tuning) -> CGImage? {
        var random = SeededRandom(seed: seed &+ t.layout)
        let flip = Bool.random(using: &random)
        func x(_ v: CGFloat) -> CGFloat { let v = v + .random(in: -0.05...0.05, using: &random); return flip ? 1 - v : v }
        func y(_ v: CGFloat) -> CGFloat { v + .random(in: -0.05...0.05, using: &random) }
        func size(_ v: CGFloat) -> CGFloat { v * .random(in: 0.88...1.12, using: &random) }
        let found = hues(palette, count: 2)
        let (a, b, k) = found.isEmpty ? (tvBlue, tvBlue, 0.5) : (found[0], found[1], 1.0)
        let l = light ? t.lightLevels : t.darkLevels
        let (bandColour, massColour) = light ? (t.lightBandColour, t.lightMassColour) : (t.darkBandColour, t.darkMassColour)
        func neutral(_ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            light ? (v, v, v) : (v + warm.r, v + warm.g, v + warm.b)
        }
        func tinted(_ v: CGFloat, _ hue: SIMD3<Double>, _ amount: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let d = hue * Double(amount) * k
            return (max(0, v + CGFloat(d.x)), max(0, v + CGFloat(d.y)), max(0, v + CGFloat(d.z)))
        }
        // One of the compositions, its parts where it puts them (x, y,
        // radii; before the mirror and the shifts).
        let shape = compositions[Int.random(in: 0..<compositions.count, using: &random)]
        func pool(_ c: (CGFloat, CGFloat, CGFloat), _ p: Place) -> Pool {
            Pool(r: c.0, g: c.1, b: c.2, x: x(p.x), y: y(p.y), rx: size(p.rx), ry: size(p.ry))
        }
        // Back to front: the darkest, the mass, the middle, the lightest,
        // the band over all.
        let pools = [
            pool(neutral(l.darkest), shape.darkest),
            pool(tinted(l.mass, b, massColour), shape.mass),
            pool(neutral(l.middle), shape.middle),
            pool(neutral(l.lightest), shape.lightest),
            pool(tinted(l.band, a, bandColour), shape.band),
        ]
        return render(base: neutral(l.middle), pools: pools, blur: t.backdropBlur)
    }

    /// The picture's hues for its spots and tints, most colourful by share
    /// first, each another hue (40° apart) or the first again; each a
    /// direction from grey, its largest channel 1. None for a grey picture.
    static func hues(_ palette: [Colour], count: Int) -> [SIMD3<Double>] {
        typealias Hue = (d: SIMD3<Double>, chroma: Double, angle: Double, share: Double)
        let hues: [Hue] = palette.compactMap { c in
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let d = SIMD3(c.r - y, c.g - y, c.b - y)
            let chroma = max(abs(d.x), abs(d.y), abs(d.z))
            guard chroma >= hueFloor else { return nil }
            return (d / chroma, chroma, atan2(sqrt(3) * (c.g - c.b), 2 * c.r - c.g - c.b), c.share)
        }.sorted { $0.chroma * $0.share.squareRoot() > $1.chroma * $1.share.squareRoot() }
        var chosen: [Hue] = []
        for hue in hues where chosen.count < count {
            let apart = chosen.allSatisfy { other in
                let gap = abs(hue.angle - other.angle).truncatingRemainder(dividingBy: 2 * .pi)
                return min(gap, 2 * .pi - gap) > 40 * .pi / 180
            }
            if apart { chosen.append(hue) }
        }
        var out = chosen.map(\.d)
        if let first = out.first { while out.count < count { out.append(first) } }
        return out
    }

    /// The Tinted method (`Tuning.method`).
    static func tinted(from palette: [Colour], light: Bool, tuning t: Tuning) -> CGImage? {
        let (base, lighter, darker) = light ? (t.lightBase, t.lightLighter, t.lightDarker)
                                            : (t.darkBase, t.darkLighter, t.darkDarker)
        func grey(_ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            light ? (v, v, v) : (v + warm.r, v + warm.g, v + warm.b)
        }
        // The backdrop: the title plays no part in its shape.
        var random = SeededRandom(seed: 0x5EED &+ t.layout)
        let cells = (0..<6).map { (col: $0 % 3, row: $0 / 3) }.shuffled(using: &random)
        let pools = cells.enumerated().map { i, cell -> Pool in
            let c = grey(i % 2 == 0 ? CGFloat.random(in: lighter, using: &random)
                                    : .random(in: darker, using: &random))
            return Pool(r: c.0, g: c.1, b: c.2,
                        x: (CGFloat(cell.col) + .random(in: 0.2...0.8, using: &random)) / 3,
                        y: (CGFloat(cell.row) + .random(in: 0.15...0.85, using: &random)) / 2,
                        rx: .random(in: 0.22...0.32, using: &random), ry: .random(in: 0.50...0.80, using: &random))
        }
        let rect = CGRect(origin: .zero, size: size)
        let backdrop = poolsImage(base: grey(base), pools: pools, blur: t.blur)
        let pair = hues(palette, count: 2)
        let amount = pair.isEmpty ? 0 : (light ? t.lightTintAmount : t.darkTintAmount)
        let a = pair.first ?? .zero, b = pair.last ?? .zero
        guard let tinted = tintKernel?.apply(extent: rect, arguments: [
            backdrop, darker.lowerBound, lighter.upperBound,
            CIVector(x: a.x, y: a.y, z: a.z), CIVector(x: b.x, y: b.y, z: b.z), amount, t.tintSpread,
        ]) else { return nil }
        return grained(tinted, in: rect, context: shared)
    }
    /// By the backdrop's lightness: the first hue in its lighter areas, the
    /// second in the darker (mixed between, through grey where they're
    /// opposite), at full strength in the lightest, `spread` of it in the
    /// darkest.
    private static let tintKernel = CIColorKernel(source: """
        kernel vec4 tint(__sample s, float lo, float hi, vec3 a, vec3 b, float amount, float spread) {
            float y = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            float t = clamp((y - lo) / max(hi - lo, 0.001), 0.0, 1.0);
            vec3 d = mix(b, a, t);
            return vec4(s.rgb + d * amount * (spread + (1.0 - spread) * t), s.a);
        }
        """)

    /// The preview's setup tried in the app (its In the App row), for this
    /// run only: the app's background drawn with it; nil, the app's own.
    /// `trialTag` names its drawings apart from the app's own and each
    /// other's.
    nonisolated(unsafe) static var trial: Tuning?
    nonisolated(unsafe) static var trialTag = 0
    /// The app's Backdrop's shape, mixed into the title's seed: a new one
    /// at each launch, on coming back to the app, and as Home comes into
    /// view an hour after the last (`BackgroundStore.reshape`); the title
    /// and its colours stay.
    nonisolated(unsafe) static var shape = UInt64.random(in: 0...UInt64.max)

    /// A title's background by any method (`source`: the picture, small,
    /// for Picture only).
    static func drawing(palette: [Colour], backdrop source: CGImage?, light: Bool, seed: UInt64,
                        tuning t: Tuning) -> CGImage? {
        switch t.method {
        case .backdrop: return backdrop(from: palette, light: light, seed: seed, tuning: t)
        case .picture: return source.flatMap { picture($0, light: light, tuning: t) }
        case .tinted: return tinted(from: palette, light: light, tuning: t)
        case .pools:
            guard let bands = pools(from: palette, light: light, seed: seed, tuning: t) else { return nil }
            return render(base: bands.base, pools: bands.pools, blur: t.blur)
        }
    }

    /// The Picture method (`Tuning.method`): drawn small (160 × 90), so the
    /// blur and the per-pixel mapping are cheap, then scaled to the screen
    /// and softened.
    static func picture(_ source: CGImage, light: Bool, tuning t: Tuning) -> CGImage? {
        let (w, h) = (160, 90)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // Filled into 16:9, mirrored if asked.
        let scale = max(CGFloat(w) / CGFloat(source.width), CGFloat(h) / CGFloat(source.height))
        let sw = CGFloat(source.width) * scale, sh = CGFloat(source.height) * scale
        var small = CIImage(cgImage: source)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (CGFloat(w) - sw) / 2, y: (CGFloat(h) - sh) / 2))
        if t.mirror {
            small = small.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(w), y: 0))
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(t.pictureBlur * CGFloat(w)))
            .cropped(to: rect)
        var bytes = [Float](repeating: 0, count: w * h * 4)
        shared.render(blurred, toBitmap: &bytes, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: srgb)

        // Lightness into the band.
        func luma(_ i: Int) -> Float { 0.2126 * bytes[i] + 0.7152 * bytes[i + 1] + 0.0722 * bytes[i + 2] }
        let lumas = stride(from: 0, to: bytes.count, by: 4).map(luma).sorted()
        let lo = lumas[lumas.count * 2 / 100], hi = max(lumas[lumas.count * 98 / 100], lo + 0.02)
        let band = light ? t.lightRange : t.darkRange
        let ceiling = Float(light ? t.lightCeiling : t.darkCeiling)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let y = luma(i)
            let k = min(1, max(0, (y - lo) / (hi - lo)))
            let newY = Float(band.lowerBound) + k * Float(band.upperBound - band.lowerBound)
            var d = (bytes[i] - y, bytes[i + 1] - y, bytes[i + 2] - y)
            let m = max(abs(d.0), abs(d.1), abs(d.2))
            if m > 0.0001, ceiling > 0 {
                // Eased in under the ceiling: a soft knee, not a cut.
                let eased = ceiling * tanh(Float(t.pictureColour) * m / ceiling)
                d = (d.0 / m * eased, d.1 / m * eased, d.2 / m * eased)
            } else { d = (0, 0, 0) }
            bytes[i] = min(1, max(0, newY + d.0))
            bytes[i + 1] = min(1, max(0, newY + d.1))
            bytes[i + 2] = min(1, max(0, newY + d.2))
            bytes[i + 3] = 1
        }

        let mapped = CIImage(bitmapData: Data(bytes: bytes, count: bytes.count * 4), bytesPerRow: w * 16,
                             size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: srgb)
        let screen = CGRect(origin: .zero, size: size)
        let up = mapped.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
            .applyingGaussianBlur(sigma: 24)
            .cropped(to: screen)
        return grained(up, in: screen, context: shared)
    }
    /// Details' and the stage's spots, dark: stronger (closer to the film).
    static let detailsSpot: CGFloat = 0.09
    static let stageSpot: CGFloat = 0.115
    /// A palette colour this far from its grey (a channel) has a hue;
    /// greyer ones give no spot (a grey picture: grey areas only).
    static let hueFloor = 0.035
    /// Dark's grey leans warm whatever the title (half Apple TV's red
    /// about 8 levels over blue: the whole read too warm); its lightness
    /// about kept.
    static let warm: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.007, 0.0005, -0.0085)
    /// A colour pulled toward its own grey until no channel strays more
    /// than `cap`; its lightness kept.
    static func capped(_ c: (CGFloat, CGFloat, CGFloat), _ cap: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        let most = max(abs(c.0 - y), abs(c.1 - y), abs(c.2 - y))
        guard most > cap else { return c }
        let k = cap / most
        return (y + (c.0 - y) * k, y + (c.1 - y) * k, y + (c.2 - y) * k)
    }
    /// Details' (`TitleBands`): the picture's colour stronger over the grey
    /// — 0 lands at 50 %, 1 at 92 %.
    static func liftedStrong(_ v: Double, darker: Double = 1) -> CGFloat {
        CGFloat((0.50 + 0.42 * v) * (1 - (1 - darker) * 0.4))
    }

    /// Draws pools of colour on a base (Core Image on the GPU, the grain on
    /// the CPU).
    static func render(base: (CGFloat, CGFloat, CGFloat), pools: [Pool], blur: CGFloat = Tuning().blur) -> CGImage? {
        grained(poolsImage(base: base, pools: pools, blur: blur), in: CGRect(origin: .zero, size: size), context: shared)
    }

    /// The pools on the base, blurred, before the grain.
    static func poolsImage(base: (CGFloat, CGFloat, CGFloat), pools: [Pool], blur: CGFloat) -> CIImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = Self.size.width, h = Self.size.height
        let rect = CGRect(origin: .zero, size: Self.size)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> CIColor {
            CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: srgb)!
        }

        // Core Image's y runs up: the top of the screen is y = h.
        var image = CIImage(color: color(base.0, base.1, base.2)).cropped(to: rect)

        for pool in pools {
            // A circle of radius 1000 scaled into the pool's ellipse.
            let r: CGFloat = 1000
            let circle = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": 0, "inputRadius1": r,
                "inputColor0": color(pool.r, pool.g, pool.b),
                "inputColor1": color(pool.r, pool.g, pool.b, 0),
            ])!.outputImage!
            let ellipse = circle
                .transformed(by: CGAffineTransform(scaleX: pool.rx * w / r, y: pool.ry * h / r))
                .transformed(by: CGAffineTransform(translationX: pool.x * w, y: (1 - pool.y) * h))
            image = ellipse.composited(over: image).cropped(to: rect)
        }

        // Softens the gradients' cone-shaped centres into round light.
        return image.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: rect)
    }

    /// A picture's main colours (a few, k-means on a small copy), darkest
    /// first, each with its share of the picture.
    static func palette(_ picture: CGImage, count: Int = 4) -> [(r: Double, g: Double, b: Double, share: Double)] {
        let (w, h) = (48, 27)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let c = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }
        let pixels = stride(from: 0, to: bytes.count, by: 4).map {
            SIMD3<Double>(Double(bytes[$0]), Double(bytes[$0 + 1]), Double(bytes[$0 + 2])) / 255
        }
        func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        // Started from the light's spread, so dark and light both get one.
        let byLight = pixels.sorted { luma($0) < luma($1) }
        var centres = (0..<count).map { byLight[min(byLight.count - 1, (2 * $0 + 1) * byLight.count / (2 * count))] }
        var members = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<10 {
            for (i, p) in pixels.enumerated() {
                members[i] = centres.indices.min { simd_length_squared(p - centres[$0]) < simd_length_squared(p - centres[$1]) }!
            }
            for k in centres.indices {
                let mine = pixels.indices.filter { members[$0] == k }
                if !mine.isEmpty { centres[k] = mine.reduce(SIMD3<Double>()) { $0 + pixels[$1] } / Double(mine.count) }
            }
        }
        return centres.indices.map { k in
            (centres[k].x, centres[k].y, centres[k].z, Double(members.filter { $0 == k }.count) / Double(pixels.count))
        }
        .filter { $0.3 >= 0.04 }
        .sorted { luma(SIMD3($0.0, $0.1, $0.2)) < luma(SIMD3($1.0, $1.1, $1.2)) }
    }

    /// A picture's colours as pools in a layout of their own (tvOS's way;
    /// `seed`: the same picture, the same layout). Dark: `darkPools`.
    /// Light: the darkest the base, the rest spread across the screen at
    /// random, each colour by its share, lifted to tvOS's light grey, the
    /// colours a tint (`lifted`).
    static func pools(from palette: [(r: Double, g: Double, b: Double, share: Double)],
                      light: Bool = false, strong: Bool = false,
                      saturation chosen: Double? = nil, seed: UInt64,
                      tuning t: Tuning = Tuning()) -> (base: (CGFloat, CGFloat, CGFloat), pools: [Pool])? {
        let seed = seed &+ t.layout
        guard light else {
            var t = t
            if chosen != nil { t.spotColour = stageSpot } else if strong { t.spotColour = detailsSpot }
            return darkPools(from: palette, seed: seed, tuning: t)
        }
        guard let darkest = palette.first else { return nil }
        // The app's own (not Details' or the stage's): its base and its
        // colour amount by the tuning.
        let app = !strong && chosen == nil
        let gain = app ? colourGain(palette, t) : 1
        func shaded(_ c: (r: Double, g: Double, b: Double, share: Double), _ extra: Double = 1) -> (CGFloat, CGFloat, CGFloat) {
            // The picture's hues pushed out from its grey (k-means averages
            // and the blur pull them toward grey); Details' further.
            var c = c
            let saturation = chosen ?? (strong ? Self.strongSaturation : t.saturation * gain)
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            func out(_ v: Double) -> Double { min(1, max(0, y + (v - y) * saturation)) }
            (c.r, c.g, c.b) = (out(c.r), out(c.g), out(c.b))
            if strong { return (liftedStrong(c.r, darker: extra), liftedStrong(c.g, darker: extra), liftedStrong(c.b, darker: extra)) }
            let lit = (lifted(c.r, darker: extra, t), lifted(c.g, darker: extra, t), lifted(c.b, darker: extra, t))
            return chosen == nil ? capped(lit, t.lightTint) : lit
        }
        /// The base's colour: its share of its colour kept, its lightness
        /// fixed if asked (the darker pools a step down, as `lifted`'s).
        func based(_ extra: Double) -> (CGFloat, CGFloat, CGFloat) {
            let c = shaded(darkest, extra)
            guard app else { return c }
            let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
            let k = CGFloat(t.baseColour)
            let to = t.baseLight.map { $0 * CGFloat(1 - (1 - extra) * 0.4) } ?? y
            return (to + (c.0 - y) * k, to + (c.1 - y) * k, to + (c.2 - y) * k)
        }
        var random = SeededRandom(seed: seed)
        let colours = palette.count > 1 ? Array(palette.dropFirst()) : palette
        let total = colours.reduce(0) { $0 + $1.share }
        func pick() -> (r: Double, g: Double, b: Double, share: Double) {
            var roll = Double.random(in: 0..<total, using: &random)
            for c in colours { roll -= c.share; if roll < 0 { return c } }
            return colours[colours.count - 1]
        }
        // Spread across the width (one per column, placed at random in it),
        // anywhere up and down, of mixed sizes; a few of the base's own
        // colour between them for dark bands.
        let count = poolCount
        let pools = (0..<count).map { i -> Pool in
            let colour = i % 3 == 2 ? based(0.8) : shaded(pick())
            return Pool(r: colour.0, g: colour.1, b: colour.2,
                        x: (CGFloat(i) + .random(in: 0.1...0.9, using: &random)) / CGFloat(count),
                        y: .random(in: 0...1, using: &random),
                        rx: .random(in: 0.14...0.30, using: &random),
                        ry: .random(in: 0.35...0.80, using: &random))
        }.shuffled(using: &random)
        return (based(0.85), pools)
    }

    /// Light's pools' colour at the tuning's saturation (no gain): each
    /// colour's channel furthest from its grey after the lift, averaged by
    /// share (the base left out); the cap not counted.
    static func colourAmount(_ palette: [Colour], _ t: Tuning) -> Double {
        let colours = palette.count > 1 ? Array(palette.dropFirst()) : palette
        let total = colours.reduce(0) { $0 + $1.share }
        guard total > 0 else { return 0 }
        return colours.reduce(0) { sum, c in
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let chroma = max(abs(c.r - y), abs(c.g - y), abs(c.b - y))
            return sum + c.share / total * min(1, chroma * t.saturation) * (t.liftHigh - t.liftLow)
        }
    }

    /// The gain bringing a title to `colourTarget` (1 without one).
    static func colourGain(_ palette: [Colour], _ t: Tuning) -> Double {
        guard let target = t.colourTarget else { return 1 }
        let amount = colourAmount(palette, t)
        guard amount > 0.0005 else { return 1 }
        return min(t.gainLimits.upperBound, max(t.gainLimits.lowerBound, target / amount))
    }

    /// Dark: a neutral warm grey (`darkBase`), lighter and darker areas over
    /// it, and the picture's hues in spots (two), each at the same strength
    /// (`spotColour`) whatever the picture's own: a third of the screen or
    /// so in colour, the rest grey. The screen as six cells, three across
    /// and two down, each area in a cell of its own so they don't pile up.
    static func darkPools(from palette: [Colour], seed: UInt64, tuning t: Tuning)
        -> (base: (CGFloat, CGFloat, CGFloat), pools: [Pool])? {
        guard !palette.isEmpty else { return nil }
        func grey(_ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) { (v + warm.r, v + warm.g, v + warm.b) }
        let chosen = hues(palette, count: t.spots)

        var random = SeededRandom(seed: seed)
        var cells = (0..<6).map { (col: $0 % 3, row: $0 / 3) }.shuffled(using: &random)
        // The spots in different columns (three at most).
        for i in stride(from: 1, to: min(chosen.count, 3), by: 1) {
            let taken = Set(cells.prefix(i).map(\.col))
            if let other = cells[i...].firstIndex(where: { !taken.contains($0.col) }) { cells.swapAt(i, other) }
        }
        func place(_ cell: (col: Int, row: Int), rx: ClosedRange<CGFloat>, ry: ClosedRange<CGFloat>,
                   _ c: (CGFloat, CGFloat, CGFloat)) -> Pool {
            Pool(r: c.0, g: c.1, b: c.2,
                 x: (CGFloat(cell.col) + .random(in: 0.2...0.8, using: &random)) / 3,
                 y: (CGFloat(cell.row) + .random(in: 0.15...0.85, using: &random)) / 2,
                 rx: .random(in: rx, using: &random), ry: .random(in: ry, using: &random))
        }
        // The grey areas first, the spots over them (under them, a lighter
        // grey washed their colour out).
        var pools: [Pool] = []
        for (i, cell) in cells.dropFirst(chosen.count).enumerated() {
            let v = i % 2 == 0 ? CGFloat.random(in: t.darkLighter, using: &random)
                               : .random(in: t.darkDarker, using: &random)
            pools.append(place(cell, rx: 0.18...0.28, ry: 0.40...0.70, grey(v)))
        }
        for (i, hue) in chosen.enumerated() {
            let d = hue * Double(t.spotColour)
            let c = grey(t.spotLight)
            let (dw, dh): (CGFloat, CGFloat) = i == 0 ? (0, 0) : (0.06, 0.10)
            pools.append(place(cells[i % cells.count],
                               rx: max(0.02, t.spotWidth.lowerBound - dw)...max(0.02, t.spotWidth.upperBound - dw),
                               ry: max(0.02, t.spotHeight.lowerBound - dh)...max(0.02, t.spotHeight.upperBound - dh),
                               (max(0, c.0 + d.x), max(0, c.1 + d.y), max(0, c.2 + d.z))))
        }
        return (grey(t.darkBase), pools)
    }

    private static let poolCount = 8
    /// Details' colours' saturation, light, times the picture's (the app's:
    /// `Tuning.saturation`, 1.4 read too colourful on an OLED with tvOS in
    /// Dolby Vision, which lifts colour far more than light; 0.8 and 1.0
    /// were tried).
    static let strongSaturation = 1.5
    /// The play stage's: a step past Details', the same bands deepening as
    /// it comes in (closer to the film).
    static let stageSaturation = 1.8
}

/// The same numbers for the same seed (a picture's layout drawn again).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// THE BACKGROUND, one still picture behind every page: a title's
/// picture's colours as soft pools in a layout of their own, in tvOS's
/// mode (`BackgroundPicks`): light, its colours lifted to tvOS's light
/// grey; dark, sunk to a dark one's. A new title at each launch (Change
/// at Launch: from Home, from Saved, never); a mode change keeps the title (Automatic at sunset: the page changes anyway).
/// Grey pools are the fallback (nothing picked yet: a first launch).
/// (Tried: the title's picture blurred as Details' — too busy at times;
/// grey alone; following the focused title — its colours, then its
/// blurred picture: too much going on.)
@MainActor
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()
    @Published private(set) var image: UIImage?
    /// The title it's from (Settings → Appearance → Background); nil: Bands.
    @Published private(set) var shown: BackgroundPicks.Entry?
    /// How it came: from Home, from Saved, or chosen.
    @Published private(set) var source: BackgroundPicks.Source = .home
    /// Saved backgrounds, newest last (Settings → Background → Saved).
    @Published private(set) var saved: [BackgroundPicks.Entry] = BackgroundPicks.shared.savedEntries
    private var loading = false

    /// At launch: the next title (Change at Launch), else Bands (nil until in).
    func load() {
        guard image == nil, !loading else { return }
        loading = true
        Task {
            _ = await BackgroundPicks.Mode.known()
            let pick = await BackgroundPicks.shared.next()
            await show(pick, fade: false)
            loading = false
        }
    }

    /// The first title drawn while Bands is up (a first launch): in, faded.
    func firstReady() {
        guard shown == nil, image != nil, !loading else { return }
        Task {
            let pick = await BackgroundPicks.shared.next()
            if pick != nil { await show(pick, fade: true) }
        }
    }

    /// The mode the picture up is drawn in.
    private var drawnMode: BackgroundPicks.Mode?

    /// tvOS's mode changed: the same title in the mode's colours (the
    /// page's text turns with it), faded in.
    func modeChanged() {
        let now = BackgroundPicks.Mode.now
        guard image != nil, drawnMode != now else { return }
        if let ahead, ahead.mode == now, let shown,
           ahead.file == BackgroundPicks.file(for: shown.url, mode: now).lastPathComponent {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { image = ahead.image }
            drawnMode = now
            self.ahead = nil
            AppProbe.life("background → \(now), ready ahead")
            prepareOther()
            return
        }
        guard !loading else { return }
        AppProbe.life("background → \(now), drawn now")
        Task {
            let pick = await BackgroundPicks.shared.current()
            await show(pick, fade: true)
        }
    }

    /// Another shape for the title up (`BandsPicture.shape`), faded in:
    /// on coming back to the app, and as Home comes into view (`hourly`:
    /// only an hour after the last). Not while something plays.
    func reshape(hourly: Bool = false) {
        guard image != nil, shown != nil, !loading, !NuvioSyncManager.playbackActive,
              !hourly || Date().timeIntervalSince(shapedAt) >= 3600 else { return }
        shapedAt = Date()
        BandsPicture.shape = UInt64.random(in: 0...UInt64.max)
        redraw()
    }
    private var shapedAt = Date()

    /// The preview's setup tried in the app, or the app's own back: the
    /// title up drawn again with it, faded.
    func redraw() {
        Task {
            let pick = await BackgroundPicks.shared.current()
            await show(pick, fade: true)
        }
    }

    /// Settings' Pick Another: another now (from Saved when launches take
    /// those, else from Home).
    func another() {
        Task {
            let pick = await BackgroundPicks.shared.next(fresh: true)
            await show(pick, fade: true)
        }
    }

    /// A card's "Use as Background": its title now.
    func use(_ item: MetaItem) {
        Task {
            guard let pick = await BackgroundPicks.shared.choose(item) else { return }
            await show(pick, fade: true)
        }
    }

    /// A saved one, set from Settings.
    func set(_ entry: BackgroundPicks.Entry) {
        Task {
            guard let pick = await BackgroundPicks.shared.set(entry) else { return }
            await show(pick, fade: true)
        }
    }

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }

    /// The one up saved, or taken off Saved (the hold menu's Save
    /// Background, Settings' Save This Background).
    func toggleSaved() {
        guard let shown else { return }
        if isSaved(shown.id) { unsave(shown.id); return }
        guard saved.count < BackgroundPicks.savedLimit else {
            ToastCenter.shared.show("\(BackgroundPicks.savedLimit) saved. Remove one first.", icon: "photo")
            return
        }
        Task {
            guard await BackgroundPicks.shared.save(shown) else { return }
            saved = BackgroundPicks.shared.savedEntries
        }
    }

    func unsave(_ id: String) {
        BackgroundPicks.shared.unsave(id)
        saved = BackgroundPicks.shared.savedEntries
        // Nothing left to take from: launches go back to Home.
        if saved.isEmpty, BackgroundPicks.AtLaunch.current == .saved { BackgroundPicks.AtLaunch.current = .home }
    }

    private func show(_ pick: (entry: BackgroundPicks.Entry, file: URL)?, fade: Bool) async {
        let mode = BackgroundPicks.Mode.now
        let light = mode == .light
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage, Bool)? in
            if let pick, let image = UIImage(contentsOfFile: pick.file.path)?.preparingForDisplay() {
                return (image, true)
            }
            return Self.bands(light: light).map { ($0, false) }
        }.value
        guard let (picture, picked) = loaded else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = !fade
        withTransaction(transaction) { image = picture }
        drawnMode = mode
        shown = picked ? pick?.entry : nil
        source = BackgroundPicks.shared.source
        prepareOther()
    }

    /// The title up drawn and decoded in the other mode, ahead: tvOS's
    /// appearance changing swaps it in at once, with the pages' text
    /// (drawn at the change, it came a moment after the text).
    private var ahead: (mode: BackgroundPicks.Mode, file: String, image: UIImage)?

    private func prepareOther() {
        guard let entry = shown, let mode = drawnMode else { ahead = nil; return }
        let other: BackgroundPicks.Mode = mode == .light ? .dark : .light
        Task {
            guard let pick = await BackgroundPicks.shared.current(in: other) else { return }
            let decoded = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: pick.file.path)?.preparingForDisplay()
            }.value
            guard let decoded, shown?.id == entry.id else { return }
            ahead = (other, pick.file.lastPathComponent, decoded)
        }
    }

    /// The Bands picture (~8 MB), from its copy on disk once drawn (a first
    /// draw took longer than the launch's play).
    nonisolated private static func bands(light: Bool) -> UIImage? {
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.map { Int($0.timeIntervalSince1970) } ?? 0
        let file = BackgroundPicks.folder.deletingLastPathComponent()
            .appendingPathComponent("background-\(built)\(light ? "-light" : "").png")
        if let picture = UIImage(contentsOfFile: file.path)?.preparingForDisplay() { return picture }
        guard let cg = BandsPicture.render(light: light) else { return nil }
        let drawn = UIImage(cgImage: cg)
        let folder = file.deletingLastPathComponent()
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        // Earlier builds' copies go.
        for old in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where old.hasPrefix("background-") && !old.hasPrefix("background-\(built)") {
            try? files.removeItem(at: folder.appendingPathComponent(old))
        }
        try? drawn.pngData()?.write(to: file, options: .atomic)
        return drawn
    }
}

/// Which title's colours are the background (`BackgroundStore`). At each
/// launch, by Change at Launch (`AtLaunch`): any title on Home (the
/// billboard's, each row's first 15) at random, not one of the last 7; or
/// one of your saved ones (up to 12, never the same twice running); or
/// none (it stays). One title for both modes: its colours sunk for dark,
/// lifted for light (`BandsPicture.pools`), so any picture works in either
/// and a mode change keeps the title. Home's next is drawn ahead in both
/// modes, so a change is instant. (A brightness score and a dark / light
/// split of the titles were for the blurred picture as the background.)
@MainActor
final class BackgroundPicks {
    static let shared = BackgroundPicks()

    struct Entry: Codable, Equatable {
        let id: String
        let name: String
        /// TMDB's backdrop (Details' picture).
        let url: String
    }

    /// How the one up came.
    enum Source: String, Codable {
        case home, saved, chosen
    }

    /// What a launch brings (Settings → Background → Change at Launch).
    enum AtLaunch: String, CaseIterable {
        case home, saved, never
        var label: String {
            switch self {
            case .home: "From Home"
            case .saved: "From Saved"
            case .never: "Never"
            }
        }
        static let key = "cue.background.atLaunch"
        static var current: AtLaunch {
            get { AtLaunch(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .home }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    /// tvOS's appearance (Settings → Appearance; Automatic turns it at
    /// sunset).
    enum Mode: Int, CaseIterable, Codable {
        case dark, light
        static var now: Mode {
            (window?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .light ? .light : .dark
        }
        private static var window: UIWindow? {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        }
        /// Once there's a window: before it (the app's init) tvOS's mode
        /// is unspecified, read as dark, and the launch drew dark bands,
        /// then light over them (a flicker).
        static func known() async -> Mode {
            for _ in 0..<100 where window == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return now
        }
    }

    private struct State: Codable {
        var shown: Entry?
        var source: Source?
        /// Title ids.
        var recent: [String] = []
        /// Drawn ahead in both modes.
        var next: Entry?
    }

    /// A saved background: the title and its colours (drawn again
    /// without its picture).
    private struct Saved: Codable {
        let entry: Entry
        /// r, g, b, share.
        let palette: [[Double]]
    }

    static let recentCount = 7
    static let savedLimit = 12

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueCache/backgrounds")
    }
    private static var stateFile: URL { folder.appendingPathComponent("background.json") }
    /// Not a cache: Clear Cache leaves it (`KeptFiles`).
    private static var savedFile: URL { KeptFiles.url("saved-backgrounds.json") }

    private lazy var state: State = {
        // The scored picks of before.
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("picks.json"))
        guard let data = try? Data(contentsOf: Self.stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }()
    private lazy var saved: [Saved] = {
        guard let data = try? Data(contentsOf: Self.savedFile),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return [] }
        return saved
    }()
    /// Home's titles, from the last deep band.
    private var pool: [MetaItem] = []
    private var preparing = false

    private func save() {
        let data = try? JSONEncoder().encode(state)
        let file = Self.stateFile
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data?.write(to: file, options: .atomic)
        }
    }

    private func saveSaved() {
        let data = try? JSONEncoder().encode(saved)
        let file = Self.savedFile
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data?.write(to: file, options: .atomic)
        }
    }

    nonisolated static func seed(_ url: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    /// (The drawing's version in the name: older drawings go.)
    nonisolated static func file(for url: String, mode: Mode) -> URL {
        folder.appendingPathComponent("bands17-" + String(seed(url), radix: 36) + (mode == .light ? "-light" : "")
                                      + "-" + String(BandsPicture.shape % 46656, radix: 36)
                                      + (BandsPicture.trial == nil ? "" : "-trial\(BandsPicture.trialTag)") + ".png")
    }

    private func drawn(_ entry: Entry?, _ mode: Mode) -> (entry: Entry, file: URL)? {
        guard let entry else { return nil }
        let file = Self.file(for: entry.url, mode: mode)
        return FileManager.default.fileExists(atPath: file.path) ? (entry, file) : nil
    }

    var source: Source { state.source ?? .home }

    /// The title up, in this mode's colours (drawn now if it isn't yet).
    func current(in mode: Mode = Mode.now) async -> (entry: Entry, file: URL)? {
        guard let shown = state.shown else { return nil }
        if let ready = drawn(shown, mode) { return ready }
        return await draw(shown.url, mode: mode) ? drawn(shown, mode) : nil
    }

    /// A launch's (Change at Launch), or another now (`fresh`: Pick
    /// Another, never "Never"); else the one up; nil: none (Bands).
    func next(fresh: Bool = false) async -> (entry: Entry, file: URL)? {
        let atLaunch = AtLaunch.current
        if !fresh, atLaunch == .never, let current = await current() { return current }
        if atLaunch == .saved, let pick = await nextSaved() { return pick }
        if fresh {
            // Drawn now, whatever's ready.
            state.next = nil
            await prepare()
        }
        guard let next = drawn(state.next, Mode.now) else { return await current() }
        state.next = nil
        up(next.entry, source: .home)
        return next
    }

    /// One of the saved, not the one up (unless it's the only one).
    private func nextSaved() async -> (entry: Entry, file: URL)? {
        let others = saved.filter { $0.entry.id != state.shown?.id }
        guard let pick = others.randomElement() else { return await current() }
        return await set(pick.entry)
    }

    /// A saved one, up now.
    func set(_ entry: Entry) async -> (entry: Entry, file: URL)? {
        let mode = Mode.now
        guard await draw(entry.url, mode: mode) else { return nil }
        up(entry, source: .saved)
        return drawn(entry, mode)
    }

    /// A title chosen from its card's menu: up now.
    func choose(_ item: MetaItem) async -> (entry: Entry, file: URL)? {
        guard let url = await TMDBService.backdrop(id: item.id, type: item.type) else { return nil }
        let entry = Entry(id: item.id, name: item.name, url: url)
        let mode = Mode.now
        guard await draw(url, mode: mode) else { return nil }
        if state.next?.id == item.id { state.next = nil }
        up(entry, source: .chosen)
        return (entry, Self.file(for: url, mode: mode))
    }

    private func up(_ entry: Entry, source: Source) {
        state.shown = entry
        state.source = source
        state.recent = Array(([entry.id] + state.recent.filter { $0 != entry.id }).prefix(Self.recentCount))
        save()
        Task {
            // The other mode's too, for a mode change.
            for mode in Mode.allCases { _ = await draw(entry.url, mode: mode) }
            await prepare()
        }
    }

    // MARK: Saved

    var savedEntries: [Entry] { saved.map(\.entry) }

    /// Saved with its colours; false: full, or its colours couldn't be read.
    func save(_ entry: Entry) async -> Bool {
        guard saved.count < Self.savedLimit else { return false }
        if saved.contains(where: { $0.entry.id == entry.id }) { return true }
        guard let palette = await TitleBands.shared.palette(for: entry.url) else { return false }
        saved.append(Saved(entry: entry, palette: palette.map { [$0.r, $0.g, $0.b, $0.share] }))
        saveSaved()
        return true
    }

    func unsave(_ id: String) {
        saved.removeAll { $0.entry.id == id }
        saveSaved()
    }

    /// A background's colours, darkest first (Settings 2's strip): a saved
    /// one's own, else read from its picture.
    func colours(_ entry: Entry) async -> [BandsPicture.Colour]? {
        let kept = saved.first { $0.entry.id == entry.id }?.palette
            .filter { $0.count == 4 }.map { (r: $0[0], g: $0[1], b: $0[2], share: $0[3]) }
        if let kept, !kept.isEmpty { return kept }
        return await TitleBands.shared.palette(for: entry.url)
    }

    /// A saved one drawn small, in this mode (Settings' list).
    func preview(_ entry: Entry) async -> UIImage? {
        let mode = Mode.now
        guard await draw(entry.url, mode: mode) else { return nil }
        let file = Self.file(for: entry.url, mode: mode)
        return await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: file.path)?.preparingThumbnail(of: CGSize(width: 192, height: 108))
        }.value
    }

    /// The picture's colours drawn to its file (off the main thread): a
    /// saved one's own, else read from its picture.
    private func draw(_ url: String, mode: Mode) async -> Bool {
        let file = Self.file(for: url, mode: mode)
        if FileManager.default.fileExists(atPath: file.path) { return true }
        let kept: [BandsPicture.Colour]? = saved.first { $0.entry.url == url }?.palette
            .filter { $0.count == 4 }.map { (r: $0[0], g: $0[1], b: $0[2], share: $0[3]) }
        var palette = kept
        if palette == nil { palette = await TitleBands.shared.palette(for: url) }
        guard let palette else { return false }
        let seed = Self.seed(url) &+ BandsPicture.shape % 46656
        let tuning = BandsPicture.trial ?? BandsPicture.Tuning()
        let backdrop = tuning.method == .picture ? await Self.backdrop(url) : nil
        return await Task.detached(priority: .utility) { () -> Bool in
            // Dark sinks the colours, light lifts them: neither dims.
            guard let picture = BandsPicture.drawing(palette: palette, backdrop: backdrop, light: mode == .light,
                                                     seed: seed, tuning: tuning),
                  let png = UIImage(cgImage: picture).pngData() else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return (try? png.write(to: file, options: .atomic)) != nil
        }.value
    }

    /// The backdrop, small (TMDB's 780 px copy): the Picture method's.
    static func backdrop(_ url: String) async -> CGImage? {
        let small = url.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")
        guard let remote = URL(string: small), let data = try? await ImageCache.shared.download(remote) else { return nil }
        return UIImage(data: data)?.cgImage
    }

    /// The deep band: Home's titles, then the next drawn ahead.
    func offer(_ items: [MetaItem]) async {
        var seen = Set<String>()
        pool = items.filter { seen.insert($0.id).inserted }
        await prepare()
        BackgroundStore.shared.firstReady()
    }

    /// Home's next title, drawn ahead in both modes.
    private func prepare() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        if state.next.map({ next in Mode.allCases.allSatisfy { drawn(next, $0) != nil } }) != true {
            state.next = nil
            let taken = Set(state.recent + [state.shown?.id].compactMap { $0 })
            var options = pool.filter { !taken.contains($0.id) }.shuffled()
            if options.isEmpty { options = pool.filter { $0.id != state.shown?.id }.shuffled() }
            // A few tries: a title with no backdrop is passed over.
            for item in options.prefix(5) {
                guard let url = await TMDBService.backdrop(id: item.id, type: item.type) else { continue }
                var ok = true
                for mode in Mode.allCases where !(await draw(url, mode: mode)) { ok = false }
                if ok { state.next = Entry(id: item.id, name: item.name, url: url); break }
            }
        }
        // Only what's up, the next and the saved stay on disk.
        let files = FileManager.default
        var keep = Set<String>()
        for entry in [state.shown, state.next].compactMap({ $0 }) + savedEntries {
            for mode in Mode.allCases { keep.insert(Self.file(for: entry.url, mode: mode).lastPathComponent) }
        }
        for name in (try? files.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        where name.hasSuffix(".png") && !keep.contains(name) {
            try? files.removeItem(at: Self.folder.appendingPathComponent(name))
        }
        save()
    }
}

/// DETAILS' BACKGROUND: its picture's colours as bands, as the app's
/// background (`BandsPicture.pools`) but stronger — dark, the same grey
/// with more of the title's colour; light, a deeper tint (`liftedStrong`) — the title's
/// flavour on its page (Details is the billboard's card opened: without it
/// it read as Home). Drawn when focus rests on a title (`TitlePictures`),
/// kept in memory for the last few; the opening and Details draw the same
/// image, so the hand-over can't show.
@MainActor
final class TitleBands {
    static let shared = TitleBands()
    private static let kept = 6

    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private var working: [String: Task<UIImage?, Never>] = [:]

    /// `saturation`: other than Details' (the play stage's).
    private static func key(_ url: String, _ saturation: Double?) -> String {
        url + (BackgroundPicks.Mode.now == .light ? "#light" : "") + (saturation.map { "#s\($0)" } ?? "")
    }

    func cached(_ url: String?, saturation: Double? = nil) -> UIImage? {
        url.flatMap { images[Self.key($0, saturation)] }
    }

    /// Each picture's colours (a few numbers), for many more titles than
    /// the drawings kept: the press only renders (`image`). Worked out as
    /// a picture is decoded at the screen's size (`ImageCache.preload`).
    private var palettes: [String: [BandsPicture.Colour]] = [:]
    private var paletteOrder: [String] = []
    private static let palettesKept = 300

    /// The colours worked out ahead from a decoded picture.
    func prepare(_ url: String, from picture: CGImage) async {
        guard palettes[url] == nil else { return }
        let palette = await Task.detached(priority: .utility) {
            Self.shrunk(picture, to: 160).map { BandsPicture.palette($0) }
        }.value
        if let palette { keep(palette, for: url) }
    }

    private func keep(_ palette: [BandsPicture.Colour], for url: String) {
        if palettes[url] == nil { paletteOrder.append(url) }
        palettes[url] = palette
        while paletteOrder.count > Self.palettesKept { palettes[paletteOrder.removeFirst()] = nil }
    }

    /// The picture's colours: known, else from the picture decoded for
    /// the screen (Details' opening waits on it: no download first, it
    /// came seconds late at times), else from TMDB's small copy.
    func palette(for url: String) async -> [BandsPicture.Colour]? {
        if let known = palettes[url] { return known }
        let decoded = ImageCache.shared.image(for: RemoteImage.memoryKey(url, maxDimension: PictureSize.screen,
                                                                        maxPixels: nil))?.cgImage
        var data: Data?
        if decoded == nil {
            let small = url.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")
            guard let remote = URL(string: small),
                  let downloaded = try? await ImageCache.shared.download(remote) else { return nil }
            data = downloaded
        }
        let palette = await Task.detached(priority: .userInitiated) { () -> [BandsPicture.Colour]? in
            guard let source = decoded.flatMap({ Self.shrunk($0, to: 160) })
                    ?? data.flatMap({ ImageCache.decodeDownsampled($0, budget: 160)?.cgImage })
            else { return nil }
            return BandsPicture.palette(source)
        }.value
        if let palette { keep(palette, for: url) }
        return palette
    }

    /// Drawn (or being drawn) for `url`; nil if it can't be.
    @discardableResult
    func image(for url: String, saturation: Double? = nil) async -> UIImage? {
        let key = Self.key(url, saturation)
        if let image = images[key] { return image }
        if let task = working[key] { return await task.value }
        let light = BackgroundPicks.Mode.now == .light
        let seed = BackgroundPicks.seed(url)
        let task = Task<UIImage?, Never> {
            guard let palette = await self.palette(for: url) else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let bands = BandsPicture.pools(from: palette, light: light, strong: true,
                                                     saturation: saturation,
                                                     seed: seed),
                      let picture = BandsPicture.render(base: bands.base, pools: bands.pools)
                else { return nil }
                return UIImage(cgImage: picture).preparingForDisplay()
            }.value
        }
        working[key] = task
        let image = await task.value
        working[key] = nil
        if let image {
            images[key] = image
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > Self.kept { images[order.removeFirst()] = nil }
        }
        return image
    }

    /// A decoded picture drawn small (its longest side `side` pixels).
    nonisolated static func shrunk(_ image: CGImage, to side: Int) -> CGImage? {
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}

/// Details' background: its title's bands (`TitleBands`), faded in if
/// they come late; until then the app's.
struct TitleBandsBackground: View {
    let url: String?
    /// Other than Details' (the play stage's); until drawn, Details' own.
    var saturation: Double? = nil
    @State private var image: UIImage?

    init(url: String?, saturation: Double? = nil) {
        self.url = url
        self.saturation = saturation
        _image = State(initialValue: TitleBands.shared.cached(url, saturation: saturation)
                       ?? (saturation == nil ? nil : TitleBands.shared.cached(url)))
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Motion.fadeDuration), value: image)
        .task(id: url ?? "") {
            guard let url else { image = nil; return }
            if let known = TitleBands.shared.cached(url, saturation: saturation) { image = known; return }
            image = await TitleBands.shared.image(for: url, saturation: saturation)
        }
    }
}

/// The app's background, behind every screen (`BackgroundStore`).
struct ATVBackground: View {
    @ObservedObject private var picture = BackgroundStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Also the launch screen's; light: tvOS's light grey.
            scheme == .light ? Color(white: 0.68) : Color("AppBackground")
            if let image = picture.image {
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Motion.fadeDuration), value: picture.image)
        .ignoresSafeArea()
        .onAppear {
            picture.load()
            ModeChangeCover.shared.install()
        }
        .onChange(of: scheme) { _, _ in picture.modeChanged() }
    }
}

/// tvOS's appearance changing (light to dark or back, mostly found on
/// coming back to the app): a still of the screen as it was goes over
/// everything at once, the pages, their text and the background change
/// under it, and once the new background is in it dissolves away (0.5 s),
/// one crossfade from the old look to the new. Before, the screen stood
/// while every page re-rendered, the text changed, then the background
/// faded in after.
@MainActor
final class ModeChangeCover {
    static let shared = ModeChangeCover()
    private weak var window: UIWindow?
    private var cover: UIView?
    private var watch: AnyCancellable?
    private var fallback: DispatchWorkItem?
    private var returning: NSObjectProtocol?

    /// Once a window is up (the background's first appearance).
    func install() {
        guard window == nil, let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        self.window = window
        window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindow, _: UITraitCollection) in
            self?.changed()
        }
    }

    private func changed() {
        guard let window, cover == nil,
              let still = window.snapshotView(afterScreenUpdates: false) else { return }
        still.frame = window.bounds
        still.isUserInteractionEnabled = false
        window.addSubview(still)
        cover = still
        AppProbe.life("appearance → \(BackgroundPicks.Mode.now), app \(UIApplication.shared.applicationState == .active ? "in front" : "away")")
        // The new mode's background published: lifted once it's drawn
        // (its own fade under the still runs out first). With nothing to
        // redraw (no title up), lifted after a moment anyway.
        watch = BackgroundStore.shared.$image.dropFirst().first().sink { [weak self] _ in
            self?.lift(after: Motion.fadeDuration + 0.05)
        }
        // The new background at once, under the still, with the text
        // (`BackgroundStore.modeChanged`: ready ahead, else drawn).
        BackgroundStore.shared.modeChanged()
        let item = DispatchWorkItem { [weak self] in self?.lift(after: 0) }
        fallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func lift(after delay: TimeInterval) {
        watch = nil
        fallback?.cancel()
        fallback = nil
        guard let still = cover else { return }
        // Changed while away: the crossfade once Cue is in front again.
        guard UIApplication.shared.applicationState == .active else {
            if returning == nil {
                returning = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let returning = self.returning { NotificationCenter.default.removeObserver(returning) }
                        self.returning = nil
                        self.lift(after: 0.3)
                    }
                }
            }
            return
        }
        cover = nil
        UIView.animate(withDuration: 0.5, delay: delay, options: [.curveEaseInOut, .beginFromCurrentState]) {
            still.alpha = 0
        } completion: { _ in
            still.removeFromSuperview()
        }
    }
}

// MARK: - Background preview (a developer tool)

/// A title's background alone, full screen, its values changed on the fly
/// (a card's hold menu, Background Preview): to see what makes a good one.
/// Three methods: Pools (the app's), Picture (the blurred backdrop, tvOS's
/// way) and Tinted (one neutral backdrop for every title, tinted by it). A dark plate of rows (Up/Down a row, Left/Right its value), Select
/// hides and shows it (hidden, Left/Right another layout, or the picture
/// mirrored), Back closes. The values
/// carry to the next title opened this run (Reset puts the app's back); the
/// app itself always draws with `BandsPicture.Tuning()`.
@MainActor
final class BackgroundPreview: UIViewController {
    static func open(_ item: MetaItem) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top, !(top is BackgroundPreview) else { return }
        top.present(BackgroundPreview(item: item), animated: false)
    }

    /// Kept for the run: the next title opens on the same values.
    private static var tuning = BandsPicture.Tuning()
    private static var light = BackgroundPicks.Mode.now == .light
    private static let methods: [BandsPicture.Tuning.Method] = [.backdrop, .pools, .picture, .tinted]
    private static var tintedDefaults: BandsPicture.Tuning {
        var t = BandsPicture.Tuning()
        t.method = .tinted
        return t
    }

    private let item: MetaItem
    private var palette: [BandsPicture.Colour]?
    private var url: String?
    /// The backdrop, small (the Picture method draws from it).
    private var backdrop: CGImage?
    private let picture = UIImageView()
    private let plate = UIView()
    private let header = UILabel()
    private let swatches = UIStackView()
    private let source = UIImageView()
    private let list = UIStackView()
    private var selected = 0
    private var generation = 0

    init(item: MetaItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rows

    private struct Row {
        let name: String
        let value: (BandsPicture.Tuning, Bool) -> String
        /// One step either way (-1, +1).
        let step: (inout BandsPicture.Tuning, inout Bool, Int) -> Void
    }

    private static func levels(_ v: CGFloat) -> String { String(format: "%.3f  (%d)", v, Int((v * 255).rounded())) }
    private static func range(_ r: ClosedRange<CGFloat>) -> String {
        String(format: "%.3f–%.3f  (%d–%d)", r.lowerBound, r.upperBound,
               Int((r.lowerBound * 255).rounded()), Int((r.upperBound * 255).rounded()))
    }
    private static func shifted(_ r: ClosedRange<CGFloat>, _ d: CGFloat) -> ClosedRange<CGFloat> {
        let lo = max(0, r.lowerBound + d)
        return lo...max(lo, r.upperBound + d)
    }

    /// Every method's rows, then In the App: Right puts this title up as
    /// the background with these values (for this run, `BandsPicture.trial`),
    /// Left gives the app its own back.
    private var rows: [Row] {
        methodRows + [Row(name: "In the App", value: { t, _ in
            guard let trial = BandsPicture.trial else { return "The app's own" }
            return trial == t ? "These values" : "Earlier values"
        }, step: { [item] t, _, d in
            if d > 0 {
                BandsPicture.trial = t
                BandsPicture.trialTag += 1
                BackgroundStore.shared.use(item)
            } else if BandsPicture.trial != nil {
                BandsPicture.trial = nil
                BackgroundStore.shared.redraw()
            }
        })]
    }

    private var methodRows: [Row] {
        var rows = [
            Row(name: "Method", value: { t, _ in ["Backdrop", "Pools", "Picture", "Tinted"][Self.methods.firstIndex(of: t.method)!] },
                step: { t, _, d in
                    let i = Self.methods.firstIndex(of: t.method)!
                    t.method = Self.methods[(i + d + Self.methods.count) % Self.methods.count] }),
            Row(name: "Appearance", value: { $1 ? "Light" : "Dark" }, step: { _, light, _ in light.toggle() }),
        ]
        if Self.tuning.method == .backdrop {
            func level(_ name: String, _ path: WritableKeyPath<BandsPicture.Levels, CGFloat>) -> Row {
                Row(name: name, value: { t, l in Self.levels((l ? t.lightLevels : t.darkLevels)[keyPath: path]) },
                    step: { t, l, d in
                        let v = (l ? 0.01 : 0.005) * CGFloat(d)
                        if l { t.lightLevels[keyPath: path] = min(1, max(0, t.lightLevels[keyPath: path] + v)) }
                        else { t.darkLevels[keyPath: path] = min(1, max(0, t.darkLevels[keyPath: path] + v)) } })
            }
            rows += [
                Row(name: "Band Colour", value: { t, l in Self.levels(l ? t.lightBandColour : t.darkBandColour) },
                    step: { t, l, d in
                        if l { t.lightBandColour = max(0, t.lightBandColour + 0.01 * CGFloat(d)) }
                        else { t.darkBandColour = max(0, t.darkBandColour + 0.005 * CGFloat(d)) } }),
                Row(name: "Mass Colour", value: { t, l in Self.levels(l ? t.lightMassColour : t.darkMassColour) },
                    step: { t, l, d in
                        if l { t.lightMassColour = max(0, t.lightMassColour + 0.01 * CGFloat(d)) }
                        else { t.darkMassColour = max(0, t.darkMassColour + 0.005 * CGFloat(d)) } }),
                level("Band Light", \.band),
                level("Middle", \.middle),
                level("Mass Light", \.mass),
                level("Lightest", \.lightest),
                level("Darkest", \.darkest),
                Row(name: "Blur", value: { t, _ in String(format: "%.0f", t.backdropBlur) },
                    step: { t, _, d in t.backdropBlur = max(0, t.backdropBlur + 10 * CGFloat(d)) }),
                Row(name: "Layout", value: { t, _ in t.layout == 0 ? "The title's" : "+\(t.layout)" },
                    step: { t, _, d in t.layout = d < 0 && t.layout == 0 ? 0 : t.layout &+ UInt64(bitPattern: Int64(d)) }),
                Row(name: "Reset", value: { t, _ in t == BandsPicture.Tuning() ? "The app's values" : "Changed" },
                    step: { t, _, _ in t = BandsPicture.Tuning() }),
            ]
            return rows
        }
        if Self.tuning.method == .tinted {
            func shown(_ r: ClosedRange<CGFloat>) -> String { Self.range(r) }
            rows += [
                Row(name: "Base", value: { t, l in Self.levels(l ? t.lightBase : t.darkBase) },
                    step: { t, l, d in
                        if l { t.lightBase = max(0, t.lightBase + 0.01 * CGFloat(d)) }
                        else { t.darkBase = max(0, t.darkBase + 0.005 * CGFloat(d)) } }),
                Row(name: "Lighter", value: { t, l in shown(l ? t.lightLighter : t.darkLighter) },
                    step: { t, l, d in
                        if l { t.lightLighter = Self.shifted(t.lightLighter, 0.01 * CGFloat(d)) }
                        else { t.darkLighter = Self.shifted(t.darkLighter, 0.01 * CGFloat(d)) } }),
                Row(name: "Darker", value: { t, l in shown(l ? t.lightDarker : t.darkDarker) },
                    step: { t, l, d in
                        if l { t.lightDarker = Self.shifted(t.lightDarker, 0.01 * CGFloat(d)) }
                        else { t.darkDarker = Self.shifted(t.darkDarker, 0.005 * CGFloat(d)) } }),
                Row(name: "Tint", value: { t, l in Self.levels(l ? t.lightTintAmount : t.darkTintAmount) },
                    step: { t, l, d in
                        if l { t.lightTintAmount = max(0, t.lightTintAmount + 0.01 * CGFloat(d)) }
                        else { t.darkTintAmount = max(0, t.darkTintAmount + 0.005 * CGFloat(d)) } }),
                Row(name: "In the Darker", value: { t, _ in String(format: "%.0f %%", t.tintSpread * 100) },
                    step: { t, _, d in t.tintSpread = min(1, max(0, t.tintSpread + 0.1 * CGFloat(d))) }),
                Row(name: "Blur", value: { t, _ in String(format: "%.0f", t.blur) },
                    step: { t, _, d in t.blur = max(0, t.blur + 10 * CGFloat(d)) }),
                Row(name: "Shape", value: { t, _ in "\(t.layout + 1)" },
                    step: { t, _, d in t.layout = d < 0 && t.layout == 0 ? 0 : t.layout &+ UInt64(bitPattern: Int64(d)) }),
                Row(name: "Reset", value: { t, _ in t == Self.tintedDefaults ? "The defaults" : "Changed" },
                    step: { t, _, _ in t = Self.tintedDefaults }),
            ]
            return rows
        }
        if Self.tuning.method == .picture {
            func bound(_ t: BandsPicture.Tuning, _ light: Bool, high: Bool) -> String {
                let r = light ? t.lightRange : t.darkRange
                return Self.levels(high ? r.upperBound : r.lowerBound)
            }
            func move(_ t: inout BandsPicture.Tuning, _ light: Bool, high: Bool, _ d: Int) {
                var r = light ? t.lightRange : t.darkRange
                let v = 0.01 * CGFloat(d)
                r = high ? r.lowerBound...min(1, max(r.lowerBound, r.upperBound + v))
                         : max(0, min(r.upperBound, r.lowerBound + v))...r.upperBound
                if light { t.lightRange = r } else { t.darkRange = r }
            }
            rows += [
                Row(name: "Blur", value: { t, _ in String(format: "%.0f %% of the width", t.pictureBlur * 100) },
                    step: { t, _, d in t.pictureBlur = max(0, t.pictureBlur + 0.01 * CGFloat(d)) }),
                Row(name: "Darkest", value: { t, l in bound(t, l, high: false) },
                    step: { t, l, d in move(&t, l, high: false, d) }),
                Row(name: "Lightest", value: { t, l in bound(t, l, high: true) },
                    step: { t, l, d in move(&t, l, high: true, d) }),
                Row(name: "Colour", value: { t, _ in String(format: "%.1f×", t.pictureColour) },
                    step: { t, _, d in t.pictureColour = max(0, t.pictureColour + 0.1 * CGFloat(d)) }),
                Row(name: "Ceiling", value: { t, l in Self.levels(l ? t.lightCeiling : t.darkCeiling) },
                    step: { t, l, d in
                        if l { t.lightCeiling = max(0, t.lightCeiling + 0.01 * CGFloat(d)) }
                        else { t.darkCeiling = max(0, t.darkCeiling + 0.005 * CGFloat(d)) } }),
                Row(name: "Mirror", value: { t, _ in t.mirror ? "On" : "Off" }, step: { t, _, _ in t.mirror.toggle() }),
                Row(name: "Reset", value: { _, _ in "The defaults" },
                    step: { t, _, _ in t = BandsPicture.Tuning(); t.method = .picture }),
            ]
            return rows
        }
        if Self.light {
            rows += [
                Row(name: "Saturation", value: { t, _ in String(format: "%.2f×", t.saturation) },
                    step: { t, _, d in t.saturation = max(0, t.saturation + 0.1 * Double(d)) }),
                Row(name: "Tint", value: { t, _ in Self.levels(t.lightTint) },
                    step: { t, _, d in t.lightTint = max(0, t.lightTint + 0.005 * CGFloat(d)) }),
                Row(name: "Lift Low", value: { t, _ in String(format: "%.2f", t.liftLow) },
                    step: { t, _, d in t.liftLow = min(t.liftHigh, max(0, t.liftLow + 0.02 * Double(d))) }),
                Row(name: "Lift High", value: { t, _ in String(format: "%.2f", t.liftHigh) },
                    step: { t, _, d in t.liftHigh = min(1, max(t.liftLow, t.liftHigh + 0.02 * Double(d))) }),
                Row(name: "Base Colour", value: { t, _ in String(format: "%.0f %%", t.baseColour * 100) },
                    step: { t, _, d in t.baseColour = min(1, max(0, t.baseColour + 0.1 * Double(d))) }),
                Row(name: "Base Light", value: { t, _ in t.baseLight.map { Self.levels($0) } ?? "The picture's" },
                    step: { t, _, d in
                        guard let v = t.baseLight else { t.baseLight = 0.78; return }
                        let next = v + 0.01 * CGFloat(d)
                        t.baseLight = next < 0.5 ? nil : min(1, next) }),
                Row(name: "Colour Target", value: { [palette] t, _ in
                        let amount = palette.map { BandsPicture.colourAmount($0, t) } ?? 0
                        guard let target = t.colourTarget else { return String(format: "Off (here %.3f)", amount) }
                        let gain = palette.map { BandsPicture.colourGain($0, t) } ?? 1
                        return String(format: "%.3f · %.1f× (here %.3f)", target, gain, amount) },
                    step: { [palette] t, _, d in
                        guard let target = t.colourTarget else {
                            t.colourTarget = palette.map { BandsPicture.colourAmount($0, t) } ?? 0.02
                            return
                        }
                        let next = target + 0.002 * Double(d)
                        t.colourTarget = next <= 0 ? nil : next }),
                Row(name: "Least Gain", value: { t, _ in String(format: "%.1f×", t.gainLimits.lowerBound) },
                    step: { t, _, d in
                        let lo = min(t.gainLimits.upperBound, max(0.1, t.gainLimits.lowerBound + 0.1 * Double(d)))
                        t.gainLimits = lo...t.gainLimits.upperBound }),
                Row(name: "Most Gain", value: { t, _ in String(format: "%.1f×", t.gainLimits.upperBound) },
                    step: { t, _, d in
                        let hi = max(t.gainLimits.lowerBound, t.gainLimits.upperBound + 0.5 * Double(d))
                        t.gainLimits = t.gainLimits.lowerBound...hi }),
            ]
        } else {
            rows += [
                Row(name: "Base", value: { t, _ in Self.levels(t.darkBase) },
                    step: { t, _, d in t.darkBase = max(0, t.darkBase + 0.005 * CGFloat(d)) }),
                Row(name: "Lighter", value: { t, _ in Self.range(t.darkLighter) },
                    step: { t, _, d in t.darkLighter = Self.shifted(t.darkLighter, 0.01 * CGFloat(d)) }),
                Row(name: "Darker", value: { t, _ in Self.range(t.darkDarker) },
                    step: { t, _, d in t.darkDarker = Self.shifted(t.darkDarker, 0.005 * CGFloat(d)) }),
                Row(name: "Spot Light", value: { t, _ in Self.levels(t.spotLight) },
                    step: { t, _, d in t.spotLight = max(0, t.spotLight + 0.01 * CGFloat(d)) }),
                Row(name: "Colour", value: { t, _ in Self.levels(t.spotColour) },
                    step: { t, _, d in t.spotColour = max(0, t.spotColour + 0.005 * CGFloat(d)) }),
                Row(name: "Spots", value: { t, _ in "\(t.spots)" },
                    step: { t, _, d in t.spots = min(4, max(0, t.spots + d)) }),
                Row(name: "Spot Width", value: { t, _ in String(format: "%.2f–%.2f", t.spotWidth.lowerBound, t.spotWidth.upperBound) },
                    step: { t, _, d in t.spotWidth = Self.shifted(t.spotWidth, 0.02 * CGFloat(d)) }),
                Row(name: "Spot Height", value: { t, _ in String(format: "%.2f–%.2f", t.spotHeight.lowerBound, t.spotHeight.upperBound) },
                    step: { t, _, d in t.spotHeight = Self.shifted(t.spotHeight, 0.04 * CGFloat(d)) }),
            ]
        }
        rows += [
            Row(name: "Blur", value: { t, _ in String(format: "%.0f", t.blur) },
                step: { t, _, d in t.blur = max(0, t.blur + 10 * CGFloat(d)) }),
            Row(name: "Layout", value: { t, _ in t.layout == 0 ? "The title's" : "+\(t.layout)" },
                step: { t, _, d in t.layout = d < 0 && t.layout == 0 ? 0 : t.layout &+ UInt64(bitPattern: Int64(d)) }),
            Row(name: "Reset", value: { _, _ in "The defaults" },
                step: { t, _, _ in t = BandsPicture.Tuning(); t.method = .pools }),
        ]
        return rows
    }

    // MARK: Screen

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        picture.frame = view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picture.contentMode = .scaleToFill
        view.addSubview(picture)

        plate.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        plate.layer.cornerRadius = 32
        plate.layer.cornerCurve = .continuous
        view.addSubview(plate)

        header.font = .systemFont(ofSize: 29, weight: .semibold)
        header.textColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        header.text = item.name
        swatches.axis = .horizontal
        swatches.spacing = 8
        swatches.distribution = .fillEqually
        source.contentMode = .scaleAspectFill
        source.clipsToBounds = true
        source.layer.cornerRadius = 12
        source.layer.cornerCurve = .continuous
        list.axis = .vertical
        list.spacing = 2
        let stack = UIStackView(arrangedSubviews: [header, source, swatches, list])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(10, after: source)
        stack.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(stack)
        plate.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plate.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60),
            plate.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
            plate.widthAnchor.constraint(equalToConstant: 620),
            stack.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: plate.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -28),
            source.heightAnchor.constraint(equalToConstant: 150),
            swatches.heightAnchor.constraint(equalToConstant: 44),
        ])
        drawRows()
        Task { await load() }
    }

    private func load() async {
        guard let url = await TMDBService.backdrop(id: item.id, type: item.type) else {
            header.text = "\(item.name): no backdrop"
            return
        }
        self.url = url
        palette = await TitleBands.shared.palette(for: url)
        drawSwatches()
        render()
        let small = url.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")
        if let remote = URL(string: small), let data = try? await ImageCache.shared.download(remote) {
            source.image = UIImage(data: data)
            backdrop = source.image?.cgImage
            if Self.tuning.method == .picture { render() }
        }
    }

    /// The palette as the drawing reads it: darkest first, each with its
    /// share; under it the hue's strength (a channel's most from its grey).
    private func drawSwatches() {
        swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for c in palette ?? [] {
            let swatch = UIView()
            swatch.backgroundColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            swatch.layer.cornerRadius = 8
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let chroma = max(abs(c.r - y), abs(c.g - y), abs(c.b - y))
            let label = UILabel()
            label.text = String(format: "%.0f%% · %.2f", c.share * 100, chroma)
            label.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
            label.textColor = y > 0.55 ? .black : .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            swatch.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: swatch.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: swatch.centerYAnchor),
            ])
            swatches.addArrangedSubview(swatch)
        }
    }

    private func drawRows() {
        let rows = rows
        selected = min(selected, rows.count - 1)
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, row) in rows.enumerated() {
            let on = i == selected
            let line = UIView()
            line.backgroundColor = on ? UIColor.white : .clear
            line.layer.cornerRadius = 12
            line.layer.cornerCurve = .continuous
            let name = UILabel(), value = UILabel()
            name.text = row.name
            name.font = .systemFont(ofSize: 24, weight: .medium)
            value.text = (on ? "‹  " : "") + row.value(Self.tuning, Self.light) + (on ? "  ›" : "")
            value.font = .monospacedDigitSystemFont(ofSize: 24, weight: .regular)
            value.textAlignment = .right
            let ink = on ? UIColor.black : UIColor.white.withAlphaComponent(FixedFocusText.body)
            name.textColor = ink
            value.textColor = ink
            let pair = UIStackView(arrangedSubviews: [name, value])
            pair.translatesAutoresizingMaskIntoConstraints = false
            line.addSubview(pair)
            NSLayoutConstraint.activate([
                pair.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 16),
                pair.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -16),
                pair.topAnchor.constraint(equalTo: line.topAnchor, constant: 5),
                pair.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: -5),
            ])
            list.addArrangedSubview(line)
        }
    }

    /// Drawn off the main thread; a newer change wins.
    private func render() {
        guard let palette, let url else { return }
        generation += 1
        let mine = generation
        let (tuning, light, seed, backdrop) = (Self.tuning, Self.light, BackgroundPicks.seed(url), backdrop)
        if tuning.method == .picture, backdrop == nil { return }
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                BandsPicture.drawing(palette: palette, backdrop: backdrop, light: light, seed: seed, tuning: tuning)
                    .map { UIImage(cgImage: $0) }
            }.value
            guard mine == generation, let image else { return }
            picture.image = image
        }
    }

    private func change(_ d: Int) {
        let rows = rows
        rows[selected].step(&Self.tuning, &Self.light, d)
        drawRows()
        render()
    }

    // MARK: Presses

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [] }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return }
        let shown = plate.alpha > 0
        switch press.type {
        case .menu:
            dismiss(animated: false)
        case .select, .playPause:
            UIView.animate(withDuration: Motion.fadeDuration) { self.plate.alpha = shown ? 0 : 1 }
        case .upArrow where shown:
            selected = max(0, selected - 1); drawRows()
        case .downArrow where shown:
            selected = min(rows.count - 1, selected + 1); drawRows()
        case .leftArrow, .rightArrow:
            let d = press.type == .leftArrow ? -1 : 1
            if shown { change(d) } else if Self.tuning.method == .picture {
                Self.tuning.mirror.toggle()
                drawRows()
                render()
            } else {
                Self.tuning.layout = d < 0 && Self.tuning.layout == 0 ? 0 : Self.tuning.layout &+ UInt64(bitPattern: Int64(d))
                drawRows()
                render()
            }
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    // Swallowed: the page under it never sees them.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
}
