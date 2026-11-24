import SwiftUI

/// A locked profile's PIN, full screen; `onUnlocked` once it's right.
struct ProfilePinCheck: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profile: UserProfile
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    var body: some View {
        PinEntryView(
            title: "Enter PIN",
            subtitle: profile.name,
            onSubmit: { pin in
                let outcome = await profiles.verifyPin(id: profile.id, pin: pin)
                if outcome.unlocked {
                    onUnlocked()
                    return nil
                }
                if outcome.retryAfterSeconds > 0 {
                    return "Too many attempts. Try again in \(outcome.retryAfterSeconds)s."
                }
                return outcome.message ?? "Incorrect PIN"
            },
            onCancel: onCancel
        )
    }
}

/// The profile page's header: a card in a deep shade of the profile's
/// colour (dark always: words on it white), the avatar large, the name and
/// what applies beside it. Not focusable: it shows what you pick.
struct ProfileEditHeader: View {
    let profile: UserProfile
    let notes: String
    var avatarSize: CGFloat = 150
    /// The top of a card (the avatar picker's): only the top corners round.
    var topOnly = false

    var body: some View {
        HStack(spacing: 32) {
            ProfileAvatarView(profile: profile, size: avatarSize)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                if !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Spotlight.cornerRadius,
                                   bottomLeadingRadius: topOnly ? 0 : Spotlight.cornerRadius,
                                   bottomTrailingRadius: topOnly ? 0 : Spotlight.cornerRadius,
                                   topTrailingRadius: Spotlight.cornerRadius, style: .continuous)
                .fill(Self.shade(profile.avatarColorHex))
        }
        .animation(.easeOut(duration: 0.25), value: profile.avatarColorHex)
    }

    /// The colour's deep shade: its hue, a little less saturated, dark.
    static func shade(_ hex: String) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(profileHex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s * 0.75, brightness: 0.26)
    }
}

/// The avatars to pick from, in Settings' look: Use Initials (a row, the
/// profile's colour), then the catalog six across under its kinds' names.
/// Also the new profile's avatar page.
struct AvatarChoices: View {
    @EnvironmentObject private var profiles: ProfileStore
    /// Whose initials (name and colour).
    let initials: UserProfile
    let chosen: String?
    let pick: (String?) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: SettingsMetrics.rowGap), count: 6)

    var body: some View {
        Button { pick(nil) } label: {
            SettingsRowLabel(title: "Use Initials", checked: chosen == nil,
                             leading: AnyView(Circle().fill(Color(profileHex: initials.avatarColorHex))
                                .overlay(Text(initials.initial).font(.system(size: 20, weight: .heavy))
                                    .foregroundStyle(.white))
                                .frame(width: 44, height: 44)))
        }
        .settingsRow(id: "initials")
        ForEach(Self.groups(profiles.avatarCatalog), id: \.name) { group in
            SettingsSection(title: group.name) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: SettingsMetrics.rowGap) {
                    ForEach(group.items) { item in
                        Button { pick(item.id) } label: {
                            AvatarTile(item: item, chosen: chosen == item.id)
                        }
                        .settingsRow(id: item.id)
                    }
                }
            }
        }
        .task { await profiles.loadAvatarCatalog() }
    }

    /// The catalog's kinds in its order.
    static func groups(_ catalog: [AvatarCatalogItem]) -> [(name: String, items: [AvatarCatalogItem])] {
        var order: [String] = []
        var byKind: [String: [AvatarCatalogItem]] = [:]
        for item in catalog {
            if byKind[item.category] == nil { order.append(item.category) }
            byKind[item.category, default: []].append(item)
        }
        return order.map { (name: $0.capitalized, items: byKind[$0] ?? []) }
    }

    private struct AvatarTile: View {
        @Environment(\.isFocused) private var isFocused
        let item: AvatarCatalogItem
        let chosen: Bool

        var body: some View {
            VStack(spacing: 12) {
                AsyncImage(url: URL(string: item.imageURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.08))
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                HStack(spacing: 6) {
                    Text(item.displayName).lineLimit(1)
                    if chosen { Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold)) }
                }
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isFocused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A PIN change's steps, full screen (`ProfilePinEntry`).
enum ProfilePinStep: Identifiable {
    case set, current(thenNew: Bool), new(current: String)
    var id: String {
        switch self {
        case .set: return "set"
        case .current(let thenNew): return "current-\(thenNew)"
        case .new: return "new"
        }
    }
}

/// The PIN pad for a step: Set, Change (the current one, then the new),
/// Remove (the current one). Done: `step` to nil.
struct ProfilePinEntry: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profile: UserProfile
    let current: ProfilePinStep
    @Binding var step: ProfilePinStep?

    var body: some View {
        ZStack {
            ATVBackground()
            switch current {
            case .set, .new:
                PinEntryView(title: "Choose a 4-digit PIN", subtitle: profile.name, onSubmit: { pin in
                    var old: String?
                    if case .new(let value) = current { old = value }
                    switch await profiles.setPin(id: profile.id, pin: pin, currentPin: old) {
                    case .success: step = nil; return nil
                    case .currentPinRequired: return "This profile already has a PIN."
                    case .failure(let message): return message
                    }
                }, onCancel: { step = nil })
                .id(current.id)
            case .current(let thenNew):
                PinEntryView(title: "Enter the current PIN", subtitle: profile.name, onSubmit: { pin in
                    if thenNew {
                        let outcome = await profiles.verifyPin(id: profile.id, pin: pin)
                        guard outcome.unlocked else { return outcome.message ?? "Incorrect PIN" }
                        step = .new(current: pin)
                        return nil
                    }
                    if await profiles.clearPin(id: profile.id, currentPin: pin) { step = nil; return nil }
                    return "Incorrect PIN, or it couldn't be removed."
                }, onCancel: { step = nil })
                .id(current.id)
            }
        }
    }
}

