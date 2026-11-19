import SwiftUI
import UIKit

/// The stage: Details' card, where Details has it, on the title's bands
/// as Details' page (following the setting). In the
/// card at Details' text's place the logo and what plays (a show's episode,
/// a film's facts and tagline); where Details' buttons were, a line on
/// what's happening. With the list up, the card's foot rises and the links
/// are a row on the page under it. Lights down: the card's window grows to
/// the screen as its picture goes dark, and the film rises out of the black.
/// Back while finding or loading stops it.
struct PlayStageView<Sources: View>: View {
    @ObservedObject private var picker = SourcePicker.shared
    @ObservedObject private var launcher = PlayLauncher.shared
    let scene: PlayStage.Scene
    let onBack: () -> Void
    @ViewBuilder let sources: (SourcePicker.Request) -> Sources

    /// Holds focus while there's no list, so Back reaches the stage.
    @FocusState private var holding: Bool
    /// Scrolled up for the links' row, once there are links, as Details'
    /// card scrolls up with its rows (from Details' card: once the stage is
    /// in). Until then where Details has it, the tabs and Refresh under it.
    @State private var short = false
    /// The stage is in (its fade done): only then does it scroll, so the
    /// row is first in Details' peek's place, then moves, never both.
    @State private var settled = false
    /// Its own fade in (the root's insertion transition never ran: it cut
    /// in, a flicker).
    @State private var shownIn = false
    /// On the way out (`leave`).
    @State private var leaving = false
    /// Back's fade off as a whole.
    @State private var gone = false
    /// Grown out of a card with the links already in: the row waits below
    /// the screen under the cover, and comes up with the scroll as the
    /// cover goes (it never fades in, then moves).
    @State private var below = false

    @ObservedObject private var stage = PlayStage.shared

    private var listUp: Bool { picker.request != nil && !picker.picked }
    private var searchingNow: Bool { launcher.searching != nil || picker.searching }
    /// At work: a line from the press's set, the light passing through it.
    private var waiting: Bool { !listUp || picker.searching }
    /// The line: at work, or with the list up, why there's nothing to play.
    private var status: String? {
        if waiting {
            if searchingNow { return scene.searchingLine }
            return stage.note == .swapping ? PlayStage.swappingLine : scene.startingLine
        }
        if case .allFailed(let tried) = stage.note { return PlayStage.allFailedLine(tried: tried) }
        if picker.noAddons { return PlayStage.noAddonsLine }
        if picker.empty { return PlayStage.nothingFoundLine }
        return nil
    }

    private var card: CGRect {
        if stage.dark { return CGRect(origin: .zero, size: StagePictureView.pictureSize) }
        let card = StagePictureView.detailsCard
        return short ? card.offsetBy(dx: 0, dy: -ShelfShape.stageScroll) : card
    }

