import SwiftUI

/// Settings → Account. Nuvio, rows only: Account (the email; its page signs
/// out), Profiles (the active one; its page switches) — then Sync: Sync Now
/// with the last sync as its value, and what's synced, a count to a row (a
/// kind with a page of its own opens it: Add-ons, Watched; the rest only to
/// read). Signed out: Sign in (the first launch's sign-in screen).
struct AccountSettingsDetail: View {
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var profiles: ProfileStore

    @State private var signingIn = false

    var body: some View {
        Group {
            if case .signedIn(_, let email) = account.authState {
                SettingsPage(title: SettingsCategory.account.title, subtitle: "Manage synced data across web, mobile, and TV.") {
                    VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                        SettingsLinkRow(title: "Account", value: email.isEmpty ? "Nuvio account" : email) {
                            NuvioAccountPage(email: email)
                        }
                        SettingsLinkRow(title: "Profiles", value: profiles.active.name) { NuvioProfilesPage() }
                    }

                    SettingsSection(title: "Sync") {
                        if let sync = NuvioSyncManager.shared { SyncNowRow(sync: sync) }
                        SettingsLinkRow(title: "Add-ons", value: addons.addons.count.formatted()) { AddonsPage() }
                        // Its page: later.
                        Button {} label: {
                            SettingsRowLabel(title: "Watch progress", value: progress.items.count.formatted(), chevron: true)
                        }
                        .settingsRow(id: "Watch progress")
                        // Its page: later.
                        Button {} label: {
                            SettingsRowLabel(title: "Library", value: library.items.count.formatted(), chevron: true)
                        }
                        .settingsRow(id: "Library")
                        // Its page: later.
                        Button {} label: {
                            SettingsRowLabel(title: "Collections", value: collections.library.count.formatted(), chevron: true)
                        }
                        .settingsRow(id: "Collections")
                        SettingsLinkRow(title: "Watched", value: watched.items.count.formatted()) { WatchedSettingsPage() }
                    }
                }
            } else {
                SettingsPage(title: SettingsCategory.account.title, subtitle: SettingsCategory.account.subtitle) {
                    SettingsSection {
                        // The first launch's sign-in screen, over everything.
                        SettingsButtonRow(
                            title: "Sign in",
                            description: "Sign in to your Nuvio account to sync profiles, Continue Watching, your library, add-ons and settings with your other devices."
                        ) { signingIn = true }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $signingIn) {
            NuvioSignInView(account: account, onSignedIn: { signingIn = false })
                .onExitCommand { signingIn = false }
        }
    }
}

/// Sync Now, its value when the last sync was ("Today at 22:34",
/// "Syncing…", "Failed").
private struct SyncNowRow: View {
    @ObservedObject var sync: NuvioSyncManager

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        SettingsButtonRow(title: "Sync Now", value: state) {
            Task { await sync.syncNow() }
        }
    }

    private var state: String {
        if sync.isSyncing { return "Syncing…" }
        if sync.lastSyncError != nil { return "Failed" }
        guard let last = sync.lastSyncedAt else { return "Not yet" }
        return Self.formatter.string(from: last)
    }
}

/// Account → its page: Sign Out with the email on its right, confirmed.
private struct NuvioAccountPage: View {
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var nav: SettingsNav
    let email: String
    @State private var confirmSignOut = false

    var body: some View {
        SettingsPage(title: "Account", subtitle: "Signed in to Nuvio on this TV.") {
            SettingsButtonRow(title: "Sign Out", value: email) { confirmSignOut = true }
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) {
                account.signOut()
                nav.pop()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your watch progress, library and add-ons stay on this TV, but they'll stop syncing until you sign in again.")
        }
    }
}

/// Profiles → its page: every profile (avatar, name, "Primary · Active"),
/// Select opening its page; Add Profile last (the keyboard for the name,
/// then the new profile's page).
private struct NuvioProfilesPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var keyboard: KeyboardRequest?

