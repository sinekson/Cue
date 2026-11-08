import SwiftUI
import UIKit

/// The stage: the title's picture sharp under an even dim, and centred above
/// the shelf's place its logo (else the name) and a line on what's happening while
/// it waits, in one spot for every way in, never moving, still; the player's
/// shelf of links under it when there is one.
/// Back while finding or loading stops it.
struct PlayStageView<Sources: View>: View {
    @ObservedObject private var picker = SourcePicker.shared
    @ObservedObject private var launcher = PlayLauncher.shared
    let scene: PlayStage.Scene
    let onBack: () -> Void
    @ViewBuilder let sources: (SourcePicker.Request) -> Sources

    /// Holds focus while there's no list, so Back reaches the stage.
    @FocusState private var holding: Bool

    @ObservedObject private var stage = PlayStage.shared

    private var listUp: Bool { picker.request != nil && !picker.picked }
    private var searchingNow: Bool { launcher.searching != nil || picker.searching }
    /// At work: the loading symbol with a line from the press's set.
    private var waiting: Bool { !listUp || picker.searching }
    /// The line: at work, or with the list up, why there's nothing to play.
    private var status: String? {
        if waiting {
            if searchingNow { return scene.searchingLine }
            return stage.note == .swapping ? PlayStage.swappingLine : scene.startingLine
        }
        if case .allFailed(let tried) = stage.note { return PlayStage.allFailedLine(tried: tried) }
        if picker.empty { return PlayStage.nothingFoundLine }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The picture sharp, evenly dimmed so the centred text reads
            // anywhere on it: more than under Details' rows, more again for a
            // bright picture.
            Color.black
            // Lights down: the picture goes to black, slowly, the text first.
            ZStack {
                RemoteImage(url: scene.art, maxDimension: PictureSize.screen, showsPlaceholder: false)
                    .frame(width: 1920, height: 1080)
                    .blur(radius: Self.blur, opaque: true)
                Color.black.opacity(max(Self.dim, StageArt.dimBelow(for: scene.art)))
            }
            .opacity(stage.dark ? 0 : 1)
            .animation(.easeInOut(duration: PlayStage.lightsDown), value: stage.dark)
            header
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 1080 - ShelfShape.top + Self.aboveShelf)
                .opacity(stage.dark ? 0 : 1)
                .animation(Motion.fade, value: stage.dark)
            // With the list too, until it has taken focus from Details' Play
            // behind the stage: then it goes, and focus falls into the list
            // (SwiftUI's host refuses UIKit's own requests).
            if !listUp || !picker.listShown {
                Color.clear
                    .focusable()
                    .focused($holding)
                    .onExitCommand(perform: onBack)
            }
            if let request = picker.request {
                sources(request)
                    .opacity(listUp ? 1 : 0)
                    .disabled(!listUp)
            }
        }
        .frame(width: 1920, height: 1080)
        .ignoresSafeArea()
        .animation(Motion.fade, value: listUp)
        // Focus here at once: left where it was (Details' Play, in its own
        // host, isn't disabled with the page), a Back reached no handler.
        .onAppear { DispatchQueue.main.async { holding = true } }
        .onChange(of: listUp) { _, up in if !up { holding = true } }
        .onChange(of: holding) { _, on in if on, listUp { picker.listShown = true } }
    }

    /// Centred, its foot just above the shelf's tabs: the logo, a show's
    /// episode (its number as a label over its name), then the status.
    private var header: some View {
        VStack(spacing: 0) {
            mark
            // A show's episode: its number as a small label over its name.
            // A film keeps their room, so the logo sits in one spot for both.
            Text(scene.episodeNumber?.uppercased() ?? " ")
                .font(.system(size: 23, weight: SectionHint.weight))
                .tracking(SectionHint.tracking)
                .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                .padding(.top, 28)
            Text(scene.episodeName ?? " ")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                .padding(.top, 6)
            work
                .padding(.top, 28)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: Self.textWidth)
    }

    /// What's happening, under the episode on every way in, keeping its room
    /// so nothing moves: at work a line from the press's set with a light
    /// passing through it (beside it, the loading symbol left the words off
    /// centre; above or below, a letter wave and a pulse were tried); with
    /// the list up, why there's nothing to play, still. The one place for it
    /// (Refresh shows only its own search).
    private var work: some View {
        SweepLine(text: status ?? " ", sweeping: waiting)
            .id(status)
            .transition(.opacity)
            .frame(width: Self.textWidth, height: 36)
            .opacity(status == nil ? 0 : 1)
            .animation(Motion.fade, value: status)
    }

    /// The logo, trimmed and sized by area as the billboard's (`LogoFit`) so
    /// logos weigh alike, its foot in one place; the name where there's none.
    @ViewBuilder private var mark: some View {
        if let logo = scene.logo {
            RemoteImage(url: logo, maxDimension: Self.logoSize.width, showsPlaceholder: false,
                        fallback: AnyView(name), logoFit: LogoFit(area: Self.logoArea, maxSize: Self.logoSize))
                .frame(height: Self.logoSize.height, alignment: .bottom)
        } else {
            name
        }
    }

    private var name: some View {
        Text(scene.title)
            .font(.system(size: 48, weight: .semibold))
            .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
    }

    private static var logoSize: CGSize { CGSize(width: 728, height: 160) }
    private static var logoArea: CGFloat { 70_000 }
    /// The picture's dim at least (Details' rows: 0.55).
    private static var dim: CGFloat { 0.7 }
    /// Soft: the picture still reads, its detail doesn't compete with the text.
    private static var blur: CGFloat { 12 }

    private static var textWidth: CGFloat { 1200 }
    /// Its foot this far above the shelf's tabs.
    private static var aboveShelf: CGFloat { 40 }
}

