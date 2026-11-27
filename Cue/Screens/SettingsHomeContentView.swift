import SwiftUI

// MARK: - Home & Details

/// The taste, laid out to fit the column without scrolling.
struct WhyTasteGrid: View {
    let saved: CueRows.Saved

    private typealias Block = (name: String, lines: [CueRows.TasteLine])

    /// The kinds with blocks (top five each), studios and networks as one;
    /// and the ones read in a line (a language or two).
    private static let blocks: [(name: String, keys: Set<String>)] = [
        ("Genres", ["g"]), ("Themes", ["k"]), ("People", ["p"]), ("Studios & Networks", ["c", "n"]),
    ]
    private static let lines: [(name: String, key: String)] = [
        ("Languages", "l"), ("Countries", "o"), ("Decades", "d"),
    ]

    var body: some View {
        let byShare = saved.taste.filter { $0.kind != nil }.sorted { $0.share > $1.share }
        let blocks: [Block] = Self.blocks.compactMap { block in
            let lines = byShare.filter { block.keys.contains($0.kind ?? "") }.prefix(6)
            return lines.isEmpty ? nil : (block.name, Array(lines))
        }
        let pairs = stride(from: 0, to: blocks.count, by: 2).map { Array(blocks[$0..<min($0 + 2, blocks.count)]) }
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: 56) {
                    ForEach(pair, id: \.name) { block in
                        blockView(block).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
            let small = Self.lines.compactMap { kind -> (String, String)? in
                let found = byShare.filter { $0.kind == kind.key }.prefix(3)
                return found.isEmpty ? nil
                    : (kind.name, found.map { "\($0.label) \(Self.percent($0.share))" }.joined(separator: "  ·  "))
            }
            if !small.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(small, id: \.0) { name, value in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(name)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(CueInk.tertiary)
                                .frame(width: 160, alignment: .leading)
                            Text(value)
                                .font(.system(size: 24))
                                .monospacedDigit()
                                .foregroundStyle(CueInk.body)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, CardSettingsRow.textInset - CardSettingsRow.plateInset)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(block.name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(CueInk.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(block.lines, id: \.label) { line in
                    GridRow(alignment: .center) {
                        Text(line.label)
                            .font(.system(size: 24))
                            .foregroundStyle(CueInk.primary)
                            .lineLimit(1)
                            .frame(maxWidth: 240, alignment: .leading)
                        Capsule()
                            .fill(CueInk.color(0.10))
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(CueInk.body)
                                        .frame(width: max(6, geo.size.width * min(max(line.share, 0), 1)))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        Text(Self.percent(line.share))
                            .font(.system(size: 24))
                            .monospacedDigit()
                            .foregroundStyle(CueInk.body)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }
}

// MARK: - Why These Rows' panels

/// The panels' parts. One grid in every panel: three columns of 460, 60
/// apart, across the panel's 1500; the intro two of them wide (980: lined
/// up with the grid; the whole width ran past 120 characters a line).
private enum WhyPanel {
    static let textSize = FixedFocusMetrics.textSize
    static let column: CGFloat = 460
    static let gap: CGFloat = 60
    static let introWidth = 2 * column + gap

    static func intro(_ text: String) -> some View {
        Text(text)
            .font(.system(size: SettingsMetrics.descriptionTextSize))
            .lineSpacing(8)
            .foregroundStyle(CueInk.body)
            .frame(maxWidth: introWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A group's header: its icon and name in the section labels' capitals,
/// a quiet count after it.
private struct WhyHeader: View {
    let icon: String
    let title: String
    var count: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 34)
            Text(title.uppercased())
                .font(.system(size: SettingsMetrics.sectionTextSize, weight: .semibold))
            if let count {
                Text(count)
                    .font(.system(size: SettingsMetrics.sectionTextSize))
                    .foregroundStyle(CueInk.tertiary)
            }
        }
        .foregroundStyle(CueInk.secondary)
    }
}

/// What You Watch: your traits by kind, each a bar of its share of your
/// watching (against the largest), the share, and how many times more it
/// is in yours than in what's popular. Two columns of kinds.
struct WhyTastePanel: View {
    let taste: [CueRows.TasteLine]

    private static let kinds: [(key: String, name: String, icon: String)] = [
        ("g", "Genres", "theatermasks"), ("k", "Themes", "tag"), ("l", "Languages", "character.bubble"),
        ("o", "Countries", "globe"), ("d", "Decades", "calendar"), ("c", "Studios", "building.2"),
        ("n", "Networks", "tv"), ("p", "People", "person.2"),
    ]

    /// Three columns across the panel; a group takes a column per 7 lines
    /// (at most three), its lines split evenly between them (read down,
    /// then across). Groups fill each line of the grid in order; one that
    /// doesn't fit takes the columns left if that keeps it to 12 lines a
    /// column (Themes beside Genres, not under it alone), else starts the
    /// next line.
    static let columns = 3
    static let column = WhyPanel.column
    static let gap = WhyPanel.gap

    static func span(_ lines: Int) -> Int { min(columns, max(1, (lines + 6) / 7)) }
    static func leastSpan(_ lines: Int) -> Int { min(columns, max(1, (lines + 11) / 12)) }

    private typealias Group = (name: String, icon: String, lines: [CueRows.TasteLine])

    /// The grid's lines, each group with the columns it takes.
    private static func pack(_ groups: [Group]) -> [[(group: Group, span: Int)]] {
        var out: [[(group: Group, span: Int)]] = []
        var line: [(group: Group, span: Int)] = []
        var used = 0
        for group in groups {
            var span = span(group.lines.count)
            if used + span > columns {
                if !line.isEmpty, columns - used >= leastSpan(group.lines.count) {
                    span = columns - used
                } else if !line.isEmpty {
                    out.append(line)
                    line = []
                    used = 0
                }
            }
            line.append((group, span))
            used += span
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    private var groups: [Group] {
        // Saved before kinds were kept: one group.
        guard taste.contains(where: { $0.kind != nil }) else {
            return taste.isEmpty ? [] : [("Your Traits", "sparkles", taste)]
        }
        return Self.kinds.compactMap { kind in
            let lines = taste.filter { $0.kind == kind.key }.sorted { $0.share > $1.share }
            return lines.isEmpty ? nil : (kind.name, kind.icon, lines)
        }
    }

    var body: some View {
        let most = taste.map(\.share).max() ?? 1
        VStack(alignment: .leading, spacing: 56) {
            WhyPanel.intro("Cue reads a taste from the last titles you watched, started or saved, "
                + "and scores every row against it, with a share of the day's chance so the rows "
                + "change each day. A trait counts more where it's rarer in what's popular: "
                + "the number after each share says how many times more it is in yours.")
            VStack(alignment: .leading, spacing: 64) {
                ForEach(Array(Self.pack(groups).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(line, id: \.group.name) { entry in
                            WhyTasteGroup(name: entry.group.name, icon: entry.group.icon, lines: entry.group.lines,
                                          most: most, span: entry.span)
                        }
                    }
                    .panelAnchor(.strong)
                }
            }
        }
    }
}

/// One kind of trait: its header, its lines in `span` columns.
private struct WhyTasteGroup: View {
    let name: String
    let icon: String
    let lines: [CueRows.TasteLine]
    let most: Double
    let span: Int

    var body: some View {
        let perColumn = Int((Double(lines.count) / Double(span)).rounded(.up))
        let columns = stride(from: 0, to: lines.count, by: max(perColumn, 1))
            .map { Array(lines[$0..<min($0 + perColumn, lines.count)]) }
        VStack(alignment: .leading, spacing: 20) {
            WhyHeader(icon: icon, title: name)
            HStack(alignment: .top, spacing: WhyTastePanel.gap) {
                ForEach(columns.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(columns[index], id: \.label) { line in
                            WhyBar(line: line, most: most).panelAnchor(.line)
                        }
                    }
                    .frame(width: WhyTastePanel.column, alignment: .leading)
                }
            }
        }
    }
}

/// A trait's line: its name, its bar, its share, its lift (the column's
/// 460 pt: 180, 120, 64, 48 and three gaps of 16).
private struct WhyBar: View {
    let line: CueRows.TasteLine
    let most: Double

    var body: some View {
        HStack(spacing: 16) {
            Text(line.label)
                .font(.system(size: WhyPanel.textSize, weight: .medium))
                .foregroundStyle(CueInk.primary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 120, height: 10)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(CueInk.primary)
                        .frame(width: max(10, 120 * line.share / max(most, 0.0001)))
                }
            Text("\(Int((line.share * 100).rounded())) %")
                .font(.system(size: WhyPanel.textSize))
                .monospacedDigit()
                .foregroundStyle(CueInk.body)
                .frame(width: 64, alignment: .trailing)
            Text(line.lift.map { $0 >= 1.5 ? String(format: "%.0f×", $0.rounded()) : "" } ?? "")
                .font(.system(size: WhyPanel.textSize))
                .monospacedDigit()
                .foregroundStyle(CueInk.tertiary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Your rows

// MARK: - Add-ons

/// Settings 2's Add-ons, one page: Add Add-on and Refresh on top, then
/// the add-ons in source order, each a row with its actions on it
/// (`ActionListRow`): Configure (when it has settings), Turn Off / On,
/// Move, Rename, Remove. No add-on page, no Edit mode.
struct AddonsCardPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @State private var moving: String?
    @State private var adding = false
    @State private var configuring: InstalledAddon?
    @State private var removing: InstalledAddon?
    @State private var keyboard: KeyboardRequest?
    @State private var refreshing = false
    @State private var failed = 0
    @AppStorage("cue.addons.refreshedAt") private var refreshedAt: Double = 0

    private var refreshValue: String {
        if refreshing { return "Refreshing…" }
        if failed > 0 { return failed == 1 ? "1 didn't answer" : "\(failed) didn't answer" }
        guard refreshedAt > 0 else { return "Not yet" }
        return DateFormatter.settingsWhen.string(from: Date(timeIntervalSince1970: refreshedAt))
    }

    var body: some View {
        SettingsPage(title: "Add-ons") {
            SettingsSection {
                SettingsButtonRow(title: "Add Add-on", description: "From your phone, with its link.") { adding = true }
                SettingsButtonRow(title: "Refresh Add-ons", value: refreshValue) {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        failed = await addonManager.refreshManifests(bypassCache: true)
                        refreshing = false
                        if failed == 0 { refreshedAt = Date().timeIntervalSince1970 }
                    }
                }
            }
            .disabled(moving != nil)
            if !addonManager.addons.isEmpty {
                SettingsSection(title: "Higher Ones Come First for Sources") {
                    ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, addon in
                        ActionListRow(
                            id: addon.id,
                            leading: AnyView(AddonLogo(addon: addon)),
                            title: addon.displayName,
                            detail: Self.detail(addon),
                            dimmed: !addon.enabled,
                            actions: actions(addon),
                            moving: moving == addon.id,
                            anyMoving: moving != nil,
                            onMoveStep: { addonManager.move(addon, to: index + $0) },
                            onDrop: { moving = nil })
                    }
                }
            }
        }
        .onChange(of: moving) { _, now in TopBarLock.shared.locked = now != nil }
        .onDisappear { TopBarLock.shared.locked = false }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .fullScreenCover(isPresented: $adding) {
            AddonPhoneAddView(addonManager: addonManager) { adding = false }
        }
        .fullScreenCover(item: $configuring) { addon in
            AddonPhoneAddView(addonManager: addonManager, configuring: addon) { configuring = nil }
        }
        .alert("Remove \(removing?.displayName ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { addonManager.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It's removed from this device and your account. You can add it back later with its link.")
        }
    }

    private func actions(_ addon: InstalledAddon) -> [SettingsAction] {
        var list: [SettingsAction] = []
        if addon.configureURL != nil {
            list.append(SettingsAction(title: "Configure", icon: "gearshape") { configuring = addon })
        }
        list.append(SettingsAction(title: addon.enabled ? "Turn Off" : "Turn On",
                                   icon: addon.enabled ? "eye.slash" : "eye", key: "toggle") {
            addonManager.setEnabled(addon, !addon.enabled)
        })
        if addonManager.addons.count > 1 {
            list.append(SettingsAction(title: "Move", icon: "arrow.up.arrow.down", move: true) { moving = addon.id })
        }
        list.append(SettingsAction(title: "Rename", icon: "pencil") {
            keyboard = KeyboardRequest(text: addon.displayName, placeholder: addon.manifest.name) {
                addonManager.rename(addon, to: $0)
            }
        })
        list.append(SettingsAction(title: "Remove", icon: "trash", danger: true) { removing = addon })
        return list
    }

    /// What Cue uses it for: streams, subtitles (its catalogs and show
    /// info never: Cue's own); neither, it says so.
    static func detail(_ addon: InstalledAddon) -> String {
        if AddonManager.isUnused(addon.manifest) { return "Not used by Cue: no streams" }
        let named = [addon.manifest.providesStreams ? "Streams" : nil,
                     addon.manifest.providesSubtitles ? "Subtitles" : nil].compactMap { $0 }
        return ([addon.manifest.version.map { "v\($0)" }] + [named.isEmpty ? nil : named.joined(separator: ", ")])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// An add-on's logo, small, on the left of its row.
struct AddonLogo: View {
    let addon: InstalledAddon

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08))
            if let logo = addon.manifest.logo {
                RemoteImage(url: logo, contentMode: .fit, maxDimension: 80, showsPlaceholder: false)
                    .padding(4)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }
}