    var body: some View {
        SettingsPage(title: "Profiles",
                     subtitle: "\(profiles.profiles.count) of \(ProfileStore.maxProfiles) profiles · Each has its own synced data.") {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ForEach(profiles.profiles) { profile in
                    Button { nav.push(ProfileSettingsPage(profileID: profile.id)) } label: {
                        SettingsRowLabel(title: profile.name, value: profiles.notes(for: profile), chevron: true,
                                         leading: AnyView(ProfileAvatarView(profile: profile, size: 44)))
                    }
                    .settingsRow(id: "profile-\(profile.id)")
                }
                if profiles.canAddProfile {
                    SettingsButtonRow(title: "Add Profile") {
                        keyboard = KeyboardRequest(text: "", placeholder: "Profile name") { name in
                            let name = name.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            if let created = profiles.addProfile(name: name) {
                                nav.push(ProfileSettingsPage(profileID: created.id))
                            } else {
                                ToastCenter.shared.show("Can't add a profile just yet — try again in a moment",
                                                        icon: "person.crop.circle.badge.exclamationmark")
                            }
                        }
                    }
                }
            }
        }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
    }
}

/// One profile: Switch to This Profile (not the active one; a locked one
/// asks its PIN), Name, Avatar, Colour, PIN, the active one's Collections,
/// Use Primary's Add-ons (not Primary), Copy Settings, Delete Profile (not
/// Primary).
private struct ProfileSettingsPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var nav: SettingsNav
    let profileID: Int

    @State private var keyboard: KeyboardRequest?
    @State private var unlocking = false
    @State private var confirmDelete = false

    private var profile: UserProfile? { profiles.profiles.first { $0.id == profileID } }

    var body: some View {
        if let profile {
            page(profile)
        }
    }

    private func page(_ profile: UserProfile) -> some View {
        let primary = profile.id == 1
        let active = profile.id == profiles.activeProfileID
        return SettingsPage(title: profile.name, subtitle: profiles.notes(for: profile)) {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                if !active {
                    SettingsButtonRow(title: "Switch to This Profile") {
                        if profile.pinEnabled { unlocking = true } else { profiles.setActive(profile.id) }
                    }
                }
                SettingsButtonRow(title: "Name", value: profile.name) {
                    keyboard = KeyboardRequest(text: profile.name, placeholder: "Profile name") { name in
                        let name = name.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { profiles.rename(id: profile.id, to: name) }
                    }
                }
                SettingsLinkRow(title: "Avatar", value: profiles.avatarName(for: profile)) {
                    ProfileAvatarPage(profileID: profile.id)
                }
                SettingsOptionsRow(title: "Colour", description: "Behind the initials, when there's no avatar.",
                                   options: ProfileStore.avatarColors.map { hex in
                                       SettingsOption(id: hex, label: ProfileStore.colourName(hex),
                                                      leading: AnyView(Circle().fill(Color(profileHex: hex))
                                                        .frame(width: 32, height: 32)))
                                   },
                                   selection: profile.avatarColorHex) { profiles.setColor(id: profile.id, hex: $0) }
                SettingsLinkRow(title: "PIN", value: profile.pinEnabled ? "On" : "Off") {
                    ProfilePinPage(profileID: profile.id)
                }
                if active, !collections.library.isEmpty {
                    SettingsLinkRow(title: "Collections", value: collectionsSummary) { ProfileCollectionsPage() }
                }
            }
            if !primary {
                SettingsSection(title: "Shared from Primary") {
                    SettingsToggleRow(title: "Use Primary's Add-ons",
                                      description: "Its add-ons instead of its own; changes to them show here too.",
                                      isOn: Binding(get: { profile.usesPrimaryAddons },
                                                    set: { profiles.setUsesPrimaryAddons(id: profile.id, $0) }))
                }
            }
            if profiles.profiles.count > 1 || !primary {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                    if profiles.profiles.count > 1 {
                        SettingsLinkRow(title: "Copy Settings") { ProfileCopyPage(targetID: profile.id) }
                    }
                    if !primary {
                        SettingsButtonRow(title: "Delete Profile") { confirmDelete = true }
                    }
                }
            }
        }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .fullScreenCover(isPresented: $unlocking) {
            ZStack {
                ATVBackground()
                PinEntryView(
                    title: "Enter PIN",
                    subtitle: profile.name,
                    onSubmit: { pin in
                        let outcome = await profiles.verifyPin(id: profile.id, pin: pin)
                        if outcome.unlocked {
                            unlocking = false
                            profiles.setActive(profile.id)
                            return nil
                        }
                        if outcome.retryAfterSeconds > 0 {
                            return "Too many attempts. Try again in \(outcome.retryAfterSeconds)s."
                        }
                        return outcome.message ?? "Incorrect PIN"
                    },
                    onCancel: { unlocking = false }
                )
            }
        }
        .alert("Delete \(profile.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                nav.pop()
                profiles.delete(id: profile.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile and everything synced to it from this TV and your Nuvio account.")
        }
    }

    private var collectionsSummary: String {
        let shown = collections.library.filter { collections.isVisible($0.id) }.count
        return "\(shown) of \(collections.library.count)"
    }
}

