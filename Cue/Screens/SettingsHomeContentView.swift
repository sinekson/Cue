import SwiftUI

// MARK: - Home & Details

/// Settings → Home & Details: Home's rows (their order, names, which
/// show), Continue Watching's order, hiding watched titles, the billboard
/// paging by itself, trailers, hiding spoilers.
/// (The add-ons are Nuvio's, synced: under Nuvio → Sync.)
struct HomeContentSettingsDetail: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @AppStorage(BillboardAutoPage.key) private var billboardAutoPage = true
    @AppStorage(HomeHideWatched.key) private var hideWatched = false
    @AppStorage(DetailHideSpoilers.key) private var hideSpoilers = false

    var body: some View {
        let rows = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
        SettingsPage(title: SettingsCategory.homeContent.title) {
            SettingsSection {
                SettingsLinkRow(
                    title: "Home Rows",
                    description: "Choose which rows show on Home, their order and their names.",
                    value: "\(rows.filter { $0.isShown(settings: settings) }.count)"
                ) { HomeRowsPage() }

                SettingsOptionsRow(
                    title: "Continue Watching Order",
                    pageDescription: "Choose how Continue Watching is sorted. Last Watched puts what you played "
                        + "most recently first. In Progress First puts titles you're part way through "
                        + "ahead of the rest.",
                    options: ContinueWatchingSortMode.allCases.map { SettingsOption(id: $0.rawValue, label: $0.displayName) },
                    selection: settings.continueWatchingSortMode.rawValue
                ) { settings.continueWatchingSortMode = ContinueWatchingSortMode(rawValue: $0) ?? .recentlyWatched }

                SettingsToggleRow(
                    title: "Hide Watched Titles",
                    description: "Leaves films you've watched and shows you've finished out of Home's rows.",
                    isOn: $hideWatched
                )

                SettingsToggleRow(
                    title: "Auto-Advance Billboard",
                    description: "Moves on to the next title every \(Int(BillboardAutoPage.interval)) seconds.",
                    isOn: $billboardAutoPage
                )

                SettingsOptionsRow(
                    title: "Trailers",
                    pageDescription: "Choose how trailers play when you rest on a title on the billboard or Details. "
                        + "With Sound plays them with it. Silent plays them without sound. "
                        + "Off leaves the picture still.",
                    options: [SettingsOption(id: "sound", label: "With Sound"),
                              SettingsOption(id: "silent", label: "Silent"),
                              SettingsOption(id: "off", label: "Off")],
                    selection: !settings.heroTrailersEnabled ? "off" : settings.heroTrailerSound ? "sound" : "silent"
                ) {
                    settings.heroTrailersEnabled = $0 != "off"
                    if $0 != "off" { settings.heroTrailerSound = $0 == "sound" }
                }

                SettingsToggleRow(
                    title: "Hide Spoilers",
                    description: "Blurs the pictures of episodes you haven't watched.",
                    isOn: $hideSpoilers
                )
            }
        }
    }
}

// MARK: - Rows

/// One of Home's rows, as the Rows page lists it: a catalog or a
/// collection (each its own row on Home).
private struct HomeRowEntry: Identifiable {
    let key: String
    let defaultTitle: String
    /// The add-on it comes from.
    let source: String
    var id: String { key }

    @MainActor
    func title(settings: HomeCatalogSettingsStore) -> String {
        settings.customTitle(for: key) ?? defaultTitle
    }

    @MainActor
    func isShown(settings: HomeCatalogSettingsStore) -> Bool { settings.isEnabled(key: key) }

    @MainActor
    static func collectionKeys(_ collections: CollectionsStore) -> [String] {
        collections.collections.map { HomeCatalogSettingsStore.collectionKey($0.id) }
    }

    /// Every catalog an add-on offers as a plain row (no required extras).
    @MainActor
    static func catalogKeys(_ addonManager: AddonManager) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
        return keys
    }

    /// The rows in Home's order.
    @MainActor
    static func all(addonManager: AddonManager, collections: CollectionsStore,
                    settings: HomeCatalogSettingsStore) -> [HomeRowEntry] {
        var byKey: [String: HomeRowEntry] = [:]
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                if byKey[key] == nil {
                    byKey[key] = HomeRowEntry(key: key, defaultTitle: catalog.displayName, source: addon.displayName)
                }
            }
        }
        for collection in collections.collections {
            let key = HomeCatalogSettingsStore.collectionKey(collection.id)
            byKey[key] = HomeRowEntry(key: key, defaultTitle: collection.title, source: "Collection")
        }
        var result: [HomeRowEntry] = []
        for key in settings.mergedOrder(catalogKeys: catalogKeys(addonManager),
                                        collectionKeys: collectionKeys(collections)) {
            if let entry = byKey[key] { result.append(entry) }
        }
        return result
    }
}