/// The sources on the stage, under the title: the player's shelf with Sources
/// unfolded: its add-on tabs, Refresh and when they were found, its place,
/// glass and cards.
/// Shown by `SourcePicker` — from Details (hold Play) and Continue Watching
/// ("Choose Source"), and when Play finds nothing. The links in the add-ons' own order
/// (an aggregator like AIOStreams has sorted and filtered them), nothing
/// filtered or re-sorted. Every enabled add-on is searched; a tab only shows
/// one add-on's links. Refresh asks them all again.
/// Select plays; Back closes.
struct SourcePanel: View {
    @EnvironmentObject private var addonManager: AddonManager
    @ObservedObject private var picker = SourcePicker.shared
    @StateObject private var model: StreamsViewModel
    let onPlay: (StreamEntry, [StreamEntry]) -> Void
    let onClose: () -> Void

    @State private var problem: String?
    /// The link picked, for focus when Back comes back from its loading.
    @State private var pickedID: UUID?
    @State private var focusRequest: StageSources.FocusRequest?
    /// A search started with Refresh: Refresh shows it, not the stage.
    @State private var refreshing = false

    init(meta: MetaItem, video: MetaVideo?, onPlay: @escaping (StreamEntry, [StreamEntry]) -> Void,
         onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: StreamsViewModel(meta: meta, video: video))
        self.onPlay = onPlay
        self.onClose = onClose
    }

    var body: some View {
        StageSources(entries: model.entries, addons: model.addonNames, loading: model.isLoading,
                     refreshing: refreshing, failed: picker.failed, foundAt: model.foundAt, active: !picker.picked, focusRequest: focusRequest,
                     onPick: play, onRefresh: searchAgain, onBack: onClose)
            .frame(width: ShelfShape.width, height: ShelfShape.height)
            .padding(.top, ShelfShape.top)
            .frame(width: 1920, height: 1080, alignment: .top)
            .ignoresSafeArea()
            .onExitCommand(perform: onClose)
            .onChange(of: picker.picked) { _, picked in
                if !picked, let pickedID { focusRequest = .init(entry: pickedID) }
            }
            .onChange(of: model.isLoading && !refreshing, initial: true) { _, waiting in picker.searching = waiting }
            .onChange(of: !model.isLoading && model.entries.isEmpty, initial: true) { _, empty in picker.empty = empty }
            .task {
                await model.load(addonManager: addonManager)
            }
            .alert("Can't play this source", isPresented: Binding(get: { problem != nil },
                                                                  set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }

    private func searchAgain() {
        refreshing = true
        // New links: the marks and the line go with the old ones.
        picker.failed = []
        PlayStage.shared.note = nil
        Task {
            defer { refreshing = false }
            await model.reload(addonManager: addonManager)
        }
    }

    private func play(_ entry: StreamEntry) {
        guard !entry.stream.isTorrent else {
            problem = "This source is a raw torrent, which Cue can't play. Configure debrid in the add-on itself."
            return
        }
        pickedID = entry.id
        onPlay(entry, model.entries)
    }
}

/// The player's sheet on the stage (`StageSheet`).
private struct StageSources: UIViewControllerRepresentable {
    struct FocusRequest: Equatable {
        let id = UUID()
        let entry: UUID
    }

    let entries: [StreamEntry]
    let addons: [String]
    let loading: Bool
    /// A search started with Refresh: only that turns Refresh's arrows.
    let refreshing: Bool
    /// Links tried that didn't play: marked, focus past them.
    let failed: Set<String>
    let foundAt: Date?
    /// False while what's picked loads: no focus for what's hidden.
    let active: Bool
    let focusRequest: FocusRequest?
    let onPick: (StreamEntry) -> Void
    let onRefresh: () -> Void
    let onBack: () -> Void

    final class Coordinator {
        var served: FocusRequest?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A controller of its own: in a plain representable, SwiftUI kept focus
    /// from leaving the cards for the tabs.
    final class Host: UIViewController {
        let sheet = StageSheet()
        override func loadView() { view = sheet }
        override var preferredFocusEnvironments: [UIFocusEnvironment] { [sheet] }
    }

    func makeUIViewController(context: Context) -> Host { Host() }

    func updateUIViewController(_ host: Host, context: Context) {
        let sheet = host.sheet
        sheet.onPick = onPick
        sheet.onRefresh = onRefresh
        sheet.onBack = onBack
        sheet.failed = failed
        sheet.searching = loading && refreshing
        sheet.foundAt = loading ? nil : foundAt
        sheet.update(entries: entries, addons: addons, loading: loading, active: active)
        guard let focusRequest, focusRequest != context.coordinator.served else { return }
        context.coordinator.served = focusRequest
        sheet.focus(on: focusRequest.entry)
    }
}

/// The stage's line at work: in place of the loading symbol, a soft band of
/// light passes through the words, left to right, then a brief rest, as the
/// dots' light goes with them. The words drawn once; only a mask moves, so it
/// costs nothing. Still, it sits at the body level.
private struct SweepLine: UIViewRepresentable {
    let text: String
    let sweeping: Bool

    func makeUIView(context: Context) -> Line { Line() }

    func updateUIView(_ line: Line, context: Context) {
        line.set(text, sweeping: sweeping)
    }

    final class Line: UIView {
        private let label = UILabel()
        private let band = CAGradientLayer()
        private var sweeping = false
        /// What the running sweep was made for: the same, it runs on.
        private var running: CGFloat?
        /// At rest the words a level down; the light past the primary, on
        /// purpose: at the primary it barely showed.
        private static let rest = FixedFocusText.secondary
        private static let peak: CGFloat = 0.85
        private static let pass: CFTimeInterval = 1.0
        private static let pause: CFTimeInterval = 0.6

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            label.font = .systemFont(ofSize: 28, weight: .medium)
            label.textColor = .white
            label.textAlignment = .center
            addSubview(label)
            let dim = UIColor(white: 1, alpha: Self.rest).cgColor
            let lit = UIColor(white: 1, alpha: Self.peak).cgColor
            band.colors = [dim, dim, lit, dim, dim]
            // A wider, softer band: about half the words lit at its peak.
            band.locations = [0, 0.4, 0.5, 0.6, 1]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func set(_ text: String, sweeping: Bool) {
            label.text = text
            self.sweeping = sweeping
            label.alpha = sweeping ? 1 : FixedFocusText.body
            label.layer.mask = sweeping ? band : nil
            setNeedsLayout()
            run()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = label.sizeThatFits(bounds.size)
            let width = min(size.width, bounds.width)
            label.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - size.height) / 2,
                                 width: width, height: size.height)
            // Three times the words, so it covers them wherever the band is.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.frame = CGRect(x: -width, y: 0, width: width * 3, height: label.bounds.height)
            CATransaction.commit()
            run()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            run()
        }

        /// The band from just before the words to just past them.
        private func run() {
            let width = label.bounds.width
            let wanted: CGFloat? = sweeping && window != nil && width > 0 ? width : nil
            guard wanted != running || (wanted != nil && band.animation(forKey: "sweep") == nil) else { return }
            running = wanted
            band.removeAnimation(forKey: "sweep")
            guard wanted != nil else { return }
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = -0.8 * width
            move.toValue = 0.8 * width
            move.duration = Self.pass
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let round = CAAnimationGroup()
            round.animations = [move]
            round.duration = Self.pass + Self.pause
            round.repeatCount = .infinity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.transform = CATransform3DMakeTranslation(-0.8 * width, 0, 0)
            CATransaction.commit()
            band.add(round, forKey: "sweep")
        }
    }
}
