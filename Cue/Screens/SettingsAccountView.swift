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
                SettingsPage(title: SettingsCategory.account.title) {
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
                SettingsPage(title: SettingsCategory.account.title) {
                    SettingsSection {
                        // The first launch's sign-in screen, over everything.
                        SettingsButtonRow(title: "Sign in") { signingIn = true }
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

    var body: some View {
        SettingsButtonRow(title: "Sync Now", value: state) {
            Task { await sync.syncNow() }
        }
    }

    private var state: String {
        if sync.isSyncing { return "Syncing…" }
        if sync.lastSyncError != nil { return "Failed" }
        guard let last = sync.lastSyncedAt else { return "Not yet" }
        return DateFormatter.settingsWhen.string(from: last)
    }
}

/// Account → its page: Sign Out with the email on its right, confirmed.
private struct NuvioAccountPage: View {
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var nav: SettingsNav
    let email: String
    @State private var confirmSignOut = false

    var body: some View {
        SettingsPage(title: "Account") {
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

/// Profiles → its page: every profile (avatar, name, "Primary, Active"),
/// Select opening its page; Add Profile last (`ProfileSetup`, the guided
/// steps, then the new profile's page).
private struct NuvioProfilesPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var adding = false

    var body: some View {
        SettingsPage(title: "Profiles",
                     subtitle: "\(profiles.profiles.count) of \(ProfileStore.maxProfiles) profiles") {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ForEach(profiles.profiles) { profile in
                    Button { nav.push(ProfileSettingsPage(profileID: profile.id)) } label: {
                        SettingsRowLabel(title: profile.name, value: profiles.notes(for: profile), chevron: true,
                                         leading: AnyView(ProfileAvatarView(profile: profile, size: 44)))
                    }
                    .settingsRow(id: "profile-\(profile.id)")
                }
                if profiles.canAddProfile {
                    SettingsButtonRow(title: "Add Profile") { adding = true }
                }
            }
        }
        .fullScreenCover(isPresented: $adding) {
            ProfileSetup(onFinish: { created in
                adding = false
                nav.push(ProfileSettingsPage(profileID: created.id))
            }, onCancel: { adding = false })
            .environmentObject(profiles)
        }
    }
}

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

/// One profile: Switch to This Profile (not the active one; a locked one
/// asks its PIN), Name, Avatar, Colour, PIN, the active one's Collections,
/// Use Primary's Add-ons (not Primary), Copy Settings, Delete Profile (not
/// Primary).
struct ProfileSettingsPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.fromProfileGate) private var fromGate
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
                // On the gate, picking an avatar switches.
                if !active, !fromGate {
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
            ProfilePinCheck(profile: profile) {
                unlocking = false
                profiles.setActive(profile.id)
            } onCancel: { unlocking = false }
        }
        .alert("Delete \(profile.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                nav.back()
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

    var body: some View {
        if let profile {
            SettingsPage(title: "Avatar") {
                AvatarChoices(initials: profile, chosen: profile.avatarID) { id in
                    profiles.setAvatar(id: profileID, avatarID: id)
                    nav.pop()
                }
            }
        }
    }
}

/// The avatars to pick from, in Settings' look: Use Initials (a row, the
/// profile's colour), then the catalog six across under its kinds' names.
/// Also Add Profile's avatar step (`ProfileSetup`).
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
        SettingsPage(title: "Collections") {
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
            SettingsPage(title: collection.title) {
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
                    Text("Nothing watched yet.")
                        .font(.system(size: SettingsMetrics.valueTextSize))
                        .foregroundStyle(SettingsMetrics.secondaryText)
                        .padding(.horizontal, SettingsMetrics.labelIndent)
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
    let onSelect: () -> Void
    let onRemove: () -> Void

    private enum Part: Hashable { case row, remove }
    @FocusState private var focused: Part?

    @Environment(\.settingsFocusHidden) private var focusHidden
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
                    .buttonStyle(PressStyle())
                    .focused($focused, equals: .row)
                    .modifier(SettingsRowEntry(id: id))
            }
        }
        .anchorPreference(key: SettingsDescribedKey.self, value: .bounds) { pill in
            focused == .remove ? .init(text: "Remove from Watched", pill: pill) : nil
        }
        .focusSection()
        .id(id)
    }

    private var face: some View {
        HStack(spacing: 24) {
            if let poster {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                RemoteImage(url: poster, maxDimension: 90, fallback: AnyView(Color.white.opacity(0.08)))
                    .frame(width: 58, height: 87)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText : SettingsMetrics.primaryText)
                Text(detail)
                    .font(.system(size: SettingsMetrics.descriptionTextSize))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText.opacity(0.6) : SettingsMetrics.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 24)
            if editing {
                Button(action: onRemove) {
                    SettingsRowButtonFace(icon: "trash", focused: focused == .remove, onLitRow: false)
                }
                .buttonStyle(PressStyle())
                .focused($focused, equals: .remove)
                .modifier(SettingsRowEntry(id: id))
                .transition(.opacity)
            } else if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: SettingsMetrics.rowTextSize, weight: .medium))
                    .foregroundStyle(lit ? SettingsMetrics.focusedText.opacity(0.45) : SettingsMetrics.secondaryText)
                    .padding(.trailing, SettingsMetrics.chevronInset)
            }
        }
        .padding(.leading, poster == nil ? SettingsMetrics.rowInset : 16)
        .padding(.trailing, editing ? SettingsMetrics.rowButtonInset : SettingsMetrics.rowInset)
        .frame(height: SettingsMetrics.tallRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: SettingsMetrics.tallRowRadius, style: .continuous)
            Group {
                if lit { GlassHighlight(focused: true, shape: shape) }
                else { shape.fill(SettingsMetrics.restingFill) }
            }
            .padding(.vertical, lit ? -(SettingsMetrics.focusGrowth
                - SettingsMetrics.tallRowHeight * (SettingsMetrics.focusScale - 1) / 2) : 0)
            .shadow(color: .black.opacity(lit ? 0.3 : 0), radius: 16, y: 8)
        }
        .scaleEffect(lit ? SettingsMetrics.focusScale : 1)
        .animation(.smooth(duration: 0.18), value: lit)
        .animation(.smooth(duration: 0.15), value: focused)
        .animation(.smooth(duration: 0.2), value: editing)
    }

    /// No system focus look: the row draws it.
    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
        }
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
