import SwiftUI
import UIKit

/// The sources, in a Liquid Glass popup on the right, styled like the
/// system's context menu (glass platter, plain rows, the white highlight).
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

    /// The add-on shown (nil: all).
    @State private var addon: String?
    @State private var problem: String?
    @FocusState private var focused: UUID?

    /// Wide enough for an aggregator's long lines; it still leaves Details'
    /// text column clear.
    static let width: CGFloat = 1000
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

    /// The links shown: all, or the add-on picked.
    private var shown: [StreamEntry] {
        guard let addon else { return model.entries }
        return model.entries.filter { $0.addonName == addon }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    pill("All", selected: addon == nil) { addon = nil }
                    ForEach(model.addonNames, id: \.self) { name in
                        Button { addon = name } label: { addonLabel(name) }
                            .buttonStyle(PillButtonStyle(selected: addon == name))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 22)
            }
            .scrollClipDisabled()
            .focusSection()
            list
        }
        .padding(.top, 28)
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // The platter only: it stays still while the rows scroll over it.
            // (The app's one glass — its tint keeps the text crisp.)
            let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            Color.clear
                .liquidGlass(in: shape)
        }
        .padding(.vertical, 48)
        .padding(.trailing, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .focusSection()
        .onExitCommand(perform: onClose)
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

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sources")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.white)
                Text(status)
                    .font(.system(size: 21))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            // Ask every add-on again — also mid-search (one add-on hanging).
            Button { searchAgain() } label: {
                Label("Search Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(selected: false))
        }
        .padding(.horizontal, 22)
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

    private var status: String {
        let code = model.video.map { "\($0.seasonEpisodeCode) · " } ?? ""
        if model.isLoading {
            return code + "Searching add-ons \(model.finishedAddons)/\(model.totalAddons)"
        }
        if addon != nil {
            return code + "\(shown.count) of \(model.entries.count) sources"
        }
        let found = model.entries.isEmpty ? "No sources found" : "\(model.entries.count) sources"
        // A list from the cache: say when it was found.
        guard let cachedAt = model.cachedAt else { return code + found }
        let minutes = Int(Date().timeIntervalSince(cachedAt) / 60)
        return code + found + " · found " + (minutes < 1 ? "just now" : "\(minutes) min ago")
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

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(PillButtonStyle(selected: selected))
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
        let secondary = isFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.72)
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(primary)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.displayDetail.isEmpty {
                Text(entry.displayDetail)
                    .font(.system(size: 21))
                    .lineSpacing(3)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let resolution = entry.stream.resolutionLabel { tag(resolution) }
                if !badges.isEmpty { StreamBadgeChips(badges: badges) }
                Spacer(minLength: 8)
                Text(entry.addonName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.95))
            .padding(.horizontal, 10)
            .frame(height: 29)
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
                    .foregroundStyle(Color.white)
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