/// Settings → Home & Details → Home Rows: Home's rows in order, as the
/// add-ons': a row each (its name, where it comes from, "Off" when hidden),
/// lit whole; Select opens its page (`HomeRowPage`). Edit, on the title's
/// line, gives each row an on / off and the ≡ handle; Done or Back ends it.
/// (Tried: each one line with Rename, Move and a switch.)
private struct HomeRowsPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus
    @State private var editing = false
    @State private var moving: String?

    var body: some View {
        let rows = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
        SettingsPage(title: "Home Rows",
                     accessory: AnyView(accessory(hasRows: !rows.isEmpty))) {
            SettingsSection(spacing: SettingsMetrics.tallRowGap) {
                ForEach(rows) { row in
                    let shown = row.isShown(settings: settings)
                    SettingsReorderRow(
                        title: row.title(settings: settings), id: row.id,
                        value: shown ? row.source : "Off",
                        chevron: true,
                        dimmed: !shown,
                        toggle: SettingsEntrySwitch(isOn: shown, title: shown ? "Hide" : "Show") {
                            settings.setEnabled(!shown, key: row.key)
                        },
                        editing: editing, isMoving: moving == row.id, anyMoving: moving != nil,
                        onSelect: { nav.push(HomeRowPage(key: row.key)) },
                        onLift: { moving = row.id },
                        onMoveStep: { step in
                            settings.move(key: row.key, up: step < 0,
                                          within: HomeRowEntry.catalogKeys(addonManager)
                                              + HomeRowEntry.collectionKeys(collections))
                        },
                        onDrop: { moving = nil })
                }
            }
        }
        .onExitCommand(perform: editing && moving == nil ? endEditing : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onDisappear { TopBarLock.shared.locked = false }
    }

    @ViewBuilder private func accessory(hasRows: Bool) -> some View {
        if editing {
            SettingsCapsuleButton(title: "Done", action: endEditing).disabled(moving != nil)
        } else if hasRows {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func endEditing() {
        moving = nil; editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = "Edit" }
    }
}

/// A Home row's own page: Rename (the keyboard; empty or the original: its
/// own name again), and where it comes from, to read.
private struct HomeRowPage: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore
    let key: String

    @State private var keyboard: KeyboardRequest?

    var body: some View {
        if let row = HomeRowEntry.all(addonManager: addonManager, collections: collections, settings: settings)
            .first(where: { $0.key == key }) {
            let name = row.title(settings: settings)
            SettingsPage(title: name) {
                SettingsSection {
                    SettingsButtonRow(title: "Rename", value: name) {
                        keyboard = KeyboardRequest(text: name, placeholder: row.defaultTitle) { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.setCustomTitle(trimmed == row.defaultTitle ? nil : trimmed, key: row.key)
                        }
                    }
                    SettingsInfoRow(title: "Source", value: row.source)
                        .padding(.top, SettingsMetrics.infoGap)
                }
            }
            .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
        }
    }
}

// MARK: - Add-ons