/// Settings → Account → Watched: every title watched, one to a row, newest
/// first, scrolling; Select opens its page (`WatchedTitlePage`). Edit on
/// the title's line gives each row a trash button — one press removes the
/// title, every episode of a show — and Remove All beside Done. No hold
/// menus, no alerts. Removals reach the account (`WatchedStore.onRemove`).
struct WatchedSettingsPage: View {
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus

    /// The titles' records: the add-ons' (from disk for anything opened
    /// before), else TMDB's — the name, the poster, the episodes' names.
    @State private var metas: [String: MetaItem] = [:]
    /// Names Continue Watching or the library already know.
    @State private var known: [String: String] = [:]
    @State private var ready = false
    @State private var editing = false

    /// One title: a film, or a show's watched episodes.
    struct Entry: Identifiable {
        let id: String
        let items: [WatchedItem]
        var isShow: Bool { items.contains { $0.episode != nil } }
        var latest: Date { items.map(\.watchedAt).max() ?? .distantPast }
        var type: String {
            let type = items.first?.contentType ?? ""
            return type.isEmpty ? (isShow ? "series" : "movie") : type
        }
    }

    private var entries: [Entry] {
        Dictionary(grouping: watched.items.values, by: \.contentID)
            .map { Entry(id: $0.key, items: $0.value) }
            .sorted { $0.latest > $1.latest }
    }

