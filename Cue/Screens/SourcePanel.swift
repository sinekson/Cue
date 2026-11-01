import SwiftUI
import UIKit

/// The stage: a dimmed blur over whatever was on screen at the press, its logo or name in the middle, breathing while it loads, with a
/// line on what's happening; the source list when there is one, the logo above it.
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
    private var status: String { launcher.searching != nil ? "Searching sources" : "Starting" }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.black.opacity(Self.dim))
            header
                .padding(.top, listUp ? SummaryPanelMetrics.titleTop : 0)
                .frame(maxHeight: .infinity, alignment: listUp ? .top : .center)
                .animation(Motion.move, value: listUp)
            if !listUp {
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
        .onAppear { DispatchQueue.main.async { if !listUp { holding = true } } }
        .task(id: listUp) {
            statusUp = false
            breathing = !listUp
            guard !listUp else { return }
            holding = true
            try? await Task.sleep(for: Self.statusDelay)
            if !Task.isCancelled { statusUp = true }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            mark
                .scaleEffect(breathing ? 1.06 : 1)
                .animation(breathing ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : Motion.fade,
                           value: breathing)
                // Larger alone in the middle, by a transform so it moves as one.
                .scaleEffect(listUp ? 1 : Self.middleScale)
                .animation(Motion.move, value: listUp)
                .padding(.vertical, listUp ? 0 : Self.middleRoom)
            if let episode = scene.episode {
                Text(episode)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                    .lineLimit(1)
            }
        }
        .frame(width: 1400)
        // Under it, not part of it: the logo stays in the very middle.
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
            RemoteImage(url: logo, contentMode: .fit, maxDimension: Self.logoSize.width * Self.middleScale * 2,
                        showsPlaceholder: false)
                .frame(width: Self.logoSize.width, height: Self.logoSize.height)
        } else {
            Text(scene.title)
                .font(.system(size: SettingsMetrics.titleTextSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                .lineLimit(1)
        }
    }

    /// Over the blur, so the list reads over any page.
    private static var dim: Double { 0.6 }
    private static var logoSize: CGSize { CGSize(width: 520, height: 96) }
    private static var middleScale: CGFloat { 1.4 }
    /// Keeps what's under the logo clear of it at its largest.
    private static var middleRoom: CGFloat { 28 }
}

