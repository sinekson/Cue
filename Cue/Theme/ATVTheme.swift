import CoreImage
import SwiftUI

extension View {
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

    /// `image` read back at 16 bits, then grained going down to 8: each
    /// channel the same random offset (grey grain), from two dice
    /// (triangular — dithers dark gradients without banding on a TV).
    static func grained(_ image: CIImage, in rect: CGRect, context: CIContext) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = Int(rect.width), height = Int(rect.height)
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

    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            .workingFormat: CIFormat.RGBAh])
    }

    /// Draws the picture (Core Image on the GPU, the grain on the CPU).
    static func render() -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = Self.context()
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

        return grained(image, in: rect, context: context)
    }
}

/// THE BACKGROUND, one still picture behind every page: a title's
/// picture, blurred and dimmed as below Details' billboard, picked by the
/// time of day (`BackgroundPicks`) — lighter by day, darkest at night.
/// It changes only where it can't be seen changing: at launch, and coming
/// back to the app once the time of day has moved on or 4 h have passed.
/// Bands is the fallback (nothing picked yet: a first launch). (Tried:
/// Bands alone, and following the focused title — its colours, then its
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

    /// Settings' Pick Another: the time of day's next picture now.
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
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage, Bool)? in
            if let pick, let image = UIImage(contentsOfFile: pick.file.path)?.preparingForDisplay() {
                return (image, true)
            }
            return Self.bands().map { ($0, false) }
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
    nonisolated private static func bands() -> UIImage? {
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.map { Int($0.timeIntervalSince1970) } ?? 0
        let file = BackgroundPicks.folder.deletingLastPathComponent()
            .appendingPathComponent("background-\(built).png")
        if let picture = UIImage(contentsOfFile: file.path)?.preparingForDisplay() { return picture }
        guard let cg = BandsPicture.render() else { return nil }
        let drawn = UIImage(cgImage: cg)
        let folder = file.deletingLastPathComponent()
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        // Earlier builds' copies go.
        for old in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix("background-") {
            try? files.removeItem(at: folder.appendingPathComponent(old))
        }
        try? drawn.pngData()?.write(to: file, options: .atomic)
        return drawn
    }
}