    var body: some View {
        let entries = entries
        SettingsPage(title: "Watched", subtitle: Self.count(watched), accessory: entries.isEmpty ? nil : AnyView(accessory)) {
            if ready {
                if entries.isEmpty {
                    SettingsNote("Nothing watched yet.", large: true)
                } else {
                    LazyVStack(spacing: SettingsMetrics.tallRowGap) {
                        ForEach(entries) { entry in row(entry, in: entries) }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: ready)
        .task { await resolve() }
        .onExitCommand(perform: editing ? { end(focusing: "Edit") } : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onChange(of: entries.isEmpty) { _, empty in if empty { editing = false } }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    @ViewBuilder private var accessory: some View {
        if editing {
            SettingsCapsuleButton(title: "Remove All") {
                editing = false
                if let sync = NuvioSyncManager.shared {
                    Task { await sync.clearWatchHistoryEverywhere() }
                } else {
                    watched.clearAll()
                }
            }
            SettingsCapsuleButton(title: "Done") { end(focusing: "Edit") }
        } else {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func end(focusing id: String) {
        editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = id }
    }

    /// The Account page's value: "214 titles".
    static func count(_ store: WatchedStore) -> String {
        let titles = Set(store.items.values.map(\.contentID)).count
        return titles == 1 ? "1 title" : "\(titles) titles"
    }

    private func row(_ entry: Entry, in entries: [Entry]) -> some View {
        let name = name(of: entry)
        return WatchedRow(id: entry.id, poster: metas[entry.id]?.poster, name: name,
                          detail: detail(of: entry), chevron: true, editing: editing,
                          onSelect: { nav.push(WatchedTitlePage(id: entry.id, name: name, meta: metas[entry.id])) },
                          onRemove: {
                              WatchedRow.removed(entry.id, in: entries.map(\.id), focus: rowFocus)
                              watched.remove(keys: entry.items.map(\.key))
                          })
    }

    private func name(of entry: Entry) -> String {
        if let name = metas[entry.id]?.name, !name.isEmpty { return name }
        if let name = known[entry.id] { return name }
        if !entry.isShow, let film = entry.items.first, !film.title.isEmpty { return film.title }
        return entry.id
    }

    /// What was watched last, and when: "S2:E4, 14 Oct 2026"; a film the
    /// date alone.
    private func detail(of entry: Entry) -> String {
        let date = entry.latest.formatted(.dateTime.day().month(.abbreviated).year())
        guard entry.isShow, let last = entry.items.max(by: { $0.watchedAt < $1.watchedAt }) else {
            return date
        }
        return "S\(last.season ?? 0):E\(last.episode ?? 0), \(date)"
    }

    /// Every title's record: the add-on's (from disk when it was ever
    /// fetched — only the rest go out), else TMDB's. The page shows once
    /// they're in (1.5 s at most); later ones fill in.
    private func resolve() async {
        known = Self.knownNames(progress: progress, library: library)
        let wanted = entries.filter { metas[$0.id] == nil }.map { ($0.id, $0.type) }
        guard !wanted.isEmpty else { ready = true; return }
        let cap = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            ready = true
        }
        await Self.resolveMetas(wanted, addonManager: addonManager) { metas[$0] = $1 }
        cap.cancel()
        ready = true
    }

    /// Names Continue Watching or the library already know.
    static func knownNames(progress: ProgressStore, library: LibraryStore) -> [String: String] {
        var known: [String: String] = [:]
        for item in progress.items.values where !item.name.isEmpty { known[item.metaID] = item.name }
        for item in library.items.values where !item.name.isEmpty { known[item.id] = item.name }
        return known
    }

    /// Each title's record as it comes: the add-on's, else TMDB's.
    static func resolveMetas(_ wanted: [(String, String)], addonManager: AddonManager,
                             found: @MainActor (String, MetaItem) -> Void) async {
        let addons = Dictionary(wanted.map { ($0.0, addonManager.metaAddons(for: $0.1, id: $0.0).first) },
                                uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: (String, MetaItem?).self) { group in
            for (id, type) in wanted {
                let addon = addons[id] ?? nil
                group.addTask {
                    if let addon, let meta = try? await StremioAPI.meta(addon: addon, type: type, id: id),
                       !meta.name.isEmpty {
                        return (id, meta)
                    }
                    return (id, await TMDBService.metaItem(imdbID: id, type: type))
                }
            }
            for await (id, meta) in group {
                if let meta { await found(id, meta) }
            }
        }
    }
}

/// Settings → Account → Watch Progress: every position the account holds,
/// one to a row, newest first (what Continue Watching is made from; there
/// only a show's latest, unfinished). Select starts Edit on the row's
/// button; Edit gives each row a trash button, one press removes it, and
/// Remove All beside Done. Removals reach the account (`ProgressStore.onRemove`).
struct WatchProgressPage: View {
    @EnvironmentObject private var progress: ProgressStore
    @Environment(\.settingsRowFocus) private var rowFocus
    @State private var editing = false

    private var rows: [WatchProgress] {
        progress.items.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        let rows = rows
        SettingsPage(title: "Watch Progress", subtitle: "", accessory: rows.isEmpty ? nil : AnyView(accessory)) {
            if rows.isEmpty {
                SettingsNote("Nothing in progress.", large: true)
            } else {
                LazyVStack(spacing: SettingsMetrics.tallRowGap) {
                    ForEach(rows) { row($0, ids: rows.map(\.id)) }
                }
            }
        }
        .onExitCommand(perform: editing ? { end() } : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onChange(of: rows.isEmpty) { _, empty in if empty { editing = false } }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    private func row(_ item: WatchProgress, ids: [String]) -> some View {
        WatchedRow(id: item.id, poster: item.poster, name: item.name.isEmpty ? item.metaID : item.name,
                   detail: Self.detail(of: item), editing: editing,
                   removeLine: "Remove this position, on all your devices",
                   onSelect: {
                       editing = true
                       DispatchQueue.main.async { rowFocus?.wrappedValue = item.id }
                   },
                   onRemove: {
                       WatchedRow.removed(item.id, in: ids, focus: rowFocus)
                       progress.remove(id: item.id)
                   })
    }

    @ViewBuilder private var accessory: some View {
        if editing {
            SettingsCapsuleButton(title: "Remove All") {
                editing = false
                progress.clearAllProgress()
            }
            SettingsCapsuleButton(title: "Done") { end() }
        } else {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func end() {
        editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = "Edit" }
    }

    /// "S1:E1, 14:43 of 25:00, 14 Oct 2026"; a film without the episode.
    static func detail(of item: WatchProgress) -> String {
        var parts = ["\(clock(item.positionSeconds)) of \(clock(item.durationSeconds))",
                     item.updatedAt.formatted(.dateTime.day().month(.abbreviated).year())]
        if let season = item.season, let episode = item.episode {
            parts.insert("S\(season):E\(episode)", at: 0)
        }
        return parts.joined(separator: ", ")
    }

    /// "14:43", "1:02:09".
    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let minutes = String(format: "%02d", total / 60 % 60), rest = String(format: "%02d", total % 60)
        return total >= 3600 ? "\(total / 3600):\(minutes):\(rest)" : "\(total / 60):\(rest)"
    }
}

/// One row of Watched, Apple's two-line row (its Languages' "Deutsch /
/// German"): a title (a small poster, the name, what was watched last and
/// when, a chevron) or an episode (its name, when). A list's tall row, lit
/// whole at rest; in Edit only its trash button takes focus.
private struct WatchedRow: View {
    let id: String
    var poster: String?? = nil
    let name: String
    let detail: String
    var chevron = false
    let editing: Bool
    /// The left-hand line while its trash button has focus.
    var removeLine = "Remove from Watched"
    let onSelect: () -> Void
    let onRemove: () -> Void

    private enum Part: Hashable { case row, remove }
    @FocusState private var focused: Part?

    @Environment(\.settingsFocusHidden) private var focusHidden
    @Environment(\.settingsCards) private var cards
    private var lit: Bool { !editing && focused == .row && !focusHidden }

    /// Focus after a removal: the next row's button, else the one before's.
    static func removed(_ id: String, in ids: [String], focus: FocusState<String?>.Binding?) {
        guard let index = ids.firstIndex(of: id) else { return }
        let next = ids.indices.contains(index + 1) ? ids[index + 1]
            : ids.indices.contains(index - 1) ? ids[index - 1] : nil
        if let next { DispatchQueue.main.async { focus?.wrappedValue = next } }
    }

    var body: some View {
        Group {
            if editing {
                face
            } else {
                Button(action: onSelect) { face }
                    .buttonStyle(SettingsPress(lift: SettingsMetrics.focusScale))
                    .focused($focused, equals: .row)
                    .modifier(SettingsRowEntry(id: id))
            }
        }
        .anchorPreference(key: SettingsDescribedKey.self, value: .bounds) { pill in
            focused == .remove ? .init(text: removeLine, pill: pill) : nil
        }
        .focusSection()
        .id(id)
    }

    private var face: some View {
        let look = SettingsLook(cards: cards)
        return HStack(spacing: cards ? 18 : 24) {
            if let poster {
                let shape = RoundedRectangle(cornerRadius: cards ? 6 : 8, style: .continuous)
                RemoteImage(url: poster, maxDimension: 90, fallback: AnyView(Color.white.opacity(0.08)))
                    .frame(width: cards ? 44 : 58, height: cards ? 66 : 87)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(cards ? 0.15 : 0.3), lineWidth: cards ? 1 : 1.5) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(look.name)
                    .foregroundStyle(SettingsInk.name(lit, cards: cards))
                Text(detail)
                    .font(look.detail)
                    .foregroundStyle(SettingsInk.quiet(lit, cards: cards))
            }
            .lineLimit(1)
            Spacer(minLength: 24)
            if editing {
                Button(action: onRemove) {
                    SettingsRowButtonFace(icon: "trash", focused: focused == .remove, onLitRow: false)
                }
                .buttonStyle(SettingsPress(lift: SettingsRowButtonFace.focusScale))
                .focused($focused, equals: .remove)
                .modifier(SettingsRowEntry(id: id))
                .transition(.opacity)
            } else if chevron {
                Image(systemName: "chevron.right")
                    .font(look.chevron)
                    .foregroundStyle(SettingsInk.chevron(lit, cards: cards))
                    .padding(.trailing, look.chevronGap)
            }
        }
        .padding(.leading, poster == nil ? look.inset : (cards ? 10 : 16))
        .padding(.trailing, editing ? look.buttonInset : look.inset)
        .settingsTallChrome(lit: lit, cards: cards)
        .animation(.smooth(duration: 0.15), value: focused)
        .animation(.smooth(duration: 0.2), value: editing)
    }
}

/// A title's page (Watched → a title): what was watched of it — a show's
/// episodes, a section per season in the show's order ("E3: name", when
/// under it); a film its one row. Edit on the title's line gives each row
/// its trash button (one press removes it) and Remove All beside Done;
/// Select on a row starts Edit on its button. Empty, the page closes.
struct WatchedTitlePage: View {
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus
    let id: String
    let name: String
    let meta: MetaItem?
    @State private var editing = false

    private var items: [WatchedItem] {
        watched.items.values.filter { $0.contentID == id }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    var body: some View {
        let items = items
        let isShow = items.contains { $0.episode != nil }
        let seasons = Dictionary(grouping: items) { $0.season ?? 0 }.sorted { $0.key < $1.key }
        let ids = items.map(\.key)
        SettingsPage(title: name, subtitle: summary(items, isShow: isShow, seasons: seasons.count),
                     accessory: AnyView(accessory)) {
            if isShow {
                ForEach(seasons, id: \.key) { season, episodes in
                    SettingsSection(title: season == 0 ? "Specials" : "Season \(season)",
                                    spacing: SettingsMetrics.tallRowGap) {
                        ForEach(episodes, id: \.key) { item in
                            row(item, title: title(of: item), ids: ids)
                        }
                    }
                }
            } else {
                SettingsSection(spacing: SettingsMetrics.tallRowGap) {
                    ForEach(items, id: \.key) { item in row(item, title: name, ids: ids) }
                }
            }
        }
        .onChange(of: items.isEmpty) { _, empty in if empty { nav.pop() } }
        .onExitCommand(perform: editing ? { end() } : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    private func row(_ item: WatchedItem, title: String, ids: [String]) -> some View {
        WatchedRow(id: item.key, name: title, detail: Self.when(item.watchedAt), editing: editing,
                   onSelect: {
                       editing = true
                       DispatchQueue.main.async { rowFocus?.wrappedValue = item.key }
                   },
                   onRemove: {
                       WatchedRow.removed(item.key, in: ids, focus: rowFocus)
                       watched.remove(keys: [item.key])
                   })
    }

    @ViewBuilder private var accessory: some View {
        if editing {
            SettingsCapsuleButton(title: "Remove All") { watched.remove(keys: items.map(\.key)) }
            SettingsCapsuleButton(title: "Done") { end() }
        } else {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func end() {
        editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = "Edit" }
    }

    /// "14 Oct 2026, 23:15".
    private static func when(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    /// "41 episodes, 3 seasons"; a film nothing — its row says it.
    private func summary(_ items: [WatchedItem], isShow: Bool, seasons: Int) -> String {
        guard isShow else { return "" }
        return "\(items.count == 1 ? "1 episode" : "\(items.count) episodes"), "
            + (seasons == 1 ? "1 season" : "\(seasons) seasons")
    }

    /// "E3: Episode title": the record's name for it, else what the entry
    /// carries (the episode's own name when Cue marked it).
    private func title(of item: WatchedItem) -> String {
        let number = "E\(item.episode ?? 0)"
        let video = meta?.videos?.first { $0.season == item.season && $0.episode == item.episode }
        let title = video?.title ?? (item.title == name || item.title == meta?.name ? "" : item.title)
        return title.isEmpty ? number : "\(number): \(title)"
    }
}

// MARK: - Shared pieces