/// A profile's avatar: Use Initials (its colour), then the catalog as a
/// grid under its kinds' names. Select picks and goes back.
private struct ProfileAvatarPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    let profileID: Int

    private var profile: UserProfile? { profiles.profiles.first { $0.id == profileID } }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: SettingsMetrics.rowGap), count: 6)

    var body: some View {
        if let profile {
            SettingsPage(title: "Avatar", subtitle: "Initials use the profile's colour.") {
                Button { pick(nil) } label: {
                    SettingsRowLabel(title: "Use Initials", checked: profile.avatarID == nil,
                                     leading: AnyView(Circle().fill(Color(profileHex: profile.avatarColorHex))
                                        .overlay(Text(profile.initial).font(.system(size: 20, weight: .heavy))
                                            .foregroundStyle(.white))
                                        .frame(width: 44, height: 44)))
                }
                .settingsRow(id: "initials")
                ForEach(groups, id: \.name) { group in
                    SettingsSection(title: group.name) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: SettingsMetrics.rowGap) {
                            ForEach(group.items) { item in
                                Button { pick(item.id) } label: {
                                    AvatarTile(item: item, chosen: profile.avatarID == item.id)
                                }
                                .settingsRow(id: item.id)
                            }
                        }
                    }
                }
            }
            .task { await profiles.loadAvatarCatalog() }
        }
    }

    /// The catalog's kinds in its order.
    private var groups: [(name: String, items: [AvatarCatalogItem])] {
        var order: [String] = []
        var byKind: [String: [AvatarCatalogItem]] = [:]
        for item in profiles.avatarCatalog {
            if byKind[item.category] == nil { order.append(item.category) }
            byKind[item.category, default: []].append(item)
        }
        return order.map { (name: $0.capitalized, items: byKind[$0] ?? []) }
    }

    private func pick(_ id: String?) {
        profiles.setAvatar(id: profileID, avatarID: id)
        nav.pop()
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

/// A profile's PIN: off, Set PIN; on, Change PIN (the current one, then the
/// new) and Remove PIN (the current one).
private struct ProfilePinPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profileID: Int

    private enum Step: Identifiable {
        case set, current(thenNew: Bool), new(current: String)
        var id: String {
            switch self {
            case .set: return "set"
            case .current(let thenNew): return "current-\(thenNew)"
            case .new: return "new"
            }
        }
    }

    @State private var step: Step?

    private var profile: UserProfile? { profiles.profiles.first { $0.id == profileID } }

    var body: some View {
        if let profile {
            SettingsPage(title: "PIN", subtitle: profile.pinEnabled
                         ? "\(profile.name) asks for its PIN before it opens."
                         : "Ask for a 4-digit PIN before \(profile.name) opens.") {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                    if profile.pinEnabled {
                        SettingsButtonRow(title: "Change PIN") { step = .current(thenNew: true) }
                        SettingsButtonRow(title: "Remove PIN") { step = .current(thenNew: false) }
                    } else {
                        SettingsButtonRow(title: "Set PIN") { step = .set }
                    }
                }
            }
            .fullScreenCover(item: $step) { step in
                ZStack {
                    ATVBackground()
                    entry(step, profile: profile)
                }
            }
        }
    }

    @ViewBuilder
    private func entry(_ current: Step, profile: UserProfile) -> some View {
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

/// The active profile's collections: each one's folders shown here (its
/// page: the collection on or off, then its folders).
private struct ProfileCollectionsPage: View {
    @EnvironmentObject private var collections: CollectionsStore

    var body: some View {
        SettingsPage(title: "Collections", subtitle: "What this profile sees.") {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ForEach(collections.library) { collection in
                    if collections.isGloballyVisible(collection.id) {
                        SettingsLinkRow(title: collection.title, value: summary(collection)) {
                            ProfileCollectionFoldersPage(collectionID: collection.id)
                        }
                    } else {
                        SettingsRowLabel(title: collection.title, value: "Off for everyone")
                    }
                }
            }
        }
    }

    private func summary(_ collection: CueCollection) -> String {
        guard collections.isVisible(collection.id) else { return "Hidden" }
        let total = collection.folders.count
        let on = collection.folders.filter { collections.isFolderVisible($0.id) }.count
        return on == total ? "All \(total) folders" : "\(on) of \(total) folders"
    }
}

