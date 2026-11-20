import QuartzCore
import UIKit

/// Developer: the Frame Rate overlay (Settings → Developer → Frame Rate),
/// top right over everything, the player included: a window of its own
/// above the app's, taking no presses and no focus.
///
/// It counts the frames the main thread's display link gets: a frame the
/// main thread misses (layout, decoding, SwiftUI work) shows as a long one.
/// Frames the GPU or the render server drop can't be seen from inside the
/// app (the link still fires every vsync): for those, Instruments' Animation
/// Hitches. Hence "main thread" on the panel.
///
/// Compact: the frame rate and a dot. Full: the last 4 s of frame times as
/// bars (a line at one frame), the last 5 s' dropped frames and worst frame,
/// CPU, memory and the thermal state.
@MainActor
final class FrameRateOverlay {
    static let shared = FrameRateOverlay()

    private var window: UIWindow?
    private let panel = FrameRatePanel()

    func apply(_ mode: PerformanceSettingsStore.FrameRate) {
        guard mode != .off,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            panel.stop()
            window?.isHidden = true
            window = nil
            return
        }
        if window == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.isUserInteractionEnabled = false
            window.overrideUserInterfaceStyle = .dark
            window.backgroundColor = .clear
            let root = UIViewController()
            root.view.backgroundColor = .clear
            root.view.isUserInteractionEnabled = false
            root.view.addSubview(panel)
            window.rootViewController = root
            window.isHidden = false
            self.window = window
        }
        panel.mode = mode
        panel.start()
    }
}

private final class FrameRatePanel: UIView {
    var mode = PerformanceSettingsStore.FrameRate.compact {
        didSet { if mode != oldValue { place() } }
    }

    private static let width: CGFloat = 400
    private static let pad: CGFloat = 22
    private static let graphHeight: CGFloat = 84
    /// The graph's top: 50 ms (three frames).
    private static let graphTop: Double = 0.050
    private static let graphSeconds: Double = 4
    private static let statSeconds: Double = 5
    private static let edge: CGFloat = 40

    private let dot = UIView()
    private let rate = UILabel()
    private let unit = UILabel()
    private let caption = UILabel()
    private let graph = UIView()
    private let calm = CAShapeLayer()
    private let late = CAShapeLayer()
    private let guides = CAShapeLayer()
    private let drops = UILabel()
    private let system = UILabel()

