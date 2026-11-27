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

    /// The grain's full range (sRGB, 0–1): up to ±1 level of 255, a
    /// dither only, enough to break the dark gradients' steps (±3 was
    /// seen on the TV: drawn at 1080p, each grain a 2 × 2 dot on the 4K
    /// panel; decided 2026-11-27: not to be noticed at all).
    static let grain: CGFloat = 2.0 / 255
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

    /// A colour's channel for light mode (the grey picture's): toward
    /// tvOS's light grey — 0 lands at 62 %, 1 at 90 %.
    static func lifted(_ v: Double) -> CGFloat { CGFloat(0.62 + 0.28 * v) }

    /// The Backdrop's values, in one place so the background preview
    /// (`BackgroundPreview`, a card's hold menu) can change them on the
    /// fly; the app draws with the defaults.
    ///
    /// Backdrop (2026-11-27): tvOS's own backdrop, measured off its
    /// Photos screens (dark and light share one shape): a coloured band, a
    /// neutral middle, a darker coloured mass, the lightest and the darkest
    /// apart at the edges (`compositions`). The title's first hue in the
    /// band, its second in the mass, at a set strength (`…BandColour`,
    /// `…MassColour`: a channel's most from its grey, tvOS's ~0.12 in
    /// light, ~0.05 in dark); its lightness tvOS's (`Levels`). (Tried the
    /// same day and dropped: the title's colours as pools at their own
    /// saturation, the darkest the base: Barbie's maroon everywhere, a dull
    /// picture grey, capped, the colour gone; the same with a quieter base
    /// and one colour amount for every title; spots on a neutral grey; the
    /// backdrop itself blurred, its lightness pressed into tvOS's band;
    /// one neutral backdrop tinted by the title.)
    struct Tuning: Equatable {
        var lightLevels = Levels(band: 0.90, middle: 0.85, mass: 0.73, lightest: 0.97, darkest: 0.77)
        var darkLevels = Levels(band: 0.205, middle: 0.195, mass: 0.12, lightest: 0.225, darkest: 0.11)
        var lightBandColour: CGFloat = 0.12
        var lightMassColour: CGFloat = 0.12
        var darkBandColour: CGFloat = 0.055
        var darkMassColour: CGFloat = 0.045
        var backdropBlur: CGFloat = 90
        /// Added to the seed: another shape of the same colours.
        var layout: UInt64 = 0
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
            light ? (v, v, v) : (v + lean.r, v + lean.g, v + lean.b)
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
        // Orange and skin (10°–55°: faces, lamps, fire, most films'
        // backdrops) count for less: every background came out warm. A
        // title's blue, teal, green or purple wins where it has one; a
        // clearly orange title still gets its orange.
        func pull(_ angle: Double) -> Double {
            let degrees = angle * 180 / .pi
            return (10...55).contains(degrees) ? 0.4 : 1
        }
        typealias Hue = (d: SIMD3<Double>, chroma: Double, angle: Double, share: Double)
        let hues: [Hue] = palette.compactMap { c in
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let d = SIMD3(c.r - y, c.g - y, c.b - y)
            let chroma = max(abs(d.x), abs(d.y), abs(d.z))
            guard chroma >= hueFloor else { return nil }
            return (d / chroma, chroma, atan2(sqrt(3) * (c.g - c.b), 2 * c.r - c.g - c.b), c.share)
        }.sorted { $0.chroma * $0.share.squareRoot() * pull($0.angle) > $1.chroma * $1.share.squareRoot() * pull($1.angle) }
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

    /// Details' and the stage's spots, dark: stronger (closer to the film).
    static let detailsSpot: CGFloat = 0.09
    static let stageSpot: CGFloat = 0.115
    /// A palette colour this far from its grey (a channel) has a hue;
    /// greyer ones give no spot (a grey picture: grey areas only).
    static let hueFloor = 0.035
    /// Dark's grey leans a little cool whatever the title, its lightness
    /// about kept: half Apple TV's Home (measured 2026-11-27: its neutral
    /// areas blue ~4 levels over red). A warm lean (from its Search page,
    /// red ~4 over blue) made every background warm grey with the titles'
    /// mostly orange hues on top: overwhelming beside Apple TV's.
    static let lean: (r: CGFloat, g: CGFloat, b: CGFloat) = (-0.006, 0.001, 0.006)
    /// Details' (`TitleBands`): the picture's colour stronger over the grey
    /// — 0 lands at 50 %, 1 at 92 %.
    static func liftedStrong(_ v: Double, darker: Double = 1) -> CGFloat {
        CGFloat((0.50 + 0.42 * v) * (1 - (1 - darker) * 0.4))
    }

    /// Draws pools of colour on a base (Core Image on the GPU, the grain on
    /// the CPU).
    static func render(base: (CGFloat, CGFloat, CGFloat), pools: [Pool], blur: CGFloat = 60) -> CGImage? {
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

    /// Details' and the play stage's background (`TitleBands`): a
    /// picture's colours as pools in a layout of their own (`seed`: the
    /// same picture, the same layout). Dark: `darkPools`. Light: the
    /// darkest the base, the rest spread across the screen at random, each
    /// colour by its share, its saturation pushed out (`strongSaturation`,
    /// the stage's `chosen`), lifted (`liftedStrong`).
    static func pools(from palette: [(r: Double, g: Double, b: Double, share: Double)],
                      light: Bool = false, saturation chosen: Double? = nil,
                      seed: UInt64) -> (base: (CGFloat, CGFloat, CGFloat), pools: [Pool])? {
        guard light else {
            return darkPools(from: palette, seed: seed, spot: chosen != nil ? stageSpot : detailsSpot)
        }
        guard let darkest = palette.first else { return nil }
        func shaded(_ c: (r: Double, g: Double, b: Double, share: Double), _ extra: Double = 1) -> (CGFloat, CGFloat, CGFloat) {
            // The picture's hues pushed out from its grey (k-means averages
            // and the blur pull them toward grey).
            var c = c
            let saturation = chosen ?? Self.strongSaturation
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            func out(_ v: Double) -> Double { min(1, max(0, y + (v - y) * saturation)) }
            (c.r, c.g, c.b) = (out(c.r), out(c.g), out(c.b))
            return (liftedStrong(c.r, darker: extra), liftedStrong(c.g, darker: extra), liftedStrong(c.b, darker: extra))
        }
        var random = SeededRandom(seed: seed)
        let colours = palette.count > 1 ? Array(palette.dropFirst()) : palette
        let total = colours.reduce(0) { $0 + $1.share }
        func pick() -> (r: Double, g: Double, b: Double, share: Double) {
            guard total > 0 else { return colours[0] }
            var roll = Double.random(in: 0..<total, using: &random)
            for c in colours { roll -= c.share; if roll < 0 { return c } }
            return colours[colours.count - 1]
        }
        // Spread across the width (one per column, placed at random in it),
        // anywhere up and down, of mixed sizes; a few of the base's own
        // colour between them for dark bands.
        let count = poolCount
        let pools = (0..<count).map { i -> Pool in
            let colour = i % 3 == 2 ? shaded(darkest, 0.8) : shaded(pick())
            return Pool(r: colour.0, g: colour.1, b: colour.2,
                        x: (CGFloat(i) + .random(in: 0.1...0.9, using: &random)) / CGFloat(count),
                        y: .random(in: 0...1, using: &random),
                        rx: .random(in: 0.14...0.30, using: &random),
                        ry: .random(in: 0.35...0.80, using: &random))
        }.shuffled(using: &random)
        return (shaded(darkest, 0.85), pools)
    }

    /// Details' and the stage's dark: a neutral grey (0.125), lighter and
    /// darker areas over it (0.21–0.26, ~0.10), and the picture's hues in
    /// two spots (lifted to 0.21), each at the same strength (`spot`)
    /// whatever the picture's own. The screen as six cells, three across
    /// and two down, each area in a cell of its own so they don't pile up.
    static func darkPools(from palette: [Colour], seed: UInt64, spot: CGFloat)
        -> (base: (CGFloat, CGFloat, CGFloat), pools: [Pool])? {
        guard !palette.isEmpty else { return nil }
        func grey(_ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) { (v + lean.r, v + lean.g, v + lean.b) }
        let chosen = hues(palette, count: 2)

        var random = SeededRandom(seed: seed)
        var cells = (0..<6).map { (col: $0 % 3, row: $0 / 3) }.shuffled(using: &random)
        // The spots in different columns.
        if chosen.count > 1, let other = cells.dropFirst().firstIndex(where: { $0.col != cells[0].col }) {
            cells.swapAt(1, other)
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
            let v = i % 2 == 0 ? CGFloat.random(in: 0.21...0.26, using: &random)
                               : .random(in: 0.095...0.105, using: &random)
            pools.append(place(cell, rx: 0.18...0.28, ry: 0.40...0.70, grey(v)))
        }
        for (i, hue) in chosen.enumerated() {
            let d = hue * Double(spot)
            let c = grey(0.21)
            pools.append(place(cells[i], rx: i == 0 ? 0.24...0.32 : 0.18...0.26,
                               ry: i == 0 ? 0.55...0.75 : 0.45...0.65,
                               (max(0, c.0 + d.x), max(0, c.1 + d.y), max(0, c.2 + d.z))))
        }
        return (grey(0.125), pools)
    }

    private static let poolCount = 8
    /// Details' colours' saturation, light, times the picture's (1.8 was
    /// too colourful on an OLED with tvOS in Dolby Vision, which lifts
    /// colour far more than light).
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
        guard !loading, changing != now else { return }
        changing = now
        AppProbe.life("background → \(now), drawn now")
        Task {
            let pick = await BackgroundPicks.shared.current()
            await show(pick, fade: true)
            changing = nil
        }
    }
    /// The mode a redraw is under way for: tvOS flips the mode back and
    /// forth for its snapshots as the app goes away; one redraw each.
    private var changing: BackgroundPicks.Mode?

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
        folder.appendingPathComponent("bands19-" + String(seed(url), radix: 36) + (mode == .light ? "-light" : "")
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
        return await Task.detached(priority: .utility) { () -> Bool in
            guard let picture = BandsPicture.backdrop(from: palette, light: mode == .light, seed: seed, tuning: tuning),
                  let png = UIImage(cgImage: picture).pngData() else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return (try? png.write(to: file, options: .atomic)) != nil
        }.value
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
                guard let bands = BandsPicture.pools(from: palette, light: light, saturation: saturation,
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
        // A mode change redraws it through the window's trait change
        // (`ModeChangeCover`), once: each of these (one per page, ~10)
        // redrawing it on its own was ten loads at every change.
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
        guard let window else { return }
        // No still (one up already, or none to be had while away): the
        // background changes all the same.
        guard cover == nil, let still = window.snapshotView(afterScreenUpdates: false) else {
            BackgroundStore.shared.modeChanged()
            return
        }
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
/// A dark plate of rows (Up/Down a row, Left/Right its value), Select hides
/// and shows it (hidden, Left/Right another shape), Back closes. The values
/// carry to the next title opened this run (Reset puts the app's back); In
/// the App shows them behind the cards for the run; the app otherwise draws
/// with `BandsPicture.Tuning()`.
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

    private let item: MetaItem
    private var palette: [BandsPicture.Colour]?
    private var url: String?
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

    /// Another shape: the layout one step on (never under the title's own).
    private static func reshaped(_ layout: UInt64, _ d: Int) -> UInt64 {
        d < 0 && layout == 0 ? 0 : layout &+ UInt64(bitPattern: Int64(d))
    }

    private var rows: [Row] {
        func level(_ name: String, _ path: WritableKeyPath<BandsPicture.Levels, CGFloat>) -> Row {
            Row(name: name, value: { t, l in Self.levels((l ? t.lightLevels : t.darkLevels)[keyPath: path]) },
                step: { t, l, d in
                    let v = (l ? 0.01 : 0.005) * CGFloat(d)
                    if l { t.lightLevels[keyPath: path] = min(1, max(0, t.lightLevels[keyPath: path] + v)) }
                    else { t.darkLevels[keyPath: path] = min(1, max(0, t.darkLevels[keyPath: path] + v)) } })
        }
        return [
            Row(name: "Appearance", value: { $1 ? "Light" : "Dark" }, step: { _, light, _ in light.toggle() }),
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
            Row(name: "Shape", value: { t, _ in t.layout == 0 ? "The title's" : "+\(t.layout)" },
                step: { t, _, d in t.layout = Self.reshaped(t.layout, d) }),
            Row(name: "Reset", value: { t, _ in t == BandsPicture.Tuning() ? "The app's values" : "Changed" },
                step: { t, _, _ in t = BandsPicture.Tuning() }),
            // Right: this title up as the background with these values, for
            // the run (`BandsPicture.trial`); Left: the app's own back.
            Row(name: "In the App", value: { t, _ in
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
            }),
        ]
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
        }
    }

    /// The palette as the drawing reads it: darkest first, each with its
    /// share and its strength (a channel's most from its grey).
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
        let (tuning, light, seed) = (Self.tuning, Self.light, BackgroundPicks.seed(url))
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                BandsPicture.backdrop(from: palette, light: light, seed: seed, tuning: tuning)
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
            if shown { change(d) } else {
                Self.tuning.layout = Self.reshaped(Self.tuning.layout, d)
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
