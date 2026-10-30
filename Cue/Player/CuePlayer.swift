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
    /// A test stream: nothing of it is saved or synced.
    var isDemo = false
}

/// The player: AetherEngine's picture, Cue's subtitles, progress to the same
/// `ProgressStore` calls the sync reads. Remote: select pause, left/right 30 s,
/// up next audio, down next subtitle (then off), Back out.
struct CuePlayer: UIViewControllerRepresentable {
    let request: PlaybackRequest
    let progress: ProgressStore
    let settings: PlayerSettings
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> PlayerController {
        PlayerController(request: request, progress: progress, settings: settings, onClose: onClose)
    }

    func updateUIViewController(_ controller: PlayerController, context: Context) {}
}

/// Takes focus, so the remote's presses reach the controller.
private final class PlayerFocusView: UIView {
    override var canBecomeFocused: Bool { true }
}

/// The bare overlay: what's playing, where it is, which tracks, and a spinner
/// while the engine waits. Shows nothing that takes focus.
private final class PlayerOverlay: UIView {
    /// A view, so the gradient follows the bounds without its own animation.
    private final class Shade: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
    }

    private(set) var isShown = false

    private let controls = UIView()
    private let shade = Shade()
    private let title = UILabel()
    private let state = UILabel()
    private let tracks = UILabel()
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private let bar = UIView()
    private let fill = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var fraction: CGFloat = 0

    init(title text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        controls.alpha = 0
        addSubview(controls)
        addSubview(spinner)
        spinner.color = UIColor.white.withAlphaComponent(0.75)

        let gradient = shade.layer as? CAGradientLayer
        gradient?.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        controls.addSubview(shade)

        title.text = text
        title.font = .systemFont(ofSize: 32, weight: .medium)
        title.textColor = UIColor.white.withAlphaComponent(0.75)
        for label in [state, tracks, elapsed, remaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.55)
        }
        remaining.textAlignment = .right
        state.textAlignment = .right
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        bar.layer.cornerRadius = 3
        bar.clipsToBounds = true
        fill.backgroundColor = UIColor.white.withAlphaComponent(0.75)
        bar.addSubview(fill)
        for sub in [title, state, tracks, elapsed, remaining, bar] as [UIView] {
            controls.addSubview(sub)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 80
        let width = bounds.width - inset * 2
        controls.frame = bounds
        shade.frame = CGRect(x: 0, y: bounds.height - 360, width: bounds.width, height: 360)
        title.frame = CGRect(x: inset, y: bounds.height - 200, width: width - 200, height: 40)
        state.frame = CGRect(x: inset + width - 200, y: bounds.height - 196, width: 200, height: 32)
        bar.frame = CGRect(x: inset, y: bounds.height - 146, width: width, height: 6)
        fill.frame = CGRect(x: 0, y: 0, width: width * fraction, height: 6)
        elapsed.frame = CGRect(x: inset, y: bounds.height - 126, width: 200, height: 32)
        remaining.frame = CGRect(x: inset + width - 200, y: bounds.height - 126, width: 200, height: 32)
        tracks.frame = CGRect(x: inset + 200, y: bounds.height - 126, width: width - 400, height: 32)
        tracks.textAlignment = .center
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func update(time: Double, duration: Double, audio: String, subtitle: String, state text: String?, waiting: Bool) {
        fraction = duration > 0 ? CGFloat(min(max(time / duration, 0), 1)) : 0
        fill.frame.size.width = bar.bounds.width * fraction
        elapsed.text = duration > 0 ? Self.clock(time) : nil
        remaining.text = duration > 0 ? "-" + Self.clock(max(duration - time, 0)) : nil
        tracks.text = audio.isEmpty ? nil : "\(audio)  ·  \(subtitle)"
        state.text = text
        if waiting != spinner.isAnimating {
            if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        UIView.animate(withDuration: Motion.fadeDuration) { self.controls.alpha = shown ? 1 : 0 }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

final class PlayerController: UIViewController {
    /// Background preloading stands down while a title plays.
    private(set) static var isPlaying = false

    private static let tickInterval: TimeInterval = 0.2
    /// Played this long in a session, it counts. Until then nothing is saved,
    /// so a Start Over keeps its old position.
    private static let countsAfterSeconds: Double = 30
    /// Worst-case loss if the app dies: periodic saves reach disk this often.
    private static let saveInterval: TimeInterval = 10
    /// Playback that proves a link good, measured from where the session began.
    private static let provenLinkSeconds: Double = 5 * 60

    private let request: PlaybackRequest
    private let progress: ProgressStore
    private let settings: PlayerSettings
    private let onClose: () -> Void
    private let engine: AetherEngine?

    private let focusView = PlayerFocusView()
    private let surface = AetherPlayerView()
    private let subtitleText = UILabel()
    private let subtitleImage = UIImageView()
    private let overlay: PlayerOverlay
    private let readout = UILabel()

    private var probe: SourceProbe?
    private var failure: String?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var started = false
    private var closed = false

    /// The first frame has played: only then does the clock mean anything.
    private var hasPlayed = false
    /// Time actually played this session, seeks not included.
    private var played: Double = 0
    private var wasPaused = false
    /// Until then a save would stomp the saved position with the clock's zero.
    private var resumeFloor: Double
    private let startPosition: Double
    private var lastSave = Date.distantPast
    private var saves = 0
    private var audioPicked = false
    /// How long the overlay stays after a press.
    private static let overlaySeconds: TimeInterval = 4
    private var overlayUntil = Date.distantPast

    init(request: PlaybackRequest, progress: ProgressStore, settings: PlayerSettings,
         onClose: @escaping () -> Void) {
        self.request = request
        self.progress = progress
        self.settings = settings
        self.onClose = onClose
        resumeFloor = request.resumePosition ?? 0
        startPosition = request.resumePosition ?? 0
        overlay = PlayerOverlay(title: request.video.map { "\(request.meta.name)  \($0.seasonEpisodeCode)" } ?? request.meta.name)
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
        for sub in [focusView, surface, subtitleImage, subtitleText, overlay, readout] as [UIView] {
            view.addSubview(sub)
        }

        subtitleText.numberOfLines = 0
        subtitleText.textAlignment = .center
        subtitleText.textColor = .white
        subtitleText.font = .systemFont(ofSize: CGFloat(settings.subtitleSize), weight: .medium)
        subtitleText.shadowColor = .black
        subtitleText.shadowOffset = CGSize(width: 0, height: 2)

        readout.numberOfLines = 0
        readout.textColor = .white
        readout.font = .monospacedSystemFont(ofSize: 23, weight: .regular)
        readout.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        readout.layer.cornerRadius = 12
        readout.clipsToBounds = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(leavingApp), name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        focusView.frame = view.bounds
        surface.frame = view.bounds
        overlay.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Self.isPlaying = true
        setNeedsFocusUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardown()
    }

    private func start() {
        guard let engine else { return }
        engine.bind(view: surface)
        guard let raw = request.entry.stream.url, let url = URL(string: raw) else {
            failure = "This link has no direct URL"
            return
        }
        var options = LoadOptions(
            httpHeaders: request.entry.stream.behaviorHints?.proxyHeaders?.requestHeaders ?? [:],
            matchContentEnabled: view.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true,
            confirmAtmos: true
        )
        options.preferredAudioLanguages = audioLanguages()
        options.preferredSubtitleLanguages = subtitleLanguages()
        let resume = request.resumePosition
        loadTask = Task { [weak self] in
            do {
                let probe = try await engine.load(url: url, startPosition: resume, options: options)
                self?.probe = probe
            } catch is CancellationError {
            } catch {
                self?.failure = error.localizedDescription
            }
            // Left mid-load: the load outlives the stop, so stop what it started.
            if self?.closed ?? true { engine.stop() }
        }
    }

    // MARK: Tracks

    /// What was picked by hand for this title, then the setting, then the
    /// device's own language. Never the file's first track: that may be a dub.
    private func audioLanguages() -> [String] {
        let device = Locale.preferredLanguages.first.map { String($0.prefix(2)) }
        let wanted = [PlaybackMemory.memory(for: request.meta.id)?.audioLanguage,
                      settings.preferredAudioLanguage, device]
        var out: [String] = []
        for case let language? in wanted where !language.isEmpty && !out.contains(language) {
            out.append(language)
        }
        return out
    }

    private func subtitleLanguages() -> [String] {
        if let picked = PlaybackMemory.memory(for: request.meta.id)?.subtitleLanguage {
            return picked == "off" ? [] : [picked]
        }
        return settings.subtitlesOnByDefault ? [settings.preferredSubtitleLanguage] : []
    }

    /// TrueHD loses its objects in the bridge, so E-AC-3 Atmos in the same
    /// language plays instead. Atmos is confirmed during playback, hence here.
    private func preferAtmos(_ engine: AetherEngine) {
        guard !audioPicked,
              let active = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }),
              active.codec.lowercased() == "truehd",
              let atmos = engine.audioTracks.first(where: {
                  $0.isAtmos && $0.codec.lowercased() == "eac3" && !$0.isCommentary
                      && $0.language == active.language
              }) else { return }
        audioPicked = true
        Task { try? await engine.selectAudioTrack(index: atmos.id) }
    }

    // MARK: Progress

    private var position: Double {
        max(engine?.currentTime ?? 0, resumeFloor)
    }

    private var counts: Bool {
        hasPlayed && played >= Self.countsAfterSeconds && !request.isDemo
    }

    /// Transient: a publish would redraw Home behind the player.
    private func save(_ engine: AetherEngine) {
        lastSave = Date()
        progress.updateTransient(
            meta: request.meta, video: request.video, streamURL: request.entry.stream.url,
            position: position, duration: engine.duration,
            signature: request.entry.stream.signature(addonName: request.entry.addonName)
        )
    }

    /// To the device every 10 s, to the account on the first save and every 30 s.
    private func saveDuringPlayback(_ engine: AetherEngine) {
        guard counts, Date().timeIntervalSince(lastSave) > Self.saveInterval else { return }
        save(engine)
        saves &+= 1
        if saves == 1 || saves % 3 == 0 { progress.requestSyncPush() }
    }

    /// Pausing or leaving the app: now, to both.
    private func saveAndPush() {
        guard counts, !closed, let engine else { return }
        save(engine)
        progress.requestSyncPush()
    }

    @objc private func leavingApp() { saveAndPush() }

    /// Publishes, and `update` pushes. The end counts however little was played.
    private func saveFinal() {
        guard let engine, hasPlayed, !request.isDemo else { return }
        let ended = engine.state == .ended
        guard ended || counts else { return }
        progress.update(
            meta: request.meta, video: request.video, streamURL: request.entry.stream.url,
            position: ended ? engine.duration : position, duration: engine.duration,
            signature: request.entry.stream.signature(addonName: request.entry.addonName)
        )
    }

    /// Walked out early, the link was probably bad and the next try skips it.
    private func recordLinkVerdict() {
        guard let engine, engine.duration > 60, !request.isDemo else { return }
        let title = ProgressStore.key(metaID: request.meta.id, video: request.video)
        let key = request.entry.rejectionKey
        if hasPlayed, position - startPosition >= Self.provenLinkSeconds {
            RejectedLinks.keep(key, for: title)
        } else {
            RejectedLinks.reject(key, for: title)
        }
    }

    private func close() {
        teardown()
        onClose()
    }

    /// Runs however the player goes: its own Back, or the system dismissing it
    /// with the press never reaching us.
    private func teardown() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        saveFinal()
        recordLinkVerdict()
        loadTask?.cancel()
        engine?.stop()
        Self.isPlaying = false
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, let engine else {
            if presses.first?.type == .menu { close() }
            return
        }
        overlayUntil = Date().addingTimeInterval(Self.overlaySeconds)
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
        let target = max(0, position + seconds)
        resumeFloor = 0
        Task { await engine.seek(to: target) }
    }

    private func nextAudio() {
        guard let engine, !engine.audioTracks.isEmpty else { return }
        let tracks = engine.audioTracks
        let now = tracks.firstIndex { $0.id == engine.activeAudioTrackIndex } ?? -1
        let next = tracks[(now + 1) % tracks.count]
        audioPicked = true
        PlaybackMemory.update(request.meta.id) { $0.audioLanguage = next.language }
        Task { try? await engine.selectAudioTrack(index: next.id) }
    }

    private func nextSubtitle() {
        guard let engine, !engine.subtitleTracks.isEmpty else { return }
        let tracks = engine.subtitleTracks
        let now = tracks.firstIndex { $0.id == engine.activeSubtitleTrackIndex } ?? -1
        if now + 1 < tracks.count {
            let next = tracks[now + 1]
            engine.selectSubtitleTrack(index: next.id)
            PlaybackMemory.update(request.meta.id) { $0.subtitleLanguage = next.language }
        } else {
            engine.clearSubtitle()
            PlaybackMemory.update(request.meta.id) { $0.subtitleLanguage = "off" }
        }
    }

    // MARK: Screen

    private func tick() {
        if let engine {
            if engine.state == .ended { close(); return }
            // A resume reads near zero until its seek lands.
            if engine.state == .playing, engine.currentTime > 0, engine.currentTime >= resumeFloor - 5 {
                hasPlayed = true
                resumeFloor = 0
            }
            if hasPlayed, engine.state == .playing { played += Self.tickInterval }
            let paused = engine.state == .paused
            if paused, !wasPaused { saveAndPush() }
            wasPaused = paused
            showSubtitle(engine)
            preferAtmos(engine)
            saveDuringPlayback(engine)
            updateOverlay(engine)
        }
        let showReadout = failure != nil || PerformanceSettingsStore.shared.settings.showPlayerDiagnostics
        readout.isHidden = !showReadout
        guard showReadout else { return }
        readout.text = "  " + lines().joined(separator: "  \n  ") + "  "
        let size = readout.sizeThatFits(CGSize(width: 1200, height: 900))
        readout.frame = CGRect(x: 60, y: 40, width: size.width, height: size.height + 16)
    }

    private func updateOverlay(_ engine: AetherEngine) {
        let waiting = !hasPlayed || engine.state == .seeking || engine.isBuffering
        overlay.update(
            time: position, duration: engine.duration,
            audio: audioLabel(engine), subtitle: subtitleLabel(engine),
            state: engine.state == .paused ? "Paused" : nil, waiting: waiting
        )
        overlay.setShown(engine.state == .paused || !hasPlayed || Date() < overlayUntil)
    }

    private func audioLabel(_ engine: AetherEngine) -> String {
        guard let track = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) else { return "" }
        let extra = track.isAtmos ? "Atmos" : track.isDTSX ? "DTS:X" : "\(track.channels) ch"
        return "\(languageName(track.language)), \(track.codec.uppercased()) \(extra)"
    }

    private func subtitleLabel(_ engine: AetherEngine) -> String {
        guard let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else {
            return "Subtitles off"
        }
        return "Subtitles: \(languageName(track.language))"
    }

    private func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
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
        subtitleText.frame = CGRect(x: 150, y: view.bounds.height - (overlay.isShown ? 230 : 90) - height, width: width, height: height)

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
