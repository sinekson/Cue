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
    @EnvironmentObject private var profiles: ProfileStore

    @State private var signingIn = false

    var body: some View {
        Group {
            if case .signedIn(_, let email) = account.authState {
                SettingsPage(title: SettingsCategory.account.title) {
                    SettingsSection {
                        SettingsLinkRow(title: "Account", value: email.isEmpty ? "Nuvio account" : email) {
                            NuvioAccountPage(email: email)
                        }
                        SettingsLinkRow(title: "Profiles", value: profiles.active.name) { NuvioProfilesPage() }
                    }

                    SettingsSection(title: "Sync") {
                        if let sync = NuvioSyncManager.shared { SyncNowRow(sync: sync) }
                        SettingsLinkRow(title: "Add-ons", value: addons.addons.count.formatted()) { AddonsPage() }
                        SettingsLinkRow(title: "Watch Progress", value: progress.items.count.formatted()) {
                            WatchProgressPage()
                        }
                        SettingsLinkRow(title: "Library", value: library.items.count.formatted()) { LibraryPage() }
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
struct NuvioAccountPage: View {
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
struct NuvioProfilesPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsCards) private var cards
    @State private var adding = false

    /// A profile's page: Settings 2's one page, else the old levels.
    private func open(_ id: Int) {
        if cards { nav.push(ProfileEditPage(profileID: id)) } else { nav.push(ProfileSettingsPage(profileID: id)) }
    }

    var body: some View {
        SettingsPage(title: "Profiles",
                     subtitle: "\(profiles.profiles.count) of \(ProfileStore.maxProfiles) profiles") {
            SettingsSection {
                ForEach(profiles.profiles) { profile in
                    Button { open(profile.id) } label: {
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
                open(created.id)
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

/// A profile in Settings 2, everything on one page: a header in its colour
/// (the avatar, the name, "Primary, Active"), changing as you pick; Name,
/// Colour (its swatches in the row) and the PIN's rows; the
/// avatars to pick from in place; then Switch, Use Primary's
/// Add-ons, Copy Settings, Delete Profile.
struct ProfileEditPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.fromProfileGate) private var fromGate
    let profileID: Int

    @State private var keyboard: KeyboardRequest?
    @State private var unlocking = false
    @State private var confirmDelete = false
    @State private var pin: ProfilePinStep?

    private var profile: UserProfile? { profiles.profiles.first { $0.id == profileID } }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 10)

    var body: some View {
        if let profile { page(profile) }
    }

    private func page(_ profile: UserProfile) -> some View {
        let primary = profile.id == 1
        let active = profile.id == profiles.activeProfileID
        return SettingsPage(title: "Edit Profile") {
            ProfileEditHeader(profile: profile, notes: profiles.notes(for: profile))
                .containerValue(\.settingsOwnCard, true)
                .preference(key: CardFirstLabelKey.self, value: false)

            SettingsSection(title: "Profile") {
                Button {
                    keyboard = KeyboardRequest(text: profile.name, placeholder: "Profile name") { name in
                        let name = name.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { profiles.rename(id: profile.id, to: name) }
                    }
                } label: {
                    SettingsRowLabel(title: "Name", value: profile.name)
                }
                .settingsRow(id: "pe.name")
                // The PIN: its actions as rows.
                if profile.pinEnabled {
                    SettingsButtonRow(title: "Change PIN",
                                      description: "Asked before \(profile.name) opens.") { pin = .current(thenNew: true) }
                    SettingsButtonRow(title: "Remove PIN") { pin = .current(thenNew: false) }
                } else {
                    SettingsButtonRow(title: "Set PIN",
                                      description: "A 4-digit PIN before \(profile.name) opens.") { pin = .set }
                }
            }

            // Above the avatars: the grid is long.
            if (!active && !fromGate) || !primary || profiles.profiles.count > 1 {
            SettingsSection(title: "More") {
                if !active, !fromGate {
                    SettingsButtonRow(title: "Switch to This Profile") {
                        if profile.pinEnabled { unlocking = true } else { profiles.setActive(profile.id) }
                    }
                }
                if !primary {
                    SettingsOnOffRow(id: "pe.primaryAddons", title: "Use Primary's Add-ons",
                                     description: "Its add-ons instead of its own, kept in step.",
                                     isOn: profile.usesPrimaryAddons) { profiles.setUsesPrimaryAddons(id: profile.id, $0) }
                }
                if profiles.profiles.count > 1 {
                    SettingsLinkRow(title: "Copy Settings") { ProfileCopyPage(targetID: profile.id) }
                }
                if !primary {
                    Button { confirmDelete = true } label: {
                        SettingsRowLabel(title: "Delete Profile", danger: true)
                    }
                    .settingsRow(id: "pe.delete")
                }
            }
            }
            SettingsSection(title: "Avatar") {
                // The initials on a colour, a group as the avatars' (picking
                // one is the initials on it), then every kind of avatar.
                group("Colours") {
                    ForEach(ProfileStore.avatarColors, id: \.self) { hex in
                        Button {
                            profiles.setColor(id: profile.id, hex: hex)
                            profiles.setAvatar(id: profile.id, avatarID: nil)
                        } label: {
                            ProfileEditColourTile(hex: hex, initial: profile.initial,
                                                  chosen: profile.avatarID == nil
                                                    && profile.avatarColorHex.uppercased() == hex.uppercased())
                        }
                        .buttonStyle(SettingsPress(lift: 1))
                    }
                }
                // Every kind in the same card, each under its name.
                ForEach(AvatarChoices.groups(profiles.avatarCatalog), id: \.name) { avatars in
                    group(avatars.name) {
                        ForEach(avatars.items) { item in
                            Button { profiles.setAvatar(id: profile.id, avatarID: item.id) } label: {
                                ProfileEditAvatarTile(item: item, chosen: profile.avatarID == item.id)
                            }
                            // Not in the column's focus binding: each move
                            // through the grid rebuilt the whole page.
                            .buttonStyle(SettingsPress(lift: 1))
                        }
                    }
                }
            }

        }
        .task { await profiles.loadAvatarCatalog() }
        .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        .fullScreenCover(isPresented: $unlocking) {
            ProfilePinCheck(profile: profile) {
                unlocking = false
                profiles.setActive(profile.id)
            } onCancel: { unlocking = false }
        }
        .fullScreenCover(item: $pin) { current in
            ProfilePinEntry(profile: profile, current: current, step: $pin)
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

    /// A kind of avatar under its name, ten across.
    private func group<Tiles: View>(_ name: String, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(CueInk.tertiary)
                .padding(.leading, CardSettingsRow.textInset - CardSettingsRow.plateInset)
                .padding(.top, 12)
            LazyVGrid(columns: columns, spacing: 12) { tiles() }
        }
        .focusSection()
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

/// A colour to pick: the profile's initial on it, round, the avatars' size
/// and plates (focused the rows' glass, chosen the selected tint).
private struct ProfileEditColourTile: View {
    @Environment(\.isFocused) private var isFocused
    let hex: String
    let initial: String
    let chosen: Bool

    var body: some View {
        Circle()
            .fill(Color(profileHex: hex))
            .overlay {
                Text(initial)
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 80, height: 80)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                Group {
                    if isFocused { GlassHighlight(focused: true, shape: shape) }
                    else if chosen { GlassHighlight(focused: false, shape: shape) }
                }
                .padding(.horizontal, 4)
            }
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// An avatar to pick: its picture round, its name under it, on a plate
/// a little smaller than the tile's room: focused, the rows' glass;
/// chosen, the selected tint (as the shown category).
private struct ProfileEditAvatarTile: View {
    @Environment(\.isFocused) private var isFocused
    let item: AvatarCatalogItem
    let chosen: Bool

    var body: some View {
        VStack(spacing: 8) {
            // The app's cached loader, decoded at its size (AsyncImage kept
            // nothing: every visit loaded them all again).
            RemoteImage(url: item.imageURL, maxDimension: 80, fallback: AnyView(Color.white.opacity(0.08)))
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            Text(item.displayName)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(isFocused ? Color.black : CueInk.primary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background {
            // Glass only where it shows: a hidden one is still drawn.
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            Group {
                if isFocused { GlassHighlight(focused: true, shape: shape) }
                else if chosen { GlassHighlight(focused: false, shape: shape) }
            }
            .padding(.horizontal, 4)
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// One profile: Switch to This Profile (not the active one; a locked one
/// asks its PIN), Name, Avatar, Colour, PIN,
/// Use Primary's Add-ons (not Primary), Copy Settings, Delete Profile (not
/// Primary).
struct ProfileSettingsPage: View {
    @EnvironmentObject private var profiles: ProfileStore
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
            SettingsSection {
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
                SettingsSection {
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

/// A profile's PIN: off, Set PIN; on, Change PIN (the current one, then the
/// new) and Remove PIN (the current one).
private struct ProfilePinPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profileID: Int

    @State private var step: ProfilePinStep?

    private var profile: UserProfile? { profiles.profiles.first { $0.id == profileID } }

    var body: some View {
        if let profile {
            SettingsPage(title: "PIN", subtitle: profile.pinEnabled
                         ? "\(profile.name) asks for its PIN before it opens."
                         : "Ask for a 4-digit PIN before \(profile.name) opens.") {
                SettingsSection {
                    if profile.pinEnabled {
                        SettingsButtonRow(title: "Change PIN") { step = .current(thenNew: true) }
                        SettingsButtonRow(title: "Remove PIN") { step = .current(thenNew: false) }
                    } else {
                        SettingsButtonRow(title: "Set PIN") { step = .set }
                    }
                }
            }
            .fullScreenCover(item: $step) { current in
                ProfilePinEntry(profile: profile, current: current, step: $step)
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
            let from = sources.first { $0.id == copy.source }?.name ?? ""
            SettingsPage(title: "Copy Settings") {
                SettingsSection(title: "From") {
                    let options = sources.map { SettingsOption(id: "\($0.id)", label: $0.name) }
                    let pick: (String) -> Void = { id in self.copy = with(copy) { $0.source = Int(id) ?? $0.source } }
                    // Up to three: pills; more, their own page.
                    if options.count <= 3 {
                        SettingsChoiceRow(id: "cp.from", title: "Copy From",
                                          description: "The profile whose settings \(target.name) takes.",
                                          options: options, selection: "\(copy.source)", onPick: pick)
                    } else {
                        SettingsOptionsRow(title: "Copy From", options: options, selection: "\(copy.source)",
                                           onPick: pick)
                    }
                }
                SettingsSection(title: "What to Copy") {
                    toggle("cp.tv", "TV Settings", "Cue's and NuvioTV's look, playback, subtitles and more.", copy, \.tv)
                    toggle("cp.mobile", "Mobile Settings", "Nuvio Mobile's look, cards, playback and notifications.",
                           copy, \.mobile)
                    toggle("cp.desktop", "Desktop Settings", "Nuvio Desktop's look, cards, playback and notifications.",
                           copy, \.desktop)
                    toggle("cp.keys", "API Keys", "TMDB, MDBList, debrid, AnimeSkip and IntroDB; no sign-ins.",
                           copy, \.keys)
                    if copy.keys {
                        toggle("cp.replace", "Replace \(target.name)'s Keys", "Keys only \(target.name) has are always kept.",
                               copy, \.replaceKeys)
                    }
                }
                SettingsSection {
                    ActionListRow(
                        id: "cp.copy",
                        title: copying ? "Copying…" : "Copy from \(from) to \(target.name)",
                        detail: copy.isEmpty ? "Choose something to copy." : "Once: later changes stay separate.",
                        actions: copy.isEmpty ? [] : [
                            SettingsAction(title: "Copy Settings", icon: "doc.on.doc", key: "copy") {
                                guard !copying else { return }
                                confirm = true
                            },
                        ])
                }
            }
            .alert("Replace \(target.name)'s settings?", isPresented: $confirm) {
                Button("Copy") { run(copy) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Watch history, library, add-ons, PIN and the profile itself stay as they are.")
            }
        }
    }

    private func toggle(_ id: String, _ title: String, _ description: String, _ copy: ProfileSetupCopy,
                        _ part: WritableKeyPath<ProfileSetupCopy, Bool>) -> some View {
        SettingsOnOffRow(id: id, title: title, description: description, isOn: copy[keyPath: part]) { on in
            self.copy = with(copy) { $0[keyPath: part] = on }
        }
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

/// Settings 2's Watched → a show's episodes: Remove All (the show's,
/// confirmed), then a section per season, a row per episode ("E3: name",
/// when), its bin; removed in place, undone with a second press, sent as
/// the page goes.
struct WatchedEpisodesCardPage: View {
    @EnvironmentObject private var watched: WatchedStore
    let id: String
    let name: String
    let meta: MetaItem?
    @State private var pending: Set<String> = []
    @State private var confirmAll = false

    private var items: [WatchedItem] {
        watched.items.values.filter { $0.contentID == id }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    var body: some View {
        let items = items
        let seasons = Dictionary(grouping: items) { $0.season ?? 0 }.sorted { $0.key < $1.key }
        SettingsPage(title: name) {
            if items.isEmpty {
                SettingsNote("No episodes watched.")
            } else {
                SettingsSection {
                    Button { confirmAll = true } label: {
                        SettingsRowLabel(title: "Remove All", value: "\(items.count - pending.count)", danger: true)
                    }
                    .settingsRow(id: "remove-all")
                }
                ForEach(seasons, id: \.key) { season, episodes in
                    SettingsSection(title: season == 0 ? "Specials" : "Season \(season)") {
                        ForEach(episodes, id: \.key) { item in
                            let gone = pending.contains(item.key)
                            ActionListRow(
                                id: item.key,
                                title: title(of: item),
                                detail: gone ? "Removed" : item.watchedAt.formatted(
                                    .dateTime.day().month(.abbreviated).year().hour().minute()),
                                dimmed: gone,
                                actions: [gone
                                    ? SettingsAction(title: "Undo", icon: "arrow.uturn.backward", key: "remove") {
                                        pending.remove(item.key)
                                    }
                                    : SettingsAction(title: "Remove", icon: "trash", danger: true, key: "remove") {
                                        pending.insert(item.key)
                                    }])
                        }
                    }
                }
            }
        }
        .onDisappear {
            if !pending.isEmpty { watched.remove(keys: Array(pending)) }
            pending = []
        }
        .alert("Remove all of \(name)?", isPresented: $confirmAll) {
            Button("Remove All", role: .destructive) {
                pending = []
                watched.remove(keys: items.map(\.key))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every episode is marked unwatched, on all your devices.")
        }
    }

    /// "E3: Episode title", else "E3".
    private func title(of item: WatchedItem) -> String {
        let number = "E\(item.episode ?? 0)"
        let video = meta?.videos?.first { $0.season == item.season && $0.episode == item.episode }
        let title = video?.title ?? (item.title == name || item.title == meta?.name ? "" : item.title)
        return title.isEmpty ? number : "\(number): \(title)"
    }
}

/// Settings 2's Watched: a row per title, newest first — a show's count and
/// its last episode, a film's date — Open (its Details), a show's Episodes
/// (its page, one by one) and Remove (the title, every episode; undone in
/// place).
struct WatchedCardPage: View {
    @EnvironmentObject private var nav: SettingsNav
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addonManager: AddonManager
    @State private var metas: [String: MetaItem] = [:]
    @State private var known: [String: String] = [:]
    @State private var ready = false

    private var entries: [WatchedSettingsPage.Entry] {
        Dictionary(grouping: watched.items.values, by: \.contentID)
            .map { WatchedSettingsPage.Entry(id: $0.key, items: $0.value) }
            .sorted { $0.latest > $1.latest }
    }

    var body: some View {
        let entries = entries
        RemovableListPage(
            title: "Watched",
            items: entries.map { entry in
                let name = name(of: entry)
                let meta = metas[entry.id]
                return .init(id: entry.id, poster: meta?.poster, name: name, detail: detail(of: entry),
                             meta: meta ?? MetaItem(id: entry.id, type: entry.type, name: name),
                             more: entry.isShow ? SettingsAction(title: "Episodes", icon: "list.bullet") {
                                 nav.push(WatchedEpisodesCardPage(id: entry.id, name: name, meta: meta))
                             } : nil)
            },
            ready: ready,
            empty: "Nothing watched yet.",
            removeAllTitle: "Remove all watch history?",
            removeAllMessage: "Every title and episode is marked unwatched, on all your devices.",
            remove: { id in
                if let entry = entries.first(where: { $0.id == id }) { watched.remove(keys: entry.items.map(\.key)) }
            },
            removeAll: {
                if let sync = NuvioSyncManager.shared {
                    Task { await sync.clearWatchHistoryEverywhere() }
                } else {
                    watched.clearAll()
                }
            })
        .animation(.easeOut(duration: 0.25), value: ready)
        .task {
            known = WatchedSettingsPage.knownNames(progress: progress, library: library)
            let wanted = entries.filter { metas[$0.id] == nil }.map { ($0.id, $0.type) }
            guard !wanted.isEmpty else { ready = true; return }
            let cap = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                ready = true
            }
            await WatchedSettingsPage.resolveMetas(wanted, addonManager: addonManager) { metas[$0] = $1 }
            cap.cancel()
            ready = true
        }
    }

    private func name(of entry: WatchedSettingsPage.Entry) -> String {
        if let name = metas[entry.id]?.name, !name.isEmpty { return name }
        if let name = known[entry.id] { return name }
        if !entry.isShow, let film = entry.items.first, !film.title.isEmpty { return film.title }
        return entry.id
    }

    /// "12 episodes · S2:E4, 14 Oct 2026"; a film its date.
    private func detail(of entry: WatchedSettingsPage.Entry) -> String {
        let date = entry.latest.formatted(.dateTime.day().month(.abbreviated).year())
        guard entry.isShow, let last = entry.items.max(by: { $0.watchedAt < $1.watchedAt }) else { return date }
        let count = entry.items.filter { $0.episode != nil }.count
        return "\(count == 1 ? "1 episode" : "\(count) episodes") · S\(last.season ?? 0):E\(last.episode ?? 0), \(date)"
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

/// Settings 2's Watch Progress: a row each, newest first, its bin.
struct WatchProgressCardPage: View {
    @EnvironmentObject private var progress: ProgressStore

    var body: some View {
        RemovableListPage(
            title: "Watch Progress",
            items: progress.items.values.sorted { $0.updatedAt > $1.updatedAt }.map {
                .init(id: $0.id, poster: $0.poster, name: $0.name.isEmpty ? $0.metaID : $0.name,
                      detail: WatchProgressPage.detail(of: $0),
                      meta: MetaItem(id: $0.metaID, type: $0.type, name: $0.name,
                                     poster: $0.poster, background: $0.background))
            },
            empty: "Nothing in progress.",
            removeAllTitle: "Remove all watch progress?",
            removeAllMessage: "Every position is removed, on all your devices.",
            remove: { progress.remove(id: $0) },
            removeAll: { progress.clearAllProgress() })
    }
}

/// Settings 2's Library: a row each, newest first, its bin.
struct LibraryCardPage: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let items = library.items.values.sorted { $0.addedAt > $1.addedAt }
        RemovableListPage(
            title: "Library",
            items: items.map {
                .init(id: $0.key, poster: $0.poster, name: $0.name,
                      detail: "Added \($0.addedAt.formatted(.dateTime.day().month(.abbreviated).year()))",
                      meta: $0.metaItem)
            },
            empty: "Nothing saved yet.",
            removeAllTitle: "Remove everything from your library?",
            removeAllMessage: "Saved for Later is emptied, on all your devices.",
            remove: { key in
                if let item = items.first(where: { $0.key == key }) { library.remove(id: item.id, type: item.type) }
            },
            removeAll: {
                // One by one: `clearAll` is the account switch's, it queues no deletes.
                for item in items { library.remove(id: item.id, type: item.type) }
            })
    }
}

/// Settings → Account → Library: what Home shows as Saved for Later, one
/// to a row, newest first, with the date it was added. Select starts Edit
/// on the row's button; Edit gives each row a trash button, one press
/// removes it, and Remove All beside Done. Removals reach the account
/// (`LibraryStore.onRemove`).
struct LibraryPage: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.settingsRowFocus) private var rowFocus
    @State private var editing = false

    private var rows: [SavedLibraryItem] {
        library.items.values.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        let rows = rows
        SettingsPage(title: "Library", subtitle: "", accessory: rows.isEmpty ? nil : AnyView(accessory)) {
            if rows.isEmpty {
                SettingsNote("Nothing saved yet.", large: true)
            } else {
                LazyVStack(spacing: SettingsMetrics.tallRowGap) {
                    ForEach(rows, id: \.key) { row($0, ids: rows.map(\.key)) }
                }
            }
        }
        .onExitCommand(perform: editing ? { end() } : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onChange(of: rows.isEmpty) { _, empty in if empty { editing = false } }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    private func row(_ item: SavedLibraryItem, ids: [String]) -> some View {
        WatchedRow(id: item.key, poster: item.poster, name: item.name,
                   detail: "Added \(item.addedAt.formatted(.dateTime.day().month(.abbreviated).year()))",
                   editing: editing,
                   removeLine: "Remove from your library, on all your devices",
                   onSelect: {
                       editing = true
                       DispatchQueue.main.async { rowFocus?.wrappedValue = item.key }
                   },
                   onRemove: {
                       WatchedRow.removed(item.key, in: ids, focus: rowFocus)
                       library.remove(id: item.id, type: item.type)
                   })
    }

    @ViewBuilder private var accessory: some View {
        if editing {
            SettingsCapsuleButton(title: "Remove All") {
                editing = false
                // One by one: `clearAll` is the account switch's, it queues no deletes.
                for item in rows { library.remove(id: item.id, type: item.type) }
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