    /// The page follows the setting, as Details'; the card is dark always.
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Details' bands a step more vivid: closer to the film.
            TitleBandsBackground(url: scene.bands, saturation: BandsPicture.stageSaturation)
                .frame(width: 1920, height: 1080)
            Group {
                picture
                text
                    .opacity(stage.dark ? 0 : 1)
                    .animation(Motion.fade, value: stage.dark)
            }
            .environment(\.colorScheme, .dark)
            // With the list too, until it has taken focus from Details' Play
            // behind the stage: then it goes, and focus falls into the list
            // (SwiftUI's host refuses UIKit's own requests).
            if !listUp || !picker.listShown {
                Color.clear
                    .focusable()
                    .focused($holding)
                    .onExitCommand(perform: back)
            }
            if let request = picker.request {
                // Under the card, moved by the card's own state in the same
                // move (on its own animation it ran ahead of the card).
                sources(request)
                    .offset(y: below ? StagePictureView.pictureSize.height
                            : ShelfShape.stageTop + (short ? 0 : ShelfShape.stageScroll))
                    .opacity(listUp && !stage.dark ? 1 : 0)
                    .disabled(!listUp)
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .ignoresSafeArea()
        // As one picture: without the group each layer took the opacity
        // (bands, the card's black, the picture through each other: a
        // grey wash mid-fade).
        .compositingGroup()
        .opacity((scene.grown || shownIn) && !gone ? 1 : 0)
        .onExitCommand(perform: back)
        .animation(Motion.fade, value: listUp)
        // Focus here at once: left where it was (Details' Play, in its own
        // host, isn't disabled with the page), a Back reached no handler.
        .onAppear {
            picker.leave = leave
            // Back on Home: focus to the row it left (else the first card
            // on screen took it, Continue Watching).
            FixedFocusRowsController.keepReturnRows()
            DispatchQueue.main.async { holding = true }
            // As into Details: the page changes round the card first (the
            // stage's fade), then one move up.
            let fade = picker.request != nil ? PlayStage.listFadeIn : PlayStage.fadeInDuration
            withAnimation(.easeInOut(duration: fade)) { shownIn = true }
            // Grown out of a card (`DetailTransition.openStage`): there at
            // once under the cover, the scroll as the cover goes
            // (`coverGoing`).
            if scene.grown {
                below = picker.request != nil && picker.hasLinks
                if stage.coverGoing { settle() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { settle() }
        }
        .onChange(of: stage.coverGoing) { _, going in if going, scene.grown, !settled { settle() } }
        .onDisappear { picker.leave = nil }
        // Links in: the scroll, only once the stage is in.
        .onChange(of: picker.request != nil && picker.hasLinks) { _, on in
            // In while still under the cover: below, to come up with the scroll.
            if !settled, scene.grown, on { below = true }
            guard settled, !leaving else { return }
            withAnimation(ShelfShape.stageScrollAnimation) { short = on }
        }
        // Up while it already holds focus (Play found nothing): it goes
        // now, or it kept focus and the list never got it.
        .onChange(of: listUp) { _, up in
            if !up { holding = true } else if holding { picker.listShown = true }
        }
        .onChange(of: holding) { _, on in if on, listUp { picker.listShown = true } }
    }

    /// In: the scroll up if there are links (the row coming up from below
    /// with it, grown out of a card), one move.
    private func settle() {
        settled = true
        withAnimation(ShelfShape.stageScrollAnimation) {
            below = false
            short = picker.request != nil && picker.hasLinks
        }
    }

    /// Back: with the list up it closes (as the list's own Back), else the
    /// stage stops what it's doing.
    private func back() {
        if listUp { picker.back() } else { onBack() }
    }

    /// Back from the list: the card scrolls back down to Details' place
    /// (the row to its peek), then the stage fades off whole over Details'
    /// same card; grown out of a card on Home, one fade off from where it
    /// is (the scroll back only leads into Details' same card). Presses
    /// meanwhile are dropped.
    private func leave() {
        guard !leaving else { return }
        leaving = true
        let fadeOff = {
            withAnimation(.easeInOut(duration: PlayStage.listFadeIn)) { gone = true } completion: {
                closed()
            }
        }
        guard short, !scene.grown else { return fadeOff() }
        withAnimation(ShelfShape.stageScrollAnimation) { short = false } completion: { fadeOff() }
    }

    /// Gone: focus back on the page's row it left (Home; Details takes
    /// its own back).
    private func closed() {
        picker.close()
        DispatchQueue.main.async { FixedFocusRowsController.returnFocus() }
    }

    /// The card: the picture as Details' card shows it (a window onto the
    /// screen-sized picture, moved for its faces), its bottom fade.
    private var picture: some View {
        let card = card
        // The picture goes with the card (scrolled with it, as Details').
        let full = StagePictureView.cardPicture(in: StagePictureView.detailsCard, url: scene.art)
        let shown = stage.dark ? CGRect(origin: CGPoint(x: full.minX, y: 0), size: full.size)
            : full.offsetBy(dx: 0, dy: card.minY - StagePictureView.detailsCard.minY)
        return ZStack(alignment: .topLeading) {
            Color.black
            ZStack(alignment: .topLeading) {
                RemoteImage(url: scene.art, maxDimension: PictureSize.screen, showsPlaceholder: false)
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.minX - card.minX, y: shown.minY - card.minY)
                // The card's bottom fade, over the card (not the picture).
                LinearGradient(stops: Self.shade, startPoint: .top, endPoint: .bottom)
                    .frame(width: card.width, height: card.height)
            }
            // Lights down: the picture goes to black as the window grows.
            .opacity(stage.dark ? 0 : 1)
            .animation(.easeInOut(duration: PlayStage.lightsDown - Self.darkDelay).delay(Self.darkDelay),
                       value: stage.dark)
        }
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: stage.dark ? 0 : Spotlight.cornerRadius, style: .continuous))
        .offset(x: card.minX, y: card.minY)
        .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: Self.grow), value: stage.dark)
    }

    /// Details' card shade (`StageArt.cardShade`'s stops, eased between),
    /// as a gradient so it goes with the card's foot.
    private static var shade: [Gradient.Stop] { StageShade.stops }
}

