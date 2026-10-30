import AVKit
import AetherEngine
import SwiftUI
import UIKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let meta: MetaItem
    let video: MetaVideo?
    let entry: StreamEntry
    let allEntries: [StreamEntry]
    let resumePosition: Double?
}

/// AetherEngine's test on the TV: the picture, subtitles and a readout of what
/// the engine says it's doing, to compare with the TV's and receiver's badges.
/// Not the new player: no progress, no next episode, no Nuvio.
///
/// Remote: select pause, left/right 30 s, up next audio, down next subtitle
/// (then off), Back out.
struct EngineTestPlayer: UIViewControllerRepresentable {
    let request: PlaybackRequest
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> EngineTestController {
        EngineTestController(request: request, onClose: onClose)
    }

    func updateUIViewController(_ controller: EngineTestController, context: Context) {}
}

/// Takes focus, so the remote's presses reach the controller.
private final class EngineTestFocusView: UIView {
    override var canBecomeFocused: Bool { true }
}

final class EngineTestController: UIViewController {
    /// Background preloading stands down while a title plays.
    private(set) static var isPlaying = false

    private let request: PlaybackRequest
    private let onClose: () -> Void
    private let engine: AetherEngine?

    private let focusView = EngineTestFocusView()
    private let surface = AetherPlayerView()
    private let subtitleText = UILabel()
    private let subtitleImage = UIImageView()
    private let readout = UILabel()

    private var probe: SourceProbe?
    private var failure: String?
    private var timer: Timer?
    private var started = false