/// Settings → Nuvio → Add-ons: the add-ons in order, a row each (its logo,
/// its name, "Off" when off), lit whole; Select opens its page
/// (`AddonPage`: Configure, Rename, Remove). Edit, on the title's line,
/// gives each row an on / off and the ≡ handle (`SettingsReorderRow`);
/// Done or Back ends it. Then Add Add-on (from your phone), as Profiles'
/// Add Profile, and Refresh Add-ons (their manifests fetched again, this
/// device only). (Tried: each one line with Configure, Rename, Move, a
/// switch and Remove — too many buttons; a round + by the heading.)
struct AddonsPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    @Environment(\.settingsRowFocus) private var rowFocus
    @State private var editing = false
    @State private var moving: String?
    @State private var adding = false
    @State private var refreshing = false
    /// The last refresh's add-ons that didn't answer (this visit).
    @State private var failed = 0
    @AppStorage("cue.addons.refreshedAt") private var refreshedAt: Double = 0

    private var refreshValue: String {
        if refreshing { return "Refreshing…" }
        if failed > 0 { return failed == 1 ? "1 didn't answer" : "\(failed) didn't answer" }
        guard refreshedAt > 0 else { return "Not yet" }
        return DateFormatter.settingsWhen.string(from: Date(timeIntervalSince1970: refreshedAt))
    }

    var body: some View {
        SettingsPage(title: "Add-ons", subtitle: "Higher ones come first for sources.",
                     accessory: AnyView(accessory)) {
            SettingsSection(spacing: SettingsMetrics.tallRowGap) {
                ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, addon in
                    SettingsReorderRow(
                        title: addon.displayName, id: addon.id,
                        leading: AnyView(AddonLogo(addon: addon)),
                        value: addon.enabled ? nil : "Off",
                        chevron: true,
                        dimmed: !addon.enabled,
                        toggle: SettingsEntrySwitch(isOn: addon.enabled, title: addon.enabled ? "Turn off" : "Turn on") {
                            addonManager.setEnabled(addon, !addon.enabled)
                        },
                        editing: editing, isMoving: moving == addon.id, anyMoving: moving != nil,
                        onSelect: { nav.push(AddonPage(addonID: addon.id)) },
                        onLift: { moving = addon.id },
                        onMoveStep: { addonManager.move(addon, to: index + $0) },
                        onDrop: { moving = nil })
                }
                // Under the list as Apple's Add Language…, the rows' own gap between them.
                VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                    SettingsButtonRow(title: "Add Add-on") { adding = true }
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
                .disabled(editing)
                .padding(.top, SettingsMetrics.listButtonGap - SettingsMetrics.tallRowGap)
            }
        }
        .onExitCommand(perform: editing && moving == nil ? endEditing : nil)
        .onChange(of: editing) { _, editing in TopBarLock.shared.locked = editing }
        .onDisappear { TopBarLock.shared.locked = false }
        .fullScreenCover(isPresented: $adding) {
            AddonPhoneAddView(addonManager: addonManager) { adding = false }
                .environmentObject(theme)
        }
    }

    @ViewBuilder private var accessory: some View {
        if editing {
            SettingsCapsuleButton(title: "Done", action: endEditing).disabled(moving != nil)
        } else if !addonManager.addons.isEmpty {
            SettingsCapsuleButton(title: "Edit") {
                editing = true
                DispatchQueue.main.async { rowFocus?.wrappedValue = "Done" }
            }
        }
    }

    private func endEditing() {
        moving = nil; editing = false
        DispatchQueue.main.async { rowFocus?.wrappedValue = "Edit" }
    }
}

/// An add-on's own page: Configure (when it has settings — its page on
/// your phone), Rename (the keyboard; empty: its own name again), Remove
/// (confirmed; back to the list).
private struct AddonPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    let addonID: String

    @State private var keyboard: KeyboardRequest?
    @State private var configuring = false
    @State private var confirmRemove = false

    private var addon: InstalledAddon? { addonManager.addons.first { $0.id == addonID } }

    var body: some View {
        if let addon {
            SettingsPage(title: addon.displayName, subtitle: addon.manifest.description ?? "") {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                    if addon.configureURL != nil {
                        SettingsButtonRow(title: "Configure") { configuring = true }
                    }
                    SettingsButtonRow(title: "Rename", value: addon.displayName) {
                        keyboard = KeyboardRequest(text: addon.displayName, placeholder: addon.manifest.name) {
                            addonManager.rename(addon, to: $0)
                        }
                    }
                    SettingsButtonRow(title: "Remove") { confirmRemove = true }
                }
            }
            .background(KeyboardPresenter(request: $keyboard).frame(width: 1, height: 1))
            .fullScreenCover(isPresented: $configuring) {
                AddonPhoneAddView(addonManager: addonManager, configuring: addon) { configuring = false }
                    .environmentObject(theme)
            }
            .alert("Remove \(addon.displayName)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    nav.back()
                    addonManager.remove(addon)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's removed from this device and your account. You can add it back later with its link.")
            }
        }
    }
}

/// An add-on's logo, small, on the left of its row.
private struct AddonLogo: View {
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