/// Which title's picture is the background (`BackgroundStore`). The pool:
/// the titles on Home (the billboard's, each row's first 15), each scored
/// once from TMDB's backdrop — Details' picture — in the loading queue's
/// deep band. A picture passes when, blurred and dimmed as Details does:
/// it isn't near black, its colour sits in at most two runs of hues (no
/// confetti of colours), and nothing in it is bright enough to fight the
/// text. The passes, darkest first, split in three: night, evening, day.
/// One is drawn ahead for each (grained, at 1080p, on disk), so a change
/// is instant; the last 7 shown aren't picked again.
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
        /// Its brightest 5 %, once dimmed (a chosen picture's further dim).
        var spot: Double?
    }

    enum TimeOfDay: Int, CaseIterable, Codable {
        case night, evening, day
        /// Day 7–17, evening 17–21, night 21–7.
        static var now: TimeOfDay {
            let hour = Calendar.current.component(.hour, from: Date())
            return (7..<17).contains(hour) ? .day : (17..<21).contains(hour) ? .evening : .night
        }
        var name: String { ["Night", "Evening", "Day"][rawValue] }
    }

    private struct State: Codable {
        var scored: [String: Scored] = [:]
        /// Titles with no backdrop to score (asked again after a week).
        var none: [String: Date] = [:]
        var shown: String?
        var shownAt: Date?
        var shownTime: TimeOfDay?
        /// The one up was chosen from a card's menu.
        var chosen: Bool?
        var recent: [String] = []
        /// Drawn ahead: a picture's URL per time of day.
        var ready: [Int: String] = [:]
    }

    /// Rules (tuned on 12 titles: Made in Abyss, Tengoku Daimakyo, From,
    /// Stick, … passing; One Piece's confetti and Stranger Things' black
    /// failing).
    nonisolated static let darkest = 0.14
    nonisolated static let brightestSpot = 0.40
    nonisolated static let hueRuns = 0.95
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

    nonisolated static func file(for url: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return folder.appendingPathComponent(String(hash, radix: 36) + ".png")
    }

    /// A new picture is due (coming back): the time of day moved on, or
    /// it's been up 4 h.
    var due: Bool {
        guard let at = state.shownAt else { return true }
        return state.shownTime != TimeOfDay.now || Date().timeIntervalSince(at) >= Self.keep
    }

    /// The picture to show: the one up while it isn't due (`force`: never),
    /// else the time of day's drawn ahead; nil: none ready (Bands).
    func pick(force: Bool) async -> (scored: Scored, file: URL)? {
        let files = FileManager.default
        func ready(_ url: String?) -> (Scored, URL)? {
            guard let url, let scored = state.scored.values.first(where: { $0.url == url }) else { return nil }
            let file = Self.file(for: url)
            return files.fileExists(atPath: file.path) ? (scored, file) : nil
        }
        if !force, !due, let current = ready(state.shown) { return current }
        let time = TimeOfDay.now
        if force {
            // Pick Another: drawn now, whatever's ready.
            state.ready[time.rawValue] = nil
            await prepare(only: time)
        }
        guard let next = ready(state.ready[time.rawValue]) else {
            // Nothing ready for now: the one up stays.
            return ready(state.shown)
        }
        state.ready[time.rawValue] = nil
        up(next.0.url, chosen: false)
        return next
    }

    /// The one up was chosen from a card's menu (until the next change).
    var chosen: Bool { state.chosen ?? false }

    /// A title chosen from its card's menu: up now, until the next change
    /// (`due`). Any title: the rules don't hold a choice back, but a bright
    /// spot is dimmed down to what they allow.
    func choose(_ item: MetaItem) async -> (scored: Scored, file: URL)? {
        var scored = state.scored[item.id]
        if scored?.spot == nil {
            guard let url = await TMDBService.backdrop(id: item.id, type: item.type),
                  let measured = await Self.measure(url: url, item: item) else { return nil }
            state.scored[item.id] = measured
            scored = measured
        }
        guard let scored else { return nil }
        var dim = scored.dim
        if let spot = scored.spot, spot > Self.brightestSpot {
            dim = 1 - (1 - dim) * Self.brightestSpot / spot
        }
        guard await draw(scored.url, dim: dim) else { return nil }
        for (time, url) in state.ready where url == scored.url { state.ready[time] = nil }
        up(scored.url, chosen: true)
        return (scored, Self.file(for: scored.url))
    }

    private func up(_ url: String, chosen: Bool) {
        state.shown = url
        state.shownAt = Date()
        state.shownTime = TimeOfDay.now
        state.chosen = chosen
        state.recent = Array(([url] + state.recent.filter { $0 != url }).prefix(Self.recentCount))
        save()
        Task { await prepare() }
    }

    /// The picture drawn to its file (`draw(_:dim:)`, off the main thread).
    private func draw(_ url: String, dim: Double) async -> Bool {
        guard let blurred = await BlurredBackdrop.image(for: url), let cg = blurred.cgImage else { return false }
        let file = Self.file(for: url)
        return await Task.detached(priority: .utility) { () -> Bool in
            guard let picture = Self.draw(cg, dim: dim),
                  let png = UIImage(cgImage: picture).pngData() else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return (try? png.write(to: file, options: .atomic)) != nil
        }.value
    }

    /// The deep band: Home's titles not yet scored, then a picture drawn
    /// ahead for each time of day.
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

    /// The passes for a time of day: darkest first, in thirds.
    private func candidates(_ time: TimeOfDay) -> [Scored] {
        var byURL: [String: Scored] = [:]
        for scored in state.scored.values where scored.passes { byURL[scored.url] = scored }
        let passes = byURL.values.sorted { $0.light < $1.light }
        guard !passes.isEmpty else { return [] }
        let third = Double(passes.count) / 3
        let from = Int((Double(time.rawValue) * third).rounded())
        let to = max(from + 1, Int((Double(time.rawValue + 1) * third).rounded()))
        return Array(passes[min(from, passes.count - 1)..<min(to, passes.count)])
    }

    /// A picture drawn ahead for each time of day without one.
    private func prepare(only: TimeOfDay? = nil) async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        let files = FileManager.default
        for time in only.map({ [$0] }) ?? TimeOfDay.allCases {
            if let url = state.ready[time.rawValue], files.fileExists(atPath: Self.file(for: url).path) { continue }
            let taken = Set(state.recent + [state.shown].compactMap { $0 } + state.ready.values)
            let options = candidates(time)
            guard let choice = options.filter({ !taken.contains($0.url) }).randomElement()
                    ?? options.filter({ $0.url != state.shown }).randomElement() else { continue }
            if await draw(choice.url, dim: choice.dim) { state.ready[time.rawValue] = choice.url }
        }
        // Only what's up or ready stays on disk.
        let keep = Set(([state.shown].compactMap { $0 } + state.ready.values).map { Self.file(for: $0).lastPathComponent })
        for name in (try? files.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        where name.hasSuffix(".png") && !keep.contains(name) {
            try? files.removeItem(at: Self.folder.appendingPathComponent(name))
        }
        save()
    }

    /// Details' blur at 1080p, its dim, grained (`BandsPicture.grained`).
    nonisolated private static func draw(_ blurred: CGImage, dim: Double) -> CGImage? {
        let rect = CGRect(origin: .zero, size: BandsPicture.size)
        var image = CIImage(cgImage: blurred)
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (rect.width - image.extent.width) / 2 - image.extent.minX,
                                                        y: (rect.height - image.extent.height) / 2 - image.extent.minY))
        let k = CGFloat(1 - dim)
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ]).cropped(to: rect)
        return BandsPicture.grained(image, in: rect, context: BandsPicture.context())
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
            var lumas: [Double] = []
            var bins = [Double](repeating: 0, count: 12)
            var colour = 0.0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                let high = max(r, g, b), low = min(r, g, b)
                let saturation = high > 0 ? (high - low) / high : 0
                guard saturation > 0.15, high > 0.08 else { continue }
                var hue = high == r ? (g - b) / (high - low) : high == g ? 2 + (b - r) / (high - low) : 4 + (r - g) / (high - low)
                hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
                bins[Int(hue / 30) % 12] += saturation * high
                colour += saturation * high
            }
            let mean = max(lumas.reduce(0, +) / Double(lumas.count), 0.01)
            let dim = Double(StageArt.dimBelow(mean: CGFloat(mean)))
            let light = mean * (1 - dim)
            let spot = (lumas.sorted()[Int(Double(lumas.count) * 0.95)]) * (1 - dim)
            // Runs of neighbouring hues (each bin ≥ 3 % of the colour); the
            // two largest must hold nearly all of it.
            var inRuns = 1.0
            if colour > 0 {
                let share = bins.map { $0 / colour }
                var runs: [Double] = []
                if share.allSatisfy({ $0 >= 0.03 }) { runs = [1] } else {
                    let start = share.firstIndex(where: { $0 < 0.03 })!
                    var run = 0.0
                    for step in 1...12 {
                        let value = share[(start + step) % 12]
                        if value >= 0.03 { run += value } else if run > 0 { runs.append(run); run = 0 }
                    }
                }
                inRuns = runs.sorted(by: >).prefix(2).reduce(0, +)
            }
            var why: [String] = []
            if light < BackgroundPicks.darkest { why.append("too dark") }
            if spot > BackgroundPicks.brightestSpot { why.append("a bright spot") }
            if inRuns < BackgroundPicks.hueRuns { why.append("too many colours") }
            return Scored(id: item.id, name: item.name, url: url, light: light, dim: dim,
                          passes: why.isEmpty, why: why.isEmpty ? "passes" : why.joined(separator: ", "),
                          spot: spot)
        }.value
    }
}

/// The app's background, behind every screen (`BackgroundStore`).
struct ATVBackground: View {
    @ObservedObject private var picture = BackgroundStore.shared

    var body: some View {
        ZStack {
            Color("AppBackground")   // also the launch screen's
            if let image = picture.image {
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Motion.fadeDuration), value: picture.image)
        .ignoresSafeArea()
        .onAppear { picture.load() }
    }
}