    init(request: PlaybackRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        do {
            engine = try AetherEngine()
        } catch {
            engine = nil
            failure = error.localizedDescription
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [focusView] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for sub in [focusView, surface, subtitleImage, subtitleText, readout] as [UIView] {
            view.addSubview(sub)
        }

        subtitleText.numberOfLines = 0
        subtitleText.textAlignment = .center
        subtitleText.textColor = .white
        subtitleText.font = .systemFont(ofSize: 40, weight: .medium)
        subtitleText.shadowColor = .black
        subtitleText.shadowOffset = CGSize(width: 0, height: 2)

        readout.numberOfLines = 0
        readout.textColor = .white
        readout.font = .monospacedSystemFont(ofSize: 23, weight: .regular)
        readout.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        readout.layer.cornerRadius = 12
        readout.clipsToBounds = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        focusView.frame = view.bounds
        surface.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Self.isPlaying = true
        setNeedsFocusUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        start()
    }

    private func start() {
        guard let engine else { return }
        engine.bind(view: surface)
        guard let raw = request.entry.stream.url, let url = URL(string: raw) else {
            failure = "This link has no direct URL"
            return
        }
        let options = LoadOptions(
            httpHeaders: request.entry.stream.behaviorHints?.proxyHeaders?.requestHeaders ?? [:],
            matchContentEnabled: view.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true,
            confirmAtmos: true
        )
        Task { [weak self] in
            do {
                let probe = try await engine.load(
                    url: url, startPosition: self?.request.resumePosition, options: options
                )
                self?.probe = probe
            } catch is CancellationError {
            } catch {
                self?.failure = error.localizedDescription
            }
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        engine?.stop()
        Self.isPlaying = false
        onClose()
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, let engine else {
            if presses.first?.type == .menu { close() }
            return
        }
        switch press.type {
        case .select, .playPause: engine.togglePlayPause()
        case .leftArrow: jump(-30)
        case .rightArrow: jump(30)
        case .upArrow: nextAudio()
        case .downArrow: nextSubtitle()
        case .menu: close()
        default: super.pressesBegan(presses, with: event)
        }
    }

    private func jump(_ seconds: Double) {
        guard let engine else { return }
        let target = max(0, engine.currentTime + seconds)
        Task { await engine.seek(to: target) }
    }

    private func nextAudio() {
        guard let engine, !engine.audioTracks.isEmpty else { return }
        let tracks = engine.audioTracks
        let now = tracks.firstIndex { $0.id == engine.activeAudioTrackIndex } ?? -1
        let next = tracks[(now + 1) % tracks.count]
        Task { try? await engine.selectAudioTrack(index: next.id) }
    }

    private func nextSubtitle() {
        guard let engine, !engine.subtitleTracks.isEmpty else { return }
        let tracks = engine.subtitleTracks
        let now = tracks.firstIndex { $0.id == engine.activeSubtitleTrackIndex } ?? -1
        if now + 1 < tracks.count {
            engine.selectSubtitleTrack(index: tracks[now + 1].id)
        } else {
            engine.clearSubtitle()
        }
    }

    // MARK: Screen

    private func tick() {
        if let engine { showSubtitle(engine) }
        readout.text = "  " + lines().joined(separator: "  \n  ") + "  "
        let size = readout.sizeThatFits(CGSize(width: 1200, height: 900))
        readout.frame = CGRect(x: 60, y: 40, width: size.width, height: size.height + 16)
    }

    private func showSubtitle(_ engine: AetherEngine) {
        let time = engine.clock.sourceTime
        let cue = engine.subtitleCues.first { $0.startTime <= time && time < $0.endTime }
        var text: String?
        var image: SubtitleImage?
        switch cue?.body {
        case .image(let picture): image = picture
        case .some: text = cue?.text
        case nil: break
        }

        subtitleText.text = text
        let width = view.bounds.width - 300
        let height = subtitleText.sizeThatFits(CGSize(width: width, height: 400)).height
        subtitleText.frame = CGRect(x: 150, y: view.bounds.height - 90 - height, width: width, height: height)

        if let image {
            let bounds = view.bounds
            subtitleImage.image = UIImage(cgImage: image.cgImage)
            subtitleImage.frame = CGRect(
                x: image.position.minX * bounds.width, y: image.position.minY * bounds.height,
                width: image.position.width * bounds.width, height: image.position.height * bounds.height
            )
        } else {
            subtitleImage.image = nil
        }
    }

    private func lines() -> [String] {
        var out: [String] = []
        if let failure { out.append("FAILED  \(failure)") }
        guard let engine else { return out }

        if let probe {
            var source = "\(probe.videoCodecName ?? "?") \(probe.videoWidth)x\(probe.videoHeight)"
            if let fps = probe.videoFrameRate { source += String(format: " %.3f fps", fps) }
            if probe.isDolbyVision { source += " DV\(probe.dvProfile.map { " P\($0)" } ?? "")" }
            out.append("source     \(source)")
        } else {
            out.append("source     (probing)")
        }
        out.append("presenting \(engine.videoFormat)   route \(engine.videoRoute.rawValue)")
        let screen = AetherEngine.displayCapabilities
        out.append("display    DV \(screen.supportsDolbyVision)  HDR10 \(screen.supportsHDR10)  HLG \(screen.supportsHLG)")

        let audio = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        let atmos = audio?.isAtmos == true ? " Atmos" : audio?.isDTSX == true ? " DTS:X" : ""
        out.append("audio      \(audio.map { "\($0.codec) \($0.channels)ch\(atmos) \($0.language ?? "")" } ?? "none")")
        out.append("delivery   \(engine.audioDelivery.rawValue)   tracks \(engine.audioTracks.count)")
        out.append("decoder    \(engine.activeAudioDecoder ?? "none")")
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        out.append("output     \(port)  \(session.outputNumberOfChannels)ch of \(session.maximumOutputNumberOfChannels)")
        if let info = engine.errorInfo { out.append("error      \(info.message)") }

        let subtitle = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        out.append("subtitle   \(subtitle.map { "\($0.codec) \($0.language ?? "")" } ?? "off")   tracks \(engine.subtitleTracks.count)")

        out.append("state      \(engine.state)")
        out.append(String(format: "time       %.0f / %.0f s   buffered to %.0f s",
                          engine.currentTime, engine.duration, engine.clock.bufferedPosition))
        out.append("memory     \(memoryMB()) MB")
        return out
    }

    private func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}
