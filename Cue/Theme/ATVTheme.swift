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

    /// `image` read back at 16 bits, then grained going down to 8: each
    /// channel the same random offset (grey grain), from two dice
    /// (triangular — dithers dark gradients without banding on a TV).
    /// The grain added on the GPU before the picture goes to 8 bits (it
    /// keeps the dark gradients from banding): two noises summed, a
    /// triangular ±`grain`/2, the same in each channel. (A per-pixel loop
    /// on the CPU took seconds in a Debug build on the TV: Details' colours
    /// came late.)
    static func grained(_ image: CIImage, in rect: CGRect, context: CIContext) -> CGImage? {
        let a = grain / 2
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: rect)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: a, z: 0, w: 0),
                "inputGVector": CIVector(x: a, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: a, y: a, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -a, y: -a, z: -a, w: 0),
            ])
        let out = image.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: noise])
            .cropped(to: rect)
        return context.createCGImage(out, from: rect, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// One for every drawing (making one each time cost tens of ms).
    static let shared = context()

    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            .workingFormat: CIFormat.RGBAh])
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
    /// 0 lands at 62 %, 1 at 90 %.
    static func lifted(_ v: Double, darker: Double = 1) -> CGFloat {
        CGFloat((0.62 + 0.28 * v) * (1 - (1 - darker) * 0.4))
    }
    /// A colour's channel for dark mode: toward tvOS's dark grey (its
    /// Settings', about 11 %), the picture's colour a soft tint over it —
    /// 0 lands at 5 %, 1 at 22 % (light's `lifted`, mirrored; 7–30 % was
    /// too light).
    static func sunk(_ v: Double, darker: Double = 1) -> CGFloat {
        CGFloat((0.05 + 0.17 * v) * (1 - (1 - darker) * 0.4))
    }
    /// Details' (`TitleBands`): the picture's colour stronger over the grey
    /// — 0 lands at 50 %, 1 at 92 %.
    static func liftedStrong(_ v: Double, darker: Double = 1) -> CGFloat {
        CGFloat((0.50 + 0.42 * v) * (1 - (1 - darker) * 0.4))
    }

    /// Draws pools of colour on a base (Core Image on the GPU, the grain on
    /// the CPU).
    static func render(base: (CGFloat, CGFloat, CGFloat), pools: [Pool]) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = Self.shared
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
        image = image.clampedToExtent().applyingGaussianBlur(sigma: 60).cropped(to: rect)

        return grained(image, in: rect, context: context)
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

    /// A picture's colours as pools in a layout of their own (tvOS's way):
    /// the darkest the base, the rest spread across the screen at random
    /// (`seed`: the same picture, the same layout), each colour by its share.
    /// Dark: dimmed by `dim` and never brighter than `brightest`. Light:
    /// lifted to tvOS's light grey, the colours a tint (`lifted`).
    static func pools(from palette: [(r: Double, g: Double, b: Double, share: Double)], dim: Double,
                      brightest: Double, light: Bool = false, strong: Bool = false,
                      saturation chosen: Double? = nil, seed: UInt64) -> (base: (CGFloat, CGFloat, CGFloat), pools: [Pool])? {
        guard let darkest = palette.first else { return nil }
        func shaded(_ c: (r: Double, g: Double, b: Double, share: Double), _ extra: Double = 1) -> (CGFloat, CGFloat, CGFloat) {
            // The picture's hues pushed out from its grey (k-means averages
            // and the blur pull them toward grey); Details' further.
            var c = c
            let saturation = chosen ?? (strong ? Self.strongSaturation : Self.saturation)
            let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            func out(_ v: Double) -> Double { min(1, max(0, y + (v - y) * saturation)) }
            (c.r, c.g, c.b) = (out(c.r), out(c.g), out(c.b))
            if light {
                let lift = strong ? liftedStrong : lifted
                return (lift(c.r, extra), lift(c.g, extra), lift(c.b, extra))
            }
            // The app's, dark: light's mirror, a dark grey with the
            // picture's colours a tint over it (dimmed alone, they read
            // too colourful beside light's silver). Details' keeps its own.
            if !strong, chosen == nil {
                return (sunk(c.r, darker: extra), sunk(c.g, darker: extra), sunk(c.b, darker: extra))
            }
            var (r, g, b) = (c.r * (1 - dim) * extra, c.g * (1 - dim) * extra, c.b * (1 - dim) * extra)
            let light = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if light > brightest { let k = brightest / light; (r, g, b) = (r * k, g * k, b * k) }
            return (CGFloat(r), CGFloat(g), CGFloat(b))
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
            let colour = i % 3 == 2 ? shaded(darkest, 0.8) : shaded(pick())
            return Pool(r: colour.0, g: colour.1, b: colour.2,
                        x: (CGFloat(i) + .random(in: 0.1...0.9, using: &random)) / CGFloat(count),
                        y: .random(in: 0...1, using: &random),
                        rx: .random(in: 0.14...0.30, using: &random),
                        ry: .random(in: 0.35...0.80, using: &random))
        }.shuffled(using: &random)
        return (shaded(darkest, 0.85), pools)
    }

    private static let poolCount = 8
    /// The colours' saturation, times the picture's: the app's
    /// background, below the picture's own (1.4, then 1.2 in dark, read
    /// too colourful on an OLED with tvOS in Dolby Vision, which lifts
    /// colour far more than light: tuned there), Details' (`strong`).
    static let saturation = 0.8
    static let strongSaturation = 1.8
    /// The play stage's: a step past Details', the same bands deepening as
    /// it comes in (closer to the film).
    static let stageSaturation = 2.2
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
/// mode (`BackgroundPicks`): light, a light picture's colours lifted to
/// tvOS's light grey; dark, a dark one's, dimmed. It changes where it
/// can't be seen changing — at launch, coming back once 4 h have passed —
/// and with the mode (Automatic at sunset: the page changes anyway).
/// Grey pools are the fallback (nothing picked yet: a first launch).
/// (Tried: the title's picture blurred as Details' — too busy at times;
/// grey alone; following the focused title — its colours, then its
/// blurred picture: too much going on.)
@MainActor
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()
    @Published private(set) var image: UIImage?
    /// The title it's from (Settings → Appearance → Background); nil: Bands.
    @Published private(set) var shown: BackgroundPicks.Scored?
    /// Chosen from a card's menu, not by the time of day.
    @Published private(set) var chosen = false
    private var loading = false

    /// At launch: the time of day's picture, else Bands (nil until in).
    func load() {
        guard image == nil, !loading else { return }
        loading = true
        Task {
            let pick = await BackgroundPicks.shared.pick(force: false)
            await show(pick, fade: false)
            loading = false
        }
    }

    /// tvOS's mode changed: the mode's picture (the page's text turns with
    /// it), faded in.
    func modeChanged() {
        guard image != nil, !loading else { return }
        Task {
            guard BackgroundPicks.shared.due else { return }
            let pick = await BackgroundPicks.shared.pick(force: false)
            await show(pick, fade: true)
        }
    }

    /// Back in the app: a new picture if it's due (shown at once — the
    /// system's own move covers it).
    func cameBack() {
        guard image != nil, !loading else { return }
        Task {
            guard BackgroundPicks.shared.due else { return }
            let pick = await BackgroundPicks.shared.pick(force: false)
            if pick?.scored.url != shown?.url { await show(pick, fade: false) }
        }
    }

    /// Settings' Pick Another: the mode's next picture now.
    func another() {
        Task {
            let pick = await BackgroundPicks.shared.pick(force: true)
            await show(pick, fade: true)
        }
    }

    /// A card's "Use as Background": its picture now, until the next change.
    func use(_ item: MetaItem) {
        Task {
            guard let pick = await BackgroundPicks.shared.choose(item) else { return }
            await show(pick, fade: true)
        }
    }

    private func show(_ pick: (scored: BackgroundPicks.Scored, file: URL)?, fade: Bool) async {
        let light = BackgroundPicks.Mode.now == .light
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
        shown = picked ? pick?.scored : nil
        chosen = picked && BackgroundPicks.shared.chosen
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

/// Which title's picture is the background (`BackgroundStore`). The pool:
/// the titles on Home (the billboard's, each row's first 15), each scored
/// once from TMDB's backdrop — Details' picture — in the loading queue's
/// deep band. A picture passes when, dimmed as Details does, it isn't near
/// black. Shown as its colours in bands (`BandsPicture.pools`). The passes,
/// darkest first, split in two by tvOS's mode: dark the darker half, light
/// the lighter (by the clock — day, evening, night thirds — was before:
/// dimmed to dark either way, day read dark). One is drawn ahead for each
/// mode (grained, at 1080p, on disk), so a change is instant; the last 7
/// shown aren't picked again.
@MainActor
final class BackgroundPicks {
    static let shared = BackgroundPicks()

    struct Scored: Codable, Equatable {
        let id: String
        let name: String
        let url: String
        /// Its mean brightness once dimmed (0–1).
        let light: Double
        let dim: Double
        let passes: Bool
        let why: String
    }

    /// tvOS's appearance (Settings → Appearance; Automatic turns it at
    /// sunset).
    enum Mode: Int, CaseIterable, Codable {
        case dark, light
        static var now: Mode {
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            return (window?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .light ? .light : .dark
        }
        var name: String { ["Dark", "Light"][rawValue] }
    }

    private struct State: Codable {
        var scored: [String: Scored] = [:]
        /// Titles with no backdrop to score (asked again after a week).
        var none: [String: Date] = [:]
        var shown: String?
        var shownAt: Date?
        var shownMode: Mode?
        /// The one up was chosen from a card's menu.
        var chosen: Bool?
        var recent: [String] = []
        /// Drawn ahead: a picture's URL per mode.
        var ready: [Int: String] = [:]
    }

    /// Rules: not near black once dimmed (Stranger Things' black failed);
    /// no colour brighter than `brightestSpot` (brighter ones are dimmed to
    /// it). Busy pictures are fine: only their colours are used.
    nonisolated static let darkest = 0.14
    nonisolated static let brightestSpot = 0.40
    static let keep: TimeInterval = 4 * 60 * 60
    static let recentCount = 7
    /// New titles scored per pass (the deep band, at launch and hourly).
    static let perPass = 40

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueCache/backgrounds")
    }
    private static var stateFile: URL { folder.appendingPathComponent("picks.json") }

    private lazy var state: State = {
        guard let data = try? Data(contentsOf: Self.stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }()
    private var scoring = false
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

    nonisolated static func seed(_ url: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    /// (The drawing's version in the name: older drawings go.)
    nonisolated static func file(for url: String, mode: Mode) -> URL {
        folder.appendingPathComponent("bands6-" + String(seed(url), radix: 36) + (mode == .light ? "-light" : "") + ".png")
    }

    /// A new picture is due: the mode changed, or it's been up 4 h (coming
    /// back).
    var due: Bool {
        guard let at = state.shownAt else { return true }
        return state.shownMode != Mode.now || Date().timeIntervalSince(at) >= Self.keep
    }

    /// The picture to show: the one up while it isn't due (`force`: never),
    /// else the mode's drawn ahead; nil: none ready (Bands).
    func pick(force: Bool) async -> (scored: Scored, file: URL)? {
        let files = FileManager.default
        let mode = Mode.now
        func ready(_ url: String?) -> (Scored, URL)? {
            guard let url, let scored = state.scored.values.first(where: { $0.url == url }) else { return nil }
            let file = Self.file(for: url, mode: mode)
            return files.fileExists(atPath: file.path) ? (scored, file) : nil
        }
        if !force, !due, let current = ready(state.shown) { return current }
        if force {
            // Pick Another: drawn now, whatever's ready.
            state.ready[mode.rawValue] = nil
            await prepare(only: mode)
        }
        guard let next = ready(state.ready[mode.rawValue]) else {
            // Nothing ready for this mode: the one up, drawn for it (a
            // chosen one, or the mode just turned), else Bands.
            if let shown = state.shown, let scored = state.scored.values.first(where: { $0.url == shown }),
               await draw(shown, dim: scored.dim, mode: mode) {
                state.shownMode = mode
                save()
                return ready(shown)
            }
            return nil
        }
        state.ready[mode.rawValue] = nil
        up(next.0.url, chosen: false)
        return next
    }

    /// The one up was chosen from a card's menu (until the next change).
    var chosen: Bool { state.chosen ?? false }

    /// A title chosen from its card's menu: up now, until the next change
    /// (`due`). Any title: the rules don't hold a choice back (its colours
    /// are dimmed to them).
    func choose(_ item: MetaItem) async -> (scored: Scored, file: URL)? {
        var scored = state.scored[item.id]
        if scored == nil {
            guard let url = await TMDBService.backdrop(id: item.id, type: item.type),
                  let measured = await Self.measure(url: url, item: item) else { return nil }
            state.scored[item.id] = measured
            scored = measured
        }
        guard let scored else { return nil }
        let mode = Mode.now
        guard await draw(scored.url, dim: scored.dim, mode: mode) else { return nil }
        for (key, url) in state.ready where url == scored.url { state.ready[key] = nil }
        up(scored.url, chosen: true)
        return (scored, Self.file(for: scored.url, mode: mode))
    }

    private func up(_ url: String, chosen: Bool) {
        state.shown = url
        state.shownAt = Date()
        state.shownMode = Mode.now
        state.chosen = chosen
        state.recent = Array(([url] + state.recent.filter { $0 != url }).prefix(Self.recentCount))
        save()
        Task { await prepare() }
    }

    /// The picture drawn to its file (`draw(_:dim:)`, off the main thread).
    private func draw(_ url: String, dim: Double, mode: Mode) async -> Bool {
        let file = Self.file(for: url, mode: mode)
        if FileManager.default.fileExists(atPath: file.path) { return true }
        guard let blurred = await BlurredBackdrop.image(for: url), let cg = blurred.cgImage else { return false }
        let seed = Self.seed(url)
        return await Task.detached(priority: .utility) { () -> Bool in
            guard let picture = Self.draw(cg, dim: dim, light: mode == .light, seed: seed),
                  let png = UIImage(cgImage: picture).pngData() else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return (try? png.write(to: file, options: .atomic)) != nil
        }.value
    }

    /// The deep band: Home's titles not yet scored, then a picture drawn
    /// ahead for each mode.
    func score(_ items: [MetaItem]) async {
        guard !scoring else { return }
        scoring = true
        defer { scoring = false }
        var seen = Set<String>()
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let fresh = items.filter { item in
            guard seen.insert(item.id).inserted, state.scored[item.id] == nil else { return false }
            return (state.none[item.id] ?? .distantPast) < weekAgo
        }
        for item in fresh.prefix(Self.perPass) {
            guard let url = await TMDBService.backdrop(id: item.id, type: item.type),
                  let scored = await Self.measure(url: url, item: item) else {
                state.none[item.id] = Date()
                continue
            }
            state.scored[item.id] = scored
        }
        if !fresh.isEmpty { save() }
        await prepare()
    }

    /// The passes for a mode: darkest first, dark the darker half, light
    /// the lighter.
    private func candidates(_ mode: Mode) -> [Scored] {
        var byURL: [String: Scored] = [:]
        for scored in state.scored.values where scored.light >= Self.darkest { byURL[scored.url] = scored }
        let passes = byURL.values.sorted { $0.light < $1.light }
        guard !passes.isEmpty else { return [] }
        let half = max(1, passes.count / 2)
        return mode == .dark ? Array(passes.prefix(half)) : Array(passes.suffix(max(1, passes.count - half)))
    }

    /// A picture drawn ahead for each mode without one.
    private func prepare(only: Mode? = nil) async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        let files = FileManager.default
        for mode in only.map({ [$0] }) ?? Mode.allCases {
            if let url = state.ready[mode.rawValue],
               files.fileExists(atPath: Self.file(for: url, mode: mode).path) { continue }
            let taken = Set(state.recent + [state.shown].compactMap { $0 } + state.ready.values)
            let options = candidates(mode)
            guard let choice = options.filter({ !taken.contains($0.url) }).randomElement()
                    ?? options.filter({ $0.url != state.shown }).randomElement() else { continue }
            if await draw(choice.url, dim: choice.dim, mode: mode) { state.ready[mode.rawValue] = choice.url }
        }
        // Only what's up (in either mode) or ready stays on disk.
        var keep = Set<String>()
        if let shown = state.shown { for mode in Mode.allCases { keep.insert(Self.file(for: shown, mode: mode).lastPathComponent) } }
        for (key, url) in state.ready {
            keep.insert(Self.file(for: url, mode: Mode(rawValue: key) ?? .dark).lastPathComponent)
        }
        for name in (try? files.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        where name.hasSuffix(".png") && !keep.contains(name) {
            try? files.removeItem(at: Self.folder.appendingPathComponent(name))
        }
        save()
    }

    /// The picture's colours as bands (`BandsPicture.pools`): no shapes of
    /// its own (the blurred picture was too busy at times), its mood only.
    nonisolated private static func draw(_ blurred: CGImage, dim: Double, light: Bool, seed: UInt64) -> CGImage? {
        guard let bands = BandsPicture.pools(from: BandsPicture.palette(blurred), dim: dim,
                                             brightest: brightestSpot, light: light, seed: seed) else { return nil }
        return BandsPicture.render(base: bands.base, pools: bands.pools)
    }

    /// The picture's score: a small copy (TMDB's w780), blurred as
    /// Details' at its scale, read at 64 × 36.
    private static func measure(url: String, item: MetaItem) async -> Scored? {
        let small = url.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")
        guard let remote = URL(string: small), let data = try? await ImageCache.shared.download(remote) else { return nil }
        return await Task.detached(priority: .utility) { () -> Scored? in
            guard let source = ImageCache.decodeDownsampled(data, budget: 160)?.cgImage else { return nil }
            var input = CIImage(cgImage: source)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 20 * input.extent.width / 640)
                .cropped(to: input.extent)
            input = blurred
            let context = CIContext()
            guard let cg = context.createCGImage(input, from: input.extent) else { return nil }
            let (w, h) = (64, 36)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let c = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                c.interpolationQuality = .medium
                c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            var total = 0.0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
            let mean = max(total / Double(w * h), 0.01)
            let dim = Double(StageArt.dimBelow(mean: CGFloat(mean)))
            let light = mean * (1 - dim)
            let passes = light >= BackgroundPicks.darkest
            return Scored(id: item.id, name: item.name, url: url, light: light, dim: dim,
                          passes: passes, why: passes ? "passes" : "too dark")
        }.value
    }
}

/// DETAILS' BACKGROUND: its picture's colours as bands, as the app's
/// background (`BandsPicture.pools`) but stronger — dimmed less, a
/// brighter ceiling; light, a deeper tint (`liftedStrong`) — the title's
/// flavour on its page (Details is the billboard's card opened: without it
/// it read as Home). Drawn when focus rests on a title (`TitlePictures`),
/// kept in memory for the last few; the opening and Details draw the same
/// image, so the hand-over can't show.
@MainActor
final class TitleBands {
    static let shared = TitleBands()
    static let dim = 0.3
    static let brightest = 0.34
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

    /// Drawn (or being drawn) for `url`; nil if it can't be.
    @discardableResult
    func image(for url: String, saturation: Double? = nil) async -> UIImage? {
        let key = Self.key(url, saturation)
        if let image = images[key] { return image }
        if let task = working[key] { return await task.value }
        let light = BackgroundPicks.Mode.now == .light
        let seed = BackgroundPicks.seed(url)
        let small = url.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")
        // The picture already decoded (Details' opening waits on it): no
        // download first (it came seconds late at times).
        let decoded = ImageCache.shared.image(for: RemoteImage.memoryKey(url, maxDimension: PictureSize.screen,
                                                                        maxPixels: nil))?.cgImage
        let known = palettes[url]
        let task = Task<UIImage?, Never> {
            var data: Data?
            if known == nil, decoded == nil {
                guard let remote = URL(string: small),
                      let downloaded = try? await ImageCache.shared.download(remote) else { return nil }
                data = downloaded
            }
            let palette = await Task.detached(priority: .userInitiated) { () -> [BandsPicture.Colour]? in
                if let known { return known }
                guard let source = decoded.flatMap({ Self.shrunk($0, to: 160) })
                        ?? data.flatMap({ ImageCache.decodeDownsampled($0, budget: 160)?.cgImage })
                else { return nil }
                return BandsPicture.palette(source)
            }.value
            guard let palette else { return nil }
            if known == nil { self.keep(palette, for: url) }
            return await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let bands = BandsPicture.pools(from: palette, dim: Self.dim,
                                                     brightest: Self.brightest, light: light, strong: true,
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
    nonisolated private static func shrunk(_ image: CGImage, to side: Int) -> CGImage? {
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
        .onAppear { picture.load() }
        .onChange(of: scheme) { _, _ in picture.modeChanged() }
    }
}