/// Details' card shade as gradient stops (`PlayStageView`).
private enum StageShade {
    static let stops: [Gradient.Stop] = {
        let stops: [(CGFloat, CGFloat)] = [(0.3, 0), (0.55, 0.3), (0.8, 0.65), (1, 0.85)]
        var out = [Gradient.Stop(color: .clear, location: 0)]
        for (a, b) in zip(stops, stops.dropFirst()) {
            for i in 0...6 {
                let t = CGFloat(i) / 6
                let eased = t * t * (3 - 2 * t)
                out.append(.init(color: .black.opacity(a.1 + (b.1 - a.1) * eased), location: a.0 + (b.0 - a.0) * t))
            }
        }
        return out
    }()
}

extension PlayStageView {
    /// Bottom left the logo and what plays, as Details' text; bottom right,
    /// where its buttons were, what's happening.
    private var text: some View {
        let card = card
        return ZStack(alignment: .topLeading) {
            block
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .frame(width: card.width - 2 * StagePictureView.cardMargin,
                       height: StagePictureView.textBottom(card) - card.minY, alignment: .bottomLeading)
                .offset(x: card.minX + StagePictureView.cardMargin, y: card.minY)
            work
                .frame(width: Self.statusWidth, height: Self.statusHeight)
                .offset(x: card.maxX - StagePictureView.cardMargin - Self.statusWidth,
                        y: StagePictureView.textBottom(card) - Self.statusHeight + Self.statusDrop)
        }
    }

    private typealias Text26 = FixedFocusBillboardText

    /// The logo, then two lines: a show's "Season 2, Episode 5" over the
    /// episode's name; a film's facts over its tagline, as Details.
    private var block: some View {
        let meta = scene.meta
        let episode = scene.episodeNumber != nil
        let first = episode ? scene.episodeNumber ?? ""
            : FixedFocusShowInfo.factsLine(meta, info: TitleRecords.shared.size(meta))
        let second = episode ? scene.episodeName ?? " " : TitleRecords.shared.tagline(meta) ?? meta.name
        return VStack(alignment: .leading, spacing: 0) {
            mark
            Text(first)
                .font(.system(size: Text26.textSize, weight: .medium))
                .foregroundStyle(CueInk.body)
                .frame(height: Text26.lineHeight, alignment: .leading)
                .padding(.top, Text26.space - Text26.lineInset)
            Text(second)
                .font(episode ? .system(size: Text26.textSize, weight: .regular)
                              : .system(size: Text26.textSize, weight: .regular).italic())
                .foregroundStyle(CueInk.secondary)
                .frame(height: Text26.lineHeight, alignment: .leading)
                .padding(.top, Text26.gap - 2 * Text26.lineInset)
        }
        .lineLimit(1)
        .frame(maxWidth: Self.textWidth, alignment: .leading)
    }

    /// What's happening, keeping its room so nothing moves: at work a line
    /// from the press's set with a light passing through it; with the list
    /// up, why there's nothing to play, still.
    private var work: some View {
        SweepLine(text: status ?? " ", sweeping: waiting, alignment: .right)
            .id(status)
            .transition(.opacity)
            .opacity(status == nil ? 0 : 1)
            .animation(Motion.fade, value: status)
    }

    /// The logo as Details' card's (`FixedFocusBillboardText`'s fit); the
    /// name where there's none.
    @ViewBuilder private var mark: some View {
        if let logo = scene.logo {
            RemoteImage(url: logo, maxDimension: Text26.logoMaxSize.width, showsPlaceholder: false,
                        fallback: AnyView(name),
                        logoFit: LogoFit(area: Text26.logoArea, maxSize: Text26.logoMaxSize))
        } else {
            name
        }
    }

    private var name: some View {
        Text(scene.title)
            .font(FusionType.heroTitle)
            .foregroundStyle(CueInk.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .frame(maxWidth: TitleBlock.logoWidth, alignment: .bottomLeading)
    }

    private static var textWidth: CGFloat { 900 }
    private static var statusWidth: CGFloat { 760 }
    private static var statusHeight: CGFloat { 36 }
    /// The status's baseline on the second line's.
    private static var statusDrop: CGFloat { 3 }
    /// Lights down: the window's growth (the opening's zoom), the picture
    /// going dark after this.
    private static var grow: Double { 0.55 }
    private static var darkDelay: Double { 0.2 }
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
            .frame(width: ShelfShape.stageWidth, height: ShelfShape.height)
            .frame(width: 1920, height: 1080, alignment: .top)
            .ignoresSafeArea()
            .onExitCommand(perform: onClose)
            .onChange(of: picker.picked) { _, picked in
                if !picked, let pickedID { focusRequest = .init(entry: pickedID) }
            }
            .onChange(of: model.isLoading && !refreshing, initial: true) { _, waiting in picker.searching = waiting }
            .onChange(of: !model.isLoading && model.entries.isEmpty, initial: true) { _, empty in picker.empty = empty }
            .onChange(of: !model.isLoading && model.addonNames.isEmpty, initial: true) { _, none in picker.noAddons = none }
            .onChange(of: !model.entries.isEmpty, initial: true) { _, some in picker.hasLinks = some }
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
        // No add-ons: nothing was found, not "just now".
        sheet.foundAt = loading || addons.isEmpty ? nil : foundAt
        sheet.update(entries: entries, addons: addons, loading: loading, active: active)
        guard let focusRequest, focusRequest != context.coordinator.served else { return }
        context.coordinator.served = focusRequest
        sheet.focus(on: focusRequest.entry)
    }
}