    private var link: CADisplayLink?
    /// Frame times with their timestamps, the last few seconds.
    private var frames: [(at: CFTimeInterval, length: CFTimeInterval)] = []
    private var last: CFTimeInterval = 0
    private var textAt: CFTimeInterval = 0
    private var graphAt: CFTimeInterval = 0
    private var systemAt: CFTimeInterval = 0
    private let refresh = Double(UIScreen.main.maximumFramesPerSecond)
    private var interval: Double { 1 / refresh }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerCurve = .continuous
        dot.layer.cornerRadius = 7
        rate.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        rate.textColor = .white.withAlphaComponent(FixedFocusText.primary)
        unit.text = "fps"
        unit.font = .systemFont(ofSize: 24, weight: .medium)
        unit.textColor = .white.withAlphaComponent(FixedFocusText.secondary)
        caption.text = "main thread · \(Int(refresh)) Hz"
        for label in [caption, drops, system] {
            label.font = .monospacedDigitSystemFont(ofSize: 23, weight: .regular)
            label.textColor = .white.withAlphaComponent(label === caption ? FixedFocusText.tertiary : FixedFocusText.body)
        }
        guides.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        guides.lineWidth = 1
        guides.lineDashPattern = [4, 4]
        calm.fillColor = UIColor.white.withAlphaComponent(0.45).cgColor
        late.fillColor = UIColor.systemOrange.cgColor
        for shape in [guides, calm, late] { graph.layer.addSublayer(shape) }
        for sub in [dot, rate, unit, caption, graph, drops, system] { addSubview(sub) }
        place()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard link == nil else { return }
        frames = []
        last = 0
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The link holds its target: a weak hop, so the panel can go.
    private final class Ticker: NSObject {
        weak var panel: FrameRatePanel?
        init(_ panel: FrameRatePanel) { self.panel = panel }
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { panel?.tick(link) } }
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 { frames.append((now, now - last)) }
        last = now
        frames.removeAll { now - $0.at > Self.statSeconds }
        if now - textAt >= 0.5 { textAt = now; showText(now) }
        if mode == .full, now - graphAt >= 0.1 { graphAt = now; drawGraph(now) }
        if mode == .full, now - systemAt >= 1 { systemAt = now; showSystem() }
    }

    private func showText(_ now: CFTimeInterval) {
        let second = frames.filter { now - $0.at <= 1 }
        let span = second.reduce(0) { $0 + $1.length }
        let fps = span > 0 ? Double(second.count) / span : 0
        rate.text = String(format: "%.0f", min(fps, refresh))
        let share = fps / refresh
        dot.backgroundColor = share >= 0.95 ? .systemGreen : share >= 0.8 ? .systemYellow : .systemRed
        guard mode == .full else { return }
        let dropped = frames.reduce(0) { $0 + max(0, Int(($1.length / interval).rounded()) - 1) }
        let worst = (frames.map(\.length).max() ?? 0) * 1000
        drops.text = String(format: "dropped %d · worst %.0f ms · 5 s", dropped, worst)
    }

    private func showSystem() {
        system.text = String(format: "CPU %.0f %% · %.0f MB · %@", PlayerProbe.cpuPercent(),
                             PlayerProbe.footprintMB(),
                             AppProbe.thermalLabel(ProcessInfo.processInfo.thermalState))
    }

    private func drawGraph(_ now: CFTimeInterval) {
        let size = graph.bounds.size
        let slots = Int(Self.graphSeconds * refresh)
        let bar = size.width / CGFloat(slots)
        let shown = frames.filter { now - $0.at <= Self.graphSeconds }.suffix(slots)
        let calmPath = CGMutablePath(), latePath = CGMutablePath()
        let start = slots - shown.count
        for (index, frame) in shown.enumerated() {
            let height = min(CGFloat(frame.length / Self.graphTop), 1) * size.height
            let rect = CGRect(x: CGFloat(start + index) * bar, y: size.height - height,
                              width: max(bar - 0.5, 1), height: height)
            (frame.length > interval * 1.5 ? latePath : calmPath).addRect(rect)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        calm.path = calmPath
        late.path = latePath
        CATransaction.commit()
    }

    private func place() {
        let full = mode == .full
        for sub in [caption, graph, drops, system] { sub.isHidden = !full }
        rate.sizeToFit()
        let top = Self.pad
        if full {
            rate.text = rate.text ?? "60"
            rate.frame = CGRect(x: Self.pad, y: top - 4, width: 92, height: 52)
            unit.frame = CGRect(x: Self.pad + 92, y: top + 14, width: 60, height: 30)
            dot.frame = CGRect(x: Self.width - Self.pad - 14, y: top + 19, width: 14, height: 14)
            caption.frame = CGRect(x: Self.pad, y: top + 54, width: Self.width - Self.pad * 2, height: 30)
            graph.frame = CGRect(x: Self.pad, y: top + 96, width: Self.width - Self.pad * 2, height: Self.graphHeight)
            drops.frame = CGRect(x: Self.pad, y: graph.frame.maxY + 14, width: graph.bounds.width, height: 30)
            system.frame = CGRect(x: Self.pad, y: drops.frame.maxY + 4, width: graph.bounds.width, height: 30)
            let guide = CGMutablePath()
            for frames in [1.0, 2.0] {
                let y = graph.bounds.height * (1 - CGFloat(frames * interval / Self.graphTop))
                guide.move(to: CGPoint(x: 0, y: y))
                guide.addLine(to: CGPoint(x: graph.bounds.width, y: y))
            }
            guides.path = guide
            let height = system.frame.maxY + Self.pad
            frame = CGRect(x: 1920 - Self.edge - Self.width, y: Self.edge, width: Self.width, height: height)
            layer.cornerRadius = 22
        } else {
            let width: CGFloat = 196
            dot.frame = CGRect(x: 24, y: 29, width: 14, height: 14)
            rate.frame = CGRect(x: 50, y: 10, width: 82, height: 52)
            unit.frame = CGRect(x: 132, y: 24, width: 50, height: 30)
            frame = CGRect(x: 1920 - Self.edge - width, y: Self.edge, width: width, height: 72)
            layer.cornerRadius = 36
        }
    }
}
