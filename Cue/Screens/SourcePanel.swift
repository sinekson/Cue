import SwiftUI
import UIKit

/// The sources, in a Liquid Glass popup on the right, over the page dimmed
/// (as a hold menu): the name, the episode, the add-ons' tabs, then the
/// links (plain rows, the white highlight).
/// Shown over the whole app by `SourcePicker` — from Details (hold Play) and
/// Continue Watching ("Choose Source"). The links in the add-ons' own order
/// (an aggregator like AIOStreams has sorted and filtered them), their labels'
/// line breaks kept, nothing filtered or re-sorted. Every enabled add-on is
/// searched; the pills only show one add-on's links. Search Again asks them
/// all again.
/// Select plays; Back closes.
struct SourcePanel: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @StateObject private var model: StreamsViewModel
    let onPlay: (StreamEntry, [StreamEntry]) -> Void
    let onClose: () -> Void

    /// The add-on shown — the one whose tab had focus last (nil: the first
    /// link's).
    @State private var addon: String?
    @FocusState private var tab: String?
    @State private var problem: String?
    @FocusState private var focused: UUID?

    /// Wide: an aggregator's long lines on as few lines as can be (1240
    /// was too wide).
    static let width: CGFloat = 1100
    /// Not the screen's whole height (too chunky); the list scrolls.
    private static let height: CGFloat = 900
    /// The screen margin right of it.
    private static let margin: CGFloat = 48
    private static let corner: CGFloat = 44
    /// The rows' highlight sits this far in from the platter's edge, its
    /// corners following the platter's (as in the system menu).
    static let inset: CGFloat = 14

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
        panel
            .padding(.trailing, Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .focusSection()
            .onExitCommand(perform: onClose)
            .onChange(of: tab) { _, name in
                if let name { addon = name }
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

    /// As the About panel's: the name as a row's, under it the episode.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.meta.name)
                .font(.system(size: Spotlight.headerTitleSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(FixedFocusText.heading))
                .lineLimit(1)
            if let video = model.video, !video.seasonEpisodeCode.isEmpty {
                Text([video.seasonEpisodeCode, video.title].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.captionDetail))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
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
                    .foregroundStyle(Color.white.opacity(FixedFocusText.captionDetail))
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

    private var panel: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            VStack(alignment: .leading, spacing: 18) {
                controls
                list
            }
        }
        .padding(.top, 48)
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        .frame(width: Self.width, height: Self.height)
        .background {
            // The platter only: it stays still while the rows scroll over it.
            let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            Color.clear
                .liquidGlass(in: shape)
        }
        .focusSection()
    }

    /// An add-on's pill: its name and how many links it gave — a spinner
    /// while it's searching, "–" when it gave none (or failed).
    private func addonLabel(_ name: String) -> some View {
        HStack(spacing: 10) {
            Text(name)
            if !model.finishedAddonNames.contains(name) {
                ProgressView().scaleEffect(0.6).frame(width: 24, height: 24)
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
                if model.isLoading { ProgressView() }
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
                            SourceRow(entry: entry, badges: streamBadges.badges(for: entry))
                        }
                        .buttonStyle(SourceRowStyle())
                        .focused($focused, equals: entry.id)
                    }
                }
                .padding(.vertical, 2)
            }
            // Kept inside the platter: rows scroll under its edges.
            .clipShape(UnevenRoundedRectangle(
                bottomLeadingRadius: SourceRowStyle.corner, bottomTrailingRadius: SourceRowStyle.corner,
                style: .continuous))
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
        onPlay(entry, model.entries)
    }
}

/// One source: the add-on's label and its description, each with their own
/// line breaks; the badges and quality below; the add-on's name.
private struct SourceRow: View {
    @Environment(\.isFocused) private var isFocused
    let entry: StreamEntry
    let badges: [StreamBadge]

    var body: some View {
        let primary = isFocused ? Color.black : Color.white
        // Focused, near-black (at 70 % it read grey on the white).
        let secondary = isFocused ? Color.black.opacity(0.85) : Color.white.opacity(0.72)
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
                Text(entry.addonName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
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
            .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.95))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((isFocused ? Color.black : Color.white).opacity(0.14)))
    }
}

/// A source row as a menu row: nothing at rest, the white highlight when
/// focused.
private struct SourceRowStyle: ButtonStyle {
    static let corner: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View { Platter(configuration: configuration) }

    private struct Platter: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            // Only the fill changes (growing a tall row on every step made
            // the scrolling stutter).
            configuration.label
                .background(RoundedRectangle(cornerRadius: SourceRowStyle.corner, style: .continuous)
                    .fill(isFocused ? FlatControl.focus : Color.clear))
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

/// Play from a card or an episode: finding its source, in the picker's
/// glass (`PlayLauncher`'s overlay). Cancel or Back stops it.
struct FindingSourceCard: View {
    let search: PlayLauncher.Search
    let onCancel: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        VStack(spacing: 22) {
            ProgressView()
            VStack(spacing: 6) {
                Text("Finding a source…")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(FixedFocusText.primary))
                Text([search.title, search.episode].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 22))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Button("Cancel", action: onCancel)
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(minWidth: 560)
        .background {
            Color.clear
                .liquidGlass(in: shape)
        }
        .focusSection()
        .onExitCommand(perform: onCancel)
    }
}