/// The stage's line at work (and the launch curtain's): in place of the loading symbol, a soft band of
/// light passes through the words, left to right, then a brief rest, as the
/// dots' light goes with them. The words drawn once; only a mask moves, so it
/// costs nothing. Still, it sits at the body level.
struct SweepLine: UIViewRepresentable {
    let text: String
    let sweeping: Bool
    /// The words in the line's box: centred, or at its right end (the stage).
    var alignment: NSTextAlignment = .center

    func makeUIView(context: Context) -> Line { Line() }

    func updateUIView(_ line: Line, context: Context) {
        line.alignment = alignment
        line.set(text, sweeping: sweeping)
    }

    final class Line: UIView {
        private let label = UILabel()
        /// The label's box, the whole line: the mask sits on it, wider than
        /// any words, so new words never fall outside it (sized to the
        /// words, a change of line left part of the new ones masked out).
        private let holder = UIView()
        private let band = CAGradientLayer()
        private var sweeping = false
        var alignment: NSTextAlignment = .center {
            didSet { if alignment != oldValue { setNeedsLayout() } }
        }
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
            label.textAlignment = .center
            holder.isUserInteractionEnabled = false
            addSubview(holder)
            holder.addSubview(label)
            paint()
            // The page's ink by tvOS's setting (the launch curtain on the
            // page); the stage is dark always.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (line: Line, _) in line.paint() }
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var light: Bool { traitCollection.userInterfaceStyle == .light }
        /// A text level in this appearance (`CueInk`'s: black at tvOS's
        /// greys on light).
        private func level(_ value: CGFloat) -> CGFloat { light ? CueInk.onLight(value) : value }

        private func paint() {
            label.textColor = light ? .black : .white
            label.alpha = sweeping ? 1 : level(FixedFocusText.body)
            let dim = UIColor(white: 0, alpha: level(Self.rest)).cgColor
            let lit = UIColor(white: 0, alpha: level(Self.peak)).cgColor
            band.colors = [dim, dim, lit, dim, dim]
        }

        func set(_ text: String, sweeping: Bool) {
            // New words, a new width: the band laid out and started again
            // for them at once (the old pass, sized for the old words, left
            // part of the new ones masked out).
            if label.text != text { running = nil }
            label.text = text
            self.sweeping = sweeping
            label.alpha = sweeping ? 1 : level(FixedFocusText.body)
            holder.layer.mask = sweeping ? band : nil
            setNeedsLayout()
            layoutIfNeeded()
            run()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = label.sizeThatFits(bounds.size)
            let width = min(size.width, bounds.width)
            holder.frame = bounds
            let x = alignment == .right ? bounds.width - width : (bounds.width - width) / 2
            label.frame = CGRect(x: x, y: (bounds.height - size.height) / 2,
                                 width: width, height: size.height)
            // Three times the line, so it covers it wherever the band is; a
            // wide, soft band: about half the words lit at its peak.
            let span = max(bounds.width, 1) * 3
            let half = Double(0.1 * width * 3 / span)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.frame = CGRect(x: -bounds.width, y: 0, width: span, height: bounds.height)
            band.locations = [0, NSNumber(value: 0.5 - half), 0.5, NSNumber(value: 0.5 + half), 1]
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
            // Through the words, wherever they sit in the line.
            let centre = label.frame.midX - bounds.midX
            move.fromValue = centre - 0.8 * width
            move.toValue = centre + 0.8 * width
            move.duration = Self.pass
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let round = CAAnimationGroup()
            round.animations = [move]
            round.duration = Self.pass + Self.pause
            round.repeatCount = .infinity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.transform = CATransform3DMakeTranslation(centre - 0.8 * width, 0, 0)
            CATransaction.commit()
            band.add(round, forKey: "sweep")
        }
    }
}