private struct ProfileCollectionFoldersPage: View {
    @EnvironmentObject private var collections: CollectionsStore
    let collectionID: String

    var body: some View {
        if let collection = collections.library.first(where: { $0.id == collectionID }) {
            SettingsPage(title: collection.title, subtitle: "Which folders this profile sees.") {
                SettingsToggleRow(title: "Show This Collection",
                                  isOn: Binding(get: { collections.isVisible(collection.id) },
                                                set: { collections.setVisible($0, id: collection.id) }))
                if collections.isVisible(collection.id) {
                    SettingsSection(title: "Folders") {
                        ForEach(collection.folders) { folder in
                            if collections.isFolderGloballyVisible(folder.id) {
                                SettingsToggleRow(title: folder.title,
                                                  isOn: Binding(get: { collections.isFolderVisible(folder.id) },
                                                                set: { collections.setFolderVisible($0, id: folder.id) }))
                            } else {
                                SettingsRowLabel(title: folder.title, value: "Off for everyone")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Copy Settings onto a profile, as the website's: from which profile, what
/// (each app's settings, the API keys — replacing the ones it has, or not),
/// then Copy Settings, confirmed. Once: later changes stay separate.
private struct ProfileCopyPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    let targetID: Int

    @State private var copy: ProfileSetupCopy?
    @State private var copying = false
    @State private var confirm = false

    private var target: UserProfile? { profiles.profiles.first { $0.id == targetID } }

    var body: some View {
        if let target {
            let sources = profiles.profiles.filter { $0.id != targetID }
            let copy = copy ?? ProfileSetupCopy(source: sources.first?.id ?? 1, target: targetID)
            SettingsPage(title: "Copy Settings",
                         subtitle: "A one-time copy of another profile's synced settings onto \(target.name). Later changes stay separate.") {
                SettingsOptionsRow(title: "Copy From",
                                   options: sources.map { SettingsOption(id: "\($0.id)", label: $0.name) },
                                   selection: "\(copy.source)") { id in
                    self.copy = with(copy) { $0.source = Int(id) ?? $0.source }
                }
                SettingsSection(title: "What to copy") {
                    toggle("TV Settings", "Appearance, layout, playback, subtitles and integrations — Cue's and NuvioTV's.",
                           copy, \.tv)
                    toggle("Mobile Settings", "Nuvio Mobile's appearance, cards, playback, metadata and notifications.",
                           copy, \.mobile)
                    toggle("Desktop Settings", "Nuvio Desktop's appearance, navigation, cards, playback, metadata and notifications.",
                           copy, \.desktop)
                    toggle("API Keys", "Debrid, TMDB, MDBList, AnimeSkip and IntroDB. Trakt and other sign-ins aren't included.",
                           copy, \.keys)
                    if copy.keys {
                        toggle("Replace \(target.name)'s Keys", "Keys only \(target.name) has are always kept.",
                               copy, \.replaceKeys)
                    }
                }
                SettingsButtonRow(title: "Copy Settings", value: copying ? "Copying…" : nil) {
                    guard !copying, !copy.isEmpty else { return }
                    confirm = true
                }
            }
            .alert("Replace \(target.name)'s settings?", isPresented: $confirm) {
                Button("Copy") { run(copy) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Home layout, watch history, library, collections, add-ons, PIN and the profile itself stay as they are.")
            }
        }
    }

    private func toggle(_ title: String, _ description: String, _ copy: ProfileSetupCopy,
                        _ part: WritableKeyPath<ProfileSetupCopy, Bool>) -> some View {
        SettingsToggleRow(title: title, description: description,
                          isOn: Binding(get: { copy[keyPath: part] },
                                        set: { on in self.copy = with(copy) { $0[keyPath: part] = on } }))
    }

    private func with(_ copy: ProfileSetupCopy, _ change: (inout ProfileSetupCopy) -> Void) -> ProfileSetupCopy {
        var copy = copy
        change(&copy)
        return copy
    }

    private func run(_ copy: ProfileSetupCopy) {
        copying = true
        Task {
            let failure = await profiles.copySetup(copy)
            copying = false
            if let failure {
                ToastCenter.shared.show(failure, icon: "exclamationmark.triangle")
            } else {
                ToastCenter.shared.show("Settings copied", icon: "checkmark")
                nav.pop()
            }
        }
    }
}

/// Settings → Account → Watched: every title watched, one to a row, newest
/// first, scrolling. A show opens what was watched of it
/// (`WatchedTitlePage`); a film's Select — and any title's hold — offers
/// Remove. Clear all by the heading. Removals reach the account
/// (`WatchedStore.onRemove`).
struct WatchedSettingsPage: View {
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var nav: SettingsNav

    /// The titles' records: the add-ons' (from disk for anything opened
    /// before), else TMDB's — the name, the poster, the episodes' names.
    @State private var metas: [String: MetaItem] = [:]
    /// Names Continue Watching or the library already know.
    @State private var known: [String: String] = [:]
    @State private var ready = false
    @State private var confirmClear = false

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
        SettingsPage(title: "Watched", subtitle: summary(entries), accessory: entries.isEmpty ? nil : AnyView(
            SettingsRoundButton(icon: "trash", title: "Clear all") { confirmClear = true }
        )) {
            if ready {
                if entries.isEmpty {
                    Text("Nothing watched yet.")
                        .font(.system(size: SettingsMetrics.valueTextSize))
                        .foregroundStyle(SettingsMetrics.secondaryText)
                        .padding(.horizontal, SettingsMetrics.labelIndent)
                } else {
                    LazyVStack(spacing: SettingsMetrics.rowGap) {
                        ForEach(entries) { entry in row(entry) }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: ready)
        .task { await resolve() }
        .onAppear { HoldMenu.shared.install() }
        .alert("Clear all watch history?", isPresented: $confirmClear) {
            Button("Clear everything", role: .destructive) {
                if let sync = NuvioSyncManager.shared {
                    Task { await sync.clearWatchHistoryEverywhere() }
                } else {
                    watched.clearAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(Self.count(watched)) here and everything in Continue Watching — on this TV and on all your devices. This can't be undone.")
        }
    }

    /// The Account page's value: "214 titles".
    static func count(_ store: WatchedStore) -> String {
        let titles = Set(store.items.values.map(\.contentID)).count
        return titles == 1 ? "1 title" : "\(titles) titles"
    }

    /// "1,530 records · 214 titles".
    private func summary(_ entries: [Entry]) -> String {
        let records = watched.items.count
        return "\(records.formatted()) \(records == 1 ? "record" : "records") · "
            + "\(entries.count.formatted()) \(entries.count == 1 ? "title" : "titles")"
    }

    private func row(_ entry: Entry) -> some View {
        let name = name(of: entry)
        let remove = MenuEntry(title: "Remove from Watched", icon: "minus.circle", destructive: true,
                               confirm: entry.isShow ? "Remove All \(entry.items.count) Episodes" : nil) {
            watched.remove(keys: entry.items.map(\.key))
        }
        return WatchedTitleRow(id: entry.id, poster: metas[entry.id]?.poster, name: name,
                               label: entry.isShow ? "Last watched" : "Watched",
                               detail: detail(of: entry), opens: entry.isShow, hold: [remove]) { frame in
            if entry.isShow {
                nav.push(WatchedTitlePage(id: entry.id, name: name, meta: metas[entry.id]))
            } else {
                HoldMenu.shared.openDropdown([remove], below: frame)
            }
        }
    }

    private func name(of entry: Entry) -> String {
        if let name = metas[entry.id]?.name, !name.isEmpty { return name }
        if let name = known[entry.id] { return name }
        if !entry.isShow, let film = entry.items.first, !film.title.isEmpty { return film.title }
        return entry.id
    }

    /// What was watched last, and when (after its label): "S2:E4 on 14 Oct
    /// 2026, 23:15"; a film just the date.
    private func detail(of entry: Entry) -> String {
        let date = entry.latest.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        guard entry.isShow, let last = entry.items.max(by: { $0.watchedAt < $1.watchedAt }) else {
            return date
        }
        return "S\(last.season ?? 0):E\(last.episode ?? 0) on \(date)"
    }

    /// Every title's record: the add-on's (from disk when it was ever
    /// fetched — only the rest go out), else TMDB's. The page shows once
    /// they're in (1.5 s at most); later ones fill in.
    private func resolve() async {
        var known: [String: String] = [:]
        for item in progress.items.values where !item.name.isEmpty { known[item.metaID] = item.name }
        for item in library.items.values where !item.name.isEmpty { known[item.id] = item.name }
        self.known = known
        let wanted = entries.filter { metas[$0.id] == nil }.map { ($0.id, $0.type) }
        guard !wanted.isEmpty else { ready = true; return }
        let cap = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            ready = true
        }
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
                if let meta { metas[id] = meta }
            }
        }
        cap.cancel()
        ready = true
    }
}

/// A watched title, one to a row: a small poster, the name, under it its
/// label ("Last watched") and what was watched last and when (a show: a chevron at the end — it opens). The rows' look: a faint fill, focused white.
/// Select gets the row's frame (a dropdown opens under it).
private struct WatchedTitleRow: View {
    let id: String
    let poster: String?
    let name: String
    let label: String
    let detail: String
    let opens: Bool
    let hold: [MenuEntry]
    let action: (CGRect) -> Void
    @State private var frame = CGRect.zero
    /// Its hold menu is open: the press that opened it isn't a Select.
    @State private var held = false

    var body: some View {
        Button { if !held { action(frame) } } label: {
            Face(poster: poster, name: name, label: label, detail: detail, opens: opens, hold: hold) { held = $0 }
        }
        .settingsRow(id: id)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, rect in frame = rect }
            }
        }
    }

    private struct Face: View {
        @Environment(\.isFocused) private var isFocused
        let poster: String?
        let name: String
        let label: String
        let detail: String
        let opens: Bool
        let hold: [MenuEntry]
        let onHeld: (Bool) -> Void

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            HStack(spacing: 22) {
                RemoteImage(url: poster, maxDimension: 96, fallback: AnyView(Color.white.opacity(0.08)))
                    .frame(width: 64, height: 96)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                    // The label a step up (brighter, medium), what and when after it.
                    (Text(label)
                        .fontWeight(.medium)
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.85)
                                                   : SettingsMetrics.primaryText)
                     + Text("  \(detail)")
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.6)
                                                   : SettingsMetrics.secondaryText))
                        .font(.system(size: 24))
                }
                .lineLimit(1)
                Spacer(minLength: 16)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.6)
                                                   : SettingsMetrics.secondaryText)
                }
            }
            .padding(.vertical, 14)
            .padding(.leading, 14)
            .padding(.trailing, SettingsMetrics.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .holdMenu(focused: isFocused, onHeld: onHeld) { hold }
            .animation(.smooth(duration: 0.18), value: isFocused)
        }
    }
}