/// The sources on the stage: in one column the add-ons' tabs, then the links
/// (plain rows, a blur for focus, as the shelf's cards).
/// Shown by `SourcePicker` — from Details (hold Play) and Continue Watching
/// ("Choose Source"), and when Play finds nothing. The links in the add-ons' own order
/// (an aggregator like AIOStreams has sorted and filtered them), their labels'
/// line breaks kept, nothing filtered or re-sorted. Every enabled add-on is
/// searched; the pills only show one add-on's links. Search Again asks them
/// all again.
/// Select plays; Back closes.
struct SourcePanel: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @ObservedObject private var picker = SourcePicker.shared
    @StateObject private var model: StreamsViewModel
    let onPlay: (StreamEntry, [StreamEntry]) -> Void
    let onClose: () -> Void

    /// The add-on shown — the one whose tab had focus last (nil: the first
    /// link's).
    @State private var addon: String?
    @FocusState private var tab: String?
    @State private var problem: String?
    @FocusState private var focused: UUID?
    /// Search Again: where focus starts, until the first link is in.
    @FocusState private var again: Bool
    /// The link picked, for focus when Back comes back from its loading.
    @State private var pickedID: UUID?

    /// Wide: an aggregator's long lines on as few lines as can be.
    private static let width = SourcePanelMetrics.width
    /// The list fades out over this at the screen's foot.
    private static let fade: CGFloat = 60

    init(meta: MetaItem, video: MetaVideo?, onPlay: @escaping (StreamEntry, [StreamEntry]) -> Void,
         onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: StreamsViewModel(meta: meta, video: video))
        self.onPlay = onPlay
        self.onClose = onClose
    }

    /// The add-on shown: the one picked, else the first link's.
    private var current: String? {
        addon ?? model.entries.first?.addonName ?? model.addonNames.first
    }

    /// The links shown: one add-on's.
    private var shown: [StreamEntry] {
        model.entries.filter { $0.addonName == current }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            controls
            list
        }
        .frame(width: Self.width)
        .padding(.top, SummaryPanelMetrics.columnTop)
        .frame(width: 1920, height: 1080)
        .ignoresSafeArea()
            .focusSection()
            .onExitCommand(perform: onClose)
            // Focus into the panel at once: left where it was (Details' Play,
            // in its own host, isn't disabled with the page), a Back reached
            // no handler.
            .onAppear {
                DispatchQueue.main.async { if focused == nil, tab == nil { again = true } }
            }
            .onChange(of: tab) { _, name in
                if let name { addon = name }
            }
            .onChange(of: picker.picked) { _, picked in
                if !picked, let pickedID { focused = pickedID }
            }
            .task {
                let settings = playerSettings.settings
                await model.load(addonManager: addonManager, perTier: settings.sourcesPerSizeTier,
                                 filtersEnabled: settings.sourceFiltersEnabled,
                                 streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
            }
            .onChange(of: model.entries.first?.id) { _, first in
                // The first link in: focus on it (once).
                if focused == nil, let first { focused = first }
            }
            .alert("Can't play this source", isPresented: Binding(get: { problem != nil },
                                                                  set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }

    /// Search Again, the add-ons' tabs, and when the list was found.
    private var controls: some View {
        HStack(spacing: 16) {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    // Ask every add-on again — also mid-search (one add-on
                    // hanging). Icon only, before the add-ons.
                    Button { searchAgain() } label: {
                        Image(systemName: "arrow.clockwise").fontWeight(.semibold)
                    }
                    .buttonStyle(PillButtonStyle(selected: false))
                    .focused($again)
                    .accessibilityLabel("Search Again")
                    // A tab shows its add-on's links as focus reaches it.
                    ForEach(model.addonNames, id: \.self) { name in
                        Button { addon = name } label: { addonLabel(name) }
                            .buttonStyle(PillButtonStyle(selected: current == name))
                            .focused($tab, equals: name)
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 22)
            }
            .scrollClipDisabled()
            .focusSection()
            // Kept current while open (the minutes go on).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(found(at: context.date))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.secondary))
                    .lineLimit(1)
            }
            .padding(.trailing, 22)
        }
    }

    /// "Found just now" / "Found 4 min ago" — the last search's end, or the
    /// cached list's.
    private func found(at now: Date) -> String {
        if model.isLoading { return "Searching…" }
        guard let foundAt = model.foundAt else { return "" }
        let minutes = Int(now.timeIntervalSince(foundAt) / 60)
        return minutes < 1 ? "Found just now" : "Found \(minutes) min ago"
    }

    /// An add-on's pill: its name and how many links it gave — a spinner
    /// while it's searching, "–" when it gave none (or failed).
    private func addonLabel(_ name: String) -> some View {
        HStack(spacing: 10) {
            Text(name)
            if !model.finishedAddonNames.contains(name) {
                LoadingSpinner(size: 22)
            } else {
                let count = model.entries.filter { $0.addonName == name }.count
                Text(count > 0 ? "\(count)" : "–").opacity(0.6)
            }
        }
    }

    private func searchAgain() {
        focused = nil
        let settings = playerSettings.settings
        Task {
            await model.reload(addonManager: addonManager, perTier: settings.sourcesPerSizeTier,
                               filtersEnabled: settings.sourceFiltersEnabled,
                               streamTimeout: TimeInterval(settings.sourceSearchTimeoutSeconds))
        }
    }

    @ViewBuilder private var list: some View {
        if shown.isEmpty {
            Group {
                if model.isLoading { LoadingSpinner() }
                else {
                    Text("No add-on has a source for this.")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.white.opacity(0.6))
                        // Something to hold focus (Back has to reach the panel).
                        .focusable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(shown) { entry in
                        Button { play(entry) } label: {
                            SourceRow(entry: entry, badges: streamBadges.badges(for: entry),
                                      showsAddon: model.addonNames.count > 1)
                        }
                        .buttonStyle(SourceRowStyle())
                        .focused($focused, equals: entry.id)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, Self.fade)
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
            .focusSection()
        }
    }

    private func play(_ entry: StreamEntry) {
        // A cast link (DMM Cast): the system opens it, not the player.
        if entry.stream.isExternal, let link = entry.stream.externalUrl, let url = URL(string: link) {
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened { problem = "Apple TV can't open this cast link directly." }
            }
            return
        }
        guard !entry.stream.isTorrent else {
            problem = "This source is a raw torrent, which Cue can't play. Configure debrid in the add-on itself."
            return
        }
        pickedID = entry.id
        onPlay(entry, model.entries)
    }
}

/// One source: the add-on's label and its description, each with their own
/// line breaks; the badges and quality below; the add-on's name, with more
/// than one.
private struct SourceRow: View {
    let entry: StreamEntry
    let badges: [StreamBadge]
    let showsAddon: Bool

    var body: some View {
        let primary = Color.white.opacity(FixedFocusText.primary)
        let secondary = Color.white.opacity(FixedFocusText.body)
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(primary)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.displayDetail.isEmpty {
                Text(entry.displayDetail)
                    .font(.system(size: 24))
                    .lineSpacing(3)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let resolution = entry.stream.resolutionLabel { tag(resolution) }
                if !badges.isEmpty { StreamBadgeChips(badges: badges) }
                Spacer(minLength: 8)
                if showsAddon {
                    Text(entry.addonName)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // As tall as its lines need (a last line was cut off).
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.14)))
    }
}

/// A source row: nothing at rest; focused, a blur and a little growth, as the
/// shelf's cards. No white: it fought the add-ons' colours.
private struct SourceRowStyle: ButtonStyle {
    static let corner: CGFloat = 30
    /// In points, as the shelf's cards: a share of a wide row is a big jump.
    private static let growth: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View { Platter(configuration: configuration) }

    private struct Platter: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: SourceRowStyle.corner, style: .continuous)
                        .fill(.regularMaterial)
                        .opacity(isFocused ? 0.9 : 0)
                }
                .scaleEffect(isFocused ? 1 + SourceRowStyle.growth / SourcePanelMetrics.width : 1)
                .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}

private enum SourcePanelMetrics {
    static let width: CGFloat = 1100
}
