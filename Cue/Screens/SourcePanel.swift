import SwiftUI
import UIKit

/// The stage: the title's backdrop as under Details' rows, the logo
/// or name in one spot for every way in, never moving, breathing while it waits,
/// with a line on what's happening; the player's shelf of links under it when there is one.
/// Back while finding or loading stops it.
struct PlayStageView<Sources: View>: View {
    @ObservedObject private var picker = SourcePicker.shared
    @ObservedObject private var launcher = PlayLauncher.shared
    let scene: PlayStage.Scene
    let onBack: () -> Void
    @ViewBuilder let sources: (SourcePicker.Request) -> Sources

    @State private var breathing = false
    @State private var statusUp = false
    /// Holds focus while there's no list, so Back reaches the stage.
    @FocusState private var holding: Bool

    /// A quick start shows no line at all.
    private static var statusDelay: Duration { .milliseconds(500) }

    private var listUp: Bool { picker.request != nil && !picker.picked }
    private var waiting: Bool { !listUp || picker.searching }
    private var status: String {
        launcher.searching != nil || picker.searching ? "Searching sources" : "Starting"
    }

    var body: some View {
        ZStack(alignment: .top) {
            DetailsBackdropBackground(url: scene.art)
            header
                .padding(.top, Self.logoTop)
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
        .task(id: waiting) {
            statusUp = false
            breathing = waiting
            guard waiting else { return }
            try? await Task.sleep(for: Self.statusDelay)
            if !Task.isCancelled { statusUp = true }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            mark
                .frame(width: Self.logoSize.width, height: Self.logoSize.height)
                .scaleEffect(breathing ? 1.06 : 1)
                .animation(breathing ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : Motion.fade,
                           value: breathing)
            if let episode = scene.episode {
                Text(episode)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                    .lineLimit(1)
            }
        }
        .frame(width: 1400)
        // Under it, not part of it: the logo's spot doesn't depend on it.
        .overlay(alignment: .bottom) {
            Text(status)
                .font(.system(size: 24))
                .foregroundStyle(Color.white.opacity(FixedFocusText.tertiary))
                .id(status)
                .transition(.opacity)
                .opacity(statusUp ? 1 : 0)
                .alignmentGuide(.bottom) { $0[.top] - 20 }
                .animation(Motion.fade, value: status)
                .animation(Motion.fade, value: statusUp)
        }
    }

    @ViewBuilder private var mark: some View {
        if let logo = scene.logo {
            RemoteImage(url: logo, contentMode: .fit, maxDimension: Self.logoSize.width * 2, showsPlaceholder: false)
        } else {
            Text(scene.title)
                .font(.system(size: SettingsMetrics.titleTextSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                .lineLimit(1)
        }
    }

    private static var logoSize: CGSize { CGSize(width: 728, height: 140) }
    /// Above the shelf's tabs, with the episode and the status line.
    private static var logoTop: CGFloat { 250 }
}

/// The sources on the stage, under the logo: the player's shelf with Sources
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

    init(meta: MetaItem, video: MetaVideo?, onPlay: @escaping (StreamEntry, [StreamEntry]) -> Void,
         onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: StreamsViewModel(meta: meta, video: video))
        self.onPlay = onPlay
        self.onClose = onClose
    }

    var body: some View {
        StageSources(entries: model.entries, addons: model.addonNames, loading: model.isLoading,
                     foundAt: model.foundAt, active: !picker.picked, focusRequest: focusRequest,
                     onPick: play, onRefresh: searchAgain, onBack: onClose)
            .frame(width: ShelfShape.width, height: ShelfShape.height)
            .padding(.top, ShelfShape.top)
            .frame(width: 1920, height: 1080, alignment: .top)
            .ignoresSafeArea()
            .onExitCommand(perform: onClose)
            .onChange(of: picker.picked) { _, picked in
                if !picked, let pickedID { focusRequest = .init(entry: pickedID) }
            }
            .onChange(of: model.isLoading && model.entries.isEmpty, initial: true) { _, waiting in picker.searching = waiting }
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
        Task {
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
        sheet.searching = loading
        sheet.foundAt = loading ? nil : foundAt
        sheet.update(entries: entries, addons: addons, loading: loading, active: active)
        guard let focusRequest, focusRequest != context.coordinator.served else { return }
        context.coordinator.served = focusRequest
        sheet.focus(on: focusRequest.entry)
    }
}
