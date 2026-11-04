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
            RemoteImage(url: scene.art, maxDimension: StagePictureView.pictureSize.width, showsPlaceholder: false)
                .frame(width: 1920, height: 1080)
                .blur(radius: Self.blur, opaque: true)
            Color.black.opacity(max(Self.dim, StageArt.dimBelow(for: scene.art)))
            header
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 1080 - ShelfShape.top + Self.aboveShelf)
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
    /// so nothing moves: at work the loading symbol and a line from the
    /// press's set; with the list up, why there's nothing to play. The one
    /// place for it (Refresh shows only its own search).
    private var work: some View {
        HStack(spacing: 16) {
            if waiting {
                LoadingSpinner(size: 36)
                    .transition(.opacity)
            }
            Text(status ?? " ")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.white.opacity(FixedFocusText.body))
                .id(status)
                .transition(.opacity)
        }
        .frame(height: 36)
        .lineLimit(1)
        .opacity(status == nil ? 0 : 1)
        .animation(Motion.fade, value: status)
        .animation(Motion.fade, value: waiting)
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
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
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
                let settings = playerSettings.settings
                await model.load(addonManager: addonManager, perTier: settings.sourcesPerSizeTier,
                                 filtersEnabled: settings.sourceFiltersEnabled,
                                 streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
            }
            .alert("Can't play this source", isPresented: Binding(get: { problem != nil },
                                                                  set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }

    private func searchAgain() {
        let settings = playerSettings.settings
        refreshing = true
        // New links: the marks and the line go with the old ones.
        picker.failed = []
        PlayStage.shared.note = nil
        Task {
            defer { refreshing = false }
            await model.reload(addonManager: addonManager, perTier: settings.sourcesPerSizeTier,
                               filtersEnabled: settings.sourceFiltersEnabled,
                               streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
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