/// A show's watched episodes (Watched → a show): a section per season, the
/// episodes two across (their names fit), each with when it was watched; Select: Remove.
/// Remove all by the heading. Empty, the page closes.
struct WatchedTitlePage: View {
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var nav: SettingsNav
    let id: String
    let name: String
    let meta: MetaItem?
    @State private var removeAllFrame = CGRect.zero

    private var items: [WatchedItem] {
        watched.items.values.filter { $0.contentID == id }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    var body: some View {
        let items = items
        let seasons = Dictionary(grouping: items) { $0.season ?? 0 }.sorted { $0.key < $1.key }
        SettingsPage(title: name, subtitle: summary(items, seasons: seasons.count), accessory: AnyView(
            SettingsRoundButton(icon: "trash", title: "Remove all") {
                HoldMenu.shared.openDropdown([
                    MenuEntry(title: "Remove All \(items.count == 1 ? "1 Episode" : "\(items.count) Episodes")",
                              icon: "minus.circle", destructive: true) {
                        watched.remove(keys: items.map(\.key))
                    }
                ], below: removeAllFrame)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { removeAllFrame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { _, rect in removeAllFrame = rect }
                }
            }
        )) {
            ForEach(seasons, id: \.key) { season, episodes in
                SettingsSection(title: season == 0 ? "Specials" : "Season \(season)") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SettingsMetrics.rowGap,
                                                                 alignment: .top), count: 2),
                              alignment: .leading, spacing: SettingsMetrics.rowGap) {
                        ForEach(episodes, id: \.key) { item in
                            WatchedEpisodeTile(title: title(of: item), date: item.watchedAt, key: item.key) {
                                watched.remove(keys: [item.key])
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: items.isEmpty) { _, empty in if empty { nav.pop() } }
    }

    /// "41 episodes · 3 seasons".
    private func summary(_ items: [WatchedItem], seasons: Int) -> String {
        "\(items.count == 1 ? "1 episode" : "\(items.count) episodes") · "
            + (seasons == 1 ? "1 season" : "\(seasons) seasons")
    }

    /// "E3 · Episode title": the record's name for it, else what the entry
    /// carries (the episode's own name when Cue marked it).
    private func title(of item: WatchedItem) -> String {
        let number = "E\(item.episode ?? 0)"
        let video = meta?.videos?.first { $0.season == item.season && $0.episode == item.episode }
        let title = video?.title ?? (item.title == name || item.title == meta?.name ? "" : item.title)
        return title.isEmpty ? number : "\(number) · \(title)"
    }
}

/// One watched episode: its number and name, when it was watched under it
/// (the count tiles' look); Select opens Remove under it.
private struct WatchedEpisodeTile: View {
    let title: String
    let date: Date
    let key: String
    let remove: () -> Void
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            HoldMenu.shared.openDropdown([MenuEntry(title: "Remove", icon: "minus.circle",
                                                    destructive: true, run: remove)], below: frame)
        } label: {
            Face(title: title, date: date)
        }
        .settingsRow(id: key)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, rect in frame = rect }
            }
        }
    }

    private struct Face: View {
        @Environment(\.isFocused) private var isFocused
        let title: String
        let date: Date

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isFocused ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                Text(date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                    .font(.system(size: 24))
                    .foregroundStyle(isFocused ? SettingsMetrics.focusedText.opacity(0.6) : SettingsMetrics.secondaryText)
            }
            .lineLimit(1)
            .padding(SettingsMetrics.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.18), value: isFocused)
        }
    }
}

// MARK: - Shared pieces

/// One line of the sync log (Settings → Developer).
struct SyncLogRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let entry: NuvioSyncLogEntry

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(entry.timeLabel)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(entry.area)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.palette.secondary)
                .frame(width: 90, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.background.opacity(0.32))
        )
    }

    private var icon: String {
        switch entry.level {
        case .info: return "circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return theme.palette.textTertiary
        case .success: return CuePrimitives.success
        case .warning: return theme.palette.secondary
        case .failure: return CuePrimitives.error
        }
    }
}
