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
/// `ProgressStore` calls the sync reads. Remote: select pause, left/right or a
/// swipe scrub, up the Audio and Subtitles buttons, down back to the timeline,
/// Back out.
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
    var takesFocus = true
    override var canBecomeFocused: Bool { takesFocus }
}

/// The app's one glass, as a backing for UIKit controls.
private final class GlassBacking: UIView {
    private let host: UIViewController

    init<S: Shape>(_ shape: S) {
        host = UIHostingController(rootView: Color.clear.liquidGlass(in: shape))
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
}

/// A round glass button; focused white with a dark icon, 5 % larger. Focusable
/// only while the buttons are in use, so the arrows scrub during playback.
private final class PlayerButton: UIButton {
    static let size: CGFloat = 72

    var takesFocus = false
    private let glass = GlassBacking(Circle())
    private let platter = UIView()

    init(icon: String, label: String) {
        super.init(frame: .zero)
        accessibilityLabel = label
        let symbol = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        setImage(UIImage(systemName: icon, withConfiguration: symbol)?.withRenderingMode(.alwaysTemplate), for: .normal)
        adjustsImageWhenHighlighted = false
        tintColor = UIColor.white.withAlphaComponent(FixedFocusText.primary)
        platter.backgroundColor = .white
        platter.alpha = 0
        platter.isUserInteractionEnabled = false
        insertSubview(glass, at: 0)
        insertSubview(platter, at: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { takesFocus && super.canBecomeFocused }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        platter.frame = bounds
        platter.layer.cornerRadius = bounds.width / 2
        imageView.map(bringSubviewToFront)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations {
            self.platter.alpha = focused ? 1 : 0
            self.tintColor = focused ? UIColor.black.withAlphaComponent(0.85)
                                     : UIColor.white.withAlphaComponent(FixedFocusText.primary)
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}

/// One track: nothing at rest, focused a white capsule, as the hold menus' rows.
private final class TrackCell: UICollectionViewCell {
    static let height: CGFloat = 66

    private let platter = UIView()
    private let check = UIImageView()
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        platter.backgroundColor = .white
        platter.alpha = 0
        check.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        check.contentMode = .center
        title.font = .systemFont(ofSize: 28, weight: .medium)
        for sub in [platter, check, title] as [UIView] { contentView.addSubview(sub) }
        paint(focused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: TrackList.Row) {
        title.text = row.title
        check.isHidden = !row.active
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = contentView.bounds.insetBy(dx: 6, dy: 0)
        platter.frame = inner
        platter.layer.cornerRadius = inner.height / 2
        check.frame = CGRect(x: inner.minX + 18, y: 0, width: 28, height: inner.height)
        title.frame = CGRect(x: inner.minX + 62, y: 0, width: inner.width - 90, height: inner.height)
    }

    private func paint(focused: Bool) {
        let color = focused ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        title.textColor = color
        check.tintColor = color
        platter.alpha = focused ? 1 : 0
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations { self.paint(focused: focused) }
    }
}

/// The tracks to pick from: a glass panel rising from its button. A collection
/// view: a tvOS table spaces its rows out and fades its edges.
private final class TrackList: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    struct Row {
        let title: String
        let active: Bool
        let pick: () -> Void
    }

    static let width: CGFloat = 620
    private static let inset: CGFloat = 16
    private static let maxHeight: CGFloat = 640

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: TrackCell.height / 2 + inset, style: .continuous))
    private let list: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: width - inset * 2, height: TrackCell.height)
        layout.minimumLineSpacing = 0
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private var rows: [Row] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        list.backgroundColor = .clear
        list.contentInsetAdjustmentBehavior = .never
        list.dataSource = self
        list.delegate = self
        list.remembersLastFocusedIndexPath = false
        list.register(TrackCell.self, forCellWithReuseIdentifier: "row")
        addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [list] }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        list.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    /// Unfolds out of its bottom right corner. Its alpha lands at 1 at once:
    /// tvOS wouldn't focus into it otherwise.
    func open(_ rows: [Row], rightEdge: CGFloat, bottom: CGFloat) {
        self.rows = rows
        transform = .identity
        let height = min(CGFloat(rows.count) * TrackCell.height + Self.inset * 2, Self.maxHeight)
        frame = CGRect(x: rightEdge - Self.width, y: bottom - height, width: Self.width, height: height)
        list.reloadData()
        layoutIfNeeded()
        isHidden = false
        alpha = 0
        transform = CGAffineTransform(translationX: Self.width * 0.2, y: height * 0.2).scaledBy(x: 0.6, y: 0.6)
        UIView.animate(withDuration: Motion.presentDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func close() {
        guard !isHidden else { return }
        UIView.animate(withDuration: Motion.fadeDuration) { self.alpha = 0 } completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        (cell as? TrackCell)?.show(rows[indexPath.item])
        return cell
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        rows.firstIndex(where: \.active).map { IndexPath(item: $0, section: 0) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        rows[indexPath.item].pick()
    }
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
    private let held = UIView()
    private let fill = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let preview = UIImageView()
    private var fraction: CGFloat = 0
    private var heldSpan: (from: CGFloat, to: CGFloat) = (0, 0)
    private static let barHeight: CGFloat = 6
    /// The timeline with the remote on it.
    private static let barActive: CGFloat = 1.67

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
        bar.layer.cornerRadius = Self.barHeight / 2
        bar.clipsToBounds = true
        fill.backgroundColor = UIColor.white.withAlphaComponent(0.75)
        held.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        bar.addSubview(held)
        bar.addSubview(fill)
        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = .black
        preview.layer.cornerRadius = Spotlight.cornerRadius
        preview.layer.cornerCurve = .continuous
        preview.clipsToBounds = true
        preview.isHidden = true
        for sub in [title, state, tracks, elapsed, remaining, bar, preview] as [UIView] {
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
        title.frame = CGRect(x: inset, y: bounds.height - 200, width: width - 500, height: 40)
        state.frame = CGRect(x: inset + width - 400, y: bounds.height - 196, width: 200, height: 32)
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        bar.center = CGPoint(x: bounds.midX, y: bounds.height - 143)
        fill.frame = CGRect(x: 0, y: 0, width: width * fraction, height: Self.barHeight)
        placeHeld()
        elapsed.frame = CGRect(x: inset, y: bounds.height - 126, width: 200, height: 32)
        remaining.frame = CGRect(x: inset + width - 200, y: bounds.height - 126, width: 200, height: 32)
        tracks.frame = CGRect(x: inset + 200, y: bounds.height - 126, width: width - 400, height: 32)
        tracks.textAlignment = .center
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        placePreview()
    }

    private func placeHeld() {
        let width = bar.bounds.width
        held.frame = CGRect(x: width * heldSpan.from, y: 0,
                            width: width * max(heldSpan.to - heldSpan.from, 0), height: Self.barHeight)
    }

    private func placePreview() {
        let size = CGSize(width: 480, height: 270)
        let x = min(max(bar.frame.minX + bar.bounds.width * fraction - size.width / 2, bar.frame.minX),
                    bar.frame.maxX - size.width)
        preview.frame = CGRect(x: x, y: bounds.height - 250 - size.height, width: size.width, height: size.height)
    }

    /// nil: time only (no still for that spot yet).
    func setPreview(_ image: CGImage?) {
        guard image !== preview.image?.cgImage else { return }
        preview.image = image.map { UIImage(cgImage: $0) }
        preview.isHidden = image == nil
    }

    func setTitle(_ text: String) { title.text = text }

    func move(time: Double, duration: Double) {
        fraction = duration > 0 ? CGFloat(min(max(time / duration, 0), 1)) : 0
        fill.frame.size.width = bar.bounds.width * fraction
        placePreview()
        elapsed.text = duration > 0 ? Self.clock(time) : nil
        remaining.text = duration > 0 ? "-" + Self.clock(max(duration - time, 0)) : nil
    }

    /// What's on disk ahead of the playhead, a shade over the empty bar.
    func setHeld(from start: Double, to end: Double, duration: Double) {
        guard duration > 0 else { return }
        heldSpan = (CGFloat(min(max(start / duration, 0), 1)), CGFloat(min(max(end / duration, 0), 1)))
        placeHeld()
    }

    func update(time: Double, duration: Double, audio: String, subtitle: String, state text: String?, waiting: Bool) {
        move(time: time, duration: duration)
        tracks.text = audio.isEmpty ? nil : "\(audio)  ·  \(subtitle)"
        state.text = text
        if waiting != spinner.isAnimating {
            if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    func setTimelineActive(_ active: Bool) {
        UIView.animate(withDuration: Motion.focusDuration) {
            self.bar.transform = active ? CGAffineTransform(scaleX: 1, y: Self.barActive) : .identity
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

/// What IntroDB knows of an episode or film: community timings, by IMDb id.
struct PlayerSegments {
    var recap: Range<Double>?
    var intro: Range<Double>?
    var outro: Range<Double>?

    static func fetch(meta: MetaItem, video: MetaVideo?) async -> PlayerSegments? {
        guard let id = ((video?.id ?? meta.id).firstMatch(of: /tt\d{6,}/) ?? meta.id.firstMatch(of: /tt\d{6,}/))
            .map({ String($0.output) }),
            var parts = URLComponents(string: "https://api.introdb.app/segments") else { return nil }
        parts.queryItems = [URLQueryItem(name: "imdb_id", value: id)]
        if let video {
            guard let season = video.season, let episode = video.episode else { return nil }
            parts.queryItems? += [URLQueryItem(name: "season", value: String(season)),
                                  URLQueryItem(name: "episode", value: String(episode))]
        } else {
            parts.queryItems?.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        guard let url = parts.url,
              let (data, reply) = try? await URLSession.shared.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PlayerSegments(recap: span(json["recap"]), intro: span(json["intro"]), outro: span(json["outro"]))
    }

    private static func span(_ value: Any?) -> Range<Double>? {
        guard let segment = value as? [String: Any],
              let start = seconds(segment["start_sec"]), let end = seconds(segment["end_sec"]),
              start < end else { return nil }
        return start..<end
    }

    /// A number, or "mm:ss".
    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        guard let text = value as? String else { return nil }
        return text.split(separator: ":").reduce(0.0 as Double?) { total, part in
            guard let total, let part = Double(part) else { return nil }
            return total * 60 + part
        }
    }
}

/// Bottom right, above the controls: Skip Intro, or the next episode as a card
/// with its picture. Glass at rest; focused white with dark content, 5 % larger.
/// The controller takes its Select: no button, so nothing fires twice.
private final class PlayerPrompt: UIView {
    private static let pillHeight: CGFloat = 72
    private static let cardWidth: CGFloat = 420
    private static let cardPadding: CGFloat = 16
    private static let pictureHeight: CGFloat = (cardWidth - cardPadding * 2) * 9 / 16

    var takesFocus = false
    override var canBecomeFocused: Bool { takesFocus }

    private let glass = GlassBacking(RoundedRectangle(cornerRadius: Spotlight.cornerRadius, style: .continuous))
    private let pillGlass = GlassBacking(Capsule())
    private let platter = UIView()
    private let picture = UIImageView()
    private let heading = UILabel()
    private let detail = UILabel()
    private var isCard = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        platter.backgroundColor = .white
        platter.alpha = 0
        platter.layer.cornerCurve = .continuous
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = Spotlight.cornerRadius - Self.cardPadding / 2
        picture.layer.cornerCurve = .continuous
        heading.font = .systemFont(ofSize: 25, weight: .medium)
        detail.font = .systemFont(ofSize: 24)
        for sub in [glass, pillGlass, platter, picture, heading, detail] as [UIView] { addSubview(sub) }
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showPill(_ text: String) {
        isCard = false
        heading.text = text
        detail.text = nil
        picture.image = nil
        place()
    }

    func showCard(heading text: String, detail second: String, picture image: UIImage?) {
        isCard = true
        heading.text = text
        detail.text = second
        picture.image = image
        place()
    }

    func setHeading(_ text: String) { heading.text = text }

    /// Its bottom right corner stays where it is.
    private func place() {
        let right = frame.maxX, bottom = frame.maxY
        let size = isCard
            ? CGSize(width: Self.cardWidth, height: Self.cardPadding * 2 + Self.pictureHeight + 86)
            : CGSize(width: heading.intrinsicContentSize.width + 72, height: Self.pillHeight)
        transform = .identity
        frame = CGRect(x: right - size.width, y: bottom - size.height, width: size.width, height: size.height)
        glass.isHidden = !isCard
        pillGlass.isHidden = isCard
        picture.isHidden = !isCard
        detail.isHidden = !isCard
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        pillGlass.frame = bounds
        platter.frame = bounds
        platter.layer.cornerRadius = isCard ? Spotlight.cornerRadius : bounds.height / 2
        guard isCard else {
            heading.frame = bounds.insetBy(dx: 36, dy: 0)
            heading.textAlignment = .center
            return
        }
        let inset = Self.cardPadding
        let width = bounds.width - inset * 2
        picture.frame = CGRect(x: inset, y: inset, width: width, height: Self.pictureHeight)
        heading.textAlignment = .left
        heading.frame = CGRect(x: inset, y: picture.frame.maxY + 12, width: width, height: 32)
        detail.frame = CGRect(x: inset, y: heading.frame.maxY + 2, width: width, height: 32)
    }

    private func restyle() {
        heading.textColor = isFocused ? UIColor.black.withAlphaComponent(0.85)
                                      : UIColor.white.withAlphaComponent(FixedFocusText.primary)
        detail.textColor = isFocused ? UIColor.black.withAlphaComponent(0.65)
                                     : UIColor.white.withAlphaComponent(FixedFocusText.secondary)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations {
            self.platter.alpha = focused ? 1 : 0
            self.restyle()
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}

final class PlayerController: UIViewController, UIGestureRecognizerDelegate {
    /// What's on disk around the playhead: 10 minutes ahead at most, and the
    /// budget (the engine keeps it under a quarter of free space) holds that
    /// and what's behind. Seeks and stills inside it never touch the network.
    private static let windowSegments = 150
    private static let windowBytes = 6 << 30

    /// Background preloading stands down while a title plays.
    private(set) static var isPlaying = false

    private static let tickInterval: TimeInterval = 0.2
    /// Played this long in a session, it counts. Until then nothing is saved,
    /// so a Start Over keeps its old position.
    private static let countsAfterSeconds: Double = 30
    /// Worst-case loss if the app dies: periodic saves reach disk this often.
    private static let saveInterval: TimeInterval = 10
    /// Links tried silently after the first, then the source list.
    private static let maxRetries = 3
    /// No first frame by then: the link counts as failed.
    private static let firstFrameSeconds: TimeInterval = 20

    /// The episode playing: the player stays open from one to the next.
    private var meta: MetaItem
    private var video: MetaVideo?
    private var resume: Double?
    private var links: [StreamEntry]
    private let isDemo: Bool
    private let progress: ProgressStore
    private let settings: PlayerSettings
    private let onClose: () -> Void
    private let engine: AetherEngine?

    private let focusView = PlayerFocusView()
    private let surface = AetherPlayerView()
    private let subtitleText = UILabel()
    private let subtitleImage = UIImageView()
    private let overlay: PlayerOverlay
    private let audioButton = PlayerButton(icon: "waveform", label: "Audio")
    private let subtitleButton = PlayerButton(icon: "captions.bubble", label: "Subtitles")
    private let trackList = TrackList()
    private let promptView = PlayerPrompt()
    private let readout = UILabel()

    /// The link playing, once failover has moved on from the request's.
    private var entry: StreamEntry
    private var tried: [String]
    private var loadStarted = Date()
    /// Tells a superseded load from the current one.
    private var attempt = 0

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
    private var lastSave = Date.distantPast
    private var saves = 0
    private var audioPicked = false
    /// How long the overlay stays after a press.
    private static let overlaySeconds: TimeInterval = 4
    private var overlayUntil = Date.distantPast
    /// Back put them away: they stay gone, even paused, until the next press.
    private var controlsDismissed = false

    /// A press moves the target this far, paused or playing.
    private static let scrubStep: Double = 10
    /// Paused, a swipe is fine control: about 30 s across the pad, whatever the
    /// title's length, so going far stays a job for the scan.
    private static let swipeSecondsPerPoint: Double = 0.02
    /// A swipe lets go with its speed and eases out over this.
    private static let glideSeconds: Double = 0.25
    private static let glideStop: Double = 1
    /// Playing, a press held this long starts the scan, which goes on by itself.
    private static let scanHoldSeconds: TimeInterval = 0.5
    /// The scan's slider, in seconds of title per second. The picture is paused:
    /// the engine plays 2× at most and never backwards.
    private static let scanSpeeds: [Double] = [8, 24, 60]
    /// The seek waits this long after the last input, so a run of inputs is one seek.
    private static let scrubCommitSeconds: TimeInterval = 0.3
    /// The bar follows at this rate; the swipe comes in at twice it.
    private static let scrubDrawInterval: TimeInterval = 1.0 / 30
    private static let stillWidth = 480
    /// Past what's on disk, a still waits for the target to stop.
    private static let stillSettleSeconds: TimeInterval = 0.3

    /// Where the viewer is scrubbing to; playback goes on until it lands.
    private var scrubTarget: Double?
    private var scrubCommitAt = Date.distantPast
    private var lastScrubDraw = Date.distantPast
    /// Where a commit is going: the bar stays there until the seek is done.
    private var landing: Double?
    /// The arrow going down, until it's up or the scan takes over.
    private var holdDirection: Double = 0
    private var holdWait: Task<Void, Never>?
    private var scan: (direction: Double, level: Int)?
    private var glide: Double = 0
    private var runLink: CADisplayLink?
    private var panning = false
    private var panLast: CGFloat = 0
    private var previewBusy = false
    /// Stills for what the engine doesn't hold: its own connection to the link,
    /// made at the first such scrub.
    private var stills: FrameExtractor?

    /// A skip left alone goes after this; it's back while the controls are up.
    private static let skipSeconds: TimeInterval = 10
    /// Without an outro from IntroDB, the next episode comes up this long before the end.
    private static let nextLeadSeconds: Double = 120
    /// Its link is looked for this much before it comes up.
    private static let nextSearchSeconds: Double = 60
    /// Between the end of the file and the next episode playing by itself.
    private static let nextCountdown: TimeInterval = 5

    private enum Prompt: Equatable {
        case skip(String, to: Double)
        case next
    }

    private var segments: PlayerSegments?
    private var segmentsTask: Task<Void, Never>?
    private var prompt: Prompt?
    private var promptSince = Date.distantPast
    private var dismissedPrompt: Prompt?
    private var nextUp: PlayLauncher.NextEpisode?
    private var nextPicture: UIImage?
    private var nextTask: Task<Void, Never>?
    private var nextSearched = false
    private var endedAt: Date?

    private enum Menu { case none, buttons, tracks }
    private var menu = Menu.none
    /// The button to come back to from its list.
    private weak var lastButton: PlayerButton?

    init(request: PlaybackRequest, progress: ProgressStore, settings: PlayerSettings,
         onClose: @escaping () -> Void) {
        meta = request.meta
        video = request.video
        resume = request.resumePosition
        links = request.allEntries
        isDemo = request.isDemo
        self.progress = progress
        self.settings = settings
        self.onClose = onClose
        resumeFloor = request.resumePosition ?? 0
        entry = request.entry
        tried = [request.entry.rejectionKey]
        overlay = PlayerOverlay(title: Self.title(request.meta, request.video))
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

    private static func title(_ meta: MetaItem, _ video: MetaVideo?) -> String {
        video.map { "\(meta.name)  \($0.seasonEpisodeCode)" } ?? meta.name
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch menu {
        case .none: return [promptView.takesFocus ? promptView : focusView]
        case .buttons: return [lastButton ?? audioButton]
        case .tracks: return [trackList]
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for sub in [focusView, surface, subtitleImage, subtitleText, overlay, audioButton, subtitleButton,
                    trackList, promptView, readout] as [UIView] {
            view.addSubview(sub)
        }

        for button in [audioButton, subtitleButton] {
            button.alpha = 0
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.openTracks(from: button)
            }, for: .primaryActionTriggered)
        }
        trackList.isHidden = true
        overlay.setTimelineActive(true)

        let back = UITapGestureRecognizer(target: self, action: #selector(backPressed))
        back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(back)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        view.addGestureRecognizer(pan)

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
        let bounds = view.bounds
        let size = PlayerButton.size
        subtitleButton.bounds.size = CGSize(width: size, height: size)
        audioButton.bounds.size = CGSize(width: size, height: size)
        subtitleButton.center = CGPoint(x: bounds.width - 80 - size / 2, y: bounds.height - 196)
        audioButton.center = CGPoint(x: bounds.width - 80 - size * 1.5 - 20, y: bounds.height - 196)
        if promptView.frame.isEmpty {
            promptView.frame = CGRect(x: bounds.width - 80, y: bounds.height - 250, width: 0, height: 0)
        }
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
        loadSegments()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardown()
    }

    private func start() {
        guard let engine else { return }
        engine.bind(view: surface)
        guard let raw = entry.stream.url, let url = URL(string: raw) else {
            linkFailed()
            return
        }
        attempt += 1
        let attempt = attempt
        loadStarted = Date()
        var options = LoadOptions(
            httpHeaders: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders ?? [:],
            matchContentEnabled: view.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true,
            confirmAtmos: true
        )
        options.forwardBufferSegments = Self.windowSegments
        options.sessionCacheByteBudget = Self.windowBytes
        options.softwarePacketCacheStorage = .disk
        options.preferredAudioLanguages = audioLanguages()
        options.preferredSubtitleLanguages = subtitleLanguages()
        let resume = resume
        loadTask = Task { [weak self] in
            do {
                let probe = try await engine.load(url: url, startPosition: resume, options: options)
                self?.probe = probe
            } catch is CancellationError {
            } catch {
                if self?.attempt == attempt { self?.linkFailed() }
            }
            // Left mid-load: the load outlives the stop, so stop what it started.
            if self?.closed ?? true { engine.stop() }
        }
    }

    /// Before the first frame, the next link in the add-ons' order, silently;
    /// out of tries or links, the source list.
    private func linkFailed() {
        guard !closed, !hasPlayed else { return }
        let links = PlayLauncher.shared.links(meta, video) ?? links
        let next = links.first {
            !$0.stream.isExternal && !$0.stream.isTorrent && !tried.contains($0.rejectionKey)
        }
        guard tried.count <= Self.maxRetries, let next else {
            let (meta, video, fromStart) = (meta, video, resume == nil)
            close()
            SourcePicker.shared.open(meta, video, fromStart: fromStart)
            return
        }
        tried.append(next.rejectionKey)
        entry = next
        loadTask?.cancel()
        dropStills()
        engine?.stop()
        start()
    }

    // MARK: Tracks

    /// What was picked by hand for this title, then the setting, then the
    /// device's own language. Never the file's first track: that may be a dub.
    private func audioLanguages() -> [String] {
        let device = Locale.preferredLanguages.first.map { String($0.prefix(2)) }
        let wanted = [PlaybackMemory.memory(for: meta.id)?.audioLanguage,
                      settings.preferredAudioLanguage, device]
        var out: [String] = []
        for case let language? in wanted where !language.isEmpty && !out.contains(language) {
            out.append(language)
        }
        return out
    }

    private func subtitleLanguages() -> [String] {
        if let picked = PlaybackMemory.memory(for: meta.id)?.subtitleLanguage {
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
        hasPlayed && played >= Self.countsAfterSeconds && !isDemo
    }

    /// Transient: a publish would redraw Home behind the player.
    private func save(_ engine: AetherEngine) {
        lastSave = Date()
        progress.updateTransient(
            meta: meta, video: video, streamURL: entry.stream.url,
            position: position, duration: engine.duration,
            signature: entry.stream.signature(addonName: entry.addonName)
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

    /// Publishes, and `update` pushes. The end counts however little was played;
    /// going on to the next episode is the end.
    private func saveFinal(finished: Bool = false) {
        guard let engine, hasPlayed, !isDemo else { return }
        let ended = finished || engine.state == .ended
        guard ended || counts else { return }
        progress.update(
            meta: meta, video: video, streamURL: entry.stream.url,
            position: ended ? engine.duration : position, duration: engine.duration,
            signature: entry.stream.signature(addonName: entry.addonName)
        )
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
        endScrub()
        saveFinal()
        loadTask?.cancel()
        segmentsTask?.cancel()
        nextTask?.cancel()
        dropStills()
        engine?.stop()
        Self.isPlaying = false
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, let engine else { return }
        // Back is `backPressed`'s: here it would bring the controls back up.
        guard press.type != .menu else {
            super.pressesBegan(presses, with: event)
            return
        }
        if press.type == .select, promptView.takesFocus {
            promptPressed(engine)
            return
        }
        showControls()
        if menu != .none {
            switch press.type {
            case .downArrow where menu == .buttons: setMenu(.none)
            case .playPause: engine.togglePlayPause()
            default: super.pressesBegan(presses, with: event)
            }
            return
        }
        switch press.type {
        case .select where scrubTarget != nil, .playPause where scrubTarget != nil: commitScrub(resume: true)
        case .select, .playPause: engine.togglePlayPause()
        case .leftArrow: arrowPressed(-1)
        case .rightArrow: arrowPressed(1)
        case .upArrow where scan == nil: setMenu(.buttons)
        case .downArrow: break
        default: super.pressesBegan(presses, with: event)
        }
    }

    /// A recognizer, not `pressesBegan`: with a button or list focused, the
    /// system takes Back first and dismisses the player.
    @objc private func backPressed() {
        switch menu {
        case .tracks:
            setMenu(.buttons)
        case .buttons:
            setMenu(.none)
            hideControls()
        case .none:
            if scan != nil {
                commitScrub(resume: true)
            } else if scrubTarget != nil {
                endScrub()
                showControls()
            } else if hasPlayed, overlay.isShown {
                hideControls()
            } else if promptView.alpha > 0, let prompt {
                dismissedPrompt = prompt
                if let engine { updatePrompt(engine) }
            } else {
                close()
            }
        }
    }

    private func showControls() {
        controlsDismissed = false
        overlayUntil = Date().addingTimeInterval(Self.overlaySeconds)
    }

    private func hideControls() {
        controlsDismissed = true
        if let engine { updateOverlay(engine) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endHold(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endHold(presses)
        super.pressesCancelled(presses, with: event)
    }

    // MARK: Scrubbing

    private func moveScrub(to seconds: Double) {
        guard let engine, hasPlayed, engine.duration > 0 else { return }
        scrubTarget = min(max(seconds, 0), max(engine.duration - 1, 0))
        scrubCommitAt = Date().addingTimeInterval(Self.scrubCommitSeconds)
        guard let target = scrubTarget else { return }
        loadPreview()
        guard Date().timeIntervalSince(lastScrubDraw) >= Self.scrubDrawInterval else { return }
        lastScrubDraw = Date()
        overlay.move(time: target, duration: engine.duration)
    }

    private var isFine: Bool { engine?.state == .paused && scan == nil }

    private func arrowPressed(_ direction: Double) {
        if scan != nil {
            shiftScan(direction)
        } else if panning, scrubTarget != nil {
            // A swipe ending in a click on the pad's edge.
            commitScrub(resume: true)
        } else {
            glide = 0
            moveScrub(to: (scrubTarget ?? position) + direction * Self.scrubStep)
            if scrubTarget != nil, !isFine { waitForHold(direction) }
        }
    }

    private func waitForHold(_ direction: Double) {
        holdDirection = direction
        holdWait?.cancel()
        holdWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.scanHoldSeconds))
            guard let self, !Task.isCancelled, self.holdDirection == direction else { return }
            self.holdDirection = 0
            self.scan = (direction, 0)
            self.engine?.pause()
            self.startRun()
        }
    }

    private func endHold(_ presses: Set<UIPress>) {
        guard presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) else { return }
        stopHold()
        scrubCommitAt = Date().addingTimeInterval(Self.scrubCommitSeconds)
    }

    private func stopHold() {
        holdDirection = 0
        holdWait?.cancel()
    }

    /// The same way, faster; the other way, slower, and through the slowest
    /// speed it turns round.
    private func shiftScan(_ direction: Double) {
        guard let current = scan else { return }
        if direction == current.direction {
            scan?.level = min(current.level + 1, Self.scanSpeeds.count - 1)
        } else if current.level > 0 {
            scan?.level = current.level - 1
        } else {
            scan?.direction = direction
        }
    }

    private func startRun() {
        guard runLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(runStep))
        link.add(to: .main, forMode: .common)
        runLink = link
    }

    private func stopRun() {
        glide = 0
        runLink?.invalidate()
        runLink = nil
    }

    @objc private func runStep(_ link: CADisplayLink) {
        guard let target = scrubTarget, let engine else { return stopRun() }
        if let scan {
            let next = target + scan.direction * Self.scanSpeeds[scan.level] * link.duration
            moveScrub(to: next)
            if next <= 0 || next >= engine.duration - 1 { commitScrub(resume: true) }
        } else {
            moveScrub(to: target + glide * link.duration)
            glide *= exp(-link.duration / Self.glideSeconds)
            if abs(glide) < Self.glideStop { stopRun() }
        }
    }

    private func tickScrub() {
        guard scrubTarget != nil, holdDirection == 0, scan == nil, !panning, !isFine,
              Date() > scrubCommitAt else { return }
        commitScrub()
    }

    private func commitScrub(resume: Bool = false) {
        guard let engine, let target = scrubTarget else { return }
        endScrub()
        resumeFloor = 0
        landing = target
        Task {
            await engine.seek(to: target)
            if resume { engine.play() }
            landing = nil
        }
    }

    private func endScrub() {
        scrubTarget = nil
        stopHold()
        scan = nil
        stopRun()
        overlay.setPreview(nil)
    }

    private func dropStills() {
        let old = stills
        stills = nil
        Task { await old?.shutdown() }
    }

    /// One still at a time, always for the latest target. What the engine holds
    /// comes first: the disk window, then its sparse stills across the title.
    private func loadPreview() {
        guard let engine, let target = scrubTarget, !previewBusy else { return }
        previewBusy = true
        let exact = isFine
        Task { [weak self] in
            guard let self else { return }
            let held = await engine.scrubPreviewFrame(atSeconds: target, refined: exact,
                                                      maxWidth: Self.stillWidth) { false }
            var image = held?.image
            if image == nil { image = await self.fetchStill(target, exact: exact) }
            self.previewBusy = false
            guard let latest = self.scrubTarget else { return }
            if let image { self.overlay.setPreview(image) }
            if latest != target { self.loadPreview() }
        }
    }

    private func fetchStill(_ target: Double, exact: Bool) async -> CGImage? {
        try? await Task.sleep(for: .seconds(Self.stillSettleSeconds))
        guard let engine, scrubTarget == target else { return nil }
        if stills == nil { stills = engine.makeFrameExtractor() }
        return exact ? await stills?.preview(at: target, maxWidth: Self.stillWidth)
                     : await stills?.thumbnail(at: target, maxWidth: Self.stillWidth)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return menu == .none && hasPlayed && isFine && abs(velocity.x) > abs(velocity.y)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            panning = true
            stopRun()
            panLast = pan.translation(in: view).x
        case .changed:
            let x = pan.translation(in: view).x
            defer { panLast = x }
            moveScrub(to: (scrubTarget ?? position) + Double(x - panLast) * Self.swipeSecondsPerPoint)
            showControls()
        default:
            panning = false
            glide = Double(pan.velocity(in: view).x) * Self.swipeSecondsPerPoint
            if abs(glide) >= Self.glideStop { startRun() }
        }
    }

    // MARK: Skip and next episode

    private func loadSegments() {
        guard !isDemo else { return }
        let (meta, video) = (meta, video)
        segmentsTask = Task { [weak self] in
            let found = await PlayerSegments.fetch(meta: meta, video: video)
            guard !Task.isCancelled else { return }
            self?.segments = found
        }
    }

    /// Where the next episode comes up: the outro, else two minutes before the end.
    private func nextStart(_ engine: AetherEngine) -> Double {
        segments?.outro?.lowerBound ?? engine.duration - Self.nextLeadSeconds
    }

    private func findNext(_ engine: AetherEngine) {
        guard !nextSearched, !isDemo, hasPlayed, let video, engine.duration > 0,
              position >= nextStart(engine) - Self.nextSearchSeconds else { return }
        nextSearched = true
        let (meta, current) = (meta, entry)
        nextTask = Task { [weak self] in
            let next = await PlayLauncher.shared.next(after: meta, video, current: current)
            var picture: UIImage?
            if let address = next?.video.thumbnail { picture = await Self.picture(address) }
            guard !Task.isCancelled else { return }
            self?.nextUp = next
            self?.nextPicture = picture
            self?.nextTask = nil
        }
    }

    private static func picture(_ address: String) async -> UIImage? {
        guard let url = URL(string: address),
              let data = try? await ImageCache.shared.download(url) else { return nil }
        return ImageCache.decodeDownsampled(data)
    }

    private func wantedPrompt(_ engine: AetherEngine) -> Prompt? {
        guard hasPlayed, menu != .tracks, engine.duration > 0 else { return nil }
        let time = landing ?? position
        if nextUp != nil, engine.state == .ended || time >= nextStart(engine) { return .next }
        if let recap = segments?.recap, recap.contains(time) { return .skip("Skip Recap", to: recap.upperBound) }
        if let intro = segments?.intro, intro.contains(time) { return .skip("Skip Intro", to: intro.upperBound) }
        if nextUp == nil, nextTask == nil, let outro = segments?.outro, outro.contains(time) {
            return .skip("Skip Credits", to: outro.upperBound)
        }
        return nil
    }

    private func updatePrompt(_ engine: AetherEngine) {
        let wanted = wantedPrompt(engine)
        if wanted != prompt {
            prompt = wanted
            promptSince = Date()
            switch wanted {
            case .skip(let label, _): promptView.showPill(label)
            case .next:
                if let nextUp {
                    let episode = [nextUp.video.seasonEpisodeCode, nextUp.video.title].compactMap { $0 }
                    promptView.showCard(heading: "Next Episode", detail: episode.joined(separator: "  "),
                                        picture: nextPicture)
                }
            case nil: break
            }
        }
        var shown = wanted != nil && wanted != dismissedPrompt
        if case .skip = wanted, Date().timeIntervalSince(promptSince) > Self.skipSeconds, !overlay.isShown {
            shown = false
        }
        let alpha: CGFloat = shown ? 1 : 0
        if promptView.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) { self.promptView.alpha = alpha }
        }
        // Scrubbing or paused, Select keeps its usual job.
        let focused = shown && menu == .none && scrubTarget == nil && scan == nil && engine.state != .paused
        guard focused != promptView.takesFocus else { return }
        promptView.takesFocus = focused
        focusView.takesFocus = !focused && menu == .none
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func promptPressed(_ engine: AetherEngine) {
        switch prompt {
        case .skip(_, let end):
            scrubTarget = min(end, max(engine.duration - 1, 0))
            commitScrub()
        case .next: playNext()
        case nil: break
        }
    }

    /// The next episode plays after a moment, unless Back put it away.
    private func reachedEnd(_ engine: AetherEngine) {
        guard dismissedPrompt != .next, !isDemo else { return close() }
        // Scrubbed to the very end: its link may still be coming.
        if nextTask != nil { return }
        guard nextUp != nil else { return close() }
        let ended = endedAt ?? Date()
        endedAt = ended
        updatePrompt(engine)
        let left = Self.nextCountdown - Date().timeIntervalSince(ended)
        guard left > 0 else { return playNext() }
        promptView.setHeading("Next in \(Int(left.rounded(.up)))")
    }

    /// The same player goes on: new link, new window, as a fresh start.
    private func playNext() {
        guard let next = nextUp else { return }
        endScrub()
        saveFinal(finished: true)
        loadTask?.cancel()
        segmentsTask?.cancel()
        dropStills()
        engine?.stop()

        meta = next.meta
        video = next.video
        entry = next.entry
        links = next.links
        resume = next.resume
        resumeFloor = next.resume ?? 0
        tried = [next.entry.rejectionKey]
        hasPlayed = false
        played = 0
        wasPaused = false
        lastSave = .distantPast
        saves = 0
        audioPicked = false
        landing = nil
        probe = nil
        segments = nil
        prompt = nil
        dismissedPrompt = nil
        nextUp = nil
        nextPicture = nil
        nextSearched = false
        endedAt = nil

        overlay.setTitle(Self.title(next.meta, next.video))
        promptView.alpha = 0
        promptView.takesFocus = false
        setMenu(.none)
        showControls()
        start()
        loadSegments()
    }

    // MARK: Picker

    private func setMenu(_ new: Menu) {
        if new != .none { commitScrub() }
        menu = new
        promptView.takesFocus = false
        focusView.takesFocus = new == .none
        for button in [audioButton, subtitleButton] {
            button.takesFocus = new == .buttons
            if new != .none { button.alpha = 1 }
        }
        if new != .tracks { trackList.close() }
        overlay.setTimelineActive(new == .none)
        showControls()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func openTracks(from button: PlayerButton) {
        guard let engine else { return }
        lastButton = button
        trackList.open(button === audioButton ? audioRows(engine) : subtitleRows(engine),
                       rightEdge: view.bounds.width - 80, bottom: view.bounds.height - 250)
        setMenu(.tracks)
    }

    private func audioRows(_ engine: AetherEngine) -> [TrackList.Row] {
        engine.audioTracks.map { track in
            TrackList.Row(title: audioTitle(track), active: track.id == engine.activeAudioTrackIndex) { [weak self] in
                self?.audioPicked = true
                PlaybackMemory.update(self?.meta.id ?? "") { $0.audioLanguage = track.language }
                Task { try? await engine.selectAudioTrack(index: track.id) }
                self?.setMenu(.none)
            }
        }
    }

    private func subtitleRows(_ engine: AetherEngine) -> [TrackList.Row] {
        let active = engine.subtitleTracks.first { $0.id == engine.activeSubtitleTrackIndex }
        let off = TrackList.Row(title: "Off", active: active == nil) { [weak self] in
            engine.clearSubtitle()
            PlaybackMemory.update(self?.meta.id ?? "") { $0.subtitleLanguage = "off" }
            self?.setMenu(.none)
        }
        return [off] + engine.subtitleTracks.map { track in
            TrackList.Row(title: subtitleTitle(track), active: track.id == active?.id) { [weak self] in
                engine.selectSubtitleTrack(index: track.id)
                PlaybackMemory.update(self?.meta.id ?? "") { $0.subtitleLanguage = track.language }
                self?.setMenu(.none)
            }
        }
    }

    // MARK: Screen

    private func tick() {
        if let engine {
            if engine.state == .ended { reachedEnd(engine); return }
            if !hasPlayed {
                var errored = false
                if case .error = engine.state { errored = true }
                if errored || Date().timeIntervalSince(loadStarted) > Self.firstFrameSeconds {
                    linkFailed()
                    return
                }
            }
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
            tickScrub()
            updateOverlay(engine)
            findNext(engine)
            updatePrompt(engine)
        }
        let showReadout = failure != nil || PerformanceSettingsStore.shared.settings.showPlayerDiagnostics
        readout.isHidden = !showReadout
        guard showReadout else { return }
        readout.text = "  " + lines().joined(separator: "  \n  ") + "  "
        let size = readout.sizeThatFits(CGSize(width: 1200, height: 900))
        readout.frame = CGRect(x: 60, y: 40, width: size.width, height: size.height + 16)
    }

    private var scanLabel: String? {
        scan.map { String(repeating: $0.direction > 0 ? "▸" : "◂", count: $0.level + 1) }
    }

    private func updateOverlay(_ engine: AetherEngine) {
        let waiting = !hasPlayed || engine.state == .seeking || engine.isBuffering
        overlay.update(
            time: scrubTarget ?? landing ?? position, duration: engine.duration,
            audio: audioLabel(engine), subtitle: subtitleLabel(engine),
            state: scanLabel ?? (engine.state == .paused ? "Paused" : nil), waiting: waiting
        )
        overlay.setHeld(from: position, to: engine.bufferedPosition, duration: engine.duration)
        let shown = menu != .none || scrubTarget != nil || !hasPlayed
            || (!controlsDismissed && (engine.state == .paused || Date() < overlayUntil))
        overlay.setShown(shown)
        let alpha: CGFloat = shown ? 1 : 0
        if audioButton.alpha != alpha {
            UIView.animate(withDuration: Motion.fadeDuration) {
                self.audioButton.alpha = alpha
                self.subtitleButton.alpha = alpha
            }
        }
    }

    private func audioLabel(_ engine: AetherEngine) -> String {
        engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }.map(audioTitle) ?? ""
    }

    private func audioTitle(_ track: TrackInfo) -> String {
        let extra = track.isAtmos ? "Atmos" : track.isDTSX ? "DTS:X" : "\(track.channels) ch"
        var title = "\(languageName(track.language)), \(track.codec.uppercased()) \(extra)"
        if track.isCommentary { title += ", Commentary" }
        if track.isVisualImpaired { title += ", Audio Description" }
        return title
    }

    private func subtitleTitle(_ track: TrackInfo) -> String {
        var title = languageName(track.language)
        if track.isForced { title += ", Forced" }
        if track.isHearingImpaired { title += ", SDH" }
        if track.isCommentary { title += ", Commentary" }
        return title
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
        subtitleText.frame = CGRect(x: 150, y: view.bounds.height - (overlay.isShown ? 250 : 90) - height, width: width, height: height)

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
